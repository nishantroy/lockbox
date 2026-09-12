import Combine
import DeviceActivity
import FamilyControls
import ManagedSettings
import Foundation

@MainActor
final class ScreenTimeCoordinator: ObservableObject {
    enum RestrictionMode: String, CaseIterable, Identifiable, Hashable {
        case blockSelected = "blockSelected"
        case allowOnlySelected = "allowOnlySelected"
        var id: Self { self }
        var title: String { self == .blockSelected ? "Block selected" : "Allow only selected" }
    }

    static let activityName = DeviceActivityName("com.phone-lockbox.bedtime")
    private static let manualActivityName = DeviceActivityName("com.phone-lockbox.manual")
    private static let appGroupIdentifier = "group.com.phone-lockbox"
    private static let settingsName = ManagedSettingsStore.Name("phone-lockbox")
    private static let minimumScheduledDuration: TimeInterval = 15 * 60

    @Published private(set) var authorizationStatus: AuthorizationStatus = .notDetermined
    @Published private(set) var selection: FamilyActivitySelection
    @Published private(set) var mode: RestrictionMode
    @Published private(set) var scheduleIsRegistered = false
    @Published private(set) var hasOSRegistration = false
    @Published private(set) var testScheduleActive: Bool
    @Published private(set) var lastError: String?
    @Published private(set) var isConfigured: Bool
    @Published private(set) var recentDiagnostics: [RuntimeDiagnostic] = []

    private let activityCenter = DeviceActivityCenter()
    private let settingsStore = ManagedSettingsStore(named: ManagedSettingsStore.Name("phone-lockbox"))
    private let store: SharedRuntimeStore?
    private var document: RuntimeStoreDocument
    private var storageError: String?

    var selectedItemCount: Int { selection.applicationTokens.count + selection.categoryTokens.count + selection.webDomainTokens.count }
    var canApplySelection: Bool { (try? policyPlan(for: selection, mode: mode)) != nil }
    /// Drafts remain editable during a committed lock, but the save becomes a
    /// pending configuration and never mutates the active snapshot.
    var canEditDraft: Bool { isAuthorized && !testScheduleActive && storageError == nil }
    var isAuthorized: Bool {
        if #available(iOS 26.4, *), authorizationStatus == .approvedWithDataAccess { return true }
        switch authorizationStatus {
        case .approved: return true
        case .denied, .notDetermined: return false
        default: return false
        }
    }

    // MARK: R2/R3 coordinator contract

    var hasActiveLock: Bool {
        !enforcementSessions(at: Date()).isEmpty
    }

    var activeLockEnd: Date? {
        enforcementSessions(at: Date()).map(\.end).max()
    }

    var activeSessionCount: Int {
        enforcementSessions(at: Date()).count
    }

    var hasRecoveryRequest: Bool {
        guard let commitment = document.recoveryCommitment else { return false }
        return !commitment.sessionIDs.intersection(Set(enforcementSessions(at: Date()).map(\.id))).isEmpty
    }

    var recoveryEligibleAt: Date? {
        guard hasRecoveryRequest else { return nil }
        return document.recoveryCommitment?.eligibleAt
    }

    var pendingChangesSummary: String? {
        guard let pending = document.pendingConfiguration else { return nil }
        return "Pending after the current lock: \(pending.mode == .blockSelected ? "block selected" : "allow only selected"), \(pending.start.displayValue)–\(pending.end.displayValue)"
    }

    /// Lock now is intentionally finite. The displayed end is resolved from the
    /// configured daily window, so there is no caller-controlled indefinite path.
    var manualLockProposedEnd: Date? {
        proposedManualEnd(at: Date())
    }

    func canConfirmRecovery(at date: Date) -> Bool {
        guard let commitment = document.recoveryCommitment else { return false }
        // Eligibility is evaluated against every unreleased active session.
        // Filtering to the old target set would let an old request unlock a
        // newly started session.
        let active = document.effectiveSessions(at: date)
        let activeIDs = Set(active.map(\.id))
        return !active.isEmpty && commitment.isEligible(at: date, activeSessionIDs: activeIDs)
    }

    func requestRecovery() {
        guard let store else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        do {
            try store.withTransaction { context in
                let now = Date()
                _ = RuntimeLifecycle.expireNaturalSessions(&context.document, at: now)
                let active = context.document.effectiveSessions(at: now)
                guard !active.isEmpty else { throw RuntimeValidationError.invalidConfiguration("There is no active lock to recover.") }

                if let existing = context.document.recoveryCommitment,
                   !existing.sessionIDs.intersection(Set(active.map(\.id))).isEmpty {
                    // Duplicate taps are idempotent and never move eligibility.
                    return
                }
                let ids = Set(active.map(\.id))
                let commitment = try RecoveryCommitment(sessionIDs: ids, requestedAt: now)
                context.document.recoveryCommitment = commitment
                for index in context.document.sessions.indices where ids.contains(context.document.sessions[index].id) {
                    if context.document.sessions[index].state == .active { context.document.sessions[index].state = .recoveryPending }
                }
                context.document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "Recovery requested for current committed sessions; eligibility is fixed at +900 seconds."), succeeded: true)
                try context.commit()
            }
            reconcileRuntime()
            refreshDocument()
            lastError = nil
        } catch {
            reconcileRuntime()
            refreshDocument(); lastError = error.localizedDescription
        }
    }

    func cancelRecovery() {
        guard let store else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        do {
            try store.transaction { document in
                let now = Date()
                _ = RuntimeLifecycle.expireNaturalSessions(&document, at: now)
                guard let commitment = document.recoveryCommitment else { return }
                for index in document.sessions.indices where commitment.sessionIDs.contains(document.sessions[index].id) {
                    if document.sessions[index].state == .recoveryPending && now < document.sessions[index].end {
                        document.sessions[index].state = .active
                    }
                }
                document.recoveryCommitment = nil
                document.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: now, detail: "Recovery request cancelled; current policy remains committed."), succeeded: true)
            }
            reconcileRuntime()
            refreshDocument(); lastError = nil
        } catch {
            reconcileRuntime()
            refreshDocument(); lastError = error.localizedDescription
        }
    }

    func confirmRecovery() {
        guard let store else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        var shouldRegisterPending = false
        var shouldStopManualMonitoring = false
        do {
            try store.withTransaction { context in
                let now = Date()
                _ = RuntimeLifecycle.expireNaturalSessions(&context.document, at: now)
                guard let commitment = context.document.recoveryCommitment else {
                    throw RuntimeValidationError.invalidConfiguration("There is no active recovery request.")
                }
                let activeSessions = context.document.effectiveSessions(at: now)
                let activeIDs = Set(activeSessions.map(\.id))
                guard !activeIDs.isEmpty,
                      commitment.isEligible(at: now, activeSessionIDs: activeIDs) else {
                    throw RuntimeValidationError.invalidConfiguration("Recovery is not eligible yet, or a newer lock is still active.")
                }
                // Release markers and the new desired policy are durable before
                // the named Managed Settings store is changed.
                try RuntimeLifecycle.release(&context.document, sessionIDs: activeIDs, at: now)
                context.document.recoveryCommitment = nil
                shouldStopManualMonitoring = !context.document.sessions.contains {
                    $0.origin == .manual && $0.isEffective(at: now)
                }
                if RuntimeLifecycle.activatePendingConfigurationIfIdle(&context.document, at: now) {
                    shouldRegisterPending = context.document.recurringEnabledIntent
                }
                let remaining = enforcementSessions(in: context.document, at: now)
                context.document.policyIntent = remaining.isEmpty ? .clear : .apply
                context.document.record(RuntimeDiagnostic(operation: .policyClearAttempted, observedAt: now, detail: "Recovery release persisted before reconciling this app's named policy."))
                try context.commit()
                try applyEffectivePolicy(context.document, at: now)
                context.document.policyIntent = nil
                context.document.record(RuntimeDiagnostic(operation: .policyCleared, observedAt: Date(), detail: "Recovery release applied; future occurrences remain configured."), succeeded: true)
                try context.commit()
            }
            if shouldStopManualMonitoring { activityCenter.stopMonitoring([Self.manualActivityName]) }
            refreshDocument()
            lastError = nil
            if shouldRegisterPending { registerConfiguredSchedule() }
        } catch {
            // A confirmation raced the natural end: reconcile expiry even though
            // no recovery release is permitted at or after that boundary.
            reconcileRuntime()
            refreshDocument(); lastError = error.localizedDescription
        }
    }

    func startManualLock(expectedEnd: Date? = nil) {
        guard isAuthorized else { lastError = "Screen Time access is not authorized."; return }
        guard let store else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        guard !hasRecoveryRequest else { lastError = "Cancel the pending recovery request before starting another lock."; return }
        guard !testScheduleActive, !document.legacyRegistrationNeedsReview else { lastError = "Finish or resolve the developer restriction before starting a committed lock."; return }
        let proposedEnd = proposedManualEnd(at: Date())
        if let expectedEnd, proposedEnd != expectedEnd {
            lastError = "The manual lock preview changed. Review it and confirm again."
            return
        }
        guard let end = expectedEnd ?? proposedEnd, end.timeIntervalSinceNow >= Self.minimumScheduledDuration else {
            lastError = RuntimeValidationError.manualLockUnavailable.localizedDescription
            return
        }
        var sessionID: UUID?
        var manualRegistered = false
        do {
            let startedAt = Date()
            try store.withTransaction { context in
                _ = RuntimeLifecycle.expireNaturalSessions(&context.document, at: startedAt)
                guard context.document.recoveryCommitment == nil,
                      !context.document.testLockActive,
                      context.document.activeOwner != .prototypeTest,
                      !context.document.legacyRegistrationNeedsReview else {
                    throw RuntimeValidationError.invalidConfiguration("Finish the current recovery or developer restriction before starting another lock.")
                }
                let active = enforcementSessions(in: context.document, at: startedAt)
                guard !context.document.sessions.contains(where: { $0.origin == .manual && $0.isEffective(at: startedAt) }) else {
                    throw RuntimeValidationError.invalidConfiguration("A finite manual lock is already active; it cannot be shortened or replaced.")
                }
                guard let configuration = context.document.configuration else { throw RuntimeValidationError.manualLockUnavailable }
                let savedSelection = try JSONDecoder().decode(FamilyActivitySelection.self, from: configuration.selectionData)
                guard selectionSummary(savedSelection) == configuration.selectionSummary else { throw RuntimeValidationError.corruptSharedData }
                let policy = try RuntimePolicySnapshot(mode: configuration.mode, selectionSummary: configuration.selectionSummary, selectionData: configuration.selectionData).validated()
                guard let currentEnd = RuntimeOccurrenceResolver.currentOrNext(start: configuration.start, end: configuration.end, enabled: true, after: startedAt)?.end,
                      currentEnd == end else { throw RuntimeValidationError.invalidConfiguration("The manual lock preview changed. Review it and confirm again.") }
                if !active.isEmpty {
                    guard try active.allSatisfy({ try policiesAreSemanticallyEqual($0.policy, policy) }) else {
                        throw RuntimeValidationError.overlapUnsupported
                    }
                }
                RuntimeLifecycle.pruneTerminalSessions(&context.document)
                let session = RuntimeSession(origin: .manual, start: startedAt, end: end, sourceRevision: configuration.revision, policy: policy)
                sessionID = session.id
                context.document.sessions.append(session)
                context.document.manualRegistrationIntent = true
                context.document.manualRegistrationActive = false
                context.document.policyIntent = .apply
                context.document.record(RuntimeDiagnostic(operation: .policyApplyAttempted, observedAt: startedAt, detail: "Finite manual session persisted before OS registration."))
                try context.commit()

                let schedule = manualSchedule(start: startedAt, end: end)
                try activityCenter.startMonitoring(Self.manualActivityName, during: schedule)
                manualRegistered = true
                context.document.manualRegistrationIntent = false
                context.document.manualRegistrationActive = true
                try context.commit()
                try applyEffectivePolicy(context.document, at: startedAt)
                context.document.policyIntent = nil
                context.document.record(RuntimeDiagnostic(operation: .policyApplied, observedAt: Date(), detail: "Finite manual policy application attempted; OS-managed end is registered."), succeeded: true)
                try context.commit()
            }
            refreshDocument(); lastError = nil
        } catch {
            if !manualRegistered {
                // A rejected second manual lock has no sessionID and must not
                // stop the first lock's only end route.
                if let sessionID {
                    activityCenter.stopMonitoring([Self.manualActivityName])
                    try? store.transaction { document in
                        document.sessions.removeAll { $0.id == sessionID }
                        document.manualRegistrationIntent = false
                        document.manualRegistrationActive = false
                        let remaining = enforcementSessions(in: document, at: Date())
                        document.policyIntent = remaining.isEmpty ? .clear : .apply
                        document.record(RuntimeDiagnostic(operation: .registrationFailed, observedAt: Date(), detail: error.localizedDescription), succeeded: false)
                    }
                    reconcileRuntime()
                }
            } else {
                // The OS release route was accepted. Retain cleanup ownership
                // and durable apply intent; never clear the named store here.
                try? store.transaction { document in
                    document.record(RuntimeDiagnostic(operation: .policyApplyFailed, observedAt: Date(), detail: error.localizedDescription), succeeded: false)
                }
                reconcilePendingManualRegistration()
                reconcileRuntime()
            }
            refreshDocument(); lastError = error.localizedDescription
        }
    }

    /// Debug-only immediate release. It marks only current occurrences released;
    /// the repeating registration and future occurrences are left intact.
    func developerUnlockNow() {
        guard let store else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        var shouldStopManualMonitoring = false
        do {
            try store.withTransaction { context in
                let now = Date()
                _ = RuntimeLifecycle.expireNaturalSessions(&context.document, at: now)
                let ids = Set(enforcementSessions(in: context.document, at: now).map(\.id))
                let isPrototypeOwner = context.document.activeOwner == .prototypeTest && context.document.testLockActive
                guard !ids.isEmpty || isPrototypeOwner else {
                    throw RuntimeValidationError.invalidConfiguration("No current owned lock is available for developer unlock.")
                }
                if !ids.isEmpty {
                    try RuntimeLifecycle.release(&context.document, sessionIDs: ids, at: now)
                    context.document.recoveryCommitment = nil
                }
                shouldStopManualMonitoring = !context.document.sessions.contains {
                    $0.origin == .manual && $0.isEffective(at: now)
                }
                context.document.manualRegistrationIntent = false
                context.document.manualRegistrationActive = false
                context.document.policyIntent = .clear
                context.document.record(RuntimeDiagnostic(operation: .policyClearAttempted, observedAt: now, detail: "Developer unlock persisted release suppression before clearance."))
                try context.commit()
                try applyEffectivePolicy(context.document, at: now)
                context.document.activeOwner = nil
                context.document.testLockActive = false
                context.document.policyIntent = nil
                context.document.record(RuntimeDiagnostic(operation: .policyCleared, observedAt: Date(), detail: "Developer unlock cleared current owned policy; future schedule preserved."), succeeded: true)
                try context.commit()
            }
            if shouldStopManualMonitoring { activityCenter.stopMonitoring([Self.manualActivityName]) }
            refreshDocument(); lastError = nil
        } catch { refreshDocument(); lastError = error.localizedDescription }
    }

    // MARK: Existing R1 UI surface

    var startComponents: DateComponents { DateComponents(hour: draftStart.hour, minute: draftStart.minute) }
    var endComponents: DateComponents { DateComponents(hour: draftEnd.hour, minute: draftEnd.minute) }
    var savedStartComponents: DateComponents { DateComponents(hour: document.configuration?.start.hour ?? 22, minute: document.configuration?.start.minute ?? 0) }
    var savedEndComponents: DateComponents { DateComponents(hour: document.configuration?.end.hour ?? 7, minute: document.configuration?.end.minute ?? 0) }
    var savedModeTitle: String { document.configuration?.mode == .blockSelected ? "Block selected" : "Allow only selected" }
    var savedSelectedItemCount: Int { document.configuration?.selectionSummary.totalCount ?? 0 }
    var draftStart: RuntimeTime { document.draft?.start ?? document.configuration?.start ?? RuntimeTime(hour: 22, minute: 0) }
    var draftEnd: RuntimeTime { document.draft?.end ?? document.configuration?.end ?? RuntimeTime(hour: 7, minute: 0) }
    var recurringEnabledIntent: Bool { document.recurringEnabledIntent }
    var lastOperation: RuntimeOperationStatus { document.operationStatus }
    var legacyRegistrationNeedsReview: Bool { document.legacyRegistrationNeedsReview }
    var hasUnsavedDraft: Bool {
        guard let configuration = document.configuration else { return document.draft != nil }
        guard let draft = document.draft else { return true }
        return draft.mode != configuration.mode || draft.selectionData != configuration.selectionData || draft.start != configuration.start || draft.end != configuration.end
    }

    var registrationLabel: String {
        if document.legacyRegistrationNeedsReview { return "Legacy registration needs cleanup or re-registration" }
        guard isAuthorized else { return "Unavailable: Screen Time access is not authorized" }
        if hasOSRegistration && !scheduleIsRegistered { return "OS schedule differs from saved rules; stop and re-register" }
        if scheduleIsRegistered && recurringEnabledIntent { return "Registered (OS reports matching schedule)" }
        if scheduleIsRegistered { return "OS registration remains; recurring intent is disabled" }
        if recurringEnabledIntent { return "Registration not observed" }
        return "Not registered"
    }

    init() {
        var loadedStore: SharedRuntimeStore?
        var loadedDocument = RuntimeStoreDocument()
        var loadError: String?
        do {
            let shared = try SharedRuntimeStore(appGroupIdentifier: Self.appGroupIdentifier)
            loadedStore = shared
            loadedDocument = try shared.loadOrMigrate { try Self.legacyDocument() }
            Self.removeLegacyDefaults()
        } catch { loadError = error.localizedDescription }
        store = loadedStore
        storageError = loadError
        document = loadedDocument

        let sourceData = loadedDocument.draft?.selectionData ?? loadedDocument.configuration?.selectionData
        if let sourceData, let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: sourceData) {
            selection = decoded
            let storedMode = loadedDocument.draft?.mode ?? loadedDocument.configuration?.mode
            mode = RestrictionMode(rawValue: storedMode?.rawValue ?? "") ?? .allowOnlySelected
        } else {
            selection = FamilyActivitySelection(includeEntireCategory: true)
            mode = .allowOnlySelected
            if loadedDocument.configuration != nil { loadError = RuntimeValidationError.corruptSharedData.localizedDescription }
        }
        testScheduleActive = loadedDocument.testLockActive
        isConfigured = loadedDocument.configuration != nil
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        lastError = loadError ?? (loadedDocument.operationStatus.succeeded == false ? loadedDocument.operationStatus.detail : nil)
        recentDiagnostics = loadedDocument.diagnostics
        reconcileRegistration()
        reconcileManualRegistrationFromOS()
        retryInterruptedDailyRegistration()
        reconcilePendingManualRegistration()
        reconcileRuntime()
    }

    func refreshAuthorization() {
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        refreshDocument()
        reconcileRegistration()
        reconcileManualRegistrationFromOS()
        retryInterruptedDailyRegistration()
        reconcilePendingManualRegistration()
        reconcileRuntime()
        refreshDocument()
    }

    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            refreshAuthorization()
            if !isAuthorized { lastError = "Screen Time access was not approved." }
        } catch {
            authorizationStatus = AuthorizationCenter.shared.authorizationStatus
            refreshDocument()
            lastError = error.localizedDescription
        }
    }

    // MARK: Draft and saved schedule

    func setDraftMode(_ newMode: RestrictionMode) {
        guard isAuthorized else { lastError = "Screen Time access is not authorized."; return }
        guard !testScheduleActive else { lastError = "Finish the developer prototype restriction before editing."; return }
        do {
            let draft = try makeDraft(mode: RuntimeMode(rawValue: newMode.rawValue)!, start: draftStart, end: draftEnd, selection: selection)
            try persistDraft(draft); mode = newMode
        } catch { lastError = error.localizedDescription }
    }

    func setDraftStart(_ value: Date) { setDraftTime(start: components(from: value), end: endComponents) }
    func setDraftEnd(_ value: Date) { setDraftTime(start: startComponents, end: components(from: value)) }

    private func setDraftTime(start: DateComponents, end: DateComponents) {
        guard isAuthorized else { lastError = "Screen Time access is not authorized."; return }
        guard !testScheduleActive else { lastError = "Finish the developer prototype restriction before editing."; return }
        guard let sh = start.hour, let sm = start.minute, let eh = end.hour, let em = end.minute else { return }
        do {
            let draft = try makeDraft(mode: RuntimeMode(rawValue: mode.rawValue)!, start: RuntimeTime(hour: sh, minute: sm), end: RuntimeTime(hour: eh, minute: em), selection: selection)
            try persistDraft(draft)
        } catch { lastError = error.localizedDescription }
    }

    func commitSelection(_ draftSelection: FamilyActivitySelection) {
        guard isAuthorized else { lastError = "Screen Time access is not authorized."; return }
        guard !testScheduleActive else { lastError = "Finish the developer prototype restriction before editing."; return }
        do {
            let draft = try makeDraft(mode: RuntimeMode(rawValue: mode.rawValue)!, start: draftStart, end: draftEnd, selection: draftSelection)
            try persistDraft(draft); selection = draftSelection; lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    private func makeDraft(mode: RuntimeMode, start: RuntimeTime, end: RuntimeTime, selection: FamilyActivitySelection) throws -> RuntimeDraft {
        RuntimeDraft(start: start, end: end, mode: mode, selectionSummary: selectionSummary(selection), selectionData: try JSONEncoder().encode(selection))
    }

    private func persistDraft(_ draft: RuntimeDraft) throws {
        guard let store else { throw RuntimeValidationError.appGroupUnavailable }
        try store.transaction { document in
            guard document.activeOwner != .prototypeTest, !document.testLockActive else { throw RuntimeValidationError.invalidConfiguration("Finish the developer prototype restriction before editing.") }
            document.draft = draft
        }
        refreshDocument()
    }

    func saveConfiguration(start: DateComponents, end: DateComponents) {
        guard isAuthorized else { lastError = "Screen Time access is not authorized."; return }
        guard let store else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        guard !testScheduleActive, document.activeOwner != .prototypeTest else { lastError = "Finish the developer prototype restriction before changing the schedule."; return }
        // Expire a missed end before deciding whether this save is pending;
        // otherwise a stale shield could survive a same-process edit.
        reconcileRuntime()
        refreshDocument()
        guard !document.legacyRegistrationNeedsReview else { lastError = "Clean up the legacy registration before re-registering this schedule."; return }
        guard let sh = start.hour, let sm = start.minute, let eh = end.hour, let em = end.minute else { lastError = "Choose a valid bedtime window."; return }
        do {
            let runtimeMode = RuntimeMode(rawValue: mode.rawValue)!
            let summary = selectionSummary(selection)
            _ = try RuntimePolicyPlan.make(mode: runtimeMode, selection: summary)
            let configuration = RuntimeConfiguration(revision: (document.configuration?.revision ?? 0) + 1, start: RuntimeTime(hour: sh, minute: sm), end: RuntimeTime(hour: eh, minute: em), mode: runtimeMode, selectionSummary: summary, selectionData: try JSONEncoder().encode(selection))
            try configuration.validate()
            let draft = RuntimeDraft(start: configuration.start, end: configuration.end, mode: runtimeMode, selectionSummary: summary, selectionData: configuration.selectionData)
            var shouldRegister = false
            try store.transaction { document in
                guard document.activeOwner != .prototypeTest,
                      !document.testLockActive,
                      !document.legacyRegistrationNeedsReview else {
                    throw RuntimeValidationError.invalidConfiguration("Finish the developer prototype restriction before changing the schedule.")
                }
                let active = hasAnyCommittedSession(in: document, at: Date())
                if active {
                    document.pendingConfiguration = configuration
                    // Existing suppression/fence history belongs to the
                    // current civil occurrence and must survive ordinary edits.
                    document.draft = draft
                    document.record(RuntimeDiagnostic(operation: .configurationSaved, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "Validated configuration queued until committed sessions end."), succeeded: true)
                } else {
                    document.configuration = configuration
                    document.pendingConfiguration = nil
                    document.draft = draft
                    document.recurringEnabledIntent = false
                    document.record(RuntimeDiagnostic(operation: .configurationSaved, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "Validated draft saved; registration requested."), succeeded: true)
                    shouldRegister = true
                }
            }
            refreshDocument()
            if shouldRegister { registerConfiguredSchedule() }
            else { lastError = nil }
        } catch { lastError = error.localizedDescription }
    }

    func registerDailySchedule() {
        guard isAuthorized else { lastError = "Screen Time access is not authorized."; return }
        // registerConfiguredSchedule re-reads the document under the shared
        // lock; do not make a cached active-session snapshot authoritative.
        registerConfiguredSchedule()
    }

    private func registerConfiguredSchedule() {
        guard let store else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        guard let configuration = document.configuration else { lastError = "Save a valid bedtime configuration first."; return }
        guard !document.legacyRegistrationNeedsReview else { lastError = "Clean up the legacy registration before re-registering."; return }
        var replacingRegistration = false
        do {
            try store.transaction { document in
                guard document.configuration?.revision == configuration.revision, !hasAnyCommittedSession(in: document, at: Date()) else { throw RuntimeValidationError.invalidConfiguration("The saved configuration changed or a lock became active.") }
                document.recurringEnabledIntent = false
            }
            replacingRegistration = true
            activityCenter.stopMonitoring([Self.activityName])
            try store.withTransaction { context in
                guard let current = context.document.configuration, current.revision == configuration.revision,
                      !hasAnyCommittedSession(in: context.document, at: Date()), !context.document.testLockActive else {
                    throw RuntimeValidationError.invalidConfiguration("The saved configuration changed or is owned by another lock.")
                }
                context.document.recurringEnabledIntent = true
                context.document.record(RuntimeDiagnostic(operation: .registrationAttempted, requestedStart: current.start, requestedEnd: current.end, revision: current.revision, detail: "OS registration requested."))
                try context.commit()
            }
            let schedule = DeviceActivitySchedule(intervalStart: DateComponents(hour: configuration.start.hour, minute: configuration.start.minute), intervalEnd: DateComponents(hour: configuration.end.hour, minute: configuration.end.minute), repeats: true)
            try activityCenter.startMonitoring(Self.activityName, during: schedule)
            try store.transaction { document in
                guard document.configuration?.revision == configuration.revision else { throw RuntimeValidationError.invalidConfiguration("The saved configuration changed during registration.") }
                document.record(RuntimeDiagnostic(operation: .registrationSucceeded, observedAt: Date(), requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "OS accepted monitoring; callback delivery is not independently verified."), succeeded: true)
            }
            refreshDocument(); reconcileRegistration(); lastError = nil
        } catch {
            guard replacingRegistration else { refreshDocument(); reconcileRegistration(); lastError = error.localizedDescription; return }
            activityCenter.stopMonitoring([Self.activityName])
            try? store.transaction { document in
                guard document.configuration?.revision == configuration.revision else { return }
                document.recurringEnabledIntent = false
                document.record(RuntimeDiagnostic(operation: .registrationFailed, observedAt: Date(), requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: error.localizedDescription), succeeded: false)
            }
            refreshDocument(); reconcileRegistration(); lastError = error.localizedDescription
        }
    }

    // MARK: Developer prototype compatibility

    func startImmediateTestLock() {
        guard isAuthorized else { lastError = "Screen Time access is not authorized."; return }
        guard let store else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        reconcileRegistration()
        guard !hasOSRegistration else { lastError = "Stop recurring monitoring before starting the prototype test."; return }
        do {
            let plan = try policyPlan(for: selection, mode: mode)
            try store.withTransaction { context in
                guard !context.document.recurringEnabledIntent,
                      context.document.activeOwner == nil,
                      !context.document.legacyRegistrationNeedsReview,
                      !hasAnyCommittedSession(in: context.document, at: Date()) else {
                    throw RuntimeValidationError.invalidConfiguration("Stop recurring monitoring and resolve legacy cleanup before starting the prototype test.")
                }
                context.document.activeOwner = .prototypeTest
                context.document.testLockActive = true
                context.document.policyIntent = .apply
                context.document.record(RuntimeDiagnostic(operation: .policyApplyAttempted, revision: context.document.configuration?.revision, detail: "Prototype test ownership persisted before apply."))
                try context.commit()
                apply(plan: plan, selection: selection)
                context.document.policyIntent = nil
                context.document.record(RuntimeDiagnostic(operation: .policyApplied, revision: context.document.configuration?.revision, detail: "Prototype test policy application attempted."), succeeded: true)
                try context.commit()
            }
            refreshDocument(); lastError = nil
        } catch { refreshDocument(); lastError = error.localizedDescription }
    }

    func clearImmediateShield() {
        guard let store else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        do { try clearOwnedPrototypePolicy(store: store); refreshDocument(); lastError = nil }
        catch { refreshDocument(); lastError = error.localizedDescription }
    }

    func stopSchedule() {
        guard let store else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        reconcileRuntime()
        refreshDocument()
        var shouldStopMonitoring = false
        do {
            try store.withTransaction { context in
                let now = Date()
                _ = RuntimeLifecycle.expireNaturalSessions(&context.document, at: now)
                // This decision is deliberately made while holding the shared
                // transaction lock. A callback may have committed a session
                // after the coordinator's cached snapshot was read.
                let active = hasAnyCommittedSession(in: context.document, at: now)
                context.document.recurringEnabledIntent = false
                shouldStopMonitoring = !active
                context.document.record(RuntimeDiagnostic(operation: .configurationSaved, detail: active ? "Recurring schedule disabled for future occurrences; current committed session is unchanged." : "Recurring schedule disabled."), succeeded: true)
                try context.commit()
            }
            if shouldStopMonitoring { activityCenter.stopMonitoring([Self.activityName]) }
            refreshDocument(); lastError = nil
        } catch { refreshDocument(); lastError = error.localizedDescription }
    }

    /// Ultimate developer cleanup. Unlike normal recovery it intentionally
    /// resets all of this app's durable runtime state after stopping monitoring.
    func emergencyReset() {
        activityCenter.stopMonitoring([Self.activityName, Self.manualActivityName])
        guard let store else {
            settingsStore.clearAllSettings()
            lastError = "Monitoring stopped and named settings clearance was requested, but the App Group is unavailable; shared state was not cleared."
            return
        }
        do {
            try store.reset { settingsStore.clearAllSettings() }
            Self.removeLegacyDefaults()
            document = RuntimeStoreDocument()
            selection = FamilyActivitySelection(includeEntireCategory: true)
            mode = .allowOnlySelected
            testScheduleActive = false
            isConfigured = false
            recentDiagnostics = []
            storageError = nil
            lastError = nil
            reconcileRegistration()
        } catch {
            reconcileRegistration()
            lastError = "Monitoring was stopped, but reset did not complete. Restrictions may remain; retry Emergency reset. \(error.localizedDescription)"
        }
    }

    // MARK: Runtime reconciliation and policy adapter

    private func reconcileRuntime(at date: Date = Date()) {
        guard let store else { return }
        var shouldRegisterPending = false
        var shouldStopManual = false
        do {
            try store.withTransaction { context in
                var changed = RuntimeLifecycle.expireNaturalSessions(&context.document, at: date)
                if try reconcileCurrentScheduledOccurrence(&context.document, at: date) { changed = true }
                if RuntimeLifecycle.activatePendingConfigurationIfIdle(&context.document, at: date) { changed = true; shouldRegisterPending = context.document.recurringEnabledIntent }
                let effective = enforcementSessions(in: context.document, at: date)
                if !context.document.sessions.contains(where: { $0.origin == .manual && $0.isEffective(at: date) }) {
                    shouldStopManual = context.document.manualRegistrationActive || context.document.manualRegistrationIntent
                    context.document.manualRegistrationActive = false
                    context.document.manualRegistrationIntent = false
                }
                let mustClear = effective.isEmpty && !context.document.legacyRegistrationNeedsReview && (changed || context.document.policyIntent == .clear || context.document.activeOwner == .scheduled || context.document.activeOwner == .prototypeTest && context.document.policyIntent == .clear)
                let mustApply = isAuthorized && !effective.isEmpty
                let mustApplyLegacyPrototype = effective.isEmpty && !context.document.legacyRegistrationNeedsReview && context.document.activeOwner == .prototypeTest && context.document.policyIntent == .apply
                // A manual registration intent with no OS-accepted route is not
                // permission to apply an unbounded shield. Replay registration
                // first; apply is allowed only once a session is enforceable.
                guard mustClear || mustApply || mustApplyLegacyPrototype else { return }
                context.document.policyIntent = mustClear ? .clear : .apply
                context.document.record(RuntimeDiagnostic(operation: mustClear ? .policyClearAttempted : .policyApplyAttempted, observedAt: date, detail: "Runtime reconciliation intent persisted before policy adapter."))
                try context.commit()
                try applyEffectivePolicy(context.document, at: date)
                context.document.policyIntent = nil
                if !mustApplyLegacyPrototype {
                    context.document.activeOwner = nil
                    context.document.testLockActive = false
                }
                context.document.record(RuntimeDiagnostic(operation: mustClear ? .policyCleared : .policyApplied, observedAt: Date(), detail: mustClear ? "Runtime reconciliation cleared this app's named policy." : (mustApplyLegacyPrototype ? "Runtime reconciliation replayed the developer prototype policy." : "Runtime reconciliation applied frozen active policy.")), succeeded: true)
                try context.commit()
            }
            if shouldStopManual { activityCenter.stopMonitoring([Self.manualActivityName]) }
            if shouldRegisterPending { registerConfiguredSchedule() }
            refreshDocument()
        } catch {
            refreshDocument()
            lastError = "State reconciliation needs attention: \(error.localizedDescription)"
        }
    }

    private func retryInterruptedDailyRegistration() {
        guard isAuthorized, document.recurringEnabledIntent, !scheduleIsRegistered,
              !hasAnyCommittedSession(at: Date()), !document.legacyRegistrationNeedsReview else { return }
        // Registration intent was durable before the OS call. A relaunch after
        // that boundary retries once through the same replacement path rather
        // than trusting a stale local flag.
        registerConfiguredSchedule()
    }

    private func reconcileManualRegistrationFromOS() {
        guard let store else { return }
        let now = Date()
        guard activityCenter.activities.contains(Self.manualActivityName),
              let registered = activityCenter.schedule(for: Self.manualActivityName) else {
            // Never trust a persisted active bit as an end route. If the OS
            // no longer reports the one-off registration, retire that manual
            // session and reconcile any remaining scheduled policy instead of
            // leaving an unbounded shield.
            if document.manualRegistrationActive {
                try? store.transaction { context in
                    for index in context.sessions.indices where context.sessions[index].origin == .manual && context.sessions[index].isEffective(at: now) {
                        context.sessions[index].state = .expired
                    }
                    context.manualRegistrationActive = false
                    context.manualRegistrationIntent = false
                    context.policyIntent = context.effectiveSessions(at: now).isEmpty ? .clear : .apply
                }
                reconcileRuntime()
            }
            return
        }
        var shouldStopStaleRegistration = false
        do {
            try store.transaction { context in
                guard let session = context.sessions.first(where: {
                    $0.origin == .manual && $0.isEffective(at: now) && now < $0.end
                }) else {
                    context.manualRegistrationActive = false
                    context.manualRegistrationIntent = false
                    shouldStopStaleRegistration = true
                    return
                }
                let end = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: session.end)
                let matches = registered.repeats == false
                    && registered.intervalEnd.hour == end.hour
                    && registered.intervalEnd.minute == end.minute
                    && (registered.intervalEnd.year == nil || registered.intervalEnd.year == end.year)
                    && (registered.intervalEnd.month == nil || registered.intervalEnd.month == end.month)
                    && (registered.intervalEnd.day == nil || registered.intervalEnd.day == end.day)
                guard matches else {
                    context.manualRegistrationActive = false
                    context.manualRegistrationIntent = true
                    return
                }
                // OS registration is the end route; persisted booleans are
                // repaired from it rather than trusted after relaunch.
                context.manualRegistrationIntent = false
                context.manualRegistrationActive = true
            }
            if shouldStopStaleRegistration { activityCenter.stopMonitoring([Self.manualActivityName]) }
        } catch { lastError = error.localizedDescription }
    }

    private func reconcilePendingManualRegistration() {
        guard let store, let pending = document.sessions.first(where: { $0.origin == .manual && $0.isEffective && document.manualRegistrationIntent && !document.manualRegistrationActive }) else { return }
        let now = Date()
        guard pending.end > now, pending.end.timeIntervalSince(now) >= Self.minimumScheduledDuration else {
            // There is no safe minimum-length OS route left after a crash;
            // reject the pending lock instead of applying an unbounded shield.
            try? store.transaction { document in
                for index in document.sessions.indices where document.sessions[index].id == pending.id {
                    document.sessions[index].state = .expired
                }
                document.manualRegistrationIntent = false
                document.manualRegistrationActive = false
                document.policyIntent = nil
                document.record(RuntimeDiagnostic(operation: .registrationFailed, observedAt: now, detail: "Pending manual lock expired before a safe OS-managed registration could be replayed."), succeeded: false)
            }
            return
        }
        do {
            // The original start may be in the past after a crash. The session
            // end remains frozen, while the OS registration starts from now.
            try activityCenter.startMonitoring(Self.manualActivityName, during: manualSchedule(start: Date(), end: pending.end))
            try store.transaction { document in
                guard document.sessions.contains(where: { $0.id == pending.id && $0.state == .active }) else { return }
                document.manualRegistrationIntent = false
                document.manualRegistrationActive = true
                document.record(RuntimeDiagnostic(operation: .registrationSucceeded, requestedEnd: RuntimeTime(hour: Calendar.current.component(.hour, from: pending.end), minute: Calendar.current.component(.minute, from: pending.end)), detail: "Pending finite manual registration replayed."), succeeded: true)
            }
            reconcileRuntime()
        } catch { lastError = error.localizedDescription }
    }

    private func applyEffectivePolicy(_ state: RuntimeStoreDocument, at date: Date) throws {
        let sessions = enforcementSessions(in: state, at: date)
        guard !sessions.isEmpty else {
            if state.activeOwner == .prototypeTest, state.policyIntent == .apply {
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
            for item in selections {
                applications.formUnion(item.applicationTokens)
                categories.formUnion(item.categoryTokens)
                webDomains.formUnion(item.webDomainTokens)
            }
            settingsStore.shield.applications = applications.isEmpty ? nil : applications
            settingsStore.shield.applicationCategories = categories.isEmpty ? nil : .specific(categories)
            settingsStore.shield.webDomains = webDomains.isEmpty ? nil : webDomains
            settingsStore.shield.webDomainCategories = nil
        case .allowOnlySelected:
            guard let first = selections.first else { settingsStore.clearAllSettings(); return }
            var applications = first.applicationTokens
            var webDomains = first.webDomainTokens
            for item in selections.dropFirst() {
                applications.formIntersection(item.applicationTokens)
                webDomains.formIntersection(item.webDomainTokens)
            }
            guard !applications.isEmpty else { throw RuntimeValidationError.overlapUnsupported }
            settingsStore.shield.applications = nil
            settingsStore.shield.applicationCategories = .all(except: applications)
            settingsStore.shield.webDomains = nil
            settingsStore.shield.webDomainCategories = .all(except: webDomains)
        }
    }

    private func reconcileCurrentScheduledOccurrence(_ state: inout RuntimeStoreDocument, at date: Date) throws -> Bool {
        guard isAuthorized,
              state.recurringEnabledIntent,
              let configuration = state.configuration,
              let registered = activityCenter.schedule(for: Self.activityName),
              activityCenter.activities.contains(Self.activityName),
              RuntimeScheduleDecision.registrationMatches(configuration: configuration, start: registered.intervalStart, end: registered.intervalEnd, repeats: registered.repeats),
              let occurrence = RuntimeOccurrenceResolver.candidates(start: configuration.start, end: configuration.end, around: date).first(where: { date >= $0.start && date < $0.end }) else { return false }
        if RuntimeLifecycle.shouldSuppressScheduledOccurrence(state, start: occurrence.start, end: occurrence.end) { return false }
        if RuntimeSessionDecision.isReleased(sessions: state.sessions, releasedOccurrences: state.releasedOccurrences, origin: .scheduled, start: occurrence.start, end: occurrence.end) { return false }
        if state.sessions.contains(where: { $0.origin == .scheduled && $0.isEffective(at: date) }) { return false }
        if state.sessions.contains(where: { $0.origin == .scheduled && $0.start == occurrence.start && $0.end == occurrence.end }) { return false }
        let snapshot = RuntimePolicySnapshot(mode: configuration.mode, selectionSummary: configuration.selectionSummary, selectionData: configuration.selectionData)
        try snapshot.validate()
        let savedSelection = try JSONDecoder().decode(FamilyActivitySelection.self, from: configuration.selectionData)
        guard selectionSummary(savedSelection) == configuration.selectionSummary else { throw RuntimeValidationError.corruptSharedData }
        RuntimeLifecycle.pruneTerminalSessions(&state)
        let session = RuntimeSession(origin: .scheduled, start: occurrence.start, end: occurrence.end, sourceRevision: configuration.revision, policy: snapshot)
        state.sessions.append(session)
        do { _ = try RuntimeSessionDecision.composedMode(for: RuntimeSessionDecision.activeSessions(state.sessions, at: date)) }
        catch {
            state.sessions.removeAll { $0.id == session.id }
            state.record(RuntimeDiagnostic(operation: .conflictRejected, observedAt: date, detail: "Foreground scheduled start rejected: mixed restriction modes cannot be safely composed."), succeeded: false)
            return false
        }
        state.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: date, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "Foreground reconciliation committed the current scheduled occurrence."), succeeded: true)
        return true
    }

    private func enforcementSessions(in state: RuntimeStoreDocument, at date: Date) -> [RuntimeSession] {
        state.sessions.filter { session in
            guard session.isEffective(at: date) else { return false }
            return session.origin != .manual || state.manualRegistrationActive
        }
    }

    private func enforcementSessions(at date: Date) -> [RuntimeSession] { enforcementSessions(in: document, at: date) }
    private func hasAnyCommittedSession(in state: RuntimeStoreDocument, at date: Date) -> Bool { state.sessions.contains { $0.isEffective(at: date) } }
    private func hasAnyCommittedSession(at date: Date) -> Bool { hasAnyCommittedSession(in: document, at: date) }

    private func proposedManualEnd(at date: Date) -> Date? {
        guard let configuration = document.configuration else { return nil }
        let occurrence = RuntimeOccurrenceResolver.currentOrNext(start: configuration.start, end: configuration.end, enabled: true, after: date)
        guard let end = occurrence?.end, end > date, end.timeIntervalSince(date) >= Self.minimumScheduledDuration else { return nil }
        return end
    }

    private func manualSchedule(start: Date, end: Date) -> DeviceActivitySchedule {
        let calendar = Calendar.current
        // The persisted session end is authoritative. Do not add a minute to
        // the registration start: doing so can turn an otherwise valid 15+
        // minute session into an OS-rejected interval.
        let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        let endComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: end)
        return DeviceActivitySchedule(intervalStart: startComponents, intervalEnd: endComponents, repeats: false)
    }

    private func clearOwnedPrototypePolicy(store: SharedRuntimeStore) throws {
        try store.withTransaction { context in
            guard context.document.activeOwner == .prototypeTest else { throw RuntimeValidationError.invalidConfiguration("No verified prototype policy owner is present; nothing was cleared.") }
            context.document.policyIntent = .clear
            context.document.record(RuntimeDiagnostic(operation: .policyClearAttempted, revision: context.document.configuration?.revision, detail: "Prototype cleanup intent persisted before clear."))
            try context.commit()
            settingsStore.clearAllSettings()
            context.document.activeOwner = nil
            context.document.policyIntent = nil
            context.document.testLockActive = false
            context.document.record(RuntimeDiagnostic(operation: .policyCleared, revision: context.document.configuration?.revision, detail: "Prototype policy cleanup completed."), succeeded: true)
            try context.commit()
        }
    }

    private func policyPlan(for selection: FamilyActivitySelection, mode: RestrictionMode) throws -> RuntimePolicyPlan {
        try RuntimePolicyPlan.make(mode: RuntimeMode(rawValue: mode.rawValue)!, selection: selectionSummary(selection))
    }

    private func selectionSummary(_ selection: FamilyActivitySelection) -> RuntimeSelectionSummary {
        RuntimeSelectionSummary(applicationCount: selection.applicationTokens.count, categoryCount: selection.categoryTokens.count, webDomainCount: selection.webDomainTokens.count)
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

    private func reconcileRegistration() {
        let schedule = activityCenter.schedule(for: Self.activityName)
        hasOSRegistration = activityCenter.activities.contains(Self.activityName) && schedule != nil
        if let schedule, let configuration = document.configuration {
            scheduleIsRegistered = hasOSRegistration && RuntimeScheduleDecision.registrationMatches(configuration: configuration, start: schedule.intervalStart, end: schedule.intervalEnd, repeats: schedule.repeats)
        } else { scheduleIsRegistered = false }
    }

    private func refreshDocument() {
        guard let store else { return }
        do {
            document = try store.read()
            let source = document.draft?.selectionData ?? document.configuration?.selectionData
            if let source, let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: source) {
                selection = decoded
                let storedMode = document.draft?.mode ?? document.configuration?.mode
                if let storedMode { mode = RestrictionMode(rawValue: storedMode.rawValue) ?? mode }
            }
            recentDiagnostics = document.diagnostics
            isConfigured = document.configuration != nil
            testScheduleActive = document.testLockActive
            storageError = nil
            if document.operationStatus.succeeded == false { lastError = document.operationStatus.detail }
        } catch { storageError = error.localizedDescription; lastError = storageError }
    }

    private func components(from date: Date) -> DateComponents { Calendar.current.dateComponents([.hour, .minute], from: date) }

    private static func legacyDocument() throws -> RuntimeStoreDocument {
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        var document = RuntimeStoreDocument()
        guard let defaults else { return document }
        let hasLegacy = ["familyActivitySelection", "restrictionMode", "bedtimeStartHour", "bedtimeStartMinute", "bedtimeEndHour", "bedtimeEndMinute", "scheduleConfigured", "testLockActive"].contains { defaults.object(forKey: $0) != nil }
        guard hasLegacy else { return document }
        let data = try defaults.data(forKey: "familyActivitySelection") ?? JSONEncoder().encode(FamilyActivitySelection(includeEntireCategory: true))
        let modeRaw = defaults.string(forKey: "restrictionMode")
        let mode = RuntimeMode(rawValue: modeRaw ?? "allowOnlySelected") ?? .allowOnlySelected
        let modeIsValid = modeRaw == nil || RuntimeMode(rawValue: modeRaw!) != nil
        let sh = defaults.object(forKey: "bedtimeStartHour") as? Int ?? 22
        let sm = defaults.object(forKey: "bedtimeStartMinute") as? Int ?? 0
        let eh = defaults.object(forKey: "bedtimeEndHour") as? Int ?? 7
        let em = defaults.object(forKey: "bedtimeEndMinute") as? Int ?? 0
        if let saved = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            let summary = RuntimeSelectionSummary(applicationCount: saved.applicationTokens.count, categoryCount: saved.categoryTokens.count, webDomainCount: saved.webDomainTokens.count)
            document.draft = RuntimeDraft(start: RuntimeTime(hour: sh, minute: sm), end: RuntimeTime(hour: eh, minute: em), mode: mode, selectionSummary: summary, selectionData: data)
            if defaults.bool(forKey: "scheduleConfigured") {
                let candidate = RuntimeConfiguration(revision: 1, start: RuntimeTime(hour: sh, minute: sm), end: RuntimeTime(hour: eh, minute: em), mode: mode, selectionSummary: summary, selectionData: data)
                if modeIsValid, (try? candidate.validate()) != nil { document.configuration = candidate }
                document.legacyRegistrationNeedsReview = true
            }
        } else if defaults.bool(forKey: "scheduleConfigured") { document.legacyRegistrationNeedsReview = true }
        if defaults.bool(forKey: "testLockActive") {
            document.activeOwner = .prototypeTest
            document.testLockActive = true
            document.policyIntent = .apply
        }
        let migrationSafe = modeIsValid && (try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)) != nil
        if !migrationSafe { document.legacyRegistrationNeedsReview = true }
        document.record(RuntimeDiagnostic(operation: .legacyMigration, detail: migrationSafe ? (document.legacyRegistrationNeedsReview ? "Legacy settings migrated; registration owner requires explicit cleanup." : "Legacy draft settings migrated.") : "Legacy settings retained for explicit cleanup; invalid values were not used for enforcement."), succeeded: migrationSafe)
        return document
    }

    private static func removeLegacyDefaults() {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        ["familyActivitySelection", "restrictionMode", "bedtimeStartHour", "bedtimeStartMinute", "bedtimeEndHour", "bedtimeEndMinute", "scheduleConfigured", "testLockActive"].forEach { defaults.removeObject(forKey: $0) }
    }
}

private extension RuntimePolicySnapshot {
    func validated() throws -> RuntimePolicySnapshot { try validate(); return self }
}

private extension ScreenTimeCoordinator {
    /// FamilyControls selection archives are not a semantic identity: two
    /// JSON encodes can differ while carrying the same token sets. Overlap
    /// safety therefore compares decoded snapshots, never Data bytes.
    func policiesAreSemanticallyEqual(_ lhs: RuntimePolicySnapshot, _ rhs: RuntimePolicySnapshot) throws -> Bool {
        guard lhs.mode == rhs.mode, lhs.selectionSummary == rhs.selectionSummary else { return false }
        let left = try JSONDecoder().decode(FamilyActivitySelection.self, from: lhs.selectionData)
        let right = try JSONDecoder().decode(FamilyActivitySelection.self, from: rhs.selectionData)
        return left.applicationTokens == right.applicationTokens
            && left.categoryTokens == right.categoryTokens
            && left.webDomainTokens == right.webDomainTokens
    }
}
