# Build 6 — concise ambient presentation

Installed and launched on the owner's paired iPhone on 2026-09-12 at 14:00 local after one transient wireless connection reset. Build identity `0.1 (6)`.

Changes from build 5:

- Dynamic Island uses a semantic rest/focus/demo icon and opening time; minimal view is icon-only.
- Lock Screen Live Activity uses **Get some rest** or **Focus time**, **Opens at…**, and only a short recovery/stale line when needed.
- Wind-down notification uses **Bedtime in N minutes** and **Lockbox starts at [time]**.
- Internal notification queue counts and long verification text are not shown in ordinary UI.
- Developer Live Activity screen reconciles an existing demo after navigation instead of incorrectly saying inactive.

Evidence: 84 root tests and 15 AmbientKit tests passed; simulator and signed device builds passed; Terra found no P0/P1 blocker and one P2 demo-state issue, fixed before this build. Owner subsequently confirmed the requested physical-device wind-down and Live Activity checks passed.

Owner feedback after QA: ordinary action buttons needed a clearer touch-down state. Source now uses a consistent full-width press style (scale, darkening and opacity) for primary, secondary and destructive actions; toolbar/navigation controls retain native behavior. This follow-up passed 84 tests and a simulator build but is not installed in build 6.
