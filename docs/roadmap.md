# Execution roadmap — Luna handoff

Updated: 2026-09-11. **Current milestone: R2/R3 implementation is integrated and passed an initial focused build-3 device QA pass.** Automated tests, signed build, Lock now persistence, pending edits, delayed recovery and overnight natural expiry all have evidence. Broader lifecycle/reboot/accessibility coverage remains. See the [swarm work contract](r2-r3-work-contract.md) and [acceptance checklist](r2-r3-qa.md). Not yet a dependable bedtime MVP. See [R1 implementation/QA handoff](r1-progress.md).

## Start here

1. Read [status and QA evidence](status-and-qa.md), [Sol review](reviews/2026-09-10-sol.md), and this file.
2. Read [technical plan](technical-plan.md) and [interaction design](interaction-design.md) for intended behavior. They are specifications, not completed work.
3. Inspect the full working tree: most implementation files are currently untracked. `git diff` alone misses them. Do not reset or discard them.
4. Work through R1 → R2 → R3 → R4. Start the R1 device experiment when ready; continue core implementation while it runs. Do not wait for a nightly trial to write tests.
5. Record each completed slice, exact checks, remaining risks, and next action here and in the QA log. Keep user QA narrow: only behavior that changed or lacks evidence.

**Next action:** Sol/final integration review, then continue narrowly scoped device coverage: reboot/relaunch, authorization revoke/restore, critical-app/browser/category paths, accessibility and the seven-night trial. Build-2 baseline and build-3 lifecycle evidence are recorded; do not repeat passed tests without a relevant change. R1 status/diagnostics, storage ownership, intent replay and R2/R3 invariants are implemented; they do not substitute for broader platform evidence.

No further product questionnaire is needed. The user wants autonomous progress. Interrupt for device/system prompts, an actual platform limitation, critical-access verification, or a material product decision—not configurable bedtime times or app choices.

## Current scope and constraints

- Native SwiftUI, local only, one daily configurable window, individual Screen Time authorization.
- Keep both **Block selected** and **Allow only selected**, with whole-category selection. Category allowance is currently an expansion to app/domain exceptions; do not claim automatic coverage of future installed apps without testing.
- Quiet UI, full-row tap targets, visible feedback, no engagement mechanics.
- Recovery: provisional 15-minute wait + explicit confirmation. Waiting alone never unlocks. Natural end wins. Cancellation and re-request begin a new full wait.
- Real manual locks must have confirmed finite ends. The existing immediate prototype test is intentionally manually cleared and is not the finished Lock now feature.
- No casual temporary unlock. Pending edits/disable affect future locks, not the current committed occurrence.
- Maintain a tested developer cleanup route until automatic release is validated. Do not remove the prototype escape hatch before its replacement is safe.
- **Midnight Original** is the selected production visual direction; its current implementation remains a source QA candidate, not device-passed evidence. **Start bedtime now** is integrated as a bounded runtime/UI source candidate and still requires the validation gates below; no device pass is implied.
- Launcher/widgets, NFC, weekday profiles, distribution, and cosmetic redesign are deferred.

## R1 — Honest operational state and observable scheduling

**Goal:** distinguish saved configuration, registered monitoring, requested shielding, observed callbacks, and unavailable authorization. Make the next device test diagnostic rather than another vague pass/fail.

Work:
- Replace save-then-register success UI with one explicit operation and result. A draft may persist on failure, but must not appear armed. Restore/reconcile registration from DeviceActivity's supported registration queries; a flag reset on launch is not OS truth.
- Validate authorization and selection in service methods, not just disabled SwiftUI controls. Gate configured dashboards too; refresh on initial display/foreground and permission changes as supported.
- Add bounded, local, privacy-minimal diagnostics: requested interval, registration attempt/result, callback name/start/end/time, state revision, policy apply/clear attempt. No raw tokens or app identifiers.
- Share the mode/selection validation and policy mapping between app and monitor. Decode failures/unknown modes must surface a problem, not silently broad-block everything or clear another live session.
- Clearly separate test/manual and scheduled ownership. While the full model is pending, prevent simultaneous prototype tests and recurring enforcement rather than allowing either to clear the other's shield.
- Remove or route the dashboard's separate `Lock now → applyImmediateShield()` path: today it bypasses even the persisted test flag.
- **Verified:** Apple documents a 15-minute minimum, with usage-dependent callbacks; see [platform research](reviews/2026-09-10-platform.md). R1 preflights civil duration but OS registration remains authoritative. Use a 20-minute QA interval, not an hour/90-minute assumption.
- Correct target-level device-family configuration: `project.yml` requests iPhone at project level, but generated app targets override it with `1,2`. Set the intended family at the appropriate target level, regenerate, and inspect effective build settings. Do not change signing identifiers.

Acceptance:
- Tests cover failed registration, denied/revoked authorization, relaunch with registered monitoring, invalid/empty selection, corrupted shared data, and manual/schedule conflicts.
- UI never shows green protection merely because a draft exists. Application success is labelled as a request/last operation, not proof every app is blocked.
- One safe scheduled-start/end experiment has actual requested and observed times recorded. Natural end is checked **before opening Phone Lockbox** or touching cleanup.
- Device test can run while coding continues; do not reinstall the app or change the schedule during the experiment.

**Gate:** automatic scheduled release remains a prerequisite to a real nightly trial. R2 may proceed before this gate passes, but a failed release is a blocker, not a reason to substitute a foreground timer.

## R2 — Shared persisted lifecycle and reconciliation

**Goal:** replace independent booleans/direct clears with one small, testable session authority used by app and monitor.

Work in small slices:
1. Fix occurrence resolution first. Specify a current-or-next half-open interval `[start, end)`; cover exact start/end, same-day active time, overnight evening/morning, disabled configuration, DST skipped/repeated times, and time-zone changes. Current `nextOccurrence` skips the active evening and same-day window.
2. Harden reducer invariants: finite positive policy-approved delay (production default 900 seconds, not caller-controlled); valid date ranges; natural expiry before recovery confirmation/cancellation; consistent session/recovery identity; validated decode. Eligibility can be derived—no background countdown state needed.
3. Add stable occurrence identity, frozen selection/mode/end snapshot, schema/revision, release markers and operational metadata. A random new UUID per callback cannot suppress duplicate starts. `policyRevision` alone is not a policy snapshot.
4. Choose and document a small App Group transactional storage strategy (e.g. coordinated atomic file updates). Atomic replacement alone does not serialize competing read/modify/write operations. Do not treat separate UserDefaults keys as a transaction or an actor as a cross-process lock.
5. Put shared core/adapters in both app and monitor targets via `project.yml`. Today the policy file is not compiled into the monitor. Consolidate duplicated test sources or otherwise ensure one maintained suite exercises the same core.
6. Implement idempotent reconciliation on callbacks and app launch/foreground. Validate time, occurrence/revision and release markers; persist intent before side effects; recover from interruption between them. Expire stale sessions; never blindly clear an entire store for one callback.
7. Handle bounded manual/scheduled overlap explicitly: ending/recovering one cannot clear another's restrictions. Use a documented store-ownership/composition strategy and test mixed deny/allow policies. If overlap is deferred, reject it explicitly and update the product behavior rather than shipping accidental overlap.
8. Migrate prototype settings and `testLockActive` safely. Do not reinterpret an old indefinite test as a production committed session; show a migration/cleanup state. Fail clearly on inaccessible shared storage rather than falling back silently to app-only defaults.

Acceptance:
- Tests cover boundary resolution, stable identity, duplicate/late/out-of-order callbacks, recovery suppression, stale end callbacks, overlaps, two writers, corrupt/versioned storage, and crash points between persisted intent and policy application.
- Relaunch derives a consistent UI from durable state; no `Lock now` route bypasses persistence.
- Revocation/restoration is orthogonal to lifecycle. Restoration cannot extend or resurrect a released occurrence.
- Device smoke: force quit during a lock and a recovery request; state remains consistent after reopening. Reboot before/after first unlock must be separately recorded, not inferred.

## R3 — Recovery and active-session UX

**Depends on R2**, not merely the existing seven reducer tests.

Work:
- Integrate request → waiting → eligible → explicit release; recheck eligibility and natural expiry on confirmation.
- Display the eligibility clock time; user can leave the app. No second-by-second countdown or required notification.
- Recovery identifies the effective current lock/occurrences it ends, preserves future schedules, and persists release suppression before clearing/reconciling owned restrictions.
- Active view shows frozen end and known operational health. Queue mode/selection/schedule relaxations, conservatively deferring all edits if stronger/weaker comparison cannot be proven.
- Disable recurring schedule affects future nights only while committed. Keep developer cleanup clearly separate from the normal product UI.
- Implement bounded Lock now confirmation and OS-managed end/reconciliation. No indefinite production locks.
- Make shield copy correct for block mode, allow mode and manual locks; only show end time if available and trustworthy through supported extension storage/API.

Acceptance:
- Early confirmation fails; duplicate taps never accelerate recovery; relaunch retains eligibility; cancellation/re-request waits again; normal end wins; release never reblocks the same occurrence.
- Current-session edits cannot weaken it, even through disable/re-enable or schedule revisions. Pending changes activate at a defined boundary without immediately recreating a recovered lock.
- Device recovery test passes with app closed during the wait. A shortened test delay may exist only in an unmistakable developer path; production delay remains enforced.

## R4 — Reliability gate and seven-night trial

Work:
- Run [QA matrix](status-and-qa.md): natural end, overnight, force quit, reboot, authorization revoke/restore, registration failure, stale state/cleanup, clock/time-zone behavior, essentials and browser coverage, recovery, overlaps/pending edits.
- Check VoiceOver, Dynamic Type, contrast, and full-row controls across setup/status/recovery.
- Only after release/cleanup and critical access are proven, begin seven-night personal trial; keep reflection outside bedtime.

Acceptance:
- No unresolved high-severity lifecycle/release findings; documented platform limits and tested cleanup route.
- Automatic release works without opening the app under the recorded test conditions. Failures are not silently reclassified as passes because foreground cleanup worked.
- Trial evidence records reliability and usefulness without collecting sensitive app choices or telemetry.

## R5 — Production trusted-person relay and identity lifecycle (future prerequisite)

This begins only after the R4 reliability gate. The existing same-app companion/pairing foundation and relay simulations are useful for protocol exploration, but they are not a deployed service and the in-memory core is not production-ready.

Work:
- Replace simulations with the real PostgreSQL adapter, authenticated transport, durable server inbox/fetch, and explicit identity/key lifecycle.
- Preserve accountless companion use where approved, but require explicit pairing, sender/recipient consent, per-person revocation, re-pairing, and cross-owner isolation. APNs/text may wake or remind only; they are never approval credentials or authoritative delivery.
- Persist and reconcile a bounded, idempotent outbox without making recovery or emergency access depend on network delivery. Define bounded retention/deletion and offline, reinstall, and clock-rollback behavior.

Acceptance:
- Deployed-path tests prove authentication, identity lifecycle, revocation, cross-owner isolation, server-authoritative fetch, duplicate/late delivery handling, and emergency/network independence.
- No ordinary UI claims that a local demo or in-memory implementation is a production relay. Any failed infrastructure or security gate keeps accountability deferred.

## R6 — Opt-in accountability (future, after R5)

Build the owner-approved capability only after R5. The owner selects accepted trusted people individually and separately consents to event notices and optional weekly summaries. Record the exact-session terminal event locally before ordinary recovery or trusted release clears policy; queue it offline with a stable idempotency key. Use supportive “ended early” language and distinguish natural end, recovery, trusted approval, authorization loss/integrity warning, and developer/emergency cleanup.

Share no app selections, app/site usage, messages, or raw schedules by default. Weekly summaries contain only planned, naturally completed, ended early, and unavailable/integrity-unknown counts/statuses, with no streaks, scores, rankings, or shame. Quiet hours, generic notification previews, cancellation/late delivery, recipient opt-out, retention/deletion, multiple approvers, one-way/mutual independence, and reinstall/clock limitations are part of the feature contract. The server inbox/fetch remains authoritative; APNs/text remain wake/reminder hints. See [accountability design](accountability-design.md).

Acceptance gates are specification-level tests for exact-session binding, idempotent delivery, offline queue/retry, no duplicate weekly counts, revocation, cross-owner isolation, quiet hours, classification, approval/recovery races, reinstall/clock rollback, privacy payload inspection, and accessibility/copy. Product QA must exercise the deployed PostgreSQL/authenticated path and identity lifecycle before exposure. Do not widen the existing local recovery flow or claim tamper-proof accountability when the device is locally controlled, reinstalled, or offline.

## R7 — Polish, then optional expansion

After R6 (or an explicit decision to defer it): replace bare Form layout with the calm visual design, then separately evaluate launcher/widget, NFC recovery, daytime features, and distribution entitlement/provisioning renewal. Do not bundle these with lifecycle or accountability work.

## Sol review disposition

| Finding group | Disposition / destination |
| --- | --- |
| Invalid allow-only selection, unknown mode | Verified safety risk. R1 shared validation before further enforcement features. |
| Misleading registration/auth/test state, untracked Lock now, conflicting test/schedule controls | R1 immediate containment; R2 replaces flags with lifecycle state. |
| Unbounded manual lock, unconditional clears, overlap, mutable active selection, absent runtime recovery | Known prototype concessions / MVP blockers. R2 ownership and snapshots, then R3 committed UX; keep developer cleanup until safe replacement. |
| Current-occurrence resolver, recovery expiry/delay invariants | Verified latent defects, reproduced by parent probe. R2 fix/test before integration. |
| App Group fallback, corruption and concurrent writers | R2 transactional shared state; R1 should already report invalid data honestly. |
| Incorrect shield copy / count / website-only messaging | R3 UX, with neutral truth-preserving copy appropriate earlier. |
| Generated device-family override | Verified configuration defect; R1 focused YAML/generated-settings correction. |
| Stale status docs | Corrected by this handoff. Sol report preserved as review snapshot. |
| Natural end, browser coverage, DST/time zone, reboot/platform behavior | Validation gates, not claims of proven platform failure. R1 experiment + R4 matrix. |

## Review and delivery discipline

- Sol's independent review: [2026-09-10 report](reviews/2026-09-10-sol.md). Prioritize its verified high-severity findings within R1/R2; treat API hypotheses as investigations.
- See [developer runbook](development.md) for build/install commands. Do not delete build directories between every incremental build.
- Run focused tests plus an iOS build after code changes; `swift test` alone cannot validate extensions or enforcement.
- Record real-device QA separately from compile/test passes. Increment build identity for future QA so reports identify the installed version.
- Inspect generated project changes after `xcodegen generate`; preserve team/capability settings in `project.yml`.
- Before an implementation commit, inspect all untracked source and generated files for secrets/artifacts; checkpoint coherent work without destructive cleanup. No app code is changed by this evaluation/handoff.

## Handoff checklist

- [x] Current evidence and unresolved gates documented.
- [x] Next implementation and dependency order explicit.
- [x] Core tests and simulator build rerun for evaluation baseline.
- [x] Independent Sol review completed, saved, and triaged into R1–R4.
- [x] R1 diagnostics/registration/shared-ownership slice implemented; 37 automated tests and simulator/signed builds pass. Owner reports build-2 migration and bounded schedule/relaunch regression passed.
- [x] R2 pure-core occurrence/recovery prerequisites fixed and reviewed; not yet the production runtime engine.
- [x] Natural scheduled end observed in the bounded test by owner report; supplied screenshot confirms start only, exact end timestamp not captured. Overnight/reboot matrix remains open.
- [ ] R2 persisted reconciliation integrated in app and monitor.
- [ ] R3 recovery and immutable active-session UX integrated.
- [ ] R4 reliability gate and nightly trial complete.
