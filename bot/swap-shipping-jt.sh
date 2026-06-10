#!/bin/bash
# swap-shipping-jt.sh — swap an order's order_shipping_method.shipping_option_id
# to the J&T Express option for the same shipping_profile, so the order
# routes via real J&T (channel_code=JNT-EXP-FWD) instead of the
# auto-created `manual-fulfillment` fallback that the populator script
# picks by default (first-match-by-ULID).
#
# Usage: swap-shipping-jt.sh <order_id_or_sn> [env=prod] [--prefer=standard|jt|own]
#
# - `--prefer=jt` (default) prefers the J&T Express option
#   (data.channel_code = 'JNT-EXP-FWD').
# - `--prefer=standard` prefers Standard Delivery (STD-DELIVERY-FWD,
#   J&T's masked channel).
# - `--prefer=own` prefers Seller Own Shipment (SELLER-OWN-FWD).
#
# Idempotent: if the order's current shipping option already has the
# preferred channel_code, no-op.
#
# On success: `<order_id> swap-shipping channel=<channel_code> option=<so_id>`.

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <order_id_or_sn> [env=stage|dev|prod] [--prefer=jt|standard|own]" >&2
  exit 2
fi

INPUT=$1
shift
ENV=prod
PREFER=jt
for arg in "$@"; do
  case "$arg" in
    --prefer=jt)        PREFER=jt ;;
    --prefer=standard)  PREFER=standard ;;
    --prefer=own)       PREFER=own ;;
    stage|staging|dev|development|prod|production) ENV=$arg ;;
    *) echo "error: unrecognized arg '$arg'" >&2; exit 2 ;;
  esac
done

case "$PREFER" in
  jt)        TARGET_CHANNEL='JNT-EXP-FWD' ;;
  standard)  TARGET_CHANNEL='STD-DELIVERY-FWD' ;;
  own)       TARGET_CHANNEL='SELLER-OWN-FWD' ;;
esac

case "$ENV" in
  stage|staging) API_BASE=${MEDUSA_API_BASE_STAGE:-https://staging-api.mallplus.ph}
                 SC_PASSWORD=${MEDUSA_SCRIPT_CONSOLE_PASSWORD_STAGE:-123} ;;
  dev|development) API_BASE=${MEDUSA_API_BASE_DEV:-https://dev-api.mallplus.ph}
                   SC_PASSWORD=${MEDUSA_SCRIPT_CONSOLE_PASSWORD_DEV:-123} ;;
  prod|production) API_BASE=${MEDUSA_API_BASE_PROD:-https://api.mallplus.ph}
                   SC_PASSWORD=${MEDUSA_SCRIPT_CONSOLE_PASSWORD_PROD:-123} ;;
  *) echo "error: env must be 'stage' | 'dev' | 'prod'" >&2; exit 2 ;;
esac

RESOLVED=$(/Users/daydream/buyer-data-populate/bot/resolve-order-id.sh "$INPUT" "$ENV" 2>&1) \
  || { echo "$RESOLVED" >&2; exit 1; }
ORDER_ID=$RESOLVED

TOKEN=$(/Users/daydream/buyer-data-populate/bot/admin-token.sh "$ENV") \
  || { echo "error: admin login failed for env=$ENV" >&2; exit 1; }

sql_run() {
  local query=$1 body
  body=$(/usr/bin/python3 -c "import json,sys;print(json.dumps({'query': sys.argv[1]}))" "$query")
  /usr/bin/curl -s -X POST "$API_BASE/admin/script-console/sql/run" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $TOKEN" \
    -H "x-script-console-password: $SC_PASSWORD" \
    -d "$body"
}

# Find the order's current shipping_method + its shipping_profile_id
LOOKUP=$(sql_run "SELECT osm.id AS osm_id, osm.shipping_option_id, so.shipping_profile_id, so.data->>'channel_code' AS current_channel FROM order_shipping os JOIN order_shipping_method osm ON osm.id = os.shipping_method_id JOIN shipping_option so ON so.id = osm.shipping_option_id WHERE os.order_id = '$ORDER_ID' LIMIT 1")

OSM_ID=$(echo "$LOOKUP" | /usr/bin/python3 -c "
import json,sys
try:
  r = json.load(sys.stdin).get('rows',[])
  print(r[0].get('osm_id','') if r else '')
except: print('')")
PROFILE_ID=$(echo "$LOOKUP" | /usr/bin/python3 -c "
import json,sys
try:
  r = json.load(sys.stdin).get('rows',[])
  print(r[0].get('shipping_profile_id','') if r else '')
except: print('')")
CURRENT_CHANNEL=$(echo "$LOOKUP" | /usr/bin/python3 -c "
import json,sys
try:
  r = json.load(sys.stdin).get('rows',[])
  print(r[0].get('current_channel','') or '' if r else '')
except: print('')")

if [ -z "$OSM_ID" ] || [ -z "$PROFILE_ID" ]; then
  echo "error: could not resolve shipping_method / shipping_profile for $ORDER_ID" >&2
  exit 1
fi
if [ "$CURRENT_CHANNEL" = "$TARGET_CHANNEL" ]; then
  echo "$ORDER_ID swap-shipping already-on channel=$TARGET_CHANNEL"
  exit 0
fi

TARGET=$(sql_run "SELECT id, name FROM shipping_option WHERE shipping_profile_id = '$PROFILE_ID' AND data->>'channel_code' = '$TARGET_CHANNEL' AND deleted_at IS NULL ORDER BY created_at ASC LIMIT 1")
TARGET_SO_ID=$(echo "$TARGET" | /usr/bin/python3 -c "
import json,sys
try:
  r = json.load(sys.stdin).get('rows',[])
  print(r[0].get('id','') if r else '')
except: print('')")
if [ -z "$TARGET_SO_ID" ]; then
  echo "error: no shipping_option with channel_code='$TARGET_CHANNEL' for profile $PROFILE_ID (env=$ENV)" >&2
  exit 1
fi

RES=$(sql_run "UPDATE order_shipping_method SET shipping_option_id = '$TARGET_SO_ID' WHERE id = '$OSM_ID'")
AFFECTED=$(echo "$RES" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('affectedRows', 0))" 2>/dev/null || echo 0)
if [ "$AFFECTED" = "0" ]; then
  echo "error: order_shipping_method UPDATE affected 0 rows" >&2
  exit 1
fi

echo "$ORDER_ID swap-shipping channel=$TARGET_CHANNEL option=$TARGET_SO_ID"
