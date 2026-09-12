import Foundation

/// The single local-time occurrence resolver used by the app and the monitor.
/// Occurrences are half-open: [start, end).  A skipped civil boundary uses the
/// next valid instant and a repeated boundary uses its first occurrence.
public enum RuntimeOccurrenceResolver {
    public typealias Occurrence = (start: Date, end: Date)

    public static func currentOrNext(
        start: RuntimeTime,
        end: RuntimeTime,
        enabled: Bool,
        after date: Date,
        calendar: Calendar = .current
    ) -> Occurrence? {
        guard enabled, start != end, date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return candidates(start: start, end: end, around: date, calendar: calendar)
            .first { occurrence in
                (date >= occurrence.start && date < occurrence.end) || occurrence.start >= date
            }
    }

    /// Includes the previous occurrence so an end callback at the boundary can
    /// be distinguished from an old callback for an occurrence that is live now.
    public static func candidates(
        start: RuntimeTime,
        end: RuntimeTime,
        around date: Date,
        calendar: Calendar = .current
    ) -> [Occurrence] {
        guard start != end, date.timeIntervalSinceReferenceDate.isFinite else { return [] }
        let day = calendar.startOfDay(for: date)
        let overnight = start.minutesSinceMidnight > end.minutesSinceMidnight
        return (-3...3).compactMap { offset in
            guard let occurrenceDay = calendar.date(byAdding: .day, value: offset, to: day),
                  let startDate = boundary(start, on: occurrenceDay, calendar: calendar) else { return nil }
            let endDay = overnight ? calendar.date(byAdding: .day, value: 1, to: occurrenceDay) : occurrenceDay
            guard let endDay,
                  let endDate = boundary(end, on: endDay, calendar: calendar),
                  endDate > startDate else { return nil }
            return (start: startDate, end: endDate)
        }.sorted { $0.start < $1.start }
    }

    public static func matches(
        _ occurrence: Occurrence,
        start: RuntimeTime,
        end: RuntimeTime,
        calendar: Calendar = .current
    ) -> Bool {
        candidates(start: start, end: end, around: occurrence.start, calendar: calendar).contains {
            $0.start == occurrence.start && $0.end == occurrence.end
        }
    }

    private static func boundary(_ time: RuntimeTime, on day: Date, calendar: Calendar) -> Date? {
        let dayStart = calendar.startOfDay(for: day)
        guard let value = calendar.nextDate(
            after: dayStart.addingTimeInterval(-1),
            matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else { return nil }
        return calendar.isDate(value, inSameDayAs: dayStart) ? value : nil
    }
}

private extension RuntimeTime {
    var minutesSinceMidnight: Int { hour * 60 + minute }
}
