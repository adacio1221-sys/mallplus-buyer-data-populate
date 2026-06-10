#!/bin/bash
# admin-token.sh — fetch a Medusa admin token for the given env, with
# fallback to the prod superadmin (admin@example.com / supersecret) when
# the primary admin account's session is invalidated.
#
# Usage:
#   TOKEN=$(./bot/admin-token.sh <env>)
#
# Where <env> ∈ stage | dev | prod.
#
# Background: the default admin user (`admin@medusa-test.com`) gets its
# session_version bumped on prod whenever the real superadmin's password
# is rotated — so `/auth/user/emailpass` issues a token but every
# subsequent `/admin/*` call returns 401 SESSION_INVALIDATED. This helper
# probes the token against `/admin/script-console/sql/run`; on failure it
# falls back to `admin@example.com` (the real prod superadmin).
#
# Env-var overrides (per env): MEDUSA_API_BASE_<ENV>,
# MEDUSA_ADMIN_EMAIL_<ENV>, MEDUSA_ADMIN_PASSWORD_<ENV>,
# MEDUSA_SCRIPT_CONSOLE_PASSWORD_<ENV>.
#
# Prints the working token to stdout. Exits non-zero if neither account works.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <stage|dev|prod>" >&2
  exit 2
fi

ENV=$1

case "$ENV" in
  stage|staging)
    API_BASE=${MEDUSA_API_BASE_STAGE:-https://staging-api.mallplus.ph}
    PRIMARY_EMAIL=${MEDUSA_ADMIN_EMAIL_STAGE:-admin@medusa-test.com}
    PRIMARY_PASSWORD=${MEDUSA_ADMIN_PASSWORD_STAGE:-supersecret}
    SC_PASSWORD=${MEDUSA_SCRIPT_CONSOLE_PASSWORD_STAGE:-123} ;;
  dev|development)
    API_BASE=${MEDUSA_API_BASE_DEV:-https://dev-api.mallplus.ph}
    PRIMARY_EMAIL=${MEDUSA_ADMIN_EMAIL_DEV:-admin@medusa-test.com}
    PRIMARY_PASSWORD=${MEDUSA_ADMIN_PASSWORD_DEV:-supersecret}
    SC_PASSWORD=${MEDUSA_SCRIPT_CONSOLE_PASSWORD_DEV:-123} ;;
  prod|production)
    API_BASE=${MEDUSA_API_BASE_PROD:-https://api.mallplus.ph}
    PRIMARY_EMAIL=${MEDUSA_ADMIN_EMAIL_PROD:-admin@medusa-test.com}
    PRIMARY_PASSWORD=${MEDUSA_ADMIN_PASSWORD_PROD:-supersecret}
    SC_PASSWORD=${MEDUSA_SCRIPT_CONSOLE_PASSWORD_PROD:-123} ;;
  *) echo "error: env must be stage | dev | prod (got '$ENV')" >&2; exit 2 ;;
esac

issue_token() {
  local email=$1 password=$2
  /usr/bin/curl -s -X POST "$API_BASE/auth/user/emailpass" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$email\",\"password\":\"$password\"}" \
    | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin).get('token',''))"
}

token_works() {
  local token=$1
  [ -z "$token" ] && return 1
  local code
  code=$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' -X POST "$API_BASE/admin/script-console/sql/run" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $token" \
    -H "x-script-console-password: $SC_PASSWORD" \
    -d '{"query":"SELECT 1"}')
  [ "$code" = "200" ]
}

# Try primary. If the token works against /admin/*, use it.
TOKEN=$(issue_token "$PRIMARY_EMAIL" "$PRIMARY_PASSWORD")
if token_works "$TOKEN"; then
  echo "$TOKEN"
  exit 0
fi

# Fallback: the prod superadmin. Always exists, well-known creds.
TOKEN=$(issue_token "admin@example.com" "supersecret")
if token_works "$TOKEN"; then
  echo "$TOKEN"
  exit 0
fi

echo "error: neither primary ($PRIMARY_EMAIL) nor fallback (admin@example.com) admin login worked on $ENV" >&2
exit 1
