import Foundation

/// Pure lifecycle decisions shared by the app and DeviceActivity adapter.
/// Managed Settings is intentionally outside this file.
public enum RuntimeSessionDecision {
    public static func activeSessions(_ sessions: [RuntimeSession], at date: Date) -> [RuntimeSession] {
        sessions.filter { $0.isEffective(at: date) }
    }

    public static func matchingScheduledOccurrence(
        sessions: [RuntimeSession],
        start: Date,
        end: Date
    ) -> RuntimeSession? {
        sessions.first {
            $0.origin == .scheduled && $0.start == start && $0.end == end
        }
    }

    public static func matchingManualSession(sessions: [RuntimeSession]) -> RuntimeSession? {
        sessions.first { $0.origin == .manual && $0.isEffective }
    }

    public static func isReleased(
        sessions: [RuntimeSession],
        releasedOccurrences: [RuntimeReleasedOccurrence],
        origin: RuntimeSessionOrigin,
        start: Date,
        end: Date
    ) -> Bool {
        sessions.contains { $0.origin == origin && $0.start == start && $0.end == end && $0.state == .released }
            || releasedOccurrences.contains { $0.origin == origin && $0.start == start && $0.end == end }
    }

    /// The MVP can safely compose restrictions from same-mode sessions. A
    /// mixed block/allow union is rejected rather than allowing an assignment
    /// to silently replace a stronger restriction.
    public static func composedMode(for sessions: [RuntimeSession]) throws -> RuntimeMode? {
        let modes = Set(sessions.map { $0.policy.mode })
        guard modes.count <= 1 else { throw RuntimeValidationError.overlapUnsupported }
        return modes.first
    }

    public static func shouldRelease(_ session: RuntimeSession, at date: Date) -> Bool {
        date >= session.end || session.state == .released || session.state == .expired
    }

    public static func occurrenceKey(origin: RuntimeSessionOrigin, start: Date, end: Date) -> String {
        "\(origin.rawValue):\(start.timeIntervalSinceReferenceDate):\(end.timeIntervalSinceReferenceDate)"
    }
}
