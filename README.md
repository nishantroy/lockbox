# Phone Lockbox

A native iPhone app to keep essentials available while restricting nighttime app-hopping. Personal use first; local-only, no accounts or backend.

**Status:** working device prototype. Build-2 settings migration, scheduled blocking/automatic release and relaunch persistence have owner-reported passes. Next is production session/recovery integration; overnight and reboot reliability remain unvalidated.

## Start here

- **[Execution roadmap / Luna handoff](docs/roadmap.md)** — next tasks, dependencies, acceptance gates.
- **[Latest R1 progress and focused QA](docs/r1-progress.md)** — implementation, checks, and the next 20-minute device experiment.
- [Historical status and QA evidence](docs/status-and-qa.md) — confirmed build-1 behavior versus assumptions.
- [Independent Sol code review](docs/reviews/2026-09-10-sol.md) — prioritized findings.
- [Developer runbook](docs/development.md) — source map, builds, wireless device deployment.

## Specifications

- [Product plan](docs/product-plan.md): scope and success criteria.
- [Interaction design](docs/interaction-design.md): target setup, active-lock and recovery experience.
- [Technical plan](docs/technical-plan.md): intended architecture and platform-validation gates.

The SwiftUI app uses FamilyControls, ManagedSettings and DeviceActivity, with monitor and shield extensions. Generate the Xcode project using `xcodegen generate`; run core tests using `swift test`. Physical-device enforcement requires eligible Apple development signing. See the runbook for full commands.

This is a self-control tool, not tamper-proof lockdown. System exclusions, authorization revocation and uninstall remain limitations. Launcher/widgets, NFC and public distribution are deferred until bedtime reliability is proven.
