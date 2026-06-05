#!/bin/bash
# attach-pod.sh — attach a proof-of-delivery (photo URL + recipient name) to
# an order's fulfillment by directly patching `fulfillment.metadata` via the
# Medusa fulfillment module. Lands in the same place a real JT POD webhook
# would (per MP-7037: `proof_of_delivery_url` + `proof_of_delivery_recipient_name`
# on fulfillment.metadata), so the buyer storefront's "Check proof of delivery"
# sheet picks it up.
#
# Does NOT move the order to "completed" — POD lives on fulfillment, the
# order.status flip is a separate buyer action (rating/confirm).
#
# Why direct-write instead of firing the JT webhook: the /3pl/webhook/jt
# endpoint requires a valid HMAC-SHA256 `x-signature` header signed with
# the provider secret (encrypted server-side), so a synthetic webhook from
# outside is rejected with "Missing signature header". Going through the
# fulfillment module directly gets the same end state on fulfillment.metadata
# without the signing dance.
#
# Usage:
#   attach-pod.sh <order_id_or_sn> [env=prod] [--url=<photo_url>] [--recipient=<name>]
#
# Defaults:
#   url       = https://via.placeholder.com/600x400.jpg?text=QA+POD
#   recipient = "QA Recipient"
#
# Pre-flight: requires the order to have a fulfillment row (i.e. it's at
# shipping/delivered/completed status, not unpaid/to_ship).
#
# On success: `<order_id> attach-pod url=<url> recipient=<name>`.
# On failure: prints diagnostic lines to stderr and exits non-zero.

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 4 ]; then
  echo "usage: $0 <order_id_or_sn> [env=stage|dev|prod] [--url=<photo_url>] [--recipient=<name>]" >&2
  exit 2
fi

INPUT=$1
shift
ENV=prod
POD_URL='https://via.placeholder.com/600x400.jpg?text=QA+POD'
POD_RECIPIENT='QA Recipient'

for arg in "$@"; do
  case "$arg" in
    --url=*)       POD_URL="${arg#--url=}" ;;
    --recipient=*) POD_RECIPIENT="${arg#--recipient=}" ;;
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

RESOLVED=$(/Users/daydream/buyer-data-populate/bot/resolve-order-id.sh "$INPUT" "$ENV" 2>&1) \
  || { echo "$RESOLVED" >&2; exit 1; }
ORDER_ID=$RESOLVED

TOKEN=$(/usr/bin/curl -s -X POST "$API_BASE/auth/user/emailpass" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" \
  | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))")
[ -z "$TOKEN" ] && { echo "error: admin login failed" >&2; exit 1; }

# Build TS that merges proof_of_delivery_url + recipient into fulfillment.metadata
# via the fulfillment module's updateFulfillment(). Mirrors the write path in
# src/subscribers/3pl-jt/webhook-event-handler.ts so the buyer UI sees the
# same shape as a real POD upload.
IFS='' read -r -d '' TS_CODE <<'TSEOF' || true
import { ContainerRegistrationKeys, Modules } from '@medusajs/framework/utils'

export default async function main({ container, args }: any) {
  const parsed = (args || []).reduce((acc: any, kv: string) => {
    const idx = kv.indexOf('=')
    if (idx > 0) acc[kv.slice(0, idx)] = kv.slice(idx + 1)
    return acc
  }, {})
  const orderId = parsed.ORDER_ID
  const podUrl = parsed.POD_URL
  const recipient = parsed.POD_RECIPIENT
  if (!orderId || !podUrl || !recipient) {
    throw new Error('ORDER_ID, POD_URL, POD_RECIPIENT args are required')
  }

  const query = container.resolve(ContainerRegistrationKeys.QUERY)

  const { data: links } = await query.graph({
    entity: 'order_fulfillment',
    fields: ['fulfillment_id'],
    filters: { order_id: orderId }
  } as any)
  const fulfillmentIds = (links || [])
    .map((l: any) => l.fulfillment_id)
    .filter(Boolean)
  if (fulfillmentIds.length === 0) {
    throw new Error('No fulfillment found for order ' + orderId + ' — needs to be at least shipping/delivered status first')
  }

  const fulfillmentModule: any = container.resolve(Modules.FULFILLMENT)

  // Load existing metadata so we merge, not clobber. Mirrors the webhook
  // handler's pattern: append a tracking event, attach POD, then write back.
  const existing = await fulfillmentModule.retrieveFulfillment(fulfillmentIds[0])
  const existingMetadata = (existing?.metadata as any) || {}
  const trackingEvents = Array.isArray(existingMetadata.tracking_events)
    ? [...existingMetadata.tracking_events]
    : []

  const now = new Date()
  trackingEvents.push({
    timestamp: now.toISOString(),
    description: 'Parcel delivered to recipient',
    location: 'Manila'
  })

  const newMetadata = {
    ...existingMetadata,
    tracking_events: trackingEvents,
    proof_of_delivery_url: podUrl,
    proof_of_delivery_recipient_name: recipient
  }

  // Match the webhook handler's two writes: metadata update + delivered_at
  // stamp. We intentionally SKIP orderModule.completeOrder() so order.status
  // stays pending (user preference 2026-06-05: POD without completing).
  await fulfillmentModule.updateFulfillment(fulfillmentIds[0], {
    metadata: newMetadata
  })
  const alreadyDelivered = !!existing?.delivered_at
  if (!alreadyDelivered) {
    await fulfillmentModule.updateFulfillment(fulfillmentIds[0], {
      delivered_at: now
    })
  }

  console.log(JSON.stringify({
    ok: true,
    order_id: orderId,
    fulfillment_id: fulfillmentIds[0],
    proof_of_delivery_url: podUrl,
    proof_of_delivery_recipient_name: recipient,
    delivered_at_stamped: !alreadyDelivered,
    tracking_events_count: trackingEvents.length
  }))
}
TSEOF

REQ_BODY=$(/usr/bin/python3 <<PYEOF
import json
print(json.dumps({
  "code": $(/usr/bin/python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$TS_CODE"),
  "fileName": "attach-pod",
  "args": ["ORDER_ID=$ORDER_ID", "POD_URL=$POD_URL", "POD_RECIPIENT=$POD_RECIPIENT"]
}))
PYEOF
)

RESULT=$(/usr/bin/curl -s -X POST "$API_BASE/admin/script-console/typescript/run" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-script-console-password: $SC_PASSWORD" \
  -d "$REQ_BODY")

OUTCOME=$(echo "$RESULT" | /usr/bin/python3 -c "
import json, sys, re
try:
    d = json.load(sys.stdin)
except json.JSONDecodeError:
    print('error: response was not JSON', file=sys.stderr); sys.exit(1)
exit_code = d.get('exitCode')
if exit_code == 0:
    print('ok'); sys.exit(0)
buf = d.get('stdout', '') or json.dumps(d)
errs = [l for l in buf.splitlines() if '\"level\":\"error\"' in l or 'Error running' in l or 'No fulfillment' in l]
for l in errs[-3:]:
    print(l[:300], file=sys.stderr)
print('fail')
" 2>&1)

case "$OUTCOME" in
  *ok*)
    echo "$ORDER_ID attach-pod url=$POD_URL recipient=\"$POD_RECIPIENT\""
    exit 0 ;;
  *)
    echo "error: attach-pod failed for $ORDER_ID" >&2
    echo "$OUTCOME" | head -5 >&2
    exit 1 ;;
esac
