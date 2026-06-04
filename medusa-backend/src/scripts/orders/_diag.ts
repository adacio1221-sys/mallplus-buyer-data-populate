import { ExecArgs } from "@medusajs/framework/types"
import { Modules } from "@medusajs/framework/utils"

export default async function ({ container }: ExecArgs) {
  const query: any = container.resolve("query")

  console.log("--- via query.graph filter email ---")
  const r1 = await query.graph({
    entity: "customer",
    fields: ["id", "email"],
    filters: { email: "adacio1221@gmail.com" },
  })
  console.log("count:", r1.data?.length, r1.data?.slice(0, 3))

  console.log("--- via query.graph filter has_account ---")
  const r2 = await query.graph({
    entity: "customer",
    fields: ["id", "email", "has_account"],
    pagination: { take: 5 },
  })
  console.log("count:", r2.data?.length)
  console.log("first 5:", r2.data?.slice(0, 5))

  console.log("--- via Modules.CUSTOMER service ---")
  const customerService: any = container.resolve(Modules.CUSTOMER)
  const list = await customerService.listCustomers(
    { email: "adacio1221@gmail.com" },
    { take: 5 }
  )
  console.log("count:", list?.length, list?.slice(0, 3))
}
