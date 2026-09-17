# Phone Lockbox

A native iPhone app to keep essentials available while restricting nighttime app-hopping. Personal use first. Bedtime enforcement is local; an accountless trusted-person companion protocol is being prototyped separately, with no hosted service configured.

**Status:** build 3 has owner-reported passes for persistence, pending edits, delayed recovery and one overnight natural release. Interruption/reboot and broader platform cases still need coverage. Source-only reliability, companion and ambient prototypes are tracked in the [overnight build contract](docs/overnight-build-plan.md); no new device deployment is implied.

## Start here

- **[Build-5 candidate](docs/build5-candidate.md)** — reviewed tabbed layout and flexible Lock now; signed and ready for focused device QA.
- [Build-4 ambient candidate](docs/build4-candidate.md) — reliability fixes and standalone native demos; owner-tested.
- **[Execution roadmap / Luna handoff](docs/roadmap.md)** — next tasks, dependencies, acceptance gates.
- **[Build-3 lifecycle QA](docs/r2-r3-qa.md)** — reported passes and remaining acceptance cases.
- [Historical R1 progress](docs/r1-progress.md) — build-2 implementation and completed bounded experiment.
- [Historical status and QA evidence](docs/status-and-qa.md) — confirmed build-1 behavior versus assumptions.
- [Independent Sol code review](docs/reviews/2026-09-10-sol.md) — prioritized findings.
- [Developer runbook](docs/development.md) — source map, builds, wireless device deployment.
- [Quick Actions candidate](docs/quick-actions.md) — bounded App Intents and deep-link safety contract.

## Specifications

- [Product plan](docs/product-plan.md): scope and success criteria.
- [Interaction design](docs/interaction-design.md): target setup, active-lock and recovery experience.
- [Technical plan](docs/technical-plan.md): intended architecture and platform-validation gates.

The SwiftUI app uses FamilyControls, ManagedSettings and DeviceActivity, with monitor and shield extensions. Generate the Xcode project using `xcodegen generate`; run core tests using `swift test`. Physical-device enforcement requires eligible Apple development signing. See the runbook for full commands.

This is a self-control tool, not tamper-proof lockdown. System exclusions, authorization revocation and uninstall remain limitations. NFC and public distribution remain deferred. Live Activity and wind-down prototypes are informational only, never enforcement or cleanup dependencies.
