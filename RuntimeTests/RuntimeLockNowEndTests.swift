import XCTest
@testable import PhoneLockboxRuntime

final class RuntimeLockNowEndTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_US")
    private let bedtime = (start: RuntimeTime(hour: 22, minute: 0), end: RuntimeTime(hour: 7, minute: 0))

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
    }

    // MARK: displayedEnd

    func testPresetEndIsNowPlusDuration() {
        let now = date(6, 20, 0)
        XCTAssertEqual(RuntimeLockNowEnd.displayedEnd(preset: .thirtyMinutes, customEnd: nil, now: now), date(6, 20, 30))
        XCTAssertEqual(RuntimeLockNowEnd.displayedEnd(preset: .oneHour, customEnd: nil, now: now), date(6, 21, 0))
    }

    func testPresetCrossesMidnight() {
        let now = date(6, 23, 50)
        XCTAssertEqual(RuntimeLockNowEnd.displayedEnd(preset: .thirtyMinutes, customEnd: nil, now: now), date(7, 0, 20))
    }

    func testCustomEndMustSurviveTheStaleMargin() {
        let now = date(6, 20, 0)
        // 16 minutes out is still 15 minutes a minute from now.
        XCTAssertEqual(RuntimeLockNowEnd.displayedEnd(preset: nil, customEnd: date(6, 20, 16), now: now), date(6, 20, 16))
        // 15 minutes out would be rejected one minute later.
        XCTAssertNil(RuntimeLockNowEnd.displayedEnd(preset: nil, customEnd: date(6, 20, 15), now: now))
        // As the minute ticks, a previously valid custom end goes stale.
        XCTAssertNil(RuntimeLockNowEnd.displayedEnd(preset: nil, customEnd: date(6, 20, 16), now: date(6, 20, 1)))
    }

    func testCustomEndUpperBoundAndMissingEnd() {
        let now = date(6, 20, 0)
        let max = now.addingTimeInterval(7 * 24 * 3600 + 60)
        XCTAssertNotNil(RuntimeLockNowEnd.displayedEnd(preset: nil, customEnd: max, now: now))
        XCTAssertNil(RuntimeLockNowEnd.displayedEnd(preset: nil, customEnd: max.addingTimeInterval(1), now: now))
        XCTAssertNil(RuntimeLockNowEnd.displayedEnd(preset: nil, customEnd: nil, now: now))
    }

    func testPickerReferenceIsOneMinuteLater() {
        let now = date(6, 20, 0)
        XCTAssertEqual(RuntimeLockNowEnd.pickerReference(at: now), date(6, 20, 1))
        let lower = RuntimeManualLockDecision.customEndRange(at: RuntimeLockNowEnd.pickerReference(at: now), calendar: calendar)?.lowerBound
        XCTAssertEqual(lower, date(6, 20, 16))
        XCTAssertNotNil(RuntimeLockNowEnd.displayedEnd(preset: nil, customEnd: lower, now: now))
    }

    // MARK: bedtime overlap

    func testOverlapWhenLockRunsIntoBedtime() {
        let now = date(6, 21, 30)
        let overlap = RuntimeLockNowEnd.bedtimeOverlap(
            schedule: bedtime, enabled: true, lockEnd: date(6, 22, 30), now: now, calendar: calendar
        )
        XCTAssertEqual(overlap, .init(bedtimeStart: date(6, 22, 0), effectiveEnd: date(7, 7, 0)))
    }

    func testNoOverlapWhenLockEndsBeforeBedtime() {
        XCTAssertNil(RuntimeLockNowEnd.bedtimeOverlap(
            schedule: bedtime, enabled: true, lockEnd: date(6, 21, 59), now: date(6, 21, 0), calendar: calendar
        ))
    }

    func testLockEndingExactlyAtBedtimeStartDoesNotOverlap() {
        XCTAssertNil(RuntimeLockNowEnd.bedtimeOverlap(
            schedule: bedtime, enabled: true, lockEnd: date(6, 22, 0), now: date(6, 21, 0), calendar: calendar
        ))
    }

    func testNoOverlapWhenBedtimeIsOffOrMissing() {
        XCTAssertNil(RuntimeLockNowEnd.bedtimeOverlap(
            schedule: bedtime, enabled: false, lockEnd: date(6, 23, 0), now: date(6, 21, 30), calendar: calendar
        ))
        XCTAssertNil(RuntimeLockNowEnd.bedtimeOverlap(
            schedule: nil, enabled: true, lockEnd: date(6, 23, 0), now: date(6, 21, 30), calendar: calendar
        ))
    }

    func testNoOverlapWhenLockEndsAfterBedtimeEnds() {
        // A multi-day lock that already outlasts bedtime is not extended by it.
        XCTAssertNil(RuntimeLockNowEnd.bedtimeOverlap(
            schedule: bedtime, enabled: true, lockEnd: date(8, 12, 0), now: date(6, 23, 0), calendar: calendar
        ))
    }

    func testNoOverlapNoteForBedtimeAlreadyInProgress() {
        // Bedtime started before now: nothing "starts" during the lock.
        XCTAssertNil(RuntimeLockNowEnd.bedtimeOverlap(
            schedule: bedtime, enabled: true, lockEnd: date(7, 0, 30), now: date(6, 23, 30), calendar: calendar
        ))
    }

    // MARK: chip text

    func testChipTimeIsTimeOnlyWithinADay() {
        let now = date(6, 23, 0)
        XCTAssertTrue(RuntimeLockNowEnd.chipTime(date(7, 0, 15), now: now, calendar: calendar, locale: locale).hasPrefix("12:15"))
        XCTAssertTrue(RuntimeLockNowEnd.chipTime(date(7, 23, 0), now: now, calendar: calendar, locale: locale).hasPrefix("11:00"))
    }

    func testChipTimeAddsWeekdayBeyondADay() {
        let now = date(6, 23, 0)
        XCTAssertTrue(RuntimeLockNowEnd.chipTime(date(8, 7, 0), now: now, calendar: calendar, locale: locale).hasPrefix("Sun 7:00"))
    }
}
