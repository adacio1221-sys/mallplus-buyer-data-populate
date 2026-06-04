#!/bin/bash
# unavailable-item.sh — make a past order's line item show as "unavailable"
# in the buy-again flow. Used to QA the storefront's skipped-items UI.
#
# Usage: unavailable-item.sh <order_id> [revert] [env=prod]
#
# Mechanism: soft-deletes the product_variant linked to the order's first
# line item. The buy-again endpoint (POST /store/orders/{id}/buy-again)
# then categorizes the item under skipped_items with reason "Variant not
# found (may be discontinued)". The order itself is unchanged — only the
# variant's deleted_at column is touched.
#
# Pass `revert` as 2nd arg to restore (set deleted_at = NULL).
#
# Why variant-soft-delete vs product.status=draft: a variant delete only
# breaks the one SKU. Flipping product status would also hide the entire
# PDP from the storefront, which is more disruptive when the seller is
# still live.

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <order_id> [revert] [env=stage|dev|prod]" >&2
  exit 2
fi

ORDER_ID=$1
MODE=set
ENV=prod
for arg in "${@:2}"; do
  case "$arg" in
    revert) MODE=revert ;;
    stage|staging|dev|development|prod|production) ENV=$arg ;;
    *) echo "error: unknown arg '$arg' (expected 'revert' or env)" >&2; exit 2 ;;
  esac
done

# Accept either a Medusa ULID or a storefront order_sn.
RESOLVED=$(/Users/daydream/buyer-data-populate/bot/resolve-order-id.sh "$ORDER_ID" "$ENV" 2>&1) || { echo "$RESOLVED" >&2; exit 1; }
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
esac

TOKEN=$(/usr/bin/curl -s -X POST "$API_BASE/auth/user/emailpass" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" \
  | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))")
if [ -z "$TOKEN" ]; then
  echo "error: admin login failed for $ADMIN_EMAIL on $API_BASE" >&2
  exit 1
fi

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

# Step 0: state check. Buy-again only surfaces in the storefront for
# completed or canceled orders, so refuse to mark a variant unavailable
# off an in-flight order — there's no UI affordance to test against
# until the order reaches a terminal state. Revert is permissive (we may
# need to restore a variant regardless of which order originally triggered).
if [ "$MODE" != "revert" ]; then
  STATE=$(sql_run "SELECT status, canceled_at FROM \"order\" WHERE id = '$ORDER_ID'")
  ORDER_STATUS=$(echo "$STATE" | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('status', '') if rows else '')
except Exception:
    print('')
")
  CANCELED_AT=$(echo "$STATE" | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('canceled_at') or '' if rows else '')
except Exception:
    print('')
")
  if [ -z "$ORDER_STATUS" ]; then
    echo "error: order $ORDER_ID not found" >&2
    exit 1
  fi
  if [ "$ORDER_STATUS" != "completed" ] && [ -z "$CANCELED_AT" ]; then
    echo "error: order $ORDER_ID is $ORDER_STATUS/not-canceled — buy-again only surfaces for completed or canceled orders" >&2
    exit 1
  fi
fi

# Step 1: find the order's first line item -> variant_id, product_id, title.
LOOKUP=$(sql_run "SELECT oi.variant_id, oi.product_id, oi.title FROM \"order\" o JOIN order_item oio ON oio.order_id = o.id JOIN order_line_item oi ON oi.id = oio.item_id WHERE o.id = '$ORDER_ID' ORDER BY oio.created_at ASC LIMIT 1")
VARIANT_ID=$(echo "$LOOKUP" | /usr/bin/python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    rows = d.get('rows', [])
    print(rows[0].get('variant_id', '') if rows else '')
except Exception:
    print('')
")
PRODUCT_ID=$(echo "$LOOKUP" | /usr/bin/python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    rows = d.get('rows', [])
    print(rows[0].get('product_id', '') if rows else '')
except Exception:
    print('')
")
TITLE=$(echo "$LOOKUP" | /usr/bin/python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    rows = d.get('rows', [])
    print(rows[0].get('title', '') if rows else '')
except Exception:
    print('')
")

if [ -z "$VARIANT_ID" ]; then
  echo "error: could not resolve variant_id for $ORDER_ID first line item" >&2
  echo "$LOOKUP" | head -c 400 >&2
  exit 1
fi

# Step 2: flip the variant's deleted_at column.
if [ "$MODE" = "revert" ]; then
  RES=$(sql_run "UPDATE product_variant SET deleted_at = NULL WHERE id = '$VARIANT_ID'")
  AFFECTED=$(echo "$RES" | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('affectedRows', 0))" 2>/dev/null || echo 0)
  if [ "$AFFECTED" = "0" ]; then
    echo "error: revert UPDATE affected 0 rows (variant $VARIANT_ID may not exist)" >&2
    echo "$RES" | head -c 400 >&2
    exit 1
  fi
  echo "$ORDER_ID buy-again-restored variant=$VARIANT_ID product=$PRODUCT_ID title=\"$TITLE\""
else
  RES=$(sql_run "UPDATE product_variant SET deleted_at = NOW() WHERE id = '$VARIANT_ID' AND deleted_at IS NULL")
  AFFECTED=$(echo "$RES" | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('affectedRows', 0))" 2>/dev/null || echo 0)
  if [ "$AFFECTED" = "0" ]; then
    echo "note: variant $VARIANT_ID already had deleted_at set (or doesn't exist)" >&2
    echo "$RES" | head -c 400 >&2
  fi
  echo "$ORDER_ID buy-again-unavailable variant=$VARIANT_ID product=$PRODUCT_ID title=\"$TITLE\""
fi
