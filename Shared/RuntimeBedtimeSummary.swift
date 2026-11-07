import Foundation

/// Plain-language descriptions of the recurring bedtime window, shared by the
/// Lockbox tab, Settings and the bedtime editor. Pure: no runtime state.
public enum RuntimeBedtimeSummary {
    public static let minimumWindowMinutes = RuntimeConfiguration.minimumWindowMinutes

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

    /// The end of the occurrence that is in progress at `now`, or nil when
    /// `now` is outside the window (or the window is empty).
    public static func inProgressEnd(
        start: RuntimeTime,
        end: RuntimeTime,
        at now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard let occurrence = RuntimeOccurrenceResolver.currentOrNext(start: start, end: end, enabled: true, after: now, calendar: calendar),
              occurrence.start <= now, now < occurrence.end else { return nil }
        return occurrence.end
    }
}

/// Why the bedtime editor can't save the current combination, if it can't.
public enum RuntimeBedtimeEditBlock: Equatable, Sendable {
    /// Bedtime can only be turned on once the current lock has ended.
    case turnOnAfterLock
    /// Bedtime can't be turned off while its window is running.
    case turnOffDuringWindow

    public var message: String {
        switch self {
        case .turnOnAfterLock: return "Turn bedtime on after this lock ends."
        case .turnOffDuringWindow: return "Bedtime has started. You can turn it off after it ends."
        }
    }

    public static func evaluate(isOn: Bool, wasOn: Bool, locked: Bool, savedWindowInProgress: Bool) -> RuntimeBedtimeEditBlock? {
        if isOn && !wasOn && locked { return .turnOnAfterLock }
        if !isOn && wasOn && savedWindowInProgress { return .turnOffDuringWindow }
        return nil
    }

    /// Something differs from what is saved. Times only count while on.
    public static func hasChanges(isOn: Bool, wasOn: Bool, start: RuntimeTime, end: RuntimeTime, savedStart: RuntimeTime, savedEnd: RuntimeTime) -> Bool {
        isOn != wasOn || (isOn && (start != savedStart || end != savedEnd))
    }
}

/// What a save or stop actually did.
public enum RuntimeSaveOutcome: Equatable, Sendable {
    /// Applied now.
    case saved
    /// Validated and held until the current lock ends.
    case queued
    case failed

    /// The editor closes only when the change is in place or safely queued.
    public var closesEditor: Bool { self != .failed }
}

public extension RuntimeStoreDocument {
    /// The configuration the user most recently saved: a queued change wins
    /// over the one currently applied.
    var effectiveConfiguration: RuntimeConfiguration? { pendingConfiguration ?? configuration }
}
