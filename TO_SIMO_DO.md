# TO_SIMO_DO — manual actions still open (2026-10-29, updated after round 2)

Everything the agent can do without you is done; the two 2026-10-28 batches passed CI and are committed (section 0). This file lists only what needs your hands, your devices or your decision. Reply with results in the order you like; nothing here blocks the others. History of earlier requests is in git (`git log -p TO_SIMO_DO.md`).

## 000. Round 2 of 2026-10-29 — CI green 13:39, committed

1. ~~Run CI~~ — done (all green).
2. **Disconnect on the Mac:** menu → Paired devices → <phone> → Disconnect (also in Settings → Devices). The phone shows "<Mac> disconnected this device. Tap Reconnect to use it again." and does not reconnect by itself; Reconnect works. Forget now asks for confirmation.
3. **Scroll speed (G-SCR):** the constant fallback model now ships by default, because the Apple scroll-curve port scrolled 3–23 × too far. During C4 compare once with `defaults write app.trackglass.mac TGUseAppleScrollCurves -bool YES` (quit/reopen), then `defaults delete app.trackglass.mac TGUseAppleScrollCurves`; send me the `tgaccel` JSON so I can fix the curve units.
4. **Feel changes to check with the phone:** a tap never nudges the pointer (0.5 mm touch-down hysteresis); fingers that stop before lifting do not coast; a pinch started during a scroll still zooms, a long scroll never zooms by itself; lifting one of two fingers after a scroll/zoom does not move the pointer; resting a thumb at the bottom never force-clicks; a second finger landing late and moving with the first scrolls; with Tap to click off, tap-and-a-half drags.
5. **Instruments (SPEC §7):** Allocations on the Mac app while scrolling and pointing for 30 s — use "Created & Destroyed": the `input-pipeline` queue should allocate nothing per frame beyond the CGEvents themselves (`PipelineAllocationTests` only catches memory that is kept); on the phone, Allocations while dragging one finger should show only the one `Data` copy per datagram (B11).
6. The website, README and App Store text no longer promise "works with no router" (peer-to-peer). Try it once (both devices off Wi-Fi networks, Wi-Fi still on, Bluetooth on); if it connects, tell me and I restore the line.
7. The 24 h soak now takes `TG_SOAK_EXPECT_CONNECTED=1` (`docs/QA-Robustness.md` §4) and fails if the phone drops the session.

## 00. Review fixes of 2026-10-29

1. The Mac app is now built as **Trackglass for Mac.app** (SPEC §1.5). Delete the old `TrackglassMac.app` from Applications and Login Items if you installed one; macOS may ask for Accessibility again for the new bundle.
2. TestFlight (M11.5) rejects a second upload with the same build number: archive the iOS app with `CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD)` (or raise it in Xcode). The Mac release script now does this by itself.
3. During D3, the Spaces / Mission Control keyboard fallback now sends Control+Fn like a real keyboard; tell me if a four-finger swipe still does nothing on macOS 27.

## 0. The two 2026-10-28 batches — CI green at 17:30, committed

1. **Update both apps together before pairing anything new:** the pairing messages changed (X25519 keys + Allow click). Existing pairings keep working.
2. Optional tidy-ups: delete the `TG_SPARKLE_PUBLIC_KEY` line from your `Config/Local.xcconfig` (the tracked `Shared.xcconfig` has it; the release script stops if the two differ); re-run `Scripts/make-icons.py` so the DMG caption reads "Drag Trackglass for Mac to Applications". (`output.txt` is now untracked and ignored.)
3. Quick physical checks (when you next have the phone): pair once and click **Allow** on the Mac; pair again and click **Don't Allow** (the phone says pairing was not allowed); a four-finger pinch with the thumb held still opens Launchpad / Apps; after a three-finger Spaces swipe, lifting the fingers one at a time does not scroll or move the pointer.
4. ~~Soak UI test main-actor warnings~~ — fixed in round 2.

## A2. Legacy dock-swipe trial on macOS 27 — two minutes

1. `defaults write app.trackglass.mac TGTryLegacyDockSwipes -bool YES`, quit and reopen the Mac app. "Reduced gesture mode" lists "…legacy dock-swipe trial (macOS 27)".
2. Three-finger swipe slowly left/right: does the Space follow your fingers live (or switch at all)? Four-finger swipe up: Mission Control?
3. `defaults delete app.trackglass.mac TGTryLegacyDockSwipes`. Reply "live", "switches but not live" or "nothing" — I make it the default on macOS 27 if it works.

## A. Gate G-NC — two minutes, waiting on you

1. `defaults write app.trackglass.mac TGTryPrivateNotificationCenter -bool YES`, then quit and reopen the Mac app. Its menu → "Reduced gesture mode" must list "Notification Center: private gesture trial (G-NC)".
2. Phone connected: two-finger swipe in from the phone's right edge. Does Notification Center open? (`log stream --predicate 'subsystem == "app.trackglass.mac" AND category == "inject"'` shows `private fluid gesture trial (G-NC), attached=false`.)
3. `defaults delete app.trackglass.mac TGTryPrivateNotificationCenter`, reopen the app, confirm the swipe opens it again via the Accessibility fallback.
4. Reply "opened" or "nothing happened". I record the outcome (PROGRESS M7.6, SPEC Appendix A) and commit `mac: notification center`.

G-FORCE (M7.7) cannot run on this Mac: the private force path needs `CGEventSetHIDEvent`, which is absent here (M6.1). If the macOS 14 QA Mac resolves it (`PrivateAPITests` prints `attachmentSymbol`), set `TGTryPrivateForceClick -bool YES` there and hold one finger still ≥ 0.6 s over a word in TextEdit (Look Up?) and over a file in Finder (Quick Look?). Otherwise the recorded outcome is "keyboard fallback shipped; private path unreachable".

## B. Decisions (SPEC or legal — yours)

1. ~~PIN pairing security~~ — done 2026-10-28 (X25519 + Allow click).
2. ~~LICENSE~~ — Apache-2.0, added 2026-10-28.
3. **SPEC §2.3 layout** no longer matches the tree (`Mac/Networking` instead of `Mac/Server`/`Preferences`/`Permissions`; iOS screens under `iOS/Surface`). Approve a doc update or a file move.
4. Optional, affects feel: (i) let pointer motion continue while a bottom-edge thumb is being classified (SPEC §6.5.3; fixture `resting_thumb_ignored` is then regenerated); (ii) whether the engine should read `HIDTrackpadScrollAcceleration`/`HIDScrollResolution`/`HIDScrollReportRate` for scroll acceleration (SPEC §6.8) — decide after `tgaccel` dumps them during C4.

5. ~~4/5-finger pinch arbitration~~ — done 2026-10-28 (bigger change wins).
6. ~~Staggered lift-off~~ — done 2026-10-28 (hold mode until the last finger).
7. ~~Dock fallback threshold~~ — done 2026-10-28 (0.5).
8. ~~macOS 27 legacy dock trial~~ — wired 2026-10-28; run it (section A2).
9. **`releases/latest` vs the 0.9.0 pre-release.** GitHub's `/releases/latest` never resolves to a pre-release, but PLAN M11.2 publishes 0.9.0 as one and M11.3/APPSTORE.md send the reviewer to `releases/latest`. Either publish 0.9.0 as a normal release, or accept that the download links work from 1.0.0 (then the M11.3 test text changes).
10. ~~Sparkle public key placement~~ — done 2026-10-28 (Shared.xcconfig).
11. **Small spec clarifications to ratify or revert** (each is one line of code or spec): the per-frame `Data` copy at `NWConnection.send` (public API needs an owned `Data`; §7 says zero allocations — record as an accepted deviation in Appendix A, or I try `DispatchData`-backed sends); `tcp.noDelay` on the control channel (§3.3 lists plain `NWParameters(tls:)`); SURFACE carries four fields (§4.5 wording "same geometry fields as HELLO"); the §5.3 "iPad mini 326" fallback cannot be derived from an unknown identifier (table-based only); the scroll-acceleration curve index follows the pointer tracking speed (macOS's scroll gain does not — affects C4); the Diagnostics "Coalesced touch samples" toggle is user-visible (§5.1 does not list it — keep as a debug switch until M10.3 decides, or hide it).

## C. Release plumbing (before any public build)

1. `APPSTORE_URL` → the full `https://apps.apple.com/…` link in the two `data-appstore` attributes of `website/index.html` once the App Store page exists (until then the buttons show "App Store · soon" and link to `support.html#get-the-app`; support e-mail is set).
2. Sparkle: back up the private key (`generate_keys -x <file>` → password manager, delete the file); put the Sparkle 2 tools (`generate_appcast`) on your PATH.
3. `xcrun notarytool store-credentials trackglass-notary` (App Store Connect API key or app-specific password); Developer ID Application certificate installed; `gh auth login`.
4. GitHub → Settings → Pages → Source: GitHub Actions (`.github/workflows/pages.yml` exists). The CI workflow runs on the next push to `main` by itself.
5. First release exercise: set `MARKETING_VERSION = 0.9.0` in `Config/Shared.xcconfig`, commit, run `Scripts/release-mac.sh 0.9.0 --pre-release --dry-run` (refuses a dirty tree). Then the M11.1 manual test: 0.9.0 → 1.0.0 through a local appcast.
6. App Store Connect (M11.4): screenshots, privacy-label answers (Data Not Collected), review notes with the release page URL.

## D. Device checks (when you have the phone/iPad; nothing blocks development)

Use matching builds on both sides (the SETTINGS payload changed in M6.2). Mac log categories are `net`, `engine`, `inject`, `prefs`.

1. **Pointer/clicks/drags (M4.x):** pointer follows one finger smoothly; tap = left click; two-finger tap = context menu; configured corner tap = secondary; double-tap opens a file; tap-and-a-half drags a window and releases ≈0.3 s after lift (Drag Lock: stays held until a tap); three-finger drag with the setting on; three-finger tap on a word = Look Up; Tap-to-click off on the Mac shows the one-time phone notice; force-quitting the phone during a drag releases the button within 2 s.
2. **Scroll/zoom (M6.x, gate G-DIR):** Safari scrolls correctly with Natural scrolling on and off (no double inversion); slow one-row Finder list scroll; momentum coasts and stops on touch; pinch/rotate in Preview/Maps; Safari smart zoom; single secondary tap still works with smart zoom on.
3. **System gestures (M7.x):** Spaces/Mission Control/App Exposé/Show Desktop via four-finger swipes (shortcut fallback on this Mac); Safari back/forward swipe; with "Reduced gesture mode" shown, list matches what happens.
4. **Haptics (M8.2):** every click vibrates; secondary and force feel different; disconnecting stops the engine without console errors.
5. **iOS UI (M8.3–M8.8, M10.4):** theme switch instant, halos follow fingers; grip opens Settings and never moves the pointer; Record session produces a `.tgrec` that `tgreplay run` replays; status pill shows Mac name + latency then hides; latency overlay updates once per second; fresh install → onboarding → pairing; forget and re-pair; no Mac in range shows the overlay with other paired Macs; tracking-override slider changes speed within a second (0 = Mac setting); VoiceOver-only pairing works; largest Dynamic Type on an iPhone SE does not clip.
6. **iPad (M8.7, needs Developer Mode):** all orientations; Stage Manager/Split View resize updates mm dimensions; Apple Pencil does nothing; with iPadOS gestures disabled, four-finger swipes reach the Mac; second-device busy message "<Mac> is being used by <iPhone>".
7. **Mac windows (M8.6):** first launch shows Welcome, granting Accessibility flips the status live, auto-start after reboot; every Settings tab renders; forgetting a phone disconnects it; a second app copy activates the first.
8. **Robustness (M9):** the 17-item checklist in `docs/QA-Robustness.md` §2; Link Conditioner at 3 % loss and 100 ms spikes (§3); the 24 h soak with the `TrackglassiOSSoak` scheme (§4) — note start/end memory.
9. **Numbers to write into PROGRESS:** Settings → Advanced "Pipeline p95" (expect ≤ 0.30 ms, M10.1); M10.2 end-to-end latency at 120 Hz and 60 Hz plus the camera-vs-trackpad delta; M10.5 Xcode thermal simulation (Serious → halos vanish, pointer keeps moving).
10. **M10.3 on the iPad:** Settings → Diagnostics → Record session, slow circles for 20 s, share the `.tgrec`; repeat with "Coalesced touch samples" on; send me the two `tgreplay velocity-stats off.tgrec on.tgrec` lines.
11. **Calibrations (M5.4, M6.8, M7.9):** C1–C3 pointer at tracking ticks 1, 4, 7, 10 plus the blind A/B; C4–C6 scroll; C7–C8 gestures — all per SPEC §10.3 against the built-in trackpad. Final values go to PROGRESS and SPEC Appendix A.
12. **Wireshark (M3.7):** `docs/QA-Robustness.md` §1 — control and input ports show only TLS/DTLS records.

## E. Before release / Phase 2

1. macOS 14 QA Mac: run `TrackglassMacTests/TLSGateTests` (`testTwoRegisteredKeysTLS`, `testTwoRegisteredKeysDTLS`) — the deferred G-TLS gate.
2. TestFlight week with 10 external testers (M11.5), then `release-mac.sh 1.0.0` and App Store submission (M11.6).
3. Phase 2: Apple's answer to the DriverKit entitlement request (P0.0) and a dedicated SIP-disabled test Mac (never the development Mac). `docs/Phase2-Spike.md` holds the G-DRV gate table.
