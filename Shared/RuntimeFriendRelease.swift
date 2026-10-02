import Foundation
import CryptoKit

/// Pure derivation of the companion "active set" identity. It is a stable
/// digest of *which sessions* were concurrently enforcing, never of the
/// restricted app/category selection — a companion request must not be able
/// to fingerprint which apps are blocked, even indirectly through a hash.
///
/// This must stay byte-identical to the app-layer
/// `ScreenTimeCoordinator.companionActiveSetID(for:)`, which R5 Slice B2c
/// switches to call this function instead of duplicating the algorithm.
public enum RuntimeActiveSet {
    /// `SHA256("PhoneLockbox.active-set.v1" || "|" || sorted session ID
    /// uuidStrings joined by "|")`. Order of `sessionIDs` does not matter:
    /// the ID strings are sorted before hashing.
    public static func id(for sessionIDs: [UUID]) -> String {
        let sortedIDs = sessionIDs.map { $0.uuidString }.sorted()
        let input = (["PhoneLockbox.active-set.v1"] + sortedIDs).joined(separator: "|")
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Outcome types and pure helpers for the durable friend-release flow (R5
/// Slice B2). The entry points themselves live on `RuntimeLifecycle` (see the
/// extension below) so callers write `RuntimeLifecycle.prepareFriendRelease`
/// etc., consistent with every other lifecycle transition; this namespace
/// only holds the supporting value types.
public enum RuntimeFriendRelease {
    /// Why `prepareFriendRelease`/`applyFriendRelease` produced a no-op
    /// instead of a state change. Natural end always wins: every case here
    /// is a calm, non-throwing outcome, never an error that leaves the
    /// device in a worse state.
    public enum NoOpReason: Equatable, Sendable {
        /// The target session is missing, or is no longer `.active`/
        /// `.recoveryPending` and effective at the transaction clock —
        /// natural end, another release, or an unknown session.
        case alreadyEnded
        /// The live active-set digest no longer matches the one the friend
        /// approved (a different session started or ended since).
        case activeSetMismatch
        /// A different friend-release intent is already pending.
        case conflictingPendingIntent
        /// `applyFriendRelease` was called with a `useID` that does not
        /// match any currently pending intent (already applied, already
        /// abandoned, or never prepared).
        case noMatchingPendingIntent
    }

    public enum PrepareOutcome: Equatable, Sendable {
        case recorded
        case noOp(NoOpReason)
    }

    /// What the caller (B2c) must still do after a successful apply. This is
    /// exposed so the app coordinator never re-derives the policy-intent or
    /// manual-route-stop decisions that `confirmRecovery` already makes
    /// inline; it only has to act on them.
    public struct ApplyEffect: Equatable, Sendable {
        /// `.apply` if another enforcement session remains after this
        /// release, `.clear` otherwise.
        public let policyIntent: RuntimePolicyIntent
        /// The exact manual route generation to stop, set only when the
        /// released session was the last live manual session. `nil` means
        /// no route stop is owed (either no manual route existed, or
        /// another manual session is still live).
        public let manualRouteToStop: RuntimeManualRouteBinding?

        public init(policyIntent: RuntimePolicyIntent, manualRouteToStop: RuntimeManualRouteBinding?) {
            self.policyIntent = policyIntent
            self.manualRouteToStop = manualRouteToStop
        }
    }

    public enum ApplyOutcome: Equatable, Sendable {
        case released(sessionID: UUID, remainingEffective: [UUID], effect: ApplyEffect)
        case noOp(NoOpReason)
    }
}

public extension RuntimeLifecycle {
    /// Records a durable intent to release exactly one session once the
    /// caller's relay `use` call is verified. Idempotent for a byte-identical
    /// re-prepare; rejects a second, different pending intent. Every failure
    /// path is a `.noOp`, never a throw, and makes no state change beyond the
    /// natural expiry that `expireNaturalSessions` always performs first.
    ///
    /// The live enforcement set is always recomputed from `document` itself
    /// — a caller-supplied set would let a stale or forged claim bind an
    /// approval to sessions that were never actually concurrently enforcing.
    /// This also means a manual session that is merely `isEffective` but not
    /// yet `manualRegistrationActive` (not actually enforcing) cannot be
    /// targeted, matching `RuntimeSessionDecision.enforcementSessions`.
    static func prepareFriendRelease(
        _ document: inout RuntimeStoreDocument,
        intent: RuntimeFriendReleaseIntent,
        at date: Date,
        calendar: Calendar = .current
    ) -> RuntimeFriendRelease.PrepareOutcome {
        _ = expireNaturalSessions(&document, at: date, calendar: calendar)

        let enforcementIDs = RuntimeSessionDecision.enforcementSessions(in: document, at: date).map(\.id)
        guard enforcementIDs.contains(intent.sessionID) else {
            return .noOp(.alreadyEnded)
        }
        guard RuntimeActiveSet.id(for: enforcementIDs) == intent.activeSetID else {
            return .noOp(.activeSetMismatch)
        }
        if let existing = document.pendingFriendRelease, existing != intent {
            return .noOp(.conflictingPendingIntent)
        }

        document.pendingFriendRelease = intent
        return .recorded
    }

    /// Applies a previously prepared friend release once its `use` has been
    /// verified. Safe to replay with the same `useID` after a crash: the
    /// first call releases the session and clears the intent; a later replay
    /// finds no matching pending intent and returns a calm `.noOp` rather
    /// than re-releasing or throwing.
    ///
    /// Re-derives and rechecks the live enforcement set exactly as
    /// `prepareFriendRelease` does, rather than trusting the set recorded at
    /// prepare time: the live set can change between prepare and apply (a
    /// new session can start, or the target's manual registration can drop)
    /// and a release must never go through against a set the friend did not
    /// actually approve.
    static func applyFriendRelease(
        _ document: inout RuntimeStoreDocument,
        useID: String,
        at date: Date,
        calendar: Calendar = .current
    ) -> RuntimeFriendRelease.ApplyOutcome {
        guard let pending = document.pendingFriendRelease, pending.useID == useID else {
            return .noOp(.noMatchingPendingIntent)
        }

        _ = expireNaturalSessions(&document, at: date, calendar: calendar)

        let enforcementIDs = RuntimeSessionDecision.enforcementSessions(in: document, at: date).map(\.id)
        guard enforcementIDs.contains(pending.sessionID) else {
            // Natural end (or some other release, or a dropped manual
            // registration) already won. Clear the stale intent so a
            // foreground replay has nothing left to retry.
            document.pendingFriendRelease = nil
            return .noOp(.alreadyEnded)
        }
        guard RuntimeActiveSet.id(for: enforcementIDs) == pending.activeSetID else {
            document.pendingFriendRelease = nil
            return .noOp(.activeSetMismatch)
        }

        do {
            try release(
                &document,
                sessionIDs: [pending.sessionID],
                at: date,
                calendar: calendar,
                cause: .friendApproval,
                friendUseID: pending.useID
            )
        } catch RuntimeValidationError.invalidConfiguration(let message) where message == RuntimeLifecycle.releaseAlreadyEndedMessage {
            // The one documented way `release` can fail here: a race between
            // the effectiveness recheck above and this call let natural end
            // win in between. Convert to the same calm no-op.
            document.pendingFriendRelease = nil
            return .noOp(.alreadyEnded)
        } catch {
            // `release`'s API makes no other provision for failure with a
            // single, already-rechecked session ID and a finite `date`; this
            // branch is a last-resort safety net, not an expected path.
            // `applyFriendRelease` cannot rethrow (every caller treats it as
            // non-throwing), so map to the safe no-op direction but surface
            // the surprise loudly in debug builds.
            assertionFailure("RuntimeLifecycle.release threw an unexpected error in applyFriendRelease: \(error)")
            document.pendingFriendRelease = nil
            return .noOp(.alreadyEnded)
        }
        document.pendingFriendRelease = nil

        // `release`'s own recovery-commitment normalization can only clear
        // the *whole* commitment (when no target remains effective), because
        // `RecoveryCommitment.sessionIDs` is immutable; it cannot drop just
        // the released ID from a commitment that still targets other live
        // sessions. A multi-target recovery request made before this exact-
        // session release must keep targeting its other sessions with the
        // same eligibility — not go corrupt (P1-1) or silently vanish.
        if let commitment = document.recoveryCommitment, commitment.sessionIDs.contains(pending.sessionID) {
            let remainingTargets = commitment.sessionIDs.subtracting([pending.sessionID])
            if !remainingTargets.isEmpty {
                do {
                    document.recoveryCommitment = try RecoveryCommitment(sessionIDs: remainingTargets, requestedAt: commitment.requestedAt)
                } catch {
                    // `requestedAt` and `remainingTargets` both came from an
                    // already-valid commitment, so this cannot actually
                    // throw; keep the document safe (no commitment is always
                    // valid) if that assumption is ever wrong.
                    assertionFailure("Rebuilding a recovery commitment after a friend release should never fail: \(error)")
                    document.recoveryCommitment = nil
                }
            }
            // An empty remaining set was already normalized to nil by `release`.
        }

        // Mirror `confirmRecovery` exactly: the manual flags are cleared
        // whenever no manual session remains live, regardless of whether a
        // `manualRoute` binding happens to be present.
        let hasLiveManual = document.sessions.contains {
            $0.origin == .manual && $0.isEffective(at: date)
        }
        var manualRouteToStop: RuntimeManualRouteBinding?
        if !hasLiveManual {
            manualRouteToStop = document.manualRoute
            document.manualRegistrationActive = false
            document.manualRegistrationIntent = false
        }

        let remaining = RuntimeSessionDecision.enforcementSessions(in: document, at: date)
        let effect = RuntimeFriendRelease.ApplyEffect(
            policyIntent: remaining.isEmpty ? .clear : .apply,
            manualRouteToStop: manualRouteToStop
        )
        return .released(sessionID: pending.sessionID, remainingEffective: remaining.map(\.id), effect: effect)
    }

    /// Clears a pending friend-release intent after a definitive relay
    /// rejection (replay, expired, wrong target, unauthorized, …). A
    /// `useID` that does not match the pending intent is a no-op: it never
    /// clears an unrelated, still-valid pending request.
    @discardableResult
    static func abandonFriendRelease(_ document: inout RuntimeStoreDocument, useID: String) -> Bool {
        guard let pending = document.pendingFriendRelease, pending.useID == useID else { return false }
        document.pendingFriendRelease = nil
        return true
    }
}
