#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift test --package-path Packages/TrackglassKit
swift test --package-path Packages/TrackglassEngine
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac -destination 'platform=macOS' test
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOS -destination "${TG_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}" test
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOS -destination 'generic/platform=iOS' build
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac -configuration Debug build
TRACKGLASS_REPLAY_DERIVED_DATA="${TMPDIR:-/tmp}/trackglass-replay-ci"
xcodebuild -project Trackglass.xcodeproj -scheme tgreplay -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$TRACKGLASS_REPLAY_DERIVED_DATA" build
"$TRACKGLASS_REPLAY_DERIVED_DATA/Build/Products/Debug/tgreplay" verify-dir Tests/Fixtures
Scripts/invariants.sh "$TRACKGLASS_REPLAY_DERIVED_DATA/Build/Products/Debug/tgreplay" 0.05 20
xcodebuild -project Trackglass.xcodeproj -scheme tgaccel -destination 'platform=macOS' build
