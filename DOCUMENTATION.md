# Implementation log

- [2026-10-22 15:00 CEST]: M5.1 — tgaccel and default curves
  - *Details*: Implemented `tgaccel` to read built-in Apple multitouch trackpad registry properties and saved the reference Mac acceleration data.
  - *Tech Notes*: `tgaccel` exits 0; JSON parses and contains 10 parametric curves, a 771-byte acceleration table, pointer resolution 26,214,400 and report rate 120. G-ACC selects the parametric curve representation because `HIDAccelCurves` is present; table data is retained. No dependencies added.

- [2026-10-20 12:47 CEST]: P0.1 — Project scaffold (manual verification pending)
  - *Details*: Added the XcodeGen project, empty black UIKit scene for iPhone/iPad, and Mac menu-bar app with Quit. Both prescribed app builds pass; the Mac app has been opened. P0.1 remains uncommitted until manual verification passes.
  - *Tech Notes*: Installed XcodeGen 2.46.0. Swift 6 with complete strict concurrency; iOS 17 and macOS 14 deployment targets; Mac hardened runtime enabled and sandbox disabled. Shared configuration supplies product identifiers, GitHub Pages URL, and versions to generated Info.plists. The development team read from the owner's WealthCompass project is stored only in gitignored `Config/Local.xcconfig`. Generated Xcode projects, local signing configuration, build products and non-fixture recordings are ignored. The iOS scaffold build reports an orientation warning; orientation behavior is assigned to M2.1. No packages or later-step implementation added.

- [2026-10-20]: P0.1 — Verification complete
  - *Details*: Owner confirmed the Mac menu test and authorized continuing implementation, deferring mobile installation until a device test requires it. Both app builds passed.
  - *Tech Notes*: No code changes since the successful builds.

## Current Status

M1.7 complete. Next: M2.1 touch surface root, then build/install and request its manual test. Preserve the owner's existing edit to `FIRST-PROMPT.md`.

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


- [2026-10-22]: M1.3 correction — Active phone name in WELCOME
  - *Details*: With owner approval, appended activePhoneName to WELCOME so a busy response can identify the active controller. The default is empty for other statuses. Updated SPEC §4.5.
  - *Tech Notes*: Uses the existing u16-length UTF-8 encoding. All 32 Kit tests pass with zero compiler warnings, including busy/empty round trips, exact UTF-8 bytes and exhaustive truncation rejection. Both apps must use the corrected prerelease protocol layout. No dependencies added.


- [2026-10-25 19:23 CET]: M6.1 — Private Mac event support
  - *Details*: Centralized Appendix B event fields/types, added cached runtime API detection and missing-symbol/class fallbacks, and enforced the private-module source boundary. Owner approved deferring M5.4 calibration; OUTPUT_SCALE remains 1.0.
  - *Tech Notes*: Five new tests and all 34 Mac hosted tests pass. HIDEvent resolves; neither CGEventSetHIDEvent nor CGEventSetIOHIDEvent resolves on this Mac, so dockSwipe is false. Gesture event construction is available; fluid/force flags remain disabled pending their gates. No private framework linker dependency or new package dependency.


- [2026-10-25 19:25 CET]: M6.1 — Bridging-header warning fix
  - *Details*: Replaced pragma-once with a conventional header guard so direct Swift bridging-header compilation emits no main-file pragma warning.
  - *Tech Notes*: Mac hosted regression passes all 36 tests, including the five private API checks.
