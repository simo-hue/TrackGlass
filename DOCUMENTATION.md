# Implementation log

- [2026-10-20 12:47 CEST]: P0.1 — Project scaffold (manual verification pending)
  - *Details*: Added the XcodeGen project, empty black UIKit scene for iPhone/iPad, and Mac menu-bar app with Quit. Both prescribed app builds pass; the Mac app has been opened. P0.1 remains uncommitted until manual verification passes.
  - *Tech Notes*: Installed XcodeGen 2.46.0. Swift 6 with complete strict concurrency; iOS 17 and macOS 14 deployment targets; Mac hardened runtime enabled and sandbox disabled. Shared configuration supplies product identifiers, GitHub Pages URL, and versions to generated Info.plists. The development team read from the owner's WealthCompass project is stored only in gitignored `Config/Local.xcconfig`. Generated Xcode projects, local signing configuration, build products and non-fixture recordings are ignored. The iOS scaffold build reports an orientation warning; orientation behavior is assigned to M2.1. No packages or later-step implementation added.

- [2026-10-20]: P0.1 — Verification complete
  - *Details*: Owner confirmed the Mac menu test and authorized continuing implementation, deferring mobile installation until a device test requires it. Both app builds passed.
  - *Tech Notes*: No code changes since the successful builds.

## Current Status

P0.2 complete. Next: P0.3 build instructions and attribution documents. Preserve the owner's existing edit to `FIRST-PROMPT.md`.

- [2026-10-20]: P0.2 — Packages and CI
  - *Details*: Added both shared packages, placeholder package and app-hosted tests, and empty tgreplay/tgaccel targets. CI exited 0, including simulator tests and both signed app builds.
  - *Tech Notes*: Engine depends on Kit; both packages enforce Swift 6, complete strict concurrency and warnings as errors. Injector placeholder skips without Accessibility. CI supports an optional TG_IOS_TEST_DESTINATION override and also builds both command-line tools. No new third-party dependencies.
