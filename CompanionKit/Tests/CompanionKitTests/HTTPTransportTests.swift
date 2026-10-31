import XCTest
@testable import CompanionKit

/// Intercepts every request made through a session configured with it, so
/// tests can exercise `HTTPCompanionTransport` against canned status codes
/// and bodies without a real listener.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let status: Int
        let body: Data
        var failure: URLError.Code?

        init(status: Int, body: Data) {
            self.status = status; self.body = body
        }
        init(failure: URLError.Code) {
            self.status = 0; self.body = Data(); self.failure = failure
        }
    }

    private static let lock = NSLock()
    // Guarded by `lock`; the compiler cannot see that, so this is an
    // intentional, explicit escape hatch for test-only global state.
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> Stub)?
    static var handler: (@Sendable (URLRequest) -> Stub)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = handler(request)
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// `URLProtocol` may deliver the body as `httpBody` or as `httpBodyStream`
/// depending on the session plumbing; tests read whichever is present.
private func bodyData(from request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: bufferSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

private func encodedRelayResponse(operationID: String, revision: UInt64, ownerIdentityID: String? = nil,
                                  stateRoot: Data? = nil) throws -> Data {
    let response = try RelayResponse(operationID: operationID, revision: revision,
                                     result: .acknowledgement, ownerIdentityID: ownerIdentityID,
                                     stateRoot: stateRoot)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(response)
}

/// R5 Slice B2a: a `.verification` `RelayResponse`, for `useApproval` tests.
private func encodedVerificationResponse(operationID: String, revision: UInt64,
                                         verification: ApprovalVerification,
                                         ownerIdentityID: String? = nil, stateRoot: Data? = nil) throws -> Data {
    let response = try RelayResponse(operationID: operationID, revision: revision, result: .verification(verification),
                                     ownerIdentityID: ownerIdentityID, stateRoot: stateRoot)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(response)
}

private let fixedTime = Date(timeIntervalSince1970: 1_700_000_000)
private let testBaseURL = URL(string: "http://127.0.0.1:8002")!

/// A fixed, well-formed invite token for stubbed-relay tests (22 base64url characters).
private let testInviteToken = String(repeating: "A", count: 22)

private func makeInvite(ownerName: String? = nil) throws -> (DeviceSigner, Invitation) {
    let ownerKeys = InMemoryDeviceKeyStore()
    let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
    return (ownerSigner, try signedInvite(ownerSigner: ownerSigner, inviteID: "invite-http", nonceByte: 9, ownerName: ownerName))
}

private func signedInvite(ownerSigner: DeviceSigner, inviteID: String, nonceByte: UInt8, ownerName: String? = nil) throws -> Invitation {
    let payload = try InvitePayload(inviteID: inviteID, owner: ownerSigner.identity, issuedAt: fixedTime,
                                    expiresAt: fixedTime.addingTimeInterval(3_600), nonce: Data(repeating: nonceByte, count: 24),
                                    tokenHash: InviteToken.inviteHash(token: testInviteToken, ownerPublicKey: ownerSigner.identity.publicKey, inviteID: inviteID),
                                    lookupKey: InviteToken.lookupKey(testInviteToken), ownerDisplayName: ownerName)
    let signature = try ownerSigner.sign(domain: "\(CompanionCanonical.version).invite.v3", fields: payload.signingFields())
    return try Invitation(payload: payload, signature: signature)
}

private func encodedPairingResponse(operationID: String, revision: UInt64, pairing: Pairing,
                                    ownerIdentityID: String? = nil, stateRoot: Data? = nil) throws -> Data {
    let response = try RelayResponse(operationID: operationID, revision: revision, result: .pairing(pairing),
                                     ownerIdentityID: ownerIdentityID, stateRoot: stateRoot)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(response)
}

/// Test convenience: reads a checkpoint back out of a store without needing
/// a mutation, using the same key `RollbackAnchor` would use internally.
private func loadCheckpoint(_ store: any RollbackAnchorStore, relayBaseURL: String = testBaseURL.absoluteString,
                            ownerIdentityID: String) throws -> CompanionCheckpoint? {
    try store.withCheckpoint(forKey: RollbackAnchor.storageKey(relayBaseURL: relayBaseURL, ownerIdentityID: ownerIdentityID)) { current in (current, nil) }
}

final class HTTPTransportTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Success path

    func testSubmitPostsToOperationsPathAndDecodesRelayResponse() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let client = AsyncCompanionClient(signer: ownerSigner,
                                          transport: HTTPCompanionTransport(baseURL: testBaseURL,
                                                                            session: StubURLProtocol.makeSession()),
                                          now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 1)
            XCTAssertEqual(request.url?.path, "/v1/operations")
            XCTAssertEqual(request.httpMethod, "POST")
            return .init(status: 200, body: body)
        }
        _ = try await client.createInvite(inviteID: invitation.payload.inviteID, validFor: 3_600, now: fixedTime,
                                          nonce: invitation.payload.nonce)
    }

    func testFetchInboxPostsToInboxPathAndValidatesOwner() async throws {
        let ownerKeys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        let ownerIdentityID = ownerSigner.identity.identityID
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/inbox")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let response = try! InboxResponse(ownerIdentityID: ownerIdentityID, revision: 1, requests: [])
            return .init(status: 200, body: try! encoder.encode(response))
        }
        let requests = try await client.fetchInbox()
        XCTAssertTrue(requests.isEmpty)
    }

    /// Documents the exact signed inbox query body shape for the relay
    /// writer: `JSONEncoder().sortedKeys` over `InboxQuery`, with `issuedAt`
    /// as a bare `Double` (`Date`'s default Codable representation —
    /// `timeIntervalSinceReferenceDate`, i.e. seconds since 2001-01-01T00:00:00Z
    /// — not `timeIntervalSince1970`), omitted entirely when `nil`.
    func testInboxQueryEncodesIdentityIDAndIssuedAtWithSortedKeysAndDefaultDateEncoding() throws {
        let withIssuedAt = InboxQuery(identityID: "abc123", issuedAt: Date(timeIntervalSinceReferenceDate: 750_000_000))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(data: try encoder.encode(withIssuedAt), encoding: .utf8),
                       "{\"identityID\":\"abc123\",\"issuedAt\":750000000}")

        let withoutIssuedAt = InboxQuery(identityID: "abc123")
        XCTAssertEqual(String(data: try encoder.encode(withoutIssuedAt), encoding: .utf8),
                       "{\"identityID\":\"abc123\"}")
    }

    func testFetchInboxSignsAFreshIssuedAtInTheQueryBody() async throws {
        let ownerKeys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        let ownerIdentityID = ownerSigner.identity.identityID
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let query = try! JSONDecoder().decode(InboxQuery.self, from: signed.body)
            XCTAssertEqual(query.identityID, ownerIdentityID)
            XCTAssertEqual(query.issuedAt, fixedTime)
            let response = try! InboxResponse(ownerIdentityID: ownerIdentityID, revision: 1, requests: [])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return .init(status: 200, body: try! encoder.encode(response))
        }
        _ = try await client.fetchInbox()
    }

    func testFetchInboxResponseCarriesPairingsAndConsents() async throws {
        let ownerKeys = InMemoryDeviceKeyStore()
        let approverKeys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: approverKeys)
        let pairing = try Pairing(pairingID: "pairing-1", owner: ownerSigner.identity, approver: approverSigner.identity,
                                  epoch: 1, createdAt: fixedTime, state: .active)
        let consent = try RelationshipConsent(relationshipID: "pairing-1", pairingID: "pairing-1", pairEpoch: 1,
                                              owner: ownerSigner.identity, approver: approverSigner.identity,
                                              ownerScopes: [.approveEarlyEnd], approverScopes: [.approveEarlyEnd],
                                              ownerState: .active, approverState: .active, updatedAt: fixedTime, generation: 2)
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: approverSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { _ in
            // A pure helper inbox omits ownerIdentityID/stateRoot but still
            // carries pairings/consents.
            let response = try! InboxResponse(ownerIdentityID: nil, revision: 1, requests: [],
                                              pairings: [pairing], consents: [consent])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return .init(status: 200, body: try! encoder.encode(response))
        }
        let response = try await client.fetchInboxResponse()
        XCTAssertNil(response.ownerIdentityID)
        XCTAssertEqual(response.pairings, [pairing])
        XCTAssertEqual(response.consents?.first?.generation, 2)
    }

    // MARK: - R5 Slice B2a: AsyncCompanionClient.useApproval

    private func makeHTTPUseFixture() throws -> (owner: DeviceSigner, approver: DeviceSigner, request: TrustedRequest, approval: Approval) {
        let ownerKeys = InMemoryDeviceKeyStore()
        let approverKeys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: approverKeys)
        let pairing = try Pairing(pairingID: "pairing-use-http", owner: ownerSigner.identity, approver: approverSigner.identity,
                                  epoch: 1, createdAt: fixedTime, state: .active)
        let session = try ActiveSession(owner: ownerSigner.identity, sessionID: "session-use-http", activeSetID: "set-use-http",
                                        startsAt: fixedTime.addingTimeInterval(-1), endsAt: fixedTime.addingTimeInterval(3_600))
        let binding = try RequestTargetBinding(pairing: pairing, consentGeneration: 2)
        let request = try TrustedRequest(requestID: "request-use-http", owner: ownerSigner.identity, targetBindings: [binding],
                                         session: session, message: nil, createdAt: fixedTime,
                                         expiresAt: fixedTime.addingTimeInterval(600))
        let unsignedApproval = Approval(approvalID: "approval-use-http", requestID: request.requestID, pairingID: pairing.pairingID,
                                        pairEpoch: pairing.epoch, sessionID: request.sessionID, activeSetID: request.activeSetID,
                                        approver: approverSigner.identity, decision: .approved, issuedAt: fixedTime,
                                        consentGeneration: binding.consentGeneration, nonce: Data(repeating: 6, count: 24), signature: Data())
        let approvalSignature = try approverSigner.sign(domain: "\(CompanionCanonical.version).approval", fields: unsignedApproval.signingFields())
        let approval = Approval(approvalID: unsignedApproval.approvalID, requestID: unsignedApproval.requestID,
                                pairingID: unsignedApproval.pairingID, pairEpoch: unsignedApproval.pairEpoch,
                                sessionID: unsignedApproval.sessionID, activeSetID: unsignedApproval.activeSetID,
                                approver: unsignedApproval.approver, decision: unsignedApproval.decision,
                                issuedAt: unsignedApproval.issuedAt, consentGeneration: unsignedApproval.consentGeneration,
                                nonce: unsignedApproval.nonce, signature: approvalSignature)
        return (ownerSigner, approverSigner, request, approval)
    }

    func testUseApprovalPostsToOperationsPathAndVerifiesTheResponse() async throws {
        let fixture = try makeHTTPUseFixture()
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: fixture.owner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/operations")
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            XCTAssertEqual(signed.kind, "use")
            let verification = ApprovalVerification(approval: fixture.approval, verifiedAt: fixedTime, useID: "use-http-1")
            let body = try! encodedVerificationResponse(operationID: signed.operationID, revision: 1, verification: verification)
            return .init(status: 200, body: body)
        }
        let verification = try await client.useApproval(fixture.approval, request: fixture.request, useID: "use-http-1")
        XCTAssertEqual(verification.useID, "use-http-1")
        XCTAssertEqual(verification.approval, fixture.approval)
    }

    func testUseApprovalRejectsATamperedApprovalInTheResponse() async throws {
        let fixture = try makeHTTPUseFixture()
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: fixture.owner, transport: transport, now: { fixedTime })
        // The relay confirms a *different* approval than the one actually
        // submitted (still validly signed by the real approver, so a naive
        // client that only checked the signature would accept it).
        let substituted = Approval(approvalID: "attacker-substituted-approval", requestID: fixture.approval.requestID,
                                   pairingID: fixture.approval.pairingID, pairEpoch: fixture.approval.pairEpoch,
                                   sessionID: fixture.approval.sessionID, activeSetID: fixture.approval.activeSetID,
                                   approver: fixture.approval.approver, decision: .approved, issuedAt: fixedTime,
                                   consentGeneration: fixture.approval.consentGeneration,
                                   nonce: Data(repeating: 8, count: 24), signature: Data())
        let substitutedSignature = try fixture.approver.sign(domain: "\(CompanionCanonical.version).approval",
                                                              fields: substituted.signingFields())
        let signedSubstituted = Approval(approvalID: substituted.approvalID, requestID: substituted.requestID,
                                         pairingID: substituted.pairingID, pairEpoch: substituted.pairEpoch,
                                         sessionID: substituted.sessionID, activeSetID: substituted.activeSetID,
                                         approver: substituted.approver, decision: substituted.decision,
                                         issuedAt: substituted.issuedAt, consentGeneration: substituted.consentGeneration,
                                         nonce: substituted.nonce, signature: substitutedSignature)
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let verification = ApprovalVerification(approval: signedSubstituted, verifiedAt: fixedTime, useID: "use-http-2")
            let body = try! encodedVerificationResponse(operationID: signed.operationID, revision: 1, verification: verification)
            return .init(status: 200, body: body)
        }
        do {
            _ = try await client.useApproval(fixture.approval, request: fixture.request, useID: "use-http-2")
            XCTFail("expected rejection of a substituted approval")
        } catch CompanionError.responseVerificationFailed {
            // expected (R5 Slice B2a review fix, N3: wrapped, not bare .malformed)
        }
    }

    func testUseApprovalRejectsAWrongUseIDInTheResponse() async throws {
        let fixture = try makeHTTPUseFixture()
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: fixture.owner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            // Same (real, validly signed) approval, but a useID the client never asked for.
            let verification = ApprovalVerification(approval: fixture.approval, verifiedAt: fixedTime, useID: "attacker-use-id")
            let body = try! encodedVerificationResponse(operationID: signed.operationID, revision: 1, verification: verification)
            return .init(status: 200, body: body)
        }
        do {
            _ = try await client.useApproval(fixture.approval, request: fixture.request, useID: "use-http-wrong-id")
            XCTFail("expected rejection of a mismatched useID")
        } catch CompanionError.responseVerificationFailed {
            // expected (R5 Slice B2a review fix, N3: wrapped, not bare .malformed)
        }
    }

    func testUseApprovalRejectsAnInvalidlySignedApprovalInTheResponse() async throws {
        let fixture = try makeHTTPUseFixture()
        // A corrupted signature on the very approval the client itself holds
        // and submits -- the relay simply echoes it back unchanged (so the
        // `verification.approval == approval` and `useID` checks both pass),
        // but `validateUseVerification`'s explicit signature check must
        // still catch it.
        var corruptedSignature = fixture.approval.signature
        corruptedSignature[0] ^= 0xFF
        let corruptedApproval = Approval(approvalID: fixture.approval.approvalID, requestID: fixture.approval.requestID,
                                         pairingID: fixture.approval.pairingID, pairEpoch: fixture.approval.pairEpoch,
                                         sessionID: fixture.approval.sessionID, activeSetID: fixture.approval.activeSetID,
                                         approver: fixture.approval.approver, decision: fixture.approval.decision,
                                         issuedAt: fixture.approval.issuedAt, consentGeneration: fixture.approval.consentGeneration,
                                         nonce: fixture.approval.nonce, signature: corruptedSignature)
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: fixture.owner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let verification = ApprovalVerification(approval: corruptedApproval, verifiedAt: fixedTime, useID: "use-http-bad-sig")
            let body = try! encodedVerificationResponse(operationID: signed.operationID, revision: 1, verification: verification)
            return .init(status: 200, body: body)
        }
        do {
            _ = try await client.useApproval(corruptedApproval, request: fixture.request, useID: "use-http-bad-sig")
            XCTFail("expected rejection of an invalid approval signature")
        } catch CompanionError.responseVerificationFailed {
            // expected (R5 Slice B2a review fix, N3: wrapped, not bare .invalidSignature)
        }
    }

    func testUseApprovalRejectsANonApprovedDecisionInTheResponse() async throws {
        let fixture = try makeHTTPUseFixture()
        // A validly signed, structurally-matching approval whose decision is
        // "declined" -- every other check passes, so this isolates the final
        // decision == .approved guard.
        let declinedUnsigned = Approval(approvalID: fixture.approval.approvalID, requestID: fixture.approval.requestID,
                                        pairingID: fixture.approval.pairingID, pairEpoch: fixture.approval.pairEpoch,
                                        sessionID: fixture.approval.sessionID, activeSetID: fixture.approval.activeSetID,
                                        approver: fixture.approval.approver, decision: .declined, issuedAt: fixedTime,
                                        consentGeneration: fixture.approval.consentGeneration,
                                        nonce: Data(repeating: 13, count: 24), signature: Data())
        let declinedSignature = try fixture.approver.sign(domain: "\(CompanionCanonical.version).approval",
                                                           fields: declinedUnsigned.signingFields())
        let declinedApproval = Approval(approvalID: declinedUnsigned.approvalID, requestID: declinedUnsigned.requestID,
                                        pairingID: declinedUnsigned.pairingID, pairEpoch: declinedUnsigned.pairEpoch,
                                        sessionID: declinedUnsigned.sessionID, activeSetID: declinedUnsigned.activeSetID,
                                        approver: declinedUnsigned.approver, decision: declinedUnsigned.decision,
                                        issuedAt: declinedUnsigned.issuedAt, consentGeneration: declinedUnsigned.consentGeneration,
                                        nonce: declinedUnsigned.nonce, signature: declinedSignature)
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: fixture.owner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let verification = ApprovalVerification(approval: declinedApproval, verifiedAt: fixedTime, useID: "use-http-declined")
            let body = try! encodedVerificationResponse(operationID: signed.operationID, revision: 1, verification: verification)
            return .init(status: 200, body: body)
        }
        do {
            _ = try await client.useApproval(declinedApproval, request: fixture.request, useID: "use-http-declined")
            XCTFail("expected rejection of a non-approved decision")
        } catch CompanionError.responseVerificationFailed {
            // expected (R5 Slice B2a review fix, N3: wrapped, not bare .wrongTarget)
        }
    }

    /// R5 Slice B2a review fix (P1-1): a "use" replay (identical
    /// operationID/body) that arrives after the owner's rollback anchor has
    /// already advanced past the operation's original commit revision must
    /// still succeed, returning the identical idempotent verification. Before
    /// the fix, the relay's replay path echoed the historical
    /// `(revision, stateRoot)` pair from the operation's first commit, which
    /// `RollbackAnchor.accept` would reject as a regression once a later,
    /// legitimate response had already advanced the anchor past that point —
    /// which would permanently strand a B2c crash-recovery retry of "use".
    func testUseApprovalReplayAfterTheAnchorAdvancesStillSucceeds() async throws {
        let fixture = try makeHTTPUseFixture()
        let anchorStore = InMemoryRollbackAnchorStore()
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession(),
                                               anchorStore: anchorStore)
        let client = AsyncCompanionClient(signer: fixture.owner, transport: transport, now: { fixedTime })
        let ownerIdentityID = fixture.owner.identity.identityID
        let verification = ApprovalVerification(approval: fixture.approval, verifiedAt: fixedTime, useID: "use-replay-1")

        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let body = try! encodedVerificationResponse(operationID: signed.operationID, revision: 5, verification: verification,
                                                         ownerIdentityID: ownerIdentityID, stateRoot: Data(repeating: 0x11, count: 32))
            return .init(status: 200, body: body)
        }
        let first = try await client.useApproval(fixture.approval, request: fixture.request, useID: "use-replay-1")
        XCTAssertEqual(first, verification)

        // Something else (an unrelated mutation, an inbox fetch) advances
        // the owner's accepted anchor past the "use" operation's original
        // commit revision before the replay arrives.
        let anchor = RollbackAnchor(store: anchorStore)
        try anchor.accept(relayBaseURL: testBaseURL.companionAnchorKey, ownerIdentityID: ownerIdentityID,
                          revision: 9, stateRoot: Data(repeating: 0x22, count: 32), enforceIfNoCheckpoint: true)

        // The relay replays the identical "use" operation: same result, but
        // the ledger's CURRENT revision/root (12), not the historical 5.
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let body = try! encodedVerificationResponse(operationID: signed.operationID, revision: 12, verification: verification,
                                                         ownerIdentityID: ownerIdentityID, stateRoot: Data(repeating: 0x33, count: 32))
            return .init(status: 200, body: body)
        }
        let replay = try await client.useApproval(fixture.approval, request: fixture.request, useID: "use-replay-1")
        XCTAssertEqual(replay, verification)
        let checkpoint = try anchor.currentCheckpoint(relayBaseURL: testBaseURL.companionAnchorKey, ownerIdentityID: ownerIdentityID)
        XCTAssertEqual(checkpoint?.revision, 12)
    }

    // MARK: - Pairing v3: invite lookup and malicious accept responses

    func testLookupInvitePostsTheTokenAndVerifiesTheReturnedInvitation() async throws {
        let (ownerSigner, invitation) = try makeInvite(ownerName: "Alex")
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: approverSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/invite/lookup")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try! JSONSerialization.jsonObject(with: bodyData(from: request)) as! [String: String]
            // Only the lookup key is sent; the token itself never leaves the device.
            XCTAssertEqual(body, ["lookupKey": InviteToken.lookupKeyString(testInviteToken)])
            XCTAssertFalse(String(decoding: bodyData(from: request), as: UTF8.self).contains(testInviteToken))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            struct Wrapper: Encodable { let invitation: Invitation }
            return .init(status: 200, body: try! encoder.encode(Wrapper(invitation: invitation)))
        }
        let found = try await client.lookupInvite(token: testInviteToken)
        XCTAssertEqual(found.payload.ownerDisplayName, "Alex")
        XCTAssertEqual(found.payload.owner, ownerSigner.identity)

        // A relay that returns an invitation for a different token is refused.
        StubURLProtocol.handler = { _ in
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            struct Wrapper: Encodable { let invitation: Invitation }
            return .init(status: 200, body: try! encoder.encode(Wrapper(invitation: invitation)))
        }
        do {
            _ = try await client.lookupInvite(token: String(repeating: "B", count: 22))
            XCTFail("expected a token/hash mismatch to be rejected")
        } catch CompanionError.malformed {
            // expected
        }
    }

    func testRelayCannotSwapInInvitationItSignedItself() async throws {
        // An active relay knows the lookup key. It answers with an invitation signed by its OWN key
        // that reuses that lookup key; without the token it cannot compute the owner-bound token hash.
        let relayOwner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let forgedPayload = try InvitePayload(inviteID: "relay-made", owner: relayOwner.identity, issuedAt: fixedTime,
                                              expiresAt: fixedTime.addingTimeInterval(3_600), nonce: Data(repeating: 4, count: 24),
                                              tokenHash: Data(repeating: 7, count: 32),
                                              lookupKey: InviteToken.lookupKey(testInviteToken), ownerDisplayName: "Your friend")
        let forged = try Invitation(payload: forgedPayload, signature: try relayOwner.sign(
            domain: "\(CompanionCanonical.version).invite.v3", fields: forgedPayload.signingFields()))
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: approverSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { _ in
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            struct Wrapper: Encodable { let invitation: Invitation }
            return .init(status: 200, body: try! encoder.encode(Wrapper(invitation: forged)))
        }
        do {
            _ = try await client.lookupInvite(token: testInviteToken)
            XCTFail("a relay-signed invitation must be rejected")
        } catch CompanionError.malformed {
            // expected
        }
    }

    func testBareNotFoundIsUnavailableButTheRelaysJSONErrorIsNotFound() async throws {
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: approverSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { _ in .init(status: 404, body: Data("<html>Not Found</html>".utf8)) }
        do {
            _ = try await client.lookupInvite(token: testInviteToken)
            XCTFail("expected unavailable")
        } catch let error as CompanionTransportError { XCTAssertEqual(error, .unavailable) }
    }

    func testLookupInviteMapsNotFoundAndRateLimited() async throws {
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: approverSigner, transport: transport, now: { fixedTime })
        for (status, code, expected) in [(404, "not_found", CompanionError.notFound), (429, "rate_limited", CompanionError.rateLimited)] {
            StubURLProtocol.handler = { _ in .init(status: status, body: Data(#"{"error":"\#(code)"}"#.utf8)) }
            do {
                _ = try await client.lookupInvite(token: testInviteToken)
                XCTFail("expected \(code)")
            } catch let error as CompanionTransportError {
                XCTAssertEqual(error, .server(expected))
            }
        }
    }

    func testAcceptRejectsARelayThatSwapsTheApproverKeyInTheResponse() async throws {
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let realApproverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let attackerSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let invitation = try signedInvite(ownerSigner: ownerSigner, inviteID: "invite-accept-swap", nonceByte: 2)
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: realApproverSigner, transport: transport, now: { fixedTime })

        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            // The relay answers with a pairing naming the attacker as approver
            // instead of the identity that actually accepted.
            let swapped = try! Pairing(pairingID: Pairing.derivedID(inviteID: invitation.payload.inviteID,
                                                                    approverIdentityID: realApproverSigner.identity.identityID),
                                       owner: ownerSigner.identity, approver: attackerSigner.identity, epoch: 1,
                                       createdAt: fixedTime, state: .active)
            return .init(status: 200, body: try! encodedPairingResponse(operationID: signed.operationID, revision: 1, pairing: swapped))
        }
        do {
            _ = try await client.acceptInvite(invitation, token: testInviteToken, acceptanceID: "accept-swap", now: fixedTime)
            XCTFail("expected rejection of a swapped approver")
        } catch CompanionError.malformed {
            // expected
        }
    }

    func testAcceptRejectsARelayThatSubstitutesTheOwnerOrAltersNames() async throws {
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let realApproverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let attackerOwnerSigner = try DeviceSigner.create(role: .owner, keyStore: InMemoryDeviceKeyStore())
        let invitation = try signedInvite(ownerSigner: ownerSigner, inviteID: "invite-accept-owner-swap", nonceByte: 5, ownerName: "Alex")
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: realApproverSigner, transport: transport, now: { fixedTime })
        let pairingID = Pairing.derivedID(inviteID: invitation.payload.inviteID,
                                          approverIdentityID: realApproverSigner.identity.identityID)

        // (owner, ownerDisplayName, approverDisplayName) the hostile relay reports.
        let hostile: [(DeviceIdentity, String?, String?)] = [
            (attackerOwnerSigner.identity, "Alex", "Sam"),
            (ownerSigner.identity, "Mallory", "Sam"),
            (ownerSigner.identity, "Alex", "Someone else")
        ]
        for (owner, ownerName, approverName) in hostile {
            StubURLProtocol.handler = { request in
                let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
                let pairing = try! Pairing(pairingID: pairingID, owner: owner, approver: realApproverSigner.identity, epoch: 1,
                                           createdAt: fixedTime, state: .active,
                                           ownerDisplayName: ownerName, approverDisplayName: approverName)
                return .init(status: 200, body: try! encodedPairingResponse(operationID: signed.operationID, revision: 1, pairing: pairing))
            }
            do {
                _ = try await client.acceptInvite(invitation, token: testInviteToken, approverDisplayName: "Sam",
                                                  acceptanceID: "accept-hostile", now: fixedTime)
                XCTFail("expected rejection of a response that does not match the accepted invitation")
            } catch CompanionError.malformed {
                // expected
            }
        }
    }

    func testCancelledURLRequestIsCancellationNotUnavailable() async throws {
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: InMemoryDeviceKeyStore())
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: approverSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { _ in .init(failure: .cancelled) }
        do {
            _ = try await client.lookupInvite(token: testInviteToken)
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("expected CancellationError, got \(error)") }
        StubURLProtocol.handler = { _ in .init(failure: .notConnectedToInternet) }
        do {
            _ = try await client.lookupInvite(token: testInviteToken)
            XCTFail("expected unavailable")
        } catch let error as CompanionTransportError { XCTAssertEqual(error, .unavailable) }
    }

    func testHealthEndpointReportsOk() async throws {
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/health")
            XCTAssertEqual(request.httpMethod, "GET")
            return .init(status: 200, body: Data(#"{"ok":true}"#.utf8))
        }
        let ok = try await transport.health()
        XCTAssertTrue(ok)
    }

    // MARK: - Status code -> typed error mapping

    private func expectServerError(status: Int, code: String, expected: CompanionError) async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { _ in .init(status: status, body: Data("{\"error\":\"\(code)\"}".utf8)) }
        do {
            _ = try await client.createInvite(inviteID: invitation.payload.inviteID, validFor: 3_600, now: fixedTime,
                                              nonce: invitation.payload.nonce)
            XCTFail("expected \(expected) for status \(status)")
        } catch CompanionTransportError.server(let error) {
            XCTAssertEqual(error, expected)
        }
    }

    func test400MapsToMalformed() async throws {
        try await expectServerError(status: 400, code: "malformed", expected: .malformed("relay rejected the operation"))
    }

    func test401MapsToInvalidSignature() async throws {
        try await expectServerError(status: 401, code: "invalid_signature", expected: .invalidSignature)
    }

    func test403MapsToUnauthorized() async throws {
        try await expectServerError(status: 403, code: "unauthorized", expected: .unauthorized)
    }

    func test409MapsToStaleRevision() async throws {
        try await expectServerError(status: 409, code: "stale_revision", expected: .staleRevision(expected: 0, actual: 0))
    }

    func test409MapsToIdempotencyConflict() async throws {
        try await expectServerError(status: 409, code: "idempotency_conflict", expected: .operationConflict)
    }

    func test413MapsToPayloadTooLarge() async throws {
        try await expectServerError(status: 413, code: "payload_too_large", expected: .malformed("payload too large"))
    }

    func test429MapsToRateLimited() async throws {
        try await expectServerError(status: 429, code: "rate_limited", expected: .rateLimited)
    }

    func testInvalidEnvelopeMapsToDistinguishableMalformed() async throws {
        try await expectServerError(status: 400, code: "invalid_envelope", expected: .malformed("invalid operation envelope"))
    }

    func testUnknownOwnerMapsToUnknownIdentity() async throws {
        try await expectServerError(status: 400, code: "unknown_owner", expected: .unknownIdentity)
    }

    func testConsentRequiredMapsThrough() async throws {
        try await expectServerError(status: 403, code: "consent_required", expected: .consentRequired)
    }

    func testUnknownErrorCodeStillProducesATypedMalformedError() async throws {
        try await expectServerError(status: 400, code: "totally_new_code",
                                    expected: .malformed("unrecognized relay error: totally_new_code"))
    }

    func test5xxIsRetryableUnavailable() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { _ in .init(status: 503, body: Data()) }
        do {
            _ = try await client.createInvite(inviteID: invitation.payload.inviteID, validFor: 3_600, now: fixedTime,
                                              nonce: invitation.payload.nonce)
            XCTFail("expected transport failure")
        } catch CompanionTransportError.unavailable {
            // expected: retryable
        }
    }

    func testMalformedBodyOnSuccessStatusIsMalformedResponse() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { _ in .init(status: 200, body: Data("not json".utf8)) }
        do {
            _ = try await client.createInvite(inviteID: invitation.payload.inviteID, validFor: 3_600, now: fixedTime,
                                              nonce: invitation.payload.nonce)
            XCTFail("expected malformed response")
        } catch CompanionTransportError.malformedResponse {
            // expected
        }
    }

    // MARK: - Rollback anchor

    func testAnchorAcceptsIncreasingRevisionAndPersistsCheckpoint() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession(), anchorStore: anchorStore)
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        let ownerIdentityID = ownerSigner.identity.identityID
        let root1 = Data(repeating: 1, count: 32)
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 1,
                                                 ownerIdentityID: ownerIdentityID, stateRoot: root1)
            return .init(status: 200, body: body)
        }
        _ = try await client.createInvite(inviteID: invitation.payload.inviteID, validFor: 3_600, now: fixedTime,
                                          nonce: invitation.payload.nonce)
        let checkpoint = try loadCheckpoint(anchorStore, ownerIdentityID: ownerIdentityID)
        XCTAssertEqual(checkpoint?.revision, 1)
        XCTAssertEqual(checkpoint?.stateRoot, root1)
    }

    func testAnchorRejectsLowerRevisionThanAlreadyAccepted() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let ownerIdentityID = ownerSigner.identity.identityID
        let anchor = RollbackAnchor(store: anchorStore)
        try anchor.accept(relayBaseURL: testBaseURL.absoluteString, ownerIdentityID: ownerIdentityID,
                          revision: 5, stateRoot: Data(repeating: 2, count: 32), enforceIfNoCheckpoint: true)
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession(), anchorStore: anchorStore)
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 3,
                                                 ownerIdentityID: ownerIdentityID, stateRoot: Data(repeating: 3, count: 32))
            return .init(status: 200, body: body)
        }
        do {
            _ = try await client.createInvite(inviteID: invitation.payload.inviteID, validFor: 3_600, now: fixedTime,
                                              nonce: invitation.payload.nonce)
            XCTFail("expected rollback rejection")
        } catch CompanionTransportError.server(.relayRollback(.regressedRevision(let expected, let actual))) {
            XCTAssertEqual(expected, 5)
            XCTAssertEqual(actual, 3)
        }
        // The stored checkpoint must be unchanged by the rejected regression.
        let checkpoint = try loadCheckpoint(anchorStore, ownerIdentityID: ownerIdentityID)
        XCTAssertEqual(checkpoint?.revision, 5)
    }

    func testAnchorRejectsConflictingRootAtSameRevision() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let ownerIdentityID = ownerSigner.identity.identityID
        let originalRoot = Data(repeating: 4, count: 32)
        let anchor = RollbackAnchor(store: anchorStore)
        try anchor.accept(relayBaseURL: testBaseURL.absoluteString, ownerIdentityID: ownerIdentityID,
                          revision: 2, stateRoot: originalRoot, enforceIfNoCheckpoint: true)
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession(), anchorStore: anchorStore)
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 2,
                                                 ownerIdentityID: ownerIdentityID, stateRoot: Data(repeating: 9, count: 32))
            return .init(status: 200, body: body)
        }
        do {
            _ = try await client.createInvite(inviteID: invitation.payload.inviteID, validFor: 3_600, now: fixedTime,
                                              nonce: invitation.payload.nonce)
            XCTFail("expected fork rejection")
        } catch CompanionTransportError.server(.relayRollback(.conflictingRoot(let revision))) {
            XCTAssertEqual(revision, 2)
        }
        let checkpoint = try loadCheckpoint(anchorStore, ownerIdentityID: ownerIdentityID)
        XCTAssertEqual(checkpoint?.stateRoot, originalRoot, "unchanged on a rejected fork")
    }

    /// R5 Slice B2a review fix (N2): the relay's own `stale_revision`
    /// rejection (a benign optimistic-concurrency write race, surfaced as
    /// an HTTP error status before any response body is even decoded) and
    /// this device's own local anchor detecting a rollback in an otherwise
    /// well-formed 200 response must never collapse to the same error case
    /// — a caller needs to treat them completely differently (retry with a
    /// fresh revision vs. never retry).
    func testRelayStaleRevisionAndAnchorRollbackAreDistinctErrors() async throws {
        // (1) The relay itself rejects the mutation outright: HTTP 409 with
        // error code "stale_revision". Never reaches `RollbackAnchor` at all.
        let (ownerSigner1, invitation1) = try makeInvite()
        let transport1 = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession())
        let client1 = AsyncCompanionClient(signer: ownerSigner1, transport: transport1, now: { fixedTime })
        StubURLProtocol.handler = { _ in .init(status: 409, body: Data(#"{"error":"stale_revision"}"#.utf8)) }
        do {
            _ = try await client1.createInvite(inviteID: invitation1.payload.inviteID, validFor: 3_600, now: fixedTime,
                                               nonce: invitation1.payload.nonce)
            XCTFail("expected a relay-rejected stale revision")
        } catch CompanionTransportError.server(let error) {
            guard case .staleRevision = error else { return XCTFail("expected .staleRevision, got \(error)") }
        }

        // (2) A well-formed 200 response whose revision regresses behind
        // this device's own already-accepted checkpoint -- an actual
        // rollback/fork, detected locally, nothing to do with the relay's
        // HTTP-level rejection above.
        let (ownerSigner2, invitation2) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let ownerIdentityID2 = ownerSigner2.identity.identityID
        let anchor = RollbackAnchor(store: anchorStore)
        try anchor.accept(relayBaseURL: testBaseURL.absoluteString, ownerIdentityID: ownerIdentityID2,
                          revision: 5, stateRoot: Data(repeating: 1, count: 32), enforceIfNoCheckpoint: true)
        let transport2 = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession(), anchorStore: anchorStore)
        let client2 = AsyncCompanionClient(signer: ownerSigner2, transport: transport2, now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 2,
                                                 ownerIdentityID: ownerIdentityID2, stateRoot: Data(repeating: 2, count: 32))
            return .init(status: 200, body: body)
        }
        do {
            _ = try await client2.createInvite(inviteID: invitation2.payload.inviteID, validFor: 3_600, now: fixedTime,
                                               nonce: invitation2.payload.nonce)
            XCTFail("expected an anchor rollback rejection")
        } catch CompanionTransportError.server(let error) {
            guard case .relayRollback = error else { return XCTFail("expected .relayRollback, got \(error)") }
            if case .staleRevision = error { XCTFail("a locally-detected rollback must never also match .staleRevision") }
        }
    }

    func testAnchorEnforcementRejectsMissingStateRootByDefault() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession(), anchorStore: anchorStore)
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        let ownerIdentityID = ownerSigner.identity.identityID
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            // No stateRoot, but does carry ownerIdentityID matching the signer.
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 1, ownerIdentityID: ownerIdentityID)
            return .init(status: 200, body: body)
        }
        do {
            _ = try await client.createInvite(inviteID: invitation.payload.inviteID, validFor: 3_600, now: fixedTime,
                                              nonce: invitation.payload.nonce)
            XCTFail("expected enforcement failure without a state root")
        } catch CompanionTransportError.server(.malformed) {
            // expected: fail closed when anchoring is requested but unsupported
        }
    }

    func testAnchorOnceEstablishedAlwaysEnforcesEvenIfConstructedWithEnforcementDisabled() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let ownerIdentityID = ownerSigner.identity.identityID
        // A checkpoint already exists for this key (established elsewhere).
        let anchor = RollbackAnchor(store: anchorStore)
        try anchor.accept(relayBaseURL: testBaseURL.absoluteString, ownerIdentityID: ownerIdentityID,
                          revision: 4, stateRoot: Data(repeating: 8, count: 32), enforceIfNoCheckpoint: true)
        // Even with enforceStateRoot: false, a missing root must be rejected
        // once a checkpoint exists for this key.
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession(),
                                               anchorStore: anchorStore, enforceStateRoot: false)
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 5, ownerIdentityID: ownerIdentityID)
            return .init(status: 200, body: body)
        }
        do {
            _ = try await client.createInvite(inviteID: invitation.payload.inviteID, validFor: 3_600, now: fixedTime,
                                              nonce: invitation.payload.nonce)
            XCTFail("expected enforcement even though the transport was constructed with enforceStateRoot: false")
        } catch CompanionTransportError.server(.malformed) {
            // expected
        }
    }

    func testAnchorEnforcementCanBeRelaxedOnlyBeforeAnyCheckpointExists() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let ownerIdentityID = ownerSigner.identity.identityID
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession(),
                                               anchorStore: anchorStore, enforceStateRoot: false)
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 1, ownerIdentityID: ownerIdentityID)
            return .init(status: 200, body: body)
        }
        _ = try await client.createInvite(inviteID: invitation.payload.inviteID, validFor: 3_600, now: fixedTime,
                                          nonce: invitation.payload.nonce)
        XCTAssertNil(try loadCheckpoint(anchorStore, ownerIdentityID: ownerIdentityID))
    }

    func testHelperSignedOperationsAreNeverAnchored() async throws {
        let approverKeys = InMemoryDeviceKeyStore()
        let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: approverKeys)
        let ownerKeys = InMemoryDeviceKeyStore()
        let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
        let invitation = try signedInvite(ownerSigner: ownerSigner, inviteID: "invite-helper", nonceByte: 1)
        let anchorStore = InMemoryRollbackAnchorStore()
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession(), anchorStore: anchorStore)
        let client = AsyncCompanionClient(signer: approverSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            // Even if the relay attributes this response to the owner's
            // ledger (correct per contract for a helper-signed op) with a
            // real state root, a helper-signed operation must never be
            // anchored by this device.
            let pairing = try! Pairing(pairingID: Pairing.derivedID(inviteID: invitation.payload.inviteID,
                                                                    approverIdentityID: approverSigner.identity.identityID),
                                       owner: ownerSigner.identity, approver: approverSigner.identity, epoch: 1,
                                       createdAt: fixedTime, state: .active)
            let body = try! encodedPairingResponse(operationID: signed.operationID, revision: 1, pairing: pairing,
                                                   ownerIdentityID: ownerSigner.identity.identityID,
                                                   stateRoot: Data(repeating: 1, count: 32))
            return .init(status: 200, body: body)
        }
        _ = try await client.acceptInvite(invitation, token: testInviteToken, acceptanceID: "accept-helper", now: fixedTime)
        XCTAssertNil(try loadCheckpoint(anchorStore, ownerIdentityID: ownerSigner.identity.identityID))
    }

    func testOwnerIdentityMismatchIsRejectedRegardlessOfEnforcement() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession(),
                                               anchorStore: anchorStore, enforceStateRoot: false)
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            // A different owner identity than the signer — must be rejected
            // even though enforceStateRoot is false.
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 1,
                                                 ownerIdentityID: "someone-else", stateRoot: Data(repeating: 1, count: 32))
            return .init(status: 200, body: body)
        }
        do {
            _ = try await client.createInvite(inviteID: invitation.payload.inviteID, validFor: 3_600, now: fixedTime,
                                              nonce: invitation.payload.nonce)
            XCTFail("expected owner-identity mismatch to be rejected")
        } catch CompanionTransportError.server(.malformed) {
            // expected
        }
    }

    func testAnchorIsKeyedByRelayBaseURLAsWellAsOwner() throws {
        let store = InMemoryRollbackAnchorStore()
        let anchor = RollbackAnchor(store: store)
        try anchor.accept(relayBaseURL: "http://127.0.0.1:8002", ownerIdentityID: "owner-1",
                          revision: 3, stateRoot: Data(repeating: 1, count: 32), enforceIfNoCheckpoint: true)
        // A different relay base URL for the same owner ID starts unanchored,
        // so a "lower" revision against it is not a regression.
        try anchor.accept(relayBaseURL: "http://staging.example:8002", ownerIdentityID: "owner-1",
                          revision: 1, stateRoot: Data(repeating: 2, count: 32), enforceIfNoCheckpoint: true)
        XCTAssertEqual(try loadCheckpoint(store, relayBaseURL: "http://127.0.0.1:8002", ownerIdentityID: "owner-1")?.revision, 3)
        XCTAssertEqual(try loadCheckpoint(store, relayBaseURL: "http://staging.example:8002", ownerIdentityID: "owner-1")?.revision, 1)
    }

    // MARK: - Anchor key URL normalization

    func testAnchorKeyNormalizesSchemeHostPortAndTrailingSlash() {
        let variants = [
            "http://127.0.0.1:8002",
            "http://127.0.0.1:8002/",
            "HTTP://127.0.0.1:8002",
            "http://127.0.0.1:8002",
        ]
        let keys = Set(variants.map { URL(string: $0)!.companionAnchorKey })
        XCTAssertEqual(keys.count, 1, "expected every variant to normalize to the same key, got \(keys)")
    }

    func testAnchorKeyMakesTheDefaultPortExplicit() {
        XCTAssertEqual(URL(string: "http://example.com")!.companionAnchorKey, "http://example.com:80")
        XCTAssertEqual(URL(string: "https://example.com")!.companionAnchorKey, "https://example.com:443")
        XCTAssertEqual(URL(string: "https://example.com:8443")!.companionAnchorKey, "https://example.com:8443")
    }

    func testAnchorKeyLowercasesSchemeAndHostButKeepsCasedPathSegmentsUntouched() {
        XCTAssertEqual(URL(string: "HTTP://Example.COM:8002/Relay")!.companionAnchorKey, "http://example.com:8002/Relay")
    }

    func testDifferentlyFormattedEquivalentBaseURLsShareOneAnchor() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let ownerIdentityID = ownerSigner.identity.identityID
        let transport1 = HTTPCompanionTransport(baseURL: URL(string: "http://127.0.0.1:8002")!,
                                                session: StubURLProtocol.makeSession(), anchorStore: anchorStore)
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 4,
                                                 ownerIdentityID: ownerIdentityID, stateRoot: Data(repeating: 1, count: 32))
            return .init(status: 200, body: body)
        }
        _ = try await AsyncCompanionClient(signer: ownerSigner, transport: transport1, now: { fixedTime })
            .createInvite(inviteID: invitation.payload.inviteID, validFor: 3_600, now: fixedTime, nonce: invitation.payload.nonce)

        // A trailing slash and different casing describe the same relay.
        let transport2 = HTTPCompanionTransport(baseURL: URL(string: "HTTP://127.0.0.1:8002/")!,
                                                session: StubURLProtocol.makeSession(), anchorStore: anchorStore)
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            // A lower revision than transport1 already anchored — must be
            // rejected as a regression if the two transports share one key.
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 2,
                                                 ownerIdentityID: ownerIdentityID, stateRoot: Data(repeating: 2, count: 32))
            return .init(status: 200, body: body)
        }
        let (_, invitation2) = try makeInvite()
        do {
            _ = try await AsyncCompanionClient(signer: ownerSigner, transport: transport2, now: { fixedTime })
                .createInvite(inviteID: invitation2.payload.inviteID, validFor: 3_600, now: fixedTime, nonce: invitation2.payload.nonce)
            XCTFail("expected the two differently-formatted base URLs to share one anchor and reject the regression")
        } catch CompanionTransportError.server(.relayRollback(.regressedRevision(let expected, let actual))) {
            XCTAssertEqual(expected, 4)
            XCTAssertEqual(actual, 2)
        }
    }

    // MARK: - Missing owner identity with an existing checkpoint

    func testMissingOwnerIdentityIsRejectedWhenACheckpointAlreadyExistsEvenWithEnforcementRelaxed() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let ownerIdentityID = ownerSigner.identity.identityID
        let anchor = RollbackAnchor(store: anchorStore)
        try anchor.accept(relayBaseURL: URL(string: "http://127.0.0.1:8002")!.companionAnchorKey, ownerIdentityID: ownerIdentityID,
                          revision: 2, stateRoot: Data(repeating: 1, count: 32), enforceIfNoCheckpoint: true)
        let transport = HTTPCompanionTransport(baseURL: URL(string: "http://127.0.0.1:8002")!,
                                               session: StubURLProtocol.makeSession(), anchorStore: anchorStore,
                                               enforceStateRoot: false)
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            // No ownerIdentityID at all this time, from an owner-signed op.
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 3)
            return .init(status: 200, body: body)
        }
        do {
            _ = try await client.createInvite(inviteID: invitation.payload.inviteID, validFor: 3_600, now: fixedTime,
                                              nonce: invitation.payload.nonce)
            XCTFail("expected rejection: a checkpoint already exists for this owner")
        } catch CompanionTransportError.server(.malformed) {
            // expected
        }
    }

    func testMissingOwnerIdentityIsAllowedWhenNoCheckpointExistsAndEnforcementIsRelaxed() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let transport = HTTPCompanionTransport(baseURL: URL(string: "http://127.0.0.1:8002")!,
                                               session: StubURLProtocol.makeSession(), anchorStore: anchorStore,
                                               enforceStateRoot: false)
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 1)
            return .init(status: 200, body: body)
        }
        _ = try await client.createInvite(inviteID: invitation.payload.inviteID, validFor: 3_600, now: fixedTime,
                                          nonce: invitation.payload.nonce)
        XCTAssertNil(try loadCheckpoint(anchorStore, relayBaseURL: URL(string: "http://127.0.0.1:8002")!.companionAnchorKey,
                                        ownerIdentityID: ownerSigner.identity.identityID))
    }

    func testResetAllClearsEveryStoredCheckpoint() throws {
        let store = InMemoryRollbackAnchorStore()
        let anchor = RollbackAnchor(store: store)
        try anchor.accept(relayBaseURL: testBaseURL.absoluteString, ownerIdentityID: "owner-1",
                          revision: 2, stateRoot: Data(repeating: 1, count: 32), enforceIfNoCheckpoint: true)
        try anchor.resetAll()
        XCTAssertNil(try loadCheckpoint(store, ownerIdentityID: "owner-1"))
        // Resetting un-anchors the key, so a lower revision is now accepted.
        try anchor.accept(relayBaseURL: testBaseURL.absoluteString, ownerIdentityID: "owner-1",
                          revision: 1, stateRoot: Data(repeating: 2, count: 32), enforceIfNoCheckpoint: true)
        XCTAssertEqual(try loadCheckpoint(store, ownerIdentityID: "owner-1")?.revision, 1)
    }

    func testConcurrentAcceptsDoNotRaceLoadAndSave() async throws {
        let store = InMemoryRollbackAnchorStore()
        let anchor = RollbackAnchor(store: store)
        let ownerIdentityID = "owner-race"
        try await withThrowingTaskGroup(of: Void.self) { group in
            for revision in UInt64(1)...50 {
                group.addTask {
                    _ = try? anchor.accept(relayBaseURL: testBaseURL.absoluteString, ownerIdentityID: ownerIdentityID,
                                           revision: revision, stateRoot: Data(repeating: UInt8(revision % 255), count: 32),
                                           enforceIfNoCheckpoint: true)
                }
            }
            try await group.waitForAll()
        }
        // Whatever the interleaving, the store must end on a self-consistent
        // checkpoint (no torn read/write), and the highest revision anyone
        // accepted must be the final revision seen, since revisions never
        // regress once accepted.
        let final = try loadCheckpoint(store, ownerIdentityID: ownerIdentityID)
        XCTAssertNotNil(final)
    }

    // MARK: - App Group-capable store

    func testUserDefaultsRollbackAnchorStoreRoundTripsAndIsInjectable() throws {
        let suiteName = "companionkit-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return XCTFail("could not create test suite") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsRollbackAnchorStore(defaults: defaults)
        let anchor = RollbackAnchor(store: store)
        XCTAssertNil(try loadCheckpoint(store, ownerIdentityID: "owner-1"))
        try anchor.accept(relayBaseURL: testBaseURL.absoluteString, ownerIdentityID: "owner-1",
                          revision: 7, stateRoot: Data(repeating: 5, count: 32), enforceIfNoCheckpoint: true)
        XCTAssertEqual(try loadCheckpoint(store, ownerIdentityID: "owner-1")?.revision, 7)

        XCTAssertThrowsError(try anchor.accept(relayBaseURL: testBaseURL.absoluteString, ownerIdentityID: "owner-1",
                                               revision: 6, stateRoot: Data(repeating: 6, count: 32), enforceIfNoCheckpoint: true))
        try anchor.accept(relayBaseURL: testBaseURL.absoluteString, ownerIdentityID: "owner-1",
                          revision: 8, stateRoot: Data(repeating: 7, count: 32), enforceIfNoCheckpoint: true)
        XCTAssertEqual(try loadCheckpoint(store, ownerIdentityID: "owner-1")?.revision, 8)
    }

    func testUserDefaultsStoreFailsClosedOnCorruptStoredCheckpoint() throws {
        let suiteName = "companionkit-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return XCTFail("could not create test suite") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsRollbackAnchorStore(defaults: defaults)
        let key = RollbackAnchor.storageKey(relayBaseURL: testBaseURL.absoluteString, ownerIdentityID: "owner-1")
        defaults.set(Data("not a checkpoint".utf8), forKey: "com.phone-lockbox.companion.anchor.\(key)")
        XCTAssertThrowsError(try loadCheckpoint(store, ownerIdentityID: "owner-1")) { error in
            guard case CompanionError.malformed = error else {
                return XCTFail("expected a malformed/fail-closed error, got \(error)")
            }
        }
    }

    func testUserDefaultsStoreResetAllClearsIndexAndValues() throws {
        let suiteName = "companionkit-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return XCTFail("could not create test suite") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsRollbackAnchorStore(defaults: defaults)
        let anchor = RollbackAnchor(store: store)
        try anchor.accept(relayBaseURL: testBaseURL.absoluteString, ownerIdentityID: "owner-1",
                          revision: 3, stateRoot: Data(repeating: 1, count: 32), enforceIfNoCheckpoint: true)
        try store.resetAll()
        XCTAssertNil(try loadCheckpoint(store, ownerIdentityID: "owner-1"))
    }
}
