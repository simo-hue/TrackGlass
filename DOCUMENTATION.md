# Implementation log

- [2026-10-27 18:10 CET]: M11.2/M11.3/M11.4 groundwork and audit backlog (uncompiled)
  - *Details*: Release pipeline `Scripts/release-mac.sh` (SPEC §6.11) with per-run export options so the team ID never enters the repo, `Releases/` layout and 0.9.0 notes; README rewritten per PLAN M11.3 with `docs/Install.md`; website repo placeholders filled; `PrivacyInfo.xcprivacy` per §5.10. Backlog from the audit: streaming `.tgrec` writer, control-channel handshake watchdog, single pipeline timer, real `engineState` levels plus the §6.3 idle reset, honest degraded-gesture list, recording-state sync, spec log categories, sequence helpers, parametric replay model, scroll-axis interval, duplicate-frame suppression, snapshot-ordered session state. New tests: `ControlChannelTests` (3), `TGRecTests.testFileWriterStreams…`, `MessageHeaderTests.testSequenceOrderingAndGapsAcrossWrap`, `PointerInjectorTests.testDegradedList…`, `ConnectionStateTests` (2).
  - *Tech Notes*: Left for the owner (see `TO_SIMO_DO.md`): Sparkle keys + M11.1 integration, notarization profile, `gh auth`, `SUPPORT_EMAIL`/`APPSTORE_URL`, LICENSE, Pages enablement, the PIN-pairing decision, and all device work (M10.2, M10.3, calibrations, soak). Mac log categories changed from "Input"/"Control" to "net" — older manual-check notes that say "Input log" mean the `net` category now. No new dependencies.

- [2026-10-27 16:40 CET]: M10.4 — Accessibility and icons (uncompiled)
  - *Details*: `Scripts/make-icons.py` (Pillow) renders the iOS 1024 px universal icon, the ten macOS sizes as a HIG rounded rectangle with shadow, and the §6.1 two-outline menu-bar template icon at 1x/2x/3x into asset catalogs wired through `project.yml` (`ASSETCATALOG_COMPILER_APPICON_NAME`); `MenuBarExtra` now uses `Image("MenuBarIcon")`. Accessibility: the touch surface is a single `allowsDirectInteraction` element labelled "Trackpad", PIN rows expose `.isSelected`, the camera view has a label/hint, the scanner message uses Dynamic Type, onboarding pages scroll at large sizes, discovery status (Local Network denial) is shown in the Macs list. Tests: `AccessibilityTests` (iOS), `MenuBarIconTests` (Mac).
  - *Tech Notes*: Generated PNGs are committed; rerun the script after a brand change. Still uncompiled in this session; owner runs `xcodegen generate && Scripts/ci.sh`. Manual M10.4 acceptance (VoiceOver pairing/settings end to end, no truncation at the largest accessibility size on iPhone SE) deferred. No new dependencies (Pillow is a tooling-only requirement of the generator script).

- [2026-10-27 16:00 CET]: Codebase audit and fixes (uncompiled)
  - *Details*: Five parallel read-only audits (TrackglassKit, TrackglassEngine + fixtures + tgreplay, Mac companion, iOS app, tooling/config/docs) produced ~70 findings; the confirmed bugs were fixed in place, each with a regression test where the harness allows: `DragSafetyTests` (7 engine tests), `PointerInjectorTests` (dragged event types, sub-point accumulation), `testSamePhoneReconnectSupersedesItsStaleSession`, `testNonFiniteOrNonPositiveGeometryIsRejected`, `testApproximateComparisonToleratesFloatingPointNoiseOnly`. Highest-impact fixes: a lost/cancelled drag contact could leave the Mac's left button held forever; pointer motion during a drag was posted as `mouseMoved` so AppKit drags never worked; a finger held still for 1.5 s was force-released by the Mac (phone now sends stationary keep-alives); opening Mac Settings or pairing a second device restarted the input listener without the admitted phone's key; `IOHIDManagerOpen` every 2 s would trigger Input Monitoring; the `settings_change_deferred` fixture was inconsistent with the engine (momentum kept the settings pending). Full list in `docs/PROGRESS.md` (decisions section) and the findings that need the owner in `TO_SIMO_DO.md`.
  - *Tech Notes*: Still no Xcode in this session: all changes are unverified until `xcodegen generate && Scripts/ci.sh`. Deferred (not fixed) findings are recorded in `TO_SIMO_DO.md` §"Audit follow-ups": PIN-pairing PSK brute force (SPEC §3.4 decision), scroll-acceleration registry keys (§6.8), pointer motion withheld during the resting-thumb settle (fixture `resting_thumb_ignored` encodes it), streaming `.tgrec` writer, per-datagram `Data` allocation in `UDPFrameSink`, duplicate frames per UIEvent, `ConnectionManager.refreshState` reentrancy, SPEC §2.3 layout drift, missing LICENSE, `PrivacyInfo.xcprivacy` (M11.4). No new dependencies.

- [2026-10-27 13:20 CET]: M9.1–M9.4, M10.1, M10.5 — Robustness scripts, latency stats, thermal behavior (uncompiled)
  - *Details*: Added the SPEC §8 checklist (all 17 items) plus loss-conditioning and soak procedures to `docs/QA-Robustness.md`; `Scripts/invariants.sh` replays every fixture with 5 % loss for seeds 1–20 and is called by `Scripts/ci.sh`; `TrackglassiOSUITests` target and `TrackglassiOSSoak` scheme with `SoakUITests` (`TG_SOAK_SECONDS`); `LatencyStats` (Mac) records receive→post per frame into a 1 000-sample ring buffer with a preallocated 4 096-bucket histogram, p50/p95 flow into STATUS and Settings → Advanced via `ControlListener.lastStatus`, with `LatencyStatsTests`; iOS thermal `.serious`/`.critical` suppresses halos through `SurfaceRenderer.setHalosSuppressed` (touch sending untouched), with `ThermalStateTests`.
  - *Tech Notes*: This session's shell was a Linux VM without Xcode, so nothing from this session or from the morning's M8.6a–M9.2 work has been compiled or tested yet. Owner must run `xcodegen generate` (new UI-test target and scheme) and `Scripts/ci.sh`, then report errors. §8 items 2–6 were already satisfied by existing code (wake assertion before the event in `PointerState.move`, `setSessionActive(false)` → busy, `DisplayBounds` reconfiguration callback, 5 s `AXIsProcessTrusted` polling → BYE + Welcome, `Scripts/assert-signing-team.sh`); no code change was needed for them. M10.2 (camera latency), M10.3 (coalesced samples — needs a recorded session to compare), M10.4 (icons, VoiceOver pass) and M11 remain. No new dependencies.

- [2026-10-27 08:25 CEST]: M8.6a–M9.2 — Mac Welcome/Settings windows, iPad, Feel settings, robustness items (uncompiled)
  - *Details*: `MacWindowCoordinator` with Welcome (Accessibility polling, System Settings link, login item default on) and Settings (General/Devices/Advanced/About), §6.1 menu and single-instance guard in `TrackglassMacApp`; iPad orientations and SURFACE re-send on bounds change; Feel section (tracking override, haptics controls) and Mac-side `effectiveSettings` clamp; fixture `settings_change_deferred` with `settingsChanges` support in the fixture harness and `tgreplay`; `ControlSessionTests.testInactiveUserSessionRejectsAdmissionUntilReactivated`.
  - *Tech Notes*: Reconstructed from the working tree on 2026-10-27 13:00 (the session that wrote these files ended without logging them). Whether the final Mac/iOS builds passed after 08:17 is unknown; treat as unverified until CI runs.

- [2026-10-22 15:11 CEST]: M5.3 — Pointer acceleration
  - *Details*: Added report-rate-normalized millimeter-to-count acceleration, tracking-speed curve updates with index clamping, live IORegistry curve preference, bundled JSON fallback and the specified emergency curve fallback. The Mac app now packages `DefaultAccelCurves.json`; the engine's placeholder gain is replaced by `PointerAccelerator`.
  - *Tech Notes*: EngineTests pass in debug (10 tests, one optimized-only performance test skipped) and release (10 tests); all 29 Mac hosted tests pass. The Mac Debug build includes the bundled curves. The 60/120 Hz equal-velocity check passes. Manual tracking-speed slider check remains deferred; no dependencies added. M5.3 remains uncommitted pending manual acceptance and earlier deferred commit boundaries.

- [2026-10-22 15:05 CEST]: M5.2 — Parametric acceleration curve
  - *Details*: Added an Apple IOHIDFamily parametric curve evaluator with fixed-point registry decoding, acceleration-index selection/interpolation, tangent segments and AccelerationModel conformance.
  - *Tech Notes*: EngineTests pass in debug (6 passed, performance test intentionally skipped) and release (7 passed); release multiplier benchmark meets the 50 ns limit. Reference curves are monotonic on 0–50 in/s, tangent continuity and midpoint interpolation pass. No dependencies added. M5.2 remains uncommitted because its M4.1b protocol dependency is part of the owner's deferred, uncommitted work.

- [2026-10-22 15:00 CEST]: M5.1 — tgaccel and default curves
  - *Details*: Implemented `tgaccel` to read built-in Apple multitouch trackpad registry properties and saved the reference Mac acceleration data.
  - *Tech Notes*: `tgaccel` exits 0; JSON parses and contains 10 parametric curves, a 771-byte acceleration table, pointer resolution 26,214,400 and report rate 120. G-ACC selects the parametric curve representation because `HIDAccelCurves` is present; table data is retained. No dependencies added.

- [2026-10-22 14:58 CEST]: M4.9 — Replay tool and Mac recorder
  - *Details*: Added a Mac menu-bar recording toggle that saves received frames as origin-2 `.tgrec` files, plus replay, fixture-directory verification, and seeded packet-drop invariant commands. CI now runs the replay verifier.
  - *Tech Notes*: Full `Scripts/ci.sh` passed: 32 Kit tests, 3 Engine tests, 29 Mac hosted tests, 17 iOS simulator tests, app/tool builds, and 18 replay fixtures verified. The real phone tap-drag snapshot and 20-second Instruments allocation check remain deferred. No dependencies added; M4.9 remains uncommitted.

- [2026-10-22 14:54 CEST]: M4.8 — Lift-off safety
  - *Details*: Added 1.5-second contact silence timeout, heartbeat-triggered liftoff, synthetic liftoff that preserves deliberate drag lock, forced disconnect release, and vanished/reused contact handling.
  - *Tech Notes*: EngineTests pass (3 tests, including the four required safety fixtures); Mac hosted suite passes (29 tests), including heartbeat and real timeout release tests. Phone termination and packet-loss checks remain deferred. No dependencies added; M4.8 remains uncommitted.

- [2026-10-22 14:52 CEST]: M4.7 — Three-finger drag and Look Up
  - *Details*: Added three-finger centroid drag with the Mac preference, shared drag release/lock handling, three-finger tap recognition, and the Ctrl+Cmd+D Look Up key sequence.
  - *Tech Notes*: EngineTests pass (3 tests, including both required fixtures); Mac hosted suite passes (27 tests). Finder/TextEdit manual checks remain deferred. No dependencies added; M4.7 remains uncommitted.

- [2026-10-22 14:51 CEST]: M4.6 — Multi-click and drag
  - *Details*: Added click-count tracking, Dragging-dependent second-tap button timing, tap-and-a-half drag movement, timed release grace, drag-lock persistence/release, and logged haptic suggestions.
  - *Tech Notes*: EngineTests pass (3 tests, including double/triple tap, tap drag, and drag lock fixtures); Mac hosted suite passes (27 tests). Finder manual checks remain deferred. No dependencies added; M4.6 remains uncommitted.

- [2026-10-22 14:48 CEST]: M4.5 — Taps and clicks
  - *Details*: Added single-finger tap clicks, two-finger secondary clicks, configured bottom-corner secondary clicks, Mac left/right mouse button injection, and the one-time iPhone notice when Mac tap-to-click is disabled. The settle-window fixture now records its qualifying two-finger secondary click.
  - *Tech Notes*: EngineTests pass (3 tests, including tap, two-finger, and both corner fixtures); hosted Mac suite passed (27 tests); iOS device build succeeded. Manual interaction checks remain deferred. No dependencies added; M4.5 remains uncommitted.

- [2026-10-22 14:46 CEST]: M4.4 — Trackpad preferences
  - *Details*: Added synchronized preference reads for built-in and Bluetooth trackpad domains, Bluetooth-device detection, a two-second polling service, settings application when the engine is idle, and live SETTINGS updates to connected phones.
  - *Tech Notes*: Mac hosted suite passes 27 tests, including built-in/Bluetooth plist fixture parsing; Mac app builds through the hosted test run. Physical preference toggles and corner-value mapping remain deferred. No dependencies added; M4.4 remains uncommitted.

- [2026-10-22 14:44 CEST]: M4.3 — Contact rules and fixture harness
  - *Details*: Added fixed-capacity contact tracking, palm rejection, resting-thumb detect/release rules, settle-window mode changes with scroll mayBegin/cancelled events, the specified GestureEvent JSON encoding, fixture settings defaults and replay harness. Added palm, resting-thumb and settle-window `.tgrec` triplets.
  - *Tech Notes*: `swift test --package-path Packages/TrackglassEngine` passes 3 tests with zero package warnings; the Mac Debug build succeeds. The physical resting-thumb check is deferred to the owner's manual-check iteration. No dependencies added; M4.3 remains uncommitted.

- [2026-10-22 14:40 CEST]: M4.2 — Pointer bounds and display wake
  - *Details*: Added active-display bounds refresh on Core Graphics reconfiguration, edge sliding and clamping for pointer movement, and a user-activity declaration when input resumes after at least 10 seconds idle.
  - *Tech Notes*: Mac Debug build succeeds. External-display crossing and display-sleep wake checks are deferred to the next manual-check iteration. No dependencies added; M4.2 remains uncommitted pending manual acceptance.

- [2026-10-22 14:34 CEST]: M4.1b — Pointer input pipeline
  - *Details*: Added a pointer-only GestureEngine, fixed event buffer, unit/constant gain acceleration, queue-confined datagram pipeline, 8 ms estimated-phone-time tick, and Quartz mouse movement with suppression disabled. Admitted-session geometry is initialized from HELLO and updated on SURFACE.
  - *Tech Notes*: Mac hosted tests pass 25/25, including ordering, backwards frame-time and tick-clock coverage; Mac build succeeds. InputPipeline now owns TouchFrame decoding, and InputListener keeps only transport frame/loss counters. Physical pointer/mouse check is deferred to the next iteration. No dependencies added; step remains uncommitted pending manual acceptance.

- [2026-10-22 14:17 CEST]: M3.5 — Input channel implementation
  - *Details*: Added the DTLS input listener and connected it to the admitted control session. The listener is recreated with only the admitted phone's LTK, binding authenticated input to the active phone; the phone sends touch frames and idle INPUT_HEARTBEAT messages, and the Mac reports frame rate and sequence-gap loss once per second.
  - *Tech Notes*: The local macOS SDK does not expose the authenticated peer's selected PSK identity. The owner approved the single-admitted-key listener design; SPEC §6.3 and PLAN M3.5 now record it. Network.framework sends datagrams with `.idempotent`. No dependencies added. Manual ProMotion frame-rate and raw unencrypted UDP checks are pending.

- [2026-10-22 14:22 CEST]: M3.6 — Reconnect and lifecycle implementation
  - *Details*: Added actor-owned phone discovery/session coordination with a 0.5-to-8-second foreground reconnect backoff, background BYE, and Mac listener shutdown/restart on sleep/wake. Control channels now close after three missed PINGs.
  - *Tech Notes*: Both iOS and Mac app builds succeed. The iPhone and iPad are unavailable for physical lifecycle checks, which remain deferred under the owner's existing authorization. M3.5 manual acceptance remains pending as well; no step is marked complete or committed.

- [2026-10-22 14:23 CEST]: M3.7 — Security verification setup
  - *Details*: Added hosted tests proving a wrong control PSK cannot complete its handshake and an unencrypted UDP payload is not accepted by a DTLS listener. Added the Wireshark encryption procedure as the first section of `docs/QA-Robustness.md`.
  - *Tech Notes*: Existing pairing exchange tests cover one-use replay rejection; existing PIN pairing tests cover key rotation and the three-attempt limit. All 23 Mac hosted tests pass (log: `/tmp/trackglass-m37-tests.log`). The physical Wireshark packet capture remains deferred. No dependencies added.

- [2026-10-22 14:26 CEST]: M4.1a — Accessibility gating
  - *Details*: Extracted Accessibility permission prompting and one-second grant polling into `AccessibilityPermission`. Added a menu hint and a button that opens the Accessibility pane; the advertiser starts listeners after permission is granted.
  - *Tech Notes*: No new dependencies. The Mac build and manual revoked/granted permission check are pending.

- [2026-10-20 12:47 CEST]: P0.1 — Project scaffold (manual verification pending)
  - *Details*: Added the XcodeGen project, empty black UIKit scene for iPhone/iPad, and Mac menu-bar app with Quit. Both prescribed app builds pass; the Mac app has been opened. P0.1 remains uncommitted until manual verification passes.
  - *Tech Notes*: Installed XcodeGen 2.46.0. Swift 6 with complete strict concurrency; iOS 17 and macOS 14 deployment targets; Mac hardened runtime enabled and sandbox disabled. Shared configuration supplies product identifiers, GitHub Pages URL, and versions to generated Info.plists. The development team read from the owner's WealthCompass project is stored only in gitignored `Config/Local.xcconfig`. Generated Xcode projects, local signing configuration, build products and non-fixture recordings are ignored. The iOS scaffold build reports an orientation warning; orientation behavior is assigned to M2.1. No packages or later-step implementation added.

- [2026-10-20]: P0.1 — Verification complete
  - *Details*: Owner confirmed the Mac menu test and authorized continuing implementation, deferring mobile installation until a device test requires it. Both app builds passed.
  - *Tech Notes*: No code changes since the successful builds.

## Current Status

Owner instruction, reaffirmed 2026-10-27: continue feature after feature with automated tests; defer calibration and routine device acceptance. Do not claim unperformed physical gates passed.

2026-10-27 15:08: full `Scripts/ci.sh` passed on the reference Mac with the audit fixes; everything through M10.5 is committed (5c1057f, one combined commit at the owner's request). Agent sessions in Cowork run in a Linux VM without Xcode: the owner runs CI and reports. M10.4 committed (6a93258). Release groundwork (M11.2–M11.4 code/docs) and the audit backlog are implemented and await CI; next is M11.1 Sparkle once the owner has keys; M10.2 (latency measurements) and M10.3 (coalesced samples, needs an iPad recording) wait for device time. Owner decisions pending in `TO_SIMO_DO.md` "Audit follow-ups" (PIN-pairing security first).

M7 physical G-NC/G-FORCE gates remain pending; private fluid/force attempts are not implemented. Calibration (M5.4, M6.8, M7.9) remains deferred. Recent committed independent changes remain c537e0f, 94e49e9, c2e6c92. New dependent work remains uncommitted pending deferred physical acceptance; do not stage all existing work.


- [2026-10-20]: P0.2 — Packages and CI
  - *Details*: Added both shared packages, placeholder package and app-hosted tests, and empty tgreplay/tgaccel targets. CI exited 0, including simulator tests and both signed app builds.
  - *Tech Notes*: Engine depends on Kit; both packages enforce Swift 6, complete strict concurrency and warnings as errors. Injector placeholder skips without Accessibility. CI supports an optional TG_IOS_TEST_DESTINATION override and also builds both command-line tools. No new third-party dependencies.

- [2026-10-20]: P0.3 — Build documentation
  - *Details*: Added README setup, signing, build, test and install commands, plus Apple APSL-2.0 attribution and Sparkle MIT/upstream notices. Confirmed the progress checklist covers all plan steps; CI exited 0.
  - *Tech Notes*: No implementation or dependency changes. References are facts only; no MMF, VoodooInput or Touch code is included.

- [2026-10-20]: M1.1 — Message header
  - *Details*: Added the 16-byte little-endian header, all message type values, typed decoding errors and a monotonic nanosecond clock. Six package tests pass with zero warnings.
  - *Tech Notes*: Unknown type bytes are retained; magic is compared byte-wise; unaligned buffers are supported. Clock converts mach_absolute_time with full-width arithmetic. No new dependencies.

- [2026-10-20]: M1.2 — Touch frame codec
  - *Details*: Added inline ten-contact frame storage and bounded little-endian encoding/decoding, including both flags and enum values. Eleven tests pass in Debug and Release; 10,000 deterministic fuzz cases do not trap.
  - *Tech Notes*: No array-backed contact storage or per-frame allocations. Release measure batches averaged about 48 ns per ten-contact encoding; the 300 ns assertion passed. Malformed sizes, reserved bits and contact enums are rejected. No new dependencies.

- [2026-10-20]: M1.3 — Control messages
  - *Details*: Added every specified TCP payload, nested welcome settings, all STATUS fields, length-prefixed UTF-8 strings and unknown-type handling. Sixteen package tests pass, including exhaustive truncation checks for each payload.
  - *Tech Notes*: UUIDs use 16 wire bytes; LTK requires 32 bytes; numeric fields are little-endian. Invalid UTF-8, oversized strings and trailing payload bytes produce typed errors. No new dependencies.

- [2026-10-20]: M1.4 — Control stream framer
  - *Details*: Implemented the Network.framework length-prefix framer with bounded 64 KiB messages and partial-input state. Eighteen package tests pass, including 1,000 ordered loopback messages and fragmented prefix/payload delivery.
  - *Tech Notes*: UInt32 little-endian framing; no-copy body delivery; invalid lengths fail the connection. Uses Network.framework only.

- [2026-10-20 21:20 CEST]: M1.5 — Pairing crypto
  - *Details*: Added peer identities, strict QR payload parsing, six-digit PIN HKDF and specified TLS/DTLS parameter factories. All 24 package tests pass, including a Python-derived HKDF vector and correct/wrong PSK loopback tests.
  - *Tech Notes*: Server options register each supplied PSK; multi-key feasibility remains M3.4. Wrong-key TLS reports server failed/bad MAC and client waiting/bad MAC; the initial test timed out because it only handled failed. Corrected the test to observe both TLS rejection states, removed temporary logs and reran the complete suite. Production security configuration was unchanged. No new dependencies.

- [2026-10-20]: M1.6 — Surface geometry
  - *Details*: Added physical-unit conversion with injected native scale, device pixel densities, marketing names and fallbacks. All 28 package tests pass, including the reference 393 × 852-point geometry and window resizing.
  - *Tech Notes*: Pure Swift point/size values avoid UIKit/CoreGraphics in the package. Apple pixel-density references are recorded in docs/DevicePPI.md; reference iPhone and iPad entries checked. No new dependencies.

- [2026-10-20]: M1.7 — Recording format
  - *Details*: Added TGREC version-1 headers, origin and hundredth-millimeter geometry, record writer/reader and file round-trips. Thirty-one package tests pass, including 500 frames for both recording origins and malformed/truncated input.
  - *Tech Notes*: Capture timestamps and raw touch-frame bytes are preserved; integer fields are little-endian and frame sizes are bounded. File writing is atomic. No new dependencies.

- [2026-10-20]: M2.1 — Touch surface root (manual test pending)
  - *Details*: Installed a black multitouch/exclusive UIKit surface as scene root, hid system indicators, deferred all screen-edge gestures, enabled specified phone/iPad orientations, and managed the idle timer with visibility and scene activity. Full CI exited 0.
  - *Tech Notes*: No gesture recognizers or networking added. The iOS orientation build warning is resolved. iPhone installation reached developer-image mounting but failed because the device is locked (CoreDevice 12040 / 10003). Manual verification and commit await installation and owner confirmation.

- [2026-10-20]: M2.1 — Device installation resolved
  - *Details*: Installed and launched the validated Debug build on the reference iPhone after it was unlocked.
  - *Tech Notes*: No code changes. Awaiting manual verification before committing.


- [2026-10-20 21:45 CEST]: M2.1 — Edge-swipe diagnosis
  - *Details*: Owner confirmed idle prevention and reported edge-swipe failure. Inspected the actual root controller and ran a temporary real-device XCUITest. The first-swipe screenshot shows the app switcher, confirming the reported failure. No production code was changed during diagnosis.
  - *Tech Notes*: The test process returned success because XCUIApplication.state still reported foreground during system UI presentation; this is not a valid passing result for edge deferral. Evidence is in /tmp/trackglass-edge-probe/baseline.xcresult. Restored project.yml, regenerated the project, uninstalled the temporary UI-test runner, and relaunched Trackglass. SPEC §5.4 explicitly requires prefersHomeIndicatorAutoHidden=true alongside all-edge deferral; owner decision is required before changing that final decision.


- [2026-10-21]: M2.1 — Approved home-indicator correction
  - *Details*: Set automatic home-indicator hiding to false and updated SPEC §5.4 and PLAN M2.1 with owner approval. Kept status-bar hiding and all-edge deferral.
  - *Tech Notes*: Signed iOS build succeeds. Device probe built/installed and returned success, but screenshots still show system UI on first synthetic swipe; its foreground assertion is insufficient and is not accepted as a pass. Production project restored after probe. Both physical devices now unavailable; runner uninstall and app relaunch failed with CoreDevice 4016. No new dependencies or commit.


- [2026-10-21]: M2.2 — Touch capture and console frames (manual check deferred)
  - *Details*: Added retained ten-slot contact tracking, a 256-ID free-list, phase/kind filtering, point-to-millimeter conversion using the window screen scale, event timestamps, and one console frame per UIKit callback. Terminal samples are emitted before their IDs are released.
  - *Tech Notes*: Seven simulator-hosted tests pass, including six new tests for retention, capacity, ID exhaustion/reuse, phase and input filtering, physical conversion, and timestamps. Coordinates and two-contact distance are debug-only private log data. No gesture recognizers, synthetic lift-off, networking, or new dependencies. Owner authorized deferring device checks; this is implementation progress, not a completed milestone. M2.3 queue-full behavior is not specified in PLAN or SPEC; decision requested before implementing the sender.


- [2026-10-21]: M2.3 — Bounded frame sender
  - *Details*: Added a 16-frame ring with owner-approved drop-oldest overflow, serial userInteractive draining, a reused 188-byte Data encoding buffer, and a preallocated surface frame. Sink now borrows encoded bytes synchronously.
  - *Tech Notes*: A dispatch data-add source avoids creating a dispatch closure per enqueue; a lock protects ring access and encoding stays queue-confined. Console logging consumes borrowed payload bytes without constructing contact strings. Added deterministic overflow/wraparound, encoding and buffer-address reuse tests. No new dependencies. Device Instruments allocation verification remains deferred; zero allocation is not yet claimed.


- [2026-10-21]: M2.3 — Automated verification
  - *Details*: Nine simulator-hosted tests and the signed iPhone build pass. Overflow test blocks the consumer and confirms only the newest 16 queued frames survive; encoder pointer stays identical for 28-byte and 188-byte payloads.
  - *Tech Notes*: Manual Instruments check still pending. Tests and build logs: /tmp/trackglass-m23-test.log and /tmp/trackglass-m23-build.log.

- [2026-10-21]: M2.4 — Display-link delivery
  - *Details*: Added the ProMotion Info.plist opt-in and a display link requesting 80–120 Hz on high-refresh screens while the surface is attached to its window. Added a debug moved-event rate counter. Signed iPhone build passes.
  - *Tech Notes*: Default scheduling remains on 60 Hz screens. The display link never sends touch frames; a weak target avoids retaining the surface/driver. Physical ≥115/≥58 event-rate checks are deferred.


- [2026-10-21]: M2.5 — Lift-off and surface changes
  - *Details*: Added exactly one empty synthetic frame after removal of the last contact, including cancellation; subsequent real frames clear the synthetic flag. Added geometry-change callbacks on layout changes, including rotation and resizing, with dimensions logged in millimeters.
  - *Tech Notes*: Nine simulator-hosted regression tests and the signed iPhone build pass. Physical emission/rotation behavior remains a deferred manual check. No heartbeat cadence or network behavior added ahead of the networking steps. Logs: /tmp/trackglass-m25-test.log and /tmp/trackglass-m25-build.log.


- [2026-10-21]: M3.1 — Bonjour discovery
  - *Details*: Added the two peer-to-peer-enabled TLS/DTLS listeners and specified TXT records, a persistent Mac UUID, menu advertising status, and phone Bonjour browsing with distinct main/pairing instances. Added the local-network plist declarations to both apps and a dismissible SwiftUI discovery list.
  - *Tech Notes*: Uses the plan’s temporary dev PSK, accepts no sessions/input at this stage, and waits for Accessibility permission before starting listeners. Pair IDs decode as canonical base64url eight-byte values. Parser tests cover malformed metadata and separate pairing instances; Mac tests cover identity persistence and TXT fields. No third-party dependencies. Apple’s public AX option key is expressed as its verified string value because the C global is rejected under Swift 6 strict concurrency. Device discovery timing and router-off peer-to-peer checks remain deferred.


- [2026-10-21]: M3.1 — Full CI verified
  - *Details*: Scripts/ci.sh exited 0 with all applicable tests and builds passing. Physical discovery checks remain deferred.
  - *Tech Notes*: No package warnings. The existing Accessibility-dependent placeholder test skips without a grant. CI log: /tmp/trackglass-m31-ci.log.


- [2026-10-21]: M3.2 — Keychain pairing store and phone identity
  - *Details*: Added shared PairingStore save/load/all/delete APIs, validated 32-byte LTKs, exact JSON payload fields and ISO8601 dates, idempotent deletion, and update-in-place saves. Added a persisted phone UUID and user-editable name defaulted from the marketing-model catalog.
  - *Tech Notes*: Generic-password items use app.trackglass.pairing, the other peer’s UUID account, AfterFirstUnlockThisDeviceOnly and synchronizable=false; every Mac query selects the data-protection Keychain. Mac hosted tests initially failed with errSecMissingEntitlement (-34018). Added the app-specific keychain-access-groups entitlement through XcodeGen using build-variable prefixes; signed-host tests now pass. No Team ID is stored in source and no fallback to the legacy Keychain was added. Shared hosted tests verify lifecycle, updates, two-peer listing, storage attributes/JSON and invalid-key rejection. No new dependencies or manual actions.


- [2026-10-21]: M3.2 — Full CI verified
  - *Details*: Keychain tests pass in both signed application hosts, including storage protection and JSON validation; phone marketing-name defaults and user-name/UUID persistence pass. Full Scripts/ci.sh exited 0.
  - *Tech Notes*: 31 Kit tests, one Engine test, six Mac tests with one pre-existing AX skip, and fifteen iOS tests; both app and tool builds pass. Package warnings remain zero. Commit net: pairing store is queued behind earlier deferred manual-step commits. Log: /tmp/trackglass-m32-ci.log.


- [2026-10-21]: M3.3a — QR pairing
  - *Details*: Added the Mac floating 480×360 pairing window with a 320×320 CoreImage QR, CSPRNG pairing credentials, a separate 120-second pairing listener, single-use admission and Keychain persistence. Added the phone name field, AVFoundation QR scanner, Bonjour pairing-instance matching, cancellable TLS-PSK exchange, and paired-peer lists on both apps.
  - *Tech Notes*: Uses existing codecs/framing/TLS helpers. PAIR_REQUEST is version checked; the client checks the returned Mac identity before storing the LTK. No secrets are logged. Camera setup/start/stop run on a dedicated serial queue and permission denial has a visible message. Five signed-host loopback/render tests verify QR payload preservation, matching stored LTKs/names, replay rejection, concurrent admission, closed-window rejection and authorization gating. Full CI passes with fifteen iOS tests; the final Mac regression run passes twelve tests with one existing Accessibility placeholder skip. Physical QR/camera verification is deferred. No new dependencies.

- [2026-10-21]: M3.1 fix — Report actual Bonjour registration
  - *Details*: The pairing tests exposed Bonjour PolicyDenied while listening sockets were ready. Advertising status now requires both service registrations as well as ready listeners, so the menu cannot falsely claim discovery is available. QR presentation also waits for pairing-service registration and uses the registered instance name.
  - *Tech Notes*: Added a status regression test; final Mac test run passes. User must allow Local Network access for physical discovery tests. Queue a separate fix commit (`fix: report bonjour registration status`) after the pending M3.1 commit; no implementation has been committed yet. Logs: /tmp/trackglass-m33a-ci.log and /tmp/trackglass-m33a-registration-test.log.


- [2026-10-21]: M3.3b — PIN pairing and URL handoff
  - *Details*: Added CSPRNG six-digit PINs with unbiased sampling and leading zeros, PIN/QR modes in the Mac window, HKDF PIN exchange, and phone selection of pairing-only advertisements. Failed handshakes rotate the PIN, pairID and QR secret, replace the listener/TXT record and invalidate pending connections. Three PIN generations are allowed per window; a fourth is unavailable until a new window is opened.
  - *Tech Notes*: Only one handshake runs at a time, preventing concurrent guesses against the same PIN. UI mode chooses the listener’s active PSK; this does not assume multi-key support before Gate G-TLS. Mode changes and credential rotation preserve the original 120-second deadline. Added trackglass URL registration, cold/warm SceneDelegate routing, and payload-bearing SwiftUI presentation. Invalid URLs cannot replace a valid pending request. Full CI passes; physical PIN, rotation display and Camera-app handoff tests remain deferred. No new dependencies; PINs/QR secrets are not logged or stored in defaults.


- [2026-10-21]: M3.3b — Final PIN regression
  - *Details*: The focused PIN suite passes, including a real fourth connection after exhaustion using the last correct PIN; it is rejected and no peer is stored.
  - *Tech Notes*: Full CI log: /tmp/trackglass-m33b-ci.log. Final PIN regression log: /tmp/trackglass-m33b-fourth-attempt.log. No manual result or commit claimed.


- [2026-10-21]: M3.4 — Protocol clarification required
  - *Details*: Reviewed the control-session requirements and existing WelcomeMessage. The busy response must name the active phone, but WELCOME contains only Mac identity/name, OS version, injector mode and settings; no other specified Mac-to-phone message carries the active phone name. Stopped per CLAUDE.md and the owner’s explicit spec-error rule.
  - *Tech Notes*: Proposed appending a length-prefixed activePhoneName string to WELCOME, empty unless busy; requires owner approval before changing SPEC §4.5 or the M1.3 codec. No code changed, no test or commit claimed; G-TLS remains pending.


- [2026-10-22]: M1.3 correction — Active phone name in WELCOME
  - *Details*: With owner approval, appended activePhoneName to WELCOME so a busy response can identify the active controller. The default is empty for other statuses. Updated SPEC §4.5.
  - *Tech Notes*: Uses the existing u16-length UTF-8 encoding. All 32 Kit tests pass with zero compiler warnings, including busy/empty round trips, exact UTF-8 bytes and exhaustive truncation rejection. Both apps must use the corrected prerelease protocol layout. No dependencies added.


- [2026-10-22]: M3.4 — Multi-key transport gate on development Mac
  - *Details*: Added hosted loopback gate tests: one listener registers two distinct keys/phone identities, both clients send framed PING payloads and receive exact authenticated echoes. TLS and DTLS both pass; negotiated versions are asserted as TLS 1.2 and DTLS 1.2.
  - *Tech Notes*: Tested macOS 27.0.1 (26A434). Initial TLS test payload was below the framer’s 16-byte minimum; corrected the test to use valid encoded PING messages and reran successfully. DTLS emits SSL_set_min_proto_version diagnostics for the spec’s shared TLS minimum setting, but negotiates DTLS 1.2 successfully; production configuration unchanged. Final log: /tmp/trackglass-m34-gate.log. macOS 14 validation is pending, so the gate branch remains provisional and session implementation has not started. Gate tests are uncommitted with M3.4.


- [2026-10-22]: M3.4 — Control session
  - *Details*: Replaced the dev PSK with all paired-phone keys on both listeners and refresh listeners after pairing/Forget. Added one-phone actor admission, HELLO/WELCOME defaults, named busy response, SURFACE and override updates, PING/PONG RTT, timeout and BYE. Added phone connection/disconnection controls and a status button as a sibling of the touch surface; idle timer now requires a visible, connected, foreground surface.
  - *Tech Notes*: Shared ControlChannel handles only low-rate framed traffic; touch capture and datagrams stay separate. Unknown message types log once; incompatible versions send BYE. SessionCoordinator owns admission and geometry by connection token. Loopback tests cover busy ownership, settings, RTT, rotated geometry and override, release/re-admission, Forget with a recreated-key listener, and incompatible HELLO. Initial harness test selected port zero before listener readiness; corrected to wait for a nonzero bound port. No dependencies added. M3.5 datagram input and M3.6 reconnect remain unimplemented.


- [2026-10-22]: M3.4 — Verification complete; physical checks pending
  - *Details*: Full CI exited 0, and the final four session integration tests pass, including three unanswered PINGs causing timeout. Busy rejection preserves the first connection; disconnection releases admission; a forgotten key is rejected on the next handshake while the remaining phone can connect.
  - *Tech Notes*: Logs: /tmp/trackglass-m34-ci.log and /tmp/trackglass-m34-final-session.log. Both signed apps build. iPhone and iPad installation attempts both failed with CoreDevice 4016; no physical or macOS 14 pass claimed. Separate step snapshot retained under Git metadata trackglass-pending-steps/M3.4. Exact future step commit: net: control session. No M3.4 commit made before manual confirmation.


- [2026-10-22]: iPad installation — Awaiting Developer Mode
  - *Details*: Connected physical iPad detected; retried installation of the verified M3.4 build. Installation was rejected because Developer Mode is disabled. Mac companion opened.
  - *Tech Notes*: CoreDevice 12040, MobileImageMounterDiskImageRestricted 0xe800011c, underlying message “Developer mode is not enabled on device”. No code change or manual test pass. Immediate next action: owner enables Developer Mode and confirms restart, then retry iPad installation/launch. iPhone remains unavailable.


- [2026-10-22]: M3.4 — iPhone build installed and launched
  - *Details*: Detected the connected physical iPhone 15 Pro Max, successfully installed the verified signed app and launched app.trackglass.ios. Opened the Mac companion for pairing/connection verification.
  - *Tech Notes*: Awaiting owner’s first physical pairing/Connected/RTT result; no manual pass or new commit claimed. Immediate next action: receive that result, then verify rotation, Forget and idle behavior; two-device busy check still needs the iPad with Developer Mode enabled.


- [2026-10-22]: Mac pairing diagnosis — Local Network access denied
  - *Details*: Inspected both supplied screenshots. iPhone is looking for Macs; Mac pairing UI explicitly waits for Bonjour permission. A targeted system-log query confirms repeated PolicyDenied errors on the running Mac app’s main and pairing listeners at the reported time. Codes are gated on successful service registration.
  - *Tech Notes*: No code change justified by this evidence; direct OS diagnostics identify the blocker without speculative fixes. Owner must allow Local Network access, restart the Mac companion and retry pairing. No permission reset or unrelated skill-configuration changes made. Immediate next action: verify QR/PIN after the permission change; if already allowed or app absent, inspect that state before further action.


- [2026-10-22]: M3.4 — Physical connection and RTT confirmed
  - *Details*: Owner enabled Mac Local Network access and confirmed the iPhone can connect with updating RTT. Reported absent pointer movement is expected: M3.4 implements the control session; M3.5 adds touch transport and M4.1b adds pointer injection.
  - *Tech Notes*: This is a partial manual pass only. Rotation/SURFACE, Forget/rejection, connected idle behavior and second-device busy checks remain pending. Immediate next action: verify the remaining M3.4 checks; do not claim pointer injection or commit M3.4 as fully verified.


- [2026-10-22]: M3.4 — Physical rotation and disconnection confirmed
  - *Details*: Owner reports disconnection and rotation working. Mac info logs independently verify SURFACE changes at 11:28:04 and 11:28:13, swapping 71.230438 × 154.387833 mm and back, with PPI 460.
  - *Tech Notes*: No code changes. “Disconnection” does not establish that Forget removed trust and rejected a subsequent connection; that specific outcome still needs confirmation. Immediate next action: confirm Forget shows Pair again on the next connection attempt. Idle-timer and second-device busy checks remain pending/deferred; no full M3.4 pass or commit claimed.


- [2026-10-22]: M3.4 — Forget and rejection confirmed
  - *Details*: Following the specific Mac Forget/reconnect instructions, the owner confirmed the check works. Physical iPhone connection, updating RTT, rotation/SURFACE, disconnection and Forget/reconnection rejection are now confirmed.
  - *Tech Notes*: No code changes. The remaining explicit PLAN M3.4 manual acceptance check is a second paired device receiving busy naming the active iPhone. iPad installation previously failed because Developer Mode was disabled. Immediate next action: reconnect/unlock the iPad with Developer Mode enabled, install the verified build and perform that two-device check. Connected idle behavior is also still unverified, but is not an additional explicit PLAN M3.4 acceptance item. No M3.4 commit or complete milestone claimed.


- [2026-10-22]: Trackglass logo — Owner-requested design interlude
  - *Details*: Generated and visually inspected a logo concept combining a rounded touch surface and curved fingertip path in the website’s blue/lavender palette. Selected the simpler dark-background design after transparent glass variants showed edge artifacts.
  - *Tech Notes*: Saved Design/Brand/trackglass-logo-v1.png and its full generation prompt. Built-in image generation used; PNG inspected with sips. No app code, asset catalogs, dependencies or step commits changed. Logo generation complete; M3.4 two-device busy test remains the next implementation verification task.


- [2026-10-22]: Session handoff and approved logo
  - *Details*: Owner approved the final dark-background logo and requested a handoff prompt before continuing implementation in another session. Updated Current Status to supersede stale device-installation and Local Network blockers.
  - *Tech Notes*: Handoff document saved outside the repository in the OS temporary directory. No source changes, new test claims or commits. Resume from existing M3.4 implementation and its remaining busy check; do not restart completed work.


- [2026-10-25 19:23 CET]: M6.1 — Private Mac event support
  - *Details*: Centralized Appendix B event fields/types, added cached runtime API detection and missing-symbol/class fallbacks, and enforced the private-module source boundary. Owner approved deferring M5.4 calibration; OUTPUT_SCALE remains 1.0.
  - *Tech Notes*: Five new tests and all 34 Mac hosted tests pass. HIDEvent resolves; neither CGEventSetHIDEvent nor CGEventSetIOHIDEvent resolves on this Mac, so dockSwipe is false. Gesture event construction is available; fluid/force flags remain disabled pending their gates. No private framework linker dependency or new package dependency.


- [2026-10-25 19:25 CET]: M6.1 — Bridging-header warning fix
  - *Details*: Replaced pragma-once with a conventional header guard so direct Swift bridging-header compilation emits no main-file pragma warning.
  - *Tech Notes*: Mac hosted regression passes all 36 tests, including the five private API checks.


- [2026-10-25 19:27 CET]: M6.2 — Scroll and zoom preferences
  - *Details*: Added seven scroll/zoom/navigation preferences to engine snapshots, built-in/Bluetooth preference parsing and the owner-approved SETTINGS/WELCOME wire layout. Defaults preserve older replay recordings.
  - *Tech Notes*: All 33 Kit tests pass (including all 128 preference combinations), 10 Engine tests pass with one optimized-only skip, 36 Mac hosted tests and 17 iOS hosted tests pass. Both wire message forms share one codec. No dependencies added. This step remains uncommitted because its preference/engine files include earlier manually deferred implementations.


- [2026-10-25 19:28 CET]: M1.3 correction — Scroll preferences in SETTINGS
  - *Details*: With owner approval, appended seven Boolean preference bytes to SETTINGS and its WELCOME embedding. Both variants share one serializer/parser. Updated SPEC §4.5.
  - *Tech Notes*: All 33 Kit tests, 36 Mac hosted tests and 17 iOS hosted tests pass; signed iPhone build succeeds. Wire-layout coverage exercises all 128 combinations and truncated old payloads. No protocol-version bump for this owner-approved prerelease change; install both apps together.


- [2026-10-25 19:28 CET]: M6.3 — Scroll draft and resting-thumb specification conflict
  - *Details*: Added the two-finger scroll recognizer, 1.5 mm activation, separate scroll acceleration, natural-direction sign, horizontal disable, gesture termination, and prevention of a click after activated scrolling. Added Quartz wheel/gesture companion construction with point/line accumulation and field assertions.
  - *Tech Notes*: Both new recording fixtures and focused scroll tests pass; all 38 Mac hosted tests pass. Full EngineTests: 12 tests, one optimized-only skip, one failure in resting_thumb_ignored. SPEC centroid activation starts before its 150 ms thumb classification, contradicting the fixture's required no-scroll result. Owner decision requested; no speculative change to the thumb rule or expected fixture, no M6.3 commit, no G-DIR/manual pass. Logs: /tmp/trackglass-m63-engine.log and /tmp/trackglass-m63-mac.log. No new dependencies.


- [2026-10-26]: M6.3 — Resting-thumb protection and scroll verification
  - *Details*: Under the owner's instruction to resolve routine implementation details and continue, suppressed activation while a stationary bottom-zone finger remains a resting-thumb candidate. All existing gesture recordings remain unchanged.
  - *Tech Notes*: All 12 engine tests passed (one optimized-only performance skip); all 38 Mac hosted tests passed. Natural direction, horizontal disable, event fields and subpoint/subline accumulation are covered. Physical G-DIR remains deferred, not passed.

- [2026-10-26]: M6.4 — Apple scroll acceleration
  - *Details*: The reference archive contains HIDScrollAccelCurves, selecting the Apple parametric branch. Added independent-axis recent-motion history, direction/pause resets, device-unit conversion, curve selection, and live/bundled data loading with the specified fallback.
  - *Tech Notes*: All 15 EngineTests pass (one optimized-only skip); Mac hosted regression passes. Output speed is monotonic across the reference curves; tests cover linear units, sign, history reset and fallback bounds. Apple's square-root segment can reduce gain while output speed continues increasing. No new dependencies. Physical feel/calibration remains deferred.


- [2026-10-26]: M6.5 — Momentum
  - *Details*: Added three-sample exit velocity, 8 ms engine-tick decay, touch cancellation, preference-driven inertia stop, and wheel-only momentum events. Synthetic empty lift-off preserves coasting; disconnect/geometry reset cancels it.
  - *Tech Notes*: Momentum decay and touch-cancellation fixture triplets pass. Tests cover stale/slow samples, disabled inertia, synthetic lift-off and forced stop. Mac event tests assert momentum phase and absence of gesture companions. Physical feel remains deferred.

- [2026-10-26]: M6.6 — Compound pinch and rotation
  - *Details*: Added independent pinch/rotation activation, simultaneous scrolling, angle unwrap, begin/end brackets, cancellation, and Quartz gesture events. Resting-thumb candidates suppress unintended compound activation.
  - *Tech Notes*: pinch_only, rotate_only and scroll_then_pinch fixture triplets pass. Concurrent recognition, preference disable and private event fields are tested; all 21 engine tests (one optimized-only skip) and Mac hosted tests passed at this boundary.

- [2026-10-26]: M6.7 — Smart zoom
  - *Details*: Two-finger double taps emit smart zoom; single secondary taps wait for the double-click interval when smart zoom is enabled. Disabled smart zoom retains immediate right click. Disconnect drops delayed clicks.
  - *Tech Notes*: smart_zoom and two_finger_tap_pending_then_click fixtures pass; earlier immediate-click fixtures explicitly disable smart zoom. Smart zoom works with secondary click disabled. All 23 engine tests (one optimized-only skip) and Mac hosted tests pass. No dependencies added for M6.5–M6.7.

- [2026-10-26]: M7.1–M7.2 — Gesture preferences and recognition
  - *Details*: Added multi-finger and Dock preference snapshots, axis-locked Spaces/navigation/vertical/pinch recognition, reverse cancellation, and right-edge Notification Center recognition. Late extra contacts no longer change a locked gesture.
  - *Tech Notes*: M7.1 package and hosted tests passed. Eight new replay fixtures pass; final focused recognition checks are in progress. Physical acceptance remains deferred. Immediate next step: Dock event injection. No dependencies added.

- [2026-10-26]: M7.3–M7.5 — Dock and navigation event injection
  - *Details*: Implemented legacy Dock field pairs, progress accumulation, terminal velocity, timed end reposts, conditional HID attachment, and navigation swipe began/ended events. Pipeline ticking now continues while the injector has delayed end events.
  - *Tech Notes*: Legacy field/repost tests passed with all 44 Mac tests. Attached construction and navigation tests are running. Current MMF uses macOS 27.0 as its cut line and calls CGEventSetHIDEvent, but its own bridge defines that function; it is not an exported OS API on this Mac. Runtime attachment remains unavailable and requires the specified fallback. No raw-memory bridge copied or introduced; physical acceptance deferred.

- [2026-10-26]: M7.6–M7.8 — System gesture fallbacks and force hold
  - *Details*: Added the Accessibility Clock action for Notification Center, one-shot 600 ms stationary force holds with consumed lift, delayed click/Look Up fallback, terminal-only Dock shortcuts, and a Reduced gesture mode menu. The hidden TGDisablePrivateGestures default exercises missing-capability behavior.
  - *Tech Notes*: 27 engine tests pass (one optimized-only skip); the force-click recording brings the suite to 36 fixtures. Mac regression passed 47 tests before the final force-fallback timing test. No dependencies added. G-NC/G-FORCE private event attempts remain unimplemented/unverified because HID fields do not establish CGEvent field mappings and the attachment symbol is unavailable. Shipping candidates currently use the specified fallbacks; their actual OS behavior still needs essential device verification. Calibration remains deferred.

- [2026-10-27]: M8.1 — Preference verification and global-domain fix
  - *Details*: Verified available keys in both reference trackpad domains; fixed shared global values being dropped when host-specific values are present. Unknown values now fall back safely and are reported once per key.
  - *Tech Notes*: Hosted tests passed, including Bluetooth selection, shared/host precedence, invalid-value validation and all gesture preferences. Physical toggle timing remains deferred; no dependencies added.

- [2026-10-27]: M8.2 — Haptic implementation in verification
  - *Details*: Routed gesture outcomes over HAPTIC to the admitted phone; added the six specified CoreHaptics patterns, two-pulse force click, impact fallback, lifecycle handling, and persisted enabled/strength settings.
  - *Tech Notes*: New pattern and preference tests added. Mac and iOS hosted regressions are running; no physical feel acceptance claimed. No dependencies added.

- [2026-10-27]: M8.2 — Haptics verified
  - *Details*: Mac and iOS hosted regressions pass, including haptic pattern values and persistent strength/enable settings. Hardware feel remains deferred.
  - *Tech Notes*: SessionClient's haptic calls are UIKit-conditional for the Mac-hosted transport harness. No dependencies added.

- [2026-10-27]: M8.3a–M8.3b — Themes, halos and settings
  - *Details*: Added five procedural themes, persistent appearance selection, pooled display-link halos, a sibling grip control, settings sections, and origin-1 phone recording/export. Recording state survives closing/reopening Settings.
  - *Tech Notes*: iOS hosted suite passed 22 tests, including theme serialization, persisted selections and decoding the phone recording. Rendering uses ten reusable gradient layers; noise generated once. Physical latency/allocation checks remain deferred.

- [2026-10-27]: M8.4 — Live status and diagnostics
  - *Details*: Mac sends STATUS once per second; phone shows a two-second connection pill and optional 120-sample RTT graph, FPS and loss. Tap-to-click notice moved into the pill. RTT updates now refresh the observable connection state.
  - *Tech Notes*: Both hosted suites passed. All STATUS fields are transported; pipeline histogram values remain zero until M10.1, as planned. No dependencies added.

- [2026-10-27]: M8.5 — Onboarding and saved Macs
  - *Details*: Added three-page first-launch onboarding, download/copy actions, saved-Mac connect/forget controls, and an offline surface overlay. Removed raw discovery identifiers from user-facing lists.
  - *Tech Notes*: iOS hosted verification is running in /tmp/trackglass-m85-ios.log. Physical fresh-install/re-pair acceptance remains deferred. Immediate next step: inspect test result, then M8.6 Mac Welcome/Settings windows.
