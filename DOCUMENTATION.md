# Implementation log

- [2026-10-20 12:47 CEST]: P0.1 — Project scaffold (manual verification pending)
  - *Details*: Added the XcodeGen project, empty black UIKit scene for iPhone/iPad, and Mac menu-bar app with Quit. Both prescribed app builds pass; the Mac app has been opened. P0.1 remains uncommitted until manual verification passes.
  - *Tech Notes*: Installed XcodeGen 2.46.0. Swift 6 with complete strict concurrency; iOS 17 and macOS 14 deployment targets; Mac hardened runtime enabled and sandbox disabled. Shared configuration supplies product identifiers, GitHub Pages URL, and versions to generated Info.plists. The development team read from the owner's WealthCompass project is stored only in gitignored `Config/Local.xcconfig`. Generated Xcode projects, local signing configuration, build products and non-fixture recordings are ignored. The iOS scaffold build reports an orientation warning; orientation behavior is assigned to M2.1. No packages or later-step implementation added.

- [2026-10-20]: P0.1 — Verification complete
  - *Details*: Owner confirmed the Mac menu test and authorized continuing implementation, deferring mobile installation until a device test requires it. Both app builds passed.
  - *Tech Notes*: No code changes since the successful builds.

## Current Status

M1.1 complete. Next: M1.2 inline touch frame and codec. Preserve the owner's existing edit to `FIRST-PROMPT.md`.

- [2026-10-20]: P0.2 — Packages and CI
  - *Details*: Added both shared packages, placeholder package and app-hosted tests, and empty tgreplay/tgaccel targets. CI exited 0, including simulator tests and both signed app builds.
  - *Tech Notes*: Engine depends on Kit; both packages enforce Swift 6, complete strict concurrency and warnings as errors. Injector placeholder skips without Accessibility. CI supports an optional TG_IOS_TEST_DESTINATION override and also builds both command-line tools. No new third-party dependencies.

- [2026-10-20]: P0.3 — Build documentation
  - *Details*: Added README setup, signing, build, test and install commands, plus Apple APSL-2.0 attribution and Sparkle MIT/upstream notices. Confirmed the progress checklist covers all plan steps; CI exited 0.
  - *Tech Notes*: No implementation or dependency changes. References are facts only; no MMF, VoodooInput or Touch code is included.

- [2026-10-20]: M1.1 — Message header
  - *Details*: Added the 16-byte little-endian header, all message type values, typed decoding errors and a monotonic nanosecond clock. Six package tests pass with zero warnings.
  - *Tech Notes*: Unknown type bytes are retained; magic is compared byte-wise; unaligned buffers are supported. Clock converts mach_absolute_time with full-width arithmetic. No new dependencies.
