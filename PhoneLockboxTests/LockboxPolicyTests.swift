import XCTest
@testable import PhoneLockbox

final class LockboxPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ components: DateComponents) throws -> Date {
        try XCTUnwrap(calendar.date(from: components))
    }

    private func enabled(_ start: LocalTime, _ end: LocalTime) -> LockboxConfiguration {
        LockboxConfiguration(start: start, end: end, enabled: true)
    }

    func testDisabledConfigurationHasNoOccurrence() throws {
        let configuration = LockboxConfiguration(start: LocalTime(hour: 22, minute: 0), end: LocalTime(hour: 7, minute: 0))
        let noon = try date(DateComponents(year: 2026, month: 9, day: 10, hour: 12))
        XCTAssertFalse(configuration.enabled)
        XCTAssertNil(LockboxPolicy.nextOccurrence(configuration: configuration, after: noon, calendar: calendar))
    }

    func testSameDayOccurrenceUsesCurrentOrNextHalfOpenInterval() throws {
        let configuration = enabled(LocalTime(hour: 9, minute: 0), LocalTime(hour: 17, minute: 0))
        let start = try date(DateComponents(year: 2026, month: 9, day: 10, hour: 9))
        let beforeStart = try date(DateComponents(year: 2026, month: 9, day: 10, hour: 8))
        let inside = try date(DateComponents(year: 2026, month: 9, day: 10, hour: 12))
        let end = try date(DateComponents(year: 2026, month: 9, day: 10, hour: 17))
        let nextDay = try date(DateComponents(year: 2026, month: 9, day: 11, hour: 9))

        let before = try XCTUnwrap(LockboxPolicy.nextOccurrence(configuration: configuration, after: beforeStart, calendar: calendar))
        XCTAssertEqual(before.start, start)
        let atStart = try XCTUnwrap(LockboxPolicy.nextOccurrence(configuration: configuration, after: start, calendar: calendar))
        XCTAssertEqual(atStart.start, start)
        XCTAssertEqual(atStart.end, end)
        let current = try XCTUnwrap(LockboxPolicy.nextOccurrence(configuration: configuration, after: inside, calendar: calendar))
        XCTAssertEqual(current.start, start)
        let afterEnd = try XCTUnwrap(LockboxPolicy.nextOccurrence(configuration: configuration, after: end, calendar: calendar))
        XCTAssertEqual(afterEnd.start, nextDay)
    }

    func testOvernightOccurrenceUsesCurrentOrNextAtBothBoundaries() throws {
        let configuration = enabled(LocalTime(hour: 22, minute: 0), LocalTime(hour: 7, minute: 0))
        let beforeStart = try date(DateComponents(year: 2026, month: 9, day: 10, hour: 12))
        let eveningStart = try date(DateComponents(year: 2026, month: 9, day: 10, hour: 22))
        let eveningInside = try date(DateComponents(year: 2026, month: 9, day: 10, hour: 23))
        let morningInside = try date(DateComponents(year: 2026, month: 9, day: 11, hour: 2))
        let morningEnd = try date(DateComponents(year: 2026, month: 9, day: 11, hour: 7))
        let nextEvening = try date(DateComponents(year: 2026, month: 9, day: 11, hour: 22))

        let before = try XCTUnwrap(LockboxPolicy.nextOccurrence(configuration: configuration, after: beforeStart, calendar: calendar))
        XCTAssertEqual(before.start, eveningStart)
        let atEveningStart = try XCTUnwrap(LockboxPolicy.nextOccurrence(configuration: configuration, after: eveningStart, calendar: calendar))
        XCTAssertEqual(atEveningStart.start, eveningStart)
        let evening = try XCTUnwrap(LockboxPolicy.nextOccurrence(configuration: configuration, after: eveningInside, calendar: calendar))
        XCTAssertEqual(evening.start, eveningStart)
        let morning = try XCTUnwrap(LockboxPolicy.nextOccurrence(configuration: configuration, after: morningInside, calendar: calendar))
        XCTAssertEqual(morning.start, eveningStart)
        let atMorningEnd = try XCTUnwrap(LockboxPolicy.nextOccurrence(configuration: configuration, after: morningEnd, calendar: calendar))
        XCTAssertEqual(atMorningEnd.start, nextEvening)
    }

    func testEqualTimesAreInvalidAndDoNotDecode() throws {
        let configuration = enabled(LocalTime(hour: 22, minute: 0), LocalTime(hour: 22, minute: 0))
        XCTAssertFalse(configuration.isValid)
        XCTAssertNil(LockboxPolicy.nextOccurrence(configuration: configuration, after: .now, calendar: calendar))
        let data = Data(#"{"start":{"hour":22,"minute":0},"end":{"hour":22,"minute":0},"enabled":true}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LockboxConfiguration.self, from: data))
    }

    func testSkippedDSTTimeUsesNextValidBoundary() throws {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let configuration = enabled(LocalTime(hour: 2, minute: 30), LocalTime(hour: 4, minute: 0))
        let query = try XCTUnwrap(dstCalendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 3, minute: 15)))
        let occurrence = try XCTUnwrap(LockboxPolicy.nextOccurrence(configuration: configuration, after: query, calendar: dstCalendar))
        XCTAssertEqual(occurrence.start, Date(timeIntervalSince1970: 1772953200)) // 03:00 EDT
        XCTAssertEqual(dstCalendar.component(.hour, from: occurrence.start), 3)
        XCTAssertEqual(dstCalendar.component(.hour, from: occurrence.end), 4)
    }

    func testRepeatedDSTTimeUsesFirstOccurrence() throws {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let configuration = enabled(LocalTime(hour: 1, minute: 15), LocalTime(hour: 1, minute: 45))
        let first = Date(timeIntervalSince1970: 1793510100) // 2026-11-01 01:15 EDT
        let occurrence = try XCTUnwrap(LockboxPolicy.nextOccurrence(configuration: configuration, after: first, calendar: dstCalendar))
        XCTAssertEqual(occurrence.start, first)
        XCTAssertEqual(occurrence.end, Date(timeIntervalSince1970: 1793511900)) // first 01:45 EDT
    }

    func testRecoveryDelayIsPositiveFiniteAndMeasuredFromRequestTime() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let session = LockboxSession(origin: .scheduled, start: start, end: start.addingTimeInterval(3600), policyRevision: 3)
        var controller = LockboxSessionController(session: session)
        XCTAssertThrowsError(try controller.apply(.requestRecovery(at: start.addingTimeInterval(1), delay: 0))) { error in
            XCTAssertEqual(error as? LockboxSessionTransitionError, .invalidRecoveryDelay)
        }
        XCTAssertThrowsError(try controller.apply(.requestRecovery(at: start.addingTimeInterval(1), delay: .infinity))) { error in
            XCTAssertEqual(error as? LockboxSessionTransitionError, .invalidRecoveryDelay)
        }
        let requested = start.addingTimeInterval(10)
        try controller.apply(.requestRecovery(at: requested, delay: 900))
        XCTAssertFalse(controller.recovery!.isEligible(at: requested.addingTimeInterval(899)))
        XCTAssertTrue(controller.recovery!.isEligible(at: requested.addingTimeInterval(900)))
    }

    func testUnrepresentableRecoveryDelayDoesNotTrapOrMutateState() throws {
        let start = Date(timeIntervalSince1970: 1000)
        for delay in [-1.0, Double.nan, Double.leastNonzeroMagnitude] {
            var controller = LockboxSessionController(session: LockboxSession(origin: .manual, start: start, end: start.addingTimeInterval(3600), policyRevision: 1))
            XCTAssertThrowsError(try controller.apply(.requestRecovery(at: start, delay: delay)))
            XCTAssertEqual(controller.session.state, .active)
            XCTAssertNil(controller.recovery)
        }
    }

    func testCancellationUsesNaturalEndAndRerequestStartsFreshWait() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let session = LockboxSession(origin: .manual, start: start, end: start.addingTimeInterval(3600), policyRevision: 1)
        var controller = LockboxSessionController(session: session)
        try controller.apply(.requestRecovery(at: start, delay: 900))
        try controller.apply(.cancelRecovery(at: start.addingTimeInterval(100)))
        try controller.apply(.requestRecovery(at: start.addingTimeInterval(200), delay: 900))
        XCTAssertEqual(controller.recovery?.eligibleAt, start.addingTimeInterval(1100))
        try controller.apply(.cancelRecovery(at: session.end))
        XCTAssertEqual(controller.session.state, .expired)
        XCTAssertNil(controller.recovery)
    }

    func testRecoveryRequiresWaitAndExplicitConfirmation() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let session = LockboxSession(origin: .manual, start: start, end: start.addingTimeInterval(3600), policyRevision: 1)
        var controller = LockboxSessionController(session: session)
        XCTAssertThrowsError(try controller.apply(.confirmRecovery(at: start.addingTimeInterval(1))))
        try controller.apply(.requestRecovery(at: start.addingTimeInterval(10), delay: 900))
        XCTAssertEqual(controller.session.state, .recoveryPending)
        XCTAssertThrowsError(try controller.apply(.confirmRecovery(at: start.addingTimeInterval(909)))) { error in
            XCTAssertEqual(error as? LockboxSessionTransitionError, .recoveryNotEligible)
        }
        try controller.apply(.confirmRecovery(at: start.addingTimeInterval(910)))
        XCTAssertEqual(controller.session.state, .released)
        XCTAssertNil(controller.recovery)
    }

    func testNaturalEndWinsConfirmationAtAndAfterEnd() throws {
        for offset in [0.0, 1.0] {
            let start = Date(timeIntervalSince1970: 1000)
            let end = start.addingTimeInterval(100)
            let session = LockboxSession(origin: .scheduled, start: start, end: end, policyRevision: 1)
            var controller = LockboxSessionController(session: session)
            try controller.apply(.requestRecovery(at: start.addingTimeInterval(10), delay: 1))
            try controller.apply(.confirmRecovery(at: end.addingTimeInterval(offset)))
            XCTAssertEqual(controller.session.state, .expired)
            XCTAssertNil(controller.recovery)
        }
    }

    func testRecoveryRequestDateMustBeInsideSession() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let session = LockboxSession(origin: .manual, start: start, end: start.addingTimeInterval(100), policyRevision: 1)
        var controller = LockboxSessionController(session: session)
        XCTAssertThrowsError(try controller.apply(.requestRecovery(at: start.addingTimeInterval(-1), delay: 1)))
        XCTAssertThrowsError(try controller.apply(.requestRecovery(at: start.addingTimeInterval(100), delay: 1)))
    }

    func testControllerAndConfigurationRoundTrip() throws {
        let configuration = enabled(LocalTime(hour: 22, minute: 0), LocalTime(hour: 7, minute: 0))
        let session = LockboxSession(origin: .scheduled, start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 2000), policyRevision: 4)
        var controller = LockboxSessionController(session: session)
        try controller.apply(.requestRecovery(at: Date(timeIntervalSince1970: 1100), delay: 900))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(LockboxConfiguration.self, from: encoder.encode(configuration)), configuration)
        XCTAssertEqual(try decoder.decode(LockboxSessionController.self, from: encoder.encode(controller)), controller)
    }

    func testCodableRejectsInvalidTimesSessionsRecoveryAndController() throws {
        let invalidTime = Data(#"{"hour":24,"minute":0}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalTime.self, from: invalidTime))

        let invalidSession = Data(#"{"id":"00000000-0000-0000-0000-000000000001","origin":"manual","start":1000,"end":1000,"state":"active","policyRevision":0}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LockboxSession.self, from: invalidSession))
        let negativeRevision = Data(#"{"id":"00000000-0000-0000-0000-000000000001","origin":"manual","start":1000,"end":2000,"state":"active","policyRevision":-1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LockboxSession.self, from: negativeRevision))

        let invalidRecovery = Data(#"{"sessionID":"00000000-0000-0000-0000-000000000001","requestedAt":1000,"eligibleAt":1000,"cancelled":false}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RecoveryRequest.self, from: invalidRecovery))

        let session = LockboxSession(origin: .manual, start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 2000), policyRevision: 0)
        let validData = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LockboxSessionController(session: session))) as! [String: Any]
        var malformed = validData
        var sessionObject = malformed["session"] as! [String: Any]
        sessionObject["state"] = "recoveryPending"
        malformed["session"] = sessionObject
        XCTAssertThrowsError(try JSONDecoder().decode(LockboxSessionController.self, from: JSONSerialization.data(withJSONObject: malformed)))
    }

    func testDuplicateRecoveryAndRecoveredEndAreIdempotent() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let session = LockboxSession(origin: .scheduled, start: start, end: start.addingTimeInterval(3600), policyRevision: 1)
        var controller = LockboxSessionController(session: session)
        try controller.apply(.requestRecovery(at: start.addingTimeInterval(10), delay: 1))
        XCTAssertThrowsError(try controller.apply(.requestRecovery(at: start.addingTimeInterval(11), delay: 1)))
        try controller.apply(.confirmRecovery(at: start.addingTimeInterval(12)))
        try controller.apply(.scheduledEnd(at: start.addingTimeInterval(3601)))
        XCTAssertEqual(controller.session.state, .released)
    }
}
