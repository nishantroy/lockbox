import Foundation
import XCTest
@testable import PhoneLockboxRuntime

final class RuntimeContractsTests: XCTestCase {
    func testEmptySelectionAndAllowOnlyWithoutAppAreRejected() throws {
        XCTAssertThrowsError(try RuntimePolicyPlan.make(
            mode: .blockSelected,
            selection: RuntimeSelectionSummary(applicationCount: 0, categoryCount: 0, webDomainCount: 0)
        ))
        XCTAssertThrowsError(try RuntimePolicyPlan.make(
            mode: .allowOnlySelected,
            selection: RuntimeSelectionSummary(applicationCount: 0, categoryCount: 1, webDomainCount: 0)
        ))
    }

    func testUnknownModeCannotBeDecodedAsAValidPolicy() {
        let data = Data(#""futureMode""#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RuntimeMode.self, from: data))
        XCTAssertEqual(try? JSONDecoder().decode(RuntimeMode.self, from: Data(#""blockSelected""#.utf8)), .blockSelected)
    }

    func testOverflowingSelectionCountsAreRejectedWithoutTrapping() {
        let summary = RuntimeSelectionSummary(applicationCount: Int.max, categoryCount: 1, webDomainCount: 0)
        XCTAssertThrowsError(try summary.validate(for: .allowOnlySelected))
        XCTAssertEqual(summary.totalCount, Int.max)
    }

    func testCivilPreflightUsesTheDocumentedFifteenMinuteMinimum() {
        let short = RuntimeConfiguration(
            revision: 1,
            start: RuntimeTime(hour: 22, minute: 0),
            end: RuntimeTime(hour: 22, minute: 14),
            mode: .blockSelected,
            selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            selectionData: Data([1])
        )
        XCTAssertEqual(short.civilDurationMinutes, 14)
        XCTAssertThrowsError(try short.validate()) { XCTAssertEqual($0 as? RuntimeValidationError, .intervalTooShort) }
    }

    func testMonitorDecisionRejectsLateStartAndEarlyOrStaleEnd() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let configuration = RuntimeConfiguration(
            revision: 1,
            start: RuntimeTime(hour: 22, minute: 0),
            end: RuntimeTime(hour: 7, minute: 0),
            mode: .blockSelected,
            selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            selectionData: Data([1])
        )
        let evening = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 23))!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 1, day: 3, hour: 6, minute: 59))!
        let ended = calendar.date(from: DateComponents(year: 2026, month: 1, day: 3, hour: 7))!
        XCTAssertTrue(RuntimeScheduleDecision.accepts(.start, configuration: configuration, at: evening, calendar: calendar))
        XCTAssertFalse(RuntimeScheduleDecision.accepts(.start, configuration: configuration, at: ended, calendar: calendar))
        XCTAssertFalse(RuntimeScheduleDecision.accepts(.end, configuration: configuration, at: morning, calendar: calendar))
        XCTAssertTrue(RuntimeScheduleDecision.accepts(.end, configuration: configuration, at: ended, calendar: calendar))
        // A stale end must not be allowed to clear tonight's live occurrence.
        XCTAssertFalse(RuntimeScheduleDecision.accepts(.end, configuration: configuration, at: evening, calendar: calendar))
    }

    func testIntentCommitSurvivesFailureAfterSideEffectBoundary() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedRuntimeStore(directoryURL: directory)
        XCTAssertThrowsError(try store.withTransaction { context in
            context.document.activeOwner = .prototypeTest
            context.document.testLockActive = true
            context.document.policyIntent = .apply
            try context.commit()
            throw RuntimeValidationError.invalidConfiguration("simulated side-effect failure")
        })
        let durable = try store.read()
        XCTAssertEqual(durable.activeOwner, .prototypeTest)
        XCTAssertEqual(durable.policyIntent, .apply)
    }

    #if canImport(Darwin) || canImport(Glibc)
    func testLockAcquisitionIsBoundedWhenAnotherWriterHoldsTheLock() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedRuntimeStore(directoryURL: directory, lockTimeout: 0.02)
        let descriptor = open(directory.appendingPathComponent("runtime-state.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let started = Date()
        XCTAssertThrowsError(try store.read()) { XCTAssertEqual($0 as? RuntimeValidationError, .concurrentStoreAccess) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }
    #endif

    func testBlockAndAllowPlansAreExplicit() throws {
        let selected = RuntimeSelectionSummary(applicationCount: 2, categoryCount: 1, webDomainCount: 1)
        let block = try RuntimePolicyPlan.make(mode: .blockSelected, selection: selected)
        XCTAssertTrue(block.blocksSelectedApplications)
        XCTAssertTrue(block.blocksSelectedCategories)
        XCTAssertFalse(block.excludesSelectedApplicationsFromBroadShield)

        let allow = try RuntimePolicyPlan.make(mode: .allowOnlySelected, selection: selected)
        XCTAssertTrue(allow.excludesSelectedApplicationsFromBroadShield)
        XCTAssertTrue(allow.excludesSelectedWebDomainsFromBroadShield)
        XCTAssertFalse(allow.blocksSelectedCategories)
    }

    func testRecoveryDocumentRequiresBidirectionalSessionRelationships() throws {
        let id = UUID()
        let policy = RuntimePolicySnapshot(
            mode: .blockSelected,
            selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            selectionData: Data([1])
        )
        let pending = RuntimeSession(id: id, origin: .scheduled, start: Date(timeIntervalSinceReferenceDate: 1_000), end: Date(timeIntervalSinceReferenceDate: 2_000), sourceRevision: 1, policy: policy, state: .recoveryPending)
        var valid = RuntimeStoreDocument()
        valid.sessions = [pending]
        valid.recoveryCommitment = try RecoveryCommitment(sessionIDs: [id], requestedAt: Date(timeIntervalSinceReferenceDate: 1_100))
        XCTAssertNoThrow(try JSONDecoder().decode(RuntimeStoreDocument.self, from: JSONEncoder().encode(valid)))

        var orphanTarget = valid
        orphanTarget.recoveryCommitment = try RecoveryCommitment(sessionIDs: [UUID()], requestedAt: Date(timeIntervalSinceReferenceDate: 1_100))
        XCTAssertThrowsError(try JSONDecoder().decode(RuntimeStoreDocument.self, from: JSONEncoder().encode(orphanTarget)))

        var orphanPending = RuntimeStoreDocument()
        orphanPending.sessions = [pending]
        XCTAssertThrowsError(try JSONDecoder().decode(RuntimeStoreDocument.self, from: JSONEncoder().encode(orphanPending)))

        var activeTarget = valid
        activeTarget.sessions[0].state = .active
        XCTAssertThrowsError(try JSONDecoder().decode(RuntimeStoreDocument.self, from: JSONEncoder().encode(activeTarget)))

        var requestOutsideTarget = valid
        requestOutsideTarget.recoveryCommitment = try RecoveryCommitment(sessionIDs: [id], requestedAt: Date(timeIntervalSinceReferenceDate: 2_100))
        XCTAssertThrowsError(try JSONDecoder().decode(RuntimeStoreDocument.self, from: JSONEncoder().encode(requestOutsideTarget)))
    }

    func testExpiredRecoveryTargetCanRemainWhileAnotherTargetIsPending() throws {
        let first = UUID()
        let second = UUID()
        let policy = RuntimePolicySnapshot(
            mode: .blockSelected,
            selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            selectionData: Data([1])
        )
        let expired = RuntimeSession(id: first, origin: .scheduled, start: Date(timeIntervalSinceReferenceDate: 1_000), end: Date(timeIntervalSinceReferenceDate: 1_100), sourceRevision: 1, policy: policy, state: .expired)
        let pending = RuntimeSession(id: second, origin: .scheduled, start: Date(timeIntervalSinceReferenceDate: 1_000), end: Date(timeIntervalSinceReferenceDate: 2_000), sourceRevision: 1, policy: policy, state: .recoveryPending)
        var document = RuntimeStoreDocument()
        document.sessions = [expired, pending]
        document.recoveryCommitment = try RecoveryCommitment(sessionIDs: [first, second], requestedAt: Date(timeIntervalSinceReferenceDate: 1_050))
        XCTAssertNoThrow(try JSONDecoder().decode(RuntimeStoreDocument.self, from: JSONEncoder().encode(document)))
    }

    func testCorruptDocumentIsRejectedWithoutResettingIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedRuntimeStore(directoryURL: directory)
        let invalid = Data(#"{"schemaVersion":99,"recurringEnabledIntent":false,"testLockActive":false,"operationStatus":{},"diagnostics":[]}"#.utf8)
        try invalid.write(to: directory.appendingPathComponent("runtime-state.json"))

        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? RuntimeValidationError, .corruptSharedData)
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("runtime-state.json")), invalid)
    }

    func testDisabledIntentAndBoundedDiagnosticsArePersistedAtomically() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedRuntimeStore(directoryURL: directory)

        try store.transaction { document in
            document.recurringEnabledIntent = false
            for _ in 0..<40 {
                document.record(RuntimeDiagnostic(operation: .callbackReceived, detail: "test"), succeeded: false)
            }
        }

        let saved = try store.read()
        XCTAssertFalse(saved.recurringEnabledIntent)
        XCTAssertEqual(saved.diagnostics.count, RuntimeStoreDocument.maximumDiagnostics)
    }

    func testConcurrentTransactionsDoNotLoseIntentUpdates() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedRuntimeStore(directoryURL: directory)
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                try? store.transaction { document in
                    document.record(RuntimeDiagnostic(operation: .registrationAttempted, detail: "concurrent"), succeeded: nil)
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(try store.read().diagnostics.count, 8)
    }

    func testRegistrationFailureDoesNotLeaveEnabledIntentAndConflictIsInvalid() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedRuntimeStore(directoryURL: directory)
        try store.transaction { document in
            document.recurringEnabledIntent = false
            document.record(RuntimeDiagnostic(operation: .registrationFailed, detail: "interval rejected"), succeeded: false)
        }
        XCTAssertFalse(try store.read().recurringEnabledIntent)
        XCTAssertEqual(try store.read().operationStatus.operation, .registrationFailed)

        XCTAssertThrowsError(try store.transaction { document in
            document.activeOwner = .prototypeTest
            document.testLockActive = true
            document.recurringEnabledIntent = true
        })
    }

    func testRelaunchReadsARegisteredConfigurationAndItsRequestedWindow() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedRuntimeStore(directoryURL: directory)
        let configuration = RuntimeConfiguration(
            revision: 4,
            start: RuntimeTime(hour: 22, minute: 0),
            end: RuntimeTime(hour: 7, minute: 0),
            mode: .blockSelected,
            selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            selectionData: Data([1])
        )
        try store.transaction { document in
            document.configuration = configuration
            document.recurringEnabledIntent = true
        }
        let relaunched = try SharedRuntimeStore(directoryURL: directory).read()
        XCTAssertEqual(relaunched.configuration?.revision, 4)
        XCTAssertEqual(relaunched.configuration?.start, RuntimeTime(hour: 22, minute: 0))
        XCTAssertTrue(relaunched.recurringEnabledIntent)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-lockbox-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
