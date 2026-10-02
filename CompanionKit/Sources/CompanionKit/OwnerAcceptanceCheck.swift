import Foundation

/// Pure, local pre-check the owner device runs on an inbox-delivered
/// `SignedAcceptance` (R5 pairing v2, `docs/r5-pairing-v2-plan.md`'s "Slice
/// P2a", item 4), replacing the owner typing a six-digit code read aloud by
/// the friend. The relay independently re-checks everything this verifies
/// when `confirm` is submitted (including the verification code itself) —
/// this check never substitutes for that server-side authorization — but a
/// relay-supplied acceptance must never be trusted (or shown to the owner)
/// before this device itself confirms it is signed by the approver, names
/// this device's own owner identity, and answers an invite this very device
/// created.
///
/// No I/O: every input is a value the caller already has (the inbox
/// `SignedAcceptance`, the device's own locally-stored `Invitation` for that
/// `inviteID`, and the device's own owner `DeviceIdentity`).
public enum OwnerAcceptanceCheck {
    /// Throws unless `signedAcceptance` is a valid, current acceptance of
    /// `invite` — an invitation **this device created**, looked up by the
    /// caller from its own local store before calling `verify` (never
    /// trusted from the relay alone: an acceptance whose `inviteID` has no
    /// matching local invite must never reach this function — see the P2b
    /// plan item 2, "Drop anything that fails verification or has no
    /// matching local invite").
    ///
    /// On success, returns the expected six-digit verification code, derived
    /// independently by this device from the invite and the acceptance's
    /// approver — so the caller can call
    /// `confirm(acceptance, verificationCode:)`/`AsyncCompanionClient.confirm`
    /// without the owner ever reading or typing a code.
    ///
    /// Checks, in order:
    /// - the approver's signature over the acceptance;
    /// - `acceptance.owner == ownerIdentity`;
    /// - `acceptance.inviteID` matches `invite` (the invite this device
    ///   created, passed in by the caller);
    /// - the invite has not expired as of `now`;
    /// - `acceptance.issuedAt` is bounded both against the invite
    ///   (`>= invite.payload.issuedAt - 60`, i.e. not claimed to predate the
    ///   invite by more than clock skew; `< invite.payload.expiresAt`, i.e.
    ///   not claimed to have happened after the invite's own expiry) and
    ///   against this device's own clock (`<= now + 60`, i.e. not claimed to
    ///   be from the future) — P2a review follow-up P2-4: a relay-supplied
    ///   acceptance's own timestamp was previously never checked here at
    ///   all, only the invite's expiry against `now`;
    /// - `acceptance.verificationCode == PairingAcceptance.code(invite:approver:)`,
    ///   i.e. the code this device would itself derive for this exact invite
    ///   and approver.
    public static func verify(signedAcceptance: SignedAcceptance, invite: Invitation,
                              ownerIdentity: DeviceIdentity, now: Date) throws -> String {
        let acceptance = signedAcceptance.acceptance
        // The approver signature. `validateSignature()` also structurally
        // validates `acceptance` itself (identifiers, roles, code shape).
        try signedAcceptance.validateSignature()
        guard ownerIdentity.role == .owner else {
            throw CompanionError.unauthorized
        }
        guard acceptance.owner == ownerIdentity else {
            throw CompanionError.unauthorized
        }
        // `inviteID` matches an invite this device created, passed in by the
        // caller -- never inferred from the acceptance alone.
        guard acceptance.inviteID == invite.payload.inviteID,
              invite.payload.owner == ownerIdentity else {
            throw CompanionError.wrongTarget
        }
        try invite.validateSignature()
        // The invite has not expired.
        guard now < invite.payload.expiresAt else {
            throw CompanionError.expired
        }
        // The acceptance's own timestamp, bounded against both the invite
        // and this device's clock (P2-4).
        guard acceptance.issuedAt >= invite.payload.issuedAt.addingTimeInterval(-60),
              acceptance.issuedAt < invite.payload.expiresAt,
              acceptance.issuedAt <= now.addingTimeInterval(60) else {
            throw CompanionError.expired
        }
        let expectedCode = PairingAcceptance.code(invite: invite.payload, approver: acceptance.approver)
        guard acceptance.verificationCode == expectedCode else {
            throw CompanionError.wrongVerificationCode
        }
        return expectedCode
    }
}
