#!/bin/bash
# advance.sh — advance an existing order to a target status via the Medusa
# admin script-console (orders/update-order-status-qa.js).
#
# Usage: advance.sh <order_id> <target_status> [env=stage|dev|prod]
#
# - <target_status> ∈ unpaid | to_ship | shipping | delivered | completed | canceled | refunded.
# - This calls createOrderFulfillmentWorkflow when needed, so transitions that
#   require fulfillment (e.g. to_ship → shipping) will still fail on sellers
#   whose inventory isn't at their stock_location (Adidas Official on stage,
#   Adidas PH on prod). Use this primarily for fulfillment-clean transitions
#   like shipping → completed once a human has done the seller-portal step.
# - On success, prints `order_<id> <status>` for the order.
# - On failure, prints diagnostic lines to stderr and exits non-zero.

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <order_id> <target_status> [env=stage|dev|prod]" >&2
  exit 2
fi

ORDER_ID=$1
TARGET=$2
ENV=${3:-stage}

# Accept either a Medusa ULID or a storefront-friendly order_sn.
RESOLVED=$(/Users/daydream/buyer-data-populate/bot/resolve-order-id.sh "$ORDER_ID" "$ENV" 2>&1) || { echo "$RESOLVED" >&2; exit 1; }
ORDER_ID=$RESOLVED

case "$TARGET" in
  unpaid|to_ship|shipping|delivered|completed|canceled|refunded) ;;
  *) echo "error: invalid status '$TARGET'" >&2; exit 2 ;;
esac
if ! [[ "$ORDER_ID" =~ ^order_[A-Z0-9]+$ ]]; then
  echo "error: '$ORDER_ID' doesn't look like a Medusa order id (order_…)" >&2
  exit 2
fi

# Per-env config. Admin creds default to the staging "test admin"; override
# with env vars MEDUSA_ADMIN_EMAIL_<ENV> / MEDUSA_ADMIN_PASSWORD_<ENV> /
# MEDUSA_SCRIPT_CONSOLE_PASSWORD_<ENV> if a deployment differs.
case "$ENV" in
  stage|staging)
    API_BASE=https://staging-api.mallplus.ph
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

# Admin login.
TOKEN=$(/usr/bin/curl -s -X POST "$API_BASE/auth/user/emailpass" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" \
  | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('token',''))")
if [ -z "$TOKEN" ]; then
  echo "error: admin login failed for $ADMIN_EMAIL on $API_BASE" >&2
  exit 1
fi

# Script-console auth (separate password gate).
AUTHZ=$(/usr/bin/curl -s -X POST "$API_BASE/admin/script-console/auth" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"password\":\"$SC_PASSWORD\"}" \
  | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d.get('authorized') else '')")
if [ "$AUTHZ" != "yes" ]; then
  echo "error: script-console auth rejected (password may be wrong)" >&2
  exit 1
fi

# Run the QA status-update script.
BODY=$(/usr/bin/python3 -c "
import json
print(json.dumps({
  'script': 'orders/update-order-status-qa.ts',
  'args': ['ORDER_ID=$ORDER_ID', 'STATUS=$TARGET', 'FORCE=true']
}))")
RESULT=$(/usr/bin/curl -s -X POST "$API_BASE/admin/script-console/scripts/run" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-script-console-password: $SC_PASSWORD" \
  -d "$BODY")

# The endpoint returns the script's stdout/stderr stream as JSON. Parse it
# and look for the success/failure markers used by update-order-status-qa.js.
SUCCESS=$(echo "$RESULT" | /usr/bin/python3 -c "
import json, sys, re
try:
    d = json.load(sys.stdin)
except json.JSONDecodeError:
    print('error: response was not JSON', file=sys.stderr); sys.exit(1)
# Try common shapes for stdout/logs.
buf = ''
for k in ('output', 'logs', 'stdout', 'result', 'data'):
    v = d.get(k)
    if isinstance(v, str): buf += v
    elif isinstance(v, list): buf += '\n'.join(str(x) for x in v)
# Some implementations return whole d as the buffer.
if not buf:
    buf = json.dumps(d)
if re.search(r'UPDATED TO [A-Z_]+ SUCCESSFULLY', buf):
    print('ok')
else:
    # Surface failure lines to stderr.
    import sys as _s
    fail_lines = [l for l in buf.splitlines() if re.search(r'level\"\\s*:\\s*\"error\"|❌|Error', l)]
    for l in fail_lines[:5]:
        print(l, file=_s.stderr)
    print('fail')
" 2>&1)

case "$SUCCESS" in
  *ok*) echo "$ORDER_ID $TARGET"; exit 0 ;;
  *)
    echo "error: script-console reported failure for $ORDER_ID -> $TARGET" >&2
    echo "$SUCCESS" | head -5 >&2
    exit 1 ;;
esac
