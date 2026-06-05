#!/bin/bash
# attach-pod.sh — attach a proof-of-delivery (photo + recipient name) to an
# order's fulfillment by firing a synthetic J&T "Delivered" webhook. Goes
# through the normal /3pl/webhook/jt pipeline (MP-7037), so it persists
# `proof_of_delivery_url` + `proof_of_delivery_recipient_name` into
# fulfillment.metadata exactly the way a real JT POD upload would. Does NOT
# move the order to "completed" — POD lives on fulfillment, status flip is
# a separate buyer action.
#
# Usage:
#   attach-pod.sh <order_id_or_sn> [env=prod] [--url=<photo_url>] [--recipient=<name>]
#
# Defaults:
#   url       = https://via.placeholder.com/600x400.jpg?text=QA+POD
#   recipient = "QA Recipient"
#
# Pre-flight: requires an existing JT shipment (i.e. arrange-pickup has run
# and a waybill exists). Refuses if no `jt_shipment.bill_code` for the order.
#
# On success: `<order_id> attach-pod waybill=<bill_code>`.
# On failure: prints diagnostic lines to stderr and exits non-zero.

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 4 ]; then
  echo "usage: $0 <order_id_or_sn> [env=stage|dev|prod] [--url=<photo_url>] [--recipient=<name>]" >&2
  exit 2
fi

INPUT=$1
shift
ENV=prod
POD_URL='https://via.placeholder.com/600x400.jpg?text=QA+POD'
POD_RECIPIENT='QA Recipient'

for arg in "$@"; do
  case "$arg" in
    --url=*)       POD_URL="${arg#--url=}" ;;
    --recipient=*) POD_RECIPIENT="${arg#--recipient=}" ;;
    stage|staging|dev|development|prod|production) ENV=$arg ;;
    *) echo "error: unrecognized arg '$arg'" >&2; exit 2 ;;
  esac
done

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

# Resolve order_sn → ULID (pass-through for ULIDs).
RESOLVED=$(/Users/daydream/buyer-data-populate/bot/resolve-order-id.sh "$INPUT" "$ENV" 2>&1) \
  || { echo "$RESOLVED" >&2; exit 1; }
ORDER_ID=$RESOLVED

TOKEN=$(/usr/bin/curl -s -X POST "$API_BASE/auth/user/emailpass" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" \
  | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))")
[ -z "$TOKEN" ] && { echo "error: admin login failed" >&2; exit 1; }

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

# Look up the order's waybill from jt_shipment. Prefer the most recent
# non-deleted, non-canceled shipment (excludes orphan/retry rows).
LOOKUP=$(sql_run "SELECT bill_code, fulfillment_id FROM jt_shipment WHERE order_id = '$ORDER_ID' AND deleted_at IS NULL AND bill_code IS NOT NULL ORDER BY created_at DESC LIMIT 1")
BILL_CODE=$(echo "$LOOKUP" | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('bill_code', '') if rows else '')
except Exception:
    print('')")
if [ -z "$BILL_CODE" ]; then
  echo "error: no jt_shipment.bill_code for $ORDER_ID — arrange-pickup must run first to create a JT waybill" >&2
  exit 1
fi

# Build a J&T webhook payload. The 3pl webhook endpoint is public (no auth);
# it stores the raw payload, dedupes via event_id, and the normalizer extracts
# proof_of_delivery_url from signImg + recipient from signByName.
NOW_MANILA=$(/usr/bin/python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) + timedelta(hours=8)).strftime('%Y-%m-%d %H:%M:%S'))")

PAYLOAD=$(/usr/bin/python3 -c "
import json, sys
print(json.dumps({
  'billCode': sys.argv[1],
  'status': 'Delivered',
  'updatedTime': sys.argv[2],
  'orderId': sys.argv[3],
  'signImg': sys.argv[4],
  'signByName': sys.argv[5],
  'scanCity': 'QA'
}))" "$BILL_CODE" "$NOW_MANILA" "$ORDER_ID" "$POD_URL" "$POD_RECIPIENT")

HTTP=$(/usr/bin/curl -s -o /tmp/attach_pod.out -w '%{http_code}' \
  -X POST "$API_BASE/3pl/webhook/jt" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD")

if [ "$HTTP" != "200" ] && [ "$HTTP" != "201" ] && [ "$HTTP" != "202" ]; then
  echo "error: webhook POST returned HTTP $HTTP" >&2
  /usr/bin/head -c 400 /tmp/attach_pod.out >&2
  echo >&2
  exit 1
fi

# Webhook is processed async. Poll fulfillment.metadata briefly for the POD
# field to confirm propagation — exits as soon as it lands or after timeout.
DEADLINE=$((SECONDS + 20))
while [ $SECONDS -lt $DEADLINE ]; do
  POD_PERSISTED=$(sql_run "SELECT (metadata ->> 'proof_of_delivery_url') AS pod FROM fulfillment WHERE id IN (SELECT fulfillment_id FROM order_fulfillment WHERE order_id = '$ORDER_ID') AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 1" \
    | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('pod', '') if rows else '')
except Exception:
    print('')")
  if [ -n "$POD_PERSISTED" ]; then
    echo "$ORDER_ID attach-pod waybill=$BILL_CODE"
    exit 0
  fi
  /bin/sleep 2
done

echo "warning: webhook accepted (HTTP $HTTP) but POD field not visible on fulfillment after 20s — subscriber may be backlogged" >&2
echo "$ORDER_ID attach-pod waybill=$BILL_CODE pending"
exit 0
