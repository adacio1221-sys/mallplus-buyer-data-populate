#!/bin/bash
# fix-refund-amount.sh — patch an existing order_return_request_case's
# requested/approved/final refund amounts when the buyer flow created
# the case with 0 (recurring backend bug).
#
# Usage: fix-refund-amount.sh <order_id_or_sn> [env=prod]
#
# Sources the correct amount from the order's captured payment (sum of
# captured amounts on the order's payment chain). Updates all three
# refund-amount columns + their jsonb mirrors on the most recent
# non-deleted case for the order, so the seller portal & buyer storefront
# stop showing ₱0 wherever they read these fields.
#
# Does NOT create cases — only patches an existing one. Use refund-state.sh
# to create a new case from scratch.

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "usage: $0 <order_id_or_sn> [env=stage|dev|prod]" >&2
  exit 2
fi

ORDER_IN=$1
ENV=${2:-prod}

RESOLVED=$(/Users/daydream/buyer-data-populate/bot/resolve-order-id.sh "$ORDER_IN" "$ENV" 2>&1) || { echo "$RESOLVED" >&2; exit 1; }
ORDER_ID=$RESOLVED

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

sql_run() {
  local query=$1
  local body
  body=$(/usr/bin/python3 -c "import json,sys; print(json.dumps({'query': sys.argv[1]}))" "$query")
  /usr/bin/curl -s -X POST "$API_BASE/admin/script-console/sql/run" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $TOKEN" \
    -H "x-script-console-password: $SC_PASSWORD" \
    -d "$body"
}

# 1. Resolve the case + actual payment amount.
LOOKUP=$(sql_run "SELECT c.id AS case_id, c.currency_code, COALESCE((SELECT SUM(p.amount) FROM payment p WHERE p.payment_collection_id IN (SELECT payment_collection_id FROM order_payment_collection WHERE order_id = c.order_id) AND p.captured_at IS NOT NULL), 0) AS captured_total FROM order_return_request_case c WHERE c.order_id = '$ORDER_ID' AND c.deleted_at IS NULL ORDER BY c.created_at DESC LIMIT 1")

CASE_ID=$(echo "$LOOKUP" | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('case_id', '') if rows else '')
except Exception:
    print('')")
CAPTURED=$(echo "$LOOKUP" | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('captured_total', '0') if rows else '0')
except Exception:
    print('0')")
CCY=$(echo "$LOOKUP" | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('currency_code', 'PHP') if rows else 'PHP')
except Exception:
    print('PHP')")

if [ -z "$CASE_ID" ]; then
  echo "error: no return-request-case found for $ORDER_ID" >&2
  exit 1
fi
if [ "$CAPTURED" = "0" ] || [ -z "$CAPTURED" ]; then
  echo "error: no captured payment for $ORDER_ID — nothing to refund" >&2
  exit 1
fi

# 2. Patch all three amount columns + their raw_ jsonb mirrors.
RAW_JSON="{\"value\":\"$CAPTURED\",\"precision\":20}"
UPDATE_SQL="UPDATE order_return_request_case SET requested_refund_amount = $CAPTURED, approved_refund_amount = $CAPTURED, final_refund_amount = $CAPTURED, raw_requested_refund_amount = '$RAW_JSON'::jsonb, raw_approved_refund_amount = '$RAW_JSON'::jsonb, raw_final_refund_amount = '$RAW_JSON'::jsonb WHERE id = '$CASE_ID'"
RES=$(sql_run "$UPDATE_SQL")
AFFECTED=$(echo "$RES" | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('affectedRows', 0))" 2>/dev/null || echo 0)
if [ "$AFFECTED" = "0" ]; then
  echo "error: case UPDATE affected 0 rows" >&2
  echo "$RES" | head -c 400 >&2
  exit 1
fi

echo "$ORDER_ID refund-amount-fixed case=$CASE_ID amount=$CAPTURED $CCY"
