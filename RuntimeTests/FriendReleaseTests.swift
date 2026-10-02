import Foundation
import XCTest
@testable import PhoneLockboxRuntime

/// R5 Slice B2b: the durable friend-release intent and exact-session
/// release. Natural end always wins; every stale/mismatched/already-used
/// case must be a calm no-op, never a throw, and must change no state beyond
/// natural expiry and intent cleanup.
final class FriendReleaseTests: XCTestCase {
    private func policy(id: Int = 1) -> RuntimePolicySnapshot {
        RuntimePolicySnapshot(
            mode: .blockSelected,
            selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            selectionData: Data([UInt8(id)])
        )
    }

    private func session(
        id: UUID = UUID(),
        origin: RuntimeSessionOrigin = .scheduled,
        start: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        duration: TimeInterval = 3_600,
        dataID: Int = 1
    ) -> RuntimeSession {
        RuntimeSession(id: id, origin: origin, start: start, end: start.addingTimeInterval(duration), sourceRevision: 1, policy: policy(id: dataID))
    }

    private func intent(
        sessionID: UUID,
        activeSetID: String,
        requestID: String = "req-1",
        approvalID: String = "appr-1",
        useID: String = "use-1",
        approverIdentityID: String = "friend-1",
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 1_000)
    ) -> RuntimeFriendReleaseIntent {
        RuntimeFriendReleaseIntent(
            sessionID: sessionID,
            activeSetID: activeSetID,
            requestID: requestID,
            approvalID: approvalID,
            useID: useID,
            approverIdentityID: approverIdentityID,
            createdAt: createdAt
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-lockbox-friend-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Active-set ID

    func testActiveSetIDFixedVectorMatchesThePortedCoordinatorAlgorithm() {
        let first = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let second = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        XCTAssertEqual(
            RuntimeActiveSet.id(for: [first, second]),
            "dae82c44b1d1590d8c3414b027ab80539197573c0e485d5a35beb5f2538502ba"
        )
        // Input order must not matter: IDs are sorted before hashing.
        XCTAssertEqual(RuntimeActiveSet.id(for: [second, first]), RuntimeActiveSet.id(for: [first, second]))
        XCTAssertEqual(
            RuntimeActiveSet.id(for: [first]),
            "0a0970fb8e2bca03cd5c270296cc9c6367c06acf89f372b6bc71ed44ba8a8fc9"
        )
    }

    // MARK: - Prepare + apply releases only the target

    func testPrepareAndApplyReleasesOnlyTargetSessionAndKeepsOverlapEnforced() throws {
        let target = session(id: UUID(), origin: .scheduled, start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 3_600)
        let overlapping = session(id: UUID(), origin: .manual, start: target.start, duration: 7_200, dataID: 2)
        var document = RuntimeStoreDocument()
        document.sessions = [target, overlapping]
        document.manualRegistrationActive = true

        let now = target.start.addingTimeInterval(10)
        let activeSetID = RuntimeActiveSet.id(for: [target.id, overlapping.id])
        let friendIntent = intent(sessionID: target.id, activeSetID: activeSetID)

        let prepareOutcome = RuntimeLifecycle.prepareFriendRelease(
            &document, intent: friendIntent, effectiveSessionIDs: [target.id, overlapping.id], at: now
        )
        XCTAssertEqual(prepareOutcome, .recorded)
        XCTAssertEqual(document.pendingFriendRelease, friendIntent)
        try document.validate()

        let applyOutcome = RuntimeLifecycle.applyFriendRelease(&document, useID: friendIntent.useID, at: now.addingTimeInterval(1))
        guard case .released(let releasedID, let remaining, let effect) = applyOutcome else {
            return XCTFail("expected a released outcome, got \(applyOutcome)")
        }
        XCTAssertEqual(releasedID, target.id)
        XCTAssertEqual(remaining, [overlapping.id])
        XCTAssertEqual(effect.policyIntent, .apply)
        XCTAssertNil(effect.manualRouteToStop)
        XCTAssertNil(document.pendingFriendRelease)
        XCTAssertEqual(document.sessions.first(where: { $0.id == target.id })?.state, .released)
        XCTAssertEqual(document.sessions.first(where: { $0.id == overlapping.id })?.state, .active)
        let marker = document.releasedOccurrences.first(where: { $0.sessionID == target.id })
        XCTAssertEqual(marker?.cause, .friendApproval)
        XCTAssertEqual(marker?.friendUseID, friendIntent.useID)
        try document.validate()
    }

    func testApplyReturnsManualRouteToStopWhenReleasedSessionWasTheLastLiveManualSession() throws {
        let manual = session(id: UUID(), origin: .manual, start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 3_600)
        var document = RuntimeStoreDocument()
        document.sessions = [manual]
        document.manualRegistrationActive = true
        let route = RuntimeManualRouteBinding(sessionID: manual.id, registeredStart: manual.start, registeredEnd: manual.end)
        document.manualRoute = route

        let now = manual.start.addingTimeInterval(10)
        let activeSetID = RuntimeActiveSet.id(for: [manual.id])
        let friendIntent = intent(sessionID: manual.id, activeSetID: activeSetID)
        XCTAssertEqual(
            RuntimeLifecycle.prepareFriendRelease(&document, intent: friendIntent, effectiveSessionIDs: [manual.id], at: now),
            .recorded
        )

        let outcome = RuntimeLifecycle.applyFriendRelease(&document, useID: friendIntent.useID, at: now.addingTimeInterval(1))
        guard case .released(_, let remaining, let effect) = outcome else {
            return XCTFail("expected a released outcome, got \(outcome)")
        }
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(effect.policyIntent, .clear)
        XCTAssertEqual(effect.manualRouteToStop, route)
        XCTAssertFalse(document.manualRegistrationActive)
        XCTAssertFalse(document.manualRegistrationIntent)
        // `applyFriendRelease` never clears `manualRoute` itself: the caller
        // only nils it after the OS stop actually succeeds, exactly as
        // `confirmRecovery`/`stopManualRouteIfOwned` do.
        XCTAssertEqual(document.manualRoute, route)
        try document.validate()
    }

    // MARK: - Natural end wins

    func testNaturalEndBeforeApplyIsANoOpAndClearsTheIntent() throws {
        let target = session(id: UUID(), start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 600)
        var document = RuntimeStoreDocument()
        document.sessions = [target]
        let now = target.start.addingTimeInterval(10)
        let activeSetID = RuntimeActiveSet.id(for: [target.id])
        let friendIntent = intent(sessionID: target.id, activeSetID: activeSetID)
        XCTAssertEqual(
            RuntimeLifecycle.prepareFriendRelease(&document, intent: friendIntent, effectiveSessionIDs: [target.id], at: now),
            .recorded
        )

        let outcome = RuntimeLifecycle.applyFriendRelease(&document, useID: friendIntent.useID, at: target.end.addingTimeInterval(1))
        XCTAssertEqual(outcome, .noOp(.alreadyEnded))
        XCTAssertNil(document.pendingFriendRelease)
        XCTAssertEqual(document.sessions.first?.state, .expired)
        XCTAssertTrue(document.releasedOccurrences.isEmpty)
        try document.validate()
    }

    func testNaturalEndExactlyAtTheSessionEndIsAlsoANoOp() throws {
        let target = session(id: UUID(), start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 600)
        var document = RuntimeStoreDocument()
        document.sessions = [target]
        let now = target.start.addingTimeInterval(10)
        let activeSetID = RuntimeActiveSet.id(for: [target.id])
        let friendIntent = intent(sessionID: target.id, activeSetID: activeSetID)
        XCTAssertEqual(
            RuntimeLifecycle.prepareFriendRelease(&document, intent: friendIntent, effectiveSessionIDs: [target.id], at: now),
            .recorded
        )

        // `isEffective(at:)` is a half-open interval: `date == end` is not
        // effective, so the apply exactly at the natural end is a no-op too.
        let outcome = RuntimeLifecycle.applyFriendRelease(&document, useID: friendIntent.useID, at: target.end)
        XCTAssertEqual(outcome, .noOp(.alreadyEnded))
        XCTAssertNil(document.pendingFriendRelease)
    }

    // MARK: - Active-set mismatch

    func testActiveSetMismatchAtPrepareIsANoOpAndRecordsNothing() throws {
        let target = session(id: UUID(), start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 3_600)
        var document = RuntimeStoreDocument()
        document.sessions = [target]
        let now = target.start.addingTimeInterval(10)
        let staleActiveSetID = RuntimeActiveSet.id(for: [UUID()])
        let friendIntent = intent(sessionID: target.id, activeSetID: staleActiveSetID)

        let outcome = RuntimeLifecycle.prepareFriendRelease(
            &document, intent: friendIntent, effectiveSessionIDs: [target.id], at: now
        )
        XCTAssertEqual(outcome, .noOp(.activeSetMismatch))
        XCTAssertNil(document.pendingFriendRelease)
        try document.validate()
    }

    // MARK: - Crash/replay idempotency

    func testCrashBetweenPrepareAndApplyLeadsToAnIdempotentReplayedApply() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedRuntimeStore(directoryURL: directory)
        let target = session(id: UUID(), start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 3_600)
        let now = target.start.addingTimeInterval(10)
        let activeSetID = RuntimeActiveSet.id(for: [target.id])
        let friendIntent = intent(sessionID: target.id, activeSetID: activeSetID)

        try store.withTransaction { context in
            context.document.sessions = [target]
            let outcome = RuntimeLifecycle.prepareFriendRelease(
                &context.document, intent: friendIntent, effectiveSessionIDs: [target.id], at: now
            )
            XCTAssertEqual(outcome, .recorded)
            try context.commit()
        }

        // Simulate the crash: read the committed document fresh instead of
        // continuing the same in-memory transaction/context.
        var reloaded = try store.read()
        XCTAssertEqual(reloaded.pendingFriendRelease, friendIntent)

        let applyNow = now.addingTimeInterval(1)
        let first = RuntimeLifecycle.applyFriendRelease(&reloaded, useID: friendIntent.useID, at: applyNow)
        guard case .released = first else { return XCTFail("expected the first apply to release, got \(first)") }
        XCTAssertNil(reloaded.pendingFriendRelease)
        XCTAssertEqual(reloaded.sessions.first?.state, .released)

        // A foreground replay with the same useID, after the intent is
        // already cleared, is a calm no-op: not a second release, not a throw.
        let replay = RuntimeLifecycle.applyFriendRelease(&reloaded, useID: friendIntent.useID, at: applyNow.addingTimeInterval(1))
        XCTAssertEqual(replay, .noOp(.noMatchingPendingIntent))
        XCTAssertEqual(reloaded.sessions.first?.state, .released)
        XCTAssertEqual(reloaded.releasedOccurrences.filter { $0.sessionID == target.id }.count, 1)
        try reloaded.validate()
    }

    // MARK: - Conflicting / repeated prepares

    func testSecondDifferentIntentIsRejectedWhileOnePendingButIdenticalReprepareIsIdempotent() throws {
        let target = session(id: UUID(), start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 3_600)
        var document = RuntimeStoreDocument()
        document.sessions = [target]
        let now = target.start.addingTimeInterval(10)
        let activeSetID = RuntimeActiveSet.id(for: [target.id])
        let first = intent(sessionID: target.id, activeSetID: activeSetID, useID: "use-1")
        XCTAssertEqual(
            RuntimeLifecycle.prepareFriendRelease(&document, intent: first, effectiveSessionIDs: [target.id], at: now),
            .recorded
        )

        let second = intent(sessionID: target.id, activeSetID: activeSetID, useID: "use-2")
        let conflict = RuntimeLifecycle.prepareFriendRelease(&document, intent: second, effectiveSessionIDs: [target.id], at: now)
        XCTAssertEqual(conflict, .noOp(.conflictingPendingIntent))
        XCTAssertEqual(document.pendingFriendRelease, first)

        let replay = RuntimeLifecycle.prepareFriendRelease(&document, intent: first, effectiveSessionIDs: [target.id], at: now)
        XCTAssertEqual(replay, .recorded)
        XCTAssertEqual(document.pendingFriendRelease, first)
    }

    // MARK: - Normalization

    func testPendingIntentForAnExpiredSessionIsNormalizedAway() throws {
        let target = session(id: UUID(), start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 600)
        var document = RuntimeStoreDocument()
        document.sessions = [target]
        let now = target.start.addingTimeInterval(10)
        let activeSetID = RuntimeActiveSet.id(for: [target.id])
        let friendIntent = intent(sessionID: target.id, activeSetID: activeSetID)
        XCTAssertEqual(
            RuntimeLifecycle.prepareFriendRelease(&document, intent: friendIntent, effectiveSessionIDs: [target.id], at: now),
            .recorded
        )

        XCTAssertTrue(RuntimeLifecycle.expireNaturalSessions(&document, at: target.end.addingTimeInterval(1)))
        XCTAssertNil(document.pendingFriendRelease)
        XCTAssertEqual(document.sessions.first?.state, .expired)
        try document.validate()
    }

    func testRecoveryCommitmentTargetingTheReleasedSessionIsNormalizedAway() throws {
        let target = session(id: UUID(), start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 3_600)
        var document = RuntimeStoreDocument()
        document.sessions = [target]
        let now = target.start.addingTimeInterval(10)
        document.recoveryCommitment = try RecoveryCommitment(sessionIDs: [target.id], requestedAt: now)
        document.sessions[0].state = .recoveryPending

        let activeSetID = RuntimeActiveSet.id(for: [target.id])
        let friendIntent = intent(sessionID: target.id, activeSetID: activeSetID)
        XCTAssertEqual(
            RuntimeLifecycle.prepareFriendRelease(&document, intent: friendIntent, effectiveSessionIDs: [target.id], at: now),
            .recorded
        )

        let outcome = RuntimeLifecycle.applyFriendRelease(&document, useID: friendIntent.useID, at: now.addingTimeInterval(1))
        guard case .released = outcome else { return XCTFail("expected a released outcome, got \(outcome)") }
        XCTAssertNil(document.recoveryCommitment)
        try document.validate()
    }

    func testRecoveryCommitmentTargetingAnotherSessionIsPreservedAfterAnUnrelatedFriendRelease() throws {
        let target = session(id: UUID(), origin: .scheduled, start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 3_600)
        let other = session(id: UUID(), origin: .manual, start: target.start, duration: 7_200, dataID: 2)
        var document = RuntimeStoreDocument()
        document.sessions = [target, other]
        document.manualRegistrationActive = true
        let now = target.start.addingTimeInterval(10)
        document.recoveryCommitment = try RecoveryCommitment(sessionIDs: [other.id], requestedAt: now)
        document.sessions[1].state = .recoveryPending

        let activeSetID = RuntimeActiveSet.id(for: [target.id, other.id])
        let friendIntent = intent(sessionID: target.id, activeSetID: activeSetID)
        XCTAssertEqual(
            RuntimeLifecycle.prepareFriendRelease(&document, intent: friendIntent, effectiveSessionIDs: [target.id, other.id], at: now),
            .recorded
        )

        let outcome = RuntimeLifecycle.applyFriendRelease(&document, useID: friendIntent.useID, at: now.addingTimeInterval(1))
        guard case .released(_, let remaining, _) = outcome else { return XCTFail("expected a released outcome, got \(outcome)") }
        XCTAssertEqual(remaining, [other.id])
        XCTAssertEqual(document.recoveryCommitment?.sessionIDs, Set([other.id]))
        XCTAssertEqual(document.sessions.first(where: { $0.id == other.id })?.state, .recoveryPending)
        try document.validate()
    }

    // MARK: - Scheduled fencing

    func testReleasedScheduledOccurrenceStillFencesAndSuppressesLateCallback() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 22))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 7))!
        let scheduled = session(id: UUID(), origin: .scheduled, start: start, duration: end.timeIntervalSince(start))
        var document = RuntimeStoreDocument()
        document.sessions = [scheduled]

        let now = start.addingTimeInterval(60)
        let activeSetID = RuntimeActiveSet.id(for: [scheduled.id])
        let friendIntent = intent(sessionID: scheduled.id, activeSetID: activeSetID)
        XCTAssertEqual(
            RuntimeLifecycle.prepareFriendRelease(&document, intent: friendIntent, effectiveSessionIDs: [scheduled.id], at: now, calendar: calendar),
            .recorded
        )

        let outcome = RuntimeLifecycle.applyFriendRelease(&document, useID: friendIntent.useID, at: now.addingTimeInterval(60), calendar: calendar)
        guard case .released = outcome else { return XCTFail("expected a released outcome, got \(outcome)") }

        XCTAssertTrue(RuntimeSessionDecision.isReleased(
            sessions: document.sessions,
            releasedOccurrences: document.releasedOccurrences,
            origin: .scheduled,
            start: scheduled.start,
            end: scheduled.end
        ))
        XCTAssertTrue(RuntimeLifecycle.shouldSuppressScheduledOccurrence(document, start: start, end: end, calendar: calendar))
        let nextNight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 22))!
        XCTAssertFalse(RuntimeLifecycle.shouldSuppressScheduledOccurrence(
            document, start: nextNight, end: nextNight.addingTimeInterval(8 * 3_600), calendar: calendar
        ))
        try document.validate()
    }

    // MARK: - Abandon

    func testAbandonClearsOnlyAMatchingPendingIntent() throws {
        let target = session(id: UUID(), start: Date(timeIntervalSinceReferenceDate: 1_000), duration: 3_600)
        var document = RuntimeStoreDocument()
        document.sessions = [target]
        let now = target.start.addingTimeInterval(10)
        let activeSetID = RuntimeActiveSet.id(for: [target.id])
        let friendIntent = intent(sessionID: target.id, activeSetID: activeSetID, useID: "use-1")
        XCTAssertEqual(
            RuntimeLifecycle.prepareFriendRelease(&document, intent: friendIntent, effectiveSessionIDs: [target.id], at: now),
            .recorded
        )

        XCTAssertFalse(RuntimeLifecycle.abandonFriendRelease(&document, useID: "use-mismatched"))
        XCTAssertEqual(document.pendingFriendRelease, friendIntent)

        XCTAssertTrue(RuntimeLifecycle.abandonFriendRelease(&document, useID: "use-1"))
        XCTAssertNil(document.pendingFriendRelease)
        try document.validate()
    }

    // MARK: - Schema-2 decoding fixtures

    func testSchemaTwoDocumentWithoutFriendReleaseFieldsDecodesUnchanged() throws {
        let scheduled = RuntimeSession(
            origin: .scheduled,
            start: Date(timeIntervalSinceReferenceDate: 1_000),
            end: Date(timeIntervalSinceReferenceDate: 2_000),
            sourceRevision: 1,
            policy: policy()
        )
        var released = scheduled
        released.state = .released
        var document = RuntimeStoreDocument()
        document.sessions = [released]
        document.releasedOccurrences = [
            RuntimeReleasedOccurrence(sessionID: scheduled.id, origin: .scheduled, start: scheduled.start, end: scheduled.end, releasedAt: scheduled.end)
        ]

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        object.removeValue(forKey: "pendingFriendRelease")
        if var occurrences = object["releasedOccurrences"] as? [[String: Any]] {
            occurrences = occurrences.map { occurrence in
                var occurrence = occurrence
                occurrence.removeValue(forKey: "cause")
                occurrence.removeValue(forKey: "friendUseID")
                return occurrence
            }
            object["releasedOccurrences"] = occurrences
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RuntimeStoreDocument.self, from: legacyData)

        XCTAssertNil(decoded.pendingFriendRelease)
        XCTAssertNil(decoded.releasedOccurrences.first?.cause)
        XCTAssertNil(decoded.releasedOccurrences.first?.friendUseID)
        XCTAssertEqual(decoded.sessions.first?.id, scheduled.id)
        XCTAssertNoThrow(try decoded.validate())
    }
}
