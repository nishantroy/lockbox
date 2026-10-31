import XCTest
@testable import PhoneLockbox
#if canImport(CompanionKit)
import CompanionKit
#endif

/// R5 Slice B2c: host-testable pieces of the app-layer friend-release
/// wiring that do not require FamilyControls authorization or a reachable
/// relay — the active-set algorithm switch, the developer gate's default
/// and persistence, no-op copy mapping, and read-only session-state queries
/// on a coordinator with an empty/unavailable store. The rest (the actual
/// network round trip, `OwnerApprovalCheck`, durable prepare/apply/abandon
/// semantics) is covered by `CompanionKitTests`, `RuntimeTests
/// /FriendReleaseTests.swift`, and the parent's simulator/relay-smoke runs.
@MainActor
final class FriendReleaseWiringTests: XCTestCase {

    // MARK: - companionActiveSetID switch (R5 Slice B2c, B2b item 1)

    private func policySnapshot() -> RuntimePolicySnapshot {
        RuntimePolicySnapshot(
            mode: .blockSelected,
            selectionSummary: RuntimeSelectionSummary(applicationCount: 1, categoryCount: 0, webDomainCount: 0),
            selectionData: Data([1])
        )
    }

    private func session(id: UUID) -> RuntimeSession {
        RuntimeSession(
            id: id,
            origin: .scheduled,
            start: Date(timeIntervalSinceReferenceDate: 1_000),
            end: Date(timeIntervalSinceReferenceDate: 4_600),
            sourceRevision: 1,
            policy: policySnapshot()
        )
    }

    /// Same fixed vector as `RuntimeTests/FriendReleaseTests
    /// .testActiveSetIDFixedVectorMatchesThePortedCoordinatorAlgorithm`.
    /// `ScreenTimeCoordinator.companionActiveSetID(for:)` must still produce
    /// byte-identical output now that it delegates to
    /// `RuntimeActiveSet.id(for:)` instead of duplicating the algorithm.
    func testCompanionActiveSetIDMatchesTheSharedFixedVectorAndDelegatesToRuntimeActiveSet() {
        let first = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let second = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let sessions = [session(id: first), session(id: second)]

        XCTAssertEqual(
            ScreenTimeCoordinator.companionActiveSetID(for: sessions),
            "dae82c44b1d1590d8c3414b027ab80539197573c0e485d5a35beb5f2538502ba"
        )
        XCTAssertEqual(
            ScreenTimeCoordinator.companionActiveSetID(for: [session(id: first)]),
            "0a0970fb8e2bca03cd5c270296cc9c6367c06acf89f372b6bc71ed44ba8a8fc9"
        )
        XCTAssertEqual(
            ScreenTimeCoordinator.companionActiveSetID(for: sessions),
            RuntimeActiveSet.id(for: sessions.map(\.id))
        )
        // Order of sessions must not change the digest.
        XCTAssertEqual(
            ScreenTimeCoordinator.companionActiveSetID(for: [session(id: second), session(id: first)]),
            ScreenTimeCoordinator.companionActiveSetID(for: sessions)
        )
    }

#if canImport(CompanionKit)
    // MARK: - Developer gate default and persistence (R5 Slice B2c)

    func testFriendApprovalGateDefaultsOffAndPersistsAcrossInstancesInTheSameSuite() throws {
        let suiteName = "com.phone-lockbox.tests.friend-release-gate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults)
        XCTAssertFalse(first.friendApprovalCanEndLocksEnabled)

        first.friendApprovalCanEndLocksEnabled = true

        let second = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults)
        XCTAssertTrue(second.friendApprovalCanEndLocksEnabled, "the gate must persist in the same App Group suite")
    }

    func testFriendApprovalGateDefaultsOffWhenAppGroupIsUnavailable() {
        // `sharedDefaults: nil` with no suite resolvable is the same
        // "App Group unavailable" path every other companion feature uses;
        // the gate must still default to a safe, disabled value rather than
        // crash or silently fall back to `.standard`.
        let coordinator = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: nil)
        // When a real App Group suite happens to resolve on this host, the
        // persisted value could already be true from a prior run; only the
        // unavailable path is asserted on here.
        if !coordinator.isAvailable {
            XCTAssertFalse(coordinator.friendApprovalCanEndLocksEnabled)
        }
    }

    // MARK: - No-op copy mapping (shown immediately / after a verified `use`)

    func testPrepareNoOpMessageCoversEveryReason() {
        XCTAssertEqual(CompanionCoordinator.prepareNoOpMessage(.alreadyEnded), "This lock already ended.")
        XCTAssertEqual(CompanionCoordinator.prepareNoOpMessage(.activeSetMismatch), "This approval is for a different lock.")
        XCTAssertEqual(CompanionCoordinator.prepareNoOpMessage(.conflictingPendingIntent), "Another end-lock request is already in progress.")
        XCTAssertEqual(CompanionCoordinator.prepareNoOpMessage(.noMatchingPendingIntent), "This lock already ended.")
    }

    func testApplyNoOpMessageCoversEveryReasonAndMatchesThePlanForTheNamedCases() {
        // `.alreadyEnded` and `.activeSetMismatch` are the plan's named
        // terminal copy. `.noMatchingPendingIntent` is also genuinely
        // reachable from `RuntimeLifecycle.applyFriendRelease`
        // (Shared/RuntimeFriendRelease.swift) — for example a second,
        // concurrent replay call after the first already cleared the
        // intent — and falls back to the same calm "already ended" copy.
        // `.conflictingPendingIntent` is prepare-only and exhaustively
        // mapped here only for defense in depth.
        XCTAssertEqual(CompanionCoordinator.applyNoOpMessage(.alreadyEnded), "This lock already ended.")
        XCTAssertEqual(CompanionCoordinator.applyNoOpMessage(.activeSetMismatch), "Your locks changed; ask again.")
        XCTAssertEqual(CompanionCoordinator.applyNoOpMessage(.conflictingPendingIntent), "This lock already ended.")
        XCTAssertEqual(CompanionCoordinator.applyNoOpMessage(.noMatchingPendingIntent), "This lock already ended.")
    }

    // MARK: - P2-10: gate-off hides the "End lock now" action

    /// `CompanionCoordinator.shouldShowFriendReleaseAction` is the exact
    /// predicate `PeopleView`'s `InboxRow` uses to decide whether to show
    /// the gated row at all, kept in sync with the view by construction
    /// (review P2-10 — this replaces an earlier vacuous test that never
    /// exercised the gate's effect on anything).
    func testShouldShowFriendReleaseActionIsGatedOffByDefaultAndOnlyForAnOwnApprovedRequest() throws {
        let fixture = try makeFixture()
        var approvedOfMine = fixture.request
        approvedOfMine.status = .approved
        let mine = CompanionInboxItem(request: approvedOfMine, viewerIdentityID: fixture.ownerSigner.identity.identityID)

        XCTAssertFalse(CompanionCoordinator.shouldShowFriendReleaseAction(for: mine, gateEnabled: false))
        XCTAssertTrue(CompanionCoordinator.shouldShowFriendReleaseAction(for: mine, gateEnabled: true))

        var pendingOfMine = fixture.request
        pendingOfMine.status = .pending
        let minePending = CompanionInboxItem(request: pendingOfMine, viewerIdentityID: fixture.ownerSigner.identity.identityID)
        XCTAssertFalse(CompanionCoordinator.shouldShowFriendReleaseAction(for: minePending, gateEnabled: true),
                       "only an approved request may show the action, gate or no gate")

        let helpingWith = CompanionInboxItem(request: approvedOfMine, viewerIdentityID: fixture.approverSigner.identity.identityID)
        XCTAssertFalse(CompanionCoordinator.shouldShowFriendReleaseAction(for: helpingWith, gateEnabled: true),
                       "a request this device is only helping with must never show the owner-only action")
    }

    // MARK: - P3d: "Waiting for you" selection and status badges

    func testWaitingForYouHoldsOnlyActionableItemsAndHistoryHoldsTheRest() throws {
        let fixture = try makeFixture()
        let (companion, cleanup) = try makeCompanion()
        defer { cleanup() }
        let fake = FakeFriendReleaseLifecycle()
        let ownerID = fixture.ownerSigner.identity.identityID
        let approverID = fixture.approverSigner.identity.identityID

        // Friend side: undecided and pending is waiting; already decided or settled is history.
        let pendingForMe = CompanionInboxItem(request: fixture.request, viewerIdentityID: approverID)
        var decided = fixture.request
        decided.decisions[approverID] = .approved
        let decidedByMe = CompanionInboxItem(request: decided, viewerIdentityID: approverID)
        var declined = fixture.request
        declined.status = .declined
        let settled = CompanionInboxItem(request: declined, viewerIdentityID: approverID)
        // Owner side: own pending request is history; own approved request waits only while the gate shows End lock now.
        let ownPending = CompanionInboxItem(request: fixture.request, viewerIdentityID: ownerID)
        var approved = fixture.request
        approved.status = .approved
        let ownApproved = CompanionInboxItem(request: approved, viewerIdentityID: ownerID)

        companion.setInboxItemsForTesting([pendingForMe, decidedByMe, settled, ownPending, ownApproved])
        companion.friendApprovalCanEndLocksEnabled = false
        XCTAssertEqual(companion.waitingItems(coordinator: fake).map(\.id), [pendingForMe.id])
        XCTAssertEqual(Set(companion.historyItems(coordinator: fake).map(\.id)),
                       Set([decidedByMe.id, settled.id, ownPending.id, ownApproved.id]))

        companion.friendApprovalCanEndLocksEnabled = true
        XCTAssertEqual(Set(companion.waitingItems(coordinator: fake).map(\.id)), Set([pendingForMe.id, ownApproved.id]))
        // The fixture's items share one request ID, so match by role and status, not by ID.
        XCTAssertFalse(companion.historyItems(coordinator: fake).contains { $0.isMine && $0.status == .approved })
    }

    func testUsedAndAlreadyEndedApprovedRequestsGoToHistoryEvenWithTheGateOn() throws {
        let fixture = try makeFixture()
        let (companion, cleanup) = try makeCompanion()
        defer { cleanup() }
        let fake = FakeFriendReleaseLifecycle()
        var approved = fixture.request
        approved.status = .approved
        let item = CompanionInboxItem(request: approved, viewerIdentityID: fixture.ownerSigner.identity.identityID)
        companion.setInboxItemsForTesting([item])
        companion.friendApprovalCanEndLocksEnabled = true

        XCTAssertEqual(companion.waitingItems(coordinator: fake).count, 1, "eligible: End lock now is offered")
        fake.sessionStatesByID[approved.sessionID] = .usedToEnd
        XCTAssertTrue(companion.waitingItems(coordinator: fake).isEmpty)
        XCTAssertEqual(companion.historyItems(coordinator: fake).count, 1)
        fake.sessionStatesByID[approved.sessionID] = .alreadyEnded
        XCTAssertTrue(companion.waitingItems(coordinator: fake).isEmpty)
        XCTAssertEqual(companion.historyItems(coordinator: fake).count, 1)
    }

    func testStatusBadgesUsePlainWords() {
        XCTAssertEqual(CompanionCoordinator.statusBadgeTitle(.pending), "Waiting")
        XCTAssertEqual(CompanionCoordinator.statusBadgeTitle(.approved), "Approved")
        XCTAssertEqual(CompanionCoordinator.statusBadgeTitle(.declined), "Declined")
        XCTAssertEqual(CompanionCoordinator.statusBadgeTitle(.cancelled), "Cancelled")
        XCTAssertEqual(CompanionCoordinator.statusBadgeTitle(.expired), "Expired")
    }

    // MARK: - P1-3: selectFriendRelease (pure selection + OwnerApprovalCheck)

    private struct Fixture {
        let ownerSigner: DeviceSigner
        let approverSigner: DeviceSigner
        let pairing: Pairing
        let consent: RelationshipConsent
        let session: ActiveSession
        let request: TrustedRequest
    }

    private func makeFixture(pairingState: PairingState = .active, consentGeneration: UInt64 = 1) throws -> Fixture {
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let pairing = try Pairing(pairingID: "pairing-\(UUID().uuidString)", owner: ownerSigner.identity,
                                  approver: approverSigner.identity, epoch: 1, createdAt: Date(), state: pairingState)
        let consent = try RelationshipConsent(
            relationshipID: pairing.pairingID, pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
            owner: ownerSigner.identity, approver: approverSigner.identity,
            ownerScopes: [.approveEarlyEnd, .receiveRequests], approverScopes: [.approveEarlyEnd, .receiveRequests],
            ownerState: .active, approverState: .active, updatedAt: Date(), generation: consentGeneration
        )
        let now = Date()
        let session = try ActiveSession(owner: ownerSigner.identity, sessionID: UUID().uuidString,
                                        activeSetID: "set-1", startsAt: now, endsAt: now.addingTimeInterval(600))
        let request = try TrustedRequest(requestID: "req-\(UUID().uuidString)", owner: ownerSigner.identity, pairing: pairing,
                                         session: session, targets: [approverSigner.identity.identityID],
                                         message: nil, createdAt: now, expiresAt: now.addingTimeInterval(300))
        return Fixture(ownerSigner: ownerSigner, approverSigner: approverSigner, pairing: pairing,
                       consent: consent, session: session, request: request)
    }

    /// Builds a validly-signed `Approval`, exactly mirroring
    /// `AsyncCompanionClient.submitApproval`'s local construction (no
    /// network): the unsigned value's `signingFields()` is what gets
    /// signed. `signingSigner` lets a test sign with a key other than the
    /// claimed approver's, to build a forged/substituted approval.
    private func makeApproval(
        request: TrustedRequest,
        pairing: Pairing,
        approverIdentity: DeviceIdentity,
        signingSigner: DeviceSigner,
        decision: ApproverDecision = .approved,
        consentGeneration: UInt64 = 1,
        requestID: String? = nil
    ) throws -> Approval {
        let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let unsigned = Approval(
            approvalID: "appr-\(UUID().uuidString)", requestID: requestID ?? request.requestID, pairingID: pairing.pairingID,
            pairEpoch: pairing.epoch, sessionID: request.sessionID, activeSetID: request.activeSetID,
            approver: approverIdentity, decision: decision, issuedAt: Date(),
            consentGeneration: consentGeneration, nonce: nonce, signature: Data()
        )
        let signature = try signingSigner.sign(domain: "\(CompanionCanonical.version).approval", fields: unsigned.signingFields())
        return Approval(
            approvalID: unsigned.approvalID, requestID: unsigned.requestID, pairingID: unsigned.pairingID,
            pairEpoch: unsigned.pairEpoch, sessionID: unsigned.sessionID, activeSetID: unsigned.activeSetID,
            approver: unsigned.approver, decision: unsigned.decision, issuedAt: unsigned.issuedAt,
            consentGeneration: unsigned.consentGeneration, nonce: unsigned.nonce, signature: signature
        )
    }

    private func person(for fixture: Fixture) -> CompanionPerson {
        CompanionPerson(nickname: "Friend", localRole: .iAmOwner, pairing: fixture.pairing, consent: fixture.consent, joinVerified: true)
    }

    func testSelectFriendReleaseHappyPath() throws {
        let fixture = try makeFixture()
        let approval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                        approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let response = try InboxResponse(ownerIdentityID: fixture.ownerSigner.identity.identityID, revision: 1,
                                         requests: [fixture.request], approvals: [approval])

        let (request, selectedApproval, trustedApprover) = try CompanionCoordinator.selectFriendRelease(
            response: response, requestID: fixture.request.requestID, people: [person(for: fixture)],
            ownerIdentity: fixture.ownerSigner.identity
        )
        XCTAssertEqual(request.requestID, fixture.request.requestID)
        XCTAssertEqual(selectedApproval.approvalID, approval.approvalID)
        XCTAssertTrue(trustedApprover.isActive)
    }

    /// With no pinned approvalID, a bad approval listed first must not hide a good one.
    func testSelectFriendReleasePicksTheFirstApprovalThatVerifies() throws {
        let fixture = try makeFixture()
        let impostor = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let forged = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                      approverIdentity: fixture.approverSigner.identity, signingSigner: impostor)
        let good = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                    approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let response = try InboxResponse(ownerIdentityID: fixture.ownerSigner.identity.identityID, revision: 1,
                                         requests: [fixture.request], approvals: [forged, good])
        let (_, selected, _) = try CompanionCoordinator.selectFriendRelease(
            response: response, requestID: fixture.request.requestID, people: [person(for: fixture)],
            ownerIdentity: fixture.ownerSigner.identity)
        XCTAssertEqual(selected.approvalID, good.approvalID)
    }

    /// Pairing v3: an approval is accepted only from a person the join check verified.
    func testSelectFriendReleaseRejectsAnUnverifiedPerson() throws {
        let fixture = try makeFixture()
        let approval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                        approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let response = try InboxResponse(ownerIdentityID: fixture.ownerSigner.identity.identityID, revision: 1,
                                         requests: [fixture.request], approvals: [approval])
        var unverified = person(for: fixture)
        unverified.joinVerified = false
        XCTAssertThrowsError(try CompanionCoordinator.selectFriendRelease(
            response: response, requestID: fixture.request.requestID, people: [unverified],
            ownerIdentity: fixture.ownerSigner.identity
        )) { error in
            XCTAssertEqual(error as? CompanionError, .unknownIdentity)
        }
    }

    func testSelectFriendReleaseRejectsASubstitutedApprover() throws {
        let fixture = try makeFixture()
        let impostor = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        // Claims to be the legitimate approver (same `DeviceIdentity`,
        // including public key) but is actually signed by a different key.
        let forged = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                      approverIdentity: fixture.approverSigner.identity, signingSigner: impostor)
        let response = try InboxResponse(ownerIdentityID: fixture.ownerSigner.identity.identityID, revision: 1,
                                         requests: [fixture.request], approvals: [forged])

        XCTAssertThrowsError(try CompanionCoordinator.selectFriendRelease(
            response: response, requestID: fixture.request.requestID, people: [person(for: fixture)],
            ownerIdentity: fixture.ownerSigner.identity
        )) { error in
            XCTAssertEqual(error as? CompanionError, .invalidSignature)
        }
    }

    func testSelectFriendReleaseRejectsABindingWhosePairingIDIsNotInPeople() throws {
        let fixture = try makeFixture()
        let approval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                        approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let response = try InboxResponse(ownerIdentityID: fixture.ownerSigner.identity.identityID, revision: 1,
                                         requests: [fixture.request], approvals: [approval])

        // `people` is empty: this device has no cached pairing/consent for
        // the approver named in the request's binding.
        XCTAssertThrowsError(try CompanionCoordinator.selectFriendRelease(
            response: response, requestID: fixture.request.requestID, people: [], ownerIdentity: fixture.ownerSigner.identity
        )) { error in
            XCTAssertEqual(error as? CompanionError, .unknownIdentity)
        }
    }

    func testSelectFriendReleaseRejectsARevokedPairing() throws {
        // The request/approval must be built while the pairing is still
        // `.active` (`RequestTargetBinding.init(pairing:)` itself requires
        // that); the pairing is revoked only in the locally cached
        // `CompanionPerson` passed to `selectFriendRelease`, exactly as a
        // real revoke-after-request would look on this device.
        let fixture = try makeFixture()
        let approval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                        approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let response = try InboxResponse(ownerIdentityID: fixture.ownerSigner.identity.identityID, revision: 1,
                                         requests: [fixture.request], approvals: [approval])
        var revokedPerson = person(for: fixture)
        revokedPerson.pairing.state = .revoked

        XCTAssertThrowsError(try CompanionCoordinator.selectFriendRelease(
            response: response, requestID: fixture.request.requestID, people: [revokedPerson],
            ownerIdentity: fixture.ownerSigner.identity
        )) { error in
            XCTAssertEqual(error as? CompanionError, .revokedPairing)
        }
    }

    func testSelectFriendReleaseRejectsAnApprovalForADifferentRequest() throws {
        let fixture = try makeFixture()
        let otherFixture = try makeFixture()
        // An approval that genuinely targets a *different* request is
        // present in the response, but none targets `fixture.request`.
        let otherApproval = try makeApproval(request: otherFixture.request, pairing: otherFixture.pairing,
                                             approverIdentity: otherFixture.approverSigner.identity,
                                             signingSigner: otherFixture.approverSigner)
        let response = try InboxResponse(ownerIdentityID: fixture.ownerSigner.identity.identityID, revision: 1,
                                         requests: [fixture.request, otherFixture.request], approvals: [otherApproval])

        XCTAssertThrowsError(try CompanionCoordinator.selectFriendRelease(
            response: response, requestID: fixture.request.requestID, people: [person(for: fixture)],
            ownerIdentity: fixture.ownerSigner.identity
        )) { error in
            XCTAssertEqual(error as? CompanionError, .notFound)
        }
    }

    func testSelectFriendReleaseRejectsAMissingApproval() throws {
        let fixture = try makeFixture()
        let response = try InboxResponse(ownerIdentityID: fixture.ownerSigner.identity.identityID, revision: 1,
                                         requests: [fixture.request], approvals: nil)

        XCTAssertThrowsError(try CompanionCoordinator.selectFriendRelease(
            response: response, requestID: fixture.request.requestID, people: [person(for: fixture)],
            ownerIdentity: fixture.ownerSigner.identity
        )) { error in
            XCTAssertEqual(error as? CompanionError, .notFound)
        }
    }

    /// R2-5: a given `approvalID` must pin selection to that exact approval,
    /// never merely the first one found for the request — proven here by
    /// putting the pinned approval *second* in the array.
    func testSelectFriendReleasePinsToTheGivenApprovalIDEvenWhenItSortsSecond() throws {
        let fixture = try makeFixture()
        let firstApproval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                             approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let secondApproval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                              approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        XCTAssertNotEqual(firstApproval.approvalID, secondApproval.approvalID)
        let response = try InboxResponse(ownerIdentityID: fixture.ownerSigner.identity.identityID, revision: 1,
                                         requests: [fixture.request], approvals: [firstApproval, secondApproval])

        let (_, selected, _) = try CompanionCoordinator.selectFriendRelease(
            response: response, requestID: fixture.request.requestID, approvalID: secondApproval.approvalID,
            people: [person(for: fixture)], ownerIdentity: fixture.ownerSigner.identity
        )

        XCTAssertEqual(selected.approvalID, secondApproval.approvalID)
    }

    func testSelectFriendReleaseRejectsAMissingPinnedApprovalIDEvenWhenAnotherApprovalExistsForTheRequest() throws {
        let fixture = try makeFixture()
        let approval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                        approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let response = try InboxResponse(ownerIdentityID: fixture.ownerSigner.identity.identityID, revision: 1,
                                         requests: [fixture.request], approvals: [approval])

        XCTAssertThrowsError(try CompanionCoordinator.selectFriendRelease(
            response: response, requestID: fixture.request.requestID, approvalID: "does-not-exist",
            people: [person(for: fixture)], ownerIdentity: fixture.ownerSigner.identity
        )) { error in
            XCTAssertEqual(error as? CompanionError, .notFound)
        }
    }

    // MARK: - P1-3: finishFriendRelease branching, against a fake ScreenTimeCoordinator seam

    /// A test double for `FriendReleaseLifecycle` (R5 Slice B2c review,
    /// P1-3) so `finishFriendRelease`'s branching can be exercised without
    /// FamilyControls/DeviceActivity or a real App Group store.
    @MainActor
    private final class FakeFriendReleaseLifecycle: FriendReleaseLifecycle {
        var pendingFriendReleaseIntent: RuntimeFriendReleaseIntent?
        var sessionStatesByID: [String: ScreenTimeCoordinator.FriendReleaseSessionState] = [:]
        var useIDsBySessionID: [String: String] = [:]
        var applyResult: Result<RuntimeFriendRelease.ApplyOutcome, Error> = .success(.noOp(.noMatchingPendingIntent))
        var abandonResult: Result<Bool, Error> = .success(true)
        private(set) var prepareCallCount = 0
        private(set) var applyCallCount = 0
        private(set) var abandonCallCount = 0

        func prepareFriendRelease(sessionID: UUID, activeSetID: String, requestID: String, approvalID: String,
                                  useID: String, approverIdentityID: String) throws -> RuntimeFriendRelease.PrepareOutcome {
            prepareCallCount += 1
            pendingFriendReleaseIntent = RuntimeFriendReleaseIntent(sessionID: sessionID, activeSetID: activeSetID,
                                                                    requestID: requestID, approvalID: approvalID,
                                                                    useID: useID, approverIdentityID: approverIdentityID,
                                                                    createdAt: Date())
            return .recorded
        }

        func applyFriendRelease(useID: String) throws -> RuntimeFriendRelease.ApplyOutcome {
            applyCallCount += 1
            pendingFriendReleaseIntent = nil
            return try applyResult.get()
        }

        @discardableResult
        func abandonFriendRelease(useID: String) throws -> Bool {
            abandonCallCount += 1
            pendingFriendReleaseIntent = nil
            return try abandonResult.get()
        }

        func friendReleaseSessionState(sessionID: String) -> ScreenTimeCoordinator.FriendReleaseSessionState {
            sessionStatesByID[sessionID] ?? .eligible
        }

        func friendReleaseUseID(forSessionID sessionID: String) -> String? {
            useIDsBySessionID[sessionID]
        }
    }

    private func makeCompanion() throws -> (CompanionCoordinator, () -> Void) {
        let suiteName = "com.phone-lockbox.tests.friend-release-finish.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let companion = CompanionCoordinator(keyStore: InMemoryDeviceKeyStore(), sharedDefaults: defaults)
        return (companion, { defaults.removePersistentDomain(forName: suiteName) })
    }

    func testFinishFriendReleaseKeepsTheIntentOnARetryableUseFailure() async throws {
        let fixture = try makeFixture()
        let approval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                        approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let (companion, cleanup) = try makeCompanion()
        defer { cleanup() }
        let fake = FakeFriendReleaseLifecycle()
        fake.pendingFriendReleaseIntent = RuntimeFriendReleaseIntent(
            sessionID: UUID(uuidString: fixture.request.sessionID) ?? UUID(), activeSetID: fixture.request.activeSetID,
            requestID: fixture.request.requestID, approvalID: approval.approvalID, useID: "use-1",
            approverIdentityID: fixture.approverSigner.identity.identityID, createdAt: Date()
        )
        companion.useApprovalOverride = { _, _, _ in throw CompanionTransportError.unavailable }

        await companion.finishFriendRelease(request: fixture.request, approval: approval, useID: "use-1", coordinator: fake)

        XCTAssertEqual(fake.applyCallCount, 0)
        XCTAssertEqual(fake.abandonCallCount, 0)
        XCTAssertNotNil(fake.pendingFriendReleaseIntent, "retryable must keep the intent")
        XCTAssertEqual(companion.lastError, "Couldn't connect. Pull down to finish.")
    }

    func testFinishFriendReleaseAbandonsOnADefinitiveUseFailure() async throws {
        let fixture = try makeFixture()
        let approval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                        approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let (companion, cleanup) = try makeCompanion()
        defer { cleanup() }
        let fake = FakeFriendReleaseLifecycle()
        fake.pendingFriendReleaseIntent = RuntimeFriendReleaseIntent(
            sessionID: UUID(), activeSetID: "set", requestID: fixture.request.requestID, approvalID: approval.approvalID,
            useID: "use-1", approverIdentityID: fixture.approverSigner.identity.identityID, createdAt: Date()
        )
        companion.useApprovalOverride = { _, _, _ in throw CompanionError.replay }

        await companion.finishFriendRelease(request: fixture.request, approval: approval, useID: "use-1", coordinator: fake)

        XCTAssertEqual(fake.applyCallCount, 0)
        XCTAssertEqual(fake.abandonCallCount, 1)
        XCTAssertNil(fake.pendingFriendReleaseIntent, "definitive must abandon and clear the intent")
        XCTAssertEqual(companion.lastError, "This approval was already used.")
    }

    func testFinishFriendReleaseKeepsTheIntentAndNeverAbandonsOnAnIntegrityFatalFailure() async throws {
        let fixture = try makeFixture()
        let approval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                        approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let (companion, cleanup) = try makeCompanion()
        defer { cleanup() }
        let fake = FakeFriendReleaseLifecycle()
        fake.pendingFriendReleaseIntent = RuntimeFriendReleaseIntent(
            sessionID: UUID(), activeSetID: "set", requestID: fixture.request.requestID, approvalID: approval.approvalID,
            useID: "use-1", approverIdentityID: fixture.approverSigner.identity.identityID, createdAt: Date()
        )
        companion.useApprovalOverride = { _, _, _ in throw CompanionError.responseVerificationFailed("mismatch") }

        await companion.finishFriendRelease(request: fixture.request, approval: approval, useID: "use-1", coordinator: fake)

        XCTAssertEqual(fake.applyCallCount, 0)
        XCTAssertEqual(fake.abandonCallCount, 0, "integrityFatal must never abandon")
        XCTAssertNotNil(fake.pendingFriendReleaseIntent, "integrityFatal must keep the intent")
        XCTAssertEqual(companion.lastError, "The server's response failed an integrity check. Nothing was changed here; this needs attention before trying again.")
    }

    func testFinishFriendReleaseApplyNoOpIsTerminalAndNotRetried() async throws {
        let fixture = try makeFixture()
        let approval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                        approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let (companion, cleanup) = try makeCompanion()
        defer { cleanup() }
        let fake = FakeFriendReleaseLifecycle()
        fake.applyResult = .success(.noOp(.activeSetMismatch))
        companion.useApprovalOverride = { approval, request, useID in
            ApprovalVerification(approval: approval, verifiedAt: Date(), useID: useID)
        }

        await companion.finishFriendRelease(request: fixture.request, approval: approval, useID: "use-1", coordinator: fake)

        XCTAssertEqual(fake.applyCallCount, 1)
        XCTAssertEqual(companion.lastError, "Your locks changed; ask again.")
    }

    /// Review P1-1 (second half), tightened by R2-1: a verified `use`
    /// followed by `.noMatchingPendingIntent` is reported as success, not
    /// "already ended", only once the durable released marker confirms
    /// *this exact `useID`* actually completed the release — not merely
    /// that *some* friend approval released the session.
    func testFinishFriendReleaseTreatsANoMatchingPendingIntentAsSuccessWhenTheMarkerConfirmsTheExactUseID() async throws {
        let fixture = try makeFixture()
        let approval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                        approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let (companion, cleanup) = try makeCompanion()
        defer { cleanup() }
        let fake = FakeFriendReleaseLifecycle()
        fake.applyResult = .success(.noOp(.noMatchingPendingIntent))
        fake.sessionStatesByID[fixture.request.sessionID] = .usedToEnd
        fake.useIDsBySessionID[fixture.request.sessionID] = "use-1"
        companion.useApprovalOverride = { approval, request, useID in
            ApprovalVerification(approval: approval, verifiedAt: Date(), useID: useID)
        }

        await companion.finishFriendRelease(request: fixture.request, approval: approval, useID: "use-1", coordinator: fake)

        XCTAssertNil(companion.lastError, "the marker confirms this exact use already succeeded")
    }

    func testFinishFriendReleaseNoMatchingPendingIntentWithoutAMarkerIsStillAlreadyEnded() async throws {
        let fixture = try makeFixture()
        let approval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                        approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let (companion, cleanup) = try makeCompanion()
        defer { cleanup() }
        let fake = FakeFriendReleaseLifecycle()
        fake.applyResult = .success(.noOp(.noMatchingPendingIntent))
        // No marker recorded for this session: unrelated/unconfirmed.
        companion.useApprovalOverride = { approval, request, useID in
            ApprovalVerification(approval: approval, verifiedAt: Date(), useID: useID)
        }

        await companion.finishFriendRelease(request: fixture.request, approval: approval, useID: "use-1", coordinator: fake)

        XCTAssertEqual(companion.lastError, "This lock already ended.")
    }

    /// R2-1: `.usedToEnd` alone is not enough — a *different* request's
    /// approval could have released the same session. The marker's own
    /// `useID` must match the one this `finishFriendRelease` call just
    /// submitted.
    func testFinishFriendReleaseNoMatchingPendingIntentWithUsedToEndButADifferentUseIDIsStillAlreadyEnded() async throws {
        let fixture = try makeFixture()
        let approval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                        approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let (companion, cleanup) = try makeCompanion()
        defer { cleanup() }
        let fake = FakeFriendReleaseLifecycle()
        fake.applyResult = .success(.noOp(.noMatchingPendingIntent))
        fake.sessionStatesByID[fixture.request.sessionID] = .usedToEnd
        fake.useIDsBySessionID[fixture.request.sessionID] = "use-from-a-different-request"
        companion.useApprovalOverride = { approval, request, useID in
            ApprovalVerification(approval: approval, verifiedAt: Date(), useID: useID)
        }

        await companion.finishFriendRelease(request: fixture.request, approval: approval, useID: "use-1", coordinator: fake)

        XCTAssertEqual(companion.lastError, "This lock already ended.")
    }

    // MARK: - P1-1: single-flight

    /// A one-shot async gate so the single-flight test is deterministic
    /// rather than sleep-based.
    private actor Gate {
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Deterministic (no fixed-yield assumption): the first flight is held
    /// open on `gate` until the second call is *known* to have joined it —
    /// signaled by `friendReleaseFlightJoinCount`, which
    /// `runSingleFlightFriendRelease` increments synchronously, before any
    /// suspension point, the instant a caller takes the join branch — only
    /// then is the gate released (R5 Slice B2c review, determinism fix).
    func testSingleFlightJoinsAnInFlightCallInsteadOfSubmittingASecondUse() async throws {
        let fixture = try makeFixture()
        let approval = try makeApproval(request: fixture.request, pairing: fixture.pairing,
                                        approverIdentity: fixture.approverSigner.identity, signingSigner: fixture.approverSigner)
        let (companion, cleanup) = try makeCompanion()
        defer { cleanup() }
        let fake = FakeFriendReleaseLifecycle()
        let gate = Gate()
        var useCallCount = 0
        companion.useApprovalOverride = { approval, request, useID in
            useCallCount += 1
            await gate.wait()
            return ApprovalVerification(approval: approval, verifiedAt: Date(), useID: useID)
        }

        async let first: Void = companion.runSingleFlightFriendRelease {
            await companion.finishFriendRelease(request: fixture.request, approval: approval, useID: "use-1", coordinator: fake)
        }
        // Wait for the first flight to actually register itself as
        // in-flight before starting the second (deterministic: this flag is
        // set synchronously, before any suspension point, inside
        // `runSingleFlightFriendRelease`).
        while !companion.hasFriendReleaseFlightInFlight {
            await Task.yield()
        }
        async let second: Void = companion.runSingleFlightFriendRelease {
            await companion.finishFriendRelease(request: fixture.request, approval: approval, useID: "use-2", coordinator: fake)
        }
        // Wait until the second call has *actually* taken the join branch —
        // never assume any fixed number of yields is "enough" — before
        // releasing the first.
        while companion.friendReleaseFlightJoinCount == 0 {
            await Task.yield()
        }
        await gate.open()
        _ = await (first, second)

        XCTAssertEqual(useCallCount, 1, "the second call must join the in-flight work, not submit its own use")
        XCTAssertEqual(companion.friendReleaseFlightJoinCount, 1)
    }

    // MARK: - R2-3: endLockNow reports a conflict rather than joining an unrelated flight

    func testEndLockNowReportsAConflictWhenAFlightForADifferentRequestIsInProgress() async throws {
        let fixture = try makeFixture()
        var approved = fixture.request
        approved.status = .approved
        let item = CompanionInboxItem(request: approved, viewerIdentityID: fixture.ownerSigner.identity.identityID)
        let (companion, cleanup) = try makeCompanion()
        defer { cleanup() }
        companion.friendApprovalCanEndLocksEnabled = true
        let gate = Gate()

        // An unrelated flight for a different request, held open.
        async let other: Void = companion.runSingleFlightFriendRelease(requestID: "some-other-request-id") {
            await gate.wait()
        }
        while !companion.hasFriendReleaseFlightInFlight {
            await Task.yield()
        }

        // `endLockNow` must detect the mismatch and return without ever
        // reaching the network (no `useApprovalOverride` is even set here —
        // if it tried to fetch the inbox for real, this test would hang or
        // fail with a transport error instead of asserting the message).
        await companion.endLockNow(item, coordinator: FakeFriendReleaseLifecycle())

        XCTAssertEqual(companion.lastError, "Another end-lock request is already in progress.")

        await gate.open()
        _ = await other
    }
#endif
}
