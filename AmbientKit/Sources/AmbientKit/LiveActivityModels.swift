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
    case fixedEndMismatch
    case releaseObservationRequired
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

    /// Release-observed copy is reserved for the dedicated observed-release
    /// hook. A caller cannot smuggle it through start or an ordinary update.
    public static func startRejection(
        status: AmbientLiveActivityStatus
    ) -> AmbientLiveActivityUnavailableReason? {
        status == .releaseObserved ? .releaseObservationRequired : nil
    }

    public static func updateRejection(
        attributes: AmbientLiveActivityAttributes,
        requestedFixedEnd: Date,
        status: AmbientLiveActivityStatus
    ) -> AmbientLiveActivityUnavailableReason? {
        guard requestedFixedEnd == attributes.fixedEnd else { return .fixedEndMismatch }
        return startRejection(status: status)
    }
}

/// The widget uses this value-only mapping for every presentation region. In
/// particular, WidgetKit's `context.isStale` wins over the state status so a
/// stale activity cannot continue to present a planned or recovery status.
public struct AmbientLiveActivityPresentation: Equatable, Sendable {
    public let title: String
    public let accessibilityLabel: String
    public let compactLabel: String

    public init(status: AmbientLiveActivityStatus, isStale: Bool) {
        if isStale {
            title = "Status stale"
            accessibilityLabel = "Status stale; open Phone Lockbox to reconcile"
            compactLabel = "STALE"
        } else {
            switch status {
            case .plannedSession:
                title = "Planned session"
                accessibilityLabel = status.accessibilityLabel
                compactLabel = "PLAN"
            case .recoveryPending:
                title = "Recovery requested"
                accessibilityLabel = status.accessibilityLabel
                compactLabel = "REC"
            case .releaseObserved:
                title = "Release observed"
                accessibilityLabel = status.accessibilityLabel
                compactLabel = "DONE"
            case .expired:
                title = "Session end reached"
                accessibilityLabel = status.accessibilityLabel
                compactLabel = "END"
            case .stale:
                title = "Status stale"
                accessibilityLabel = status.accessibilityLabel
                compactLabel = "STALE"
            }
        }
    }
}
