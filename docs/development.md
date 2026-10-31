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

Current deployment target: iOS 17, Swift 6. Build 22 (from `r5-relay` at 12bc414, 2026-10-31) is the latest QA candidate: pairing v3 — a ~50-character invite link, the friend taps Accept and is paired (no owner confirm, no permission switches), real names, a one-time "‹Name› joined" notice, People auto-refresh, and a checkmark list for Ask to end early. The production relay runs v3; builds ≤21 can no longer pair. R5 friend-approval release stays developer-gated. App unit/UI suites for this build were not run (compile-only; they run before the next push).

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

## Companion pairing UI test (`PhoneLockboxUITests`)

`PhoneLockboxUITests` (XCUITest) drives the owner side of companion pairing in the simulator against a **local** relay, with a scripted in-process "friend" (a fresh, in-memory `CompanionKit` identity — see `tools/relay-smoke` for the pattern it mirrors). It needs a running local relay, so it is listed in the `PhoneLockbox` scheme's test action but marked `skipped = YES` there (review P2-4): a bare `xcodebuild test -scheme PhoneLockbox` (or Xcode's own Product > Test) runs only `PhoneLockboxTests` and never needs the relay. Run the UI tests deliberately with `-only-testing:PhoneLockboxUITests`, which overrides the scheme's skip:

```bash
lsof -nP -iTCP:8002 -sTCP:LISTEN          # confirm the port is free first
cd relay
npm install                               # first run only
cp .env.example .env                      # first run only
npm run db:migrate                        # Postgres on 56330; `npm run db:start` first if it isn't running
npm run dev                                # leave running in this shell/process
```

Then, from the repo root, with a booted simulator (discover its ID with `xcrun simctl list devices available`; do not reuse a guessed ID):

```bash
xcodegen generate
xcodebuild -project PhoneLockbox.xcodeproj -scheme PhoneLockbox \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -configuration Debug -derivedDataPath DerivedData \
  -only-testing:PhoneLockboxUITests \
  -resultBundlePath <path>.xcresult \
  test
```

The app under test is launched with two DEBUG-only launch arguments, read once at launch by `CompanionCoordinator`: `-relayBaseURL http://127.0.0.1:8002` (so the test needs no interaction with the Developer settings screen to point the app at the local relay) and `-resetCompanionStateForUITests` (clears this app's companion Keychain identity, App Group keys and rollback anchors before the coordinator initializes, so each run is independent of whatever a previous — possibly interrupted — run, or another process sharing the same local relay's Postgres, left behind; otherwise a genuine relay-state regression is correctly, but unhelpfully for a test, reported as `CompanionError.relayRollback` against a stale identity's leftover anchor). Stop the relay dev server (`Ctrl-C`, or kill the background process) once the run finishes — it is local-only infrastructure, not something to leave running.

The tests attach `XCTAttachment` screenshots (`lifetime: .keepAlways`) at key steps. Export them from the result bundle:

```bash
xcrun xcresulttool export attachments --path <path>.xcresult --output-path <output-dir>
```

This writes each attachment plus a `manifest.json` describing them into `<output-dir>`.

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

Increment `CURRENT_PROJECT_VERSION` for the next device QA build and record the revision alongside it. Build 21 was built on 2026-10-02 and installed on the iPhone 17 simulator. For the iPhone install status, see the R5 docs.

## Review and continuation

- [Roadmap](roadmap.md) defines next tasks and gates.
- [R1 progress](r1-progress.md) gives the current implementation and focused QA; [status/QA](status-and-qa.md) preserves earlier device evidence.
- [Sol review](reviews/2026-09-10-sol.md) covers the whole working tree at handoff.
- Use local privacy-minimal diagnostics, not remote analytics or raw app-token dumps.
- Preserve a tested developer cleanup route until bounded sessions and automatic release are proven. Do not claim the current immediate test or dashboard Lock now has an automatic end.

## Worktree builds and cleanup

Builders and reviewers in git worktrees keep all build output outside the worktree, under `/Users/nishantroy/code/.build-cache/phone-lockbox/<worktree-name>/`, one folder per worktree:

```bash
C=/Users/nishantroy/code/.build-cache/phone-lockbox/$(basename "$PWD")
xcodebuild ... -derivedDataPath "$C/DerivedData" ...
swift test --scratch-path "$C/spm-root"
(cd CompanionKit && swift test --scratch-path "$C/spm-companionkit")
```

When a slice merges, the parent removes the worktree (`git worktree remove --force <path>`; the branch stays) and its cache folder. `tools/worktree-cache-report.sh` lists worktrees, sizes, unmerged commits and orphaned cache folders without deleting anything.
