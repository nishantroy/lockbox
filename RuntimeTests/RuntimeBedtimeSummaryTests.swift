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

    func testBoundaryAndLocale24Hour() {
        XCTAssertNil(RuntimeBedtimeSummary.validationMessage(start: t(23, 45), end: t(0, 0)))
        XCTAssertNotNil(RuntimeBedtimeSummary.validationMessage(start: t(23, 46), end: t(0, 0)))
        XCTAssertEqual(RuntimeBedtimeSummary.minimumWindowMinutes, RuntimeConfiguration.minimumWindowMinutes)
        let gb = Locale(identifier: "en_GB")
        XCTAssertEqual(RuntimeBedtimeSummary.window(start: t(21, 30), end: t(8, 5), calendar: calendar, locale: gb), "21:30 – 8:05")
    }

    private func date(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    func testInProgressEnd() {
        XCTAssertEqual(RuntimeBedtimeSummary.inProgressEnd(start: t(22), end: t(7), at: date(7, 23), calendar: calendar), date(8, 7))
        XCTAssertEqual(RuntimeBedtimeSummary.inProgressEnd(start: t(22), end: t(7), at: date(7, 3), calendar: calendar), date(7, 7))
        XCTAssertNil(RuntimeBedtimeSummary.inProgressEnd(start: t(22), end: t(7), at: date(7, 12), calendar: calendar))
        XCTAssertNil(RuntimeBedtimeSummary.inProgressEnd(start: t(22), end: t(7), at: date(7, 7), calendar: calendar))
        XCTAssertEqual(RuntimeBedtimeSummary.inProgressEnd(start: t(13), end: t(15), at: date(7, 14), calendar: calendar), date(7, 15))
    }

    func testSuppressedOccurrenceIsNotInProgress() {
        let now = date(7, 23)
        let released = RuntimeBedtimeSummary.inProgressOccurrence(start: t(22), end: t(7), at: now, calendar: calendar) { _ in true }
        XCTAssertNil(released)
        let live = RuntimeBedtimeSummary.inProgressOccurrence(start: t(22), end: t(7), at: now, calendar: calendar) { _ in false }
        XCTAssertEqual(live?.end, date(8, 7))
        // Predicate sees the actual occurrence, as a suppressed-key lookup would.
        let key = RuntimeSessionDecision.occurrenceKey(origin: .scheduled, start: date(7, 22), end: date(8, 7))
        var document = RuntimeStoreDocument()
        document.suppressedOccurrenceKeys.insert(key)
        let viaDocument = RuntimeBedtimeSummary.inProgressOccurrence(start: t(22), end: t(7), at: now, calendar: calendar) {
            RuntimeLifecycle.shouldSuppressScheduledOccurrence(document, start: $0.start, end: $0.end, calendar: calendar)
        }
        XCTAssertNil(viaDocument)
    }

    func testEditBlocksAndChanges() {
        XCTAssertEqual(RuntimeBedtimeEditBlock.evaluate(isOn: true, wasOn: false, locked: true, savedWindowInProgress: false), .turnOnAfterLock)
        XCTAssertEqual(RuntimeBedtimeEditBlock.evaluate(isOn: false, wasOn: true, locked: false, savedWindowInProgress: true), .turnOffDuringWindow)
        XCTAssertNil(RuntimeBedtimeEditBlock.evaluate(isOn: false, wasOn: true, locked: false, savedWindowInProgress: false))
        XCTAssertNil(RuntimeBedtimeEditBlock.evaluate(isOn: true, wasOn: true, locked: true, savedWindowInProgress: true))
        XCTAssertFalse(RuntimeBedtimeEditBlock.hasChanges(isOn: false, wasOn: false, start: t(1), end: t(2), savedStart: t(3), savedEnd: t(4)))
        XCTAssertTrue(RuntimeBedtimeEditBlock.hasChanges(isOn: true, wasOn: true, start: t(1), end: t(2), savedStart: t(3), savedEnd: t(4)))
        XCTAssertTrue(RuntimeBedtimeEditBlock.hasChanges(isOn: true, wasOn: false, start: t(3), end: t(4), savedStart: t(3), savedEnd: t(4)))
    }

    func testOutcomeAndEffectiveConfiguration() {
        XCTAssertTrue(RuntimeSaveOutcome.saved.closesEditor)
        XCTAssertTrue(RuntimeSaveOutcome.queued.closesEditor)
        XCTAssertFalse(RuntimeSaveOutcome.failed.closesEditor)

        func config(_ revision: Int, _ h: Int) -> RuntimeConfiguration {
            RuntimeConfiguration(revision: revision, start: t(h), end: t(7), mode: .blockSelected, selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0), selectionData: Data([1]))
        }
        var document = RuntimeStoreDocument()
        XCTAssertNil(document.effectiveConfiguration)
        document.configuration = config(1, 22)
        XCTAssertEqual(document.effectiveConfiguration?.revision, 1)
        document.pendingConfiguration = config(2, 23)
        XCTAssertEqual(document.effectiveConfiguration?.revision, 2)
    }
}
