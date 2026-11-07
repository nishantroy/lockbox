import XCTest
@testable import PhoneLockboxRuntime

final class RuntimeBedtimeSummaryTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_US")

    private func t(_ h: Int, _ m: Int = 0) -> RuntimeTime { RuntimeTime(hour: h, minute: m) }

    func testSummaryCrossingMidnight() {
        let text = RuntimeBedtimeSummary.summary(start: t(21, 30), end: t(8, 5), calendar: calendar, locale: locale)
        XCTAssertTrue(text.hasPrefix("Every day · locks 9:30"))
        XCTAssertTrue(text.contains("PM, opens 8:05"))
        XCTAssertTrue(text.hasSuffix("AM"))
        XCTAssertTrue(RuntimeBedtimeSummary.crossesMidnight(start: t(21, 30), end: t(8, 5)))
        XCTAssertEqual(RuntimeBedtimeSummary.durationMinutes(start: t(21, 30), end: t(8, 5)), 635)
    }

    func testSummarySameDayWindow() {
        let text = RuntimeBedtimeSummary.summary(start: t(13), end: t(15), calendar: calendar, locale: locale)
        XCTAssertTrue(text.hasPrefix("Every day · locks 1:00"))
        XCTAssertTrue(text.contains("PM, opens 3:00"))
        XCTAssertFalse(RuntimeBedtimeSummary.crossesMidnight(start: t(13), end: t(15)))
        XCTAssertEqual(RuntimeBedtimeSummary.durationMinutes(start: t(13), end: t(15)), 120)
    }

    func testWindowUsesEnDash() {
        let text = RuntimeBedtimeSummary.window(start: t(21, 30), end: t(8, 5), calendar: calendar, locale: locale)
        XCTAssertTrue(text.contains(" – "))
        XCTAssertTrue(text.hasPrefix("9:30"))
    }

    func testValidation() {
        XCTAssertNil(RuntimeBedtimeSummary.validationMessage(start: t(22), end: t(7)))
        XCTAssertNil(RuntimeBedtimeSummary.validationMessage(start: t(10), end: t(10, 15)))
        XCTAssertNotNil(RuntimeBedtimeSummary.validationMessage(start: t(10), end: t(10, 14)))
        XCTAssertNotNil(RuntimeBedtimeSummary.validationMessage(start: t(23, 55), end: t(0, 5)))
        XCTAssertNil(RuntimeBedtimeSummary.validationMessage(start: t(23, 50), end: t(0, 5)))
        XCTAssertEqual(RuntimeBedtimeSummary.validationMessage(start: t(9), end: t(9)), "Choose different start and end times.")
        XCTAssertEqual(RuntimeBedtimeSummary.durationMinutes(start: t(23, 55), end: t(0, 5)), 10)
    }
}
