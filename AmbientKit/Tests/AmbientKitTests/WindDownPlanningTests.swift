import XCTest
@testable import AmbientKit

final class WindDownPlanningTests: XCTestCase {
    private func configuration(
        enabled: Bool = true,
        hour: Int = 22,
        minute: Int = 0,
        leadMinutes: Int = 30
    ) throws -> WindDownConfiguration {
        WindDownConfiguration(
            enabled: enabled,
            bedtime: try AmbientLocalTime(hour: hour, minute: minute),
            lead: try WindDownLeadOffset(minutes: leadMinutes)
        )
    }

    private func calendar(_ identifier: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    func testDisabledConfigurationPlansNothing() throws {
        let config = try configuration(enabled: false)
        let now = ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z")!
        XCTAssertTrue(try WindDownPlanner.plan(configuration: config, now: now, calendar: calendar()).isEmpty)
    }

    func testOnlyUpcomingTriggersArePlannedAndIDsAreStable() throws {
        let config = try configuration()
        let now = ISO8601DateFormatter().date(from: "2026-01-01T21:45:00Z")!
        let planned = try WindDownPlanner.plan(configuration: config, now: now, calendar: calendar(), limit: 7)

        XCTAssertEqual(planned.count, 7)
        XCTAssertEqual(planned[0].triggerDate, ISO8601DateFormatter().date(from: "2026-01-02T21:30:00Z"))
        XCTAssertTrue(planned.allSatisfy { $0.triggerDate > now })
        XCTAssertEqual(planned.map(\.identifier).count, Set(planned.map(\.identifier)).count)
        XCTAssertEqual(
            planned[0].identifier,
            "com.phone-lockbox.ambient.wind-down.2026-01-02-22-00"
        )

        let again = try WindDownPlanner.plan(configuration: config, now: now, calendar: calendar(), limit: 7)
        XCTAssertEqual(planned, again)
    }

    func testCrossMidnightActiveSessionDoesNotGetDelayedHeadsUp() throws {
        let config = try configuration(hour: 22, minute: 0)
        let now = ISO8601DateFormatter().date(from: "2026-01-02T01:00:00Z")!
        let active = try AmbientSessionBoundary(
            start: ISO8601DateFormatter().date(from: "2026-01-01T22:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-01-02T07:00:00Z")!
        )
        let planned = try WindDownPlanner.plan(
            configuration: config,
            now: now,
            calendar: calendar(),
            activeSession: active,
            limit: 2
        )

        XCTAssertEqual(planned.first?.triggerDate, ISO8601DateFormatter().date(from: "2026-01-02T21:30:00Z"))
        XCTAssertTrue(planned.allSatisfy { $0.triggerDate > now })
    }

    func testLeadOffsetValidation() throws {
        XCTAssertThrowsError(try WindDownLeadOffset(seconds: 0))
        XCTAssertThrowsError(try WindDownLeadOffset(seconds: -1))
        XCTAssertThrowsError(try WindDownLeadOffset(seconds: .infinity))
        XCTAssertThrowsError(try WindDownLeadOffset(seconds: 0.5))
        XCTAssertThrowsError(try WindDownLeadOffset(seconds: 24 * 60 * 60 + 1))
        XCTAssertNoThrow(try WindDownLeadOffset(seconds: 1))
    }

    func testUTCAndDSTCalendarValuesBecomeConcreteTriggerComponents() throws {
        var eastern = calendar("America/New_York")
        let config = try configuration(hour: 2, minute: 30, leadMinutes: 30)
        let springNow = ISO8601DateFormatter().date(from: "2026-03-07T12:00:00Z")!
        let spring = try WindDownPlanner.plan(configuration: config, now: springNow, calendar: eastern, limit: 3)
        XCTAssertEqual(spring[0].triggerComponents.timeZone?.identifier, "America/New_York")
        XCTAssertEqual(spring[0].triggerComponents.hour, 3) // 02:30 normalizes through the skipped hour.
        XCTAssertEqual(spring[0].triggerDate, ISO8601DateFormatter().date(from: "2026-03-08T07:00:00Z"))

        eastern.timeZone = TimeZone(identifier: "UTC")!
        let utc = try WindDownPlanner.plan(configuration: config, now: springNow, calendar: eastern, limit: 1)
        XCTAssertEqual(utc[0].triggerComponents.timeZone?.secondsFromGMT(), 0)
        XCTAssertEqual(utc[0].triggerDate, ISO8601DateFormatter().date(from: "2026-03-08T02:00:00Z"))
    }

    func testReplacementRemovesOnlyOwnNamespaceAndDoesNotDuplicate() throws {
        let config = try configuration()
        let now = ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z")!
        let occurrences = try WindDownPlanner.plan(configuration: config, now: now, calendar: calendar(), limit: 2)
        let replacement = try WindDownNotificationReplacement(
            existingPendingIdentifiers: [
                "other.app.reminder",
                occurrences[0].identifier,
                "com.phone-lockbox.ambient.wind-down.old"
            ],
            occurrences: occurrences
        )

        XCTAssertEqual(
            replacement.removeIdentifiers,
            [occurrences[0].identifier, "com.phone-lockbox.ambient.wind-down.old"].sorted()
        )
        XCTAssertEqual(replacement.addIdentifiers, occurrences.map(\.identifier))
        XCTAssertThrowsError(
            try WindDownNotificationReplacement(existingPendingIdentifiers: [], occurrences: [occurrences[0], occurrences[0]])
        )
    }
}

final class LiveActivityModelTests: XCTestCase {
    func testFixedEndBecomesStaleWithoutClaimingRelease() {
        let end = Date(timeIntervalSince1970: 100)
        let state = AmbientActivityContentState(fixedEnd: end, status: .plannedSession)
        XCTAssertEqual(state.staleIfNeeded(at: Date(timeIntervalSince1970: 100)), .init(fixedEnd: end, status: .stale))
        XCTAssertEqual(
            AmbientActivityContentState(fixedEnd: end, status: .releaseObserved).staleIfNeeded(at: Date(timeIntervalSince1970: 200)).status,
            .releaseObserved
        )
    }

    func testLongSessionIsReportedAsPotentiallyStale() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            AmbientLiveActivityPolicy.lifetime(for: Date(timeIntervalSince1970: 8 * 60 * 60 + 1), now: now),
            .mayBecomeStaleAfterEightHours
        )
    }
}
