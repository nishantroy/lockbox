import Foundation

/// Pure, local check the **owner** device runs on a relay-reported pairing
/// before it shows "‹Name› joined" or treats the person as trusted
/// (pairing v3, `docs/r5-pairing-v3-plan.md`).
///
/// v3 removed the owner's confirm step, so the owner no longer creates the
/// pairing record itself; the relay reports it in the inbox. A relay must not
/// be able to invent a trusted person, so each reported pairing comes with the
/// friend-signed acceptance that created it (`InboxResponse.acceptances`), and
/// this check proves, against state the owner device already holds, that:
///
/// - the acceptance is signed by the approver key named in the pairing,
/// - it answers an invite **this device created** (`issued` comes from the
///   device's own store, never from the relay),
/// - its `tokenProof` equals `H("accept-proof", token, approverPublicKey,
///   acceptanceID)` for the token this device generated. Only a holder of the
///   link can compute that: the relay never sees the token and knows only the
///   lookup key, so it cannot fabricate an acceptance the owner will trust,
/// - it carries the invite's lookup key and accepts exactly the scopes the owner granted,
/// - the pairing's ID, owner, approver and names are exactly what that
///   acceptance and invite imply.
///
/// What it cannot prove: that the key belongs to the person the owner
/// intended. Whoever holds an unexpired, unused link can join (the accepted
/// risk in `docs/companion-security.md`). That risk is "link holders", not the
/// relay. It is bounded by the owner seeing every person and being able to
/// remove them.
public enum JoinedAcceptanceCheck {
    /// - Parameters:
    ///   - signedAcceptance: One entry from `InboxResponse.acceptances`.
    ///   - pairing: The `InboxResponse.pairings` entry it is claimed to have created.
    ///   - issued: This device's own stored invite for `acceptance.inviteID`, including its token.
    ///   - ownerIdentity: This device's owner identity.
    /// - Throws: `CompanionError` describing the first failed check.
    public static func verify(signedAcceptance: SignedAcceptance, pairing: Pairing, issued: IssuedInvite,
                              ownerIdentity: DeviceIdentity) throws {
        let acceptance = signedAcceptance.acceptance
        let invite = issued.invitation
        try signedAcceptance.validateSignature()
        try invite.validateSignature()
        guard ownerIdentity.role == .owner,
              invite.payload.owner == ownerIdentity,
              acceptance.owner == ownerIdentity,
              acceptance.inviteID == invite.payload.inviteID else {
            throw CompanionError.unauthorized
        }
        // The stored token must be the one this invite was issued for, and the acceptance must prove it.
        guard InviteToken.matches(issued.token, payload: invite.payload),
              InviteToken.constantTimeEqual(acceptance.lookupKey, invite.payload.lookupKey),
              InviteToken.constantTimeEqual(
                acceptance.tokenProof,
                InviteToken.acceptanceProof(token: issued.token, approverPublicKey: acceptance.approver.publicKey,
                                            acceptanceID: acceptance.acceptanceID)) else {
            throw CompanionError.unauthorized
        }
        guard InviteToken.verifyPossession(of: acceptance, possessionKey: invite.payload.possessionKey) else {
            throw CompanionError.unauthorized
        }
        guard acceptance.acceptedScopes.sorted(by: { $0.rawValue < $1.rawValue }) == invite.payload.grantedScopes else {
            throw CompanionError.consentRequired
        }
        // The relay already refuses a late acceptance; bound it here too (with clock skew) so a
        // far-future stamp reported by the relay cannot pass.
        guard acceptance.issuedAt < invite.payload.expiresAt.addingTimeInterval(CompanionLimits.pairingClockSkew) else {
            throw CompanionError.expired
        }
        try pairing.validate()
        guard pairing.owner == ownerIdentity,
              pairing.approver == acceptance.approver,
              pairing.pairingID == Pairing.derivedID(inviteID: invite.payload.inviteID, approverIdentityID: acceptance.approver.identityID),
              pairing.ownerDisplayName == invite.payload.ownerDisplayName,
              pairing.approverDisplayName == acceptance.approverDisplayName else {
            throw CompanionError.unauthorized
        }
    }

    /// The outcome of checking a whole inbox.
    public struct Result: Sendable, Equatable {
        /// Active pairings proven to answer an invite this device created.
        public let verified: [Pairing]
        /// Integrity problems the UI should surface (for example a relay reporting two
        /// acceptances for one single-use invite). Pairings for such invites are excluded.
        public let integrityWarnings: [String]
    }

    /// Filters an inbox to the pairings this device can prove. Anything that fails
    /// is excluded, so a relay-supplied pairing that cannot be proven never
    /// reaches the UI as a person who "joined". Revoked pairings are not "joined".
    /// An invite is single use, so more than one acceptance for the same invite ID
    /// means a misbehaving relay (or a bug): every pairing for it is rejected and a
    /// warning is returned.
    ///
    /// Pairings created before v3 or by `replace_pairing` carry no acceptance and
    /// are never returned here; the caller needs another trust source for them.
    ///
    /// The owner must keep each `IssuedInvite` (including its token) for as long as the
    /// pairing it created exists, and delete it when the owner removes that person:
    /// `verify` needs it on every inbox fetch.
    public static func verifiedPairings(in inbox: InboxResponse, invites: [String: IssuedInvite],
                                        ownerIdentity: DeviceIdentity) -> Result {
        let acceptances = inbox.acceptances ?? []
        var countsByInvite: [String: Int] = [:]
        for signed in acceptances { countsByInvite[signed.acceptance.inviteID, default: 0] += 1 }
        let duplicated = Set(countsByInvite.filter { $0.value > 1 }.keys)
        var warnings = duplicated.sorted().map { "relay reported more than one acceptance for single-use invite \($0)" }
        // An acceptance that matches an invite this device holds but does not verify is a relay
        // misbehaving (or a bug), never a normal state: surface it instead of silently hiding it.
        for signed in acceptances where !duplicated.contains(signed.acceptance.inviteID) {
            guard let issued = invites[signed.acceptance.inviteID] else { continue }
            let pairing = (inbox.pairings ?? []).first {
                $0.pairingID == Pairing.derivedID(inviteID: signed.acceptance.inviteID, approverIdentityID: signed.acceptance.approver.identityID)
            }
            let valid = pairing.flatMap { try? verify(signedAcceptance: signed, pairing: $0, issued: issued, ownerIdentity: ownerIdentity) }
            if valid == nil {
                warnings.append("relay reported an acceptance for invite \(signed.acceptance.inviteID) that failed verification")
            }
        }
        let verified = (inbox.pairings ?? []).filter { pairing in
            guard pairing.state == .active else { return false }
            return acceptances.contains { signed in
                guard !duplicated.contains(signed.acceptance.inviteID),
                      let issued = invites[signed.acceptance.inviteID] else { return false }
                return (try? verify(signedAcceptance: signed, pairing: pairing, issued: issued, ownerIdentity: ownerIdentity)) != nil
            }
        }
        return Result(verified: verified, integrityWarnings: warnings)
    }
}
