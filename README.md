# DAD iOS

SwiftUI donor-app foundation backed by DAD-Main's Go API. The native implementation
was selected on 18 October 2026, superseding the earlier cross-platform plan. The final
feature subset and navigation still require the mobile PRD.

## Build and test

Requires Xcode 27+, its iOS Simulator runtime, Swift 6.2+, and Node 24. No Apple team,
production certificate, or signing key is required for simulator builds.

```sh
node scripts/prepare-client.mjs
open DAD.xcodeproj
```

Select the shared DAD scheme and an iPhone simulator. The default app uses a clearly
labeled synthetic account through the same session API as a configured deployment.
Run `bash scripts/check-ios.sh` for contract verification, Swift unit tests, and simulator
journeys. `DAD_SIMULATOR_ID`, `DAD_SWIFT_BUILD`, and `DAD_XCODE_BUILD` override the simulator
and disposable build paths. Unit tests alone: `swift test --scratch-path /tmp/dad-ios-swift`.

CI executes that same script. The pinned Apple generator plugin is trusted explicitly
with `-skipPackagePluginValidation`; compilation and tests remain enabled. Xcode's benign
AppIntents metadata-extraction diagnostic is not suppressed; this app defines no intents.

## Shared contract and native boundaries

`foundation.lock.json` pins mobile foundation 2.0.0 and its manifest digest. The vendored
release is verified before generation. `prepare-client.mjs` copies the Swift generator input, null-only Codable adapter, tokens,
and link policy into ignored generator inputs. Apple's pinned Swift generator produces
types and a client during the build, scoped to profile, claim, refresh, and logout.
Generated files are not hand-edited or separately maintained. Dependency revisions are
locked in `Package.resolved` and the Xcode workspace's SwiftPM lock.

`AccountSession` owns one shared refresh operation, atomic credential replacement,
revocation, bounded read retry, and logout/account-switch race protection. Keychain uses
non-synchronizing `WhenUnlockedThisDeviceOnly` items. Tokens and proofs are redacted from
value descriptions; they are never logged. URLSession rejects redirects, sends no
browser cookies or Origin, limits responses to 1 MiB, and has request/resource timeouts.
Canceling a read does not cancel another caller's shared refresh. An in-flight refresh
can finish after local logout so remote logout uses the newest known access token;
its result cannot restore local credentials. Offline remote logout can fail after local
cleanup; errors propagate rather than claiming a confirmed remote revocation.

Set Xcode build settings `DAD_API_ORIGIN` and `DAD_PUBLIC_ORIGIN` to the direct HTTPS API
origin and public website origin for a real environment. No production hostname or secret
is compiled by default. An existing live session can read the profile; a plain account
claim link can establish one. UI sign-in forms/passkeys are PRD work. Native entry hooks
handle cold/foreground URLs through the origin/path policy. Profile destinations can
wait for sign-in. Email-change, referral, and other unimplemented destinations use the
website in Safari, without sending bearer credentials. Claim links with a web-only next
destination stay on the web before their one-use proof is consumed.

System universal links/passkeys require a final bundle ID, signing team, Associated
Domains (`applinks:` and `webcredentials:`), and matching DAD-Main association files.
The preview ID `org.dad.foundation.preview` is not a registered production identity.
Camera, push registration, and Wallet have integration protocols; this foundation does
not request those permissions or configure provider accounts. A reachable staging API
and real-device/provider acceptance remain separate from synthetic tests.

The version 2 Swift input preserves nullable dashboard, recurring, and event values
without the generator's standalone-null omissions. The canonical API schemas remain
in the release unchanged. Apps expanding into payment updates must add the
`DADLiteralNull: DADNullValue` generator type override, as the DAD-Main probe does;
the bundled Codable adapter rejects any non-null completed-payment URL. Keep response
compatibility tests when adding operations. Go continues to compute account figures.

## Contract updates

Download an explicit `mobile-foundation-vX.Y.Z` release from `CoachCoe/DAD-Main`, review
its source and changes, then replace the vendored snapshot and lock together. Never
fetch a moving branch during builds. `node scripts/check-foundation.mjs` verifies every
file hash, source revision, and version; its tests demonstrate tamper detection.

## Real backend acceptance

From the matching DAD-Main checkout, run `make test-native-clients` with
`TEST_DATABASE_URL` naming its migrated synthetic `donor_go` database. Override
`DAD_IOS_DIR` and `DAD_ANDROID_DIR` when the checkouts are elsewhere. This opt-in
suite exercises the actual generated client and session store against a loopback
HTTPS Go API: claim/profile, expired-access refresh and credential replacement,
revocation cleanup, and logout. Test-only transports trust the temporary server's
certificate; production TLS settings are unchanged. No provider credentials are used.
The test runner removes the private proof fixtures after either success or failure.
