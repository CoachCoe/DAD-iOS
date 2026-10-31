import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { verifyFoundation } from "./check-foundation.mjs";
await verifyFoundation(process.cwd());
await mkdir("Sources/DADFoundation", { recursive: true });
for (const [source, target] of [["swift.openapi.json", "openapi.json"], ["DADNullValue.swift", "DADNullValue.swift"], ["DADTokens.swift", "DADTokens.swift"], ["links.json", "links.json"]]) {
  await copyFile(`contracts/foundation/${source}`, `Sources/DADFoundation/${target}`);
}
// Problem.code is an open set: a newer server may add values, and a generated Swift enum would fail
// the whole response decode on an unknown one. Generate it as a plain string instead.
const spec = JSON.parse(await readFile("Sources/DADFoundation/openapi.json", "utf8"));
const code = spec.components?.schemas?.Problem?.properties?.code;
if (!code?.enum) throw new Error("Problem.code enum not found");
delete code.enum;
// Subscription.status mirrors Stripe's open set (paused, trialing, ... may appear): same treatment. The
// enum is declared on Subscription and again inline where RecurringDetails embeds it, so strip every copy.
let stripped = 0;
const strip = (node) => {
  if (Array.isArray(node)) return node.forEach(strip);
  if (node === null || typeof node !== "object") return;
  const status = node.properties?.status;
  if (status?.enum?.includes("incomplete_expired")) { delete status.enum; stripped += 1; }
  Object.values(node).forEach(strip);
};
strip(spec.components.schemas);
if (stripped < 1) throw new Error("Subscription.status enum not found");
await writeFile("Sources/DADFoundation/openapi.json", `${JSON.stringify(spec, null, 2)}\n`);
const config = await readFile("Sources/DADFoundation/openapi-generator-config.yaml", "utf8");
if (!config.includes("operations:")) throw new Error("Client scope must be explicit");
