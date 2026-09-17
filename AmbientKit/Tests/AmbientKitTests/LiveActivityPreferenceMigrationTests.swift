import XCTest
@testable import AmbientKit

final class LiveActivityPreferenceMigrationTests: XCTestCase {
    func testMissingVersionDisablesLegacyEnabledPreference() {
        XCTAssertEqual(
            AmbientLiveActivityPreferenceMigration.migrate(storedVersion: nil, storedEnabled: true),
            AmbientLiveActivityPreference(enabled: false)
        )
    }

    func testCurrentVersionPreservesExplicitChoice() {
        let version = AmbientLiveActivityPreference.currentVersion
        XCTAssertEqual(
            AmbientLiveActivityPreferenceMigration.migrate(storedVersion: version, storedEnabled: true),
            AmbientLiveActivityPreference(enabled: true)
        )
        XCTAssertEqual(
            AmbientLiveActivityPreferenceMigration.migrate(storedVersion: version, storedEnabled: false),
            AmbientLiveActivityPreference(enabled: false)
        )
    }

    func testUnknownOrMissingValueIsOff() {
        XCTAssertEqual(
            AmbientLiveActivityPreferenceMigration.migrate(storedVersion: 0, storedEnabled: false),
            AmbientLiveActivityPreference(enabled: false)
        )
        XCTAssertEqual(
            AmbientLiveActivityPreferenceMigration.migrate(storedVersion: AmbientLiveActivityPreference.currentVersion, storedEnabled: nil),
            AmbientLiveActivityPreference(enabled: false)
        )
    }
}
