#!/bin/bash
# Full verification (CLAUDE.md "Build commands"). Environment knobs:
#   TG_IOS_TEST_DESTINATION   simulator destination (default: platform=iOS Simulator,name=iPhone 17)
#   TG_CI_UNSIGNED=1          build without code signing (hosted CI runners have no team or certificate)
set -euo pipefail
cd "$(dirname "$0")/.."

SIGNING=()
IOS_TEST_SKIPS=()
if [[ "${TG_CI_UNSIGNED:-0}" == 1 ]]; then
  SIGNING=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="")
  # The data-protection Keychain refuses an unsigned host (-34018 errSecMissingEntitlement: no
  # keychain-access-groups), so the Keychain-backed PairingStore tests run only on the signed Mac.
  IOS_TEST_SKIPS=(-skip-testing:TrackglassiOSTests/PairingStoreTests)
fi
# bash 3.2 (macOS) trips `set -u` on an empty array expansion; use the ${arr[@]+"${arr[@]}"} idiom.
xcb() { xcodebuild "$@" ${SIGNING[@]+"${SIGNING[@]}"}; }

swift test --package-path Packages/TrackglassKit
swift test --package-path Packages/TrackglassEngine
if [[ "${TG_CI_UNSIGNED:-0}" == 1 ]]; then
  # The Mac-hosted bundle needs the data-protection Keychain (keychain-access-groups), which an unsigned
  # build cannot use; those tests stay on the signed release Mac. The Mac app is still built below.
  echo "TG_CI_UNSIGNED=1: skipping TrackglassMacTests (requires a signed host app)"
else
  xcb -project Trackglass.xcodeproj -scheme TrackglassMac -destination 'platform=macOS' test
fi
xcb -project Trackglass.xcodeproj -scheme TrackglassiOS -destination "${TG_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}" \
  ${IOS_TEST_SKIPS[@]+"${IOS_TEST_SKIPS[@]}"} test
xcb -project Trackglass.xcodeproj -scheme TrackglassiOS -destination 'generic/platform=iOS' build
xcb -project Trackglass.xcodeproj -scheme TrackglassMac -configuration Debug build
TRACKGLASS_REPLAY_DERIVED_DATA="${TMPDIR:-/tmp}/trackglass-replay-ci"
xcb -project Trackglass.xcodeproj -scheme tgreplay -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$TRACKGLASS_REPLAY_DERIVED_DATA" build
"$TRACKGLASS_REPLAY_DERIVED_DATA/Build/Products/Debug/tgreplay" verify-dir Tests/Fixtures
Scripts/invariants.sh "$TRACKGLASS_REPLAY_DERIVED_DATA/Build/Products/Debug/tgreplay" 0.05 20
xcb -project Trackglass.xcodeproj -scheme tgaccel -destination 'platform=macOS' build
