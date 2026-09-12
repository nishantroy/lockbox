# Build 4 — source-only device-QA candidate

Prepared 2026-09-12. Build 4 was installed on the owner's paired iPhone at 11:41 PDT and launched successfully on explicit request. No notification permission or demo scheduling was requested by the agent. Physical-device QA of this build remains pending.

## Included

- Reliability fixes: persisted release replay, atomic current-aggregate cleanup, scheduled recurrence retention, absolute activation fences/migration, recovery/history invariants, late manual callbacks retaining newer manual routes, and surfaced reconciliation failures.
- `AmbientKit` and an embedded WidgetKit Live Activity extension.
- Developer tools → **Wind-down & Live Activity prototypes**. Standalone opt-in notification demo (up to seven reminders), explicit permission request/schedule/disable, and fixed-end Live Activity demo with start/update/end. No countdown.
- Demos are not connected to saved lock configuration and cannot enforce or release restrictions. Reminder controls are drafts; pending system request count is queried on entry. Demo notifications remain until delivered/disabled; leaving the screen does not remove them.
- Live Activities have platform lifetime limits; stale data is labeled. Neither notifications nor the Activity are an automatic-release mechanism.

## Excluded

Companion pairing/pact/service prototypes remain on `overnight/companion` while security findings receive fixes and re-review. No functioning remote relay, APNs provisioning, TestFlight, NFC, broader redesign or mandatory accounts.

## Actual validation

- Root SwiftPM: **77 tests passed**.
- `swift test --package-path AmbientKit`: **13 tests passed**.
- XcodeGen generation, simulator build including all four extensions: passed.
- Signed generic-device Debug build: passed, `0.1 (4)`, `.build-device/Build/Products/Debug-iphoneos/PhoneLockbox.app`.
- Terra medium integrated review: **no verified P0/P1 blockers for narrow device-QA prototype**; independently reran tests/simulator build and plist/diff checks. See [report](reviews/2026-09-12-build4-terra.md).
- Initial integrated compilation caught ActivityKit/UserNotifications Swift 6 isolation issues and missing widget bundle metadata. Those were fixed before the passing builds/review; standalone lane typechecks had not established app integration readiness.

## Source checkpoints

- `75c6a8d`: build-3 source/QA baseline.
- `ae6c514`: merge reliability commits, including stale manual-route regression fix `5bb2263`.
- `e2baa4e`: merge ambient commits, including planned-zone fix `def9fd2`.
- Subsequent integration commit links local package/widget, adds the developer entry point, labels demos, fixes Swift 6 bridges/metadata and bumps build identity. Each slice is locally committed, not pushed.

## Focused next owner QA

Install only when no current lock/QA interval is running. Preserve developer unlock/reset.

1. Confirm settings remain present; locate the new developer prototype screen.
2. Explicitly request notification permission only if testing reminders. Set a demo bedtime a few minutes ahead with a one-minute lead; Schedule. Leave the app and observe delivery. Disable afterward to remove remaining demo requests.
3. Start Live Activity demo, inspect Lock Screen/Dynamic Island, update recovery text and end demo. These operations must not change actual restrictions. This is presentation evidence, not enforcement evidence.
4. Reliability changes require targeted subsequent validation: daily registration remains after natural end, next occurrence starts, manual end/recovery/relaunch behavior. Historical build-3 owner passes remain valid but do not certify this new runtime.

## Owner ambient QA — 2026-09-12

Owner confirmed both the wind-down notification and Live Activity demos worked on the physical device. This validates the explicit demo paths only—not automatic linkage to bedtime sessions, background reliability or enforcement. Owner feedback: use a normal time picker, integrate wind-down semantics with the actual bedtime flow, and separate ordinary product UI from developer controls before further polish.

No overnight/reboot or revised runtime enforcement behavior is claimed for build 4 yet.
