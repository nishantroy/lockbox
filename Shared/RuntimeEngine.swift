import Foundation

/// Pure lifecycle decisions shared by the app and DeviceActivity adapter.
/// Managed Settings is intentionally outside this file.
public enum RuntimeSessionDecision {
    public static func activeSessions(_ sessions: [RuntimeSession], at date: Date) -> [RuntimeSession] {
        sessions.filter { $0.isEffective(at: date) }
    }

    /// The sessions that may contribute to the named Managed Settings store.
    /// A manual session is not enforceable until DeviceActivity has accepted
    /// its one-shot end route. Keeping this gate in the shared core prevents a
    /// recovery/relaunch path from shielding a manual lock indefinitely.
    public static func enforcementSessions(
        in document: RuntimeStoreDocument,
        at date: Date
    ) -> [RuntimeSession] {
        document.sessions.filter {
            $0.isEffective(at: date) && ($0.origin != .manual || document.manualRegistrationActive)
        }
    }

    public static func matchingScheduledOccurrence(
        sessions: [RuntimeSession],
        start: Date,
        end: Date
    ) -> RuntimeSession? {
        sessions.first {
            $0.origin == .scheduled && $0.start == start && $0.end == end
        }
    }

    public static func matchingManualSession(sessions: [RuntimeSession]) -> RuntimeSession? {
        sessions.first { $0.origin == .manual && $0.isEffective }
    }

    public static func isReleased(
        sessions: [RuntimeSession],
        releasedOccurrences: [RuntimeReleasedOccurrence],
        origin: RuntimeSessionOrigin,
        start: Date,
        end: Date
    ) -> Bool {
        sessions.contains { $0.origin == origin && $0.start == start && $0.end == end && $0.state == .released }
            || releasedOccurrences.contains { $0.origin == origin && $0.start == start && $0.end == end }
    }

    /// The MVP can safely compose restrictions from same-mode sessions. A
    /// mixed block/allow union is rejected rather than allowing an assignment
    /// to silently replace a stronger restriction.
    public static func composedMode(for sessions: [RuntimeSession]) throws -> RuntimeMode? {
        let modes = Set(sessions.map { $0.policy.mode })
        guard modes.count <= 1 else { throw RuntimeValidationError.overlapUnsupported }
        return modes.first
    }

    public static func shouldRelease(_ session: RuntimeSession, at date: Date) -> Bool {
        date >= session.end || session.state == .released || session.state == .expired
    }

    public static func occurrenceKey(origin: RuntimeSessionOrigin, start: Date, end: Date) -> String {
        "\(origin.rawValue):\(start.timeIntervalSinceReferenceDate):\(end.timeIntervalSinceReferenceDate)"
    }
}

/// Decisions used at callback boundaries by both the monitor and the app.
/// The callback may be late, duplicated, or arrive after a crash between a
/// durable intent and Managed Settings. It must always reduce the *current*
/// aggregate, rather than replaying an unconditional clear from the callback's
/// origin.
public enum RuntimeCallbackDecision {
    public static func currentAggregate(
        _ document: RuntimeStoreDocument,
        at date: Date
    ) -> [RuntimeSession] {
        RuntimeSessionDecision.enforcementSessions(in: document, at: date)
    }

    public static func desiredPolicyIntent(
        _ document: RuntimeStoreDocument,
        at date: Date
    ) -> RuntimePolicyIntent {
        if !currentAggregate(document, at: date).isEmpty {
            return .apply
        }

        // The developer prototype deliberately has no committed session. Its
        // persisted apply intent is the one supported exception to the
        // no-manual-route rule, and is retained for the existing cleanup path.
        if document.activeOwner == .prototypeTest,
           document.testLockActive {
            return .apply
        }
        return .clear
    }

    /// Expire natural sessions and persist the intent that a callback must
    /// replay before touching Managed Settings. Callers still commit this
    /// mutation before performing the side effect.
    @discardableResult
    public static func preparePolicyReconciliation(
        _ document: inout RuntimeStoreDocument,
        at date: Date,
        calendar: Calendar = .current
    ) -> RuntimePolicyIntent {
        _ = RuntimeLifecycle.expireNaturalSessions(&document, at: date, calendar: calendar)
        let intent = desiredPolicyIntent(document, at: date)
        document.policyIntent = intent
        return intent
    }
}
