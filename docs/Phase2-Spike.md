# Phase 2 — DriverKit feasibility spike (SPEC §12.3)

Not started. Phase 2 needs two things that do not exist yet: Apple's answer to the system-extension entitlement request (P0.0, owner) and a dedicated test Mac with SIP disabled (never the development Mac). D1–D3 can run on that Mac before the entitlement arrives; D4–D5 only after it is granted and every gate below passed.

## Gates (record the outcome of each; a failure after reasonable iteration closes Phase 2 for that OS)

| Gate | What must be observed | macOS | Outcome | Notes (transport string / feature responses tried) |
|---|---|---|---|---|
| G-DRV-1 | `ioreg -l` shows `AppleMultitouchTrackpadHIDEventDriver` (or `AppleMultitouchDevice`) attached under the virtual device | | | |
| G-DRV-2 | System Settings → Trackpad lists the device and its gesture settings apply | | | |
| G-DRV-3 | Pointer, tap-to-click, two-finger scroll with native momentum, pinch, Mission Control from scripted frames | | | |
| G-DRV-4 | Force click from scripted pressure ramps | | | |
| G-DRV-5 | Survives sleep/wake and reboot (dext re-activation) | | | |

## Decisions and facts to record

- Entitlement request: date filed, Apple's answer and date.
- Test Mac: model, macOS version, `csrutil status`, `systemextensionsctl developer` state.
- Device description that made the multitouch driver attach (VID/PID/Transport/VersionNumber).
- Feature-report responses that differed from the reference.
