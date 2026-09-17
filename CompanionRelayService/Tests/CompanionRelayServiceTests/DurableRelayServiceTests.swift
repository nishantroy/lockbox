import XCTest
@testable import CompanionRelayService
import CompanionKit

final class DurableRelayServiceTests: XCTestCase {
    private struct Payload: Codable, Sendable {
        let value: Int
    }

    private func owner() throws -> DeviceSigner {
        try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
    }

    private func operation(signer: DeviceSigner, id: String, revision: Int64,
                           value: Int = 1, kind: String = "ack") throws -> SignedOperation {
        try DurableOperationFactory.make(kind: kind, operationID: id,
                                         expectedRevision: revision,
                                         payload: Payload(value: value), signer: signer)
    }

    func testDuplicateRetryReturnsCommittedResponseWithoutRunningMutationAgain() throws {
        let signer = try owner()
        let store = InMemoryDurableRelayStore()
        let service = DurableRelayService(store: store)
        let op = try operation(signer: signer, id: "duplicate", revision: 0)
        var calls = 0

        let first = try service.submit(op, owner: signer.identity) { _, _ in
            calls += 1
            return .acknowledgement
        }
        let retry = try service.submit(op, owner: signer.identity) { _, _ in
            calls += 1
            return .acknowledgement
        }

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(first.receipt.revision, 1)
        XCTAssertEqual(retry.receipt.revision, first.receipt.revision)
        XCTAssertEqual(try store.read().owners[signer.identity.identityID]?.revision, 1)
    }

    func testSameOperationIDWithDifferentRequestDigestIsRejected() throws {
        let signer = try owner()
        let store = InMemoryDurableRelayStore()
        let service = DurableRelayService(store: store)
        _ = try service.submit(try operation(signer: signer, id: "reuse", revision: 0, value: 1),
                               owner: signer.identity) { _, _ in .acknowledgement }
        let conflicting = try operation(signer: signer, id: "reuse", revision: 1, value: 2)

        XCTAssertThrowsError(try service.submit(conflicting, owner: signer.identity) { _, _ in
            XCTFail("a conflicting retry must not invoke the mutation")
            return .acknowledgement
        }) { error in
            XCTAssertEqual(error as? DurableRelayError, .idempotencyConflict)
        }
        XCTAssertEqual(try store.read().owners[signer.identity.identityID]?.revision, 1)
    }

    func testExpectedRevisionIsOwnerScopedAndStaleWritersAreRejected() throws {
        let signer = try owner()
        let store = InMemoryDurableRelayStore()
        let service = DurableRelayService(store: store)
        _ = try service.submit(try operation(signer: signer, id: "first", revision: 0),
                               owner: signer.identity) { _, _ in .acknowledgement }
        let stale = try operation(signer: signer, id: "stale", revision: 0)

        XCTAssertThrowsError(try service.submit(stale, owner: signer.identity) { _, _ in
            XCTFail("stale mutation must not run")
            return .acknowledgement
        }) { error in
            XCTAssertEqual(error as? DurableRelayError, .staleRevision(expected: 0, actual: 1))
        }
        XCTAssertEqual(try store.read().owners[signer.identity.identityID]?.revision, 1)
    }

    func testCrashAfterCommitCanBeRetriedFromRestartedStore() throws {
        let signer = try owner()
        let store = InMemoryDurableRelayStore()
        let service = DurableRelayService(store: store)
        let op = try operation(signer: signer, id: "lost-ack", revision: 0)
        store.injectFailure(.afterCommitBeforeAcknowledgement)

        XCTAssertThrowsError(try service.submit(op, owner: signer.identity) { _, _ in
            return .acknowledgement
        }) { error in
            XCTAssertEqual(error as? DurableStoreError, .crashAfterCommitBeforeAcknowledgement)
        }

        let restarted = try store.restarted()
        let retry = try DurableRelayService(store: restarted).submit(op, owner: signer.identity) { _, _ in
            XCTFail("committed operation must be replayed, not applied again")
            return .acknowledgement
        }
        XCTAssertEqual(retry.receipt.revision, 1)
        XCTAssertEqual(try restarted.read().owners[signer.identity.identityID]?.operations.count, 1)
    }

    func testSameOperationIDAndRevisionAreIsolatedPerOwner() throws {
        let first = try owner()
        let second = try owner()
        let store = InMemoryDurableRelayStore()
        let service = DurableRelayService(store: store)
        let firstOperation = try operation(signer: first, id: "shared-id", revision: 0)
        let secondOperation = try operation(signer: second, id: "shared-id", revision: 0)

        _ = try service.submit(firstOperation, owner: first.identity) { _, _ in .acknowledgement }
        let secondResult = try service.submit(secondOperation, owner: second.identity) { _, _ in .acknowledgement }

        XCTAssertEqual(secondResult.receipt.ownerID, second.identity.identityID)
        let database = try store.read()
        XCTAssertEqual(database.owners[first.identity.identityID]?.revision, 1)
        XCTAssertEqual(database.owners[second.identity.identityID]?.revision, 1)
        XCTAssertEqual(database.owners[first.identity.identityID]?.operations.count, 1)
        XCTAssertEqual(database.owners[second.identity.identityID]?.operations.count, 1)
    }

    func testOwnerOnlyPolicyRejectsHostileCrossOwnerSubmission() throws {
        let ownerA = try owner()
        let ownerB = try owner()
        let store = InMemoryDurableRelayStore()
        let service = DurableRelayService(store: store, authorization: .ownerOnly())
        let hostile = try operation(signer: ownerA, id: "cross-owner", revision: 0)

        XCTAssertThrowsError(try service.submit(hostile, owner: ownerB.identity) { _, _ in
            XCTFail("authorization must run before mutation")
            return .acknowledgement
        }) { error in
            XCTAssertEqual(error as? DurableRelayError, .unauthorized)
        }
        XCTAssertTrue(try store.read().owners.isEmpty)
    }

    func testApproverPolicyRequiresOwnerScopedPairingAuthorization() throws {
        let targetOwner = try owner()
        let approver = try DeviceSigner.create(role: .trustedApprover,
                                               keyStore: InMemoryDeviceKeyStore())
        let policy = DurableAuthorizationPolicy(ownerOnlyKinds: [], approverKinds: ["approve"]) {
            operation, owner, ledger in
            // This callback is the explicit integration seam: a production
            // caller must validate an active pairing in this owner's ledger.
            operation.signer == approver.identity && owner == targetOwner.identity &&
                ledger.owner == targetOwner.identity && !ledger.pairings.isEmpty
        }
        let service = DurableRelayService(store: InMemoryDurableRelayStore(), authorization: policy)
        let operation = try operation(signer: approver, id: "approver", revision: 0,
                                      kind: "approve")

        XCTAssertThrowsError(try service.submit(operation, owner: targetOwner.identity) { _, _ in
            XCTFail("an unpaired approver must not mutate the owner ledger")
            return .acknowledgement
        }) { error in
            XCTAssertEqual(error as? DurableRelayError, .unauthorized)
        }
    }

    func testMutationCannotChangeServiceOwnedRevision() throws {
        let signer = try owner()
        let store = InMemoryDurableRelayStore()
        let service = DurableRelayService(store: store)
        let op = try operation(signer: signer, id: "revision-attack", revision: 0)

        XCTAssertThrowsError(try service.submit(op, owner: signer.identity) { ledger, _ in
            ledger.revision = Int64.max
            return .acknowledgement
        }) { error in
            XCTAssertEqual(error as? DurableRelayError,
                           .mutationChangedRevision(expected: 0, actual: Int64.max))
        }
        XCTAssertTrue(try store.read().owners.isEmpty)
    }

    func testInvalidMutationLedgerIsRejectedBeforeCommit() throws {
        let signer = try owner()
        let store = InMemoryDurableRelayStore()
        let service = DurableRelayService(store: store)
        let op = try operation(signer: signer, id: "invalid-ledger", revision: 0)

        XCTAssertThrowsError(try service.submit(op, owner: signer.identity) { ledger, _ in
            ledger.audit.append(DurableAuditEvent(revision: 0, operationID: "bad",
                                                   kind: "ack", signerID: signer.identity.identityID,
                                                   occurredAt: Date(), outcome: "bad"))
            return .acknowledgement
        }) { error in
            XCTAssertEqual(error as? DurableStoreError, .invalidSnapshot)
        }
        XCTAssertTrue(try store.read().owners.isEmpty)
    }

    func testScopedOwnerRequestRequiresBilateralConsentInsideTransaction() throws {
        let ownerSigner = try owner()
        let approver = try DeviceSigner.create(role: .trustedApprover,
                                               keyStore: InMemoryDeviceKeyStore())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pairing = try Pairing(pairingID: "durable-scope-pairing", owner: ownerSigner.identity,
                                  approver: approver.identity, epoch: 1, createdAt: now, state: .active)
        let session = try ActiveSession(owner: ownerSigner.identity, sessionID: "durable-scope-session",
                                        activeSetID: "durable-scope-set", startsAt: now.addingTimeInterval(-1),
                                        endsAt: now.addingTimeInterval(600))
        let request = try TrustedRequest(requestID: "durable-scope-request", owner: ownerSigner.identity,
                                         pairing: pairing, session: session,
                                         targets: [approver.identity.identityID], message: nil,
                                         createdAt: now, expiresAt: now.addingTimeInterval(300))
        let consent = try RelationshipConsent(relationshipID: pairing.pairingID,
                                               pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
                                               owner: ownerSigner.identity, approver: approver.identity,
                                               ownerScopes: [.approveEarlyEnd, .receiveRequests],
                                               approverScopes: [.approveEarlyEnd, .receiveRequests],
                                               ownerState: .active, approverState: .active, updatedAt: now)
        let ledger = DurableOwnerLedger(owner: ownerSigner.identity,
                                        pairings: [pairing.pairingID: DurablePairingRecord(pairing: pairing)],
                                        relationshipConsents: [pairing.pairingID: consent])
        let store = try InMemoryDurableRelayStore(database: DurableRelayDatabase(
            owners: [ownerSigner.identity.identityID: ledger]))
        let policy = DurableAuthorizationPolicy.ownerAndActivePairing(
            ownerOnlyKinds: ["request"], approverKinds: [],
            requiredScopes: ["request": .approveEarlyEnd])
        let service = DurableRelayService(store: store, authorization: policy)
        let operation = try DurableOperationFactory.make(kind: "request", operationID: "durable-scoped-request",
                                                         expectedRevision: 0, payload: request, signer: ownerSigner)
        XCTAssertNoThrow(try service.submit(operation, owner: ownerSigner.identity) { _, _ in RelayResult.request(request) })

        let staleLedger = DurableOwnerLedger(owner: ownerSigner.identity,
                                              pairings: [pairing.pairingID: DurablePairingRecord(pairing: pairing)])
        let staleStore = try InMemoryDurableRelayStore(database: DurableRelayDatabase(
            owners: [ownerSigner.identity.identityID: staleLedger]))
        let staleService = DurableRelayService(store: staleStore, authorization: policy)
        XCTAssertThrowsError(try staleService.submit(operation, owner: ownerSigner.identity) { _, _ in
            XCTFail("stale consent must be rejected before mutation")
            return RelayResult.request(request)
        }) { XCTAssertEqual($0 as? DurableRelayError, .unauthorized) }
    }

    func testR6ScopedDeliveryCannotBeAuthorizedByR5Policy() throws {
        let signer = try owner()
        let policy = DurableAuthorizationPolicy.ownerOnly(kinds: ["notice"],
                                                           requiredScopes: ["notice": .earlyEndNotices])
        let service = DurableRelayService(store: InMemoryDurableRelayStore(), authorization: policy)
        let operation = try operation(signer: signer, id: "r6-notice", revision: 0, kind: "notice")
        XCTAssertThrowsError(try service.submit(operation, owner: signer.identity) { _, _ in
            XCTFail("R6 notice capability must not authorize a mutation")
            return .acknowledgement
        }) { XCTAssertEqual($0 as? DurableRelayError, .unauthorized) }
    }

    func testInitialDatabaseRejectsOperationDictionaryKeyMismatch() throws {
        let signer = try owner()
        let response = Data("{}".utf8)
        let record = DurableOperationRecord(operationID: "actual", ownerID: signer.identity.identityID,
                                            signer: signer.identity, kind: "ack",
                                            bodyDigest: Data(repeating: 1, count: 32),
                                            responseKind: "acknowledgement", responseBody: response,
                                            responseDigest: CompanionCanonical.digest(response),
                                            committedRevision: 1, committedAt: Date())
        let ledger = DurableOwnerLedger(owner: signer.identity, revision: 1,
                                        operations: ["wrong-key": record])
        let database = DurableRelayDatabase(owners: [signer.identity.identityID: ledger])

        XCTAssertThrowsError(try InMemoryDurableRelayStore(database: database)) { error in
            XCTAssertEqual(error as? DurableStoreError, .invalidSnapshot)
        }
    }
}
