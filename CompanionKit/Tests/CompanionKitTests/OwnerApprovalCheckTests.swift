import XCTest
@testable import CompanionKit

/// R5 Slice B2a: `OwnerApprovalCheck.verify` is the owner device's pure,
/// local pre-check on an `Approval` read out of its own anchored inbox,
/// before ever calling `useApproval`. Exercises every rejection case listed
/// in `docs/r5-b2-plan.md`'s B2a item 3, plus the accepting path.
final class OwnerApprovalCheckTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private func harness() throws -> (InMemoryCompanionRelay, CompanionClient, CompanionClient, Pairing, ActiveSession) {
        let ownerKeys = InMemoryDeviceKeyStore()
        let approverKeys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: approverKeys)
        let relay = try InMemoryCompanionRelay(owner: ownerSigner.identity, now: t)
        let fixedNow = t
        let owner = CompanionClient(signer: ownerSigner, transport: relay, now: { fixedNow })
        let approver = CompanionClient(signer: approverSigner, transport: relay, now: { fixedNow })
        let invitation = try owner.createInvite(inviteID: "oac-invite", validFor: 3_600, now: t,
                                                 nonce: Data(repeating: 4, count: 24))
        let acceptance = try approver.accept(invitation, acceptanceID: "oac-accept", now: t)
        let pairing = try owner.confirm(acceptance, verificationCode: acceptance.verificationCode, now: t)
        _ = try owner.grantScopes(pairing: pairing, scopes: [.approveEarlyEnd, .receiveRequests])
        _ = try approver.acceptScopes(pairing: pairing, scopes: [.approveEarlyEnd, .receiveRequests])
        let session = try ActiveSession(owner: ownerSigner.identity, sessionID: "oac-session", activeSetID: "oac-set",
                                        startsAt: t.addingTimeInterval(-1), endsAt: t.addingTimeInterval(3_600))
        _ = try owner.publishSession(session)
        return (relay, owner, approver, pairing, session)
    }

    private func trustedApprover(ownerIdentityID: String, pairing: Pairing, consentGeneration: UInt64,
                                 isActive: Bool = true) -> OwnerApprovalCheck.TrustedApprover {
        OwnerApprovalCheck.TrustedApprover(ownerIdentityID: ownerIdentityID,
                                           approverIdentityID: pairing.approver.identityID,
                                           approverPublicKey: pairing.approver.publicKey,
                                           pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
                                           consentGeneration: consentGeneration, isActive: isActive)
    }

    func testVerifyAcceptsAWellFormedApproval() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-ok", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let trusted = trustedApprover(ownerIdentityID: owner.signer.identity.identityID, pairing: pairing,
                                      consentGeneration: approval.consentGeneration)
        XCTAssertNoThrow(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted))
    }

    func testVerifyRejectsARevokedApprover() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-revoked", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let trusted = trustedApprover(ownerIdentityID: owner.signer.identity.identityID, pairing: pairing,
                                      consentGeneration: approval.consentGeneration, isActive: false)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted)) {
            XCTAssertEqual($0 as? CompanionError, .revokedPairing)
        }
    }

    func testVerifyRejectsAnUnknownApproverIdentity() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-unknown", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        var trusted = trustedApprover(ownerIdentityID: owner.signer.identity.identityID, pairing: pairing,
                                      consentGeneration: approval.consentGeneration)
        trusted = OwnerApprovalCheck.TrustedApprover(ownerIdentityID: trusted.ownerIdentityID,
                                                     approverIdentityID: "a-completely-different-identity",
                                                     approverPublicKey: trusted.approverPublicKey,
                                                     pairingID: trusted.pairingID, pairEpoch: trusted.pairEpoch,
                                                     consentGeneration: trusted.consentGeneration, isActive: true)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted)) {
            XCTAssertEqual($0 as? CompanionError, .unknownIdentity)
        }
    }

    func testVerifyRejectsAPublicKeyMismatch() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-key", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let trusted = OwnerApprovalCheck.TrustedApprover(ownerIdentityID: owner.signer.identity.identityID,
                                                         approverIdentityID: pairing.approver.identityID,
                                                         approverPublicKey: Data(repeating: 0xAB, count: 32),
                                                         pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
                                                         consentGeneration: approval.consentGeneration, isActive: true)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted)) {
            XCTAssertEqual($0 as? CompanionError, .unknownIdentity)
        }
    }

    func testVerifyRejectsAPairEpochMismatch() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-epoch", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let trusted = OwnerApprovalCheck.TrustedApprover(ownerIdentityID: owner.signer.identity.identityID,
                                                         approverIdentityID: pairing.approver.identityID,
                                                         approverPublicKey: pairing.approver.publicKey,
                                                         pairingID: pairing.pairingID, pairEpoch: pairing.epoch + 1,
                                                         consentGeneration: approval.consentGeneration, isActive: true)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted)) {
            XCTAssertEqual($0 as? CompanionError, .revokedPairing)
        }
    }

    func testVerifyRejectsAConsentGenerationMismatch() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-generation", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let trusted = trustedApprover(ownerIdentityID: owner.signer.identity.identityID, pairing: pairing,
                                      consentGeneration: approval.consentGeneration + 1)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted)) {
            XCTAssertEqual($0 as? CompanionError, .consentRequired)
        }
    }

    func testVerifyRejectsARequestNotOwnedByThisOwner() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-owner", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let trusted = trustedApprover(ownerIdentityID: "a-different-owner-identity", pairing: pairing,
                                      consentGeneration: approval.consentGeneration)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted)) {
            XCTAssertEqual($0 as? CompanionError, .unauthorized)
        }
    }

    func testVerifyRejectsAnApprovalForADifferentRequest() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let requestOne = try owner.requestUnlock(requestID: "oac-request-one", pairing: pairing, session: session,
                                                 target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let requestTwo = try owner.requestUnlock(requestID: "oac-request-two", pairing: pairing, session: session,
                                                 target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approvalForOne = try approver.submitApproval(request: requestOne, pairing: pairing, decision: .approved)
        let trusted = trustedApprover(ownerIdentityID: owner.signer.identity.identityID, pairing: pairing,
                                      consentGeneration: approvalForOne.consentGeneration)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approvalForOne, request: requestTwo, trustedApprover: trusted)) {
            XCTAssertEqual($0 as? CompanionError, .wrongTarget)
        }
    }

    func testVerifyRejectsAnApprovalThatIsNotApproved() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-declined", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .declined)
        let trusted = trustedApprover(ownerIdentityID: owner.signer.identity.identityID, pairing: pairing,
                                      consentGeneration: approval.consentGeneration)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted)) {
            XCTAssertEqual($0 as? CompanionError, .wrongTarget)
        }
    }
}
