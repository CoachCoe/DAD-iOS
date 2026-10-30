import assert from "node:assert/strict";
import { test } from "node:test";
import { assess } from "./check-foundation-drift.mjs";

const v = (major, minor, patch) => ({ major, minor, patch });

test("up to date is ok", () => {
  assert.equal(assess("2.2.0", v(2, 2, 0)).level, "ok");
});

test("pinned ahead of latest is ok (never a failure)", () => {
  assert.equal(assess("2.3.0", v(2, 2, 0)).level, "ok");
});

test("behind by a minor warns, does not fail", () => {
  const r = assess("2.0.0", v(2, 2, 0));
  assert.equal(r.level, "warn");
  assert.match(r.message, /additive/);
});

test("behind by a patch warns", () => {
  assert.equal(assess("2.2.0", v(2, 2, 3)).level, "warn");
});

test("behind by a major fails", () => {
  const r = assess("2.2.0", v(3, 0, 0));
  assert.equal(r.level, "fail");
  assert.match(r.message, /BREAKING/);
});

test("unreachable remote (null latest) warns, never fails", () => {
  const r = assess("2.0.0", null);
  assert.equal(r.level, "warn");
  assert.match(r.message, /skipping drift check/);
});

test("invalid pinned version fails", () => {
  assert.equal(assess("not-a-version", v(2, 2, 0)).level, "fail");
});
