import Foundation

/// A successful unrelated operation must not hide a reconciliation failure.
/// The coordinator supplies its local reconciliation error and the latest
/// durable operation status to this shared rule before clearing UI errors.
public enum RuntimeErrorPolicy {
    public static func mayClearLastError(
        storageError: String?,
        reconciliationError: String?,
        latestOperationSucceeded: Bool?
    ) -> Bool {
        storageError == nil && reconciliationError == nil && latestOperationSucceeded != false
    }
}

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

    /// A bedtime started manually may cover the same saved occurrence that the
    /// repeating callback will later announce (for example an early start).
    /// Keep the recurring route registered for future nights, but do not create
    /// a second scheduled session or misreport the active origin as automatic.
    public static func suppressesScheduledStart(
        sessions: [RuntimeSession],
        occurrenceStart: Date,
        occurrenceEnd: Date,
        at date: Date
    ) -> Bool {
        sessions.contains { session in
            guard session.origin == .manual,
                  session.purpose == .bedtime,
                  session.isEffective(at: date) else { return false }
            if let binding = session.scheduledOccurrence {
                return binding.start == occurrenceStart && binding.end == occurrenceEnd
            }
            // Backward-compatible fallback for a bedtime value written before
            // explicit absolute occurrence bindings existed. New sessions
            // always take the exact binding branch above.
            return session.end == occurrenceEnd
                && session.start < occurrenceEnd
                && session.end > occurrenceStart
        }
    }

    public static func isReleased(
        sessions: [RuntimeSession],
        releasedOccurrences: [RuntimeReleasedOccurrence],
        origin: RuntimeSessionOrigin,
        start: Date,
        end: Date
    ) -> Bool {
        let terminalSessionMatches = origin == .scheduled && sessions.contains {
            $0.origin == origin && $0.start == start && $0.end == end && $0.state == .released
        }
        // Only the repeating route needs an occurrence-key release marker.
        // Manual sessions have no callback that can recreate an old session;
        // allowing a prior manual marker to suppress a new UUID would make a
        // restarted bedtime inherit old recovery/release ownership.
        let releasedMarkerMatches = origin == .scheduled && releasedOccurrences.contains {
            $0.origin == origin && $0.start == start && $0.end == end
        }
        return terminalSessionMatches || releasedMarkerMatches
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

    /// Manual activity names are reused. Retire the route only when no live
    /// manual session remains, even if older unnormalized sessions have ended.
    /// Returns whether the adapter may stop monitoring while still holding its
    /// shared transaction lock. The caller commits before policy side effects.
    public static func prepareManualEnd(
        _ document: inout RuntimeStoreDocument,
        at date: Date
    ) -> Bool {
        _ = RuntimeLifecycle.expireNaturalSessions(&document, at: date)
        let hasLiveManual = document.sessions.contains {
            $0.origin == .manual && $0.isEffective(at: date)
        }
        if !hasLiveManual {
            document.manualRegistrationActive = false
            document.manualRegistrationIntent = false
        }
        _ = RuntimeLifecycle.normalizeRecoveryCommitment(&document, at: date)
        document.policyIntent = desiredPolicyIntent(document, at: date)
        return !hasLiveManual
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
