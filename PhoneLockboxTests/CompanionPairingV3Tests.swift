import XCTest
@testable import PhoneLockbox
#if canImport(CompanionKit)
import CompanionKit
#endif

#if canImport(CompanionKit)
/// Pairing v3 (`docs/r5-pairing-v3-plan.md`, slice P3b): host-testable,
/// relay-free coverage of the app layer. The owner trusts a joined friend
/// only through `JoinedAcceptanceCheck` against an invite this device issued;
/// the friend stores the `Pairing` that `acceptInvite` returns. The full HTTP
/// round trip lives in `CompanionLocalRelayFlowTests` and the UI tests.
@MainActor
final class CompanionPairingV3Tests: XCTestCase {

    // MARK: - Fixtures

    private struct OwnerRig {
        let coordinator: CompanionCoordinator
        let keyStore: InMemoryDeviceKeyStore
        let store: InMemoryIssuedInviteStore
        let defaults: UserDefaults
        let ownerSigner: DeviceSigner
        let relay: InMemoryCompanionRelay
        let now: Date
    }

    private func makeOwnerRig(now: Date = Date()) throws -> OwnerRig {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "p3b.\(UUID().uuidString)"))
        let keyStore = InMemoryDeviceKeyStore()
        let store = InMemoryIssuedInviteStore()
        let coordinator = CompanionCoordinator(keyStore: keyStore, sharedDefaults: defaults, inviteStore: store)
        let identity = try coordinator.ensureOwnerIdentityForTesting()
        let signer = try DeviceSigner(identity: identity, keyStore: keyStore)
        let relay = try InMemoryCompanionRelay(owner: identity, now: now)
        return OwnerRig(coordinator: coordinator, keyStore: keyStore, store: store, defaults: defaults,
                        ownerSigner: signer, relay: relay, now: now)
    }

    /// One friend joining through one invite, fully formed offline.
    private struct Join {
        let issued: IssuedInvite
        let pairing: Pairing
        let signed: SignedAcceptance
        let consent: RelationshipConsent
        let approver: DeviceSigner
    }

    private func makeJoin(_ rig: OwnerRig, friendName: String? = "Ari", approver: DeviceSigner? = nil,
                          inviteID: String = UUID().uuidString) throws -> Join {
        let ownerClient = CompanionClient(signer: rig.ownerSigner, transport: rig.relay, now: { [now = rig.now] in now })
        let issued = try ownerClient.createInvite(inviteID: inviteID, validFor: 3_600, now: rig.now, ownerDisplayName: "Owner")
        let approver = try approver ?? DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let acceptance = try PairingAcceptance(acceptanceID: UUID().uuidString, invite: issued.invitation.payload, token: issued.token,
                                               approver: approver.identity, approverDisplayName: friendName, issuedAt: rig.now)
        let signature = try approver.sign(domain: "\(CompanionCanonical.version).acceptance.v3", fields: acceptance.signingFields())
        let pairing = try Pairing(pairingID: Pairing.derivedID(inviteID: inviteID, approverIdentityID: approver.identity.identityID),
                                  owner: rig.ownerSigner.identity, approver: approver.identity, epoch: 1, createdAt: rig.now,
                                  state: .active, ownerDisplayName: "Owner", approverDisplayName: friendName)
        let consent = try RelationshipConsent(
            relationshipID: pairing.pairingID, pairingID: pairing.pairingID, pairEpoch: 1,
            owner: pairing.owner, approver: pairing.approver,
            ownerScopes: [.approveEarlyEnd, .receiveRequests], approverScopes: [.approveEarlyEnd, .receiveRequests],
            ownerState: .active, approverState: .active, updatedAt: rig.now, generation: 2)
        return Join(issued: issued, pairing: pairing, signed: SignedAcceptance(acceptance: acceptance, signature: signature),
                    consent: consent, approver: approver)
    }

    private func inbox(pairings: [Pairing], consents: [RelationshipConsent], acceptances: [SignedAcceptance]) throws -> InboxResponse {
        try InboxResponse(ownerIdentityID: nil, revision: 1, requests: [], pairings: pairings, consents: consents, acceptances: acceptances)
    }

    // MARK: - Owner: trust comes only from the join check

    func testVerifiedJoinAddsANamedPersonAndOneJoinedNotice() throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        rig.coordinator.insertIssuedInviteForTesting(join.issued)
        let response = try inbox(pairings: [join.pairing], consents: [join.consent], acceptances: [join.signed])
        let rejected = rig.coordinator.applyInboxSnapshot(response, viewerIdentity: rig.ownerSigner.identity)

        XCTAssertEqual(rejected, 0)
        XCTAssertEqual(rig.coordinator.people.map(\.nickname), ["Ari"], "the real name, not a placeholder")
        XCTAssertTrue(try XCTUnwrap(rig.coordinator.people.first).joinVerified)
        XCTAssertEqual(rig.coordinator.trustedApprovers.map(\.nickname), ["Ari"], "joined and consented immediately, no confirm step")
        XCTAssertEqual(rig.coordinator.joinedNotices.map(\.name), ["Ari"])
        XCTAssertNil(rig.coordinator.integrityNotice)

        // Re-applying the same inbox never duplicates the person or the notice.
        rig.coordinator.applyInboxSnapshot(response, viewerIdentity: rig.ownerSigner.identity)
        XCTAssertEqual(rig.coordinator.people.count, 1)
        XCTAssertEqual(rig.coordinator.joinedNotices.count, 1)
    }

    func testJoinedNoticeIsDismissableAndStaysDismissedAcrossRelaunch() throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        rig.coordinator.insertIssuedInviteForTesting(join.issued)
        rig.coordinator.applyInboxSnapshot(try inbox(pairings: [join.pairing], consents: [join.consent], acceptances: [join.signed]),
                                           viewerIdentity: rig.ownerSigner.identity)
        let notice = try XCTUnwrap(rig.coordinator.joinedNotices.first)
        rig.coordinator.dismissJoinedNotice(id: notice.id)
        XCTAssertTrue(rig.coordinator.joinedNotices.isEmpty)
        XCTAssertEqual(rig.coordinator.trustedPeople.count, 1, "dismissing the notice keeps the person")

        let relaunched = CompanionCoordinator(keyStore: rig.keyStore, sharedDefaults: rig.defaults, inviteStore: rig.store)
        XCTAssertEqual(relaunched.trustedPeople.count, 1)
        XCTAssertTrue(relaunched.joinedNotices.isEmpty, "the notice is one-time")
    }

    func testAPairingWithoutAnIssuedInviteIsNeverAdded() throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)   // invite deliberately NOT stored on the owner device
        let response = try inbox(pairings: [join.pairing], consents: [join.consent], acceptances: [join.signed])
        rig.coordinator.applyInboxSnapshot(response, viewerIdentity: rig.ownerSigner.identity)
        XCTAssertTrue(rig.coordinator.people.isEmpty)
        XCTAssertTrue(rig.coordinator.trustedApprovers.isEmpty)
        XCTAssertTrue(rig.coordinator.joinedNotices.isEmpty)
    }

    func testARelayFabricatedPairingWithNoAcceptanceIsNeverAdded() throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        rig.coordinator.insertIssuedInviteForTesting(join.issued)
        let response = try inbox(pairings: [join.pairing], consents: [join.consent], acceptances: [])
        rig.coordinator.applyInboxSnapshot(response, viewerIdentity: rig.ownerSigner.identity)
        XCTAssertTrue(rig.coordinator.people.isEmpty)
    }

    func testConsentIsIgnoredForAnUnverifiedOwnerSidePerson() throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        // An earlier-build pairing: stored locally, never verified.
        rig.coordinator.testOnlySeedPerson(join.pairing, nickname: "Old", role: .iAmOwner, joinVerified: false)
        rig.coordinator.applyInboxSnapshot(try inbox(pairings: [join.pairing], consents: [join.consent], acceptances: []),
                                           viewerIdentity: rig.ownerSigner.identity)
        let person = try XCTUnwrap(rig.coordinator.people.first)
        XCTAssertNil(person.consent)
        XCTAssertTrue(rig.coordinator.trustedApprovers.isEmpty)
        XCTAssertTrue(rig.coordinator.trustedPeople.isEmpty)
        XCTAssertTrue(rig.coordinator.hasUnverifiedOwnerPeople, "drives the re-invite hint")
    }

    func testRequestsToAnUnverifiedPersonAreRefusedBeforeAnyNetworkCall() async throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        rig.coordinator.testOnlySeedPerson(join.pairing, nickname: "Old", role: .iAmOwner, consent: join.consent, joinVerified: false)
        let target = try XCTUnwrap(rig.coordinator.people.first)
        await rig.coordinator.requestEarlyEnd(sessionID: "s", activeSetID: "a", start: Date().addingTimeInterval(-60),
                                              end: Date().addingTimeInterval(600), to: [target])
        XCTAssertEqual(rig.coordinator.lastError, "Choose at least one trusted person to ask.")
    }

    func testTheSameFriendAcceptingTwiceIsOneRow() throws {
        let rig = try makeOwnerRig()
        let friend = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let first = try makeJoin(rig, approver: friend)
        let second = try makeJoin(rig, approver: friend)
        rig.coordinator.insertIssuedInviteForTesting(first.issued)
        rig.coordinator.insertIssuedInviteForTesting(second.issued)
        rig.coordinator.applyInboxSnapshot(
            try inbox(pairings: [first.pairing, second.pairing], consents: [first.consent, second.consent],
                      acceptances: [first.signed, second.signed]),
            viewerIdentity: rig.ownerSigner.identity)
        XCTAssertEqual(rig.coordinator.people.count, 2)
        XCTAssertEqual(rig.coordinator.trustedPeople.count, 1)
        XCTAssertEqual(rig.coordinator.trustedApprovers.count, 1, "asking targets the person once")
        XCTAssertEqual(rig.coordinator.joinedNotices.count, 1)
    }

    func testTwoAcceptancesForOneInviteShowACalmNoticeAndAddNobody() throws {
        let rig = try makeOwnerRig()
        let inviteID = UUID().uuidString
        let a = try makeJoin(rig, friendName: "Ari", inviteID: inviteID)
        // A second, different friend "accepting" the same single-use invite.
        let other = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let acceptance = try PairingAcceptance(acceptanceID: UUID().uuidString, invite: a.issued.invitation.payload, token: a.issued.token,
                                               approver: other.identity, approverDisplayName: "Bo", issuedAt: rig.now)
        let signature = try other.sign(domain: "\(CompanionCanonical.version).acceptance.v3", fields: acceptance.signingFields())
        let b = SignedAcceptance(acceptance: acceptance, signature: signature)
        let bPairing = try Pairing(pairingID: Pairing.derivedID(inviteID: inviteID, approverIdentityID: other.identity.identityID),
                                   owner: rig.ownerSigner.identity, approver: other.identity, epoch: 1, createdAt: rig.now,
                                   state: .active, ownerDisplayName: "Owner", approverDisplayName: "Bo")
        rig.coordinator.insertIssuedInviteForTesting(a.issued)
        rig.coordinator.applyInboxSnapshot(try inbox(pairings: [a.pairing, bPairing], consents: [a.consent], acceptances: [a.signed, b]),
                                           viewerIdentity: rig.ownerSigner.identity)
        XCTAssertTrue(rig.coordinator.people.isEmpty)
        XCTAssertEqual(rig.coordinator.integrityNotice, CompanionCoordinator.integrityNoticeText)
    }

    // MARK: - Owner: issued invites live in the invite store

    func testIssuedInvitesPersistThroughTheStoreAndExpiredUnusedOnesArePruned() throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        rig.coordinator.insertIssuedInviteForTesting(join.issued)
        let relaunched = CompanionCoordinator(keyStore: rig.keyStore, sharedDefaults: rig.defaults, inviteStore: rig.store)
        XCTAssertEqual(relaunched.issuedInvitesForTesting.keys.sorted(), [join.issued.invitation.payload.inviteID])

        // Unused and long expired (past the retention window): dropped at launch.
        let old = Date().addingTimeInterval(-40 * 24 * 3_600)
        let oldRig = try makeOwnerRig(now: old)
        let stale = try makeJoin(oldRig)
        let store = InMemoryIssuedInviteStore()
        store.save([stale.issued.invitation.payload.inviteID: stale.issued])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "p3b.\(UUID().uuidString)"))
        let launched = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults, inviteStore: store)
        XCTAssertTrue(launched.issuedInvitesForTesting.isEmpty)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testAJoinedPersonKeepsItsInviteEvenAfterItExpires() throws {
        let old = Date().addingTimeInterval(-40 * 24 * 3_600)
        let rig = try makeOwnerRig(now: old)
        let join = try makeJoin(rig)
        rig.coordinator.insertIssuedInviteForTesting(join.issued)
        rig.coordinator.applyInboxSnapshot(try inbox(pairings: [join.pairing], consents: [join.consent], acceptances: [join.signed]),
                                           viewerIdentity: rig.ownerSigner.identity)
        let relaunched = CompanionCoordinator(keyStore: rig.keyStore, sharedDefaults: rig.defaults, inviteStore: rig.store)
        XCTAssertEqual(relaunched.issuedInvitesForTesting.count, 1, "the check needs it for as long as the pairing exists")
    }

    func testAutoRefreshIsFastOnlyWhileSomethingIsOutstanding() throws {
        let rig = try makeOwnerRig()
        XCTAssertEqual(rig.coordinator.autoRefreshInterval, CompanionCoordinator.idleRefreshInterval)
        let join = try makeJoin(rig)
        rig.coordinator.insertIssuedInviteForTesting(join.issued)
        XCTAssertTrue(rig.coordinator.hasOutstandingInvite)
        XCTAssertEqual(rig.coordinator.autoRefreshInterval, CompanionCoordinator.fastRefreshInterval)
        rig.coordinator.applyInboxSnapshot(try inbox(pairings: [join.pairing], consents: [join.consent], acceptances: [join.signed]),
                                           viewerIdentity: rig.ownerSigner.identity)
        XCTAssertFalse(rig.coordinator.hasOutstandingInvite, "the invite produced its person")
        XCTAssertEqual(rig.coordinator.autoRefreshInterval, CompanionCoordinator.idleRefreshInterval)
        XCTAssertEqual(CompanionCoordinator.fastRefreshInterval, 5)
        XCTAssertEqual(CompanionCoordinator.idleRefreshInterval, 30)
    }

    func testALoopingRefreshFlightIsCappedSoATimerCannotSpinIt() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "p3b.\(UUID().uuidString)"))
        let coordinator = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults,
                                               inviteStore: InMemoryIssuedInviteStore())
        var passes = 0
        // Every pass triggers one more refresh call while the flight is running.
        coordinator.inboxFetchGateForTesting = { [unowned coordinator] in
            passes += 1
            let target = coordinator.refreshCallCountForTesting + 1
            Task { await coordinator.refreshInbox() }
            while coordinator.refreshCallCountForTesting < target { await Task.yield() }
        }
        await coordinator.refreshInbox()
        XCTAssertEqual(passes, CompanionCoordinator.maxRefreshPasses)
    }

    // MARK: - Display names

    func testDisplayNamesUseTheProtocolRulesAndAreTrimmed() throws {
        XCTAssertEqual(CompanionCoordinator.validatedDisplayName("  Ari \n"), "Ari")
        XCTAssertNil(CompanionCoordinator.validatedDisplayName(""))
        XCTAssertNil(CompanionCoordinator.validatedDisplayName("   "))
        XCTAssertNil(CompanionCoordinator.validatedDisplayName(String(repeating: "a", count: 41)))
        XCTAssertNotNil(CompanionCoordinator.validatedDisplayName(String(repeating: "a", count: 40)))
        XCTAssertNil(CompanionCoordinator.validatedDisplayName("Ari\u{202E}"), "bidi override is rejected")
    }

    func testOwnerNameIsStoredAndEditable() throws {
        let rig = try makeOwnerRig()
        XCTAssertEqual(rig.coordinator.ownerDisplayName, "")
        XCTAssertFalse(rig.coordinator.setOwnerDisplayName("   "))
        XCTAssertTrue(rig.coordinator.setOwnerDisplayName("Nishant"))
        XCTAssertTrue(rig.coordinator.setOwnerDisplayName("Nish"))
        let relaunched = CompanionCoordinator(keyStore: rig.keyStore, sharedDefaults: rig.defaults, inviteStore: rig.store)
        XCTAssertEqual(relaunched.ownerDisplayName, "Nish")
    }

    func testCreatingAnInviteWithoutAnOwnerNameAsksForOneAndSendsNothing() async throws {
        let rig = try makeOwnerRig()
        await rig.coordinator.createInvite()
        XCTAssertEqual(rig.coordinator.lastError, "Add your name first, so the person you invite knows it's from you.")
        XCTAssertNil(rig.coordinator.pendingInvite)
    }

    // MARK: - Friend: open link, look up, Accept

    private func makeFriend() throws -> CompanionCoordinator {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "p3b.friend.\(UUID().uuidString)"))
        return CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults, inviteStore: InMemoryIssuedInviteStore())
    }

    private func linkURL(token: String = InviteToken.generate()) throws -> (URL, String) {
        (try XCTUnwrap(URL(string: InviteToken.shareLink(token: token))), token)
    }

    private func failedMessage(_ state: IncomingInviteState) -> String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    func testForeignSchemeIsNotClaimed() throws {
        let friend = try makeFriend()
        XCTAssertFalse(friend.handleIncomingCompanionLink(try XCTUnwrap(URL(string: "phonelockbox://lock/now"))))
        if case .none = friend.incomingInvite {} else { XCTFail("must stay idle") }
    }

    func testAMalformedCompanionLinkIsClaimedWithACalmMessage() throws {
        let friend = try makeFriend()
        XCTAssertTrue(friend.handleIncomingCompanionLink(try XCTUnwrap(URL(string: "phone-lockbox-companion://i/short"))))
        XCTAssertEqual(failedMessage(friend.incomingInvite), CompanionCoordinator.invalidInviteLinkMessage)
        XCTAssertTrue(friend.handleIncomingCompanionLink(try XCTUnwrap(URL(string: "phone-lockbox-companion://invite/abc"))))
        XCTAssertEqual(failedMessage(friend.incomingInvite), CompanionCoordinator.invalidInviteLinkMessage)
    }

    func testLookupFailuresReadAsClearCalmMessages() async throws {
        let friend = try makeFriend()
        let (_, token) = try linkURL()
        let cases: [(Error, String)] = [
            (CompanionTransportError.server(.notFound), "This invite was already used or has expired. Ask for a new link."),
            (CompanionError.expired, "This invite has expired. Ask for a new link."),
            (CompanionTransportError.server(.rateLimited), "Too many tries just now. Wait a minute, then open the link again."),
            (CompanionTransportError.unavailable, "Couldn't reach the relay. Check your connection and open the link again."),
        ]
        for (error, expected) in cases {
            friend.inviteLookupOverride = { _ in throw error }
            await friend.lookUpInvite(token: token)
            XCTAssertEqual(failedMessage(friend.incomingInvite), expected)
        }
    }

    func testALookedUpInviteWaitsForAnExplicitAcceptAndShowsTheOwnersName() async throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        let friend = try makeFriend()
        friend.inviteLookupOverride = { _ in join.issued.invitation }
        await friend.lookUpInvite(token: join.issued.token)
        guard case .ready(let incoming) = friend.incomingInvite else { return XCTFail("expected the invite prompt") }
        XCTAssertEqual(incoming.ownerName, "Owner")
        XCTAssertTrue(friend.people.isEmpty, "opening the link never accepts")
    }

    func testALinkWhoseTokenDoesNotMatchTheInviteIsNotValid() async throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        let friend = try makeFriend()
        friend.inviteLookupOverride = { _ in join.issued.invitation }
        await friend.lookUpInvite(token: InviteToken.generate())
        XCTAssertEqual(failedMessage(friend.incomingInvite), CompanionCoordinator.invalidInviteLinkMessage)
    }

    func testAcceptStoresTheReturnedPairingWithTheOwnersNameAndRemembersTheFriendsName() async throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        let friend = try makeFriend()
        let friendIdentity = try friend.ensureApproverIdentityForTesting()
        let pairing = try Pairing(pairingID: Pairing.derivedID(inviteID: join.issued.invitation.payload.inviteID,
                                                              approverIdentityID: friendIdentity.identityID),
                                  owner: rig.ownerSigner.identity, approver: friendIdentity, epoch: 1, createdAt: Date(),
                                  state: .active, ownerDisplayName: "Owner", approverDisplayName: "Sam")
        var receivedName: String?
        friend.acceptInviteOverride = { _, _, name in receivedName = name; return pairing }
        let incoming = IncomingInvite(invitation: join.issued.invitation, token: join.issued.token)
        friend.incomingInvite = .ready(incoming)

        let blank = await friend.acceptIncomingInvite(incoming, name: "  ")
        XCTAssertFalse(blank)
        XCTAssertNil(receivedName)

        let accepted = await friend.acceptIncomingInvite(incoming, name: " Sam ")
        XCTAssertTrue(accepted)
        XCTAssertEqual(receivedName, "Sam")
        XCTAssertEqual(friend.helpingPeople.map(\.nickname), ["Owner"], "paired immediately, named after the owner")
        XCTAssertEqual(friend.approverDisplayName, "Sam", "prefilled next time")
        if case .none = friend.incomingInvite {} else { XCTFail("no waiting state after Accept") }
    }

    func testAcceptOnAUsedInviteReplacesThePromptWithAClearMessage() async throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        let friend = try makeFriend()
        friend.acceptInviteOverride = { _, _, _ in throw CompanionTransportError.server(.replay) }
        let incoming = IncomingInvite(invitation: join.issued.invitation, token: join.issued.token)
        let accepted = await friend.acceptIncomingInvite(incoming, name: "Sam")
        XCTAssertFalse(accepted)
        XCTAssertEqual(failedMessage(friend.incomingInvite), "This invite was already used or has expired. Ask for a new link.")
        XCTAssertTrue(friend.helpingPeople.isEmpty)
    }

    func testAcceptKeepsThePromptOnATransientNetworkFailure() async throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        let friend = try makeFriend()
        friend.acceptInviteOverride = { _, _, _ in throw CompanionTransportError.unavailable }
        let incoming = IncomingInvite(invitation: join.issued.invitation, token: join.issued.token)
        friend.incomingInvite = .ready(incoming)
        let accepted = await friend.acceptIncomingInvite(incoming, name: "Sam")
        XCTAssertFalse(accepted)
        guard case .ready = friend.incomingInvite else { return XCTFail("the friend can simply tap Accept again") }
        XCTAssertNotNil(friend.lastError)
    }
}
#endif
