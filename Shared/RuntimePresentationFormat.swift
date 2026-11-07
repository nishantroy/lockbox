import Foundation

/// Short, calm time strings for the ordinary UI. Pure Foundation so it can be
/// unit-tested with a fixed calendar and locale.
///
/// Day rule: today is the time alone; tomorrow and yesterday are named; two to
/// five days ahead use the weekday; everything else (six or more days ahead,
/// or any earlier day) uses a short date so it is never ambiguous.
public enum RuntimeTimeFormat {
    public enum Style: Sendable {
        /// "10:00 PM", "Tomorrow 7:00 AM", "Sat 7:00 AM", "Fri, Nov 13, 3:00 PM".
        case standalone
        /// Mid-sentence after a verb like "until": "7:00 AM", "tomorrow at 7:00 AM".
        case phrase
        /// Mid-sentence where "at" is needed: "at 7:00 AM", "tomorrow at 7:00 AM".
        case atPhrase
    }

    public static func string(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        style: Style = .standalone
    ) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0

        let day: String?
        switch days {
        case 0: day = nil
        case 1: day = style == .standalone ? "Tomorrow" : "tomorrow"
        case -1: day = style == .standalone ? "Yesterday" : "yesterday"
        case 2...5:
            day = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
        default:
            day = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated).month(.abbreviated).day())
        }

        switch (style, day) {
        case (.standalone, nil): return time
        case (.phrase, nil): return time
        case (.atPhrase, nil): return "at \(time)"
        case (.standalone, let day?):
            // Short dates read "Fri, Nov 13, 3:00 PM"; named days read "Tomorrow 7:00 AM".
            return days >= 6 || days < -1 ? "\(day), \(time)" : "\(day) \(time)"
        case (_, let day?): return "\(day) at \(time)"
        }
    }
}

/// How the active lock is described on the Lockbox tab, derived from session
/// origins and purposes rather than title strings.
public enum RuntimeActiveLockDisplay: Equatable, Sendable {
    case scheduledBedtime
    case manualBedtime
    case focus
    case bedtimeAndFocus

    /// Small label above the time hero.
    public var label: String {
        switch self {
        case .scheduledBedtime, .manualBedtime: return "Bedtime"
        case .focus: return "Focus"
        case .bedtimeAndFocus: return "Bedtime + Focus"
        }
    }

    /// Bedtime is the governing (longer) lock whenever it is present.
    public var isBedtime: Bool { self != .focus }

    public var originCopy: String {
        switch self {
        case .scheduledBedtime: return "Scheduled bedtime"
        case .manualBedtime: return "You started bedtime"
        case .focus: return "You started focus"
        case .bedtimeAndFocus: return "Bedtime and focus overlap"
        }
    }

    public static func display(for sessions: [RuntimeSession]) -> RuntimeActiveLockDisplay? {
        func isBedtime(_ s: RuntimeSession) -> Bool { s.purpose == .bedtime || s.origin == .scheduled }
        let bedtime = sessions.filter(isBedtime)
        let hasFocus = sessions.contains { !isBedtime($0) }
        switch (bedtime.isEmpty, hasFocus) {
        case (true, false): return nil
        case (true, true): return .focus
        case (false, true): return .bedtimeAndFocus
        case (false, false):
            return bedtime.contains { $0.origin == .scheduled } ? .scheduledBedtime : .manualBedtime
        }
    }
}
