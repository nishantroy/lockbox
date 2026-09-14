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

    private func operation(signer: DeviceSigner, id: String, revision: Int64, value: Int = 1) throws -> SignedOperation {
        try DurableOperationFactory.make(kind: "ack", operationID: id,
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
}
