import Foundation
import XCTest
@testable import PhoneLockboxRuntime

final class ManualLockRuntimeTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func configuration(start: RuntimeTime = RuntimeTime(hour: 22, minute: 0), end: RuntimeTime = RuntimeTime(hour: 7, minute: 0)) -> RuntimeConfiguration {
        RuntimeConfiguration(
            revision: 1,
            start: start,
            end: end,
            mode: .blockSelected,
            selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            selectionData: Data([1])
        )
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute, second: second))!
    }

    private func session(origin: RuntimeSessionOrigin) -> RuntimeSession {
        let policy = RuntimePolicySnapshot(
            mode: .blockSelected,
            selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            selectionData: Data([1])
        )
        return RuntimeSession(origin: origin, start: date(10, 22), end: date(11, 7), sourceRevision: 1, policy: policy)
    }

    func testManualBoundsAcceptThirtyMinutesAndOneHourButRejectOutsideLimits() {
        let start = date(10, 12, 0, 17)
        XCTAssertNil(RuntimeManualLockDecision.proposedEnd(after: 14 * 60, at: start))
        XCTAssertEqual(RuntimeManualLockDecision.proposedEnd(after: 15 * 60, at: start), start.addingTimeInterval(15 * 60))
        XCTAssertEqual(RuntimeManualLockDecision.proposedEnd(after: 30 * 60, at: start), start.addingTimeInterval(30 * 60))
        XCTAssertEqual(RuntimeManualLockDecision.proposedEnd(after: 60 * 60, at: start), start.addingTimeInterval(60 * 60))
        XCTAssertEqual(RuntimeManualLockDecision.proposedEnd(after: 7 * 24 * 60 * 60, at: start), start.addingTimeInterval(7 * 24 * 60 * 60))
        XCTAssertNil(RuntimeManualLockDecision.proposedEnd(after: 7 * 24 * 60 * 60 + 1, at: start))
    }

    func testFrozenEndIsRecheckedAgainstTransactionClockWithoutRecomputingPreview() {
        let previewAt = date(10, 12, 0, 0)
        let actualStart = previewAt.addingTimeInterval(2)
        let frozenThirtyMinuteEnd = RuntimeManualLockDecision.proposedEnd(after: 30 * 60, at: previewAt)!

        XCTAssertTrue(RuntimeManualLockDecision.accepts(expectedEnd: frozenThirtyMinuteEnd, startedAt: actualStart))
        XCTAssertEqual(frozenThirtyMinuteEnd, previewAt.addingTimeInterval(30 * 60))
        XCTAssertFalse(RuntimeManualLockDecision.accepts(
            expectedEnd: previewAt.addingTimeInterval(15 * 60),
            startedAt: actualStart
        ))
        XCTAssertFalse(RuntimeManualLockDecision.accepts(
            expectedEnd: previewAt.addingTimeInterval(7 * 24 * 60 * 60 + 1),
            startedAt: previewAt
        ))
    }

    func testCustomSelectionInitializesOnceAndPreservesUserEndAcrossPresetRoundTrip() throws {
        let openedAt = date(10, 12, 0, 17)
        let initiallyEmpty = RuntimeCustomEndSelectionState()
        let initialized = RuntimeCustomEndSelectionState.transition(
            initiallyEmpty,
            event: .enteredCustom,
            at: openedAt,
            calendar: utc
        )
        let defaultEnd = try XCTUnwrap(initialized.customEnd)
        XCTAssertFalse(initialized.hasUserSelection)

        let userEnd = date(11, 18, 42)
        let userSelected = RuntimeCustomEndSelectionState.transition(
            initialized,
            event: .userSelected(userEnd),
            at: openedAt,
            calendar: utc
        )
        XCTAssertEqual(userSelected.customEnd, userEnd)
        XCTAssertTrue(userSelected.hasUserSelection)

        let afterPreset = RuntimeCustomEndSelectionState.transition(
            userSelected,
            event: .selectedPreset,
            at: openedAt.addingTimeInterval(30 * 60),
            calendar: utc
        )
        // Re-entering Custom therefore returns the exact absolute date the
        // user chose, rather than rebasing it from the current clock.
        let reenteredCustom = RuntimeCustomEndSelectionState.transition(
            afterPreset,
            event: .enteredCustom,
            at: openedAt.addingTimeInterval(60 * 60),
            calendar: utc
        )
        XCTAssertEqual(reenteredCustom.customEnd, userEnd)
        XCTAssertNotEqual(reenteredCustom.customEnd, defaultEnd)
    }

    func testCustomEndAvailabilityKeepsStaleEndActionableWithoutReplacingIt() {
        let reference = date(10, 12, 0)
        let tooSoon = date(10, 12, 14)
        let tooLate = date(18, 12)
        let valid = date(10, 12, 30)

        XCTAssertEqual(RuntimeCustomEndAvailability.evaluate(tooSoon, at: reference, calendar: utc), .tooSoon)
        XCTAssertEqual(RuntimeCustomEndAvailability.evaluate(tooLate, at: reference, calendar: utc), .tooLate)
        XCTAssertEqual(RuntimeCustomEndAvailability.evaluate(valid, at: reference, calendar: utc), .available)
        XCTAssertEqual(RuntimeCustomEndAvailability.evaluate(nil, at: reference, calendar: utc), .unavailable)
    }

    func testCustomRangeCeilsLowerAndFloorsUpperForSecondsBearingNow() {
        let start = date(10, 12, 0, 17)
        let range = try! XCTUnwrap(RuntimeManualLockDecision.customEndRange(at: start, calendar: utc))
        XCTAssertEqual(range.lowerBound, date(10, 12, 16))
        XCTAssertEqual(range.upperBound, date(17, 12, 0))
        XCTAssertTrue(range.contains(range.lowerBound))
        XCTAssertTrue(range.contains(range.upperBound))
        XCTAssertFalse(range.contains(date(10, 12, 15)))
        XCTAssertFalse(range.contains(date(17, 12, 1)))
    }

    func testCustomRangeKeepsExactMinuteThresholdsIncluded() {
        let start = date(10, 12, 0, 0)
        let range = try! XCTUnwrap(RuntimeManualLockDecision.customEndRange(at: start, calendar: utc))
        XCTAssertEqual(range.lowerBound, date(10, 12, 15))
        XCTAssertEqual(range.upperBound, date(17, 12, 0))
        XCTAssertEqual(RuntimeManualLockDecision.defaultCustomEnd(at: start, calendar: utc), date(10, 12, 30))
    }

    func testCustomRangeUsesCalendarMinuteBoundariesAcrossDST() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let now = newYork.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 50, second: 30))!
        let range = try XCTUnwrap(RuntimeManualLockDecision.customEndRange(at: now, calendar: newYork))
        let lowerComponents = newYork.dateComponents([.year, .month, .day, .hour, .minute, .second], from: range.lowerBound)
        XCTAssertEqual(lowerComponents.year, 2026)
        XCTAssertEqual(lowerComponents.month, 3)
        XCTAssertEqual(lowerComponents.day, 8)
        XCTAssertEqual(lowerComponents.hour, 3)
        XCTAssertEqual(lowerComponents.minute, 6)
        XCTAssertEqual(lowerComponents.second, 0)
        XCTAssertLessThanOrEqual(range.upperBound, now.addingTimeInterval(RuntimeManualLockDecision.maximumDuration))
    }

    func testDelayedConfirmationReturnsPreciseReasonWithoutWeakeningRuntimeAcceptance() {
        let preview = date(10, 12, 0, 0)
        let frozenEnd = date(10, 12, 15)
        XCTAssertEqual(
            RuntimeManualLockDecision.validation(expectedEnd: frozenEnd, startedAt: preview.addingTimeInterval(1)),
            .tooSoon
        )
        XCTAssertEqual(
            RuntimeManualLockDecision.validation(expectedEnd: date(17, 12), startedAt: preview),
            .valid
        )
        XCTAssertEqual(
            RuntimeManualLockDecision.validation(expectedEnd: date(17, 12, 0, 1), startedAt: preview),
            .tooLate
        )
        XCTAssertFalse(RuntimeManualLockDecision.accepts(expectedEnd: frozenEnd, startedAt: preview.addingTimeInterval(1)))
        XCTAssertTrue(RuntimeManualLockDecision.accepts(expectedEnd: frozenEnd, startedAt: preview))
        XCTAssertEqual(RuntimeValidationError.manualEndTooSoon.localizedDescription, "Choose an end at least 15 minutes from now.")
        XCTAssertEqual(RuntimeValidationError.manualEndTooLate.localizedDescription, "Choose an end within seven days.")
    }

    func testFutureScheduledOverlapIsFoundAcrossMultipleDays() {
        let start = date(10, 10)
        let end = date(13, 23)
        let overlaps = RuntimeManualLockDecision.overlappingScheduledOccurrences(
            configuration: configuration(),
            intervalStart: start,
            intervalEnd: end,
            calendar: utc
        )

        XCTAssertEqual(overlaps.count, 4)
        XCTAssertEqual(overlaps.map { utc.component(.day, from: $0.start) }, [10, 11, 12, 13])
    }

    func testNonOverlappingFutureScheduleIsNotAConflictCandidate() {
        let overlaps = RuntimeManualLockDecision.overlappingScheduledOccurrences(
            configuration: configuration(),
            intervalStart: date(10, 8),
            intervalEnd: date(10, 20),
            calendar: utc
        )
        XCTAssertTrue(overlaps.isEmpty)
    }

    func testActiveOriginCopyIsTruthfulForManualScheduledOverlap() {
        XCTAssertEqual(RuntimeLockPresentation.activeTitle(for: [session(origin: .scheduled)]), "Get some rest")
        XCTAssertEqual(RuntimeLockPresentation.activeTitle(for: [session(origin: .manual)]), "Focus time")
        XCTAssertEqual(RuntimeLockPresentation.activeTitle(for: [session(origin: .scheduled), session(origin: .manual)]), "Get some rest + Focus time")
        XCTAssertEqual(RuntimeLockPresentation.originSummary(for: [session(origin: .scheduled), session(origin: .manual)]), "Scheduled bedtime and manual focus overlap")
    }

    func testExactManualRegistrationUsesFrozenSecondsAndTolerance() {
        let start = date(10, 12, 0, 17)
        let end = start.addingTimeInterval(30 * 60)
        let startComponents = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        var endComponents = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: end)
        XCTAssertTrue(RuntimeScheduleDecision.manualRegistrationMatchesExact(
            start: start,
            end: end,
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: false,
            calendar: utc
        ))
        endComponents.second! += 2
        XCTAssertFalse(RuntimeScheduleDecision.manualRegistrationMatchesExact(
            start: start,
            end: end,
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: false,
            calendar: utc
        ))
        XCTAssertFalse(RuntimeScheduleDecision.manualRegistrationMatchesExact(
            start: start,
            end: end,
            intervalStart: startComponents,
            intervalEnd: DateComponents(hour: 12, minute: 30),
            repeats: false,
            calendar: utc
        ))
    }
}
