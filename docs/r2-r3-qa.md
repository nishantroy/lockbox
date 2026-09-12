# R2/R3 validation checklist

Status: automated R2/R3 gates passed for build 3; focused physical-device acceptance remains pending. **No new device behavior or deployment is claimed by this checklist.** See [work contract](r2-r3-work-contract.md), [safety follow-up](reviews/2026-09-10-r2-r3-safety-followup.md) and [roadmap](roadmap.md).

## Automated gates before asking the owner

- R1 persisted state migrates without losing saved/draft selections, existing prototype ownership, registration intent or the developer cleanup route.
- Scheduled occurrence identity survives relaunch and duplicate callbacks; terminal/recovered occurrences do not resurrect after save/disable/re-enable.
- Active policy and absolute end are frozen. Ordinary draft edits/disable cannot weaken a committed current session.
- Finite manual lock is applied only with a registered/supported automatic-release route. A failed registration leaves no indefinite new shield.
- Overlap is combined conservatively where supported; unsupported overlap is explicitly rejected. An end/release never clears another live session's policy.
- Recovery request targets immutable active session IDs and waits 900 seconds. Repeated request cannot accelerate eligibility. New sessions outside that set cannot be released by the old request.
- Confirmation rechecks time/current targets inside the storage transaction. Natural end wins; no automatic release merely because recovery becomes eligible.
- Cancellation removes only the commitment; requesting again waits a fresh 900 seconds.
- Interrupted apply/release/re-registration has a deterministic replay/cleanup path. Reset serializes with callbacks and leaves a durable tombstone.
- Future scheduling survives recovery and developer unlock; emergency reset remains an explicit all-state escape hatch.
- UI display/confirmation uses the same state/end as enforcement and reports unavailable authorization/failed scheduling honestly.

The first Terra medium snapshot review found and drove fixes for bounded history and recovery relationships; category-token criticism was triaged against prior picker expansion/device evidence. A final independent review is still required before treating device QA as release evidence.

## Owner QA update — build 3

- Existing settings survived installation and relaunch.
- Finite **Lock now** showed the saved-policy confirmation and its committed end survived force-close/relaunch.
- Editing bedtime settings during that active lock produced pending changes while the original active end remained unchanged across relaunch.
- Recovery request waited 15 minutes; after reopening Phone Lockbox, explicit **End this lock** confirmation released the current lock successfully.
- Future configuration remained present.
- After leaving Phone Lockbox closed overnight, the owner confirmed the disposable test app was unblocked at the scheduled end and diagnostics looked good. This is the first owner-reported build-3 natural-expiry pass; exact timestamps were not recorded.

## Focused human QA after build/review

Use a disposable nonessential block selection, not critical utilities. Do not rerun every basic category-selection test. This is a regression of new lifecycle behavior, not a retraction of the successful build-2 scheduled-start/end result.

1. **Migration and developer escape:** confirm existing settings survived. Locate the developer unlock/reset controls before committing. Use only if normal cleanup is unavailable or to finish a deliberate test; distinguish that from automatic release evidence.
2. **Bounded Lock now:** verify the confirmation shows a real future end and the active screen agrees. Force-quit/reopen; the same session/end must remain. A separate test observes its natural end before opening Lockbox.
3. **Committed rules:** during an active test session, edit a selection/window or disable recurrence. The existing restriction and its original end must remain; the UI must clearly describe pending/future behavior.
4. **Recovery:** request recovery, leave the app, confirm it is unavailable early, then explicitly release once eligible. Verify blocked apps reopen and future nights remain configured. No need to watch a countdown.
5. **Natural end during waiting:** request recovery near the ordinary end. The schedule must release naturally without waiting another 15 minutes or requiring recovery confirmation.
6. **Overlap (if supported):** start a manual lock before a scheduled interval. Confirm ending/releasing one does not weaken the other. If rejected, the UI must explain the unsupported overlap before applying a new policy.

Record unique build, intended/observed boundaries, active origins, recovery request/eligibility/confirmation, whether the app was closed, and whether developer cleanup was used. Never count foreground/manual cleanup as an automatic-release pass.

Overnight/reboot, time-zone manipulation, critical-access/browser coverage, accessibility and the seven-night trial follow these initial lifecycle/recovery checks. Visual polish is a separate conversation, not part of this implementation batch. Build 3 is signed and ready for installation when the paired iPhone is available.
