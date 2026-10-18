#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/check-foundation.mjs
node --test scripts/check-foundation.test.mjs
node scripts/prepare-client.mjs
swift test --scratch-path "${DAD_SWIFT_BUILD:-/tmp/dad-ios-swift}" --force-resolved-versions
device="${DAD_SIMULATOR_ID:-$(node scripts/simulator.mjs)}"
xcodebuild -project DAD.xcodeproj -scheme DAD -destination "platform=iOS Simulator,id=$device" \
  -derivedDataPath "${DAD_XCODE_BUILD:-/tmp/dad-ios-xcode}" -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ARCHS="$(uname -m)" test
