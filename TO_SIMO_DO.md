# TO_SIMO_DO — manual actions still open (2026-10-31, updated after round 4)

Everything the agent can do without you is done; the two 2026-10-28 batches passed CI and are committed (section 0). This file lists only what needs your hands, your devices or your decision. Reply with results in the order you like; nothing here blocks the others. History of earlier requests is in git (`git log -p TO_SIMO_DO.md`).

## 00000. Round 4 of 2026-10-31 — review fixes, CI green, committed

Every finding of the round-4 review is fixed except those in item 5. CI passed on 2026-10-31 (Kit 67, Engine 115, Mac 146 and iOS 83 tests; 39 fixtures verified; invariants held for 780 replays) and the fixes are committed. Details: `docs/PROGRESS.md` (Decisions, 2026-10-31) and the dated SPEC amendments.

1. ~~Run CI~~ — done (green).
2. **Update both apps together before pairing anything new: the PIN is replaced by code comparison (both screens show 6 digits).** A new Mac still pairs an old phone by QR.
3. **Don't install an older build over this one on the phone: the phone's identity moved to the Keychain; if you do, re-pair.**
4. **Device checks** (when you have the devices; one line each):
   - **Mac — gestures, with the phone:**
     1. Force click: rest a finger still ~1 s on a Safari link — the page must not navigate (Look Up or nothing); over a word in TextEdit — Look Up, nothing selected or clicked.
     2. Dragging on: tap, then tap-and-hold on a Finder icon — it is picked up ~0.1 s after the second touch (tell me if that feels late); tap, then tap-and-drag text — the selection starts where the second touch landed, no jump.
     3. Dragging on, TextEdit: tap a word, then quickly two-finger scroll — nothing gets selected; with Drag Lock on, no click is needed afterwards to free the button.
     4. Three-finger drag + Drag Lock on: drag a window with three fingers, quickly add a fourth and swipe for Spaces — the window drops at once, the Space switches, no drag-lock haptic.
     5. Landscape iPhone held with a thumb still on the bottom edge: a three-finger swipe switches Spaces, and a tap with the index finger beside the thumb clicks.
     6. Two-finger scroll with a thumb resting at the bottom that drifts ~5 mm mid-scroll — the scroll continues and coasts; afterwards the thumb alone moves the pointer.
     7. Two-finger tap with one finger near the bottom edge (landscape iPhone) — a secondary click, not a left click.
     8. Rotate the phone while two-finger scrolling — the scroll ends cleanly with no jump, no corner right-click or Notification Center swipe; fingers held through the rotation do nothing until lifted; a new touch works.
     9. Smart zoom on: a slow two-finger double-tap (second tap held ~0.15 s) zooms, with no context menu.
     10. Drag Lock on: lock a drag, then two-finger tap — the lock releases with its haptic, then the context menu opens.
   - **Mac — app:**
     1. Accessibility Inspector: the menu-bar clock's `AXIdentifier` is `com.apple.menuextra.clock` on macOS 14 and on the reference Mac (report it if not); then switch the system language to German or Italian, log out and in — the phone's two-finger swipe from the right edge opens Notification Center.
     2. Tap-and-a-half drag a window, keep the finger down, close the lid; after wake the physical trackpad does not drag the window.
     3. No phone connected: change System Settings → Trackpad → Tracking speed, open Trackglass Settings → General — "Mac tracking speed" shows it within ~1 s (reopen the window if it was open).
     4. Phone A connected, phone B paired but away: Forget B on the Mac — A disconnects briefly and reconnects by itself within ~2 s, no "Pair again".
     5. Settings → About → Acknowledgements… — the full text scrolls and is selectable; Done closes it.
     6. Record session, flick-scroll, lift, stop recording (once more ending with a phone disconnect instead) — `tgreplay run <x>.tgrec --settings <x>.settings.json` includes `scrollMomentum` events.
     7. Optional, test user account only (it re-pairs every phone): `defaults write app.trackglass.mac peerIDHardware -string x`, relaunch — phones see it as a new Mac.
   - **Phone:**
     1. Input path blocked: read the UDP port from the Mac's `net` log (`input listener ready udpPort=<port>`), `echo "block drop in proto udp to any port <port>" | sudo pfctl -ef -`, Disconnect then Reconnect on the phone — "Connected" at most 3 times with growing gaps, then "Touches couldn't reach <Mac>…" with Reconnect; `sudo pfctl -F all -d` (if you use pf, reload your rules with `sudo pfctl -f /etc/pf.conf`), tap Reconnect — touches work.
     2. Decoy record: get the Mac's `id` with `dns-sd -L "<Mac name>" _trackglass._tcp`; from another Mac run `dns-sd -R " <Mac name>" _trackglass._tcp local 9 v=1 id=<id> nm=<Mac name> pr=0` — the phone still reaches the real Mac (Reconnect, relaunch, Mac sleep/wake), never offers "Pair again", and Settings → Mac → Connect works.
     3. Install this build over the previous paired one — it reconnects without re-pairing, and Console (subsystem `app.trackglass`, category `identity`) shows no "not in the Keychain" error.
     4. Optional: restore an encrypted backup of this phone onto a second iPhone/iPad — it is not connected as the first one and needs its own pairing.
     5. Optional, two Macs with the same computer name both running Trackglass for Mac: touches work on each.
     6. iPhone SE at the largest accessibility text size: onboarding page 2 scrolls to the Download link, the URL and "Copy download link", nothing clipped (D.5).
     7. Settings → Diagnostics → "Coalesced touch samples" turned on while connected changes nothing until the next connection; then on the iPad a two-finger scroll with one finger already moving and a three-finger swipe do not stutter; re-run the M10.3 `tgreplay velocity-stats` comparison (D.10).
     8. Network Link Conditioner at ~5 % loss: quick one-finger lift-and-reposition, repeated — no pointer jump from the old lift point (the debug `id0` now counts 0, 1, 2…).
     9. Instruments Allocations (M2.3 procedure): coalesced off — 0 transient allocations per frame; on — only UIKit's `coalescedTouches` arrays.
     10. A phone "Record session" export still replays with `tgreplay run`.
   - **Pairing (both apps of this round):**
     1. Mac: Pair a device… → **Use a code instead** (it says "On your iPhone or iPad, open Trackglass → Pair with a code and choose “<Mac>”"); phone: **Pair with a code** → tap the Mac — both show the same "123 456" and Allow stays greyed ~1 s; Allow then Matches pairs and connects; again with Matches first, then Allow.
     2. **Doesn't match** on the phone → the Mac says "The codes didn't match — try again"; tap the Mac again → a new code, it pairs. **Don't Allow** on the Mac → the phone says the Mac did not allow pairing. Three failed sessions end the window ("Try again").
     3. With the Mac window still showing the QR, tap the Mac under Pair with a code — the phone says to click "Use a code instead" first.
     4. Phone already paired: scan the Mac's QR again — "Replace the pairing with “<Mac>”?"; Cancel keeps the old pairing working; Replace pairs again.
     5. VoiceOver on both: the code is read digit by digit; the Mac's question is read as one sentence.
     6. Screenshot or screen share of the pairing window: the QR does not appear (not guaranteed with ScreenCaptureKit on macOS 15+).
     7. Phone names with an emoji, a very long name, and a pasted RIGHT-TO-LEFT OVERRIDE (U+202E): the Mac shows the name without reordering, at most 40 characters ending in "…".
   - **Release:**
     1. During M11.2 prep, after `MARKETING_VERSION = 0.9.0` is committed and pushed (C5): `Scripts/release-mac.sh 0.9.0 --pre-release --dry-run`, open `Releases/Trackglass-for-Mac-0.9.0.dmg` — app left, Applications right, `Acknowledgements.md` above the arrow, nothing overlapping; Quick Look on it shows the Sparkle notices; eject.
     2. Optional, same prep: run the dry run again with that DMG still mounted — it stops at "Checking prerequisites" with "'/Volumes/Trackglass for Mac' is mounted …".
     3. `tgaccel --help; echo $?` prints the usage and `2`.
     4. C4 data run as `docs/Calibration.md` describes ("separate data-gathering run"); send `~/Desktop/tgaccel.json` — it should contain `tgaccelKeySources` and whichever scroll keys the Mac exposes (also the G-SCR data of 0000, item 3).
     5. Next push to `main`: the CI "Select Xcode" step prints a GA Xcode, not a beta or RC.
     6. Decide the EU trader status in App Store Connect → Business before submitting (`docs/APPSTORE.md` §3/§7).
     7. Keep `generate_keys -x` exports and `AuthKey_*.p8` files outside the repository (C2/C3); `.gitignore` now ignores them, but only as a backstop.
5. **Deferred (not done this round):**
   - L6: another app can claim the `trackglass://` scheme; a Universal Link (secret in the fragment) would fix it.
   - L23: scroll acceleration from `HIDScrollResolution`/`HIDScrollReportRate` waits for the `tgaccel` dump (B4 ii).
   - A 180° rotation (iPhone landscape left ↔ right, any on iPad) with a finger down is not cancelled: that finger's next frame lands mirrored, so the pointer can jump.
   - Release-script improvements not requested: lipo/arch and Sparkle CLI version checks, designated-requirement comparison in `assert-signing-team.sh`, pinned XcodeGen and action SHAs, website link check, meta CSP.
6. **Decision 0000.4 (tap-and-a-half timing) is superseded** by this round's change: the press never goes out early on motion (the motion is held and follows as drag motion), and from the 8 ms tick it waits a 35 ms margin (`TAP_HALF_PRESS_MARGIN`) after the 60 ms window. Re-ratify it on the device (Mac gesture checks 2–3): reply "ok" or say what you prefer.

## 0000. Round 3 of 2026-10-29 — CI green, committed; four decisions

1. ~~Run CI~~ — done (exit 0).
2. **Decision — WELCOME forward compatibility (SPEC §4.5, before 1.0):** WELCOME embeds the SETTINGS fields in its middle, then `activePhoneName`. After 1.0 the Mac (Sparkle) and the phone (App Store) update separately; a newer Mac appending a field to SETTINGS makes every older phone fail to read WELCOME (BYE{1}, final) until it updates. Options: (a) a `u16 settingsLength` before the embedded settings (wire change now, both prerelease apps updated together — recommended); (b) a rule that new settings fields go to the *end* of WELCOME, after `activePhoneName`. Reply "a" or "b".
3. **Decision — rotation during a straight scroll (SPEC §6.5.7):** with fingers 20 mm apart, a 2 mm lag over a 40 mm scroll crosses ROTATE_ACTIVATION (5°); rotation then joins and the scroll does not coast. Apply "bigger change wins" to rotation too (rotation needs more arc length than centroid travel before a scroll, a quarter of it during one)? Reply "yes" / "no".
4. *(Superseded 2026-10-31 by 00000.6 — do not ratify this version.)* **Ratify — tap-and-a-half press timing (SPEC §6.5.6, amended):** the press now waits up to 60 ms (settle window) unless the finger moves or lifts first; that is what stops a tap followed by a quick two-finger scroll from drag-selecting. Reply "ok" or say what you prefer.
5. **Ratify — pairing QR size (SPEC §3.4 says 320 × 320 pt):** it is 260 pt plus a 16 pt white quiet zone (292 pt) so the status column still fits the 480 × 360 window and phones read it in Dark Mode. Reply "ok" or "make it 320" (the status column then gets narrow).


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
