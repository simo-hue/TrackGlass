# Trackglass

Trackglass turns an iPhone or iPad into a trackpad for a Mac. Implementation follows [the specification](docs/SPEC.md) and [the step-by-step plan](docs/PLAN.md); see [progress](docs/PROGRESS.md) for completed work.

## Development setup

Use Xcode 27.1, Swift 6, and an Apple Developer account configured in Xcode. Deployment targets are iOS/iPadOS 17 and macOS 14.

```bash
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Set `DEVELOPMENT_TEAM` in `Config/Local.xcconfig` to your Apple Developer Team ID. This file is ignored by Git. Never commit signing credentials or provisioning profiles. Development signing is automatic; initial provisioning may require `-allowProvisioningUpdates` on an Xcode build.

```bash
xcodegen generate
```

Edit `project.yml`, never the generated `.xcodeproj`. Regenerate after changing targets or project settings.

## Build and test

```bash
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOS -destination 'generic/platform=iOS' build
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac -configuration Debug build
swift test --package-path Packages/TrackglassKit
swift test --package-path Packages/TrackglassEngine
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac -destination 'platform=macOS' test
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOS -destination 'platform=iOS Simulator,name=iPhone 17' test
Scripts/ci.sh
```

CI runs both package test suites, both app-hosted test bundles, both app builds, and the `tgreplay` and `tgaccel` command-line builds. Packages treat warnings as errors. Injector tests skip when the Mac app lacks Accessibility permission. An installed iPhone 17 simulator is required by default; use `TG_IOS_TEST_DESTINATION` to choose another installed simulator.

The Mac app enables Hardened Runtime and disables App Sandbox. Release signing will use Developer ID Application for Mac and App Store distribution for iOS. DriverKit targets are deferred until Phase 2 gates pass.

## Device installation

```bash
xcrun devicectl list devices
xcrun devicectl device install app --device <device-id> <path-to-TrackglassiOS.app>
open <path-to-TrackglassMac.app>
```

Connect and unlock the device, trust the Mac, and enable Developer Mode if Xcode requests it. Each manual test is confirmed by the owner before that step is committed.

## Third-party notices

See [THIRD-PARTY.md](docs/THIRD-PARTY.md). Reference projects are read for facts only; their implementation code is not copied.
