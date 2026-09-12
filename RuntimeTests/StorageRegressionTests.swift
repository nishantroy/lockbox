import Foundation
import XCTest
@testable import PhoneLockboxRuntime

final class StorageRegressionTests: XCTestCase {
    func testResetLeavesTombstoneAndDisablesIntentBeforeCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedRuntimeStore(directoryURL: directory)
        try store.transaction { document in
            document.activeOwner = .prototypeTest
            document.testLockActive = true
        }
        var cleanupRan = false
        try store.reset {
            let data = try! Data(contentsOf: directory.appendingPathComponent("runtime-state.json"))
            let saved = try! JSONDecoder().decode(RuntimeStoreDocument.self, from: data)
            XCTAssertFalse(saved.recurringEnabledIntent)
            XCTAssertNil(saved.activeOwner)
            cleanupRan = true
        }
        XCTAssertTrue(cleanupRan)
        XCTAssertTrue(store.hasDocument, "Removing the file would trigger legacy migration again")
        XCTAssertFalse(try store.read().testLockActive)
    }

    func testInterruptedApplyRetainsDurableCleanupOwnership() throws {
        enum Interruption: Error { case simulated }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedRuntimeStore(directoryURL: directory)
        XCTAssertThrowsError(try store.withTransaction { context in
            context.document.activeOwner = .prototypeTest
            context.document.testLockActive = true
            context.document.policyIntent = .apply
            try context.commit()
            throw Interruption.simulated
        })
        let saved = try store.read()
        XCTAssertEqual(saved.activeOwner, .prototypeTest)
        XCTAssertEqual(saved.policyIntent, .apply)
    }

    func testCompetingStoreTimesOutWithoutHangingOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try SharedRuntimeStore(directoryURL: directory)
        let contender = try SharedRuntimeStore(directoryURL: directory, lockTimeout: 0.02)
        try owner.withTransaction { _ in
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try contender.read()) { error in
                XCTAssertEqual(error as? RuntimeValidationError, .concurrentStoreAccess)
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        }
    }

    func testSchemaOneDocumentIsUpgradedWithoutDroppingConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedRuntimeStore(directoryURL: directory)
        var current = RuntimeStoreDocument()
        current.configuration = RuntimeConfiguration(
            revision: 3,
            start: RuntimeTime(hour: 22, minute: 0),
            end: RuntimeTime(hour: 7, minute: 0),
            mode: .blockSelected,
            selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            selectionData: Data([1])
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        object["schemaVersion"] = 1
        object["legacyMigrationCompleted"] = false
        object.removeValue(forKey: "pendingConfiguration")
        object.removeValue(forKey: "sessions")
        object.removeValue(forKey: "releasedOccurrences")
        object.removeValue(forKey: "recoveryCommitment")
        object.removeValue(forKey: "manualRegistrationIntent")
        object.removeValue(forKey: "manualRegistrationActive")
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("runtime-state.json"))

        let migrated = try store.loadOrMigrate { XCTFail("A versioned runtime document must not invoke legacy defaults migration"); return RuntimeStoreDocument() }
        XCTAssertEqual(migrated.schemaVersion, RuntimeStoreDocument.currentSchema)
        XCTAssertEqual(migrated.configuration?.revision, 3)
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("runtime-state.json"))) as? [String: Any]
        XCTAssertEqual(persisted?["schemaVersion"] as? Int, RuntimeStoreDocument.currentSchema)
    }
}
