import XCTest
@testable import PhoneLockboxCore

final class WeekendScheduleTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var policy: WeekendPolicySnapshot {
        try! WeekendPolicySnapshot(
            reference: "selection.v1",
            revision: 7,
            snapshotData: Data([0x01, 0x02, 0x03])
        )
    }

    private func date(_ components: DateComponents, calendar: Calendar? = nil) throws -> Date {
        try XCTUnwrap((calendar ?? utc).date(from: components))
    }

    private func rule(
        _ id: WeekendRuleID,
        days: Set<WeekendScheduleDay>,
        start: (Int, Int) = (9, 0),
        end: (Int, Int) = (17, 0),
        policy: WeekendPolicySnapshot? = nil
    ) throws -> WeekendRule {
        try WeekendRule(
            id: id,
            enabledDays: days,
            start: LocalTime(hour: start.0, minute: start.1),
            end: LocalTime(hour: end.0, minute: end.1),
            policy: policy ?? self.policy
        )
    }

    func testProfilesAreExactlyBoundedAndRequireTheirDaySets() throws {
        XCTAssertEqual(WeekendRuleID.allCases, [.weekday, .weekend])
        XCTAssertEqual(WeekendRuleID.weekday.allowedDays, [.monday, .tuesday, .wednesday, .thursday, .friday])
        XCTAssertEqual(WeekendRuleID.weekend.allowedDays, [.saturday, .sunday])

        XCTAssertThrowsError(try rule(.weekday, days: [])) { error in
            XCTAssertEqual(error as? WeekendScheduleValidationError, .profileHasNoEnabledDays(.weekday))
        }
        XCTAssertThrowsError(try rule(.weekday, days: [.saturday])) { error in
            XCTAssertEqual(error as? WeekendScheduleValidationError, .dayNotAllowed(rule: .weekday, day: .saturday))
        }
        XCTAssertThrowsError(try rule(.weekend, days: [.monday])) { error in
            XCTAssertEqual(error as? WeekendScheduleValidationError, .dayNotAllowed(rule: .weekend, day: .monday))
        }
        XCTAssertThrowsError(try rule(.weekday, days: [.monday], start: (9, 0), end: (9, 0))) { error in
            XCTAssertEqual(error as? WeekendScheduleValidationError, .equalBoundaries(.weekday))
        }
    }

    func testScheduleAllowsOnlyOptionalWeekdayAndWeekendSlotsWithStableIdentity() throws {
        let weekday = try rule(.weekday, days: [.monday])
        let weekend = try rule(.weekend, days: [.saturday])
        let schedule = try WeekendSchedule(revision: 12, weekday: weekday, weekend: weekend)

        XCTAssertEqual(schedule.schemaVersion, WeekendSchedule.currentSchemaVersion)
        XCTAssertEqual(schedule.revision, 12)
        XCTAssertEqual(schedule.rules.map(\.id), [.weekday, .weekend])
        XCTAssertEqual(schedule.weekday?.id.rawValue, "weekday")
        XCTAssertEqual(schedule.weekend?.id.rawValue, "weekend")

        let weekdayInWeekendSlot = try WeekendRule(
            id: .weekday,
            enabledDays: [.monday],
            start: LocalTime(hour: 10, minute: 0),
            end: LocalTime(hour: 11, minute: 0),
            policy: policy
        )
        XCTAssertThrowsError(try WeekendSchedule(weekend: weekdayInWeekendSlot)) { error in
            XCTAssertEqual(error as? WeekendScheduleValidationError, .profileIdentityMismatch(expected: .weekend, actual: .weekday))
        }
    }

    func testLegacyDailyMigrationPreservesAllDaysAndDisabledState() throws {
        let legacy = LockboxConfiguration(
            start: LocalTime(hour: 22, minute: 30),
            end: LocalTime(hour: 7, minute: 15),
            enabled: true
        )
        let migrated = try WeekendScheduleMigration.fromLegacyDaily(legacy, policy: policy, revision: 4)
        XCTAssertEqual(migrated.revision, 4)
        XCTAssertEqual(migrated.weekday?.enabledDays, WeekendRuleID.weekday.allowedDays)
        XCTAssertEqual(migrated.weekend?.enabledDays, WeekendRuleID.weekend.allowedDays)
        XCTAssertEqual(migrated.weekday?.start, legacy.start)
        XCTAssertEqual(migrated.weekend?.end, legacy.end)
        XCTAssertEqual(migrated.weekday?.policy, policy)
        XCTAssertEqual(migrated.weekend?.policy, policy)

        let disabled = LockboxConfiguration(start: legacy.start, end: legacy.end, enabled: false)
        let empty = try WeekendScheduleMigration.fromLegacyDaily(disabled, policy: policy)
        XCTAssertNil(empty.weekday)
        XCTAssertNil(empty.weekend)

        let invalid = LockboxConfiguration(start: LocalTime(hour: 9, minute: 0), end: LocalTime(hour: 9, minute: 0), enabled: true)
        XCTAssertThrowsError(try WeekendScheduleMigration.fromLegacyDaily(invalid, policy: policy)) { error in
            XCTAssertEqual(error as? WeekendScheduleValidationError, .invalidLegacyConfiguration)
        }
    }

    func testSchemaRoundTripIsVersionedAndDaysEncodeCanonically() throws {
        let weekday = try rule(.weekday, days: [.friday, .monday, .wednesday])
        let schedule = try WeekendSchedule(revision: 3, weekday: weekday)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(schedule)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, WeekendSchedule.currentSchemaVersion)
        XCTAssertEqual(try decoder.decode(WeekendSchedule.self, from: data), schedule)

        let invalidVersion = Data(#"{"schemaVersion":99,"revision":0,"weekday":null,"weekend":null}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(WeekendSchedule.self, from: invalidVersion)) { error in
            XCTAssertEqual(error as? WeekendScheduleValidationError, .unsupportedSchemaVersion(99))
        }
        XCTAssertThrowsError(try WeekendSchedule(revision: -1)) { error in
            XCTAssertEqual(error as? WeekendScheduleValidationError, .invalidRuleRevision)
        }
    }

    func testRejectsStrictOverlapAndTouchingBoundaryIncludingOvernightCrossDay() throws {
        let weekdayOvernight = try rule(.weekday, days: [.friday], start: (22, 0), end: (7, 0))
        let weekendOverlap = try rule(.weekend, days: [.saturday], start: (6, 0), end: (8, 0))
        XCTAssertThrowsError(try WeekendSchedule(weekday: weekdayOvernight, weekend: weekendOverlap)) { error in
            guard case let .conflictingRules(first, second, firstDay, secondDay, boundaryOnly) = error as? WeekendScheduleValidationError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(first, .weekday)
            XCTAssertEqual(second, .weekend)
            XCTAssertEqual(firstDay, .friday)
            XCTAssertEqual(secondDay, .saturday)
            XCTAssertFalse(boundaryOnly)
        }

        let weekendBoundary = try rule(.weekend, days: [.saturday], start: (7, 0), end: (8, 0))
        XCTAssertThrowsError(try WeekendSchedule(weekday: weekdayOvernight, weekend: weekendBoundary)) { error in
            guard case let .conflictingRules(first, second, _, _, boundaryOnly) = error as? WeekendScheduleValidationError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(first, .weekday)
            XCTAssertEqual(second, .weekend)
            XCTAssertTrue(boundaryOnly)
        }

        let sundayOvernight = try rule(.weekend, days: [.sunday], start: (22, 0), end: (7, 0))
        let mondayBoundary = try rule(.weekday, days: [.monday], start: (7, 0), end: (8, 0))
        XCTAssertThrowsError(try WeekendSchedule(weekday: mondayBoundary, weekend: sundayOvernight)) { error in
            guard case let .conflictingRules(_, _, firstDay, secondDay, boundaryOnly) = error as? WeekendScheduleValidationError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(firstDay, .monday)
            XCTAssertEqual(secondDay, .sunday)
            XCTAssertTrue(boundaryOnly)
        }

        let nonOverlapping = try rule(.weekend, days: [.saturday], start: (8, 0), end: (10, 0))
        XCTAssertNoThrow(try WeekendSchedule(weekday: weekdayOvernight, weekend: nonOverlapping))
    }

    func testCurrentOrNextCoversEveryWeekdayAtStartInsideEndAndAfterEnd() throws {
        let sunday = try date(DateComponents(year: 2026, month: 9, day: 6, hour: 0))
        for day in WeekendRuleID.weekday.allowedDays {
            let dayStart = try XCTUnwrap(utc.date(byAdding: .day, value: day.rawValue - 1, to: sunday))
            let profile = try rule(.weekday, days: [day])
            let schedule = try WeekendSchedule(revision: 5, weekday: profile)
            let expectedStart = dayStart.addingTimeInterval(9 * 3_600)
            let expectedEnd = dayStart.addingTimeInterval(17 * 3_600)

            let before = try XCTUnwrap(schedule.currentOrNext(after: dayStart.addingTimeInterval(8 * 3_600), calendar: utc))
            XCTAssertEqual(before.start, expectedStart)
            XCTAssertEqual(before.end, expectedEnd)
            XCTAssertEqual(before.localStartDate, WeekendCivilDate(year: 2026, month: 9, day: 6 + day.rawValue - 1))

            let atStart = try XCTUnwrap(schedule.currentOrNext(after: expectedStart, calendar: utc))
            XCTAssertEqual(atStart.id, before.id)
            let inside = try XCTUnwrap(schedule.currentOrNext(after: expectedStart.addingTimeInterval(60), calendar: utc))
            XCTAssertEqual(inside.id, before.id)
            let atEnd = try XCTUnwrap(schedule.currentOrNext(after: expectedEnd, calendar: utc))
            XCTAssertEqual(atEnd.start, expectedStart.addingTimeInterval(7 * 24 * 3_600))
            XCTAssertNotEqual(atEnd.id, before.id)
        }
    }

    func testCurrentOrNextCoversEveryDayForOvernightWindowsAndHalfOpenEnd() throws {
        let sunday = try date(DateComponents(year: 2026, month: 9, day: 6, hour: 0))
        for day in WeekendScheduleDay.allCases {
            let profileID: WeekendRuleID = day == .saturday || day == .sunday ? .weekend : .weekday
            let profile = try rule(profileID, days: [day], start: (22, 0), end: (7, 0))
            let schedule = try WeekendSchedule(revision: 6, weekday: profileID == .weekday ? profile : nil, weekend: profileID == .weekend ? profile : nil)
            let startDate = try XCTUnwrap(utc.date(byAdding: .day, value: day.rawValue - 1, to: sunday)).addingTimeInterval(22 * 3_600)
            let morning = startDate.addingTimeInterval(4 * 3_600)
            let current = try XCTUnwrap(schedule.currentOrNext(after: morning, calendar: utc))
            XCTAssertEqual(current.start, startDate)
            XCTAssertEqual(current.end, startDate.addingTimeInterval(9 * 3_600))
            let atEnd = try XCTUnwrap(schedule.currentOrNext(after: current.end, calendar: utc))
            XCTAssertEqual(atEnd.start, startDate.addingTimeInterval(7 * 24 * 3_600))
        }
    }

    func testDSTSkippedAndRepeatedBoundariesUseDocumentedCalendarPolicies() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let springRule = try rule(.weekend, days: [.sunday], start: (2, 30), end: (4, 0))
        let springSchedule = try WeekendSchedule(weekend: springRule)
        let springQuery = try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 3, minute: 15)))
        let spring = try XCTUnwrap(springSchedule.currentOrNext(after: springQuery, calendar: newYork))
        XCTAssertEqual(spring.start, Date(timeIntervalSince1970: 1772953200))
        XCTAssertEqual(newYork.component(.hour, from: spring.start), 3)
        XCTAssertEqual(newYork.component(.hour, from: spring.end), 4)

        let fallRule = try rule(.weekend, days: [.sunday], start: (1, 15), end: (1, 45))
        let fallSchedule = try WeekendSchedule(revision: 2, weekend: fallRule)
        let first = Date(timeIntervalSince1970: 1793510100)
        let fall = try XCTUnwrap(fallSchedule.currentOrNext(after: first, calendar: newYork))
        XCTAssertEqual(fall.start, first)
        XCTAssertEqual(fall.end, Date(timeIntervalSince1970: 1793511900))
        XCTAssertEqual(fall.localStartDate, WeekendCivilDate(year: 2026, month: 11, day: 1))
    }

    func testTimezoneChangeChangesFutureAbsoluteBoundaryButNotRuleOrOccurrenceIdentity() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let profile = try rule(.weekday, days: [.monday])
        let schedule = try WeekendSchedule(revision: 8, weekday: profile)
        let newYorkQuery = try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12)))
        let losAngelesQuery = try XCTUnwrap(losAngeles.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12)))
        let ny = try XCTUnwrap(schedule.currentOrNext(after: newYorkQuery, calendar: newYork))
        let la = try XCTUnwrap(schedule.currentOrNext(after: losAngelesQuery, calendar: losAngeles))

        XCTAssertNotEqual(ny.start, la.start)
        XCTAssertEqual(ny.localStartDate, la.localStartDate)
        XCTAssertEqual(ny.id, la.id)
        XCTAssertEqual(ny.policy, la.policy)
        XCTAssertEqual(ny.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(la.timeZoneIdentifier, "America/Los_Angeles")
    }

    func testOccurrenceFreezesPolicyAndAdapterNamesNeverRegisterAnything() throws {
        let profile = try rule(.weekday, days: [.monday])
        let schedule = try WeekendSchedule(revision: 9, weekday: profile)
        let query = try date(DateComponents(year: 2026, month: 9, day: 7, hour: 10))
        let occurrence = try XCTUnwrap(schedule.currentOrNext(after: query, calendar: utc))
        XCTAssertEqual(occurrence.policy, profile.policy)
        XCTAssertEqual(occurrence.policyReference, policy.reference)
        XCTAssertEqual(WeekendScheduleAdapter.activityName(for: .weekday), "phone-lockbox.schedule.v1.weekday")
        XCTAssertEqual(WeekendScheduleAdapter.activityName(for: .weekend), "phone-lockbox.schedule.v1.weekend")
        XCTAssertEqual(WeekendScheduleAdapter.occurrenceIdentity(for: occurrence), occurrence.id.rawValue)
        XCTAssertTrue(occurrence.id.rawValue.contains("weekday.r9.2026-09-07"))
    }
}
