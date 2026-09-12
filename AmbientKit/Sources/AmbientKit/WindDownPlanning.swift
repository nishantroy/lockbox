import Foundation

/// The local civil time at which a bedtime session begins.
public struct AmbientLocalTime: Codable, Equatable, Hashable, Sendable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) throws {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else {
            throw WindDownPlanningError.invalidLocalTime(hour: hour, minute: minute)
        }
        self.hour = hour
        self.minute = minute
    }
}

/// A lead time is deliberately bounded so an accidental value cannot fill the
/// notification queue with a far-future or effectively continuous schedule.
public struct WindDownLeadOffset: Codable, Equatable, Hashable, Sendable {
    public static let maximumSeconds: TimeInterval = 24 * 60 * 60
    public let seconds: TimeInterval

    public init(seconds: TimeInterval) throws {
        guard seconds.isFinite, seconds.rounded() == seconds, seconds > 0, seconds <= Self.maximumSeconds else {
            throw WindDownPlanningError.invalidLeadOffset(seconds: seconds)
        }
        self.seconds = seconds
    }

    public init(minutes: Int) throws {
        try self.init(seconds: TimeInterval(minutes) * 60)
    }
}

/// Configuration is intentionally independent of the lockbox runtime store.
/// The host supplies a Calendar so time-zone and DST behavior is explicit.
public struct WindDownConfiguration: Codable, Equatable, Sendable {
    public static let maximumScheduledOccurrences = 7

    public var enabled: Bool
    public var bedtime: AmbientLocalTime
    public var lead: WindDownLeadOffset

    public init(
        enabled: Bool = false,
        bedtime: AmbientLocalTime,
        lead: WindDownLeadOffset
    ) {
        self.enabled = enabled
        self.bedtime = bedtime
        self.lead = lead
    }
}

/// A concrete occurrence, rather than a repeating notification rule.
public struct WindDownOccurrence: Equatable, Sendable {
    public let identifier: String
    public let intendedLocalDate: Date
    public let bedtime: Date
    public let triggerDate: Date
    public let triggerComponents: DateComponents

    public init(
        identifier: String,
        intendedLocalDate: Date,
        bedtime: Date,
        triggerDate: Date,
        triggerComponents: DateComponents
    ) {
        self.identifier = identifier
        self.intendedLocalDate = intendedLocalDate
        self.bedtime = bedtime
        self.triggerDate = triggerDate
        self.triggerComponents = triggerComponents
    }
}

/// Optional context supplied by the host when a lock is already active.
/// Wind-down is informational; it must not enqueue a late heads-up for a
/// session that is already in force.
public struct AmbientSessionBoundary: Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) throws {
        guard start < end else {
            throw WindDownPlanningError.invalidSessionBoundary
        }
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool {
        start <= date && date < end
    }
}

public enum WindDownPlanningError: Error, Equatable, Sendable {
    case invalidLocalTime(hour: Int, minute: Int)
    case invalidLeadOffset(seconds: TimeInterval)
    case invalidSessionBoundary
    case invalidLimit
    case unableToConstructCivilDate
}

public enum WindDownPlanner {
    /// Plans only concrete future triggers. `calendar` is the source of truth
    /// for civil dates and its time zone is carried into triggerComponents.
    public static func plan(
        configuration: WindDownConfiguration,
        now: Date,
        calendar: Calendar,
        activeSession: AmbientSessionBoundary? = nil,
        limit requestedLimit: Int = WindDownConfiguration.maximumScheduledOccurrences
    ) throws -> [WindDownOccurrence] {
        guard requestedLimit > 0 else { throw WindDownPlanningError.invalidLimit }
        guard configuration.enabled else { return [] }

        let limit = min(requestedLimit, WindDownConfiguration.maximumScheduledOccurrences)
        let startOfToday = calendar.startOfDay(for: now)
        var day = startOfToday
        var result: [WindDownOccurrence] = []
        var seenIdentifiers = Set<String>()

        // Seven occurrences plus a small civil-date cushion is ample even for
        // a skipped day/time-zone transition. This is not a timer or a retry.
        for _ in 0..<370 where result.count < limit {
            let dayComponents = calendar.dateComponents([.era, .year, .month, .day], from: day)
            var bedtimeComponents = dayComponents
            bedtimeComponents.hour = configuration.bedtime.hour
            bedtimeComponents.minute = configuration.bedtime.minute
            bedtimeComponents.second = 0
            bedtimeComponents.nanosecond = 0
            bedtimeComponents.timeZone = calendar.timeZone

            guard let bedtime = calendar.date(from: bedtimeComponents) else {
                throw WindDownPlanningError.unableToConstructCivilDate
            }
            guard let triggerDate = calendar.date(
                byAdding: .second,
                value: -Int(configuration.lead.seconds.rounded()),
                to: bedtime
            ) else {
                throw WindDownPlanningError.unableToConstructCivilDate
            }

            let isAlreadyActive = activeSession.map { session in
                session.contains(now) && triggerDate < session.end
            } ?? false
            let isUpcoming = triggerDate > now
            if isUpcoming && !isAlreadyActive {
                let id = identifier(for: dayComponents, bedtime: configuration.bedtime)
                if seenIdentifiers.insert(id).inserted {
                    var triggerComponents = calendar.dateComponents(
                        [.era, .year, .month, .day, .hour, .minute, .second],
                        from: triggerDate
                    )
                    triggerComponents.timeZone = calendar.timeZone
                    result.append(
                        WindDownOccurrence(
                            identifier: id,
                            intendedLocalDate: day,
                            bedtime: bedtime,
                            triggerDate: triggerDate,
                            triggerComponents: triggerComponents
                        )
                    )
                }
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                throw WindDownPlanningError.unableToConstructCivilDate
            }
            day = nextDay
        }

        return result
    }

    private static func identifier(
        for components: DateComponents,
        bedtime: AmbientLocalTime
    ) -> String {
        let year = components.year ?? 0
        let month = String(format: "%02d", components.month ?? 0)
        let day = String(format: "%02d", components.day ?? 0)
        let hour = String(format: "%02d", bedtime.hour)
        let minute = String(format: "%02d", bedtime.minute)
        return "\(WindDownNotificationNamespace.prefix)\(year)-\(month)-\(day)-\(hour)-\(minute)"
    }
}

public enum WindDownNotificationNamespace {
    public static let prefix = "com.phone-lockbox.ambient.wind-down."
}

/// Pure bookkeeping used by the native adapter before touching UNUserNotificationCenter.
/// All IDs outside this namespace are retained by the caller.
public struct WindDownNotificationReplacement: Equatable, Sendable {
    public let removeIdentifiers: [String]
    public let addIdentifiers: [String]

    public init(existingPendingIdentifiers: [String], occurrences: [WindDownOccurrence]) throws {
        guard occurrences.count <= WindDownConfiguration.maximumScheduledOccurrences else {
            throw WindDownPlanningError.invalidLimit
        }
        let addIdentifiers = occurrences.map(\.identifier)
        guard Set(addIdentifiers).count == addIdentifiers.count else {
            throw WindDownPlanningError.invalidLimit
        }
        self.removeIdentifiers = existingPendingIdentifiers
            .filter { $0.hasPrefix(WindDownNotificationNamespace.prefix) }
            .sorted()
        self.addIdentifiers = addIdentifiers
    }
}
