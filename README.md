# DAD iOS

Mobile integration foundation for DAD. The application implementation stack and final feature subset are pending; this repository currently pins the shared interfaces without selecting a framework.

Run `node scripts/check-foundation.mjs` with Node 24. CI verifies the pinned bundle without fetching DAD-Main, credentials, or a moving branch.

`foundation.lock.json` pins the release, source revision, and manifest SHA-256. `contracts/foundation/` vendors the canonical API, derived native API, shared tokens in JSON/TypeScript/Swift/Kotlin, link rules, and their checksums. Generated token files are intentional dependency snapshots, never hand-edited. Client generation is selected with the app stack.

DAD-Main owns business rules and interface releases. Read [the shared foundation contract](https://github.com/CoachCoe/DAD-Main/blob/5e237101c0ad81aa4675d16a94eb64863c5276b9/docs/mobile-foundation.md) before implementing sessions, deep links, networking, or platform adapters. It records the Apple generator null-schema limitation.

## Dependency updates

Download an explicit release using `gh release download RELEASE_TAG --repo CoachCoe/DAD-Main --dir /tmp/dad-foundation-update`. Review changes and source provenance, verify hashes, replace the vendored files, and update the lock in the same commit. Never regenerate from latest/dev during builds. CI detects changed contracts, tokens, link rules, and lock mismatches.
