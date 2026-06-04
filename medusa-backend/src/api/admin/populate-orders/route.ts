// POST /admin/populate-orders
//
// Body:
//   {
//     "customer_email": "qa@example.com",
//     "counts": { "to_pay": 2, "to_ship": 1, "to_receive": 1, "to_rate": 1 },
//     "region_id": "reg_...",            // optional
//     "sales_channel_id": "sc_...",      // optional
//     "shipping_option_id": "so_...",    // optional
//     "items_per_order": 1                // optional
//   }
//
// Auth: standard Medusa admin (Bearer admin JWT or x-medusa-access-token API key
// — whichever your /admin auth is configured for). The route lives under /admin
// so Medusa's admin auth middleware applies automatically.

import type {
  MedusaRequest,
  MedusaResponse,
} from "@medusajs/framework/http"
import {
  populateOrdersByStatus,
  STATUS_KEYS,
  type StatusKey,
} from "../../../lib/populate-orders"

type Body = {
  customer_email?: unknown
  counts?: unknown
  region_id?: unknown
  sales_channel_id?: unknown
  shipping_option_id?: unknown
  seller_handle?: unknown
  items_per_order?: unknown
}

export async function POST(req: MedusaRequest, res: MedusaResponse) {
  const body = (req.body ?? {}) as Body

  const customer_email = body.customer_email
  if (typeof customer_email !== "string" || !customer_email.includes("@")) {
    return res
      .status(400)
      .json({ error: "customer_email (string, must be an email) is required" })
  }

  const rawCounts = body.counts
  if (!rawCounts || typeof rawCounts !== "object") {
    return res
      .status(400)
      .json({ error: "counts (object with to_pay/to_ship/to_receive/to_rate) is required" })
  }

  const counts: Partial<Record<StatusKey, number>> = {}
  for (const k of STATUS_KEYS) {
    const v = (rawCounts as Record<string, unknown>)[k]
    if (v === undefined) continue
    if (typeof v !== "number" || !Number.isInteger(v) || v < 0) {
      return res
        .status(400)
        .json({ error: `counts.${k} must be a non-negative integer` })
    }
    counts[k] = v
  }
  if (Object.keys(counts).length === 0) {
    return res
      .status(400)
      .json({ error: "At least one of counts.to_pay/to_ship/to_receive/to_rate must be set" })
  }

  const total = Object.values(counts).reduce((a, b) => a + (b ?? 0), 0)
  if (total > 50) {
    return res
      .status(400)
      .json({ error: `total order count ${total} exceeds the per-request cap of 50` })
  }

  // seller_handle: omit -> defaults to "adidas-official"; null/empty -> disable.
  let seller_handle: string | null | undefined
  if (body.seller_handle === null || body.seller_handle === "") {
    seller_handle = null
  } else if (typeof body.seller_handle === "string") {
    seller_handle = body.seller_handle
  }

  const opts = {
    customer_email,
    counts,
    region_id:
      typeof body.region_id === "string" ? body.region_id : undefined,
    sales_channel_id:
      typeof body.sales_channel_id === "string"
        ? body.sales_channel_id
        : undefined,
    shipping_option_id:
      typeof body.shipping_option_id === "string"
        ? body.shipping_option_id
        : undefined,
    seller_handle,
    items_per_order:
      typeof body.items_per_order === "number"
        ? body.items_per_order
        : undefined,
  }

  try {
    const result = await populateOrdersByStatus(req.scope, opts)
    const status = result.errors.length ? 207 : 200
    return res.status(status).json(result)
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e)
    return res.status(500).json({ error: message })
  }
}
