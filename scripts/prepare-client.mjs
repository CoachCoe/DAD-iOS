import { copyFile, mkdir, readFile } from "node:fs/promises";
import { verifyFoundation } from "./check-foundation.mjs";
await verifyFoundation(process.cwd());
await mkdir("Sources/DADFoundation", { recursive: true });
for (const [source, target] of [["mobile.openapi.json", "openapi.json"], ["DADTokens.swift", "DADTokens.swift"], ["links.json", "links.json"]]) {
  await copyFile(`contracts/foundation/${source}`, `Sources/DADFoundation/${target}`);
}
const config = await readFile("Sources/DADFoundation/openapi-generator-config.yaml", "utf8");
if (!config.includes("operations:")) throw new Error("Client scope must be explicit");
