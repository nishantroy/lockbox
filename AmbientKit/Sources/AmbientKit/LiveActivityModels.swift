import Foundation

/// The origin determines the small amount of language and iconography shown
/// by the Live Activity. It is part of the immutable Activity attributes.
public enum AmbientLiveActivityKind: String, Codable, Hashable, Sendable {
    case bedtime
    case focus
    case demo

    public var title: String {
        switch self {
        case .bedtime: return "Get some rest"
        case .focus, .demo: return "Focus time"
        }
    }

    public var iconSystemName: String {
        switch self {
        case .bedtime: return "moon.fill"
        case .focus: return "lock.fill"
        case .demo: return "testtube.2"
        }
    }
}

/// Compatibility spelling for callers that describe this value as an origin.
public typealias AmbientLiveActivityOrigin = AmbientLiveActivityKind

public enum AmbientLiveActivityStatus: String, Codable, Hashable, Sendable {
    case plannedSession
    case recoveryPending
    case releaseObserved
    case expired
    case stale

    public var accessibilityLabel: String {
        switch self {
        case .plannedSession: return "Session is active"
        case .recoveryPending: return "Recovery requested"
        case .releaseObserved: return "Session released"
        case .expired: return "Session end reached"
        case .stale: return "Status may be out of date. Open Phone Lockbox"
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

/// Activity attributes are immutable after an Activity starts. In particular,
/// neither the fixed end nor the presentation kind can be changed by updates.
public struct AmbientLiveActivityAttributes: Codable, Hashable, Sendable {
    public let sessionID: String
    public let fixedEnd: Date
    public let kind: AmbientLiveActivityKind

    public init(
        sessionID: String,
        fixedEnd: Date,
        kind: AmbientLiveActivityKind = .demo
    ) {
        self.sessionID = sessionID
        self.fixedEnd = fixedEnd
        self.kind = kind
    }

    public var origin: AmbientLiveActivityOrigin { kind }
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
    case kindMismatch
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
        status: AmbientLiveActivityStatus,
        requestedKind: AmbientLiveActivityKind? = nil
    ) -> AmbientLiveActivityUnavailableReason? {
        guard requestedFixedEnd == attributes.fixedEnd else { return .fixedEndMismatch }
        if let requestedKind, requestedKind != attributes.kind { return .kindMismatch }
        return startRejection(status: status)
    }
}

/// Value-only presentation mapping shared by the widget and host tests.
/// Accessibility labels contain context that is intentionally not printed in
/// the compact or expanded regions.
public struct AmbientLiveActivityPresentation: Equatable, Sendable {
    public let title: String
    public let accessibilityLabel: String
    public let compactIconName: String
    public let recoveryText: String?
    public let demoIndicator: String?
    public let staleActionText: String?

    /// Compatibility value for older hosts; compact presentation now uses an
    /// icon rather than an abbreviated status string.
    public var compactLabel: String { compactIconName }

    public init(
        kind: AmbientLiveActivityKind,
        status: AmbientLiveActivityStatus,
        isStale: Bool
    ) {
        compactIconName = kind.iconSystemName
        recoveryText = !isStale && status == .recoveryPending ? "Recovery requested" : nil
        demoIndicator = kind == .demo ? "Demo" : nil
        staleActionText = isStale ? "Open Phone Lockbox" : nil

        if isStale {
            title = "Status may be out of date"
            let originLabel = kind == .demo ? "Demo. " : ""
            accessibilityLabel = "\(originLabel)Status may be out of date. Open Phone Lockbox."
        } else {
            title = kind.title
            let originLabel = kind == .demo ? "Demo. " : ""
            accessibilityLabel = "\(originLabel)\(kind.title). \(status.accessibilityLabel)."
        }
    }

    /// Preserves the old host-test initializer; new call sites should pass the
    /// immutable kind explicitly.
    public init(status: AmbientLiveActivityStatus, isStale: Bool) {
        self.init(kind: .demo, status: status, isStale: isStale)
    }
}
