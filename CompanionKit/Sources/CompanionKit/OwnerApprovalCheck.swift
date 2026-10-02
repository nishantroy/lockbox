import Foundation

/// Pure, local pre-check the owner device runs **before** calling
/// `useApproval`/`AsyncCompanionClient.useApproval` on an `Approval` it read
/// out of its own anchored inbox (R5 Slice B2a,
/// `docs/r5-b2-plan.md`: "B2a — protocol: owner approval delivery and async
/// `use`", item 3). The relay independently re-checks everything this
/// verifies when `use` is submitted — this check never substitutes for that
/// server-side authorization — but a bad or stale-cache local decision
/// should never reach the network in the first place, and failing fast here
/// keeps a rejected `use` attempt from being reported as "the relay said no"
/// when actually the owner's own device already knew the approval did not
/// apply.
///
/// No I/O: every input is a value the caller already has (the inbox
/// `Approval`, the local `TrustedRequest` copy, and a snapshot of the
/// owner's own trusted pairing/consent cache for that approver).
public enum OwnerApprovalCheck {
    /// A snapshot of the owner's own trusted pairing/consent cache for one
    /// approver, exactly as `OwnerApprovalCheck.verify` needs it. The caller
    /// builds this from data it already locally trusts (its own pairing
    /// store and bilateral consent cache) — never from the `Approval` under
    /// check itself, which is exactly what this type exists to validate
    /// against.
    public struct TrustedApprover: Sendable {
        /// The local owner identity this approver is paired with. Checked
        /// against `request.owner` so an approval cannot be accepted for a
        /// request this device does not itself own.
        public let ownerIdentityID: String
        public let approverIdentityID: String
        public let approverPublicKey: Data
        public let pairingID: String
        public let pairEpoch: UInt64
        public let consentGeneration: UInt64
        /// `false` once the owner has revoked this pairing (or it was
        /// replaced), or the cached bilateral consent no longer authorizes
        /// both `approveEarlyEnd` and `receiveRequests`. An `Approval` from
        /// an approver the owner no longer trusts must never be accepted,
        /// even if its signature and bindings still line up with a stale
        /// cache entry.
        public let isActive: Bool

        public init(ownerIdentityID: String, approverIdentityID: String, approverPublicKey: Data,
                    pairingID: String, pairEpoch: UInt64, consentGeneration: UInt64, isActive: Bool) {
            self.ownerIdentityID = ownerIdentityID
            self.approverIdentityID = approverIdentityID
            self.approverPublicKey = approverPublicKey
            self.pairingID = pairingID
            self.pairEpoch = pairEpoch
            self.consentGeneration = consentGeneration
            self.isActive = isActive
        }
    }

    /// Throws unless `approval` is exactly the approval the owner's own
    /// trusted-person cache would expect for `request`. Every failure throws
    /// before any signature work that could be influenced by attacker input,
    /// except `validateSignature()` itself, which is pure.
    public static func verify(approval: Approval, request: TrustedRequest,
                              trustedApprover: TrustedApprover) throws {
        // An unknown or revoked approver.
        guard trustedApprover.isActive else { throw CompanionError.revokedPairing }
        guard approval.approver.identityID == trustedApprover.approverIdentityID,
              approval.approver.role == .trustedApprover else {
            throw CompanionError.unknownIdentity
        }
        // A key mismatch: the signing key on the approval does not match the
        // key this device actually confirmed for that approver identity.
        guard approval.approver.publicKey == trustedApprover.approverPublicKey else {
            throw CompanionError.unknownIdentity
        }
        guard approval.pairingID == trustedApprover.pairingID else {
            throw CompanionError.wrongTarget
        }
        // An epoch or generation mismatch.
        guard approval.pairEpoch == trustedApprover.pairEpoch else {
            throw CompanionError.revokedPairing
        }
        guard approval.consentGeneration == trustedApprover.consentGeneration else {
            throw CompanionError.consentRequired
        }
        // A request that isn't owned by this owner.
        guard request.owner.identityID == trustedApprover.ownerIdentityID else {
            throw CompanionError.unauthorized
        }
        // An approval for a different request, session or active set.
        guard approval.requestID == request.requestID,
              approval.sessionID == request.sessionID,
              approval.activeSetID == request.activeSetID else {
            throw CompanionError.wrongTarget
        }
        guard let binding = request.binding(for: trustedApprover.approverIdentityID),
              binding.pairingID == approval.pairingID,
              binding.pairEpoch == approval.pairEpoch,
              binding.consentGeneration == approval.consentGeneration else {
            throw CompanionError.wrongTarget
        }
        // An approval that isn't `.approved`.
        guard approval.decision == .approved else {
            throw CompanionError.wrongTarget
        }
        try approval.validateSignature()
    }
}
