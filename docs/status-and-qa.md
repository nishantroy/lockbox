# Status and QA evidence

Updated: 2026-09-14. **Latest implementation: build 12 bounded Live Activity callback fix candidate.** Automated validation and physical-device observations are recorded separately. This page preserves earlier build evidence as historical baseline and does not treat the build-12 Live Activity result as an automatic-dismissal pass. Read with [roadmap](roadmap.md), [R1 progress](r1-progress.md), [R2/R3 QA](r2-r3-qa.md) and [safety follow-up](reviews/2026-09-10-r2-r3-safety-followup.md).

## Build-12 focused owner QA — natural-end presentation failure

Owner confirmed on installed build 12: Start bedtime now ended at the exact confirmed time, Get some rest worked, enforcement survived force-close, and tomorrow's recurrence remained. **Finding:** with the host app closed, the Live Activity did not disappear at natural end; it became stale and showed “Status may be out of date.” This is a failed automatic-dismissal observation. Foreground fallback status was not confirmed.

The current source candidate keeps enforcement/end/recurrence behavior unchanged and replaces the monitor's fire-and-forget presentation task with an exact-identity ActivityKit completion bridge bounded to 750 ms, only after durable expiry and Managed Settings replay return. The bridge is best-effort and non-authoritative; timeout, no-match, or error cannot change enforcement. Privacy-minimal result diagnostics use an isolated App Group UserDefaults namespace and are visible under Developer diagnostics. A new device run is required; no source-only compile result certifies dismissal.

## Build-3 implementation gate — 2026-09-10

- SwiftPM runtime/core tests: **56 passed, 0 failures**.
- Generic iOS Simulator build: **succeeded**, including all three extensions.
- Signed generic iOS device build: **succeeded**, version `0.1 (3)`; plist/extension metadata validation passed.
- Simulator install/launch: **succeeded**; setup UI screenshot captured at `/tmp/phone-lockbox-build3-simulator.png`.
- `git diff --check` and Markdown relative-link validation: passed.
- Build 3 was installed and launched on the paired iPhone at 19:38 local after Wi-Fi connectivity returned. No schedule was changed by the installation/launch.

## Build-3 focused owner QA — 2026-09-11

Owner reported: settings/relaunch persistence passed; Lock now displayed and persisted the saved-policy end; active edits became pending without changing the current end; delayed recovery waited 15 minutes and required explicit confirmation; future configuration remained; and, after leaving the app closed overnight, the test app was unblocked at the scheduled end with good diagnostics. Exact overnight timestamps were not recorded.

Remaining validation is broader coverage: reboot/authorization changes, browser/system/critical-app behavior, accessibility, overlap variants and the seven-night trial. See [R2/R3 checklist](r2-r3-qa.md).

## Build-2 QA update — 2026-09-10

Owner confirms settings survived migration; blocking started on schedule and rolled off at the end. Force-closing the app while locked did not remove shielding. After release, disabling recurrence and relaunching preserved settings. This is one owner-reported bounded schedule/natural-release pass, not proof of overnight/reboot reliability.

Screenshot shows registration acceptance at 15:21:55 and `intervalDidStart` at 15:23:03. It ends before the scheduled release events; no exact end timestamp or latency can be extracted. See [R1 results](r1-progress.md) for the complete transcription. No repeat of this baseline QA is needed now.

## Original build-1 assessment and evidence

**Useful feasibility prototype; not ready to rely on as a dependable overnight lock.**

The difficult initial access path—paid-team development signing, real-device installation, Screen Time authorization and useful app/category shielding—works. The remaining work is lifecycle correctness, reliable automatic release, persisted recovery and truthful operational UI, not another round of basic category-selection QA or a launcher.

| Area | Current implementation | Evidence / limit |
| --- | --- | --- |
| Native app + extensions | SwiftUI app, monitor, shield configuration/action; XcodeGen | Simulator/device builds and phone installs previously succeeded; simulator build rerun below. |
| Authorization | iOS individual authorization, refreshed on foreground | User confirmed it survives force quit/reopen. Configured dashboard is not authorization-gated yet. |
| Deny/allow selection | Persistent apps/categories/domains; category expansion enabled | User confirmed category blocking and allowlisting work on tested apps. Not proof of all system/browser paths or newly installed apps. |
| Immediate prototype lock | Direct ManagedSettings application, persisted test flag, manual clear | User confirmed lock and active button survive force quit after fix. Separate dashboard Lock now path still bypasses this flag. |
| Recurring schedule | Repeating DeviceActivity registration and start/end handlers | Owner reported that the remaining checklist items worked, including scheduled start with app closed and manual disable. Treat as provisional start/cleanup evidence; no timestamps or callback log captured. |
| Natural scheduled release | Monitor end callback calls clear | **Not demonstrated.** The checklist ended with manual disable, which does not test automatic release. |
| Session/recovery core | Standalone Codable reducer + basic time model | Seven tests pass. Not used by coordinator or monitor; important invariant/occurrence gaps remain. |
| Active-session hardening | Not implemented | No policy snapshots, persisted occurrences, overlap ownership, release markers or transactional app/extension reconciliation. |
| Recovery UI | Not implemented | Nothing new for owner to QA here until integration. |
| Product UX | Native Form with large test/picker buttons | Prototype cleanup/disable is intentionally easy, unlike planned committed-lock UX. Accessibility not validated. |
| Public distribution | Not pursued | Paid development signing works; Family Controls distribution approval is separate and not established. |

## Evidence chronology (owner reported, 2026-09-10)

1. Immediate broad shielding works; category blocking subsequently works.
2. After `includeEntireCategory: true` change, owner reported category allowance working; the remaining allow/deny tests were later reported as passing.
3. Mode and selected apps survive force quit. Initial authorization concern resolved: owner confirms authorization persists after force restart/reopen. Do not assume reinstall behavior is guaranteed by this observation.
4. Owner found active test button reset while shielding persisted. Persisting `testLockActive` and exposing cleanup fixed the reported relaunch case; owner confirmed it works. This is not cross-process reconciliation evidence.
5. Scheduled-start/manual-cleanup scenario is provisionally included in the owner's overall pass report. Exact schedule, app state, requested/observed times and latency were not captured. Prior assistant statements that no scheduled start had ever been tested were too categorical.

Device used: iPhone 15 Pro; iOS 26.6.1 per setup history. Xcode 26.6 (17F113), iPhoneOS SDK 26.5. App version 0.1/build 1 throughout the prototype, so a version label alone cannot distinguish historical installs. Future QA should identify a unique build/revision.

## Evaluation checks actually run

On 2026-09-10:

- `swift test --scratch-path /tmp/phone-lockbox-eval-core` — **7 tests passed, 0 failures**. These are pure core unit tests, not Screen Time enforcement tests.
- `xcodebuild -project PhoneLockbox.xcodeproj -scheme PhoneLockbox -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath /tmp/phone-lockbox-eval-simulator CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED**, including extension targets. Not a simulator installation/enforcement test.
- A temporary Swift probe combining the current policy source with focused calls reproduced: overnight lookup at 23:00 returns tomorrow's 22:00 start; a negative recovery delay permits immediate release; confirmation after the natural end records `released` instead of `expired`. Probe: `/tmp/phone-lockbox-eval-probe.swift`. Add permanent regression tests during R2.
- `git diff --check` passed for tracked edits; a Python check validated local Markdown links and whitespace across all nine Markdown files, including new handoff/review files. All seven extension plists/app-and-extension entitlement files parsed successfully with `plistlib`.
- Independent Sol review completed using `openai-codex/gpt-5.6-sol` (high reasoning, read-only tools); [full report and parent triage](reviews/2026-09-10-sol.md). Sol ran no builds/tests; the validation above was run by the parent agent.
- No phone build/install, lock changes or new physical-device QA were performed during this evaluation.

Historical simulator installation failure involved extension placeholder metadata; do not describe that failure as proof extensions inherently cannot install in Simulator. Physical-device testing is still required for enforcement.

## Current gaps after R2/R3 implementation

The initial R1 defects and the R2/R3 session/recovery integration have automated coverage; see [progress and follow-up reviews](r1-progress.md), [safety follow-up](reviews/2026-09-10-r2-r3-safety-followup.md) and [R2/R3 checklist](r2-r3-qa.md). Build-2 migration/scheduled-start/natural-end evidence remains historical and valid for that build only.

Remaining: physical-device callback timing and automatic release, relaunch/reboot/file-protection behavior, authorization revoke/restore, critical-app/browser/category coverage, accessibility and the seven-night trial. Developer reset remains an explicit escape hatch, not ordinary recovery.

## Bounded automatic-release experiment — completed by owner report

**Do not make the owner sit and watch for an hour.** Prepare diagnostics in R1; use a disposable denylist selection, not essential apps. Keep known manual cleanup available.

1. Clear any immediate prototype lock and disable an old test schedule. Verify the chosen test app opens.
2. Choose a same-day start a few minutes ahead and an end **20 minutes after start**. Apple's documented minimum is 15 minutes, verified in [platform research](reviews/2026-09-10-platform.md); earlier hour/90-minute suggestions were unnecessary. Record exact start/end before saving. Callbacks depend on device use, so record when the phone is used as well as requested boundaries.
3. Register successfully. Force quit Phone Lockbox before start; leave the build and configuration unchanged during the experiment.
4. Around start, briefly open the chosen app. Record the observed time and whether it is shielded. Then leave the phone and do other work.
5. After end, open the chosen app **before opening Phone Lockbox**. Record whether it opens normally and the time. Do not manually clear early if testing natural release.
6. Open Phone Lockbox to capture callback/operation diagnostics. Disable the recurring test to prevent tomorrow's recurrence.
7. If still shielded after end, record that first; use **Clear prototype lock/Clear test lock**, then **Disable recurring schedule** as needed. Foreground/manual cleanup is a fallback, not a pass for automatic release. If controls are inaccessible, iOS authorization revocation is an owner bypass to investigate/document, not a guaranteed tested cleanup claim.

Development can continue during the interval, but do not deploy to the phone until this observation is complete.

## Remaining device matrix

| Scenario | Status | Required evidence |
| --- | --- | --- |
| Immediate allow/deny categories | Owner-reported pass | Retest only after selection/policy mapping changes. |
| Selection/mode/auth/test UI after force quit | Owner-reported pass | Build-2 settings preservation and relaunch confirmed; retest only after relevant changes. |
| Scheduled start + manual cleanup, app closed | Provisional owner-reported pass | Capture exact boundaries/callback diagnostics next run. |
| Natural scheduled end, app closed | Build-2 owner-reported pass | Exact end timestamp absent from screenshot; repeat under overnight/reboot conditions later. |
| Overnight start/end | NOT TESTED | Cross-midnight transition and morning release. |
| Reboot before/during lock, first unlock | NOT TESTED | Shield/state persistence and cleanup; protected storage access. |
| Denied/revoked/restored authorization | NOT FULLY TESTED | Honest dashboard, no stale success, safe reconciliation. |
| Invalid registration / stale callbacks | Partial error observed | 10-minute attempt rejected as too short; rollback/status/late callback handling needs tests. |
| Recovery + relaunch/natural end | NOT IMPLEMENTED | Explicit wait/confirm, no same-occurrence resurrection. |
| Overlap and pending edits | NOT IMPLEMENTED | No early clearance, frozen active rules/end. |
| Clock/time-zone/DST | NOT TESTED | Separate desired local-time semantics from OS callback behavior. |
| Essential and browser coverage | NOT SYSTEMATICALLY TESTED | Critical apps, normal emergency UI access (never place a test emergency call), Safari/other browsers/embedded views as relevant. |
| VoiceOver / large text | NOT TESTED | Setup, status, errors and recovery. |

For each future run record: unique build, device/OS, requested window, app lifecycle, callback times, observed shield transitions, cleanup used, pass/fail/unresolved. Keep app choices/tokens and unnecessary personal identifiers out of the log.
