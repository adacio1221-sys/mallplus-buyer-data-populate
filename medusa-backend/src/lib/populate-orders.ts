// Creates N orders per buyer-tab status for a given customer on the MallPlus
// Medusa v2 backend.
//
// Tab → Medusa fields:
//   to_pay     → status=pending  payment=not_paid  fulfillment=not_fulfilled
//   to_ship    → status=pending  payment=captured  fulfillment=not_fulfilled
//   to_receive → status=pending  payment=captured  fulfillment=shipped
//   to_rate    → status=pending  payment=captured  fulfillment=delivered
//
// Used by:
//   - src/scripts/orders/create-order-by-status.ts  (npx medusa exec ...)
//   - src/api/admin/populate-orders/route.ts        (HTTP, called by Telegram bot)
//
// Assumptions about the environment (already true on staging.mallplus.ph):
//   - A region for PH exists with currency PHP and the GCash provider enabled.
//   - At least one shipping option is enabled for that region.
//   - The customer (looked up by email) has at least one address.
//   - Some product variants are in-stock in the region's sales channel.
//
// Trade-off note on payment_provider_id:
//   We use markPaymentCollectionAsPaid for to_ship/to_receive/to_rate. That
//   workflow internally creates a session against pp_system_default to skip
//   the live GCash flow (which sandbox can't auto-confirm from here). The
//   resulting order may show pp_system_default as the payment provider rather
//   than pp_gcash_webpay. The original GCash session is still on the payment
//   collection — only the *captured* session is system_default. If your QA
//   needs the displayed provider to be GCash, drive the live sandbox flow
//   separately for that specific test.

import { MedusaContainer } from "@medusajs/framework/types"
import { Modules } from "@medusajs/framework/utils"
import {
  createCartWorkflow,
  addShippingMethodToCartWorkflow,
  createPaymentCollectionForCartWorkflow,
  createPaymentSessionsWorkflow,
  completeCartWorkflow,
  createOrderFulfillmentWorkflow,
  createOrderShipmentWorkflow,
  markOrderFulfillmentAsDeliveredWorkflow,
  markPaymentCollectionAsPaid,
} from "@medusajs/medusa/core-flows"

export const PAYMENT_PROVIDER_ID = "pp_gcash_webpay"
export const DEFAULT_SELLER_HANDLE = "adidas-official"

export type StatusKey = "to_pay" | "to_ship" | "to_receive" | "to_rate"
export const STATUS_KEYS: StatusKey[] = [
  "to_pay",
  "to_ship",
  "to_receive",
  "to_rate",
]

export type Counts = Record<StatusKey, number>

export type PopulateOptions = {
  customer_email: string
  counts: Partial<Counts>
  // Optional overrides — auto-resolved if omitted.
  region_id?: string
  sales_channel_id?: string
  shipping_option_id?: string
  // Restrict line items to products from a specific seller (Mercur-style
  // multi-vendor link). Matches against `seller.handle`. Pass null/empty to
  // disable filtering; defaults to "adidas-official" per QA convention.
  seller_handle?: string | null
  // Number of variants to randomize across (defaults to 1 line item per order).
  items_per_order?: number
}

export type PopulateResult = {
  to_pay: string[]
  to_ship: string[]
  to_receive: string[]
  to_rate: string[]
  errors: { status: StatusKey; index: number; message: string }[]
}

export async function populateOrdersByStatus(
  container: MedusaContainer,
  opts: PopulateOptions
): Promise<PopulateResult> {
  const logger = resolveLogger(container)
  const result: PopulateResult = {
    to_pay: [],
    to_ship: [],
    to_receive: [],
    to_rate: [],
    errors: [],
  }

  const ctx = await resolveContext(container, opts)
  logger.info(
    `[populate-orders] customer=${ctx.customer.id} region=${ctx.region.id} ` +
      `sales_channel=${ctx.salesChannelId} shipping_option=${ctx.shippingOptionId} ` +
      `seller=${ctx.sellerHandle ?? "(any)"} variants=${ctx.variantIds.length}`
  )

  for (const status of STATUS_KEYS) {
    const n = opts.counts[status] ?? 0
    for (let i = 0; i < n; i++) {
      try {
        const orderId = await createOrderInStatus(container, ctx, status, i)
        result[status].push(orderId)
        logger.info(`[populate-orders] ${status} #${i + 1}/${n} -> ${orderId}`)
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e)
        result.errors.push({ status, index: i, message })
        logger.error(
          `[populate-orders] ${status} #${i + 1}/${n} FAILED: ${message}`
        )
      }
    }
  }

  return result
}

type ResolvedContext = {
  customer: { id: string; email: string }
  shippingAddress: Record<string, unknown>
  region: { id: string; currency_code: string }
  salesChannelId: string
  shippingOptionId: string
  sellerHandle: string | null
  variantIds: string[]
  itemsPerOrder: number
}

async function resolveContext(
  container: MedusaContainer,
  opts: PopulateOptions
): Promise<ResolvedContext> {
  const query = container.resolve("query")

  // Customer + default shipping address
  const { data: customers } = await query.graph({
    entity: "customer",
    fields: [
      "id",
      "email",
      "addresses.id",
      "addresses.first_name",
      "addresses.last_name",
      "addresses.address_1",
      "addresses.address_2",
      "addresses.city",
      "addresses.country_code",
      "addresses.province",
      "addresses.postal_code",
      "addresses.phone",
      "addresses.is_default_shipping",
    ],
    filters: { email: opts.customer_email },
  })
  const customer = customers?.[0]
  if (!customer) {
    throw new Error(`No customer found with email ${opts.customer_email}`)
  }
  const addr =
    customer.addresses?.find((a: any) => a.is_default_shipping) ??
    customer.addresses?.[0]
  if (!addr) {
    throw new Error(
      `Customer ${opts.customer_email} has no addresses; populator needs a shipping address.`
    )
  }
  const shippingAddress = stripIdAndTimestamps(addr)

  // Region — explicit, or matched on the customer's country
  let region: { id: string; currency_code: string }
  if (opts.region_id) {
    const { data: regions } = await query.graph({
      entity: "region",
      fields: ["id", "currency_code"],
      filters: { id: opts.region_id },
    })
    if (!regions?.[0]) throw new Error(`Region ${opts.region_id} not found`)
    region = regions[0]
  } else {
    const { data: regions } = await query.graph({
      entity: "region",
      fields: ["id", "currency_code", "countries.iso_2"],
    })
    const matched = regions?.find((r: any) =>
      r.countries?.some((c: any) => c.iso_2 === addr.country_code)
    )
    if (!matched) {
      throw new Error(
        `No region matches customer country ${addr.country_code}; pass region_id explicitly.`
      )
    }
    region = { id: matched.id, currency_code: matched.currency_code }
  }

  // Sales channel — explicit, or first one
  let salesChannelId = opts.sales_channel_id
  if (!salesChannelId) {
    const { data: channels } = await query.graph({
      entity: "sales_channel",
      fields: ["id", "is_disabled"],
    })
    const enabled = channels?.find((c: any) => !c.is_disabled)
    if (!enabled) throw new Error("No enabled sales channel found")
    salesChannelId = enabled.id
  }

  // Resolve seller filter (defaults to Adidas Official). Pass empty string or
  // null to disable.
  const sellerHandle =
    opts.seller_handle === null || opts.seller_handle === ""
      ? null
      : (opts.seller_handle ?? DEFAULT_SELLER_HANDLE)

  // Variants in the chosen sales channel — sample up to 25 in-stock ones from
  // the chosen seller.
  const { data: products } = await query.graph({
    entity: "product",
    fields: [
      "id",
      "sales_channels.id",
      "seller.id",
      "seller.handle",
      "variants.id",
      "variants.manage_inventory",
      "variants.inventory_items.required_quantity",
      "variants.inventory_items.inventory.location_levels.available_quantity",
    ],
    filters: { status: "published" },
    pagination: { take: 200 },
  })
  const variantIds: string[] = []
  for (const p of products ?? []) {
    if (
      salesChannelId &&
      p.sales_channels?.length &&
      !p.sales_channels.some((c: any) => c.id === salesChannelId)
    ) {
      continue
    }
    if (sellerHandle && p.seller?.handle !== sellerHandle) {
      continue
    }
    for (const v of p.variants ?? []) {
      if (variantIds.length >= 25) break
      if (!v.manage_inventory) {
        variantIds.push(v.id)
        continue
      }
      const stocked = (v.inventory_items ?? []).every((ii: any) =>
        (ii.inventory?.location_levels ?? []).some(
          (l: any) => (l.available_quantity ?? 0) >= (ii.required_quantity ?? 1)
        )
      )
      if (stocked) variantIds.push(v.id)
    }
  }
  if (variantIds.length === 0) {
    const where = sellerHandle ? ` for seller "${sellerHandle}"` : ""
    throw new Error(
      `No in-stock variants found in the sales channel${where} — populator needs at least one purchasable variant.`
    )
  }

  // Shipping option for the region
  let shippingOptionId = opts.shipping_option_id
  if (!shippingOptionId) {
    const { data: options } = await query.graph({
      entity: "shipping_option",
      fields: ["id", "service_zone.fulfillment_set.location.id"],
      filters: { service_zone: { fulfillment_set: { type: "shipping" } } },
    })
    if (!options?.length) {
      throw new Error(
        "No shipping options found; configure one for the region or pass shipping_option_id."
      )
    }
    shippingOptionId = options[0].id
  }

  return {
    customer: { id: customer.id, email: customer.email! },
    shippingAddress,
    region,
    salesChannelId: salesChannelId!,
    shippingOptionId: shippingOptionId!,
    sellerHandle,
    variantIds,
    itemsPerOrder: Math.max(1, opts.items_per_order ?? 1),
  }
}

async function createOrderInStatus(
  container: MedusaContainer,
  ctx: ResolvedContext,
  status: StatusKey,
  index: number
): Promise<string> {
  // Pick variants for this order — rotate through the pool for variety.
  const items = pickVariants(ctx.variantIds, ctx.itemsPerOrder, index).map(
    (variant_id) => ({ variant_id, quantity: 1 })
  )

  // 1. Create cart
  const { result: cart } = await createCartWorkflow(container).run({
    input: {
      region_id: ctx.region.id,
      sales_channel_id: ctx.salesChannelId,
      customer_id: ctx.customer.id,
      email: ctx.customer.email,
      currency_code: ctx.region.currency_code,
      shipping_address: ctx.shippingAddress as any,
      billing_address: ctx.shippingAddress as any,
      items,
    },
  })

  // 2. Add shipping method
  await addShippingMethodToCartWorkflow(container).run({
    input: {
      cart_id: cart.id,
      options: [{ id: ctx.shippingOptionId }],
    },
  })

  // 3. Payment collection
  const { result: paymentCollection } =
    await createPaymentCollectionForCartWorkflow(container).run({
      input: { cart_id: cart.id },
    })

  // 4. Payment session against GCash so the resulting order's payment shows
  //    GCash as the chosen provider when it's still in to_pay.
  const { result: session } = await createPaymentSessionsWorkflow(
    container
  ).run({
    input: {
      payment_collection_id: paymentCollection.id,
      provider_id: PAYMENT_PROVIDER_ID,
    },
  })

  // 5. Authorize the GCash session. GCash sandbox returns a 'pending' session
  //    on authorize (it expects a customer redirect); a pending session lets
  //    completeCartWorkflow create a not_paid order, which is exactly what
  //    to_pay needs.
  const paymentModule: any = container.resolve(Modules.PAYMENT)
  await paymentModule.authorizePaymentSession(session.id, {})

  // 6. Complete cart -> order
  const { result: completed } = await completeCartWorkflow(container).run({
    input: { id: cart.id },
  })
  const orderId = (completed as any).id as string

  if (status === "to_pay") return orderId

  // 7. Mark payment as paid (uses pp_system_default internally — see top-of-file note).
  await markPaymentCollectionAsPaid(container).run({
    input: {
      order_id: orderId,
      payment_collection_id: paymentCollection.id,
    },
  })

  if (status === "to_ship") return orderId

  // 8. Fulfill + ship
  const orderItems = await fetchOrderItems(container, orderId)
  const fulfillmentItems = orderItems.map((i) => ({
    id: i.id,
    quantity: i.quantity,
  }))

  const { result: fulfillment } = await createOrderFulfillmentWorkflow(
    container
  ).run({
    input: { order_id: orderId, items: fulfillmentItems },
  })
  const fulfillmentId = (fulfillment as any).id as string

  await createOrderShipmentWorkflow(container).run({
    input: {
      order_id: orderId,
      fulfillment_id: fulfillmentId,
      items: fulfillmentItems,
    },
  })

  if (status === "to_receive") return orderId

  // 9. Mark delivered (note camelCase keys for this workflow's input).
  await markOrderFulfillmentAsDeliveredWorkflow(container).run({
    input: { orderId, fulfillmentId },
  })

  return orderId
}

async function fetchOrderItems(
  container: MedusaContainer,
  orderId: string
): Promise<Array<{ id: string; quantity: number }>> {
  const query = container.resolve("query")
  const { data } = await query.graph({
    entity: "order",
    fields: ["id", "items.id", "items.quantity"],
    filters: { id: orderId },
  })
  const order = data?.[0]
  if (!order?.items?.length) {
    throw new Error(`Order ${orderId} has no items`)
  }
  return order.items.map((i: any) => ({ id: i.id, quantity: i.quantity }))
}

function pickVariants(pool: string[], n: number, seedIndex: number): string[] {
  const out: string[] = []
  for (let k = 0; k < n; k++) {
    out.push(pool[(seedIndex + k) % pool.length])
  }
  return out
}

function stripIdAndTimestamps(addr: any): Record<string, unknown> {
  const {
    id,
    customer_id,
    created_at,
    updated_at,
    deleted_at,
    is_default_shipping,
    is_default_billing,
    address_name,
    ...rest
  } = addr ?? {}
  return rest
}

function resolveLogger(container: MedusaContainer): {
  info: (m: string) => void
  error: (m: string) => void
} {
  try {
    const logger: any = container.resolve("logger")
    return {
      info: (m) => logger.info(m),
      error: (m) => logger.error(m),
    }
  } catch {
    return { info: console.log, error: console.error }
  }
}
