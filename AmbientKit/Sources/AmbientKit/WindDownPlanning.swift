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
    public let bedtimeComponents: DateComponents
    public let triggerComponents: DateComponents

    public init(
        identifier: String,
        intendedLocalDate: Date,
        bedtime: Date,
        triggerDate: Date,
        bedtimeComponents: DateComponents = DateComponents(),
        triggerComponents: DateComponents
    ) {
        self.identifier = identifier
        self.intendedLocalDate = intendedLocalDate
        self.bedtime = bedtime
        self.triggerDate = triggerDate
        self.bedtimeComponents = bedtimeComponents
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
    case insufficientQueueCapacity(available: Int, requested: Int)
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
                    var plannedBedtimeComponents = calendar.dateComponents(
                        [.era, .year, .month, .day, .hour, .minute, .second],
                        from: bedtime
                    )
                    plannedBedtimeComponents.calendar = calendar
                    plannedBedtimeComponents.timeZone = calendar.timeZone
                    var triggerComponents = calendar.dateComponents(
                        [.era, .year, .month, .day, .hour, .minute, .second],
                        from: triggerDate
                    )
                    triggerComponents.calendar = calendar
                    triggerComponents.timeZone = calendar.timeZone
                    result.append(
                        WindDownOccurrence(
                            identifier: id,
                            intendedLocalDate: day,
                            bedtime: bedtime,
                            triggerDate: triggerDate,
                            bedtimeComponents: plannedBedtimeComponents,
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

/// The exact user-facing copy for one concrete local reminder. It is derived
/// from the occurrence's resolved dates, never from a second bedtime setting.
public struct WindDownNotificationContent: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(
        occurrence: WindDownOccurrence,
        locale: Locale = .current
    ) throws {
        let leadSeconds = occurrence.bedtime.timeIntervalSince(occurrence.triggerDate)
        guard leadSeconds.isFinite,
              leadSeconds >= 60,
              leadSeconds <= WindDownLeadOffset.maximumSeconds,
              leadSeconds.rounded() == leadSeconds else {
            throw WindDownPlanningError.invalidLeadOffset(seconds: leadSeconds)
        }
        let leadMinutes = Int((leadSeconds / 60).rounded())
        guard leadMinutes > 0 else {
            throw WindDownPlanningError.invalidLeadOffset(seconds: leadSeconds)
        }

        var calendar = occurrence.bedtimeComponents.calendar ?? Calendar(identifier: .gregorian)
        if let timeZone = occurrence.bedtimeComponents.timeZone {
            calendar.timeZone = timeZone
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let localBedtime = formatter.string(from: occurrence.bedtime)

        title = "Bedtime in \(leadMinutes) minutes"
        body = "Lockbox starts at \(localBedtime)."
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

    public let availableSlots: Int

    public init(
        existingPendingIdentifiers: [String],
        occurrences: [WindDownOccurrence],
        systemLimit: Int = 64
    ) throws {
        try self.init(
            existingPendingIdentifiers: existingPendingIdentifiers,
            newIdentifiers: occurrences.map(\.identifier),
            systemLimit: systemLimit
        )
    }

    public init(
        existingPendingIdentifiers: [String],
        newIdentifiers: [String],
        systemLimit: Int = 64
    ) throws {
        guard newIdentifiers.count <= WindDownConfiguration.maximumScheduledOccurrences,
              systemLimit > 0 else {
            throw WindDownPlanningError.invalidLimit
        }
        let addIdentifiers = newIdentifiers
        guard Set(addIdentifiers).count == addIdentifiers.count,
              addIdentifiers.allSatisfy({ $0.hasPrefix(WindDownNotificationNamespace.prefix) }) else {
            throw WindDownPlanningError.invalidLimit
        }

        let owned = existingPendingIdentifiers.filter {
            $0.hasPrefix(WindDownNotificationNamespace.prefix)
        }
        let availableSlots = systemLimit - (existingPendingIdentifiers.count - owned.count)
        guard availableSlots >= addIdentifiers.count else {
            throw WindDownPlanningError.insufficientQueueCapacity(
                available: max(0, availableSlots),
                requested: addIdentifiers.count
            )
        }

        self.removeIdentifiers = owned.sorted()
        self.addIdentifiers = addIdentifiers
        self.availableSlots = availableSlots
    }
}

/// The host-facing result of a replacement transaction. A failure during
/// `add` is reported rather than being disguised as a successful replacement.
public enum WindDownReplacementOutcome: Equatable, Sendable {
    case replaced(count: Int)
    case failed(
        requestedCount: Int,
        addedCount: Int,
        previousScheduleRestored: Bool
    )
}

/// Minimal store contract shared by the native adapter and host fake-center
/// tests. The transaction removes only the owned namespace, checks capacity
/// before removing anything, and restores the old requests after an add fails.
public protocol WindDownNotificationStore {
    associatedtype Request: Sendable

    func pendingRequests() async -> [Request]
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async
    func add(_ request: Request) async throws
}

public enum WindDownNotificationReplacementEngine {
    public static let systemPendingRequestLimit = 64

    public static func replace<Store: WindDownNotificationStore>(
        store: Store,
        requests: [Store.Request],
        identifier: (Store.Request) -> String,
        systemLimit: Int = systemPendingRequestLimit
    ) async throws -> WindDownReplacementOutcome {
        let pending = await store.pendingRequests()
        let plan = try WindDownNotificationReplacement(
            existingPendingIdentifiers: pending.map(identifier),
            newIdentifiers: requests.map(identifier),
            systemLimit: systemLimit
        )

        let ownedRequests = pending.filter {
            identifier($0).hasPrefix(WindDownNotificationNamespace.prefix)
        }
        await store.removePendingNotificationRequests(withIdentifiers: plan.removeIdentifiers)

        var added = 0
        do {
            for request in requests {
                try await store.add(request)
                added += 1
            }
            return .replaced(count: added)
        } catch {
            let addedIDs = requests.prefix(added).map(identifier)
            await store.removePendingNotificationRequests(withIdentifiers: addedIDs)

            var restored = true
            for request in ownedRequests {
                do {
                    try await store.add(request)
                } catch {
                    restored = false
                    break
                }
            }
            return .failed(
                requestedCount: requests.count,
                addedCount: added,
                previousScheduleRestored: restored
            )
        }
    }
}
