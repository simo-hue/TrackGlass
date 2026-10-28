# Trackglass — Latency measurements (docs/Latency.md)

Required by SPEC §7 and PLAN M10.2. Two metrics, both relative to the same Mac and display. The numbers need the owner's devices; the agent keeps the method, the formula and the table. Until measured, the cells are empty and M10.2 stays open in `docs/PROGRESS.md`.

## 1. Instrumented latency

Definition (SPEC §7): `RTT/2 + Mac pipeline latency + one phone touch-delivery period`, where

- `RTT` is the control-channel PING/PONG round trip the phone shows in the status pill (`RTT/2` is the figure in the pill) and the latency overlay (Settings → Diagnostics → Latency overlay; 120-sample sparkline, read the median and the 95th percentile off the overlay or from a `.tgrec`-free log of STATUS messages),
- the Mac pipeline latency is `pipelineP50Micros` / `pipelineP95Micros` from STATUS (Trackglass for Mac → Settings → Advanced shows the same p50/p95; SPEC §7 budget ≤ 0.3 ms p95),
- the touch-delivery period is 8.3 ms at 120 Hz and 16.7 ms at 60 Hz (one frame of the phone's display pipeline; the touch digitizer is sampled per display frame, SPEC §5.4).

Procedure: same Wi-Fi network, phone and Mac idle otherwise, two minutes of continuous one-finger motion, read the medians and p95 at the end. Repeat with the 60 Hz device (or the iPhone with Low Power Mode on, which caps ProMotion at 60 Hz).

| Device / rate | RTT median (ms) | RTT p95 (ms) | Pipeline p50 (µs) | Pipeline p95 (µs) | Delivery period (ms) | **Instrumented median (ms)** = RTT_med/2 + p50 + period | **Instrumented p95 (ms)** = RTT_p95/2 + p95 + period | Target |
|---|---|---|---|---|---|---|---|---|
| iPhone, 120 Hz | | | | | 8.3 | | | ≤ 12 median, ≤ 20 p95 |
| 60 Hz device | | | | | 16.7 | | | informational |

Date: — . Network: — . macOS / iOS versions: — .

## 2. Finger-to-pixel latency (camera)

What the user sees: the time from the finger starting to move on the glass to the pointer starting to move on the Mac's display, measured identically for the built-in trackpad and for Trackglass so the display's own latency cancels out. Target (SPEC §7): Trackglass ≤ built-in trackpad + 10 ms.

Procedure: 240 fps slow-motion video (iPhone Camera → Slo-mo 240 fps) framing both the finger and the Mac screen; a sharp finger start (a tap-and-slide from rest) and a high-contrast pointer; count frames between the first frame of finger motion and the first frame of pointer motion; one frame = 4.17 ms. 20 trials each; report median and p95.

| Input | Trials | Frames to first pointer motion (median) | Median (ms) | p95 (ms) |
|---|---|---|---|---|
| Built-in trackpad | 20 | | | |
| Trackglass, iPhone 120 Hz | 20 | | | |
| Trackglass, 60 Hz device | 20 | | | |

Delta Trackglass (120 Hz) − trackpad: — ms (target ≤ +10 ms).

## 3. If a target is missed

SPEC M10.2: profile and fix before continuing. Order of suspects: Wi-Fi RTT (compare with a peer-to-peer link and with the Mac on Ethernet), the phone's send path (Instruments → Time Profiler on `FrameSender`/`UDPFrameSink`), the Mac pipeline histogram (p95 above 0.3 ms means something allocates or blocks on the `input-pipeline` queue), then display pipeline effects (a 60 Hz external display adds up to 16.7 ms to both rows equally and cancels in the delta).
