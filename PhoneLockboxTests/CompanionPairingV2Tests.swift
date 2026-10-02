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

    // MARK: - storedInvites persistence, pruning and capping (owner-review follow-up, P2-9)

    func testStoredInvitesPersistAndPruneExpiredAcrossACoordinatorReinit() throws {
        let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let freshInvitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: Date())
        let expiredInvitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: Date(timeIntervalSinceNow: -7_200))

        let first = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults)
        first.insertStoredInviteForTesting(freshInvitation)
        first.insertStoredInviteForTesting(expiredInvitation)
        XCTAssertEqual(first.storedInvitesForTesting.count, 2)

        // A fresh coordinator instance over the same App Group suite —
        // mirrors a relaunch. `pruneStoredInvites(now:)` runs at `init`.
        let second = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults)
        XCTAssertEqual(second.storedInvitesForTesting.count, 1, "the expired invite should be pruned on re-init")
        XCTAssertNotNil(second.storedInvitesForTesting[freshInvitation.payload.inviteID], "the still-valid invite should survive the relaunch")
        XCTAssertNil(second.storedInvitesForTesting[expiredInvitation.payload.inviteID])
    }

    /// P2-7: a defensive cap so creating many invites over a long device
    /// lifetime cannot grow `storedInvites` unboundedly.
    func testStoredInvitesAreCappedDroppingTheOldestFirst() throws {
        let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let companion = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults)
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())

        var invitations: [Invitation] = []
        for i in 0..<25 {
            let invitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: Date(timeIntervalSinceNow: Double(i)))
            invitations.append(invitation)
            companion.insertStoredInviteForTesting(invitation)
        }

        XCTAssertEqual(companion.storedInvitesForTesting.count, 20)
        for oldest in invitations.prefix(5) {
            XCTAssertNil(companion.storedInvitesForTesting[oldest.payload.inviteID], "the oldest invites should have been dropped first")
        }
        for newest in invitations.suffix(20) {
            XCTAssertNotNil(companion.storedInvitesForTesting[newest.payload.inviteID])
        }
    }

    // MARK: - dismissPendingAcceptance / confirmPendingAcceptance (P1-1, P2-9)

    /// A convenience bundling a coordinator with the owner identity/signer
    /// it will use, so `confirmPendingAcceptance`-adjacent tests can build
    /// an invite whose `owner` actually matches `companion.ownerIdentity` —
    /// required for `OwnerAcceptanceCheck.verify` (and so the P1-1 guard in
    /// `confirmPendingAcceptance`) to ever succeed.
    private func makeOwnerCoordinator(suiteName: String) throws -> (companion: CompanionCoordinator, ownerSigner: DeviceSigner, defaults: UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let keyStore = InMemoryDeviceKeyStore()
        let companion = CompanionCoordinator(keyStore: keyStore, sharedDefaults: defaults)
        let ownerIdentity = try companion.ensureOwnerIdentityForTesting()
        let ownerSigner = try DeviceSigner(identity: ownerIdentity, keyStore: keyStore)
        return (companion, ownerSigner, defaults)
    }

    func testDismissPendingAcceptanceDiscardsTheStoredInvite() throws {
        let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
        let (companion, ownerSigner, defaults) = try makeOwnerCoordinator(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date()
        let invitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: now)
        companion.insertStoredInviteForTesting(invitation)

        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let signed = try makeSignedAcceptance(invitation: invitation, approverSigner: approverSigner, issuedAt: now)
        let code = try OwnerAcceptanceCheck.verify(signedAcceptance: signed, invite: invitation, ownerIdentity: ownerSigner.identity, now: now)
        let item = VerifiedPendingAcceptance(signedAcceptance: signed, expectedVerificationCode: code)

        companion.dismissPendingAcceptance(item)

        XCTAssertNil(companion.storedInvitesForTesting[invitation.payload.inviteID])
    }

    /// The plan's explicit P1-1 requirement: "Add a unit test that confirm
    /// is refused after discard." Must refuse without ever attempting the
    /// network call — no override is installed, so a stray attempt would
    /// hang/throw against a real transport; the guard must short-circuit
    /// before that, which is itself part of what this test proves (it
    /// completes at all, quickly, with no relay running).
    func testConfirmPendingAcceptanceIsRefusedAfterTheUnderlyingInviteIsDiscarded() async throws {
        let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
        let (companion, ownerSigner, defaults) = try makeOwnerCoordinator(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date()
        let invitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: now)
        companion.insertStoredInviteForTesting(invitation)

        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let signed = try makeSignedAcceptance(invitation: invitation, approverSigner: approverSigner, issuedAt: now)
        let code = try OwnerAcceptanceCheck.verify(signedAcceptance: signed, invite: invitation, ownerIdentity: ownerSigner.identity, now: now)
        let item = VerifiedPendingAcceptance(signedAcceptance: signed, expectedVerificationCode: code)

        // Simulate "Not them" having already discarded the invite —
        // elsewhere, or during an `await` earlier in the same refresh/tap.
        companion.dismissPendingAcceptance(item)
        XCTAssertNil(companion.storedInvitesForTesting[invitation.payload.inviteID])

        await companion.confirmPendingAcceptance(item, nickname: "Ari", grantEarlyEndTrust: true)

        XCTAssertTrue(companion.people.isEmpty, "a discarded acceptance must never be confirmable into a pairing")
    }

    /// The plan's other explicit P1-1 requirement: "one for the assignment
    /// filter" — `refreshInbox()`'s own re-verification right before
    /// publishing `pendingOwnerAcceptances`, factored out as
    /// `reverifyPendingOwnerAcceptancesAtAssignmentTime` so it is directly
    /// testable without a network round trip. Simulates the exact race:
    /// a card was computed as verified earlier in a refresh cycle, then its
    /// invite was discarded (by a concurrent "Not them") before this
    /// assignment-time guard runs.
    func testReverifyAtAssignmentTimeDropsAnEntryWhoseInviteWasDiscardedMidRefresh() throws {
        let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
        let (companion, ownerSigner, defaults) = try makeOwnerCoordinator(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date()
        let invitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: now)
        companion.insertStoredInviteForTesting(invitation)

        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let signed = try makeSignedAcceptance(invitation: invitation, approverSigner: approverSigner, issuedAt: now)
        let code = try OwnerAcceptanceCheck.verify(signedAcceptance: signed, invite: invitation, ownerIdentity: ownerSigner.identity, now: now)
        let computedEarlierInRefresh = [VerifiedPendingAcceptance(signedAcceptance: signed, expectedVerificationCode: code)]

        // The invite is discarded — e.g. a concurrent "Not them" — after
        // `computedEarlierInRefresh` above was built but before the
        // assignment-time guard runs.
        companion.dismissPendingAcceptance(computedEarlierInRefresh[0])

        let reverified = companion.reverifyPendingOwnerAcceptancesAtAssignmentTime(
            computedEarlierInRefresh, ownerIdentity: ownerSigner.identity, now: Date()
        )

        XCTAssertTrue(reverified.isEmpty, "an entry whose invite was discarded mid-refresh must never survive the assignment-time guard")
    }

    /// Companion case: nothing is dropped when `storedInvites` hasn't
    /// changed since the entry was computed — the guard is a no-op in the
    /// ordinary (non-racing) path.
    func testReverifyAtAssignmentTimeKeepsAnEntryWhoseInviteIsStillStored() throws {
        let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
        let (companion, ownerSigner, defaults) = try makeOwnerCoordinator(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date()
        let invitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: now)
        companion.insertStoredInviteForTesting(invitation)

        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let signed = try makeSignedAcceptance(invitation: invitation, approverSigner: approverSigner, issuedAt: now)
        let code = try OwnerAcceptanceCheck.verify(signedAcceptance: signed, invite: invitation, ownerIdentity: ownerSigner.identity, now: now)
        let computedEarlierInRefresh = [VerifiedPendingAcceptance(signedAcceptance: signed, expectedVerificationCode: code)]

        let reverified = companion.reverifyPendingOwnerAcceptancesAtAssignmentTime(
            computedEarlierInRefresh, ownerIdentity: ownerSigner.identity, now: Date()
        )

        XCTAssertEqual(reverified.map(\.id), computedEarlierInRefresh.map(\.id))
    }

    // MARK: - Grant-at-confirm sequencing (owner-review follow-up, P2-9, P2-10)

    private func makePairing(owner: DeviceIdentity, approver: DeviceIdentity, pairingID: String = UUID().uuidString) throws -> Pairing {
        try Pairing(pairingID: pairingID, owner: owner, approver: approver, epoch: 1, createdAt: Date(), state: .active)
    }

    private func makeConsent(pairing: Pairing, scopes: [CompanionScope]) throws -> RelationshipConsent {
        try RelationshipConsent(relationshipID: pairing.pairingID, pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
                                owner: pairing.owner, approver: pairing.approver, ownerScopes: scopes,
                                ownerState: .active, approverState: .pending, updatedAt: Date())
    }

    /// The grant must only ever run after a *successful* confirm, and only
    /// when the owner left the toggle on. Three cases in one test, using
    /// `confirmPendingAcceptanceOverride`/`grantOwnerTrustAfterConfirmOverride`
    /// (mirrors B2c's `useApprovalOverride`) so none of them touch a relay.
    func testGrantRunsOnlyAfterASuccessfulConfirmAndOnlyWhenRequested() async throws {
        struct StubError: Error {}

        // Case 1: confirm fails — the grant must never even be attempted.
        do {
            let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
            let (companion, ownerSigner, defaults) = try makeOwnerCoordinator(suiteName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let now = Date()
            let invitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: now)
            companion.insertStoredInviteForTesting(invitation)
            let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
            let signed = try makeSignedAcceptance(invitation: invitation, approverSigner: approverSigner, issuedAt: now)
            let code = try OwnerAcceptanceCheck.verify(signedAcceptance: signed, invite: invitation, ownerIdentity: ownerSigner.identity, now: now)
            let item = VerifiedPendingAcceptance(signedAcceptance: signed, expectedVerificationCode: code)

            companion.confirmPendingAcceptanceOverride = { _, _ in throw StubError() }
            var grantAttempted = false
            companion.grantOwnerTrustAfterConfirmOverride = { pairing, scopes in
                grantAttempted = true
                return try self.makeConsent(pairing: pairing, scopes: scopes)
            }

            await companion.confirmPendingAcceptance(item, nickname: "Ari", grantEarlyEndTrust: true)

            XCTAssertFalse(grantAttempted, "the grant must never run when confirm itself failed")
            XCTAssertTrue(companion.people.isEmpty)
        }

        // Case 2: confirm succeeds, but the owner left the toggle off — the
        // grant must never run either.
        do {
            let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
            let (companion, ownerSigner, defaults) = try makeOwnerCoordinator(suiteName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let now = Date()
            let invitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: now)
            companion.insertStoredInviteForTesting(invitation)
            let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
            let signed = try makeSignedAcceptance(invitation: invitation, approverSigner: approverSigner, issuedAt: now)
            let code = try OwnerAcceptanceCheck.verify(signedAcceptance: signed, invite: invitation, ownerIdentity: ownerSigner.identity, now: now)
            let item = VerifiedPendingAcceptance(signedAcceptance: signed, expectedVerificationCode: code)
            let pairing = try makePairing(owner: ownerSigner.identity, approver: approverSigner.identity)

            companion.confirmPendingAcceptanceOverride = { _, _ in pairing }
            var grantAttempted = false
            companion.grantOwnerTrustAfterConfirmOverride = { pairing, scopes in
                grantAttempted = true
                return try self.makeConsent(pairing: pairing, scopes: scopes)
            }

            await companion.confirmPendingAcceptance(item, nickname: "Ari", grantEarlyEndTrust: false)

            XCTAssertFalse(grantAttempted, "the grant must never run when the owner left the toggle off")
            XCTAssertEqual(companion.people.first?.nickname, "Ari", "the pairing itself must still confirm")
        }

        // Case 3: confirm succeeds and the toggle is on — the grant must run.
        do {
            let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
            let (companion, ownerSigner, defaults) = try makeOwnerCoordinator(suiteName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let now = Date()
            let invitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: now)
            companion.insertStoredInviteForTesting(invitation)
            let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
            let signed = try makeSignedAcceptance(invitation: invitation, approverSigner: approverSigner, issuedAt: now)
            let code = try OwnerAcceptanceCheck.verify(signedAcceptance: signed, invite: invitation, ownerIdentity: ownerSigner.identity, now: now)
            let item = VerifiedPendingAcceptance(signedAcceptance: signed, expectedVerificationCode: code)
            let pairing = try makePairing(owner: ownerSigner.identity, approver: approverSigner.identity)

            companion.confirmPendingAcceptanceOverride = { _, _ in pairing }
            var grantedScopes: Set<CompanionScope>?
            companion.grantOwnerTrustAfterConfirmOverride = { pairing, scopes in
                grantedScopes = Set(scopes)
                return try self.makeConsent(pairing: pairing, scopes: scopes)
            }

            await companion.confirmPendingAcceptance(item, nickname: "Ari", grantEarlyEndTrust: true)

            XCTAssertEqual(grantedScopes, Set<CompanionScope>([.approveEarlyEnd, .receiveRequests]))
            XCTAssertTrue(companion.people.first?.hasGrantedApproveEarlyEnd ?? false)
            XCTAssertTrue(companion.people.first?.hasGrantedReceiveRequests ?? false)
        }
    }

    /// A grant *failure* must never un-confirm the pairing: the person
    /// stays in `people`, confirmed, just without the owner-side scopes —
    /// exactly the state the person row's own toggles exist to recover
    /// from.
    func testGrantFailureLeavesThePairingConfirmed() async throws {
        let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
        let (companion, ownerSigner, defaults) = try makeOwnerCoordinator(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        struct StubError: Error {}

        let now = Date()
        let invitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: now)
        companion.insertStoredInviteForTesting(invitation)
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let signed = try makeSignedAcceptance(invitation: invitation, approverSigner: approverSigner, issuedAt: now)
        let code = try OwnerAcceptanceCheck.verify(signedAcceptance: signed, invite: invitation, ownerIdentity: ownerSigner.identity, now: now)
        let item = VerifiedPendingAcceptance(signedAcceptance: signed, expectedVerificationCode: code)
        let pairing = try makePairing(owner: ownerSigner.identity, approver: approverSigner.identity)

        companion.confirmPendingAcceptanceOverride = { _, _ in pairing }
        companion.grantOwnerTrustAfterConfirmOverride = { _, _ in throw StubError() }

        await companion.confirmPendingAcceptance(item, nickname: "Ari", grantEarlyEndTrust: true)

        XCTAssertEqual(companion.people.first?.nickname, "Ari", "the pairing must stay confirmed even though the grant failed")
        XCTAssertEqual(companion.people.first?.pairing.pairingID, pairing.pairingID)
        XCTAssertFalse(companion.people.first?.hasGrantedApproveEarlyEnd ?? true, "the failed grant must not be recorded as having happened")
        XCTAssertNotNil(companion.lastError, "the grant failure should still be surfaced")
    }

    /// P2-10: a pairing-ID conflict must skip the grant entirely (never
    /// land on whatever *other* person happens to share the pairing ID)
    /// and must never clear the specific conflict `lastError`
    /// `upsertConfirmedPairing` set.
    func testPairingIDConflictSkipsTheGrantAndKeepsTheConflictError() async throws {
        let suiteName = "com.phone-lockbox.tests.pairing-v2.\(UUID().uuidString)"
        let (companion, ownerSigner, defaults) = try makeOwnerCoordinator(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Seed an existing person whose pairing has a *different*
        // owner/approver but the *same* pairingID the override below will
        // return — the exact collision `upsertConfirmedPairing` guards
        // against.
        let conflictingApproverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let sharedPairingID = UUID().uuidString
        let existingPairing = try makePairing(owner: ownerSigner.identity, approver: conflictingApproverSigner.identity, pairingID: sharedPairingID)
        companion.testOnlySeedConfirmedPairing(existingPairing, nickname: "Existing")

        let now = Date()
        let invitation = try makeInvitation(ownerSigner: ownerSigner, issuedAt: now)
        companion.insertStoredInviteForTesting(invitation)
        let newApproverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let signed = try makeSignedAcceptance(invitation: invitation, approverSigner: newApproverSigner, issuedAt: now)
        let code = try OwnerAcceptanceCheck.verify(signedAcceptance: signed, invite: invitation, ownerIdentity: ownerSigner.identity, now: now)
        let item = VerifiedPendingAcceptance(signedAcceptance: signed, expectedVerificationCode: code)
        // Same pairingID as the already-stored person, but a *different*
        // approver — the conflict `upsertConfirmedPairing` rejects.
        let conflictingPairing = try makePairing(owner: ownerSigner.identity, approver: newApproverSigner.identity, pairingID: sharedPairingID)

        companion.confirmPendingAcceptanceOverride = { _, _ in conflictingPairing }
        var grantAttempted = false
        companion.grantOwnerTrustAfterConfirmOverride = { pairing, scopes in
            grantAttempted = true
            return try self.makeConsent(pairing: pairing, scopes: scopes)
        }

        await companion.confirmPendingAcceptance(item, nickname: "Ari", grantEarlyEndTrust: true)

        XCTAssertFalse(grantAttempted, "a pairing-ID conflict must skip the grant, never landing on the existing person")
        XCTAssertEqual(companion.lastError, "The relay returned a pairing that conflicts with one already stored; ignoring it.")
        XCTAssertEqual(companion.people.first?.nickname, "Existing", "the existing (conflicting) person must be untouched")
    }
}
#endif
