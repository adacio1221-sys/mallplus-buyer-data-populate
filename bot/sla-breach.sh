#!/bin/bash
# sla-breach.sh — force a Return-Refund case into SLA-breached state and fire
# the `rr_sla_breach` ticketing webhook NOW (instead of waiting for the real
# 24h+ inspection deadline or the 30-min cron).
#
# Usage:
#   sla-breach.sh <case_id_or_order_id_or_sn> [env=stage|dev|prod] [--skip-fire] [--dry-run]
#
# - Accepts a case ID (`orrc_...`), a Medusa order ULID (`order_...`), or a
#   storefront order_sn (`260605…`). For order inputs, resolves the latest
#   non-deleted case for that order.
# - Default behaviour: apply the state mutation AND fire the webhook
#   (the backing script's `apply=true` flag).
# - --skip-fire: apply the mutation but don't fire the webhook (cron will
#   pick it up on the next tick if you want to test the real flow).
# - --dry-run: invoke the script without `apply=true` — script prints what
#   it would change but doesn't mutate.
# - Pre-flight: refuses if the case isn't `workflow_state=RETURN_PROCESSING`
#   (mirrors the backing script's own safety guard, fails fast).
# - On success: `<case_id> sla-breach <fired|skipped|dry>`.
# - On failure: prints diagnostic lines to stderr and exits non-zero.

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 4 ]; then
  echo "usage: $0 <case_id_or_order_id_or_sn> [env=stage|dev|prod] [--skip-fire] [--dry-run]" >&2
  exit 2
fi

INPUT=$1
shift
ENV=prod
SKIP_FIRE=0
DRY_RUN=0

# Parse remaining args (positional env + optional flags, any order).
for arg in "$@"; do
  case "$arg" in
    --skip-fire) SKIP_FIRE=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    stage|staging|dev|development|prod|production) ENV=$arg ;;
    *) echo "error: unrecognized arg '$arg'" >&2; exit 2 ;;
  esac
done

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

# Resolve input to a case_id. The backing script expects `case-id=<id>`.
# Three input shapes:
#   orrc_…              → use directly
#   order_<ULID>        → SELECT latest case for this order
#   <order_sn> (date-ish + suffix) → resolve to order_id first, then case
if [[ "$INPUT" =~ ^orrc_[A-Z0-9]+$ ]]; then
  CASE_ID=$INPUT
elif [[ "$INPUT" =~ ^[A-Z0-9]{26}$ ]]; then
  # Bare 26-char ULID — could be a case ID (refund-state.sh prints these unprefixed).
  # Check if it exists as a case; if so use directly, else fall through to order path.
  PROBE=$(sql_run "SELECT id FROM order_return_request_case WHERE id = '$INPUT' AND deleted_at IS NULL LIMIT 1" \
    | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('id', '') if rows else '')
except Exception:
    print('')")
  if [ -n "$PROBE" ]; then
    CASE_ID=$INPUT
  else
    echo "error: '$INPUT' is not a known case ID; pass an order_id, order_sn, or orrc_… case ID instead" >&2
    exit 1
  fi
else
  # If not a Medusa ULID, run it through resolve-order-id to convert order_sn.
  if [[ ! "$INPUT" =~ ^order_[A-Z0-9]+$ ]]; then
    RESOLVED=$(/Users/daydream/buyer-data-populate/bot/resolve-order-id.sh "$INPUT" "$ENV" 2>&1) \
      || { echo "$RESOLVED" >&2; exit 1; }
    INPUT=$RESOLVED
  fi
  CASE_LOOKUP=$(sql_run "SELECT id, workflow_state FROM order_return_request_case WHERE order_id = '$INPUT' AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 1")
  CASE_ID=$(echo "$CASE_LOOKUP" | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('id', '') if rows else '')
except Exception:
    print('')")
  if [ -z "$CASE_ID" ]; then
    echo "error: no return-request-case found for $INPUT" >&2
    exit 1
  fi
fi

# Pre-flight: workflow_state must be RETURN_PROCESSING (matches the script's guard).
STATE=$(sql_run "SELECT workflow_state FROM order_return_request_case WHERE id = '$CASE_ID'" \
  | /usr/bin/python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin).get('rows', [])
    print(rows[0].get('workflow_state', '') if rows else '')
except Exception:
    print('')")
if [ "$STATE" != "RETURN_PROCESSING" ]; then
  echo "error: case $CASE_ID is in workflow_state='$STATE' (need RETURN_PROCESSING)" >&2
  exit 1
fi

# Build the script args list.
SCRIPT_ARGS="\"case-id=$CASE_ID\""
if [ "$DRY_RUN" -eq 0 ]; then
  SCRIPT_ARGS="$SCRIPT_ARGS, \"apply=true\""
fi
if [ "$SKIP_FIRE" -eq 1 ]; then
  SCRIPT_ARGS="$SCRIPT_ARGS, \"skip-fire=true\""
fi

# Stage/prod are Dockerized and serve compiled .js; dev still has the .ts source.
SCRIPT_NAME="test-data-support/breach-rr-sla.js"

BODY="{\"script\":\"$SCRIPT_NAME\",\"args\":[$SCRIPT_ARGS]}"

RESULT=$(/usr/bin/curl -s -X POST "$API_BASE/admin/script-console/scripts/run" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-script-console-password: $SC_PASSWORD" \
  -d "$BODY")

OUTCOME=$(echo "$RESULT" | /usr/bin/python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except json.JSONDecodeError:
    print('error: response was not JSON', file=sys.stderr); sys.exit(1)
exit_code = d.get('exitCode')
if exit_code == 0:
    print('ok'); sys.exit(0)
buf = d.get('stdout', '') or d.get('output', '') or json.dumps(d)
fail_lines = [l for l in buf.splitlines() if '❌' in l or 'Error running script' in l or '[breach-rr-sla]' in l]
for l in fail_lines[-3:]:
    print(l[:300], file=sys.stderr)
print('fail')
" 2>&1)

case "$OUTCOME" in
  *ok*)
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "$CASE_ID sla-breach dry"
    elif [ "$SKIP_FIRE" -eq 1 ]; then
      echo "$CASE_ID sla-breach skipped"
    else
      echo "$CASE_ID sla-breach fired"
    fi
    exit 0 ;;
  *)
    echo "error: breach-rr-sla script reported failure for $CASE_ID" >&2
    echo "$OUTCOME" | head -5 >&2
    exit 1 ;;
esac
