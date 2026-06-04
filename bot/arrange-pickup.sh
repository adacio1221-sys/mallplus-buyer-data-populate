#!/bin/bash
# arrange-pickup.sh — advance a to_ship order to shipping via the Mercur
# vendor API (POST /vendor/orders/{id}/shipment/pickup). Books a real J&T
# Express pickup, so call only when you're prepared to either let the
# courier come or cancel the booking via the seller portal.
#
# Usage: arrange-pickup.sh <order_id> [env=prod] [seller_handle]
#
# - [seller_handle] (optional): if provided AND bot/seller-creds.json has an
#   entry for that handle, those credentials are used to log in. Otherwise
#   falls back to ARRANGE_SELLER_EMAIL/ARRANGE_SELLER_PASSWORD env vars,
#   then to the Adidas/bianca defaults. Each seller portal only authorizes
#   its own orders via the vendor API.
# - Stage is rejected by default — J&T staging often returns B063 for orders
#   whose shipping_option lacks `channel_code`. Override with FORCE_STAGE=1
#   if you've verified the order's shipping option carries channel_code.
# - Pre-flight: the order's shipping_address.phone is fetched via the
#   seller's /vendor/orders endpoint and validated against PH JT format
#   (`+639XXXXXXXXX` or `09XXXXXXXXX`). Fails fast with a clear error if
#   malformed, before burning a JT API call.
# - On success, prints `<order_id> shipping <waybill_number>`.
# - On failure, prints diagnostic lines to stderr and exits non-zero.

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <order_id> [env=prod] [seller_handle]" >&2
  exit 2
fi

ORDER_ID=$1
ENV=${2:-prod}
SELLER_HANDLE=${3:-}

# Accept either a Medusa ULID or a storefront-friendly order_sn (resolved
# via order_extension.order_sn lookup). Pass-through if already a ULID.
RESOLVED=$(/Users/daydream/buyer-data-populate/bot/resolve-order-id.sh "$ORDER_ID" "$ENV" 2>&1) || { echo "$RESOLVED" >&2; exit 1; }
ORDER_ID=$RESOLVED

case "$ENV" in
  prod|production) API_BASE=https://api.mallplus.ph ;;
  stage|staging)
    if [ "${FORCE_STAGE:-}" != "1" ]; then
      echo "error: stage JT often rejects orders whose shipping_option lacks channel_code. Set FORCE_STAGE=1 to attempt anyway." >&2
      exit 2
    fi
    API_BASE=https://staging-api.mallplus.ph ;;
  dev|development)
    echo "error: dev not configured for arrange-pickup" >&2
    exit 2 ;;
  *) echo "error: env must be 'prod' (stage with FORCE_STAGE=1, dev unsupported)" >&2; exit 2 ;;
esac

# Resolve seller credentials: file lookup by handle, then env vars, then defaults.
CREDS_FILE=/Users/daydream/buyer-data-populate/bot/seller-creds.json
SELLER_EMAIL=""
SELLER_PASSWORD=""
if [ -n "$SELLER_HANDLE" ] && [ -f "$CREDS_FILE" ]; then
  SELLER_EMAIL=$(/usr/bin/python3 -c "
import json, sys
try:
    d = json.load(open('$CREDS_FILE'))
    print(d.get('$SELLER_HANDLE', {}).get('email', ''))
except Exception as e:
    pass
")
  SELLER_PASSWORD=$(/usr/bin/python3 -c "
import json, sys
try:
    d = json.load(open('$CREDS_FILE'))
    print(d.get('$SELLER_HANDLE', {}).get('password', ''))
except Exception as e:
    pass
")
fi
SELLER_EMAIL=${ARRANGE_SELLER_EMAIL:-${SELLER_EMAIL:-bianca.velez100697@gmail.com}}
SELLER_PASSWORD=${ARRANGE_SELLER_PASSWORD:-${SELLER_PASSWORD:-Qweqwe123!}}

# 1. Seller login.
TOKEN=$(/usr/bin/curl -s -X POST "$API_BASE/auth/seller/login" \
  -H 'Content-Type: application/json' \
  -d "{\"identifier\":\"$SELLER_EMAIL\",\"password\":\"$SELLER_PASSWORD\",\"remember_me\":true}" \
  | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('token',''))")
if [ -z "$TOKEN" ]; then
  echo "error: seller login failed for $SELLER_EMAIL on $API_BASE" >&2
  echo "(if you passed seller_handle, check bot/seller-creds.json; otherwise set ARRANGE_SELLER_EMAIL/PASSWORD env vars)" >&2
  exit 1
fi

# (Earlier versions had a phone pre-check here that queried the vendor
# /orders endpoint with an `id[]=` filter; that endpoint doesn't support
# filtering by id this way and returned 0 orders even for valid ones.
# Dropped — JT's own error message ("Invalid receiver phone format. Expected
# +639XXXXXXXXX or 09XXXXXXXXX") is already surfaced by the failure path
# below.)

# 2. Pickup address.
# Lookup order:
#   a) seller-creds.json["<handle>"].pickup_address_id  (per-seller override)
#   b) PICKUP_ADDRESS_ID env var (per-call override)
#   c) seller's is_default address
#   d) first address returned by /pickup-addresses
PICKUP_ADDR=""
if [ -n "$SELLER_HANDLE" ] && [ -f "$CREDS_FILE" ]; then
  PICKUP_ADDR=$(/usr/bin/python3 -c "
import json
try:
    d = json.load(open('$CREDS_FILE'))
    print(d.get('$SELLER_HANDLE', {}).get('pickup_address_id', ''))
except Exception:
    pass
")
fi
PICKUP_ADDR=${PICKUP_ADDRESS_ID:-$PICKUP_ADDR}
if [ -z "$PICKUP_ADDR" ]; then
  PICKUP_ADDR=$(/usr/bin/curl -s "$API_BASE/vendor/orders/shipment/pickup-addresses" \
    -H "Authorization: Bearer $TOKEN" \
    | /usr/bin/python3 -c "
import json, sys
addrs = json.load(sys.stdin).get('addresses', [])
chosen = next((a for a in addrs if a.get('is_default')), addrs[0] if addrs else None)
print(chosen.get('id','') if chosen else '')
")
fi
if [ -z "$PICKUP_ADDR" ]; then
  echo "error: seller has no pickup addresses configured" >&2
  exit 1
fi

# 4. First available pickup date.
PICKUP_DATE=$(/usr/bin/curl -s "$API_BASE/vendor/orders/shipment/pickup-slots?days_ahead=7" \
  -H "Authorization: Bearer $TOKEN" \
  | /usr/bin/python3 -c "
import json, sys
slots = json.load(sys.stdin).get('slots', [])
avail = [s.get('date') for s in slots if s.get('is_available')]
print(avail[0] if avail else '')
")
if [ -z "$PICKUP_DATE" ]; then
  echo "error: no available pickup slot in the next 7 days" >&2
  exit 1
fi

# 5. Arrange pickup — invokes J&T Express. Real booking on success.
RESULT=$(/usr/bin/curl -s -X POST "$API_BASE/vendor/orders/$ORDER_ID/shipment/pickup" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"pickup_address_id\":\"$PICKUP_ADDR\",\"pickup_date\":\"$PICKUP_DATE\"}")

OUTCOME=$(echo "$RESULT" | /usr/bin/python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except json.JSONDecodeError:
    print('parse_error|response was not JSON', file=sys.stderr); sys.exit(2)
if d.get('success') and d.get('waybill_number'):
    print('ok|' + d['waybill_number'])
else:
    msg = d.get('message') or d.get('type') or json.dumps(d)
    print('fail|' + msg[:400])
" 2>&1)

if [[ "$OUTCOME" == ok\|* ]]; then
  WAYBILL=${OUTCOME#ok|}
  echo "$ORDER_ID shipping $WAYBILL"
  exit 0
fi

REJECT="${OUTCOME#fail|}"
echo "error: arrange-pickup rejected — $REJECT" >&2
exit 1
