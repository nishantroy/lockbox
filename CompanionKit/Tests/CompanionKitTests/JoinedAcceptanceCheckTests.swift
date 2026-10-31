import XCTest
@testable import CompanionKit

/// `JoinedAcceptanceCheck` is the owner device's only defence now that pairing
/// v3 has no confirm step: a relay-reported pairing counts as "joined" only if
/// the friend-signed acceptance behind it proves it answered an invite this
/// device created.
final class JoinedAcceptanceCheckTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Fixture {
        let relay: InMemoryCompanionRelay
        let owner: CompanionClient
        let approver: CompanionClient
        let issued: IssuedInvite
        let pairing: Pairing
        let signed: SignedAcceptance
        let ownerIdentity: DeviceIdentity
    }

    private func fixture() throws -> Fixture {
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let relay = try InMemoryCompanionRelay(owner: ownerSigner.identity, now: t)
        let now = t
        let owner = CompanionClient(signer: ownerSigner, transport: relay, now: { now })
        let approver = CompanionClient(signer: approverSigner, transport: relay, now: { now })
        let issued = try owner.createInvite(inviteID: "joined-invite", validFor: 3_600, now: t,
                                            nonce: Data(repeating: 5, count: 24), ownerDisplayName: "Alex")
        let invitation = try approver.lookupInvite(token: issued.token)
        let pairing = try approver.acceptInvite(invitation, token: issued.token, approverDisplayName: "Sam",
                                                acceptanceID: "joined-accept", now: t)
        let query = InboxQuery(identityID: ownerSigner.identity.identityID, issuedAt: t)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(query)
        let operationID = operationIdentifier(kind: "inbox", signer: ownerSigner.identity, body: body)
        let unsigned = try SignedOperation(operationID: operationID, expectedRevision: nil, kind: "inbox",
                                           signer: ownerSigner.identity, body: body, signature: Data(repeating: 0, count: 64))
        let signature = try ownerSigner.sign(domain: "\(CompanionCanonical.version).operation", fields: unsigned.signingFields())
        let inbox = try relay.fetchInbox(try SignedOperation(operationID: operationID, expectedRevision: nil, kind: "inbox",
                                                              signer: ownerSigner.identity, body: body, signature: signature))
        let signed = try XCTUnwrap(inbox.acceptances?.first)
        return Fixture(relay: relay, owner: owner, approver: approver, issued: issued, pairing: pairing,
                       signed: signed, ownerIdentity: ownerSigner.identity)
    }

    func testVerifiesAPairingBackedByTheFriendsSignedAcceptanceForAnInviteThisDeviceCreated() throws {
        let f = try fixture()
        XCTAssertNoThrow(try JoinedAcceptanceCheck.verify(signedAcceptance: f.signed, pairing: f.pairing,
                                                          invite: f.issued.invitation, ownerIdentity: f.ownerIdentity))
    }

    func testRejectsAnAcceptanceForAnInviteThisDeviceDidNotCreate() throws {
        let f = try fixture()
        let stranger = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let otherRelay = try InMemoryCompanionRelay(owner: stranger.identity, now: t)
        let other = CompanionClient(signer: stranger, transport: otherRelay, now: { [t] in t })
        let otherInvite = try other.createInvite(inviteID: "joined-invite", validFor: 3_600, now: t,
                                                 nonce: Data(repeating: 5, count: 24), ownerDisplayName: "Alex")
        XCTAssertThrowsError(try JoinedAcceptanceCheck.verify(signedAcceptance: f.signed, pairing: f.pairing,
                                                              invite: otherInvite.invitation, ownerIdentity: f.ownerIdentity))
    }

    func testRejectsAPairingWhoseApproverKeyOrNamesDifferFromTheAcceptance() throws {
        let f = try fixture()
        let attacker = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let swappedApprover = try Pairing(pairingID: f.pairing.pairingID, owner: f.pairing.owner, approver: attacker.identity,
                                          epoch: 1, createdAt: f.pairing.createdAt, state: .active,
                                          ownerDisplayName: "Alex", approverDisplayName: "Sam")
        let renamed = try Pairing(pairingID: f.pairing.pairingID, owner: f.pairing.owner, approver: f.pairing.approver,
                                  epoch: 1, createdAt: f.pairing.createdAt, state: .active,
                                  ownerDisplayName: "Alex", approverDisplayName: "Mallory")
        let wrongID = try Pairing(pairingID: "someone-elses-pairing", owner: f.pairing.owner, approver: f.pairing.approver,
                                  epoch: 1, createdAt: f.pairing.createdAt, state: .active,
                                  ownerDisplayName: "Alex", approverDisplayName: "Sam")
        for bad in [swappedApprover, renamed, wrongID] {
            XCTAssertThrowsError(try JoinedAcceptanceCheck.verify(signedAcceptance: f.signed, pairing: bad,
                                                                  invite: f.issued.invitation, ownerIdentity: f.ownerIdentity))
        }
    }

    func testRejectsATamperedOrForgedAcceptance() throws {
        let f = try fixture()
        var badSignature = f.signed.signature
        badSignature[0] ^= 1
        XCTAssertThrowsError(try JoinedAcceptanceCheck.verify(
            signedAcceptance: SignedAcceptance(acceptance: f.signed.acceptance, signature: badSignature),
            pairing: f.pairing, invite: f.issued.invitation, ownerIdentity: f.ownerIdentity)) {
            XCTAssertEqual($0 as? CompanionError, .invalidSignature)
        }
        // A relay that signs an acceptance with its own key, not the token holder's, and a wrong token.
        let relayKey = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let wrongToken = InviteToken.generate()
        let forgedInvite = f.issued.invitation
        XCTAssertThrowsError(try PairingAcceptance(acceptanceID: "forged", invite: forgedInvite.payload, token: wrongToken,
                                                   approver: relayKey.identity, issuedAt: t))
    }

    func testVerifiedPairingsFiltersAnInboxToOnlyProvenPairings() throws {
        let f = try fixture()
        let attacker = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let injected = try Pairing(pairingID: "injected", owner: f.ownerIdentity, approver: attacker.identity, epoch: 1,
                                   createdAt: t, state: .active, ownerDisplayName: nil, approverDisplayName: "Totally Legit")
        let inbox = try InboxResponse(ownerIdentityID: f.ownerIdentity.identityID, revision: 3, requests: [],
                                      pairings: [f.pairing, injected], acceptances: [f.signed])
        let verified = JoinedAcceptanceCheck.verifiedPairings(
            in: inbox, invites: [f.issued.invitation.payload.inviteID: f.issued.invitation], ownerIdentity: f.ownerIdentity)
        XCTAssertEqual(verified.map(\.pairingID), [f.pairing.pairingID])
        // With no local invite on record, nothing is proven.
        XCTAssertTrue(JoinedAcceptanceCheck.verifiedPairings(in: inbox, invites: [:], ownerIdentity: f.ownerIdentity).isEmpty)
    }
}
