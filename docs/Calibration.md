# Trackglass — Calibration record (docs/Calibration.md)

The procedures are SPEC §10.3; the constants they may change are the **Tunable** rows of SPEC Appendix A. This file holds the measurements and the final values. Only the owner can fill the result cells (they need the reference MacBook's built-in trackpad, the 120 Hz iPhone and the iPad); the agent keeps the tables, the arithmetic and Appendix A in sync once numbers arrive. Until a row is measured, the Appendix A starting value ships.

Reference set-up for every procedure: the same Mac, the same display, Trackglass connected over Wi-Fi (not peer-to-peer), the phone's tracking override at 0, System Settings → Trackpad left at the values noted in the row. Log pointer travel with `log stream --predicate 'subsystem == "app.trackglass.mac" AND category == "inject"' --level debug` (pointer deltas are `.debug` and private; run the stream as the logged-in user) or with a small `CGEvent` location logger — the same logger for both devices.

## C1–C3 Pointer (M5.4) — PLAN M5.4, owner-deferred on 2026-10-25

Target: travel within the tolerance of the built-in trackpad at the same tracking tick. Three trials per cell, median reported. `OUTPUT_SCALE` (SPEC §6.6) changes only if a constant ratio appears across all ticks.

| Tick (System Settings slider) | `com.apple.trackpad.scaling` | C1 1 mm / 1 s — trackpad pt | C1 — Trackglass pt | C1 ratio (±15 %) | C2 100 mm / 0.5 s — trackpad pt | C2 — Trackglass pt | C2 ratio (±10 %) | C3 60 mm / 0.12 s — trackpad pt | C3 — Trackglass pt | C3 ratio (±15 %) | C3 crosses ≥ 90 % of 1512 pt at default tick |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 0 | | | | | | | | | | — |
| 4 | 0.6875 (default) | | | | | | | | | | |
| 7 | 1.5 | | | | | | | | | | — |
| 10 | 3 | | | | | | | | | | — |

Result: `OUTPUT_SCALE` = 1.0 (starting value; change only if every ratio above agrees on a constant). Date: — . Tester: — .

**Blind A/B** (three testers, 10 slow moves + 10 flicks each on trackpad and phone in random order, screen only):

| Tester | Correct identifications / 20 | At chance (≤ 12)? |
|---|---|---|
| 1 | | |
| 2 | | |
| 3 | | |

Pass when at least two testers are at chance. Result: — .

## C4–C6 Scroll, momentum, pinch (M6.8) — owner-deferred

C4 drives `SCROLL_BASE_GAIN` / `SCROLL_ACCEL_GAIN` / `SCROLL_ACCEL_V0` **only if** Gate G-SCR selected the constant model; PROGRESS M6.4 records that the reference Mac exposes `HIDScrollAccelCurves`, so the Apple scroll curves are in use and C4 is a verification, not a tuning, unless it fails.

| Procedure | Trackpad | Trackglass | Tolerance | Pass |
|---|---|---|---|---|
| C4 scroll distance — two fingers 50 mm in 0.33 s, Finder list view (rows scrolled) | | | ±15 % | |
| C5 momentum — same flick: time until the list stops (s) | | | ±25 % | |
| C5 momentum — same flick: rows travelled during momentum | | | ±25 % | |
| C6 pinch — 20 mm spread in Preview on a PDF at 100 % (resulting zoom %) | | | ±10 % | |

Final values: `SCROLL_BASE_GAIN` = 3.8 pt/mm, `SCROLL_ACCEL_GAIN` = 0.5, `SCROLL_ACCEL_V0` = 350 mm/s (fallback model only), `MOMENTUM_MIN_START` = 60 pt/s, `MOMENTUM_DECAY_PER_MS` = 0.998 — all still the Appendix A starting values. Date: — .

## C7 Spaces (M7.9)

| Trial | 110 mm three-finger swipe → exactly one Space? | 40 mm swipe → snaps back? |
|---|---|---|
| 1 | | |
| 2 | | |
| 3 | | |

`SPACES_MM_PER_SPACE` final value: 110 mm (starting value). Note: on the reference Mac (macOS 27) the Dock swipe runs through the keyboard fallback (PROGRESS M7.3/M7.4), which cannot track live; C7 is meaningful only on a Mac where `PrivateAPICapabilities.dockSwipe` resolves, or after the owner decides whether to trial the legacy-fields path on macOS 27 (TO_SIMO_DO).

## C8 Thresholds (M7.9)

20 deliberately marginal trials per gesture on the trackpad and 20 identical trials on the phone, same tester, same intent. Agreement ≥ 19/20; otherwise move the constant toward the trackpad's behaviour and repeat.

| Gesture | Constant (Appendix A start) | Trackpad recognized / 20 | Trackglass recognized / 20 | Agreement | Final value |
|---|---|---|---|---|---|
| Tap | TAP_MAX_DURATION 0.30 s, TAP_MAX_MOVEMENT 2.0 mm | | | | |
| Double tap | MULTI_TAP_SPREAD 5.0 mm (+ `NSEvent.doubleClickInterval`) | | | | |
| Two-finger tap | TWO_FINGER_TAP_STAGGER 0.10 s | | | | |
| Tap-drag | DRAG_RELEASE_GRACE 0.30 s | | | | |
| Three-finger drag | THREE_FINGER_DRAG_START 2 mm (not tunable) | | | | — |
| Scroll start | SCROLL_ACTIVATION 1.5 mm | | | | |
| Pinch start | PINCH_ACTIVATION 2.5 mm | | | | |
| Rotate start | ROTATE_ACTIVATION 5° | | | | |
| Navigation swipe | NAV_SWIPE_DISTANCE 20 mm | | | | |
| Mission Control | MISSION_CONTROL_MM 60 mm | | | | |
| Launchpad pinch | PINCH_MM_FULL 40 mm, PINCH_GESTURE_ACTIVATION 8 mm | | | | |
| Force click | FORCE_HOLD 0.60 s | | | | |
| Momentum start | MOMENTUM_MIN_START 60 pt/s | | | | |
| Settle window | SETTLE_WINDOW 60 ms | | | | |

## How a changed value is recorded

1. Change the literal in the engine (the constants are literals next to a `// §…` comment; `grep -n` the Appendix A name in `Packages/TrackglassEngine/Sources`).
2. Regenerate any fixture whose expected output depends on it (`tgreplay run … > <name>.expected.json`, then `Scripts/ci.sh`).
3. Write the final value here, in `docs/PROGRESS.md` (M5.4 / M6.8 / M7.9 row) and in SPEC Appendix A, with the date.
