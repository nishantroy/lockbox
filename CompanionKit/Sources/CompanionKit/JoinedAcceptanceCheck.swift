import Foundation

/// Pure, local check the **owner** device runs on a relay-reported pairing
/// before it shows "‹Name› joined" or treats the person as trusted
/// (pairing v3, `docs/r5-pairing-v3-plan.md`).
///
/// v3 removed the owner's confirm step, so the owner no longer creates the
/// pairing record itself; the relay reports it in the inbox. A relay must not
/// be able to invent a trusted person, so each reported pairing comes with
/// the friend-signed acceptance that created it
/// (`InboxResponse.acceptances`), and this check proves, against state the
/// owner device already holds, that:
///
/// - the acceptance is signed by the approver key named in the pairing,
/// - it answers an invite **this device created** (`invite` is passed in from
///   the device's own store, never from the relay),
/// - it carries that invite's token (so the signer held the link), and accepts
///   exactly the scopes the owner granted,
/// - it was issued inside the invite's validity window,
/// - the pairing's ID, owner, approver and names are exactly what that
///   acceptance and invite imply.
///
/// What it cannot prove: that the key belongs to the person the owner
/// intended. Whoever holds an unexpired, unused link can join (the accepted
/// risk in `docs/companion-security.md`); a relay that sees the token in
/// transit could race the friend. Both are bounded by the owner seeing every
/// person and being able to remove them.
public enum JoinedAcceptanceCheck {
    /// Allowed clock skew between the acceptance's `issuedAt` and the invite's window.
    private static let skew: TimeInterval = 60

    /// - Parameters:
    ///   - signedAcceptance: One entry from `InboxResponse.acceptances`.
    ///   - pairing: The `InboxResponse.pairings` entry it is claimed to have created.
    ///   - invite: This device's own stored `Invitation` with `payload.inviteID == acceptance.inviteID`.
    ///   - ownerIdentity: This device's owner identity.
    /// - Throws: `CompanionError` describing the first failed check.
    public static func verify(signedAcceptance: SignedAcceptance, pairing: Pairing, invite: Invitation,
                              ownerIdentity: DeviceIdentity) throws {
        let acceptance = signedAcceptance.acceptance
        try signedAcceptance.validateSignature()
        try invite.validateSignature()
        guard ownerIdentity.role == .owner,
              invite.payload.owner == ownerIdentity,
              acceptance.owner == ownerIdentity,
              acceptance.inviteID == invite.payload.inviteID else {
            throw CompanionError.unauthorized
        }
        guard InviteToken.matches(acceptance.token, hash: invite.payload.tokenHash) else {
            throw CompanionError.unauthorized
        }
        guard acceptance.acceptedScopes.sorted(by: { $0.rawValue < $1.rawValue }) == invite.payload.grantedScopes else {
            throw CompanionError.consentRequired
        }
        guard acceptance.issuedAt >= invite.payload.issuedAt.addingTimeInterval(-skew),
              acceptance.issuedAt < invite.payload.expiresAt else {
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

    /// Convenience over a whole inbox: returns the pairings (keyed by pairing
    /// ID) whose acceptance verifies against one of `invites` (this device's
    /// own invites, keyed by invite ID). Anything that fails is silently
    /// excluded, so a relay-supplied pairing that cannot be proven never
    /// reaches the UI as a person who "joined".
    public static func verifiedPairings(in inbox: InboxResponse, invites: [String: Invitation],
                                        ownerIdentity: DeviceIdentity) -> [Pairing] {
        let acceptances = inbox.acceptances ?? []
        return (inbox.pairings ?? []).filter { pairing in
            acceptances.contains { signed in
                guard let invite = invites[signed.acceptance.inviteID] else { return false }
                return (try? verify(signedAcceptance: signed, pairing: pairing, invite: invite, ownerIdentity: ownerIdentity)) != nil
            }
        }
    }
}
