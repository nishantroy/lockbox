import Foundation
import XCTest
@testable import PhoneLockboxRuntime

final class ReconciliationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func document() -> RuntimeStoreDocument {
        var state = RuntimeStoreDocument()
        state.configuration = RuntimeConfiguration(revision: 1, start: RuntimeTime(hour: 22, minute: 0), end: RuntimeTime(hour: 7, minute: 0), mode: .blockSelected, selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0), selectionData: Data([1]))
        state.recurringEnabledIntent = true
        state.activeOwner = .scheduled
        return state
    }

    private func date(_ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: hour))!
    }

    func testOldOSWindowDoesNotMatchReplacementSavedWindow() {
        let configuration = document().configuration!
        XCTAssertFalse(RuntimeScheduleDecision.registrationMatches(configuration: configuration, start: DateComponents(hour: 23, minute: 0), end: DateComponents(hour: 6, minute: 0), repeats: true))
        XCTAssertTrue(RuntimeScheduleDecision.registrationMatches(configuration: configuration, start: DateComponents(hour: 22, minute: 0), end: DateComponents(hour: 7, minute: 0), repeats: true))
        XCTAssertFalse(RuntimeScheduleDecision.registrationMatches(configuration: configuration, start: DateComponents(hour: 22, minute: 0), end: DateComponents(hour: 7, minute: 0), repeats: false))
    }

    func testInterruptedClearReplaysWithoutAuthorization() {
        var state = document()
        state.policyIntent = .clear
        XCTAssertEqual(RuntimeReconciliation.action(document: state, at: date(23), authorized: false, registrationMatches: false, calendar: calendar), .clearOwned)
    }

    func testInterruptedApplyRequiresValidCurrentWindowAndAuthorization() {
        var state = document()
        state.policyIntent = .apply
        // An apply intent without a committed current session is unsafe to
        // replay from configuration alone; the shared callback decision clears
        // it rather than creating an unbounded shield.
        XCTAssertEqual(RuntimeReconciliation.action(document: state, at: date(23), authorized: true, registrationMatches: true, calendar: calendar), .clearOwned)
        XCTAssertEqual(RuntimeReconciliation.action(document: state, at: date(23), authorized: false, registrationMatches: true, calendar: calendar), .clearOwned)
        XCTAssertEqual(RuntimeReconciliation.action(document: state, at: date(12), authorized: true, registrationMatches: true, calendar: calendar), .clearOwned)
        XCTAssertEqual(RuntimeReconciliation.action(document: state, at: date(23), authorized: true, registrationMatches: false, calendar: calendar), .clearOwned)
    }

    func testForegroundAfterMissedEndIsExplicitCleanupFallback() {
        XCTAssertEqual(RuntimeReconciliation.action(document: document(), at: date(12), authorized: true, registrationMatches: true, calendar: calendar), .clearOwned)
        XCTAssertEqual(RuntimeReconciliation.action(document: document(), at: date(23), authorized: true, registrationMatches: true, calendar: calendar), .none)
    }

    func testPrototypeAndLegacyOwnershipAreNotMistakenForScheduledExpiry() {
        var state = RuntimeStoreDocument()
        state.activeOwner = .prototypeTest
        state.testLockActive = true
        state.policyIntent = .apply
        XCTAssertEqual(RuntimeReconciliation.action(document: state, at: date(12), authorized: true, registrationMatches: false, calendar: calendar), .applyPrototype)
        state.legacyRegistrationNeedsReview = true
        XCTAssertEqual(RuntimeReconciliation.action(document: state, at: date(12), authorized: true, registrationMatches: false, calendar: calendar), .none)
    }

    func testDiagnosticOnlyCallbackDocumentDoesNotSuppressLegacyMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedRuntimeStore(directoryURL: directory)
        try store.transaction { state in state.record(RuntimeDiagnostic(operation: .callbackReceived, detail: "Before first main-app launch")) }
        let migrated = try store.loadOrMigrate {
            var state = RuntimeStoreDocument()
            state.activeOwner = .prototypeTest
            state.testLockActive = true
            return state
        }
        XCTAssertTrue(migrated.testLockActive)
        XCTAssertEqual(migrated.legacyMigrationCompleted, true)
        XCTAssertEqual(migrated.diagnostics.count, 1)
        _ = try store.loadOrMigrate { XCTFail("Migration must be once only"); return RuntimeStoreDocument() }
        try store.reset()
        let afterReset = try store.loadOrMigrate { XCTFail("Reset must not revive old defaults"); return migrated }
        XCTAssertFalse(afterReset.testLockActive)
    }
}
