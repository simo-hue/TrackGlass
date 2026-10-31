# Trackglass

Your iPhone or iPad as a wireless trackpad for your Mac — pointer, clicks, scrolling, pinch, rotate and the same multi-finger gestures your Mac's trackpad has, mirroring your Mac's own Trackpad settings.

[**Download for Mac**](https://github.com/simo-hue/TrackGlass/releases/latest) · [Website](https://simo-hue.github.io/TrackGlass) · [Support](https://simo-hue.github.io/TrackGlass/support.html) · [Privacy](https://simo-hue.github.io/TrackGlass/privacy.html)

The iPhone/iPad app is distributed through the App Store (link on the website once it is live); the Mac companion, Trackglass for Mac, is a free download from GitHub Releases, signed by the developer and notarized by Apple, that updates itself.

## Requirements

- iPhone or iPad with iOS/iPadOS 17 or later (120 Hz displays get the smoothest tracking).
- Mac with macOS 14 Sonoma or later, Apple silicon or Intel.
- Both devices on the same Wi-Fi network. Touch data travels only between your devices, encrypted; the only other connection is the Mac app's daily update check (it reads the update feed from raw.githubusercontent.com and downloads updates from github.com).

## Setup

1. Install Trackglass for Mac from the download above, open it and allow **Accessibility** when the Welcome window asks (it is what lets the app move the pointer). On macOS 15 or later, also allow **Local Network** access when macOS asks.
2. Install Trackglass on your iPhone or iPad, follow the onboarding and allow **Local Network** access when iOS asks.
3. In the Mac's menu bar icon choose **Pair a device…** and scan the QR code in Trackglass on the phone (or click *Use a code instead* on the Mac, tap *Pair with a code* on the phone, choose the Mac and check that both screens show the same six digits, then tap *Matches*).
4. Click **Allow** on the Mac to accept the pairing.
5. Touch the surface: your Mac's pointer follows. Clicks, drags, scrolling and gestures work like they do on the Mac's trackpad, using the settings in System Settings → Trackpad (on macOS 27, Spaces, Mission Control and the other Dock gestures switch when you lift your fingers instead of following them live).

The manual install path and troubleshooting are in [docs/Install.md](docs/Install.md).

## Developers

Trackglass is open source. The product and technical specification is [docs/SPEC.md](docs/SPEC.md), the build order is [docs/PLAN.md](docs/PLAN.md), and progress is tracked in [docs/PROGRESS.md](docs/PROGRESS.md).

```bash
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then set DEVELOPMENT_TEAM (never committed)
xcodegen generate                                        # edit project.yml, never the .xcodeproj
Scripts/ci.sh                                            # package tests, hosted tests, builds, fixture replay, loss invariants
```

The individual steps `Scripts/ci.sh` runs (SPEC §2.5):

```bash
swift test --package-path Packages/TrackglassKit
swift test --package-path Packages/TrackglassEngine
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac -destination 'platform=macOS' test                       # TrackglassMacTests (incl. InjectorTests)
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOS -destination 'platform=iOS Simulator,name=iPhone 17' test  # TrackglassiOSTests
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOS -destination 'generic/platform=iOS' build
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac -configuration Debug build
```

Xcode 27.1 or later (the toolchain baseline in `docs/SPEC.md`; macOS 14 and iOS 17 deployment targets) with Swift 6 and strict concurrency. `TrackglassKit` (protocol, pairing, transport) and `TrackglassEngine` (gesture engine, acceleration) are Swift packages with warnings treated as errors; the apps are generated from `project.yml` by XcodeGen. Device installs: `xcrun devicectl list devices` then `xcrun devicectl device install app --device <id> <path.app>`. Releases of the Mac app are cut with `Scripts/release-mac.sh <version>` (see `Releases/README.md`).

Licensed under the [Apache License 2.0](LICENSE). Third-party notices: [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md).
