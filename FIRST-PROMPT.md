You are implementing Trackglass, an iOS/iPadOS app plus a macOS companion that turns an iPhone or iPad into a trackpad for a Mac that behaves exactly like an Apple Magic Trackpad. The repository currently contains only documentation. The product, architecture, protocol and every technical decision are already final and written down; your job is to implement them in Swift, one step at a time.

Start by reading, in this order, without writing any code:
1. `CLAUDE.md` — the working rules. They apply to every step.
2. `docs/SPEC.md` sections 0 through 4 in full (how to read the spec, product definition, architecture, security and pairing, the shared protocol).
3. `docs/PLAN.md` — the "How to work a step" section and step P0.1.
4. `docs/PROGRESS.md` — the checklist you will keep updated.

Then confirm to me in at most ten lines: the two apps and the two shared packages you will build, the two phases and why Phase 1 ships first, the one rule about commits, and the one rule about manual tests. Do not summarize the whole spec.

After that, begin with step P0.1 exactly as written in `docs/PLAN.md`: implement it, run its test, and when the test passes, update `docs/PROGRESS.md` and commit with the message `scaffold project`. Then continue to P0.2, and so on, one step at a time, in the order of `docs/PLAN.md`.

Working agreement:
- One step at a time. Never implement a later step early, never bundle two steps into one commit, never refactor outside the current step.
- Every step ends with its test passing and one commit whose message is exactly the one in `docs/PLAN.md` (a single line; no body, no trailers).
- When a step's test is marked MANUAL, build and install the apps, then stop and give me a numbered list of what to do and what I should see. Wait for my confirmation before committing. I will answer "pass" or describe what I saw.
- If a step says "Gate", run the check, follow the branch the spec prescribes, and record the outcome in `docs/PROGRESS.md`.
- If you believe the spec or the plan is wrong or impossible, stop and tell me the section number and your reasoning; do not improvise an alternative.
- Read the spec sections a step cites before implementing it. Read the reference projects the spec names only to learn facts; never copy code from them.
- Keep your messages short: when a step is done, one line with the step ID, what passed, and the commit message; when you need me, a numbered list.

My environment: this Mac has Xcode 27.1 installed, with my Apple Developer account signed in and automatic signing available for development. My iPhone (120 Hz display) and my iPad are connected by cable and trusted for development. The built-in trackpad of this MacBook is the calibration reference. Step P0.0 (the DriverKit entitlement request) is mine, not yours; never wait for it. When P0.1 needs my Team ID, ask me for it.

Begin with the reading, then the ten-line confirmation, then P0.1.