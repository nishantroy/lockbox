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

private func makeInvite() throws -> (DeviceSigner, Invitation) {
    let ownerKeys = InMemoryDeviceKeyStore()
    let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
    let payload = try InvitePayload(inviteID: "invite-http", owner: ownerSigner.identity, issuedAt: fixedTime,
                                    expiresAt: fixedTime.addingTimeInterval(3_600), nonce: Data(repeating: 9, count: 24))
    let signature = try ownerSigner.sign(domain: "\(CompanionCanonical.version).invite", fields: payload.signingFields())
    return (ownerSigner, try Invitation(payload: payload, signature: signature))
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
                                          transport: HTTPCompanionTransport(baseURL: URL(string: "http://127.0.0.1:8002")!,
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
        let transport = HTTPCompanionTransport(baseURL: URL(string: "http://127.0.0.1:8002")!, session: StubURLProtocol.makeSession())
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

    func testHealthEndpointReportsOk() async throws {
        let transport = HTTPCompanionTransport(baseURL: URL(string: "http://127.0.0.1:8002")!, session: StubURLProtocol.makeSession())
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
        let transport = HTTPCompanionTransport(baseURL: URL(string: "http://127.0.0.1:8002")!, session: StubURLProtocol.makeSession())
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

    func test409MapsToOperationConflictWhenCodeIndicatesIdempotencyMismatch() async throws {
        try await expectServerError(status: 409, code: "operation_conflict", expected: .operationConflict)
    }

    func test413MapsToMalformedPayloadTooLarge() async throws {
        try await expectServerError(status: 413, code: "malformed", expected: .malformed("relay rejected the operation"))
    }

    func test429MapsToRateLimited() async throws {
        try await expectServerError(status: 429, code: "rate_limited", expected: .rateLimited)
    }

    func testUnknownErrorCodeStillProducesATypedMalformedError() async throws {
        try await expectServerError(status: 400, code: "totally_new_code",
                                    expected: .malformed("unrecognized relay error: totally_new_code"))
    }

    func test5xxIsRetryableUnavailable() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let transport = HTTPCompanionTransport(baseURL: URL(string: "http://127.0.0.1:8002")!, session: StubURLProtocol.makeSession())
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
        let transport = HTTPCompanionTransport(baseURL: URL(string: "http://127.0.0.1:8002")!, session: StubURLProtocol.makeSession())
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
        let transport = HTTPCompanionTransport(baseURL: URL(string: "http://127.0.0.1:8002")!,
                                               session: StubURLProtocol.makeSession(), anchorStore: anchorStore)
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
        let checkpoint = anchorStore.loadCheckpoint(ownerIdentityID: ownerIdentityID)
        XCTAssertEqual(checkpoint?.revision, 1)
        XCTAssertEqual(checkpoint?.stateRoot, root1)
    }

    func testAnchorRejectsLowerRevisionThanAlreadyAccepted() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let ownerIdentityID = ownerSigner.identity.identityID
        _ = try anchorStore.saveCheckpoint(CompanionCheckpoint(ownerIdentityID: ownerIdentityID,
                                                               revision: 5, stateRoot: Data(repeating: 2, count: 32)))
        let transport = HTTPCompanionTransport(baseURL: URL(string: "http://127.0.0.1:8002")!,
                                               session: StubURLProtocol.makeSession(), anchorStore: anchorStore)
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
        let checkpoint = anchorStore.loadCheckpoint(ownerIdentityID: ownerIdentityID)
        XCTAssertEqual(checkpoint?.revision, 5)
    }

    func testAnchorRejectsConflictingRootAtSameRevision() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let ownerIdentityID = ownerSigner.identity.identityID
        let originalRoot = Data(repeating: 4, count: 32)
        _ = try anchorStore.saveCheckpoint(CompanionCheckpoint(ownerIdentityID: ownerIdentityID,
                                                               revision: 2, stateRoot: originalRoot))
        let transport = HTTPCompanionTransport(baseURL: URL(string: "http://127.0.0.1:8002")!,
                                               session: StubURLProtocol.makeSession(), anchorStore: anchorStore)
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
        let checkpoint = anchorStore.loadCheckpoint(ownerIdentityID: ownerIdentityID)
        XCTAssertEqual(checkpoint?.stateRoot, originalRoot, "unchanged on a rejected fork")
    }

    func testAnchorEnforcementRejectsMissingStateRootByDefault() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let transport = HTTPCompanionTransport(baseURL: URL(string: "http://127.0.0.1:8002")!,
                                               session: StubURLProtocol.makeSession(), anchorStore: anchorStore)
        let client = AsyncCompanionClient(signer: ownerSigner, transport: transport, now: { fixedTime })
        StubURLProtocol.handler = { request in
            let signed = try! JSONDecoder().decode(SignedOperation.self, from: bodyData(from: request))
            let body = try! encodedRelayResponse(operationID: signed.operationID, revision: 1)
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

    func testAnchorEnforcementCanBeRelaxedForInterimIntegration() async throws {
        let (ownerSigner, invitation) = try makeInvite()
        let anchorStore = InMemoryRollbackAnchorStore()
        let ownerIdentityID = ownerSigner.identity.identityID
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
        XCTAssertNil(anchorStore.loadCheckpoint(ownerIdentityID: ownerIdentityID))
    }

    // MARK: - App Group-capable store

    func testUserDefaultsRollbackAnchorStoreRoundTripsAndIsInjectable() throws {
        let suiteName = "companionkit-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return XCTFail("could not create test suite") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsRollbackAnchorStore(defaults: defaults)
        XCTAssertNil(store.loadCheckpoint(ownerIdentityID: "owner-1"))
        let checkpoint = try CompanionCheckpoint(ownerIdentityID: "owner-1", revision: 7, stateRoot: Data(repeating: 5, count: 32))
        try store.saveCheckpoint(checkpoint)
        XCTAssertEqual(store.loadCheckpoint(ownerIdentityID: "owner-1"), checkpoint)

        let anchor = RollbackAnchor(store: store)
        XCTAssertThrowsError(try anchor.accept(ownerIdentityID: "owner-1", revision: 6, stateRoot: Data(repeating: 6, count: 32)))
        try anchor.accept(ownerIdentityID: "owner-1", revision: 8, stateRoot: Data(repeating: 7, count: 32))
        XCTAssertEqual(store.loadCheckpoint(ownerIdentityID: "owner-1")?.revision, 8)
    }
}
