import XCTest
@testable import PhoneLockboxRuntime

final class RuntimeTimeFormatTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_US")

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func fmt(_ d: Date, now: Date, _ style: RuntimeTimeFormat.Style) -> String {
        RuntimeTimeFormat.string(d, now: now, calendar: calendar, locale: locale, style: style)
    }

    func testTodayIsTimeOnly() {
        let now = date(6, 20)
        XCTAssertTrue(fmt(date(6, 22), now: now, .standalone).hasPrefix("10:00"))
        XCTAssertTrue(fmt(date(6, 22), now: now, .phrase).hasPrefix("10:00"))
        XCTAssertTrue(fmt(date(6, 22), now: now, .atPhrase).hasPrefix("at 10:00"))
    }

    func testPartsSplitDayFromTime() {
        let now = date(6, 20)
        let today = RuntimeTimeFormat.parts(date(6, 22), now: now, calendar: calendar, locale: locale)
        XCTAssertNil(today.day)
        XCTAssertTrue(today.time.hasPrefix("10:00"))
        let tomorrow = RuntimeTimeFormat.parts(date(7, 7), now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(tomorrow.day, "Tomorrow")
        XCTAssertTrue(tomorrow.time.hasPrefix("7:00"))
        XCTAssertEqual(
            "\(tomorrow.day ?? "") \(tomorrow.time)",
            fmt(date(7, 7), now: now, .standalone)
        )
    }

    func testTomorrowIsNamedWithCorrectCasing() {
        let now = date(6, 20)
        XCTAssertTrue(fmt(date(7, 7), now: now, .standalone).hasPrefix("Tomorrow 7:00"))
        XCTAssertTrue(fmt(date(7, 7), now: now, .phrase).hasPrefix("tomorrow at 7:00"))
        XCTAssertTrue(fmt(date(7, 0, 30), now: now, .atPhrase).hasPrefix("tomorrow at 12:30"))
    }

    func testTwoToFiveDaysAheadUseWeekday() {
        let now = date(6, 20)   // Fri Nov 6
        XCTAssertTrue(fmt(date(8, 7), now: now, .standalone).hasPrefix("Sun 7:00"))
        XCTAssertTrue(fmt(date(11, 7), now: now, .standalone).hasPrefix("Wed 7:00"))
    }

    func testSixOrMoreDaysAheadUseShortDate() {
        let now = date(6, 20)
        XCTAssertTrue(fmt(date(12, 15), now: now, .standalone).hasPrefix("Thu, Nov 12, 3:00"))
        XCTAssertTrue(fmt(date(13, 15), now: now, .phrase).hasPrefix("Fri, Nov 13 at 3:00"))
    }

    func testPastDaysAreNeverBareWeekdays() {
        let now = date(6, 9)
        XCTAssertTrue(fmt(date(5, 23, 55), now: now, .standalone).hasPrefix("Yesterday 11:55"))
        XCTAssertTrue(fmt(date(5, 23, 55), now: now, .phrase).hasPrefix("yesterday at 11:55"))
        XCTAssertTrue(fmt(date(3, 10), now: now, .standalone).hasPrefix("Tue, Nov 3, 10:00"))
    }

    func testSixDayBoundaryOnBothSides() {
        let now = date(6, 20)
        // 5 days ahead: weekday. 6 days ahead: short date.
        XCTAssertTrue(fmt(date(11, 7), now: now, .standalone).hasPrefix("Wed 7:00"))
        XCTAssertTrue(fmt(date(12, 7), now: now, .standalone).hasPrefix("Thu, Nov 12, 7:00"))
    }

    func testDayCountAcrossDaylightSavingChange() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        // US clocks fall back on 2026-11-01; the 25-hour day must still count as one day.
        let now = ny.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 22))!
        let next = ny.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 22))!
        let after = ny.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 7))!
        XCTAssertTrue(RuntimeTimeFormat.string(next, now: now, calendar: ny, locale: locale, style: .standalone).hasPrefix("Tomorrow 10:00"))
        XCTAssertTrue(RuntimeTimeFormat.string(after, now: now, calendar: ny, locale: locale, style: .standalone).hasPrefix("Mon 7:00"))
    }
}

final class RuntimeActiveLockDisplayTests: XCTestCase {
    private func session(_ origin: RuntimeSessionOrigin, purpose: RuntimeSessionPurpose? = nil) -> RuntimeSession {
        RuntimeSession(
            origin: origin,
            start: Date(timeIntervalSinceReferenceDate: 1_000),
            end: Date(timeIntervalSinceReferenceDate: 2_000),
            sourceRevision: 1,
            policy: RuntimePolicySnapshot(
                mode: .blockSelected,
                selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
                selectionData: Data([1])
            ),
            purpose: purpose
        )
    }

    func testNoSessionsHasNoDisplay() {
        XCTAssertNil(RuntimeActiveLockDisplay.display(for: []))
    }

    func testScheduledBedtime() {
        let d = RuntimeActiveLockDisplay.display(for: [session(.scheduled)])
        XCTAssertEqual(d, .scheduledBedtime)
        XCTAssertEqual(d?.label, "Bedtime")
        XCTAssertEqual(d?.originCopy, "Bedtime")
        XCTAssertEqual(d?.isBedtime, true)
    }

    func testManualBedtime() {
        let d = RuntimeActiveLockDisplay.display(for: [session(.manual, purpose: .bedtime)])
        XCTAssertEqual(d, .manualBedtime)
        XCTAssertEqual(d?.originCopy, "Bedtime · you started it")
    }

    func testManualFocus() {
        let d = RuntimeActiveLockDisplay.display(for: [session(.manual)])
        XCTAssertEqual(d, .focus)
        XCTAssertEqual(d?.label, "Focus")
        XCTAssertEqual(d?.originCopy, "Focus · you started it")
        XCTAssertEqual(d?.spokenOriginCopy, "Focus, you started it")
        XCTAssertEqual(d?.isBedtime, false)
    }

    func testOverlapIsBedtimeAndFocus() {
        let d = RuntimeActiveLockDisplay.display(for: [session(.scheduled), session(.manual)])
        XCTAssertEqual(d, .bedtimeAndFocus)
        XCTAssertEqual(d?.label, "Bedtime + Focus")
        XCTAssertEqual(d?.originCopy, "Bedtime + Focus")
        XCTAssertEqual(d?.isBedtime, true)
    }

    func testLegacyScheduledSessionWithoutPurposeIsBedtime() throws {
        let legacy = session(.scheduled)
        let data = try JSONEncoder().encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "purpose")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RuntimeSession.self, from: stripped)
        XCTAssertEqual(RuntimeActiveLockDisplay.display(for: [decoded]), .scheduledBedtime)
    }
}
