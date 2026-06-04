#!/bin/bash
# cancel-line-item.sh — cancel a single line item on a multi-item order,
# leaving the others intact. Drives Medusa core's order-edit workflow
# (begin → update item quantity to 0 → confirm) via the script-console
# TypeScript runner.
#
# Usage: cancel-line-item.sh <order_id> <item_index_1_based> [env=prod]
#
# Example: `cancel-line-item.sh order_X 2 dev` cancels the 2nd line item
# of the order. Items are ordered by their order_item.created_at.
#
# Mechanism: setting an item's quantity to 0 through the order-edit
# workflow removes it cleanly — Medusa's core docs explicitly state
# this is the supported way. The workflow recalculates order totals,
# fulfillment requirements, and other aggregates so the order stays
# internally consistent.
#
# On success, prints `<order_id> line-canceled item=<orli_id> remaining=<n>`.

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <order_id> <item_index_1_based> [env=stage|dev|prod]" >&2
  exit 2
fi

ORDER_ID=$1
ITEM_INDEX=$2
ENV=${3:-prod}

# Accept either a Medusa ULID or a storefront order_sn.
RESOLVED=$(/Users/daydream/buyer-data-populate/bot/resolve-order-id.sh "$ORDER_ID" "$ENV" 2>&1) || { echo "$RESOLVED" >&2; exit 1; }
ORDER_ID=$RESOLVED

if ! [[ "$ITEM_INDEX" =~ ^[0-9]+$ ]] || [ "$ITEM_INDEX" -lt 1 ]; then
  echo "error: item_index must be a positive integer (got '$ITEM_INDEX')" >&2
  exit 2
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
[ -z "$TOKEN" ] && { echo "error: admin login failed" >&2; exit 1; }

TS_CODE=$(/bin/cat <<'TSEOF'
import { ContainerRegistrationKeys } from '@medusajs/framework/utils'
import {
  beginOrderEditOrderWorkflow,
  orderEditUpdateItemQuantityWorkflow,
  confirmOrderEditRequestWorkflow
} from '@medusajs/core-flows'

export default async function main({ container, args }: any) {
  const parsed = (args || []).reduce((acc: any, kv: string) => {
    const idx = kv.indexOf('=')
    if (idx > 0) acc[kv.slice(0, idx)] = kv.slice(idx + 1)
    return acc
  }, {})
  const orderId = parsed.ORDER_ID
  const itemIndex = parseInt(parsed.ITEM_INDEX || '0', 10)
  if (!orderId || !itemIndex) {
    throw new Error('ORDER_ID and ITEM_INDEX args are required')
  }

  const query = container.resolve(ContainerRegistrationKeys.QUERY)

  // Fetch order items in creation order. We filter to items with a
  // variant_id (i.e. real product line items) to skip auto-injected
  // entries like "Service Fee" rows that show up alongside products.
  const { data: orders } = await query.graph({
    entity: 'order',
    fields: ['id', 'status', 'canceled_at', 'items.id', 'items.title', 'items.quantity', 'items.variant_id', 'items.created_at'],
    filters: { id: orderId }
  })
  if (!orders || orders.length === 0) throw new Error(`Order ${orderId} not found`)
  const order = orders[0] as any
  if (order.canceled_at) throw new Error(`Order ${orderId} is already canceled`)
  const items = (order.items || []).filter((it: any) => it.variant_id).slice().sort((a: any, b: any) => {
    const ta = new Date(a.created_at).getTime()
    const tb = new Date(b.created_at).getTime()
    return ta - tb
  })
  if (items.length < 2) {
    throw new Error(`Order ${orderId} has only ${items.length} product line item(s); partial cancel needs 2+`)
  }
  if (itemIndex > items.length) {
    throw new Error(`item_index ${itemIndex} > product item count ${items.length}`)
  }

  const target = items[itemIndex - 1]
  const targetId = target.id
  const targetTitle = target.title

  // 1. Begin order edit.
  await beginOrderEditOrderWorkflow(container).run({
    input: { order_id: orderId, created_by: 'system_qa_bot' }
  })

  // 2. Set item quantity to 0 → removes it from the order.
  await orderEditUpdateItemQuantityWorkflow(container).run({
    input: {
      order_id: orderId,
      items: [{ id: targetId, quantity: 0 }]
    }
  })

  // 3. Confirm.
  await confirmOrderEditRequestWorkflow(container).run({
    input: { order_id: orderId, confirmed_by: 'system_qa_bot' }
  })

  console.log(JSON.stringify({
    ok: true,
    order_id: orderId,
    canceled_item_id: targetId,
    canceled_item_title: targetTitle,
    remaining_items: items.length - 1
  }))
}
TSEOF
)

REQ_BODY=$(/usr/bin/python3 <<PYEOF
import json
body = {
  "code": $(/usr/bin/python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$TS_CODE"),
  "fileName": "cancel-line-item",
  "args": ["ORDER_ID=$ORDER_ID", "ITEM_INDEX=$ITEM_INDEX"]
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
    print('--- stderr ---', file=sys.stderr); print((d.get('stderr') or '')[-1500:], file=sys.stderr)
    print('--- stdout ---', file=sys.stderr); print((d.get('stdout') or '')[-1500:], file=sys.stderr)
except Exception:
    print(json.dumps({'raw': sys.stdin.read()})[:1500], file=sys.stderr)
"
  exit 1
fi

STDOUT=$(echo "$RESP" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('stdout',''))")
RESULT_LINE=$(echo "$STDOUT" | /usr/bin/grep -E '^\{.*"ok":\s*true' | tail -1 || true)
if [ -z "$RESULT_LINE" ]; then
  echo "error: TS script did not emit expected JSON result" >&2
  echo "$STDOUT" | tail -c 1500 >&2
  exit 1
fi

CANCELED_ID=$(echo "$RESULT_LINE" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('canceled_item_id',''))")
REMAINING=$(echo "$RESULT_LINE" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('remaining_items',''))")
echo "$ORDER_ID line-canceled item=$CANCELED_ID remaining=$REMAINING"
