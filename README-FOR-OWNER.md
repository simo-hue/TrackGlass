# How to use this folder (for Sambath — not part of the repo)

## What is here

| File | Goes where | Purpose |
|---|---|---|
| `CLAUDE.md` | repo root | Standing rules the coding agent reads at every session start (step discipline, test-then-commit, no scope creep, licensing, private-API policy). |
| `docs/SPEC.md` | `docs/` | The complete product and technical specification. All decisions are final; tunables and gates are marked. |
| `docs/PLAN.md` | `docs/` | The build order: ~80 small steps, each = one feature + its test + one commit message. The agent follows it top to bottom. |
| `docs/PROGRESS.md` | `docs/` | Checklist the agent ticks; gate outcomes and final tunable values are written here. |
| `docs/APPSTORE.md` | `docs/` | Every App Store Connect field for the iOS app, ready to paste (English). Also used by the agent in step M11.4. |
| `FIRST-PROMPT.md` | nowhere (keep it for yourself) | The first message to give the coding agent. |
| `README-FOR-OWNER.md` | nowhere | This file. |

## Setting up the repository

1. Create the **public** repo on GitHub (its Releases are the Mac app's download channel, and releases of a private repo are not publicly downloadable) with your `README.md` (one line is enough: "Trackglass — iPhone/iPad trackpad for Mac. See docs/.").
2. Copy `CLAUDE.md` to the repo root and the four files into `docs/`.
3. File the DriverKit entitlement request (P0.0 below) and tick its row in `docs/PROGRESS.md` with the date — or leave it unticked; the agent skips it either way.
4. Commit: `docs: specification and plan`.
5. Open Claude Code in the repo root and paste the text from `FIRST-PROMPT.md`. The agent will ask you for your Apple Team ID (untracked file) and the GitHub owner/repo name in P0.1, and for the license in P0.3.

## Things only you can do (the agent will wait for you)

- **P0.0** File the DriverKit entitlement request at https://developer.apple.com/contact/request/system-extension/ with the text in `docs/SPEC.md` §12.2. Phase 2 depends on Apple's answer; Phase 1 does not.
- **Manual tests** Many steps end with a MANUAL test: the agent installs the builds and gives you a numbered list of what to do on the phone/Mac. Reply "pass" or describe what you saw. The agent does not commit until you confirm.
- **Calibration** Steps M5.4, M6.8, M7.9 compare the phone against your MacBook's built-in trackpad. Budget an hour each; M5.4 also needs two other people for the blind A/B test (three testers in total).
- **Accounts and secrets** Developer ID certificate, App Store Connect record, Sparkle EdDSA key, `gh auth login` on the release Mac, trademark check on the name "Trackglass", and the open-source license you want for the public repo (MIT or Apache-2.0 are the usual choices). The Mac app is distributed from the repo's GitHub Releases and the README is the landing page; no website or domain is needed for 1.0.
- **Hardware** iPhone with 120 Hz display (reference), iPad, your MacBook; later a second Mac on macOS 14 for the QA matrix, and a dedicated Mac with SIP disabled for Phase 2 only.

## Renaming later

Everything derives from three xcconfig variables (`TG_PRODUCT_NAME`, `TG_BUNDLE_PREFIX`, `TG_REPO_URL`) plus the Bonjour service type and URL scheme listed in `docs/SPEC.md` §1.5. Change those and search the docs for "Trackglass".
