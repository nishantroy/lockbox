import DeviceActivity
import FamilyControls
import ManagedSettings
import Foundation

final class MonitorExtension: DeviceActivityMonitor {
    private static let appGroupIdentifier = "group.com.phone-lockbox"
    private let activityName = DeviceActivityName("com.phone-lockbox.bedtime")
    private let manualActivityName = DeviceActivityName("com.phone-lockbox.manual")
    private let settingsStore = ManagedSettingsStore(named: ManagedSettingsStore.Name("phone-lockbox"))
    private let activityCenter = DeviceActivityCenter()

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        if activity == activityName { handleScheduledStart() }
        else if activity == manualActivityName { handleManualStart() }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if activity == activityName { handleScheduledEnd() }
        else if activity == manualActivityName { handleManualEnd() }
    }

    private func handleScheduledStart() {
        guard let store = try? SharedRuntimeStore(appGroupIdentifier: Self.appGroupIdentifier) else { return }
        let now = Date()
        do {
            try store.withTransaction { context in
                guard let configuration = context.document.configuration,
                      context.document.recurringEnabledIntent,
                      let registered = activityCenter.schedule(for: activityName),
                      activityCenter.activities.contains(activityName),
                      RuntimeScheduleDecision.registrationMatches(configuration: configuration, start: registered.intervalStart, end: registered.intervalEnd, repeats: registered.repeats),
                      let occurrence = RuntimeOccurrenceResolver.candidates(start: configuration.start, end: configuration.end, around: now).first(where: { now >= $0.start && now < $0.end }) else {
                    context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "intervalDidStart ignored: registration, intent, or current occurrence did not match."), succeeded: false)
                    try replayCurrentPolicy(in: context, at: now, detail: "Rejected scheduled start callback replayed current aggregate.")
                    return
                }
                _ = RuntimeLifecycle.expireNaturalSessions(&context.document, at: now)
                RuntimeLifecycle.pruneTerminalSessions(&context.document, at: now)
                let savedSelection = try JSONDecoder().decode(FamilyActivitySelection.self, from: configuration.selectionData)
                guard selectionSummary(savedSelection) == configuration.selectionSummary else {
                    context.document.record(RuntimeDiagnostic(operation: .policyApplyFailed, observedAt: now, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "intervalDidStart rejected: selection summary mismatch."), succeeded: false)
                    try replayCurrentPolicy(in: context, at: now, detail: "Invalid scheduled selection replayed current aggregate.")
                    return
                }
                if RuntimeLifecycle.shouldSuppressScheduledOccurrence(context.document, start: occurrence.start, end: occurrence.end) {
                    context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "intervalDidStart ignored: a durable activation fence deferred this already-open occurrence."), succeeded: true)
                    try replayCurrentPolicy(in: context, at: now, detail: "Suppressed scheduled start replayed current aggregate.")
                    return
                }
                if RuntimeSessionDecision.isReleased(sessions: context.document.sessions, releasedOccurrences: context.document.releasedOccurrences, origin: .scheduled, start: occurrence.start, end: occurrence.end) {
                    context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "intervalDidStart ignored: this stable occurrence was already released or expired."), succeeded: true)
                    try replayCurrentPolicy(in: context, at: now, detail: "Released scheduled start replayed current aggregate.")
                    return
                }
                let snapshot = RuntimePolicySnapshot(mode: configuration.mode, selectionSummary: configuration.selectionSummary, selectionData: configuration.selectionData)
                try snapshot.validate()
                if let existing = RuntimeSessionDecision.matchingScheduledOccurrence(sessions: context.document.sessions, start: occurrence.start, end: occurrence.end) {
                    guard existing.state == .active || existing.state == .recoveryPending else {
                        try replayCurrentPolicy(in: context, at: now, detail: "Terminal duplicate scheduled start replayed current aggregate.")
                        return
                    }
                } else {
                    let active = RuntimeCallbackDecision.currentAggregate(context.document, at: now)
                    // A time-zone change or duplicate callback must not make a
                    // second scheduled session while a frozen one is live.
                    guard !active.contains(where: { $0.origin == .scheduled }) else {
                        context.document.record(RuntimeDiagnostic(operation: .conflictRejected, observedAt: now, detail: "Scheduled start rejected: a different frozen scheduled occurrence is already active."), succeeded: false)
                        try replayCurrentPolicy(in: context, at: now, detail: "Conflicting scheduled start replayed current aggregate.")
                        return
                    }
                    let session = RuntimeSession(origin: .scheduled, start: occurrence.start, end: occurrence.end, sourceRevision: configuration.revision, policy: snapshot)
                    context.document.sessions.append(session)
                    do { _ = try RuntimeSessionDecision.composedMode(for: RuntimeCallbackDecision.currentAggregate(context.document, at: now)) }
                    catch {
                        context.document.sessions.removeAll { $0.id == session.id }
                        context.document.record(RuntimeDiagnostic(operation: .conflictRejected, observedAt: now, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "Scheduled start rejected: mixed restriction modes cannot be safely composed."), succeeded: false)
                        try replayCurrentPolicy(in: context, at: now, detail: "Mixed-mode scheduled start replayed current aggregate.")
                        return
                    }
                    if !active.isEmpty { context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "Scheduled occurrence composed with an existing same-mode session."), succeeded: true) }
                }
                context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "intervalDidStart; stable occurrence committed."), succeeded: true)
                try replayCurrentPolicy(in: context, at: now, detail: "Frozen scheduled policy reconciled.")
            }
        } catch { try? record(store: store, operation: .policyApplyFailed, detail: error.localizedDescription, succeeded: false) }
    }

    private func handleManualStart() {
        guard let store = try? SharedRuntimeStore(appGroupIdentifier: Self.appGroupIdentifier) else { return }
        let now = Date()
        do {
            try store.withTransaction { context in
                guard context.document.manualRegistrationActive || context.document.manualRegistrationIntent else {
                    try replayCurrentPolicy(in: context, at: now, detail: "Unowned manual start replayed current aggregate.")
                    return
                }
                guard let session = context.document.sessions.first(where: { $0.origin == .manual && $0.isEffective(at: now) && now < $0.end }) else {
                    context.document.manualRegistrationActive = false
                    context.document.manualRegistrationIntent = false
                    try replayCurrentPolicy(in: context, at: now, detail: "Manual start without a current session replayed current aggregate.")
                    return
                }
                context.document.manualRegistrationActive = true
                context.document.manualRegistrationIntent = false
                context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "manual intervalDidStart; stable manual session reconciled."), succeeded: true)
                _ = session
                try replayCurrentPolicy(in: context, at: now, detail: "Finite manual policy reconciled after OS start.")
            }
        } catch { try? record(store: store, operation: .policyApplyFailed, detail: error.localizedDescription, succeeded: false) }
    }

    private func handleScheduledEnd() {
        guard let store = try? SharedRuntimeStore(appGroupIdentifier: Self.appGroupIdentifier) else { return }
        let now = Date()
        do {
            var shouldStop = false
            var scheduleToRegister: RuntimeConfiguration?
            try store.withTransaction { context in
                let configuration = context.document.configuration
                if let configuration,
                   let registered = activityCenter.schedule(for: activityName),
                   activityCenter.activities.contains(activityName),
                   !RuntimeScheduleDecision.registrationMatches(configuration: configuration, start: registered.intervalStart, end: registered.intervalEnd, repeats: registered.repeats) {
                    context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "intervalDidEnd registration no longer matches saved configuration; replaying current aggregate."), succeeded: false)
                }

                let expiredScheduled = context.document.sessions.contains {
                    $0.origin == .scheduled && ($0.state == .active || $0.state == .recoveryPending) && now >= $0.end
                }
                _ = RuntimeLifecycle.expireNaturalSessions(&context.document, at: now)
                let activated = RuntimeLifecycle.activatePendingConfigurationIfIdle(&context.document, at: now)
                if activated && context.document.recurringEnabledIntent {
                    // The old repeating registration has old boundaries. Stop
                    // it after this transaction, then register the new one.
                    scheduleToRegister = context.document.configuration
                }
                let hasLiveScheduled = RuntimeLifecycle.scheduledRegistrationShouldRemain(context.document, at: now)
                // A manual-only aggregate never keeps the daily OS route alive.
                shouldStop = activated || !hasLiveScheduled
                context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, requestedStart: configuration?.start, requestedEnd: configuration?.end, revision: configuration?.revision, detail: expiredScheduled ? "intervalDidEnd; natural end wins over recovery." : "intervalDidEnd replayed idempotently; no natural scheduled expiry was required."), succeeded: true)
                try replayCurrentPolicy(in: context, at: now, detail: "Scheduled-end reconciliation used the current aggregate.")
            }
            if shouldStop { activityCenter.stopMonitoring([activityName]) }
            if let configuration = scheduleToRegister {
                do {
                    let schedule = DeviceActivitySchedule(intervalStart: DateComponents(hour: configuration.start.hour, minute: configuration.start.minute), intervalEnd: DateComponents(hour: configuration.end.hour, minute: configuration.end.minute), repeats: true)
                    try store.withTransaction { context in
                        guard context.document.configuration?.revision == configuration.revision,
                              context.document.activeOwner == nil,
                              context.document.sessions.allSatisfy({ !$0.isEffective(at: Date()) }) else { throw RuntimeValidationError.invalidConfiguration("A lock became active while replacing the daily schedule.") }
                        context.document.recurringEnabledIntent = true
                        context.document.record(RuntimeDiagnostic(operation: .registrationAttempted, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "Pending configuration registration requested after natural end."))
                        try context.commit()
                    }
                    try activityCenter.startMonitoring(activityName, during: schedule)
                    try store.transaction { context in
                        context.record(RuntimeDiagnostic(operation: .registrationSucceeded, observedAt: Date(), requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "Pending configuration registration accepted by OS."), succeeded: true)
                    }
                } catch {
                    activityCenter.stopMonitoring([activityName])
                    try? store.transaction { context in
                        context.recurringEnabledIntent = false
                        context.record(RuntimeDiagnostic(operation: .registrationFailed, observedAt: Date(), requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: error.localizedDescription), succeeded: false)
                    }
                }
            }
        } catch { try? record(store: store, operation: .policyClearFailed, detail: error.localizedDescription, succeeded: false) }
    }

    private func handleManualEnd() {
        guard let store = try? SharedRuntimeStore(appGroupIdentifier: Self.appGroupIdentifier) else { return }
        let now = Date()
        do {
            try store.withTransaction { context in
                let hasLiveManual = context.document.sessions.contains {
                    $0.origin == .manual && $0.isEffective(at: now)
                }
                let hasTerminalManual = context.document.sessions.contains {
                    $0.origin == .manual && ($0.state == .active || $0.state == .recoveryPending) && now >= $0.end
                }
                if hasTerminalManual {
                    _ = RuntimeLifecycle.expireNaturalSessions(&context.document, at: now)
                    context.document.manualRegistrationActive = false
                    context.document.manualRegistrationIntent = false
                    _ = RuntimeLifecycle.normalizeRecoveryCommitment(&context.document, at: now)
                    context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "manual intervalDidEnd; natural finite end reconciled."), succeeded: true)
                } else if !hasLiveManual {
                    // This includes a released manual session after a crash at
                    // the release-commit/clear boundary. Do not let the
                    // terminal callback's old path return before replaying the
                    // durable intent against any scheduled overlap.
                    context.document.manualRegistrationActive = false
                    context.document.manualRegistrationIntent = false
                    _ = RuntimeLifecycle.normalizeRecoveryCommitment(&context.document, at: now)
                    context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "manual intervalDidEnd replayed a terminal or already-released session."), succeeded: true)
                } else {
                    // A stale end callback must not clear a newer live manual
                    // lock. The shared aggregate below re-applies it.
                    context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "stale manual intervalDidEnd ignored while a finite manual session remains live."), succeeded: true)
                }
                try replayCurrentPolicy(in: context, at: now, detail: "Manual-end reconciliation used the current aggregate.")
            }
        } catch { try? record(store: store, operation: .policyClearFailed, detail: error.localizedDescription, succeeded: false) }
    }

    /// Persist the current desired intent before applying Managed Settings.
    /// This is the shared callback decision boundary: a clear intent from one
    /// session is converted to apply when another current session remains.
    private func replayCurrentPolicy(
        in context: RuntimeStoreTransaction,
        at date: Date,
        detail: String
    ) throws {
        let intent = RuntimeCallbackDecision.preparePolicyReconciliation(&context.document, at: date)
        context.document.record(RuntimeDiagnostic(
            operation: intent == .clear ? .policyClearAttempted : .policyApplyAttempted,
            observedAt: date,
            detail: detail
        ))
        try context.commit()
        try applyEffectivePolicy(context.document, at: date)
        context.document.policyIntent = nil
        context.document.record(RuntimeDiagnostic(
            operation: intent == .clear ? .policyCleared : .policyApplied,
            observedAt: Date(),
            detail: intent == .clear ? "Current aggregate is empty; named policy cleared." : "Current aggregate policy applied.",
        ), succeeded: true)
        try context.commit()
    }

    private func applyEffectivePolicy(_ state: RuntimeStoreDocument, at date: Date) throws {
        let sessions = RuntimeCallbackDecision.currentAggregate(state, at: date)
        guard !sessions.isEmpty else {
            if state.activeOwner == .prototypeTest && state.testLockActive && state.policyIntent == .apply {
                let data = state.draft?.selectionData ?? state.configuration?.selectionData
                let runtimeMode = state.draft?.mode ?? state.configuration?.mode
                let expected = state.draft?.selectionSummary ?? state.configuration?.selectionSummary
                guard let data, let runtimeMode, let expected else { throw RuntimeValidationError.corruptSharedData }
                let saved = try JSONDecoder().decode(FamilyActivitySelection.self, from: data)
                guard selectionSummary(saved) == expected else { throw RuntimeValidationError.corruptSharedData }
                apply(plan: try RuntimePolicyPlan.make(mode: runtimeMode, selection: expected), selection: saved)
            } else {
                settingsStore.clearAllSettings()
            }
            return
        }
        guard let mode = try RuntimeSessionDecision.composedMode(for: sessions) else { return }
        var selections: [FamilyActivitySelection] = []
        for session in sessions {
            let decoded = try JSONDecoder().decode(FamilyActivitySelection.self, from: session.policy.selectionData)
            guard selectionSummary(decoded) == session.policy.selectionSummary else { throw RuntimeValidationError.corruptSharedData }
            selections.append(decoded)
        }
        switch mode {
        case .blockSelected:
            var applications = Set<ApplicationToken>()
            var categories = Set<ActivityCategoryToken>()
            var webDomains = Set<WebDomainToken>()
            for selection in selections {
                applications.formUnion(selection.applicationTokens)
                categories.formUnion(selection.categoryTokens)
                webDomains.formUnion(selection.webDomainTokens)
            }
            settingsStore.shield.applications = applications.isEmpty ? nil : applications
            settingsStore.shield.applicationCategories = categories.isEmpty ? nil : .specific(categories)
            settingsStore.shield.webDomains = webDomains.isEmpty ? nil : webDomains
            settingsStore.shield.webDomainCategories = nil
        case .allowOnlySelected:
            guard let first = selections.first else { settingsStore.clearAllSettings(); return }
            var applications = first.applicationTokens
            var webDomains = first.webDomainTokens
            for selection in selections.dropFirst() {
                applications.formIntersection(selection.applicationTokens)
                webDomains.formIntersection(selection.webDomainTokens)
            }
            guard !applications.isEmpty else { throw RuntimeValidationError.overlapUnsupported }
            settingsStore.shield.applications = nil
            settingsStore.shield.applicationCategories = .all(except: applications)
            settingsStore.shield.webDomains = nil
            settingsStore.shield.webDomainCategories = .all(except: webDomains)
        }
    }

    private func selectionSummary(_ selection: FamilyActivitySelection) -> RuntimeSelectionSummary {
        RuntimeSelectionSummary(applicationCount: selection.applicationTokens.count, categoryCount: selection.categoryTokens.count, webDomainCount: selection.webDomainTokens.count)
    }

    private func record(store: SharedRuntimeStore, operation: RuntimeOperation, detail: String, succeeded: Bool) throws {
        try store.transaction { document in
            document.record(RuntimeDiagnostic(operation: operation, observedAt: Date(), detail: detail), succeeded: succeeded)
        }
    }

    private func apply(plan: RuntimePolicyPlan, selection: FamilyActivitySelection) {
        switch plan.mode {
        case .blockSelected:
            settingsStore.shield.applications = plan.blocksSelectedApplications ? selection.applicationTokens : nil
            settingsStore.shield.applicationCategories = plan.blocksSelectedCategories ? .specific(selection.categoryTokens) : nil
            settingsStore.shield.webDomains = plan.blocksSelectedWebDomains ? selection.webDomainTokens : nil
            settingsStore.shield.webDomainCategories = nil
        case .allowOnlySelected:
            settingsStore.shield.applications = nil
            settingsStore.shield.applicationCategories = .all(except: selection.applicationTokens)
            settingsStore.shield.webDomains = nil
            settingsStore.shield.webDomainCategories = .all(except: selection.webDomainTokens)
        }
    }

    private func time(from date: Date) -> RuntimeTime {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return RuntimeTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }
}
