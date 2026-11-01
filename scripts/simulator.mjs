// Prints the UDID of an available iPhone simulator on the last-listed iOS runtime.
// `--create <name>` instead creates a new simulator of that model and runtime and prints its UDID, so a
// CI job on a shared Mac tests on a device no local run is using (delete it with `xcrun simctl delete`).
import { execFileSync } from "node:child_process";

const { devices } = JSON.parse(
  execFileSync("xcrun", ["simctl", "list", "devices", "available", "--json"], { encoding: "utf8" }),
);
const found = Object.entries(devices)
  .filter(([runtime]) => runtime.includes("iOS"))
  .reverse()
  .flatMap(([runtime, list]) => list.map((device) => ({ runtime, device })))
  .find(({ device }) => device.name.startsWith("iPhone") && device.isAvailable);
if (!found) {
  console.error("No available iPhone simulator");
  process.exit(1);
}
const create = process.argv.indexOf("--create");
if (create === -1) {
  process.stdout.write(found.device.udid);
} else {
  const name = process.argv[create + 1];
  if (!name) {
    console.error("--create needs a simulator name");
    process.exit(1);
  }
  const udid = execFileSync("xcrun", ["simctl", "create", name, found.device.deviceTypeIdentifier, found.runtime], {
    encoding: "utf8",
  }).trim();
  process.stdout.write(udid);
}
