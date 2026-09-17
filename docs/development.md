# Developer runbook

## Source of truth

- `project.yml` generates `PhoneLockbox.xcodeproj` with XcodeGen; keep build/signing/capability changes in YAML.
- `PhoneLockbox/ScreenTimeCoordinator.swift`: authorization, persistence, registration, direct shielding, Safety Assistant input and navigation-only Quick Action delivery.
- `PhoneLockbox/ContentView.swift`: setup/dashboard and three-tab product shell.
- `PhoneLockbox/Policy/LockboxPolicy.swift`: standalone core; compiled into app and Swift package, **not currently into monitor**.
- `Shared/`: app/monitor runtime contracts, transactional JSON storage, callback gates and interrupted-intent reconciliation decisions; also compiled as `PhoneLockboxRuntime` for host tests.
- `Extensions/DeviceActivityMonitor/MonitorExtension.swift`: validated, ownership-gated callbacks with durable apply/clear intents and local diagnostics.
- `Extensions/ShieldConfiguration`, `Extensions/ShieldAction`: system shield presentation and close action.
- `PhoneLockbox/QuickActions/`: canonical navigation routes, App Intents, bounded App Group queue, delivery gate and lease-retry broker. These paths do not mutate enforcement or confirm recovery.
- `PhoneLockbox/Policy/WeekendSchedule.swift`: reviewed pure weekday/weekend scheduling model; not connected to production registration/storage.
- `PhoneLockbox/Policy/TaskUnlock.swift`: reviewed pure finite task-commitment model; not connected to providers, UI or enforcement.
- `Shared/SafetyAssistant.swift` and `PhoneLockbox/Views/SafetyAssistantView.swift`: local privacy-minimal safety review.
- `CoreTests`, `RuntimeTests` and `PhoneLockboxTests`: pure core/runtime and iOS integration tests.

Current deployment target: iOS 17, Swift 6. Build 15 is the latest installed QA candidate; its reviewed source integrations have not yet received focused behavioral/device acceptance. Actual oldest-OS runtime/API compatibility has not been validated. Build machine: Xcode 26.6 / iPhoneOS SDK 26.5. No backend, HTTP listener, dependency port or signing secret is needed in the repository.

Development signing uses the paid team already specified in `project.yml`. App Group: `group.com.phone-lockbox`. App bundle: `com.phone-lockbox.app`; three extension identifiers are specified in YAML. Do not change identifiers casually—this can invalidate the device test baseline and storage/provisioning assumptions.

## Build and test

```bash
xcodegen generate
swift test
xcodebuild -project PhoneLockbox.xcodeproj -scheme PhoneLockbox \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Use separate derived data from SwiftPM's `.build/`; do not repeatedly delete caches. A simulator build does not demonstrate Screen Time enforcement. For iOS unit-test execution, discover a valid simulator with `xcrun simctl list devices available`, then use its ID with `xcodebuild ... test`. Do not reuse guessed simulator IDs.

Review new/untracked sources as well as `git diff`. Most app implementation remains untracked at this handoff; no reset/clean or blind staging of build artifacts.

## Physical-device deployment (wireless supported after pairing)

```bash
xcrun devicectl list devices
xcodebuild -project PhoneLockbox.xcodeproj -scheme PhoneLockbox -showdestinations
```

Choose the paired iPhone's CoreDevice ID for devicectl and its Xcode destination UDID for xcodebuild. These are different identifiers. If unavailable, ask owner to unlock/check network or connect; don't recreate signing accounts or change system settings.

```bash
# Substitute IDs returned above.
xcodebuild -project PhoneLockbox.xcodeproj -scheme PhoneLockbox \
  -destination 'platform=iOS,id=<Xcode-device-UDID>' \
  -configuration Debug -derivedDataPath .build-device \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device '<CoreDevice-ID>' \
  .build-device/Build/Products/Debug-iphoneos/PhoneLockbox.app
xcrun devicectl device process launch --device '<CoreDevice-ID>' com.phone-lockbox.app
```

Check each exit status. Installation can succeed while launch fails because the phone is locked; report those separately. A transient wireless timeout is not a compiler/signing defect. No new deployment is needed for documentation-only changes. Never reinstall mid scheduled-release experiment.

Increment `CURRENT_PROJECT_VERSION` for the next device QA build and record the revision alongside it. Build 15 installed and launched successfully on 2026-09-17; do not convert that delivery result into feature or reliability acceptance.

## Review and continuation

- [Roadmap](roadmap.md) defines next tasks and gates.
- [R1 progress](r1-progress.md) gives the current implementation and focused QA; [status/QA](status-and-qa.md) preserves earlier device evidence.
- [Sol review](reviews/2026-09-10-sol.md) covers the whole working tree at handoff.
- Use local privacy-minimal diagnostics, not remote analytics or raw app-token dumps.
- Preserve a tested developer cleanup route until bounded sessions and automatic release are proven. Do not claim the current immediate test or dashboard Lock now has an automatic end.
