# Overnight reliability implementation review

Date: 2026-09-12
Branch: `overnight/reliability`
Scope: shared lifecycle/reconciliation contracts, the app coordinator, and the Device Activity monitor. No device deployment or device QA was performed.

## Delivered

- Added `RuntimeCallbackDecision`, the shared current-aggregate policy decision used by both callback adapters. A terminal manual callback now replays a durable clear against the live aggregate, re-applying an overlapping scheduled session instead of unconditionally clearing it. Every monitor start/end path persists the resulting apply/clear intent before Managed Settings.
- Made schedule-stop expiry atomic with its durable desired policy and changed daily-route retention to depend only on a live scheduled session. Manual-only state no longer keeps the repeating registration alive; a current scheduled session keeps its natural end route.
- Added shared manual-route normalization and recovery relationship repair. A missing accepted route retires the manual session; a mismatched route becomes pending replacement without entering the enforcement aggregate. Recovery-pending and naturally expired targets remain internally consistent.
- Replaced the new fence behavior with an absolute cutoff through the frozen occurrence end. Pending current windows are suppressed, changed boundaries cannot resurrect the released window, and a genuine later same-day start is allowed. Build-3 civil-day fence data is decoded conservatively; when retained session/configuration data can provide an absolute end, it is used rather than silently dropping suppression. Otherwise the old same-day suppression remains as the safe fallback.
- Protected recovery-referenced terminal sessions and current scheduled release markers during bounded history pruning.
- Kept reconciliation failures separate from ordinary successful UI operations so later actions do not blindly clear `lastError`.

## Validation

- `swift test --scratch-path /tmp/phone-lockbox-over-reliability-tests`: **70 tests passed**.
- Simulator app build, no signing: `xcodebuild -project PhoneLockbox.xcodeproj -scheme PhoneLockbox -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build`: **passed**.
- Monitor extension target build, no signing, using `DerivedData/MonitorTarget`: **passed**. This explicitly compiled `MonitorExtension.swift` and all shared runtime sources.
- `git diff --check`: passed.

The tests include terminal manual clear with scheduled overlap, atomic natural expiry intent, manual route loss/mismatch during recovery, manual-history stress and marker protection, commitment-target pruning, before/after-midnight pending fences, next-22:00 same-day activation, legacy fence decoding, and bounded clear intent on an empty document.

## Remaining platform risks

- No physical-device QA was performed. DeviceActivity callback delivery/latency, one-shot manual end behavior across force-quit/reboot, Managed Settings persistence and authorization changes remain platform validation items.
- Screen Time category/browser coverage, DST/time-zone changes, file-protection/reboot timing, and accessibility remain unverified.
- The developer emergency reset/prototype cleanup route remains intentionally available until bounded manual release and recovery are device-validated.

## Commits

- Shared lifecycle and regression tests: `369c798` (`fix: harden shared runtime lifecycle decisions`)
- App/monitor integration: `b1b8b1e` (`fix: replay runtime policy across callback races`)
- This review record: committed separately after recording the implementation hashes.
