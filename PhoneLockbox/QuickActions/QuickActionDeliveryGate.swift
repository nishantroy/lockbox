import Foundation

/// In-memory serialization for one currently presenting quick action. The
/// durable queue owns retryability; this gate owns the UI rule that no later
/// route may replace a presented identity until its destination settles.
struct QuickActionDeliveryGate: Equatable, Sendable {
    struct Identity: Equatable, Sendable {
        let id: String
        let action: QuickActionRoute.Action
    }

    private(set) var activeIdentity: Identity?

    @discardableResult
    mutating func begin(_ identity: Identity) -> Bool {
        guard activeIdentity == nil else { return false }
        activeIdentity = identity
        return true
    }

    func accepts(_ identity: Identity) -> Bool {
        activeIdentity == identity
    }

    @discardableResult
    mutating func settle(_ identity: Identity) -> Bool {
        guard activeIdentity == identity else { return false }
        activeIdentity = nil
        return true
    }
}
