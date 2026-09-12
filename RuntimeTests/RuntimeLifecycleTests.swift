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
}
