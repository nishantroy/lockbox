import Foundation

/// Pure bounds and overlap decisions for the finite Lock now route. The
/// coordinator uses these values before it persists or applies a policy so a
/// UI preview can never turn into an indefinite restriction.
public enum RuntimeManualLockDecision {
    public static let minimumDuration: TimeInterval = 15 * 60
    public static let maximumDuration: TimeInterval = 7 * 24 * 60 * 60
    /// DeviceActivity can round a returned component boundary by a second on
    /// some OS versions. This is only used to compare the frozen registration
    /// with the already committed absolute end; it is not a duration grace.
    public static let registrationClockTolerance: TimeInterval = 1

    public static func proposedEnd(after duration: TimeInterval, at date: Date) -> Date? {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              duration.isFinite,
              duration >= minimumDuration,
              duration <= maximumDuration else { return nil }
        let end = date.addingTimeInterval(duration)
        guard end.timeIntervalSinceReferenceDate.isFinite, end > date else { return nil }
        return end
    }

    public static func customEndRange(at date: Date) -> ClosedRange<Date> {
        date.addingTimeInterval(minimumDuration)...date.addingTimeInterval(maximumDuration)
    }

    /// Validates the caller's frozen absolute end against the actual
    /// transaction start. It intentionally does not compare against a newly
    /// computed preview: a few seconds of UI/clock drift must not replace the
    /// confirmed absolute boundary.
    public static func accepts(expectedEnd: Date, startedAt: Date) -> Bool {
        guard startedAt.timeIntervalSinceReferenceDate.isFinite,
              expectedEnd.timeIntervalSinceReferenceDate.isFinite else { return false }
        let duration = expectedEnd.timeIntervalSince(startedAt)
        return duration.isFinite
            && duration >= minimumDuration
            && duration <= maximumDuration
    }

    /// Returns every saved daily occurrence that intersects a finite manual
    /// interval. The seven-day manual limit makes this bounded while the
    /// small calendar cushion covers overnight and DST boundaries.
    public static func overlappingScheduledOccurrences(
        configuration: RuntimeConfiguration,
        intervalStart: Date,
        intervalEnd: Date,
        calendar: Calendar = .current
    ) -> [RuntimeOccurrenceResolver.Occurrence] {
        guard intervalStart < intervalEnd,
              intervalStart.timeIntervalSinceReferenceDate.isFinite,
              intervalEnd.timeIntervalSinceReferenceDate.isFinite else { return [] }

        let firstDay = calendar.startOfDay(for: intervalStart)
        let lastDay = calendar.startOfDay(for: intervalEnd)
        guard let first = calendar.date(byAdding: .day, value: -2, to: firstDay),
              let last = calendar.date(byAdding: .day, value: 2, to: lastDay) else { return [] }

        var day = first
        var seen = Set<String>()
        var result: [RuntimeOccurrenceResolver.Occurrence] = []
        var iterations = 0
        while day <= last && iterations < 32 {
            let candidates = RuntimeOccurrenceResolver.candidates(
                start: configuration.start,
                end: configuration.end,
                around: day,
                calendar: calendar
            )
            for occurrence in candidates where occurrence.start < intervalEnd && occurrence.end > intervalStart {
                let key = "\(occurrence.start.timeIntervalSinceReferenceDate):\(occurrence.end.timeIntervalSinceReferenceDate)"
                if seen.insert(key).inserted { result.append(occurrence) }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
            iterations += 1
        }
        return result.sorted { $0.start < $1.start }
    }
}

/// Resolution and transaction-clock validation for the owner-approved
/// Start bedtime now action. The action borrows the saved civil schedule's
/// next occurrence, but its committed end is an absolute Date frozen at the
/// transaction boundary.
public enum RuntimeBedtimeNowDecision {
    public static func proposedOccurrence(
        configuration: RuntimeConfiguration?,
        recurringEnabled: Bool,
        at date: Date,
        calendar: Calendar = .current
    ) -> RuntimeScheduledOccurrenceBinding? {
        guard recurringEnabled,
              let configuration,
              (try? configuration.validate()) != nil,
              let occurrence = RuntimeOccurrenceResolver.currentOrNext(
                  start: configuration.start,
                  end: configuration.end,
                  enabled: true,
                  after: date,
                  calendar: calendar
              ) else { return nil }
        return RuntimeScheduledOccurrenceBinding(start: occurrence.start, end: occurrence.end)
    }

    public static func proposedEnd(
        configuration: RuntimeConfiguration?,
        recurringEnabled: Bool,
        at date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        proposedOccurrence(
            configuration: configuration,
            recurringEnabled: recurringEnabled,
            at: date,
            calendar: calendar
        )?.end
    }

    /// The confirmation is valid only when it names the exact end of the
    /// next saved occurrence at the transaction clock. A preview may survive
    /// harmless clock drift before the same occurrence, but it cannot be
    /// shortened, extended, or carried into a different occurrence.
    public static func accepts(
        expectedEnd: Date,
        configuration: RuntimeConfiguration?,
        recurringEnabled: Bool,
        at date: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard expectedEnd.timeIntervalSinceReferenceDate.isFinite,
              let proposed = proposedOccurrence(configuration: configuration, recurringEnabled: recurringEnabled, at: date, calendar: calendar),
              proposed.end == expectedEnd else { return false }
        return RuntimeManualLockDecision.accepts(expectedEnd: expectedEnd, startedAt: date)
    }
}

/// Truthful copy for the ordinary Lockbox active-session surface. The
/// coordinator supplies the currently effective sessions; no cached title can
/// survive a changing clock or a newly reconciled overlap.
public enum RuntimeLockPresentation {
    private static func isBedtime(_ session: RuntimeSession) -> Bool {
        // Scheduled sessions written before `purpose` existed were decoded as
        // bedtime. The origin fallback also keeps this boundary defensive for
        // callers constructing a historical scheduled value.
        session.purpose == .bedtime || session.origin == .scheduled
    }

    public static func activeTitle(for sessions: [RuntimeSession]) -> String {
        let hasBedtime = sessions.contains(where: isBedtime)
        let hasFocus = sessions.contains { !isBedtime($0) }
        switch (hasBedtime, hasFocus) {
        case (true, true): return "Get some rest + Focus time"
        case (true, false): return "Get some rest"
        case (false, true): return "Focus time"
        case (false, false): return ""
        }
    }

    public static func originSummary(for sessions: [RuntimeSession]) -> String {
        let scheduledBedtime = sessions.contains { $0.origin == .scheduled && isBedtime($0) }
        let manualBedtime = sessions.contains { $0.origin == .manual && isBedtime($0) }
        let manualFocus = sessions.contains { $0.origin == .manual && !isBedtime($0) }
        switch (scheduledBedtime, manualBedtime, manualFocus) {
        case (false, false, false): return ""
        case (true, false, false): return "Scheduled bedtime"
        case (false, true, false): return "Bedtime started manually"
        case (false, false, true): return "Manual focus"
        case (true, true, false): return "Scheduled bedtime and bedtime started manually overlap"
        case (true, false, true): return "Scheduled bedtime and manual focus overlap"
        case (false, true, true): return "Bedtime started manually and manual focus overlap"
        case (true, true, true): return "Scheduled bedtime, bedtime started manually, and manual focus overlap"
        }
    }
}

/// The only restriction modes accepted by the app and the monitor.
public enum RuntimeMode: String, Codable, CaseIterable, Sendable {
    case blockSelected
    case allowOnlySelected
}

public struct RuntimeSelectionSummary: Codable, Equatable, Sendable {
    public let applicationCount: Int
    public let categoryCount: Int
    public let webDomainCount: Int

    public init(applicationCount: Int, categoryCount: Int, webDomainCount: Int) {
        self.applicationCount = applicationCount
        self.categoryCount = categoryCount
        self.webDomainCount = webDomainCount
    }

    public var totalCount: Int {
        let (first, overflow1) = applicationCount.addingReportingOverflow(categoryCount)
        let (total, overflow2) = first.addingReportingOverflow(webDomainCount)
        return overflow1 || overflow2 ? Int.max : total
    }

    public func validateCounts() throws {
        let (first, overflow1) = applicationCount.addingReportingOverflow(categoryCount)
        let (_, overflow2) = first.addingReportingOverflow(webDomainCount)
        guard applicationCount >= 0, categoryCount >= 0, webDomainCount >= 0,
              !overflow1, !overflow2 else {
            throw RuntimeValidationError.invalidSelection("Selection counts are invalid.")
        }
    }

    public func validate(for mode: RuntimeMode) throws {
        try validateCounts()
        guard totalCount > 0 else {
            throw RuntimeValidationError.invalidSelection("Select at least one app, category, or website.")
        }
        if mode == .allowOnlySelected, applicationCount == 0 {
            throw RuntimeValidationError.invalidSelection("Allow-only mode requires at least one app token.")
        }
    }
}

public enum RuntimeValidationError: LocalizedError, Equatable, Sendable {
    case invalidSelection(String)
    case invalidConfiguration(String)
    case intervalTooShort
    case corruptSharedData
    case appGroupUnavailable
    case concurrentStoreAccess
    case overlapUnsupported
    case manualLockUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidSelection(let message), .invalidConfiguration(let message): return message
        case .intervalTooShort: return "The bedtime window must be at least 15 minutes (Apple's DeviceActivity minimum)."
        case .corruptSharedData: return "Shared Phone Lockbox data is corrupt and was not used."
        case .appGroupUnavailable: return "The Phone Lockbox App Group is unavailable."
        case .concurrentStoreAccess: return "Phone Lockbox shared state is busy. Try again."
        case .overlapUnsupported: return "This lock overlaps a rule with a different mode. The existing lock was not changed."
        case .manualLockUnavailable: return "A finite system-managed end is not available for Lock now."
        }
    }
}

/// This value keeps policy construction identical without putting Screen Time
/// framework types in the Foundation-only shared target.
public struct RuntimePolicyPlan: Codable, Equatable, Sendable {
    public let mode: RuntimeMode
    public let blocksSelectedApplications: Bool
    public let blocksSelectedCategories: Bool
    public let blocksSelectedWebDomains: Bool
    public let excludesSelectedApplicationsFromBroadShield: Bool
    public let excludesSelectedWebDomainsFromBroadShield: Bool

    public static func make(mode: RuntimeMode, selection: RuntimeSelectionSummary) throws -> RuntimePolicyPlan {
        try selection.validate(for: mode)
        switch mode {
        case .blockSelected:
            return RuntimePolicyPlan(
                mode: mode,
                blocksSelectedApplications: selection.applicationCount > 0,
                blocksSelectedCategories: selection.categoryCount > 0,
                blocksSelectedWebDomains: selection.webDomainCount > 0,
                excludesSelectedApplicationsFromBroadShield: false,
                excludesSelectedWebDomainsFromBroadShield: false
            )
        case .allowOnlySelected:
            return RuntimePolicyPlan(
                mode: mode,
                blocksSelectedApplications: false,
                blocksSelectedCategories: false,
                blocksSelectedWebDomains: false,
                excludesSelectedApplicationsFromBroadShield: true,
                excludesSelectedWebDomainsFromBroadShield: true
            )
        }
    }
}

public struct RuntimeTime: Codable, Equatable, Sendable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public func validate() throws {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else {
            throw RuntimeValidationError.invalidConfiguration("Choose valid start and end times.")
        }
    }

    public var displayValue: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

public struct RuntimeConfiguration: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public let schemaVersion: Int
    public let revision: Int
    public let start: RuntimeTime
    public let end: RuntimeTime
    public let mode: RuntimeMode
    public let selectionSummary: RuntimeSelectionSummary
    /// Opaque FamilyControls data. Diagnostics never expose this value.
    public let selectionData: Data

    public init(
        revision: Int,
        start: RuntimeTime,
        end: RuntimeTime,
        mode: RuntimeMode,
        selectionSummary: RuntimeSelectionSummary,
        selectionData: Data
    ) {
        self.schemaVersion = Self.currentSchema
        self.revision = revision
        self.start = start
        self.end = end
        self.mode = mode
        self.selectionSummary = selectionSummary
        self.selectionData = selectionData
    }

    public var civilDurationMinutes: Int {
        let startMinutes = start.hour * 60 + start.minute
        let endMinutes = end.hour * 60 + end.minute
        let duration = endMinutes - startMinutes
        return duration > 0 ? duration : duration + 24 * 60
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchema else {
            throw RuntimeValidationError.invalidConfiguration("This saved configuration version is not supported.")
        }
        try start.validate()
        try end.validate()
        guard start != end else {
            throw RuntimeValidationError.invalidConfiguration("Choose different start and end times.")
        }
        guard civilDurationMinutes >= 15 else {
            throw RuntimeValidationError.intervalTooShort
        }
        guard revision >= 0, !selectionData.isEmpty else {
            throw RuntimeValidationError.invalidConfiguration("Saved selection data is incomplete.")
        }
        _ = try RuntimePolicyPlan.make(mode: mode, selection: selectionSummary)
    }
}

/// Draft edits are persisted separately and are never read by the monitor for enforcement.
public struct RuntimeDraft: Codable, Equatable, Sendable {
    public let start: RuntimeTime
    public let end: RuntimeTime
    public let mode: RuntimeMode
    public let selectionSummary: RuntimeSelectionSummary
    public let selectionData: Data

    public init(start: RuntimeTime, end: RuntimeTime, mode: RuntimeMode, selectionSummary: RuntimeSelectionSummary, selectionData: Data) {
        self.start = start
        self.end = end
        self.mode = mode
        self.selectionSummary = selectionSummary
        self.selectionData = selectionData
    }
}

public enum RuntimeOwner: String, Codable, Sendable {
    case scheduled
    case prototypeTest
}

public enum RuntimeSessionOrigin: String, Codable, Sendable {
    case scheduled
    case manual
}

/// The immutable user-facing purpose of a session. A bedtime started from the
/// app deliberately keeps the nonrepeating `.manual` DeviceActivity route so
/// its end is finite, while retaining bedtime presentation semantics.
public enum RuntimeSessionPurpose: String, Codable, Sendable {
    case bedtime
    case focus
}

/// Absolute identity of the saved recurring occurrence covered by a manually
/// started bedtime. Civil components are intentionally not persisted here:
/// after a time-zone change, the original absolute bounds remain authoritative.
public struct RuntimeScheduledOccurrenceBinding: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var key: String {
        RuntimeSessionDecision.occurrenceKey(origin: .scheduled, start: start, end: end)
    }

    public func validate() throws {
        guard start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              end > start else {
            throw RuntimeValidationError.corruptSharedData
        }
    }
}

public enum RuntimeSessionState: String, Codable, Sendable {
    case active
    case recoveryPending
    case released
    case expired
}

/// A policy is copied into every committed occurrence.  Configuration revisions
/// are not snapshots: an active session must remain enforceable after an edit.
public struct RuntimePolicySnapshot: Codable, Equatable, Sendable {
    public let mode: RuntimeMode
    public let selectionSummary: RuntimeSelectionSummary
    public let selectionData: Data

    public init(mode: RuntimeMode, selectionSummary: RuntimeSelectionSummary, selectionData: Data) {
        self.mode = mode
        self.selectionSummary = selectionSummary
        self.selectionData = selectionData
    }

    public func validate() throws {
        guard !selectionData.isEmpty else { throw RuntimeValidationError.corruptSharedData }
        _ = try RuntimePolicyPlan.make(mode: mode, selection: selectionSummary)
    }
}

/// Durable identity for one resolved scheduled or bounded manual occurrence.
/// The start/end pair is retained as well as the UUID so a duplicate callback
/// can be matched even after the saved configuration has changed.
public struct RuntimeSession: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public let schemaVersion: Int
    public let id: UUID
    public let origin: RuntimeSessionOrigin
    /// Frozen presentation semantics, independent from the DeviceActivity
    /// route used to obtain a finite end. Missing values in older documents
    /// decode from the historical origin (`scheduled` bedtime, `manual`
    /// focus), preserving existing stored sessions unchanged.
    public let purpose: RuntimeSessionPurpose
    /// Frozen absolute recurring occurrence covered by a bedtime-now session.
    /// Older sessions leave this nil and use conservative fallback matching.
    public let scheduledOccurrence: RuntimeScheduledOccurrenceBinding?
    public let start: Date
    public let end: Date
    public let sourceRevision: Int
    public let policy: RuntimePolicySnapshot
    public var state: RuntimeSessionState

    public init(
        id: UUID = UUID(),
        origin: RuntimeSessionOrigin,
        start: Date,
        end: Date,
        sourceRevision: Int,
        policy: RuntimePolicySnapshot,
        purpose: RuntimeSessionPurpose? = nil,
        scheduledOccurrence: RuntimeScheduledOccurrenceBinding? = nil,
        state: RuntimeSessionState = .active
    ) {
        self.schemaVersion = Self.currentSchema
        self.id = id
        self.origin = origin
        self.purpose = purpose ?? (origin == .scheduled ? .bedtime : .focus)
        self.scheduledOccurrence = scheduledOccurrence
        self.start = start
        self.end = end
        self.sourceRevision = sourceRevision
        self.policy = policy
        self.state = state
    }

    public var occurrenceKey: String {
        "\(origin.rawValue):\(start.timeIntervalSinceReferenceDate):\(end.timeIntervalSinceReferenceDate)"
    }

    public var occurrenceIdentity: String { occurrenceKey }
    public var policyRevision: Int { sourceRevision }
    public var policySnapshot: RuntimePolicySnapshot { policy }

    public var isEffective: Bool {
        state == .active || state == .recoveryPending
    }

    public func isEffective(at date: Date) -> Bool {
        isEffective && date >= start && date < end
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchema,
              start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              end > start,
              sourceRevision >= 0 else { throw RuntimeValidationError.corruptSharedData }
        if let scheduledOccurrence {
            try scheduledOccurrence.validate()
            guard end == scheduledOccurrence.end,
                  start < scheduledOccurrence.end else { throw RuntimeValidationError.corruptSharedData }
        }
        try policy.validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, origin, purpose, scheduledOccurrence, start, end, sourceRevision, policy, state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(UUID.self, forKey: .id)
        origin = try container.decode(RuntimeSessionOrigin.self, forKey: .origin)
        purpose = try container.decodeIfPresent(RuntimeSessionPurpose.self, forKey: .purpose)
            ?? (origin == .scheduled ? .bedtime : .focus)
        scheduledOccurrence = try container.decodeIfPresent(RuntimeScheduledOccurrenceBinding.self, forKey: .scheduledOccurrence)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        sourceRevision = try container.decode(Int.self, forKey: .sourceRevision)
        policy = try container.decode(RuntimePolicySnapshot.self, forKey: .policy)
        state = try container.decode(RuntimeSessionState.self, forKey: .state)
        do { try validate() } catch {
            throw DecodingError.dataCorruptedError(forKey: .end, in: container, debugDescription: "Invalid runtime session")
        }
    }
}

/// Terminal identity retained to suppress a late or duplicate start callback.
public struct RuntimeReleasedOccurrence: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let origin: RuntimeSessionOrigin
    public let start: Date
    public let end: Date
    public let releasedAt: Date

    public init(sessionID: UUID, origin: RuntimeSessionOrigin, start: Date, end: Date, releasedAt: Date) {
        self.sessionID = sessionID
        self.origin = origin
        self.start = start
        self.end = end
        self.releasedAt = releasedAt
    }

    public func validate() throws {
        guard start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              end > start,
              releasedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RuntimeValidationError.corruptSharedData
        }
    }
}

/// A release of a scheduled occurrence is also a monotonic activation fence.
/// A replacement occurrence is suppressed when its absolute start is at or
/// before the frozen occurrence's end. This keeps edits from resurrecting the
/// released window before its natural end, while intentionally avoiding a
/// civil-day flag: after a 22:00–07:00 recovery, a genuine 22:00 occurrence
/// later on that same calendar day has a later absolute start and is allowed.
///
/// The optional year/month/day values are retained solely to decode documents
/// written by the build-3 civil-day fence. Such a legacy fence remains a
/// conservative same-day suppression until a later lifecycle write replaces
/// it with an absolute cutoff; it is never silently discarded.
public struct RuntimeScheduledActivationFence: Codable, Equatable, Sendable {
    public let notBeforeOccurrenceStart: Date?
    public let year: Int
    public let month: Int
    public let day: Int
    internal let preservesLegacyCivilDay: Bool

    public init(date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        notBeforeOccurrenceStart = date
        year = components.year ?? 0
        month = components.month ?? 0
        day = components.day ?? 0
        preservesLegacyCivilDay = false
    }

    internal init(
        notBeforeOccurrenceStart: Date?,
        year: Int,
        month: Int,
        day: Int,
        preservesLegacyCivilDay: Bool
    ) {
        self.notBeforeOccurrenceStart = notBeforeOccurrenceStart
        self.year = year
        self.month = month
        self.day = day
        self.preservesLegacyCivilDay = preservesLegacyCivilDay
    }

    /// True when this occurrence start is fenced. `matches` remains as a
    /// source-compatible name for the callback adapters.
    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let absoluteMatch: Bool
        if let cutoff = notBeforeOccurrenceStart {
            absoluteMatch = date.timeIntervalSinceReferenceDate.isFinite
                && cutoff.timeIntervalSinceReferenceDate.isFinite
                && date <= cutoff
        } else {
            absoluteMatch = false
        }
        guard preservesLegacyCivilDay else { return absoluteMatch }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return absoluteMatch || (components.year == year && components.month == month && components.day == day)
    }

    public func validate() throws {
        if let cutoff = notBeforeOccurrenceStart {
            guard cutoff.timeIntervalSinceReferenceDate.isFinite else {
                throw RuntimeValidationError.corruptSharedData
            }
        } else {
            guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
                throw RuntimeValidationError.corruptSharedData
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case notBeforeOccurrenceStart, year, month, day, preservesLegacyCivilDay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let cutoff = try container.decodeIfPresent(Date.self, forKey: .notBeforeOccurrenceStart) {
            let year = try container.decodeIfPresent(Int.self, forKey: .year) ?? 0
            let month = try container.decodeIfPresent(Int.self, forKey: .month) ?? 0
            let day = try container.decodeIfPresent(Int.self, forKey: .day) ?? 0
            self.init(notBeforeOccurrenceStart: cutoff, year: year, month: month, day: day, preservesLegacyCivilDay: try container.decodeIfPresent(Bool.self, forKey: .preservesLegacyCivilDay) ?? false)
        } else {
            // Build-3 encoded only the civil date. Preserve that meaning until
            // lifecycle code has an opportunity to write a newer absolute fence.
            self.init(
                notBeforeOccurrenceStart: nil,
                year: try container.decode(Int.self, forKey: .year),
                month: try container.decode(Int.self, forKey: .month),
                day: try container.decode(Int.self, forKey: .day),
                preservesLegacyCivilDay: true
            )
        }
        try validate()
    }
}

public typealias RuntimeSessionSnapshot = RuntimeSession

public enum RuntimeCallbackKind: Sendable {
    case start
    case end
}

/// Host-independent callback gating used by the monitor (and testable without
/// DeviceActivity). The OS remains authoritative for DST and callback timing;
/// this only rejects callbacks that are plainly outside the civil window.
public enum RuntimeScheduleDecision {
    public static func registrationMatches(configuration: RuntimeConfiguration, start: DateComponents, end: DateComponents, repeats: Bool) -> Bool {
        repeats && start.hour == configuration.start.hour && start.minute == configuration.start.minute
            && end.hour == configuration.end.hour && end.minute == configuration.end.minute
    }

    /// A manual route is safe only when DeviceActivity owns a finite,
    /// non-repeating end matching the frozen session. The shared adapter rule
    /// prevents either process from treating a stale or mismatched route as
    /// permission to shield a manual session.
    public static func manualRegistrationMatches(
        end: Date,
        intervalEnd: DateComponents,
        repeats: Bool,
        calendar: Calendar = .current
    ) -> Bool {
        guard !repeats else { return false }
        let expected = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: end)
        guard intervalEnd.hour == expected.hour,
              intervalEnd.minute == expected.minute else { return false }
        if let year = intervalEnd.year, year != expected.year { return false }
        if let month = intervalEnd.month, month != expected.month { return false }
        if let day = intervalEnd.day, day != expected.day { return false }
        return true
    }

    /// Strict one-shot registration check used by production Lock now.  The
    /// older component-only helper above remains for legacy schedule queries;
    /// a finite manual session must include an absolute calendar boundary and
    /// may differ by at most the documented component clock tolerance.
    public static func manualRegistrationMatchesExact(
        start: Date? = nil,
        end: Date,
        intervalStart: DateComponents? = nil,
        intervalEnd: DateComponents,
        repeats: Bool,
        calendar: Calendar = .current,
        tolerance: TimeInterval = 1
    ) -> Bool {
        guard !repeats, tolerance.isFinite, tolerance >= 0,
              let registeredEnd = exactDate(from: intervalEnd, calendar: calendar),
              abs(registeredEnd.timeIntervalSince(end)) <= tolerance else { return false }
        if let start {
            guard let intervalStart,
                  let registeredStart = exactDate(from: intervalStart, calendar: calendar),
                  abs(registeredStart.timeIntervalSince(start)) <= tolerance else { return false }
        }
        return true
    }

    private static func exactDate(from components: DateComponents, calendar: Calendar) -> Date? {
        guard components.year != nil,
              components.month != nil,
              components.day != nil,
              components.hour != nil,
              components.minute != nil,
              components.second != nil else { return nil }
        var components = components
        components.calendar = calendar
        return calendar.date(from: components)
    }

    public static func accepts(_ kind: RuntimeCallbackKind, configuration: RuntimeConfiguration, at date: Date, calendar: Calendar = .current) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return false }
        let occurrences = RuntimeOccurrenceResolver.candidates(
            start: configuration.start,
            end: configuration.end,
            around: date,
            calendar: calendar
        )
        switch kind {
        case .start:
            return occurrences.contains { date >= $0.start && date < $0.end }
        case .end:
            // Never let an old end callback clear a currently live occurrence.
            if occurrences.contains(where: { date >= $0.start && date < $0.end }) { return false }
            return occurrences.contains { date >= $0.end }
        }
    }
}

public enum RuntimePolicyIntent: String, Codable, Sendable {
    case apply
    case clear
}

public enum RuntimeOperation: String, Codable, Sendable {
    case configurationSaved
    case registrationAttempted
    case registrationSucceeded
    case registrationFailed
    case callbackReceived
    case policyApplyAttempted
    case policyApplied
    case policyApplyFailed
    case policyClearAttempted
    case policyCleared
    case policyClearFailed
    case conflictRejected
    case legacyMigration
    case emergencyReset
}

public struct RuntimeDiagnostic: Codable, Equatable, Sendable {
    public let operation: RuntimeOperation
    public let observedAt: Date
    public let requestedStart: RuntimeTime?
    public let requestedEnd: RuntimeTime?
    public let revision: Int?
    public let detail: String?

    public init(
        operation: RuntimeOperation,
        observedAt: Date = Date(),
        requestedStart: RuntimeTime? = nil,
        requestedEnd: RuntimeTime? = nil,
        revision: Int? = nil,
        detail: String? = nil
    ) {
        self.operation = operation
        self.observedAt = observedAt
        self.requestedStart = requestedStart
        self.requestedEnd = requestedEnd
        self.revision = revision
        self.detail = detail
    }
}

public struct RuntimeOperationStatus: Codable, Equatable, Sendable {
    public var operation: RuntimeOperation?
    public var succeeded: Bool?
    public var observedAt: Date?
    public var requestedStart: RuntimeTime?
    public var requestedEnd: RuntimeTime?
    public var revision: Int?
    public var detail: String?

    public init() {}
}

public struct RuntimeStoreDocument: Codable, Equatable, Sendable {
    public static let currentSchema = 2
    public static let maximumDiagnostics = 32

    public let schemaVersion: Int
    /// Optional for documents written before locked legacy migration existed.
    public var legacyMigrationCompleted: Bool? = false
    public var configuration: RuntimeConfiguration?
    /// A change made while one or more sessions are effective is activated only
    /// after those sessions end. The monitor never reads this for enforcement.
    public var pendingConfiguration: RuntimeConfiguration?
    /// Draft fields survive before the first successful schedule save.
    public var draft: RuntimeDraft?
    /// This is the callback gate. A late callback must not infer intent from a
    /// stale schedule or from a local app flag.
    public var recurringEnabledIntent: Bool
    public var activeOwner: RuntimeOwner?
    public var policyIntent: RuntimePolicyIntent?
    public var testLockActive: Bool
    /// Committed occurrences are the source of truth for current enforcement.
    public var sessions: [RuntimeSession]
    public var releasedOccurrences: [RuntimeReleasedOccurrence]
    /// A pending edit that becomes active while its new civil window is already
    /// open must skip that first occurrence; otherwise recovery could silently
    /// recreate a lock immediately.
    public var suppressedOccurrenceKeys: Set<String>
    /// Absolute activation fence used when a released occurrence is
    /// represented by a different pending interval after recovery or an edit.
    /// Legacy build-3 civil-day data is retained and migrated conservatively by
    /// RuntimeScheduledActivationFence's decoder.
    public var scheduledActivationFence: RuntimeScheduledActivationFence?
    /// Fixed-delay recovery target persisted in the same runtime transaction as
    /// session state. It is decoded by RecoveryCommitment's exact validator.
    public var recoveryCommitment: RecoveryCommitment?
    /// Manual DeviceActivity registration is separate from the repeating daily
    /// schedule and is never considered successful until the OS accepts it.
    public var manualRegistrationIntent: Bool
    public var manualRegistrationActive: Bool
    /// A pre-runtime schedule may still be registered in DeviceActivity, but
    /// its shield owner is unknowable. It must be surfaced and cleaned up, not
    /// treated as unlocked.
    public var legacyRegistrationNeedsReview: Bool
    public var operationStatus: RuntimeOperationStatus
    public var diagnostics: [RuntimeDiagnostic]

    public init() {
        schemaVersion = Self.currentSchema
        configuration = nil
        pendingConfiguration = nil
        draft = nil
        recurringEnabledIntent = false
        activeOwner = nil
        policyIntent = nil
        testLockActive = false
        sessions = []
        releasedOccurrences = []
        suppressedOccurrenceKeys = []
        scheduledActivationFence = nil
        recoveryCommitment = nil
        manualRegistrationIntent = false
        manualRegistrationActive = false
        legacyRegistrationNeedsReview = false
        operationStatus = RuntimeOperationStatus()
        diagnostics = []
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, legacyMigrationCompleted, configuration, pendingConfiguration, draft, recurringEnabledIntent, activeOwner, policyIntent, testLockActive, sessions, releasedOccurrences, suppressedOccurrenceKeys, scheduledActivationFence, recoveryCommitment, manualRegistrationIntent, manualRegistrationActive, legacyRegistrationNeedsReview, operationStatus, diagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchema = try container.decode(Int.self, forKey: .schemaVersion)
        guard decodedSchema <= Self.currentSchema, decodedSchema > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "Unsupported runtime document version")
        }
        schemaVersion = Self.currentSchema
        legacyMigrationCompleted = try container.decodeIfPresent(Bool.self, forKey: .legacyMigrationCompleted) ?? false
        configuration = try container.decodeIfPresent(RuntimeConfiguration.self, forKey: .configuration)
        pendingConfiguration = try container.decodeIfPresent(RuntimeConfiguration.self, forKey: .pendingConfiguration)
        draft = try container.decodeIfPresent(RuntimeDraft.self, forKey: .draft)
        recurringEnabledIntent = try container.decodeIfPresent(Bool.self, forKey: .recurringEnabledIntent) ?? false
        activeOwner = try container.decodeIfPresent(RuntimeOwner.self, forKey: .activeOwner)
        policyIntent = try container.decodeIfPresent(RuntimePolicyIntent.self, forKey: .policyIntent)
        testLockActive = try container.decodeIfPresent(Bool.self, forKey: .testLockActive) ?? false
        sessions = try container.decodeIfPresent([RuntimeSession].self, forKey: .sessions) ?? []
        releasedOccurrences = try container.decodeIfPresent([RuntimeReleasedOccurrence].self, forKey: .releasedOccurrences) ?? []
        suppressedOccurrenceKeys = try container.decodeIfPresent(Set<String>.self, forKey: .suppressedOccurrenceKeys) ?? []
        scheduledActivationFence = try container.decodeIfPresent(RuntimeScheduledActivationFence.self, forKey: .scheduledActivationFence)
        recoveryCommitment = try container.decodeIfPresent(RecoveryCommitment.self, forKey: .recoveryCommitment)
        manualRegistrationIntent = try container.decodeIfPresent(Bool.self, forKey: .manualRegistrationIntent) ?? false
        manualRegistrationActive = try container.decodeIfPresent(Bool.self, forKey: .manualRegistrationActive) ?? false
        legacyRegistrationNeedsReview = try container.decodeIfPresent(Bool.self, forKey: .legacyRegistrationNeedsReview) ?? false
        operationStatus = try container.decodeIfPresent(RuntimeOperationStatus.self, forKey: .operationStatus) ?? RuntimeOperationStatus()
        diagnostics = try container.decodeIfPresent([RuntimeDiagnostic].self, forKey: .diagnostics) ?? []
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .sessions, in: container, debugDescription: "Invalid runtime document invariants")
        }
    }

    public mutating func record(_ diagnostic: RuntimeDiagnostic, succeeded: Bool? = nil) {
        diagnostics.append(diagnostic)
        if diagnostics.count > Self.maximumDiagnostics {
            diagnostics.removeFirst(diagnostics.count - Self.maximumDiagnostics)
        }
        operationStatus.operation = diagnostic.operation
        operationStatus.succeeded = succeeded
        operationStatus.observedAt = diagnostic.observedAt
        operationStatus.requestedStart = diagnostic.requestedStart
        operationStatus.requestedEnd = diagnostic.requestedEnd
        operationStatus.revision = diagnostic.revision
        operationStatus.detail = diagnostic.detail
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchema else {
            throw RuntimeValidationError.corruptSharedData
        }
        if let configuration {
            try configuration.validate()
        } else if recurringEnabledIntent || activeOwner == .scheduled {
            throw RuntimeValidationError.corruptSharedData
        }
        if let pendingConfiguration {
            try pendingConfiguration.validate()
            if let configuration, pendingConfiguration.revision <= configuration.revision {
                throw RuntimeValidationError.corruptSharedData
            }
        }
        if let draft {
            try draft.start.validate()
            try draft.end.validate()
            try draft.selectionSummary.validateCounts()
            guard !draft.selectionData.isEmpty else { throw RuntimeValidationError.corruptSharedData }
        }
        guard sessions.count <= 64, releasedOccurrences.count <= 64,
              suppressedOccurrenceKeys.count <= 64,
              diagnostics.count <= Self.maximumDiagnostics else {
            throw RuntimeValidationError.corruptSharedData
        }
        var ids = Set<UUID>()
        var keys = Set<String>()
        for session in sessions {
            try session.validate()
            guard ids.insert(session.id).inserted, keys.insert(session.occurrenceKey).inserted else {
                throw RuntimeValidationError.corruptSharedData
            }
        }
        var releasedIDs = Set<UUID>()
        for occurrence in releasedOccurrences {
            try occurrence.validate()
            guard releasedIDs.insert(occurrence.sessionID).inserted else { throw RuntimeValidationError.corruptSharedData }
        }
        for session in sessions where session.state == .released {
            guard releasedIDs.contains(session.id) else { throw RuntimeValidationError.corruptSharedData }
        }
        try scheduledActivationFence?.validate()

        // Recovery is a relationship between the immutable request and the
        // session states, not merely a set of UUIDs. Expired natural targets
        // are deliberately retained in the request until the next transaction
        // normalizes it; wall-clock age alone must not make a valid document
        // undecodable.
        let pendingIDs = Set(sessions.filter { $0.state == .recoveryPending }.map(\.id))
        if let recoveryCommitment {
            let targetIDs = recoveryCommitment.sessionIDs
            guard !targetIDs.isEmpty, targetIDs.isSubset(of: ids) else {
                throw RuntimeValidationError.corruptSharedData
            }
            let targets = sessions.filter { targetIDs.contains($0.id) }
            // The request must have been made while every target was a valid
            // current occurrence. This is checked against persisted request
            // time, not wall-clock `now`, so a naturally stale target remains
            // decodable until lifecycle normalization clears it.
            guard targets.allSatisfy({ $0.start <= recoveryCommitment.requestedAt && recoveryCommitment.requestedAt < $0.end }) else {
                throw RuntimeValidationError.corruptSharedData
            }
            let targetEffectiveIDs = Set(targets.filter { $0.isEffective }.map(\.id))
            guard pendingIDs == targetEffectiveIDs,
                  sessions.filter({ targetIDs.contains($0.id) }).allSatisfy({ $0.state != .released }) else {
                throw RuntimeValidationError.corruptSharedData
            }
        } else if !pendingIDs.isEmpty {
            throw RuntimeValidationError.corruptSharedData
        }
        guard !(testLockActive && activeOwner != .prototypeTest),
              !(testLockActive && !sessions.isEmpty),
              !(testLockActive && recurringEnabledIntent),
              !(activeOwner == .prototypeTest && recurringEnabledIntent),
              // A clear intent with no remaining session is a valid durable
              // cleanup request (for example a stale callback on an empty
              // store). Only an orphan apply could create an unbounded shield.
              !(policyIntent == .apply && activeOwner == nil && sessions.isEmpty) else {
            throw RuntimeValidationError.corruptSharedData
        }
    }

    public func effectiveSessions(at date: Date) -> [RuntimeSession] {
        sessions.filter { $0.isEffective(at: date) }
    }
}