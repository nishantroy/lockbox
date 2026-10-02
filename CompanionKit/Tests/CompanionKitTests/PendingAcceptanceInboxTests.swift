import XCTest
@testable import CompanionKit

/// R5 pairing v2 (`docs/r5-pairing-v2-plan.md`'s "Slice P2a"), mirroring
/// `relay/test/pairing-v2-inbox.test.ts`'s coverage against the Swift
/// reference relay (`InMemoryCompanionRelay`): owner-only exposure of
/// `InboxResponse.pendingAcceptances`, clearing after confirm, omission
/// after the invite expires, and (P2a review follow-up P2-2) a schema-4
/// `RelaySnapshot` round trip.
final class PendingAcceptanceInboxTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_710_000_000)

    private struct Harness {
        let relay: InMemoryCompanionRelay
        let owner: CompanionClient
        let approver: CompanionClient
        let invitation: Invitation
    }

    private func harness(now: Date, validFor: TimeInterval = 3_600) throws -> Harness {
        let ownerKeys = InMemoryDeviceKeyStore()
        let approverKeys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: approverKeys)
        let relay = try InMemoryCompanionRelay(owner: ownerSigner.identity, now: now)
        let owner = CompanionClient(signer: ownerSigner, transport: relay, now: { now })
        let approver = CompanionClient(signer: approverSigner, transport: relay, now: { now })
        let invitation = try owner.createInvite(inviteID: "pai-invite", validFor: validFor, now: now,
                                                 nonce: Data(repeating: 6, count: 24))
        return Harness(relay: relay, owner: owner, approver: approver, invitation: invitation)
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

    // MARK: - P2-2a: a helper fetch returns nil for pendingAcceptances

    func testHelperInboxOmitsPendingAcceptancesEntirely() throws {
        let h = try harness(now: t)
        _ = try h.approver.accept(h.invitation, acceptanceID: "pai-accept-helper-nil", now: t)

        let ownerInbox = try h.relay.fetchInbox(makeInboxOperation(identity: h.owner.signer, now: t))
        XCTAssertEqual(ownerInbox.pendingAcceptances?.count, 1)

        let helperInbox = try h.relay.fetchInbox(makeInboxOperation(identity: h.approver.signer, now: t))
        XCTAssertNil(helperInbox.pendingAcceptances)
    }

    // MARK: - P2-2b: the list is cleared after confirm

    func testPendingAcceptanceIsClearedFromTheOwnerInboxAfterConfirm() throws {
        let h = try harness(now: t)
        let acceptance = try h.approver.accept(h.invitation, acceptanceID: "pai-accept-confirm", now: t)

        let beforeConfirm = try h.relay.fetchInbox(makeInboxOperation(identity: h.owner.signer, now: t))
        XCTAssertEqual(beforeConfirm.pendingAcceptances?.map(\.acceptance.acceptanceID), [acceptance.acceptanceID])

        _ = try h.owner.confirm(acceptance, verificationCode: acceptance.verificationCode, now: t)

        let afterConfirm = try h.relay.fetchInbox(makeInboxOperation(identity: h.owner.signer, now: t))
        XCTAssertEqual(afterConfirm.pendingAcceptances, [])
    }

    // MARK: - P2-2c: the list is empty after the invite expires

    func testPendingAcceptanceIsOmittedOnceTheInviteExpires() throws {
        let h = try harness(now: t, validFor: 120)
        _ = try h.approver.accept(h.invitation, acceptanceID: "pai-accept-expiry", now: t)

        let stillPending = try h.relay.fetchInbox(makeInboxOperation(identity: h.owner.signer, now: t))
        XCTAssertEqual(stillPending.pendingAcceptances?.count, 1)

        try h.relay.advance(to: t.addingTimeInterval(121))
        let afterExpiry = try h.relay.fetchInbox(makeInboxOperation(identity: h.owner.signer, now: t.addingTimeInterval(121)))
        XCTAssertEqual(afterExpiry.pendingAcceptances, [])
    }

    // MARK: - P2-2d: a v4 snapshot round trip retains the signed acceptance

    func testRelaySnapshotRoundTripRetainsTheSignedPendingAcceptance() throws {
        let h = try harness(now: t)
        let acceptance = try h.approver.accept(h.invitation, acceptanceID: "pai-accept-snapshot", now: t)

        let data = try h.relay.snapshot()
        let checkpoint = try h.relay.checkpoint()
        let restored = try InMemoryCompanionRelay(snapshot: data, checkpoint: checkpoint)

        let restoredInbox = try restored.fetchInbox(makeInboxOperation(identity: h.owner.signer, now: t))
        XCTAssertEqual(restoredInbox.pendingAcceptances?.count, 1)
        XCTAssertEqual(restoredInbox.pendingAcceptances?.first?.acceptance, acceptance)
        XCTAssertNoThrow(try restoredInbox.pendingAcceptances?.first?.validateSignature())
    }
}
