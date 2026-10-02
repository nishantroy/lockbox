import XCTest
@testable import CompanionKit

/// R5 pairing v2 (`docs/r5-pairing-v2-plan.md`'s "Slice P2a", item 4):
/// `OwnerAcceptanceCheck.verify` is the owner device's pure, local check on a
/// `SignedAcceptance` read out of its own anchored inbox, replacing the typed
/// six-digit code. Exercises every rejection listed in the plan and the
/// accepting path, including the code the check returns.
final class OwnerAcceptanceCheckTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Harness {
        let ownerSigner: DeviceSigner
        let approverSigner: DeviceSigner
        let invitation: Invitation
        let signedAcceptance: SignedAcceptance
    }

    private func harness(now: Date? = nil, acceptanceID: String = "oac-accept") throws -> Harness {
        let ownerKeys = InMemoryDeviceKeyStore()
        let approverKeys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: approverKeys)
        let fixedNow = now ?? t
        let relay = try InMemoryCompanionRelay(owner: ownerSigner.identity, now: fixedNow)
        let owner = CompanionClient(signer: ownerSigner, transport: relay, now: { fixedNow })
        let approver = CompanionClient(signer: approverSigner, transport: relay, now: { fixedNow })
        let invitation = try owner.createInvite(inviteID: "oac-invite", validFor: 3_600, now: fixedNow,
                                                 nonce: Data(repeating: 4, count: 24))
        let acceptance = try approver.accept(invitation, acceptanceID: acceptanceID, now: fixedNow)
        // Mirrors exactly what `CompanionClient.accept`/`AsyncCompanionClient.accept`
        // sign and submit as the "accept" operation body -- this is the
        // signed form an inbox fetch would deliver back to the owner.
        let signature = try approverSigner.sign(domain: "\(CompanionCanonical.version).acceptance", fields: acceptance.signingFields())
        let signedAcceptance = SignedAcceptance(acceptance: acceptance, signature: signature)
        return Harness(ownerSigner: ownerSigner, approverSigner: approverSigner,
                       invitation: invitation, signedAcceptance: signedAcceptance)
    }

    /// Re-encodes `acceptance` with `verificationCode` replaced, then re-signs
    /// over the tampered fields with `approverSigner` -- a validly-signed
    /// acceptance (the signature matches the bytes it actually covers) that
    /// nonetheless carries the wrong code, exactly what a malicious relay
    /// substituting its own generated code would have to produce.
    private func acceptanceWithTamperedCode(_ acceptance: PairingAcceptance, approverSigner: DeviceSigner) throws -> SignedAcceptance {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var object = try JSONSerialization.jsonObject(with: encoder.encode(acceptance)) as! [String: Any]
        let tamperedCode = (acceptance.verificationCode == "000000") ? "111111" : "000000"
        object["verificationCode"] = tamperedCode
        let tamperedData = try JSONSerialization.data(withJSONObject: object)
        let tampered = try JSONDecoder().decode(PairingAcceptance.self, from: tamperedData)
        let signature = try approverSigner.sign(domain: "\(CompanionCanonical.version).acceptance", fields: tampered.signingFields())
        return SignedAcceptance(acceptance: tampered, signature: signature)
    }

    /// Same consistently-signed-but-tampered pattern as
    /// `acceptanceWithTamperedCode`, targeting `issuedAt` instead (P2a review
    /// follow-up P2-4).
    private func acceptanceWithTamperedIssuedAt(_ acceptance: PairingAcceptance, approverSigner: DeviceSigner, issuedAt: Date) throws -> SignedAcceptance {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var object = try JSONSerialization.jsonObject(with: encoder.encode(acceptance)) as! [String: Any]
        object["issuedAt"] = issuedAt.timeIntervalSinceReferenceDate
        let tamperedData = try JSONSerialization.data(withJSONObject: object)
        let tampered = try JSONDecoder().decode(PairingAcceptance.self, from: tamperedData)
        let signature = try approverSigner.sign(domain: "\(CompanionCanonical.version).acceptance", fields: tampered.signingFields())
        return SignedAcceptance(acceptance: tampered, signature: signature)
    }

    // MARK: - Accepting path

    func testVerifyAcceptsAWellFormedAcceptanceAndReturnsTheExpectedCode() throws {
        let h = try harness()
        let code = try OwnerAcceptanceCheck.verify(signedAcceptance: h.signedAcceptance, invite: h.invitation,
                                                   ownerIdentity: h.ownerSigner.identity, now: t)
        XCTAssertEqual(code, h.signedAcceptance.acceptance.verificationCode)
        XCTAssertEqual(code, PairingAcceptance.code(invite: h.invitation.payload, approver: h.signedAcceptance.acceptance.approver))
    }

    // MARK: - Rejections

    func testVerifyRejectsAnInvalidApproverSignature() throws {
        let h = try harness()
        let tampered = SignedAcceptance(acceptance: h.signedAcceptance.acceptance,
                                        signature: Data(repeating: 0x42, count: 64))
        XCTAssertThrowsError(try OwnerAcceptanceCheck.verify(signedAcceptance: tampered, invite: h.invitation,
                                                             ownerIdentity: h.ownerSigner.identity, now: t)) {
            XCTAssertEqual($0 as? CompanionError, .invalidSignature)
        }
    }

    func testVerifyRejectsAnAcceptanceSignedByAWrongKeyEvenWithAConsistentlyTamperedBody() throws {
        let h = try harness()
        let wrongKeys = InMemoryDeviceKeyStore()
        let wrongSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: wrongKeys)
        let signature = try wrongSigner.sign(domain: "\(CompanionCanonical.version).acceptance",
                                             fields: h.signedAcceptance.acceptance.signingFields())
        let tampered = SignedAcceptance(acceptance: h.signedAcceptance.acceptance, signature: signature)
        XCTAssertThrowsError(try OwnerAcceptanceCheck.verify(signedAcceptance: tampered, invite: h.invitation,
                                                             ownerIdentity: h.ownerSigner.identity, now: t)) {
            XCTAssertEqual($0 as? CompanionError, .invalidSignature)
        }
    }

    func testVerifyRejectsWhenAcceptanceOwnerIsNotThisDevicesOwnerIdentity() throws {
        let h = try harness()
        let otherOwnerKeys = InMemoryDeviceKeyStore()
        let otherOwnerSigner = try DeviceSigner.create(role: .owner, keyStore: otherOwnerKeys)
        XCTAssertThrowsError(try OwnerAcceptanceCheck.verify(signedAcceptance: h.signedAcceptance, invite: h.invitation,
                                                             ownerIdentity: otherOwnerSigner.identity, now: t)) {
            XCTAssertEqual($0 as? CompanionError, .unauthorized)
        }
    }

    func testVerifyRejectsWhenTheInviteIDDoesNotMatchTheLocallyCreatedInvite() throws {
        let h = try harness()
        let fixedNow = t
        let owner = CompanionClient(signer: h.ownerSigner, transport: try InMemoryCompanionRelay(owner: h.ownerSigner.identity, now: t), now: { fixedNow })
        let otherInvitation = try owner.createInvite(inviteID: "oac-other-invite", validFor: 3_600, now: t,
                                                     nonce: Data(repeating: 9, count: 24))
        XCTAssertThrowsError(try OwnerAcceptanceCheck.verify(signedAcceptance: h.signedAcceptance, invite: otherInvitation,
                                                             ownerIdentity: h.ownerSigner.identity, now: t)) {
            XCTAssertEqual($0 as? CompanionError, .wrongTarget)
        }
    }

    func testVerifyRejectsAnExpiredInvite() throws {
        let h = try harness()
        let afterExpiry = h.invitation.payload.expiresAt.addingTimeInterval(1)
        XCTAssertThrowsError(try OwnerAcceptanceCheck.verify(signedAcceptance: h.signedAcceptance, invite: h.invitation,
                                                             ownerIdentity: h.ownerSigner.identity, now: afterExpiry)) {
            XCTAssertEqual($0 as? CompanionError, .expired)
        }
    }

    func testVerifyRejectsAWrongVerificationCodeEvenWhenConsistentlySigned() throws {
        let h = try harness()
        let tampered = try acceptanceWithTamperedCode(h.signedAcceptance.acceptance, approverSigner: h.approverSigner)
        XCTAssertThrowsError(try OwnerAcceptanceCheck.verify(signedAcceptance: tampered, invite: h.invitation,
                                                             ownerIdentity: h.ownerSigner.identity, now: t)) {
            XCTAssertEqual($0 as? CompanionError, .wrongVerificationCode)
        }
    }

    func testVerifyRejectsAnAcceptanceIssuedTooFarInTheFutureRelativeToThisDevicesClock() throws {
        let h = try harness()
        // More than 60s ahead of `now` -- still inside the invite's own
        // validity window, but claims to be from the future.
        let tampered = try acceptanceWithTamperedIssuedAt(h.signedAcceptance.acceptance, approverSigner: h.approverSigner,
                                                          issuedAt: t.addingTimeInterval(120))
        XCTAssertThrowsError(try OwnerAcceptanceCheck.verify(signedAcceptance: tampered, invite: h.invitation,
                                                             ownerIdentity: h.ownerSigner.identity, now: t)) {
            XCTAssertEqual($0 as? CompanionError, .expired)
        }
    }

    func testVerifyRejectsAnAcceptanceIssuedTooLongBeforeTheInviteItself() throws {
        let h = try harness()
        // More than 60s before the invite's own issuedAt -- cannot really be
        // an acceptance of this invite.
        let tampered = try acceptanceWithTamperedIssuedAt(h.signedAcceptance.acceptance, approverSigner: h.approverSigner,
                                                          issuedAt: h.invitation.payload.issuedAt.addingTimeInterval(-120))
        XCTAssertThrowsError(try OwnerAcceptanceCheck.verify(signedAcceptance: tampered, invite: h.invitation,
                                                             ownerIdentity: h.ownerSigner.identity, now: t)) {
            XCTAssertEqual($0 as? CompanionError, .expired)
        }
    }

    func testVerifyRejectsAnAcceptanceIssuedAtOrAfterTheInviteExpiry() throws {
        let h = try harness()
        let tampered = try acceptanceWithTamperedIssuedAt(h.signedAcceptance.acceptance, approverSigner: h.approverSigner,
                                                          issuedAt: h.invitation.payload.expiresAt)
        XCTAssertThrowsError(try OwnerAcceptanceCheck.verify(signedAcceptance: tampered, invite: h.invitation,
                                                             ownerIdentity: h.ownerSigner.identity, now: t)) {
            XCTAssertEqual($0 as? CompanionError, .expired)
        }
    }

    func testVerifyRejectsAnAcceptanceForAnotherOwnersInvite() throws {
        let h = try harness()
        let otherOwnerKeys = InMemoryDeviceKeyStore()
        let otherOwnerSigner = try DeviceSigner.create(role: .owner, keyStore: otherOwnerKeys)
        let otherRelay = try InMemoryCompanionRelay(owner: otherOwnerSigner.identity, now: t)
        let fixedNow = t
        let otherOwner = CompanionClient(signer: otherOwnerSigner, transport: otherRelay, now: { fixedNow })
        let otherInvitation = try otherOwner.createInvite(inviteID: "oac-invite", validFor: 3_600, now: t,
                                                          nonce: Data(repeating: 4, count: 24))
        // Same inviteID string as `h.invitation`, but a different owner --
        // `invite.payload.owner != ownerIdentity` must still reject.
        XCTAssertThrowsError(try OwnerAcceptanceCheck.verify(signedAcceptance: h.signedAcceptance, invite: otherInvitation,
                                                             ownerIdentity: otherOwnerSigner.identity, now: t)) {
            XCTAssertEqual($0 as? CompanionError, .unauthorized)
        }
    }
}
