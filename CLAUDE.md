# Trackglass — working rules for the coding agent

You are building Trackglass: an iOS/iPadOS app plus a macOS companion that turns an iPhone or iPad into a trackpad for a Mac that behaves exactly like an Apple Magic Trackpad. Everything you need to know is in `docs/`. These rules apply to every session and every step.

## The documents

- `docs/SPEC.md` — the product and technical specification. Decisions there are final. Read §0–§4 fully before touching code; read the sections a step cites before doing that step.
- `docs/PLAN.md` — the only build order. One step at a time, in sequence.
- `docs/PROGRESS.md` — the checklist you keep up to date (tick steps, record gate outcomes and final tunable values).
- `docs/APPSTORE.md` — App Store Connect texts and assets (used in M11).
- `docs/THIRD-PARTY.md` — licenses and attribution (created in P0.3).

## The loop (never deviate)

1. Open `docs/PROGRESS.md`, find the first unticked step that is yours (P0.0 belongs to the owner; never wait on it), open it in `docs/PLAN.md`.
2. Implement only that step. No work on later steps, no "while I'm here" refactors, no extra features.
3. Run that step's test. AUTO tests you run yourself. MANUAL tests: build and install, then give the owner a numbered list of exactly what to do and what they must observe, and wait. Do not commit before the owner confirms.
4. If the test fails, fix it and test again. If the fix belongs to an earlier step, fix it there, test that earlier step again, and commit that fix on its own (message: `fix: <what>`).
5. When the test passes with zero failures (and zero warnings in `Packages/`), update `docs/PROGRESS.md`, then commit with the step's commit message exactly as written in `docs/PLAN.md`. One line. No body, no trailers, no co-author lines.
6. Only then move to the next step.

A step that cannot be completed (missing hardware, an Apple gate that fails) is not skipped silently: record the blocker in `docs/PROGRESS.md`, tell the owner, and stop.

## Hard rules

- **No scope creep.** If the spec does not say it, do not build it. If you believe the spec is wrong, say so to the owner with the section number and your reasoning, and wait; do not silently do something else.
- **Decisions, tunables, gates.** "Decision:" lines are implemented as written. "Tunable:" values start at the value given and change only through the calibration procedures in SPEC §10.3; record the final value in `docs/PROGRESS.md` and in SPEC Appendix A. "Gate:" steps branch exactly as written; record the outcome.
- **No private API on iOS, ever.** On the Mac, undocumented fields and classes live only under `Mac/Injection/Quartz/PrivateAPI/`, are resolved at runtime, and always have a fallback (SPEC §0.5).
- **Reference projects are for facts only.** Mac Mouse Fix, VoodooInput, Calf Trail's Touch and Apple's IOHIDFamily may be read to learn constants, sequences and algorithms. Never copy a file, a function body, or a comment from them. Write everything yourself; keep the attribution comment SPEC §6.6 prescribes on the acceleration files.
- **Zero allocations on the per-frame path** on both platforms (SPEC §7). Verify with Instruments when a step says so.
- **Swift 6, strict concurrency, warnings are errors in the packages.** SwiftUI for UI, UIKit for the touch surface, AppKit only where SPEC says. No third-party dependencies except Sparkle (Mac) and XcodeGen (tooling).
- **Project generation:** never edit the `.xcodeproj`; edit `project.yml` and run `xcodegen generate`.
- **Commits:** one per completed step (plus one per fix of an earlier step). Message = the exact text in `docs/PLAN.md`. Never commit failing tests, never commit with uncommitted generated junk, never amend published history.
- **Secrets:** never commit certificates, provisioning profiles, Sparkle private keys, or the owner's team ID in source. They live in the owner's Keychain and in the untracked `Config/Local.xcconfig` (created in P0.1 from `Config/Local.xcconfig.example`, gitignored).
- **Logging:** `os_log` only; touch coordinates only at `.debug` and marked private. No analytics, no network calls other than the Mac link and Sparkle.
- **Communication with the owner:** short, concrete, numbered. When you need a manual test, say which build to install, where to tap, and what should happen. When you report a step done, one line: step ID, what passed, the commit message.

## Reference hardware

The owner's reference devices: an iPhone with a 120 Hz display, an iPad, and an Apple-silicon MacBook (its built-in trackpad is the calibration reference). A second Mac on macOS 14 is used for the QA matrix when available. Phase 2 needs a dedicated test Mac with SIP disabled; never disable SIP on the development Mac.

## Build commands

```bash
brew install xcodegen                     # once
xcodegen generate
Scripts/ci.sh                             # swift test (both packages) + hosted test bundles + both app builds (+ tgreplay verify-dir from M4.9)
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOS -destination 'generic/platform=iOS' build
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac -configuration Debug build
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac -destination 'platform=macOS' test                       # TrackglassMacTests
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOS -destination 'platform=iOS Simulator,name=iPhone 17' test  # TrackglassiOSTests
xcrun devicectl list devices              # find the iPhone/iPad for installs
xcrun devicectl device install app --device <id> <path-to.app>
```

Test targets: `TrackglassKitTests` and `EngineTests` are package tests (`swift test`); `TrackglassMacTests` is hosted by the Mac app (so Accessibility and the data-protection Keychain are available; it contains the `InjectorTests` folder); `TrackglassiOSTests` is hosted by the iOS app on the simulator.
