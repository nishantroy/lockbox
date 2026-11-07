# Phone Lockbox agent handoff

Inherits `/Users/nishantroy/code/AGENTS.md`.

Before implementation, read:
1. `docs/roadmap.md` — execution order and acceptance gates (Luna's starting point).
2. `docs/r1-progress.md` — current implementation, validation and focused build-2 QA; `docs/status-and-qa.md` preserves earlier device evidence.
3. `docs/reviews/2026-09-10-sol.md` — independent review of the prototype.
4. `docs/development.md` — build/test/install commands and source map.
5. `docs/overnight-build-plan.md` — approved feature scope, lane ownership and source-only delivery constraints.
6. `docs/layout-v1-contract.md` — owner-approved tab structure, Lock now choices and UI/presentation boundaries.
7. `docs/accountability-design.md` — deferred accountability contract and production acceptance gates, when working on that future capability.

Product/interaction/technical plans specify intended behavior; they do not certify implementation. Update roadmap/QA evidence as work lands. Do not repeat already-passed owner QA without a relevant code change.

- Native iOS app. New approved prototype scope/ownership is in `docs/overnight-build-plan.md`: same-app accountless companion pairing, optional mutual pact, wind-down and minimal Live Activity. No hosted service/listener is provisioned yet; local HTTP ports must be reserved before adding one. NFC, TestFlight and visual redesign remain deferred.
- `project.yml` is XcodeGen source of truth. Preserve existing team, bundle IDs and App Group.
- Inspect untracked implementation as well as tracked diffs. Do not discard or overwrite existing work.
- In the main checkout, build into `DerivedData`/`.build-device`, leaving `.build` for SwiftPM. Do not delete the main checkout's build caches routinely.
- **Simulator use (owner rule, 2026-11-06, supersedes 2026-10-31):** nobody boots a simulator, launches the app in one, or runs `xcodebuild test`/UI tests unless the owner explicitly says to at that time (the laptop is low on RAM). This includes the pre-push app unit and `PhoneLockboxUITests` run: ask the owner before running it on the one dedicated simulator, and shut the simulator down afterwards. Without asking, validate with `swift test`, relay `npm test`/typecheck and compile-only `xcodebuild build` for the simulator SDK. Local commits and merges into `r5-relay` need no simulator run (record them as compile-only). The owner does hands-on QA in between.
- **Worktree builds** follow the shared rule in `/Users/nishantroy/code/AGENTS.md` ("Git worktrees and build caches"). Here that means `/Users/nishantroy/code/.build-cache/phone-lockbox/<worktree-name>/` with the commands in `docs/development.md`; `tools/worktree-cache-report.sh` lists worktrees, cache sizes and orphaned cache folders.
- Keep a safe prototype cleanup route until bounded session/recovery integration is device-validated. Never present manual cleanup as proof of automatic release.
- Do not install/update or change device schedules during a scheduled-release QA interval. Ask only for necessary system prompts/device participation or material decisions; otherwise proceed through the roadmap autonomously.
- Owner delegation standard: all substantive code-building or feature implementation is delegated to isolated writers with explicit file ownership; the parent writes the plan, orchestrates, and retains integration authority. This does not require a subagent for trivial status reporting or mechanical integration, and infrastructure-failure safety rules still apply (never claim delegation or validation that did not occur).
  - **Fleet sessions:** builders use executable Luna model variants at high/xhigh thinking as appropriate. Independent reviews and final gates use executable Terra model variants: medium for most reviews, high for complex cross-cutting changes, and xhigh only for exceptional security or lifecycle risk.
  - **Claude Code sessions** (Luna/Terra unavailable): builders are **Sonnet** subagents in isolated git worktrees, each handed a written plan slice. Independent reviews and final gates are **Opus** subagents that did not write the code under review. Record the actual models used in the QA/review docs; never label Claude work as Luna/Terra.
- **UX/design-polish review gate (owner rule, 2026-10-31):** every slice that changes user-facing UI or copy gets a separate UX review, in addition to the code review. It runs on the screenshots from the owner-approved pre-push UI suite run (owner decision 2026-10-31), so the owner may hands-on QA a build before it; findings must be fixed or deferred by the owner before pushing. The reviewer did not write the code; inputs are those screenshots plus `docs/design-language.md` (owner-approved design language, takes precedence on visual matters), `docs/layout-v1-contract.md`, `docs/design-polish.md` and `docs/interaction-design.md`. It checks: fewest steps for the task; real names instead of role placeholders; the right control type (selection is not a toggle); no unexplained disabled controls; empty/error states that say what to do; accurate, calm copy; accessibility labels, Dynamic Type and tab-bar overlap. 
