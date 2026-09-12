# Layout/runtime implementation review

Date: 2026-09-12

## Delivered

- Added finite manual-lock duration/range decisions (15 minutes through 7 days), frozen absolute-end validation, strict one-shot DeviceActivity component matching, saved-policy-only application, and conservative current/future schedule conflict rejection.
- Added dynamic active-lock title/origin, next scheduled boundaries, compact saved-rule summary, and an injectable coordinator clock.
- Added persisted ambient preferences with a distinct UserDefaults namespace. Wind-down derives its bedtime from the saved schedule, owns only the wind-down notification namespace, schedules at most seven concrete reminders, reports permission/errors separately, and never requests permission implicitly.
- Connected best-effort Live Activity reconciliation to committed foreground sessions, recovery/expiry states, stable session IDs and fixed ends. Existing activities are updated rather than duplicated; ambient failures do not alter enforcement state.
- Added focused runtime tests for duration limits, preview/transaction drift, exact registration boundaries, multi-day schedule overlap, and truthful origin copy.

## Checks run

- `swift test --scratch-path /tmp/lockbox-layout-runtime-final-tests`: **84 tests passed**.
- `swift test --package-path AmbientKit --scratch-path /tmp/lockbox-layout-runtime-ambient-tests`: **13 tests passed**.
- `xcodebuild -project PhoneLockbox.xcodeproj -scheme PhoneLockbox -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath /tmp/lockbox-layout-runtime-final-derived CODE_SIGNING_ALLOWED=NO build`: **passed**.
- `git diff --check`: **passed**.

No device deployment, notification permission request, or device schedule manipulation was performed.

## Platform gaps

- DeviceActivity's treatment of second/year components and the exact callback timing still require physical-device evidence; the strict route fails closed if the OS does not report the frozen boundary.
- Notification authorization and Live Activity behavior remain best-effort platform features and were not re-tested on-device in this source-only change.
- Parent layout integration is intentionally outside this lane; the existing prototype UI remains until the layout owner consumes the new APIs.
- Terra medium read-only review is pending; no visual or companion work was included.
