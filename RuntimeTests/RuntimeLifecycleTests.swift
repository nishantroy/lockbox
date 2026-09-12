import Foundation
import XCTest
@testable import PhoneLockboxRuntime

final class RuntimeLifecycleTests: XCTestCase {
    private func policy(mode: RuntimeMode = .blockSelected, id: Int = 1) -> RuntimePolicySnapshot {
        RuntimePolicySnapshot(
            mode: mode,
            selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            selectionData: Data([UInt8(id)])
        )
    }

    private func session(
        id: UUID = UUID(),
        origin: RuntimeSessionOrigin = .scheduled,
        start: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        duration: TimeInterval = 3_600,
        mode: RuntimeMode = .blockSelected,
        dataID: Int = 1
    ) -> RuntimeSession {
        RuntimeSession(id: id, origin: origin, start: start, end: start.addingTimeInterval(duration), sourceRevision: 1, policy: policy(mode: mode, id: dataID))
    }

    func testOccurrenceIdentityIsStableAcrossDuplicateCallbacks() throws {
        let id = UUID()
        let original = session(id: id)
        var document = RuntimeStoreDocument()
        document.sessions = [original]

        XCTAssertEqual(RuntimeSessionDecision.matchingScheduledOccurrence(sessions: document.sessions, start: original.start, end: original.end)?.id, id)
        XCTAssertEqual(RuntimeSessionDecision.occurrenceKey(origin: .scheduled, start: original.start, end: original.end), original.occurrenceKey)
        XCTAssertTrue(RuntimeSessionDecision.isReleased(sessions: document.sessions, releasedOccurrences: [], origin: .scheduled, start: original.start, end: original.end) == false)
    }

    func testNaturalExpiryAndRecoveryReleaseRetainTerminalSuppression() throws {
        let id = UUID()
        let original = session(id: id)
        var document = RuntimeStoreDocument()
        document.sessions = [original]
        document.recoveryCommitment = try RecoveryCommitment(sessionIDs: [id], requestedAt: original.start.addingTimeInterval(10))

        XCTAssertTrue(RuntimeLifecycle.expireNaturalSessions(&document, at: original.end))
        XCTAssertEqual(document.sessions[0].state, .expired)
        XCTAssertNil(document.recoveryCommitment)

        var released = RuntimeStoreDocument()
        let live = session(id: id)
        released.sessions = [live]
        try RuntimeLifecycle.release(&released, sessionIDs: [id], at: live.start.addingTimeInterval(1))
        XCTAssertEqual(released.sessions[0].state, .released)
        XCTAssertTrue(RuntimeSessionDecision.isReleased(sessions: released.sessions, releasedOccurrences: released.releasedOccurrences, origin: .scheduled, start: live.start, end: live.end))
    }

    func testMixedModesAreRejectedAndSameModePoliciesCanCompose() throws {
        let first = session(mode: .blockSelected)
        let second = session(origin: .manual, start: first.start, mode: .allowOnlySelected, dataID: 2)
        XCTAssertThrowsError(try RuntimeSessionDecision.composedMode(for: [first, second])) { error in
            XCTAssertEqual(error as? RuntimeValidationError, .overlapUnsupported)
        }
        XCTAssertEqual(try RuntimeSessionDecision.composedMode(for: [first, session(origin: .manual, start: first.start)]), .blockSelected)
    }

    func testPendingConfigurationActivatesOnlyWhenAllSessionsEnd() throws {
        let active = session()
        var document = RuntimeStoreDocument()
        document.sessions = [active]
        document.configuration = RuntimeConfiguration(revision: 1, start: RuntimeTime(hour: 22, minute: 0), end: RuntimeTime(hour: 7, minute: 0), mode: .blockSelected, selectionSummary: policy().selectionSummary, selectionData: Data([1]))
        document.pendingConfiguration = RuntimeConfiguration(revision: 2, start: RuntimeTime(hour: 23, minute: 0), end: RuntimeTime(hour: 6, minute: 0), mode: .blockSelected, selectionSummary: policy().selectionSummary, selectionData: Data([2]))

        XCTAssertFalse(RuntimeLifecycle.activatePendingConfigurationIfIdle(&document, at: active.start.addingTimeInterval(1)))
        XCTAssertTrue(RuntimeLifecycle.activatePendingConfigurationIfIdle(&document, at: active.end))
        XCTAssertEqual(document.configuration?.revision, 2)
        XCTAssertNil(document.pendingConfiguration)
    }

    func testPendingConfigurationDefersAnAlreadyOpenReplacementWindow() throws {
        let active = session(start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 100)
        var document = RuntimeStoreDocument()
        document.sessions = [active]
        document.recurringEnabledIntent = true
        document.pendingConfiguration = RuntimeConfiguration(
            revision: 2,
            start: RuntimeTime(hour: 0, minute: 0),
            end: RuntimeTime(hour: 23, minute: 59),
            mode: .blockSelected,
            selectionSummary: policy().selectionSummary,
            selectionData: Data([2])
        )
        let activation = active.end
        XCTAssertTrue(RuntimeLifecycle.activatePendingConfigurationIfIdle(&document, at: activation))
        XCTAssertEqual(document.configuration?.revision, 2)
        XCTAssertEqual(document.suppressedOccurrenceKeys.count, 1)
    }

    func testRecoveryCommitmentTargetsOnlyTheOriginalActiveSubset() throws {
        let first = session()
        let newSession = session(origin: .manual, start: first.start, dataID: 2)
        let commitment = try RecoveryCommitment(sessionIDs: [first.id], requestedAt: first.start.addingTimeInterval(1))
        XCTAssertTrue(commitment.isEligible(at: commitment.eligibleAt, activeSessionIDs: [first.id]))
        XCTAssertFalse(commitment.isEligible(at: commitment.eligibleAt, activeSessionIDs: [newSession.id]))
        XCTAssertFalse(commitment.isEligible(at: commitment.eligibleAt, activeSessionIDs: [first.id, newSession.id]))
    }

    func testTerminalHistoryPruningRetainsCurrentScheduledSuppression() throws {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        var document = RuntimeStoreDocument()
        for index in 0..<70 {
            let old = session(
                start: Date(timeIntervalSinceReferenceDate: Double(index)),
                duration: 1,
                dataID: index + 1
            )
            document.sessions.append(RuntimeSession(
                id: old.id,
                origin: old.origin,
                start: old.start,
                end: old.end,
                sourceRevision: old.sourceRevision,
                policy: old.policy,
                state: .released
            ))
            document.releasedOccurrences.append(RuntimeReleasedOccurrence(
                sessionID: old.id, origin: old.origin, start: old.start, end: old.end, releasedAt: old.end
            ))
        }
        let current = session(start: now.addingTimeInterval(-60), duration: 600)
        var releasedCurrent = current
        releasedCurrent.state = .released
        document.sessions.append(releasedCurrent)
        document.releasedOccurrences.append(RuntimeReleasedOccurrence(
            sessionID: current.id, origin: .scheduled, start: current.start, end: current.end, releasedAt: now
        ))

        RuntimeLifecycle.pruneTerminalSessions(&document, at: now)

        XCTAssertLessThanOrEqual(document.sessions.count, 64)
        XCTAssertTrue(RuntimeSessionDecision.isReleased(
            sessions: document.sessions,
            releasedOccurrences: document.releasedOccurrences,
            origin: .scheduled,
            start: current.start,
            end: current.end
        ))
        XCTAssertTrue(RuntimeLifecycle.shouldSuppressScheduledOccurrence(
            document, start: current.start, end: current.end
        ))
        XCTAssertNoThrow(try document.validate())
    }

    func testActivationFenceSuppressesChangedCurrentIntervalButAllowsFutureDay() throws {
        let currentStart = Date(timeIntervalSinceReferenceDate: 20_000)
        var document = RuntimeStoreDocument()
        document.scheduledActivationFence = RuntimeScheduledActivationFence(date: currentStart)
        let changedEnd = currentStart.addingTimeInterval(7_200)
        XCTAssertTrue(RuntimeLifecycle.shouldSuppressScheduledOccurrence(document, start: currentStart, end: changedEnd))

        var calendar = Calendar.current
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: currentStart)!
        XCTAssertFalse(RuntimeLifecycle.shouldSuppressScheduledOccurrence(document, start: tomorrow, end: tomorrow.addingTimeInterval(3_600)))
    }

    func testCrashOrderingLeavesApplyIntentDurableBeforeSideEffect() throws {
        enum SimulatedCrash: Error { case afterCommit }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phone-lockbox-r23-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedRuntimeStore(directoryURL: directory)
        let committed = session()
        XCTAssertThrowsError(try store.withTransaction { context in
            context.document.sessions = [committed]
            context.document.policyIntent = .apply
            try context.commit()
            throw SimulatedCrash.afterCommit
        })
        let recovered = try store.read()
        XCTAssertEqual(recovered.sessions.first?.id, committed.id)
        XCTAssertEqual(recovered.policyIntent, .apply)
    }

    func testManualTerminalClearIntentReplaysTheCurrentScheduledAggregate() throws {
        let scheduled = session(id: UUID(), origin: .scheduled, start: Date(timeIntervalSinceReferenceDate: 1_000))
        let manual = session(id: UUID(), origin: .manual, start: scheduled.start)
        var document = RuntimeStoreDocument()
        var releasedManual = manual
        releasedManual.state = .released
        document.sessions = [scheduled, releasedManual]
        document.manualRegistrationActive = true
        document.policyIntent = .clear

        let intent = RuntimeCallbackDecision.preparePolicyReconciliation(&document, at: scheduled.start.addingTimeInterval(100))
        XCTAssertEqual(intent, .apply)
        XCTAssertEqual(document.policyIntent, .apply)
        XCTAssertEqual(RuntimeReconciliation.action(document: document, at: scheduled.start.addingTimeInterval(100), authorized: true, registrationMatches: false), .applyScheduled)
    }

    func testTerminalManualIntentClearsWhenNoCurrentAggregateRemains() {
        let manual = session(origin: .manual, start: Date(timeIntervalSinceReferenceDate: 1_000))
        var document = RuntimeStoreDocument()
        var released = manual
        released.state = .released
        document.sessions = [released]
        document.manualRegistrationActive = true
        document.policyIntent = .clear

        XCTAssertEqual(RuntimeCallbackDecision.desiredPolicyIntent(document, at: released.start.addingTimeInterval(10)), .clear)
        _ = RuntimeCallbackDecision.preparePolicyReconciliation(&document, at: released.start.addingTimeInterval(10))
        XCTAssertEqual(document.policyIntent, .clear)
    }

    func testManualOnlyStateDoesNotKeepDailyRegistration() {
        let manual = session(origin: .manual, start: Date(timeIntervalSinceReferenceDate: 1_000))
        var document = RuntimeStoreDocument()
        document.sessions = [manual]
        document.manualRegistrationActive = true
        XCTAssertFalse(RuntimeLifecycle.scheduledRegistrationShouldRemain(document, at: manual.start.addingTimeInterval(1)))
    }

    func testEnabledRecurrenceRetainsDailyRegistrationAfterNaturalExpiry() {
        let configuration = RuntimeConfiguration(
            revision: 1,
            start: RuntimeTime(hour: 22, minute: 0),
            end: RuntimeTime(hour: 7, minute: 0),
            mode: .blockSelected,
            selectionSummary: policy().selectionSummary,
            selectionData: Data([1])
        )
        let ended = session(start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 10)
        var document = RuntimeStoreDocument()
        document.configuration = configuration
        document.recurringEnabledIntent = true
        document.sessions = [ended]
        var expired = ended
        expired.state = .expired
        document.sessions = [expired]

        // Natural expiry must stop shielding this occurrence without
        // unregistering the repeating route for the next one.
        XCTAssertTrue(RuntimeLifecycle.scheduledRegistrationShouldRemain(document, at: ended.end))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let nextStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 22))!
        XCTAssertTrue(RuntimeScheduleDecision.accepts(.start, configuration: configuration, at: nextStart, calendar: calendar))
    }

    func testPendingReplacementIsTheOnlyNaturalEndRouteStop() {
        let ended = session(start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 10)
        var document = RuntimeStoreDocument()
        document.recurringEnabledIntent = true
        document.sessions = [ended]
        var expired = ended
        expired.state = .expired
        document.sessions = [expired]
        document.pendingConfiguration = RuntimeConfiguration(
            revision: 2,
            start: RuntimeTime(hour: 23, minute: 0),
            end: RuntimeTime(hour: 6, minute: 0),
            mode: .blockSelected,
            selectionSummary: policy().selectionSummary,
            selectionData: Data([2])
        )

        XCTAssertFalse(RuntimeLifecycle.scheduledRegistrationShouldRemain(document, at: ended.end))
        // If another route still owns the current scheduled session, retain
        // its end callback even while a replacement waits to activate.
        document.sessions = [ended]
        XCTAssertTrue(RuntimeLifecycle.scheduledRegistrationShouldRemain(
            document,
            at: ended.start.addingTimeInterval(1)
        ))
    }

    func testNaturalExpiryPreparesDurableClearBeforeTheEndRouteIsStopped() {
        let scheduled = session(start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 10)
        var document = RuntimeStoreDocument()
        document.sessions = [scheduled]
        document.policyIntent = .apply

        let intent = RuntimeCallbackDecision.preparePolicyReconciliation(&document, at: scheduled.end)
        XCTAssertEqual(document.sessions.first?.state, .expired)
        XCTAssertEqual(intent, .clear)
        XCTAssertEqual(document.policyIntent, .clear)
    }

    func testMismatchedManualRouteIsPendingButNeverEnforceable() throws {
        let manual = session(origin: .manual, start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 10_000)
        var document = RuntimeStoreDocument()
        var pending = manual
        pending.state = .recoveryPending
        document.sessions = [pending]
        document.recoveryCommitment = try RecoveryCommitment(sessionIDs: [manual.id], requestedAt: manual.start.addingTimeInterval(1))
        document.manualRegistrationActive = true

        XCTAssertTrue(RuntimeLifecycle.normalizeManualRegistration(&document, at: manual.start.addingTimeInterval(2), routeExists: true, routeMatches: false))
        XCTAssertFalse(document.manualRegistrationActive)
        XCTAssertTrue(document.manualRegistrationIntent)
        XCTAssertTrue(RuntimeCallbackDecision.currentAggregate(document, at: manual.start.addingTimeInterval(2)).isEmpty)
        XCTAssertNoThrow(try document.validate())
    }

    func testManualRouteLossExpiresManualTargetAndRepairsRecoveryRelationship() throws {
        let scheduled = session(id: UUID(), origin: .scheduled, start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 10_000)
        let manual = session(id: UUID(), origin: .manual, start: scheduled.start, duration: 10_000)
        var document = RuntimeStoreDocument()
        var pendingScheduled = scheduled
        pendingScheduled.state = .recoveryPending
        var pendingManual = manual
        pendingManual.state = .recoveryPending
        document.sessions = [pendingScheduled, pendingManual]
        document.recoveryCommitment = try RecoveryCommitment(sessionIDs: [scheduled.id, manual.id], requestedAt: scheduled.start.addingTimeInterval(10))
        document.manualRegistrationActive = true

        XCTAssertTrue(RuntimeLifecycle.normalizeManualRegistration(&document, at: scheduled.start.addingTimeInterval(20), routeExists: false, routeMatches: false))
        XCTAssertEqual(document.sessions.first(where: { $0.id == manual.id })?.state, .expired)
        // The expired target remains named so the fixed recovery request stays
        // auditable; only its pending-session relationship is removed.
        XCTAssertEqual(document.recoveryCommitment?.sessionIDs, Set([scheduled.id, manual.id]))
        XCTAssertFalse(RuntimeCallbackDecision.currentAggregate(document, at: scheduled.start.addingTimeInterval(20)).contains { $0.id == manual.id })
        XCTAssertNoThrow(try document.validate())
    }

    func testPruningProtectsCommitmentTerminalTargetWhileRetainingBoundedHistory() throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        var document = RuntimeStoreDocument()
        for index in 0..<50 {
            let old = session(id: UUID(), start: base.addingTimeInterval(Double(index)), duration: 1)
            var released = old
            released.state = .released
            document.sessions.append(released)
            document.releasedOccurrences.append(RuntimeReleasedOccurrence(sessionID: old.id, origin: .scheduled, start: old.start, end: old.end, releasedAt: old.end))
        }
        let protected = session(id: UUID(), start: base.addingTimeInterval(100), duration: 100)
        var expiredProtected = protected
        expiredProtected.state = .expired
        let liveTarget = session(id: UUID(), start: base.addingTimeInterval(100), duration: 10_000)
        var pendingLive = liveTarget
        pendingLive.state = .recoveryPending
        document.sessions += [expiredProtected, pendingLive]
        document.releasedOccurrences.append(RuntimeReleasedOccurrence(sessionID: protected.id, origin: .scheduled, start: protected.start, end: protected.end, releasedAt: protected.end))
        document.recoveryCommitment = try RecoveryCommitment(sessionIDs: [protected.id, liveTarget.id], requestedAt: protected.start.addingTimeInterval(1))

        RuntimeLifecycle.pruneTerminalSessions(&document, at: base.addingTimeInterval(200))

        XCTAssertLessThanOrEqual(document.sessions.count, 64)
        XCTAssertNotNil(document.sessions.first(where: { $0.id == protected.id }))
        XCTAssertNotNil(document.releasedOccurrences.first(where: { $0.sessionID == protected.id }))
        XCTAssertNoThrow(try document.validate())
    }

    func testManualHistoryStressRetainsCurrentScheduledMarker() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        var document = RuntimeStoreDocument()
        for index in 0..<80 {
            let old = session(origin: .manual, start: Date(timeIntervalSinceReferenceDate: Double(index)), duration: 1)
            var released = old
            released.state = .released
            document.sessions.append(released)
            document.releasedOccurrences.append(RuntimeReleasedOccurrence(sessionID: old.id, origin: .manual, start: old.start, end: old.end, releasedAt: old.end))
        }
        let current = session(origin: .scheduled, start: now.addingTimeInterval(-60), duration: 600)
        var releasedCurrent = current
        releasedCurrent.state = .released
        document.sessions.append(releasedCurrent)
        document.releasedOccurrences.append(RuntimeReleasedOccurrence(sessionID: current.id, origin: .scheduled, start: current.start, end: current.end, releasedAt: now))

        RuntimeLifecycle.pruneTerminalSessions(&document, at: now)

        XCTAssertLessThanOrEqual(document.sessions.count, 64)
        XCTAssertLessThanOrEqual(document.releasedOccurrences.count, 64)
        XCTAssertTrue(RuntimeSessionDecision.isReleased(sessions: document.sessions, releasedOccurrences: document.releasedOccurrences, origin: .scheduled, start: current.start, end: current.end))
        XCTAssertNoThrow(try document.validate())
    }

    func testAbsoluteFenceAllowsFutureSameDayStartButSuppressesCurrentReplacement() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let currentStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 0))!
        let currentEnd = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 8))!
        let nextSameDayStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 22))!
        var document = RuntimeStoreDocument()
        document.scheduledActivationFence = RuntimeScheduledActivationFence(date: currentStart, calendar: calendar)

        XCTAssertTrue(RuntimeLifecycle.shouldSuppressScheduledOccurrence(document, start: currentStart, end: currentEnd, calendar: calendar))
        XCTAssertFalse(RuntimeLifecycle.shouldSuppressScheduledOccurrence(document, start: nextSameDayStart, end: nextSameDayStart.addingTimeInterval(8 * 3600), calendar: calendar))
    }

    func testReleasedOvernightWindowFencesChangedBoundariesUntilFrozenEnd() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 22))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 7))!
        let releasedAt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 2))!
        var document = RuntimeStoreDocument()
        document.sessions = [session(origin: .scheduled, start: start, duration: end.timeIntervalSince(start))]
        try RuntimeLifecycle.release(&document, sessionIDs: Set([document.sessions[0].id]), at: releasedAt)

        let changedCurrent = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 0))!
        let futureSameDay = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 22))!
        XCTAssertTrue(RuntimeLifecycle.shouldSuppressScheduledOccurrence(document, start: changedCurrent, end: end, calendar: calendar))
        XCTAssertFalse(RuntimeLifecycle.shouldSuppressScheduledOccurrence(document, start: futureSameDay, end: futureSameDay.addingTimeInterval(8 * 3600), calendar: calendar))
    }

    func testPendingWindowFenceWorksAfterMidnightAndAllowsNextNightSameDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let afterMidnight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 2))!
        let pending = RuntimeConfiguration(
            revision: 2,
            start: RuntimeTime(hour: 0, minute: 0),
            end: RuntimeTime(hour: 8, minute: 0),
            mode: .blockSelected,
            selectionSummary: policy().selectionSummary,
            selectionData: Data([2])
        )
        var document = RuntimeStoreDocument()
        document.pendingConfiguration = pending
        XCTAssertTrue(RuntimeLifecycle.activatePendingConfigurationIfIdle(&document, at: afterMidnight, calendar: calendar))

        let currentStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 0))!
        let nextNight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 22))!
        XCTAssertTrue(RuntimeLifecycle.shouldSuppressScheduledOccurrence(document, start: currentStart, end: currentStart.addingTimeInterval(8 * 3600), calendar: calendar))
        XCTAssertFalse(RuntimeLifecycle.shouldSuppressScheduledOccurrence(document, start: nextNight, end: nextNight.addingTimeInterval(8 * 3600), calendar: calendar))
    }

    func testLegacyCivilFenceIsConservativelyPreservedOnDecode() throws {
        let old: [String: Any] = ["year": 2026, "month": 9, "day": 10]
        let data = try JSONSerialization.data(withJSONObject: old)
        let fence = try JSONDecoder().decode(RuntimeScheduledActivationFence.self, from: data)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sameDay = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 22))!
        let nextDay = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 22))!
        XCTAssertTrue(fence.matches(sameDay, calendar: calendar))
        XCTAssertFalse(fence.matches(nextDay, calendar: calendar))

        // With the retained configuration, migration can turn the old civil
        // marker into an absolute end cutoff and permit the next same-day
        // night without dropping suppression for the old open window.
        var migrated = RuntimeStoreDocument()
        migrated.configuration = RuntimeConfiguration(
            revision: 1,
            start: RuntimeTime(hour: 0, minute: 0),
            end: RuntimeTime(hour: 8, minute: 0),
            mode: .blockSelected,
            selectionSummary: policy().selectionSummary,
            selectionData: Data([1])
        )
        migrated.scheduledActivationFence = fence
        let oldWindowStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 0))!
        let oldWindowEnd = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 8))!
        let nextNightStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 22))!
        let nextNightEnd = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 6))!
        XCTAssertTrue(RuntimeLifecycle.shouldSuppressScheduledOccurrence(migrated, start: oldWindowStart, end: oldWindowEnd, calendar: calendar))
        XCTAssertFalse(RuntimeLifecycle.shouldSuppressScheduledOccurrence(migrated, start: nextNightStart, end: nextNightEnd, calendar: calendar))
    }

    func testPendingWindowFenceWorksBeforeMidnightAndAllowsNextNight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let beforeMidnight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 23))!
        let pending = RuntimeConfiguration(
            revision: 2,
            start: RuntimeTime(hour: 22, minute: 0),
            end: RuntimeTime(hour: 8, minute: 0),
            mode: .blockSelected,
            selectionSummary: policy().selectionSummary,
            selectionData: Data([2])
        )
        var document = RuntimeStoreDocument()
        document.pendingConfiguration = pending
        XCTAssertTrue(RuntimeLifecycle.activatePendingConfigurationIfIdle(&document, at: beforeMidnight, calendar: calendar))

        let currentNight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 22))!
        let nextNight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 22))!
        XCTAssertTrue(RuntimeLifecycle.shouldSuppressScheduledOccurrence(document, start: currentNight, end: currentNight.addingTimeInterval(10 * 3600), calendar: calendar))
        XCTAssertFalse(RuntimeLifecycle.shouldSuppressScheduledOccurrence(document, start: nextNight, end: nextNight.addingTimeInterval(8 * 3600), calendar: calendar))
    }
}
