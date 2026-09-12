import Foundation

/// Status wording deliberately distinguishes a plan from observed Managed
/// Settings state. There is no generic "unlocked" or "success" state.
public enum AmbientLiveActivityStatus: String, Codable, Hashable, Sendable {
    case plannedSession
    case recoveryPending
    case releaseObserved
    case expired
    case stale

    public var accessibilityLabel: String {
        switch self {
        case .plannedSession: return "Planned session; enforcement is not independently verified"
        case .recoveryPending: return "Recovery requested; release is not yet observed"
        case .releaseObserved: return "Release observed"
        case .expired: return "Session end reached; release is not independently verified"
        case .stale: return "Status stale; open Phone Lockbox to reconcile"
        }
    }
}

public struct AmbientActivityContentState: Codable, Hashable, Sendable {
    public let fixedEnd: Date
    public let status: AmbientLiveActivityStatus

    public init(fixedEnd: Date, status: AmbientLiveActivityStatus) {
        self.fixedEnd = fixedEnd
        self.status = status
    }

    /// This is a foreground/manual reconciliation helper, not a countdown or
    /// a background timer. At the committed end we stop claiming freshness.
    public func staleIfNeeded(at now: Date) -> AmbientActivityContentState {
        guard now >= fixedEnd else { return self }
        switch status {
        case .releaseObserved, .expired, .stale:
            return self
        case .plannedSession, .recoveryPending:
            return AmbientActivityContentState(fixedEnd: fixedEnd, status: .stale)
        }
    }
}

/// The Activity attributes are also useful to host tests and do not depend on
/// ActivityKit. The iOS adapter conditionally adds ActivityAttributes below.
public struct AmbientLiveActivityAttributes: Codable, Hashable, Sendable {
    public let sessionID: String
    public let fixedEnd: Date

    public init(sessionID: String, fixedEnd: Date) {
        self.sessionID = sessionID
        self.fixedEnd = fixedEnd
    }
}

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

@available(iOS 17.0, *)
extension AmbientLiveActivityAttributes: ActivityAttributes {
    public typealias ContentState = AmbientActivityContentState
}
#endif

public enum AmbientLiveActivityUnavailableReason: String, Codable, Hashable, Sendable {
    case userDisabled
    case platformUnavailable
    case noMatchingActivity
    case fixedEndPast
}

public enum AmbientLiveActivityLifetime: String, Codable, Hashable, Sendable {
    case withinPlatformWindow
    case mayBecomeStaleAfterEightHours
}

public enum AmbientLiveActivityOutcome: Equatable, Sendable {
    case started(lifetime: AmbientLiveActivityLifetime)
    case updated
    case ended
    case unavailable(AmbientLiveActivityUnavailableReason)
    case failed(String)
}

public enum AmbientLiveActivityPolicy {
    /// Apple limits an active Live Activity to about eight hours, with a
    /// shorter Lock Screen presentation after that. It is informational only.
    public static let maximumActiveSeconds: TimeInterval = 8 * 60 * 60

    public static func lifetime(for fixedEnd: Date, now: Date) -> AmbientLiveActivityLifetime {
        fixedEnd.timeIntervalSince(now) <= maximumActiveSeconds
            ? .withinPlatformWindow
            : .mayBecomeStaleAfterEightHours
    }
}
