import Combine
import DeviceActivity
import FamilyControls
import ManagedSettings
import Foundation
import AmbientKit
#if canImport(UserNotifications)
import UserNotifications
#endif

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
    private static let minimumScheduledDuration = RuntimeManualLockDecision.minimumDuration
    private static let defaultManualDuration: TimeInterval = 30 * 60
    private static let maximumManualDuration = RuntimeManualLockDecision.maximumDuration
    private static let ambientDefaultsPrefix = "phone-lockbox.ambient."
    private static let windDownEnabledKey = ambientDefaultsPrefix + "wind-down-enabled"
    private static let windDownLeadMinutesKey = ambientDefaultsPrefix + "wind-down-lead-minutes"
    /// One encoded value is the commit boundary for this preference. The
    /// former enabled/version keys remain named so they can be removed only
    /// after a complete record has been written.
    private static let liveActivityPreferenceKey = ambientDefaultsPrefix + "live-activity-preference"
    private static let legacyLiveActivityEnabledKey = ambientDefaultsPrefix + "live-activity-enabled"
    private static let legacyLiveActivityPreferenceVersionKey = ambientDefaultsPrefix + "live-activity-preference-version"
    private static let legacyLiveActivityDiagnosticsKey = "phone-lockbox.ambient.live-activity-termination-diagnostics"
    private static let legacyLiveActivityDiagnosticsLockFile = "phone-lockbox-ambient-diagnostics.lock"
    /// This value contains only SafetyAssistantAcknowledgements' checklist
    /// identifiers and schema version. It deliberately never shares the
    /// configuration blob or FamilyControls selection data.
    private static let safetyAssistantAcknowledgementsKey = "phone-lockbox.safety-assistant-acknowledgements"

    @Published private(set) var authorizationStatus: AuthorizationStatus = .notDetermined
    @Published private(set) var selection: FamilyActivitySelection
    @Published private(set) var mode: RestrictionMode
    @Published private(set) var scheduleIsRegistered = false
    @Published private(set) var hasOSRegistration = false
    @Published private(set) var testScheduleActive: Bool
    @Published private(set) var lastError: String?
    @Published private(set) var isConfigured: Bool
    @Published private(set) var recentDiagnostics: [RuntimeDiagnostic] = []
    /// Ambient state is deliberately separate from enforcement errors. A
    /// notification or Live Activity failure must never make a committed lock
    /// appear released or roll back a lifecycle transaction.
    @Published private(set) var windDownEnabled = false
    @Published private(set) var windDownLeadMinutes = 30
    @Published private(set) var liveActivityEnabled = false
    @Published private(set) var ambientError: String?
    /// A parsed quick action is only a request to present existing UI. It is
    /// consumed by the Lockbox tab and never represents an applied policy.
    @Published private(set) var pendingQuickAction: PendingQuickAction?
    /// Review P1: set once by `ContentView` to switch to the Lockbox tab
    /// and clear any stale recovery path. Called synchronously, inside
    /// `processPendingQuickActionRoute`'s `present` callback, strictly
    /// *before* `pendingQuickAction` is assigned (and therefore before
    /// `objectWillChange` fires for it) — never reactively from an
    /// `onChange` keyed to the same publish. That ordering is what this
    /// exists to guarantee: a sibling `onChange(of: pendingQuickAction)` in
    /// `LockboxTabView` consumes the new value by appending `.recovery` to
    /// the nav path, and SwiftUI does not define which of two `onChange`
    /// handlers observing the same change runs first — so a *reactive*
    /// reset in `ContentView` could run after `LockboxTabView`'s and pop
    /// the just-appended destination (or clear a path whose append hasn't
    /// happened yet, leaving it to land on top of a tab ContentView is
    /// about to leave). Firing before the publish removes the ordering
    /// question entirely. This single closure, invoked from one place
    /// inside the coordinator, is what reaches *every* path that can
    /// present a route — `.task`, scene activation, `onOpenURL`, and the
    /// delivery broker's own lease-deadline retry timer re-entering
    /// `present` on its own with no `ContentView` call in between.
    var onWillPresentQuickAction: (() -> Void)?
    @Published private(set) var pendingWindDownNotificationCount = 0
    @Published private(set) var windDownAuthorizationStatus = "Not requested"
    @Published private(set) var safetyAssistantAcknowledgements = SafetyAssistantAcknowledgements()

    private let activityCenter = DeviceActivityCenter()
    private let clock: () -> Date
#if canImport(UserNotifications)
    private let windDownScheduler = WindDownNotificationScheduler()
#endif
#if canImport(ActivityKit)
    private let liveActivity = LockboxLiveActivityAdapter()
#endif
    private let settingsStore = ManagedSettingsStore(named: ManagedSettingsStore.Name("phone-lockbox"))
    private let store: SharedRuntimeStore?
    private var document: RuntimeStoreDocument
    private var storageError: String?
    /// A reconciliation failure remains visible until a later reconciliation
    /// succeeds; an unrelated successful UI action must not erase it.
    private var reconciliationError: String?
    private var quickActionDelivery = QuickActionDeliveryGate()
    private let quickActionBroker: QuickActionDeliveryBroker

    /// The durable route identity and claim stay attached to a delivery from
    /// queue claim through UI dismissal. Keeping both values here prevents a
    /// stale callback from acknowledging a re-leased route or settling a
    /// newer presentation after a crash or scene teardown.
    struct PendingQuickAction: Equatable, Sendable {
        let id: String
        let action: QuickActionRoute.Action
        let claim: QuickActionPendingRouteStore.Claim

        var deliveryIdentity: QuickActionDeliveryGate.Identity {
            QuickActionDeliveryGate.Identity(id: id, action: action)
        }
    }

    var selectedItemCount: Int { selection.applicationTokens.count + selection.categoryTokens.count + selection.webDomainTokens.count }
    var canApplySelection: Bool { (try? policyPlan(for: selection, mode: mode)) != nil }

    /// A privacy-minimal input for the local Safety Assistant. Only the saved
    /// mode and opaque selection counts leave this coordinator; token values
    /// and app identifiers never enter the assistant model or its storage.
    var safetyAssistantAudit: SafetyAssistantAudit {
        let configuration = document.configuration
        let registration: SafetyAssistantRegistrationState
        if hasOSRegistration && !scheduleIsRegistered {
            registration = .mismatch
        } else if scheduleIsRegistered && document.recurringEnabledIntent {
            registration = .matching
        } else {
            registration = .notRegistered
        }
        return SafetyAssistantAudit.evaluate(
            input: SafetyAssistantAuditInput(
                mode: configuration?.mode,
                selection: configuration?.selectionSummary,
                authorization: isAuthorized ? .authorized : .unavailable,
                registration: registration
            ),
            acknowledgements: safetyAssistantAcknowledgements
        )
    }

    func setSafetyAssistantChecklistAcknowledged(_ item: SafetyAssistantChecklistItem, acknowledged: Bool) {
        var updated = safetyAssistantAcknowledgements
        if acknowledged { updated.checklist.insert(item) } else { updated.checklist.remove(item) }
        persistSafetyAssistantAcknowledgements(updated)
    }

    func setSafetyAssistantTestStepAcknowledged(_ step: SafetyAssistantTestStep, acknowledged: Bool) {
        var updated = safetyAssistantAcknowledgements
        if acknowledged { updated.testSteps.insert(step) } else { updated.testSteps.remove(step) }
        persistSafetyAssistantAcknowledgements(updated)
    }

    private func persistSafetyAssistantAcknowledgements(_ value: SafetyAssistantAcknowledgements) {
        guard (try? value.validated()) != nil,
              let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: Self.safetyAssistantAcknowledgementsKey)
        safetyAssistantAcknowledgements = value
    }
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
        !enforcementSessions(at: currentDate()).isEmpty
    }

    var activeLockEnd: Date? {
        enforcementSessions(at: currentDate()).map(\.end).max()
    }

    var activeSessionCount: Int {
        enforcementSessions(at: currentDate()).count
    }

    var activeLockTitle: String {
        RuntimeLockPresentation.activeTitle(for: enforcementSessions(at: currentDate()))
    }

    var activeLockOriginSummary: String {
        RuntimeLockPresentation.originSummary(for: enforcementSessions(at: currentDate()))
    }

    /// Read-only identity for the trusted-person companion prototype (R5,
    /// Slice B1). It never mutates coordinator state and is `nil` unless
    /// there is exactly one active enforcement session, since a companion
    /// "ask to end early" request targets one exact current session only.
    /// `activeSetID` is a stable digest of the session's restricted-app
    /// selection so a later approval binds to the set that was actually
    /// active, not merely to a session identifier.
    var companionActiveSessionIdentity: (sessionID: String, activeSetID: String, start: Date, end: Date)? {
        let sessions = enforcementSessions(at: currentDate())
        guard sessions.count == 1, let session = sessions.first else { return nil }
        return (session.id.uuidString, Self.companionActiveSetID(for: sessions), session.start, session.end)
    }

    /// Derived from session **identity only** — never from
    /// `RuntimeSession.policy.selectionData` (the restricted app/category
    /// selection). A companion request must not be able to fingerprint which
    /// apps are blocked, even indirectly through a hash.
    ///
    /// R5 Slice B2c: delegates to the pure `RuntimeActiveSet.id(for:)` in
    /// `Shared/RuntimeFriendRelease.swift`, which must stay byte-identical to
    /// (and now is the single source of truth for) this algorithm.
    static func companionActiveSetID(for sessions: [RuntimeSession]) -> String {
        RuntimeActiveSet.id(for: sessions.map(\.id))
    }

    // MARK: R5 Slice B2c — friend-release wiring
    //
    // CompanionKit stays app-only: every value crossing this boundary is a
    // plain String/UUID/Date (RuntimeFriendReleaseIntent, RuntimeFriendRelease
    // outcomes), never a CompanionKit type. `CompanionCoordinator` builds and
    // verifies the signed `Approval`/`use` round trip; this coordinator only
    // ever records/applies/abandons the durable intent under the shared
    // transaction lock, using its own injected clock.

    /// The per-session state the People tab needs under the developer gate.
    /// Computed fresh from the document on every call, never cached. This is
    /// a coarse, UI-facing read: the authoritative recheck happens inside
    /// `RuntimeLifecycle.prepareFriendRelease`/`applyFriendRelease` at the
    /// moment of an actual attempt.
    enum FriendReleaseSessionState: Equatable {
        /// The session is still active/recoveryPending and not already
        /// targeted by a pending intent — "End lock now" may be offered.
        case eligible
        /// A friend-release intent for this exact session is durably pending
        /// (prepared but not yet applied, or interrupted mid-flight).
        case finishing
        /// A released marker exists for this session with cause
        /// `.friendApproval` — the approval was actually used to end it.
        case usedToEnd
        /// The session ended some other way (natural end, recovery,
        /// developer unlock), or the session ID is unknown entirely.
        case alreadyEnded
    }

    /// The durable friend-release intent awaiting a verified `use`, if any.
    /// Read-only; `nil` when nothing is pending. Used by `CompanionCoordinator`
    /// to drive the foreground replay (retry `use` with the same `useID`, then
    /// continue to apply) without ever starting a new release automatically.
    var pendingFriendReleaseIntent: RuntimeFriendReleaseIntent? { document.pendingFriendRelease }

    func friendReleaseSessionState(sessionID: String) -> FriendReleaseSessionState {
        guard let uuid = UUID(uuidString: sessionID) else { return .alreadyEnded }
        if let pending = document.pendingFriendRelease, pending.sessionID == uuid {
            return .finishing
        }
        if let released = document.releasedOccurrences.first(where: { $0.sessionID == uuid }) {
            return released.cause == .friendApproval ? .usedToEnd : .alreadyEnded
        }
        // R5 Slice B2c review (P2-6): matches `prepareFriendRelease`'s own
        // eligibility check exactly — the live enforcement set, not merely
        // `isEffective`. A manual session that is `isEffective` but not yet
        // `manualRegistrationActive` is not actually enforcing and must not
        // read as eligible here either.
        let now = currentDate()
        let enforcementIDs = Set(RuntimeSessionDecision.enforcementSessions(in: document, at: now).map(\.id))
        if enforcementIDs.contains(uuid) {
            return .eligible
        }
        return .alreadyEnded
    }

    /// The exact `useID` that released this session via a friend approval,
    /// if any. `nil` when the session is not released-by-friend-approval
    /// (not yet released, released by a different cause, or unknown).
    /// Exposed so a caller can confirm a specific *request* — not just a
    /// session — was the one that actually ended the lock, since several
    /// requests could in principle target the same session but only one
    /// `useID` ever actually releases it (R5 Slice B2c review, P2-6).
    func friendReleaseUseID(forSessionID sessionID: String) -> String? {
        guard let uuid = UUID(uuidString: sessionID) else { return nil }
        guard let released = document.releasedOccurrences.first(where: { $0.sessionID == uuid }),
              released.cause == .friendApproval else { return nil }
        return released.friendUseID
    }

    /// The frozen absolute end of an exact session, for People tab
    /// confirmation/status copy, regardless of how many sessions are
    /// concurrently enforcing (unlike `companionActiveSessionIdentity`, which
    /// is only populated for exactly one active session). `nil` when the
    /// session is unknown to this document.
    func sessionEnd(forSessionID sessionID: String) -> Date? {
        guard let uuid = UUID(uuidString: sessionID) else { return nil }
        return document.sessions.first(where: { $0.id == uuid })?.end
    }

    /// Persists a durable intent to release exactly one session once the
    /// caller's relay `use` call is verified. Runs under the shared
    /// transaction lock using this coordinator's injected clock, mirroring
    /// every other lifecycle mutation here. Every failure path inside
    /// `RuntimeLifecycle.prepareFriendRelease` is a calm `.noOp`, never a
    /// throw; this method itself only throws for a local storage failure
    /// (no App Group, lock busy), which is a different, non-relay failure
    /// the caller must handle separately from a `.noOp` outcome.
    func prepareFriendRelease(
        sessionID: UUID,
        activeSetID: String,
        requestID: String,
        approvalID: String,
        useID: String,
        approverIdentityID: String
    ) throws -> RuntimeFriendRelease.PrepareOutcome {
        let store = try requireStore()
        var outcome: RuntimeFriendRelease.PrepareOutcome = .noOp(.alreadyEnded)
        try store.withTransaction { context in
            let now = currentDate()
            let intent = RuntimeFriendReleaseIntent(
                sessionID: sessionID,
                activeSetID: activeSetID,
                requestID: requestID,
                approvalID: approvalID,
                useID: useID,
                approverIdentityID: approverIdentityID,
                createdAt: now
            )
            outcome = RuntimeLifecycle.prepareFriendRelease(&context.document, intent: intent, at: now, calendar: Calendar.current)
            try context.commit()
        }
        refreshDocument()
        return outcome
    }

    /// Applies a previously prepared friend release once its `use` has been
    /// verified. Mirrors `confirmRecovery`'s ordering exactly: set the policy
    /// intent and record `.policyClearAttempted`, commit, `applyEffectivePolicy`,
    /// clear the intent and record `.policyCleared`, commit — then stop only
    /// the released session's own manual route generation and, exactly as
    /// `confirmRecovery` does, activate and re-register a pending
    /// configuration if the store is now idle. Every `.noOp` outcome is
    /// terminal: the durable intent is already cleared inside
    /// `RuntimeLifecycle.applyFriendRelease`, so this is never retried.
    func applyFriendRelease(useID: String) throws -> RuntimeFriendRelease.ApplyOutcome {
        let store = try requireStore()
        var outcome: RuntimeFriendRelease.ApplyOutcome = .noOp(.noMatchingPendingIntent)
        var manualRouteToStop: RuntimeManualRouteBinding?
        var shouldRegisterPending = false
        var shouldReconcileAfterNoOp = false
        do {
            try store.withTransaction { context in
                let now = currentDate()
                let result = RuntimeLifecycle.applyFriendRelease(&context.document, useID: useID, at: now, calendar: Calendar.current)
                outcome = result
                switch result {
                case .noOp(let reason):
                    if reason == .alreadyEnded { shouldReconcileAfterNoOp = true }
                    try context.commit()
                case .released(let sessionID, _, let effect):
                    manualRouteToStop = effect.manualRouteToStop
                    if RuntimeLifecycle.activatePendingConfigurationIfIdle(&context.document, at: now) {
                        shouldRegisterPending = context.document.recurringEnabledIntent
                    }
                    // `effect.policyIntent` is already the correct post-release
                    // decision (Shared/RuntimeFriendRelease.swift); it is used
                    // directly rather than re-derived here.
                    context.document.policyIntent = effect.policyIntent
                    context.document.record(RuntimeDiagnostic(operation: .policyClearAttempted, observedAt: now, detail: "Friend-release persisted for session \(sessionID.uuidString), use \(useID), before reconciling this app's named policy."))
                    try context.commit()
                    try applyEffectivePolicy(context.document, at: now)
                    context.document.policyIntent = nil
                    context.document.record(RuntimeDiagnostic(operation: .policyCleared, observedAt: currentDate(), detail: "Friend-release applied for use \(useID); future occurrences remain configured."), succeeded: true)
                    try context.commit()
                }
            }
        } catch {
            // R5 Slice B2c review (P1-2): mirrors `confirmRecovery`. A throw
            // here (most likely `applyEffectivePolicy`, after the release
            // itself was already durably committed by the first `commit()`
            // above) must not leave this coordinator's in-memory `document`
            // stale relative to what is actually on disk.
            reconcileRuntime()
            refreshDocument()
            throw error
        }
        // R5 Slice B2c review (P1-2): a no-op because natural end (or
        // another release) already won between prepare and apply can leave
        // other reconciliation (OS registration, policy intent) out of sync
        // with the newly-expired session; resync exactly as other natural-
        // end-observing paths do.
        if shouldReconcileAfterNoOp {
            reconcileRuntime()
        }
        if let manualRouteToStop {
            do {
                try stopManualRouteIfOwned(store: store, expected: manualRouteToStop)
            } catch {
                // R5 Slice B2c review (P1-2): non-fatal. The release itself
                // is already durably committed by this point; a failed OS
                // manual-route stop only means monitoring cleanup needs a
                // later reconciliation, and must never be reported as the
                // release itself having failed.
                try? store.transaction { document in
                    document.record(RuntimeDiagnostic(operation: .registrationFailed, observedAt: currentDate(), detail: "Friend-release manual route stop failed after a committed release for use \(useID): \(error.localizedDescription)"), succeeded: false)
                }
            }
        }
        refreshDocument()
        if case .released = outcome {
            clearLastErrorAfterSuccessfulOperation()
            scheduleLiveActivityReconciliation()
            if shouldRegisterPending { registerConfiguredSchedule() }
        }
        return outcome
    }

    /// Clears a pending friend-release intent after a **definitive** relay
    /// rejection (replay, expired, wrong target, unauthorized, …) only. An
    /// `integrityFatal` classification must never call this — that case
    /// keeps the intent pending and neither retries nor abandons it. A
    /// `useID` that does not match the pending intent is a safe no-op.
    @discardableResult
    func abandonFriendRelease(useID: String) throws -> Bool {
        let store = try requireStore()
        var abandoned = false
        try store.withTransaction { context in
            abandoned = RuntimeLifecycle.abandonFriendRelease(&context.document, useID: useID)
            try context.commit()
        }
        refreshDocument()
        return abandoned
    }

    private func requireStore() throws -> SharedRuntimeStore {
        guard let store else {
            throw RuntimeValidationError.invalidConfiguration(storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription)
        }
        return store
    }

    var nextScheduledStart: Date? {
        scheduledOccurrence(at: currentDate())?.start
    }

    var nextScheduledEnd: Date? {
        scheduledOccurrence(at: currentDate())?.end
    }

    /// Whether the owner-approved bedtime-now action can safely create a new
    /// finite session at the current transaction boundary. This is advisory;
    /// `startBedtimeNow(expectedEnd:)` repeats every check while holding the
    /// shared runtime transaction lock.
    var canStartBedtimeNow: Bool {
        let now = currentDate()
        guard isAuthorized,
              storageError == nil,
              document.recoveryCommitment == nil,
              !document.testLockActive,
              document.activeOwner != .prototypeTest,
              !document.legacyRegistrationNeedsReview,
              document.effectiveSessions(at: now).isEmpty,
              let configuration = document.configuration,
              let expectedEnd = bedtimeNowProposedEnd(at: now),
              RuntimeBedtimeNowDecision.accepts(
                  expectedEnd: expectedEnd,
                  configuration: configuration,
                  recurringEnabled: document.recurringEnabledIntent,
                  at: now,
                  calendar: Calendar.current
              ),
              hasMatchingRecurringRegistration(configuration),
              !activityCenter.activities.contains(Self.manualActivityName),
              activityCenter.schedule(for: Self.manualActivityName) == nil else {
            return false
        }
        guard let savedSelection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: configuration.selectionData),
              selectionSummary(savedSelection) == configuration.selectionSummary,
              (try? RuntimePolicySnapshot(mode: configuration.mode, selectionSummary: configuration.selectionSummary, selectionData: configuration.selectionData).validated()) != nil else {
            return false
        }
        return true
    }

    /// Resolves the exact absolute end shown by confirmation UI from the next
    /// saved occurrence. It returns nil when no enabled, valid saved bedtime
    /// schedule can provide a finite end.
    func bedtimeNowProposedEnd(at date: Date = Date()) -> Date? {
        RuntimeBedtimeNowDecision.proposedEnd(
            configuration: document.configuration,
            recurringEnabled: document.recurringEnabledIntent,
            at: date,
            calendar: Calendar.current
        )
    }

    /// A compact summary for the parent UI. It is derived from the saved
    /// configuration on every read, rather than cached across clock or edits.
    var compactSavedSummary: String {
        guard let configuration = document.configuration else { return "No saved bedtime rules" }
        let mode = configuration.mode == .blockSelected ? "Block selected" : "Allow only selected"
        return "\(mode) · \(configuration.selectionSummary.totalCount) selected · \(configuration.start.displayValue)–\(configuration.end.displayValue)"
    }

    var savedRulesSummary: String { compactSavedSummary }

    var hasRecoveryRequest: Bool {
        guard let commitment = document.recoveryCommitment else { return false }
        return !commitment.sessionIDs.intersection(Set(enforcementSessions(at: currentDate()).map(\.id))).isEmpty
    }

    var recoveryEligibleAt: Date? {
        guard hasRecoveryRequest else { return nil }
        return document.recoveryCommitment?.eligibleAt
    }

    var pendingChangesSummary: String? {
        guard let pending = document.pendingConfiguration else { return nil }
        return "Pending after the current lock: \(pending.mode == .blockSelected ? "block selected" : "allow only selected"), \(pending.start.displayValue)–\(pending.end.displayValue)"
    }

    func manualLockProposedEnd(after duration: TimeInterval, at date: Date = Date()) -> Date? {
        RuntimeManualLockDecision.proposedEnd(after: duration, at: date)
    }

    func manualLockCustomRange(at date: Date = Date()) -> ClosedRange<Date>? {
        RuntimeManualLockDecision.customEndRange(at: date, calendar: Calendar.current)
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
            clearLastErrorAfterSuccessfulOperation()
            scheduleLiveActivityReconciliation()
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
            refreshDocument(); clearLastErrorAfterSuccessfulOperation()
            scheduleLiveActivityReconciliation()
        } catch {
            reconcileRuntime()
            refreshDocument(); lastError = error.localizedDescription
        }
    }

    func confirmRecovery() {
        guard let store else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        var shouldRegisterPending = false
        var shouldStopManualMonitoring = false
        var manualRouteToStop: RuntimeManualRouteBinding?
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
                if shouldStopManualMonitoring {
                    manualRouteToStop = context.document.manualRoute
                    context.document.manualRegistrationActive = false
                    context.document.manualRegistrationIntent = false
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
            if shouldStopManualMonitoring, let manualRouteToStop {
                try stopManualRouteIfOwned(store: store, expected: manualRouteToStop)
            }
            refreshDocument()
            clearLastErrorAfterSuccessfulOperation()
            scheduleLiveActivityReconciliation()
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
        guard store != nil else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        guard !hasRecoveryRequest else { lastError = "Cancel the pending recovery request before starting another lock."; return }
        guard !testScheduleActive, !document.legacyRegistrationNeedsReview else { lastError = "Finish or resolve the developer restriction before starting a committed lock."; return }

        // This is the transaction clock. An explicit expected end is a frozen
        // absolute boundary; it is never replaced by a freshly recomputed
        // bedtime end or by the current clock.
        let previewClock = currentDate()
        let end = expectedEnd ?? RuntimeManualLockDecision.proposedEnd(after: Self.defaultManualDuration, at: previewClock)
        guard let end else {
            lastError = RuntimeValidationError.manualLockUnavailable.localizedDescription
            return
        }
        switch RuntimeManualLockDecision.validation(expectedEnd: end, startedAt: previewClock) {
        case .valid:
            break
        case .tooSoon:
            lastError = RuntimeValidationError.manualEndTooSoon.localizedDescription
            return
        case .tooLate:
            lastError = RuntimeValidationError.manualEndTooLate.localizedDescription
            return
        case .invalidDate:
            lastError = RuntimeValidationError.manualLockUnavailable.localizedDescription
            return
        }
        // The transaction re-reads the coordinator clock. Do not carry the
        // preview seconds into persistence, so a delayed confirmation is
        // rejected rather than shortening the frozen absolute end.
        startFiniteManualSession(expectedEnd: end, purpose: .focus, bedtimeNow: false, transactionStart: nil)
    }

    /// Starts the saved bedtime policy immediately while retaining the
    /// repeating bedtime registration. The nonrepeating manual route is an
    /// implementation detail only; `purpose` keeps the committed session's
    /// user-facing semantics as bedtime.
    func startBedtimeNow(expectedEnd: Date) {
        guard isAuthorized else { lastError = "Screen Time access is not authorized."; return }
        guard store != nil else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        startFiniteManualSession(expectedEnd: expectedEnd, purpose: .bedtime, bedtimeNow: true, transactionStart: nil)
    }

    /// Shared finite manual registration path for Lock now and Start bedtime
    /// now. Bedtime confirmation is revalidated inside this transaction so a
    /// stale UI preview cannot shorten, extend, or retarget the occurrence.
    private func startFiniteManualSession(
        expectedEnd: Date,
        purpose: RuntimeSessionPurpose,
        bedtimeNow: Bool,
        transactionStart: Date?
    ) {
        guard let store else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        // Reconcile a queued edit before reading the policy snapshot. This
        // keeps an idle start from committing an old configuration after a
        // prior session ended without its callback being observed.
        reconcileRuntime()
        refreshDocument()
        var sessionID: UUID?
        var manualRouteToCleanup: RuntimeManualRouteBinding?
        var manualRegistered = false
        do {
            try store.withTransaction { context in
                let startedAt = transactionStart ?? currentDate()
                switch RuntimeManualLockDecision.validation(expectedEnd: expectedEnd, startedAt: startedAt) {
                case .valid:
                    break
                case .tooSoon:
                    throw RuntimeValidationError.manualEndTooSoon
                case .tooLate:
                    throw RuntimeValidationError.manualEndTooLate
                case .invalidDate:
                    throw RuntimeValidationError.manualLockUnavailable
                }
                _ = RuntimeLifecycle.expireNaturalSessions(&context.document, at: startedAt)
                guard context.document.recoveryCommitment == nil,
                      !context.document.testLockActive,
                      context.document.activeOwner != .prototypeTest,
                      !context.document.legacyRegistrationNeedsReview else {
                    throw RuntimeValidationError.invalidConfiguration("Finish the current recovery or developer restriction before starting another lock.")
                }
                _ = RuntimeLifecycle.activatePendingConfigurationIfIdle(&context.document, at: startedAt)
                if context.document.recurringEnabledIntent {
                    guard hasMatchingRecurringRegistration(context.document.configuration) else {
                        throw RuntimeValidationError.invalidConfiguration("The saved bedtime schedule is not registered exactly.")
                    }
                }
                // A route binding is an ownership generation. Never reuse an
                // existing or unknown route for a new session; reconciliation
                // must retire it first while holding the same store lock.
                guard context.document.manualRoute == nil,
                      !activityCenter.activities.contains(Self.manualActivityName),
                      activityCenter.schedule(for: Self.manualActivityName) == nil else {
                    throw RuntimeValidationError.invalidConfiguration("A finite manual end route is already registered.")
                }
                let bedtimeOccurrence = bedtimeNow
                    ? RuntimeBedtimeNowDecision.proposedOccurrence(
                        configuration: context.document.configuration,
                        recurringEnabled: context.document.recurringEnabledIntent,
                        at: startedAt,
                        calendar: Calendar.current
                    )
                    : nil
                if bedtimeNow {
                    guard context.document.effectiveSessions(at: startedAt).isEmpty else {
                        throw RuntimeValidationError.invalidConfiguration("A lock is already active; bedtime cannot be started over it.")
                    }
                    guard bedtimeOccurrence != nil,
                          RuntimeBedtimeNowDecision.accepts(
                              expectedEnd: expectedEnd,
                              configuration: context.document.configuration,
                              recurringEnabled: context.document.recurringEnabledIntent,
                              at: startedAt,
                              calendar: Calendar.current
                          ) else {
                        throw RuntimeValidationError.invalidConfiguration("The bedtime confirmation is stale or does not match the next saved morning end.")
                    }
                    guard hasMatchingRecurringRegistration(context.document.configuration) else {
                        throw RuntimeValidationError.invalidConfiguration("The saved bedtime schedule is not registered exactly.")
                    }
                } else {
                    guard !context.document.sessions.contains(where: { $0.origin == .manual && $0.isEffective(at: startedAt) }) else {
                        throw RuntimeValidationError.invalidConfiguration("A finite manual lock is already active; it cannot be shortened or replaced.")
                    }
                }
                guard let configuration = context.document.configuration else { throw RuntimeValidationError.manualLockUnavailable }
                let savedSelection = try JSONDecoder().decode(FamilyActivitySelection.self, from: configuration.selectionData)
                guard selectionSummary(savedSelection) == configuration.selectionSummary else { throw RuntimeValidationError.corruptSharedData }
                let policy = try RuntimePolicySnapshot(mode: configuration.mode, selectionSummary: configuration.selectionSummary, selectionData: configuration.selectionData).validated()

                // Check both current sessions and every future saved bedtime
                // occurrence intersecting the manual interval. Same-policy
                // overlap is composed by the runtime; mixed policy overlap is
                // rejected before the first Managed Settings write.
                let active = enforcementSessions(in: context.document, at: startedAt)
                guard try active.allSatisfy({ try policiesAreSemanticallyEqual($0.policy, policy) }) else {
                    throw RuntimeValidationError.overlapUnsupported
                }
                if context.document.recurringEnabledIntent {
                    let overlaps = RuntimeManualLockDecision.overlappingScheduledOccurrences(
                        configuration: configuration,
                        intervalStart: startedAt,
                        intervalEnd: expectedEnd,
                        calendar: Calendar.current
                    )
                    for occurrence in overlaps {
                        if RuntimeLifecycle.shouldSuppressScheduledOccurrence(
                            context.document,
                            start: occurrence.start,
                            end: occurrence.end
                        ) { continue }
                        let scheduledPolicy = context.document.sessions.first(where: {
                            $0.origin == .scheduled && $0.start == occurrence.start && $0.end == occurrence.end
                        })?.policy ?? policy
                        guard try policiesAreSemanticallyEqual(scheduledPolicy, policy) else {
                            throw RuntimeValidationError.overlapUnsupported
                        }
                    }
                }

                RuntimeLifecycle.pruneTerminalSessions(&context.document, at: startedAt)
                let session = RuntimeSession(
                    origin: .manual,
                    start: startedAt,
                    end: expectedEnd,
                    sourceRevision: configuration.revision,
                    policy: policy,
                    purpose: purpose,
                    scheduledOccurrence: bedtimeNow ? bedtimeOccurrence : nil
                )
                sessionID = session.id
                context.document.sessions.append(session)
                let route = RuntimeManualRouteBinding(sessionID: session.id, registeredStart: startedAt, registeredEnd: expectedEnd)
                manualRouteToCleanup = route
                context.document.manualRoute = route
                context.document.manualRegistrationIntent = true
                context.document.manualRegistrationActive = false
                context.document.policyIntent = .apply
                context.document.record(RuntimeDiagnostic(operation: .policyApplyAttempted, observedAt: startedAt, detail: bedtimeNow ? "Bedtime-now session persisted before finite OS registration." : "Finite manual session persisted before OS registration."))
                try context.commit()

                let schedule = manualSchedule(start: startedAt, end: expectedEnd)
                try activityCenter.startMonitoring(Self.manualActivityName, during: schedule)
                guard let registered = activityCenter.schedule(for: Self.manualActivityName),
                      activityCenter.activities.contains(Self.manualActivityName),
                      context.document.manualRoute == route,
                      RuntimeManualRouteDecision.registeredRouteMatches(
                          route,
                          sessionID: session.id,
                          intervalStart: registered.intervalStart,
                          intervalEnd: registered.intervalEnd,
                          repeats: registered.repeats,
                          calendar: Calendar.current,
                          tolerance: RuntimeManualLockDecision.registrationClockTolerance
                      ) else {
                    throw RuntimeValidationError.invalidConfiguration("The OS did not retain the expected finite manual end route.")
                }
                manualRegistered = true
                context.document.manualRegistrationIntent = false
                context.document.manualRegistrationActive = true
                try context.commit()
                try applyEffectivePolicy(context.document, at: startedAt)
                context.document.policyIntent = nil
                context.document.record(RuntimeDiagnostic(operation: .policyApplied, observedAt: currentDate(), detail: bedtimeNow ? "Bedtime-now policy application attempted; OS-managed morning end is registered." : "Finite manual policy application attempted; OS-managed end is registered."), succeeded: true)
                try context.commit()
            }
            refreshDocument(); clearLastErrorAfterSuccessfulOperation()
            scheduleLiveActivityReconciliation()
        } catch {
            if !manualRegistered {
                // A rejected second manual lock has no sessionID and must not
                // stop the first lock's only end route.
                if let sessionID {
                    try? store.transaction { document in
                        document.sessions.removeAll { $0.id == sessionID }
                        document.manualRegistrationIntent = false
                        document.manualRegistrationActive = false
                        let remaining = enforcementSessions(in: document, at: currentDate())
                        document.policyIntent = remaining.isEmpty ? .clear : .apply
                        document.record(RuntimeDiagnostic(operation: .registrationFailed, observedAt: currentDate(), detail: error.localizedDescription), succeeded: false)
                    }
                    if let manualRouteToCleanup {
                        try? stopManualRouteIfOwned(store: store, expected: manualRouteToCleanup)
                    }
                    reconcileRuntime()
                }
            } else {
                // The OS release route was accepted. Retain cleanup ownership
                // and durable apply intent; never clear the named store here.
                try? store.transaction { document in
                    document.record(RuntimeDiagnostic(operation: .policyApplyFailed, observedAt: currentDate(), detail: error.localizedDescription), succeeded: false)
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
        var manualRouteToStop: RuntimeManualRouteBinding?
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
                if shouldStopManualMonitoring {
                    manualRouteToStop = context.document.manualRoute
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
            if shouldStopManualMonitoring, let manualRouteToStop {
                try stopManualRouteIfOwned(store: store, expected: manualRouteToStop)
            }
            refreshDocument(); clearLastErrorAfterSuccessfulOperation()
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

    init(
        clock: @escaping () -> Date = { Date() },
        quickActionQueue: (any QuickActionRouteQueue)? = nil,
        quickActionScheduler: QuickActionRetryScheduler? = nil
    ) {
        self.clock = clock
        self.quickActionBroker = QuickActionDeliveryBroker(
            queue: quickActionQueue ?? QuickActionPendingRouteStore.appGroupStore(),
            clock: clock,
            scheduler: quickActionScheduler ?? DispatchQuickActionRetryScheduler()
        )
        let defaults = UserDefaults.standard
        pendingQuickAction = nil
        windDownEnabled = defaults.object(forKey: Self.windDownEnabledKey) as? Bool ?? false
        let storedLead = defaults.object(forKey: Self.windDownLeadMinutesKey) as? Int ?? 30
        windDownLeadMinutes = min(max(storedLead, 1), 1_440)
        if let data = defaults.data(forKey: Self.safetyAssistantAcknowledgementsKey),
           let decoded = try? JSONDecoder().decode(SafetyAssistantAcknowledgements.self, from: data),
           (try? decoded.validated()) != nil {
            safetyAssistantAcknowledgements = decoded
        } else {
            // Unknown/corrupt acknowledgements are local review state only;
            // reset the review without touching policy or recovery state.
            safetyAssistantAcknowledgements = SafetyAssistantAcknowledgements()
        }
        let liveActivityResolution = AmbientLiveActivityPreferenceMigration.resolve(
            encodedRecord: defaults.data(forKey: Self.liveActivityPreferenceKey),
            legacyVersion: defaults.object(forKey: Self.legacyLiveActivityPreferenceVersionKey) as? Int,
            legacyEnabled: defaults.object(forKey: Self.legacyLiveActivityEnabledKey) as? Bool
        )
        liveActivityEnabled = liveActivityResolution.preference.enabled
        if liveActivityResolution.shouldPersist {
            // UserDefaults has no transaction spanning multiple keys. Write
            // the complete safe record first; only then is legacy cleanup safe.
            if let data = try? liveActivityResolution.preference.encoded() {
                defaults.set(data, forKey: Self.liveActivityPreferenceKey)
                Self.removeLegacyLiveActivityPreferenceKeys(from: defaults)
            }
        } else {
            Self.removeLegacyLiveActivityPreferenceKeys(from: defaults)
        }
        Self.removeLegacyLiveActivityDiagnostics()
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
        reconciliationError = nil
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
        scheduleAmbientReconciliation()
        scheduleLiveActivityReconciliation()
    }

    /// Handles only the versioned, short-lived routes produced by this app's
    /// App Intents. An invalid or expired route is rejected without any
    /// Managed Settings or lifecycle mutation.
    func handleQuickActionURL(_ url: URL, now: Date = Date()) {
        guard QuickActionRoute.parse(url, now: now) != nil else {
            lastError = "This Phone Lockbox shortcut link is invalid or expired. No lock was changed."
            return
        }
        // Direct URL callbacks use the same durable nonce queue as App Intent
        // handoffs. A current presentation therefore remains the sole busy
        // identity; later focus/status/recovery routes wait in FIFO order.
        guard QuickActionPendingRouteStore.enqueue(url, now: now) else {
            lastError = "This Phone Lockbox shortcut could not be queued safely. No lock was changed."
            return
        }
        processPendingQuickActionRoute(now: now)
    }

    /// A destination calls this only after it has consumed and presented the
    /// requested UI. Presentation acknowledgement validates the exact
    /// in-memory identity but deliberately does not remove the durable claim:
    /// a crash before dismissal/settlement must leave the route retryable.
    @discardableResult
    func acknowledgePresentedQuickAction(_ pending: PendingQuickAction) -> Bool {
        guard pendingQuickAction == pending,
              quickActionDelivery.accepts(pending.deliveryIdentity) else { return false }
        return true
    }

    /// Releases the exact presented identity after its destination is
    /// dismissed or settled. Durable acknowledgement happens at this boundary
    /// so a crash before settlement remains retryable. A stale callback cannot
    /// remove a re-leased claim because the queue still requires its token.
    @discardableResult
    func settlePresentedQuickAction(_ pending: PendingQuickAction) -> Bool {
        guard pendingQuickAction == pending,
              quickActionDelivery.accepts(pending.deliveryIdentity) else { return false }
        // A failed acknowledgement is not a reason to retain a stale UI
        // identity. The broker schedules the exact claim lease deadline, while
        // this identity still settles locally and cannot block later routes.
        let acknowledged = quickActionBroker.acknowledge(pending.claim)
        guard quickActionDelivery.settle(pending.deliveryIdentity) else { return false }
        pendingQuickAction = nil
        processPendingQuickActionRoute()
        return acknowledged
    }

    /// Imports one App Intent handoff only at the app boundary. Claiming and
    /// acknowledging are separate durable operations so a host crash retries
    /// navigation; neither operation invokes an enforcement action.
    func processPendingQuickActionRoute(now: Date? = nil) {
        quickActionBroker.process(
            now: now ?? currentDate(),
            isBusy: { [weak self] in
                guard let self else { return true }
                return self.pendingQuickAction != nil || self.quickActionDelivery.activeIdentity != nil
            },
            disposition: { [weak self] route in
                self?.quickActionDisposition(for: route.action) ?? .dropNavigationOnly
            },
            present: { [weak self] claim, route in
                guard let self else { return false }
                let pending = PendingQuickAction(id: route.id, action: route.action, claim: claim)
                guard self.quickActionDelivery.begin(pending.deliveryIdentity) else { return false }
                // Review P1: strictly before the publish — see the doc
                // comment on `onWillPresentQuickAction`.
                self.onWillPresentQuickAction?()
                self.pendingQuickAction = pending
                return true
            },
            terminal: { [weak self] _ in
                self?.lastError = "This shortcut request is no longer available. No lock was changed."
            }
        )
    }

    private func quickActionDisposition(for action: QuickActionRoute.Action) -> QuickActionDeliveryDisposition {
        switch action {
        case .focus:
            guard isAuthorized else {
                lastError = "Screen Time access is unavailable for this focus shortcut. No lock was changed."
                return .dropNavigationOnly
            }
            guard isConfigured, store != nil, storageError == nil else {
                lastError = "Focus shortcuts are unavailable until Lockbox is configured. No lock was changed."
                return .dropNavigationOnly
            }
            guard !hasActiveLock else {
                lastError = "A lock is already active. The shortcut cannot change the active lock."
                return .dropNavigationOnly
            }
            return .present
        case .status, .recovery:
            // These destinations remain useful for explaining unavailable
            // authorization/configuration; they never mutate enforcement.
            return .present
        }
    }

    func refreshAuthorization() {
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        refreshDocument()
        Self.removeLegacyLiveActivityDiagnostics()
        reconcileRegistration()
        reconcileManualRegistrationFromOS()
        retryInterruptedDailyRegistration()
        reconcilePendingManualRegistration()
        reconcileRuntime()
        refreshDocument()
        scheduleAmbientReconciliation()
        scheduleLiveActivityReconciliation()
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

    // MARK: Ambient preferences

    /// Valid lead values are expressed in minutes so the settings surface can
    /// offer 1 minute through 24 hours without maintaining another bedtime.
    var windDownLeadChoices: ClosedRange<Int> { 1...1_440 }

    func setWindDownEnabled(_ enabled: Bool) {
        windDownEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.windDownEnabledKey)
        scheduleAmbientReconciliation()
    }

    func setWindDownLeadMinutes(_ minutes: Int) {
        guard windDownLeadChoices.contains(minutes) else {
            ambientError = "Wind-down lead time must be between 1 minute and 24 hours."
            return
        }
        windDownLeadMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: Self.windDownLeadMinutesKey)
        scheduleAmbientReconciliation()
    }

    func setLiveActivityEnabled(_ enabled: Bool) {
        let preference = AmbientLiveActivityPreference(enabled: enabled)
        guard let data = try? preference.encoded() else {
            ambientError = "Live Activity preference could not be saved."
            return
        }
        // This single UserDefaults value is the durable commit point for the
        // explicit choice. Legacy keys are removed only after it is complete.
        UserDefaults.standard.set(data, forKey: Self.liveActivityPreferenceKey)
        Self.removeLegacyLiveActivityPreferenceKeys(from: .standard)
        liveActivityEnabled = enabled
        scheduleLiveActivityReconciliation()
    }

    /// Permission is requested only from this explicit host action. Enabling
    /// wind-down or foregrounding the app never calls the system prompt.
    func requestWindDownNotificationAuthorization() async {
#if canImport(UserNotifications)
        do {
            let result = try await windDownScheduler.requestAuthorization()
            windDownAuthorizationStatus = windDownAuthorizationLabel(result)
            if result == .denied {
                ambientError = "Notification permission was denied; wind-down reminders are not scheduled."
            } else {
                ambientError = nil
                await reconcileWindDownNotifications()
            }
        } catch {
            ambientError = "Wind-down notification permission failed: \(error.localizedDescription)"
            await refreshWindDownStatus()
        }
#else
        ambientError = "Wind-down notifications are unavailable on this platform."
#endif
    }

    /// Foreground/relaunch reconciliation for the saved ambient preferences.
    /// It only touches this feature's notification namespace and has no effect
    /// on Screen Time registration or lifecycle state.
    func reconcileAmbientPreferences() {
        scheduleAmbientReconciliation()
    }

    private func scheduleAmbientReconciliation() {
#if canImport(UserNotifications)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcileWindDownNotifications()
        }
#endif
    }

#if canImport(UserNotifications)
    private func reconcileWindDownNotifications() async {
        let authorization = await windDownScheduler.authorization()
        windDownAuthorizationStatus = windDownAuthorizationLabel(authorization)

        guard windDownEnabled else {
            await windDownScheduler.disable()
            await refreshWindDownStatus()
            ambientError = nil
            return
        }
        guard let configuration = document.configuration else {
            await windDownScheduler.disable()
            await refreshWindDownStatus()
            ambientError = "Wind-down needs a saved bedtime schedule."
            return
        }
        guard document.recurringEnabledIntent else {
            await windDownScheduler.disable()
            await refreshWindDownStatus()
            ambientError = "Wind-down is waiting for the bedtime schedule to be registered."
            return
        }

        do {
            let bedtime = try AmbientLocalTime(hour: configuration.start.hour, minute: configuration.start.minute)
            let lead = try WindDownLeadOffset(minutes: windDownLeadMinutes)
            let current = enforcementSessions(at: currentDate()).first(where: { $0.isEffective(at: currentDate()) })
            let activeBoundary = try current.map { try AmbientSessionBoundary(start: $0.start, end: $0.end) }
            let plan = try WindDownPlanner.plan(
                configuration: WindDownConfiguration(enabled: true, bedtime: bedtime, lead: lead),
                now: currentDate(),
                calendar: .autoupdatingCurrent,
                activeSession: activeBoundary,
                limit: WindDownConfiguration.maximumScheduledOccurrences
            )
            let outcome = try await windDownScheduler.replace(occurrences: plan)
            switch outcome {
            case .replaced:
                ambientError = nil
            case .failed(let requested, let added, let restored):
                ambientError = restored
                    ? "Wind-down was not changed: only \(added) of \(requested) reminders could be added; the previous schedule was restored."
                    : "Wind-down reminders partially changed (\(added) of \(requested)); open Phone Lockbox to reconcile."
            }
        } catch {
            // Ambient errors are intentionally not assigned to lastError: a
            // reminder problem cannot certify or invalidate enforcement.
            ambientError = "Wind-down not scheduled: \(error.localizedDescription)"
        }
        await refreshWindDownStatus()
    }

    private func refreshWindDownStatus() async {
        let authorization = await windDownScheduler.authorization()
        windDownAuthorizationStatus = windDownAuthorizationLabel(authorization)
        pendingWindDownNotificationCount = await windDownScheduler.pendingOwnedRequestCount()
    }

    private func windDownAuthorizationLabel(_ authorization: WindDownNotificationScheduler.Authorization) -> String {
        switch authorization {
        case .notDetermined: return "Not requested"
        case .denied: return "Denied"
        case .authorized: return "Authorized"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        }
    }
#endif

#if canImport(ActivityKit)
    private func scheduleLiveActivityReconciliation() {
        Task { @MainActor [weak self] in
            await self?.reconcileLiveActivities()
        }
    }

    private func reconcileLiveActivities() async {
        if !liveActivityEnabled {
            _ = await liveActivity.endAllAppOwnedActivities()
            return
        }

        let now = currentDate()
        // Terminal history can be pruned, and the host may not have observed
        // every enforcement callback. Sweep only past immutable ends for
        // real focus/bedtime activities; the helper marks them stale rather
        // than claiming that Managed Settings released.
        _ = await liveActivity.endPastFixedEndAppOwnedActivities(now: now)
        let active = enforcementSessions(at: now)
        for session in active {
            let status: AmbientLiveActivityStatus = session.state == .recoveryPending ? .recoveryPending : .plannedSession
            let kind = AmbientLiveActivityTermination.kind(
                isBedtimePurpose: session.purpose == .bedtime,
                isScheduledOrigin: session.origin == .scheduled
            )
            _ = await liveActivity.reconcile(
                sessionID: session.id.uuidString,
                fixedEnd: session.end,
                kind: kind,
                status: status,
                now: now
            )
        }

        // Only terminal states observed in the durable runtime may end the
        // corresponding activity. A missing callback or a merely past clock
        // does not get translated into "unlocked" copy here.
        for session in document.sessions where session.state == .released || session.state == .expired {
            if session.state == .released {
                _ = await liveActivity.endAfterObservedRelease(sessionID: session.id.uuidString)
            } else {
                _ = await liveActivity.endAfterObservedExpiry(
                    sessionID: session.id.uuidString,
                    fixedEnd: session.end,
                    kind: AmbientLiveActivityTermination.kind(
                        isBedtimePurpose: session.purpose == .bedtime,
                        isScheduledOrigin: session.origin == .scheduled
                    )
                )
            }
        }
    }

#else
    private func scheduleLiveActivityReconciliation() {}
#endif

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
            try persistDraft(draft); selection = draftSelection; clearLastErrorAfterSuccessfulOperation()
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
            if shouldRegister {
                registerConfiguredSchedule()
            } else {
                clearLastErrorAfterSuccessfulOperation()
                scheduleAmbientReconciliation()
            }
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
            refreshDocument(); reconcileRegistration(); clearLastErrorAfterSuccessfulOperation()
            scheduleAmbientReconciliation()
        } catch {
            guard replacingRegistration else { refreshDocument(); reconcileRegistration(); lastError = error.localizedDescription; return }
            activityCenter.stopMonitoring([Self.activityName])
            try? store.transaction { document in
                guard document.configuration?.revision == configuration.revision else { return }
                document.recurringEnabledIntent = false
                document.record(RuntimeDiagnostic(operation: .registrationFailed, observedAt: Date(), requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: error.localizedDescription), succeeded: false)
            }
            refreshDocument(); reconcileRegistration(); lastError = error.localizedDescription
            scheduleAmbientReconciliation()
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
            refreshDocument(); clearLastErrorAfterSuccessfulOperation()
        } catch { refreshDocument(); lastError = error.localizedDescription }
    }

    func clearImmediateShield() {
        guard let store else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        do { try clearOwnedPrototypePolicy(store: store); refreshDocument(); clearLastErrorAfterSuccessfulOperation() }
        catch { refreshDocument(); lastError = error.localizedDescription }
    }

    func stopSchedule() {
        guard let store else { lastError = storageError ?? RuntimeValidationError.appGroupUnavailable.localizedDescription; return }
        var shouldStopMonitoring = false
        do {
            // Do not reconcile from the cached document before this transaction:
            // a callback can commit a session between that pass and this write.
            // Expiry, disabled intent, and the desired policy are one durable
            // decision, committed before the sole OS end route is stopped.
            try store.withTransaction { context in
                let now = Date()
                _ = RuntimeLifecycle.expireNaturalSessions(&context.document, at: now)
                context.document.recurringEnabledIntent = false
                let scheduledIsLive = RuntimeLifecycle.scheduledRegistrationShouldRemain(context.document, at: now)
                // Manual-only state must never keep the daily registration
                // alive. A current scheduled session does keep its end route so
                // disabling recurrence affects only future occurrences.
                shouldStopMonitoring = !scheduledIsLive
                let intent = RuntimeCallbackDecision.preparePolicyReconciliation(&context.document, at: now)
                context.document.record(RuntimeDiagnostic(
                    operation: .configurationSaved,
                    observedAt: now,
                    revision: context.document.configuration?.revision,
                    detail: scheduledIsLive
                        ? "Recurring schedule disabled for future occurrences; current scheduled session is unchanged."
                        : "Recurring schedule disabled; current aggregate reconciled before stopping the daily route."
                ), succeeded: true)
                context.document.record(RuntimeDiagnostic(
                    operation: intent == .clear ? .policyClearAttempted : .policyApplyAttempted,
                    observedAt: now,
                    detail: "Schedule-stop policy intent persisted before OS monitoring changed."
                ))
                try context.commit()
                try applyEffectivePolicy(context.document, at: now)
                context.document.policyIntent = nil
                context.document.record(RuntimeDiagnostic(
                    operation: intent == .clear ? .policyCleared : .policyApplied,
                    observedAt: Date(),
                    revision: context.document.configuration?.revision,
                    detail: "Schedule-stop reconciled the current aggregate."
                ), succeeded: true)
                try context.commit()
            }
            if shouldStopMonitoring { activityCenter.stopMonitoring([Self.activityName]) }
            refreshDocument(); clearLastErrorAfterSuccessfulOperation()
            scheduleAmbientReconciliation()
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
            reconciliationError = nil
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
        var manualRouteToStop: RuntimeManualRouteBinding?
        var reconciliationSucceeded = false
        do {
            try store.withTransaction { context in
                var changed = RuntimeLifecycle.expireNaturalSessions(&context.document, at: date)
                if try reconcileCurrentScheduledOccurrence(&context.document, at: date) { changed = true }
                if RuntimeLifecycle.activatePendingConfigurationIfIdle(&context.document, at: date) { changed = true; shouldRegisterPending = context.document.recurringEnabledIntent }
                let effective = RuntimeCallbackDecision.currentAggregate(context.document, at: date)
                if !context.document.sessions.contains(where: { $0.origin == .manual && $0.isEffective(at: date) }) {
                    shouldStopManual = context.document.manualRegistrationActive || context.document.manualRegistrationIntent
                    manualRouteToStop = context.document.manualRoute
                    context.document.manualRegistrationActive = false
                    context.document.manualRegistrationIntent = false
                }
                let desired = RuntimeCallbackDecision.desiredPolicyIntent(context.document, at: date)
                let mustApplyLegacyPrototype = !context.document.legacyRegistrationNeedsReview &&
                    effective.isEmpty && context.document.activeOwner == .prototypeTest && context.document.testLockActive &&
                    context.document.policyIntent == .apply
                let mustClear = !context.document.legacyRegistrationNeedsReview && effective.isEmpty &&
                    !mustApplyLegacyPrototype &&
                    (changed || context.document.policyIntent != nil || context.document.activeOwner == .scheduled)
                let mustApply = isAuthorized && !effective.isEmpty
                // A manual registration intent with no OS-accepted route is not
                // permission to apply an unbounded shield. Its session is not in
                // `effective`; replay registration first.
                guard mustClear || mustApply || mustApplyLegacyPrototype else {
                    // Keep a persisted clear/apply intent aligned with the
                    // current aggregate even when authorization is unavailable.
                    if context.document.policyIntent != nil && desired != context.document.policyIntent {
                        context.document.policyIntent = desired
                        try context.commit()
                    }
                    return
                }
                let intent: RuntimePolicyIntent = mustClear ? .clear : .apply
                context.document.policyIntent = intent
                context.document.record(RuntimeDiagnostic(operation: intent == .clear ? .policyClearAttempted : .policyApplyAttempted, observedAt: date, detail: "Runtime reconciliation intent persisted before policy adapter."))
                try context.commit()
                try applyEffectivePolicy(context.document, at: date)
                context.document.policyIntent = nil
                if !mustApplyLegacyPrototype {
                    context.document.activeOwner = nil
                    context.document.testLockActive = false
                }
                context.document.record(RuntimeDiagnostic(operation: intent == .clear ? .policyCleared : .policyApplied, observedAt: Date(), detail: intent == .clear ? "Runtime reconciliation cleared this app's named policy." : (mustApplyLegacyPrototype ? "Runtime reconciliation replayed the developer prototype policy." : "Runtime reconciliation applied frozen active policy.")), succeeded: true)
                try context.commit()
                // Only a completed policy side effect resolves a prior
                // reconciliation failure. A no-op guard (for example while
                // authorization is unavailable) must not make the UI forget
                // the source error merely because another action foregrounded
                // the app.
                reconciliationSucceeded = true
            }
            if shouldStopManual, let manualRouteToStop {
                try stopManualRouteIfOwned(store: store, expected: manualRouteToStop)
            }
            if shouldRegisterPending { registerConfiguredSchedule() }
            if reconciliationSucceeded { reconciliationError = nil }
            refreshDocument()
        } catch {
            refreshDocument()
            reconciliationError = "State reconciliation needs attention: \(error.localizedDescription)"
            lastError = reconciliationError
        }
        scheduleLiveActivityReconciliation()
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
        let routeExists = activityCenter.activities.contains(Self.manualActivityName)
        let registered = activityCenter.schedule(for: Self.manualActivityName)
        var routeMatches = false
        var staleManualRoute: RuntimeManualRouteBinding?
        do {
            try store.transaction { context in
                let priorManualRoute = context.manualRoute
                if let registered,
                   let session = context.sessions.first(where: { $0.origin == .manual && $0.isEffective(at: now) && now < $0.end }) {
                    if let route = context.manualRoute {
                        routeMatches = RuntimeManualRouteDecision.registeredRouteMatches(
                            route,
                            sessionID: session.id,
                            intervalStart: registered.intervalStart,
                            intervalEnd: registered.intervalEnd,
                            repeats: registered.repeats,
                            calendar: Calendar.current,
                            tolerance: RuntimeManualLockDecision.registrationClockTolerance
                        )
                    } else {
                        // Legacy documents have no route generation. Accept
                        // only the exact frozen session start/end once, then
                        // persist a binding through normal reconciliation.
                        routeMatches = RuntimeScheduleDecision.manualRegistrationMatchesExact(
                            start: session.start,
                            end: session.end,
                            intervalStart: registered.intervalStart,
                            intervalEnd: registered.intervalEnd,
                            repeats: registered.repeats,
                            calendar: Calendar.current,
                            tolerance: RuntimeManualLockDecision.registrationClockTolerance
                        )
                    }
                } else if let registered = registered, let route = context.manualRoute {
                    routeMatches = RuntimeManualRouteDecision.registeredRouteMatches(
                        route,
                        sessionID: route.sessionID,
                        intervalStart: registered.intervalStart,
                        intervalEnd: registered.intervalEnd,
                        repeats: registered.repeats,
                        calendar: Calendar.current,
                        tolerance: RuntimeManualLockDecision.registrationClockTolerance
                    )
                }
                if routeMatches,
                   context.manualRoute == nil,
                   let registered,
                   let session = context.sessions.first(where: { $0.origin == .manual && $0.isEffective(at: now) && now < $0.end }),
                   let registeredStart = Calendar.current.date(from: registered.intervalStart),
                   let registeredEnd = Calendar.current.date(from: registered.intervalEnd) {
                    context.manualRoute = RuntimeManualRouteBinding(sessionID: session.id, registeredStart: registeredStart, registeredEnd: registeredEnd)
                }
                let changed = RuntimeLifecycle.normalizeManualRegistration(
                    &context,
                    at: now,
                    routeExists: routeExists,
                    routeMatches: routeExists && registered != nil && routeMatches
                )
                if routeExists && !context.sessions.contains(where: { $0.origin == .manual && $0.isEffective(at: now) }) {
                    staleManualRoute = priorManualRoute
                }
                if changed {
                    context.record(RuntimeDiagnostic(
                        operation: .callbackReceived,
                        observedAt: now,
                        detail: routeExists && routeMatches
                            ? "Manual registration state normalized from the OS-owned end route."
                            : "Manual registration state normalized without trusting a missing or mismatched OS route."
                    ), succeeded: routeExists && routeMatches)
                }
            }
            if let staleManualRoute {
                try stopManualRouteIfOwned(store: store, expected: staleManualRoute)
            }
            // A pending intent is retried only after normalization. Until the
            // OS accepts the route it remains outside the enforcement aggregate.
            refreshDocument()
            reconcilePendingManualRegistration()
            reconcileRuntime()
        } catch { lastError = error.localizedDescription }
    }

    /// Stop only an ended manual route generation while holding the shared
    /// transaction lock across ownership verification and the OS side effect.
    /// A newer start therefore cannot interleave a successful route update.
    private func stopManualRouteIfOwned(
        store: SharedRuntimeStore,
        expected: RuntimeManualRouteBinding
    ) throws {
        try store.withTransaction { context in
            let registered = activityCenter.schedule(for: Self.manualActivityName)
            if let registered,
               activityCenter.activities.contains(Self.manualActivityName) {
                guard RuntimeManualRouteDecision.mayStop(
                    document: context.document,
                    expected: expected,
                    at: currentDate(),
                    intervalStart: registered.intervalStart,
                    intervalEnd: registered.intervalEnd,
                    repeats: registered.repeats,
                    calendar: Calendar.current,
                    tolerance: RuntimeManualLockDecision.registrationClockTolerance
                ) else { return }
            } else if activityCenter.activities.contains(Self.manualActivityName) {
                // An activity without inspectable exact bounds is not ours to
                // stop; retain durable ownership for a later reconciliation.
                return
            } else {
                guard context.document.manualRoute == expected,
                      !context.document.sessions.contains(where: { $0.id == expected.sessionID && $0.isEffective(at: currentDate()) }) else { return }
            }
            // Stop while the persisted generation and exact bounds still
            // prove ownership. Clearing follows the side effect; if a crash
            // occurs before this commit, relaunch sees the same binding and
            // retries the owned stop rather than adopting an unknown route.
            if registered != nil {
                activityCenter.stopMonitoring([Self.manualActivityName])
            }
            context.document.manualRoute = nil
            context.document.manualRegistrationIntent = false
            context.document.manualRegistrationActive = false
            try context.commit()
        }
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
                _ = RuntimeLifecycle.normalizeRecoveryCommitment(&document, at: now)
                document.manualRegistrationIntent = false
                document.manualRegistrationActive = false
                document.policyIntent = RuntimeCallbackDecision.desiredPolicyIntent(document, at: now)
                document.record(RuntimeDiagnostic(operation: .registrationFailed, observedAt: now, detail: "Pending manual lock expired before a safe OS-managed registration could be replayed."), succeeded: false)
            }
            reconcileRuntime()
            return
        }
        do {
            // The original start may be in the past after a crash. The session
            // end remains frozen, while the OS registration starts from now.
            // Persist the replay generation and exact bounds before touching
            // DeviceActivity so an unrelated same-end route cannot be adopted.
            let replayStart = currentDate()
            let replayRoute = RuntimeManualRouteBinding(
                sessionID: pending.id,
                registeredStart: replayStart,
                registeredEnd: pending.end
            )
            try store.withTransaction { context in
                guard context.document.sessions.contains(where: {
                    $0.id == pending.id && ($0.state == .active || $0.state == .recoveryPending) && $0.isEffective(at: Date())
                }) else {
                    throw RuntimeValidationError.invalidConfiguration("The pending finite manual session is no longer current.")
                }
                context.document.manualRoute = replayRoute
                context.document.manualRegistrationIntent = true
                context.document.manualRegistrationActive = false
                context.document.policyIntent = .apply
                context.document.record(RuntimeDiagnostic(operation: .registrationAttempted, requestedEnd: RuntimeTime(hour: Calendar.current.component(.hour, from: pending.end), minute: Calendar.current.component(.minute, from: pending.end)), detail: "Pending finite manual registration replay persisted before OS registration."))
                try context.commit()
            }
            try activityCenter.startMonitoring(Self.manualActivityName, during: manualSchedule(start: replayStart, end: pending.end))
            try store.withTransaction { context in
                guard context.document.manualRoute == replayRoute,
                      context.document.sessions.contains(where: {
                          $0.id == pending.id && ($0.state == .active || $0.state == .recoveryPending) && $0.isEffective(at: Date())
                      }),
                      let registered = activityCenter.schedule(for: Self.manualActivityName),
                      activityCenter.activities.contains(Self.manualActivityName),
                      RuntimeManualRouteDecision.registeredRouteMatches(
                          replayRoute,
                          sessionID: pending.id,
                          intervalStart: registered.intervalStart,
                          intervalEnd: registered.intervalEnd,
                          repeats: registered.repeats,
                          calendar: Calendar.current,
                          tolerance: RuntimeManualLockDecision.registrationClockTolerance
                      ) else {
                    throw RuntimeValidationError.invalidConfiguration("The OS did not retain the expected finite manual end route.")
                }
                context.document.manualRegistrationIntent = false
                context.document.manualRegistrationActive = true
                context.document.policyIntent = .apply
                context.document.record(RuntimeDiagnostic(operation: .registrationSucceeded, requestedEnd: RuntimeTime(hour: Calendar.current.component(.hour, from: pending.end), minute: Calendar.current.component(.minute, from: pending.end)), detail: "Pending finite manual registration replayed."), succeeded: true)
                try context.commit()
            }
            reconcileRuntime()
        } catch { lastError = error.localizedDescription }
    }

    private func applyEffectivePolicy(_ state: RuntimeStoreDocument, at date: Date) throws {
        let sessions = enforcementSessions(in: state, at: date)
        guard !sessions.isEmpty else {
            if state.activeOwner == .prototypeTest, state.testLockActive, state.policyIntent == .apply {
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
              RuntimeScheduleDecision.registrationMatches(configuration: configuration, start: registered.intervalStart, end: registered.intervalEnd, repeats: registered.repeats) else { return false }
        if RuntimeLifecycle.shouldSuppressScheduledCallback(state, at: date) { return false }
        guard let occurrence = RuntimeOccurrenceResolver.candidates(start: configuration.start, end: configuration.end, around: date).first(where: { date >= $0.start && date < $0.end }) else { return false }
        if RuntimeLifecycle.shouldSuppressScheduledCallback(
            state,
            at: date,
            occurrenceStart: occurrence.start,
            occurrenceEnd: occurrence.end
        ) { return false }
        if RuntimeSessionDecision.suppressesScheduledStart(
            sessions: state.sessions,
            occurrenceStart: occurrence.start,
            occurrenceEnd: occurrence.end,
            at: date
        ) { return false }
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
        do { _ = try RuntimeSessionDecision.composedMode(for: RuntimeCallbackDecision.currentAggregate(state, at: date)) }
        catch {
            state.sessions.removeAll { $0.id == session.id }
            state.record(RuntimeDiagnostic(operation: .conflictRejected, observedAt: date, detail: "Foreground scheduled start rejected: mixed restriction modes cannot be safely composed."), succeeded: false)
            return false
        }
        state.record(RuntimeDiagnostic(operation: .callbackReceived, observedAt: date, requestedStart: configuration.start, requestedEnd: configuration.end, revision: configuration.revision, detail: "Foreground reconciliation committed the current scheduled occurrence."), succeeded: true)
        return true
    }

    private func enforcementSessions(in state: RuntimeStoreDocument, at date: Date) -> [RuntimeSession] {
        RuntimeCallbackDecision.currentAggregate(state, at: date)
    }

    private func enforcementSessions(at date: Date) -> [RuntimeSession] { enforcementSessions(in: document, at: date) }
    private func hasAnyCommittedSession(in state: RuntimeStoreDocument, at date: Date) -> Bool { state.sessions.contains { $0.isEffective(at: date) } }
    private func hasAnyCommittedSession(at date: Date) -> Bool { hasAnyCommittedSession(in: document, at: date) }

    private func scheduledOccurrence(at date: Date) -> RuntimeOccurrenceResolver.Occurrence? {
        guard let configuration = document.configuration else { return nil }
        let hasCurrentScheduled = document.sessions.contains {
            $0.origin == .scheduled && $0.isEffective(at: date)
        }
        guard document.recurringEnabledIntent || hasCurrentScheduled else { return nil }
        return RuntimeOccurrenceResolver.currentOrNext(
            start: configuration.start,
            end: configuration.end,
            enabled: true,
            after: date,
            calendar: Calendar.current
        )
    }

    private func currentDate() -> Date { clock() }

    private func hasMatchingRecurringRegistration(_ configuration: RuntimeConfiguration?) -> Bool {
        guard let configuration,
              activityCenter.activities.contains(Self.activityName),
              let registered = activityCenter.schedule(for: Self.activityName) else { return false }
        return RuntimeScheduleDecision.registrationMatches(
            configuration: configuration,
            start: registered.intervalStart,
            end: registered.intervalEnd,
            repeats: registered.repeats
        )
    }

    private func manualSchedule(start: Date, end: Date) -> DeviceActivitySchedule {
        let calendar = Calendar.current
        // Persisted absolute boundaries are authoritative. Include seconds so
        // a 30-minute lock cannot be silently shortened by minute truncation.
        let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        let endComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: end)
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

        // A crash after the durable disable/clear commit can leave the old OS
        // route registered. Reconcile it on relaunch/foreground, but retain a
        // current scheduled end route when recurrence was disabled mid-window.
        if hasOSRegistration,
           !document.legacyRegistrationNeedsReview,
           !RuntimeLifecycle.scheduledRegistrationShouldRemain(document, at: Date()) {
            activityCenter.stopMonitoring([Self.activityName])
            hasOSRegistration = false
            scheduleIsRegistered = false
        }
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

    private func clearLastErrorAfterSuccessfulOperation() {
        guard RuntimeErrorPolicy.mayClearLastError(
            storageError: storageError,
            reconciliationError: reconciliationError,
            latestOperationSucceeded: document.operationStatus.succeeded
        ) else { return }
        lastError = nil
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

    private static func removeLegacyLiveActivityPreferenceKeys(from defaults: UserDefaults) {
        defaults.removeObject(forKey: legacyLiveActivityEnabledKey)
        defaults.removeObject(forKey: legacyLiveActivityPreferenceVersionKey)
    }

    private static func removeLegacyLiveActivityDiagnostics() {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        defaults.removeObject(forKey: legacyLiveActivityDiagnosticsKey)
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return }
        try? FileManager.default.removeItem(
            at: container.appendingPathComponent(legacyLiveActivityDiagnosticsLockFile)
        )
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

/// A narrow seam over `ScreenTimeCoordinator`'s friend-release API (R5 Slice
/// B2c review, P1-3) so `CompanionCoordinator`'s orchestration
/// (`endLockNow`/`replayPendingFriendRelease`/`finishFriendRelease`) can be
/// unit-tested against a fake conformer without touching FamilyControls,
/// DeviceActivity, or a real App Group store. `ScreenTimeCoordinator` is the
/// only production conformer; the conformance is a pure pass-through to its
/// own methods, added rather than duplicated.
@MainActor
protocol FriendReleaseLifecycle: AnyObject {
    func prepareFriendRelease(
        sessionID: UUID,
        activeSetID: String,
        requestID: String,
        approvalID: String,
        useID: String,
        approverIdentityID: String
    ) throws -> RuntimeFriendRelease.PrepareOutcome

    func applyFriendRelease(useID: String) throws -> RuntimeFriendRelease.ApplyOutcome

    @discardableResult
    func abandonFriendRelease(useID: String) throws -> Bool

    var pendingFriendReleaseIntent: RuntimeFriendReleaseIntent? { get }

    func friendReleaseSessionState(sessionID: String) -> ScreenTimeCoordinator.FriendReleaseSessionState
    func friendReleaseUseID(forSessionID sessionID: String) -> String?
}

extension ScreenTimeCoordinator: FriendReleaseLifecycle {}
