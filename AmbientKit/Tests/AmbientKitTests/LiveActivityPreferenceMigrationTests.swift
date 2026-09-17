import Foundation
import XCTest
@testable import AmbientKit

final class LiveActivityPreferenceMigrationTests: XCTestCase {
    func testLegacyBuild13OptInWithoutEncodedRecordMigratesOff() {
        let resolution = AmbientLiveActivityPreferenceMigration.resolve(
            encodedRecord: nil,
            legacyVersion: nil,
            legacyEnabled: true
        )

        XCTAssertEqual(resolution.preference, AmbientLiveActivityPreference(enabled: false))
        XCTAssertTrue(resolution.shouldPersist)
    }

    func testInterruptedLegacySplitIntermediateMigratesOff() {
        let resolution = AmbientLiveActivityPreferenceMigration.resolve(
            encodedRecord: nil,
            legacyVersion: AmbientLiveActivityPreference.currentVersion,
            legacyEnabled: true
        )

        XCTAssertEqual(resolution.preference, AmbientLiveActivityPreference(enabled: false))
        XCTAssertTrue(resolution.shouldPersist)
    }

    func testFreshMissingRecordMigratesOff() {
        let resolution = AmbientLiveActivityPreferenceMigration.resolve(encodedRecord: nil)

        XCTAssertEqual(resolution.preference, AmbientLiveActivityPreference(enabled: false))
        XCTAssertTrue(resolution.shouldPersist)
    }

    func testCurrentEncodedOnRecordPreservesExplicitChoice() throws {
        let data = try AmbientLiveActivityPreference(enabled: true).encoded()

        let resolution = AmbientLiveActivityPreferenceMigration.resolve(encodedRecord: data)

        XCTAssertEqual(resolution.preference, AmbientLiveActivityPreference(enabled: true))
        XCTAssertFalse(resolution.shouldPersist)
    }

    func testCurrentEncodedOffRecordPreservesExplicitChoice() throws {
        let data = try AmbientLiveActivityPreference(enabled: false).encoded()

        let resolution = AmbientLiveActivityPreferenceMigration.resolve(encodedRecord: data)

        XCTAssertEqual(resolution.preference, AmbientLiveActivityPreference(enabled: false))
        XCTAssertFalse(resolution.shouldPersist)
    }

    func testMalformedEncodedRecordFailsSafeAndRequestsReplacement() {
        let resolution = AmbientLiveActivityPreferenceMigration.resolve(
            encodedRecord: Data("not-json".utf8),
            legacyVersion: AmbientLiveActivityPreference.currentVersion,
            legacyEnabled: true
        )

        XCTAssertEqual(resolution.preference, AmbientLiveActivityPreference(enabled: false))
        XCTAssertTrue(resolution.shouldPersist)
    }

    func testUnknownEncodedVersionFailsSafeAndRequestsReplacement() {
        let data = Data("{\"version\":999,\"enabled\":true}".utf8)

        let resolution = AmbientLiveActivityPreferenceMigration.resolve(encodedRecord: data)

        XCTAssertEqual(resolution.preference, AmbientLiveActivityPreference(enabled: false))
        XCTAssertTrue(resolution.shouldPersist)
    }

    func testEncodedRecordRoundTripsAsOneCompleteValue() throws {
        let data = try AmbientLiveActivityPreference(enabled: true).encoded()

        XCTAssertEqual(
            AmbientLiveActivityPreference.decodeCurrent(data),
            AmbientLiveActivityPreference(enabled: true)
        )
    }

    func testSafeRecordWrittenAfterMigrationIsStableAcrossRelaunch() throws {
        let migrated = AmbientLiveActivityPreferenceMigration.resolve(
            encodedRecord: nil,
            legacyVersion: nil,
            legacyEnabled: true
        )
        let persisted = try migrated.preference.encoded()

        let relaunched = AmbientLiveActivityPreferenceMigration.resolve(encodedRecord: persisted)

        XCTAssertEqual(relaunched.preference, AmbientLiveActivityPreference(enabled: false))
        XCTAssertFalse(relaunched.shouldPersist)
    }

    func testExplicitChoiceEncodedAfterMigrationCanBeReadOnRelaunch() throws {
        let explicitChoice = try AmbientLiveActivityPreference(enabled: true).encoded()

        let relaunched = AmbientLiveActivityPreferenceMigration.resolve(encodedRecord: explicitChoice)

        XCTAssertEqual(relaunched.preference, AmbientLiveActivityPreference(enabled: true))
        XCTAssertFalse(relaunched.shouldPersist)
    }

    func testLegacyCompatibilityEntryPointNeverDefaultsOn() {
        XCTAssertEqual(
            AmbientLiveActivityPreferenceMigration.migrate(storedVersion: AmbientLiveActivityPreference.currentVersion, storedEnabled: true),
            AmbientLiveActivityPreference(enabled: false)
        )
        XCTAssertEqual(
            AmbientLiveActivityPreferenceMigration.migrate(storedVersion: nil, storedEnabled: true),
            AmbientLiveActivityPreference(enabled: false)
        )
    }
}
