# R1 integration progress — 2026-09-10

**Build 2: owner-reported migration, scheduled start/natural release and relaunch-persistence passes on 2026-09-10.** This is a successful bounded device experiment, not yet clearance for dependable overnight use. Build 2 was installed wirelessly at 12:28 local time; the owner subsequently opened and tested it.

## Delivered

- One validated App Group JSON document for saved policy, separate editable draft, prototype/scheduled ownership, interrupted-operation intent, and a bounded local diagnostic log.
- Bounded nonblocking cross-process file locking, atomic writes, durable intent before policy side effects, and explicit corruption/unavailable-storage errors. No app-only defaults fallback.
- Legacy draft/selection/test migration under the same lock as callbacks. An extension-created diagnostics-only file cannot suppress migration. Unknown legacy scheduled ownership is visibly flagged for cleanup.
- Emergency reset retains a disabled migration tombstone and clears the named settings store under the callback lock, so late callbacks cannot race reset and resurrect a forgotten shield. The route remains explicitly developer-only, including when JSON is damaged.
- Staged picker Done/Cancel, persisted draft mode/times/selection, direct picker bindings to persisted draft time, and foreground refresh of authorization, ownership and diagnostics.
- Real OS registration queries compare the registered interval and repetition with saved configuration. Replacement stops old monitoring before arming new intent. Draft save/registration success is not presented as verified blocking.
- Shared validation rejects unknown modes, invalid/empty allowlists, mismatched decoded token summaries and invalid intervals. Apple documents a **15-minute minimum**; use **20 minutes** for QA.
- Prototype tests and recurring monitoring are mutually exclusive. Ordinary test cleanup cannot clear scheduled ownership. The untracked dashboard Lock now shortcut was removed.
- Monitor guards reject disabled intent, wrong revisions, mismatched OS intervals, starts outside the current civil window, and early/stale end callbacks while a current window is live.
- Foreground reconciliation replays interrupted apply/clear intent and cleans stale scheduled ownership. Logs explicitly distinguish this fallback from automatic scheduled release.
- Core current-or-next occurrence and recovery invariants fixed; validated decoding, exact boundaries, cancellation/natural-end precedence, and DST cases tested. Core still awaits production runtime session integration.
- Neutral shield wording now fits either restriction mode and daytime tests. Generated iPhone target family corrected; QA build identity is 2.

## Parallel work and review

- Luna core worker: occurrence/recovery prerequisites and tests.
- Luna runtime worker + integration follow-up: shared state, UI/monitor integration, regression fixes.
- Luna platform researcher: [verified interval/query/availability contracts](reviews/2026-09-10-platform.md).
- Sol core reviewer: [no blocking pure-core findings](reviews/2026-09-10-core-followup.md).
- Sol runtime reviewer identified registration-replacement, reset, interrupted-operation, picker-state, migration and timeout bugs; parent fixed them with regressions. Final Sol re-review found **all six resolved for R1 QA scope and no new blockers**, independently rerunning 37 passing tests. See [review and disposition](reviews/2026-09-10-r1-runtime.md).

## Validation

Parent checks after integration:

- `swift test --scratch-path /tmp/phone-lockbox-r1-tests`: **37 tests passed** (15 core, 22 runtime/storage/reconciliation).
- Independent UTC oracle: **52,992 current-or-next cases passed**.
- Independent store probe: **8 separate processes retained all 24 updates**; not merely threads inside one process.
- `xcodegen generate` and iOS Simulator build succeeded.
- Signed physical-device build and wireless installation succeeded; launch blocked by the phone's lock screen. This is not a device-enforcement pass.
- Local Markdown links (13 files), seven plist/entitlement files and `git diff --check` validated. Core probes/builds/tests were repeated after integration fixes.

Temporary probe runners: `/tmp/phone-lockbox-boundary-oracle.py`, `/tmp/phone-lockbox-store-oracle.py`. Permanent regressions are in `CoreTests/` and `RuntimeTests/`. No Screen Time token or app-choice data is logged by these probes.

## Device QA result — 2026-09-10

Owner reports settings preserved across the update; restrictions started at the scheduled time and rolled off at the end. Force-closing Phone Lockbox while locked did not remove restrictions. After the end, disabling recurrence, force-closing and reopening preserved settings. Record these as owner-reported passes; do not ask for the same baseline again without a relevant regression.

The supplied 16:30:35 screenshot shows these local diagnostic times:
- 12:34:08 — legacy draft migration.
- 12:39:26 — immediate prototype apply intent/application.
- 12:39:27 — prototype clear intent/cleanup.
- 15:21:55 — configuration saved, registration requested and accepted by iOS.
- 15:23:03 — `intervalDidStart` received, then scheduled apply intent.

The screenshot cuts off before the scheduled end events. Natural release is supported by the owner's report, not an end timestamp in this image. Requested boundaries and exact end latency were not captured. Overnight, reboot and broader lifecycle cases remain outstanding.

Owner UX feedback: hide Request access once authorized. Implemented in source after build-2 QA; not yet installed. Operational logs remain developer diagnostics and should move out of the main product flow later.

## Completed bounded QA procedure (reference, not a new request)

Do not repeat every historical category test. The build-2 checklist was:

1. **Migration/draft:** open the update; check saved mode/selection/times. If a previous immediate test was active, use its ordinary clear control. If a legacy-registration warning appears, record it before using developer cleanup. Emergency reset deliberately clears configuration; use it only if normal cleanup cannot resolve the legacy state.
2. **Persistence/safety:** with recurring monitoring disabled, make a harmless draft edit, close/reopen, verify it persists. Check picker Cancel does not change the selection. Start/clear one immediate test if migration or test status changed.
3. **Natural scheduled release:** select a disposable nonessential denylist app/category. Save a window starting a few minutes ahead and lasting **20 minutes**. Confirm registration reports a matching OS schedule. Test start, then go do other things. After end, open the test app **before opening Phone Lockbox or clearing anything**. Record times/result, then view the callback log.
4. Disable the recurring test afterward. If apps remain blocked after end, record failure first, then use explicit developer cleanup. Foreground cleanup is not an automatic-release pass.

Do not update the installed build or modify the registered schedule during the experiment. Reboot, critical-access coverage, recovery UI, overlaps and seven-night use belong to later gates—not this quick QA request.

## Remaining work

- R2 production occurrence identity, frozen policy/end snapshots, released-occurrence suppression, manual-session finite ends, full crash/reboot/file-protection semantics, and shared core/monitor occurrence logic (currently runtime gating has a separate small resolver).
- R3 actual delayed recovery UI and immutable active-rule/pending-edit behavior. Current developer cleanup intentionally bypasses commitment rules.
- Automatic scheduled end now has one owner-reported bounded-test pass. Repeated/overnight behavior, reboot, authorization revoke/restore, category/browser/system coverage and accessibility still need real-device evidence.

Continue via [roadmap](roadmap.md). Do not call R2/R3 complete merely because R1 now persists ownership and intent.
