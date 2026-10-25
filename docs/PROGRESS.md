# Trackglass — Progress (docs/PROGRESS.md)

Tick a step only when its test passed and the commit is made. Keep notes to one line. Gate outcomes and final tunable values are recorded here **and** in SPEC Appendix A. P0.0 is the owner's row; the agent's first step is P0.1.

## Status

| Step | Done | Notes (gate outcome / tunable value / blocker) |
|---|---|---|
| P0.0 entitlement request filed (owner) | ☐ | date filed: |
| P0.1 scaffold project | ☐ | TG_REPO_URL: |
| P0.2 add packages and ci script | ☐ |  |
| P0.3 docs: build instructions | ☐ | license chosen: |
| M1.1 kit: message header | ☐ |  |
| M1.2 kit: touch frame codec | ☐ |  |
| M1.3 kit: control messages | ☐ |  |
| M1.4 kit: control framer | ☐ |  |
| M1.5 kit: pairing crypto | ☑ | 24 package tests pass: QR URL, independent HKDF vector, matching-key TLS exchange and wrong-key TLS rejection; zero warnings. |
| M1.6 kit: surface geometry | ☑ | Reference geometry, rotation/window bounds, PPI fallbacks and marketing names pass; 28 package tests, zero warnings. |
| M1.7 kit: tgrec format | ☑ | 500-frame file round-trips for both origins, malformed headers/records rejected; 31 package tests pass, zero warnings. |
| M2.1 ios: touch surface root | ☐ |  |
| M2.2 ios: touch frames | ☐ | ruler check result:  |
| M2.3 ios: frame sender | ☐ | Instruments result:  |
| M2.4 ios: 120hz display link | ☐ | events/s measured:  |
| M2.5 ios: liftoff and surface changes | ☐ |  |
| M3.1 net: bonjour discovery | ☐ |  |
| M3.2 net: pairing store | ☐ |  |
| M3.3a net: pairing via qr | ☐ |  |
| M3.3b net: pairing via pin | ☐ |  |
| M3.4 net: control session | ☐ | Gate G-TLS: multiple PSKs on one listener / per-phone listeners |
| M3.5 net: input channel | ☐ | frames/s observed:  |
| M3.6 net: reconnect and lifecycle | ☐ |  |
| M3.7 net: security tests | ☐ |  |
| M4.1a mac: accessibility gating | ☐ |  |
| M4.1b mac: pointer moves | ☐ |  |
| M4.2 mac: pointer bounds and wake | ☐ |  |
| M4.3 engine: contact rules | ☐ |  |
| M4.4 mac: trackpad preferences | ☐ | TrackpadCornerSecondaryClick mapping verified: 1 = , 2 =  |
| M4.5 engine: taps and clicks | ☐ |  |
| M4.6 engine: drag | ☐ |  |
| M4.7 engine: three finger drag and lookup | ☐ |  |
| M4.8 engine: liftoff safety | ☐ |  |
| M4.9 tools: tgreplay | ☐ | Mac Instruments result:  |
| M5.1 tools: tgaccel and default curves | ☑ | Gate G-ACC: the reference Mac exposes 10 `HIDAccelCurves` entries and `HIDPointerAccelerationTable` (771 bytes); select parametric curves for M5.2 and retain both in `DefaultAccelCurves.json`. Pointer resolution 26,214,400; report rate 120. `tgaccel` exits 0 and its JSON parses with all required properties. |
| M5.2 engine: acceleration curve | ☐ |  |
| M5.3 engine: pointer acceleration | ☐ |  |
| M5.4 calibrate pointer | ☐ | OUTPUT_SCALE = ; C1/C2/C3 results: ; A/B result:  |
| M6.1 mac: private fields | ☑ | Five private API tests and all 34 Mac hosted tests pass. HIDEvent resolves; both attachment symbols absent, dockSwipe=false; gestureEvents=true. Commit: mac: private fields. |
| M6.2 mac: scroll preferences | ☐ |  |
| M6.3 scroll | ☐ | Gate G-DIR:  |
| M6.4 scroll acceleration | ☐ | Gate G-SCR: Apple scroll curves / constant model |
| M6.5 scroll momentum | ☐ |  |
| M6.6 pinch and rotate | ☐ |  |
| M6.7 smart zoom | ☐ |  |
| M6.8 calibrate scroll | ☐ | final values:  |
| M7.1 mac: gesture preferences | ☐ |  |
| M7.2 engine: multi-finger swipes | ☐ |  |
| M7.3 mac: dock swipes | ☐ | MMF cut line: ; symbol name: ; tested on macOS:  |
| M7.4 mac: dock swipes hid event | ☐ |  |
| M7.5 mac: navigation swipe | ☐ |  |
| M7.6 mac: notification center | ☐ | Gate G-NC: fluid gesture / AX clock press |
| M7.7 mac: force click | ☐ | Gate G-FORCE: private force event / keyboard fallback |
| M7.8 mac: gesture fallbacks | ☐ |  |
| M7.9 calibrate gestures | ☐ | final values:  |
| M8.1 mac: preferences verified | ☐ | keys corrected:  |
| M8.2 haptics | ☐ |  |
| M8.3a ios: themes | ☐ |  |
| M8.3b ios: settings sheet | ☐ |  |
| M8.4 ios: hud | ☐ |  |
| M8.5 ios: onboarding | ☐ |  |
| M8.6a mac: welcome window | ☐ |  |
| M8.6b mac: settings window | ☐ |  |
| M8.7 ios: ipad | ☐ |  |
| M8.8 ios: feel settings | ☐ |  |
| M9.1 robustness: mac lifecycle | ☐ |  |
| M9.2 robustness: phone and engine | ☐ |  |
| M9.3 robustness: loss handling | ☐ |  |
| M9.4 robustness: soak | ☐ | memory start/end:  |
| M10.1 mac: latency stats | ☐ | p95:  |
| M10.2 docs: latency | ☐ | instrumented median/p95 at 120 Hz: ; at 60 Hz: ; camera delta vs trackpad:  |
| M10.3 ios: coalesced samples | ☐ | kept enabled: yes / no, because:  |
| M10.4 polish: accessibility and icons | ☐ |  |
| M10.5 ios: thermal and power | ☐ |  |
| M11.1 mac: sparkle updates | ☐ |  |
| M11.2 mac: release script | ☐ |  |
| M11.3 website and readme | ☐ | site URL: |
| M11.4 appstore: assets and metadata | ☐ |  |
| M11.5 testflight: beta fixes | ☐ | blockers found/fixed:  |
| M11.6 release 1.0.0 | ☐ | approval date:  |
| D1 driver: skeleton | ☐ |  |
| D2 driver: descriptor and feature reports | ☐ |  |
| D3 driver: input reports | ☐ | G-DRV-1..5:  |
| D4 driver: injector | ☐ | entitlement granted on:  |
| D5 driver: activation | ☐ |  |

## Blockers

(none yet)

## Decisions taken during implementation

(record here anything the owner approved that is not already in SPEC, with the date)

- 2026-10-22: Owner approved adding `activePhoneName str` after SETTINGS in WELCOME (§4.5), empty unless busy; codec and 32 package tests pass.
