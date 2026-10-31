# Trackglass — Build Plan (docs/PLAN.md)

This is the only build order. One step at a time, in this sequence. Every step = **one feature → its test passes → one commit**. Never start a step while the previous step's test is failing or unconfirmed.

## How to work a step

1. Read the step. Read the spec sections it cites (`docs/SPEC.md`). Do not read ahead to implement future steps "while you're there".
2. Implement only what the step says. If something the step needs is missing from an earlier step, fix the earlier step first (that fix gets its own commit, message `fix: <what>`).
3. Run the step's **Test**. Kinds:
   - **AUTO** — you run it yourself (`swift test`, `xcodebuild … test`, a script, a build). Zero failures; zero warnings in the packages. The test target that hosts each AUTO test is named in the step.
   - **MANUAL** — a human must touch the phone or look at the Mac. Build and install the apps (`xcodebuild` + `xcrun devicectl device install app --device <id> <path.app>` for the iPhone/iPad, `open` for the Mac), then stop and tell the owner exactly what to do and what they should observe, in a numbered list. Wait for the owner's confirmation. If the owner reports a failure, fix it and ask again. Do not commit until the owner confirms.
   - **AUTO+MANUAL** — both parts are required.
4. When the test passes: update `docs/PROGRESS.md` (tick the step; add one line of notes if a gate or a tunable was decided), then commit everything with the step's **Commit** message exactly (one line, nothing else).
5. Move to the next step.

Rules that apply to every step are in `CLAUDE.md` at the repo root.

Notation: `§x.y` = section of `docs/SPEC.md`. "Gate" steps branch; record the outcome in `docs/PROGRESS.md`. Test target names: `TrackglassKitTests` and `EngineTests` (packages, `swift test`), `TrackglassMacTests` (hosted by the Mac app, includes the `InjectorTests` folder), `TrackglassiOSTests` (hosted by the iOS app on the simulator).

---

## P0 — Setup

**P0.0 (owner, not the agent):** file the DriverKit entitlement request with the text in §12.2 and tick P0.0 in `docs/PROGRESS.md` with the date. Nothing else depends on it until Phase 2.

### P0.1 Project scaffold
- Do: `.gitignore` (Xcode, SPM, DerivedData, `Config/Local.xcconfig`, `*.tgrec` except under `Tests/Fixtures`), `Config/Shared.xcconfig` (`TG_PRODUCT_NAME = Trackglass`, `TG_BUNDLE_PREFIX = app.trackglass`, `TG_REPO_URL = https://github.com/<owner>/trackglass` (ask the owner for the GitHub owner/repo name), `TG_WEBSITE_URL = https://<owner>.github.io/trackglass`, `TG_APPCAST_URL = https://raw.githubusercontent.com/<owner>/trackglass/main/Releases/appcast.xml`, `MARKETING_VERSION = 1.0.0`, `CURRENT_PROJECT_VERSION = 1`, `#include? "Local.xcconfig"`; the four TG_ values are also written into both Info.plists as `TGProductName`, `TGBundlePrefix`, `TGRepoURL`, `TGWebsiteURL`). The `website/` folder and `.github/workflows/pages.yml` are already in the repo: do not modify them in this step, `Config/Local.xcconfig.example` (`DEVELOPMENT_TEAM = `) — ask the owner for the team ID or read it from `security find-identity -p codesigning -v` and write the real `Config/Local.xcconfig` (untracked); `Config/iOS.xcconfig` (iOS 17.0, universal), `Config/Mac.xcconfig` (macOS 14.0, Hardened Runtime, sandbox off, `LSUIElement = YES`); `project.yml` with targets `TrackglassiOS` (one empty UIKit `SceneDelegate` showing a black view; Info.plist already carries `ITSAppUsesNonExemptEncryption = NO`) and `TrackglassMac` (one `MenuBarExtra` with a "Quit" item), Swift 6 language mode, strict concurrency complete. `xcodegen generate`.
- Test (AUTO+MANUAL): `xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOS -destination 'generic/platform=iOS' build` and `xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac build` succeed; the owner opens the Mac app and sees a menu bar item with "Quit".
- Commit: `scaffold project`

### P0.2 Packages, test targets, CI script
- Do: `Packages/TrackglassKit` and `Packages/TrackglassEngine` (Engine depends on Kit; `-warnings-as-errors` on both) with one placeholder test each; hosted test bundles `TrackglassMacTests` (host: TrackglassMac.app; contains an `InjectorTests/` folder with one placeholder that skips when `AXIsProcessTrusted()` is false) and `TrackglassiOSTests` (host: the iOS app, simulator) with one placeholder each; link Kit + Engine from the Mac target and Kit from the iOS target; `tgreplay` and `tgaccel` as empty macOS CLI targets (`tgreplay` links Kit + Engine); `Scripts/ci.sh` runs `swift test` on both packages, both hosted test bundles (`xcodebuild test` on macOS and on an iPhone simulator) and both app builds.
- Test (AUTO): `Scripts/ci.sh` exits 0.
- Commit: `add packages and ci script`

### P0.3 Documentation files
- Do: `README.md` with a "Developers" section holding the build commands (§2.5) — the user-facing landing content is added in M11.3; `LICENSE` (the license the owner chose, ask if `docs/PROGRESS.md` P0.3 note is empty); `docs/THIRD-PARTY.md` (Apple IOHIDFamily APSL-2.0 notice, Sparkle MIT notice, statement that no code from MMF/VoodooInput/Touch is included); confirm `docs/PROGRESS.md` lists every step ID of this plan.
- Test (AUTO): files exist; `Scripts/ci.sh` still exits 0.
- Commit: `docs: build instructions`

---

## M1 — TrackglassKit

### M1.1 Message header
- Do: `MonotonicClock.nanoseconds()`, `MessageType` enum (§4.5 values), `MessageHeader` (§4.2) encode/decode with byte-wise magic `0x54 0x47`.
- Test (AUTO, `TrackglassKitTests`): round-trip for every type; decode rejects bad magic and wrong version with typed errors.
- Commit: `kit: message header`

### M1.2 Touch frame codec
- Do: `Contact`, `TouchFrame` (inline storage for 10 contacts, no arrays), `TouchFrameEncoder.encode(into: UnsafeMutableRawBufferPointer) -> Int`, `TouchFrameDecoder.decode(_:)` (§4.4). Little-endian, Float32 fields.
- Test (AUTO, `TrackglassKitTests`): round-trip with 0, 1, 5, 10 contacts; flags; a 10 000-iteration fuzz test proves the decoder never traps on random bytes; `measure {}` encode ≤ 300 ns.
- Commit: `kit: touch frame codec`

### M1.3 Control messages
- Do: `ControlMessage` enum with every §4.5 TCP payload (HELLO, WELCOME + embedded SETTINGS, SETTINGS, PING, PONG, HAPTIC, STATUS with its six fields, SURFACE, BYE, PAIR_REQUEST, PAIR_RESPONSE; since 2026-10-31 also PAIR_COMMIT, PAIR_NONCE, PAIR_REVEAL, PAIR_CONFIRM); string encoding `u16` length + UTF-8; unknown types decode to `.unknown(type)`.
- Test (AUTO, `TrackglassKitTests`): round-trip each; truncated payload → typed error; unknown type → `.unknown`.
- Commit: `kit: control messages`

### M1.4 Control framer
- Do: `TGControlFramer: NWProtocolFramerImplementation` (§4.3): `u32` length prefix, 64 KiB max, parse loop.
- Test (AUTO, `TrackglassKitTests`): loopback `NWListener`/`NWConnection` on 127.0.0.1 exchanging 1 000 mixed-size messages, including a 64 KiB one, in order, no corruption.
- Commit: `kit: control framer`

### M1.5 Pairing crypto
- Do: `PeerIdentity` (16-byte peerID + name), `PairingPayload` (QR URL format/parse, §3.4), `KeyDerivation` (HKDF-SHA256; *2026-10-31:* the PIN key `pinKey(pin:pairID:)` is replaced by the code-pairing derivations `codeChannelKey(pairID:)`, `commitment`, `comparisonCode` and `codePairingLTK`, §3.4), `TLSConfig.tlsOptions(psk:identity:)`, `TLSConfig.listenerOptions(keys: [(SymmetricKey, String)])` (registers every pair, §3.3) and `TLSConfig.parameters(control:)`/`.parameters(input:)` (`includePeerToPeer`, cellular prohibited).
- Test (AUTO, `TrackglassKitTests`): URL round-trip with special characters in names; HKDF known-answer vector computed once with Python's `hashlib`/`hmac` and embedded; a loopback TLS-PSK handshake on 127.0.0.1 succeeds with the right key and fails with a wrong key (single registered key; the multi-key case is Gate G-TLS in M3.4).
- Commit: `kit: pairing crypto`

### M1.6 Surface geometry
- Do: `SurfaceGeometry(ppi:nativeScale:boundsInPoints:)` → `mmPerPoint`, `widthMM`, `heightMM`, `toMM(point)`; `DevicePPI.lookup(modelIdentifier:)` with Appendix C and fallbacks; `DeviceModelName.marketingName(modelIdentifier:)` (e.g. `iPhone16,1` → "iPhone 15 Pro", unknown → "iPhone"/"iPad").
- Test (AUTO, `TrackglassKitTests`): `iPhone16,1` (460 ppi, scale 3, 393 × 852 pt) → 65.1 × 141.1 mm (±0.1); unknown iPad → 264 ppi; marketing names for five known identifiers.
- Commit: `kit: surface geometry`

### M1.7 .tgrec format
- Do: `TGRecWriter`/`TGRecReader` (§6.10 format).
- Test (AUTO, `TrackglassKitTests`): write 500 frames, read back identical bytes and timestamps; reader rejects a bad header.
- Commit: `kit: tgrec format`

---

## M2 — iOS touch surface (no network yet)

### M2.1 UIKit root and surface view
- Do: `SceneDelegate` installs `TouchSurfaceViewController` as root; `TouchSurfaceView` black, `isMultipleTouchEnabled`, `isExclusiveTouch`; VC overrides: home indicator automatic hiding disabled to preserve two-swipe protection, status bar hidden, all screen edges deferred, orientations per §5.4; `isIdleTimerDisabled = true` while the surface is visible (connected-only from M3.4). No gesture recognizers anywhere.
- Test (MANUAL): on the iPhone the app is full-screen black; swiping from any edge needs the second system swipe; the screen does not auto-lock for 3 minutes.
- Commit: `ios: touch surface root`

### M2.2 Touch frames to console
- Do: live-contact table of 10 retained `UITouch` slots + contact ID free-list (0…255), phase mapping, pencil → kind 2, hover ignored, mm conversion via `SurfaceGeometry` with `view.window?.screen.nativeScale`, `majorRadius` in mm, frame timestamp in ns (§5.2); a `FrameSink` protocol with a `ConsoleFrameSink` that prints one line per frame.
- Test (AUTO+MANUAL): `TrackglassiOSTests` covers the contact table and ID pool (insert/remove/reuse rules). Owner places two fingers 50 mm apart (ruler) → printed distance 50 ± 1 mm; lifting one finger prints phase 4 for that ID; a third finger reuses no live ID.
- Commit: `ios: touch frames`

### M2.3 FrameSender with zero allocation
- Do: `FrameSender` (ring buffer of 16 frames that drops the oldest queued frame when full, serial `.userInteractive` queue, one reusable 188-byte encode buffer), `TouchSurfaceView` writes into a preallocated `TouchFrame` and enqueues; `ConsoleFrameSink` now consumes encoded bytes.
- Test (AUTO+MANUAL): Instruments → Allocations, 20 s of five-finger dragging: zero transient allocations attributed to Trackglass's own symbols in `TouchSurfaceView.emit`/`FrameSender` (UIKit-internal allocations are excluded); frames still print.
- Commit: `ios: frame sender`

### M2.4 120 Hz delivery
- Do: `CADisableMinimumFrameDurationOnPhone = YES`; `DisplayLinkDriver` with `CAFrameRateRange(80, 120, 120)` active while the surface is visible; a debug counter of `touchesMoved` per second shown in the Xcode console.
- Test (MANUAL): on the ProMotion iPhone a continuous one-finger drag logs ≥ 115 moved-events/s; on a 60 Hz device ≥ 58.
- Commit: `ios: 120hz display link`

### M2.5 Lift-off and surface changes
- Do: synthetic lift-off frame (`contactCount = 0`, flag bit1) after the last contact ends; a geometry-changed callback on `viewWillTransition`/size change (for now printed).
- Test (MANUAL): after lifting all fingers exactly one extra frame with count 0 is printed; rotating the phone prints the new width/height in mm (swapped).
- Commit: `ios: liftoff and surface changes`

---

## M3 — Networking, pairing, security

### M3.1 Discovery
- Do: Info.plist keys on **both** platforms via `project.yml`: `NSBonjourServices` (`_trackglass._tcp`, `_trackglass._udp`) and `NSLocalNetworkUsageDescription` (§5.5, §6.2); Mac `BonjourAdvertiser` (two listeners, TXT per §6.3, TLS with a **temporary fixed PSK** `"dev"` until M3.4); Mac `MenuBarExtra` shows "Advertising as <name>"; phone `MacBrowser` + a plain SwiftUI list (presented by the root VC) of discovered Macs with their `id`/`pr`.
- Test (MANUAL): the Mac appears on the phone within 2 s on the same Wi-Fi; with the router off and both devices on no network it still appears (peer-to-peer).
- Commit: `net: bonjour discovery`

### M3.2 Pairing store
- Do: `PairingStore` (Keychain, §3.2; Mac adds `kSecUseDataProtectionKeychain`) on both platforms with `save`, `load(peerID)`, `all()`, `delete`; phone name storage (`UserDefaults`, default = marketing model name).
- Test (AUTO): `TrackglassMacTests` and `TrackglassiOSTests`: save/load/delete round-trip; `all()` lists two entries; the Mac test runs inside the signed app host.
- Commit: `net: pairing store`

### M3.3a Pairing via QR
- Do: Mac `PairingService` (pairID/pairSecret generation, pairing listener with its own TXT `pr=1 pid=…`, 120 s window, single-use QR), `PairingWindow` showing the QR (`CIQRCodeGenerator`); phone `NSCameraUsageDescription` in Info.plist, `PairingFlowView` with a phone-name field (pre-filled) and `QRScannerView` (AVFoundation); `PairingClient` performing PAIR_REQUEST/RESPONSE over TLS-PSK with PSK = pairSecret; both sides store the LTK and the names.
- Test (MANUAL): pair via QR; both sides list each other with the names entered; scanning the same QR again is rejected; closing the window stops advertising `pr=1`.
- Commit: `net: pairing via qr`

### M3.3b Pairing via PIN, rotation, URL scheme (code comparison since 2026-10-31)
- Do: code mode in `PairingWindow` ("Use a code instead"; *2026-10-31:* numeric code comparison replaces the PIN, §3.4): the public code-channel key, `CodePairingView` ("Pair with a code") listing `isPairing` entries, PAIR_COMMIT/NONCE/REVEAL/CONFIRM, the same six-digit code on both screens, Allow on the Mac + Matches on the phone, at most 3 code sessions per window, failed handshakes never counted (the former HKDF PIN key, `PINEntryView`, PIN rotation and 3-PIN limit are gone); `CFBundleURLTypes` with the `trackglass` scheme and URL handling in `SceneDelegate` so the Camera app opens the app and pairs.
- Test (MANUAL): pair via code comparison (both screens show the same code; Allow, then Matches, and the reverse order); "Doesn't match" spends one session and a fourth session in one window is impossible; scanning the QR with the Camera app opens Trackglass and pairs. (Until 2026-10-31 this step paired via a PIN.)
- Commit: `net: pairing via pin`

### M3.4 Control session — Gate G-TLS
- Do: replace the temporary PSK: both listeners register every paired phone's `(LTK, peerID)` and are recreated when the pairing set changes (§3.3); phone `SessionClient` connects with its LTK; HELLO/WELCOME (WELCOME embeds a SETTINGS stub filled with the Appendix A defaults until M4.4), SURFACE (sent from the M2.5 geometry callback and on override changes), PING/PONG every 1 s, BYE; `SessionCoordinator` admits one phone, answers `busy` to a second; the Mac menu gets its paired-devices submenu with "Forget" (§6.1); idle timer now tied to "connected". **Gate G-TLS:** `TrackglassMacTests` loopback test — a listener with two registered keys accepts a client using either identity, for TLS and for DTLS; if it fails on macOS 14, implement the per-phone-listener fallback of §3.3 and record it.
- Test (AUTO+MANUAL): the G-TLS test (or its fallback variant) passes. Owner: phone shows "Connected to <Mac>, RTT x ms"; a second paired phone gets "busy" naming the first phone; "Forget" on the Mac makes the phone's next connect fail with "Pair again"; rotating the phone logs a SURFACE on the Mac.
- Commit: `net: control session`

### M3.5 Input channel
- Do: Mac `InputListener` (DTLS; listener registers only the admitted phone's LTK so the authenticated key binds the session identity), `INPUT_HEARTBEAT`; phone `FrameSender` now sends to the UDP connection (`.idempotent`); Mac logs frames/s and `lossPermille` (sequence gaps) once per second.
- Test (MANUAL): with a finger moving on the phone the Mac logs ≈ 120 frames/s on the ProMotion iPhone; raw unencrypted UDP sent to the port with `nc -u` is ignored.
- Commit: `net: input channel`

### M3.6 Reconnect and lifecycle
- Do: phone `ConnectionManager` actor (owns browser, session, paired-Mac store, the reconnect loop with 0.5 s → 8 s backoff while foregrounded, and the `@MainActor` `ConnectionState`), `SceneDelegate` background/active handling (background → BYE + close), Mac `willSleep`/`didWake` listener restart, 3 missed PINGs = dead.
- Test (MANUAL): toggle Wi-Fi on the phone off/on → reconnected within 2 s; put the Mac to sleep and wake it → reconnected; background the phone app → Mac logs BYE.
- Commit: `net: reconnect and lifecycle`

### M3.7 Security tests
- Do: `TrackglassMacTests`: wrong PSK fails the handshake; replayed `pairID` rejected; raw datagram ignored; code-session counter (a PIN attempt counter until 2026-10-31); create `docs/QA-Robustness.md` with the Wireshark check procedure as its first section (M9.1 extends it).
- Test (AUTO+MANUAL): the new tests pass; once, Wireshark on the Mac shows only TLS/DTLS records on the two ports.
- Commit: `net: security tests`

---

## M4 — Pointer, clicks, drags (Quartz)

### M4.1a Accessibility gating
- Do: `AccessibilityPermission` (prompt via `AXIsProcessTrustedWithOptions`, 1 s polling, status in the menu); listeners start only when trusted; a menu line "Grant Accessibility to start" with a button opening the System Settings pane.
- Test (MANUAL): with Accessibility revoked the phone cannot connect and the menu shows the hint; after granting, listeners start without relaunch and the phone connects.
- Commit: `mac: accessibility gating`

### M4.1b Pipeline and pointer
- Do: `InputPipeline` (queue-confined, owns decoder, `GestureEngine`, `EventBuffer`, injector; drops out-of-order and backwards-time frames; estimated-phone-time `tick` every 8 ms via one `DispatchSourceTimer` armed while `engine.needsTick`); `InputInjector` protocol; `QuartzInjector` with `PointerState` (read current location each tick, sub-point accumulation, `mouseMoved` with delta fields, event source with suppression disabled); `AccelerationModel` protocol with `UnitGainAcceleration` (1 pt/mm, for fixtures) and `ConstantGainAcceleration(pointsPerMM:)` (4 pt/mm placeholder for the app until M5.3); `GestureEngine` with `ContactTracker` and `pointer` mode only; `EngineGeometry` from HELLO, updated by SURFACE through `engine.setGeometry(_:into:)` (events injected like any others).
- Test (AUTO+MANUAL): `TrackglassMacTests` — pipeline drops out-of-order and backwards-time frames and counts them; estimated phone time advances between frames. Owner: one finger moves the Mac pointer smoothly; the physical trackpad/mouse keeps working while the phone is connected.
- Commit: `mac: pointer moves`

### M4.2 Pointer bounds and display wake
- Do: multi-display clamp with edge sliding (§6.7), display reconfiguration callback, `IOPMAssertionDeclareUserActivity` after ≥ 10 s idle.
- Test (MANUAL): with an external display, the pointer crosses between displays and never lands off-screen; with the display asleep, a touch wakes it and the pointer moves on that same touch.
- Commit: `mac: pointer bounds and wake`

### M4.3 Contact rules and fixture harness
- Do: palm rejection (majorRadius > 11 mm), resting-thumb rule with immediate mode re-evaluation, settle window with immediate upward mode changes, mode-level `.scroll(.mayBegin)`/`.scroll(.cancelled)` on entering/leaving `scroll(2)` (§6.5.2–6.5.3); `GestureEvent: Codable` JSON shape (§6.5.1); `.settings.json` schema (§6.10); `EngineTests` fixture harness reading `Tests/Fixtures` triplets with a `FixtureBuilder` for hand-authored `.tgrec` files; first fixtures `palm_ignored`, `resting_thumb_ignored` (timing per §6.5.3), `settle_window_second_finger`, all with `"acceleration": {"model": "unitGain"}`.
- Test (AUTO+MANUAL): fixtures pass. Owner: a resting thumb at the bottom edge does not disturb one-finger pointing.
- Commit: `engine: contact rules`

### M4.4 Trackpad preferences (click keys)
- Do: `TrackpadPreferences` reading `Clicking`, `TrackpadRightClick`, `TrackpadCornerSecondaryClick`, `TrackpadThreeFingerDrag`, `DragLock`, `Dragging`, `TrackpadThreeFingerTapGesture`, `com.apple.trackpad.scaling`, `com.apple.swipescrolldirection`, `NSEvent.doubleClickInterval`, both domains with the Bluetooth preference rule; 2 s poller; `engine.setSettings` applied when idle; real SETTINGS message. Verify the `TrackpadCornerSecondaryClick` value mapping with `defaults read` while toggling the corner setting in System Settings and record it in `docs/PROGRESS.md`.
- Test (AUTO+MANUAL): `TrackglassMacTests` parses a fixture plist into `TrackpadSettings`; toggling "Tap to click" in System Settings changes the logged snapshot within 2 s.
- Commit: `mac: trackpad preferences`

### M4.5 Taps and clicks
- Do: `TapRecognizer`: single click, two-finger secondary click (immediate, smart zoom not yet implemented), corner secondary click (§6.5.5); injector button events (§6.9.1); the phone shows the one-time "Tap to click is off on your Mac" notice derived from `SETTINGS.tapToClick` (a plain alert for now). Fixtures `tap`, `two_finger_tap`, `corner_tap_left` (value 1), `corner_tap_right` (value 2).
- Test (AUTO+MANUAL): fixtures pass. Owner: a tap clicks, a two-finger tap opens a context menu, the corner setting works as configured on the Mac.
- Commit: `engine: taps and clicks`

### M4.6 Multi-click and drag
- Do: click count with the `Dragging`-dependent emission time (§6.5.5), `DragController`: tap-and-a-half with `down(2)` semantics, double-click disambiguation, release grace, drag lock with haptic events emitted (haptics are sent in M8.2; for now logged) (§6.5.6). Fixtures `double_tap`, `triple_tap` (`Dragging = 0`), `double_tap_dragging_on`, `tap_drag`, `tap_drag_lock` (`Dragging = 1`).
- Test (AUTO+MANUAL): fixtures pass. Owner: double tap opens a file in Finder; drag a Finder window by its title bar via tap-and-a-half; with Drag Lock on, the drag continues after lifting until a tap.
- Commit: `engine: drag`

### M4.7 Three-finger drag and look-up tap
- Do: three-finger drag per setting; three-finger tap → Look Up via Ctrl+Cmd+D keyboard events (§6.9.1). Fixtures `three_finger_drag`, `three_finger_tap_lookup`.
- Test (AUTO+MANUAL): fixtures. Owner: with three-finger drag on, three fingers move a window; three-finger tap on a word in TextEdit opens Look Up.
- Commit: `engine: three finger drag and lookup`

### M4.8 Lift-off safety
- Do: 1.5 s timeout lift-off releasing every button (`forceLiftoff(releaseDragLock: true)`); synthetic lift-off keeps drag lock; heartbeat-while-tracking → `forceLiftoff(releaseDragLock: false)`; vanished-contact and reused-ID rules (§4.7, §6.5.10); BYE/connection loss call the forced lift-off. Fixtures `liftoff_timeout`, `liftoff_timeout_releases_drag_lock`, `contact_vanishes`, `contact_id_reused`; `TrackglassMacTests` pipeline test for the heartbeat rule.
- Test (AUTO+MANUAL): fixtures and the pipeline test. Owner: start a drag, kill the phone app → the Mac releases the button within 2 s; with Network Link Conditioner at 100 % loss for 1 s during a lift, the button still releases.
- Commit: `engine: liftoff safety`

### M4.9 Replay tool and Mac recorder
- Do: Mac `ReplayRecorder` (a "Record session" menu item for now) writing `.tgrec` with origin 2; `tgreplay run`, `tgreplay verify-dir`, `tgreplay invariants --drop --seed` (§6.10); `Scripts/ci.sh` runs `tgreplay verify-dir Tests/Fixtures`; record one real tap-drag session from the phone on the Mac and add it as the snapshot fixture `recorded_tap_drag` (settings = Appendix A defaults + `unitGain`; expected = `tgreplay run` output committed after the owner confirms the Mac performed the drag correctly).
- Test (AUTO+MANUAL): owner performs one tap-drag while recording and confirms the Mac dragged; Instruments → Allocations on the Mac during 20 s of dragging shows zero transient allocations in `InputPipeline`/`GestureEngine`/`QuartzInjector`; CI passes with the new fixture.
- Commit: `tools: tgreplay`

---

## M5 — Pointer acceleration

### M5.1 tgaccel and default curves — Gate G-ACC
- Do: `tgaccel` dumps `HIDAccelCurves`, `HIDPointerResolution`, `HIDPointerReportRate`, `HIDScrollAccelCurves`, `HIDPointerAccelerationTable` of the built-in trackpad as JSON (§6.6 "Where the numbers come from"; *2026-10-31:* also the scroll resolution/rate/acceleration keys listed there, looked up on parents too, with `tgaccelKeySources`); commit the reference Mac's output as `Mac/Resources/DefaultAccelCurves.json`. Record in PROGRESS which representation (parametric curves or table) the reference Mac exposes.
- Test (AUTO): `tgaccel` exits 0 on the reference Mac; the JSON parses and contains ≥ 2 curves (or a table).
- Commit: `tools: tgaccel and default curves`

### M5.2 Acceleration curve
- Do: `ParametricAccelerationCurve` (or `TableAcceleration` if G-ACC said table) transcribed from Apple's algorithm (§6.6), curve selection + interpolation by `accelIndex`, `tangent = +∞` defaults, conforming to the `AccelerationModel` protocol from M4.1b.
- Test (AUTO, `EngineTests`): multiplier is monotonic non-decreasing on [0, 50] in/s for every curve in the JSON; continuous at both tangents (±1e-6); interpolation at the midpoint between two indices equals the mean of parameters; `measure {}` ≤ 50 ns.
- Commit: `engine: acceleration curve`

### M5.3 Pointer accelerator
- Do: `PointerAccelerator` (rateMultiplier, floor(hypot), mult = multiplier/velocity, `OUTPUT_SCALE`), mm → counts with `resolution/25.4`; live registry values preferred over the bundle; `accelIndex = clamp(scaling + override, 0, 3)` (override wired in M8.8, default 0); replaces the placeholder gain.
- Test (AUTO+MANUAL): `EngineTests` — a 1 mm/8 ms step produces the same output at 60 Hz and 120 Hz input rates. Owner: pointer feel changes when the Mac's tracking-speed slider is moved.
- Commit: `engine: pointer acceleration`

### M5.4 Calibration C1–C3
- Do: run §10.3 C1–C3 at tracking ticks 1, 4, 7, 10 against the built-in trackpad and the blind A/B; adjust only `OUTPUT_SCALE` if a constant ratio appears; write `docs/Calibration.md`.
- Test (MANUAL): C1–C3 within tolerance; blind A/B passes.
- Commit: `calibrate pointer`

---

## M6 — Scroll, momentum, pinch, rotate, smart zoom

### M6.1 Private-field module
- Do: `Mac/Injection/Quartz/PrivateAPI/TGPrivateFields.h` (every raw field number of Appendix B, including 55 and 137, and the IOHIDEventType values, with source comments), `TGPrivateAPI.m` with runtime resolution of `CGEventSetHIDEvent` (and the alternate symbol name noted in §6.9.4) and the `HIDEvent` class, the `PrivateAPICapabilities` struct (§6.9.4); the §0.5 rule enforced by a `TrackglassMacTests` test that greps `Mac/` for `CGEventField(rawValue:` outside that folder (tests themselves use the exported constants).
- Test (AUTO, `TrackglassMacTests`): the capability test reports which symbols resolved on the build machine; the grep test passes.
- Commit: `mac: private fields`

### M6.2 Scroll and zoom preferences
- Do: read `TrackpadScroll`, `TrackpadHorizScroll`, `TrackpadMomentumScroll`, `TrackpadPinch`, `TrackpadRotate`, `TrackpadTwoFingerDoubleTapGesture`, `AppleEnableSwipeNavigateWithScrolls`; add to `TrackpadSettings` and SETTINGS.
- Test (AUTO, `TrackglassMacTests`): plist fixture test extended.
- Commit: `mac: scroll preferences`

### M6.3 Two-finger scroll — Gate G-DIR
- Do: `TwoFingerRecognizer` scroll part (began/changed/ended after the mode-level mayBegin, activation 1.5 mm, horizontal disable), scroll gain taken from the `AccelerationModel` (`ConstantGainAcceleration` 4 pt/mm in the app until M6.4; `unitGain` in fixtures, so fixtures never change later); injector scroll event (§6.9.2) + type-29 companion (§6.9.3); natural-scrolling sign + field 137. **Gate G-DIR**: verify the direction on the reference Mac in both natural settings; never double-invert.
- Test (AUTO+MANUAL): fixtures `scroll_vertical`, `scroll_horizontal_disabled`; `InjectorTests` captures the scroll event and asserts every field. Owner: Safari scrolls in the correct direction for both natural settings; a Finder list scrolls one row at a time with slow movement.
- Commit: `scroll`

### M6.4 Scroll acceleration — Gate G-SCR
- Do: if `HIDScrollAccelCurves` was present in M5.1 port `IOHIDScrollAccelerator`; otherwise the constant model with `SCROLL_BASE_GAIN`, `SCROLL_ACCEL_GAIN`, `SCROLL_ACCEL_V0` (§6.8).
- Test (AUTO+MANUAL): `EngineTests` — the chosen model is monotonic in speed. Owner: slow scroll is precise, fast scroll travels far.
- Commit: `scroll acceleration`

### M6.5 Momentum
- Do: `ScrollMomentum` recognizer inside the engine, driven by `tick` (§6.8); momentum phases; cancellation on a new contact with the end + mayBegin/cancelled sequence; obeys `TrackpadMomentumScroll`.
- Test (AUTO+MANUAL): fixtures `momentum_cancelled_by_touch` and `momentum_decay` (unit gain: a two-finger flick whose last three frames average 1 000 mm/s = 1 000 pt/s exit velocity reaches < 5 pt/s between 2.0 and 3.0 s of ticks). Owner: a flick in Finder coasts and stops like the built-in trackpad; a touch stops it instantly; setting System Settings → Accessibility → Pointer Control → Trackpad Options → Scrolling to "without inertia" stops momentum within 2 s.
- Commit: `scroll momentum`

### M6.6 Pinch and rotate
- Do: magnify and rotate sub-gestures with independent activation and concurrent emission, gesture begin/end bracketing, injector events (§6.9.3).
- Test (AUTO+MANUAL): fixtures `pinch_only`, `rotate_only`, `scroll_then_pinch`; `InjectorTests` field assertions. Owner: Preview zooms and rotates a PDF, Maps zooms/rotates, Safari pinch-zooms a page; scroll + pinch at the same time works in Preview.
- Commit: `pinch and rotate`

### M6.7 Smart zoom
- Do: two-finger double tap → ZoomToggle when the setting is on; pending secondary click for `doubleClickInterval` only when smart zoom is on (§6.5.7). Update fixture `two_finger_tap` (setting off → immediate) and add `smart_zoom`, `two_finger_tap_pending_then_click` (setting on).
- Test (AUTO+MANUAL): fixtures. Owner: two-finger double tap smart-zooms a Safari page; a single two-finger tap still opens the context menu (after the short delay); with smart zoom off the context menu opens immediately.
- Commit: `smart zoom`

### M6.8 Calibration C4–C6
- Do: run §10.3 C4–C6; tune only Tunable constants; update `docs/Calibration.md` and Appendix A values in `docs/SPEC.md`.
- Test (MANUAL): C4–C6 within tolerance.
- Commit: `calibrate scroll`

---

## M7 — System gestures, Notification Center, Force click

### M7.1 Gesture preferences
- Do: read the remaining §6.4 keys (three/four-finger horizontal/vertical, four/five-finger pinch, two-finger-from-right-edge, `com.apple.trackpad.forceClick`, `ForceSuppressed`, the four `com.apple.dock` gesture keys).
- Test (AUTO, `TrackglassMacTests`): plist fixture test extended.
- Commit: `mac: gesture preferences`

### M7.2 Multi-finger recognizer
- Do: `MultiFingerRecognizer`: axis lock, dock-swipe progress for horizontal/vertical/pinch with `exitVelocity`, cancel-on-reverse, `spaceSwitched` haptic event, navigation swipe when the three-finger setting is 1, Notification Center edge swipe in the two-finger recognizer (§6.5.7–6.5.8); `setGeometry` cancels every active gesture of every recognizer (§8.7). Injector does nothing yet for the new events (logged).
- Test (AUTO, `EngineTests`): fixtures `three_finger_swipe_spaces`, `three_finger_swipe_nav`, `four_finger_mission_control`, `four_finger_app_expose`, `four_finger_pinch_launchpad`, `four_finger_spread_desktop`, `edge_swipe_notification_center`, `rotation_cancels_gesture` (uses a geometry-change record in the settings JSON).
- Commit: `engine: multi-finger swipes`

### M7.3 Dock swipes (legacy-fields path)
- Do: first re-read the current Mac Mouse Fix `TouchSimulator.m` and record in PROGRESS the exact `@available` cut line and private symbol name it uses (§6.9.4); `DockSwipePath` injectable; injector dock-swipe events for the legacy path (§6.9.4), session tap, end re-posts.
- Test (AUTO+MANUAL): `InjectorTests` assert both events and all fields with `DockSwipePath = .legacyFields`. Owner, on a Mac below the cut line if one is available (otherwise note "deferred to M7.4" in PROGRESS): three-finger swipe switches Spaces live; up → Mission Control; down → App Exposé; four-finger pinch → Launchpad/Apps; spread → Show Desktop; a reversed swipe snaps back.
- Commit: `mac: dock swipes`

### M7.4 Dock swipes (attached-HID-event path)
- Do: the `HIDEvent`-based path with the resolved `CGEventSetHIDEvent`/alternate symbol (§6.9.4), selected by the recorded cut line; capability-flag fallback.
- Test (AUTO+MANUAL): `InjectorTests` with `DockSwipePath = .attachedHIDEvent`. Owner, on the reference Mac: the same checks as M7.3.
- Commit: `mac: dock swipes hid event`

### M7.5 Navigation swipe
- Do: `NavigationSwipe` injector event (§6.9.3).
- Test (MANUAL): with "Swipe between pages: three fingers" set on the Mac, a three-finger swipe goes back/forward in Safari.
- Commit: `mac: navigation swipe`

### M7.6 Notification Center — Gate G-NC
- Do: try the FluidTouchGesture event; if it fails, the Accessibility "Clock" press fallback (§6.9.5). Keep both; record which is primary.
- Test (MANUAL): two-finger swipe from the right edge opens Notification Center; a second swipe closes it.
- Commit: `mac: notification center`

### M7.7 Force click — Gate G-FORCE
- Do: `ForceClickRecognizer` (0.60 s stationary hold, consumed contact); injector type-29 Force event attempt; fallback Ctrl+Cmd+D (Look Up) only, no click (2026-10-31); obeys `forceClick` setting (§6.5.9, §6.9.6). Fixture `force_click`.
- Test (AUTO+MANUAL): fixture. Owner: hold on a word in TextEdit → Look Up; hold on a file in Finder → Quick Look (if the private path works) or Look Up fallback; with Force click disabled in System Settings nothing happens.
- Commit: `mac: force click`

### M7.8 Fallbacks and degraded-mode reporting
- Do: keyboard-shortcut fallbacks for Spaces/Mission Control/App Exposé/Show Desktop when a private symbol is missing; `degradedGestures` published by the injector and shown as a line in the menu bar menu (the Settings → Advanced line is added in M8.6b).
- Test (AUTO+MANUAL): `TrackglassMacTests` forces every capability flag false and asserts the fallback events are emitted. Owner: with capabilities forced off via a hidden debug default, three-finger swipe still switches Spaces (discretely) and the menu shows the degraded list.
- Commit: `mac: gesture fallbacks`

### M7.9 Calibration C7–C8
- Do: run C7 and C8; tune only Tunable constants; update `docs/Calibration.md` and Appendix A.
- Test (MANUAL): C7 and C8 pass.
- Commit: `calibrate gestures`

---

## M8 — Settings mirroring, haptics, appearance, HUD, iPad, onboarding

### M8.1 Preferences verification pass
- Do: verify every §6.4 key on the reference Mac with `defaults read` (both domains), fix names/values, add the Bluetooth-domain preference rule test, log unknown values at `.info`.
- Test (AUTO+MANUAL): the `TrackglassMacTests` fixture covers every key; flipping each toggle in System Settings → Trackpad is reflected in the logged snapshot within 2 s.
- Commit: `mac: preferences verified`

### M8.2 Haptics
- Do: Mac sends HAPTIC for click/secondary/force/dragLock/spaceSwitched; phone `HapticEngine` with the §5.6 patterns, CoreHaptics with fallback, start/stop on connect/disconnect, reset handlers; haptics on/off and strength stored in `UserDefaults` (UI arrives in M8.8).
- Test (MANUAL): every click on the phone produces a haptic; secondary and force feel different; disconnecting stops the engine without errors in the console.
- Commit: `haptics`

### M8.3a Themes and surface renderer
- Do: `Theme`, `ThemeStore`, `SurfaceRenderer` (CALayer halos from a pool, driven by the display-link tick), the five themes including Custom (§5.7).
- Test (AUTO+MANUAL): `TrackglassiOSTests` — theme (de)serialization round-trip. Owner: switching themes (via a temporary debug gesture-free picker presented by the root VC) is instant; halos follow fingers with no visible lag; Instruments shows no allocation regression in the touch path.
- Commit: `ios: themes`

### M8.3b Grip button and settings sheet
- Do: grip button (sibling `UIHostingController`), `SettingsSheet` with the §5.1 sections: Mac (list placeholder filled in M8.5), Appearance (theme picker, accent, finger glow, HUD toggle), Feel (placeholder until M8.8), Diagnostics (latency overlay toggle placeholder until M8.4, "Record session" `.tgrec` export via share sheet, origin 1), About (version, privacy statement, Privacy Policy link, Mac app link).
- Test (MANUAL): the grip opens the sheet; a touch on the grip never moves the pointer; Record session produces a file that `tgreplay run` replays.
- Commit: `ios: settings sheet`

### M8.4 HUD and status
- Do: `StatusPill` (connect, state changes, 2 s auto-hide), `LatencyOverlay` (RTT sparkline, loss ‰, fps) fed by STATUS with its full field set (§4.5), Mac sends STATUS once per second; the tap-to-click notice moves from the M4.5 alert into the pill.
- Test (MANUAL): pill shows Mac name and latency after connect and hides; overlay numbers update once per second.
- Commit: `ios: hud`

### M8.5 Onboarding and Macs list
- Do: `OnboardingView` (3 pages; the iPad-only 4th page is added in M8.7), download link + Copy button, `MacsListView` (connect/forget/pair new) filling the Settings "Mac" section, `.noMac` overlay.
- Test (MANUAL): fresh install walks through onboarding into pairing; forgetting a Mac and re-pairing works; with no Mac in range the overlay offers other paired Macs.
- Commit: `ios: onboarding`

### M8.6a Mac Welcome window
- Do: Welcome window (first launch; permissions walkthrough with Accessibility status polling and the System Settings deep link; "Start at login" toggle with `SMAppService`, default on when the user finishes Welcome).
- Test (MANUAL): first launch shows Welcome; granting Accessibility flips the status without relaunch; after reboot the app auto-starts.
- Commit: `mac: welcome window`

### M8.6b Mac Settings window and menu
- Do: Settings window tabs General (login item, update check placeholder until M11.1, tracking-speed override mirror read-only), Devices (paired phones: forget), Advanced (Record session, pipeline stats placeholder until M10.1, "Reduced gesture mode" line from M7.8), About; final menu layout (§6.1); single-instance guard.
- Test (MANUAL): every tab renders; forgetting a phone disconnects it; launching a second copy activates the first.
- Commit: `mac: settings window`

### M8.7 iPad
- Do: all orientations, Stage Manager/Split View size changes re-send SURFACE, iPad-only onboarding page about multitasking gestures; verify pencil is still ignored (done in M2.2).
- Test (MANUAL on iPad): rotate and resize in Stage Manager → mm dimensions update and pointing stays correct; Apple Pencil does nothing; with iPadOS gestures disabled, four-finger swipes reach the Mac.
- Commit: `ios: ipad`

### M8.8 Feel settings
- Do: Feel section: tracking-speed override (−1…+1) persisted and sent in the `trackingOverride` field of HELLO/SURFACE (already in the codec since M1.3), applied by the Mac as `accelIndex = clamp(scaling + override, 0, 3)` (§6.4); haptics on/off and strength controls bound to the M8.2 defaults.
- Test (MANUAL): moving the override slider changes pointer speed within one second; 0 equals the Mac's own setting (compare with the built-in trackpad).
- Commit: `ios: feel settings`

---

## M9 — Robustness

### M9.1 Mac lifecycle items
- Do: §8 items 2–6 (display-sleep ordering, fast user switching, display reconfiguration, Accessibility revocation polling, signing-identity assertion placeholder in `Scripts/`); re-verify item 1 (done in M3.6). Extend `docs/QA-Robustness.md` (created in M3.7) with a checklist of all §8 items.
- Test (MANUAL): each item verified per the checklist.
- Commit: `robustness: mac lifecycle`

### M9.2 Phone and engine items
- Do: §8 items 8, 10–15, 17; fixture `settings_change_deferred` for item 16; verify item 7 with the M7.2 fixture and item 9 with the M4.1b pipeline test.
- Test (AUTO+MANUAL): new fixture passes; manual items per the checklist.
- Commit: `robustness: phone and engine`

### M9.3 Loss and latency conditioning
- Do: run `tgreplay invariants --drop 0.05 --seed 1…20` over all fixtures; Network Link Conditioner "3 % loss" and "100 ms spikes" sessions; fix what breaks.
- Test (AUTO+MANUAL): invariants hold for every fixture and seed; manual sessions show no stuck state and reconnect ≤ 2 s.
- Commit: `robustness: loss handling`

### M9.4 24-hour soak
- Do: add a `TrackglassiOSUITests` target to `project.yml`; XCUITest script on the phone that moves one finger continuously; run 24 h; Instruments Leaks on the Mac at start and end; record results in PROGRESS.
- Test (MANUAL): Mac memory flat (±5 MB), no leaks, no log spam, still connected at the end.
- Commit: `robustness: soak`

---

## M10 — Diagnostics, latency, polish

### M10.1 Pipeline latency stats
- Do: `LatencyStats` histogram (receive → post), p50/p95 in STATUS and Settings → Advanced.
- Test (AUTO+MANUAL): `TrackglassMacTests` histogram test; owner reads p95 ≤ 0.3 ms on the reference Mac.
- Commit: `mac: latency stats`

### M10.2 End-to-end latency measurement
- Do: measure both §7 latency metrics: instrumented (RTT/2 + pipeline + 8.3 ms) at 120 Hz and 60 Hz; finger-to-pixel with the 240 fps camera for the phone and for the built-in trackpad, 20 trials each; write `docs/Latency.md`.
- Test (MANUAL): instrumented median ≤ 12 ms and p95 ≤ 20 ms on the 120 Hz iPhone; camera: Trackglass ≤ trackpad + 10 ms. Otherwise profile and fix before continuing.
- Commit: `docs: latency`

### M10.3 Coalesced samples (iPad)
- Do: capability bit1: emit one frame per coalesced timestamp when the touch sample rate exceeds the display rate; compare engine velocity smoothness with and without on a recorded session.
- Test (AUTO+MANUAL): replay shows smoother velocity (lower frame-to-frame variance) with coalesced frames; keep it enabled only if so, otherwise leave disabled and record why.
- Commit: `ios: coalesced samples`

### M10.4 Accessibility and polish
- Do: VoiceOver labels on every control, Dynamic Type in settings, light/dark for all SwiftUI screens, English strings reviewed, app icons (iOS set + Mac icon), menu bar template icon.
- Test (MANUAL): VoiceOver can operate pairing and settings end to end; no truncated strings at the largest accessibility size on iPhone SE.
- Commit: `polish: accessibility and icons`

### M10.5 Thermal and power behavior
- Do: thermal state `.serious` disables halos; low power mode unchanged; idle timer restored on disconnect.
- Test (MANUAL): simulate thermal state in Xcode → halos stop; screen auto-locks after disconnect.
- Commit: `ios: thermal and power`

---

## M11 — Release

### M11.1 Sparkle
- Do: Sparkle 2 via SPM, `SUFeedURL` from xcconfig, automatic checks, "Check for Updates…" menu item and General-tab control, EdDSA public key in Info.plist.
- Test (MANUAL): with a local test appcast, an update from 0.9.0 to 1.0.0 installs and relaunches.
- Commit: `mac: sparkle updates`

### M11.2 Release script, notarization, DMG, GitHub release
- Do: `Scripts/release-mac.sh <version>` per §6.11 (archive → export Developer ID → DMG via `hdiutil` → `notarytool submit --wait` → `stapler` → `gh release create` with the DMG and `Releases/release-notes/<version>.md` → `generate_appcast --download-url-prefix` → commit and push `Releases/appcast.xml`), clean-tree and existing-tag guards, team-identifier assertion. Needs the owner's Developer ID certificate, notarytool credentials in the Keychain, and `gh auth login`. Run it once for a `0.9.0` pre-release (marked as pre-release on GitHub).
- Test (MANUAL): the script produces a stapled DMG that passes `spctl -a -t open --context context:primary-signature -v`, the `0.9.0` pre-release exists on GitHub with the DMG attached, `Releases/appcast.xml` lists it with a working enclosure URL, and the DMG opens without warnings on a clean Mac.
- Commit: `mac: release script`

### M11.3 Website placeholders, README, GitHub Pages
- Do: in `website/` replace the three placeholders (`OWNER/trackglass` → the real owner/repo, including the `data-repo` attribute on each page's `<html>`; `APPSTORE_URL` → the App Store link, or `#download` until it exists; `SUPPORT_EMAIL` → the owner's support address) and verify every link resolves; the owner enables Settings → Pages → Source: GitHub Actions so `.github/workflows/pages.yml` publishes the site; rewrite `README.md` as a short page: title, one-line pitch, "Download for Mac" button → `releases/latest`, link to the website, requirements, setup steps, Developers section; `docs/Install.md` for the manual install path.
- Test (MANUAL): the site is live at `TG_WEBSITE_URL` with the hero demo animating, `privacy.html` and `support.html` open from the iOS About screen, the download button leads to the `0.9.0` pre-release; on a clean Mac, following only the site's support page gets the Mac app installed and paired.
- Commit: `website and readme`

### M11.4 App Store assets and metadata
- Do: `iOS/Resources/PrivacyInfo.xcprivacy` per §5.10; confirm `ITSAppUsesNonExemptEncryption = NO`; screenshots for iPhone 6.9" and iPad 13" (plus optional sizes) showing only real UI, 1024 px icon, privacy label answers, review notes; everything per `docs/APPSTORE.md`.
- Test (MANUAL): App Store Connect accepts the build upload without missing-asset or ITMS warnings.
- Commit: `appstore: assets and metadata`

### M11.5 TestFlight beta
- Do: external TestFlight group with 10 testers for one week; triage; fixes each as its own `fix:` commit with the usual rule.
- Test (MANUAL): no open blocker after the week.
- Commit: `testflight: beta fixes` (one commit that records the triage in PROGRESS, after the individual fix commits)

### M11.6 Tag and submit
- Do: `MARKETING_VERSION = 1.0.0`; run `Scripts/release-mac.sh 1.0.0` (creates the `v1.0.0` GitHub release and updates the appcast); submit the iOS build for review with the release page URL in the review notes.
- Test (MANUAL): App Store approval; a Mac still running `0.9.0` receives the 1.0.0 update through Sparkle and relaunches.
- Commit: `release 1.0.0`

---

## Phase 2 — DriverKit

D1–D3 may run on the dedicated SIP-disabled test Mac before Apple answers the entitlement request (§12.3); D4–D5 only after the entitlement is granted and all G-DRV gates passed.

### D1 Driver target
- Do: `TrackglassDriver` DriverKit target (C++), personality and device description per §12.3 S1, excluded from default schemes; a debug-only "Activate driver (dev)" item in the Mac app's Advanced tab that issues the `OSSystemExtensionRequest`.
- Test (AUTO+MANUAL): the dext builds; on the test Mac with `systemextensionsctl developer on`, the owner activates it from the Advanced tab and `systemextensionsctl list` shows it activated.
- Commit: `driver: skeleton`

### D2 Descriptor and feature reports
- Do: S2 + S3 (report descriptor transcribed and decoded with comments; feature-report responses).
- Test (MANUAL on the test Mac): `ioreg -l` shows the virtual device with the expected VID/PID; `hidutil list` lists it.
- Commit: `driver: descriptor and feature reports`

### D3 Input reports and user client
- Do: S4 + S5 (`tgdrivertest` CLI pushing scripted finger paths through the user client).
- Test (MANUAL): **Gates G-DRV-1…5** per §12.3. Record every outcome in `docs/Phase2-Spike.md`. If any gate fails after iterating transport strings/feature responses: stop Phase 2 here.
- Commit: `driver: input reports`

### D4 DriverInjector
- Do: `DriverInjector` mapping (§12.4), engine bypass rules, observe-only tap detector for haptics, Force-click pressure ramp.
- Test (MANUAL): the full §10.4 matrix with the driver active; everything behaves like the built-in trackpad with no private CGEvent path involved.
- Commit: `driver: injector`

### D5 Activation UX and fallback
- Do: Settings → Advanced "Native trackpad driver" toggle with `OSSystemExtensionRequest`, automatic fallback to Quartz, `WELCOME.injectorMode`, Sparkle-delivered driver update path.
- Test (MANUAL): enabling prompts for approval in System Settings; declining leaves Quartz active; a build without the entitlement never shows the toggle.
- Commit: `driver: activation`

*End of plan.*
