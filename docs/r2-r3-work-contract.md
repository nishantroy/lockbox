# R2/R3 swarm work contract — 2026-09-10

Status: implementation in progress. No deployment during this batch. This document fixes the shared interface so the reliability and recovery workers can proceed without concurrent edits to the same files.

## Ownership

- Reliability (Luna xhigh): `Shared/` EXCEPT `Shared/RecoveryCommitment.swift`; coordinator; monitor; policy core and its existing tests; `RuntimeTests/` EXCEPT `RecoveryCommitmentTests.swift`; Package.swift/project.yml/generated project. Own all enforcement/persistence integration.
- Recovery (Luna high): `Shared/RecoveryCommitment.swift`, `RuntimeTests/RecoveryCommitmentTests.swift`, `PhoneLockbox/RecoveryView.swift`, `PhoneLockbox/ContentView.swift`. No direct ManagedSettings or storage side effects; call coordinator methods below.
- Parent: integration, docs/roadmap, build validation; no worker-owned edits until ownership released.
- Terra medium: read-only correctness review after integration.

## Recovery commitment contract (recovery worker implements first)

Foundation-only `public struct RecoveryCommitment: Codable, Equatable, Sendable`:
- `public static let delay: TimeInterval = 900` (fixed product delay, no caller-supplied shortening).
- Immutable `sessionIDs: Set<UUID>`, `requestedAt: Date`, `eligibleAt: Date`.
- `public init(sessionIDs: Set<UUID>, requestedAt: Date) throws` validates nonempty target set and finite times.
- `public func isEligible(at date: Date, activeSessionIDs: Set<UUID>) -> Bool` is true only after delay, for a nonempty active set contained in the original target set. New active sessions must not be released using an old commitment. Natural expiry may reduce the active set.
- Validated decode must enforce exact configured delay (reject edited eligibility or empty targets), not just eligibility > request.
- Cancellation is represented by removing the commitment in the owning runtime transaction. Wall-clock/clock-manipulation limitations remain explicit; do not promise tamper-proof time or a background wake.

Reliability worker compiles this shared file into app, monitor and host tests, adds optional commitment to the durable runtime document, owns request/cancel/confirm transactions, and persists release markers before applying the resulting owned policy. Neither worker should change this interface silently; record any necessary change for parent integration.

## Coordinator contract (reliability worker implements; recovery/UI consumes)

Keep existing R1 configuration/diagnostic/authorization interfaces unless correctness requires a coordinated change. Add:

- `var hasActiveLock: Bool { get }`
- `var activeLockEnd: Date? { get }` — maximum end of effective unreleased sessions, not prototype-test fiction.
- `var activeSessionCount: Int { get }`
- `var hasRecoveryRequest: Bool { get }`
- `var recoveryEligibleAt: Date? { get }`
- `var pendingChangesSummary: String? { get }`
- `var manualLockProposedEnd: Date? { get }` — a supported finite end to preview; nil if unavailable.
- `func canConfirmRecovery(at: Date) -> Bool`
- `func requestRecovery()` / `func cancelRecovery()` / `func confirmRecovery()` — revalidate inside shared lock, never trust UI eligibility alone.
- `func startManualLock(expectedEnd: Date? = nil)` — uses saved confirmed policy and the displayed supported future end; UI supplies its captured preview end. Reject changed previews/conflicts rather than silently weakening another occurrence. The default argument preserves no-argument compatibility during integration.
- `func developerUnlockNow()` — deliberately named/debug-only immediate release route; persist suppression for released current occurrences and preserve future schedules. Keep existing `emergencyReset()` as ultimate corruption cleanup.

Methods remain MainActor/synchronous coordinator actions as in R1; expose observable state updates through existing Published properties/refresh. RecoveryView may use TimelineView at a quiet coarse cadence to derive eligibility; it must not enforce policy using a timer or auto-unlock when the wait expires.

## Required lifecycle semantics

- Persist stable scheduled-occurrence identity, frozen policy/end and terminal release state. A duplicate callback cannot create a fresh active UUID for a recovered occurrence.
- Bounded production manual locks with an OS-managed release route; if an interval cannot be registered safely, report failure and do not apply an indefinite shield.
- Freeze active rules; save relaxed or changed configuration as pending, activated only after the effective lock ends. Disabling recurrence affects future nights, not the committed current lock. Avoid immediately creating a replacement lock after recovery through pending edits.
- Combine overlapping scheduled/manual restrictions conservatively or explicitly reject a scenario until safely supported; never overwrite or clear another session's needed policy. Prefer per-origin stores when their composition is validated, with shared policy decisions testable without Apple frameworks.
- Recovery snapshots the current effective session IDs. Duplicate requests preserve eligibility; a newly started session outside that set cannot be unlocked by an old request. Natural end wins and never waits on recovery.
- Runtime app and monitor use the same pure decisions and serialized shared store; recheck time, identity, authorization, selection and revision where applicable. Persist intent before side effects and reconcile interruptions.
- Retain supported R1 settings migration and developer reset/tombstone protections. Never overwrite untracked source or discard existing state blindly.
- No production promises about exact background callback timing, universal website/system coverage, or owner-proof restrictions.

## Validation and delivery

Workers run focused tests and write concise results to their final response; do not commit, deploy or change phone state. Use separate SwiftPM scratch paths; reliability owns XcodeGen generation and shared project integration. Recovery can typecheck/build after shared coordinator interface is ready, but must not generate/edit project settings concurrently.

Parent runs integrated tests and simulator/device builds, asks Terra medium for read-only review, resolves blockers, and updates R2/R3 status. Human QA after that targets finite manual release, immutable active rules, delayed recovery/relaunch/natural end, and next-occurrence preservation. Existing basic scheduled-start/end pass is not erased or needlessly repeated except as a relevant regression.
