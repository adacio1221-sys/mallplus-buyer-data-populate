#!/bin/bash
# expire-order.sh — simulate an auto-cancellation by either the unpaid-expiry
# cron (24h non-payment) or the SBD/SLA cron (seller didn't ship past
# SBD+2d). Cancels the order via the admin script-console, then patches the
# order's metadata to mimic the cron job's end state.
#
# Usage: expire-order.sh <order_id> <unpaid|sla> [env=prod]
#
# State expectations:
#   - unpaid: order must be at status=pending, payment_status=not_paid
#             (i.e. in the "To Pay" tab).
#   - sla:    order must be at status=pending, payment_status=captured,
#             fulfillment_status=not_fulfilled (i.e. in "To Ship").
#
# This is a state simulation. It does NOT fire the buyer/seller email
# notifications that the actual cron job sends — only the DB metadata
# matches. If you need notifications too, ask the team to expose the job
# via the script-console.
#
# On success, prints `<order_id> expired <reason>`. Non-zero exit + stderr
# on failure.

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <order_id> <unpaid|sla> [env=prod]" >&2
  exit 2
fi

ORDER_ID=$1
REASON=$2
ENV=${3:-prod}

# Accept either a Medusa ULID or a storefront order_sn.
RESOLVED=$(/Users/daydream/buyer-data-populate/bot/resolve-order-id.sh "$ORDER_ID" "$ENV" 2>&1) || { echo "$RESOLVED" >&2; exit 1; }
ORDER_ID=$RESOLVED

case "$REASON" in
  unpaid|sla) ;;
  *) echo "error: reason must be 'unpaid' or 'sla' (got '$REASON')" >&2; exit 2 ;;
esac

case "$ENV" in
  stage|staging)
    API_BASE=${MEDUSA_API_BASE_STAGE:-https://staging-api.mallplus.ph}
    ADMIN_EMAIL=${MEDUSA_ADMIN_EMAIL_STAGE:-admin@medusa-test.com}
    ADMIN_PASSWORD=${MEDUSA_ADMIN_PASSWORD_STAGE:-supersecret}
    SC_PASSWORD=${MEDUSA_SCRIPT_CONSOLE_PASSWORD_STAGE:-123} ;;
  dev|development)
    API_BASE=${MEDUSA_API_BASE_DEV:-https://dev-api.mallplus.ph}
    ADMIN_EMAIL=${MEDUSA_ADMIN_EMAIL_DEV:-admin@medusa-test.com}
    ADMIN_PASSWORD=${MEDUSA_ADMIN_PASSWORD_DEV:-supersecret}
    SC_PASSWORD=${MEDUSA_SCRIPT_CONSOLE_PASSWORD_DEV:-123} ;;
  prod|production)
    API_BASE=${MEDUSA_API_BASE_PROD:-https://api.mallplus.ph}
    ADMIN_EMAIL=${MEDUSA_ADMIN_EMAIL_PROD:-admin@medusa-test.com}
    ADMIN_PASSWORD=${MEDUSA_ADMIN_PASSWORD_PROD:-supersecret}
    SC_PASSWORD=${MEDUSA_SCRIPT_CONSOLE_PASSWORD_PROD:-123} ;;
  *) echo "error: env must be 'stage' | 'dev' | 'prod'" >&2; exit 2 ;;
esac

# Fetch admin token with primary + fallback handling (see bot/admin-token.sh).
TOKEN=$(/Users/daydream/buyer-data-populate/bot/admin-token.sh "$ENV") \
  || { echo "error: admin login failed for env=$ENV" >&2; exit 1; }

# 2. Fetch current order state. Refuse if it doesn't match the required
# starting state for the chosen reason.
STATE_JSON=$(/usr/bin/curl -s "$API_BASE/admin/orders/$ORDER_ID?fields=id,status,payment_status,fulfillment_status,canceled_at" \
  -H "Authorization: Bearer $TOKEN")
read STATUS PAY_STATUS FUL_STATUS CANCELED_AT < <(echo "$STATE_JSON" | /usr/bin/python3 -c "
import json, sys
try:
    o = json.load(sys.stdin).get('order') or {}
    print(o.get('status') or '_', o.get('payment_status') or '_', o.get('fulfillment_status') or '_', o.get('canceled_at') or '_')
except Exception as e:
    print('_ _ _ _', file=sys.stderr)
")
if [ -z "${STATUS:-}" ] || [ "$STATUS" = "_" ]; then
  echo "error: could not read order $ORDER_ID (404 or admin access denied)" >&2
  exit 1
fi

case "$REASON" in
  unpaid)
    if [ "$STATUS" != "pending" ] || [ "$PAY_STATUS" != "not_paid" ]; then
      echo "error: order $ORDER_ID is not in 'unpaid' state (need pending/not_paid, got $STATUS/$PAY_STATUS/$FUL_STATUS)" >&2
      exit 1
    fi ;;
  sla)
    if [ "$STATUS" != "pending" ] || [ "$PAY_STATUS" != "captured" ] || [ "$FUL_STATUS" != "not_fulfilled" ]; then
      echo "error: order $ORDER_ID is not in 'to_ship' state (need pending/captured/not_fulfilled, got $STATUS/$PAY_STATUS/$FUL_STATUS)" >&2
      exit 1
    fi ;;
esac

# 3. Build the metadata payload that mirrors the cron job's output.
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
case "$REASON" in
  unpaid)
    DEADLINE=$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)
    META_PYJSON="{
  'auto_cancelled_unpaid': True,
  'cancellation_reason': 'unpaid_auto_cancel',
  'cancellation_reason_details': 'Order unpaid for more than 24 hours',
  'cancelled_by': 'system_unpaid_auto_cancel',
  'cancelled_at': '$NOW',
  'unpaid_auto_cancel_deadline': '$DEADLINE'
}" ;;
  sla)
    DEADLINE=$(date -u -v-48H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)
    META_PYJSON="{
  'auto_cancelled_sla': True,
  'cancellation_reason': 'sbd_auto_cancel',
  'cancellation_reason_details': 'Seller did not ship within 2 day(s) past SBD deadline',
  'cancelled_by': 'system_sbd_auto_cancel',
  'cancelled_at': '$NOW',
  'sbd_auto_cancel_deadline': '$DEADLINE'
}" ;;
esac
META_JSON=$(/usr/bin/python3 -c "import json; print(json.dumps($META_PYJSON))")

# 4. Script-console auth + cancel via the QA script.
AUTHZ=$(/usr/bin/curl -s -X POST "$API_BASE/admin/script-console/auth" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"password\":\"$SC_PASSWORD\"}" \
  | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d.get('authorized') else '')")
if [ "$AUTHZ" != "yes" ]; then
  echo "error: script-console auth rejected" >&2
  exit 1
fi

RUN_BODY=$(/usr/bin/python3 -c "
import json
print(json.dumps({
  'script': 'orders/update-order-status-qa.js',
  'args': ['ORDER_ID=$ORDER_ID', 'STATUS=canceled', 'FORCE=true']
}))")
CANCEL_RESP=$(/usr/bin/curl -s -X POST "$API_BASE/admin/script-console/scripts/run" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-script-console-password: $SC_PASSWORD" \
  -d "$RUN_BODY")
CANCEL_OK=$(echo "$CANCEL_RESP" | /usr/bin/python3 -c "
import json, sys, re
try:
    d = json.load(sys.stdin)
    buf = json.dumps(d)
    if re.search(r'UPDATED TO CANCELED SUCCESSFULLY|already canceled', buf, re.IGNORECASE):
        print('ok')
    else:
        print('fail')
except Exception:
    print('fail')")
if [ "$CANCEL_OK" != "ok" ]; then
  echo "error: cancel via script-console failed for $ORDER_ID" >&2
  echo "$CANCEL_RESP" | head -c 600 >&2
  exit 1
fi

# 5. Patch the order's metadata. The admin REST endpoint refuses edits to
# canceled orders, so we go through the script-console SQL runner — same
# mechanism the cron job uses (orderModule.updateOrders bypasses the REST
# guard). Single jsonb-merge UPDATE on the order row.
SQL_BODY=$(META_JSON="$META_JSON" EOID="$ORDER_ID" /usr/bin/python3 <<'PYEOF'
import json, os
meta = json.loads(os.environ["META_JSON"])
order_id = os.environ["EOID"]
meta_str = json.dumps(meta).replace("'", "''")
sql = (
    "UPDATE \"order\" SET metadata = COALESCE(metadata, '{}'::jsonb) || '"
    + meta_str
    + "'::jsonb WHERE id = '"
    + order_id
    + "';"
)
print(json.dumps({"query": sql}))
PYEOF
)
SQL_CODE=$(/usr/bin/curl -s -o /tmp/expire-order-sql.json -w "%{http_code}" \
  -X POST "$API_BASE/admin/script-console/sql/run" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-script-console-password: $SC_PASSWORD" \
  -d "$SQL_BODY")
if [ "$SQL_CODE" != "200" ]; then
  echo "error: metadata SQL update returned HTTP $SQL_CODE for $ORDER_ID" >&2
  /bin/cat /tmp/expire-order-sql.json | head -c 600 >&2
  exit 1
fi
AFFECTED=$(/usr/bin/python3 -c "
import json
try:
    d = json.load(open('/tmp/expire-order-sql.json'))
    print(d.get('affectedRows', d.get('rowCount', d.get('result', {}).get('rowCount', 0))))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
if [ "$AFFECTED" = "0" ]; then
  echo "error: metadata SQL update affected 0 rows (order may not exist with that id)" >&2
  /bin/cat /tmp/expire-order-sql.json | head -c 400 >&2
  exit 1
fi

echo "$ORDER_ID expired $REASON"
