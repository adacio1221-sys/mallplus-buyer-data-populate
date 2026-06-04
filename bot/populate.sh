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

case "$ENV" in
  stage|staging)
    SSH_OUTER=arvind@43.98.207.70
    SSH_INNER=""
    BACKEND_DIR=/Data/sbin/medusa-api ;;
  dev|development)
    SSH_OUTER=arvind@43.98.253.168
    SSH_INNER=""
    BACKEND_DIR=/Data/sbin/medusa-api ;;
  prod|production)
    SSH_OUTER=arvind@47.84.101.211
    SSH_INNER=arvind@10.0.0.9
    BACKEND_DIR=/Data/sbin/medusa-api ;;
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

# Resolve seller handle to ID if needed. The .env's DATABASE_URL is parsed
# in-shell so the same code path works for localhost (stage/dev) and RDS
# (prod).
if [[ "$SELLER" == sel_* ]]; then
  SELLER_ID=$SELLER
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

# Run the Medusa populator. `|| true` keeps `set -e` from killing the
# script when the Medusa CLI exits non-zero (which it does on script
# throw + rollback) — we still have the full output in RESULT and run
# our own failure-marker detection below.
INNER_CMD="cd $BACKEND_DIR && npx medusa exec src/scripts/orders/create-order-by-status.ts CUSTOMER_EMAIL=$EMAIL CUSTOMER_PASSWORD=$CUSTOMER_PASSWORD SELLER_ID=$SELLER_ID SEED_ORDER_COUNT=$COUNT SEED_ORDER_STATUS=$STATUS $EXTRA_ARGS 2>&1"
RESULT=$(ssh_run "$INNER_CMD" || true)

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
