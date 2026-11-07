import Foundation

/// Pure logic behind the one-tap Lock now on the Open screen: which end is
/// shown, whether it is still safe to submit, and whether a saved bedtime
/// would extend it. The same `Date` that is shown is the one submitted.
public enum RuntimeLockNowEnd {
    public enum Preset: Sendable {
        case thirtyMinutes
        case oneHour

        public var duration: TimeInterval {
            switch self {
            case .thirtyMinutes: return 30 * 60
            case .oneHour: return 60 * 60
            }
        }
    }

    /// The displayed end must still be valid this long after `now`, because
    /// the clock keeps running between the minute tick and the tap.
    public static let staleMargin: TimeInterval = 60

    /// The end to show and submit, or nil when it is unavailable or would
    /// already be rejected a minute from `now`. Pass `preset` for a preset
    /// or nil with `customEnd` for a custom end.
    public static func displayedEnd(preset: Preset?, customEnd: Date?, now: Date) -> Date? {
        let end: Date?
        if let preset {
            end = RuntimeManualLockDecision.proposedEnd(after: preset.duration, at: now)
        } else {
            end = customEnd
        }
        guard let end,
              RuntimeManualLockDecision.accepts(expectedEnd: end, startedAt: now.addingTimeInterval(staleMargin)) else {
            return nil
        }
        return end
    }

    /// Reference date for the custom-end picker range: one minute later than
    /// the clock so every selectable end passes `displayedEnd`.
    public static func pickerReference(at date: Date) -> Date {
        date.addingTimeInterval(staleMargin)
    }

    public struct BedtimeOverlap: Equatable, Sendable {
        public let bedtimeStart: Date
        public let effectiveEnd: Date
    }

    /// A saved bedtime that begins during the lock and ends after it, so the
    /// phone stays locked past the shown end. A lock that ends exactly when
    /// bedtime starts does not overlap. Nil when bedtime is off or unset.
    public static func bedtimeOverlap(
        schedule: (start: RuntimeTime, end: RuntimeTime)?,
        enabled: Bool,
        lockEnd: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> BedtimeOverlap? {
        guard enabled, let schedule else { return nil }
        let overlaps = RuntimeManualLockDecision.overlappingScheduledOccurrences(
            start: schedule.start,
            end: schedule.end,
            intervalStart: now,
            intervalEnd: lockEnd,
            calendar: calendar
        )
        guard let occurrence = overlaps.first(where: { $0.start > now && $0.start < lockEnd && $0.end > lockEnd }) else {
            return nil
        }
        return BedtimeOverlap(bedtimeStart: occurrence.start, effectiveEnd: occurrence.end)
    }

    /// Chip text for a custom end: the time alone, plus a short weekday when
    /// the end is more than a day away ("12:15 AM", "Sat 7:00 AM").
    public static func chipTime(
        _ end: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = end.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        guard end.timeIntervalSince(now) > 24 * 60 * 60 else { return time }
        let weekday = end.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
        return "\(weekday) \(time)"
    }
}
