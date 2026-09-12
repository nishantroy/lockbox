# Layout UI review — 2026-09-12

## Delivered

- Replaced the single dashboard entry point with native **Lockbox / People / Settings** tabs. People remains reachable without Screen Time authorization.
- Kept initial authorization, staged FamilyActivityPicker Done/Cancel behavior, draft time persistence, and explicit schedule save in the setup/editor flow.
- Moved schedule and restriction editing out of the normal Lockbox dashboard and into Settings.
- Added an adaptive native Lockbox presentation for setup, unlocked, and active states. The active state presents a fixed end, origin title, pending changes, and Recovery navigation without a countdown or routine clear action.
- Added a sheet-based Lock now review with 30-minute default, one-hour, and custom end choices, an immutable proposed end, saved-policy summary, and explicit confirmation/cancellation.
- Added an honest People page: same-app/accountless pairing intent, exact-lock intent, private selections, and an explicit “remote service not connected” status. No simulated relationships or approvals are presented.
- Added Settings recovery, wind-down, and best-effort Live Activity preference structure, with developer controls and human-readable diagnostics isolated at the bottom.
- Tidied Recovery without changing the fixed 15-minute wait, explicit release confirmation, cancellation, natural-end safeguards, or error presentation.

## Validation

- `git diff --check`
- Swift parser inspection for `PhoneLockbox/ContentView.swift`, `PhoneLockbox/RecoveryView.swift`, and all new `PhoneLockbox/Views/*.swift` files.

No device deployment, schedule change, or visual/device QA was performed for this source-only layout pass.

## Integration expectations

This branch intentionally does not modify `ScreenTimeCoordinator.swift` or shared/runtime code. The layout references the runtime-lane API contract for:

- `manualLockProposedEnd(after:at:)` and `startManualLock(expectedEnd:)`
- `windDownEnabled`, `windDownLeadMinutes`, `liveActivitiesEnabled`, and `ambientStatusMessage`
- `requestWindDownAuthorization()`, `setWindDownEnabled(_:)`, `setWindDownLeadMinutes(_:)`, and `setLiveActivitiesEnabled(_:)`
- `activeLockTitle`

Those APIs are not present in this branch at the time of the source-only pass. Parent integration must provide them without adding UI-side coordinator duplicates. The manual-lock runtime must interpret the selected duration/custom end, revalidate the absolute proposed end, reject conflicts, and freeze the saved policy before applying it. Wind-down must derive from the saved bedtime start and notifications/Live Activities must remain presentation-only. The existing ambient standalone screen remains developer-only and is not used as the normal Settings implementation.
