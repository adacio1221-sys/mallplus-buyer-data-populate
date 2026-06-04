// Run via:
//   npx medusa exec src/scripts/orders/create-order-by-status.ts \
//     <email> <to_pay> <to_ship> <to_receive> <to_rate> [seller_handle]
//
// Examples:
//   npx medusa exec src/scripts/orders/create-order-by-status.ts \
//     adacio1221@gmail.com 1 1 1 1
//
//   npx medusa exec src/scripts/orders/create-order-by-status.ts \
//     qa@example.com 2 0 0 0 mercurjs
//
// Notes:
//   - Counts are required positional ints. Use 0 to skip a status.
//   - seller_handle defaults to "adidas-official". Pass "-" or "any" to disable
//     the filter and pull from any seller.
//   - The medusa CLI uses yargs strict mode, so we *cannot* use `--flag`
//     syntax here — positional args only.

import { ExecArgs } from "@medusajs/framework/types"
import {
  populateOrdersByStatus,
  STATUS_KEYS,
  type StatusKey,
} from "../../lib/populate-orders"

export default async function ({ container, args }: ExecArgs) {
  const opts = parseArgs(args ?? [])
  const result = await populateOrdersByStatus(container, opts)

  console.log("\n=== populate-orders result ===")
  for (const k of STATUS_KEYS) {
    console.log(`${k}: ${result[k].length}`, result[k])
  }
  if (result.errors.length) {
    console.log("errors:")
    for (const e of result.errors) {
      console.log(`  - ${e.status} #${e.index}: ${e.message}`)
    }
    process.exitCode = 1
  }
}

function parseArgs(args: string[]) {
  if (args.length < 5) {
    throw new Error(
      "Usage: <email> <to_pay> <to_ship> <to_receive> <to_rate> [seller_handle]"
    )
  }
  const [email, ...countStrs] = args
  if (!email.includes("@")) {
    throw new Error(`First positional must be an email; got "${email}"`)
  }

  const counts: Partial<Record<StatusKey, number>> = {}
  for (let i = 0; i < STATUS_KEYS.length; i++) {
    const raw = countStrs[i]
    const n = Number(raw)
    if (!Number.isInteger(n) || n < 0) {
      throw new Error(
        `Count for ${STATUS_KEYS[i]} must be a non-negative integer (got "${raw}")`
      )
    }
    counts[STATUS_KEYS[i]] = n
  }
  if (Object.values(counts).every((n) => !n)) {
    throw new Error("All counts are zero — nothing to do.")
  }

  const sellerArg = countStrs[STATUS_KEYS.length]
  let seller_handle: string | null | undefined
  if (sellerArg !== undefined) {
    seller_handle =
      sellerArg === "-" || sellerArg.toLowerCase() === "any" ? null : sellerArg
  }

  return { customer_email: email, counts, seller_handle }
}
