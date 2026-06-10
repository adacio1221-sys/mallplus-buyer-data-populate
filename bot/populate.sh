#!/bin/bash
# populate.sh — invoke the Medusa create-order-by-status script over SSH
# and print the resulting order IDs.
#
# Usage: populate.sh <email> <seller_handle_or_id> <status> <count> [env] [product_or_variant_id]
#
# - <seller_handle_or_id> accepts a Mercur seller handle (resolved via psql
#   on the target box) or a raw `sel_…` ID (used as-is).
# - <status> must be one of: unpaid | authorized | to_ship | shipping |
#   delivered | completed | canceled | refunded.
# - [env] is one of: stage (default) | dev | prod.
# - [product_or_variant_id] — if it starts with `prod_`, the script uses
#   PRODUCT_IDS; if it starts with `variant_`, VARIANT_IDS. Dev's script
#   doesn't support manual selection yet.
# - On success, prints lines `order_<ULID> <status>` for each created order.
# - On failure, prints diagnostic lines to stderr and exits non-zero.

set -euo pipefail

CUSTOMER_PASSWORD=admin123

if [ $# -lt 4 ] || [ $# -gt 6 ]; then
  echo "usage: $0 <email> <seller_handle_or_id> <status> <count> [env=stage|dev|prod] [product_or_variant_id]" >&2
  exit 2
fi

EMAIL=$1
SELLER=$2
STATUS=$3
COUNT=$4
ENV=${5:-stage}
PRODUCT_ARG=${6:-}

# Dispatch mode:
#   ssh   — outer (and optional inner) SSH into the host, run `npx medusa exec` against /Data/sbin/medusa-api
#   admin — POST to /admin/script-console/scripts/run with the compiled .js (used when the host's medusa source is gone, e.g. Dockerized stage)
DISPATCH=ssh
SSH_OUTER=""
SSH_INNER=""
BACKEND_DIR=/Data/sbin/medusa-api
API_BASE=""
case "$ENV" in
  stage|staging)
    # Stage Docker'ized — host doesn't have /Data/sbin/medusa-api anymore. Route through script-console.
    DISPATCH=admin
    API_BASE=${MEDUSA_API_BASE_STAGE:-https://staging-api.mallplus.ph}
    ADMIN_EMAIL=${MEDUSA_ADMIN_EMAIL_STAGE:-admin@medusa-test.com}
    ADMIN_PASSWORD=${MEDUSA_ADMIN_PASSWORD_STAGE:-supersecret}
    SC_PASSWORD=${MEDUSA_SCRIPT_CONSOLE_PASSWORD_STAGE:-123} ;;
  dev|development)
    SSH_OUTER=arvind@43.98.253.168 ;;
  prod|production)
    SSH_OUTER=arvind@47.84.101.211
    SSH_INNER=arvind@10.0.0.9 ;;
  *) echo "error: env must be 'stage' | 'dev' | 'prod' (got '$ENV')" >&2; exit 2 ;;
esac

case "$STATUS" in
  unpaid|authorized|to_ship|shipping|delivered|completed|canceled|refunded) ;;
  *) echo "error: invalid status '$STATUS' (allowed: unpaid|authorized|to_ship|shipping|delivered|completed|canceled|refunded)" >&2; exit 2 ;;
esac
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
  echo "error: count must be a positive integer (got '$COUNT')" >&2
  exit 2
fi
if ! [[ "$EMAIL" == *@*.* ]]; then
  echo "error: '$EMAIL' doesn't look like an email" >&2
  exit 2
fi

# ssh_run sends $cmd to bash on the target box. For envs with a jumphost
# (prod), an outer ssh into the admin box runs `ssh inner bash -s`,
# forwarding stdin all the way through. Stdin transport avoids nested
# quoting hell vs cramming the command into the outer ssh argv.
ssh_run() {
  local cmd=$1
  if [ -n "$SSH_INNER" ]; then
    /usr/bin/ssh -o BatchMode=yes "$SSH_OUTER" "ssh -o BatchMode=yes $SSH_INNER bash -s" <<< "$cmd"
  else
    /usr/bin/ssh -o BatchMode=yes "$SSH_OUTER" "bash -s" <<< "$cmd"
  fi
}

# admin-side helpers (only used when DISPATCH=admin)
admin_token() {
  /usr/bin/curl -s -X POST "$API_BASE/auth/user/emailpass" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" \
    | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))"
}
admin_sql() {
  local token=$1 query=$2
  local body
  body=$(/usr/bin/python3 -c "import json,sys; print(json.dumps({'query': sys.argv[1]}))" "$query")
  /usr/bin/curl -s -X POST "$API_BASE/admin/script-console/sql/run" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $token" \
    -H "x-script-console-password: $SC_PASSWORD" \
    -d "$body"
}
admin_run_script() {
  local token=$1 script=$2 args_json=$3
  local body
  body=$(/usr/bin/python3 -c "
import json, sys
print(json.dumps({'script': sys.argv[1], 'args': json.loads(sys.argv[2])}))
" "$script" "$args_json")
  /usr/bin/curl -s -X POST "$API_BASE/admin/script-console/scripts/run" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $token" \
    -H "x-script-console-password: $SC_PASSWORD" \
    -d "$body"
}

# Resolve seller handle to ID if needed. For SSH dispatch (dev/prod) we
# parse DATABASE_URL on the target host and psql directly. For admin
# dispatch (stage), we hit the script-console SQL endpoint.
if [[ "$SELLER" == sel_* ]]; then
  SELLER_ID=$SELLER
elif [ "$DISPATCH" = "admin" ]; then
  ADMIN_TOKEN=$(admin_token)
  if [ -z "$ADMIN_TOKEN" ]; then
    echo "error: admin login failed for $ENV ($ADMIN_EMAIL @ $API_BASE)" >&2
    exit 1
  fi
  SELLER_ID=$(admin_sql "$ADMIN_TOKEN" "SELECT id FROM seller WHERE handle = '$SELLER' AND deleted_at IS NULL LIMIT 1" \
    | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('id', '') if rows else '')
except Exception:
    print('')")
  if [ -z "$SELLER_ID" ]; then
    echo "error: seller lookup failed for handle '$SELLER' on $ENV (no row in seller table)" >&2
    exit 1
  fi
else
  SELLER_LOOKUP="
PASS=\$(grep ^DATABASE_URL $BACKEND_DIR/.env | sed -E 's|.*://[^:]+:([^@]+)@.*|\\1|')
HOST=\$(grep ^DATABASE_URL $BACKEND_DIR/.env | sed -E 's|.*@([^:]+):.*|\\1|')
DB=\$(grep ^DATABASE_URL $BACKEND_DIR/.env | sed -E 's|.*/([^/?]+)\$|\\1|')
USER=\$(grep ^DATABASE_URL $BACKEND_DIR/.env | sed -E 's|.*://([^:]+):.*|\\1|')
PGPASSWORD=\"\$PASS\" psql -h \"\$HOST\" -U \"\$USER\" -d \"\$DB\" -tA -c \"SELECT id FROM seller WHERE handle = '$SELLER' AND deleted_at IS NULL LIMIT 1;\"
"
  # Retry the seller lookup once on transient SSH failure. The lookup is
  # wrapped in `|| true` so `set -e` doesn't kill the script before we can
  # show a useful error. Stderr is captured (not /dev/null'd) so real
  # auth or psql errors surface.
  for attempt in 1 2; do
    LOOKUP_ERR=$(mktemp)
    SELLER_ID=$(ssh_run "$SELLER_LOOKUP" 2>"$LOOKUP_ERR" | tr -d '[:space:]' || true)
    if [ -n "$SELLER_ID" ]; then
      rm -f "$LOOKUP_ERR"
      break
    fi
    if [ "$attempt" -eq 2 ]; then
      {
        echo "error: seller lookup failed for handle '$SELLER' on $ENV after 2 attempts"
        echo "(if the handle is valid, this is usually a transient SSH/psql blip)"
        echo "--- last ssh stderr ---"
        cat "$LOOKUP_ERR" 2>/dev/null | head -10
      } >&2
      rm -f "$LOOKUP_ERR"
      exit 1
    fi
    rm -f "$LOOKUP_ERR"
    sleep 1
  done
fi

# Optional product/variant pin (staging + prod scripts support it; dev does not).
EXTRA_ARGS=""
if [ -n "$PRODUCT_ARG" ]; then
  case "$PRODUCT_ARG" in
    prod_*) EXTRA_ARGS="PRODUCT_IDS=$PRODUCT_ARG" ;;
    variant_*) EXTRA_ARGS="VARIANT_IDS=$PRODUCT_ARG" ;;
    *) echo "error: '$PRODUCT_ARG' must start with 'prod_' or 'variant_'" >&2; exit 2 ;;
  esac
fi

# Run the Medusa populator. For SSH dispatch we use the .ts source; for
# admin dispatch we point at the compiled .js (the only thing inside the
# Docker image's published path).
#
# `|| true` keeps `set -e` from killing the script when the Medusa CLI
# exits non-zero (which it does on script throw + rollback) — we still
# have the full output in RESULT and run our own failure-marker detection
# below.
if [ "$DISPATCH" = "admin" ]; then
  # Build the args array (each arg is a "KEY=VALUE" string).
  ARGS_PY=$(/usr/bin/python3 -c "
import json
args = ['CUSTOMER_EMAIL=$EMAIL','CUSTOMER_PASSWORD=$CUSTOMER_PASSWORD','SELLER_ID=$SELLER_ID','SEED_ORDER_COUNT=$COUNT','SEED_ORDER_STATUS=$STATUS']
extra = '$EXTRA_ARGS'.strip()
if extra:
  args.append(extra)
print(json.dumps(args))")
  [ -z "${ADMIN_TOKEN:-}" ] && ADMIN_TOKEN=$(admin_token)
  RAW=$(admin_run_script "$ADMIN_TOKEN" "orders/create-order-by-status.js" "$ARGS_PY")
  RESULT=$(echo "$RAW" | /usr/bin/python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('stdout','') + d.get('stderr',''))
except Exception:
    print(sys.stdin.read())
")
else
  INNER_CMD="cd $BACKEND_DIR && npx medusa exec src/scripts/orders/create-order-by-status.ts CUSTOMER_EMAIL=$EMAIL CUSTOMER_PASSWORD=$CUSTOMER_PASSWORD SELLER_ID=$SELLER_ID SEED_ORDER_COUNT=$COUNT SEED_ORDER_STATUS=$STATUS $EXTRA_ARGS 2>&1"
  RESULT=$(ssh_run "$INNER_CMD" || true)
fi

# Check for failure markers FIRST so we don't print order IDs from
# orders that the script subsequently rolled back. We use explicit
# script-emitted markers — NOT a generic `"level":"error"` match —
# because the script logs non-fatal errors (e.g. notification subscriber
# transients during first-time customer creation) at error level which
# previously caused false-positive exits.
FAILURE_MARKERS='0 ORDER CREATED|Error running script|ROLLING BACK|No available inventory'
if echo "$RESULT" | grep -qE "$FAILURE_MARKERS"; then
  {
    echo "error: medusa script reported failure for status='$STATUS' seller=$SELLER_ID"
    echo "$RESULT" | grep -E "$FAILURE_MARKERS|⚠️|Stopping" | head -5
  } >&2
  exit 1
fi

# Extract successful order IDs from the script's success block.
# `|| true` guards against pipefail when grep finds no matches.
ORDERS=$(echo "$RESULT" | grep -oE 'Order: order_[A-Z0-9]+' | awk '{print $NF}' | sort -u || true)
if [ -z "$ORDERS" ]; then
  echo "error: medusa script returned no order IDs for status='$STATUS' (no rollback marker either; check full output)" >&2
  echo "$RESULT" | tail -20 >&2
  exit 1
fi
while IFS= read -r oid; do
  echo "$oid $STATUS"
done <<< "$ORDERS"

# Post-create: propagate the customer's address metadata onto each
# order_address so JT arrange-pickup sees `metadata.barangay` (the resolved
# name string). Storefront-originated orders get this via the buyer-flow
# fix; populate.sh-seeded orders bypass that path and end up with
# metadata=null. Calling the helper here closes the gap.
#
# Best-effort: failures are logged to stderr but don't fail the populate.
# All envs benefit (prod populate-seeded orders have the same gap).
if [ -x /Users/daydream/buyer-data-populate/bot/propagate-address-metadata.sh ]; then
  while IFS= read -r oid; do
    /Users/daydream/buyer-data-populate/bot/propagate-address-metadata.sh "$oid" "$ENV" >/dev/null 2>&1 \
      || echo "warning: address metadata propagation failed for $oid (orders may need manual fix-address before arrange-pickup)" >&2
  done <<< "$ORDERS"
fi

# Post-create: swap the auto-fallback shipping option for the J&T Express
# option (channel_code=JNT-EXP-FWD) when one exists for the same shipping
# profile. The populator script picks shipping options by ULID-order,
# which means it picks the oldest auto-created `manual-fulfillment`
# fallback — that option has no channel_code so JT routing later fails
# with B063. A real buyer would pick "J&T Express" from the storefront
# picker. Best-effort: log + continue on failure (some sellers may not
# have a JT option configured yet).
if [ -x /Users/daydream/buyer-data-populate/bot/swap-shipping-jt.sh ]; then
  while IFS= read -r oid; do
    /Users/daydream/buyer-data-populate/bot/swap-shipping-jt.sh "$oid" "$ENV" >/dev/null 2>&1 \
      || echo "warning: shipping-option swap failed for $oid (order may ship via manual-fulfillment fallback instead of JT)" >&2
  done <<< "$ORDERS"
fi
