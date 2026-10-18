// Prints the UDID of an available iPhone simulator on the last-listed iOS runtime.
import { execFileSync } from "node:child_process";

const { devices } = JSON.parse(
  execFileSync("xcrun", ["simctl", "list", "devices", "available", "--json"], { encoding: "utf8" }),
);
const iphone = Object.entries(devices)
  .filter(([runtime]) => runtime.includes("iOS"))
  .reverse()
  .flatMap(([, list]) => list)
  .find((device) => device.name.startsWith("iPhone") && device.isAvailable);
if (!iphone) {
  console.error("No available iPhone simulator");
  process.exit(1);
}
process.stdout.write(iphone.udid);
