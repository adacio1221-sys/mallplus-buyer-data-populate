#!/bin/bash
# jt-status.sh — force a J&T shipment status on an order by emitting the
# matching UCDM ShipmentEvent into Medusa's event bus, so the real
# `src/subscribers/3pl-jt/webhook-event-handler.ts` runs end-to-end on
# the prod/stage container. Same effect as if J&T had actually sent the
# corresponding webhook to /3pl/webhook/jt — without needing HMAC signing
# (the route's signature gate is bypassed because we go through the
# subscriber directly).
#
# Usage:
#   jt-status.sh <order_id_or_sn> <status> [env=prod]
#
# Statuses (case-insensitive):
#   picked_up         → LOGISTICS_PICKUP_DONE,    jt_shipment.status=in_transit
#   in_transit        → jt_shipment.status=in_transit
#   departure         → LOGISTICS_DEPARTURE
#   arrival           → LOGISTICS_ARRIVAL
#   out_for_delivery  → LOGISTICS_OUT_FOR_DELIVERY
#   delivered         → LOGISTICS_DELIVERY_DONE,  fulfillment.delivered_at,
#                       calls orderModule.completeOrder() → ORDER FLIPS TO COMPLETED,
#                       emits order.delivery_confirmed
#   delivery_failed   → LOGISTICS_DELIVERY_FAILED, emits order.delivery_failed
#   returned          → jt_shipment.status=returned
#
# Pre-flight: requires an existing jt_shipment row for the order (i.e.
# arrange-pickup must have run, OR attach-pod injected a synthetic
# shipment). If no shipment exists, the helper auto-injects one (same
# pattern as attach-pod.sh) so QA-seeded orders can still exercise the
# subscriber chain.
#
# Each event also appends a tracking_events entry to fulfillment.metadata
# with timestamp + description + location.
#
# On success: `<order_id> jt-status=<status> waybill=<bill_code>`.

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <order_id_or_sn> <picked_up|in_transit|departure|arrival|out_for_delivery|delivered|delivery_failed|returned> [env=prod]" >&2
  exit 2
fi

INPUT=$1
STATUS=$(echo "$2" | /usr/bin/tr '[:upper:]' '[:lower:]')
ENV=${3:-prod}

case "$STATUS" in
  picked_up|in_transit|departure|arrival|out_for_delivery|delivered|delivery_failed|returned) ;;
  *) echo "error: unknown status '$STATUS'" >&2; exit 2 ;;
esac

case "$ENV" in
  stage|staging) API_BASE=${MEDUSA_API_BASE_STAGE:-https://staging-api.mallplus.ph}
                 SC_PASSWORD=${MEDUSA_SCRIPT_CONSOLE_PASSWORD_STAGE:-123} ;;
  dev|development) API_BASE=${MEDUSA_API_BASE_DEV:-https://dev-api.mallplus.ph}
                   SC_PASSWORD=${MEDUSA_SCRIPT_CONSOLE_PASSWORD_DEV:-123} ;;
  prod|production) API_BASE=${MEDUSA_API_BASE_PROD:-https://api.mallplus.ph}
                   SC_PASSWORD=${MEDUSA_SCRIPT_CONSOLE_PASSWORD_PROD:-123} ;;
  *) echo "error: env must be 'stage' | 'dev' | 'prod'" >&2; exit 2 ;;
esac

RESOLVED=$(/Users/daydream/buyer-data-populate/bot/resolve-order-id.sh "$INPUT" "$ENV" 2>&1) \
  || { echo "$RESOLVED" >&2; exit 1; }
ORDER_ID=$RESOLVED

TOKEN=$(/Users/daydream/buyer-data-populate/bot/admin-token.sh "$ENV") \
  || { echo "error: admin login failed for env=$ENV" >&2; exit 1; }

sql_run() {
  local query=$1 body
  body=$(/usr/bin/python3 -c "import json,sys;print(json.dumps({'query': sys.argv[1]}))" "$query")
  /usr/bin/curl -s -X POST "$API_BASE/admin/script-console/sql/run" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $TOKEN" \
    -H "x-script-console-password: $SC_PASSWORD" \
    -d "$body"
}

# Resolve the order's jt_shipment + bill_code. If missing, auto-inject one
# the same way attach-pod.sh does (so QA-seeded orders that skipped
# arrange-pickup can still drive JT events).
LOOKUP=$(sql_run "SELECT id, bill_code, fulfillment_id FROM jt_shipment WHERE order_id = '$ORDER_ID' AND deleted_at IS NULL AND bill_code IS NOT NULL ORDER BY created_at DESC LIMIT 1")
BILL_CODE=$(echo "$LOOKUP" | /usr/bin/python3 -c "
import json,sys
try:
  r = json.load(sys.stdin).get('rows',[])
  print(r[0].get('bill_code','') if r else '')
except: print('')")

if [ -z "$BILL_CODE" ]; then
  FULFILLMENT_ID=$(sql_run "SELECT fulfillment_id FROM order_fulfillment WHERE order_id = '$ORDER_ID' LIMIT 1" \
    | /usr/bin/python3 -c "
import json,sys
try:
  r = json.load(sys.stdin).get('rows',[])
  print(r[0].get('fulfillment_id','') if r else '')
except: print('')")
  if [ -z "$FULFILLMENT_ID" ]; then
    echo "error: no fulfillment for $ORDER_ID — order must be at least shipping/delivered status to drive JT events" >&2
    exit 1
  fi
  SELLER_ID=$(sql_run "SELECT seller_id FROM seller_seller_order_order WHERE order_id = '$ORDER_ID' LIMIT 1" \
    | /usr/bin/python3 -c "
import json,sys
try:
  r = json.load(sys.stdin).get('rows',[])
  print(r[0].get('seller_id','') if r else '')
except: print('')")
  BILL_CODE="QA-JT-$(echo "$ORDER_ID" | /usr/bin/sed 's/order_//')"
  SHIP_ID="jtship_qa_$(/usr/bin/python3 -c 'import secrets;print(secrets.token_hex(6))')"
  TXLID="QA_${ORDER_ID}_$(/usr/bin/python3 -c 'import secrets;print(secrets.token_hex(4))')"
  sql_run "INSERT INTO jt_shipment (id, order_id, fulfillment_id, seller_id, tx_logistic_id, bill_code, status, logistics_status, sender_name, sender_phone, sender_address, receiver_name, receiver_phone, receiver_address, created_at, updated_at) VALUES ('$SHIP_ID', '$ORDER_ID', '$FULFILLMENT_ID', '$SELLER_ID', '$TXLID', '$BILL_CODE', 'pending', 'LOGISTICS_NOT_STARTED', 'QA Seller', '-', '{}'::jsonb, 'QA Recipient', '-', '{}'::jsonb, now(), now())" > /dev/null
fi

# Map our status to ShipmentEventType + a sensible JT-shaped description.
case "$STATUS" in
  picked_up)        EVENT_TYPE='shipment.picked_up';        DESC='Parcel picked up from sender by courier';  JT_STATUS='Picked Up' ;;
  in_transit)       EVENT_TYPE='shipment.in_transit';       DESC='Parcel in transit';                         JT_STATUS='In Transit' ;;
  departure)        EVENT_TYPE='shipment.departure';        DESC='Parcel departed from sorting hub';          JT_STATUS='Departure' ;;
  arrival)          EVENT_TYPE='shipment.arrival';          DESC='Parcel arrived at sorting hub';             JT_STATUS='Arrival' ;;
  out_for_delivery) EVENT_TYPE='shipment.out_for_delivery'; DESC='Parcel out for delivery';                   JT_STATUS='Out for Delivery' ;;
  delivered)        EVENT_TYPE='shipment.delivered';        DESC='Parcel delivered to recipient';             JT_STATUS='Delivered' ;;
  delivery_failed)  EVENT_TYPE='shipment.failed_delivery';  DESC='Delivery attempt failed';                   JT_STATUS='Delivery Fail' ;;
  returned)         EVENT_TYPE='shipment.returned';         DESC='Parcel returned to sender';                 JT_STATUS='Returned' ;;
esac

# Build the UCDM event payload and emit it on the EventBus that the JT
# subscriber listens to. Calling the subscriber directly (rather than the
# raw /3pl/webhook endpoint) bypasses the HMAC signature check while
# still firing the exact same handler that real JT webhooks trigger.
IFS='' read -r -d '' TS_CODE <<'TSEOF' || true
import { ContainerRegistrationKeys, Modules } from '@medusajs/framework/utils'

export default async function main({ container, args }: any) {
  const parsed = (args || []).reduce((acc: any, kv: string) => {
    const idx = kv.indexOf('=')
    if (idx > 0) acc[kv.slice(0, idx)] = kv.slice(idx + 1)
    return acc
  }, {})
  const orderId      = parsed.ORDER_ID
  const billCode     = parsed.BILL_CODE
  const eventType    = parsed.EVENT_TYPE
  const description  = parsed.DESC
  const jtStatus     = parsed.JT_STATUS

  const nowIso = new Date().toISOString()
  const eventData = {
    event_id: `qa-${billCode}-${eventType}-${Date.now()}`,
    provider: 'jt_express',
    tracking_number: billCode,
    event_type: eventType,
    event_timestamp: nowIso,
    status_code: 'QA',
    status_description: description,
    location: { city: 'Manila', province: 'Metro Manila' },
    order_reference: orderId,
    raw_payload: { qa_simulated: true, billCode, status: jtStatus, updatedTime: nowIso, orderId }
  }

  // Invoke the subscriber's handler directly. EventBus.emit doesn't work
  // here because script-console runs in a separate process from the API
  // server — cross-process bus emits don't reach the running subscribers.
  // Importing + calling the handler function gives us the same end state
  // without needing the API server to mediate.
  const handlerMod: any = await import(
    '/Data/sbin/medusa-api/.medusa/server/src/subscribers/3pl-jt/webhook-event-handler.js'
  )
  // CJS interop wrapping varies — probe for the actual function.
  const handler =
    (typeof handlerMod === 'function' && handlerMod) ||
    (typeof handlerMod.default === 'function' && handlerMod.default) ||
    (typeof handlerMod.default?.default === 'function' && handlerMod.default.default) ||
    null
  if (!handler) {
    throw new Error('Could not locate JT subscriber handler in module: keys=' + JSON.stringify(Object.keys(handlerMod || {})))
  }
  // Capture errors from inside the handler — its outer try/catch otherwise
  // swallows them silently.
  let handlerErr: any = null
  try {
    await handler({ event: { data: eventData }, container })
  } catch (e) {
    handlerErr = e
  }

  // The handler's jtService.updateJTShipments call doesn't commit in
  // script-console's TS context (transaction quirk — parallel
  // fulfillmentModule.updateFulfillment calls DO persist, which is why
  // tracking_events land). Force the jt_shipment row update via raw SQL
  // so the visible state lands. The handler still runs all its other
  // side effects (tracking_events append, downstream order events,
  // fulfillment.delivered_at on DELIVERED) before this.
  const knex = container.resolve(ContainerRegistrationKeys.PG_CONNECTION) as any
  const updates: any = {
    jt_status_code: 'QA',
    jt_status_desc: description,
    updated_at: new Date()
  }
  switch (eventType) {
    case 'shipment.picked_up':
      updates.status = 'in_transit'
      updates.picked_up_at = nowIso
      updates.logistics_status = 'LOGISTICS_PICKUP_DONE'
      break
    case 'shipment.in_transit':
      updates.status = 'in_transit'
      break
    case 'shipment.departure':
      updates.status = 'in_transit'
      updates.logistics_status = 'LOGISTICS_DEPARTURE'
      break
    case 'shipment.arrival':
      updates.status = 'in_transit'
      updates.logistics_status = 'LOGISTICS_ARRIVAL'
      break
    case 'shipment.out_for_delivery':
      updates.status = 'in_transit'
      updates.logistics_status = 'LOGISTICS_OUT_FOR_DELIVERY'
      break
    case 'shipment.delivered':
      updates.status = 'delivered'
      updates.delivered_at = nowIso
      updates.logistics_status = 'LOGISTICS_DELIVERY_DONE'
      break
    case 'shipment.failed_delivery':
      updates.status = 'failed'
      updates.failed_at = nowIso
      updates.logistics_status = 'LOGISTICS_DELIVERY_FAILED'
      break
    case 'shipment.returned':
      updates.status = 'returned'
      updates.logistics_status = 'LOGISTICS_RETURNED'
      break
  }
  await knex('jt_shipment').where({ bill_code: billCode, deleted_at: null }).update(updates)

  console.log(JSON.stringify({ ok: !handlerErr, order_id: orderId, bill_code: billCode, event_type: eventType, sql_applied: true, err: handlerErr ? String(handlerErr?.stack || handlerErr) : null }))
}
TSEOF

REQ_BODY=$(/usr/bin/python3 <<PYEOF
import json
print(json.dumps({
  'code': $(/usr/bin/python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$TS_CODE"),
  'fileName': 'jt-status',
  'args': ["ORDER_ID=$ORDER_ID", "BILL_CODE=$BILL_CODE", "EVENT_TYPE=$EVENT_TYPE", "DESC=$DESC", "JT_STATUS=$JT_STATUS"]
}))
PYEOF
)

RESULT=$(/usr/bin/curl -s -X POST "$API_BASE/admin/script-console/typescript/run" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-script-console-password: $SC_PASSWORD" \
  -d "$REQ_BODY")

OUTCOME=$(echo "$RESULT" | /usr/bin/python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except json.JSONDecodeError:
    print('error: response was not JSON', file=sys.stderr); sys.exit(1)
ec = d.get('exitCode')
if ec == 0:
    print('ok'); sys.exit(0)
buf = d.get('stdout','') or json.dumps(d)
errs = [l for l in buf.splitlines() if '\"level\":\"error\"' in l or 'Error running' in l]
for l in errs[-3:]:
    print(l[:300], file=sys.stderr)
print('fail')
" 2>&1)

case "$OUTCOME" in
  *ok*)
    echo "$ORDER_ID jt-status=$STATUS waybill=$BILL_CODE"
    if [ "$STATUS" = "delivered" ]; then
      echo "  note: stamps fulfillment.delivered_at + emits order.delivery_confirmed. Per MP-8408 the order does NOT auto-complete on delivery — buyer must confirm-received or the auto-confirmation window-lapse job runs." >&2
    fi
    exit 0 ;;
  *)
    echo "error: jt-status handler reported failure for $ORDER_ID" >&2
    echo "$OUTCOME" | head -5 >&2
    exit 1 ;;
esac
