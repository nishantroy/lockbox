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
/// `Approval`, the local `TrustedRequest` copy, the device's own owner
/// `DeviceIdentity`, and a snapshot of the owner's own trusted
/// pairing/consent cache for that approver).
public enum OwnerApprovalCheck {
    /// A snapshot of the owner's own trusted pairing/consent cache for one
    /// approver, exactly as `OwnerApprovalCheck.verify` needs it. The caller
    /// builds this from data it already locally trusts (its own pairing
    /// store and bilateral consent cache) — never from the `Approval` under
    /// check itself, which is exactly what this type exists to validate
    /// against.
    public struct TrustedApprover: Sendable {
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

        public init(approverIdentityID: String, approverPublicKey: Data,
                    pairingID: String, pairEpoch: UInt64, consentGeneration: UInt64, isActive: Bool) {
            self.approverIdentityID = approverIdentityID
            self.approverPublicKey = approverPublicKey
            self.pairingID = pairingID
            self.pairEpoch = pairEpoch
            self.consentGeneration = consentGeneration
            self.isActive = isActive
        }

        /// Preferred constructor (R5 Slice B2a review fix, P2-1): derives
        /// every field straight from the owner's own locally trusted
        /// `Pairing` and `RelationshipConsent`, rather than requiring the
        /// caller to hand-assemble (and keep in sync) the individual
        /// identity/epoch/generation/activity fields themselves — the
        /// out-of-sync case is exactly what lets a stale-cache bug slip past
        /// `verify`. `isActive` is `pairing.state == .active` AND the
        /// consent currently authorizes *both* `approveEarlyEnd` and
        /// `receiveRequests` (bilateral, current generation — see
        /// `RelationshipConsent.authorizes(_:)`). If `pairing` and `consent`
        /// do not actually describe the same relationship (mismatched
        /// pairing ID, epoch, owner or approver — which should never happen
        /// for a caller reading both from the same local cache entry, but is
        /// checked here rather than trusted), the result is `isActive:
        /// false` rather than silently accepting whichever generation/epoch
        /// `consent` happens to carry.
        public init(pairing: Pairing, consent: RelationshipConsent) {
            self.approverIdentityID = pairing.approver.identityID
            self.approverPublicKey = pairing.approver.publicKey
            self.pairingID = pairing.pairingID
            self.pairEpoch = pairing.epoch
            self.consentGeneration = consent.generation
            let consentMatchesPairing = consent.pairingID == pairing.pairingID
                && consent.pairEpoch == pairing.epoch
                && consent.owner == pairing.owner
                && consent.approver == pairing.approver
            self.isActive = consentMatchesPairing && pairing.state == .active
                && consent.authorizes(.approveEarlyEnd) && consent.authorizes(.receiveRequests)
        }
    }

    /// Throws unless `approval` is exactly the approval the owner's own
    /// trusted-person cache would expect for `request`. Every failure throws
    /// before any signature work that could be influenced by attacker input,
    /// except `validateSignature()` itself, which is pure.
    ///
    /// - Parameter ownerIdentity: this device's own owner `DeviceIdentity`
    ///   (the signer identity `useApproval` will sign with) — **not** a
    ///   field carried inside `trustedApprover`. The owner identity is a
    ///   single, already-available value at every call site (R5 Slice B2a
    ///   review fix, P2-1); baking a copy of it into a per-approver snapshot
    ///   instead would require every cache entry to be kept in sync with it
    ///   for no benefit, and a stale or substituted copy there would be an
    ///   easy way to defeat the very check this type exists to perform.
    public static func verify(approval: Approval, request: TrustedRequest,
                              trustedApprover: TrustedApprover, ownerIdentity: DeviceIdentity) throws {
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
        // A request that isn't owned by this owner. Compares the full
        // `DeviceIdentity` (identity ID, role and public key), not just the
        // identity ID string.
        guard request.owner == ownerIdentity else {
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
