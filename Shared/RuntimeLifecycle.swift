import Foundation

/// Small, side-effect-free state mutations shared by app and monitor adapters.
public enum RuntimeLifecycle {
    /// Keep the repeating daily route for a still-enabled recurrence even
    /// after the just-ended occurrence has become terminal. A manual-only
    /// document has no recurring intent and therefore cannot keep that route.
    /// A live scheduled session is retained as an end route after the user
    /// disables recurrence; an activated pending replacement is explicitly
    /// stopped by the adapter after this decision.
    public static func pruneTerminalSessions(
        _ document: inout RuntimeStoreDocument,
        keeping limit: Int = 32,
        at date: Date = Date()
    ) {
        let maximum = min(max(0, limit), 64)
        var protectedIDs = Set(document.recoveryCommitment?.sessionIDs ?? [])
        protectedIDs.formUnion(document.releasedOccurrences.compactMap { occurrence in
            occurrence.origin == .scheduled && occurrence.end > date ? occurrence.sessionID : nil
        })

        let terminal = document.sessions.filter { $0.state == .released || $0.state == .expired }
        let nonTerminalCount = document.sessions.count - terminal.count
        let protectedTerminalCount = terminal.reduce(into: 0) { count, session in
            if protectedIDs.contains(session.id) { count += 1 }
        }
        // `limit` is a history target, not permission to discard an active
        // session or a durable commitment target. The target can therefore be
        // larger than `limit`, but never larger than the storage hard limit for
        // documents produced by normal lifecycle transitions.
        let terminalTarget = max(0, max(maximum, nonTerminalCount + protectedTerminalCount) - nonTerminalCount)
        let removableTerminal = terminal
            .filter { !protectedIDs.contains($0.id) }
            .sorted { $0.end < $1.end }
        let removeCount = max(0, terminal.count - terminalTarget)
        let removeIDs = Set(removableTerminal.prefix(removeCount).map(\.id))
        document.sessions.removeAll { removeIDs.contains($0.id) }

        // A released session requires its marker for duplicate/late callback
        // suppression. Remove old markers and their released session together;
        // never leave a `.released` session without its durable marker. Markers
        // for current scheduled windows and recovery targets are protected even
        // when noisy manual history exceeds the normal history target.
        guard document.releasedOccurrences.count > 64 else { return }
        let excess = document.releasedOccurrences.count - 64
        let removable = document.releasedOccurrences
            .filter { !protectedIDs.contains($0.sessionID) }
            .sorted { $0.releasedAt < $1.releasedAt }
        let releasedIDsToRemove = Set(removable.prefix(excess).map(\.sessionID))
        guard !releasedIDsToRemove.isEmpty else { return }
        document.releasedOccurrences.removeAll { releasedIDsToRemove.contains($0.sessionID) }
        document.sessions.removeAll {
            releasedIDsToRemove.contains($0.id) && $0.state == .released && !protectedIDs.contains($0.id)
        }
    }

    public static func scheduledRegistrationShouldRemain(
        _ document: RuntimeStoreDocument,
        at date: Date
    ) -> Bool {
        let scheduledIsLive = document.sessions.contains {
            $0.origin == .scheduled && $0.isEffective(at: date)
        }
        // `pendingConfiguration` is an explicit replacement. The callback
        // adapter stops the old route when it activates that replacement;
        // otherwise an enabled recurrence retains its daily registration even
        // after ordinary natural expiry.
        return scheduledIsLive || (document.recurringEnabledIntent && document.pendingConfiguration == nil)
    }

    public static func shouldSuppressScheduledOccurrence(
        _ document: RuntimeStoreDocument,
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let key = RuntimeSessionDecision.occurrenceKey(origin: .scheduled, start: start, end: end)
        if document.suppressedOccurrenceKeys.contains(key) { return true }
        if let fence = document.scheduledActivationFence {
            if fence.preservesLegacyCivilDay {
                let migratedCutoff = [
                    legacyFenceCutoff(document, fence: fence, calendar: calendar),
                    fence.notBeforeOccurrenceStart
                ].compactMap { $0 }.max()
                if let migratedCutoff {
                    // Build-3 stored only a civil day. Prefer a retained
                    // frozen session end (or the new absolute cutoff) so
                    // migration preserves suppression without inheriting the
                    // old whole-day bug.
                    if start <= migratedCutoff { return true }
                } else if fence.matches(start, calendar: calendar) {
                    // No retained absolute state is available. Keep the old
                    // same-day suppression rather than silently reopening data
                    // we cannot safely interpret.
                    return true
                }
            } else if fence.matches(start, calendar: calendar) {
                return true
            }
        }
        return RuntimeSessionDecision.isReleased(
            sessions: document.sessions,
            releasedOccurrences: document.releasedOccurrences,
            origin: .scheduled,
            start: start,
            end: end
        )
    }

    /// Repair the bidirectional recovery relationship before committing a
    /// state change. This is needed when a one-shot manual route disappears or
    /// changes while recovery is pending: an expired target may remain in the
    /// commitment, but an orphan pending state may not.
    @discardableResult
    public static func normalizeRecoveryCommitment(
        _ document: inout RuntimeStoreDocument,
        at date: Date
    ) -> Bool {
        var changed = false
        guard let commitment = document.recoveryCommitment else {
            for index in document.sessions.indices where document.sessions[index].state == .recoveryPending {
                document.sessions[index].state = date < document.sessions[index].end ? .active : .expired
                changed = true
            }
            return changed
        }

        let targetIDs = commitment.sessionIDs
        for index in document.sessions.indices {
            let session = document.sessions[index]
            if session.state == .recoveryPending && !targetIDs.contains(session.id) {
                document.sessions[index].state = date < session.end ? .active : .expired
                changed = true
            } else if session.state == .active && targetIDs.contains(session.id) && date < session.end {
                document.sessions[index].state = .recoveryPending
                changed = true
            }
        }

        let activeTargetIDs = Set(document.sessions.compactMap { session in
            targetIDs.contains(session.id) && session.isEffective(at: date) ? session.id : nil
        })
        if activeTargetIDs.isEmpty {
            document.recoveryCommitment = nil
            changed = true
        }
        return changed
    }

    /// Normalize manual route flags from the OS observation. A missing or
    /// mismatched route may leave a pending registration intent for the app to
    /// retry, but it can never leave a manual session enforceable. A previously
    /// accepted route that disappeared retires its session before the next
    /// durable commit and repairs recovery relationships at the same boundary.
    @discardableResult
    public static func normalizeManualRegistration(
        _ document: inout RuntimeStoreDocument,
        at date: Date,
        routeExists: Bool,
        routeMatches: Bool
    ) -> Bool {
        var changed = false
        let manualSessions = document.sessions.filter { $0.origin == .manual && $0.isEffective(at: date) }
        let hasCurrentManual = !manualSessions.isEmpty

        if routeExists && !routeMatches {
            // A stale/mismatched OS route can be replaced, so retain the
            // finite session as a pending registration but never treat the old
            // route as an active enforcement route.
            if hasCurrentManual {
                if document.manualRegistrationActive {
                    document.manualRegistrationActive = false
                    changed = true
                }
                if !document.manualRegistrationIntent {
                    document.manualRegistrationIntent = true
                    changed = true
                }
            } else if document.manualRegistrationActive || document.manualRegistrationIntent {
                document.manualRegistrationActive = false
                document.manualRegistrationIntent = false
                changed = true
            }
        } else if !routeExists {
            if document.manualRegistrationActive {
                // A missing route can never remain an active enforcement gate.
                document.manualRegistrationActive = false
                changed = true
            }
            if !document.manualRegistrationIntent && hasCurrentManual {
                // Unlike a mismatched route, absence of the previously
                // accepted end route cannot be safely replaced from the OS
                // observation. Retire the session before committing.
                for index in document.sessions.indices where document.sessions[index].origin == .manual {
                    guard document.sessions[index].isEffective(at: date) else { continue }
                    document.sessions[index].state = .expired
                    changed = true
                }
            } else if !hasCurrentManual && document.manualRegistrationIntent {
                document.manualRegistrationIntent = false
                changed = true
            }
            if !hasCurrentManual && (document.manualRegistrationActive || document.manualRegistrationIntent) {
                document.manualRegistrationActive = false
                document.manualRegistrationIntent = false
                changed = true
            }
        } else if hasCurrentManual {
            if !document.manualRegistrationActive || document.manualRegistrationIntent {
                document.manualRegistrationActive = true
                document.manualRegistrationIntent = false
                changed = true
            }
        } else if document.manualRegistrationActive || document.manualRegistrationIntent {
            document.manualRegistrationActive = false
            document.manualRegistrationIntent = false
            changed = true
        }

        if normalizeRecoveryCommitment(&document, at: date) {
            changed = true
        }
        if changed && (!routeExists || !routeMatches) {
            document.policyIntent = RuntimeCallbackDecision.desiredPolicyIntent(document, at: date)
        }
        return changed
    }

    @discardableResult
    public static func expireNaturalSessions(
        _ document: inout RuntimeStoreDocument,
        at date: Date,
        calendar: Calendar = .current
    ) -> Bool {
        var changed = false
        for index in document.sessions.indices {
            guard (document.sessions[index].state == .active || document.sessions[index].state == .recoveryPending),
                  date >= document.sessions[index].end else { continue }
            if document.sessions[index].origin == .scheduled {
                document.scheduledActivationFence = updatedFence(
                    document.scheduledActivationFence,
                    with: document.sessions[index].end,
                    preservingCalendar: calendar
                )
            }
            document.sessions[index].state = .expired
            changed = true
        }
        if normalizeRecoveryCommitment(&document, at: date) {
            changed = true
        }
        return changed
    }

    @discardableResult
    public static func activatePendingConfigurationIfIdle(
        _ document: inout RuntimeStoreDocument,
        at date: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard document.effectiveSessions(at: date).isEmpty, let pending = document.pendingConfiguration else { return false }
        if let occurrence = RuntimeOccurrenceResolver.candidates(
            start: pending.start,
            end: pending.end,
            around: date,
            calendar: calendar
        ).first(where: { date >= $0.start && date < $0.end }) {
            // Keep the fence even while recurrence is disabled: re-enabling
            // later in the same occurrence must not bypass suppression. The
            // absolute cutoff allows a genuinely future start later today.
            let key = RuntimeSessionDecision.occurrenceKey(origin: .scheduled, start: occurrence.start, end: occurrence.end)
            document.suppressedOccurrenceKeys.insert(key)
            if document.suppressedOccurrenceKeys.count > 64 {
                document.suppressedOccurrenceKeys.remove(document.suppressedOccurrenceKeys.first!)
            }
            document.scheduledActivationFence = updatedFence(
                document.scheduledActivationFence,
                with: occurrence.end,
                preservingCalendar: calendar
            )
        }
        document.configuration = pending
        document.pendingConfiguration = nil
        return true
    }

    public static func release(
        _ document: inout RuntimeStoreDocument,
        sessionIDs: Set<UUID>,
        at date: Date,
        calendar: Calendar = .current
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
                // No replacement occurrence may begin before this frozen
                // occurrence has naturally ended. This covers edits made just
                // before midnight as well as after-midnight recovery.
                document.scheduledActivationFence = updatedFence(document.scheduledActivationFence, with: session.end, preservingCalendar: calendar)
            }
        }
        _ = normalizeRecoveryCommitment(&document, at: date)
        pruneTerminalSessions(&document, at: date)
    }

    private static func legacyFenceCutoff(
        _ document: RuntimeStoreDocument,
        fence: RuntimeScheduledActivationFence,
        calendar: Calendar
    ) -> Date? {
        guard fence.preservesLegacyCivilDay else { return nil }
        let sessionEnds = document.sessions.compactMap { session -> Date? in
            guard session.origin == .scheduled else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: session.start)
            guard components.year == fence.year, components.month == fence.month, components.day == fence.day else { return nil }
            return session.end
        }
        let markerEnds = document.releasedOccurrences.compactMap { occurrence -> Date? in
            guard occurrence.origin == .scheduled else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: occurrence.start)
            guard components.year == fence.year, components.month == fence.month, components.day == fence.day else { return nil }
            return occurrence.end
        }
        let configurations = [document.configuration, document.pendingConfiguration].compactMap { $0 }
        let configurationEnds = configurations.flatMap { configuration in
            RuntimeOccurrenceResolver.candidates(
                start: configuration.start,
                end: configuration.end,
                around: calendar.date(from: DateComponents(year: fence.year, month: fence.month, day: fence.day)) ?? .distantPast,
                calendar: calendar
            ).compactMap { occurrence -> Date? in
                let components = calendar.dateComponents([.year, .month, .day], from: occurrence.start)
                return components.year == fence.year && components.month == fence.month && components.day == fence.day
                    ? occurrence.end
                    : nil
            }
        }
        return (sessionEnds + markerEnds + configurationEnds).max()
    }

    private static func updatedFence(
        _ existing: RuntimeScheduledActivationFence?,
        with cutoff: Date,
        preservingCalendar calendar: Calendar = .current
    ) -> RuntimeScheduledActivationFence {
        guard let existing else { return RuntimeScheduledActivationFence(date: cutoff, calendar: calendar) }
        guard let oldCutoff = existing.notBeforeOccurrenceStart else {
            // Keep the legacy civil-day marker in addition to the new absolute
            // cutoff. It is conservative, but preserves suppression from a
            // pre-migration document rather than silently reopening that day.
            return RuntimeScheduledActivationFence(
                notBeforeOccurrenceStart: cutoff,
                year: existing.year,
                month: existing.month,
                day: existing.day,
                preservesLegacyCivilDay: true
            )
        }
        let newer = max(oldCutoff, cutoff)
        return RuntimeScheduledActivationFence(
            notBeforeOccurrenceStart: newer,
            year: existing.year,
            month: existing.month,
            day: existing.day,
            preservesLegacyCivilDay: existing.preservesLegacyCivilDay
        )
    }
}
