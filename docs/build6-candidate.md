# Build 6 — concise ambient presentation

Installed and launched on the owner's paired iPhone on 2026-09-12 at 14:00 local after one transient wireless connection reset. Build identity `0.1 (6)`.

Changes from build 5:

- Dynamic Island uses a semantic rest/focus/demo icon and opening time; minimal view is icon-only.
- Lock Screen Live Activity uses **Get some rest** or **Focus time**, **Opens at…**, and only a short recovery/stale line when needed.
- Wind-down notification uses **Bedtime in N minutes** and **Lockbox starts at [time]**.
- Internal notification queue counts and long verification text are not shown in ordinary UI.
- Developer Live Activity screen reconciles an existing demo after navigation instead of incorrectly saying inactive.

Evidence: 84 root tests and 15 AmbientKit tests passed; simulator and signed device builds passed; Terra found no P0/P1 blocker and one P2 demo-state issue, fixed before this build. Device presentation remains owner QA, not established by compilation.
