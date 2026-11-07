import Foundation

/// Plain-language descriptions of the recurring bedtime window, shared by the
/// Lockbox tab, Settings and the bedtime editor. Pure: no runtime state.
public enum RuntimeBedtimeSummary {
    public static let minimumWindowMinutes = 15

    /// "9:30 PM" for a civil time of day.
    public static func time(
        _ time: RuntimeTime,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let date = calendar.date(from: DateComponents(hour: time.hour, minute: time.minute)) ?? Date(timeIntervalSinceReferenceDate: 0)
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    /// "9:30 PM – 8:05 AM".
    public static func window(
        start: RuntimeTime,
        end: RuntimeTime,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        "\(time(start, calendar: calendar, locale: locale)) – \(time(end, calendar: calendar, locale: locale))"
    }

    /// "Every day · locks 9:30 PM, opens 8:05 AM".
    public static func summary(
        start: RuntimeTime,
        end: RuntimeTime,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        "Every day · locks \(time(start, calendar: calendar, locale: locale)), opens \(time(end, calendar: calendar, locale: locale))"
    }

    /// Minutes from start to end, wrapping past midnight (a same-day window
    /// such as 1:00 PM to 3:00 PM is 120; 9:30 PM to 8:05 AM is 635).
    /// Equal times are a zero-length window.
    public static func durationMinutes(start: RuntimeTime, end: RuntimeTime) -> Int {
        let difference = (end.hour * 60 + end.minute) - (start.hour * 60 + start.minute)
        if difference == 0 { return 0 }
        return difference > 0 ? difference : difference + 24 * 60
    }

    public static func crossesMidnight(start: RuntimeTime, end: RuntimeTime) -> Bool {
        (end.hour * 60 + end.minute) < (start.hour * 60 + start.minute)
    }

    /// Inline message when the window can't be saved; nil when it is valid.
    public static func validationMessage(start: RuntimeTime, end: RuntimeTime) -> String? {
        if start == end { return "Choose different start and end times." }
        if durationMinutes(start: start, end: end) < minimumWindowMinutes {
            return "Bedtime needs to last at least \(minimumWindowMinutes) minutes."
        }
        return nil
    }
}
