#!/bin/bash
# propagate-address-metadata.sh — copy customer_address.metadata onto an
# order's order_address.metadata, with the resolved barangay name string.
#
# Usage: propagate-address-metadata.sh <order_id_or_sn> [env=prod]
#
# Background: the storefront's address-write flow enriches order_address.metadata
# with `barangay` (resolved name string) + `customer_address_id` + `address_name`
# in addition to the buyer's saved barangayId / cityId / provinceId / regionId.
# JT integration reads `metadata.barangay ?? address_2` for the recipient district.
#
# populate.sh-seeded orders skip the storefront flow → their order_address.metadata
# is NULL → JT arrange-pickup B063s on missing barangay. This helper patches the
# missing metadata after order creation by:
#   1. Reading the order's shipping_address_id + customer_id
#   2. Loading the customer's default shipping address metadata (canonical IDs)
#   3. Resolving metadata.barangayId → ph_barangay.name
#   4. UPDATEing order_address.metadata with the full shape the storefront writes
#
# Idempotent: if order_address.metadata already has `barangay`, no-op.
#
# On success: `<order_id> address-metadata-propagated barangay=<name>`.
# On failure: prints diagnostic line to stderr and exits non-zero.

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

# 1. Resolve shipping_address_id + customer_id from the order
LOOKUP=$(sql_run "SELECT o.shipping_address_id, o.customer_id, oa.metadata FROM \"order\" o JOIN order_address oa ON oa.id = o.shipping_address_id WHERE o.id = '$ORDER_ID'")
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
EXISTING_HAS_BARANGAY=$(echo "$LOOKUP" | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    md = rows[0].get('metadata') if rows else None
    print('yes' if md and 'barangay' in md and md.get('barangay') else '')
except Exception:
    print('')")
if [ -z "$ADDR_ID" ] || [ -z "$CUST_ID" ]; then
  echo "error: could not resolve shipping_address_id / customer_id for $ORDER_ID" >&2
  exit 1
fi
# Idempotent: skip if already populated
if [ "$EXISTING_HAS_BARANGAY" = "yes" ]; then
  echo "$ORDER_ID address-metadata-already-set"
  exit 0
fi

# 2. Customer's default shipping address — pull metadata + the customer_address.id itself
CUST_META=$(sql_run "SELECT id, metadata FROM customer_address WHERE customer_id = '$CUST_ID' AND is_default_shipping = true AND deleted_at IS NULL LIMIT 1")
CUST_ADDR_ID=$(echo "$CUST_META" | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('id', '') if rows else '')
except Exception:
    print('')")
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

# 3. Resolve barangay name
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

# 4. Build the new metadata jsonb mirroring the storefront's shape
NEW_META=$(/usr/bin/python3 -c "
import json, sys
src = json.loads(sys.argv[1])
out = {
  'cityId': src.get('cityId',''),
  'barangay': sys.argv[2],
  'regionId': src.get('regionId',''),
  'barangayId': src.get('barangayId',''),
  'provinceId': src.get('provinceId',''),
  'address_name': 'Home',
  'customer_address_id': sys.argv[3]
}
print(json.dumps(out))" "$META_JSON" "$BRGY_NAME" "$CUST_ADDR_ID")
META_ESCAPED=$(echo "$NEW_META" | /usr/bin/sed "s/'/''/g")

# UPDATE the order_address — also fix address_2 to the barangay name in case JT prefers it
BRGY_ESCAPED=$(echo "$BRGY_NAME" | /usr/bin/sed "s/'/''/g")
RES=$(sql_run "UPDATE order_address SET metadata = '$META_ESCAPED'::jsonb, address_2 = COALESCE(NULLIF(address_2, ''), '$BRGY_ESCAPED') WHERE id = '$ADDR_ID'")
AFFECTED=$(echo "$RES" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('affectedRows', 0))" 2>/dev/null || echo 0)
if [ "$AFFECTED" = "0" ]; then
  echo "error: order_address UPDATE affected 0 rows" >&2
  exit 1
fi

echo "$ORDER_ID address-metadata-propagated barangay=\"$BRGY_NAME\""
