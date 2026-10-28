# Trackglass — Progress (docs/PROGRESS.md)

Tick a step only when its test passed and the commit is made. Keep notes to one line. Gate outcomes and final tunable values are recorded here **and** in SPEC Appendix A. P0.0 is the owner's row; the agent's first step is P0.1.

## Status

| Step | Done | Notes (gate outcome / tunable value / blocker) |
|---|---|---|
| P0.0 entitlement request filed (owner) | ☐ | date filed: |
| P0.1 scaffold project | ☐ | TG_REPO_URL: https://github.com/simo-hue/TrackGlass (Config/Shared.xcconfig) |
| P0.2 add packages and ci script | ☐ |  |
| P0.3 docs: build instructions | ☐ | license chosen: |
| M1.1 kit: message header | ☑ | Six package tests pass; committed as `kit: message header` (a6f81f2). |
| M1.2 kit: touch frame codec | ☑ | Eleven tests incl. 10 000 fuzz cases; committed as `kit: touch frame codec` (4774038). |
| M1.3 kit: control messages | ☑ | Sixteen package tests; committed as `kit: control messages` (087e849). |
| M1.4 kit: control framer | ☑ | Eighteen package tests; committed as `kit: control framer` (f90b49d). |
| M1.5 kit: pairing crypto | ☑ | 24 package tests pass: QR URL, independent HKDF vector, matching-key TLS exchange and wrong-key TLS rejection; zero warnings. |
| M1.6 kit: surface geometry | ☑ | Reference geometry, rotation/window bounds, PPI fallbacks and marketing names pass; 28 package tests, zero warnings. |
| M1.7 kit: tgrec format | ☑ | 500-frame file round-trips for both origins, malformed headers/records rejected; 31 package tests pass, zero warnings. |
| M2.1 ios: touch surface root | ☐ | Implemented; full CI passed; no auto-lock confirmed. Owner approved §5.4 correction; corrected iOS build passes. Synthetic first swipe still shows system UI; manual edge retest pending. iPhone unavailable (4016); uncommitted. |
| M2.2 ios: touch frames | ☐ | Implemented; seven simulator-hosted tests and signed iPhone build pass. Owner authorized deferred device checks. Ruler/lift-off check pending; uncommitted. |
| M2.3 ios: frame sender | ☐ | Implemented; nine simulator tests and signed build pass. Drop-oldest policy approved. Instruments pending; uncommitted. |
| M2.4 ios: 120hz display link | ☐ | Implemented; signed build passes. Device event-rate measurements deferred; uncommitted. |
| M2.5 ios: liftoff and surface changes | ☐ | Implemented; nine simulator regression tests and signed build pass. Device lift-off/rotation check deferred; uncommitted. |
| M3.1 net: bonjour discovery | ☐ | Implemented; full CI passes (eleven iOS tests; existing AX skip). LAN timing and peer-to-peer manual checks deferred; uncommitted. |
| M3.2 net: pairing store | ☐ | Implemented; AUTO passed in both app hosts, full CI passed. Commit queued behind earlier deferred manual steps. |
| M3.3a net: pairing via qr | ☐ | Implemented; full CI and final Mac regression pass; QR decode/exchange/replay/concurrent-use/close tests pass. Camera/manual checks deferred. Mac Bonjour currently PolicyDenied. |
| M3.3b net: pairing via pin | ☐ | Implemented; full CI passes; PIN exchange/rotation/three-generation limit/expiry and URL routing tests pass. Physical PIN and Camera handoff deferred; uncommitted. |
| M3.4 net: control session | ☐ | WELCOME correction approved/tested/committed (7ea5694). G-TLS: both two-key TLS/DTLS echo tests pass on macOS 27.0.1; macOS 14 check deferred by owner (2026-10-22); multi-key branch selected. Control session implemented; full CI passes (21 Mac tests, one existing AX skip; 17 iOS); final four session tests pass. iPhone installed; owner confirmed connection and updating RTT after allowing Local Network. Owner confirmed disconnection/rotation; Mac SURFACE logs verify swapped dimensions. Owner confirmed Forget/reconnect rejection. Second-device busy acceptance check remains pending; connected idle behavior unverified; uncommitted. |
| M3.5 net: input channel | ☐ | Implemented with a DTLS listener restricted to the admitted phone's LTK; iOS/Mac builds pass. Physical frame-rate/raw-UDP checks deferred. |
| M3.6 net: reconnect and lifecycle | ☐ | Implemented actor-owned browser/session, foreground exponential reconnect, background BYE, Mac sleep/wake listener restart and three-missed-PING timeout. Both app builds pass; physical lifecycle checks deferred. |
| M3.7 net: security tests | ☐ | All 23 Mac hosted tests pass, including wrong-PSK, raw-UDP, pairing replay and PIN attempt coverage. Wireshark capture deferred. |
| M4.1a mac: accessibility gating | ☐ | Implemented and Mac build passes; owner deferred the manual revoked/granted check to next iteration. |
| M4.1b mac: pointer moves | ☐ | Implemented; Mac hosted suite passes (25 tests), including frame ordering/backwards time and estimated-time ticks. Phone pointer and physical mouse check deferred to next iteration. |
| M4.2 mac: pointer bounds and wake | ☐ | Implemented per-display edge sliding and display reconfiguration refresh; pointer input after ≥10 s idle declares user activity. Mac build passes; external-display/display-wake manual checks deferred. |
| M4.3 engine: contact rules | ☐ | Contact tracker, palm rejection, resting-thumb detection/release, settle-window scroll mode, and event JSON/fixture harness implemented. Three engine tests and all required fixtures pass with zero package warnings; Mac build passes. Resting-thumb manual check deferred. |
| M4.4 mac: trackpad preferences | ☐ | Preference parser, two-second poller, Bluetooth-domain selection, idle-deferred engine settings and live SETTINGS sends implemented. Mac hosted suite passes (27 tests); built-in/Bluetooth fixture parsing passes. Manual key/mapping check pending: 1 = , 2 =  |
| M4.5 engine: taps and clicks | ☐ | Single-finger click, two-finger secondary click, configured corner secondary clicks, Quartz button events and the one-time iPhone tap-to-click notice implemented. Four fixture triplets pass in EngineTests; iOS app build succeeds. Phone/Mac interaction checks deferred. |
| M4.6 engine: drag | ☐ | Click counts, Dragging-dependent tap-and-a-half, drag pointer movement, 300 ms release grace, drag-lock engagement/release haptics, and grace timer implemented. Five fixture triplets pass in EngineTests; Mac hosted suite passes (27 tests). Finder interactions deferred. |
| M4.7 engine: three finger drag and lookup | ☐ | Three-finger drag threshold, centroid motion, release/drag-lock behavior, three-finger Look Up recognition and Ctrl+Cmd+D injection implemented. Both required EngineTests fixture triplets pass; Mac hosted suite passes (27 tests). Manual app checks deferred. |
| M4.8 engine: liftoff safety | ☐ | Implemented synthetic/heartbeat lift-off lock preservation, 1.5 s no-input timeout with forced button release, BYE stop release, vanished-contact ending and active contact-ID reuse. Required EngineTests fixtures pass; Mac hosted suite passes (29 tests), including heartbeat release and timeout release tests. Phone termination/loss-conditioning checks deferred. |
| M4.9 tools: tgreplay | ☐ | ReplayRecorder, Record session menu item, `tgreplay run`, `verify-dir`, seeded `invariants`, and CI fixture verification implemented. Full `Scripts/ci.sh` passed; tgreplay verifies 18 triplets. Real phone tap-drag recording/snapshot fixture and 20 s Instruments allocation check remain deferred. |
| M5.1 tools: tgaccel and default curves | ☑ | Gate G-ACC: the reference Mac exposes 10 `HIDAccelCurves` entries and `HIDPointerAccelerationTable` (771 bytes); select parametric curves for M5.2 and retain both in `DefaultAccelCurves.json`. Pointer resolution 26,214,400; report rate 120. `tgaccel` exits 0 and its JSON parses with all required properties. |
| M5.2 engine: acceleration curve | ☐ | Apple parametric curve selection/interpolation and tangent evaluation implemented. Debug EngineTests pass (performance check skipped because debug code is unoptimized); release EngineTests pass all 7 tests, with multiplier ≤50 ns. Commit deferred because M5.2 depends on M4.1b code still awaiting its authorized manual acceptance. |
| M5.3 engine: pointer acceleration | ☐ | Implemented rate normalization, mm-to-count conversion, clamped tracking-speed selection, live registry preference and bundled/emergency fallbacks. EngineTests pass in debug (10 tests, one optimized-only performance test skipped) and release (10 tests); Mac Debug build and all 29 hosted tests pass. Manual tracking-speed slider check is deferred; step remains uncommitted. |
| M5.4 calibrate pointer | ☐ | Owner explicitly deferred calibration on 2026-10-25 and authorized continued feature implementation. OUTPUT_SCALE remains 1.0; C1–C3/A-B results pending. |
| M6.1 mac: private fields | ☑ | Five private API tests and all 34 Mac hosted tests pass. HIDEvent resolves; both attachment symbols absent, dockSwipe=false; gestureEvents=true. Commit: mac: private fields. |
| M6.2 mac: scroll preferences | ☐ | Implemented with owner-approved SETTINGS/WELCOME extension. 33 Kit, 10 Engine (one optimized-only skip), 36 Mac and 17 iOS tests pass. Commit deferred with earlier engine/preference dependencies. |
| M6.3 scroll | ☐ | Implemented with resting-thumb protection under owner-authorized discretion. All engine fixtures and 38 Mac tests pass. G-DIR physical check deferred; uncommitted with earlier dependencies. |
| M6.4 scroll acceleration | ☐ | G-SCR selects Apple scroll curves (present in reference archive). Independent-axis history/parametric model implemented; 15 engine tests and Mac hosted regression pass. Physical feel deferred; uncommitted. |
| M6.5 scroll momentum | ☐ | Implemented; decay/touch-cancellation fixtures and synthetic-liftoff/disabled-inertia tests pass. Physical feel deferred; uncommitted. |
| M6.6 pinch and rotate | ☐ | Implemented; three required fixtures, concurrent/cancellation tests and Mac field assertions pass. Physical app checks deferred; uncommitted. |
| M6.7 smart zoom | ☐ | Implemented; smart zoom/delayed secondary fixtures and disconnect tests pass. 23 engine tests (one optimized-only skip), Mac hosted tests pass. Physical checks deferred; uncommitted. |
| M6.8 calibrate scroll | ☐ | Deferred under owner instruction to continue code/features and queue routine physical calibration. Initial constants unchanged. |
| M7.1 mac: gesture preferences | ☐ | Implemented; package/hosted tests pass; physical acceptance deferred. |
| M7.2 engine: multi-finger swipes | ☐ | Implemented; 25 engine tests, one optimized-only skip; eight new fixtures pass. |
| M7.3 mac: dock swipes | ☐ | Implemented; legacy fields/reposts tested. MMF cut line: macOS 27.0; symbol name: CGEventSetHIDEvent (MMF-local wrapper); physical verification deferred. Tested on macOS:  |
| M7.4 mac: dock swipes hid event | ☐ | Conditional construction and missing-attachment tests pass. Current reference uses a local wrapper; OS symbol absent, shortcut fallback selected. Physical acceptance pending. |
| M7.5 mac: navigation swipe | ☐ | Implemented; began/ended direction fields tested. Safari acceptance pending. |
| M7.6 mac: notification center | ☐ | Gate G-NC pending: AX Clock fallback implemented; private fluid path not implemented/verified. |
| M7.7 mac: force click | ☐ | Gate G-FORCE pending: hold recognizer, fixture and keyboard fallback implemented; private force path not implemented/verified. |
| M7.8 mac: gesture fallbacks | ☐ | Implemented keyboard fallbacks and reduced-mode menu; forced missing-capability tests pass. Physical acceptance pending. |
| M7.9 calibrate gestures | ☐ | final values:  |
| M8.1 mac: preferences verified | ☐ | keys corrected:  |
| M8.2 haptics | ☐ |  |
| M8.3a ios: themes | ☐ |  |
| M8.3b ios: settings sheet | ☐ |  |
| M8.4 ios: hud | ☐ |  |
| M8.5 ios: onboarding | ☐ |  |
| M8.6a mac: welcome window | ☐ | Implemented: first-launch Welcome with Accessibility polling, System Settings link, SMAppService login toggle (default on). Shown again on revocation. Manual first-launch/reboot checks deferred; uncommitted. |
| M8.6b mac: settings window | ☐ | Implemented: General/Devices/Advanced/About tabs, §6.1 menu, single-instance guard. Manual tab/forget/second-copy checks deferred; uncommitted. |
| M8.7 ios: ipad | ☐ | Implemented: all iPad orientations, SURFACE re-sent on every bounds change (Stage Manager/Split View), iPad-only onboarding page; Pencil ignored since M2.2. iPad manual checks deferred (Developer Mode required); uncommitted. |
| M8.8 ios: feel settings | ☐ | Implemented: tracking override slider (−1…+1) persisted and sent in HELLO/SURFACE, Mac clamps trackingSpeed+override; haptics toggle/strength bound to M8.2 defaults. Manual slider check deferred; uncommitted. |
| M9.1 robustness: mac lifecycle | ☐ | §8 items 2–6 implemented (wake assertion before event, user-session inactive → busy, display reconfiguration callback, 5 s AX polling → BYE + Welcome, `Scripts/assert-signing-team.sh`); checklist of all 17 items added to `docs/QA-Robustness.md` §2. Manual checklist deferred; uncommitted. |
| M9.2 robustness: phone and engine | ☐ | Items 8, 10–15, 17 implemented; fixture `settings_change_deferred` added to EngineTests and tgreplay (settingsChanges supported). Item 7 covered by `rotation_cancels_gesture`, item 9 by `InputPipelineTests`. Manual items deferred; CI run pending (2026-10-27 session had no Xcode access). |
| M9.3 robustness: loss handling | ☐ | `Scripts/invariants.sh` (tgreplay invariants, drop 0.05, seeds 1–20, all fixtures) added and run by `Scripts/ci.sh`; procedure in `docs/QA-Robustness.md` §3. Automated run and Link Conditioner sessions pending on the owner's Mac. |
| M9.4 robustness: soak | ☐ | memory start/end:  — `TrackglassiOSUITests` target + `TrackglassiOSSoak` scheme (`SoakUITests`, `TG_SOAK_SECONDS`) added; procedure in `docs/QA-Robustness.md` §4. 24 h run not started. |
| M10.1 mac: latency stats | ☐ | p95:  — `LatencyStats` (1 000-sample ring + 4 096-bucket histogram, allocation-free) records receive→post per frame; p50/p95 in STATUS and Settings → Advanced; `LatencyStatsTests` added. Owner p95 reading pending. |
| M10.2 docs: latency | ☐ | instrumented median/p95 at 120 Hz: ; at 60 Hz: ; camera delta vs trackpad:  |
| M10.3 ios: coalesced samples | ☐ | kept enabled: yes / no, because:  |
| M10.4 polish: accessibility and icons | ☐ | Implemented: iOS/Mac AppIcon sets and 18 pt MenuBarIcon template generated from `Design/Brand/trackglass-logo-v1.png` by `Scripts/make-icons.py`; VoiceOver labels/traits (surface = direct-interaction element, PIN selection, camera view, grip, menu bar icon), Dynamic Type in the scanner and scrolling onboarding pages, Local-Network denial surfaced in the Macs list. `AccessibilityTests`, `MenuBarIconTests` added. VoiceOver end-to-end and iPhone SE largest-size checks deferred. |
| M10.5 ios: thermal and power | ☐ | Thermal `.serious`/`.critical` suppresses halos (frames unaffected); Low Power unchanged; idle timer already restored on disconnect. `ThermalStateTests` added. Xcode thermal simulation check pending. |
| M11.1 mac: sparkle updates | ☐ |  |
| M11.2 mac: release script | ☐ | `Scripts/release-mac.sh` written per §6.11 (archive → Developer ID export with per-run ExportOptions → DMG → notarytool → stapler → gh release → generate_appcast → appcast commit; guards for dirty tree, existing tag, version mismatch, signing team; `--dry-run`). `Releases/release-notes/0.9.0.md` drafted. Not run: needs the owner's Developer ID cert, notarytool profile, Sparkle keys, `gh auth`. |
| M11.3 website and readme | ☐ | site URL: https://simo-hue.github.io/TrackGlass — README rewritten, `docs/Install.md` added, `OWNER/trackglass` → `simo-hue/TrackGlass` in `website/`. Still placeholders: `APPSTORE_URL` (until the App Store page exists) and `SUPPORT_EMAIL` (owner). Pages workflow needs enabling by the owner. |
| M11.4 appstore: assets and metadata | ☐ | `iOS/Resources/PrivacyInfo.xcprivacy` (Data Not Collected; UserDefaults CA92.1, SystemBootTime 35F9.1) bundled; `ITSAppUsesNonExemptEncryption = NO` and `LSRequiresIPhoneOS` in place; 1024 px icon from M10.4. Screenshots, privacy-label answers and review notes remain (owner, App Store Connect). |
| M11.5 testflight: beta fixes | ☐ | blockers found/fixed:  |
| M11.6 release 1.0.0 | ☐ | approval date:  |
| D1 driver: skeleton | ☐ |  |
| D2 driver: descriptor and feature reports | ☐ |  |
| D3 driver: input reports | ☐ | G-DRV-1..5:  |
| D4 driver: injector | ☐ | entitlement granted on:  |
| D5 driver: activation | ☐ |  |

## Blockers

- 2026-10-27 (audit): five read-only audits (Kit, Engine, Mac, iOS, tooling) found 1 HIGH design issue needing an owner decision — SPEC §3.4 PIN pairing derives the TLS PSK from a 6-digit PIN with a pure-PSK suite, so a passive Wi-Fi capture of one PIN pairing can be brute-forced offline to recover the LTK (QR pairing is unaffected). Options are listed in `TO_SIMO_DO.md`; until decided, QR is the recommended pairing path. Code fixes from the audit are applied but, like everything since 2026-10-27 morning, uncompiled.

- 2026-10-27 15:08: owner ran `xcodegen generate && Scripts/ci.sh` on the reference Mac after the audit fixes — full CI passed (package tests incl. `DragSafetyTests`, Mac and iOS hosted tests, both app builds, 37 fixtures, loss invariants). Work through M10.5 is committed as 5c1057f. AUTO parts of M8.6a–M10.5 are verified; their MANUAL parts remain deferred under the owner's policy and are listed in `TO_SIMO_DO.md`.
- No other implementation blocker. Owner authorized routine implementation decisions and deferred non-crucial physical checks on 2026-10-25. Resting-thumb protection is implemented and all existing fixtures pass. Other prior deferrals remain valid. Owner approved deferring macOS 14 G-TLS validation on 2026-10-22; it remains required before release. Earlier phone/iPad manual tests are also deferred.

## Decisions taken during implementation

(record here anything the owner approved that is not already in SPEC, with the date)

- 2026-10-22: Owner approved adding `activePhoneName str` after SETTINGS in WELCOME (§4.5), empty unless busy; codec and 32 package tests pass.

- 2026-10-22: Owner approved continuing M3.4 using multi-key listeners after passing TLS/DTLS tests on macOS 27.0.1; macOS 14 compatibility validation deferred until before release.

- 2026-10-25: Owner explicitly deferred M5.4 calibration and authorized continued code/features. Approved appending seven Boolean scroll/zoom preferences to SETTINGS and WELCOME.settings; both prerelease apps must be updated together.

- 2026-10-27 (audit fixes, pending CI): engine drag safety (`endDragContact` for `.cancelled`/vanished/re-used IDs, three-finger re-land, sub-0.05 mm accumulation, two-finger arming after a thumb un-rests or a multi-finger set drops to two, taps beside a resting thumb/palm); Mac injector posts `leftMouseDragged`/`rightMouseDragged` while a button is held and declares user activity for every input kind; same-phone reconnect supersedes its stale session; input listener keeps the admitted key and port across pairing-set changes (only the TLS listener restarts); no `IOHIDManagerOpen` (Input Monitoring); navigation swipe sets field 55; Welcome no longer gated on login-item approval; phone sends a `.stationary` keep-alive frame every 0.5 s while a finger holds still (the Mac's 1.5 s lift-off timeout no longer fires on a held finger); DTLS input-path failure ends the session for the reconnect loop; last used Mac persisted and auto-resumed (`.noMac` overlay text); haptic engine no longer restarts on idle shutdown; colour picker clamps extended-sRGB; fixture comparison uses the §10.1 1e-6 tolerance and schedules ticks on `frameTime`; `settings_change_deferred` fixture disables momentum; TCP `noDelay` on the control channel; heartbeat timeout is three 1 s misses; NaN/non-positive geometry rejected on decode; xcconfig gains `TG_REPO_URL` and the raw-GitHub appcast URL.

- 2026-10-27 (backlog batch; full CI passed 2026-10-28 09:27, zero warnings): streaming `TGRecFileWriter` replaces in-memory recording on both platforms; `ControlChannel` handshake watchdog (10 s, configurable) with Kit loopback tests; one suspended/resumed `DispatchSourceTimer` per `InputPipeline`; `GestureEngine.diagnosticState` (0 idle … 4 drag) in STATUS and a §6.3 3 s idle reset; degraded-gesture list reports the force-click and Notification Center fallbacks the injector really uses; Mac recording button follows the pipeline's state; Mac log categories `net`/`engine`/`inject`/`prefs` per §6.10; `MessageHeader.sequence(_:isNewerThan:)`/`gap(from:to:)`; `tgreplay` `"parametric"` model; scroll-axis history interval counts idle frames; phone suppresses the duplicate frame UIKit's began/moved split produces; `SessionClient.snapshot()` + `ConnectionState.apply` ordering guard. UDP send keeps one `Data` copy at the Network.framework boundary (documented).
