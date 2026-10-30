import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";

// Advisory drift check: compares the vendored mobile-foundation version (foundation.lock.json)
// against the newest `mobile-foundation-vX.Y.Z` tag published by DAD-Main, and reports how far
// behind this app is. It NEVER fetches or vendors anything — re-vendoring stays a deliberate,
// hash-verified step (scripts/prepare-client.mjs + check-foundation.mjs). The point is only to
// surface the "re-vendor wall" at a phase boundary instead of discovering it mid-build.
//
// Policy (semantic versioning — the bundle is additive within a major):
//   - same version                       -> up to date (silent OK)
//   - behind by a MINOR or PATCH          -> WARN, exit 0 (additive; adopt when a phase needs it)
//   - behind by a MAJOR                   -> FAIL, exit 1 (a breaking contract change is unadopted)
//   - remote tags unreachable / no tags   -> WARN, exit 0 (advisory; a network blip must not break CI)

const SOURCE = "CoachCoe/DAD-Main";
const run = promisify(execFile);

const parse = (v) => {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(v);
  return m ? { major: +m[1], minor: +m[2], patch: +m[3] } : null;
};

// -1 if a < b, 0 if equal, 1 if a > b.
const cmp = (a, b) =>
  a.major - b.major || a.minor - b.minor || a.patch - b.patch;

// Returns the newest mobile-foundation-vX.Y.Z version string from the public remote, or null when
// the remote is unreachable or exposes no such tag. No auth token required (public repo).
export async function latestPublishedVersion(sourceRepository = SOURCE) {
  let stdout;
  try {
    ({ stdout } = await run("git", [
      "ls-remote", "--tags", "--refs",
      `https://github.com/${sourceRepository}`,
      "mobile-foundation-v*",
    ], { timeout: 15000 }));
  } catch {
    return null; // unreachable — treat as advisory-unavailable, never a hard failure
  }
  const versions = stdout
    .split("\n")
    .map((line) => /refs\/tags\/mobile-foundation-v(\d+\.\d+\.\d+)$/.exec(line.trim()))
    .filter(Boolean)
    .map((m) => m[1])
    .map(parse)
    .filter(Boolean);
  if (versions.length === 0) return null;
  return versions.reduce((best, v) => (cmp(v, best) > 0 ? v : best));
}

// Pure decision function (testable without the network): given the pinned version and the latest
// published version (or null), return { level: "ok"|"warn"|"fail", message }.
export function assess(pinnedVersion, latest) {
  const pinned = parse(pinnedVersion);
  if (!pinned) return { level: "fail", message: `Invalid pinned version: ${pinnedVersion}` };
  if (!latest) {
    return { level: "warn", message: `Could not read ${SOURCE} mobile-foundation tags; skipping drift check (pinned ${pinnedVersion}).` };
  }
  const c = cmp(pinned, latest);
  const l = `${latest.major}.${latest.minor}.${latest.patch}`;
  if (c >= 0) return { level: "ok", message: `mobile-foundation ${pinnedVersion} is up to date (latest ${l}).` };
  if (latest.major > pinned.major) {
    return { level: "fail", message: `BREAKING: pinned mobile-foundation ${pinnedVersion} is a MAJOR behind latest ${l}. A breaking contract change has not been adopted — re-vendor and fix before relying on this build.` };
  }
  return { level: "warn", message: `mobile-foundation ${pinnedVersion} is behind latest ${l} (additive). Re-vendor when a phase needs the new endpoints.` };
}

export async function checkDrift(root) {
  const lock = JSON.parse(await readFile(resolve(root, "foundation.lock.json"), "utf8"));
  const latest = await latestPublishedVersion(lock.source_repository);
  return assess(lock.version, latest);
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  const { level, message } = await checkDrift(resolve(dirname(fileURLToPath(import.meta.url)), ".."));
  if (level === "fail") { console.error(`drift: ${message}`); process.exitCode = 1; }
  else if (level === "warn") { console.warn(`drift (advisory): ${message}`); }
  else { console.log(`drift: ${message}`); }
}
