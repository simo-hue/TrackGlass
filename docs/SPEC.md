# Trackglass — Implementation Specification (docs/SPEC.md)

**Turn an iPhone or iPad into a Magic-Trackpad-class input device for a Mac.**

| | |
|---|---|
| Spec version | 1.0 — 2026-10-20 |
| Audience | The coding agent that implements this product in Swift. Nothing in this document is a suggestion; every decision below has already been made. |
| Toolchain baseline | Xcode 27.1 (27A9275), Swift 6 language mode, iOS/iPadOS 27 SDK, macOS 27 SDK |
| Deployment targets | iOS 17.0 / iPadOS 17.0 · macOS 14.0 (Sonoma) |
| Distribution | iOS app: App Store, free, no in-app purchases. Mac companion: Developer ID–signed, notarized, direct download, Sparkle auto-update. **Not** the Mac App Store. |
| Product name | **Trackglass** (iOS) · **Trackglass for Mac** (companion). No exact-name collision on the App Store at spec time; the owner must run a trademark check before publishing. |
| Bundle ID prefix | `app.trackglass` — see §1.5 for the complete identifier table |

---

## 0. How to use this document

0.1 **Read §1–§4 completely before writing any code.** They define the product, the architecture, the shared protocol and the naming. §5–§8 are the per-component specs. §9 lists the milestones; the step-by-step build order is `docs/PLAN.md`. §10 is testing. §11–§12 are release and Phase 2. Appendices hold constants and references.

0.2 **Decisions are final.** Where this spec says "Decision:", implement exactly that. Where it says "Tunable:", the value is the starting point and §10 defines the calibration procedure and acceptance test that decides the final value. Where it says "Gate:", you must stop, run the check, and branch according to the stated outcome. Do not invent a third option.

0.3 **Verification is part of every step.** Every step in `docs/PLAN.md` has a test and every milestone in §9 has exit criteria. A milestone is not done until its criteria pass on real hardware (an iPhone with a 120 Hz display and a Mac with a built-in trackpad are the reference devices; an iPad is the secondary device).

0.4 **Reference code is for facts, never for copying.** You will be pointed at three third-party codebases for undocumented numeric constants and mechanisms: Mac Mouse Fix (custom "MMF License", not permissive), VoodooInput (GPL-2.0), and Calf Trail's Touch (GPL-2.0). You may read them to learn constants and sequences. You must write all Trackglass code from scratch. Apple's IOHIDFamily sources are APSL-2.0; port the *algorithm* in your own code and keep the attribution comment that §6.6 specifies. Copying any file or function body from these projects into Trackglass is forbidden.

0.5 **Private API policy.** The Mac companion may use undocumented CoreGraphics/IOKit event fields (including raw `CGEventField(rawValue:)` numbers that are not public `CGEventField` cases, such as 55 and 137) and the private `HIDEvent` class **only** inside the module `Mac/Injection/Quartz/PrivateAPI/`. Every private symbol is resolved at runtime (`dlsym` / `NSClassFromString`) and has an explicit fallback path if the symbol is missing, so an OS update can degrade a gesture, never crash the app. The iOS app uses **no** private API of any kind (App Store).

0.6 **Language and style.** Swift 6, strict concurrency on (`SWIFT_STRICT_CONCURRENCY = complete`), `-warnings-as-errors` for both packages (`TrackglassKit`, `TrackglassEngine`). SwiftUI for all settings/pairing/menu UI. UIKit for the touch surface (SwiftUI cannot deliver raw multitouch at the required fidelity). AppKit only where the Mac needs windows that SwiftUI cannot do. No third-party dependencies except Sparkle 2 (Mac) and XcodeGen (dev tool). No analytics SDKs. No Combine where `async`/`await` or `@Observable` suffices.

0.7 **Terminology.** "Phone" means the iPhone or iPad running Trackglass. "Mac" means the computer running Trackglass for Mac. "Surface" is the phone's touch area. "Frame" is one TOUCH_FRAME message. "Engine" is the gesture engine on the Mac. "Injector" is the component that turns engine output into macOS input.

---

## 1. Product definition

### 1.1 Goal

A phone on the same Wi-Fi as a Mac (or within peer-to-peer Wi-Fi range) becomes a trackpad whose behavior is indistinguishable from an Apple Magic Trackpad connected to that Mac: same pointer acceleration, same tap-to-click semantics, same two-finger scroll with momentum, pinch, rotate, smart zoom, three- and four-finger swipes (Spaces, Mission Control, App Exposé, Launchpad, Show Desktop, Notification Center), Force click, and the same obedience to the Mac's own System Settings → Trackpad preferences.

### 1.2 Non-goals for v1

Keyboard input, media keys, remote screen viewing, Bluetooth transport, USB transport, Windows/Linux hosts, Apple Watch, multiple phones controlling one Mac at once, Mac App Store distribution, any paid tier.

### 1.3 The fidelity promise and how it is achieved

Only the Mac's own multitouch engine can be *literally* identical. There are two ways to drive a Mac and this product uses both, in order:

**Phase 1 — Quartz injector (ships first).** The Mac companion reads raw touch frames from the phone, runs its own gesture engine (a faithful re-implementation of what the Apple multitouch driver does), and injects results with CoreGraphics event APIs. Pointer, clicks, drags and scrolling use public API and reproduce macOS's own parametric acceleration algorithm (Apple publishes it in IOHIDFamily; §6.6). Pinch, rotate, smart zoom, system swipes and Force click use undocumented-but-stable gesture event fields (§6.9). Expected fidelity: ~95 % of a Magic Trackpad; the remaining gap is sub-perceptual in daily use.

**Phase 2 — DriverKit virtual trackpad (gated).** A DriverKit extension publishes a virtual HID device that presents itself as an Apple multitouch trackpad, so macOS's own driver performs all gesture recognition, acceleration and Force-click handling. The phone's raw touches are forwarded as multitouch reports. This is 100 % identical by construction, but it depends on (a) Apple granting DriverKit entitlements to the owner's team and (b) a feasibility spike proving that Apple's multitouch driver attaches to a DriverKit-published device. §12 defines the spike, the entitlement request and the go/no-go gates. Phase 1 remains the fallback forever.

The architecture (§2) isolates the injector behind one protocol so that Phase 2 is an added backend, not a rewrite.

### 1.4 Platforms and hardware

| Device | Minimum | Reference |
|---|---|---|
| iPhone | iOS 17, any iPhone XS/XR or later | iPhone with ProMotion (120 Hz) |
| iPad | iPadOS 17, any iPad that runs it | 11-inch iPad Pro or iPad Air |
| Mac | macOS 14 Sonoma, Intel or Apple silicon | Apple-silicon MacBook (built-in trackpad is the calibration reference) |

macOS 27 is Apple-silicon-only; Intel support therefore ends with macOS 26 and the Mac app must keep building for x86_64 (universal binary) until the deployment target is raised past 26.

### 1.5 Identifiers (final)

| Thing | Value |
|---|---|
| iOS app bundle ID | `app.trackglass.ios` |
| Mac app bundle ID | `app.trackglass.mac` |
| DriverKit extension bundle ID (Phase 2) | `app.trackglass.mac.driver` |
| Shared Swift package | `TrackglassKit` |
| App Group (Mac only, app ↔ dext) | `group.app.trackglass` |
| Custom URL scheme (pairing QR) | `trackglass` |
| Bonjour service types | `_trackglass._tcp` (control) · `_trackglass._udp` (input) |
| Keychain service names | `app.trackglass.pairing` |
| GitHub repository (public, open source) | xcconfig `TG_REPO_URL` = `https://github.com/<owner>/trackglass` (the owner fills in `<owner>` in P0.1) |
| Website (GitHub Pages, served from the repo's `website/` folder by `.github/workflows/pages.yml`) | xcconfig `TG_WEBSITE_URL` = `https://<owner>.github.io/trackglass` (a custom domain can replace it later; only this value changes) |
| Mac download page | `$(TG_REPO_URL)/releases/latest` — the newest GitHub release; its DMG asset is named `Trackglass-for-Mac-<version>.dmg`. The website's download button points there |
| Sparkle appcast URL | xcconfig `TG_APPCAST_URL` = `https://raw.githubusercontent.com/<owner>/trackglass/main/Releases/appcast.xml`; enclosure URLs inside it point at the release assets |
| Privacy policy page | `$(TG_WEBSITE_URL)/privacy.html` (used by the App Store listing and the in-app About link) |
| Support page | `$(TG_WEBSITE_URL)/support.html` (contact e-mail + setup steps; issues at `$(TG_REPO_URL)/issues`) |

Renaming later: all identifiers derive from four xcconfig variables `TG_PRODUCT_NAME = Trackglass`, `TG_BUNDLE_PREFIX = app.trackglass`, `TG_REPO_URL` and `TG_WEBSITE_URL`, exposed to code through Info.plist keys. Nothing else in the codebase hard-codes the name or a URL. No custom domain is needed for 1.0; if one is registered later, only `TG_WEBSITE_URL` changes.

**Distribution of the Mac app (Decision):** the source repository is public (open source) and GitHub Releases is the only download channel. The marketing site lives in the repo's `website/` folder (already written: `index.html`, `privacy.html`, `support.html`, `styles.css`, `main.js`, `assets/`) and is published to GitHub Pages by the workflow; its download button points at `releases/latest`. The repository `README.md` stays short (pitch, download link, link to the site, Developers section). The DMG is still Developer ID–signed and notarized, so Gatekeeper treats it like any other download. Because the code is public, the no-copying rule of §0.4 is also a licensing obligation: the repository carries its own license file (owner's choice, recorded in P0.3) and nothing from the GPL/MMF-licensed references.

### 1.6 Pricing

Free. No StoreKit, no receipts, no feature gating, no "pro" flags anywhere in the code. Do not add scaffolding for future purchases.

---

## 2. Architecture

### 2.1 Components

```
┌──────────────────────────────┐   UDP+DTLS (touch frames, 60–120 Hz)   ┌──────────────────────────────────────┐
│  Trackglass (iOS/iPadOS)     │ ─────────────────────────────────────▶ │  Trackglass for Mac (menu bar app)   │
│                              │                                        │                                      │
│  TouchSurface (UIKit)        │   TCP+TLS (control, haptics, settings) │  SessionCoordinator                  │
│  FrameEncoder                │ ◀────────────────────────────────────▶ │  TrackpadPreferences (reads macOS)   │
│  ConnectionManager           │                                        │  GestureEngine  (pure Swift)         │
│  Pairing (QR / PIN)          │   Bonjour _trackglass._tcp/_udp        │  InputInjector  ─┬─ QuartzInjector   │
│  Haptics, Appearance, HUD    │ ◀ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │                  └─ DriverInjector   │
└──────────────────────────────┘                                        │  (Phase 2: DriverKit dext)           │
                                                                        └──────────────────────────────────────┘
     Both link TrackglassKit (protocol, codec, geometry, pairing crypto, .tgrec format — Foundation/Network/CryptoKit/Security only, no UIKit/AppKit/CoreGraphics)
     The Mac app, tgreplay and EngineTests link TrackglassEngine (GestureEngine + TrackpadSettings — pure Swift, depends only on TrackglassKit)
```

**Principle: the phone is a sensor, the Mac is the brain.** The phone sends raw, time-stamped, millimeter-scaled touch contacts and nothing else. All interpretation (what is a tap, what is a scroll, which gestures are enabled) happens on the Mac, where the Mac's own trackpad preferences live. This mirrors how a real trackpad works, keeps the iOS app trivially simple (App Review-friendly), and makes Phase 2 a drop-in (raw touches are exactly what a multitouch HID report carries).

### 2.2 Data flow per frame (Phase 1)

1. UIKit delivers `touchesBegan/Moved/Ended/Cancelled` to `TouchSurfaceView` (main thread, at display refresh rate; 120 Hz on ProMotion when the display link keeps the display at 120 Hz — §5.4).
2. `TouchSurfaceView` writes contact data into a preallocated `TouchFrame` struct (no heap allocation), converts points → millimeters, stamps `CACurrentMediaTime()` in nanoseconds, increments the sequence number, and hands the frame to `FrameSender` (a `@unchecked Sendable` ring buffer drained by a dedicated `DispatchQueue(qos: .userInteractive)`).
3. `FrameSender` encodes the frame (§4.4) into a reusable `Data` buffer and calls `NWConnection.send(content:completion: .idempotent)` on the UDP connection (`.idempotent` is the completion mode that needs no callback). There is no retry logic anywhere: a lost datagram is superseded by the next frame.
4. The Mac's `InputListener` receives the datagram on a `DispatchQueue(label: "input-pipeline", qos: .userInteractive)` and hands the bytes to `InputPipeline` (a queue-confined `final class` that owns the decoder, the `GestureEngine`, the `EventBuffer` and the active `InputInjector`). `InputPipeline` decodes, drops out-of-order frames, and calls `engine.process(frame, into: &events)` synchronously on that same queue.
5. `InputPipeline` then passes every event in the buffer to the injector, synchronously, on the same queue. No thread hops and no heap allocations anywhere in this path. `SessionCoordinator` (an actor) only installs and removes the pipeline when sessions start and end.
6. Side effects that need the phone (haptic click) are sent back over the control connection.

### 2.3 Repository layout

```
Trackglass/
├── project.yml                     # XcodeGen definition (single source of truth for the Xcode project)
├── Config/
│   ├── Shared.xcconfig             # TG_PRODUCT_NAME, TG_BUNDLE_PREFIX, TG_REPO_URL, TG_APPCAST_URL, versions
│   ├── iOS.xcconfig
│   ├── Mac.xcconfig
│   └── Driver.xcconfig             # Phase 2
├── Packages/
│   └── TrackglassKit/              # SPM, platform-neutral: protocol, codec, models, math, test fixtures
│       ├── Package.swift
│       ├── Sources/TrackglassKit/
│       │   ├── Protocol/           # MessageHeader, MessageType, TouchFrame, ControlMessages, Codec
│       │   ├── Pairing/            # PairingPayload (QR URL), KeyDerivation (HKDF), PeerIdentity, TLSConfig
│       │   ├── Transport/          # TGControlFramer (NWProtocolFramerImplementation)
│       │   ├── Geometry/           # SurfaceGeometry (nativeScale injected), millimeter conversion, PPI table
│       │   ├── Recording/          # TGRecFormat: .tgrec reader/writer (raw frame bytes + capture time + origin)
│       │   └── Util/               # MonotonicClock, RingBuffer, FixedPoint helpers
│       ├── Tests/TrackglassKitTests/
│   └── TrackglassEngine/           # SPM, pure Swift, depends only on TrackglassKit
│       ├── Sources/TrackglassEngine/
│       │   ├── GestureEngine.swift, EventBuffer.swift, GestureEvent.swift (+ Codable JSON shape), TrackpadSettings.swift, EngineGeometry.swift
│       │   ├── Recognizers/        # ContactTracker, TapRecognizer, DragController, TwoFingerRecognizer, MultiFingerRecognizer, ForceClickRecognizer, ScrollMomentum
│       │   └── Acceleration/       # ParametricAccelerationCurve, TableAcceleration, PointerAccelerator, ScrollAccelerator
│       └── Tests/EngineTests/      # fixture-driven (§10.1)
├── iOS/
│   ├── App/                        # AppDelegate/SceneDelegate (UIKit root), AppState (@Observable)
│   ├── Surface/                    # TouchSurfaceViewController (root VC), TouchSurfaceView, FrameSender, DisplayLinkDriver, overlay UIHostingControllers
│   ├── Networking/                 # ConnectionManager (actor), MacBrowser (Bonjour), SessionClient, PairingClient
│   ├── Pairing/                    # PairingFlowView, QRScannerView (AVFoundation), PINEntryView
│   ├── Haptics/                    # HapticEngine (CoreHaptics with UIFeedbackGenerator fallback)
│   ├── Appearance/                 # Theme, ThemeStore, SurfaceRenderer (CALayer), FingerHaloLayer
│   ├── Settings/                   # SettingsSheet, MacsListView, AppSettings
│   ├── HUD/                        # StatusPill, LatencyOverlay
│   └── Resources/                  # Assets, Localizable.xcstrings (English only in v1), Info.plist keys via project.yml
├── Mac/
│   ├── App/                        # TrackglassMacApp.swift (MenuBarExtra), AppDelegate (AppKit glue), Windows
│   ├── Server/                     # BonjourAdvertiser, ControlListener, InputListener, SessionCoordinator (actor), InputPipeline (queue-confined)
│   ├── Pairing/                    # PairingService, QRCodeRenderer, PINGenerator
│   ├── Preferences/                # TrackpadPreferences (reads macOS defaults + HID accel curves → TrackpadSettings)
│   ├── Injection/
│   │   ├── InputInjector.swift     # protocol
│   │   ├── Quartz/                 # QuartzInjector, PointerState, GestureEventFactory, DockSwipePath
│   │   │   └── PrivateAPI/         # TGPrivateFields.h (all raw field numbers), TGPrivateAPI.h/.m (ObjC): dlsym'd CGEventSetHIDEvent, HIDEvent class
│   │   └── Driver/                 # Phase 2: DriverInjector (IOUserClient bridge)
│   ├── Permissions/                # AccessibilityPermission, LocalNetworkPermission
│   ├── Power/                      # DisplayWake (IOPMAssertionDeclareUserActivity)
│   ├── Updates/                    # SparkleController
│   ├── Diagnostics/                # LatencyStats, SessionLog (os_log), ReplayRecorder
│   └── Resources/
├── Driver/                         # Phase 2 DriverKit extension (C++): TrackglassVirtualTrackpad.iig/.cpp, UserClient
├── Tools/
│   ├── tgreplay/                   # Mac CLI: replays recorded .tgrec sessions through GestureEngine → stdout/injector
│   └── tgaccel/                    # Mac CLI: dumps the current Mac's HIDAccelCurves / resolution / rate as JSON
├── Tests/
│   ├── TrackglassMacTests/         # unit tests hosted by TrackglassMac.app (PairingStore, preferences, pipeline, security) + InjectorTests/ (CGEventTap capture; skipped when AXIsProcessTrusted() is false)
│   ├── TrackglassiOSTests/         # unit tests hosted by the iOS app on the simulator (PairingStore, geometry glue, frame emission)
│   └── Fixtures/                   # <name>.tgrec + <name>.settings.json + <name>.expected.json triplets (EngineTests and tgreplay read them from here)
├── Releases/                       # appcast.xml (Sparkle feed, committed by the release script) + release-notes/<version>.md
├── website/                        # GitHub Pages site (provided; index.html, privacy.html, support.html, styles.css, main.js, assets/)
├── .github/workflows/pages.yml     # deploys website/ to GitHub Pages (provided)
├── README.md, LICENSE
└── docs/                           # SPEC.md, PLAN.md, PROGRESS.md, APPSTORE.md (includes the App Review notes), THIRD-PARTY.md, Calibration.md, Latency.md, QA-Robustness.md, Phase2-Spike.md, Install.md
```

### 2.4 Concurrency model

- **Phone:** main thread owns UIKit touch delivery and rendering. `FrameSender` owns network sends on its own serial queue. `ConnectionManager` is an `actor` that owns connection state; the surface reads a cached `isConnected` flag (an `@Observable` property updated on the main actor), never awaits inside touch handlers.
- **Mac:** one serial `input-pipeline` queue for receive → engine → inject. `InputPipeline`, `GestureEngine` and the injector are `final class`es confined to that queue (annotate with `@unchecked Sendable` plus a debug-only `dispatchPrecondition(condition: .onQueue(pipelineQueue))` in every entry point). `SessionCoordinator` is an actor for lifecycle only: it creates an `InputPipeline` when a session is admitted, installs it into `InputListener`, and tears it down on BYE/loss; it never touches frames. One `DispatchSourceTimer` on the pipeline queue fires every **8 ms** (`ENGINE_TICK`) while contacts are tracked, a grace window is open, or momentum is running; it calls `engine.tick(now:into:)` with the estimated phone time (§4.7). Momentum scrolling (§6.8) is produced inside the engine by that tick; there is no second timer.
- **Frame-time validation** belongs to `InputPipeline`, not the engine: a frame whose `frameTime` is lower than the last accepted one is dropped and counted (§8.9).
- Never use `DispatchQueue.main.async` inside the input pipeline. UI updates (HUD, menu) read snapshot values published through `@Observable` models updated at most 10 times per second.

### 2.5 Build tooling

- Project generated by **XcodeGen** from `project.yml`. Never edit the `.xcodeproj` by hand; regenerate with `xcodegen generate`.
- Commands the agent uses (document them in `README.md`):

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOS -destination 'generic/platform=iOS' build
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac -configuration Debug build
swift test --package-path Packages/TrackglassKit
swift test --package-path Packages/TrackglassEngine
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac -destination 'platform=macOS' test                       # TrackglassMacTests (incl. InjectorTests)
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOS -destination 'platform=iOS Simulator,name=iPhone 17' test  # TrackglassiOSTests
```

- Targets and schemes: `TrackglassiOS` (iPhone + iPad, one universal app) with its hosted test bundle `TrackglassiOSTests`; `TrackglassMac` with its hosted test bundle `TrackglassMacTests` (which contains the `InjectorTests` folder; hosted tests run inside the signed app, so its Accessibility grant and data-protection Keychain apply); `TrackglassDriver` (Phase 2, excluded from default build until §12 gate passes); `tgreplay`; `tgaccel`. The packages `TrackglassKit` and `TrackglassEngine` carry their own test targets (`TrackglassKitTests`, `EngineTests`) run with `swift test`. `Scripts/ci.sh` runs all of these.
- Signing: automatic for development with `DEVELOPMENT_TEAM` supplied by the gitignored `Config/Local.xcconfig` (template committed as `Config/Local.xcconfig.example`; `Shared.xcconfig` has `#include? "Local.xcconfig"`); for release, manual with the owner's Developer ID Application certificate (Mac) and App Store distribution profile (iOS). Hardened Runtime on for the Mac app. App Sandbox **off** for the Mac app (required for Accessibility-based event posting).

---

## 3. Security and pairing

### 3.1 Threat model

Anyone on the same network must not be able to move the Mac's pointer, click, or observe touch data. Pairing must be a one-time act per Mac. Long-term keys live only in the Keychain. The low-entropy PIN path must resist online brute force.

### 3.2 Identities and keys

- Each device generates once, at first launch, a random 16-byte `peerID` (UUID) and a display name. Mac: `Host.current().localizedName`. Phone: a name the user confirms on the pairing screen, pre-filled with the marketing model name derived from the model identifier (e.g. "iPhone 17 Pro"), stored in `UserDefaults`; **never** `UIDevice.current.name`, which returns the generic model name on iOS 16+ without a special entitlement.
- Pairing produces a 32-byte random **long-term key (LTK)** per (phone, Mac) pair. The Mac generates it and transfers it inside the authenticated pairing channel (§3.4).
- Storage: Keychain, `kSecClassGenericPassword`, service `app.trackglass.pairing`, account = the *other* peer's `peerID`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no iCloud sync. On the Mac every query also sets `kSecUseDataProtectionKeychain = true` (otherwise the item lands in the legacy login keychain, where the accessibility attribute is ignored). Value = JSON `{ltk: base64, name: String, pairedAt: ISO8601}`.
- Unpairing from either side deletes that entry; the other side learns at next connect (TLS handshake fails → UI shows "Pair again").

### 3.3 Transport security

All connections use Network.framework with TLS-PSK (control: TLS over TCP; input: DTLS over UDP). Configuration (identical on both sides, in `TrackglassKit/Pairing/TLSConfig.swift`):

```swift
static func tlsOptions(psk: SymmetricKey, identity: String) -> NWProtocolTLS.Options {
    let opts = NWProtocolTLS.Options()
    let keyData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
    let idData  = identity.data(using: .utf8)!.withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(opts.securityProtocolOptions, keyData as __DispatchData, idData as __DispatchData)
    sec_protocol_options_append_tls_ciphersuite(opts.securityProtocolOptions,
        tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
    sec_protocol_options_set_min_tls_protocol_version(opts.securityProtocolOptions, .TLSv12)
    return opts
}
```

- Parameters: `NWParameters(tls: opts)` for control; `NWParameters(dtls: opts, udp: NWProtocolUDP.Options())` for input. On both set `includePeerToPeer = true`, `requiredInterfaceType` unset, `prohibitedInterfaceTypes = [.cellular]`, `allowLocalEndpointReuse = true`. The control parameters also prepend `NWProtocolFramer.Options(definition: TGControlFramer.definition)` (§4.3).
- **Server-side keys:** the Mac is paired with several phones, so the listener registers **every** paired phone's `(LTK, peerID)` pair with repeated `sec_protocol_options_add_pre_shared_key` calls on the same options object (the TLS stack picks the key whose identity the client offers); both listeners are recreated whenever the pairing set changes. `sec_protocol_options_set_pre_shared_key_selection_block` only lets a side choose among identities already registered (its completion takes an identity, not a key), so it is not the mechanism; it may be set to log the offered identity. **Gate G-TLS (M3.4):** if multiple PSKs on one listener do not work for TLS or DTLS on macOS 14, run one `NWListener` per paired phone (each with its PSK fixed) on distinct ports and advertise the port per phone in the Bonjour TXT record (`p<peerID-prefix>=<port>`). Do not weaken security to a shared key.
- Session PSK = LTK. Identity string = phone `peerID` (UUID string, lowercase).

### 3.4 Pairing protocol

The Mac's pairing window is open only while the user has it on screen (`PairingService.isOpen`). While open, the Mac runs a separate *pairing listener* on `_trackglass._tcp` with instance name `<MacName> (pairing)` and its own TXT record `v=1`, `id=<macPeerID>`, `nm=<MacName>`, `pr=1`, `pid=<base64url pairID>`. The two main listeners keep `pr=0`. The phone's `MacBrowser` keeps pairing instances as separate `isPairing` entries keyed by Bonjour instance name (they are never merged with the main entry that shares the same `id`). Both the QR path and the PIN path connect to the `(pairing)` instance; the main listeners never accept pairing traffic.

**QR path (primary).**
1. Mac generates `pairID` (8 random bytes) and `pairSecret` (32 random bytes), renders a QR code (CoreImage `CIQRCodeGenerator`, error correction "M", 320 × 320 pt) of the URL
   `trackglass://pair?v=1&id=<base64url pairID>&s=<base64url pairSecret>&n=<percent-encoded Mac name>&h=<percent-encoded Bonjour instance name>`.
2. Phone scans it (AVFoundation `AVCaptureMetadataOutput`, `.qr`), parses with `PairingPayload(url:)` from TrackglassKit, resolves `h` via Bonjour, opens a control connection whose TLS PSK is `pairSecret` and identity is `pairID`.
3. Inside the channel: phone → `PAIR_REQUEST {phonePeerID, phoneName, model, protocolVersion}`; Mac → `PAIR_RESPONSE {macPeerID, macName, ltk}`. Both store. Mac shows "Paired with <phoneName>" and closes the pairing listener. The QR is single-use: any second connection with the same `pairID` is rejected.

**PIN path (fallback, same window, a "Use a code instead" button).**
1. Mac shows a 6-digit PIN (CSPRNG, leading zeros allowed) and the same `pairID`.
2. PSK = `HKDF<SHA256>(ikm: PIN as UTF-8, salt: pairID, info: "trackglass-pair-v1", outputByteCount: 32)`. Identity = `pairID`.
3. Phone shows a list of Macs advertising `pr=1`; user taps one, types the PIN; same `PAIR_REQUEST/RESPONSE` exchange.
4. Brute-force resistance: a failed handshake invalidates the PIN immediately (Mac rotates to a new PIN and a new `pairID`, re-renders the QR code with the new `pairID`/`pairSecret`, and updates the pairing listener's TXT `pid`), at most 3 PINs per pairing-window opening, window auto-closes after 120 s. Six digits × 3 attempts = negligible online success probability.

**Trust decisions.** No iCloud, no certificates, no TOFU: the QR/PIN *is* the authentication. Never auto-pair.

### 3.5 Session admission

- A Mac serves exactly one controller. `SessionCoordinator` holds `activeSession: Session?`. A second phone that completes the TLS handshake receives `WELCOME{status: busy}` and is disconnected.
- A phone may be paired with many Macs; `MacsListView` shows them; the connect target is the last used, switchable with one tap.
- Reconnect policy (phone): on loss, retry with exponential backoff 0.5 s → 8 s while the app is foregrounded; stop in background.

---

## 4. Shared protocol (TrackglassKit)

### 4.1 Conventions

Little-endian. All integers unsigned unless stated. Floats are IEEE-754 binary32. Timestamps are nanoseconds from the *sender's* monotonic clock (`mach_absolute_time` converted via `MonotonicClock.nanoseconds()`), never wall-clock. Strings are UTF-8 with a `u16` byte-length prefix. Protocol version is `1`. A receiver that sees an unknown `type` logs once and ignores the message. A receiver that sees `version != 1` sends `BYE{reason: incompatible}` and disconnects.

### 4.2 Header (every message, both transports)

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | magic: the two bytes `0x54 0x47` (ASCII "TG", compared byte-wise, not as an integer) |
| 2 | 1 | version = 1 |
| 3 | 1 | type (see 4.5) |
| 4 | 4 | sequence (per sender, per transport, wraps) |
| 8 | 8 | sentAt (ns, sender monotonic) |

Header size 16. Datagrams carry exactly one message. Control stream messages are framed by `TGControlFramer`.

### 4.3 Control framing

`TGControlFramer: NWProtocolFramerImplementation`: each message is `u32 length` followed by `length` bytes (header + payload). Maximum 64 KiB. Implement `handleInput` with the standard parse loop; `handleOutput` writes the prefix then the message.

### 4.4 TOUCH_FRAME (UDP; phone → Mac)

| Offset | Size | Field |
|---|---|---|
| 16 | 8 | frameTime (ns; the UIEvent timestamp converted to ns) |
| 24 | 1 | contactCount (0…10) |
| 25 | 1 | flags: bit0 = surfaceIsLandscape, bit1 = isSyntheticLiftoff, bit2…7 reserved = 0 |
| 26 | 2 | reserved = 0 |
| 28 | 16·n | contacts |

Contact (16 bytes):

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | contactID (stable for the life of the touch; 0…255, phone reuses after end) |
| 1 | 1 | phase: 1 began, 2 moved, 3 stationary, 4 ended, 5 cancelled |
| 2 | 1 | kind: 1 finger, 2 pencil/stylus (Mac ignores kind 2 entirely) |
| 3 | 1 | reserved = 0 |
| 4 | 4 | x (mm, Float32, origin top-left of surface, +x right) |
| 8 | 4 | y (mm, Float32, +y down) |
| 12 | 4 | majorRadius (mm, Float32; from `UITouch.majorRadius`) |

Rules: a frame contains **every** currently tracked contact (began/moved/stationary) plus the contacts that ended/cancelled since the previous frame. After the last contact ends, the phone sends one extra frame with `contactCount = 0` and `isSyntheticLiftoff = 1` so the Mac can never be stuck with a phantom finger. Max frame size = 28 + 160 = 188 bytes, always below any MTU.

### 4.5 Message types

| Type | Name | Transport | Direction | Payload |
|---|---|---|---|---|
| 0x01 | HELLO | TCP | phone → Mac | `protocolVersion u8`, `peerID 16B`, `name str` (the user-confirmed phone name, §3.2), `modelIdentifier str` (e.g. `iPhone16,1`), `surfaceWidthMM f32`, `surfaceHeightMM f32`, `ppi f32`, `maxContacts u8`, `displayHz u16`, `caps u32` (bit0 haptics, bit1 coalescedSamples), `trackingOverride f32` (−1…+1, the phone's optional tracking-speed override, 0 = none; §6.4) |
| 0x02 | WELCOME | TCP | Mac → phone | `status u8` (0 ok, 1 busy, 2 incompatible, 3 notPaired), `macPeerID 16B`, `macName str`, `macOSVersion str`, `injectorMode u8` (1 quartz, 2 driver), `settings` (see SETTINGS payload), `activePhoneName str` (empty unless busy; owner-approved addition, 2026-10-22) |
| 0x03 | SETTINGS | TCP | Mac → phone | `naturalScrolling u8`, `tapToClick u8`, `forceClickEnabled u8`, `hapticsSuggested u8`, `trackingSpeed f32` (the Mac's `com.apple.trackpad.scaling`), `secondaryClickMode u8` (0 off, 1 two-finger, 2 bottom-right, 3 bottom-left) — informational, used only by the phone's HUD and onboarding tips |
| 0x04 | PING | TCP | both | `nonce u32` |
| 0x05 | PONG | TCP | both | `nonce u32`, `echoSentAt u64` |
| 0x06 | HAPTIC | TCP | Mac → phone | `kind u8` (1 click, 2 secondaryClick, 3 forceClickStage2, 4 dragLockEngaged, 5 dragLockReleased, 6 spaceSwitched), `intensity u8` 0…255 |
| 0x07 | STATUS | TCP | Mac → phone | `lossPermille u16`, `rttMicros u32`, `framesPerSecond u16` (frames received in the last second), `pipelineP50Micros u32`, `pipelineP95Micros u32`, `engineState u8` (0 idle, 1 pointer, 2 scroll, 3 gesture, 4 drag); sent once per second while connected |
| 0x08 | SURFACE | TCP | phone → Mac | same geometry fields as HELLO plus `trackingOverride f32` (sent on rotation / size-class change and whenever the override changes) |
| 0x09 | BYE | TCP | both | `reason u8` (0 user, 1 incompatible, 2 busy, 3 unpaired, 4 sleeping) |
| 0x10 | TOUCH_FRAME | UDP | phone → Mac | §4.4 |
| 0x11 | INPUT_HEARTBEAT | UDP | phone → Mac | empty; every 500 ms while **no contact is on the glass** (so a heartbeat is also a statement "no fingers down", §4.7) |
| 0x20 | PAIR_REQUEST | TCP (pairing) | phone → Mac | `peerID 16B`, `name str`, `modelIdentifier str`, `protocolVersion u8` |
| 0x21 | PAIR_RESPONSE | TCP (pairing) | Mac → phone | `peerID 16B`, `name str`, `ltk 32B` |

### 4.6 Session sequence

```
phone                                  Mac
  │── TCP+TLS(PSK=LTK) connect ───────▶│
  │── HELLO ──────────────────────────▶│
  │◀── WELCOME{ok, settings} ──────────│   (or busy/notPaired → BYE)
  │── UDP+DTLS(PSK=LTK) connect ──────▶│
  │── INPUT_HEARTBEAT ────────────────▶│   (confirms datagram path; Mac logs "input ready")
  │── TOUCH_FRAME × N ────────────────▶│
  │◀── HAPTIC / STATUS / SETTINGS ─────│
  │◀─▶ PING/PONG every 1 s ───────────▶│   (3 missed = dead → reconnect)
```

### 4.7 Loss, order, timing

- Mac keeps `lastSeq`; frames with `seq <= lastSeq` (modulo wrap) are dropped. Gaps are counted into `lossPermille`.
- The engine uses **frameTime deltas** (phone clock) for all durations and velocities. When the engine's `tick(now:)` runs between frames, `now` is the *estimated phone time* `lastFrameTime + (macNow − macReceiveTimeOfLastFrame)`, maintained by `InputPipeline`; so every gesture timer (hold-to-force-click, drag-release grace, pending smart zoom, momentum steps) is evaluated on one consistent clock. Nothing in the engine reads Mac time.
- A contact that is tracked but absent from a newer frame (its `ended` frame was lost) is ended by the engine at that frame's `frameTime`. A `began` for a `contactID` that is still tracked first ends the old contact, then starts the new one.
- An `INPUT_HEARTBEAT` received while contacts are tracked means the synthetic lift-off datagram was lost: the pipeline calls `engine.forceLiftoff(releaseDragLock: false)` (a deliberate drag lock survives). If **neither** a frame nor a heartbeat arrives for 1.5 s while contacts are tracked, or the connection ends (BYE or loss), the pipeline calls `forceLiftoff(releaseDragLock: true)`, releasing **every** held button so a lost "ended" or a dead link can never leave a button held down.

---

## 5. iOS / iPadOS app — Trackglass

### 5.1 Screens and navigation

Single-window UIKit-rooted app: `SceneDelegate` installs `TouchSurfaceViewController` as the window's root view controller (so no SwiftUI hosting view, with its own gesture recognizers, ever sits above the touch surface). All other screens are SwiftUI inside `UIHostingController`s that the root controller presents (onboarding, pairing, settings sheet) or adds as **sibling** child views layered above the surface (grip button, status pill, latency overlay). The root controller switches on `AppState.phase`:

| Phase | View | Notes |
|---|---|---|
| `.onboarding` | `OnboardingView` | 3 pages: what it does → "Install Trackglass for Mac" (the download URL as a tappable link plus a Copy button; the user opens it on the Mac) → "Pair". iPad adds a 4th page: how to disable iPadOS multitasking gestures (Settings → Multitasking & Gestures → Gestures off) so 4- and 5-finger gestures reach the Mac. |
| `.pairing` | `PairingFlowView` | QR scanner full screen with a "Use a code" button → `PINEntryView` listing Macs that advertise `pr=1`. |
| `.surface` | the root controller's own `TouchSurfaceView` | The trackpad. Full screen, both orientations, no navigation bar. A 36 × 36 pt circular "grip" button (a `UIHostingController` child, sibling of the surface) at top-trailing (inset 12 pt from safe area) opens `SettingsSheet`. The HUD status pill (§5.8) appears top-center. |
| `.noMac` | overlay hosting controller above the surface | "Looking for <last Mac>…" with a list of other paired Macs and "Pair a new Mac". |

`SettingsSheet` (SwiftUI `.sheet`, `presentationDetents([.medium, .large])`): sections **Mac** (paired Macs list, connect/forget, "Pair new Mac"), **Appearance** (theme picker, accent, finger glow toggle, HUD toggle), **Feel** (haptics toggle + strength, tracking-speed override slider -1…+1 relative to the Mac's setting, off by default), **Diagnostics** (latency overlay toggle, "Record session" for `.tgrec` export via share sheet), **About** (version, privacy statement "Trackglass never leaves your network", a **Privacy Policy** link to the same URL as the App Store privacy policy — App Review guideline 5.1.1 requires it in-app — and a link to the Mac app download page).

### 5.2 Touch capture (the core)

`TouchSurfaceView: UIView` hosted by `TouchSurfaceViewController`.

- `isMultipleTouchEnabled = true`, `isExclusiveTouch = true`, `isUserInteractionEnabled = true`. No gesture recognizers attached to this view or any ancestor (they add latency and steal touches); this is why the view controller is the UIKit root (§5.1). The grip button and HUD are sibling views above the surface, never children of it.
- Override `touchesBegan/Moved/Ended/Cancelled(_:with:)`. In each, call `emit(event:)` once (not once per touch). The view keeps its **own live-contact table** (a fixed array of 10 slots holding the retained `UITouch` plus its `contactID`): `touchesBegan` inserts from the `touches` parameter, `touchesEnded/Cancelled` removes, and `emit` walks the table reading `preciseLocation(in:)`, `phase` and `majorRadius` of every retained touch (UIKit keeps `UITouch` objects alive and updated for the duration of the touch). Do not call `event.allTouches` or `event.touches(for:)` in the per-frame path — both build a new `Set` per call; the zero-allocation budget (§7) covers Trackglass's own code and excludes UIKit-internal allocations. Touches from sibling views never reach this view's overrides.
- Contact IDs: a free-list of 0…255; assign on began, release on ended/cancelled, never reuse an ID that is still in the table.
- Phase mapping: `UITouch.Phase` `.began → 1`, `.moved → 2`, `.stationary → 3`, `.ended → 4`, `.cancelled → 5`, `.regionEntered/.regionMoved/.regionExited` (hover) → ignore the touch.
- `touch.type == .pencil` → send `kind = 2` (the Mac ignores it); `.indirectPointer`/`.indirect` → ignore.
- Coordinates: `touch.preciseLocation(in: self)` in points → millimeters via `SurfaceGeometry` (§5.3). `majorRadius` in points → mm via the same scale.
- Timestamps: `event.timestamp` (seconds, `CACurrentMediaTime` base) → ns.
- **Zero allocation rule:** `TouchFrame` is a fixed-size struct with an inline array of 10 contacts (`(Contact, Contact, …)` tuple or `withUnsafeMutableBytes` into a preallocated buffer). The encoder writes into a `Data` of capacity 188 that is owned by `FrameSender` and reused. Profile with Instruments "Allocations" during M2: the per-frame path must show 0 transient allocations.
- Synthetic lift-off: when the live-contact table becomes empty after emitting the frame that carries the last ended/cancelled phases, enqueue one more frame with `contactCount = 0`, `isSyntheticLiftoff = 1`, and start the 500 ms heartbeat cadence (§4.5).
- Coalesced samples (capability bit1, optional in v1, implemented in M10): for each touch, `event.coalescedTouches(for:)` yields intermediate samples; when the touch sample rate exceeds the display rate (iPad), emit one frame per coalesced timestamp. Not required for the M2 exit criteria.
- Predicted touches: **not used** (they trade jitter for latency and would corrupt tap/drag timing on the Mac). Decision is final for v1.

### 5.3 Surface geometry and millimeters

The Mac must receive physical units so that the same finger motion produces the same pointer motion as on a Magic Trackpad, regardless of device.

`SurfaceGeometry(ppi:nativeScale:boundsInPoints:)` (TrackglassKit, platform-neutral) computes `mmPerPoint = (25.4 / ppi) * nativeScale`. The iOS app supplies `nativeScale` from `view.window?.screen.nativeScale` (never `UIScreen.main`, deprecated) and PPI from `DevicePPI.lookup(modelIdentifier)` (table in Appendix C) with fallbacks: iPhone 460, iPad 264, iPad mini 326. The surface is the full view bounds in landscape and portrait; `SURFACE` is re-sent on `viewWillTransition(to:with:)`. Stage Manager / Split View on iPad: the surface is whatever bounds the window has; nothing is clamped.

### 5.4 Keeping the display and touch delivery at 120 Hz

- Info.plist: `CADisableMinimumFrameDurationOnPhone = YES`.
- `DisplayLinkDriver` holds a `CADisplayLink` added to `.main` run loop with `preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)` while the surface is visible (connected or not — halos must render while reconnecting); its callback does the per-frame HUD/halo update only (touch sending is event-driven, not display-link-driven). On 60 Hz devices this is a no-op.
- `UIApplication.shared.isIdleTimerDisabled = true` while the surface is visible **and** connected (before networking exists, M2, simply while visible); restored on disconnect/background.
- `TouchSurfaceViewController`: `prefersHomeIndicatorAutoHidden = true`, `preferredScreenEdgesDeferringSystemGestures = .all`, `prefersStatusBarHidden = true`, supported orientations: all (iPhone: all but upside-down on devices without Face ID; use `.allButUpsideDown` on iPhone, `.all` on iPad).

### 5.5 Networking (phone side)

- `MacBrowser`: `NWBrowser(for: .bonjourWithTXTRecord(type: "_trackglass._tcp", domain: nil), using: params)` with `includePeerToPeer = true`. Results are reduced to `DiscoveredMac {peerID (from TXT id=), name (nm=), instanceName, endpoint, isPairing (pr=1), pairID (pid=, pairing instances only)}`, keyed by Bonjour instance name, so a Mac in pairing mode appears as two entries (main + pairing) and the pairing one is the only target of the pairing flows.
- `SessionClient`: opens control (`NWConnection(to: .service(name:type:domain:interface:), using: controlParams)`) then input (`NWConnection` to the `_trackglass._udp` service with the same instance name, `inputParams`). Sends HELLO; on WELCOME ok, publishes `connected`. Runs PING every 1 s; 3 misses → `disconnected(reason: .timeout)`.
- `ConnectionManager` (actor): owns browser, session, reconnect loop, the paired-Mac store (`PairingStore`, Keychain), and exposes `@MainActor @Observable final class ConnectionState { var phase, macName, rttMicros, lossPermille, injectorMode }`.
- Info.plist (via project.yml): `NSLocalNetworkUsageDescription = "Trackglass finds and talks to Trackglass for Mac on your local network."`, `NSBonjourServices = [_trackglass._tcp, _trackglass._udp]`, `NSCameraUsageDescription = "Scan the pairing code shown by Trackglass for Mac."`, `UIBackgroundModes` **none** (the app stops when backgrounded; Decision), `CFBundleURLTypes` with scheme `trackglass` (so a QR scanned with the Camera app opens the app and pairs).

### 5.6 Haptics

`HapticEngine` (CoreHaptics; `UIImpactFeedbackGenerator(.rigid)` fallback when `CHHapticEngine.capabilitiesForHardware().supportsHaptics == false`). Patterns, all `CHHapticEvent(eventType: .hapticTransient, …)`:

| HAPTIC.kind | Pattern |
|---|---|
| 1 click | intensity 0.85, sharpness 0.9, duration 0 |
| 2 secondaryClick | intensity 0.7, sharpness 0.6 |
| 3 forceClickStage2 | two transients 60 ms apart, 0.6/0.9 then 1.0/1.0 |
| 4 dragLockEngaged | intensity 0.5, sharpness 0.3 |
| 5 dragLockReleased | intensity 0.35, sharpness 0.3 |
| 6 spaceSwitched | intensity 0.4, sharpness 0.8 |

Engine is started on connect, stopped on disconnect, and restarted on `CHHapticEngine` reset/stopped handlers. The user's "Haptics strength" setting multiplies intensity (0.5…1.0). The Mac decides *when* (it knows the tap-to-click outcome); the phone decides *whether* (its own toggle). Round trip is ~2–5 ms on LAN, below perception.

### 5.7 Appearance system

`Theme` is a value type: `background: ThemeBackground`, `fingerGlow: FingerGlowStyle`, `accent: Color`, `showsGrid: Bool`, `gripStyle`. Built-in themes (all procedurally rendered, no bitmaps, no Apple trade dress, no Apple logos or product likenesses):

1. **Glass Black** (default): `#000000` background, finger halos 44 pt radius, radial gradient from `accent.opacity(0.35)` to clear, fade-out 220 ms after lift, accent default `#8E8E93`.
2. **Glass White**: `#F2F2F7` background, halos `accent.opacity(0.25)`, accent default `#636366`.
3. **Aluminum**: a procedural brushed-metal look — vertical linear gradient `#D9D9DE → #BFBFC4 → #D4D4D9`, overlaid with `CAEmitterLayer`-free noise (a 64 × 64 `CGImage` noise tile generated once with `CGImage` from random bytes, tiled at 6 % opacity), 12 pt rounded corners inset 8 pt so it reads as a "pad" on the glass. Halos `#000000.opacity(0.12)`. Deliberately generic; it must **not** reproduce a Magic Trackpad's proportions, color or any logo.
4. **Midnight Grid**: Glass Black with a 10 mm dot grid at 8 % opacity (helps users feel scale).
5. **Custom**: user picks background color (system `ColorPicker`), accent, halo on/off, grid on/off.

`SurfaceRenderer` draws halos with `CALayer`s (one `FingerHaloLayer` per contact, reused from a pool of 10). Animations are implicit `CABasicAnimation`s on `opacity`/`transform`; the renderer must not touch the touch path's timing (it runs on the display link tick, reading the last frame snapshot).

### 5.8 HUD

`StatusPill` (SwiftUI, top-center): "<Mac name> · 2.3 ms" shown for 2 s after connect and whenever state changes; hidden otherwise. Latency figure = RTT/2 from PING. Optional `LatencyOverlay` (Diagnostics toggle) shows a 120-sample sparkline of RTT, loss ‰, and frames/s.

### 5.9 Background, lifecycle, power

- `SceneDelegate.sceneDidEnterBackground` → stop display link, send BYE(user), close connections, re-enable idle timer. `sceneDidBecomeActive` → reconnect to last Mac. (UIKit-rooted app: no SwiftUI `scenePhase`.)
- Low Power Mode: no change in behavior (the user chose this app).
- Thermal state `.serious` or worse: reduce halo rendering to none; never reduce frame rate of touch sending.

### 5.10 App Store compliance

- Privacy nutrition label: **Data Not Collected**. No analytics, no crash SDKs; crash reports come only via Apple's opt-in sharing (MetricKit `MXMetricManager` subscriber may be added to receive diagnostics in-app, but nothing is uploaded by Trackglass).
- Privacy manifest `iOS/Resources/PrivacyInfo.xcprivacy` (required-reason APIs, otherwise the upload is rejected with ITMS-91053): `NSPrivacyTracking = false`, `NSPrivacyCollectedDataTypes = []`, `NSPrivacyAccessedAPITypes` = `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` (app's own settings) and `NSPrivacyAccessedAPICategorySystemBootTime` with reason `35F9.1` (`mach_absolute_time` for frame timestamps).
- Export compliance: `ITSAppUsesNonExemptEncryption = NO` in Info.plist (only Apple's standard TLS/DTLS is used).
- App Review notes (`docs/APPSTORE.md` holds the text; copy it into App Store Connect): explain that a Mac companion is required, give the download URL, include a 60-second demo video link, list the test steps (install Mac app, grant Accessibility, open Pairing, scan QR). Provide a TestFlight build to the reviewer with the same notes.
- The app must be usable for review without a Mac: onboarding, settings, pairing UI, and the surface with an honest "No Mac connected" state all work offline.
- Marketing text never says "Magic Trackpad" as a product claim; "works like the trackpad on your Mac" is the phrasing. Never use Apple device renderings.

---

## 6. Mac companion — Trackglass for Mac

### 6.1 App shape

- `LSUIElement = YES` (no Dock icon). SwiftUI `MenuBarExtra` with a template-image icon (two rounded rectangles: trackpad outline + phone outline; design it as a 18 × 18 pt SF-Symbol-style PDF). Menu: connection status line, "Pair a device…", paired devices submenu (connect/forget), "Settings…", "Check for Updates…", "Quit".
- Windows (AppKit `NSWindow` hosting SwiftUI): **Pairing** (the QR code with a "Use a code instead" button that swaps in the PIN view, 480 × 360 pt, non-resizable, floats at `.floating` level), **Settings** (tabs: General, Devices, Advanced, About), **Welcome** (first launch: permissions walkthrough).
- Login item: `SMAppService.mainApp.register()` toggle in General, default **on** after the user completes Welcome.
- Single instance: if another copy is running (`NSRunningApplication` with the same bundle ID), activate it and quit.

### 6.2 Permissions

- **Accessibility**: required for `CGEventPost`. On launch call `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`. Welcome window shows status, a "Open System Settings" button (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`), and polls every 1 s until granted. The listener is not started until granted (prevents a confusing "connected but nothing moves").
- **Local Network** (macOS 15+ prompts for Bonjour advertising/browsing): Info.plist `NSLocalNetworkUsageDescription` and `NSBonjourServices` as on iOS.
- No Input Monitoring, no Screen Recording, no Automation permissions are needed or requested.

### 6.3 Server

- `BonjourAdvertiser`: two `NWListener`s with `service: NWListener.Service(name: <MacName>, type: "_trackglass._tcp", txtRecord:)` and `_trackglass._udp`, same instance name (`Host.current().localizedName`), `includePeerToPeer = true`. TXT: `v=1`, `id=<macPeerID>`, `nm=<name>`, `pr=0`, `im=1|2` (injector mode). The third, pairing-only listener of §3.4 is created and destroyed by `PairingService`.
- `ControlListener` accepts TLS connections (every paired phone's key registered on the listener, §3.3), reads HELLO, consults `SessionCoordinator.admit(peer:)`, sends WELCOME.
- `InputListener` accepts DTLS connections; the first datagram's PSK identity must equal the active session's phone `peerID`; otherwise cancel.
- Heartbeats keep the DTLS association warm; if 3 s pass without datagrams while connected, STATUS reports `engineState = idle` and the engine is reset.

### 6.4 TrackpadPreferences — mirroring the Mac's own settings

`TrackpadPreferences` is a `final class` producing an immutable `TrackpadSettings` snapshot. It reads with `CFPreferencesCopyAppValue` / `CFPreferencesCopyValue(…, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)` after `CFPreferencesAppSynchronize`, every **2 s** on a utility queue and immediately on session start; the pipeline hands the new snapshot to the engine, which applies it the next time it is idle (no tracked contacts, no open grace window, no momentum) and otherwise keeps the old snapshot until then (§8.16). Read both the built-in/USB domain `com.apple.AppleMultitouchTrackpad` and the Bluetooth domain `com.apple.driver.AppleBluetoothMultitouch.trackpad`; when they differ, prefer the Bluetooth domain if a Bluetooth trackpad is connected, otherwise the built-in domain. "Connected" is decided on every poll with `IOHIDManagerCopyDevices`: a device whose `kIOHIDTransportKey` is `"Bluetooth"` and whose `kIOHIDPrimaryUsagePageKey` is `0x0D` (Digitizer) or whose `kIOHIDProductKey` contains "Trackpad". **Verify every key on the reference Mac with `defaults read` in M8 and correct the table in code if the OS has renamed anything; log unknown values at `.info`.**

| Setting | Domain → key | Values | Engine use |
|---|---|---|---|
| Tap to click | `com.apple.AppleMultitouchTrackpad` → `Clicking` (also `NSGlobalDomain` `com.apple.mouse.tapBehavior`) | bool / 0,1 | If **off**, Trackglass still clicks on tap (there is no physical click on glass) and shows a one-time notice. |
| Secondary click | `TrackpadRightClick` (bool) + `TrackpadCornerSecondaryClick` (0 off, 1 bottom-left, 2 bottom-right — verify on the reference Mac in M4 before relying on it; SETTINGS `secondaryClickMode` 2 = bottom-right, 3 = bottom-left) | | 2-finger tap vs corner tap |
| Look up & data detectors | `NSGlobalDomain -currentHost` `com.apple.trackpad.forceClick` (bool), `TrackpadThreeFingerTapGesture` (0 off, 2 = look up) | | Force click (1 finger) vs 3-finger tap |
| Force click enabled | `com.apple.trackpad.forceClick` + `ForceSuppressed` | | §6.5.9 |
| Tracking speed | `NSGlobalDomain` `com.apple.trackpad.scaling` | 0, 0.125, 0.5, 0.6875, 0.875, 1, 1.5, 2, 2.5, 3 (slider ticks) | §6.6 accelIndex |
| Natural scrolling | `NSGlobalDomain` `com.apple.swipescrolldirection` | bool (true = natural) | §6.9.2 sign + field 137 |
| Scroll enabled | `TrackpadScroll`, `TrackpadHorizScroll` | bool | |
| Momentum | `TrackpadMomentumScroll` | bool | §6.8 |
| Zoom in/out (pinch) | `TrackpadPinch` | bool | §6.9 |
| Smart zoom | `TrackpadTwoFingerDoubleTapGesture` | bool | §6.9 |
| Rotate | `TrackpadRotate` | bool | §6.9 |
| Swipe between pages | `NSGlobalDomain` `AppleEnableSwipeNavigateWithScrolls` (two-finger scroll) and `TrackpadThreeFingerHorizSwipeGesture` (0 off, 1 = swipe between pages with 3 fingers, 2 = swipe between full-screen apps with 3 fingers) | | §6.9 navigation vs dock swipe |
| Swipe between full-screen apps | `TrackpadThreeFingerHorizSwipeGesture = 2` or `TrackpadFourFingerHorizSwipeGesture = 2` | | finger count for Spaces |
| Notification Center | `TrackpadTwoFingerFromRightEdgeSwipeGesture` (3 = on) | | §6.9 |
| Mission Control | `TrackpadThreeFingerVertSwipeGesture = 2` or `TrackpadFourFingerVertSwipeGesture = 2`; Dock `com.apple.dock` `showMissionControlGestureEnabled` | | finger count |
| App Exposé | same vertical keys (down direction); Dock `showAppExposeGestureEnabled` | | |
| Launchpad | `TrackpadFourFingerPinchGesture = 2` (also 5-finger `TrackpadFiveFingerPinchGesture`); Dock `showLaunchpadGestureEnabled` | | |
| Show Desktop | same pinch keys, spread direction; Dock `showDesktopGestureEnabled` | | |
| Three-finger drag | `TrackpadThreeFingerDrag` (bool; also `NSGlobalDomain -currentHost` `com.apple.trackpad.threeFingerDragGesture`) | | §6.5.6 |
| Drag lock / dragging | `DragLock`, `Dragging` | bool | §6.5.6 |
| Double-click interval | `NSEvent.doubleClickInterval` (API) | seconds | §6.5.5 |
| Pointer acceleration curves | IORegistry of the built-in trackpad: `HIDAccelCurves`, `HIDPointerResolution`, `HIDPointerReportRate`, plus `HIDScrollAccelCurves` if present | | §6.6, §6.8 |

The phone's optional **tracking-speed override** (−1…+1) is applied as `accelIndex = clamp(macScaling + override, 0, 3)`. Default 0 = exactly the Mac's setting.

### 6.5 GestureEngine (pure Swift, platform-independent, fully unit-tested)

#### 6.5.1 Inputs and outputs

The engine consumes `TrackglassKit.TouchFrame` exactly as decoded (§4.4); it defines no frame type of its own. Its public surface:

```swift
public final class GestureEngine {
  public init(settings: TrackpadSettings, geometry: EngineGeometry, acceleration: AccelerationModel)
  public func process(_ frame: TouchFrame, into events: inout EventBuffer)
  public func tick(now: UInt64, into events: inout EventBuffer)          // estimated phone time, §4.7
  public func setSettings(_ s: TrackpadSettings)                          // applied when idle, §6.4
  public func setGeometry(_ g: EngineGeometry, into events: inout EventBuffer) // cancels every active gesture, resets, §8.7
  public func forceLiftoff(releaseDragLock: Bool, into events: inout EventBuffer) // §6.5.10
  public var needsTick: Bool { get }   // true while contacts are tracked, a grace window is open, momentum runs, or any deferred event (e.g. a pending secondary click) is waiting; InputPipeline keeps the 8 ms timer armed exactly while this is true
}
public struct EngineGeometry { var widthMM: Double; var heightMM: Double; var isLandscape: Bool }
public enum GestureEvent: Codable, Equatable {   // Codable with the JSON shape below, shared by EngineTests and tgreplay
  case pointerMove(dx: Double, dy: Double)                       // accelerated, in points
  case button(kind: ButtonKind, phase: ButtonPhase, clickCount: Int)   // .left/.right, .down/.up
  case scroll(dxPoints: Double, dyPoints: Double, phase: GesturePhase, naturalInverted: Bool)
  case scrollMomentum(phase: MomentumPhase, dxPoints: Double, dyPoints: Double)   // emitted from tick(now:) by the engine's ScrollMomentum recognizer (§6.8)
  case magnify(delta: Double, phase: GesturePhase)
  case rotate(deltaDegrees: Double, phase: GesturePhase)
  case smartZoom
  case dockSwipe(kind: DockSwipeKind /*horizontal|vertical|pinch*/, progressDelta: Double, phase: GesturePhase, exitVelocity: Double) // exitVelocity ≠ 0 only on .ended/.cancelled
  case navigationSwipe(direction: SwipeDirection)
  case notificationCenter
  case forceClick(stage: Int)                                    // 2 = force stage
  case lookUpAtPointer                                           // three-finger tap
  case haptic(HapticKind)
  case gestureBegin, gestureEnd                                  // bracketing for AppKit begin/end gesture events
}
```

`process` and `tick` are deterministic given `(frames, ticks, settings, geometry)`. `EventBuffer` is a fixed-capacity (32) inline buffer owned by `InputPipeline` and cleared before each call; the engine never allocates per frame (overflow is a programming error → `assertionFailure` in debug, drop in release). The engine owns no timers; time-based behaviors (hold-to-force-click, drag-release grace, tap timeouts, pending smart zoom, momentum steps) are evaluated when the next frame arrives **and** by `tick(now:)`, which the pipeline calls every `ENGINE_TICK = 8 ms` while contacts are tracked, a grace window is open, or momentum is running, with `now` = estimated phone time (§4.7). Tests call `tick` with synthetic times.

**`GestureEvent` JSON shape** (fixtures, `tgreplay`): one object per event, `t` = case name, every associated value under its label, enum payloads encoded as their case-name strings, numbers compared with 1e-6 tolerance. `MomentumPhase` cases are `begin`, `continued`, `end` (not `continue`, a keyword). Examples, one per case:
`{"t":"pointerMove","dx":2.5,"dy":-1.0}` · `{"t":"button","kind":"left","phase":"down","clickCount":2}` · `{"t":"scroll","dxPoints":0,"dyPoints":-12.0,"phase":"changed","naturalInverted":true}` · `{"t":"scrollMomentum","phase":"continued","dxPoints":0,"dyPoints":-3.2}` · `{"t":"magnify","delta":0.05,"phase":"changed"}` · `{"t":"rotate","deltaDegrees":-3.0,"phase":"changed"}` · `{"t":"smartZoom"}` · `{"t":"dockSwipe","kind":"horizontal","progressDelta":-0.1,"phase":"changed","exitVelocity":0}` · `{"t":"navigationSwipe","direction":"left"}` · `{"t":"notificationCenter"}` · `{"t":"forceClick","stage":2}` · `{"t":"lookUpAtPointer"}` · `{"t":"haptic","kind":"click"}` · `{"t":"gestureBegin"}` · `{"t":"gestureEnd"}`.

#### 6.5.2 Contact tracking and palm rejection

- Maintain `Contact {id, startTime, startPos, pos, prevPos, lastTime, path length, majorRadius, isResting}` keyed by `contactID`.
- **Palm/thumb rejection:** a contact with `majorRadius > 11 mm` at began is flagged `isPalm` and ignored for the rest of its life. A contact that begins in the bottom 18 mm of the surface and stays within 1.5 mm of its origin for 150 ms while another contact moves is flagged `isResting` (Apple's "hand resting") and excluded from finger counting until it moves more than 3 mm. Fixed rules; not user-configurable.
- **Effective finger count** `n` = number of non-palm, non-resting contacts.

#### 6.5.3 Mode selection (the settle window)

When the first contact begins, the engine enters `settling` for **60 ms** (`SETTLE_WINDOW`). Pointer movement is **not** withheld during settling (1-finger pointing must be instant); instead, if a second (or third…) finger arrives inside the window, the engine switches mode to `n` fingers **immediately** (the new mode's own activation thresholds apply from that frame on, including inside the window) and any pointer motion already emitted stays (it is at most ~2 mm of travel and matches how a real trackpad behaves). The window only governs *upward* finger-count changes: after it closes, the mode is fixed by the count at that moment; additional fingers landing later (e.g. a thumb) are treated as resting, except that in `pointer` mode a new finger landing while the primary has travelled less than `TAP_MAX_MOVEMENT` makes the pair a two-finger-tap candidate (§6.5.5).

Modes: `idle`, `pointer(1)`, `scroll(2)` (also hosts magnify/rotate/smart-zoom/secondary tap), `swipe3`, `swipe4`, `pinch5`, `drag` (any mode can transition into drag per §6.5.6).

**Mode-entry/exit events are mode-level, not recognizer-level:** entering `scroll(2)` emits `.scroll(.mayBegin)` immediately; leaving `scroll(2)` without any sub-gesture having activated emits `.scroll(.cancelled)` (then the two-finger-tap rule is evaluated). These two events exist from the first engine milestone (M4.3), so fixtures written then stay valid when the scroll recognizer arrives.

**Resting-thumb re-evaluation:** when a contact is flagged `isResting` (§6.5.2) and the effective count therefore drops, the engine re-evaluates the mode immediately: if no sub-gesture of the current mode has activated, it returns to the mode for the new count (emitting `.scroll(.cancelled)` if `.mayBegin` had been emitted); an activated sub-gesture keeps its mode until lift. Fixture `resting_thumb_ignored`: index finger lands at t = 0 and moves 30 mm over 400 ms; thumb lands at t = 20 ms in the bottom 18 mm and never moves; expected output is pointer motion only, bracketed by `.scroll(.mayBegin)` at the thumb's landing and `.scroll(.cancelled)` at t = 170 ms when the thumb is flagged resting.

#### 6.5.4 Pointer (1 finger)

Each frame in `pointer` mode: `raw = pos − prevPos` (mm), `dt = time − lastTime`. If `dt ≤ 0` skip. Convert with `PointerAcceleration.accelerate(dxMM, dyMM, dt)` (§6.6) and emit `.pointerMove`. Movement below 0.05 mm is accumulated, not dropped. Velocity for the accelerator is computed from the raw mm deltas and the phone timestamps.

#### 6.5.5 Taps and clicks

Constants (Tunable, Appendix A): `TAP_MAX_DURATION = 0.30 s`, `TAP_MAX_MOVEMENT = 2.0 mm` (path length), `MULTI_TAP_SPREAD = 5.0 mm` (second tap must land within this of the first), `TWO_FINGER_TAP_STAGGER = 0.10 s`.

- **Click:** one finger, began→ended within `TAP_MAX_DURATION`, path < `TAP_MAX_MOVEMENT`, no other contact present during its life → `.button(.left,.down,1)`, `.button(.left,.up,1)`, `.haptic(.click)`. Click count: if the previous click ended less than `NSEvent.doubleClickInterval` ago and within `MULTI_TAP_SPREAD`, `clickCount = previous + 1` (cap 3).
- **Secondary click:** (a) `TrackpadRightClick` on: two fingers whose begans are within `TWO_FINGER_TAP_STAGGER`, both end within `TAP_MAX_DURATION` of the first began, combined path < `TAP_MAX_MOVEMENT` each → right down/up + `.haptic(.secondaryClick)` (immediately when smart zoom is off; deferred per §6.5.7 when it is on). (b) `TrackpadCornerSecondaryClick = 1|2`: a one-finger tap whose began point is inside the 22 × 22 mm bottom-left (value 1) or bottom-right (value 2) corner → right click (mapping per §6.4, confirmed in M4.4). Corner takes precedence over left click.
- **Click count:** `clickCount = previous + 1` when the previous click ended less than `doubleClickInterval` ago and within `MULTI_TAP_SPREAD` (cap 3). *When* the repeat press is emitted depends on the Mac's `Dragging` (tap-and-a-half) setting: `Dragging` **on** → `down(n)` is emitted on the repeat tap's *began* (so it can become a drag, §6.5.6) and `up(n)` on its ended if it did not move; `Dragging` **off** → the repeat tap is a plain tap: `down(n)` and `up(n)` are both emitted on its *ended* (a held or moved finger is just pointer motion, never a drag). Fixtures `double_tap`/`triple_tap` use `Dragging = 0`; `double_tap_dragging_on` and the `tap_drag*` fixtures use `Dragging = 1`.
- **Three-finger tap** with `TrackpadThreeFingerTapGesture = 2` → `.lookUpAtPointer`.
- Clicks are emitted at the pointer's current location (the injector supplies it); taps never move the pointer.

#### 6.5.6 Drag

- **Tap-and-a-half (Dragging on):** a click (tap) followed by a new contact beginning within `NSEvent.doubleClickInterval` and within `MULTI_TAP_SPREAD`: emit `.button(.left,.down,2)` immediately on the second began (click count 2, exactly what macOS sends for a double-click-and-drag). If that contact ends within `TAP_MAX_DURATION` having moved less than `TAP_MAX_MOVEMENT`, emit `.button(.left,.up,2)` — it was a double-click. Otherwise motion is `.pointerMove` while the button is held (the injector turns this into `leftMouseDragged`). On lift: if `DragLock` is on, keep the button down until the next tap anywhere (`.haptic(.dragLockEngaged)` on lift, `.dragLockReleased` on the releasing tap). If `DragLock` is off, keep the button down for `DRAG_RELEASE_GRACE = 0.30 s` (Tunable) after lift so the finger can be repositioned; a new contact inside the grace window continues the drag; otherwise emit `.button(.left,.up,2)`.
- **Three-finger drag:** when `TrackpadThreeFingerDrag` is on, three fingers moving together (centroid moved > 2 mm) → `.button(.left,.down,1)` then `.pointerMove` from the centroid delta; lift behaves like tap-and-a-half with the same grace/lock rules.
- **Force-click drag** is not emulated (no pressure on glass).

#### 6.5.7 Two-finger scroll (and the compound gesture rules)

Enter `scroll(2)` when `n == 2` after settling. Track `centroid`, `distance` (between contacts), and `angle` (atan2 of the vector between contacts). Each sub-gesture activates independently when it crosses its threshold and stays active until lift; a frame may emit scroll **and** magnify **and** rotate (macOS lets apps combine them):

- **Scroll:** activates when the centroid path exceeds `SCROLL_ACTIVATION = 1.5 mm`. Per frame `dMM = centroid − prevCentroid`. Points = `ScrollAcceleration.accelerate(dMM, dt)` (§6.8). Sign: in natural mode content follows the fingers. Emit `.scroll(dx, dy, phase)` with phase `.began` on activation (preceded by `.mayBegin` on second-finger landing), `.changed` after, `.ended` on lift (zero deltas), `.cancelled` if the gesture ended without ever activating (then evaluate the two-finger tap rule). `TrackpadHorizScroll = false` zeroes dx.
- **Magnify:** requires `TrackpadPinch`. Activates when `|distance − startDistance| > PINCH_ACTIVATION = 2.5 mm`. Per frame `delta = distance / prevDistance − 1`. Emit `.magnify(delta, phase)`.
- **Rotate:** requires `TrackpadRotate` and `distance > 15 mm`. Activates when `|angle − startAngle| > ROTATE_ACTIVATION = 5°`. Per frame `deltaDegrees = unwrap(angle − prevAngle)`, counter-clockwise positive. Emit `.rotate`.
- **Smart zoom:** only when `TrackpadTwoFingerDoubleTapGesture` is on: two-finger double tap (two two-finger taps within `doubleClickInterval`, each qualifying as in §6.5.5) → `.smartZoom`. To disambiguate, the first two-finger tap's secondary click is held pending for `doubleClickInterval`; if a second two-finger tap arrives → `.smartZoom` (no secondary click); else the secondary click is emitted late. When smart zoom is off, the secondary click is emitted immediately. Decision: the delay (≤ 0.5 s) is accepted because a real trackpad has the same disambiguation delay.
- **Two-finger swipe from right edge:** both contacts begin within `EDGE_ZONE = 3 mm` of the right edge (in the surface's current orientation) and move left > 8 mm → `.notificationCenter` once; the gesture is consumed (no scroll).
- **Navigation (two-finger)** is not a separate event: when `AppleEnableSwipeNavigateWithScrolls` is on, Safari and others derive it from scroll events plus the type-29 scroll gesture companion (§6.9.3). The engine does nothing special.

#### 6.5.8 Three/four/five-finger gestures

- Horizontal swipe with `k` fingers (3 or 4): if `TrackpadThreeFingerHorizSwipeGesture`/`FourFinger… = 2` for that `k` → **Spaces**: emit `.dockSwipe(.horizontal, progressDelta, phase, exitVelocity)` with `progressDelta = −dxMM / SPACES_MM_PER_SPACE` where `SPACES_MM_PER_SPACE = 110 mm` (Tunable; acceptance C7: one 110 mm swipe switches exactly one Space and tracks the finger live). When a horizontal dock swipe ends with accumulated `|progress| ≥ 0.5`, also emit `.haptic(.spaceSwitched)`. If the three-finger setting is `1` → `.navigationSwipe(.left/.right)` once the centroid moves > `NAV_SWIPE_DISTANCE = 20 mm` horizontally (direction = finger direction).
- Vertical swipe with `k` fingers where `…VertSwipeGesture = 2` for that `k`: up → Mission Control, down → App Exposé: `.dockSwipe(.vertical, progressDelta = −dyMM / MISSION_CONTROL_MM = 60 mm, phase)`. The Dock decides Mission Control vs App Exposé from the sign (verify in M7; MMF's convention is origin offset positive = up).
- Four- or five-finger pinch (`…PinchGesture = 2`): compute the mean distance from the centroid; a decrease of > 8 mm → Launchpad, an increase → Show Desktop: `.dockSwipe(.pinch, progressDelta = (meanDist − prevMeanDist)/PINCH_MM_FULL = 40 mm, phase)`.
- Direction lock: the first axis to exceed 6 mm of centroid travel wins for that gesture; the other axis is ignored until lift.
- Phases: `.began` on activation, `.changed` per frame, `.ended` on lift; if the last 3 frames moved opposite to the accumulated progress, end with `.cancelled` (Dock then snaps back). `exitVelocity` = the last frame's `progressDelta × 100` on `.ended/.cancelled`, `0` otherwise; the injector reads it and never recomputes it.
- Dock-enabled checks: if the corresponding `com.apple.dock` gesture key is false, do nothing.

#### 6.5.9 Force click (1 finger, hold)

If `forceClick` is enabled: one finger, stationary (< 1.0 mm travel) for `FORCE_HOLD = 0.60 s` (Tunable) with no other contact → `.forceClick(stage: 2)` + `.haptic(.forceClickStage2)`. The hold is cancelled by movement or by lift. After a force click, the contact is marked `consumed`: lifting it does not produce a click.

#### 6.5.10 Lift-off and resets

A synthetic lift-off frame from the phone ends every active gesture with `.ended` (or `.cancelled` for never-activated ones), releases held buttons **unless drag lock is engaged** (drag lock is a deliberate user state), clears contacts and returns to `idle`. A lift-off caused by the 1.5 s timeout, a BYE, or connection loss does the same but releases **every** button including a drag lock (§4.7, §8.8).

### 6.6 PointerAcceleration — macOS's own algorithm, reproduced

Apple publishes the pointer-acceleration code in IOHIDFamily (`IOHIDEventSystemPlugIns/IOHIDAccelerationAlgorithm.cpp` and `IOHIDAcceleration.cpp`, APSL-2.0). Port it in Swift as `ParametricAccelerationCurve` + `PointerAccelerator`, with this header comment on each file: `// Algorithm reproduced from Apple's IOHIDFamily (IOHIDAccelerationAlgorithm.cpp), Apple Public Source License 2.0. See docs/THIRD-PARTY.md.`

**Curve model** (per curve dictionary from the Mac): `Index`, `GainLinear`, `GainParabolic`, `GainCubic`, `GainQuartic`, `TangentSpeedLinear`, `TangentSpeedParabolicRoot` (keys in the registry: `HIDAccelIndex`, `HIDAccelGainLinear`, `HIDAccelGainParabolic`, `HIDAccelGainCubic`, `HIDAccelGainQuartic`, `HIDAccelTangentSpeedLinear`, `HIDAccelTangentSpeedParabolicRoot`; values are 16.16 fixed point → divide by 65536).

**Curve selection:** given `accelIndex` (= tracking speed, 0…3), pick the curve with the largest `Index ≤ accelIndex`; if a next curve exists and `Index < accelIndex`, linearly interpolate every parameter by `ratio = (accelIndex − Index_i)/(Index_{i+1} − Index_i)`.

**Segment construction** (a summary of Apple's code, including its use of `pow(gain * x, n)` forms and its second-branch slope; the pseudocode is for orientation only — transcribe the real logic from `IOHIDAccelerationAlgorithm.cpp`, and where the two differ Apple's code wins). Both tangents start at `+∞` (Apple uses `DBL_MAX`) so a segment that is never configured is never entered:

```
tangent0 = tangent1 = +inf
f1(x) = GL*x + (GP*x)^2 + (GC*x)^3 + (GQ*x)^4
if TSL != 0:
    y0 = f1(TSL)
    m0 = GL + 2*TSL*GP^2 + 3*TSL^2*GC^3 + 4*TSL^3*GQ^4
    b0 = y0 - m0*TSL ;  tangent0 = TSL
    if TSPR != 0:  y1 = m0*TSPR + b0 ; m1 = 2*y1*m0 ; b1 = y1^2 - m1*TSPR ; tangent1 = TSPR
elif TSPR != 0:
    y0 = f1(TSPR); m1 = GL + 2*TSPR*GP^2 + 3*TSPR^2*GC^3 + 4*TSPR^3*GQ^4 ; b1 = y0^2 - m1*TSPR ; tangent0 = TSPR
multiplier(v):  v' = v / (resolution / rate)
    if v' <= tangent0: f1(v')
    elif v' <= tangent1 and tangent0 == TSL: m0*v' + b0
    else: sqrt(m1*v' + b1)
    return result * (96.0/67.0)
```

**Per-frame application** (Apple's `IOHIDPointerAccelerator::accelerate`): `rateMultiplier = period_ms / max(deltaT_ms, period_ms)` with `period_ms = 1000/rate`; `velocity = floor(hypot(dx, dy)) * rateMultiplier` (minimum 1/65536); `mult = multiplier(velocity) / velocity`; `dx *= mult; dy *= mult`. Here `dx, dy` are in **device counts per report**. Trackglass converts millimeters to counts with `countsPerMM = resolution / 25.4` (`resolution` = `HIDPointerResolution` ÷ 65536, counts per inch; `rate` = `HIDPointerReportRate`, reports per second), feeds the algorithm, multiplies the result by `OUTPUT_SCALE` (1.0 unless calibration C1–C3 proves a constant unit mismatch, in which case the measured ratio is recorded in Appendix A) and posts the result as points. The `rateMultiplier` step makes the algorithm independent of the phone's actual frame rate, so 60 Hz and 120 Hz devices produce the same pointer travel for the same finger motion.

**Where the numbers come from:** on the reference MacBook run `Tools/tgaccel` (reads the IORegistry entry of the built-in trackpad — the `AppleMultitouchDevice`/`AppleMultitouchTrackpadHIDEventDriver` service — and prints `HIDAccelCurves`, `HIDPointerResolution`, `HIDPointerReportRate` and, if present, `HIDScrollAccelCurves` as JSON). Commit that JSON as `Mac/Resources/DefaultAccelCurves.json` and use it as the built-in default. At runtime, if the Mac has a trackpad (built-in or Magic Trackpad), read the live values and prefer them; otherwise use the bundled JSON. If, on the reference Mac, `HIDAccelCurves` is missing and only `HIDPointerAccelerationTable` exists, implement the table variant from the same Apple file (`IOHIDTableAcceleration`) instead — Gate G-ACC in M5 decides which one the reference Mac uses; implement that one first and the other only if a supported Mac is found to need it.

Fallback when neither is available on a given Mac and the bundle JSON fails to parse (should never happen): a single parametric curve `GL = 1.0, GP = 0.8, GC = 0.0, GQ = 0.0, TSL = 4.0, TSPR = 8.0, Index = 1` with `resolution = 1000, rate = 125`. Log an error.

### 6.7 PointerState (injector-side)

- Reads the current pointer location at the start of every pipeline tick from `CGEvent(source: nil)!.location` (global CG coordinates, origin top-left of the main display). This keeps Trackglass consistent when the user also moves a physical mouse.
- Accumulates sub-point remainders in `Double`s; posts `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)` with `.mouseMoved` (or `.leftMouseDragged` / `.rightMouseDragged` when a button is held) and sets `mouseEventDeltaX/Y` integer fields to the rounded deltas so delta-reading apps (games, remote desktops) work.
- Multi-display clamp: compute the union of `CGDisplayBounds` for `CGGetActiveDisplayList`. If `new` lies in any display → accept. Else try `(new.x, cur.y)` then `(cur.x, new.y)` (sliding along edges), else clamp into the display that contains `cur`. Re-query displays on `CGDisplayRegisterReconfigurationCallback`.
- Display wake: on the first frame after ≥ 10 s of idleness call `IOPMAssertionDeclareUserActivity(name, kIOPMUserActiveLocal, &id)` so a sleeping display wakes like it does for a real trackpad.
- Event source: one `CGEventSource(stateID: .hidSystemState)` for the process; set `localEventsSuppressionInterval = 0` and `setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: .eventSuppressionStateSuppressionInterval)` so posting never suppresses the user's physical devices.
- All events are posted to `.cghidEventTap` except Dock swipes, which go to `.cgSessionEventTap` (as established by Mac Mouse Fix; Dock ignores them at the HID tap).

### 6.8 ScrollAcceleration and ScrollMomentum

- **Gain:** if the Mac exposes `HIDScrollAccelCurves` for its trackpad, port Apple's `IOHIDScrollAccelerator` (same file, constants `SCROLL_EVENT_AVARAGE_LENGHT = 9`, `SCROLL_CLEAR_THRESHOLD_MS = 500`, `SCROLL_EVENT_THRESHOLD_MS = 150`, `SCROLL_MULTIPLIER_A = 2/65536`, `B = 0x3bb/65536`, `C = 0x18041/65536`, `SCROLL_PIXEL_TO_WHEEL_SCALE = 0x199a/65536`, `FRAME_RATE = 67`) with the same resolution/rate as the pointer. **Gate G-SCR (M6):** if the property is absent on the reference Mac, use the constant model `points = mm × SCROLL_BASE_GAIN × (1 + SCROLL_ACCEL_GAIN × (1 − e^(−v/SCROLL_ACCEL_V0)))` with `v` in mm/s and `SCROLL_BASE_GAIN = 3.8 pt/mm`, `SCROLL_ACCEL_GAIN = 0.5`, `SCROLL_ACCEL_V0 = 350 mm/s` (Tunable; acceptance C4 in §10.3).
- **Events:** every scroll frame posts a continuous scroll-wheel event (§6.9.2). Deltas are in points (`PointDeltaAxis` fields); line deltas = points / 10 with sub-line accumulation; fixed-point deltas = line deltas in 16.16.
- **Momentum** (when `TrackpadMomentumScroll` is on) is the engine's `ScrollMomentum` recognizer, driven by `tick(now:)` (§6.5.1): on scroll `.ended`, exit velocity = mean velocity (points/s) over the last 3 frames (ignore frames older than 50 ms). If `|v| < MOMENTUM_MIN_START = 60 pt/s` → no momentum. Else on every tick: `dt = now − lastTick`, `delta = v × dt`, `v *= pow(MOMENTUM_DECAY_PER_MS, dt_ms)` (`0.998`, Tunable), stop when `|v| < MOMENTUM_STOP = 5 pt/s`. Emit `.scrollMomentum(.begin)` on the first tick, `.continued` afterwards, `.end` with zero delta at the end. Any new contact (a frame with a `began`) cancels momentum: the engine emits an immediate `.scrollMomentum(.end)` followed by `.scroll(.mayBegin)` and `.scroll(.cancelled)` (prevents app-side auto-momentum from continuing) before processing the new contact. Momentum is fully testable with fixtures because it depends only on frames and ticks.

### 6.9 QuartzInjector — exact event construction

Every private numeric field below was established from Mac Mouse Fix's `TouchSimulator.m` / `GestureScrollSimulator.m` (read them to confirm; write your own code). Field numbers are `CGEventField(rawValue:)`. Where a field is undocumented, declare it once in `PrivateAPI/TGPrivateFields.h` with a comment stating the source.

#### 6.9.1 Pointer and buttons (public API)
- Move: `.mouseMoved` / `.leftMouseDragged` / `.rightMouseDragged` as in §6.7.
- Click: `.leftMouseDown`/`.leftMouseUp` (`.rightMouseDown/Up`), `mouseEventClickState` = clickCount, location = current pointer. Down and up are two separate posts; between them for a plain tap post nothing.
- Look Up (three-finger tap or Force-click fallback): keyboard event Ctrl+Cmd+D (`CGEvent(keyboardEventSource:virtualKey: 0x02 /*D*/, keyDown:)` with flags `[.maskControl, .maskCommand]`, then key up).

#### 6.9.2 Scroll (continuous trackpad semantics; fields 55 and 137 are raw numbers declared in `TGPrivateFields.h`, the rest are public `CGEventField` cases)
Create `CGEvent(source: src)`; set `type = .scrollWheel`; set fields:

| Field | Value |
|---|---|
| 55 (event type) | 22 |
| 88 `scrollWheelEventIsContinuous` | 1 |
| 137 (directionInvertedFromDevice) | 1 if natural scrolling is on else 0 |
| 11 / 12 `scrollWheelEventDeltaAxis1/2` | integer line deltas (y / x) |
| 96 / 97 `scrollWheelEventPointDeltaAxis1/2` | point deltas (y / x), integers |
| 93 / 94 `scrollWheelEventFixedPtDeltaAxis1/2` | line deltas as 16.16 |
| 99 `scrollWheelEventScrollPhase` | 128 mayBegin, 1 began, 2 changed, 4 ended, 8 cancelled, 0 for momentum frames |
| 123 `scrollWheelEventMomentumPhase` | 0 none, 1 begin, 2 continue, 3 end |

Axis 1 is vertical. Positive axis-1 delta = content moves **down** (user sees earlier content), the same sign a mouse wheel rolled away from the user produces. Natural scrolling on: `delta = +dyMM-derived points` when the fingers move down the surface (content follows fingers). Natural off: negate. **Gate G-DIR (M6):** verify on the reference Mac that posted events are not re-inverted by the system; if they are, drop Trackglass's own inversion and keep field 137 — never ship a double inversion.

Set the event location to the pointer. Post to `.cghidEventTap`. For every non-momentum phase also post the **gesture companion** (§6.9.3).

#### 6.9.3 Gesture events (private fields; type 29)
`CGEvent(source: src)`, `setType(29)` and set field 55 = 29. Common fields: 110 = IOHIDEventType, 132 = phase (same phase values as scroll phase). Then:

| Gesture | Field 110 | Other fields |
|---|---|---|
| Scroll companion | 6 (`kIOHIDEventTypeScroll`) | 116 = dx gesture, 119 = dy gesture (doubles; MMF scales the point delta by 1.67 — do the same), 132 = phase |
| Magnify | 8 (`kIOHIDEventTypeZoom`) | 113 = magnification delta (double), 132 = phase |
| Rotate | 5 (`kIOHIDEventTypeRotation`) | 114 = rotation degrees (double), 132 = phase |
| Smart zoom | 22 (`kIOHIDEventTypeZoomToggle`) | single event, no phase |
| Navigation swipe | 16 (`kIOHIDEventTypeNavigationSwipe`) | 115 = direction mask (1 up, 2 down, 4 left, 8 right), 132 = phase; sequence: began with direction, then ended with direction 0 |
| Gesture begin / end | 61 / 62 | bracket magnify/rotate sequences (AppKit `NSEventTypeBeginGesture/EndGesture`) |

Post to `.cghidEventTap`. Magnify/rotate sequence: `gestureBegin` → `.began` → `.changed`… → `.ended` → `gestureEnd`.

#### 6.9.4 Dock swipes (private; two OS paths)
`DockSwipeKind` → type: 1 horizontal (Spaces), 2 vertical (Mission Control / App Exposé), 3 pinch (Launchpad / Show Desktop). Keep an `originOffset` accumulator: `began` sets it to the delta, `changed` adds, `ended`/`cancelled` sends the final value and the exit speed carried in the event's `exitVelocity`. Post to `.cgSessionEventTap`. After `ended`/`cancelled`, re-post the same end event at +0.2 s and +0.5 s (MMF's workaround for the Dock occasionally missing the end under load).

- **macOS 14–26:** two events per step. `e29`: type 29, field 55 = 29, field 41 = 33231. `e30`: type 30, field 55 = 30, field 110 = 23 (`kIOHIDEventTypeDockSwipe`), 132 = phase, 134 = phase, 124 = originOffset (double), 135 = bit pattern of `Float(originOffset)` stored as int64, 41 = 33231, 119 and 139 = a type-specific denormal double (horizontal `1.4e-45`, vertical `2.8e-45`, pinch `4.2e-45` — i.e. the Float32 bit patterns 1, 2, 3 reinterpreted), 123 and 165 = dock swipe type, 136 = 1 if inverted-from-device else 0, and on ended/cancelled 129 and 130 = exit speed. Post `e29` then `e30`.
- **macOS 27+:** one type-30 event with an attached HID event: create `HIDEvent(type: 23, timestamp: 0, senderID: 0)` (private `HID.framework` class, obtained with `NSClassFromString("HIDEvent")` after `dlopen("/System/Library/PrivateFrameworks/HID.framework/HID")`; if that path is wrong on the build machine, locate it with `otool -L` on `/usr/bin/hidutil`), `options = phase << kIOHIDEventEventOptionPhaseShift`, integer field `kIOHIDEventFieldDockSwipeMotion` = kind, `kIOHIDEventFieldDockSwipeFlavor` = `kIOHIDGestureFlavorDockPrimary`, double field `kIOHIDEventFieldDockSwipeProgress` = originOffset; on ended/cancelled append a child `HIDEvent(type: 9 /*Velocity*/)` with `VelocityX/Y` = exit speed and `Z = 0`; then `CGEventSetHIDEvent(e30, hidEvent)` (private C function in CoreGraphics/SkyLight, resolved with `dlsym(RTLD_DEFAULT, "CGEventSetHIDEvent")`). The numeric values of `kIOHIDEventFieldDockSwipe*`, `kIOHIDGestureFlavorDockPrimary` and the phase shift are in MMF's private headers; transcribe them with a source comment.
- Path selection lives in one injectable value `DockSwipePath` (`.legacyFields` or `.attachedHIDEvent`), chosen at runtime with `if #available(macOS 27, *)` by default and overridable from `InjectorTests` so both paths are exercised on one machine. **Before implementing M7.3, re-read the current Mac Mouse Fix `TouchSimulator.m`**: confirm the exact `@available` cut line it uses for the attached-HID-event path and the exact private symbol name (`CGEventSetHIDEvent` vs `CGEventSetIOHIDEvent`), and set the cut line and symbol to what the reference shows (record both in `docs/PROGRESS.md`). If any private symbol fails to resolve, `PrivateAPICapabilities.dockSwipe = false` (one `PrivateAPICapabilities` struct with a flag per private mechanism — `dockSwipe`, `gestureEvents`, `fluidTouchGesture`, `forceEvent` — resolved once at launch; the injector publishes the derived `degradedGestures` list, §8.17) and the engine falls back to keyboard shortcuts on gesture end: Spaces ← Ctrl+Left/Right, Mission Control = Ctrl+Up, App Exposé = Ctrl+Down, Launchpad = `open -a Launchpad` is **not** used (Launchpad was removed in macOS 26; fall back to F4/`NSWorkspace` "Apps" via the `kCGSymbolicHotKey` is unreliable — simply do nothing and log), Show Desktop = F11. Launchpad/Apps (macOS 26 replaced Launchpad with the Apps view) has no reliable keyboard fallback: do nothing and log. Fallbacks are discrete (no live tracking) and are logged at `.notice` so the gap is visible in diagnostics.

#### 6.9.5 Notification Center
Primary: a private `FluidTouchGesture` (type 27) with `GestureMotion = FromRightEdge` and flavor `NotificationCenterPrimary` is how the real driver signals it. **Gate G-NC (M7):** try it (fields per MMF/IOHIDFamily headers). If Notification Center does not open, use the deterministic fallback: with Accessibility, find the Control Center process's menu-bar extra named "Clock" (`AXUIElementCreateApplication(controlCenterPID)` → `kAXExtrasMenuBarAttribute` → children → `kAXDescriptionAttribute == "Clock"`) and `AXUIElementPerformAction(kAXPressAction)`. Ship whichever passes; keep the other as a runtime fallback.

#### 6.9.6 Force click
**Gate G-FORCE (M7):** attempt a type-29 event with field 110 = 32 (`kIOHIDEventTypeForce`) and the force stage/pressure fields (transcribe from IOHIDFamily `IOHIDEventFieldDefs`/MMF headers): stage 1 with pressure 0.5, then stage 2 with pressure 1.0 after 40 ms, then back to stage 0. Test in TextEdit over a word (Look Up popover must appear) and in Finder on a file (Quick Look must appear). If it works, ship it. If not, ship the fallback: left click (down/up) followed 30 ms later by Ctrl+Cmd+D, and log `.notice("force click: keyboard fallback")`.

### 6.10 Diagnostics, logging, replay

- `os_log` subsystem `app.trackglass.mac`, categories `net`, `engine`, `inject`, `prefs`. Touch coordinates are logged only at `.debug` and marked `.private`.
- `LatencyStats`: per-frame `receiveTime − sentAt`-based one-way estimate is unusable across clocks; instead measure Mac-side **pipeline latency** (receive → post) with a 1 000-sample histogram, and end-to-end with the PING RTT. Expose p50/p95 in Settings → Advanced and in STATUS messages.
- **`.tgrec` format** (defined once in `TrackglassKit/Recording/TGRecFormat`): file header `TGREC` + `u8 version = 1` + `u8 origin` (1 = recorded on the phone at send time, 2 = recorded on the Mac at receive time) + `u32 surfaceWidthMM×100`, `u32 surfaceHeightMM×100`; then records of `u64 captureTimeNs` (the recorder's own monotonic clock) + `u16 length` + the raw TOUCH_FRAME bytes. Both apps can record: the phone's Diagnostics "Record session" writes to the app's Documents directory and offers the file in a share sheet; the Mac's `ReplayRecorder` (Settings → Advanced) writes to `~/Library/Application Support/Trackglass/Recordings/<date>.tgrec`.
- **Fixture settings file (`<name>.settings.json`)** — schema, final:
  ```json
  {
    "settings": { "clicking": true, "trackpadRightClick": true, "cornerSecondaryClick": 0, "dragging": false, "dragLock": false, "threeFingerDrag": false, "...": "every TrackpadSettings property in lowerCamelCase; any key omitted takes the Appendix A default" },
    "geometry": { "widthMM": 65.1, "heightMM": 141.1, "isLandscape": false },
    "acceleration": { "model": "unitGain" },
    "ticks": [ 8000000, 16000000 ],
    "geometryChanges": [ { "atNs": 500000000, "geometry": { "widthMM": 141.1, "heightMM": 65.1, "isLandscape": true } } ],
    "doubleClickIntervalNs": 500000000
  }
  ```
  `ticks` and `geometryChanges` are applied in `atNs`/tick order, each before the first frame whose `frameTime` is greater than it. `"unitGain"` is exactly 1 point per millimeter for pointer **and** scroll with no acceleration, so expected deltas are exact and fixtures are independent of any later acceleration or gain change; `"constant"` with `"pointsPerMM"` and `"parametric"` with a curve JSON also exist for tests of the models themselves. A recorded fixture (name prefix `recorded_`, origin 2) is a **snapshot** fixture: its expected file is generated once by `tgreplay run` after the owner has confirmed the Mac behaved correctly during the recording, then committed.
- `Tools/tgreplay` (links `TrackglassKit` + `TrackglassEngine` only; it cannot inject): a fixture is the triplet `<name>.tgrec`, `<name>.settings.json` (above), `<name>.expected.json` (the `GestureEvent` JSON array of §6.5.1). Commands: `tgreplay run <name>.tgrec --settings <name>.settings.json` prints the event stream as JSON lines; `tgreplay verify-dir Tests/Fixtures` replays every triplet and exits non-zero on the first mismatch (used by `Scripts/ci.sh`); `tgreplay invariants <name>.tgrec --settings … --drop <fraction> --seed <n>` drops datagrams pseudo-randomly and checks only the safety invariants (every button down has an up, every began has an ended/cancelled, no event after the final lift-off) — used in M9.3. Every engine bug report must come with a `.tgrec`.

### 6.11 Updates, packaging, notarization

- Sparkle 2 via SPM (`https://github.com/sparkle-project/Sparkle`, 2.x), EdDSA-signed appcast, `SUFeedURL = $(TG_APPCAST_URL)`, `SUEnableAutomaticChecks = YES`, check interval 24 h. Generate keys with `generate_keys` and store the private key only in the owner's Keychain (never in the repo).
- Release script `Scripts/release-mac.sh <version>`: `xcodebuild archive` → `xcodebuild -exportArchive` with Developer ID method → DMG via `hdiutil` (background image with "drag to Applications") → `xcrun notarytool submit --wait` → `xcrun stapler staple` → `gh release create v<version> Trackglass-for-Mac-<version>.dmg --notes-file Releases/release-notes/<version>.md` → `generate_appcast` with `--download-url-prefix "$(TG_REPO_URL)/releases/download/v<version>/"` → commit `Releases/appcast.xml` and push. Sparkle then finds the new version at the raw URL of §1.5 (raw.githubusercontent.com caches for up to five minutes; acceptable). The script refuses to run if the working tree is dirty or the tag already exists.
- Landing page: the GitHub Pages site built from `website/` (§1.5). The site's three placeholders (`OWNER/trackglass`, `APPSTORE_URL`, `SUPPORT_EMAIL`) are filled in M11.3; the repository `README.md` links to it and carries the same download button.

---

## 7. Performance budget

| Metric | Target | How measured |
|---|---|---|
| Instrumented latency, same LAN, 120 Hz iPhone | ≤ 12 ms median, ≤ 20 ms p95, defined as `RTT/2 + Mac pipeline latency + one phone touch-delivery period (8.3 ms at 120 Hz)` | PING RTT + `LatencyStats` histogram (M10.2) |
| Finger-to-pixel latency (what the user sees) | Trackglass ≤ built-in trackpad + 10 ms, measured identically | 240 fps camera of finger + Mac screen, same Mac, same display, 20 trials each (M10.2); includes the Mac's own display latency, which is why it is relative |
| Mac pipeline latency (receive → post) | ≤ 0.3 ms p95 | `LatencyStats` |
| RTT control ping, same LAN | ≤ 6 ms p95 | PING/PONG |
| Frame rate delivered | ≥ 115 fps on ProMotion while a finger moves; ≥ 58 fps on 60 Hz devices | STATUS counters |
| Packet loss tolerance | 5 % random loss: no stuck buttons, no missed lift-offs, gestures still complete | `tgreplay --drop 0.05` + Network Link Conditioner |
| iPhone CPU (A15, continuous use) | ≤ 8 % | Instruments |
| Mac CPU (M1, continuous use) | ≤ 4 % | Activity Monitor / Instruments |
| Mac memory | ≤ 60 MB resident | Activity Monitor |
| iPhone battery, 1 h continuous use, screen on, Glass Black | ≤ 12 % | manual |
| Reconnect after Wi-Fi blip | ≤ 2 s | manual, Network Link Conditioner |

Rules that protect the budget: no allocations in the per-frame path on either side (verified with Instruments in M2.3 on the phone and M4.9 on the Mac); no `Codable`/JSON on the per-frame path; no `DispatchQueue.main` in the pipeline; no logging above `.debug` per frame; `NWConnection.send` uses `.idempotent` and never waits for completion.

---

## 8. Robustness and edge cases (all required)

1. **Mac sleep / wake:** on `NSWorkspace.willSleepNotification` send BYE(sleeping) and stop listeners; on `didWakeNotification` restart listeners. Phone reconnects automatically.
2. **Display sleep:** first touch wakes the display (§6.7); the pointer must move only after the display is awake (post the wake assertion, then the event — same tick).
3. **Fast user switching / login window:** the app is per-user; when the session becomes inactive (`NSWorkspace.sessionDidResignActiveNotification`) stop injecting and reject sessions with `busy`.
4. **Screen configuration changes:** re-read displays (§6.7). Pointer never lands off-screen.
5. **Secure input / password fields:** irrelevant (no keyboard), but Accessibility can be revoked at any time: poll `AXIsProcessTrusted()` every 5 s while connected; if revoked, show the Welcome window and send BYE.
6. **Accessibility permission reset after update:** notarized builds keep the TCC grant as long as the signing identity is stable; the release script asserts the Developer ID team identifier matches the previous build.
7. **Phone rotation mid-gesture:** `SURFACE` message is sent; the pipeline calls `engine.setGeometry(_:into:)`, which ends all active gestures (`.cancelled`), releases buttons (keeping drag lock) and resets.
8. **Phone app backgrounded mid-drag:** BYE triggers lift-off; button released unless drag lock (then released anyway — drag lock does not survive disconnect).
9. **Clock weirdness:** phone timestamps that go backwards (never expected with `mach_absolute_time`) → `InputPipeline` drops the frame and counts it (pipeline unit test, not an engine fixture).
10. **Two phones:** second gets `busy` with a clear message on the phone: "<Mac> is being used by <other phone name>".
11. **Mac has no trackpad (Mac mini / Studio with mouse only):** the preference domains may lack keys → the "Default when a trackpad pref key is missing" row in Appendix A applies; acceleration uses the bundled curves; tracking speed uses `com.apple.trackpad.scaling` if present, else 0.6875. Decision: never read `com.apple.mouse.scaling` (mouse acceleration is a different curve family).
12. **iPad multitasking gestures:** documented in onboarding; nothing else possible.
13. **Pencil on iPad:** ignored (kind 2).
14. **Hover (iPad Pro with Pencil hover):** `UITouch.Phase.regionEntered/Moved/Exited` ignored.
15. **Very large iPad surfaces:** millimeters are sent as-is; the engine does not scale. A 13-inch iPad is simply a huge trackpad (correct: identical physical tracking).
16. **Trackpad preferences changed while connected:** picked up within 2 s; the engine applies the new snapshot when it is next idle (§6.4), so active gestures continue with old settings until they end.
17. **macOS upgrade breaks a private field:** the `PrivateAPICapabilities` flags turn false at symbol resolution; the affected gesture degrades to its fallback; the injector's `degradedGestures` list is shown in the menu bar menu and in Settings → Advanced as "Reduced gesture mode".

---

## 9. Implementation sequence (overview)

The authoritative, step-by-step build order lives in **`docs/PLAN.md`** (one feature per step, each with its own test and commit). This section only names the milestones so the rest of the spec can refer to them. Do not start a milestone before the previous one's exit criteria pass.

| Milestone | Scope | Spec sections | Exit criteria (all must hold before the next milestone) |
|---|---|---|---|
| P0 | Repo, XcodeGen project, xcconfigs, empty apps, test targets, CI script; owner files the DriverKit entitlement request | §2.3, §2.5, §12.2 | both apps build and launch; `Scripts/ci.sh` exits 0 |
| M1 | TrackglassKit: protocol, codec, framer, pairing crypto, geometry, `.tgrec` format | §4, §3.3, §5.3, §6.10 | every public Kit API has tests; codec ≤ 300 ns/frame |
| M2 | iOS touch surface at 120 Hz with zero-allocation frames (console sink) | §5.2–5.4 | ruler test 50 ± 1 mm; ≥ 115 moved-events/s on ProMotion; zero transient allocations in Trackglass's per-frame code |
| M3 | Networking, Bonjour, TLS-PSK, pairing (QR + PIN), admission, reconnect | §3, §5.5, §6.3 | pair via QR and PIN; reconnect ≤ 2 s; peer-to-peer with no router; second phone gets `busy`; security tests pass |
| M4 | Mac pipeline, engine skeleton, pointer + all click/drag semantics, preferences keys for clicks, replay tool | §6.5.2–6.5.6, §6.7, §6.9.1 | all M4 fixtures pass; pointer/click/double/secondary/drag/drag-lock behave per the Mac's settings and follow setting changes within 2 s |
| M5 | Apple's pointer-acceleration algorithm, calibration C1–C3 | §6.6, §10.3 | C1–C3 within tolerance; blind A/B (§10.3) passes |
| M6 | Private-field module, scroll + momentum + magnify + rotate + smart zoom, calibration C4–C6 | §6.5.7, §6.8, §6.9.2–6.9.3 | C4–C6 within tolerance; Safari, Preview, Maps, Finder, Xcode checks of M6 pass |
| M7 | Dock swipes (both OS paths), navigation swipe, Notification Center, Force click, fallbacks | §6.5.8–6.5.9, §6.9.4–6.9.6 | every System Settings → Trackpad gesture works with the configured finger counts on the available macOS versions; C7–C8 pass |
| M8 | Full preferences mirroring, haptics, themes, HUD, iPad, onboarding, Mac Welcome | §5.1, §5.6–5.9, §6.1–6.2, §6.4 | every §6.4 key verified; UI matches §5/§6.1 |
| M9 | Robustness list, loss/latency conditioning, 24 h soak | §8 | `docs/QA-Robustness.md` fully checked; 24 h soak clean |
| M10 | Diagnostics, latency measurement, polish, accessibility | §6.10, §7 | §7 budget met and documented in `docs/Latency.md`; VoiceOver operates every control |
| M11 | Sparkle, notarization, DMG, GitHub release + README landing page, App Store submission | §6.11, §11, `docs/APPSTORE.md` | App Store approval; Sparkle update verified |
| Phase 2 | DriverKit spike and (if all gates pass) the native driver backend | §12 | G-DRV-1…5 recorded; if all pass and the entitlement is granted, §10.4 matrix passes with the driver active |

---

## 10. Testing and acceptance

### 10.1 Automated

- `TrackglassKitTests`: codec, framer, geometry, pairing payload, key derivation.
- `EngineTests`: fixture-driven. Each fixture is the triplet of §6.10 (`<name>.tgrec` frames — hand-authored with a small `FixtureBuilder` helper or recorded — plus `<name>.settings.json` holding `TrackpadSettings`, `EngineGeometry`, the acceleration model and an optional list of `tick` times and geometry changes, plus `<name>.expected.json`, the exact `GestureEvent` sequence in the §6.5.1 JSON shape; floating values compared with 1e-6 tolerance). Fixtures use a fixed unit-gain acceleration model so expected pointer deltas are exact; the real curves are tested separately. Required fixtures: `tap`, `double_tap`, `triple_tap`, `tap_drag`, `tap_drag_lock`, `three_finger_drag`, `two_finger_tap`, `corner_tap_right`, `corner_tap_left`, `scroll_vertical`, `scroll_horizontal_disabled`, `scroll_then_pinch`, `pinch_only`, `rotate_only`, `smart_zoom`, `two_finger_tap_pending_then_click`, `three_finger_swipe_spaces`, `three_finger_swipe_nav`, `four_finger_mission_control`, `four_finger_app_expose`, `four_finger_pinch_launchpad`, `four_finger_spread_desktop`, `edge_swipe_notification_center`, `force_click`, `three_finger_tap_lookup`, `palm_ignored`, `resting_thumb_ignored`, `settle_window_second_finger`, `liftoff_timeout`, `liftoff_timeout_releases_drag_lock`, `contact_vanishes`, `contact_id_reused`, `rotation_cancels_gesture`, `momentum_cancelled_by_touch`, `momentum_decay`, `settings_change_deferred`, `double_tap_dragging_on`, and the snapshot fixture `recorded_tap_drag` (§6.10).
- `InjectorTests` (inside `TrackglassMacTests`, hosted by the app): install a `CGEventTap` (listen-only) in the host process, drive `QuartzInjector` with synthetic `GestureEvent`s, and assert every field of the captured events (type, fields 55/88/137/11/12/96/97/93/94/99/123, 110/132/113/114/115/116/119, dock-swipe fields for **both** `DockSwipePath` values). The tests read raw field numbers through the `TGPrivateFields.h` constants exported by the app module; the §0.5 grep rule applies to `Mac/` sources only. Skips with a clear message when `AXIsProcessTrusted()` is false.
- `TrackglassMacTests` also hosts: `PairingStore`, `TrackpadPreferences` plist fixtures, `InputPipeline` (ordering, backwards time, estimated phone time), security tests (§3). `TrackglassiOSTests` hosts: `PairingStore`, `SurfaceGeometry` glue, contact-table/ID-pool logic.
- Performance tests: `TrackglassKitTests` — encode/decode ≤ 300 ns; `EngineTests` — `ParametricAccelerationCurve.multiplier` ≤ 50 ns.

### 10.2 Replay-based regression

Every bug fixed in the engine adds a fixture triplet. `tgreplay verify-dir Tests/Fixtures` runs in CI (`Scripts/ci.sh`) from M4.9 on.

### 10.3 Calibration procedures (reference MacBook, built-in trackpad vs phone)

- **C1 Slow precision:** move 1 mm in 1 s. Pointer travel must be within ±15 % of the built-in trackpad at the same tracking tick (measure with `CGEvent` location logging on both).
- **C2 Medium:** move 100 mm in 0.5 s. Within ±10 %.
- **C3 Flick:** move 60 mm in 0.12 s. Within ±15 %, and the pointer must cross ≥ 90 % of a 1512-pt-wide display at the default tick.
- **Blind A/B (part of M5):** three testers, each performs 10 slow precision moves and 10 fast flicks on the built-in trackpad and on the phone in random order without looking at which device they use (same Mac, screen only). Pass when at least 2 of 3 testers identify the device at chance level (≤ 12 of 20 correct).
- **C4 Scroll distance:** two-finger 50 mm in 0.33 s in a Finder list view. Scrolled rows within ±15 % of the built-in trackpad.
- **C5 Momentum:** same flick; time until the list stops within ±25 %; distance within ±25 %.
- **C6 Pinch:** 20 mm spread in Preview on a PDF at 100 %; resulting zoom within ±10 %.
- **C7 Spaces:** one 110 mm three-finger swipe switches exactly one Space; a 40 mm swipe snaps back.
- **C8 Thresholds (all remaining Tunable constants):** for each of tap, double tap, two-finger tap, tap-drag, three-finger drag, scroll start, pinch start, rotate start, navigation swipe, Mission Control, Launchpad pinch, Force click and momentum start, perform 20 deliberately marginal trials on the built-in trackpad and 20 identical trials on the phone (same tester, same intent). The recognized outcome must agree in ≥ 95 % of trials (≥ 19/20); otherwise move the constant toward the trackpad's behavior and repeat.
Adjust only the constants marked Tunable; record final values in Appendix A and in `docs/Calibration.md`.

### 10.4 Manual QA matrix (run before every release)

Rows: macOS 14 and macOS 27 Macs × iPhone (120 Hz) × iPad. Columns: every gesture in System Settings → Trackpad (Point & Click, Scroll & Zoom, More Gestures) with each toggle on and off, plus natural scrolling on/off, tracking ticks 1/4/10, tap-to-click off notice, drag lock on/off, three-finger drag on/off, Bluetooth trackpad also paired, external display attached, display asleep, Mac asleep, Wi-Fi only, peer-to-peer only.

---

## 11. Release checklist (owner)

1. Trademark search for "Trackglass" in the relevant classes. Decide the open-source license for the public repo (MIT or Apache-2.0 are the usual choices; nothing copyleft, so the iOS binary on the App Store is unaffected). A custom domain is optional and can be added later.
2. Developer ID Application certificate on the release machine; Sparkle EdDSA private key in Keychain.
3. App Store Connect: app record, privacy label, age rating, review notes, TestFlight group.
4. Public GitHub repo with the `website/` site live on GitHub Pages (placeholders filled, contact e-mail set), the first release, and the appcast.
5. Demo video (60 s) for App Review: install Mac app → Accessibility → pairing QR → pointer, click, scroll, pinch, Mission Control.
6. Keep two test Macs (macOS 14 and current) and one 120 Hz iPhone and one iPad for the QA matrix.

---

## 12. Phase 2 — DriverKit virtual trackpad

### 12.1 What it is

A DriverKit driver extension (`app.trackglass.mac.driver`) subclassing `IOUserHIDDevice` (HIDDriverKit) that publishes a virtual HID device whose identity and report descriptor match an Apple multitouch trackpad, so that macOS's own `AppleMultitouchTrackpadHIDEventDriver` attaches and performs gesture recognition, acceleration, tap-to-click, Force click and all System Settings behavior natively. The Mac app forwards each `TOUCH_FRAME` to the driver through an `IOUserClient` external method; the driver packs it into multitouch input reports and calls `handleReport`.

### 12.2 Entitlement request (owner files on day 1)

Form: https://developer.apple.com/contact/request/system-extension/ — request **one group** containing: `com.apple.developer.driverkit`, `com.apple.developer.driverkit.transport.hid`, `com.apple.developer.driverkit.family.hid.device`, `com.apple.developer.driverkit.family.hid.eventservice`, `com.apple.developer.hid.virtual.device`, and `com.apple.developer.driverkit.userclient-access` (for the app, listing the driver's bundle ID). Suggested description:

> Trackglass for Mac lets a user's own iPhone or iPad act as a trackpad for their Mac over the local network. The driver extension publishes a virtual HID multitouch trackpad device; the companion app (bundle ID app.trackglass.mac, Developer ID distribution) receives touch data from the paired iOS device and delivers it to the driver through a user client. No physical hardware; vendor ID not applicable (virtual device). Transport: HID (virtual). Supported macOS 14+.

Expected outcome is uncertain; Apple has granted virtual HID entitlements to comparable products (Karabiner-Elements' virtual keyboard/mouse driver). If refused, Phase 2 is closed and Phase 1 remains the product.

### 12.3 Feasibility spike (agent; can start before the entitlement arrives)

On a dedicated test Mac: boot to Recovery, set security to Reduced, disable SIP (`csrutil disable`), then `systemextensionsctl developer on`. This permits running an unsigned/unprovisioned dext for development. Never ship from this machine.

- S1 Create `TrackglassDriver` (C++ DriverKit target) with `Info.plist` personality `IOClass = AppleUserHIDDevice`, `IOProviderClass = IOUserResources` (virtual, no hardware provider), `IOUserClass = TrackglassVirtualTrackpad`, `IOResourceMatch = IOKit`; `newDeviceDescription()` returns `VendorID = 0x05AC`, `ProductID = 0x0265`, `Transport = "USB"` (try `"Bluetooth"` and `"I2C"` if the multitouch driver does not attach), `Manufacturer = "Apple Inc."`, `Product = "Magic Trackpad 2"`, `VersionNumber = 0x0804`, `PrimaryUsagePage = 0x01`, `PrimaryUsage = 0x02`.
- S2 `newReportDescriptor()` returns the Magic Trackpad 2 descriptor. Transcribe the byte array from VoodooInput's `VoodooInput/VoodooInputSimulator/VoodooInputSimulatorDevice.cpp` (reference for facts; it is the reverse-engineered descriptor with a mouse collection on report ID 0x02, a Digitizer touch-pad collection carrying a vendor-defined 16-byte report 0x3F, and a vendor collection with a 107-byte report 0x44). Decode it with a HID descriptor tool and keep the decoded comments next to the bytes.
- S3 Feature reports: implement `setReport`/`getReport` for report IDs 0x00, 0x01 (sub-commands 0xDB, 0xD1, 0xD3, 0xD0, 0xA1, 0xD9, 0x7F, 0xC8), 0xD1, 0xD3, 0xD0, 0xA1, 0xD9 (physical size), 0x7F, 0xC8, 0x02, 0xDB, returning the responses documented in the same reference (e.g. 0xD1 → `{0xD1, 0x81}`, 0xD3 → sensor rows 0x16 / columns 0x1E, 0xC8 → `{0xC8, 0x08}`).
- S4 Input report layout (from the same reference and Linux `hid-magicmouse.c`): header 12 bytes — `ReportID = 0x02`, `Button`, `Unused[5]`, `TouchActive` (0x3 while fingers down, 0x2 otherwise), `multitouch_report_id = 0x31`, `timestamp[3]` (ms since start, packed as `(ms << 3) | 0x4` in byte 0 and the upper bits across bytes 1–2); then 9 bytes per finger — `X:13 bits, Y:13 bits` (signed; the device coordinate range is X −3678…3934 and Y −2479…2586 per `hid-magicmouse.c`, Y positive upwards), `Finger:3`, `State:3` (Start = Near|Transition = 0x3, Active = Contact = 0x4, Stop = 0x7, Inactive = 0), `Touch_Major`, `Touch_Minor`, `Size`, `Pressure`, `Identifier:4`, `:1`, `Angle:3` (fixed 0x4). Lift-off requires the three-frame sequence the reference uses (size/pressure zero → state Inactive → empty frame), 10 ms apart.
- S5 Build a tiny test client (`tgdrivertest`) that opens the user client and pushes a scripted finger path. **Gate G-DRV-1:** `ioreg -l` shows `AppleMultitouchTrackpadHIDEventDriver` (or `AppleMultitouchDevice`) attached under the virtual device. **G-DRV-2:** System Settings → Trackpad shows the device and its gesture settings apply. **G-DRV-3:** pointer, tap-to-click, two-finger scroll with native momentum, pinch, Mission Control work from scripted frames. **G-DRV-4:** Force click triggers with scripted pressure ramps. **G-DRV-5:** survives sleep/wake and reboot (dext re-activation).
- If any gate fails after reasonable iteration on transport strings and feature responses, document the failure in `docs/Phase2-Spike.md` and **stop**; Phase 2 is closed for that OS generation.

### 12.4 Integration (only after all gates and the entitlement)

- `DriverInjector: InputInjector` maps mm → device units with `X = round(xMM × 7612 / 160) − 3678` and `Y = 2586 − round(yMM × 5065 / 115)` (the ranges of S4; Y is inverted because the device's Y grows upwards), keeps a physical 1:1 mapping (an iPhone is a small trackpad; an iPad larger than 160 × 115 mm is scaled down uniformly so its whole surface maps), synthesizes `Pressure`/`Size` constants (5/10 when untouched by Force logic), raises `Pressure` to 120 for the engine's Force-click hold, and never sets the physical `Button` bit (tap-to-click is native).
- With the driver active the Mac engine is bypassed except for: palm/resting heuristics (the native driver has its own; disable ours), Force-click hold → pressure ramp, and haptic feedback (derive from the native click? not observable — send `click` haptics from our own tap detector running in observe-only mode).
- Activation UX: Settings → Advanced → "Native trackpad driver (recommended)": `OSSystemExtensionRequest.activationRequest`, user approves in System Settings; fall back to Quartz automatically when the extension is not approved or fails.
- The app keeps both injectors forever; `WELCOME.injectorMode` tells the phone which one is live.

---

## Appendix A — Constants (initial values; Tunable ones are finalized in M5–M7)

| Name | Value | Tunable | Where |
|---|---|---|---|
| SETTLE_WINDOW | 60 ms | yes | §6.5.3 |
| TAP_MAX_DURATION | 0.30 s | yes | §6.5.5 |
| TAP_MAX_MOVEMENT | 2.0 mm | yes | §6.5.5 |
| MULTI_TAP_SPREAD | 5.0 mm | yes | §6.5.5 |
| TWO_FINGER_TAP_STAGGER | 0.10 s | yes | §6.5.5 |
| CORNER_ZONE | 22 × 22 mm | no | §6.5.5 |
| DRAG_RELEASE_GRACE | 0.30 s | yes | §6.5.6 |
| THREE_FINGER_DRAG_START | 2 mm centroid | no | §6.5.6 |
| SCROLL_ACTIVATION | 1.5 mm | yes | §6.5.7 |
| PINCH_ACTIVATION | 2.5 mm | yes | §6.5.7 |
| ROTATE_ACTIVATION | 5° | yes | §6.5.7 |
| ROTATE_MIN_SPREAD | 15 mm | no | §6.5.7 |
| EDGE_ZONE | 3 mm | no | §6.5.7 |
| EDGE_SWIPE_DISTANCE | 8 mm | no | §6.5.7 |
| NAV_SWIPE_DISTANCE | 20 mm | yes | §6.5.8 |
| AXIS_LOCK_DISTANCE | 6 mm | no | §6.5.8 |
| SPACES_MM_PER_SPACE | 110 mm | yes | §6.5.8 |
| MISSION_CONTROL_MM | 60 mm | yes | §6.5.8 |
| PINCH_MM_FULL | 40 mm | yes | §6.5.8 |
| PINCH_GESTURE_ACTIVATION | 8 mm mean distance change | yes | §6.5.8 |
| FORCE_HOLD | 0.60 s | yes | §6.5.9 |
| FORCE_MAX_MOVEMENT | 1.0 mm | no | §6.5.9 |
| PALM_RADIUS | 11 mm | no | §6.5.2 |
| RESTING_ZONE | bottom 18 mm | no | §6.5.2 |
| RESTING_STILL_TIME | 150 ms | no | §6.5.2 |
| RESTING_RELEASE_MOVE | 3 mm | no | §6.5.2 |
| LIFTOFF_TIMEOUT | 1.5 s | no | §4.7 |
| OUTPUT_SCALE (pointer) | 1.0 | yes (only if C1–C3 show a constant ratio) | §6.6 |
| SCROLL_BASE_GAIN / SCROLL_ACCEL_GAIN / SCROLL_ACCEL_V0 (fallback model only) | 3.8 pt/mm / 0.5 / 350 mm/s | yes (C4) | §6.8 |
| MOMENTUM_MIN_START | 60 pt/s | yes | §6.8 |
| MOMENTUM_DECAY_PER_MS | 0.998 | yes | §6.8 |
| MOMENTUM_STOP | 5 pt/s | no | §6.8 |
| ENGINE_TICK (also drives momentum) | 8 ms | no | §2.4, §6.5.1 |
| SCROLL_GESTURE_SCALE | 1.67 | no | §6.9.3 |
| DOCK_END_REPOST | +0.2 s, +0.5 s | no | §6.9.4 |
| PING_INTERVAL / DEAD | 1 s / 3 misses | no | §4.6 |
| HEARTBEAT | 500 ms | no | §4.5 |
| PREFS_POLL | 2 s | no | §6.4 |
| Default when a trackpad pref key is missing | Clicking 1, RightClick 1, Corner 0, ThreeFingerDrag 0, DragLock 0, Dragging 0, Pinch 1, Rotate 1, SmartZoom 1, Momentum 1, TrackpadScroll 1, TrackpadHorizScroll 1, ThreeFingerHoriz 2, FourFingerHoriz 2, ThreeFingerVert 2, FourFingerVert 2, FourFingerPinch 2, FiveFingerPinch 2, NC edge 3, scaling 0.6875, natural 1, forceClick 1, ForceSuppressed 0, threeFingerTap 2, AppleEnableSwipeNavigateWithScrolls 1, Dock showMissionControlGestureEnabled 1, showAppExposeGestureEnabled 1, showLaunchpadGestureEnabled 1, showDesktopGestureEnabled 1 | no | §6.4 |

## Appendix B — Event field cheat-sheet (Quartz injector)

Public (`CGEventField` cases): 11/12 line deltas, 93/94 fixed-point deltas, 96/97 point deltas, 88 continuous, 99 scroll phase, 123 momentum phase, mouse click state via `.mouseEventClickState`, deltas via `.mouseEventDeltaX/Y`.
Private raw numbers (declared only in `TGPrivateFields.h`; from MMF, verify at M6.1/M7): 55 = event type, 137 = direction inverted from device, 29 = gesture event type, 30 = dock/gesture companion type, 110 = IOHIDEventType, 132 = phase, 134 = phase (dock), 113 = magnification, 114 = rotation, 115 = swipe mask, 116/119 = gesture dx/dy, 124 = dock progress, 135 = Float32 bits of progress, 119/139 = dock type denormal, 123/165 = dock type, 136 = inverted flag, 129/130 = exit speed, 41 = 33231 marker.
IOHIDEventType values: Rotation 5, Scroll 6, Zoom 8, Velocity 9, NavigationSwipe 16, ZoomToggle 22, DockSwipe 23, FluidTouchGesture 27, Force 32, GestureBegan 61, GestureEnded 62.
Phase bits: Undefined 0, Began 1, Changed 2, Ended 4, Cancelled 8, MayBegin 128. Momentum: None 0, Begin 1, Continue 2, End 3. Swipe mask: Up 1, Down 2, Left 4, Right 8.

## Appendix C — Device PPI table (`DevicePPI`)

Maintain as a dictionary from model identifier prefix to PPI; add new models as Apple ships them (the fallback keeps unknown devices working):

| Models | PPI |
|---|---|
| iPhone XR, iPhone 11, iPhone SE (2nd/3rd gen) | 326 |
| iPhone XS, XS Max, 11 Pro, 11 Pro Max, 12 Pro Max, 13 Pro Max, 14 Plus | 458 |
| iPhone 12 mini, 13 mini | 476 |
| iPhone 12, 12 Pro, 13, 13 Pro, 14, 14 Pro, 14 Pro Max, 15 family, 16 family (incl. 16e), 17 family, iPhone Air | 460 |
| iPad (9th gen and later), iPad Air (4th gen and later), iPad Pro 11/12.9/13 (all generations) | 264 |
| iPad mini (5th gen and later) | 326 |
| Unknown iPhone | 460 |
| Unknown iPad | 264 |

Verify each entry against Apple's tech specs when building the table; PPI errors of a few percent only scale tracking slightly, but the table must be right for the reference devices.

## Appendix D — References used for facts (read, do not copy)

- Apple, IOHIDFamily open source (APSL-2.0): `IOHIDEventSystemPlugIns/IOHIDAccelerationAlgorithm.{hpp,cpp}`, `IOHIDAcceleration.{hpp,cpp}`, `HID/Headers/HIDEvent.h` — https://github.com/apple-oss-distributions/IOHIDFamily
- Apple, HIDDriverKit `IOUserHIDDevice` / `IOHIDDevice` (`handleReport`, `getReport`, `setReport`, `newDeviceDescription`, `newReportDescriptor`) — https://developer.apple.com/documentation/hiddriverkit/iouserhiddevice
- Apple, "Requesting Entitlements for DriverKit Development" and "Debugging and testing system extensions" — https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development ; https://developer.apple.com/documentation/driverkit/debugging-and-testing-system-extensions ; request form https://developer.apple.com/contact/request/system-extension/
- Apple, entitlement `com.apple.developer.hid.virtual.device` — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device
- Apple, sample "Building a custom peer-to-peer protocol" (TLS-PSK with Network.framework, Bonjour, `includePeerToPeer`, custom framer) — https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol
- Apple, release versions (Xcode 27.1, iOS/iPadOS 27.0.1, macOS 27.0.1 as of 2026-10-15) — https://developer.apple.com/news/releases/
- pqrs-org, Karabiner-DriverKit-VirtualHIDDevice (proof that Apple grants virtual-HID DriverKit entitlements; entitlement list; macOS 13–27 support) — https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice
- Noah Nübling, Mac Mouse Fix (`Helper/Core/Touch/TouchSimulator.m`, `GestureScrollSimulator.m`; MMF License — facts only) — https://github.com/noah-nuebling/mac-mouse-fix
- acidanthera, VoodooInput (`VoodooInputSimulator/VoodooInputSimulatorDevice.{cpp,hpp}`; GPL-2.0 — facts only) — https://github.com/acidanthera/VoodooInput
- Calf Trail, Touch (`TouchSynthesis/TouchEvents.h`; GPL-2.0 — facts only) — https://github.com/calftrail/Touch
- Mathias Bynens dotfiles (`.macos`) for trackpad `defaults` key names — https://github.com/mathiasbynens/dotfiles

*End of specification.*
