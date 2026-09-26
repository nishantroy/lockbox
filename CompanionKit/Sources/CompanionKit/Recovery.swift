import Foundation

/// Local fallback recovery. It is intentionally independent of trusted-person
/// delivery and always uses the production delay; callers cannot shorten it.
public enum LocalRecoveryStatus: String, Codable, Sendable { case waiting, eligible, confirmed, cancelled, expired }

public struct LocalRecoveryRequest: Codable, Hashable, Sendable {
    public static let delay: TimeInterval = 900
    public let recoveryID: String
    public let owner: DeviceIdentity
    public let sessionID: String
    public let activeSetID: String
    public let requestedAt: Date
    public let eligibleAt: Date
    public let sessionEndsAt: Date
    public var status: LocalRecoveryStatus

    public init(recoveryID: String, owner: DeviceIdentity, session: ActiveSession, requestedAt: Date) throws {
        try requireIdentifier(recoveryID, name: "recovery ID")
        guard owner == session.owner, session.isActive(at: requestedAt) else { throw CompanionError.staleSession }
        try requireTimestamp(requestedAt, name: "recovery request time")
        self.recoveryID = recoveryID; self.owner = owner; self.sessionID = session.sessionID; self.activeSetID = session.activeSetID
        self.requestedAt = requestedAt; self.eligibleAt = requestedAt.addingTimeInterval(Self.delay)
        self.sessionEndsAt = session.endsAt; self.status = .waiting
    }

    public func status(at now: Date) -> LocalRecoveryStatus {
        guard status == .waiting || status == .eligible else { return status }
        if now >= sessionEndsAt { return .expired }
        return now >= eligibleAt ? .eligible : .waiting
    }

    public func confirm(at now: Date) throws -> LocalRecoveryRequest {
        let current = status(at: now)
        guard current == .eligible else {
            if current == .expired { throw CompanionError.expired }
            throw CompanionError.invalidTransition
        }
        var copy = self; copy.status = .confirmed; return copy
    }

    public func cancel(at now: Date) throws -> LocalRecoveryRequest {
        guard status(at: now) == .waiting || status(at: now) == .eligible else { throw CompanionError.invalidTransition }
        var copy = self; copy.status = .cancelled; return copy
    }
}
