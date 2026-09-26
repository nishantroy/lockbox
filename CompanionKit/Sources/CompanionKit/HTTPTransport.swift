import Foundation

// MARK: - Async transport protocol

/// Additive async sibling of `CompanionTransport`. It exists so a real
/// network transport can use Swift concurrency without breaking the existing
/// synchronous protocol, `InMemoryCompanionRelay`, or any existing test that
/// depends on them. Nothing in this file changes synchronous behavior.
public protocol AsyncCompanionTransport: Sendable {
    /// Reads the current bilateral-consent generation before a request is
    /// signed. The HTTP relay (v1) has no dedicated consent-read endpoint, so
    /// `HTTPCompanionTransport` does not implement this; callers must supply
    /// the last known `RelationshipConsent` (returned by a prior grant/accept
    /// call) directly to `AsyncCompanionClient.requestUnlock`.
    func consent(relationshipID: String) async throws -> RelationshipConsent

    /// A successful response includes the committed owner-scoped revision
    /// (and, when the relay populates it, a state root for rollback/fork
    /// detection). Implementations must persist the response receipt
    /// atomically with the command before returning it.
    func submit(_ operation: SignedOperation) async throws -> RelayResponse

    /// Foreground fetch is authoritative. Notification/APNs delivery is
    /// intentionally outside this package and never authorizes an action.
    func fetchInbox(_ operation: SignedOperation) async throws -> InboxResponse
}

public extension AsyncCompanionTransport {
    func consent(relationshipID: String) async throws -> RelationshipConsent {
        throw CompanionError.notFound
    }
}

// MARK: - Transport error code mapping

public extension CompanionError {
    /// Reconstructs a `CompanionError` from the wire code produced by
    /// `transportCode`. Error bodies are `{ "error": "<code>" }` only, so
    /// associated values that are not carried on the wire (for example the
    /// specific revisions in `staleRevision`) come back as `0`; callers that
    /// need the exact expected/actual revision should read it from the
    /// enclosing `RelayResponse`/anchor instead of this reconstructed error.
    static func fromTransportCode(_ code: String) -> CompanionError {
        switch code {
        case "stale_revision": return .staleRevision(expected: 0, actual: 0)
        case "operation_conflict": return .operationConflict
        case "missing_operation_revision": return .missingOperationRevision
        case "invalid_signature": return .invalidSignature
        case "unknown_identity": return .unknownIdentity
        case "unauthorized": return .unauthorized
        case "revoked_pairing": return .revokedPairing
        case "expired": return .expired
        case "replay": return .replay
        case "stale_session": return .staleSession
        case "wrong_target": return .wrongTarget
        case "wrong_verification_code": return .wrongVerificationCode
        case "rate_limited": return .rateLimited
        case "key_unavailable": return .keyUnavailable
        case "already_paired": return .alreadyPaired
        case "not_found": return .notFound
        case "invalid_transition": return .invalidTransition
        case "unsupported_scope": return .unsupportedScope
        case "consent_required": return .consentRequired
        case "malformed": return .malformed("relay rejected the operation")
        default: return .malformed("unrecognized relay error: \(code)")
        }
    }
}

// MARK: - Rollback anchor

/// Storage for the per-owner `(revision, stateRoot)` rollback/fork anchor.
/// The embedding must keep this in trusted, monotonic, App Group-capable
/// storage (see `docs/companion-security.md`); it must not be derived from,
/// or copied beside, the mutable local cache it is meant to protect.
public protocol RollbackAnchorStore: Sendable {
    func loadCheckpoint(ownerIdentityID: String) -> CompanionCheckpoint?
    func saveCheckpoint(_ checkpoint: CompanionCheckpoint) throws
}

/// Reference/test adapter. Not durable across process restarts; production
/// code should use `UserDefaultsRollbackAnchorStore` with an App Group suite.
public final class InMemoryRollbackAnchorStore: RollbackAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CompanionCheckpoint] = [:]

    public init() {}

    public func loadCheckpoint(ownerIdentityID: String) -> CompanionCheckpoint? {
        lock.lock(); defer { lock.unlock() }
        return values[ownerIdentityID]
    }

    public func saveCheckpoint(_ checkpoint: CompanionCheckpoint) throws {
        lock.lock(); defer { lock.unlock() }
        values[checkpoint.ownerIdentityID] = checkpoint
    }
}

/// App Group-capable checkpoint storage. Inject any `UserDefaults` instance
/// (an App Group suite on device, or an ephemeral suite in tests) so the
/// store never depends on `UserDefaults.standard`.
public final class UserDefaultsRollbackAnchorStore: RollbackAnchorStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func loadCheckpoint(ownerIdentityID: String) -> CompanionCheckpoint? {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.key(ownerIdentityID)) else { return nil }
        return try? JSONDecoder().decode(CompanionCheckpoint.self, from: data)
    }

    public func saveCheckpoint(_ checkpoint: CompanionCheckpoint) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(checkpoint)
        lock.lock(); defer { lock.unlock() }
        defaults.set(data, forKey: Self.key(checkpoint.ownerIdentityID))
    }

    private static func key(_ ownerIdentityID: String) -> String {
        "com.phone-lockbox.companion.anchor.\(ownerIdentityID)"
    }
}

/// Validates an incoming `(revision, stateRoot)` pair against the last
/// accepted checkpoint for that owner and persists the result. A lower
/// revision, or a different root at an already-seen revision, is rejected —
/// this is the on-device rollback/fork detector described in
/// `docs/r5-relay-plan.md` (Architecture: "Independent monotonic anchor").
public struct RollbackAnchor: Sendable {
    private let store: any RollbackAnchorStore

    public init(store: any RollbackAnchorStore) {
        self.store = store
    }

    public func currentCheckpoint(ownerIdentityID: String) -> CompanionCheckpoint? {
        store.loadCheckpoint(ownerIdentityID: ownerIdentityID)
    }

    @discardableResult
    public func accept(ownerIdentityID: String, revision: UInt64, stateRoot: Data) throws -> CompanionCheckpoint {
        if let previous = store.loadCheckpoint(ownerIdentityID: ownerIdentityID) {
            guard revision >= previous.revision else {
                throw CompanionError.staleRevision(expected: previous.revision, actual: revision)
            }
            if revision == previous.revision {
                guard stateRoot == previous.stateRoot else {
                    throw CompanionError.malformed("conflicting relay state root at revision \(revision)")
                }
                return previous
            }
        }
        let checkpoint = try CompanionCheckpoint(ownerIdentityID: ownerIdentityID, revision: revision, stateRoot: stateRoot)
        try store.saveCheckpoint(checkpoint)
        return checkpoint
    }
}

// MARK: - HTTP transport

/// `URLSession`-based implementation of the v1 HTTP API in
/// `docs/r5-relay-plan.md`: `POST /v1/operations`, `POST /v1/inbox`,
/// `GET /v1/health`. Bodies are JSON encoded by `JSONEncoder` with
/// `.sortedKeys` (matching every other encoder in this package); binary
/// fields use the Swift `Data` default (base64). Server errors are
/// `{ "error": "<code>" }` and are mapped to `CompanionTransportError`.
public struct HTTPCompanionTransport: AsyncCompanionTransport {
    public let baseURL: URL
    private let session: URLSession
    private let anchor: RollbackAnchor?
    private let enforceStateRoot: Bool
    private let fallbackOwnerIdentityID: (@Sendable () -> String?)?

    /// - Parameters:
    ///   - baseURL: Relay base URL, for example `http://127.0.0.1:8002`.
    ///   - session: Injectable for tests (a `URLProtocol`-stubbed session).
    ///   - anchorStore: When supplied, every accepted response is checked
    ///     against, and folded into, the rollback anchor before being
    ///     returned to the caller.
    ///   - enforceStateRoot: When `true` (the default), a response that is
    ///     missing a state root or owner identity is rejected once an anchor
    ///     store is configured, so a relay that has not yet implemented
    ///     anchoring cannot silently disable rollback protection. Set to
    ///     `false` only for interim integration testing against a relay
    ///     build that does not populate these fields yet.
    ///   - fallbackOwnerIdentityID: Used only if a response omits
    ///     `ownerIdentityID` (the current `RelayResponse` shape may, since
    ///     the field was added additively in this slice).
    public init(baseURL: URL, session: URLSession = .shared, anchorStore: (any RollbackAnchorStore)? = nil,
                enforceStateRoot: Bool = true, fallbackOwnerIdentityID: (@Sendable () -> String?)? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.anchor = anchorStore.map(RollbackAnchor.init(store:))
        self.enforceStateRoot = enforceStateRoot
        self.fallbackOwnerIdentityID = fallbackOwnerIdentityID
    }

    public func submit(_ operation: SignedOperation) async throws -> RelayResponse {
        let response: RelayResponse = try await post(path: "v1/operations", body: operation)
        guard response.operationID == operation.operationID else {
            throw CompanionTransportError.malformedResponse
        }
        try validateAnchor(revision: response.revision, stateRoot: response.stateRoot,
                            ownerIdentityID: response.ownerIdentityID)
        return response
    }

    public func fetchInbox(_ operation: SignedOperation) async throws -> InboxResponse {
        let response: InboxResponse = try await post(path: "v1/inbox", body: operation)
        try validateAnchor(revision: response.revision, stateRoot: response.stateRoot,
                            ownerIdentityID: response.ownerIdentityID)
        return response
    }

    /// `GET /v1/health` → `{"ok":true}`. Not part of `AsyncCompanionTransport`
    /// (health has no signed operation and no relay authority), but exposed
    /// for a Settings "check connection" affordance.
    public func health() async throws -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/health"))
        request.httpMethod = "GET"
        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw try transportError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        }
        struct Health: Decodable { let ok: Bool }
        return (try? JSONDecoder().decode(Health.self, from: data))?.ok ?? false
    }

    private func validateAnchor(revision: UInt64, stateRoot: Data?, ownerIdentityID: String?) throws {
        guard let anchor else { return }
        guard let stateRoot else {
            if enforceStateRoot { throw CompanionTransportError.server(.malformed("relay response is missing a state root")) }
            return
        }
        guard let ownerID = ownerIdentityID ?? fallbackOwnerIdentityID?() else {
            if enforceStateRoot { throw CompanionTransportError.server(.malformed("relay response is missing an owner identity for anchoring")) }
            return
        }
        do {
            try anchor.accept(ownerIdentityID: ownerID, revision: revision, stateRoot: stateRoot)
        } catch let error as CompanionError {
            throw CompanionTransportError.server(error)
        }
    }

    private func post<Body: Encodable, ResponseBody: Decodable>(path: String, body: Body) async throws -> ResponseBody {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else { throw CompanionTransportError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw try transportError(status: http.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw CompanionTransportError.malformedResponse
        }
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            throw error.code == .timedOut ? CompanionTransportError.timedOut : CompanionTransportError.unavailable
        } catch {
            throw CompanionTransportError.unavailable
        }
    }

    private func transportError(status: Int, data: Data) throws -> CompanionTransportError {
        struct ErrorBody: Decodable { let error: String }
        let decodedCode = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
        switch status {
        case 400, 401, 403, 409, 413, 429:
            return .server(.fromTransportCode(decodedCode ?? Self.defaultCode(for: status)))
        case 500...599:
            return .unavailable
        default:
            return .malformedResponse
        }
    }

    private static func defaultCode(for status: Int) -> String {
        switch status {
        case 400: return "malformed"
        case 401: return "invalid_signature"
        case 403: return "unauthorized"
        case 409: return "operation_conflict"
        case 413: return "malformed"
        case 429: return "rate_limited"
        default: return "malformed"
        }
    }
}

// MARK: - Async client

/// Async sibling of `CompanionClient`, built against `AsyncCompanionTransport`
/// instead of the synchronous `CompanionTransport`. It intentionally has no
/// `useApproval` — Slice B1 never consumes an approval into the lock
/// lifecycle; that is Slice B2, reviewed separately.
public struct AsyncCompanionClient: Sendable {
    public let signer: DeviceSigner
    public let transport: any AsyncCompanionTransport
    public let now: @Sendable () -> Date

    public init(signer: DeviceSigner, transport: any AsyncCompanionTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.signer = signer
        self.transport = transport
        self.now = now
    }

    private func submit<T: Encodable>(_ kind: String, _ body: T) async throws -> RelayResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(body)
        let operationID = operationIdentifier(kind: kind, signer: signer.identity, body: data)
        let unsigned = try SignedOperation(operationID: operationID, expectedRevision: nil,
                                           kind: kind, signer: signer.identity, body: data,
                                           signature: Data(repeating: 0, count: 64))
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).operation",
                                        fields: unsigned.signingFields())
        let operation = try SignedOperation(operationID: operationID, expectedRevision: nil,
                                            kind: kind, signer: signer.identity, body: data,
                                            signature: signature)
        return try await transport.submit(operation).validated(for: operation).result
    }

    public func createInvite(inviteID: String, validFor: TimeInterval, now: Date, nonce: Data? = nil) async throws -> Invitation {
        guard signer.identity.role == .owner, validFor > 0, validFor <= CompanionLimits.maxInviteLifetime else { throw CompanionError.unauthorized }
        let payload = try InvitePayload(inviteID: inviteID, owner: signer.identity, issuedAt: now,
                                        expiresAt: now.addingTimeInterval(validFor), nonce: nonce ?? randomNonce())
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).invite", fields: payload.signingFields())
        let invitation = try Invitation(payload: payload, signature: signature)
        _ = try await submit("invite", invitation)
        return invitation
    }

    public func accept(_ invitation: Invitation, acceptanceID: String, now: Date) async throws -> PairingAcceptance {
        guard signer.identity.role == .trustedApprover else { throw CompanionError.unauthorized }
        try invitation.validate(at: now)
        let acceptance = try PairingAcceptance(acceptanceID: acceptanceID, invite: invitation.payload, approver: signer.identity, issuedAt: now)
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).acceptance", fields: acceptance.signingFields())
        _ = try await submit("accept", SignedAcceptance(acceptance: acceptance, signature: signature))
        return acceptance
    }

    public func confirm(_ acceptance: PairingAcceptance, verificationCode: String, now: Date) async throws -> Pairing {
        guard signer.identity == acceptance.owner, signer.identity.role == .owner else { throw CompanionError.unauthorized }
        let confirmation = try PairingConfirmation(acceptance: acceptance, owner: signer.identity, verificationCode: verificationCode, issuedAt: now)
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).confirmation", fields: confirmation.signingFields())
        guard case let .pairing(pairing) = try await submit("confirm", SignedConfirmation(confirmation: confirmation, signature: signature)) else {
            throw CompanionError.malformed("relay response")
        }
        return pairing
    }

    public func publishSession(_ session: ActiveSession) async throws -> ActiveSession {
        guard signer.identity.role == .owner, session.owner == signer.identity else { throw CompanionError.unauthorized }
        guard case let .session(value) = try await submit("session", session) else { throw CompanionError.malformed("relay response") }
        return value
    }

    public func grantScopes(pairing: Pairing, scopes: [CompanionScope], nonce: Data? = nil) async throws -> RelationshipConsent {
        guard signer.identity == pairing.owner else { throw CompanionError.unauthorized }
        let mutation = try RelationshipConsentMutation(
            relationshipID: pairing.pairingID, pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
            owner: pairing.owner, approver: pairing.approver, action: .ownerGrant,
            scopes: try CompanionScopeSet(scopes), nonce: nonce ?? randomNonce(), issuedAt: now())
        guard case let .consent(value) = try await submit("consent", mutation) else { throw CompanionError.malformed("relay response") }
        return value
    }

    public func acceptScopes(pairing: Pairing, scopes: [CompanionScope], nonce: Data? = nil) async throws -> RelationshipConsent {
        guard signer.identity == pairing.approver else { throw CompanionError.unauthorized }
        let mutation = try RelationshipConsentMutation(
            relationshipID: pairing.pairingID, pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
            owner: pairing.owner, approver: pairing.approver, action: .approverAccept,
            scopes: try CompanionScopeSet(scopes), nonce: nonce ?? randomNonce(), issuedAt: now())
        guard case let .consent(value) = try await submit("consent", mutation) else { throw CompanionError.malformed("relay response") }
        return value
    }

    public func revokeScopes(pairing: Pairing, scopes: [CompanionScope], nonce: Data? = nil) async throws -> RelationshipConsent {
        let action: ConsentMutationAction
        if signer.identity == pairing.owner { action = .ownerRevoke }
        else if signer.identity == pairing.approver { action = .approverRevoke }
        else { throw CompanionError.unauthorized }
        let mutation = try RelationshipConsentMutation(
            relationshipID: pairing.pairingID, pairingID: pairing.pairingID, pairEpoch: pairing.epoch,
            owner: pairing.owner, approver: pairing.approver, action: action,
            scopes: try CompanionScopeSet(scopes), nonce: nonce ?? randomNonce(), issuedAt: now())
        guard case let .consent(value) = try await submit("consent", mutation) else { throw CompanionError.malformed("relay response") }
        return value
    }

    /// Targets are explicit identities, each paired to the exact pairing and
    /// bilateral consent generation the caller currently knows about (there
    /// is no HTTP consent-read endpoint in v1; the caller supplies the
    /// `RelationshipConsent` last returned by a grant/accept call).
    public func requestUnlock(requestID: String, pairings: [Pairing], consents: [RelationshipConsent],
                              session: ActiveSession, targets: [String], validFor: TimeInterval) async throws -> TrustedRequest {
        guard !pairings.isEmpty, pairings.count == targets.count, pairings.count == consents.count,
              signer.identity == pairings[0].owner, Set(targets).count == targets.count,
              zip(pairings, targets).allSatisfy({ $0.0.owner == signer.identity && $0.0.approver.identityID == $0.1 }) else {
            throw CompanionError.wrongTarget
        }
        let bindings = try zip(pairings, consents).map { pairing, consent -> RequestTargetBinding in
            guard consent.pairingID == pairing.pairingID, consent.pairEpoch == pairing.epoch,
                  consent.generation > 0, consent.authorizes(.approveEarlyEnd) else {
                throw CompanionError.consentRequired
            }
            return try RequestTargetBinding(pairing: pairing, consentGeneration: consent.generation)
        }
        let createdAt = now()
        let request = try TrustedRequest(requestID: requestID, owner: signer.identity, targetBindings: bindings,
                                         session: session, message: nil, createdAt: createdAt,
                                         expiresAt: createdAt.addingTimeInterval(validFor))
        guard case let .request(value) = try await submit("request", request) else { throw CompanionError.malformed("relay response") }
        return value
    }

    public func requestUnlock(requestID: String, pairing: Pairing, consent: RelationshipConsent, session: ActiveSession,
                              target: String, validFor: TimeInterval) async throws -> TrustedRequest {
        try await requestUnlock(requestID: requestID, pairings: [pairing], consents: [consent], session: session,
                                targets: [target], validFor: validFor)
    }

    public func submitApproval(request: TrustedRequest, pairing: Pairing, decision: ApproverDecision,
                               approvalID: String = UUID().uuidString, nonce: Data? = nil) async throws -> Approval {
        guard signer.identity == pairing.approver else { throw CompanionError.unauthorized }
        guard let binding = request.binding(for: signer.identity.identityID),
              binding.pairingID == pairing.pairingID, binding.pairEpoch == pairing.epoch,
              binding.consentGeneration > 0 else { throw CompanionError.wrongTarget }
        let unsigned = Approval(approvalID: approvalID, requestID: request.requestID, pairingID: pairing.pairingID,
                                pairEpoch: pairing.epoch, sessionID: request.sessionID, activeSetID: request.activeSetID,
                                approver: signer.identity, decision: decision, issuedAt: now(),
                                consentGeneration: binding.consentGeneration,
                                nonce: nonce ?? randomNonce(), signature: Data())
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).approval", fields: unsigned.signingFields())
        let approval = Approval(approvalID: unsigned.approvalID, requestID: unsigned.requestID, pairingID: unsigned.pairingID,
                               pairEpoch: unsigned.pairEpoch, sessionID: unsigned.sessionID, activeSetID: unsigned.activeSetID,
                               approver: unsigned.approver, decision: unsigned.decision, issuedAt: unsigned.issuedAt,
                               consentGeneration: unsigned.consentGeneration, nonce: unsigned.nonce, signature: signature)
        guard case let .approval(value) = try await submit("approval", approval) else { throw CompanionError.malformed("relay response") }
        return value
    }

    public func cancel(_ request: TrustedRequest) async throws {
        guard signer.identity == request.owner else { throw CompanionError.unauthorized }
        _ = try await submit("cancel", RequestReference(requestID: request.requestID))
    }

    public func revoke(_ pairing: Pairing) async throws {
        guard signer.identity == pairing.owner else { throw CompanionError.unauthorized }
        _ = try await submit("revoke", PairingReference(pairingID: pairing.pairingID, epoch: pairing.epoch))
    }

    public func fetchInbox() async throws -> [TrustedRequest] {
        let query = InboxQuery(identityID: signer.identity.identityID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(query)
        let operationID = operationIdentifier(kind: "inbox", signer: signer.identity, body: body)
        let unsigned = try SignedOperation(operationID: operationID, expectedRevision: nil,
                                           kind: "inbox", signer: signer.identity, body: body,
                                           signature: Data(repeating: 0, count: 64))
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).operation",
                                        fields: unsigned.signingFields())
        let operation = try SignedOperation(operationID: operationID, expectedRevision: nil,
                                            kind: "inbox", signer: signer.identity, body: body,
                                            signature: signature)
        let response = try await transport.fetchInbox(operation)
        guard response.ownerIdentityID == signer.identity.identityID else {
            throw CompanionError.malformed("inbox response owner mismatch")
        }
        return response.requests
    }
}
