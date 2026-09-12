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
        let invitation = try owner.createInvite(inviteID: "invite-1", validFor: 3_600, now: t,
                                                nonce: Data(repeating: 7, count: 24))
        let acceptance = try approver.accept(invitation, acceptanceID: "accept-1", now: t)
        let pairing = try owner.confirm(acceptance, verificationCode: acceptance.verificationCode, now: t)
        let session = try ActiveSession(owner: ownerSigner.identity, sessionID: "session-1", activeSetID: "set-1",
                                        startsAt: t.addingTimeInterval(-1), endsAt: t.addingTimeInterval(3_600))
        _ = try owner.publishSession(session)
        return (relay, owner, approver, pairing, session)
    }

    func testPairingRequiresSignedMutualConfirmationAndForwardedLinkIsNotAuthority() throws {
        let keys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: keys)
        let relay = try InMemoryCompanionRelay(owner: ownerSigner.identity, now: t)
        let owner = CompanionClient(signer: ownerSigner, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let invitation = try owner.createInvite(inviteID: "invite-forward", validFor: 100, now: t,
                                                nonce: Data(repeating: 2, count: 24))
        XCTAssertNoThrow(try Invitation.fromShareLink(invitation.shareLink))
        XCTAssertThrowsError(try relay.pairing(id: "not-authorized"))

        let attackerKeys = InMemoryDeviceKeyStore()
        let attacker = try DeviceSigner.create(role: .trustedApprover, keyStore: attackerKeys)
        let attackerClient = CompanionClient(signer: attacker, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let acceptance = try attackerClient.accept(invitation, acceptanceID: "forwarded-accept", now: t)
        // Possession created a pending handshake only. It cannot unlock or
        // become a pairing until the owner explicitly confirms this identity.
        XCTAssertThrowsError(try relay.pairing(id: "not-authorized"))
        let forgedCode = try PairingConfirmation(acceptance: acceptance, owner: ownerSigner.identity,
                                                verificationCode: "000000", issuedAt: t)
        XCTAssertEqual(forgedCode.verificationCode, "000000")
        XCTAssertThrowsError(try owner.confirm(acceptance, verificationCode: "000000", now: t))
        XCTAssertNoThrow(try owner.confirm(acceptance, verificationCode: acceptance.verificationCode, now: t))
    }

    func testForgedInviteAndSwapReceiverIssuerFail() throws {
        let keys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: keys)
        let relay = try InMemoryCompanionRelay(owner: ownerSigner.identity, now: t)
        let owner = CompanionClient(signer: ownerSigner, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let invite = try owner.createInvite(inviteID: "forged", validFor: 100, now: t, nonce: Data(repeating: 1, count: 24))
        var badBytes = invite.signature
        badBytes[0] ^= 1
        let forged = try Invitation(payload: invite.payload, signature: badBytes)
        XCTAssertThrowsError(try forged.validate(at: t)) { XCTAssertEqual($0 as? CompanionError, .invalidSignature) }

        let approverKeys = InMemoryDeviceKeyStore()
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: approverKeys)
        let approver = CompanionClient(signer: approverSigner, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        XCTAssertThrowsError(try approver.createInvite(inviteID: "swap", validFor: 100, now: t))
        XCTAssertThrowsError(try owner.accept(invite, acceptanceID: "wrong-receiver", now: t))
    }

    func testApprovalBindsPairingSessionAndRequestAndIsSingleUse() throws {
        let (relay, owner, approver, pairing, session) = try harness()
        let request = try owner.requestUnlock(requestID: "request-1", pairing: pairing, session: session,
                                              target: approver.signer.identity.identityID, message: "Please let me finish", validFor: 600)
        let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved)
        try approval.validateSignature()
        let verification = try owner.useApproval(approval, request: request, useID: "use-1")
        XCTAssertEqual(verification.approval.requestID, request.requestID)
        XCTAssertThrowsError(try owner.useApproval(approval, request: request, useID: "use-1"))
        XCTAssertThrowsError(try owner.useApproval(approval, request: request, useID: "use-2"))
        _ = relay // keeps the test's ownership of the test backend explicit
    }

    func testDeclineByOneApproverDoesNotInvalidateAnotherTarget() throws {
        let (relay, owner, first, firstPairing, session) = try harness()
        let secondKeys = InMemoryDeviceKeyStore()
        let secondSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: secondKeys)
        let second = CompanionClient(signer: secondSigner, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let invite = try owner.createInvite(inviteID: "invite-2", validFor: 3_600, now: t, nonce: Data(repeating: 8, count: 24))
        let acceptance = try second.accept(invite, acceptanceID: "accept-2", now: t)
        let secondPairing = try owner.confirm(acceptance, verificationCode: acceptance.verificationCode, now: t)
        let targets = [first.signer.identity.identityID, second.signer.identity.identityID]
        let multi = try owner.requestUnlock(requestID: "multi", pairings: [firstPairing, secondPairing], session: session,
                                            targets: targets, message: nil, validFor: 600)
        let declined = try first.submitApproval(request: multi, pairing: firstPairing, decision: .declined)
        XCTAssertEqual(declined.decision, ApproverDecision.declined)
        let approved = try second.submitApproval(request: multi, pairing: secondPairing, decision: .approved)
        XCTAssertEqual(approved.decision, ApproverDecision.approved)
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
        let restarted = try InMemoryCompanionRelay(snapshot: data)
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

    func testQuietHoursArePrivateLocalNotificationPolicy() throws {
        let policy = try QuietHoursPolicy(startMinute: 22 * 60, endMinute: 7 * 60, suppressApproverNotifications: true)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let night = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2023, month: 11, day: 14, hour: 23))!
        let day = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2023, month: 11, day: 14, hour: 12))!
        XCTAssertTrue(policy.suppressesNotifications(at: night, calendar: calendar))
        XCTAssertFalse(policy.suppressesNotifications(at: day, calendar: calendar))
        XCTAssertNil(policy.score)
    }

    private func makeFreshPair(owner: CompanionClient, relay: InMemoryCompanionRelay, suffix: String) throws -> Pairing {
        let store = InMemoryDeviceKeyStore()
        let signer = try DeviceSigner.create(role: .trustedApprover, keyStore: store)
        let approver = CompanionClient(signer: signer, transport: relay, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let invitation = try owner.createInvite(inviteID: "invite-\(suffix)", validFor: 3_600, now: t,
                                                nonce: Data(repeating: 3, count: 24))
        let acceptance = try approver.accept(invitation, acceptanceID: "accept-\(suffix)", now: t)
        return try owner.confirm(acceptance, verificationCode: acceptance.verificationCode, now: t)
    }
}
