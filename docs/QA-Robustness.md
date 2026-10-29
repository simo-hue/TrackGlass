# Trackglass QA: Security and robustness

## 1. Wireshark transport encryption check

Run this once on the Mac while a paired phone connects and sends touch input.

1. Start Wireshark on the Mac's active Wi-Fi interface before connecting the phone. Use `dns-sd -L '<Mac name>' _trackglass._tcp local` and `dns-sd -L '<Mac name>' _trackglass._udp local` in Terminal to identify the advertised control and input ports. The Mac Input log also reports `udpPort` for the input listener.
2. In Wireshark, filter for the two ports: `tcp.port == <control-port> || udp.port == <input-port>`. Keep the pairing listener out of the capture after pairing is complete.
3. Connect the paired phone, wait for the control session, then move a finger on the surface for several seconds. Wireshark should decode the control stream as TLS and the input datagrams as DTLS. Application data may appear as encrypted application records; no decoded `TOUCH_FRAME` fields or clear touch coordinates should appear.
4. Confirm the capture contains no clear application payload on either session port. The app logs may show frame counts, but touch coordinates are private and are never logged above debug level.

Record the macOS version, Wireshark version, interfaces, and whether both ports showed TLS/DTLS records in `docs/PROGRESS.md` after the check.

## 2. Robustness checklist (SPEC §8, M9.1–M9.2)

Run with the latest Mac and phone builds installed together. Tick each item in `docs/PROGRESS.md` only after the observation matches.

| # | Item | How to verify | Expected |
|---|---|---|---|
| 1 | Mac sleep / wake | With the phone connected, put the Mac to sleep (Apple menu → Sleep), wait 10 s, wake it. | Mac Control log shows BYE reason 4 before sleep; the phone reconnects by itself within 2 s of the Mac's listeners restarting. |
| 2 | Display sleep | Let the display sleep (Control-Shift-Eject or wait for the display timer). Touch and move on the phone. | Display wakes on the first touch; the pointer moves from that same input and is already at the new position when the display lights up (wake assertion precedes the event in the same tick). |
| 3 | Fast user switching | Switch to another macOS user (login window or a second account) while connected; try to connect from the phone; switch back. | Phone sees "Disconnected"; a connection attempt while the other user is active is refused with "<Mac> is being used by another macOS user session"; after switching back the phone connects. |
| 4 | Screen configuration changes | Connect/disconnect an external display and change arrangement in System Settings → Displays while moving the pointer. | Pointer never lands off-screen; it slides along edges and crosses displays at their shared edge. |
| 5 | Accessibility revoked while connected | System Settings → Privacy & Security → Accessibility → turn Trackglass off while connected. | Within 5 s the Mac sends BYE, the phone shows "Disconnected", and the Welcome window appears with the Accessibility status and the System Settings button. Granting again reconnects without relaunch. |
| 6 | Accessibility grant survives updates | After a release build: `Scripts/assert-signing-team.sh <new.app> <previous.app>`. | Prints "Signing team matches the previous app."; installing the new build over the old one keeps the Accessibility grant. |
| 7 | Phone rotation mid-gesture | Start a two-finger scroll, rotate the phone while scrolling. | Scroll ends (`cancelled`), no button stays held, the next gesture starts cleanly in the new orientation (fixture `rotation_cancels_gesture`). |
| 8 | Phone backgrounded mid-drag | Start a tap-and-a-half drag (with and without Drag Lock), press the phone's Home gesture. | The Mac releases the mouse button within 2 s in both cases; drag lock does not survive the disconnect. |
| 9 | Clock weirdness | Automated: `InputPipelineTests.testDropsOutOfOrderAndBackwardsTimeFrames`. | Backwards-time frames are dropped and counted; nothing is injected for them. |
| 10 | Two phones | With the iPhone connected, connect the iPad to the same Mac. | iPad shows "<Mac> is being used by <iPhone name>"; the iPhone stays connected. |
| 11 | Mac without a trackpad | On a Mac mini/Studio with only a mouse (or temporarily remove the trackpad preference domains on a throwaway test account). | Appendix A defaults apply; tracking speed uses `com.apple.trackpad.scaling` if present, else 0.6875; `com.apple.mouse.scaling` is never read; pointer still moves and clicks. |
| 12 | iPad multitasking gestures | Fresh install on the iPad: onboarding shows the 4th page. | Instructions to turn off Settings → Multitasking & Gestures → Gestures are shown; after doing so, four-finger swipes reach the Mac. |
| 13 | Apple Pencil | Touch the iPad surface with the Pencil. | Nothing happens on the Mac; finger input keeps working. |
| 14 | Pencil hover | Hover the Pencil over an iPad Pro surface. | No halo, no pointer movement, no frames with a contact. |
| 15 | Very large surfaces | 13-inch iPad in landscape. | A 1 mm finger movement moves the pointer the same distance as 1 mm on the iPhone (unitGain replay of a recording from each device gives equal deltas). |
| 16 | Preferences changed while connected | Toggle Natural scrolling in System Settings during a long two-finger scroll; keep scrolling; lift; scroll again. | The running scroll keeps its direction; the next scroll uses the new direction (fixture `settings_change_deferred`); the Mac log shows the snapshot within 2 s. |
| 17 | Private field missing | Launch with `defaults write app.trackglass.mac TGDisablePrivateGestures -bool YES`. | Three-finger swipe still switches Spaces via the shortcut fallback; the menu bar menu and Settings → Advanced show "Reduced gesture mode" with the affected gestures. |

## 3. Loss and latency conditioning (M9.3)

1. Automated: `Scripts/invariants.sh` (run by `Scripts/ci.sh`) replays every fixture with 5 % pseudo-random datagram loss for seeds 1–20. `tgreplay invariants` emulates what the Mac pipeline adds around the engine — the 8 ms tick from the first frame until the engine stops asking for ticks, and the 1.5 s no-frame lift-off timeout (§4.7) — and then checks that the engine released every button and ended every gesture **on its own** (a drag lock that is still engaged is the one legitimate held button: §6.5.10 says only a tap or BYE ends it), that it settled within 10 s of the last frame, that the BYE-style final forced lift-off finds nothing else to release, and that nothing is emitted afterwards.
2. On the iPhone enable Settings → Developer → Network Link Conditioner with a custom profile: 3 % packet loss both ways. Use the Mac for five minutes: pointer, taps, drags, scrolls, pinch, three-finger swipes.
3. Switch to a profile with 100 ms delay spikes (e.g. "Very Bad Network"). Repeat for five minutes.
4. Expected: no stuck button or gesture, no pointer jump larger than the finger movement, the connection never drops, and when it is forced to drop (toggle Wi-Fi) it reconnects within 2 s.

## 4. 24-hour soak (M9.4)

1. Pair and connect the iPhone, then run `xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOSSoak -destination 'platform=iOS,id=<device>' test TG_SOAK_SECONDS=86400 TG_SOAK_EXPECT_CONNECTED=1` (the trailing build-setting overrides reach the test runner; use `TG_SOAK_SECONDS=600` for a smoke run) (device id from `xcrun devicectl list devices`). The test drags one finger around the surface continuously; with `TG_SOAK_EXPECT_CONNECTED=1` it also fails as soon as the session is lost (the No-Mac panel appears), so a passing run proves the phone stayed connected.
2. Before starting and after 24 h record the Mac app's memory (Activity Monitor → Memory, Real Memory) and run Instruments → Leaks against the running Mac app for one minute each time.
3. Expected: memory within ±5 MB of the start, no leaks, the Mac log shows one status line per second without errors, and the phone is still connected at the end.
