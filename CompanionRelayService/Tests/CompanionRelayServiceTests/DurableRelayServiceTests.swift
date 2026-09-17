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
        if kind == "ack" {
            return try DurableOperationFactory.makeAck(operationID: id,
                                                       expectedRevision: revision,
                                                       signer: signer)
        }
        return try DurableOperationFactory.make(kind: kind, operationID: id,
                                                expectedRevision: revision,
                                                payload: Payload(value: value), signer: signer)
    }

    func testDuplicateRetryReturnsCommittedResponseWithoutRunningMutationAgain() throws {
        let signer = try owner()
        let store = InMemoryDurableRelayStore()
        let service = DurableRelayService(store: store)
        let op = try operation(signer: signer, id: "duplicate", revision: 0)
        let first = try service.submit(op, owner: signer.identity)
        let retry = try service.submit(op, owner: signer.identity)

        XCTAssertEqual(first.result, .acknowledgement)
        XCTAssertEqual(retry.result, .acknowledgement)
        XCTAssertEqual(first.receipt.revision, 1)
        XCTAssertEqual(retry.receipt.revision, first.receipt.revision)
        XCTAssertEqual(try store.read().owners[signer.identity.identityID]?.revision, 1)
    }

    func testSameOperationIDWithDifferentRequestDigestIsRejected() throws {
        let signer = try owner()
        let store = InMemoryDurableRelayStore()
        let service = DurableRelayService(store: store)
        _ = try service.submit(try operation(signer: signer, id: "reuse", revision: 0, value: 1),
                               owner: signer.identity)
        let conflicting = try operation(signer: signer, id: "reuse", revision: 1, value: 2)

        XCTAssertThrowsError(try service.submit(conflicting, owner: signer.identity)) { error in
            XCTAssertEqual(error as? DurableRelayError, .idempotencyConflict)
        }
        XCTAssertEqual(try store.read().owners[signer.identity.identityID]?.revision, 1)
    }

    func testExpectedRevisionIsOwnerScopedAndStaleWritersAreRejected() throws {
        let signer = try owner()
        let store = InMemoryDurableRelayStore()
        let service = DurableRelayService(store: store)
        _ = try service.submit(try operation(signer: signer, id: "first", revision: 0),
                               owner: signer.identity)
        let stale = try operation(signer: signer, id: "stale", revision: 0)

        XCTAssertThrowsError(try service.submit(stale, owner: signer.identity)) { error in
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

        XCTAssertThrowsError(try service.submit(op, owner: signer.identity)) { error in
            XCTAssertEqual(error as? DurableStoreError, .crashAfterCommitBeforeAcknowledgement)
        }

        let restarted = try store.restarted()
        let retry = try DurableRelayService(store: restarted).submit(op, owner: signer.identity)
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

        _ = try service.submit(firstOperation, owner: first.identity)
        let secondResult = try service.submit(secondOperation, owner: second.identity)

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

        XCTAssertThrowsError(try service.submit(hostile, owner: ownerB.identity)) { error in
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

        XCTAssertThrowsError(try service.submit(operation, owner: targetOwner.identity)) { error in
            XCTAssertEqual(error as? DurableRelayError, .unsupportedOperation("approve"))
        }
    }

    func testAckIsFixedPayloadFreeAndCannotReachAStateMutation() throws {
        let signer = try owner()
        let store = InMemoryDurableRelayStore()
        let service = DurableRelayService(store: store)
        let valid = try operation(signer: signer, id: "fixed-ack", revision: 0)
        let accepted = try service.submit(valid, owner: signer.identity)
        XCTAssertEqual(accepted.result, .acknowledgement)
        XCTAssertEqual(try store.read().owners[signer.identity.identityID]?.sessions.count, 0)

        let forged = try operation(signer: signer, id: "forged-ack", revision: 1, value: 9)
        // The helper's ack path always uses {}. A typed payload must be made
        // through the generic factory and is rejected by the reducer.
        let typed = try DurableOperationFactory.make(kind: "ack", operationID: "typed-ack",
                                                     expectedRevision: 1,
                                                     payload: Payload(value: 9), signer: signer)
        _ = forged
        XCTAssertThrowsError(try service.submit(typed, owner: signer.identity)) {
            XCTAssertEqual($0 as? CompanionError, .malformed("ack must have an empty payload"))
        }
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
                                        sessions: [session.sessionID: DurableSessionRecord(session: session, publishedAt: now)],
                                        currentSessionID: session.sessionID,
                                        relationshipConsents: [pairing.pairingID: consent])
        let store = try InMemoryDurableRelayStore(database: DurableRelayDatabase(
            owners: [ownerSigner.identity.identityID: ledger]))
        let policy = DurableAuthorizationPolicy.ownerAndActivePairing(
            ownerOnlyKinds: ["request"], approverKinds: [],
            requiredScopes: ["request": .approveEarlyEnd])
        let service = DurableRelayService(store: store, authorization: policy, now: { now })
        let operation = try DurableOperationFactory.make(kind: "request", operationID: "durable-scoped-request",
                                                         expectedRevision: 0, payload: request, signer: ownerSigner)
        XCTAssertNoThrow(try service.submit(operation, owner: ownerSigner.identity))

        let staleLedger = DurableOwnerLedger(owner: ownerSigner.identity,
                                              pairings: [pairing.pairingID: DurablePairingRecord(pairing: pairing)],
                                              sessions: [session.sessionID: DurableSessionRecord(session: session, publishedAt: now)],
                                              currentSessionID: session.sessionID)
        let staleStore = try InMemoryDurableRelayStore(database: DurableRelayDatabase(
            owners: [ownerSigner.identity.identityID: staleLedger]))
        let staleService = DurableRelayService(store: staleStore, authorization: policy)
        XCTAssertThrowsError(try staleService.submit(operation, owner: ownerSigner.identity)) {
            XCTAssertEqual($0 as? DurableRelayError, .unauthorized)
        }
    }

    func testR6ScopedDeliveryCannotBeAuthorizedByR5Policy() throws {
        let signer = try owner()
        let policy = DurableAuthorizationPolicy.ownerOnly(kinds: ["notice"],
                                                           requiredScopes: ["notice": .earlyEndNotices])
        let service = DurableRelayService(store: InMemoryDurableRelayStore(), authorization: policy)
        let operation = try operation(signer: signer, id: "r6-notice", revision: 0, kind: "notice")
        XCTAssertThrowsError(try service.submit(operation, owner: signer.identity)) {
            XCTAssertEqual($0 as? DurableRelayError, .unsupportedOperation("notice"))
        }
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

    func testClosedPolicyRejectsEveryUnmodeledCommandRegardlessOfCallerList() throws {
        let signer = try owner()
        let forbidden = ["start", "extend", "policy", "rule", "delivery", "summary", "unknown"]
        let policy = DurableAuthorizationPolicy.ownerAndActivePairing(
            ownerOnlyKinds: [], approverKinds: Set(forbidden))
        let service = DurableRelayService(store: InMemoryDurableRelayStore(), authorization: policy, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        for (index, kind) in forbidden.enumerated() {
            let op = try operation(signer: signer, id: "forbidden-\(index)-\(kind)",
                                      revision: 0, kind: kind)
            XCTAssertThrowsError(try service.submit(op, owner: signer.identity)) { error in
                XCTAssertEqual(error as? DurableRelayError, .unsupportedOperation(kind))
            }
        }
        XCTAssertTrue(try service.store.read().owners.isEmpty)
    }

    func testDurableReducerBindsExactSessionConsentGenerationAndFirstUse() throws {
        let ownerSigner = try owner()
        let approver = try DeviceSigner.create(role: .trustedApprover,
                                               keyStore: InMemoryDeviceKeyStore())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pairing = try Pairing(pairingID: "reducer-pairing", owner: ownerSigner.identity,
                                  approver: approver.identity, epoch: 1, createdAt: now, state: .active)
        let session = try ActiveSession(owner: ownerSigner.identity, sessionID: "reducer-session",
                                        activeSetID: "reducer-set", startsAt: now.addingTimeInterval(-1),
                                        endsAt: now.addingTimeInterval(600))
        let consent = try RelationshipConsent(relationshipID: pairing.pairingID,
                                               pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
                                               owner: ownerSigner.identity, approver: approver.identity,
                                               ownerScopes: [.approveEarlyEnd, .receiveRequests],
                                               approverScopes: [.approveEarlyEnd, .receiveRequests],
                                               ownerState: .active, approverState: .active,
                                               updatedAt: now, generation: 7)
        let ledger = DurableOwnerLedger(owner: ownerSigner.identity,
                                        pairings: [pairing.pairingID: DurablePairingRecord(pairing: pairing)],
                                        sessions: [session.sessionID: DurableSessionRecord(session: session, publishedAt: now)],
                                        currentSessionID: session.sessionID,
                                        relationshipConsents: [pairing.pairingID: consent])
        let store = try InMemoryDurableRelayStore(database: DurableRelayDatabase(
            owners: [ownerSigner.identity.identityID: ledger]))
        let policy = DurableAuthorizationPolicy.ownerAndActivePairing(
            ownerOnlyKinds: ["request", "use", "cancel", "natural_end", "consent"],
            approverKinds: ["approval"])
        let service = DurableRelayService(store: store, authorization: policy, now: { now })
        let request = try TrustedRequest(requestID: "reducer-request", owner: ownerSigner.identity,
                                         targetBindings: [try RequestTargetBinding(pairing: pairing,
                                                                                    consentGeneration: 7)],
                                         session: session, message: nil, createdAt: now,
                                         expiresAt: now.addingTimeInterval(300))
        let requestOperation = try DurableOperationFactory.make(kind: "request", operationID: "reducer-request-op",
                                                               expectedRevision: 0, payload: request,
                                                               signer: ownerSigner)
        let requestResult = try service.submit(requestOperation, owner: ownerSigner.identity)
        XCTAssertEqual(requestResult.receipt.revision, 1)

        let unsignedApproval = Approval(approvalID: "reducer-approval", requestID: request.requestID,
                                        pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
                                        sessionID: session.sessionID, activeSetID: session.activeSetID,
                                        approver: approver.identity, decision: .approved,
                                        issuedAt: now, consentGeneration: 7,
                                        nonce: Data(repeating: 8, count: 24), signature: Data())
        let approvalSignature = try approver.sign(domain: "\(CompanionCanonical.version).approval",
                                                  fields: unsignedApproval.signingFields())
        let approval = Approval(approvalID: unsignedApproval.approvalID, requestID: unsignedApproval.requestID,
                                pairingID: unsignedApproval.pairingID, pairEpoch: unsignedApproval.pairEpoch,
                                sessionID: unsignedApproval.sessionID, activeSetID: unsignedApproval.activeSetID,
                                approver: unsignedApproval.approver, decision: unsignedApproval.decision,
                                issuedAt: unsignedApproval.issuedAt,
                                consentGeneration: unsignedApproval.consentGeneration,
                                nonce: unsignedApproval.nonce, signature: approvalSignature)
        let approvalOperation = try DurableOperationFactory.make(kind: "approval", operationID: "reducer-approval-op",
                                                                 expectedRevision: 1, payload: approval,
                                                                 signer: approver)
        _ = try service.submit(approvalOperation, owner: ownerSigner.identity)
        let use = ApprovalUse(approval: approval, requestID: request.requestID, useID: "reducer-use",
                              consentGeneration: 7)
        let useOperation = try DurableOperationFactory.make(kind: "use", operationID: "reducer-use-op",
                                                            expectedRevision: 2, payload: use,
                                                            signer: ownerSigner)
        let used = try service.submit(useOperation, owner: ownerSigner.identity)
        XCTAssertEqual(used.receipt.revision, 3)
        XCTAssertEqual(try service.submit(useOperation, owner: ownerSigner.identity).receipt.revision, 3)
        let reused = ApprovalUse(approval: approval, requestID: request.requestID, useID: "reducer-use-2",
                                 consentGeneration: 7)
        let reusedOperation = try DurableOperationFactory.make(kind: "use", operationID: "reducer-use-op-2",
                                                               expectedRevision: 3, payload: reused,
                                                               signer: ownerSigner)
        XCTAssertThrowsError(try service.submit(reusedOperation, owner: ownerSigner.identity)) { error in
            XCTAssertEqual(error as? CompanionError, .replay)
        }

        let regrant = try RelationshipConsentMutation(
            relationshipID: pairing.pairingID, pairingID: pairing.pairingID,
            pairEpoch: pairing.epoch, owner: ownerSigner.identity, approver: approver.identity,
            action: .ownerGrant,
            scopes: try CompanionScopeSet([.approveEarlyEnd, .receiveRequests]),
            nonce: Data(repeating: 9, count: 24), issuedAt: now)
        let regrantOperation = try DurableOperationFactory.make(kind: "consent", operationID: "reducer-regrant-op",
                                                                expectedRevision: 3, payload: regrant,
                                                                signer: ownerSigner)
        store.injectFailure(.afterCommitBeforeAcknowledgement)
        XCTAssertThrowsError(try service.submit(regrantOperation, owner: ownerSigner.identity)) { error in
            XCTAssertEqual(error as? DurableStoreError, .crashAfterCommitBeforeAcknowledgement)
        }
        let restarted = try store.restarted()
        let restartedService = DurableRelayService(store: restarted, authorization: policy, now: { now })
        let replayedRegrant = try restartedService.submit(regrantOperation, owner: ownerSigner.identity)
        guard case let .consent(replayedConsent) = replayedRegrant.result else {
            return XCTFail("replayed consent receipt has the wrong result")
        }
        XCTAssertEqual(replayedConsent.generation, 8)
        // The committed use receipt is replayable even though current consent
        // has moved on; a retry never re-enters authorization or re-applies it.
        XCTAssertEqual(try restartedService.submit(useOperation, owner: ownerSigner.identity).receipt.revision, 3)
        let invalidatedUse = ApprovalUse(approval: approval, requestID: request.requestID,
                                         useID: "reducer-use-after-regrant", consentGeneration: 7)
        let invalidatedOperation = try DurableOperationFactory.make(kind: "use", operationID: "reducer-use-after-regrant-op",
                                                                    expectedRevision: 4, payload: invalidatedUse,
                                                                    signer: ownerSigner)
        XCTAssertThrowsError(try restartedService.submit(invalidatedOperation, owner: ownerSigner.identity)) {
            XCTAssertEqual($0 as? CompanionError, .replay)
        }
    }

    func testExpiryAtBoundaryCommitsTerminalRejectionAcrossRestart() throws {
        let ownerSigner = try owner()
        let approver = try DeviceSigner.create(role: .trustedApprover,
                                               keyStore: InMemoryDeviceKeyStore())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pairing = try Pairing(pairingID: "expiry-pairing", owner: ownerSigner.identity,
                                  approver: approver.identity, epoch: 1, createdAt: now, state: .active)
        let session = try ActiveSession(owner: ownerSigner.identity, sessionID: "expiry-session",
                                        activeSetID: "expiry-set", startsAt: now.addingTimeInterval(-1),
                                        endsAt: now.addingTimeInterval(600))
        let consent = try RelationshipConsent(relationshipID: pairing.pairingID,
                                               pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
                                               owner: ownerSigner.identity, approver: approver.identity,
                                               ownerScopes: [.approveEarlyEnd, .receiveRequests],
                                               approverScopes: [.approveEarlyEnd, .receiveRequests],
                                               ownerState: .active, approverState: .active,
                                               updatedAt: now, generation: 3)
        let ledger = DurableOwnerLedger(owner: ownerSigner.identity,
                                        pairings: [pairing.pairingID: DurablePairingRecord(pairing: pairing)],
                                        sessions: [session.sessionID: DurableSessionRecord(session: session, publishedAt: now)],
                                        currentSessionID: session.sessionID,
                                        relationshipConsents: [pairing.pairingID: consent])
        let store = try InMemoryDurableRelayStore(database: DurableRelayDatabase(
            owners: [ownerSigner.identity.identityID: ledger]))
        let policy = DurableAuthorizationPolicy.ownerAndActivePairing(
            ownerOnlyKinds: ["request", "use", "cancel"], approverKinds: ["approval"])
        let service = DurableRelayService(store: store, authorization: policy, now: { now })
        let request = try TrustedRequest(requestID: "expiry-request", owner: ownerSigner.identity,
                                         targetBindings: [try RequestTargetBinding(pairing: pairing,
                                                                                    consentGeneration: 3)],
                                         session: session, message: nil, createdAt: now,
                                         expiresAt: now.addingTimeInterval(10))
        let requestOperation = try DurableOperationFactory.make(kind: "request", operationID: "expiry-request-op",
                                                               expectedRevision: 0, payload: request,
                                                               signer: ownerSigner)
        _ = try service.submit(requestOperation, owner: ownerSigner.identity)
        let unsigned = Approval(approvalID: "expiry-approval", requestID: request.requestID,
                                pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
                                sessionID: session.sessionID, activeSetID: session.activeSetID,
                                approver: approver.identity, decision: .approved, issuedAt: now,
                                consentGeneration: 3, nonce: Data(repeating: 31, count: 24), signature: Data())
        let approval = Approval(approvalID: unsigned.approvalID, requestID: unsigned.requestID,
                                pairingID: unsigned.pairingID, pairEpoch: unsigned.pairEpoch,
                                sessionID: unsigned.sessionID, activeSetID: unsigned.activeSetID,
                                approver: unsigned.approver, decision: unsigned.decision,
                                issuedAt: unsigned.issuedAt, consentGeneration: unsigned.consentGeneration,
                                nonce: unsigned.nonce,
                                signature: try approver.sign(domain: "\(CompanionCanonical.version).approval",
                                                              fields: unsigned.signingFields()))
        let approvalOperation = try DurableOperationFactory.make(kind: "approval", operationID: "expiry-approval-op",
                                                                 expectedRevision: 1, payload: approval,
                                                                 signer: approver)
        let atExpiry = DurableRelayService(store: store, authorization: policy,
                                           now: { now.addingTimeInterval(10) })
        XCTAssertThrowsError(try atExpiry.submit(approvalOperation, owner: ownerSigner.identity)) {
            XCTAssertEqual($0 as? CompanionError, .expired)
        }
        let firstState = try store.read().owners[ownerSigner.identity.identityID]!
        XCTAssertEqual(firstState.revision, 2)
        XCTAssertEqual(firstState.requests[request.requestID]?.request.status, .expired)
        XCTAssertEqual(firstState.operations[approvalOperation.operationID]?.disposition,
                       .rejectedExpiredRequest)
        let restarted = try store.restarted()
        let restartedService = DurableRelayService(store: restarted, authorization: policy,
                                                    now: { now.addingTimeInterval(10) })
        XCTAssertThrowsError(try restartedService.submit(approvalOperation, owner: ownerSigner.identity)) {
            XCTAssertEqual($0 as? CompanionError, .expired)
        }
        XCTAssertEqual(try restarted.read().owners[ownerSigner.identity.identityID]?.revision, 2)

        let secondRequest = try TrustedRequest(requestID: "late-use-request", owner: ownerSigner.identity,
                                               targetBindings: [try RequestTargetBinding(pairing: pairing,
                                                                                          consentGeneration: 3)],
                                               session: session, message: nil, createdAt: now,
                                               expiresAt: now.addingTimeInterval(20))
        let secondRequestOperation = try DurableOperationFactory.make(kind: "request",
                                                                       operationID: "late-use-request-op",
                                                                       expectedRevision: 2,
                                                                       payload: secondRequest,
                                                                       signer: ownerSigner)
        _ = try service.submit(secondRequestOperation, owner: ownerSigner.identity)
        let secondUnsigned = Approval(approvalID: "late-use-approval", requestID: secondRequest.requestID,
                                      pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
                                      sessionID: session.sessionID, activeSetID: session.activeSetID,
                                      approver: approver.identity, decision: .approved, issuedAt: now,
                                      consentGeneration: 3, nonce: Data(repeating: 32, count: 24), signature: Data())
        let secondApproval = Approval(approvalID: secondUnsigned.approvalID,
                                      requestID: secondUnsigned.requestID,
                                      pairingID: secondUnsigned.pairingID,
                                      pairEpoch: secondUnsigned.pairEpoch,
                                      sessionID: secondUnsigned.sessionID,
                                      activeSetID: secondUnsigned.activeSetID,
                                      approver: secondUnsigned.approver,
                                      decision: secondUnsigned.decision,
                                      issuedAt: secondUnsigned.issuedAt,
                                      consentGeneration: secondUnsigned.consentGeneration,
                                      nonce: secondUnsigned.nonce,
                                      signature: try approver.sign(
                                        domain: "\(CompanionCanonical.version).approval",
                                        fields: secondUnsigned.signingFields()))
        let secondApprovalOperation = try DurableOperationFactory.make(kind: "approval",
                                                                        operationID: "late-use-approval-op",
                                                                        expectedRevision: 3,
                                                                        payload: secondApproval,
                                                                        signer: approver)
        _ = try service.submit(secondApprovalOperation, owner: ownerSigner.identity)
        let use = ApprovalUse(approval: secondApproval, requestID: secondRequest.requestID,
                              useID: "late-use-id", consentGeneration: 3)
        let useOperation = try DurableOperationFactory.make(kind: "use", operationID: "late-use-op",
                                                            expectedRevision: 4, payload: use,
                                                            signer: ownerSigner)
        let lateUse = DurableRelayService(store: store, authorization: policy,
                                          now: { now.addingTimeInterval(20) })
        XCTAssertThrowsError(try lateUse.submit(useOperation, owner: ownerSigner.identity)) {
            XCTAssertEqual($0 as? CompanionError, .expired)
        }
        let useState = try store.read().owners[ownerSigner.identity.identityID]!
        XCTAssertEqual(useState.revision, 5)
        XCTAssertEqual(useState.requests[secondRequest.requestID]?.request.status, .expired)
        XCTAssertEqual(useState.operations[useOperation.operationID]?.disposition,
                       .rejectedExpiredRequest)
        let useRestart = try store.restarted()
        let useRestartService = DurableRelayService(store: useRestart, authorization: policy,
                                                     now: { now.addingTimeInterval(20) })
        XCTAssertThrowsError(try useRestartService.submit(useOperation, owner: ownerSigner.identity)) {
            XCTAssertEqual($0 as? CompanionError, .expired)
        }
        XCTAssertEqual(try useRestart.read().owners[ownerSigner.identity.identityID]?.revision, 5)
    }

    func testSnapshotRejectsHistoryGapAndOrphanPairingEpoch() throws {
        let signer = try owner()
        let response = Data("{}".utf8)
        let record = DurableOperationRecord(operationID: "gap-operation", ownerID: signer.identity.identityID,
                                            signer: signer.identity, kind: "ack",
                                            bodyDigest: Data(repeating: 4, count: 32),
                                            responseKind: "acknowledgement", responseBody: response,
                                            responseDigest: CompanionCanonical.digest(response),
                                            committedRevision: 2, committedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let gapLedger = DurableOwnerLedger(owner: signer.identity, revision: 2,
                                           operations: [record.operationID: record])
        XCTAssertThrowsError(try InMemoryDurableRelayStore(database: DurableRelayDatabase(
            owners: [signer.identity.identityID: gapLedger]))) {
            XCTAssertEqual($0 as? DurableStoreError, .invalidSnapshot)
        }
        let orphanLedger = DurableOwnerLedger(owner: signer.identity,
                                              pairingEpochs: ["orphan-pairing": UInt64.max])
        XCTAssertThrowsError(try InMemoryDurableRelayStore(database: DurableRelayDatabase(
            owners: [signer.identity.identityID: orphanLedger]))) {
            XCTAssertEqual($0 as? DurableStoreError, .invalidSnapshot)
        }
    }

    func testCheckedEpochAndRevisionOverflowReturnErrors() throws {
        XCTAssertThrowsError(try checkedIncrement(Int64.max, name: "ledger revision")) {
            XCTAssertEqual($0 as? DurableRelayError, .revisionOverflow)
        }
        XCTAssertThrowsError(try checkedPairingEpoch(UInt64.max)) {
            XCTAssertEqual($0 as? DurableRelayError, .epochOverflow)
        }
    }
}
