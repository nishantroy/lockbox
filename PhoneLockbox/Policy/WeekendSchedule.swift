import Foundation
import CryptoKit

/// The seven local civil days understood by the bounded weekend scheduler.
/// Raw values intentionally match Foundation's Gregorian `Calendar.Component.weekday`
/// values, where Sunday is 1 and Saturday is 7. The v1 wire format is the
/// stable lowercase `wireName`, never the numeric raw value.
public enum WeekendScheduleDay: Int, CaseIterable, Codable, Hashable, Comparable, Sendable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    public var wireName: String {
        switch self {
        case .sunday: return "sunday"
        case .monday: return "monday"
        case .tuesday: return "tuesday"
        case .wednesday: return "wednesday"
        case .thursday: return "thursday"
        case .friday: return "friday"
        case .saturday: return "saturday"
        }
    }

    private init?(wireName: String) {
        switch wireName {
        case "sunday": self = .sunday
        case "monday": self = .monday
        case "tuesday": self = .tuesday
        case "wednesday": self = .wednesday
        case "thursday": self = .thursday
        case "friday": self = .friday
        case "saturday": self = .saturday
        default: return nil
        }
    }

    public static func < (lhs: WeekendScheduleDay, rhs: WeekendScheduleDay) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireName)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let name = try container.decode(String.self)
        guard let day = Self(wireName: name) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Enabled day must be one of the lowercase v1 names"
            )
        }
        self = day
    }
}

/// The only rule identities supported by this first multi-rule slice.
public enum WeekendRuleID: String, CaseIterable, Codable, Hashable, Sendable {
    case weekday
    case weekend

    public var allowedDays: Set<WeekendScheduleDay> {
        switch self {
        case .weekday:
            return [.monday, .tuesday, .wednesday, .thursday, .friday]
        case .weekend:
            return [.saturday, .sunday]
        }
    }

    fileprivate var sortOrder: Int {
        switch self {
        case .weekday: return 0
        case .weekend: return 1
        }
    }
}

public struct WeekendPolicyReference: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    /// Builds the only v1 reference form: a privacy-preserving SHA-256 digest
    /// of the opaque snapshot bytes. The digest binds the reference to exactly
    /// the bytes that will later be applied without interpreting or exposing them.
    public static func forSnapshot(_ snapshotData: Data) throws -> WeekendPolicyReference {
        guard !snapshotData.isEmpty, snapshotData.count <= WeekendPolicySnapshot.maxSnapshotBytes else {
            throw WeekendScheduleValidationError.invalidPolicySnapshotSize
        }
        let digest = SHA256.hash(data: snapshotData)
            .map { String(format: "%02x", $0) }
            .joined()
        return try WeekendPolicyReference(rawValue: "sha256:\(digest)")
    }

    public init(rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = rawValue.dropFirst("sha256:".count)
        let lowercaseHex = Set("0123456789abcdef")
        let isHexDigest = digest.count == 64 && digest.allSatisfy { lowercaseHex.contains($0) }
        guard trimmed == rawValue,
              rawValue.utf8.count <= WeekendPolicySnapshot.maxReferenceBytes,
              rawValue.hasPrefix("sha256:"),
              isHexDigest else {
            throw WeekendScheduleValidationError.invalidPolicyReference
        }
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) throws {
        try self.init(rawValue: rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        do {
            try self.init(rawValue: rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A policy reference must be sha256:<64 lowercase hexadecimal digits>"
            )
        }
    }
}

/// Opaque, immutable policy material captured for an occurrence.
///
/// The scheduler does not interpret `snapshotData`; the later runtime adapter
/// must decode and validate it before applying Managed Settings. Keeping both a
/// stable reference and the captured bytes here prevents a later policy edit
/// from changing an already-resolved occurrence.
public struct WeekendPolicySnapshot: Codable, Equatable, Hashable, Sendable {
    public static let maxReferenceBytes = 128
    public static let maxSnapshotBytes = 64 * 1_024
    public static let maxRevision = 999_999_999

    public let reference: WeekendPolicyReference
    public let revision: Int
    public let snapshotData: Data

    public init(reference: WeekendPolicyReference, revision: Int, snapshotData: Data) throws {
        guard (0...Self.maxRevision).contains(revision) else {
            throw WeekendScheduleValidationError.invalidPolicyRevision
        }
        guard !snapshotData.isEmpty, snapshotData.count <= Self.maxSnapshotBytes else {
            throw WeekendScheduleValidationError.invalidPolicySnapshotSize
        }
        guard reference == (try? WeekendPolicyReference.forSnapshot(snapshotData)) else {
            throw WeekendScheduleValidationError.invalidPolicyReferenceBinding
        }
        self.reference = reference
        self.revision = revision
        self.snapshotData = snapshotData
    }

    public init(reference: String, revision: Int, snapshotData: Data) throws {
        try self.init(reference: WeekendPolicyReference(reference), revision: revision, snapshotData: snapshotData)
    }

    private enum CodingKeys: String, CodingKey {
        case reference, revision, snapshotData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let reference = try container.decode(WeekendPolicyReference.self, forKey: .reference)
        let revision = try container.decode(Int.self, forKey: .revision)
        let encodedSnapshot = try container.decode(String.self, forKey: .snapshotData)
        guard encodedSnapshot.utf8.count <= Self.maxSnapshotBytes * 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .snapshotData,
                in: container,
                debugDescription: "A policy snapshot exceeds the encoded size bound"
            )
        }
        guard let snapshotData = Data(base64Encoded: encodedSnapshot) else {
            throw DecodingError.dataCorruptedError(
                forKey: .snapshotData,
                in: container,
                debugDescription: "A policy snapshot must be valid base64"
            )
        }
        do {
            try self.init(reference: reference, revision: revision, snapshotData: snapshotData)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .snapshotData,
                in: container,
                debugDescription: "The policy snapshot is out of bounds or its reference does not match its bytes"
            )
        }
    }
}

public enum WeekendScheduleValidationError: Error, Equatable, Sendable {
    case invalidPolicyReference
    case invalidPolicyReferenceBinding
    case invalidPolicyRevision
    case invalidPolicySnapshotSize
    case invalidRuleRevision
    case invalidCivilDate
    case invalidOccurrence
    case profileHasNoEnabledDays(WeekendRuleID)
    case dayNotAllowed(rule: WeekendRuleID, day: WeekendScheduleDay)
    case equalBoundaries(WeekendRuleID)
    case profileIdentityMismatch(expected: WeekendRuleID, actual: WeekendRuleID)
    case conflictingRules(
        first: WeekendRuleID,
        second: WeekendRuleID,
        firstStartDay: WeekendScheduleDay,
        secondStartDay: WeekendScheduleDay,
        boundaryOnly: Bool
    )
    case unsupportedSchemaVersion(Int)
    case invalidLegacyConfiguration
}

/// A single bounded profile. Its policy snapshot is value-semantic and immutable
/// so an occurrence can carry exactly what was selected when it was resolved.
public struct WeekendRule: Codable, Equatable, Sendable {
    public let id: WeekendRuleID
    public let enabledDays: Set<WeekendScheduleDay>
    public let start: LocalTime
    public let end: LocalTime
    public let policy: WeekendPolicySnapshot

    public init(
        id: WeekendRuleID,
        enabledDays: Set<WeekendScheduleDay>,
        start: LocalTime,
        end: LocalTime,
        policy: WeekendPolicySnapshot
    ) throws {
        guard !enabledDays.isEmpty else {
            throw WeekendScheduleValidationError.profileHasNoEnabledDays(id)
        }
        for day in enabledDays where !id.allowedDays.contains(day) {
            throw WeekendScheduleValidationError.dayNotAllowed(rule: id, day: day)
        }
        guard start.minutesSinceMidnight != end.minutesSinceMidnight else {
            throw WeekendScheduleValidationError.equalBoundaries(id)
        }
        self.id = id
        self.enabledDays = enabledDays
        self.start = start
        self.end = end
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case id, enabledDays, start, end, policy
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        // Set encoding order is not guaranteed. Canonical order keeps the
        // persisted schedule and any future digest deterministic.
        try container.encode(enabledDays.sorted(), forKey: .enabledDays)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(policy, forKey: .policy)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(WeekendRuleID.self, forKey: .id)
        var dayContainer = try container.nestedUnkeyedContainer(forKey: .enabledDays)
        guard let count = dayContainer.count, count <= WeekendSchedule.maxEnabledDays else {
            throw DecodingError.dataCorruptedError(
                forKey: .enabledDays,
                in: container,
                debugDescription: "A rule may contain at most seven enabled days"
            )
        }
        var decodedDays: [WeekendScheduleDay] = []
        decodedDays.reserveCapacity(count)
        var previousDay: WeekendScheduleDay?
        while !dayContainer.isAtEnd {
            let day = try dayContainer.decode(WeekendScheduleDay.self)
            guard previousDay.map({ $0 < day }) ?? true else {
                throw DecodingError.dataCorruptedError(
                    forKey: .enabledDays,
                    in: container,
                    debugDescription: "Enabled days must be unique and sorted in Sunday-to-Saturday order"
                )
            }
            decodedDays.append(day)
            previousDay = day
        }
        let start = try container.decode(LocalTime.self, forKey: .start)
        let end = try container.decode(LocalTime.self, forKey: .end)
        let policy = try container.decode(WeekendPolicySnapshot.self, forKey: .policy)
        do {
            try self.init(id: id, enabledDays: Set(decodedDays), start: start, end: end, policy: policy)
        } catch let error as WeekendScheduleValidationError {
            throw DecodingError.dataCorruptedError(
                forKey: .enabledDays,
                in: container,
                debugDescription: "Invalid \(id.rawValue) rule: \(error)"
            )
        }
    }
}

public struct WeekendCivilDate: Codable, Equatable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        guard (1...9_999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            throw WeekendScheduleValidationError.invalidCivilDate
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else {
            throw WeekendScheduleValidationError.invalidCivilDate
        }
        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (lhs: WeekendCivilDate, rhs: WeekendCivilDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    private enum CodingKeys: String, CodingKey {
        case year, month, day
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let year = try container.decode(Int.self, forKey: .year)
        let month = try container.decode(Int.self, forKey: .month)
        let day = try container.decode(Int.self, forKey: .day)
        do {
            try self.init(year: year, month: month, day: day)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .day,
                in: container,
                debugDescription: "Civil date must be a real Gregorian date"
            )
        }
    }

    fileprivate var canonicalString: String {
        String(format: "%04d-%02d-%02d", locale: Locale(identifier: "en_US_POSIX"), year, month, day)
    }
}

/// Stable across process restarts and timezone changes. It is intentionally
/// based on the schedule revision, rule identity and local civil start date,
/// not on a randomly generated UUID or a recomputed absolute timestamp.
public struct WeekendOccurrenceID: Codable, Equatable, Hashable, Sendable {
    public let ruleID: WeekendRuleID
    public let scheduleRevision: Int
    public let localStartDate: WeekendCivilDate

    public init(ruleID: WeekendRuleID, scheduleRevision: Int, localStartDate: WeekendCivilDate) throws {
        guard (0...WeekendSchedule.maxRevision).contains(scheduleRevision) else {
            throw WeekendScheduleValidationError.invalidRuleRevision
        }
        self.ruleID = ruleID
        self.scheduleRevision = scheduleRevision
        self.localStartDate = localStartDate
    }

    private enum CodingKeys: String, CodingKey {
        case ruleID, scheduleRevision, localStartDate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ruleID = try container.decode(WeekendRuleID.self, forKey: .ruleID)
        let scheduleRevision = try container.decode(Int.self, forKey: .scheduleRevision)
        let localStartDate = try container.decode(WeekendCivilDate.self, forKey: .localStartDate)
        do {
            try self.init(ruleID: ruleID, scheduleRevision: scheduleRevision, localStartDate: localStartDate)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .scheduleRevision,
                in: container,
                debugDescription: "An occurrence revision must be between zero and the v1 maximum"
            )
        }
    }

    public var rawValue: String {
        "phone-lockbox.occurrence.v1.\(ruleID.rawValue).r\(scheduleRevision).\(localStartDate.canonicalString)"
    }
}

public struct WeekendOccurrence: Codable, Equatable, Hashable, Sendable {
    public let id: WeekendOccurrenceID
    public let ruleID: WeekendRuleID
    public let scheduleRevision: Int
    public let localStartDate: WeekendCivilDate
    public let start: Date
    public let end: Date
    public let timeZoneIdentifier: String
    public let policy: WeekendPolicySnapshot

    fileprivate init(
        rule: WeekendRule,
        scheduleRevision: Int,
        localStartDate: WeekendCivilDate,
        start: Date,
        end: Date,
        timeZoneIdentifier: String
    ) throws {
        // All call sites are formed by the validated resolver. Keeping this
        // initializer private prevents an adapter from manufacturing a mutable
        // or open-ended occurrence accidentally.
        guard end > start,
              start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              WeekendSchedule.validatedGregorianCalendar(timeZoneIdentifier: timeZoneIdentifier) != nil,
              WeekendSchedule.localCivilDate(of: start, timeZoneIdentifier: timeZoneIdentifier) == localStartDate else {
            throw WeekendScheduleValidationError.invalidOccurrence
        }
        self.id = try WeekendOccurrenceID(
            ruleID: rule.id,
            scheduleRevision: scheduleRevision,
            localStartDate: localStartDate
        )
        self.ruleID = rule.id
        self.scheduleRevision = scheduleRevision
        self.localStartDate = localStartDate
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.policy = rule.policy
    }

    public var policyReference: WeekendPolicyReference { policy.reference }

    private enum CodingKeys: String, CodingKey {
        case id, ruleID, scheduleRevision, localStartDate, start, end, timeZoneIdentifier, policy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(WeekendOccurrenceID.self, forKey: .id)
        let ruleID = try container.decode(WeekendRuleID.self, forKey: .ruleID)
        let scheduleRevision = try container.decode(Int.self, forKey: .scheduleRevision)
        let localStartDate = try container.decode(WeekendCivilDate.self, forKey: .localStartDate)
        let start = try container.decode(Date.self, forKey: .start)
        let end = try container.decode(Date.self, forKey: .end)
        let timeZoneIdentifier = try container.decode(String.self, forKey: .timeZoneIdentifier)
        let policy = try container.decode(WeekendPolicySnapshot.self, forKey: .policy)
        let expectedID = try? WeekendOccurrenceID(
            ruleID: ruleID,
            scheduleRevision: scheduleRevision,
            localStartDate: localStartDate
        )
        guard id == expectedID,
              id.ruleID == ruleID,
              id.scheduleRevision == scheduleRevision,
              id.localStartDate == localStartDate,
              end > start,
              start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              WeekendSchedule.validatedGregorianCalendar(timeZoneIdentifier: timeZoneIdentifier) != nil,
              WeekendSchedule.localCivilDate(of: start, timeZoneIdentifier: timeZoneIdentifier) == localStartDate else {
            throw DecodingError.dataCorruptedError(
                forKey: .end,
                in: container,
                debugDescription: "An occurrence must have a matching frozen identity, Gregorian civil start date, real timezone, and finite end after start"
            )
        }
        self.id = id
        self.ruleID = ruleID
        self.scheduleRevision = scheduleRevision
        self.localStartDate = localStartDate
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.policy = policy
    }
}

public struct WeekendSchedule: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maxEnabledDays = 7
    public static let maxRevision = WeekendPolicySnapshot.maxRevision

    public let schemaVersion: Int
    public let revision: Int
    public let weekday: WeekendRule?
    public let weekend: WeekendRule?

    public init(
        revision: Int = 0,
        weekday: WeekendRule? = nil,
        weekend: WeekendRule? = nil
    ) throws {
        guard (0...Self.maxRevision).contains(revision) else {
            throw WeekendScheduleValidationError.invalidRuleRevision
        }
        if let weekday, weekday.id != .weekday {
            throw WeekendScheduleValidationError.profileIdentityMismatch(expected: .weekday, actual: weekday.id)
        }
        if let weekend, weekend.id != .weekend {
            throw WeekendScheduleValidationError.profileIdentityMismatch(expected: .weekend, actual: weekend.id)
        }
        if let conflict = Self.firstConflict(weekday: weekday, weekend: weekend) {
            throw conflict
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.revision = revision
        self.weekday = weekday
        self.weekend = weekend
    }

    public var rules: [WeekendRule] {
        [weekday, weekend].compactMap { $0 }
    }

    /// v1 persists no alternate calendar identifier: every civil date is
    /// Gregorian, and every timezone must be a Foundation-recognized identifier.
    fileprivate static func validatedGregorianCalendar(timeZoneIdentifier: String) -> Calendar? {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    fileprivate static func validatedGregorianCalendar(from calendar: Calendar) -> Calendar? {
        guard calendar.identifier == .gregorian else { return nil }
        return validatedGregorianCalendar(timeZoneIdentifier: calendar.timeZone.identifier)
    }

    fileprivate static func localCivilDate(of date: Date, timeZoneIdentifier: String) -> WeekendCivilDate? {
        guard let calendar = validatedGregorianCalendar(timeZoneIdentifier: timeZoneIdentifier),
              date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }
        return try? WeekendCivilDate(year: year, month: month, day: day)
    }

    /// Returns the active occurrence, or the earliest future occurrence when
    /// neither rule is active. A resolved occurrence freezes absolute dates and
    /// the policy snapshot; later configuration edits must create a new schedule
    /// revision rather than mutate this value.
    public func currentOrNext(after date: Date, calendar: Calendar = .current) -> WeekendOccurrence? {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              let calendar = Self.validatedGregorianCalendar(from: calendar) else { return nil }
        return rules
            .compactMap { $0.resolveCurrentOrNext(after: date, scheduleRevision: revision, calendar: calendar) }
            .sorted { lhs, rhs in
                let lhsCurrent = date >= lhs.start && date < lhs.end
                let rhsCurrent = date >= rhs.start && date < rhs.end
                if lhsCurrent != rhsCurrent { return lhsCurrent }
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.ruleID.sortOrder < rhs.ruleID.sortOrder
            }
            .first
    }

    public func nextOccurrence(after date: Date, calendar: Calendar = .current) -> WeekendOccurrence? {
        currentOrNext(after: date, calendar: calendar)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, weekday, weekend
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        // Canonical v1 output omits an absent optional slot. Decoding also
        // accepts explicit null for compatibility, but re-encoding always
        // returns to this unambiguous omitted-key representation.
        try container.encodeIfPresent(weekday, forKey: .weekday)
        try container.encodeIfPresent(weekend, forKey: .weekend)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WeekendScheduleValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        let revision = try container.decode(Int.self, forKey: .revision)
        let weekday = try container.decodeIfPresent(WeekendRule.self, forKey: .weekday)
        let weekend = try container.decodeIfPresent(WeekendRule.self, forKey: .weekend)
        do {
            try self.init(revision: revision, weekday: weekday, weekend: weekend)
        } catch let error as WeekendScheduleValidationError {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Invalid weekend schedule: \(error)"
            )
        }
    }

    private struct WeeklyInterval {
        let ruleID: WeekendRuleID
        let startDay: WeekendScheduleDay
        let startMinute: Int
        let endMinute: Int
    }

    private static func firstConflict(weekday: WeekendRule?, weekend: WeekendRule?) -> WeekendScheduleValidationError? {
        guard let weekday, let weekend else { return nil }
        let firstIntervals = weeklyIntervals(for: weekday)
        let secondIntervals = weeklyIntervals(for: weekend)

        // Compare adjacent copies of the weekly cycle so Sunday-overnight and
        // Monday-start conflicts are caught without special cases.
        for first in firstIntervals {
            for second in secondIntervals {
                for weekOffset in [-7, 0, 7] {
                    let firstAbsoluteStart = first.startMinute
                    let secondAbsoluteStart = second.startMinute + weekOffset * 1_440
                    let firstAbsoluteEnd = first.endMinute
                    let secondAbsoluteEnd = second.endMinute + weekOffset * 1_440
                    let overlapStart = max(firstAbsoluteStart, secondAbsoluteStart)
                    let overlapEnd = min(firstAbsoluteEnd, secondAbsoluteEnd)
                    guard overlapStart <= overlapEnd else { continue }
                    let boundaryOnly = overlapStart == overlapEnd
                    return .conflictingRules(
                        first: first.ruleID,
                        second: second.ruleID,
                        firstStartDay: first.startDay,
                        secondStartDay: second.startDay,
                        boundaryOnly: boundaryOnly
                    )
                }
            }
        }
        return nil
    }

    private static func weeklyIntervals(for rule: WeekendRule) -> [WeeklyInterval] {
        let overnight = rule.start.minutesSinceMidnight > rule.end.minutesSinceMidnight
        return rule.enabledDays.sorted().map { day in
            let dayOffset = (day.rawValue - 1) * 1_440
            let end = dayOffset + rule.end.minutesSinceMidnight + (overnight ? 1_440 : 0)
            return WeeklyInterval(
                ruleID: rule.id,
                startDay: day,
                startMinute: dayOffset + rule.start.minutesSinceMidnight,
                endMinute: end
            )
        }
    }
}

public enum WeekendScheduleMigration {
    /// Converts the existing single daily configuration into the two bounded
    /// profiles without changing its local-time meaning. A disabled legacy
    /// configuration becomes an empty schedule; an enabled one is represented
    /// by one weekday profile and one weekend profile with the same frozen policy.
    public static func fromLegacyDaily(
        _ configuration: LockboxConfiguration,
        policy: WeekendPolicySnapshot,
        revision: Int = 0
    ) throws -> WeekendSchedule {
        guard configuration.isValid else {
            throw WeekendScheduleValidationError.invalidLegacyConfiguration
        }
        guard configuration.enabled else {
            return try WeekendSchedule(revision: revision)
        }
        let weekday = try WeekendRule(
            id: .weekday,
            enabledDays: WeekendRuleID.weekday.allowedDays,
            start: configuration.start,
            end: configuration.end,
            policy: policy
        )
        let weekend = try WeekendRule(
            id: .weekend,
            enabledDays: WeekendRuleID.weekend.allowedDays,
            start: configuration.start,
            end: configuration.end,
            policy: policy
        )
        return try WeekendSchedule(revision: revision, weekday: weekday, weekend: weekend)
    }
}

/// Pure adapter decisions for future DeviceActivity integration. This type
/// intentionally does not import DeviceActivity or register anything.
public enum WeekendScheduleAdapter {
    public static func activityName(for ruleID: WeekendRuleID) -> String {
        "phone-lockbox.schedule.v1.\(ruleID.rawValue)"
    }

    public static func occurrenceIdentity(for occurrence: WeekendOccurrence) -> String {
        occurrence.id.rawValue
    }
}

private extension WeekendRule {
    func resolveCurrentOrNext(
        after date: Date,
        scheduleRevision: Int,
        calendar: Calendar
    ) -> WeekendOccurrence? {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let queryDay = calendar.startOfDay(for: date)
        let candidates = (-8...8).compactMap { offset -> WeekendOccurrence? in
            guard let startDay = calendar.date(byAdding: .day, value: offset, to: queryDay),
                  let day = WeekendScheduleDay(rawValue: calendar.component(.weekday, from: startDay)),
                  enabledDays.contains(day),
                  let startDate = Self.boundary(start, on: startDay, calendar: calendar) else {
                return nil
            }
            let overnight = start.minutesSinceMidnight > end.minutesSinceMidnight
            let endDay: Date
            if overnight {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startDay) else { return nil }
                endDay = nextDay
            } else {
                endDay = startDay
            }
            guard let endDate = Self.boundary(end, on: endDay, calendar: calendar), endDate > startDate else {
                return nil
            }
            let localComponents = calendar.dateComponents([.year, .month, .day], from: startDate)
            guard let year = localComponents.year, let month = localComponents.month, let localDay = localComponents.day else {
                return nil
            }
            guard let civilDate = try? WeekendCivilDate(year: year, month: month, day: localDay),
                  let occurrence = try? WeekendOccurrence(
                    rule: self,
                    scheduleRevision: scheduleRevision,
                    localStartDate: civilDate,
                    start: startDate,
                    end: endDate,
                    timeZoneIdentifier: calendar.timeZone.identifier
                  ) else {
                return nil
            }
            return occurrence
        }
        return candidates
            .sorted { $0.start < $1.start }
            .first { occurrence in
                (date >= occurrence.start && date < occurrence.end) || occurrence.start >= date
            }
    }

    private static func boundary(_ time: LocalTime, on day: Date, calendar: Calendar) -> Date? {
        let dayStart = calendar.startOfDay(for: day)
        guard let value = calendar.nextDate(
            after: dayStart.addingTimeInterval(-1),
            matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            return nil
        }
        return calendar.isDate(value, inSameDayAs: dayStart) ? value : nil
    }
}
