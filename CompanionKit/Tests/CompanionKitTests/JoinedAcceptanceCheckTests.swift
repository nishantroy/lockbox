import XCTest
@testable import CompanionKit

/// `JoinedAcceptanceCheck` is the owner device's only defence now that pairing
/// v3 has no confirm step: a relay-reported pairing counts as "joined" only if
/// the friend-signed acceptance behind it proves, with a value derived from the
/// token only the link holder has, that it answers an invite this device created.
final class JoinedAcceptanceCheckTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Fixture {
        let relay: InMemoryCompanionRelay
        let owner: CompanionClient
        let approver: CompanionClient
        let issued: IssuedInvite
        let pairing: Pairing
        let signed: SignedAcceptance
        let ownerSigner: DeviceSigner
        var ownerIdentity: DeviceIdentity { ownerSigner.identity }
    }

    private func inboxOperation(_ signer: DeviceSigner) throws -> SignedOperation {
        let query = InboxQuery(identityID: signer.identity.identityID, issuedAt: t)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(query)
        let operationID = operationIdentifier(kind: "inbox", signer: signer.identity, body: body)
        let unsigned = try SignedOperation(operationID: operationID, expectedRevision: nil, kind: "inbox",
                                           signer: signer.identity, body: body, signature: Data(repeating: 0, count: 64))
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).operation", fields: unsigned.signingFields())
        return try SignedOperation(operationID: operationID, expectedRevision: nil, kind: "inbox",
                                   signer: signer.identity, body: body, signature: signature)
    }

    func testIssuedInviteNeverRevealsTokenInDescriptions() throws {
        let f = try fixture()
        let token = f.issued.token
        XCTAssertFalse(token.isEmpty)
        var dumped = ""
        dump(f.issued, to: &dumped)
        let renderings = [String(describing: f.issued), String(reflecting: f.issued), "\(f.issued)", dumped,
                          String(describing: Mirror(reflecting: f.issued).children.map { "\($0.label ?? ""): \($0.value)" }),
                          String(describing: [f.issued]), String(describing: ["k": f.issued])]
        for text in renderings {
            XCTAssertFalse(text.contains(token), "token leaked in: \(text)")
            XCTAssertFalse(text.contains(f.issued.shareLink), "share link leaked in: \(text)")
            XCTAssertTrue(text.contains("<redacted>"))
        }
        // Codable persistence is unchanged (the app stores this in the Keychain).
        let decoded = try JSONDecoder().decode(IssuedInvite.self, from: JSONEncoder().encode(f.issued))
        XCTAssertEqual(decoded, f.issued)
        XCTAssertEqual(decoded.token, token)
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
        let inbox = try relay.fetchInbox(try inboxOperation(ownerSigner))
        let signed = try XCTUnwrap(inbox.acceptances?.first)
        return Fixture(relay: relay, owner: owner, approver: approver, issued: issued, pairing: pairing,
                       signed: signed, ownerSigner: ownerSigner)
    }

    func testVerifiesAPairingBackedByTheLinkHoldersAcceptanceForAnInviteThisDeviceCreated() throws {
        let f = try fixture()
        XCTAssertNoThrow(try JoinedAcceptanceCheck.verify(signedAcceptance: f.signed, pairing: f.pairing,
                                                          issued: f.issued, ownerIdentity: f.ownerIdentity))
    }

    func testRejectsAnAcceptanceForAnInviteThisDeviceDidNotCreateOrWithTheWrongToken() throws {
        let f = try fixture()
        let stranger = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let otherRelay = try InMemoryCompanionRelay(owner: stranger.identity, now: t)
        let other = CompanionClient(signer: stranger, transport: otherRelay, now: { [t] in t })
        let otherInvite = try other.createInvite(inviteID: "joined-invite", validFor: 3_600, now: t,
                                                 nonce: Data(repeating: 5, count: 24), ownerDisplayName: "Alex")
        XCTAssertThrowsError(try JoinedAcceptanceCheck.verify(signedAcceptance: f.signed, pairing: f.pairing,
                                                              issued: otherInvite, ownerIdentity: f.ownerIdentity))
        // The stored invite paired with some other token fails the consistency check too.
        let wrongToken = IssuedInvite(invitation: f.issued.invitation, token: InviteToken.generate())
        XCTAssertThrowsError(try JoinedAcceptanceCheck.verify(signedAcceptance: f.signed, pairing: f.pairing,
                                                              issued: wrongToken, ownerIdentity: f.ownerIdentity))
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
                                                                  issued: f.issued, ownerIdentity: f.ownerIdentity))
        }
    }

    func testRejectsATamperedAcceptanceSignature() throws {
        let f = try fixture()
        var badSignature = f.signed.signature
        badSignature[0] ^= 1
        XCTAssertThrowsError(try JoinedAcceptanceCheck.verify(
            signedAcceptance: SignedAcceptance(acceptance: f.signed.acceptance, signature: badSignature),
            pairing: f.pairing, issued: f.issued, ownerIdentity: f.ownerIdentity)) {
            XCTAssertEqual($0 as? CompanionError, .invalidSignature)
        }
    }

    /// The relay stores the lookup key, so it can build and sign an acceptance with its own key that
    /// the relay now rejects (no possession signature) and the owner would reject anyway.
    func testARelayThatKnowsOnlyTheLookupKeyCannotFabricateATrustedPerson() throws {
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let relayKey = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let relay = try InMemoryCompanionRelay(owner: ownerSigner.identity, now: t)
        let now = t
        let owner = CompanionClient(signer: ownerSigner, transport: relay, now: { now })
        let issued = try owner.createInvite(inviteID: "fabricated", validFor: 600, now: t, nonce: Data(repeating: 6, count: 24),
                                            ownerDisplayName: "Alex")
        let forged = PairingAcceptance(acceptanceID: "forged-accept", inviteID: "fabricated", owner: ownerSigner.identity,
                                       approver: relayKey.identity, issuedAt: t,
                                       lookupKey: issued.invitation.payload.lookupKey,
                                       tokenProof: Data(repeating: 0xAB, count: 32),
                                       approverDisplayName: "Your Friend", acceptedScopes: [.approveEarlyEnd, .receiveRequests])
        let signature = try relayKey.sign(domain: "\(CompanionCanonical.version).acceptance.v3", fields: forged.signingFields())
        let envelope = SignedAcceptance(acceptance: forged, signature: signature)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(envelope)
        let operationID = operationIdentifier(kind: "accept", signer: relayKey.identity, body: body)
        let unsigned = try SignedOperation(operationID: operationID, expectedRevision: nil, kind: "accept",
                                           signer: relayKey.identity, body: body, signature: Data(repeating: 0, count: 64))
        let operation = try SignedOperation(operationID: operationID, expectedRevision: nil, kind: "accept", signer: relayKey.identity,
                                            body: body, signature: try relayKey.sign(domain: "\(CompanionCanonical.version).operation",
                                                                                     fields: unsigned.signingFields()))
        // The relay now refuses it outright: it cannot produce the token-derived possession signature.
        XCTAssertThrowsError(try relay.submit(operation)) { XCTAssertEqual($0 as? CompanionError, .unauthorized) }

        // Even if a hostile relay reported such a pairing anyway, the owner's own check rejects it
        // (no valid possession signature, and the token proof it guessed does not match).
        let pairing = try Pairing(pairingID: Pairing.derivedID(inviteID: "fabricated", approverIdentityID: relayKey.identity.identityID),
                                  owner: ownerSigner.identity, approver: relayKey.identity, epoch: 1, createdAt: t, state: .active,
                                  ownerDisplayName: "Alex", approverDisplayName: "Your Friend")
        XCTAssertThrowsError(try JoinedAcceptanceCheck.verify(signedAcceptance: envelope, pairing: pairing, issued: issued,
                                                              ownerIdentity: ownerSigner.identity)) {
            XCTAssertEqual($0 as? CompanionError, .unauthorized)
        }
        let inbox = try InboxResponse(ownerIdentityID: ownerSigner.identity.identityID, revision: 2, requests: [],
                                      pairings: [pairing], acceptances: [envelope])
        let result = JoinedAcceptanceCheck.verifiedPairings(in: inbox, invites: [issued.invitation.payload.inviteID: issued],
                                                            ownerIdentity: ownerSigner.identity)
        XCTAssertTrue(result.verified.isEmpty)
        XCTAssertEqual(result.integrityWarnings.count, 1)
    }

    func testVerifiedPairingsFiltersAnInboxToOnlyProvenActivePairings() throws {
        let f = try fixture()
        let attacker = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let injected = try Pairing(pairingID: "injected", owner: f.ownerIdentity, approver: attacker.identity, epoch: 1,
                                   createdAt: t, state: .active, ownerDisplayName: nil, approverDisplayName: "Totally Legit")
        let inbox = try InboxResponse(ownerIdentityID: f.ownerIdentity.identityID, revision: 3, requests: [],
                                      pairings: [f.pairing, injected], acceptances: [f.signed])
        let invites = [f.issued.invitation.payload.inviteID: f.issued]
        let result = JoinedAcceptanceCheck.verifiedPairings(in: inbox, invites: invites, ownerIdentity: f.ownerIdentity)
        XCTAssertEqual(result.verified.map(\.pairingID), [f.pairing.pairingID])
        XCTAssertTrue(result.integrityWarnings.isEmpty)
        // With no local invite on record, nothing is proven.
        XCTAssertTrue(JoinedAcceptanceCheck.verifiedPairings(in: inbox, invites: [:], ownerIdentity: f.ownerIdentity).verified.isEmpty)
        // A revoked pairing is not "joined".
        var revoked = f.pairing
        revoked.state = .revoked
        let revokedInbox = try InboxResponse(ownerIdentityID: f.ownerIdentity.identityID, revision: 3, requests: [],
                                             pairings: [revoked], acceptances: [f.signed])
        XCTAssertTrue(JoinedAcceptanceCheck.verifiedPairings(in: revokedInbox, invites: invites, ownerIdentity: f.ownerIdentity).verified.isEmpty)
    }

    func testAnAcceptanceThatMatchesAHeldInviteButFailsVerificationRaisesAnIntegrityWarning() throws {
        let f = try fixture()
        var badSignature = f.signed.signature
        badSignature[0] ^= 1
        let tampered = SignedAcceptance(acceptance: f.signed.acceptance, signature: badSignature)
        let inbox = try InboxResponse(ownerIdentityID: f.ownerIdentity.identityID, revision: 3, requests: [],
                                      pairings: [f.pairing], acceptances: [tampered])
        let result = JoinedAcceptanceCheck.verifiedPairings(in: inbox, invites: [f.issued.invitation.payload.inviteID: f.issued],
                                                            ownerIdentity: f.ownerIdentity)
        XCTAssertTrue(result.verified.isEmpty)
        XCTAssertEqual(result.integrityWarnings.count, 1)
        // An acceptance for an invite this device does not hold is simply not ours: no warning.
        let unrelated = JoinedAcceptanceCheck.verifiedPairings(in: inbox, invites: [:], ownerIdentity: f.ownerIdentity)
        XCTAssertTrue(unrelated.integrityWarnings.isEmpty)
    }

    func testIssuedInviteSurvivesACodableRoundTrip() throws {
        let f = try fixture()
        let data = try JSONEncoder().encode(f.issued)
        XCTAssertEqual(try JSONDecoder().decode(IssuedInvite.self, from: data), f.issued)
    }

    func testMoreThanOneAcceptanceForASingleUseInviteRejectsEveryPairingAndWarns() throws {
        let f = try fixture()
        let second = SignedAcceptance(
            acceptance: PairingAcceptance(acceptanceID: "second", inviteID: f.signed.acceptance.inviteID, owner: f.ownerIdentity,
                                          approver: f.signed.acceptance.approver, issuedAt: t,
                                          lookupKey: f.signed.acceptance.lookupKey, tokenProof: f.signed.acceptance.tokenProof,
                                          approverDisplayName: "Sam", acceptedScopes: f.signed.acceptance.acceptedScopes),
            signature: f.signed.signature)
        let inbox = try InboxResponse(ownerIdentityID: f.ownerIdentity.identityID, revision: 3, requests: [],
                                      pairings: [f.pairing], acceptances: [f.signed, second])
        let result = JoinedAcceptanceCheck.verifiedPairings(in: inbox, invites: [f.issued.invitation.payload.inviteID: f.issued],
                                                            ownerIdentity: f.ownerIdentity)
        XCTAssertTrue(result.verified.isEmpty)
        XCTAssertEqual(result.integrityWarnings.count, 1)
    }
}
