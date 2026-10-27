# Manual actions

## M3.5 — Input channel verification (2026-10-22)

1. Install and launch the latest signed TrackglassiOS build on the iPhone and the latest TrackglassMac build. Connect the iPhone to the Mac.
2. Move one finger continuously on the ProMotion phone surface. The Mac's Input log should report approximately 120 `framesPerSecond` and a `lossPermille` value once per second.
3. Read `udpPort` from the Mac Input log. From Terminal on the Mac, run `printf 'raw-udp-probe' | nc -u -w 1 127.0.0.1 <udpPort>`. This unencrypted packet must not produce an `input ready` event or a frame-rate increment.
4. Reply with the observed frame rate and whether the raw packet was ignored. M3.5 must remain uncommitted until these checks are confirmed.

## M3.6 — Reconnect and lifecycle verification (2026-10-22)

1. With the iPhone connected, turn Wi-Fi off and back on. Expect Trackglass to reconnect within 2 seconds.
2. Put the Mac to sleep and wake it. Expect the iPhone to reconnect after the Mac restarts its listeners.
3. With the iPhone connected, move Trackglass to the background. The Mac log should show the control session ending after BYE.
4. Report each result or the exact failure. M3.6 must remain uncommitted until these checks are confirmed.

## M3.7 — Wireshark transport verification (2026-10-22)

1. Follow the first section of `docs/QA-Robustness.md` on the Mac while the paired iPhone connects and sends touch frames.
2. Confirm the control and input ports show TLS and DTLS records, with no clear touch payload or coordinates. Record macOS/Wireshark versions and the result.
3. The iPhone is currently unavailable to development tools; complete this capture once it is available. Keep M3.7 uncommitted until the capture is confirmed.

## M4.1a — Accessibility gating (2026-10-22)

1. Quit Trackglass. In System Settings → Privacy & Security → Accessibility, temporarily turn Trackglass off.
2. Reopen the updated app at `/Users/simo/Library/Developer/Xcode/DerivedData/Trackglass-ezhlhwnemaflqtbjwrtrlmngdpbe/Build/Products/Debug/TrackglassMac.app`. The menu must show “Grant Accessibility to start,” and the phone must not be able to connect.
3. Use the menu's “Open System Settings” button, turn Trackglass back on, and wait up to one second. Without relaunching, the menu should return to its advertising state and the phone should connect.
4. Confirm the observed menu and connection behavior. M4.1a must remain uncommitted until the check passes.

## M4.1b — Pointer movement (deferred to next iteration)

1. With Accessibility granted and the latest Mac app running, connect the paired iPhone and move one finger across the surface. The Mac pointer should follow smoothly in both axes.
2. While connected, move the pointer with the Mac's physical trackpad or mouse. It should continue to work alongside the phone.
3. Report both results. Also complete the M4.1a revoked/granted permission check above. Do not mark either step complete or commit it until its manual check is confirmed.

## M4.2 — Pointer bounds and display wake (deferred)

1. Connect an external display. Move the phone pointer across the display boundary in both directions; it should cross naturally and stay on an active display at all edges.
2. Let the display sleep. Touch and move on the phone; the display should wake and the pointer should move from that same input.
3. Report both results. Keep M4.2 uncommitted until confirmed.

## M4.3 — Contact rules (deferred)

1. Connect the phone and move one finger across the surface. Rest your thumb at the bottom edge without moving it; after the settling interval, pointer movement should continue from the index finger without a jump or unwanted scroll.
2. Lift the thumb, then repeat with the thumb moving more than 3 mm. It should be treated as an active contact again.
3. Report both results. Keep M4.3 uncommitted until confirmed.

## M4.4 — Trackpad preferences (deferred)

1. In System Settings → Trackpad, toggle “Tap to click” while Trackglass is running. Within two seconds the Mac log should record a changed settings snapshot.
2. Toggle the secondary-click corner option between left, right, and off. Confirm SETTINGS maps left to bottom-left and right to bottom-right; record the observed preference values.
3. If a Bluetooth trackpad is available, change its settings and confirm its preference domain takes precedence while connected; disconnect it and confirm built-in settings take precedence again.
4. Report the results and corner value mapping for `docs/PROGRESS.md`. Keep M4.4 uncommitted until confirmed.

## M4.5 — Taps and clicks (deferred)

1. Install/launch the latest iPhone app and Mac app, connect the phone, and tap the surface once. Confirm one left click occurs at the current pointer location.
2. Tap with two fingers together. Confirm a context menu opens on the Mac.
3. Set the Mac secondary-click corner to bottom-left, then bottom-right. Tap each configured corner on the phone and confirm a context menu; tap outside the configured corner and confirm a left click.
4. Turn off “Tap to click” in Mac System Settings and reconnect if needed. Confirm the iPhone shows “Tap to click is off on your Mac” once, while taps continue to click; confirm it does not show again on a later connection.
5. Report results. Keep M4.5 uncommitted until its manual checks are confirmed.

## M4.6 — Multi-click and drag (deferred)

1. Install/launch the latest Mac and iPhone builds and connect the phone.
2. In Finder, double-tap a file. Confirm it opens.
3. In Finder, use a tap followed quickly by a second tap held while moving to drag a window by its title bar. Confirm the window follows the finger and the Mac releases the drag after lifting and waiting about 0.3 seconds.
4. Turn on Drag Lock in Mac Trackpad settings. Repeat the drag; confirm the drag remains held after lifting, then tap elsewhere to release it.
5. Report results. Keep M4.6 uncommitted until its manual checks are confirmed.

## M4.7 — Three-finger drag and Look Up (deferred)

1. Turn on “Three finger drag” in Mac Trackpad settings and connect the phone.
2. Place three fingers on the phone surface and move them together across a Finder window title bar. Confirm the window follows, then releases after lifting (or stays held with Drag Lock enabled until a tap).
3. In TextEdit, place the pointer over a word and tap with three fingers. Confirm macOS Look Up opens.
4. Report results. Keep M4.7 uncommitted until its manual checks are confirmed.

## M4.8 — Lift-off safety (deferred)

1. Install/launch the latest Mac and iPhone builds, connect the phone, and start a tap-and-a-half drag in Finder.
2. Force quit Trackglass on the phone while the drag is held. Confirm the Mac releases the mouse button within 2 seconds.
3. Reconnect. Enable Network Link Conditioner at 100% packet loss for 1 second while lifting a finger during a drag. Confirm the phone's heartbeat causes the Mac to release the button; deliberate Drag Lock should survive this heartbeat lift-off.
4. Report results. Keep M4.8 uncommitted until its manual checks are confirmed.

## M4.9 — Replay recorder (deferred)

1. In the Mac menu bar, choose “Record session”, connect the phone, and perform one tap-and-a-half drag in Finder. Choose “Stop recording”; confirm a `.tgrec` file appears under `~/Library/Application Support/Trackglass/Recordings/`.
2. Replay the recording with `tgreplay run` using Appendix A defaults and `unitGain`. Confirm the event stream contains the pointer movement and button sequence for the drag.
3. Confirm that the Mac performed the drag correctly. Only then add this recording as `Tests/Fixtures/recorded_tap_drag` with its settings and expected event output.
4. In Instruments → Allocations, record 20 seconds of phone dragging. Confirm zero transient allocations in `InputPipeline`, `GestureEngine`, and `QuartzInjector`.
5. Report results. Keep M4.9 uncommitted until the recording and allocation checks pass.

## P0.1 — 2026-10-20

1. Reconnect and unlock the iPhone and iPad so development installation can be retried. Both currently report unavailable and return CoreDevice error 4016.
2. The Debug Mac app has been opened. Click Trackglass in the Mac menu bar and confirm that its menu contains Quit.
3. Reply “pass” if the menu check succeeds, or describe what appears. P0.1 will not be committed until the manual check passes and installation is resolved.

Update 2026-10-20: Mac menu check confirmed passed. Only device reconnection remains; installation retries on both devices still returned CoreDevice error 4016. No repeat menu confirmation is needed.

Update 2026-10-20: Owner authorized continuing. No manual action now; mobile installation is deferred until a device test requires it.

## M2.1 — 2026-10-20

1. Unlock the connected iPhone with its passcode and leave it on the Home Screen; reply “unlocked.” Developer Mode is already enabled. No iPad action is needed for this step.
2. After the agent installs and launches Trackglass, confirm the display is fully black with no status bar and the home indicator hides.
3. Swipe inward from each screen edge: the first swipe should not leave the app/open system UI, and a second should allow the system gesture. Return to Trackglass afterward.
4. Leave Trackglass open untouched for 3 minutes: it must not auto-lock. Reply “pass” or describe any difference.

The iPhone install currently fails because the phone is locked (CoreDevice 10003 under 12040). M2.1 remains uncommitted.

Update 2026-10-20: Installation and launch succeeded after unlocking. Only M2.1 test steps 2–4 above remain; reply “pass” or describe any difference.


Update 2026-10-20 21:45 CEST: Owner confirmed no auto-lock; do not repeat that check. First bottom-edge swipe failure reproduced in device screenshots. M2.1 is not passed or committed.

1. Decide whether SPEC §5.4 may change prefersHomeIndicatorAutoHidden to false, keeping all-edge deferral, to prioritize two-swipe protection. The indicator may remain visible/dimmed. This is a proposed spec correction, not yet implemented.
2. After that decision and a rebuilt/installed app, repeat only the edge-swipe manual test. No iPad action is required by M2.1.


Update 2026-10-21: Specification correction approved and implemented; no further approval of that change needed. Corrected app built and installed during device probe, but edge behavior is not verified.

1. Reconnect the iPhone by cable, unlock it, and leave it unlocked. Reply “connected.” Both physical devices currently report unavailable; no iPad action is needed for M2.1.
2. After the agent relaunches the corrected app, verify actual bottom/top-edge swipes: first must stay on the surface, second may open system UI. The home indicator may stay visible. The 3-minute idle test already passed.


## M2.2 — 2026-10-21 (deferred by owner)

After reconnecting the iPhone, the agent will install the current build and attach the Xcode debugger so private debug values can be inspected locally.
1. Place two fingers 50 mm apart, measured with a ruler: the frame log must show distanceMM between 49 and 51.
2. Lift one finger: its final sample must retain its ID and show phase=4.
3. Add a third finger while keeping the other down: it must not reuse the still-live ID.
4. Report pass or the observed values. The surface remains black; cursor movement is not implemented yet.

M2.1 and M2.2 manual checks are explicitly deferred, not passed. Keep their commits separate after confirmation.


## M2.3 — Deferred device allocation check

1. With the iPhone connected, the agent will build/install and prepare Instruments Allocations. Drag five fingers for 20 seconds.
2. Verify zero transient allocations attributed to Trackglass surface emission and sender code, excluding UIKit internals; confirm frames continue logging.
3. Only after this passes can M2.3 be committed. Queue overflow is resolved: drop oldest, keep newest.


## M2.4–M2.5 — Deferred device checks

1. M2.4: continuously drag one finger; expect ≥115 moved events/s on the ProMotion iPhone and ≥58 on a 60 Hz device. The agent will collect the debug rate logs.
2. M2.5: lift all fingers; expect exactly one extra log with count=0 and synthetic=true.
3. Rotate the device; expect logged surface width and height in millimeters to swap.

These are queued checks for when the owner reconnects the phone; no connection is being requested immediately. Separate step commits remain pending their respective passes.


## M3.1 — Deferred discovery check

1. When testing resumes, open the rebuilt Mac companion. Grant Accessibility in System Settings if prompted and allow Local Network access on both devices. The menu must show “Advertising as <Mac name>”.
2. Open Trackglass on the connected iPhone. Its discovery list must show the Mac within two seconds on the same Wi-Fi, including its id and pr=0.
3. With the router off and both devices disconnected from networks (keep Wi-Fi radios enabled), verify the Mac still appears through peer-to-peer discovery.
4. Tap Done to return to the touch surface for earlier deferred checks. Close Trackglass from the app switcher and relaunch it to reopen discovery.

No immediate device connection is required; these checks remain pending and M3.1 is not committed.


## M3.3a — Deferred QR pairing verification

The Mac test run reported Bonjour PolicyDenied. When device testing resumes, enable Trackglass under System Settings → Privacy & Security → Local Network (and grant Accessibility as previously recorded).

1. Open the rebuilt Mac app, select “Pair a device…”, and confirm a QR appears. It is shown only after Bonjour registration succeeds.
2. On the iPhone, choose “Pair with a Mac…”, confirm/edit the phone name, tap “Scan Mac QR code”, and allow Camera access. Scan the Mac QR.
3. Expect “Paired with <name>” on both sides and names in the phone’s Paired Macs section and Mac’s Paired devices menu.
4. Reuse the original QR (saved locally for this test): pairing must be rejected.
5. Open a new pairing window, then close it: its pairing advertisement must disappear and the code must stop working. A window left open must close after 120 seconds.

No device connection is requested now. These remain pending manual checks; no M3.3a commit yet.


## M3.3b — Deferred PIN and Camera-app checks

1. In the Mac pairing window choose “Use a code instead”. On the phone choose Pair with a Mac → Use a code instead, select the pairing Mac, and enter the six digits. Both sides must list each other after success.
2. In a fresh pairing window enter an incorrect PIN: the Mac must immediately display a different PIN. The phone must require the updated code.
3. Enter wrong codes for all three generations: the window must stop pairing and offer no fourth attempt. Switching QR/PIN modes must not restore attempts; close and reopen the window to start a new session.
4. Open a fresh QR window. Scan with Apple’s Camera app and tap the Trackglass link: Trackglass must open its pairing flow and pair. Test once with Trackglass terminated and once already running.
5. A window must expire 120 seconds after opening even if modes or codes change.

These checks remain deferred until the device is connected; Local Network access on the Mac is still required.


## M3.4 — Protocol decision needed now

1. Decide whether to add `activePhoneName str` to WELCOME (empty unless busy), allowing the required “<Mac> is being used by <phone>” message, or relax PLAN M3.4 / SPEC §8 item 10 to a generic busy message. SPEC §4.5 currently transmits no active-phone name. Implementation is paused under the explicit rule against improvising protocol changes. No device connection or manual app test is needed for this decision.


- 2026-10-22: The M3.4 protocol decision above is resolved: owner approved activePhoneName; implemented and package tests pass.


## M3.4 — macOS 14 gate verification

1. Provide access to the macOS 14 test Mac, or explicitly authorize deferring that compatibility check while implementation continues using the multi-key listeners that passed on macOS 27.0.1.
2. On the macOS 14 test host, run the TrackglassMacTests/TLSGateTests tests with a toolchain compatible with the project. Both testTwoRegisteredKeysTLS and testTwoRegisteredKeysDTLS must pass; provide the test result/log. No fallback is selected solely from the development Mac’s passing result.

The activePhoneName decision is resolved and committed. Phone/iPad manual tests remain deferred as previously authorized. This request follows CLAUDE.md’s instruction to record missing gate hardware and stop, not an additional device-testing requirement.


- 2026-10-22: Owner approved the macOS 14 deferral above. No immediate access is needed; its gate test remains a pre-release check.

## M3.4 — Deferred control-session checks

Both physical devices were unavailable to devicectl on 2026-10-22. Once reconnected, install the latest signed TrackglassiOS build on both devices and launch the rebuilt Mac companion; grant Mac Accessibility and Local Network access.

1. Pair the iPhone with the Mac if needed. In the phone’s Paired Macs list, tap the discovered Mac. Expect “Connected to <Mac>” and an updating RTT in milliseconds; Done returns to the surface, whose top status button reopens the list.
2. Pair the iPad with the same Mac and try connecting while the iPhone remains connected. Expect “<Mac> is being used by <iPhone name>”. The iPhone must remain connected. Disconnect the iPhone, then retry the iPad; it should connect.
3. Rotate the connected device. The Mac’s Control log must show SURFACE with swapped width/height values.
4. On the Mac choose Paired devices → <connected device> → Forget. The device must show “Pair again”; a new connection attempt must also fail with “Pair again”. Pair again to restore access.
5. The visible connected surface must stay awake; after disconnection, normal auto-lock must resume. Backgrounding must restore the idle timer.

These are control-session checks only; touch input is still console-only until M3.5. M3.4 must not be committed as complete until its manual checks pass.

- M3.4 install attempts on both devices failed with CoreDevice 4016. Reconnect and unlock the iPhone and iPad before retrying installation and the checks above. Full CI and final session tests pass.


## iPad installation — Developer Mode required (2026-10-22)

1. On the connected iPad, open Settings → Privacy & Security → Developer Mode and enable it.
2. Restart when prompted; after unlocking, confirm Turn On and enter the passcode if asked.
3. Keep the iPad connected and unlocked, then report ready so installation can be retried.

The iPad is now detected, but installation failed with CoreDevice 12040 / kAMDMobileImageMounterDiskImageRestricted; the underlying error explicitly says Developer Mode is not enabled. No new build was installed.


## iPhone M3.4 check — Installed and launched (2026-10-22)

1. On the Mac, allow Trackglass in System Settings → Privacy & Security → Accessibility and Local Network if not already allowed.
2. In the Trackglass menu-bar menu choose Pair a device…; expect a QR code.
3. On iPhone choose Pair with a Mac… → Scan Mac QR code, allow Camera/Local Network if prompted, and scan it. If already paired, skip scanning.
4. In the iPhone Paired Macs list, tap the Mac. Expect Connected to <Mac> and an updating RTT in milliseconds. Report pass or the exact visible message.

Latest signed M3.4 iPhone app installed and launched successfully. Mac companion opened. This first physical check does not yet cover rotation, Forget, idle timer, or the two-device busy test. iPad remains unavailable and previously needed Developer Mode enabled.


## Mac pairing blocked by Local Network policy (2026-10-22)

1. On the Mac open System Settings → Privacy & Security → Local Network. Enable Trackglass (or TrackglassMac, depending on the displayed app name).
2. Quit Trackglass from its menu and reopen the current build. Open Pair a device… again; expect a QR code. Use a code instead must show six digits.
3. If Trackglass is absent from the Local Network list, or already enabled, report that state before any permission reset or reinstall.

Evidence: the supplied Mac screenshot says “Waiting for Bonjour. Allow Local Network access for Trackglass.” System logs for the same running app show repeated DNS Error: PolicyDenied on its main and pairing listeners, including 11:23:57–11:24:03. No physical pairing or connection pass yet.


## M3.4 — Connection/RTT passed; remaining checks (2026-10-22)

Owner confirmed successful iPhone connection and updating RTT after enabling Mac Local Network access. Pointer movement is expected only after later input/injection steps.

1. Rotate the connected iPhone; keep it connected so the agent can inspect Mac SURFACE logs.
2. On Mac choose Paired devices → <iPhone name> → Forget. Expect Pair again on the phone; retry connecting and expect Pair again again. Then pair again to restore access.
3. With the connected surface visible, leave it untouched for three minutes; it should stay awake. Disconnect and confirm normal auto-lock resumes.
4. The second-device busy test still requires the iPad with Developer Mode enabled; it remains deferred.


- 2026-10-22 M3.4 update: rotation and disconnection confirmed by owner; Mac SURFACE logs verify rotation geometry. Clarify whether disconnection was specifically Mac → Paired devices → iPhone → Forget and whether the subsequent connection attempt showed Pair again. If it was only Disconnect, perform the Forget/reconnect check above.


## M3.4 — Remaining acceptance check: second device busy

Forget/reconnection rejection is now confirmed by the owner; no repeat required.

1. Keep the iPhone connected to Trackglass on the Mac.
2. Reconnect and unlock the iPad. If not done yet, enable Settings → Privacy & Security → Developer Mode and complete its restart/Turn On confirmation. Tell the agent when ready for installation.
3. After installation, pair the iPad with the same Mac and attempt to connect. Expect “<Mac> is being used by <iPhone name>”; the iPhone must remain connected.

This is the remaining explicit M3.4 manual acceptance check. No M3.4 commit until confirmed.

## M5.3 — Pointer tracking-speed response (deferred)

Install/open the Mac Debug build from `~/Library/Developer/Xcode/DerivedData/Trackglass-ezhlhwnemaflqtbjwrtrlmngdpbe/Build/Products/Debug/TrackglassMac.app` and connect the phone. Move the pointer with a repeatable finger motion, change System Settings → Trackpad → Tracking speed, and repeat the same motion. Confirm the pointer travel changes without reconnecting. Report the result when you ask for the manual-check list.

## M5.4 — Pointer calibration (deferred)

The next plan step requires reference-MacBook measurements for C1–C3 at tracking ticks 1, 4, 7, and 10, plus the blind A/B comparison. No calibration result or `OUTPUT_SCALE` adjustment has been recorded. Resume this step when the owner requests the manual-check list; M6.1 remains behind this calibration gate.


- 2026-10-25: Owner explicitly deferred M5.4 pointer calibration and authorized continued feature implementation. Earlier calibration checklist remains pending; it no longer blocks M6.1.


## M6.2 — Update both apps together

When resuming physical testing, install the updated iPhone/iPad app and reopen the updated Mac companion together. The owner-approved SETTINGS payload now includes seven additional scroll/zoom preference bytes (also inside WELCOME). Do not mix older and newer prerelease builds. Existing pairings are retained.


## M6.3 — Resting-thumb behavior decision (2026-10-25)

The pending question asks whether to hold off scroll activation while a stationary finger in the bottom 18 mm remains a resting-thumb candidate. Recommended: approve that protection and let scrolling start once that finger moves. Alternative: retain centroid-only activation and change the previously required thumb expectation. SPEC §§6.5.2–6.5.7 conflict under the existing fixture; implementation is paused at that decision. No device test is requested yet. After fixing and verifying this rule, G-DIR still requires Safari in both natural settings and slow Finder list scrolling.

- 2026-10-25: The owner authorized autonomous feature-by-feature implementation, resolving the resting-thumb decision with the recommended protection. Routine manual acceptance/calibration remains deferred; stop only for crucial decisions or verification. Earlier requests to decide the resting-thumb rule are superseded.


## M6 — Deferred physical acceptance

When device testing resumes, use updated builds on both sides. Verify Safari scrolling with Natural scrolling both on and off, slow one-row Finder scrolling, slow/fast acceleration, momentum coast and touch-to-stop. These are queued acceptance checks, not blockers for continued implementation under the owner's instruction. Never mark calibration or G-DIR passed without those observations.

- M6.5–M6.8 deferred acceptance: confirm inertia coast/touch stop; Preview/Maps/Safari pinch and rotation; simultaneous scroll+pinch; Safari smart zoom and delayed single-tap context menu. C4–C6 calibration remains unmeasured. No action needed while feature implementation continues.

## 2026-10-27 — Deferred system-gesture and haptic acceptance
- Latest phone installation failed with a CoreDevice tunnel timeout. When ready for device checks, unlock/connect the iPhone so the matching app build can be installed. Mac build is available in DerivedData and was opened.
- Deferred G-NC/G-FORCE checks: right-edge swipe opens/closes Notification Center; a stationary hold invokes Look Up without an extra click on lift. Verify Dock shortcuts and navigation behavior. Private force/fluid paths remain unimplemented/unverified; fallbacks are currently used.
- Verify haptic click/secondary/force patterns and disconnect behavior after M8.2 automated tests pass. These checks and calibration remain deferred under the owner's continue instruction.

## 2026-10-27 (afternoon) — Run CI for M8.6a–M10.5 (agent had no Xcode)

This session's shell could not run Xcode, so every change since the morning (Mac Welcome/Settings windows, iPad, Feel, M9 robustness, M10.1 latency stats, M10.5 thermal) is unbuilt. Please run, in the repo root:

1. `xcodegen generate` — the project gained the `TrackglassiOSUITests` target and the `TrackglassiOSSoak` scheme.
2. `Scripts/ci.sh` — package tests, Mac hosted tests (now including `LatencyStatsTests`), iOS simulator tests (now including `ThermalStateTests`), both app builds, `tgreplay verify-dir` (37 fixtures incl. `settings_change_deferred`) and the new `Scripts/invariants.sh` (5 % loss × 20 seeds × every fixture).
3. Paste any compiler error or failing test name back; I will fix them in order. Do not commit anything yet.

Deferred manual checks added this session (run when convenient, after CI is green):
- `docs/QA-Robustness.md` §2: the 17-item SPEC §8 checklist (M9.1/M9.2). Items 9 and 17 are partly automated.
- §3: Network Link Conditioner sessions at 3 % loss and 100 ms spikes (M9.3).
- §4: the 24 h soak via the `TrackglassiOSSoak` scheme (M9.4); record start/end memory in PROGRESS.
- M10.1: with the phone connected, open Settings → Advanced and read "Pipeline p95"; expected ≤ 0.30 ms on the reference Mac. Note the value in PROGRESS.
- M10.5: in Xcode, Debug → Simulate Thermal State → Serious while connected: finger halos disappear, pointer keeps moving; back to Nominal restores them. After disconnecting, the phone auto-locks normally.

## 2026-10-27 (afternoon) — Audit follow-ups that need you

Fixed and ready for CI: see `docs/PROGRESS.md` (decisions, 2026-10-27 audit fixes). Run `xcodegen generate && Scripts/ci.sh` first; the fixes touch the engine, so a changed fixture expectation is possible — paste any `fixture mismatch` output back.

Decisions (SPEC changes, so yours):
1. **PIN pairing security (SPEC §3.4, HIGH).** The PIN path derives the TLS PSK from the 6-digit PIN and uses a pure-PSK cipher suite. Anyone recording the Wi-Fi during one PIN pairing can try all 10⁶ PINs offline, decrypt PAIR_RESPONSE and obtain the phone's long-term key; an active attacker advertising a fake Mac can do the same and then pair with the real Mac within the 120 s window. QR pairing (256-bit secret) is unaffected. Options: (a) carry X25519 ephemeral public keys in PAIR_REQUEST/PAIR_RESPONSE and derive the LTK from the ECDH secret + transcript, so a captured transcript no longer reveals it; (b) require an "Allow <phone> to pair?" click on the Mac in PIN mode before PAIR_RESPONSE; (c) keep PIN as a fallback and document QR as the recommended path. (a)+(b) together is the recommendation; nothing is changed until you decide.
2. **Scroll acceleration keys (SPEC §6.8).** The engine indexes the scroll curve with the pointer tracking speed and normalises with the pointer report rate; macOS uses `HIDTrackpadScrollAcceleration` (the Accessibility "Scrolling speed" slider), `HIDScrollResolution` and `HIDScrollReportRate` (default 67). Have `tgaccel` dump those keys before C4 calibration, then decide whether the engine should read them.
3. **Pointer motion during the resting-thumb settle (SPEC §6.5.3).** Today pointer motion is withheld up to 150 ms while a bottom-edge thumb is being classified (`resting_thumb_ignored` fixture encodes ≈11 mm of lost travel). The spec text says motion is not withheld during settling. If you want real-trackpad feel, approve emitting the non-candidate finger's motion while the thumb classifies; the fixture is then regenerated.
4. **SPEC §2.3 repository layout** no longer matches the tree (e.g. `Mac/Networking` instead of `Mac/Server`/`Preferences`/`Permissions`; iOS screens all under `iOS/Surface`). Approve a doc update or a file move.
5. **LICENSE** is still missing from a public repo (P0.3 "license chosen"). Name the license and I will add the file.
6. **`Config/Shared.xcconfig`** now carries `TG_REPO_URL = https://github.com/simo-hue/TrackGlass` and the raw-GitHub appcast URL per SPEC §1.5; confirm the owner/repo spelling.

Improvements recorded but not done (no decision needed; scheduled after CI is green): streaming `.tgrec` writer (recordings currently buffer in RAM), per-datagram `Data` allocation in `UDPFrameSink`, duplicate frames when UIKit splits one event into began/moved/ended calls, `ConnectionManager.refreshState` single-snapshot refactor, ControlChannel handshake timeout, `tgreplay` `"parametric"` model, `LSRequiresIPhoneOS`/`PrivacyInfo.xcprivacy` for M11.4, VoiceOver label on the surface (M10.4), Kit test gaps (ControlChannel loopback, framer bounds, negotiated cipher suite).
