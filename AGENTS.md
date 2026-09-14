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
- Build into `DerivedData`/`.build-device`, leaving `.build` for SwiftPM. Do not delete build caches routinely.
- Keep a safe prototype cleanup route until bounded session/recovery integration is device-validated. Never present manual cleanup as proof of automatic release.
- Do not install/update or change device schedules during a scheduled-release QA interval. Ask only for necessary system prompts/device participation or material decisions; otherwise proceed through the roadmap autonomously.
- Owner delegation standard: all substantive code-building or feature implementation must use native Fleet delegation with executable Luna model variants at high/xhigh thinking as appropriate and isolated writer ownership. Independent reviews and final gates use executable Terra model variants at high/xhigh thinking as appropriate. The parent retains integration authority. This does not require a subagent for trivial status reporting or mechanical integration, and infrastructure-failure safety rules still apply (never claim delegation or validation that did not occur).
