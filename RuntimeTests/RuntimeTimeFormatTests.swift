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
}
