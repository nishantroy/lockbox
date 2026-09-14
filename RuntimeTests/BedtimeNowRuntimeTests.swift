import Foundation
import XCTest
@testable import PhoneLockboxRuntime

final class BedtimeNowRuntimeTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ components: DateComponents, calendar: Calendar? = nil) -> Date {
        (calendar ?? utc).date(from: components)!
    }

    private func configuration(
        start: RuntimeTime = RuntimeTime(hour: 22, minute: 0),
        end: RuntimeTime = RuntimeTime(hour: 7, minute: 0)
    ) -> RuntimeConfiguration {
        RuntimeConfiguration(
            revision: 4,
            start: start,
            end: end,
            mode: .blockSelected,
            selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            selectionData: Data([1])
        )
    }

    private func policy() -> RuntimePolicySnapshot {
        RuntimePolicySnapshot(
            mode: .blockSelected,
            selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            selectionData: Data([1])
        )
    }

    func testProposedEndResolvesBeforeDuringAndAfterOvernightBedtime() {
        let saved = configuration()
        let before = date(DateComponents(year: 2026, month: 9, day: 10, hour: 12))
        let evening = date(DateComponents(year: 2026, month: 9, day: 10, hour: 23))
        let morning = date(DateComponents(year: 2026, month: 9, day: 11, hour: 2))
        let afterMorning = date(DateComponents(year: 2026, month: 9, day: 11, hour: 8))
        let firstEnd = date(DateComponents(year: 2026, month: 9, day: 11, hour: 7))
        let secondEnd = date(DateComponents(year: 2026, month: 9, day: 12, hour: 7))

        XCTAssertEqual(RuntimeBedtimeNowDecision.proposedEnd(configuration: saved, recurringEnabled: true, at: before, calendar: utc), firstEnd)
        XCTAssertEqual(RuntimeBedtimeNowDecision.proposedEnd(configuration: saved, recurringEnabled: true, at: evening, calendar: utc), firstEnd)
        XCTAssertEqual(RuntimeBedtimeNowDecision.proposedEnd(configuration: saved, recurringEnabled: true, at: morning, calendar: utc), firstEnd)
        XCTAssertEqual(RuntimeBedtimeNowDecision.proposedEnd(configuration: saved, recurringEnabled: true, at: afterMorning, calendar: utc), secondEnd)
        XCTAssertNil(RuntimeBedtimeNowDecision.proposedEnd(configuration: saved, recurringEnabled: false, at: evening, calendar: utc))
    }

    func testConfirmationMustMatchTheTransactionClockAndFiniteRouteBounds() {
        let saved = configuration()
        let transaction = date(DateComponents(year: 2026, month: 9, day: 10, hour: 23))
        let exactEnd = date(DateComponents(year: 2026, month: 9, day: 11, hour: 7))
        XCTAssertTrue(RuntimeBedtimeNowDecision.accepts(expectedEnd: exactEnd, configuration: saved, recurringEnabled: true, at: transaction, calendar: utc))
        XCTAssertFalse(RuntimeBedtimeNowDecision.accepts(expectedEnd: exactEnd.addingTimeInterval(1), configuration: saved, recurringEnabled: true, at: transaction, calendar: utc))
        XCTAssertFalse(RuntimeBedtimeNowDecision.accepts(expectedEnd: transaction.addingTimeInterval(10 * 60), configuration: saved, recurringEnabled: true, at: transaction, calendar: utc))
        XCTAssertFalse(RuntimeBedtimeNowDecision.accepts(expectedEnd: transaction.addingTimeInterval(8 * 24 * 60 * 60), configuration: saved, recurringEnabled: true, at: transaction, calendar: utc))
        XCTAssertFalse(RuntimeBedtimeNowDecision.accepts(expectedEnd: exactEnd, configuration: nil, recurringEnabled: true, at: transaction, calendar: utc))
        // A preview that named this morning becomes stale after its end.
        let afterEnd = date(DateComponents(year: 2026, month: 9, day: 11, hour: 8))
        XCTAssertFalse(RuntimeBedtimeNowDecision.accepts(expectedEnd: exactEnd, configuration: saved, recurringEnabled: true, at: afterEnd, calendar: utc))
    }

    func testResolutionUsesCalendarRulesForSkippedAndRepeatedDSTBoundaries() {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York")!
        let skippedConfiguration = configuration(start: RuntimeTime(hour: 2, minute: 30), end: RuntimeTime(hour: 4, minute: 0))
        let skippedQuery = date(DateComponents(year: 2026, month: 3, day: 8, hour: 3, minute: 15), calendar: eastern)
        let skippedEnd = date(DateComponents(year: 2026, month: 3, day: 8, hour: 4), calendar: eastern)
        XCTAssertEqual(RuntimeBedtimeNowDecision.proposedEnd(configuration: skippedConfiguration, recurringEnabled: true, at: skippedQuery, calendar: eastern), skippedEnd)

        let repeatedConfiguration = configuration(start: RuntimeTime(hour: 1, minute: 15), end: RuntimeTime(hour: 1, minute: 45))
        let firstRepeatedStart = Date(timeIntervalSince1970: 1793510100)
        let firstRepeatedEnd = Date(timeIntervalSince1970: 1793511900)
        XCTAssertEqual(RuntimeBedtimeNowDecision.proposedEnd(configuration: repeatedConfiguration, recurringEnabled: true, at: firstRepeatedStart, calendar: eastern), firstRepeatedEnd)
    }

    func testOldSessionDataDecodesWithHistoricalPurposeDefaults() throws {
        let scheduled = RuntimeSession(origin: .scheduled, start: Date(timeIntervalSinceReferenceDate: 1_000), end: Date(timeIntervalSinceReferenceDate: 2_000), sourceRevision: 1, policy: policy())
        let manual = RuntimeSession(origin: .manual, start: Date(timeIntervalSinceReferenceDate: 1_000), end: Date(timeIntervalSinceReferenceDate: 2_000), sourceRevision: 1, policy: policy())
        for (session, expected) in [(scheduled, RuntimeSessionPurpose.bedtime), (manual, RuntimeSessionPurpose.focus)] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
            object.removeValue(forKey: "purpose")
            let decoded = try JSONDecoder().decode(RuntimeSession.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.purpose, expected)
        }
    }

    func testBedtimePurposePresentsAsRestAndStatesManualOrigin() {
        let bedtime = RuntimeSession(origin: .manual, start: Date(timeIntervalSinceReferenceDate: 1_000), end: Date(timeIntervalSinceReferenceDate: 2_000), sourceRevision: 1, policy: policy(), purpose: .bedtime)
        let focus = RuntimeSession(origin: .manual, start: Date(timeIntervalSinceReferenceDate: 1_000), end: Date(timeIntervalSinceReferenceDate: 2_000), sourceRevision: 1, policy: policy(), purpose: .focus)
        XCTAssertEqual(RuntimeLockPresentation.activeTitle(for: [bedtime]), "Get some rest")
        XCTAssertEqual(RuntimeLockPresentation.originSummary(for: [bedtime]), "Bedtime started manually")
        XCTAssertEqual(RuntimeLockPresentation.activeTitle(for: [bedtime, focus]), "Get some rest + Focus time")
    }

    func testReleasedManualMarkerCannotSuppressNewBedtimeSession() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let end = Date(timeIntervalSinceReferenceDate: 2_000)
        let old = RuntimeSession(origin: .manual, start: start, end: end, sourceRevision: 1, policy: policy(), purpose: .bedtime)
        var document = RuntimeStoreDocument()
        document.sessions = [old]
        try RuntimeLifecycle.release(&document, sessionIDs: [old.id], at: start.addingTimeInterval(1))
        let restarted = RuntimeSession(origin: .manual, start: start, end: end, sourceRevision: 1, policy: policy(), purpose: .bedtime)
        XCTAssertNotEqual(old.id, restarted.id)
        XCTAssertFalse(RuntimeSessionDecision.isReleased(sessions: document.sessions, releasedOccurrences: document.releasedOccurrences, origin: .manual, start: restarted.start, end: restarted.end))
    }

    func testManualBedtimeOwnsMatchingRecurringOccurrenceWithoutDisablingRecurrence() {
        let occurrenceStart = date(DateComponents(year: 2026, month: 9, day: 10, hour: 22))
        let occurrenceEnd = date(DateComponents(year: 2026, month: 9, day: 11, hour: 7))
        let manual = RuntimeSession(origin: .manual, start: date(DateComponents(year: 2026, month: 9, day: 10, hour: 20)), end: occurrenceEnd, sourceRevision: 1, policy: policy(), purpose: .bedtime)
        XCTAssertTrue(RuntimeSessionDecision.suppressesScheduledStart(sessions: [manual], occurrenceStart: occurrenceStart, occurrenceEnd: occurrenceEnd, at: occurrenceStart))
        XCTAssertFalse(RuntimeSessionDecision.suppressesScheduledStart(sessions: [manual], occurrenceStart: occurrenceStart, occurrenceEnd: occurrenceEnd.addingTimeInterval(1), at: occurrenceStart))
        var recurring = RuntimeStoreDocument()
        recurring.configuration = configuration()
        recurring.recurringEnabledIntent = true
        XCTAssertTrue(RuntimeLifecycle.scheduledRegistrationShouldRemain(recurring, at: occurrenceStart))
    }

    func testLateOldManualEndCannotReleaseNewerBedtimeSession() {
        let old = RuntimeSession(origin: .manual, start: Date(timeIntervalSinceReferenceDate: 1_000), end: Date(timeIntervalSinceReferenceDate: 2_000), sourceRevision: 1, policy: policy(), purpose: .bedtime)
        let newer = RuntimeSession(origin: .manual, start: Date(timeIntervalSinceReferenceDate: 2_000), end: Date(timeIntervalSinceReferenceDate: 4_000), sourceRevision: 1, policy: policy(), purpose: .bedtime)
        var document = RuntimeStoreDocument()
        document.sessions = [old, newer]
        document.manualRegistrationActive = true
        XCTAssertFalse(RuntimeCallbackDecision.prepareManualEnd(&document, at: newer.start.addingTimeInterval(1)))
        XCTAssertEqual(document.sessions.first(where: { $0.id == newer.id })?.state, .active)
        XCTAssertEqual(RuntimeCallbackDecision.currentAggregate(document, at: newer.start.addingTimeInterval(1)).map(\.id), [newer.id])
    }
}
