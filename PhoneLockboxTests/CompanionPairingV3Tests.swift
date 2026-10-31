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
        XCTAssertTrue(store.invites.isEmpty)
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

    func testALoopingRefreshFlightIsCappedWithOneBoundedFollowUp() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "p3b.\(UUID().uuidString)"))
        let coordinator = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults,
                                               inviteStore: InMemoryIssuedInviteStore())
        let cap = CompanionCoordinator.maxRefreshPasses
        var passes = 0
        // While the first flight runs, every pass is joined by one more refresh call.
        coordinator.inboxFetchGateForTesting = { [unowned coordinator] in
            passes += 1
            guard passes <= cap else { return }
            let target = coordinator.refreshCallCountForTesting + 1
            Task { await coordinator.refreshInbox() }
            while coordinator.refreshCallCountForTesting < target { await Task.yield() }
        }
        await coordinator.refreshInbox()
        // The caller that joined during the last pass gets exactly one follow-up flight.
        while passes < cap + 1 { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(passes, cap + 1, "capped at \(cap) passes, then one follow-up, never chained")
    }

    // MARK: - Invite store robustness, trust demotion, friend-side stop

    func testAKeychainReadErrorKeepsVerifiedPeopleVerifiedAndNeverOverwritesTheStore() async throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        rig.coordinator.insertIssuedInviteForTesting(join.issued)
        rig.coordinator.applyInboxSnapshot(try inbox(pairings: [join.pairing], consents: [join.consent], acceptances: [join.signed]),
                                           viewerIdentity: rig.ownerSigner.identity)
        XCTAssertEqual(rig.coordinator.trustedApprovers.count, 1)

        rig.store.failLoads = true   // e.g. errSecInteractionNotAllowed while the phone is locked
        let relaunched = CompanionCoordinator(keyStore: rig.keyStore, sharedDefaults: rig.defaults, inviteStore: rig.store)
        XCTAssertTrue(relaunched.inviteStoreFailed)
        // An inbox without the acceptance would normally demote them; a local read error must not.
        relaunched.applyInboxSnapshot(try inbox(pairings: [join.pairing], consents: [join.consent], acceptances: []),
                                      viewerIdentity: rig.ownerSigner.identity)
        XCTAssertEqual(relaunched.trustedApprovers.count, 1, "still verified")
        XCTAssertNil(relaunched.integrityNotice)

        // Nothing is written while the store is unreadable...
        _ = relaunched.setOwnerDisplayName("Owner")
        relaunched.insertIssuedInviteForTesting(try makeJoin(rig).issued)
        XCTAssertEqual(rig.store.invites.count, 1, "the real item was not overwritten")
        // ...and creating a new invite says so instead of proceeding.
        relaunched.issueInviteOverride = { _, _ in XCTFail("must not reach the relay"); throw CompanionError.unauthorized }
        await relaunched.createInvite()
        XCTAssertEqual(relaunched.lastError, CompanionCoordinator.inviteStoreReadFailedMessage)
        XCTAssertNil(relaunched.pendingInvite)
    }

    func testAnInviteIsNotShownWhenItCannotBeSavedSecurely() async throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        XCTAssertTrue(rig.coordinator.setOwnerDisplayName("Owner"))
        rig.coordinator.issueInviteOverride = { _, _ in join.issued }
        rig.store.failSaves = true
        await rig.coordinator.createInvite()
        XCTAssertNil(rig.coordinator.pendingInvite)
        XCTAssertEqual(rig.coordinator.lastError, "Couldn't save the invite securely on this device, so it wasn't shown. Try again.")
        XCTAssertTrue(rig.coordinator.issuedInvitesForTesting.isEmpty)

        rig.store.failSaves = false
        await rig.coordinator.createInvite()
        XCTAssertNotNil(rig.coordinator.pendingInvite)
        XCTAssertNil(rig.coordinator.lastError)
    }

    func testAnOutstandingInviteIsShownAgainAfterRelaunch() throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        rig.coordinator.insertIssuedInviteForTesting(join.issued)
        let relaunched = CompanionCoordinator(keyStore: rig.keyStore, sharedDefaults: rig.defaults, inviteStore: rig.store)
        XCTAssertEqual(relaunched.pendingInvite?.invitation.payload.inviteID, join.issued.invitation.payload.inviteID)
    }

    func testInvitesAreDroppedAtLaunchWhenThereIsNoOwnerIdentity() throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        let store = InMemoryIssuedInviteStore()
        store.invites = [join.issued.invitation.payload.inviteID: join.issued]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "p3b.\(UUID().uuidString)"))
        _ = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults, inviteStore: store)
        XCTAssertTrue(store.invites.isEmpty)
    }

    func testAPreviouslyVerifiedPersonBecomesUnverifiedWhenTheAcceptanceDisappears() throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        rig.coordinator.insertIssuedInviteForTesting(join.issued)
        rig.coordinator.applyInboxSnapshot(try inbox(pairings: [join.pairing], consents: [join.consent], acceptances: [join.signed]),
                                           viewerIdentity: rig.ownerSigner.identity)
        XCTAssertEqual(rig.coordinator.trustedApprovers.count, 1)
        rig.coordinator.applyInboxSnapshot(try inbox(pairings: [join.pairing], consents: [join.consent], acceptances: []),
                                           viewerIdentity: rig.ownerSigner.identity)
        XCTAssertTrue(rig.coordinator.trustedApprovers.isEmpty)
        XCTAssertTrue(rig.coordinator.trustedPeople.isEmpty)
        XCTAssertTrue(rig.coordinator.hasUnverifiedOwnerPeople)
    }

    func testStoppingBeingATrustedPersonRevokesBothScopesOncePerPairingWithThatOwner() async throws {
        let rig = try makeOwnerRig()
        let first = try makeJoin(rig), second = try makeJoin(rig)
        let friend = try makeFriend()
        friend.testOnlySeedPerson(first.pairing, nickname: "Owner", role: .iAmApprover, consent: first.consent, joinVerified: false)
        friend.testOnlySeedPerson(second.pairing, nickname: "Owner", role: .iAmApprover, consent: second.consent, joinVerified: false)
        var calls: [(String, Set<CompanionScope>)] = []
        friend.revokeScopesOverride = { pairing, scopes in
            calls.append((pairing.pairingID, Set(scopes)))
            let source = pairing.pairingID == first.pairing.pairingID ? first.consent : second.consent
            return try RelationshipConsent(
                relationshipID: pairing.pairingID, pairingID: pairing.pairingID, pairEpoch: 1, owner: pairing.owner, approver: pairing.approver,
                ownerScopes: source.ownerScopes, approverScopes: [], ownerState: .active, approverState: .active,
                updatedAt: Date(), generation: source.generation + 1)
        }
        XCTAssertEqual(friend.helpingPeople.count, 1, "one row for one owner")
        await friend.stopBeingTrustedPerson(for: try XCTUnwrap(friend.helpingPeople.first))
        XCTAssertNil(friend.lastError)
        XCTAssertEqual(calls.count, 2, "one revoke call per pairing, not one per scope")
        XCTAssertTrue(calls.allSatisfy { $0.1 == [.approveEarlyEnd, .receiveRequests] })
        XCTAssertTrue(friend.people.allSatisfy(\.approverStoppedHelping))
    }

    func testFriendSideAdvanceOnlyRuleRejectsAConflictingAcceptResponse() async throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        let friend = try makeFriend()
        let friendIdentity = try friend.ensureApproverIdentityForTesting()
        let make = { (epoch: UInt64, approver: DeviceIdentity) in
            try Pairing(pairingID: "fixed-pairing", owner: rig.ownerSigner.identity, approver: approver, epoch: epoch,
                        createdAt: Date(), state: .active, ownerDisplayName: "Owner", approverDisplayName: "Sam")
        }
        friend.testOnlySeedPerson(try make(2, friendIdentity), nickname: "Owner", role: .iAmApprover, joinVerified: false)
        friend.acceptInviteOverride = { _, _, _ in try make(1, friendIdentity) }   // older epoch
        let incoming = IncomingInvite(invitation: join.issued.invitation, token: join.issued.token)
        let accepted = await friend.acceptIncomingInvite(incoming, name: "Sam")
        XCTAssertFalse(accepted)
        XCTAssertEqual(friend.people.first?.pairing.epoch, 2, "the stored record was not overwritten")
    }

    func testNobodyCanBeAskedHintWordingDoesNotClaimNobodyJoined() throws {
        // Joined but not yet fully trusted: people exist, trustedApprovers is empty.
        // (The view distinguishes the two cases from exactly these two values.)
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        rig.coordinator.insertIssuedInviteForTesting(join.issued)
        rig.coordinator.applyInboxSnapshot(try inbox(pairings: [join.pairing], consents: [], acceptances: [join.signed]),
                                           viewerIdentity: rig.ownerSigner.identity)
        XCTAssertEqual(rig.coordinator.trustedPeople.count, 1)
        XCTAssertTrue(rig.coordinator.trustedApprovers.isEmpty)
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

    // MARK: - P3c-app: local errors, expiry, invite-store recovery, Ask

    private struct FailingKeyStore: DeviceKeyStore {
        func save(privateKey: Data, for identityID: String) throws { throw CompanionError.keyUnavailable }
        func loadPrivateKey(for identityID: String) throws -> Data? { nil }
        func deletePrivateKey(for identityID: String) throws {}
    }

    /// An owner coordinator with one verified, fully trusted person and the invite that created them.
    private func makeTrustedOwner(now: Date = Date()) throws -> (OwnerRig, Join) {
        let rig = try makeOwnerRig(now: now)
        let join = try makeJoin(rig)
        rig.coordinator.insertIssuedInviteForTesting(join.issued)
        rig.coordinator.applyInboxSnapshot(try inbox(pairings: [join.pairing], consents: [join.consent], acceptances: [join.signed]),
                                           viewerIdentity: rig.ownerSigner.identity)
        XCTAssertEqual(rig.coordinator.trustedApprovers.count, 1)
        return (rig, join)
    }

    func testLocalFailuresNeverReadAsRelayProblems() async throws {
        for local in [CompanionLocalError.storageUnavailable, .identityStorage] {
            let message = CompanionCoordinator.describe(local)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("relay"), message)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("reach"), message)
        }
        XCTAssertTrue(CompanionCoordinator.describe(CompanionTransportError.unavailable).contains("reach the relay"))
        XCTAssertTrue(CompanionCoordinator.describe(CompanionTransportError.timedOut).contains("reach the relay"))

        // A Keychain that refuses the new device key: Accept explains it, keeps the prompt, sends nothing.
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "p3c.\(UUID().uuidString)"))
        let friend = CompanionCoordinator(keyStore: FailingKeyStore(), sharedDefaults: defaults, inviteStore: InMemoryIssuedInviteStore())
        friend.acceptInviteOverride = { _, _, _ in XCTFail("must not reach the relay"); throw CompanionError.unauthorized }
        let incoming = IncomingInvite(invitation: join.issued.invitation, token: join.issued.token)
        friend.incomingInvite = .ready(incoming)
        let accepted = await friend.acceptIncomingInvite(incoming, name: "Sam")
        XCTAssertFalse(accepted)
        XCTAssertEqual(friend.lastError, CompanionLocalError.identityStorage.message)
        XCTAssertFalse(friend.needsRepair)
        guard case .ready = friend.incomingInvite else { return XCTFail("the prompt stays so Accept can be tried again") }
    }

    func testAnExpiredPendingInviteIsShownAsExpiredAndStopsFastPolling() async throws {
        let rig = try makeOwnerRig(now: Date().addingTimeInterval(-7_200))   // issued two hours ago, expired an hour ago
        let join = try makeJoin(rig)
        XCTAssertTrue(rig.coordinator.setOwnerDisplayName("Owner"))
        rig.coordinator.issueInviteOverride = { _, _ in join.issued }
        await rig.coordinator.createInvite()
        XCTAssertNotNil(rig.coordinator.pendingInvite)
        XCTAssertTrue(rig.coordinator.pendingInviteIsExpired)
        XCTAssertFalse(rig.coordinator.hasOutstandingInvite)
        XCTAssertEqual(rig.coordinator.autoRefreshInterval, CompanionCoordinator.idleRefreshInterval)

        // A refresh does not make the expired link disappear or come back to life.
        rig.coordinator.applyInboxSnapshot(try inbox(pairings: [], consents: [], acceptances: []), viewerIdentity: rig.ownerSigner.identity)
        XCTAssertTrue(rig.coordinator.pendingInviteIsExpired)

        // A relaunch does not offer an expired link again.
        let relaunched = CompanionCoordinator(keyStore: rig.keyStore, sharedDefaults: rig.defaults, inviteStore: rig.store)
        XCTAssertNil(relaunched.pendingInvite)

        // Creating a new one replaces it.
        let fresh = try makeOwnerRig()
        let freshJoin = try makeJoin(fresh)
        rig.coordinator.issueInviteOverride = { _, _ in freshJoin.issued }
        await rig.coordinator.createInvite()
        XCTAssertFalse(rig.coordinator.pendingInviteIsExpired)
        XCTAssertEqual(rig.coordinator.pendingInvite?.invitation.payload.inviteID, freshJoin.issued.invitation.payload.inviteID)
    }

    func testALinkThatCreatedAPersonStopsBeingOffered() async throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        XCTAssertTrue(rig.coordinator.setOwnerDisplayName("Owner"))
        rig.coordinator.issueInviteOverride = { _, _ in join.issued }
        await rig.coordinator.createInvite()
        XCTAssertNotNil(rig.coordinator.pendingInvite)
        XCTAssertFalse(rig.coordinator.pendingInviteIsExpired)
        rig.coordinator.applyInboxSnapshot(try inbox(pairings: [join.pairing], consents: [join.consent], acceptances: [join.signed]),
                                           viewerIdentity: rig.ownerSigner.identity)
        XCTAssertNil(rig.coordinator.pendingInvite, "the link was used; the card goes back to creating a new one")
    }

    func testAKeychainDecodeFailureIsToldApartFromALockedPhone() async throws {
        let (rig, join) = try makeTrustedOwner()
        XCTAssertNotNil(rig.store.invites[join.issued.invitation.payload.inviteID])

        // Locked: a retry later is the answer; the reset must refuse and the item must survive.
        rig.store.failLoads = true; rig.store.failureKind = .locked
        let locked = CompanionCoordinator(keyStore: rig.keyStore, sharedDefaults: rig.defaults, inviteStore: rig.store)
        XCTAssertEqual(locked.inviteStoreStatus, .locked)
        XCTAssertFalse(locked.inviteStoreIsCorrupt)
        XCTAssertEqual(locked.inviteStoreProblemMessage, CompanionCoordinator.inviteStoreReadFailedMessage)
        locked.resetUnreadableInviteStore()
        XCTAssertEqual(rig.store.invites.count, 1, "a locked phone never leads to deleting good data")
        XCTAssertEqual(locked.inviteStoreStatus, .locked)

        // Any other read error: transient wording, still no reset.
        rig.store.failureKind = .failed
        let other = CompanionCoordinator(keyStore: rig.keyStore, sharedDefaults: rig.defaults, inviteStore: rig.store)
        XCTAssertEqual(other.inviteStoreStatus, .unavailable)
        XCTAssertEqual(other.inviteStoreProblemMessage, CompanionCoordinator.inviteStoreUnavailableMessage)
        other.resetUnreadableInviteStore()
        XCTAssertEqual(rig.store.invites.count, 1)

        // Corrupt: its own state with a recovery route and no relay call while it lasts.
        rig.store.failureKind = .corrupt
        let corrupt = CompanionCoordinator(keyStore: rig.keyStore, sharedDefaults: rig.defaults, inviteStore: rig.store)
        XCTAssertTrue(corrupt.inviteStoreIsCorrupt)
        XCTAssertNil(corrupt.inviteStoreProblemMessage, "the reset card carries the wording")
        XCTAssertTrue(CompanionCoordinator.inviteStoreCorruptMessage.contains("Reset"))
        XCTAssertTrue(corrupt.setOwnerDisplayName("Owner"))
        corrupt.issueInviteOverride = { _, _ in XCTFail("must not reach the relay"); throw CompanionError.unauthorized }
        await corrupt.createInvite()
        XCTAssertNil(corrupt.pendingInvite)
        XCTAssertEqual(rig.store.invites.count, 1, "nothing written over the unreadable item")

        // Reset clears the item and makes invites work again.
        rig.store.failLoads = false
        corrupt.resetUnreadableInviteStore()
        XCTAssertEqual(corrupt.inviteStoreStatus, .readable)
        XCTAssertTrue(rig.store.invites.isEmpty)
        let fresh = try makeJoin(rig)
        corrupt.issueInviteOverride = { _, _ in fresh.issued }
        await corrupt.createInvite()
        XCTAssertNotNil(corrupt.pendingInvite)
        XCTAssertNil(corrupt.lastError)
    }

    func testRemovingAPersonWhileTheInviteStoreIsUnreadableLeavesNoTokenBehind() async throws {
        let (rig, join) = try makeTrustedOwner()
        let inviteID = join.issued.invitation.payload.inviteID
        rig.store.failLoads = true
        let relaunched = CompanionCoordinator(keyStore: rig.keyStore, sharedDefaults: rig.defaults, inviteStore: rig.store)
        XCTAssertTrue(relaunched.inviteStoreFailed)
        var revoked: [String] = []
        relaunched.revokePairingOverride = { revoked.append($0.pairingID) }
        await relaunched.revokePairing(try XCTUnwrap(relaunched.trustedPeople.first))
        XCTAssertEqual(revoked, [join.pairing.pairingID])
        XCTAssertNil(relaunched.lastError)
        XCTAssertNotNil(rig.store.invites[inviteID], "the unreadable item was not touched")

        // Once the store reads again the removed person's token goes.
        rig.store.failLoads = false
        relaunched.reloadInviteStoreForTesting()
        XCTAssertTrue(rig.store.invites.isEmpty)
        XCTAssertTrue(relaunched.issuedInvitesForTesting.isEmpty)
        XCTAssertNil(relaunched.pendingInvite)
    }

    func testARemovalThatCouldNotDeleteItsTokenIsFinishedAtNextLaunch() async throws {
        let (rig, _) = try makeTrustedOwner()
        rig.store.failLoads = true
        let whileLocked = CompanionCoordinator(keyStore: rig.keyStore, sharedDefaults: rig.defaults, inviteStore: rig.store)
        whileLocked.revokePairingOverride = { _ in }
        await whileLocked.revokePairing(try XCTUnwrap(whileLocked.trustedPeople.first))
        XCTAssertEqual(rig.store.invites.count, 1, "could not be deleted while unreadable")

        // The app is quit; on the next launch the store reads and the removed person's token goes.
        rig.store.failLoads = false
        let relaunched = CompanionCoordinator(keyStore: rig.keyStore, sharedDefaults: rig.defaults, inviteStore: rig.store)
        XCTAssertTrue(rig.store.invites.isEmpty, "the removed person's token does not outlive them")
        XCTAssertNil(relaunched.pendingInvite, "a consumed invite is never offered again")
    }

    func testAConsumedInviteIsNotRestoredAsThePendingLink() throws {
        // The launch discard deletes a removed person's token, so the restore
        // filter is exercised where the token is still held: the person is
        // revoked by the relay (an inbox update) during the session.
        let (rig, join) = try makeTrustedOwner()
        var revoked = join.pairing
        revoked.state = .revoked
        rig.coordinator.applyInboxSnapshot(try inbox(pairings: [revoked], consents: [join.consent], acceptances: [join.signed]),
                                           viewerIdentity: rig.ownerSigner.identity)
        XCTAssertNotNil(rig.coordinator.issuedInvitesForTesting[join.issued.invitation.payload.inviteID], "token still held")
        XCTAssertNil(rig.coordinator.pendingInvite)
        rig.coordinator.restorePendingInviteForTesting()
        XCTAssertNil(rig.coordinator.pendingInvite, "a consumed invite is never offered again")
    }

    func testThePendingLinkComesBackWhenAnUnreadableStoreReadsAgain() throws {
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        rig.coordinator.insertIssuedInviteForTesting(join.issued)
        rig.store.failLoads = true
        let relaunched = CompanionCoordinator(keyStore: rig.keyStore, sharedDefaults: rig.defaults, inviteStore: rig.store)
        XCTAssertNil(relaunched.pendingInvite)
        rig.store.failLoads = false
        relaunched.reloadInviteStoreForTesting()
        XCTAssertEqual(relaunched.pendingInvite?.invitation.payload.inviteID, join.issued.invitation.payload.inviteID)
        XCTAssertEqual(relaunched.inviteStoreStatus, .readable)
    }

    func testStopKeepsAConsentWarningItSetItself() async throws {
        let rig = try makeOwnerRig()
        let first = try makeJoin(rig), other = try makeJoin(rig)
        let friend = try makeFriend()
        friend.testOnlySeedPerson(first.pairing, nickname: "Owner", role: .iAmApprover, consent: first.consent, joinVerified: false)
        // The relay answers with a consent that belongs to a different pairing: it is ignored and says so.
        friend.revokeScopesOverride = { _, _ in other.consent }
        await friend.stopBeingTrustedPerson(for: try XCTUnwrap(friend.helpingPeople.first))
        let warning = try XCTUnwrap(friend.lastError)
        XCTAssertTrue(warning.contains("unexpected consent data"), warning)
        XCTAssertFalse(try XCTUnwrap(friend.people.first).approverStoppedHelping, "nothing was recorded as stopped")
    }

    func testTheIntegrityNoticeIsClearedWhileTheInviteStoreIsUnreadable() throws {
        let rig = try makeOwnerRig()
        let inviteID = UUID().uuidString
        let a = try makeJoin(rig, friendName: "Ari", inviteID: inviteID)
        let other = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let acceptance = try PairingAcceptance(acceptanceID: UUID().uuidString, invite: a.issued.invitation.payload, token: a.issued.token,
                                               approver: other.identity, approverDisplayName: "Bo", issuedAt: rig.now)
        let b = SignedAcceptance(acceptance: acceptance,
                                 signature: try other.sign(domain: "\(CompanionCanonical.version).acceptance.v3", fields: acceptance.signingFields()))
        let bPairing = try Pairing(pairingID: Pairing.derivedID(inviteID: inviteID, approverIdentityID: other.identity.identityID),
                                   owner: rig.ownerSigner.identity, approver: other.identity, epoch: 1, createdAt: rig.now,
                                   state: .active, ownerDisplayName: "Owner", approverDisplayName: "Bo")
        rig.coordinator.insertIssuedInviteForTesting(a.issued)
        let snapshot = try inbox(pairings: [a.pairing, bPairing], consents: [a.consent], acceptances: [a.signed, b])
        rig.coordinator.applyInboxSnapshot(snapshot, viewerIdentity: rig.ownerSigner.identity)
        XCTAssertEqual(rig.coordinator.integrityNotice, CompanionCoordinator.integrityNoticeText)

        rig.store.failLoads = true
        rig.coordinator.reloadInviteStoreForTesting()
        XCTAssertNil(rig.coordinator.integrityNotice, "it came from invites that can't be read right now")
        // And a snapshot handled while unreadable does not bring it back.
        rig.coordinator.applyInboxSnapshot(snapshot, viewerIdentity: rig.ownerSigner.identity)
        XCTAssertNil(rig.coordinator.integrityNotice)

        // Once readable again it is recomputed from the snapshot.
        rig.store.failLoads = false
        rig.store.invites[a.issued.invitation.payload.inviteID] = a.issued
        rig.coordinator.reloadInviteStoreForTesting()
        rig.coordinator.applyInboxSnapshot(snapshot, viewerIdentity: rig.ownerSigner.identity)
        XCTAssertEqual(rig.coordinator.integrityNotice, CompanionCoordinator.integrityNoticeText)
    }

    func testAskGoesThroughTheAppLevelPathWithoutARelay() async throws {
        let (rig, _) = try makeTrustedOwner()
        struct Call { let session: ActiveSession; let requestTime: Date; let validFor: TimeInterval; let targets: [CompanionPerson] }
        var calls: [Call] = []
        rig.coordinator.askRelayOverride = { session, requestTime, validFor, targets in
            calls.append(Call(session: session, requestTime: requestTime, validFor: validFor, targets: targets))
        }
        let end = Date().addingTimeInterval(3_600)
        await rig.coordinator.requestEarlyEnd(sessionID: UUID().uuidString, activeSetID: UUID().uuidString,
                                              start: Date().addingTimeInterval(-300), end: end, to: rig.coordinator.trustedApprovers)
        XCTAssertNil(rig.coordinator.lastError)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(call.targets.map(\.nickname), ["Ari"])
        XCTAssertEqual(call.session.endsAt, end)
        // The P3-0 invariant: a request never outlives its session.
        XCTAssertLessThanOrEqual(call.requestTime.addingTimeInterval(call.validFor), end)
        XCTAssertEqual(call.validFor, end.timeIntervalSince(call.requestTime), accuracy: 0.001)

        // A very long lock is capped at the maximum request lifetime.
        let longEnd = Date().addingTimeInterval(CompanionLimits.maxRequestLifetime * 3)
        await rig.coordinator.requestEarlyEnd(sessionID: UUID().uuidString, activeSetID: UUID().uuidString,
                                              start: Date().addingTimeInterval(-300), end: longEnd, to: rig.coordinator.trustedApprovers)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].validFor, CompanionLimits.maxRequestLifetime)
    }

    func testAskSaysWhenTheLockIsAboutToEndOrAlreadyEnded() async throws {
        let (rig, _) = try makeTrustedOwner()
        var sent = 0
        rig.coordinator.askRelayOverride = { _, _, _, _ in sent += 1 }

        await rig.coordinator.requestEarlyEnd(sessionID: "s", activeSetID: "a", start: Date().addingTimeInterval(-300),
                                              end: Date().addingTimeInterval(10), to: rig.coordinator.trustedApprovers)
        XCTAssertEqual(rig.coordinator.lastError, "This lock is about to end.")

        await rig.coordinator.requestEarlyEnd(sessionID: "s", activeSetID: "a", start: Date().addingTimeInterval(-300),
                                              end: Date().addingTimeInterval(-5), to: rig.coordinator.trustedApprovers)
        XCTAssertEqual(rig.coordinator.lastError, "That lock has already ended, so there's nothing left to ask about.")
        XCTAssertEqual(sent, 0, "nothing is sent for a lock that is over or about to be")

        let now = Date()
        XCTAssertNil(CompanionCoordinator.askBlockedMessage(end: now.addingTimeInterval(30), now: now))
        XCTAssertEqual(CompanionCoordinator.askBlockedMessage(end: now.addingTimeInterval(29.9), now: now), "This lock is about to end.")
        XCTAssertEqual(CompanionCoordinator.askBlockedMessage(end: now, now: now),
                       "That lock has already ended, so there's nothing left to ask about.")
        XCTAssertNil(CompanionCoordinator.askValidity(end: now, requestTime: now))
    }

    func testGotAnInviteLinkComesFirstOnlyBeforeAnyOwnerSetup() throws {
        let friend = try makeFriend()
        XCTAssertTrue(friend.showsAcceptInviteFirst, "fresh install")
        XCTAssertTrue(friend.setOwnerDisplayName("Sam"))
        XCTAssertFalse(friend.showsAcceptInviteFirst, "owner setup has begun")
        let rig = try makeOwnerRig()
        let join = try makeJoin(rig)
        friend.incomingInvite = .ready(IncomingInvite(invitation: join.issued.invitation, token: join.issued.token))
        XCTAssertTrue(friend.showsAcceptInviteFirst, "a link was just opened")
        friend.dismissIncomingInvite()
        XCTAssertFalse(friend.showsAcceptInviteFirst)
        // An owner with someone already joined keeps the owner layout.
        let (owner, _) = try makeTrustedOwner()
        XCTAssertFalse(owner.coordinator.showsAcceptInviteFirst)
    }

    #if os(iOS)
    func testCopyLinkPasteboardAllowsUniversalClipboardAndStillExpires() {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let options = CompanionPasteboard.options(expiresAt: expiry)
        XCTAssertNil(options[.localOnly], "localOnly would stop Universal Clipboard")
        XCTAssertEqual(options[.expirationDate] as? Date, expiry, "the copied link goes when the invite expires")
    }
    #endif
}
#endif
