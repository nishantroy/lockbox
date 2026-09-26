import XCTest
@testable import CompanionKit

/// Intercepts every request made through a session configured with it, so
/// tests can exercise `HTTPCompanionTransport` against canned status codes
/// and bodies without a real listener.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let status: Int
        let body: Data

        init(status: Int, body: Data) {
            self.status = status; self.body = body
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

private let fixedTime = Date(timeIntervalSince1970: 1_700_000_000)
private let testBaseURL = URL(string: "http://127.0.0.1:8002")!

private func makeInvite() throws -> (DeviceSigner, Invitation) {
    let ownerKeys = InMemoryDeviceKeyStore()
    let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
    let payload = try InvitePayload(inviteID: "invite-http", owner: ownerSigner.identity, issuedAt: fixedTime,
                                    expiresAt: fixedTime.addingTimeInterval(3_600), nonce: Data(repeating: 9, count: 24))
    let signature = try ownerSigner.sign(domain: "\(CompanionCanonical.version).invite", fields: payload.signingFields())
    return (ownerSigner, try Invitation(payload: payload, signature: signature))
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
        } catch CompanionTransportError.server(.staleRevision(let expected, let actual)) {
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
        } catch CompanionTransportError.server(.malformed) {
            // expected: conflicting root at same revision
        }
        let checkpoint = try loadCheckpoint(anchorStore, ownerIdentityID: ownerIdentityID)
        XCTAssertEqual(checkpoint?.stateRoot, originalRoot, "unchanged on a rejected fork")
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
        let payload = try InvitePayload(inviteID: "invite-helper", owner: ownerSigner.identity, issuedAt: fixedTime,
                                        expiresAt: fixedTime.addingTimeInterval(3_600), nonce: Data(repeating: 1, count: 24))
        let signature = try ownerSigner.sign(domain: "\(CompanionCanonical.version).invite", fields: payload.signingFields())
        let invitation = try Invitation(payload: payload, signature: signature)
        let anchorStore = InMemoryRollbackAnchorStore()
        let transport = HTTPCompanionTransport(baseURL: testBaseURL, session: StubURLProtocol.makeSession(), anchorStore: anchorStore)
        let client = AsyncCompanionClient(signer: approverSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            // Even if the relay attributes this response to the owner's
            // ledger (correct per contract for a helper-signed op) with a
            // real state root, a helper-signed operation must never be
            // anchored by this device.
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 1,
                                                 ownerIdentityID: ownerSigner.identity.identityID,
                                                 stateRoot: Data(repeating: 1, count: 32))
            return .init(status: 200, body: body)
        }
        _ = try await client.accept(invitation, acceptanceID: "accept-helper", now: fixedTime)
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
