# Phone Lockbox agent handoff

Inherits `/Users/nishantroy/code/AGENTS.md`.

Before implementation, read:
1. `docs/roadmap.md` — execution order and acceptance gates (Luna's starting point).
2. `docs/r1-progress.md` — current implementation, validation and focused build-2 QA; `docs/status-and-qa.md` preserves earlier device evidence.
3. `docs/reviews/2026-09-10-sol.md` — independent review of the prototype.
4. `docs/development.md` — build/test/install commands and source map.

Product/interaction/technical plans specify intended behavior; they do not certify implementation. Update roadmap/QA evidence as work lands. Do not repeat already-passed owner QA without a relevant code change.

- Local native iOS app; no server or port needed. Launcher, NFC, distribution and cosmetic redesign remain deferred.
- `project.yml` is XcodeGen source of truth. Preserve existing team, bundle IDs and App Group.
- Inspect untracked implementation as well as tracked diffs. Do not discard or overwrite existing work.
- Build into `DerivedData`/`.build-device`, leaving `.build` for SwiftPM. Do not delete build caches routinely.
- Keep a safe prototype cleanup route until bounded session/recovery integration is device-validated. Never present manual cleanup as proof of automatic release.
- Do not install/update or change device schedules during a scheduled-release QA interval. Ask only for necessary system prompts/device participation or material decisions; otherwise proceed through the roadmap autonomously.
