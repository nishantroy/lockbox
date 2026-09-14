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
