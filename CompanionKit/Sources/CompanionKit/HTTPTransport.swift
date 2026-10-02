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
    /// call, or by a prior inbox fetch's `consents`) directly to
    /// `AsyncCompanionClient.requestUnlock`.
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
    /// Reconstructs a `CompanionError` from the wire code produced by the
    /// relay. Codes mirror both `CompanionError.transportCode` and
    /// `DurableRelayError` (the durable relay's own vocabulary — see
    /// `CompanionRelayService/Sources/CompanionRelayService/DurableOperation.swift`),
    /// since the deployed relay's reducer is a port of both. Error bodies are
    /// `{ "error": "<code>" }` only, so associated values that are not
    /// carried on the wire (for example the specific revisions in
    /// `staleRevision`) come back as `0`; callers that need the exact
    /// expected/actual revision should read it from the enclosing
    /// `RelayResponse`/anchor instead of this reconstructed error.
    static func fromTransportCode(_ code: String) -> CompanionError {
        switch code {
        // CompanionError's own vocabulary.
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
        // DurableRelayError's vocabulary (the durable relay's own error
        // enum). None of these have a distinct CompanionError case, so they
        // map to `.malformed` with a code-specific, distinguishable message
        // rather than collapsing into a single generic string.
        case "invalid_envelope": return .malformed("invalid operation envelope")
        case "invalid_operation_id": return .malformed("invalid operation ID")
        case "idempotency_conflict": return .operationConflict
        case "unknown_owner": return .unknownIdentity
        case "ambiguous_owner": return .malformed("ambiguous owner")
        case "response_corrupt": return .malformed("relay response is corrupt")
        case "revision_overflow": return .malformed("revision exhausted")
        case "epoch_overflow": return .malformed("epoch exhausted")
        case "unsupported_operation": return .malformed("unsupported operation")
        case "mutation_changed_revision": return .malformed("mutation changed revision unexpectedly")
        case "payload_too_large": return .malformed("payload too large")
        default: return .malformed("unrecognized relay error: \(code)")
        }
    }
}

// MARK: - Rollback anchor

/// Storage for the per-`(relay base URL, owner)` rollback/fork anchor. The
/// embedding must keep this in trusted, monotonic, App Group-capable storage
/// (see `docs/companion-security.md`); it must not be derived from, or
/// copied beside, the mutable local cache it is meant to protect.
///
/// `withCheckpoint` is the only mutating entry point so an implementation can
/// make "load current value, decide, save new value" atomic under one lock —
/// `RollbackAnchor` relies on that to avoid a load/decide/save race between
/// concurrent callers.
public protocol RollbackAnchorStore: Sendable {
    /// Loads the current checkpoint for `key` (or `nil` if none exists yet),
    /// passes it to `mutate`, and — if `mutate` returns a non-nil checkpoint —
    /// persists that checkpoint before returning `mutate`'s result. The whole
    /// sequence must happen under one lock. A stored checkpoint that fails to
    /// decode must throw (fail closed), never silently read back as `nil`.
    func withCheckpoint<T: Sendable>(forKey key: String, _ mutate: (CompanionCheckpoint?) throws -> (T, CompanionCheckpoint?)) throws -> T

    /// Deletes every stored checkpoint. Used only by an explicit developer
    /// action ("Reset relay anchors"); never called from ordinary request
    /// handling.
    func resetAll() throws
}

/// Reference/test adapter. Not durable across process restarts; production
/// code should use `UserDefaultsRollbackAnchorStore` with an App Group suite.
public final class InMemoryRollbackAnchorStore: RollbackAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CompanionCheckpoint] = [:]

    public init() {}

    public func withCheckpoint<T: Sendable>(forKey key: String, _ mutate: (CompanionCheckpoint?) throws -> (T, CompanionCheckpoint?)) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let (result, newValue) = try mutate(values[key])
        if let newValue { values[key] = newValue }
        return result
    }

    public func resetAll() throws {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
    }
}

/// App Group-capable checkpoint storage. Inject any `UserDefaults` instance
/// (an App Group suite on device, or an ephemeral suite in tests) so the
/// store never depends on `UserDefaults.standard`.
public final class UserDefaultsRollbackAnchorStore: RollbackAnchorStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let keyPrefix = "com.phone-lockbox.companion.anchor."
    private static let indexKey = "com.phone-lockbox.companion.anchor.index"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func withCheckpoint<T: Sendable>(forKey key: String, _ mutate: (CompanionCheckpoint?) throws -> (T, CompanionCheckpoint?)) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let storageKey = Self.keyPrefix + key
        let current: CompanionCheckpoint?
        if let data = defaults.data(forKey: storageKey) {
            // A corrupt stored checkpoint must fail closed: it must never be
            // treated as "no anchor yet", since that would silently disable
            // rollback protection for a key that was already anchored.
            guard let decoded = try? JSONDecoder().decode(CompanionCheckpoint.self, from: data) else {
                throw CompanionError.malformed("stored companion relay anchor is corrupt")
            }
            current = decoded
        } else {
            current = nil
        }
        let (result, newValue) = try mutate(current)
        if let newValue {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            defaults.set(try encoder.encode(newValue), forKey: storageKey)
            var index = Set((defaults.array(forKey: Self.indexKey) as? [String]) ?? [])
            if index.insert(key).inserted {
                defaults.set(Array(index), forKey: Self.indexKey)
            }
        }
        return result
    }

    public func resetAll() throws {
        lock.lock(); defer { lock.unlock() }
        let index = (defaults.array(forKey: Self.indexKey) as? [String]) ?? []
        for key in index { defaults.removeObject(forKey: Self.keyPrefix + key) }
        defaults.removeObject(forKey: Self.indexKey)
    }
}

/// Validates an incoming `(revision, stateRoot)` pair against the last
/// accepted checkpoint for `(relayBaseURL, ownerIdentityID)` and persists the
/// result — the on-device rollback/fork detector described in
/// `docs/r5-relay-plan.md` (Architecture: "Independent monotonic anchor").
/// Keying by relay base URL as well as owner ID keeps a dev/staging relay
/// from colliding with a production one that happens to reuse an owner ID.
public struct RollbackAnchor: Sendable {
    private let store: any RollbackAnchorStore

    public init(store: any RollbackAnchorStore) {
        self.store = store
    }

    static func storageKey(relayBaseURL: String, ownerIdentityID: String) -> String {
        "\(relayBaseURL)#\(ownerIdentityID)"
    }

    /// Reads the current checkpoint for `(relayBaseURL, ownerIdentityID)`
    /// without mutating it. Uses the same atomic, fail-closed-on-corruption
    /// path as `accept`.
    public func currentCheckpoint(relayBaseURL: String, ownerIdentityID: String) throws -> CompanionCheckpoint? {
        let key = Self.storageKey(relayBaseURL: relayBaseURL, ownerIdentityID: ownerIdentityID)
        return try store.withCheckpoint(forKey: key) { current in (current, nil) }
    }

    /// - Parameter enforceIfNoCheckpoint: Governs behavior only when there is
    ///   **no existing checkpoint** for this key yet. Once a checkpoint
    ///   exists, a missing state root is always rejected and the revision may
    ///   never regress, regardless of this flag — an anchor cannot be turned
    ///   back off for a key it has already started protecting.
    @discardableResult
    public func accept(relayBaseURL: String, ownerIdentityID: String, revision: UInt64, stateRoot: Data?,
                       enforceIfNoCheckpoint: Bool) throws -> CompanionCheckpoint? {
        let key = Self.storageKey(relayBaseURL: relayBaseURL, ownerIdentityID: ownerIdentityID)
        return try store.withCheckpoint(forKey: key) { previous in
            if previous == nil, stateRoot == nil, !enforceIfNoCheckpoint {
                return (nil, nil)
            }
            guard let stateRoot else {
                throw CompanionError.malformed("relay response is missing a state root")
            }
            if let previous {
                guard revision >= previous.revision else {
                    throw CompanionError.staleRevision(expected: previous.revision, actual: revision)
                }
                if revision == previous.revision {
                    guard stateRoot == previous.stateRoot else {
                        throw CompanionError.malformed("conflicting relay state root at revision \(revision)")
                    }
                    return (previous, nil)
                }
            }
            let checkpoint = try CompanionCheckpoint(ownerIdentityID: ownerIdentityID, revision: revision, stateRoot: stateRoot)
            return (checkpoint, checkpoint)
        }
    }

    public func resetAll() throws {
        try store.resetAll()
    }
}

/// Normalizes a relay base URL for anchor keying: lowercases the scheme and
/// host, makes the port explicit (falling back to the scheme's conventional
/// default when absent), and drops a trailing slash. Without this,
/// `http://Host:8002/`, `http://host:8002`, and `HTTP://host:8002` would
/// anchor as three different keys for what is really one relay.
extension URL {
    var companionAnchorKey: String {
        let components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        let scheme = (components?.scheme ?? "http").lowercased()
        let host = (components?.host ?? "").lowercased()
        let port = components?.port ?? (scheme == "https" ? 443 : 80)
        var path = components?.path ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host):\(port)\(path)"
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

    /// - Parameters:
    ///   - baseURL: Relay base URL, for example `http://127.0.0.1:8002`.
    ///   - session: Injectable for tests (a `URLProtocol`-stubbed session).
    ///   - anchorStore: When supplied, every response to an owner-signed
    ///     operation is checked against, and folded into, the rollback
    ///     anchor before being returned to the caller. Helper-signed
    ///     operations and a pure helper inbox are never anchored — per the
    ///     relay contract, `ownerIdentityID`/`stateRoot` on those responses
    ///     either name a different person's ledger or are omitted entirely.
    ///   - enforceStateRoot: Governs behavior only the first time a given
    ///     `(baseURL, owner)` key is seen (default `true`, fail closed). Once
    ///     a checkpoint exists for that key, a missing root is always
    ///     rejected regardless of this flag.
    public init(baseURL: URL, session: URLSession = .shared, anchorStore: (any RollbackAnchorStore)? = nil,
                enforceStateRoot: Bool = true) {
        self.baseURL = baseURL
        self.session = session
        self.anchor = anchorStore.map(RollbackAnchor.init(store:))
        self.enforceStateRoot = enforceStateRoot
    }

    public func submit(_ operation: SignedOperation) async throws -> RelayResponse {
        let response: RelayResponse = try await post(path: "v1/operations", body: operation)
        guard response.operationID == operation.operationID else {
            throw CompanionTransportError.malformedResponse
        }
        try validateAnchor(for: operation, revision: response.revision, stateRoot: response.stateRoot,
                           ownerIdentityID: response.ownerIdentityID)
        return response
    }

    public func fetchInbox(_ operation: SignedOperation) async throws -> InboxResponse {
        let response: InboxResponse = try await post(path: "v1/inbox", body: operation)
        try validateAnchor(for: operation, revision: response.revision, stateRoot: response.stateRoot,
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

    /// Anchors only a response to an operation this device's **owner**
    /// identity signed, and only when the relay attributes that response to
    /// that same owner identity. This is deliberate: a helper-signed
    /// operation's `ownerIdentityID` (per the v1.1 relay contract) names the
    /// *other* person's ledger, and a pure helper inbox omits
    /// `ownerIdentityID`/`stateRoot` entirely because it can span many
    /// owners' ledgers. Neither should be folded into this device's own
    /// rollback anchor.
    private func validateAnchor(for operation: SignedOperation, revision: UInt64, stateRoot: Data?,
                                ownerIdentityID: String?) throws {
        guard let anchor else { return }
        guard operation.signer.role == .owner else { return }
        let anchorKey = baseURL.companionAnchorKey
        guard let ownerIdentityID else {
            if enforceStateRoot {
                throw CompanionTransportError.server(.malformed("relay response for an owner-signed operation is missing its owner identity"))
            }
            // Even when first-use enforcement is relaxed, an owner-signed
            // operation whose response omits its own identity must still
            // respect an anchor already established for this exact owner —
            // otherwise a compromised relay could dodge anchoring simply by
            // omitting the field on later responses.
            do {
                if try anchor.currentCheckpoint(relayBaseURL: anchorKey, ownerIdentityID: operation.signer.identityID) != nil {
                    throw CompanionTransportError.server(.malformed("relay response for an owner-signed operation is missing its owner identity, but an anchor is already established"))
                }
            } catch let error as CompanionError {
                throw CompanionTransportError.server(error)
            }
            return
        }
        guard ownerIdentityID == operation.signer.identityID else {
            // A hard integrity violation, not a "no anchor yet" situation —
            // reject regardless of enforceStateRoot.
            throw CompanionTransportError.server(.malformed("relay response owner identity does not match the signing owner"))
        }
        try operation.signer.validate()
        do {
            try anchor.accept(relayBaseURL: anchorKey, ownerIdentityID: ownerIdentityID,
                              revision: revision, stateRoot: stateRoot, enforceIfNoCheckpoint: enforceStateRoot)
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
        case 409: return "stale_revision"
        case 413: return "payload_too_large"
        case 429: return "rate_limited"
        default: return "malformed"
        }
    }
}

// MARK: - Async client

/// Async sibling of `CompanionClient`, built against `AsyncCompanionTransport`
/// instead of the synchronous `CompanionTransport`.
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
        try validateConfirmResponse(pairing, acceptance: acceptance, signerIdentity: signer.identity)
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
    /// `RelationshipConsent` last returned by a grant/accept call, or by a
    /// prior inbox fetch's `consents`).
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

    /// Submits kind `"use"` exactly as the sync `CompanionClient.useApproval`
    /// does, then verifies the relay's response before returning it: the
    /// verification's `kind` is `.verification`, its `approval`/`useID` match
    /// what was submitted, the approval's signature is valid, it binds this
    /// request's `requestID`/`sessionID`/`activeSetID` and the approver's
    /// exact pairing/epoch/consent-generation binding, and its decision is
    /// `.approved` — see `validateUseVerification`. The same `useID` and
    /// `approval` always derive the same operation ID (`operationIdentifier`
    /// hashes the encoded `ApprovalUse` body), so a retry after an
    /// interrupted app session replays the relay's stored idempotent receipt
    /// rather than submitting a second "use". R5 Slice B2a.
    public func useApproval(_ approval: Approval, request: TrustedRequest, useID: String) async throws -> ApprovalVerification {
        guard signer.identity == request.owner else { throw CompanionError.unauthorized }
        let use = ApprovalUse(approval: approval, requestID: request.requestID, useID: useID,
                              consentGeneration: approval.consentGeneration)
        guard case let .verification(value) = try await submit("use", use) else {
            throw CompanionError.malformed("relay response")
        }
        try validateUseVerification(value, approval: approval, request: request, useID: useID)
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

    /// The full inbox response, including — per the v1.1 relay contract —
    /// `pairings` (every pairing where this identity is the owner or the
    /// approver) and `consents` (the current, generation-bearing consent for
    /// each of those pairings). `ownerIdentityID`/`stateRoot` are present
    /// only when this identity is fetching its own ledger as an owner; they
    /// are `nil` for a pure helper inbox.
    public func fetchInboxResponse() async throws -> InboxResponse {
        let query = InboxQuery(identityID: signer.identity.identityID, issuedAt: now())
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
        if let ownerIdentityID = response.ownerIdentityID, ownerIdentityID != signer.identity.identityID {
            throw CompanionError.malformed("inbox response owner mismatch")
        }
        return response
    }

    public func fetchInbox() async throws -> [TrustedRequest] {
        try await fetchInboxResponse().requests
    }
}
