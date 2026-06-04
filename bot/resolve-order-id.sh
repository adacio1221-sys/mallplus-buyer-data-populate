#!/bin/bash
# resolve-order-id.sh — turn an `order_sn` (storefront-friendly ID like
# `260603H8GTPWY4`) into a Medusa `order_<ULID>`. Pass-through if input
# already looks like a ULID.
#
# Usage: resolve-order-id.sh <id_or_sn> <env>
#
# Prints the resolved `order_<ULID>` on stdout. Exits non-zero with a
# stderr message if the input doesn't resolve to any order.
#
# Used by the helper scripts (advance.sh, arrange-pickup.sh, etc.) so
# users can paste whichever ID form they have in front of them.

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <id_or_sn> <env=stage|dev|prod>" >&2
  exit 2
fi

IN=$1
ENV=$2

# Pass-through if already a Medusa ULID.
if [[ "$IN" =~ ^order_[A-Z0-9]+$ ]]; then
  echo "$IN"
  exit 0
fi

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
if [ -z "$TOKEN" ]; then
  echo "error: admin login failed while resolving order_sn '$IN'" >&2
  exit 1
fi

QUERY="SELECT order_id FROM order_extension WHERE order_sn = '$IN' LIMIT 1"
BODY=$(/usr/bin/python3 -c "import json,sys; print(json.dumps({'query': sys.argv[1]}))" "$QUERY")
RESOLVED=$(/usr/bin/curl -s -X POST "$API_BASE/admin/script-console/sql/run" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-script-console-password: $SC_PASSWORD" \
  -d "$BODY" \
  | /usr/bin/python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    rows = d.get('rows', [])
    print(rows[0].get('order_id', '') if rows else '')
except Exception:
    print('')")

if [ -z "$RESOLVED" ]; then
  echo "error: could not resolve '$IN' to an order_id (not a ULID, no matching order_sn)" >&2
  exit 1
fi

echo "$RESOLVED"
