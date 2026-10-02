import XCTest
@testable import PhoneLockbox
#if canImport(CompanionKit)
import CompanionKit
#endif

#if canImport(CompanionKit)
/// R5 pairing v2 (`docs/r5-pairing-v2-plan.md`'s "Slice P2b"): host-testable
/// coverage for the app-layer pieces that do not require a reachable relay
/// — `CompanionCoordinator.verifyPendingAcceptances`'s binding of a
/// relay-delivered `SignedAcceptance` to this device's own stored invites,
/// and `handleIncomingCompanionLink`'s expiry validation and "never clears
/// an unrelated error" rule (UX fix item 7). The full network round trip
/// (`createInvite`/`acceptInvite`/`confirmPendingAcceptance`/
/// `dismissPendingAcceptance`) is covered end to end by
/// `PhoneLockboxUITests.CompanionPairingUITests` against a local relay.
@MainActor
final class CompanionPairingV2Tests: XCTestCase {

    // MARK: - Fixtures (offline: signed directly, no transport/relay)

    private struct Fixture {
        let ownerSigner: DeviceSigner
        let approverSigner: DeviceSigner
        let invitation: Invitation
    }

    /// Builds a self-consistent, validly signed `Invitation` without any
    /// network call — mirrors exactly what `CompanionClient.createInvite`
    /// signs internally (`ProtocolModels.swift`'s `createInvite`), just
    /// without a transport.
    private func makeInvitation(ownerSigner: DeviceSigner, inviteID: String = UUID().uuidString,
                               issuedAt: Date, validFor: TimeInterval = 3_600) throws -> Invitation {
        let payload = try InvitePayload(inviteID: inviteID, owner: ownerSigner.identity, issuedAt: issuedAt,
                                        expiresAt: issuedAt.addingTimeInterval(validFor),
                                        nonce: Data((0..<24).map { _ in UInt8.random(in: 0...255) }))
        let signature = try ownerSigner.sign(domain: "\(CompanionCanonical.version).invite", fields: payload.signingFields())
        return try Invitation(payload: payload, signature: signature)
    }

    /// Builds a validly signed `SignedAcceptance` for `invitation`, as the
    /// approver, without any network call — mirrors `CompanionClient.accept`.
    private func makeSignedAcceptance(invitation: Invitation, approverSigner: DeviceSigner,
                                      acceptanceID: String = UUID().uuidString, issuedAt: Date) throws -> SignedAcceptance {
        let acceptance = try PairingAcceptance(acceptanceID: acceptanceID, invite: invitation.payload,
                                               approver: approverSigner.identity, issuedAt: issuedAt)
        let signature = try approverSigner.sign(domain: "\(CompanionCanonical.version).acceptance", fields: acceptance.signingFields())
        return SignedAcceptance(acceptance: acceptance, signature: signature)
    }

    private func makeFixture(now: Date = Date()) throws -> Fixture {
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let invitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: now)
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        return Fixture(ownerSigner: ownerSigner, approverSigner: approverSigner, invitation: invitation)
    }

    // MARK: - verifyPendingAcceptances: local-invite binding (Slice P2b, items 1–2)

    func testVerifyPendingAcceptancesAcceptsAnAcceptanceOfAStoredInvite() throws {
        let now = Date()
        let fixture = try makeFixture(now: now)
        let signed = try makeSignedAcceptance(invitation: fixture.invitation, approverSigner: fixture.approverSigner, issuedAt: now)

        let result = CompanionCoordinator.verifyPendingAcceptances(
            [signed], storedInvites: [fixture.invitation.payload.inviteID: fixture.invitation],
            ownerIdentity: fixture.ownerSigner.identity, now: now
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, signed.acceptance.acceptanceID)
        XCTAssertEqual(
            result.first?.expectedVerificationCode,
            PairingAcceptance.code(invite: fixture.invitation.payload, approver: fixture.approverSigner.identity),
            "the returned code must be the one this device itself derives, never merely copied from the acceptance"
        )
    }

    /// The plan's central requirement (Slice P2b, item 2): "Drop anything
    /// that fails verification or has no matching local invite. Never show
    /// a relay-supplied acceptance for an invite this device didn't create."
    /// An otherwise perfectly well-formed, validly signed acceptance for an
    /// invite this device never stored (or already discarded) must never be
    /// returned.
    func testVerifyPendingAcceptancesDropsAnAcceptanceWithNoMatchingLocalInvite() throws {
        let now = Date()
        let fixture = try makeFixture(now: now)
        let signed = try makeSignedAcceptance(invitation: fixture.invitation, approverSigner: fixture.approverSigner, issuedAt: now)

        // storedInvites is empty: this device never created (or already
        // discarded) the invite the acceptance claims to answer.
        let result = CompanionCoordinator.verifyPendingAcceptances(
            [signed], storedInvites: [:], ownerIdentity: fixture.ownerSigner.identity, now: now
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testVerifyPendingAcceptancesDropsAnAcceptanceForADifferentOwnerIdentity() throws {
        let now = Date()
        let fixture = try makeFixture(now: now)
        let signed = try makeSignedAcceptance(invitation: fixture.invitation, approverSigner: fixture.approverSigner, issuedAt: now)
        let otherOwnerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())

        let result = CompanionCoordinator.verifyPendingAcceptances(
            [signed], storedInvites: [fixture.invitation.payload.inviteID: fixture.invitation],
            ownerIdentity: otherOwnerSigner.identity, now: now
        )

        XCTAssertTrue(result.isEmpty, "an acceptance must never verify against an owner identity other than the invite's own owner")
    }

    func testVerifyPendingAcceptancesDropsATamperedSignature() throws {
        let now = Date()
        let fixture = try makeFixture(now: now)
        var signed = try makeSignedAcceptance(invitation: fixture.invitation, approverSigner: fixture.approverSigner, issuedAt: now)
        signed = SignedAcceptance(acceptance: signed.acceptance, signature: Data(signed.signature.reversed()))

        let result = CompanionCoordinator.verifyPendingAcceptances(
            [signed], storedInvites: [fixture.invitation.payload.inviteID: fixture.invitation],
            ownerIdentity: fixture.ownerSigner.identity, now: now
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testVerifyPendingAcceptancesDropsAnAcceptanceOfAnExpiredInvite() throws {
        let issuedAt = Date(timeIntervalSinceNow: -7_200)
        let fixture = try makeFixture(now: issuedAt) // expiresAt = issuedAt + 3600, already in the past
        let signed = try makeSignedAcceptance(invitation: fixture.invitation, approverSigner: fixture.approverSigner, issuedAt: issuedAt)

        let result = CompanionCoordinator.verifyPendingAcceptances(
            [signed], storedInvites: [fixture.invitation.payload.inviteID: fixture.invitation],
            ownerIdentity: fixture.ownerSigner.identity, now: Date()
        )

        XCTAssertTrue(result.isEmpty)
    }

    /// Several entries, only some of which bind to a stored invite: every
    /// matching one is kept (not just the first), and the mismatched ones
    /// are silently skipped rather than aborting the whole batch.
    func testVerifyPendingAcceptancesFiltersABatchKeepingOnlyThoseWithAMatchingStoredInvite() throws {
        let now = Date()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let storedInvitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: now)
        let discardedInvitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: now)
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())

        let storedSigned = try makeSignedAcceptance(invitation: storedInvitation, approverSigner: approverSigner, issuedAt: now)
        let discardedSigned = try makeSignedAcceptance(invitation: discardedInvitation, approverSigner: approverSigner, issuedAt: now)

        // Only `storedInvitation` is still in the local store — as if
        // `discardedInvitation` had already been confirmed or dismissed.
        let result = CompanionCoordinator.verifyPendingAcceptances(
            [storedSigned, discardedSigned], storedInvites: [storedInvitation.payload.inviteID: storedInvitation],
            ownerIdentity: ownerSigner.identity, now: now
        )

        XCTAssertEqual(result.map(\.id), [storedSigned.acceptance.acceptanceID])
    }

    // MARK: - handleIncomingCompanionLink (Slice P2b, UX fix item 7)

    private func makeCoordinator(suiteName: String) throws -> (CompanionCoordinator, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults), defaults)
    }

    func testHandleIncomingCompanionLinkIgnoresAForeignScheme() throws {
        let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
        let (companion, defaults) = try makeCoordinator(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let handled = companion.handleIncomingCompanionLink(try XCTUnwrap(URL(string: "phonelockbox://status")))

        XCTAssertFalse(handled)
        XCTAssertNil(companion.incomingInvite)
        XCTAssertNil(companion.lastError)
    }

    func testHandleIncomingCompanionLinkRejectsAnUndecodablePayload() throws {
        let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
        let (companion, defaults) = try makeCoordinator(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let handled = companion.handleIncomingCompanionLink(try XCTUnwrap(URL(string: "phone-lockbox-companion://invite/not-valid-base64url")))

        XCTAssertTrue(handled)
        XCTAssertNil(companion.incomingInvite)
        XCTAssertEqual(companion.lastError, CompanionCoordinator.invalidInviteLinkMessage)
    }

    /// R5 pairing v2 UX fix item 7 ("Expired invites"): an incoming link
    /// whose invite has already expired must show a distinct, actionable
    /// message rather than being silently prefilled or dropped.
    func testHandleIncomingCompanionLinkRejectsAnExpiredInviteWithADistinctMessage() throws {
        let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
        let (companion, defaults) = try makeCoordinator(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let issuedAt = Date(timeIntervalSinceNow: -7_200)
        let invitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: issuedAt)

        let handled = companion.handleIncomingCompanionLink(try XCTUnwrap(URL(string: invitation.shareLink)))

        XCTAssertTrue(handled)
        XCTAssertNil(companion.incomingInvite)
        XCTAssertEqual(companion.lastError, CompanionCoordinator.expiredInviteLinkMessage)
    }

    func testHandleIncomingCompanionLinkAcceptsAValidNotYetExpiredInvite() throws {
        let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
        let (companion, defaults) = try makeCoordinator(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let invitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: Date())

        let handled = companion.handleIncomingCompanionLink(try XCTUnwrap(URL(string: invitation.shareLink)))

        XCTAssertTrue(handled)
        XCTAssertEqual(companion.incomingInvite?.payload.inviteID, invitation.payload.inviteID)
    }

    /// R5 pairing v2 UX fix item 7: "A valid link must not clear unrelated
    /// companion errors." `requestEarlyEnd` with no targets is a pure,
    /// local-only guard that sets `lastError` without any network call —
    /// used here purely as a way to put an unrelated error on the
    /// coordinator before exercising the link handler.
    func testHandleIncomingCompanionLinkNeverClearsAPreexistingUnrelatedError() async throws {
        let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
        let (companion, defaults) = try makeCoordinator(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await companion.requestEarlyEnd(sessionID: UUID().uuidString, activeSetID: "set", start: Date(), end: Date(), to: [])
        let unrelatedError = try XCTUnwrap(companion.lastError)

        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let invitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: Date())
        _ = companion.handleIncomingCompanionLink(try XCTUnwrap(URL(string: invitation.shareLink)))

        XCTAssertEqual(companion.lastError, unrelatedError, "a valid incoming invite link must not clear an unrelated error already showing")
        XCTAssertNotNil(companion.incomingInvite, "the link should still be recognized and queued for the top-of-page prompt")
    }
}
#endif
