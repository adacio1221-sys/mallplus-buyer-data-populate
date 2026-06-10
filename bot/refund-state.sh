#!/bin/bash
# refund-state.sh — fabricate a "refund in progress" or "refund failed"
# state on a real delivered/completed order, so QA can verify the
# storefront / seller-portal UI for these scenarios.
#
# Usage: refund-state.sh <order_id> <processing|failed> [env=prod]
#
# Mechanism: POST to /admin/script-console/typescript/run with a TS
# snippet that resolves the AFTER_SALES_MODULE service and creates an
# `order_return_request_case` with workflow_state='RETURN_PROCESSING'
# (and reverse_logistics_state='LOGISTICS_PICKUP_DONE' so the case can
# legally be advanced to RETURN_REFUND_PAID later). For mode=failed, it
# additionally creates an `order_adjustment` row of type='refund' with
# status='failed', linking it back to the case.
#
# Why this path: hand-INSERTing rows risks missing required-but-undeclared
# fields (timestamps, IDs, links). Going through the module service
# guarantees we get the same shape the seed script and admin endpoints
# produce. The seed script `seed-return-status-mass-update-qa.ts` was the
# canonical reference.
#
# On success, prints `<order_id> refund-state <mode> case=<id> adj=<id?>`.

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <order_id> <processing|failed> [env=stage|dev|prod]" >&2
  exit 2
fi

ORDER_ID=$1
MODE=$2
ENV=${3:-prod}

# Accept either a Medusa ULID or a storefront order_sn.
RESOLVED=$(/Users/daydream/buyer-data-populate/bot/resolve-order-id.sh "$ORDER_ID" "$ENV" 2>&1) || { echo "$RESOLVED" >&2; exit 1; }
ORDER_ID=$RESOLVED

case "$MODE" in
  not-started|processing|validation|delivery-failed|lost|failed|cancelled) ;;
  *) echo "error: mode must be 'not-started' | 'processing' | 'validation' | 'delivery-failed' | 'lost' | 'failed' | 'cancelled' (got '$MODE')" >&2; exit 2 ;;
esac

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

# TS snippet executed via script-console. Reads ORDER_ID & MODE from
# process.env (set by the args we pass; medusa exec parses KEY=VALUE
# positional args into env vars). Outputs a JSON line to stdout that
# the wrapper parses.
IFS='' read -r -d '' TS_CODE <<'TSEOF' || true
import { ContainerRegistrationKeys } from '@medusajs/framework/utils'

export default async function main({ container, args }: any) {
  const parsed = (args || []).reduce((acc: any, kv: string) => {
    const idx = kv.indexOf('=')
    if (idx > 0) acc[kv.slice(0, idx)] = kv.slice(idx + 1)
    return acc
  }, {})
  const orderId = parsed.ORDER_ID
  const mode = parsed.MODE
  if (!orderId || !mode) {
    throw new Error('ORDER_ID and MODE args are required (got: ' + JSON.stringify(parsed) + ')')
  }

  const query = container.resolve(ContainerRegistrationKeys.QUERY)
  const afterSales = container.resolve('afterSales') as any
  const orderAdjustment = container.resolve('orderAdjustment') as any
  const orderReturn = container.resolve('order_return') as any

  // ShortIdModuleService races under parallel writes (the algorithm reads
  // MAX(short_id) and increments — two concurrent callers can compute the
  // same next ID and one's INSERT fails on the unique constraint). Retry
  // with jitter when we detect that specific failure. ~50/50 success at
  // 8-way parallel without this; ~98%+ with 5 attempts.
  async function withShortIdRetry<T>(fn: () => Promise<T>): Promise<T> {
    let lastErr: any
    for (let attempt = 1; attempt <= 5; attempt++) {
      try { return await fn() } catch (err: any) {
        lastErr = err
        const msg = String(err?.message || err)
        const stack = String(err?.stack || '')
        const isCollision = /short[_ ]?id|duplicate key|unique constraint|already exists/i.test(msg)
                            || /ShortIdModuleService/.test(stack)
        if (!isCollision || attempt === 5) throw err
        const delayMs = 50 * Math.pow(2, attempt - 1) + Math.floor(Math.random() * 50)
        await new Promise(r => setTimeout(r, delayMs))
      }
    }
    throw lastErr
  }

  // Order context
  const { data: orders } = await query.graph({
    entity: 'order',
    fields: ['id', 'customer_id', 'currency_code', 'total', 'canceled_at', 'metadata'],
    filters: { id: orderId }
  })
  if (!orders || orders.length === 0) {
    throw new Error(`Order ${orderId} not found`)
  }
  const order = orders[0]
  if (order.canceled_at) {
    throw new Error(`Order ${orderId} is canceled — refunds only make sense for delivered/completed`)
  }

  // Seller from seller_order link
  const { data: sellerLinks } = await query.graph({
    entity: 'seller_order',
    fields: ['seller_id'],
    filters: { order_id: orderId }
  })
  if (!sellerLinks || sellerLinks.length === 0) {
    throw new Error(`No seller_order link for ${orderId}`)
  }
  const sellerId = (sellerLinks[0] as any).seller_id

  const caseNumber = Math.floor(Date.now() / 1000)
  const refundAmount = String(order.total ?? 0)

  // Create the buyer's order_return_request first so the seller portal's
  // requestReason column resolves to the chosen reason label (it reads
  // customer_note and metadata.buyer_return_reason via order_return_request_id
  // on the case). Without this the seller sees "—" for the reason.
  // Default reason picked from src/modules/seller-store-order-tabs/buyer-return-reason-catalog.ts.
  const reasonLabel = 'Product is defective or does not work'
  const reasonStructured = { label: reasonLabel, leaf: reasonLabel }
  const orderReturnRequest = await withShortIdRetry(() => orderReturn.createOrderReturnRequests({
    customer_id: order.customer_id,
    customer_note: reasonLabel,
    status: 'pending',
    metadata: { buyer_return_reason: reasonStructured, source: 'refund-state.sh' }
  }))
  const returnRequestId = orderReturnRequest.id

  // Workflow + reverse-logistics per mode (drives buyer statusTitle and
  // seller portal secondary tab):
  //   not-started     → RETURN_PROCESSING + LOGISTICS_NOT_STARTED     → tab `returning`, statusTitle "Returning"
  //   processing      → RETURN_PROCESSING + LOGISTICS_PICKUP_DONE     → tab `returning`, statusTitle "Returning"
  //   validation      → RETURN_PROCESSING + LOGISTICS_DELIVERY_DONE   → tab `returning`, statusTitle "Pending Validation"
  //   delivery-failed → RETURN_PROCESSING + LOGISTICS_DELIVERY_FAILED → tab `returning`, statusTitle "Returning"
  //   lost            → RETURN_PROCESSING + LOGISTICS_LOST            → tab `returning`, statusTitle "Returning"
  //   failed          → RETURN_CLOSED     + LOGISTICS_PICKUP_DONE     → tab `rejected`,  statusTitle "Request Rejected"
  //   cancelled       → RETURN_CANCELLED  + LOGISTICS_NOT_STARTED     → tab `rejected`,  statusTitle "Request Cancelled"
  // Source: src/utils/return-request-status.ts (buyer label) +
  // src/modules/seller-store-order-tabs/return-refund-list-query.ts (seller tab).
  let workflowState: string
  let reverseLogisticsState: string
  switch (mode) {
    case 'not-started':
      workflowState = 'RETURN_PROCESSING'; reverseLogisticsState = 'LOGISTICS_NOT_STARTED'; break
    case 'validation':
      workflowState = 'RETURN_PROCESSING'; reverseLogisticsState = 'LOGISTICS_DELIVERY_DONE'; break
    case 'delivery-failed':
      workflowState = 'RETURN_PROCESSING'; reverseLogisticsState = 'LOGISTICS_DELIVERY_FAILED'; break
    case 'lost':
      workflowState = 'RETURN_PROCESSING'; reverseLogisticsState = 'LOGISTICS_LOST'; break
    case 'failed':
      workflowState = 'RETURN_CLOSED'; reverseLogisticsState = 'LOGISTICS_PICKUP_DONE'; break
    case 'cancelled':
      workflowState = 'RETURN_CANCELLED'; reverseLogisticsState = 'LOGISTICS_NOT_STARTED'; break
    default: // processing
      workflowState = 'RETURN_PROCESSING'; reverseLogisticsState = 'LOGISTICS_PICKUP_DONE'
  }
  const nowIso = new Date()

  const created = await withShortIdRetry(() => afterSales.createOrderReturnRequestCases({
    order_return_request_id: returnRequestId,
    case_number: caseNumber,
    order_id: orderId,
    customer_id: order.customer_id,
    seller_id: sellerId,
    workflow_state: workflowState,
    reverse_logistics_state: reverseLogisticsState,
    solution_type: 'refund',
    request_origin: 'qa_bot',
    requested_refund_amount: refundAmount,
    approved_refund_amount: refundAmount,
    currency_code: order.currency_code || 'PHP',
    closed_at: mode === 'failed' ? nowIso : null,
    closed_reason_code: mode === 'failed' ? 'refund_payment_failed' : null,
    closed_reason_note: mode === 'failed' ? 'Refund attempt failed at payment provider' : null,
    cancelled_at: mode === 'cancelled' ? nowIso : null,
    metadata: { source: 'refund-state.sh', mode }
  }))

  await withShortIdRetry(() => afterSales.createReverseLogisticsShipments({
    context_type: 'return_request',
    order_id: orderId,
    seller_id: sellerId,
    order_return_request_case_id: created.id,
    provider_code: 'qa_bot',
    carrier_name: 'QA Bot Carrier',
    fulfillment_type: 'integrated',
    logistics_state: reverseLogisticsState,
    tracking_number: `QA-${caseNumber}`,
    tracking_url: `https://example.test/tracking/QA-${caseNumber}`,
    request_created_at: new Date(),
    raw_provider_payload: { source: 'refund-state.sh', mode }
  }))

  // Flip order.metadata.has_return_or_refund so the seller portal's
  // /vendor/orders tab logic categorizes this order into the
  // Return/Refund tab. The buyer-side already picks it up via the
  // order_return_request_case row, but seller.mallplus.ph reads the
  // metadata flag — see src/api/vendor/orders/helpers.ts:238.
  const orderModuleService = container.resolve('order') as any
  await orderModuleService.updateOrders(orderId, {
    metadata: {
      ...((order.metadata as any) || {}),
      has_return_or_refund: true
    }
  })

  let adjustmentId: string | null = null
  if (mode === 'failed') {
    const adj = await withShortIdRetry(() => orderAdjustment.createOrderAdjustments({
      order_id: orderId,
      seller_id: sellerId,
      adjustment_type: 'refund',
      reason: 'Refund attempt failed',
      reason_details: 'Simulated failed refund via refund-state.sh',
      amount: refundAmount,
      currency_code: order.currency_code || 'PHP',
      status: 'failed',
      initiated_by: 'system',
      adjustment_source: 'qa_bot',
      order_return_request_case_id: created.id,
      metadata: { source: 'refund-state.sh' }
    }))
    adjustmentId = adj.id
  }

  console.log(JSON.stringify({
    ok: true,
    order_id: orderId,
    mode,
    case_id: created.id,
    case_number: caseNumber,
    return_request_id: returnRequestId,
    adjustment_id: adjustmentId
  }))
}
TSEOF

# Build the POST body. The runner accepts {code, fileName, args}.
# args are passed to the medusa exec command line; the script parses them
# into process.env via medusa's KEY=VALUE convention.
REQ_BODY=$(/usr/bin/python3 <<PYEOF
import json
body = {
  "code": $(/usr/bin/python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$TS_CODE"),
  "fileName": "refund-state",
  "args": ["ORDER_ID=$ORDER_ID", "MODE=$MODE"]
}
print(json.dumps(body))
PYEOF
)

RESP=$(/usr/bin/curl -s -X POST "$API_BASE/admin/script-console/typescript/run" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-script-console-password: $SC_PASSWORD" \
  -d "$REQ_BODY")

EXIT_CODE=$(echo "$RESP" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('exitCode', -1))" 2>/dev/null || echo "-1")
if [ "$EXIT_CODE" != "0" ]; then
  echo "error: TS runner exited with code $EXIT_CODE" >&2
  echo "$RESP" | /usr/bin/python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print('--- stderr ---', file=sys.stderr)
    print((d.get('stderr') or '')[-1500:], file=sys.stderr)
    print('--- stdout ---', file=sys.stderr)
    print((d.get('stdout') or '')[-500:], file=sys.stderr)
except Exception:
    print(json.dumps({'raw': sys.stdin.read()})[:1500], file=sys.stderr)
"
  exit 1
fi

# Extract the JSON line we emitted from the script's stdout.
STDOUT=$(echo "$RESP" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('stdout',''))")
RESULT_LINE=$(echo "$STDOUT" | /usr/bin/grep -E '^\{.*"ok":\s*true' | tail -1 || true)
if [ -z "$RESULT_LINE" ]; then
  echo "error: TS script did not emit expected JSON result" >&2
  echo "--- stdout (last 1500 chars) ---" >&2
  echo "$STDOUT" | tail -c 1500 >&2
  exit 1
fi

CASE_ID=$(echo "$RESULT_LINE" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('case_id',''))")
ADJ_ID=$(echo "$RESULT_LINE" | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('adjustment_id') or '-')")
echo "$ORDER_ID refund-state $MODE case=$CASE_ID adj=$ADJ_ID"
