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
        revision: Int = 4,
        start: RuntimeTime = RuntimeTime(hour: 22, minute: 0),
        end: RuntimeTime = RuntimeTime(hour: 7, minute: 0)
    ) -> RuntimeConfiguration {
        RuntimeConfiguration(
            revision: revision,
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

    func testDelayedBedtimeStartOwnsMatchingRecurringOccurrenceWithoutDisablingRecurrence() {
        let occurrenceStart = date(DateComponents(year: 2026, month: 9, day: 10, hour: 22))
        let occurrenceEnd = date(DateComponents(year: 2026, month: 9, day: 11, hour: 7))
        let manual = RuntimeSession(
            origin: .manual,
            start: date(DateComponents(year: 2026, month: 9, day: 10, hour: 23)),
            end: occurrenceEnd,
            sourceRevision: 1,
            policy: policy(),
            purpose: .bedtime,
            scheduledOccurrence: RuntimeScheduledOccurrenceBinding(start: occurrenceStart, end: occurrenceEnd)
        )
        XCTAssertTrue(RuntimeSessionDecision.suppressesScheduledStart(sessions: [manual], occurrenceStart: occurrenceStart, occurrenceEnd: occurrenceEnd, at: date(DateComponents(year: 2026, month: 9, day: 11, hour: 1))))
        XCTAssertFalse(RuntimeSessionDecision.suppressesScheduledStart(sessions: [manual], occurrenceStart: occurrenceStart, occurrenceEnd: occurrenceEnd.addingTimeInterval(1), at: occurrenceStart))
        var recurring = RuntimeStoreDocument()
        recurring.configuration = configuration()
        recurring.recurringEnabledIntent = true
        XCTAssertTrue(RuntimeLifecycle.scheduledRegistrationShouldRemain(recurring, at: occurrenceStart))
    }

    func testReleasedEarlyBedtimeFencesLateScheduledCallbackButAllowsManualRestart() throws {
        let occurrenceStart = date(DateComponents(year: 2026, month: 9, day: 10, hour: 22))
        let occurrenceEnd = date(DateComponents(year: 2026, month: 9, day: 11, hour: 7))
        let manual = RuntimeSession(
            origin: .manual,
            start: date(DateComponents(year: 2026, month: 9, day: 10, hour: 20)),
            end: occurrenceEnd,
            sourceRevision: 1,
            policy: policy(),
            purpose: .bedtime,
            scheduledOccurrence: RuntimeScheduledOccurrenceBinding(start: occurrenceStart, end: occurrenceEnd)
        )
        var document = RuntimeStoreDocument()
        document.configuration = configuration()
        document.recurringEnabledIntent = true
        document.sessions = [manual]
        try RuntimeLifecycle.release(&document, sessionIDs: [manual.id], at: date(DateComponents(year: 2026, month: 9, day: 10, hour: 23)))

        XCTAssertTrue(RuntimeLifecycle.shouldSuppressScheduledOccurrence(document, start: occurrenceStart, end: occurrenceEnd, calendar: utc))
        XCTAssertEqual(document.scheduledActivationFence?.notBeforeOccurrenceStart, occurrenceEnd)

        // A fresh manual session has a new identity and is not released by the
        // prior manual marker, even while the old recurring callback is fenced.
        let restarted = RuntimeSession(
            origin: .manual,
            start: date(DateComponents(year: 2026, month: 9, day: 11, hour: 1)),
            end: occurrenceEnd,
            sourceRevision: 1,
            policy: policy(),
            purpose: .bedtime,
            scheduledOccurrence: RuntimeScheduledOccurrenceBinding(start: occurrenceStart, end: occurrenceEnd)
        )
        XCTAssertNotEqual(restarted.id, manual.id)
        XCTAssertFalse(RuntimeSessionDecision.isReleased(sessions: document.sessions, releasedOccurrences: document.releasedOccurrences, origin: .manual, start: restarted.start, end: restarted.end))
        XCTAssertTrue(RuntimeSessionDecision.suppressesScheduledStart(sessions: [restarted], occurrenceStart: occurrenceStart, occurrenceEnd: occurrenceEnd, at: restarted.start))
    }

    func testFrozenOccurrenceBindingSurvivesCalendarTimeZoneChange() {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York")!
        let occurrenceStart = eastern.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 22))!
        let occurrenceEnd = eastern.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 7))!
        let session = RuntimeSession(
            origin: .manual,
            start: occurrenceStart.addingTimeInterval(60 * 60),
            end: occurrenceEnd,
            sourceRevision: 1,
            policy: policy(),
            purpose: .bedtime,
            scheduledOccurrence: RuntimeScheduledOccurrenceBinding(start: occurrenceStart, end: occurrenceEnd)
        )
        var utcDocument = RuntimeStoreDocument()
        utcDocument.sessions = [session]
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // The callback is matched by frozen absolute bounds, not by the new
        // calendar's civil 22:00/07:00 components.
        XCTAssertTrue(RuntimeSessionDecision.suppressesScheduledStart(sessions: [session], occurrenceStart: occurrenceStart, occurrenceEnd: occurrenceEnd, at: occurrenceStart.addingTimeInterval(2 * 60 * 60)))
        XCTAssertNoThrow(try utcDocument.validate())
    }

    func testManualEndPendingConfigurationActivatesAndStopsOldReplacementRoute() throws {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let manual = RuntimeSession(origin: .manual, start: now.addingTimeInterval(-3_600), end: now, sourceRevision: 1, policy: policy(), purpose: .bedtime)
        var document = RuntimeStoreDocument()
        document.configuration = configuration()
        document.recurringEnabledIntent = true
        document.sessions = [manual]
        document.manualRegistrationActive = true
        document.pendingConfiguration = RuntimeConfiguration(
            revision: 5,
            start: RuntimeTime(hour: 23, minute: 0),
            end: RuntimeTime(hour: 6, minute: 0),
            mode: .blockSelected,
            selectionSummary: policy().selectionSummary,
            selectionData: Data([2])
        )

        XCTAssertTrue(RuntimeCallbackDecision.prepareManualEnd(&document, at: now))
        XCTAssertTrue(RuntimeLifecycle.activatePendingConfigurationIfIdle(&document, at: now))
        XCTAssertEqual(document.configuration?.revision, 5)
        XCTAssertNil(document.pendingConfiguration)
        XCTAssertFalse(RuntimeLifecycle.scheduledRegistrationShouldRemain(document, at: now, replacementActivated: true))
        XCTAssertEqual(RuntimeCallbackDecision.desiredPolicyIntent(document, at: now), .clear)
    }

    func testPendingActivationRollsBackWithTheTransactionBeforePolicySideEffect() throws {
        enum SimulatedCrash: Error { case afterActivation }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phone-lockbox-bedtime-")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedRuntimeStore(directoryURL: directory)
        let pending = configuration(revision: 5, start: RuntimeTime(hour: 23, minute: 0), end: RuntimeTime(hour: 6, minute: 0))
        try store.transaction { document in
            document.configuration = configuration()
            document.pendingConfiguration = pending
            document.recurringEnabledIntent = true
        }
        XCTAssertThrowsError(try store.withTransaction { context in
            XCTAssertTrue(RuntimeLifecycle.activatePendingConfigurationIfIdle(&context.document, at: Date(timeIntervalSinceReferenceDate: 10_000)))
            throw SimulatedCrash.afterActivation
        })
        let recovered = try store.read()
        XCTAssertEqual(recovered.configuration?.revision, 4)
        XCTAssertEqual(recovered.pendingConfiguration?.start, pending.start)
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
