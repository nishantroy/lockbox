# Overnight reliability implementation review

Date: 2026-09-12
Branch: `overnight/reliability`
Scope: shared lifecycle/reconciliation contracts, the app coordinator, and the Device Activity monitor. No device deployment or device QA was performed.

## Delivered

- Added `RuntimeCallbackDecision`, the shared current-aggregate policy decision used by both callback adapters. A terminal manual callback now replays a durable clear against the live aggregate, re-applying an overlapping scheduled session instead of unconditionally clearing it. Every monitor start/end path persists the resulting apply/clear intent before Managed Settings.
- Made schedule-stop expiry atomic with its durable desired policy and changed daily-route retention to depend on enabled recurrence or a live scheduled session. Manual-only state no longer keeps the repeating registration alive; a current scheduled session keeps its natural end route.
- Added shared manual-route normalization and recovery relationship repair. A missing accepted route retires the manual session; a mismatched route becomes pending replacement without entering the enforcement aggregate. Recovery-pending and naturally expired targets remain internally consistent.
- Replaced the new fence behavior with an absolute cutoff through the frozen occurrence end. Pending current windows are suppressed, changed boundaries cannot resurrect the released window, and a genuine later same-day start is allowed. Build-3 civil-day fence data is decoded conservatively; when retained session/configuration data can provide an absolute end, it is used rather than silently dropping suppression. Otherwise the old same-day suppression remains as the safe fallback.
- Protected recovery-referenced terminal sessions and current scheduled release markers during bounded history pruning.
- Kept reconciliation failures separate from ordinary successful UI operations so later actions do not blindly clear `lastError`.

## Terra finding disposition — 2026-09-12

The latest Terra review reported one verified finding and no P0 findings:

| Finding | Disposition | Regression coverage |
| --- | --- | --- |
| **P1 normal scheduled end disables recurrence.** A natural end made `scheduledRegistrationShouldRemain` false, causing `handleScheduledEnd` to unregister the repeating daily route. | **Fixed.** The shared production decision now retains an enabled recurring route after terminal natural expiry. It still stops a disabled route, an explicitly activated replacement, or a manual-only route; a live scheduled session remains an end route when recurrence is disabled. `MonitorExtension.handleScheduledEnd` consumes this decision. | `testEnabledRecurrenceRetainsDailyRegistrationAfterNaturalExpiry`, `testPendingReplacementIsTheOnlyNaturalEndRouteStop`, and `testManualOnlyStateDoesNotKeepDailyRegistration` exercise the shared decision used by the monitor. |

The requested reliability slices are also covered in the owned production paths: terminal manual callback replay uses the current aggregate; schedule-stop expiry persists the desired clear/apply intent before OS changes and relaunch/late callbacks retire stale disabled daily routes; finite manual route matching is shared by app and monitor; absolute activation fences retain the frozen end and allow a later same-day start; bounded pruning protects recovery targets/current scheduled markers; and reconciliation errors are not cleared by a no-op foreground pass. No device QA is claimed.

## Validation

- `swift test --scratch-path /tmp/phone-lockbox-overnight-reliability-tests-3`: **75 tests passed**.
- Simulator app/extension build, no signing: `xcodebuild -project PhoneLockbox.xcodeproj -scheme PhoneLockbox -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build`: **passed**. This compiled `MonitorExtension.swift` and all shared runtime sources.
- iOS Simulator unit tests on booted `iPhone 17` (`D7081409-96E5-4F3A-9F33-47288449EC3D`): `xcodebuild -project PhoneLockbox.xcodeproj -scheme PhoneLockbox -destination 'platform=iOS Simulator,id=D7081409-96E5-4F3A-9F33-47288449EC3D' -configuration Debug -derivedDataPath DerivedData test -only-testing:PhoneLockboxTests`: **15 tests passed**. The simulator was not authorized for Family Controls; the system emitted expected authorization errors during app test launch.
- `git diff --check`: passed.

The tests include terminal manual clear with scheduled overlap, atomic natural expiry intent, manual route loss/mismatch during recovery, manual-history stress and marker protection, commitment-target pruning, before/after-midnight pending fences, next-22:00 same-day activation, legacy fence decoding, and bounded clear intent on an empty document.

## Remaining platform risks

- No physical-device QA was performed. DeviceActivity callback delivery/latency, one-shot manual end behavior across force-quit/reboot, Managed Settings persistence and authorization changes remain platform validation items.
- Screen Time category/browser coverage, DST/time-zone changes, file-protection/reboot timing, and accessibility remain unverified.
- The developer emergency reset/prototype cleanup route remains intentionally available until bounded manual release and recovery are device-validated.

## Commits

- Shared lifecycle and regression tests: `369c798` (`fix: harden shared runtime lifecycle decisions`)
- App/monitor integration: `b1b8b1e` (`fix: replay runtime policy across callback races`)
- Recurring-route retention, bounded-history hardening, and shared finite-route validation: `a1e578c` (`fix: retain recurring routes and bound runtime history`)
- App/monitor finite-route checks and sticky reconciliation errors: `232d2e2` (`fix: verify manual end routes before shielding`)
- Deferred replacement route retention: `0115c85` (`fix: keep recurring route through deferred replacement`)
- Stale disabled-route reconciliation: `e758547` (`fix: reconcile stale disabled daily routes`)
- Reconciliation-error retention rule and regression: `1cdb3de` (`fix: preserve reconciliation errors across UI actions`)
- Review record updates: `91b1355`, `2f60b21`, `3250258` (documentation-only disposition and validation updates).
