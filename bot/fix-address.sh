#!/bin/bash
# fix-address.sh — patch an order's shipping_address so JT accepts it.
#
# Usage: fix-address.sh <order_id_or_sn> [env=prod]
#
# Background: the JT integration reads `order_address.address_2` as the
# recipient barangay name. The buyer-flow copies customer_address into
# order_address but drops the metadata.barangayId reference, leaving
# `address_2` populated with whatever the buyer typed (often a landmark
# or apartment label like "UNCLE JOHN"). JT rejects with `Recipient
# barangay "<value>" is not a valid district for <CITY>, <PROVINCE>`.
#
# This helper:
#   1. Resolves the order's shipping_address.
#   2. Reads metadata.barangayId from the CUSTOMER's default shipping
#      address (the canonical record that has it).
#   3. Looks up the real barangay name via `ph_barangay.id → name`.
#   4. UPDATEs order_address.address_2 to that name + writes the same
#      metadata.barangayId/cityId/provinceId/regionId onto the order_address
#      so downstream readers see consistent data.
#
# Exits non-zero with a clear message when no fix is available (no
# customer address metadata, no barangay match, etc).
#
# On success: `<order_id> address-fixed barangay=<name>`.

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

# Pull order shipping_address_id + customer_id.
LOOKUP=$(sql_run "SELECT o.shipping_address_id, o.customer_id FROM \"order\" o WHERE o.id = '$ORDER_ID'")
ADDR_ID=$(echo "$LOOKUP" | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('shipping_address_id', '') if rows else '')
except Exception:
    print('')")
CUST_ID=$(echo "$LOOKUP" | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('customer_id', '') if rows else '')
except Exception:
    print('')")
if [ -z "$ADDR_ID" ] || [ -z "$CUST_ID" ]; then
  echo "error: could not resolve shipping_address_id / customer_id for $ORDER_ID" >&2
  exit 1
fi

# Find customer's default shipping address metadata (the canonical record).
CUST_META=$(sql_run "SELECT metadata FROM customer_address WHERE customer_id = '$CUST_ID' AND is_default_shipping = true LIMIT 1")
META_JSON=$(echo "$CUST_META" | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    m = rows[0].get('metadata') if rows else None
    print(json.dumps(m) if m else '')
except Exception:
    print('')")
if [ -z "$META_JSON" ] || [ "$META_JSON" = "null" ]; then
  echo "error: customer $CUST_ID has no default shipping address metadata" >&2
  exit 1
fi
BARANGAY_ID=$(echo "$META_JSON" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('barangayId',''))")
if [ -z "$BARANGAY_ID" ]; then
  echo "error: customer address metadata missing barangayId" >&2
  exit 1
fi

# Resolve barangayId → name.
BRGY_NAME=$(sql_run "SELECT name FROM ph_barangay WHERE id = '$BARANGAY_ID'" | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('name', '') if rows else '')
except Exception:
    print('')")
if [ -z "$BRGY_NAME" ]; then
  echo "error: barangay $BARANGAY_ID not found in ph_barangay" >&2
  exit 1
fi

# Escape single quotes in the barangay name for the SQL string literal.
BRGY_ESCAPED=$(echo "$BRGY_NAME" | /usr/bin/sed "s/'/''/g")

# Patch order_address: set address_2 = real barangay name AND propagate
# the metadata so downstream code reads consistent IDs too.
META_ESCAPED=$(echo "$META_JSON" | /usr/bin/sed "s/'/''/g")
UPDATE_SQL="UPDATE order_address SET address_2 = '$BRGY_ESCAPED', metadata = COALESCE(metadata, '{}'::jsonb) || '$META_ESCAPED'::jsonb WHERE id = '$ADDR_ID'"
RES=$(sql_run "$UPDATE_SQL")
AFFECTED=$(echo "$RES" | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('affectedRows', 0))" 2>/dev/null || echo 0)
if [ "$AFFECTED" = "0" ]; then
  echo "error: order_address UPDATE affected 0 rows" >&2
  echo "$RES" | head -c 400 >&2
  exit 1
fi

echo "$ORDER_ID address-fixed barangay=\"$BRGY_NAME\""
