import Foundation

/// Small, side-effect-free state mutations shared by app and monitor adapters.
public enum RuntimeLifecycle {
    /// Keep the active model small without dropping a current release marker.
    /// Manual/debug releases are disposable history; a scheduled marker whose
    /// occurrence has not ended is not. This is intentionally done inside the
    /// shared transaction before a new callback appends a session.
    public static func pruneTerminalSessions(
        _ document: inout RuntimeStoreDocument,
        keeping limit: Int = 32,
        at date: Date = Date()
    ) {
        let activeCount = document.sessions.filter(\.isEffective).count
        let terminalLimit = min(max(0, limit), max(0, 64 - activeCount))
        let terminal = document.sessions
            .filter { $0.state == .released || $0.state == .expired }
            .sorted { $0.end < $1.end }
        if terminal.count > terminalLimit {
            let removeIDs = Set(terminal.prefix(terminal.count - terminalLimit).map(\.id))
            document.sessions.removeAll { removeIDs.contains($0.id) }
        }

        // Keep enough released identities for late callbacks, but never evict
        // an unexpired scheduled suppression merely because manual history is
        // noisy. Removing a marker also removes its terminal session, if any,
        // so the document remains internally valid.
        guard document.releasedOccurrences.count > 64 else { return }
        let removable = document.releasedOccurrences
            .filter { occurrence in
                occurrence.origin != .scheduled || occurrence.end <= date
            }
            .sorted { $0.releasedAt < $1.releasedAt }
        let excess = document.releasedOccurrences.count - 64
        let removeIDs = Set(removable.prefix(excess).map(\.sessionID))
        guard !removeIDs.isEmpty else { return }
        document.releasedOccurrences.removeAll { removeIDs.contains($0.sessionID) }
        document.sessions.removeAll { removeIDs.contains($0.id) && $0.state == .released }
    }

    public static func shouldSuppressScheduledOccurrence(
        _ document: RuntimeStoreDocument,
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let key = RuntimeSessionDecision.occurrenceKey(origin: .scheduled, start: start, end: end)
        if document.suppressedOccurrenceKeys.contains(key) { return true }
        if document.scheduledActivationFence?.matches(start, calendar: calendar) == true { return true }
        return RuntimeSessionDecision.isReleased(
            sessions: document.sessions,
            releasedOccurrences: document.releasedOccurrences,
            origin: .scheduled,
            start: start,
            end: end
        )
    }

    @discardableResult
    public static func expireNaturalSessions(_ document: inout RuntimeStoreDocument, at date: Date) -> Bool {
        var changed = false
        for index in document.sessions.indices {
            guard (document.sessions[index].state == .active || document.sessions[index].state == .recoveryPending),
                  date >= document.sessions[index].end else { continue }
            if document.sessions[index].origin == .scheduled {
                document.scheduledActivationFence = RuntimeScheduledActivationFence(date: document.sessions[index].start)
            }
            document.sessions[index].state = .expired
            changed = true
        }
        if let commitment = document.recoveryCommitment,
           !document.sessions.contains(where: { commitment.sessionIDs.contains($0.id) && $0.isEffective(at: date) }) {
            // A natural end wins. Do not carry an old commitment into a future
            // occurrence or let its UI look actionable after all targets ended.
            document.recoveryCommitment = nil
            changed = true
        }
        return changed
    }

    @discardableResult
    public static func activatePendingConfigurationIfIdle(_ document: inout RuntimeStoreDocument, at date: Date) -> Bool {
        guard document.effectiveSessions(at: date).isEmpty, let pending = document.pendingConfiguration else { return false }
        if let occurrence = RuntimeOccurrenceResolver.candidates(start: pending.start, end: pending.end, around: date).first(where: { date >= $0.start && date < $0.end }) {
            // Keep the fence even while recurrence is disabled: re-enabling
            // later in the same civil occurrence must not bypass suppression.
            document.suppressedOccurrenceKeys.insert(RuntimeSessionDecision.occurrenceKey(origin: .scheduled, start: occurrence.start, end: occurrence.end))
            document.scheduledActivationFence = RuntimeScheduledActivationFence(date: occurrence.start)
            if document.suppressedOccurrenceKeys.count > 64 {
                document.suppressedOccurrenceKeys.remove(document.suppressedOccurrenceKeys.first!)
            }
        }
        document.configuration = pending
        document.pendingConfiguration = nil
        return true
    }

    public static func release(
        _ document: inout RuntimeStoreDocument,
        sessionIDs: Set<UUID>,
        at date: Date
    ) throws {
        guard !sessionIDs.isEmpty, date.timeIntervalSinceReferenceDate.isFinite else {
            throw RuntimeValidationError.invalidConfiguration("No current lock was selected for recovery.")
        }
        var released = Set<UUID>()
        for index in document.sessions.indices {
            guard sessionIDs.contains(document.sessions[index].id),
                  document.sessions[index].state == .active || document.sessions[index].state == .recoveryPending else { continue }
            guard date < document.sessions[index].end else {
                document.sessions[index].state = .expired
                continue
            }
            document.sessions[index].state = .released
            released.insert(document.sessions[index].id)
        }
        guard !released.isEmpty else { throw RuntimeValidationError.invalidConfiguration("The current lock has already ended.") }
        for session in document.sessions where released.contains(session.id) {
            if !document.releasedOccurrences.contains(where: { $0.sessionID == session.id }) {
                document.releasedOccurrences.append(RuntimeReleasedOccurrence(
                    sessionID: session.id,
                    origin: session.origin,
                    start: session.start,
                    end: session.end,
                    releasedAt: date
                ))
            }
            if session.origin == .scheduled {
                document.scheduledActivationFence = RuntimeScheduledActivationFence(date: session.start)
            }
        }
        pruneTerminalSessions(&document, at: date)
    }
}
