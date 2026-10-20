#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift test --package-path Packages/TrackglassKit
swift test --package-path Packages/TrackglassEngine
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac -destination 'platform=macOS' test
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOS -destination "${TG_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}" test
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOS -destination 'generic/platform=iOS' build
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac -configuration Debug build
xcodebuild -project Trackglass.xcodeproj -scheme tgreplay -destination 'platform=macOS' build
xcodebuild -project Trackglass.xcodeproj -scheme tgaccel -destination 'platform=macOS' build
