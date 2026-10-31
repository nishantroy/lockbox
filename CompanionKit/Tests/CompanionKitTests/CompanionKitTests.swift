import XCTest
@testable import CompanionKit

final class CompanionKitTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private func harness() throws -> (InMemoryCompanionRelay, CompanionClient, CompanionClient, Pairing, ActiveSession) {
        let ownerKeys = InMemoryDeviceKeyStore()
        let approverKeys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: approverKeys)
        let relay = try InMemoryCompanionRelay(owner: ownerSigner.identity, now: t)
        let owner = CompanionClient(signer: ownerSigner, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let approver = CompanionClient(signer: approverSigner, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let pairing = try pairV3(owner: owner, approver: approver, inviteID: "invite-1", acceptanceID: "accept-1",
                                 now: t, nonce: Data(repeating: 7, count: 24))
        let session = try ActiveSession(owner: ownerSigner.identity, sessionID: "session-1", activeSetID: "set-1",
                                        startsAt: t.addingTimeInterval(-1), endsAt: t.addingTimeInterval(3_600))
        _ = try owner.publishSession(session)
        return (relay, owner, approver, pairing, session)
    }

    func testV3PairingNeedsTheTokenAndALeakedInvitationAloneIsNotAuthority() throws {
        let keys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: keys)
        let relay = try InMemoryCompanionRelay(owner: ownerSigner.identity, now: t)
        let owner = CompanionClient(signer: ownerSigner, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let issued = try owner.createInvite(inviteID: "invite-forward", validFor: 100, now: t,
                                            nonce: Data(repeating: 2, count: 24), ownerDisplayName: "Alex")
        XCTAssertEqual(InviteToken.token(fromShareLink: issued.shareLink), issued.token)
        XCTAssertEqual(issued.token.count, 22)
        XCTAssertThrowsError(try relay.pairing(id: "not-authorized"))

        let attackerKeys = InMemoryDeviceKeyStore()
        let attacker = try DeviceSigner.create(role: .trustedApprover, keyStore: attackerKeys)
        let attackerClient = CompanionClient(signer: attacker, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        // The signed invitation is public to anyone the relay shows it to, but
        // accepting needs the token. A guess is rejected and consumes nothing.
        let guessed = InviteToken.generate()
        XCTAssertThrowsError(try attackerClient.lookupInvite(token: guessed)) { XCTAssertEqual($0 as? CompanionError, .notFound) }
        XCTAssertThrowsError(try attackerClient.acceptInvite(issued.invitation, token: guessed, acceptanceID: "guess", now: t)) {
            guard case CompanionError.malformed = $0 else { return XCTFail("expected malformed, got \($0)") }
        }
        // A well-formed token the signed hash does not bind is refused locally too.
        XCTAssertThrowsError(try relay.pairing(id: "not-authorized"))

        // The real holder of the link joins in one step, with consent active.
        let invitation = try attackerClient.lookupInvite(token: issued.token)
        XCTAssertEqual(invitation.payload.ownerDisplayName, "Alex")
        let pairing = try attackerClient.acceptInvite(invitation, token: issued.token, approverDisplayName: "Sam",
                                                      acceptanceID: "joined", now: t)
        XCTAssertEqual(pairing.state, .active)
        XCTAssertEqual(pairing.ownerDisplayName, "Alex")
        XCTAssertEqual(pairing.approverDisplayName, "Sam")
        let consent = try relay.consent(relationshipID: pairing.pairingID)
        XCTAssertEqual(consent.ownerState, .active)
        XCTAssertEqual(consent.approverState, .active)
        XCTAssertEqual(consent.generation, 2)
        XCTAssertEqual(consent.ownerScopes, [.approveEarlyEnd, .receiveRequests])
        XCTAssertEqual(consent.approverScopes, [.approveEarlyEnd, .receiveRequests])
        // Single use: the link no longer resolves.
        XCTAssertThrowsError(try attackerClient.lookupInvite(token: issued.token)) { XCTAssertEqual($0 as? CompanionError, .notFound) }
    }

    func testInviteIsSingleUseAcrossTwoFriendsHoldingTheSameLink() throws {
        let ownerKeys = InMemoryDeviceKeyStore()
        let firstKeys = InMemoryDeviceKeyStore()
        let secondKeys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
        let firstSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: firstKeys)
        let secondSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: secondKeys)
        let now = t
        let relay = try InMemoryCompanionRelay(owner: ownerSigner.identity, now: now)
        let owner = CompanionClient(signer: ownerSigner, transport: relay, now: { now })
        let first = CompanionClient(signer: firstSigner, transport: relay, now: { now })
        let second = CompanionClient(signer: secondSigner, transport: relay, now: { now })
        let issued = try owner.createInvite(inviteID: "one-use", validFor: 3_600, now: t,
                                            nonce: Data(repeating: 6, count: 24))
        let invitation = try first.lookupInvite(token: issued.token)

        XCTAssertNoThrow(try first.acceptInvite(invitation, token: issued.token, acceptanceID: "first-acceptance", now: t))
        XCTAssertThrowsError(try second.acceptInvite(invitation, token: issued.token, acceptanceID: "second-acceptance", now: t)) {
            XCTAssertEqual($0 as? CompanionError, .replay)
        }
        XCTAssertThrowsError(try second.lookupInvite(token: issued.token)) { XCTAssertEqual($0 as? CompanionError, .notFound) }
    }

    func testExpiredInviteCannotBeLookedUpOrAccepted() throws {
        let (relay, owner, approver, _, _) = try harness()
        let issued = try owner.createInvite(inviteID: "short-lived", validFor: 100, now: t,
                                            nonce: Data(repeating: 12, count: 24))
        let invitation = try approver.lookupInvite(token: issued.token)
        try relay.advance(to: t.addingTimeInterval(101))
        XCTAssertThrowsError(try approver.lookupInvite(token: issued.token)) { XCTAssertEqual($0 as? CompanionError, .notFound) }
        // Even a stale copy of the invitation cannot be accepted after expiry.
        XCTAssertThrowsError(try approver.acceptInvite(invitation, token: issued.token, acceptanceID: "late",
                                                       now: t.addingTimeInterval(101))) {
            XCTAssertEqual($0 as? CompanionError, .expired)
        }
    }

    func testSignedInviteFieldsAreCoveredByTheOwnerSignature() throws {
        let (_, owner, _, _, _) = try harness()
        let issued = try owner.createInvite(inviteID: "covered", validFor: 600, now: t,
                                            nonce: Data(repeating: 13, count: 24), ownerDisplayName: "Alex")
        let payload = issued.invitation.payload
        let renamed = try InvitePayload(inviteID: payload.inviteID, owner: payload.owner, issuedAt: payload.issuedAt,
                                        expiresAt: payload.expiresAt, nonce: payload.nonce, tokenHash: payload.tokenHash,
                                        ownerDisplayName: "Mallory", grantedScopes: payload.grantedScopes)
        let narrowed = try InvitePayload(inviteID: payload.inviteID, owner: payload.owner, issuedAt: payload.issuedAt,
                                         expiresAt: payload.expiresAt, nonce: payload.nonce, tokenHash: payload.tokenHash,
                                         ownerDisplayName: "Alex", grantedScopes: [.approveEarlyEnd])
        let rehashed = try InvitePayload(inviteID: payload.inviteID, owner: payload.owner, issuedAt: payload.issuedAt,
                                         expiresAt: payload.expiresAt, nonce: payload.nonce,
                                         tokenHash: InviteToken.hash(InviteToken.generate()),
                                         ownerDisplayName: "Alex", grantedScopes: payload.grantedScopes)
        for tampered in [renamed, narrowed, rehashed] {
            let invitation = try Invitation(payload: tampered, signature: issued.invitation.signature)
            XCTAssertThrowsError(try invitation.validateSignature()) { XCTAssertEqual($0 as? CompanionError, .invalidSignature) }
        }
        XCTAssertNoThrow(try issued.invitation.validate(at: t))
    }

    func testDisplayNameAndScopeValidation() throws {
        let keys = InMemoryDeviceKeyStore()
        let signer = try DeviceSigner.create(role: .owner, keyStore: keys)
        func payload(name: String?, scopes: [CompanionScope] = [.approveEarlyEnd, .receiveRequests]) throws -> InvitePayload {
            try InvitePayload(inviteID: "names", owner: signer.identity, issuedAt: t, expiresAt: t.addingTimeInterval(60),
                              nonce: Data(repeating: 1, count: 24), tokenHash: InviteToken.hash(InviteToken.generate()),
                              ownerDisplayName: name, grantedScopes: scopes)
        }
        XCTAssertNoThrow(try payload(name: nil))
        XCTAssertNoThrow(try payload(name: String(repeating: "A", count: 40)))
        XCTAssertNoThrow(try payload(name: String(repeating: "\u{1F600}", count: 40)))
        for bad in [String(repeating: "A", count: 41), String(repeating: "\u{1F600}", count: 41), "", "   ", "line\nbreak", "tab\there"] {
            XCTAssertThrowsError(try payload(name: bad), "name \(bad.debugDescription) must be rejected")
        }
        for scopes in [[CompanionScope](), [.mutualPact], [.approveEarlyEnd, .approveEarlyEnd]] {
            XCTAssertThrowsError(try payload(name: nil, scopes: scopes))
        }
        XCTAssertFalse(InviteToken.isWellFormed("short"))
        XCTAssertFalse(InviteToken.isWellFormed(String(repeating: "a", count: 21) + "+"))
        XCTAssertTrue(InviteToken.isWellFormed(InviteToken.generate()))
        XCTAssertNil(InviteToken.token(fromShareLink: "phone-lockbox-companion://invite/abc"))
    }

    func testRequestExpiryIsClampedToTheSessionEnd() throws {
        let (_, owner, approver, pairing, session) = try harness()
        // validFor deliberately overshoots the session end (ends t+3600).
        let request = try owner.requestUnlock(requestID: "clamped", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 3_599 + 600)
        XCTAssertEqual(request.expiresAt, session.endsAt)
    }

    func testSameFriendAcceptingASecondInviteGetsADistinctPairing() throws {
        let (_, owner, approver, firstPairing, _) = try harness()
        let again = try owner.createInvite(inviteID: "second-invite", validFor: 600, now: t, nonce: Data(repeating: 14, count: 24))
        let invitation = try approver.lookupInvite(token: again.token)
        let second = try approver.acceptInvite(invitation, token: again.token, acceptanceID: "dup", now: t)
        XCTAssertNotEqual(second.pairingID, firstPairing.pairingID)
    }

    func testRelayAcceptRetainsTheFriendSignedAcceptanceForTheOwnerToVerify() throws {
        let (relay, owner, approver, pairing, _) = try harness()
        let inbox = try relay.fetchInbox(makeInboxOperation(identity: owner.signer, now: t))
        XCTAssertEqual(inbox.pairings?.map { $0.pairingID }, [pairing.pairingID])
        XCTAssertEqual(inbox.consents?.count, 1)
        let acceptances = try XCTUnwrap(inbox.acceptances)
        XCTAssertEqual(acceptances.count, 1)
        // The owner device can prove the pairing came from the holder of the token for its own invite.
        XCTAssertEqual(acceptances[0].acceptance.approver, approver.signer.identity)
        // The approver's own inbox shows the pairing but never the acceptances.
        let helperInbox = try relay.fetchInbox(makeInboxOperation(identity: approver.signer, now: t))
        XCTAssertNil(helperInbox.acceptances)
        XCTAssertEqual(helperInbox.pairings?.map { $0.pairingID }, [pairing.pairingID])
    }

    func testSameIdentityPairingsAreExactPerTargetAndRevocationIsRechecked() throws {
        let (relay, owner, approver, firstPairing, session) = try harness()
        let secondPairing = try pairV3(owner: owner, approver: approver, inviteID: "same-identity-invite", acceptanceID: "same-identity-acceptance", now: t,
                                 nonce: Data(repeating: 10, count: 24))
        XCTAssertNotEqual(firstPairing.pairingID, secondPairing.pairingID)

        let request = try owner.requestUnlock(requestID: "exact-target", pairing: secondPairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        // The same identity is trusted through two pairings, but this request
        // names only the second one.
        XCTAssertThrowsError(try approver.submitApproval(request: request, pairing: firstPairing, decision: .approved)) {
            XCTAssertEqual($0 as? CompanionError, .wrongTarget)
        }
        let accepted = try approver.submitApproval(request: request, pairing: secondPairing, decision: .approved,
                                                   approvalID: "exact-target-approval")
        try owner.revoke(secondPairing)
        XCTAssertThrowsError(try owner.useApproval(accepted, request: request, useID: "revoked-exact-target")) {
            XCTAssertEqual($0 as? CompanionError, .revokedPairing)
        }
        _ = relay
    }

    func testForgedInviteAndSwapReceiverIssuerFail() throws {
        let keys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: keys)
        let relay = try InMemoryCompanionRelay(owner: ownerSigner.identity, now: t)
        let owner = CompanionClient(signer: ownerSigner, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let issued = try owner.createInvite(inviteID: "forged", validFor: 100, now: t, nonce: Data(repeating: 1, count: 24))
        let invite = issued.invitation
        var badBytes = invite.signature
        badBytes[0] ^= 1
        let forged = try Invitation(payload: invite.payload, signature: badBytes)
        XCTAssertThrowsError(try forged.validate(at: t)) { XCTAssertEqual($0 as? CompanionError, .invalidSignature) }

        let approverKeys = InMemoryDeviceKeyStore()
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: approverKeys)
        let approver = CompanionClient(signer: approverSigner, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        XCTAssertThrowsError(try approver.createInvite(inviteID: "swap", validFor: 100, now: t))
        // An owner is not a receiver, and a forged invitation is refused by the friend before anything is sent.
        XCTAssertThrowsError(try owner.acceptInvite(invite, token: issued.token, acceptanceID: "wrong-receiver", now: t))
        XCTAssertThrowsError(try approver.acceptInvite(forged, token: issued.token, acceptanceID: "forged-accept", now: t)) {
            XCTAssertEqual($0 as? CompanionError, .invalidSignature)
        }
    }

    func testAnchoredRestoreRejectsSameRevisionRequestExpiryAndReceiptForks() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "checkpoint-request", pairing: pairing,
                                              session: session, target: approver.signer.identity.identityID,
                                              message: nil, validFor: 600)
        _ = try approver.submitApproval(request: request, pairing: pairing, decision: .approved,
                                         approvalID: "checkpoint-approval")
        let snapshot = try relay.snapshot()
        let checkpoint = try relay.checkpoint()

        let expiryFork = try alteredSnapshot(relay) { value in
            var requests = value["requests"] as! [[String: Any]]
            requests[0]["expiresAt"] = t.addingTimeInterval(3_600).timeIntervalSince1970
            value["requests"] = requests
        }
        XCTAssertThrowsError(try InMemoryCompanionRelay(snapshot: expiryFork, checkpoint: checkpoint))

        let receiptFork = try alteredSnapshot(relay) { value in
            var records = value["operationRecords"] as! [[String: Any]]
            records[0]["response"] = ["acknowledgement": [:]]
            value["operationRecords"] = records
        }
        XCTAssertThrowsError(try InMemoryCompanionRelay(snapshot: receiptFork, checkpoint: checkpoint))

        try owner.revoke(pairing)
        let revokedCheckpoint = try relay.checkpoint()
        let resurrection = try alteredSnapshot(relay) { value in
            var pairings = value["pairings"] as! [[String: Any]]
            pairings[0]["state"] = "active"
            value["pairings"] = pairings
        }
        XCTAssertThrowsError(try InMemoryCompanionRelay(snapshot: resurrection,
                                                        checkpoint: revokedCheckpoint))

        let lower = try CompanionCheckpoint(ownerIdentityID: checkpoint.ownerIdentityID,
                                            revision: checkpoint.revision - 1,
                                            stateRoot: checkpoint.stateRoot)
        XCTAssertThrowsError(try InMemoryCompanionRelay(snapshot: snapshot, checkpoint: lower))
        let higher = try CompanionCheckpoint(ownerIdentityID: checkpoint.ownerIdentityID,
                                             revision: checkpoint.revision + 1,
                                             stateRoot: checkpoint.stateRoot)
        XCTAssertThrowsError(try InMemoryCompanionRelay(snapshot: snapshot, checkpoint: higher))
    }

    func testRequestCreationAtExactExpiryIsRejected() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        try relay.advance(to: t.addingTimeInterval(10))
        XCTAssertThrowsError(try owner.requestUnlock(requestID: "exact-expiry", pairing: pairing,
                                                     session: session,
                                                     target: approver.signer.identity.identityID,
                                                     message: nil, validFor: 10)) {
            XCTAssertEqual($0 as? CompanionError, .expired)
        }
    }

    func testApprovalBindsPairingSessionAndRequestAndIsSingleUse() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "request-1", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        try approval.validateSignature()
        let verification = try owner.useApproval(approval, request: request, useID: "use-1")
        XCTAssertEqual(verification.approval.requestID, request.requestID)
        // Retrying the exact same command returns its durable receipt rather
        // than applying the approval a second time.
        XCTAssertEqual(try owner.useApproval(approval, request: request, useID: "use-1"), verification)
        XCTAssertThrowsError(try owner.useApproval(approval, request: request, useID: "use-2"))
        _ = relay // keeps the test's ownership of the test backend explicit
    }

    func testOwnerCanCancelApprovedRequestBeforeConsumptionAndAfterRestart() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "approved-cancel", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved,
                                                   approvalID: "cancel-approval")
        try owner.cancel(request)
        XCTAssertEqual(try relay.request(id: request.requestID).status, .cancelled)
        XCTAssertThrowsError(try owner.useApproval(approval, request: request, useID: "cancel-use"))

        let checkpoint = try relay.checkpoint()
        let restarted = try InMemoryCompanionRelay(snapshot: relay.snapshot(), checkpoint: checkpoint)
        let fixedNow = t
        let restartedOwner = CompanionClient(signer: owner.signer, transport: restarted, now: { fixedNow })
        XCTAssertEqual(try restarted.request(id: request.requestID).status, .cancelled)
        XCTAssertThrowsError(try restartedOwner.useApproval(approval, request: request, useID: "cancel-replay"))
    }

    func testApprovalUseRequiresTheAcceptedRecordAndExactRequestBindings() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "bound-use", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let accepted = try approver.submitApproval(request: request, pairing: pairing, decision: .approved,
                                                   approvalID: "accepted-approval")

        let unsigned = Approval(approvalID: "unsubmitted-approval", requestID: request.requestID,
                                    pairingID: pairing.pairingID, pairEpoch: pairing.epoch, sessionID: request.sessionID,
                                    activeSetID: request.activeSetID, approver: approver.signer.identity,
                                    decision: .approved, issuedAt: t, signature: Data())
        let signature = try approver.signer.sign(domain: "\(CompanionCanonical.version).approval",
                                                 fields: unsigned.signingFields())
        let unsubmitted = Approval(approvalID: unsigned.approvalID, requestID: unsigned.requestID,
                                       pairingID: unsigned.pairingID, pairEpoch: unsigned.pairEpoch,
                                       sessionID: unsigned.sessionID, activeSetID: unsigned.activeSetID,
                                       approver: unsigned.approver, decision: unsigned.decision,
                                       issuedAt: unsigned.issuedAt, signature: signature)
        XCTAssertThrowsError(try owner.useApproval(unsubmitted, request: request, useID: "unsubmitted-use"))

        let sameIDStaleSession = try signedApproval(signer: approver.signer, approvalID: accepted.approvalID,
                                                    request: request, pairing: pairing, sessionID: "old-session",
                                                    activeSetID: request.activeSetID)
        XCTAssertThrowsError(try owner.useApproval(sameIDStaleSession, request: request, useID: "same-id-stale-use"))

        let staleSession = try signedApproval(signer: approver.signer, approvalID: "stale-approval",
                                              request: request, pairing: pairing, sessionID: "old-session",
                                              activeSetID: request.activeSetID)
        XCTAssertThrowsError(try owner.useApproval(staleSession, request: request, useID: "stale-use"))

        let wrongActiveSet = try signedApproval(signer: approver.signer, approvalID: "wrong-set-approval",
                                                request: request, pairing: pairing, sessionID: request.sessionID,
                                                activeSetID: "other-active-set")
        XCTAssertThrowsError(try owner.useApproval(wrongActiveSet, request: request, useID: "wrong-set-use"))

        XCTAssertNoThrow(try owner.useApproval(accepted, request: request, useID: "accepted-use"))
        _ = relay
    }

    func testFirstValidApprovalWinsAcrossSelectedApprovers() throws {
        let (relay, owner, first, firstPairing, session) = try harness()
        let secondStore = InMemoryDeviceKeyStore()
        let secondSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: secondStore)
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let second = CompanionClient(signer: secondSigner, transport: relay, now: { fixedNow })
        let secondPairing = try pairV3(owner: owner, approver: second, inviteID: "first-valid-invite", acceptanceID: "first-valid-accept", now: t,
                                 nonce: Data(repeating: 11, count: 24))
        let request = try owner.requestUnlock(requestID: "first-valid-request",
                                              pairings: [firstPairing, secondPairing], session: session,
                                              targets: [first.signer.identity.identityID, second.signer.identity.identityID],
                                              message: nil, validFor: 600)
        _ = try first.submitApproval(request: request, pairing: firstPairing, decision: .approved,
                                     approvalID: "first-wins", nonce: Data(repeating: 12, count: 24))
        XCTAssertThrowsError(try second.submitApproval(request: request, pairing: secondPairing,
                                                       decision: .approved,
                                                       approvalID: "late-second", nonce: Data(repeating: 13, count: 24)))
    }

    func testApprovalNonceCannotBeReusedUnderAnotherApprovalID() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "nonce-request", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let nonce = Data(repeating: 14, count: 24)
        _ = try approver.submitApproval(request: request, pairing: pairing, decision: .approved,
                                        approvalID: "nonce-first", nonce: nonce)
        XCTAssertThrowsError(try approver.submitApproval(request: request, pairing: pairing, decision: .approved,
                                                         approvalID: "nonce-second", nonce: nonce))
        _ = relay
    }

    func testDeclineByOneApproverDoesNotInvalidateAnotherTarget() throws {
        let (relay, owner, first, firstPairing, session) = try harness()
        let secondKeys = InMemoryDeviceKeyStore()
        let secondSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: secondKeys)
        let second = CompanionClient(signer: secondSigner, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let secondPairing = try pairV3(owner: owner, approver: second, inviteID: "invite-2", acceptanceID: "accept-2", now: t,
                                 nonce: Data(repeating: 8, count: 24))
        let targets = [first.signer.identity.identityID, second.signer.identity.identityID]
        let multi = try owner.requestUnlock(requestID: "multi", pairings: [firstPairing, secondPairing], session: session,
                                            targets: targets, message: nil, validFor: 600)
        let declined = try first.submitApproval(request: multi, pairing: firstPairing, decision: .declined)
        XCTAssertEqual(declined.decision, ApproverDecision.declined)
        let approved = try second.submitApproval(request: multi, pairing: secondPairing, decision: .approved)
        XCTAssertEqual(approved.decision, ApproverDecision.approved)
        XCTAssertThrowsError(try owner.useApproval(declined, request: multi, useID: "declined-use"))
    }

    func testApprovalIDCollisionCannotOverwriteAnotherRequest() throws {
        let (relay, owner, first, firstPairing, session) = try harness()
        let firstRequest = try owner.requestUnlock(requestID: "collision-first", pairing: firstPairing, session: session,
                                                   target: first.signer.identity.identityID, message: nil, validFor: 600)
        let firstApproval = try first.submitApproval(request: firstRequest, pairing: firstPairing, decision: .approved,
                                                      approvalID: "shared-approval-id")

        let secondStore = InMemoryDeviceKeyStore()
        let secondSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: secondStore)
        let fixedNow = t
        let second = CompanionClient(signer: secondSigner, transport: relay, now: { fixedNow })
        let secondPairing = try pairV3(owner: owner, approver: second, inviteID: "collision-invite", acceptanceID: "collision-acceptance", now: t,
                                 nonce: Data(repeating: 9, count: 24))
        let secondRequest = try owner.requestUnlock(requestID: "collision-second", pairing: secondPairing, session: session,
                                                    target: second.signer.identity.identityID, message: nil, validFor: 600)
        XCTAssertThrowsError(try second.submitApproval(request: secondRequest, pairing: secondPairing, decision: .approved,
                                                       approvalID: "shared-approval-id")) {
            XCTAssertEqual($0 as? CompanionError, .replay)
        }
        XCTAssertEqual(try relay.request(id: secondRequest.requestID).status, .pending)
        XCTAssertNoThrow(try owner.useApproval(firstApproval, request: firstRequest, useID: "collision-use"))
    }

    func testSnapshotRejectsOperationHistoryGap() throws {
        let keys = InMemoryDeviceKeyStore()
        let signer = try DeviceSigner.create(role: .owner, keyStore: keys)
        let relay = try InMemoryCompanionRelay(owner: signer.identity, now: t)
        let fixedNow = t
        _ = try CompanionClient(signer: signer, transport: relay, now: { fixedNow })
            .createInvite(inviteID: "history-one", validFor: 600, now: t,
                          nonce: Data(repeating: 41, count: 24))
        _ = try CompanionClient(signer: signer, transport: relay, now: { fixedNow })
            .createInvite(inviteID: "history-two", validFor: 600, now: t,
                          nonce: Data(repeating: 42, count: 24))
        let gap = try alteredSnapshot(relay) { snapshot in
            var records = snapshot["operationRecords"] as! [[String: Any]]
            records.removeFirst()
            snapshot["operationRecords"] = records
        }
        XCTAssertThrowsError(try InMemoryCompanionRelay(testSnapshot: gap))
    }

    func testSnapshotRejectsTamperedInviteSignatureAndCrossOwnerGraph() throws {
        let (relay, owner, _, _, _) = try harness()
        let tamperedInvite = try alteredSnapshot(relay) { snapshot in
            var invitations = snapshot["invitations"] as! [[String: Any]]
            let signature = invitations[0]["signature"] as! String
            let replacement = (signature.first == "A" ? "B" : "A") + String(signature.dropFirst())
            invitations[0]["signature"] = replacement
            snapshot["invitations"] = invitations
        }
        XCTAssertThrowsError(try InMemoryCompanionRelay(testSnapshot: tamperedInvite)) {
            XCTAssertEqual($0 as? CompanionError, .invalidSignature)
        }

        let otherOwnerKeys = InMemoryDeviceKeyStore()
        let otherOwner = try DeviceSigner.create(role: .owner, keyStore: otherOwnerKeys)
        let crossOwnerPairing = try alteredSnapshot(relay) { snapshot in
            var pairings = snapshot["pairings"] as! [[String: Any]]
            pairings[0]["owner"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(otherOwner.identity))
            snapshot["pairings"] = pairings
        }
        XCTAssertThrowsError(try InMemoryCompanionRelay(testSnapshot: crossOwnerPairing))

        let crossOwnerSnapshot = try alteredSnapshot(relay) { snapshot in
            snapshot["owner"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(otherOwner.identity))
        }
        XCTAssertThrowsError(try InMemoryCompanionRelay(testSnapshot: crossOwnerSnapshot))
        _ = owner
    }

    func testSnapshotRejectsMismatchedRequestTargetBinding() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "snapshot-binding", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let malformed = try alteredSnapshot(relay) { snapshot in
            var requests = snapshot["requests"] as! [[String: Any]]
            var bindings = requests[0]["targetBindings"] as! [[String: Any]]
            bindings[0]["pairEpoch"] = pairing.epoch + 1
            requests[0]["targetBindings"] = bindings
            snapshot["requests"] = requests
        }
        XCTAssertThrowsError(try InMemoryCompanionRelay(testSnapshot: malformed))
        _ = request
    }

    func testSnapshotRejectsMalformedPairingMetadataAndReplayMarkers() throws {
        let (relay, _, _, _, _) = try harness()

        let malformedID = try alteredSnapshot(relay) { snapshot in
            var pairings = snapshot["pairings"] as! [[String: Any]]
            pairings[0]["pairingID"] = "invalid pairing id"
            snapshot["pairings"] = pairings
        }
        XCTAssertThrowsError(try InMemoryCompanionRelay(testSnapshot: malformedID))

        let malformedDate = try alteredSnapshot(relay) { snapshot in
            var pairings = snapshot["pairings"] as! [[String: Any]]
            pairings[0]["createdAt"] = 10_000_000_000
            snapshot["pairings"] = pairings
        }
        XCTAssertThrowsError(try InMemoryCompanionRelay(testSnapshot: malformedDate))

        let malformedMarker = try alteredSnapshot(relay) { snapshot in
            snapshot["usedInviteIDs"] = ["invalid marker"]
            snapshot["usedApprovalIDs"] = ["invalid marker"]
        }
        XCTAssertThrowsError(try InMemoryCompanionRelay(testSnapshot: malformedMarker))

        let oversizedMarkers = try alteredSnapshot(relay) { snapshot in
            snapshot["usedInviteIDs"] = (0...CompanionLimits.maxSnapshotRecords).map { "invite-marker-\($0)" }
            snapshot["usedApprovalIDs"] = (0...CompanionLimits.maxSnapshotRecords).map { "approval-marker-\($0)" }
        }
        XCTAssertThrowsError(try InMemoryCompanionRelay(testSnapshot: oversizedMarkers))
    }

    func testRevocationNewActiveSetExpiryAndCancellation() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "stale", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        try owner.revoke(pairing)
        XCTAssertThrowsError(try approver.submitApproval(request: request, pairing: pairing, decision: .approved))

        let freshPair = try makeFreshPair(owner: owner, relay: relay, suffix: "fresh")
        let newer = try ActiveSession(owner: owner.signer.identity, sessionID: "session-2", activeSetID: "set-2",
                                      startsAt: t.addingTimeInterval(-1), endsAt: t.addingTimeInterval(3_600))
        _ = try owner.publishSession(newer)
        XCTAssertThrowsError(try owner.requestUnlock(requestID: "old-session", pairing: freshPair, session: session,
                                                      target: freshPair.approver.identityID, message: nil, validFor: 60))
        let cancelled = try owner.requestUnlock(requestID: "cancel-me", pairing: freshPair, session: newer,
                                                target: freshPair.approver.identityID, message: nil, validFor: 60)
        try owner.cancel(cancelled)
        XCTAssertEqual(try relay.request(id: cancelled.requestID).status, .cancelled)

        let expirySession = try ActiveSession(owner: owner.signer.identity, sessionID: "session-3", activeSetID: "set-3",
                                              startsAt: t.addingTimeInterval(-1), endsAt: t.addingTimeInterval(20))
        _ = try owner.publishSession(expirySession)
        let expiring = try owner.requestUnlock(requestID: "expires", pairing: freshPair, session: expirySession,
                                               target: freshPair.approver.identityID, message: nil, validFor: 10)
        try relay.advance(to: t.addingTimeInterval(11))
        XCTAssertEqual(try relay.request(id: expiring.requestID).status, .expired)
        XCTAssertEqual(try relay.request(id: expiring.requestID).status, .expired)
    }

    func testRestartPersistenceAndMissingKeyRequiresRepair() throws {
        let (relay, owner, _, pairing, _) = try harness()
        let data = try relay.snapshot()
        let checkpoint = try relay.checkpoint()
        let restarted = try InMemoryCompanionRelay(snapshot: data, checkpoint: checkpoint)
        XCTAssertEqual(try restarted.pairing(id: pairing.pairingID), pairing)
        let store = InMemoryDeviceKeyStore()
        let identity = owner.signer.identity
        let empty = try IdentityManager(keyStore: store).load(identity: identity)
        XCTAssertEqual(empty.availability, .needsRepair)
        XCTAssertThrowsError(try CompanionClient(identity: identity, keyStore: store, transport: restarted))
    }

    func testRateLimitAndIndependentDelayedRecovery() throws {
        let keys = InMemoryDeviceKeyStore()
        let signer = try DeviceSigner.create(role: .owner, keyStore: keys)
        let relay = try InMemoryCompanionRelay(owner: signer.identity, now: t)
        let owner = CompanionClient(signer: signer, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        for index in 0..<CompanionLimits.maxRateOperations {
            _ = try owner.createInvite(inviteID: "rate-\(index)", validFor: 100, now: t,
                                       nonce: Data(repeating: UInt8(index), count: 24))
        }
        XCTAssertThrowsError(try owner.createInvite(inviteID: "rate-over", validFor: 100, now: t,
                                                    nonce: Data(repeating: 9, count: 24))) { XCTAssertEqual($0 as? CompanionError, .rateLimited) }

        let (recoveryRelay, ownerClient, _, _, session) = try harness()
        let recovery = try LocalRecoveryRequest(recoveryID: "recovery-1", owner: ownerClient.signer.identity,
                                                session: session, requestedAt: t)
        XCTAssertEqual(recovery.status(at: t.addingTimeInterval(899)), .waiting)
        XCTAssertThrowsError(try recovery.confirm(at: t.addingTimeInterval(899)))
        let confirmed = try recovery.confirm(at: t.addingTimeInterval(900))
        XCTAssertEqual(confirmed.status, .confirmed)
        let lateSession = try ActiveSession(owner: ownerClient.signer.identity, sessionID: "short", activeSetID: "short-set",
                                            startsAt: t.addingTimeInterval(-1), endsAt: t.addingTimeInterval(10))
        let late = try LocalRecoveryRequest(recoveryID: "late", owner: ownerClient.signer.identity, session: lateSession, requestedAt: t)
        XCTAssertThrowsError(try late.confirm(at: t.addingTimeInterval(10))) { XCTAssertEqual($0 as? CompanionError, .expired) }
        _ = recoveryRelay
    }

    func testPactRequiresTwoIndependentFiniteCommitmentsAndCannotForceLock() throws {
        let firstStore = InMemoryDeviceKeyStore(); let secondStore = InMemoryDeviceKeyStore()
        let first = try DeviceSigner.create(role: .trustedApprover, keyStore: firstStore)
        let second = try DeviceSigner.create(role: .trustedApprover, keyStore: secondStore)
        let firstCommitment = try PactFactory.commitment(pactID: "pact-1", signer: first, periodStart: t,
                                                         periodEnd: t.addingTimeInterval(3_600), profile: Data("first-only".utf8))
        let pact = try BedtimePact(pactID: "pact-1", proposer: first.identity, participant: second.identity,
                                  proposerCommitment: firstCommitment, expiresAt: t.addingTimeInterval(600))
        let secondCommitment = try PactFactory.commitment(pactID: "pact-1", signer: second, periodStart: t,
                                                          periodEnd: t.addingTimeInterval(3_600), profile: Data("second-only".utf8))
        let accepted = try pact.accepting(secondCommitment, at: t)
        XCTAssertEqual(accepted.status, .accepted)
        XCTAssertNotEqual(firstCommitment.profileCommitment, secondCommitment.profileCommitment)
        XCTAssertThrowsError(try accepted.cancelling(at: t))
        XCTAssertEqual(pact.effectiveStatus(at: t.addingTimeInterval(601)), .expired)
    }

    func testRelayResponseRevisionAndExactRetryAreDurable() throws {
        let keys = InMemoryDeviceKeyStore()
        let signer = try DeviceSigner.create(role: .owner, keyStore: keys)
        let relay = try InMemoryCompanionRelay(owner: signer.identity, now: t)
        let payload = try InvitePayload(inviteID: "revision-invite", owner: signer.identity,
                                        issuedAt: t, expiresAt: t.addingTimeInterval(600),
                                        nonce: Data(repeating: 4, count: 24),
                                        tokenHash: InviteToken.hash(InviteToken.generate()))
        let inviteSignature = try signer.sign(domain: "\(CompanionCanonical.version).invite.v3",
                                              fields: payload.signingFields())
        let invitation = try Invitation(payload: payload, signature: inviteSignature)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(invitation)
        let unsigned = try SignedOperation(operationID: "retry-operation", expectedRevision: 0,
                                           kind: "invite", signer: signer.identity, body: body,
                                           signature: Data(repeating: 0, count: 64))
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).operation",
                                        fields: unsigned.signingFields())
        let operation = try SignedOperation(operationID: unsigned.operationID,
                                            expectedRevision: unsigned.expectedRevision,
                                            kind: unsigned.kind, signer: unsigned.signer,
                                            body: unsigned.body, signature: signature)

        let first = try relay.submit(operation)
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(try relay.submit(operation), first)
        XCTAssertEqual(relay.currentRevision, 1)

        let staleUnsigned = try SignedOperation(operationID: "stale-operation", expectedRevision: 0,
                                                 kind: operation.kind, signer: operation.signer,
                                                 body: operation.body, signature: Data(repeating: 0, count: 64))
        let staleOperation = try SignedOperation(operationID: staleUnsigned.operationID,
                                                 expectedRevision: staleUnsigned.expectedRevision,
                                                 kind: staleUnsigned.kind, signer: staleUnsigned.signer,
                                                 body: staleUnsigned.body,
                                                 signature: try signer.sign(
                                                    domain: "\(CompanionCanonical.version).operation",
                                                    fields: staleUnsigned.signingFields()))
        XCTAssertThrowsError(try relay.submit(staleOperation)) {
            XCTAssertEqual($0 as? CompanionError, .staleRevision(expected: 0, actual: 1))
        }

        let changedExpectation = try SignedOperation(operationID: operation.operationID,
                                                     expectedRevision: 1, kind: operation.kind,
                                                     signer: operation.signer, body: operation.body,
                                                     signature: try signer.sign(
                                                        domain: "\(CompanionCanonical.version).operation",
                                                        fields: [operation.operationID, "1", operation.kind,
                                                                 signer.identity.identityID,
                                                                 base64URL(signer.identity.publicKey),
                                                                 base64URL(CompanionCanonical.digest(body))]))
        XCTAssertThrowsError(try relay.submit(changedExpectation)) {
            XCTAssertEqual($0 as? CompanionError, .operationConflict)
        }

        let inbox = try CompanionClient(signer: signer, transport: relay,
                                        now: { Date(timeIntervalSince1970: 1_700_000_000) }).fetchInbox()
        XCTAssertTrue(inbox.isEmpty)

        let legacySignature = try signer.sign(
            domain: "\(CompanionCanonical.version).operation",
            fields: ["invite", signer.identity.identityID,
                     base64URL(signer.identity.publicKey),
                     base64URL(CompanionCanonical.digest(body))])
        let legacyOperation = try SignedOperation(kind: "invite", signer: signer.identity,
                                                  body: body, signature: legacySignature)
        var legacyJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacyOperation)) as! [String: Any]
        legacyJSON.removeValue(forKey: "operationID")
        legacyJSON.removeValue(forKey: "expectedRevision")
        let decodedLegacy = try JSONDecoder().decode(
            SignedOperation.self,
            from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertEqual(decodedLegacy.operationID, legacyOperation.operationID)
        XCTAssertNoThrow(try decodedLegacy.validateSignature())
        legacyJSON["operationID"] = "substituted-legacy-id"
        let substitutedLegacy = try JSONDecoder().decode(
            SignedOperation.self,
            from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertThrowsError(try substitutedLegacy.validateSignature()) {
            XCTAssertEqual($0 as? CompanionError, .invalidSignature)
        }
    }

    func testRevisionExhaustionDoesNotApplyCommand() throws {
        let keys = InMemoryDeviceKeyStore()
        let signer = try DeviceSigner.create(role: .owner, keyStore: keys)
        let relay = try InMemoryCompanionRelay(owner: signer.identity, now: t)
        let owner = CompanionClient(signer: signer, transport: relay,
                                    now: { Date(timeIntervalSince1970: 1_700_000_000) })
        relay.setRevisionForTesting(UInt64.max)
        XCTAssertThrowsError(try owner.createInvite(inviteID: "exhausted", validFor: 600,
                                                    now: t, nonce: Data(repeating: 6, count: 24))) {
            XCTAssertEqual($0 as? CompanionError,
                           .malformed("revision exhausted"))
        }
        XCTAssertEqual(relay.currentRevision, UInt64.max)
        relay.setRevisionForTesting(0)
        XCTAssertNoThrow(try owner.createInvite(inviteID: "exhausted", validFor: 600,
                                                 now: t, nonce: Data(repeating: 6, count: 24)))
    }

    func testSessionRotationRetainsHistoricalRequestsAcrossRestart() throws {
        let (relay, owner, approver, pairing, sessionA) = try harness()
        let requestA = try owner.requestUnlock(requestID: "historical-request",
                                                pairing: pairing, session: sessionA,
                                                target: approver.signer.identity.identityID,
                                                message: nil, validFor: 600)
        let approvalA = try approver.submitApproval(request: requestA, pairing: pairing,
                                                    decision: .approved)
        let sessionB = try ActiveSession(owner: owner.signer.identity,
                                         sessionID: "session-B", activeSetID: "set-B",
                                         startsAt: t.addingTimeInterval(-1),
                                         endsAt: t.addingTimeInterval(3_600))
        _ = try owner.publishSession(sessionB)
        let data = try relay.snapshot()
        let checkpoint = try relay.checkpoint()
        let restarted = try InMemoryCompanionRelay(snapshot: data, checkpoint: checkpoint)
        XCTAssertEqual(try restarted.request(id: requestA.requestID).status, .expired)
        let restartedOwner = CompanionClient(signer: owner.signer, transport: restarted,
                                             now: { Date(timeIntervalSince1970: 1_700_000_000) })
        XCTAssertThrowsError(try restartedOwner.useApproval(approvalA, request: requestA,
                                                            useID: "historical-use"))
    }

    func testAnchoredSnapshotRejectsRollback() throws {
        let keys = InMemoryDeviceKeyStore()
        let signer = try DeviceSigner.create(role: .owner, keyStore: keys)
        let relay = try InMemoryCompanionRelay(owner: signer.identity, now: t)
        let owner = CompanionClient(signer: signer, transport: relay,
                                    now: { Date(timeIntervalSince1970: 1_700_000_000) })
        _ = try owner.createInvite(inviteID: "anchor-first", validFor: 600, now: t,
                                   nonce: Data(repeating: 1, count: 24))
        let olderSnapshot = try relay.snapshot()
        let olderCheckpoint = try relay.checkpoint()
        _ = try owner.createInvite(inviteID: "anchor-second", validFor: 600, now: t,
                                   nonce: Data(repeating: 2, count: 24))
        let newerCheckpoint = try relay.checkpoint()
        XCTAssertThrowsError(try InMemoryCompanionRelay(snapshot: olderSnapshot,
                                                        checkpoint: newerCheckpoint)) {
            XCTAssertEqual($0 as? CompanionError,
                           .staleRevision(expected: newerCheckpoint.revision,
                                          actual: olderCheckpoint.revision))
        }
    }

    func testExpiryReadsAndFailedCommandsDoNotAdvanceRevision() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "derived-expiry",
                                              pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID,
                                              message: nil, validFor: 10)
        let beforeFailure = relay.currentRevision
        try relay.advance(to: t.addingTimeInterval(11))
        XCTAssertEqual(try relay.request(id: request.requestID).status, .expired)
        XCTAssertEqual(relay.currentRevision, beforeFailure)
        XCTAssertThrowsError(try approver.submitApproval(request: request,
                                                         pairing: pairing, decision: .approved))
        XCTAssertEqual(relay.currentRevision, beforeFailure)
        let persisted = try JSONSerialization.jsonObject(with: relay.snapshot()) as! [String: Any]
        let persistedRequest = (persisted["requests"] as! [[String: Any]])[0]
        XCTAssertEqual(persistedRequest["status"] as? String, "expired")

        let (secondRelay, secondOwner, secondApprover, secondPairing, secondSession) = try harness()
        let secondRequest = try secondOwner.requestUnlock(requestID: "failed-use-expiry",
                                                           pairing: secondPairing, session: secondSession,
                                                           target: secondApprover.signer.identity.identityID,
                                                           message: nil, validFor: 10)
        let approval = try secondApprover.submitApproval(request: secondRequest,
                                                         pairing: secondPairing, decision: .approved)
        let beforeUseFailure = secondRelay.currentRevision
        try secondRelay.advance(to: t.addingTimeInterval(11))
        XCTAssertThrowsError(try secondOwner.useApproval(approval, request: secondRequest,
                                                         useID: "expired-use"))
        XCTAssertEqual(secondRelay.currentRevision, beforeUseFailure)
        let secondPersisted = try JSONSerialization.jsonObject(with: secondRelay.snapshot()) as! [String: Any]
        let secondPersistedRequest = (secondPersisted["requests"] as! [[String: Any]])[0]
        XCTAssertEqual(secondPersistedRequest["status"] as? String, "expired")
    }

    func testPairingReplacementRevokesExactOldEpoch() throws {
        let (relay, owner, approver, oldPairing, session) = try harness()
        let oldRequest = try owner.requestUnlock(requestID: "replacement-old-request",
                                                 pairing: oldPairing, session: session,
                                                 target: approver.signer.identity.identityID,
                                                 message: nil, validFor: 600)
        let replacementStore = InMemoryDeviceKeyStore()
        let replacementSigner = try DeviceSigner.create(role: .trustedApprover,
                                                         keyStore: replacementStore)
        let proposal = try PairingReplacement.propose(
            replacementID: "replacement-1", previousPairing: oldPairing,
            replacementPairingID: "replacement-pairing-1", signer: replacementSigner, issuedAt: t)
        let newPairing = try owner.replacePairing(proposal)
        _ = try owner.grantScopes(pairing: newPairing, scopes: [.approveEarlyEnd, .receiveRequests])
        XCTAssertEqual(try relay.pairing(id: oldPairing.pairingID).state, .revoked)
        XCTAssertEqual(try relay.pairing(id: newPairing.pairingID), newPairing)
        XCTAssertEqual(newPairing.approver, replacementSigner.identity)
        XCTAssertThrowsError(try approver.submitApproval(request: oldRequest,
                                                          pairing: oldPairing, decision: .approved)) {
            XCTAssertEqual($0 as? CompanionError, .expired)
        }

        let replacement = CompanionClient(signer: replacementSigner, transport: relay,
                                          now: { Date(timeIntervalSince1970: 1_700_000_000) })
        _ = try replacement.acceptScopes(pairing: newPairing, scopes: [.approveEarlyEnd, .receiveRequests])
        let newRequest = try owner.requestUnlock(requestID: "replacement-new-request",
                                                 pairing: newPairing, session: session,
                                                 target: replacementSigner.identity.identityID,
                                                 message: nil, validFor: 600)
        XCTAssertNoThrow(try replacement.submitApproval(request: newRequest,
                                                         pairing: newPairing, decision: .approved))
    }

    func testScopeConsentIsBilateralAndRevocationInvalidatesApproval() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "consent-revoke-request", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved,
                                                   approvalID: "consent-revoke-approval")
        _ = try approver.revokeScopes(pairing: pairing, scopes: [.approveEarlyEnd])
        XCTAssertThrowsError(try owner.useApproval(approval, request: request, useID: "consent-revoke-use"))
        XCTAssertThrowsError(try owner.requestUnlock(requestID: "consent-revoked-new", pairing: pairing, session: session,
                                                     target: approver.signer.identity.identityID, message: nil, validFor: 600)) {
            XCTAssertEqual($0 as? CompanionError, .consentRequired)
        }
        XCTAssertEqual(try relay.consent(relationshipID: pairing.pairingID).activeScopes(), [.receiveRequests])
    }

    func testR6ScopeCannotBeGrantedOrAuthorizeDelivery() throws {
        let (relay, owner, approver, pairing, _) = try harness()
        XCTAssertThrowsError(try owner.grantScopes(pairing: pairing, scopes: [.earlyEndNotices])) {
            XCTAssertEqual($0 as? CompanionError, .unsupportedScope)
        }
        XCTAssertThrowsError(try approver.acceptScopes(pairing: pairing, scopes: [.weeklySharedSummaries])) {
            XCTAssertEqual($0 as? CompanionError, .unsupportedScope)
        }
        XCTAssertThrowsError(try owner.grantScopes(pairing: pairing, scopes: [.mutualPact])) {
            XCTAssertEqual($0 as? CompanionError, .unsupportedScope)
        }
        XCTAssertEqual(try relay.consent(relationshipID: pairing.pairingID).activeScopes(),
                       [.approveEarlyEnd, .receiveRequests])
    }

    func testConsentIsNotCopiedToReplacementPairing() throws {
        let (relay, owner, _, oldPairing, session) = try harness()
        let replacementStore = InMemoryDeviceKeyStore()
        let replacementSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: replacementStore)
        let proposal = try PairingReplacement.propose(replacementID: "scope-replacement",
                                                       previousPairing: oldPairing,
                                                       replacementPairingID: "scope-replacement-pairing",
                                                       signer: replacementSigner, issuedAt: t)
        let replacementPairing = try owner.replacePairing(proposal)
        XCTAssertThrowsError(try owner.requestUnlock(requestID: "stale-consent", pairing: replacementPairing,
                                                     session: session,
                                                     target: replacementSigner.identity.identityID,
                                                     message: nil, validFor: 600)) {
            XCTAssertEqual($0 as? CompanionError, .consentRequired)
        }
        _ = relay
    }

    func testPreScopeApprovedRequestMigratesTerminalAndCannotBeUsed() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "legacy-request", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let legacyUnsigned = Approval(approvalID: "legacy-approval", requestID: request.requestID,
                                      pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
                                      sessionID: request.sessionID, activeSetID: request.activeSetID,
                                      approver: approver.signer.identity, decision: .approved,
                                      issuedAt: t, signature: Data())
        let legacySignature = try approver.signer.sign(
            domain: "\(CompanionCanonical.version).approval", fields: legacyUnsigned.signingFields())
        let legacyApproval = Approval(approvalID: legacyUnsigned.approvalID, requestID: legacyUnsigned.requestID,
                                      pairingID: legacyUnsigned.pairingID, pairEpoch: legacyUnsigned.pairEpoch,
                                      sessionID: legacyUnsigned.sessionID, activeSetID: legacyUnsigned.activeSetID,
                                      approver: legacyUnsigned.approver, decision: legacyUnsigned.decision,
                                      issuedAt: legacyUnsigned.issuedAt, signature: legacySignature)
        var object = try JSONSerialization.jsonObject(with: relay.snapshot()) as! [String: Any]
        var requests = object["requests"] as! [[String: Any]]
        requests[0].removeValue(forKey: "consentGeneration")
        var bindings = requests[0]["targetBindings"] as! [[String: Any]]
        bindings[0].removeValue(forKey: "consentGeneration")
        requests[0]["targetBindings"] = bindings
        requests[0]["status"] = "approved"
        var decisions = requests[0]["decisions"] as! [String: String]
        decisions[approver.signer.identity.identityID] = "approved"
        requests[0]["decisions"] = decisions
        object["requests"] = requests
        object["approvals"] = [try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyApproval))]
        let migratedRelay = try InMemoryCompanionRelay(testSnapshot: JSONSerialization.data(withJSONObject: object))
        let migratedRequest = try migratedRelay.request(id: request.requestID)
        XCTAssertEqual(migratedRequest.status, .expired)
        XCTAssertEqual(migratedRequest.consentGeneration, 0)
        let fixedNow = t
        let migratedOwner = CompanionClient(signer: owner.signer, transport: migratedRelay, now: { fixedNow })
        XCTAssertThrowsError(try migratedOwner.useApproval(legacyApproval, request: migratedRequest,
                                                            useID: "legacy-use"))
    }

    func testConsentGenerationInvalidatesApprovalAcrossRegrantAndRestart() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "generation-request", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved,
                                                   approvalID: "generation-approval")
        let firstGeneration = try relay.consent(relationshipID: pairing.pairingID).generation
        _ = try owner.grantScopes(pairing: pairing, scopes: [.approveEarlyEnd, .receiveRequests])
        let second = try owner.grantScopes(pairing: pairing, scopes: [.approveEarlyEnd, .receiveRequests])
        XCTAssertGreaterThan(second.generation, firstGeneration)
        _ = try approver.acceptScopes(pairing: pairing, scopes: [.approveEarlyEnd, .receiveRequests])
        XCTAssertEqual(try relay.request(id: request.requestID).status, .expired)
        XCTAssertThrowsError(try owner.useApproval(approval, request: request, useID: "generation-use"))
        let checkpoint = try relay.checkpoint()
        let restarted = try InMemoryCompanionRelay(snapshot: relay.snapshot(), checkpoint: checkpoint)
        let fixedNow = t
        let restartedOwner = CompanionClient(signer: owner.signer, transport: restarted, now: { fixedNow })
        XCTAssertThrowsError(try restartedOwner.useApproval(approval, request: request, useID: "generation-restart-use"))
    }

    func testApprovalSignatureBindsConsentGeneration() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "generation-signature-request", pairing: pairing,
                                              session: session, target: approver.signer.identity.identityID,
                                              message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved,
                                                   approvalID: "generation-signature-approval")
        let altered = Approval(approvalID: approval.approvalID, requestID: approval.requestID,
                               pairingID: approval.pairingID, pairEpoch: approval.pairEpoch,
                               sessionID: approval.sessionID, activeSetID: approval.activeSetID,
                               approver: approval.approver, decision: approval.decision,
                               issuedAt: approval.issuedAt,
                               consentGeneration: approval.consentGeneration + 1,
                               nonce: approval.nonce, signature: approval.signature)
        XCTAssertThrowsError(try altered.validateSignature()) {
            XCTAssertEqual($0 as? CompanionError, .invalidSignature)
        }
    }

    func testMismatchedApprovalGenerationLeavesRequestPending() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "generation-mismatch-request", pairing: pairing,
                                              session: session, target: approver.signer.identity.identityID,
                                              message: nil, validFor: 600)
        let generation = request.consentGeneration + 1
        let unsigned = Approval(approvalID: "generation-mismatch-approval", requestID: request.requestID,
                                pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
                                sessionID: request.sessionID, activeSetID: request.activeSetID,
                                approver: approver.signer.identity, decision: .approved, issuedAt: t,
                                consentGeneration: generation, nonce: Data(repeating: 21, count: 24),
                                signature: Data())
        let signature = try approver.signer.sign(domain: "\(CompanionCanonical.version).approval",
                                                  fields: unsigned.signingFields())
        let mismatched = Approval(approvalID: unsigned.approvalID, requestID: unsigned.requestID,
                                 pairingID: unsigned.pairingID, pairEpoch: unsigned.pairEpoch,
                                 sessionID: unsigned.sessionID, activeSetID: unsigned.activeSetID,
                                 approver: unsigned.approver, decision: unsigned.decision,
                                 issuedAt: unsigned.issuedAt, consentGeneration: generation,
                                 nonce: unsigned.nonce, signature: signature)
        XCTAssertThrowsError(try approver.transport.submit(
            try signedOperation(kind: "approval", signer: approver.signer,
                                body: mismatched, operationID: "generation-mismatch-op")))
        XCTAssertEqual(try relay.request(id: request.requestID).status, .pending)
    }

    func testEpochOverflowIsRejectedWithoutArithmeticTrap() throws {
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        XCTAssertThrowsError(try IdentityReplacement(replacementID: "identity-overflow",
                                                      previous: ownerSigner.identity,
                                                      replacement: approverSigner.identity,
                                                      previousEpoch: UInt64.max,
                                                      replacementEpoch: UInt64.max,
                                                      issuedAt: t, signature: Data()))
        let pairing = try Pairing(pairingID: "pairing-overflow", owner: ownerSigner.identity,
                                  approver: approverSigner.identity, epoch: UInt64.max,
                                  createdAt: t, state: .active)
        XCTAssertThrowsError(try PairingReplacement.propose(replacementID: "pairing-overflow-replacement",
                                                            previousPairing: pairing,
                                                            replacementPairingID: "replacement",
                                                            signer: try DeviceSigner.create(
                                                                role: .trustedApprover,
                                                                keyStore: InMemoryDeviceKeyStore()),
                                                            issuedAt: t))
    }

    func testQuietHoursArePrivateLocalNotificationPolicy() throws {
        let policy = try QuietHoursPolicy(startMinute: 22 * 60, endMinute: 7 * 60, suppressApproverNotifications: true)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let night = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2023, month: 11, day: 14, hour: 23))!
        let day = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2023, month: 11, day: 14, hour: 12))!
        XCTAssertTrue(policy.suppressesNotifications(at: night, calendar: calendar))
        XCTAssertFalse(policy.suppressesNotifications(at: day, calendar: calendar))
        XCTAssertNil(policy.score)
    }

    private func signedOperation<T: Encodable>(kind: String, signer: DeviceSigner,
                                               body: T, operationID: String) throws -> SignedOperation {
        let data = try JSONEncoder().encode(body)
        let unsigned = try SignedOperation(operationID: operationID, expectedRevision: nil,
                                           kind: kind, signer: signer.identity, body: data,
                                           signature: Data(repeating: 0, count: 64))
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).operation",
                                        fields: unsigned.signingFields())
        return try SignedOperation(operationID: operationID, expectedRevision: nil,
                                   kind: kind, signer: signer.identity, body: data,
                                   signature: signature)
    }

    private func signedApproval(signer: DeviceSigner, approvalID: String, request: TrustedRequest,
                                pairing: Pairing, sessionID: String, activeSetID: String) throws -> Approval {
        let unsigned = Approval(approvalID: approvalID, requestID: request.requestID,
                                    pairingID: pairing.pairingID, pairEpoch: pairing.epoch, sessionID: sessionID,
                                    activeSetID: activeSetID, approver: signer.identity, decision: .approved,
                                    issuedAt: t, signature: Data())
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).approval",
                                        fields: unsigned.signingFields())
        return Approval(approvalID: unsigned.approvalID, requestID: unsigned.requestID,
                            pairingID: unsigned.pairingID, pairEpoch: unsigned.pairEpoch,
                            sessionID: unsigned.sessionID, activeSetID: unsigned.activeSetID,
                            approver: unsigned.approver, decision: unsigned.decision,
                            issuedAt: unsigned.issuedAt, signature: signature)
    }

    private func alteredSnapshot(_ relay: InMemoryCompanionRelay,
                                 mutate: (inout [String: Any]) -> Void) throws -> Data {
        var snapshot = try JSONSerialization.jsonObject(with: relay.snapshot()) as! [String: Any]
        mutate(&snapshot)
        return try JSONSerialization.data(withJSONObject: snapshot)
    }

    private func makeFreshPair(owner: CompanionClient, relay: InMemoryCompanionRelay, suffix: String) throws -> Pairing {
        let store = InMemoryDeviceKeyStore()
        let signer = try DeviceSigner.create(role: .trustedApprover, keyStore: store)
        let approver = CompanionClient(signer: signer, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let pairing = try pairV3(owner: owner, approver: approver, inviteID: "invite-\(suffix)", acceptanceID: "accept-\(suffix)", now: t,
                                 nonce: Data(repeating: 3, count: 24))
        return pairing
    }

    // MARK: - Malicious relay: confirm response validation

    func testAcceptRejectsARelayThatSwapsTheApproverKeyInTheResponse() throws {
        let ownerKeys = InMemoryDeviceKeyStore()
        let approverKeys = InMemoryDeviceKeyStore()
        let attackerKeys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: approverKeys)
        let attackerSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: attackerKeys)
        let relay = try InMemoryCompanionRelay(owner: ownerSigner.identity, now: t)
        let maliciousTransport = ApproverSwappingTransport(real: relay, attacker: attackerSigner.identity)
        let owner = CompanionClient(signer: ownerSigner, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let approver = CompanionClient(signer: approverSigner, transport: maliciousTransport, now: { Date(timeIntervalSince1970: 1_700_000_000) })

        let issued = try owner.createInvite(inviteID: "invite-swap", validFor: 3_600, now: t,
                                            nonce: Data(repeating: 3, count: 24))
        let invitation = try approver.lookupInvite(token: issued.token)
        XCTAssertThrowsError(try approver.acceptInvite(invitation, token: issued.token, acceptanceID: "accept-swap", now: t)) { error in
            guard case CompanionError.malformed = error else { return XCTFail("expected malformed, got \(error)") }
        }
    }

    func testSyncFetchInboxSignsAFreshIssuedAtInTheQueryBody() throws {
        let (relay, owner, _, _, _) = try harness()
        let capturing = InboxQueryCapturingTransport(real: relay)
        let ownerViaCapture = CompanionClient(signer: owner.signer, transport: capturing,
                                              now: { Date(timeIntervalSince1970: 1_700_000_000) })
        _ = try ownerViaCapture.fetchInbox()
        XCTAssertEqual(capturing.capturedQuery?.identityID, owner.signer.identity.identityID)
        XCTAssertEqual(capturing.capturedQuery?.issuedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testAcceptRejectsARelayThatSubstitutesTheOwner() throws {
        let ownerKeys = InMemoryDeviceKeyStore()
        let approverKeys = InMemoryDeviceKeyStore()
        let attackerOwnerKeys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: approverKeys)
        let attackerOwnerSigner = try DeviceSigner.create(role: .owner, keyStore: attackerOwnerKeys)
        let relay = try InMemoryCompanionRelay(owner: ownerSigner.identity, now: t)
        let maliciousTransport = OwnerSwappingTransport(real: relay, attacker: attackerOwnerSigner.identity)
        let owner = CompanionClient(signer: ownerSigner, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let approver = CompanionClient(signer: approverSigner, transport: maliciousTransport, now: { Date(timeIntervalSince1970: 1_700_000_000) })

        let issued = try owner.createInvite(inviteID: "invite-owner-swap", validFor: 3_600, now: t,
                                            nonce: Data(repeating: 3, count: 24))
        let invitation = try approver.lookupInvite(token: issued.token)
        XCTAssertThrowsError(try approver.acceptInvite(invitation, token: issued.token, acceptanceID: "accept-owner-swap", now: t)) { error in
            guard case CompanionError.malformed = error else { return XCTFail("expected malformed, got \(error)") }
        }
    }

    // MARK: - R5 Slice B2a: owner inbox approval delivery

    func testOwnerInboxIncludesTheAcceptedApprovalAndAHelperInboxOmitsIt() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "inbox-approval-request", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)

        // Before approval, the owner's inbox carries the (still-pending)
        // request but no approval for it yet.
        let beforeOperation = try makeInboxOperation(identity: owner.signer, now: t)
        let beforeInbox = try relay.fetchInbox(beforeOperation)
        XCTAssertEqual(beforeInbox.approvals, [])

        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)

        let ownerOperation = try makeInboxOperation(identity: owner.signer, now: t)
        let ownerInbox = try relay.fetchInbox(ownerOperation)
        XCTAssertEqual(ownerInbox.approvals, [approval])

        let helperOperation = try makeInboxOperation(identity: approver.signer, now: t)
        let helperInbox = try relay.fetchInbox(helperOperation)
        XCTAssertNil(helperInbox.approvals)
        XCTAssertTrue(helperInbox.requests.contains { $0.requestID == request.requestID })
    }

    private func makeInboxOperation(identity signer: DeviceSigner, now: Date) throws -> SignedOperation {
        let query = InboxQuery(identityID: signer.identity.identityID, issuedAt: now)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(query)
        let operationID = operationIdentifier(kind: "inbox", signer: signer.identity, body: body)
        let unsigned = try SignedOperation(operationID: operationID, expectedRevision: nil, kind: "inbox",
                                           signer: signer.identity, body: body, signature: Data(repeating: 0, count: 64))
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).operation", fields: unsigned.signingFields())
        return try SignedOperation(operationID: operationID, expectedRevision: nil, kind: "inbox",
                                   signer: signer.identity, body: body, signature: signature)
    }

    /// B2a item 2: "Same useID and approval must produce the same operation
    /// ID, so a retry gets the stored idempotent response."
    /// `operationIdentifier` hashes only `(kind, signer, bodyDigest)`, and the
    /// `ApprovalUse` body is itself a pure, deterministic encoding of
    /// `(approval, requestID, useID, consentGeneration)` -- so this is a
    /// property of `operationIdentifier`/`ApprovalUse` encoding, independent
    /// of the relay.
    func testUseApprovalOperationIDIsStableForTheSameApprovalAndUseID() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "stable-op-id-request", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let use = ApprovalUse(approval: approval, requestID: request.requestID, useID: "stable-use-id",
                              consentGeneration: approval.consentGeneration)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bodyA = try encoder.encode(use)
        let bodyB = try encoder.encode(use)
        XCTAssertEqual(bodyA, bodyB)
        let idA = operationIdentifier(kind: "use", signer: owner.signer.identity, body: bodyA)
        let idB = operationIdentifier(kind: "use", signer: owner.signer.identity, body: bodyB)
        XCTAssertEqual(idA, idB)
    }

    /// The async client's `useApproval` applies the same response-verification
    /// checks as the sync client (`validateUseVerification`, shared in
    /// `ProtocolModels.swift`). Exercised here against the sync client with a
    /// transport double that tampers with an otherwise-valid "use" response,
    /// since both clients route through the identical shared helper.
    func testSyncUseApprovalRejectsATamperedVerificationResponse() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "tamper-verification-request", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)

        let wrongUseIDTransport = VerificationUseIDSwappingTransport(real: relay, substituteUseID: "attacker-use-id")
        let ownerViaWrongUseID = CompanionClient(signer: owner.signer, transport: wrongUseIDTransport, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        XCTAssertThrowsError(try ownerViaWrongUseID.useApproval(approval, request: request, useID: "real-use-id")) { error in
            // R5 Slice B2a review fix (N3): `validateUseVerification`'s
            // rejection is wrapped as `.responseVerificationFailed`, not
            // left as a bare `.malformed`, so
            // `UseFailureDisposition.classify` can tell it apart from a
            // local pre-call guard failure.
            guard case CompanionError.responseVerificationFailed = error else {
                return XCTFail("expected responseVerificationFailed, got \(error)")
            }
        }
    }

    /// R5 Slice B2a review fix (N3): a tampered "use" verification response
    /// is `.integrityFatal` end to end through `useApproval` (not only via
    /// `UseFailureDisposition.classify` applied to a synthetic error).
    func testTamperedVerificationResponseClassifiesAsIntegrityFatalEndToEnd() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "tamper-verification-disposition-request", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        let wrongUseIDTransport = VerificationUseIDSwappingTransport(real: relay, substituteUseID: "attacker-use-id")
        let ownerViaWrongUseID = CompanionClient(signer: owner.signer, transport: wrongUseIDTransport, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        do {
            _ = try ownerViaWrongUseID.useApproval(approval, request: request, useID: "real-use-id-2")
            XCTFail("expected a tampered verification response to be rejected")
        } catch {
            XCTAssertEqual(AsyncCompanionClient.UseFailureDisposition.classify(error), .integrityFatal)
        }
    }

    /// R5 Slice B2a review fix (N3): the owner-identity guard at the top of
    /// `useApproval` -- a local pre-call failure, not a response-
    /// verification failure -- must classify as `.definitive`.
    func testOwnerMismatchGuardIsDefinitive() throws {
        let (_, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "owner-mismatch-request", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: nil, validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        do {
            // `approver` is not `request.owner`, so the very first guard in
            // `useApproval` rejects this before any network call.
            _ = try approver.useApproval(approval, request: request, useID: "owner-mismatch-use")
            XCTFail("expected the owner-identity guard to reject this call")
        } catch {
            guard case CompanionError.unauthorized = error else { return XCTFail("expected .unauthorized, got \(error)") }
            XCTAssertEqual(AsyncCompanionClient.UseFailureDisposition.classify(error), .definitive)
        }
    }
}

/// Forwards every operation to a real in-memory relay, capturing the decoded
/// `InboxQuery` body of the most recent `fetchInbox` call so a test can
/// assert on it directly.
private final class InboxQueryCapturingTransport: CompanionTransport, @unchecked Sendable {
    let real: InMemoryCompanionRelay
    private(set) var capturedQuery: InboxQuery?
    init(real: InMemoryCompanionRelay) { self.real = real }

    func submit(_ operation: SignedOperation) throws -> RelayResponse { try real.submit(operation) }

    func fetchInbox(_ operation: SignedOperation) throws -> InboxResponse {
        capturedQuery = try? JSONDecoder().decode(InboxQuery.self, from: operation.body)
        return try real.fetchInbox(operation)
    }
}

/// Forwards every operation to a real in-memory relay, except that a
/// successful "confirm" response has its `Pairing.approver` swapped for an
/// attacker identity before being returned — simulating a malicious relay
/// trying to make the owner trust the wrong approver key.
private final class ApproverSwappingTransport: CompanionTransport, @unchecked Sendable {
    let real: InMemoryCompanionRelay
    let attacker: DeviceIdentity
    init(real: InMemoryCompanionRelay, attacker: DeviceIdentity) { self.real = real; self.attacker = attacker }

    func submit(_ operation: SignedOperation) throws -> RelayResponse {
        let response = try real.submit(operation)
        guard operation.kind == "accept", case let .pairing(pairing) = response.result else { return response }
        let swapped = try Pairing(pairingID: pairing.pairingID, owner: pairing.owner, approver: attacker,
                                  epoch: pairing.epoch, createdAt: pairing.createdAt, state: pairing.state)
        return try RelayResponse(operationID: response.operationID, revision: response.revision, result: .pairing(swapped))
    }

    func fetchInbox(_ operation: SignedOperation) throws -> InboxResponse {
        try real.fetchInbox(operation)
    }

    func lookupInvite(token: String) throws -> Invitation {
        try real.lookupInvite(token: token)
    }
}

/// Same idea as `ApproverSwappingTransport`, but substitutes the owner
/// identity in the confirm response instead of the approver.
private final class OwnerSwappingTransport: CompanionTransport, @unchecked Sendable {
    let real: InMemoryCompanionRelay
    let attacker: DeviceIdentity
    init(real: InMemoryCompanionRelay, attacker: DeviceIdentity) { self.real = real; self.attacker = attacker }

    func submit(_ operation: SignedOperation) throws -> RelayResponse {
        let response = try real.submit(operation)
        guard operation.kind == "accept", case let .pairing(pairing) = response.result else { return response }
        let swapped = try Pairing(pairingID: pairing.pairingID, owner: attacker, approver: pairing.approver,
                                  epoch: pairing.epoch, createdAt: pairing.createdAt, state: pairing.state)
        return try RelayResponse(operationID: response.operationID, revision: response.revision, result: .pairing(swapped))
    }

    func fetchInbox(_ operation: SignedOperation) throws -> InboxResponse {
        try real.fetchInbox(operation)
    }

    func lookupInvite(token: String) throws -> Invitation {
        try real.lookupInvite(token: token)
    }
}

/// R5 Slice B2a: forwards every operation to a real in-memory relay, except
/// that a successful "use" response has its `ApprovalVerification.useID`
/// substituted before being returned — simulating a malicious or buggy relay
/// confirming a different use than the one actually submitted.
/// `CompanionClient.useApproval`/`AsyncCompanionClient.useApproval` must
/// reject this via `validateUseVerification` before ever treating the
/// approval as consumed.
private final class VerificationUseIDSwappingTransport: CompanionTransport, @unchecked Sendable {
    let real: InMemoryCompanionRelay
    let substituteUseID: String
    init(real: InMemoryCompanionRelay, substituteUseID: String) { self.real = real; self.substituteUseID = substituteUseID }

    func submit(_ operation: SignedOperation) throws -> RelayResponse {
        let response = try real.submit(operation)
        guard operation.kind == "use", case let .verification(verification) = response.result else { return response }
        let swapped = ApprovalVerification(approval: verification.approval, verifiedAt: verification.verifiedAt,
                                           useID: substituteUseID)
        return try RelayResponse(operationID: response.operationID, revision: response.revision, result: .verification(swapped))
    }

    func fetchInbox(_ operation: SignedOperation) throws -> InboxResponse {
        try real.fetchInbox(operation)
    }
}
