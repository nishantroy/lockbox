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
        guard activity == activityName else {
            if activity == manualActivityName { handleManualStart() }
            return
        }
        handleScheduledStart()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if activity == activityName { handleScheduledEnd() }
        else if activity == manualActivityName { handleManualEnd() }
    }

    private func handleScheduledStart() {
        guard let store = try? SharedRuntimeStore(appGroupIdentifier: Self.appGroupIdentifier) else { return }
        let now = Date()
        guard let registered = activityCenter.schedule(for: activityName), activityCenter.activities.contains(activityName) else {
            try? record(store: store, operation: .callbackReceived, detail: "intervalDidStart ignored: no current OS registration.", succeeded: false)
            return
        }
        do {
            try store.withTransaction { context in
                guard let configuration = context.document.configuration,
                      context.document.recurringEnabledIntent,
                      RuntimeScheduleDecision.registrationMatches(configuration: configuration, start: registered.intervalStart, end: registered.intervalEnd, repeats: registered.repeats),
                      let occurrence = RuntimeOccurrenceResolver.candidates(start: configuration.start, end: configuration.end, around: now).first(where: { now >= $0.start && now < $0.end }) else {
                    context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "intervalDidStart ignored: registration, intent, or current occurrence did not match."), succeeded: false)
                    return
                }
                _ = RuntimeLifecycle.expireNaturalSessions(&context.document, at: now)
                RuntimeLifecycle.pruneTerminalSessions(&context.document)
                let savedSelection = try JSONDecoder().decode(FamilyActivitySelection.self, from: configuration.selectionData)
                guard selectionSummary(savedSelection) == configuration.selectionSummary else {
                    context.document.record(RuntimeDiagnostic(operation: .policyApplyFailed, observedAt: now, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "intervalDidStart rejected: selection summary mismatch."), succeeded: false)
                    return
                }
                if RuntimeLifecycle.shouldSuppressScheduledOccurrence(context.document, start: occurrence.start, end: occurrence.end) {
                    context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "intervalDidStart ignored: a durable activation fence deliberately deferred this already-open occurrence."), succeeded: true)
                    return
                }
                if RuntimeSessionDecision.isReleased(sessions: context.document.sessions, releasedOccurrences: context.document.releasedOccurrences, origin: .scheduled, start: occurrence.start, end: occurrence.end) {
                    context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "intervalDidStart ignored: this stable occurrence was already released or expired."), succeeded: true)
                    return
                }
                let snapshot = RuntimePolicySnapshot(mode: configuration.mode, selectionSummary: configuration.selectionSummary, selectionData: configuration.selectionData)
                try snapshot.validate()
                if let existing = RuntimeSessionDecision.matchingScheduledOccurrence(sessions: context.document.sessions, start: occurrence.start, end: occurrence.end) {
                    guard existing.state == .active || existing.state == .recoveryPending else { return }
                } else {
                    let active = RuntimeSessionDecision.activeSessions(context.document.sessions, at: now)
                    // A time-zone change or a duplicate callback must not make
                    // a second scheduled session while a frozen one is live.
                    guard !active.contains(where: { $0.origin == .scheduled }) else {
                        context.document.record(RuntimeDiagnostic(operation: .conflictRejected, observedAt: now, detail: "Scheduled start rejected: a different frozen scheduled occurrence is already active."), succeeded: false)
                        return
                    }
                    let session = RuntimeSession(origin: .scheduled, start: occurrence.start, end: occurrence.end, sourceRevision: configuration.revision, policy: snapshot)
                    context.document.sessions.append(session)
                    do { _ = try RuntimeSessionDecision.composedMode(for: RuntimeSessionDecision.activeSessions(context.document.sessions, at: now)) }
                    catch {
                        context.document.sessions.removeAll { $0.id == session.id }
                        context.document.record(RuntimeDiagnostic(operation: .conflictRejected, observedAt: now, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "Scheduled start rejected: mixed restriction modes cannot be safely composed."), succeeded: false)
                        return
                    }
                    if !active.isEmpty { context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "Scheduled occurrence composed with an existing same-mode session."), succeeded: true) }
                }
                context.document.policyIntent = .apply
                context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "intervalDidStart; stable occurrence committed."), succeeded: true)
                context.document.record(RuntimeDiagnostic(operation: .policyApplyAttempted, observedAt: now, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "Frozen scheduled policy persisted before apply."))
                try context.commit()
                try applyEffectivePolicy(context.document, at: now)
                context.document.policyIntent = nil
                context.document.record(RuntimeDiagnostic(operation: .policyApplied, observedAt: Date(), requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "Frozen scheduled policy application attempted."), succeeded: true)
                try context.commit()
            }
        } catch { try? record(store: store, operation: .policyApplyFailed, detail: error.localizedDescription, succeeded: false) }
    }

    private func handleManualStart() {
        guard let store = try? SharedRuntimeStore(appGroupIdentifier: Self.appGroupIdentifier) else { return }
        let now = Date()
        do {
            try store.withTransaction { context in
                guard context.document.manualRegistrationActive || context.document.manualRegistrationIntent else { return }
                guard let session = context.document.sessions.first(where: { $0.origin == .manual && $0.isEffective && now < $0.end }) else { return }
                context.document.manualRegistrationActive = true
                context.document.manualRegistrationIntent = false
                context.document.policyIntent = .apply
                context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "manual intervalDidStart; stable manual session reconciled."), succeeded: true)
                try context.commit()
                try applyEffectivePolicy(context.document, at: now)
                context.document.policyIntent = nil
                context.document.record(RuntimeDiagnostic(operation: .policyApplied, observedAt: Date(), requestedEnd: time(from: session.end), detail: "Finite manual policy application attempted."), succeeded: true)
                try context.commit()
            }
        } catch { try? record(store: store, operation: .policyApplyFailed, detail: error.localizedDescription, succeeded: false) }
    }

    private func handleScheduledEnd() {
        guard let store = try? SharedRuntimeStore(appGroupIdentifier: Self.appGroupIdentifier) else { return }
        let now = Date()
        guard let registered = activityCenter.schedule(for: activityName), activityCenter.activities.contains(activityName) else {
            try? record(store: store, operation: .callbackReceived, detail: "intervalDidEnd ignored: no current OS registration.", succeeded: false)
            return
        }
        do {
            var shouldStop = false
            var scheduleToRegister: RuntimeConfiguration?
            try store.withTransaction { context in
                guard let configuration = context.document.configuration,
                      RuntimeScheduleDecision.registrationMatches(configuration: configuration, start: registered.intervalStart, end: registered.intervalEnd, repeats: registered.repeats) else {
                    context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "intervalDidEnd ignored: registration no longer matches saved configuration."), succeeded: false)
                    return
                }
                let prior = context.document.sessions
                let expiredScheduled = prior.contains { $0.origin == .scheduled && ($0.state == .active || $0.state == .recoveryPending) && now >= $0.end }
                guard expiredScheduled || context.document.policyIntent == .clear else {
                    context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "intervalDidEnd ignored: no scheduled occurrence is naturally finished."), succeeded: false)
                    return
                }
                _ = RuntimeLifecycle.expireNaturalSessions(&context.document, at: now)
                let activated = RuntimeLifecycle.activatePendingConfigurationIfIdle(&context.document, at: now)
                if activated && context.document.recurringEnabledIntent {
                    // The old repeating registration has the old boundaries.
                    // It is stopped after this transaction; its callback gate
                    // still rejects a stale callback against the new rules.
                    scheduleToRegister = context.document.configuration
                }
                shouldStop = activated || (!context.document.recurringEnabledIntent && expiredScheduled)
                let effective = enforcementSessions(in: context.document, at: now)
                context.document.policyIntent = effective.isEmpty ? .clear : .apply
                context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "intervalDidEnd; natural end wins over recovery."), succeeded: true)
                context.document.record(RuntimeDiagnostic(operation: effective.isEmpty ? .policyClearAttempted : .policyApplyAttempted, observedAt: now, detail: "Natural-end reconciliation intent persisted before policy update."))
                try context.commit()
                try applyEffectivePolicy(context.document, at: now)
                context.document.policyIntent = nil
                context.document.record(RuntimeDiagnostic(operation: effective.isEmpty ? .policyCleared : .policyApplied, observedAt: Date(), detail: effective.isEmpty ? "Scheduled occurrence expired and named policy was cleared." : "Remaining overlapping policy was retained."), succeeded: true)
                try context.commit()
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
                guard context.document.sessions.contains(where: { $0.origin == .manual && ($0.state == .active || $0.state == .recoveryPending) && now >= $0.end }) else { return }
                _ = RuntimeLifecycle.expireNaturalSessions(&context.document, at: now)
                context.document.manualRegistrationActive = false
                context.document.manualRegistrationIntent = false
                let effective = enforcementSessions(in: context.document, at: now)
                context.document.policyIntent = effective.isEmpty ? .clear : .apply
                context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "manual intervalDidEnd; natural finite end reconciled."), succeeded: true)
                try context.commit()
                try applyEffectivePolicy(context.document, at: now)
                context.document.policyIntent = nil
                context.document.record(RuntimeDiagnostic(operation: effective.isEmpty ? .policyCleared : .policyApplied, observedAt: Date(), detail: effective.isEmpty ? "Finite manual policy cleared." : "Scheduled overlap retained after manual end."), succeeded: true)
                try context.commit()
            }
        } catch { try? record(store: store, operation: .policyClearFailed, detail: error.localizedDescription, succeeded: false) }
    }

    private func enforcementSessions(in state: RuntimeStoreDocument, at date: Date) -> [RuntimeSession] {
        state.sessions.filter { $0.isEffective(at: date) && ($0.origin != .manual || state.manualRegistrationActive) }
    }

    private func applyEffectivePolicy(_ state: RuntimeStoreDocument, at date: Date) throws {
        let sessions = enforcementSessions(in: state, at: date)
        guard !sessions.isEmpty else { settingsStore.clearAllSettings(); return }
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

    private func time(from date: Date) -> RuntimeTime {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return RuntimeTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }
}
