import XCTest
@testable import CompanionKit

/// R5 Slice B2a: `OwnerApprovalCheck.verify` is the owner device's pure,
/// local pre-check on an `Approval` read out of its own anchored inbox,
/// before ever calling `useApproval`. Exercises every rejection case listed
/// in `docs/r5-b2-plan.md`'s B2a item 3, the review-round P2-1 convenience
/// initializer and the `ownerIdentity` parameter, plus the accepting path.
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
        let pairing = try pairV3(owner: owner, approver: approver, inviteID: "oac-invite", acceptanceID: "oac-accept", now: t,
                                 nonce: Data(repeating: 4, count: 24))
        let session = try ActiveSession(owner: ownerSigner.identity, sessionID: "oac-session", activeSetID: "oac-set",
                                        startsAt: t.addingTimeInterval(-1), endsAt: t.addingTimeInterval(3_600))
        _ = try owner.publishSession(session)
        return (relay, owner, approver, pairing, session)
    }

    private func trustedApprover(pairing: Pairing, consentGeneration: UInt64,
                                 isActive: Bool = true) -> OwnerApprovalCheck.TrustedApprover {
        OwnerApprovalCheck.TrustedApprover(approverIdentityID: pairing.approver.identityID,
                                           approverPublicKey: pairing.approver.publicKey,
                                           pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
                                           consentGeneration: consentGeneration, isActive: isActive)
    }

    private func liveConsent(relay: InMemoryCompanionRelay, pairing: Pairing) throws -> RelationshipConsent {
        try relay.consent(relationshipID: pairing.pairingID)
    }

    // MARK: - Accepting path (manual TrustedApprover)

    func testVerifyAcceptsAWellFormedApproval() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-ok", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let trusted = trustedApprover(pairing: pairing, consentGeneration: approval.consentGeneration)
        XCTAssertNoThrow(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted,
                                                       ownerIdentity: owner.signer.identity))
    }

    // MARK: - Accepting path (P2-1 convenience Pairing/RelationshipConsent initializer)

    func testTrustedApproverConvenienceInitDerivesAnActiveSnapshotFromAPairingAndConsent() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-convenience", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let consent = try liveConsent(relay: relay, pairing: pairing)
        let trusted = OwnerApprovalCheck.TrustedApprover(pairing: pairing, consent: consent)
        XCTAssertTrue(trusted.isActive)
        XCTAssertEqual(trusted.consentGeneration, consent.generation)
        XCTAssertNoThrow(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted,
                                                       ownerIdentity: owner.signer.identity))
    }

    func testTrustedApproverConvenienceInitIsInactiveWhenThePairingIsRevoked() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-revoked-pairing", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let consent = try liveConsent(relay: relay, pairing: pairing)
        let revoked = try Pairing(pairingID: pairing.pairingID, owner: pairing.owner, approver: pairing.approver,
                                  epoch: pairing.epoch, createdAt: pairing.createdAt, state: .revoked)
        let trusted = OwnerApprovalCheck.TrustedApprover(pairing: revoked, consent: consent)
        XCTAssertFalse(trusted.isActive)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .revokedPairing)
        }
    }

    func testTrustedApproverConvenienceInitIsInactiveWhenConsentNoLongerAuthorizesBothScopes() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-partial-consent", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        // The owner revokes `receiveRequests` only -- the approver side still
        // authorizes it, but bilateral authorization now requires both.
        _ = try owner.revokeScopes(pairing: pairing, scopes: [.receiveRequests])
        let consent = try liveConsent(relay: relay, pairing: pairing)
        let trusted = OwnerApprovalCheck.TrustedApprover(pairing: pairing, consent: consent)
        XCTAssertFalse(trusted.isActive)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .revokedPairing)
        }
    }

    func testTrustedApproverConvenienceInitIsInactiveWhenPairingAndConsentDescribeDifferentRelationships() throws {
        let (relay, owner, approver, pairing, _) = try harness()
        let consent = try liveConsent(relay: relay, pairing: pairing)
        // A consent record for an unrelated pairing (different pairingID) --
        // must never be accepted as authorizing this pairing, even though
        // its scopes/state look authorized in isolation.
        let unrelatedConsent = try RelationshipConsent(relationshipID: "unrelated-pairing", pairingID: "unrelated-pairing",
                                                        pairEpoch: 1, owner: owner.signer.identity, approver: approver.signer.identity,
                                                        ownerScopes: [.approveEarlyEnd, .receiveRequests],
                                                        approverScopes: [.approveEarlyEnd, .receiveRequests],
                                                        ownerState: .active, approverState: .active,
                                                        updatedAt: t, generation: consent.generation)
        let trusted = OwnerApprovalCheck.TrustedApprover(pairing: pairing, consent: unrelatedConsent)
        XCTAssertFalse(trusted.isActive)
    }

    // MARK: - Rejection cases

    func testVerifyRejectsARevokedApprover() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-revoked", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let trusted = trustedApprover(pairing: pairing, consentGeneration: approval.consentGeneration, isActive: false)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .revokedPairing)
        }
    }

    func testVerifyRejectsAnUnknownApproverIdentity() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-unknown", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let trusted = OwnerApprovalCheck.TrustedApprover(approverIdentityID: "a-completely-different-identity",
                                                         approverPublicKey: pairing.approver.publicKey,
                                                         pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
                                                         consentGeneration: approval.consentGeneration, isActive: true)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .unknownIdentity)
        }
    }

    func testVerifyRejectsAPublicKeyMismatch() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-key", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let trusted = OwnerApprovalCheck.TrustedApprover(approverIdentityID: pairing.approver.identityID,
                                                         approverPublicKey: Data(repeating: 0xAB, count: 32),
                                                         pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
                                                         consentGeneration: approval.consentGeneration, isActive: true)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .unknownIdentity)
        }
    }

    func testVerifyRejectsAPairingIDMismatch() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-pairing-id", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let trusted = OwnerApprovalCheck.TrustedApprover(approverIdentityID: pairing.approver.identityID,
                                                         approverPublicKey: pairing.approver.publicKey,
                                                         pairingID: "a-different-pairing-id", pairEpoch: pairing.epoch,
                                                         consentGeneration: approval.consentGeneration, isActive: true)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .wrongTarget)
        }
    }

    func testVerifyRejectsAPairEpochMismatch() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-epoch", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let trusted = OwnerApprovalCheck.TrustedApprover(approverIdentityID: pairing.approver.identityID,
                                                         approverPublicKey: pairing.approver.publicKey,
                                                         pairingID: pairing.pairingID, pairEpoch: pairing.epoch + 1,
                                                         consentGeneration: approval.consentGeneration, isActive: true)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .revokedPairing)
        }
    }

    func testVerifyRejectsAConsentGenerationMismatch() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-generation", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let trusted = trustedApprover(pairing: pairing, consentGeneration: approval.consentGeneration + 1)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .consentRequired)
        }
    }

    func testVerifyRejectsARequestNotOwnedByThisOwner() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-owner", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let trusted = trustedApprover(pairing: pairing, consentGeneration: approval.consentGeneration)
        let otherOwnerKeys = InMemoryDeviceKeyStore()
        let otherOwnerSigner = try DeviceSigner.create(role: .owner, keyStore: otherOwnerKeys)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted,
                                                           ownerIdentity: otherOwnerSigner.identity)) {
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
        let trusted = trustedApprover(pairing: pairing, consentGeneration: approvalForOne.consentGeneration)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approvalForOne, request: requestTwo, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .wrongTarget)
        }
    }

    func testVerifyRejectsAnApprovalForADifferentSession() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-diff-session", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let accepted = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let tampered = Approval(approvalID: accepted.approvalID, requestID: accepted.requestID, pairingID: accepted.pairingID,
                                pairEpoch: accepted.pairEpoch, sessionID: "a-different-session-id", activeSetID: accepted.activeSetID,
                                approver: accepted.approver, decision: accepted.decision, issuedAt: accepted.issuedAt,
                                consentGeneration: accepted.consentGeneration, nonce: accepted.nonce, signature: accepted.signature)
        let trusted = trustedApprover(pairing: pairing, consentGeneration: accepted.consentGeneration)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: tampered, request: request, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .wrongTarget)
        }
    }

    func testVerifyRejectsAnApprovalForADifferentActiveSet() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-diff-active-set", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let accepted = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let tampered = Approval(approvalID: accepted.approvalID, requestID: accepted.requestID, pairingID: accepted.pairingID,
                                pairEpoch: accepted.pairEpoch, sessionID: accepted.sessionID, activeSetID: "a-different-active-set",
                                approver: accepted.approver, decision: accepted.decision, issuedAt: accepted.issuedAt,
                                consentGeneration: accepted.consentGeneration, nonce: accepted.nonce, signature: accepted.signature)
        let trusted = trustedApprover(pairing: pairing, consentGeneration: accepted.consentGeneration)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: tampered, request: request, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .wrongTarget)
        }
    }

    func testVerifyRejectsARequestBindingMismatch() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-binding", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        // A *local* copy of the request whose binding for this approver
        // claims a different pairingID than the one `approval`/
        // `trustedApprover` both agree on -- simulates a stale/corrupted
        // local request cache, independent of `trustedApprover.pairingID`
        // itself (which is checked separately).
        let staleBinding = try RequestTargetBinding(approverIdentityID: approver.signer.identity.identityID,
                                                    pairingID: "a-stale-pairing-id", pairEpoch: pairing.epoch,
                                                    consentGeneration: approval.consentGeneration)
        let staleRequest = try TrustedRequest(requestID: request.requestID, owner: request.owner, targetBindings: [staleBinding],
                                              session: session, message: nil, createdAt: request.createdAt,
                                              expiresAt: request.expiresAt)
        let trusted = trustedApprover(pairing: pairing, consentGeneration: approval.consentGeneration)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: staleRequest, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .wrongTarget)
        }
    }

    func testVerifyRejectsANonTrustedApproverRole() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-role", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let accepted = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let ownerRoleIdentity = try DeviceIdentity(identityID: accepted.approver.identityID, role: .owner,
                                                   publicKey: accepted.approver.publicKey)
        let impersonating = Approval(approvalID: accepted.approvalID, requestID: accepted.requestID, pairingID: accepted.pairingID,
                                     pairEpoch: accepted.pairEpoch, sessionID: accepted.sessionID, activeSetID: accepted.activeSetID,
                                     approver: ownerRoleIdentity, decision: accepted.decision, issuedAt: accepted.issuedAt,
                                     consentGeneration: accepted.consentGeneration, nonce: accepted.nonce, signature: accepted.signature)
        let trusted = trustedApprover(pairing: pairing, consentGeneration: accepted.consentGeneration)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: impersonating, request: request, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .unknownIdentity)
        }
    }

    func testVerifyRejectsAnApprovalThatIsNotApproved() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-declined", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .declined)
        let trusted = trustedApprover(pairing: pairing, consentGeneration: approval.consentGeneration)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: approval, request: request, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .wrongTarget)
        }
    }

    func testVerifyRejectsAnInvalidSignature() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "oac-request-bad-sig", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let accepted = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        var corruptedSignature = accepted.signature
        corruptedSignature[0] ^= 0xFF
        let corrupted = Approval(approvalID: accepted.approvalID, requestID: accepted.requestID, pairingID: accepted.pairingID,
                                 pairEpoch: accepted.pairEpoch, sessionID: accepted.sessionID, activeSetID: accepted.activeSetID,
                                 approver: accepted.approver, decision: accepted.decision, issuedAt: accepted.issuedAt,
                                 consentGeneration: accepted.consentGeneration, nonce: accepted.nonce, signature: corruptedSignature)
        let trusted = trustedApprover(pairing: pairing, consentGeneration: accepted.consentGeneration)
        XCTAssertThrowsError(try OwnerApprovalCheck.verify(approval: corrupted, request: request, trustedApprover: trusted,
                                                           ownerIdentity: owner.signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .invalidSignature)
        }
    }
}
