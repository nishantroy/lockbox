import Foundation

/// The durable command boundary is intentionally small: an external service
/// must atomically compare `expectedRevision`, reject an already-used
/// `operationID` with a different digest, apply the command, increment the
/// owner-scoped revision, and persist the receipt before acknowledging it.
public struct RelayOperationRecord: Codable, Hashable, Sendable {
    public let operationID: String
    public let signerIdentityID: String
    public let kind: String
    public let bodyDigest: Data
    /// The exact signed operation is retained for restore graph validation.
    /// Empty is accepted only by legacy decoding and is rejected by anchored
    /// restore for snapshots that contain request state.
    public let signedOperation: Data
    public let expectedRevision: UInt64?
    public let revision: UInt64
    public let response: RelayResult

    public init(operationID: String, signerIdentityID: String, kind: String,
                bodyDigest: Data, revision: UInt64, response: RelayResult,
                expectedRevision: UInt64? = nil, signedOperation: Data = Data()) throws {
        try requireIdentifier(operationID, name: "operation ID")
        try requireIdentifier(signerIdentityID, name: "signer identity ID")
        try requireIdentifier(kind, name: "operation kind")
        guard bodyDigest.count == 32, signedOperation.count <= 32_768, revision > 0 else {
            throw CompanionError.malformed("invalid operation record")
        }
        self.operationID = operationID
        self.signerIdentityID = signerIdentityID
        self.kind = kind
        self.bodyDigest = bodyDigest
        self.signedOperation = signedOperation
        self.expectedRevision = expectedRevision
        self.revision = revision
        self.response = response
    }

    private enum CodingKeys: String, CodingKey {
        case operationID, signerIdentityID, kind, bodyDigest, signedOperation,
             expectedRevision, revision, response
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(operationID: c.decode(String.self, forKey: .operationID),
                      signerIdentityID: c.decode(String.self, forKey: .signerIdentityID),
                      kind: c.decode(String.self, forKey: .kind),
                      bodyDigest: c.decode(Data.self, forKey: .bodyDigest),
                      revision: c.decode(UInt64.self, forKey: .revision),
                      response: c.decode(RelayResult.self, forKey: .response),
                      expectedRevision: c.decodeIfPresent(UInt64.self, forKey: .expectedRevision),
                      signedOperation: c.decodeIfPresent(Data.self, forKey: .signedOperation) ?? Data())
    }

    public func validate() throws {
        _ = try RelayOperationRecord(operationID: operationID, signerIdentityID: signerIdentityID,
                                     kind: kind, bodyDigest: bodyDigest, revision: revision,
                                     response: response, expectedRevision: expectedRevision,
                                     signedOperation: signedOperation)
    }
}

public struct RelayResponse: Codable, Hashable, Sendable {
    public let operationID: String
    public let revision: UInt64
    public let result: RelayResult
    /// The identity of the ledger this operation mutated (relay contract
    /// v1.1). For an owner-signed operation this is the signer's own
    /// identity; for a **helper-signed** operation (accept/approval/consent
    /// acceptance) it is the *other* person's owner identity, since a
    /// helper's action mutates the owner's ledger, not their own. Added
    /// additively (R5 relay plan, Slice B1) for the on-device rollback
    /// anchor (`RollbackAnchor` in `HTTPTransport.swift`); optional so the
    /// in-memory relay and every existing test keep decoding/encoding
    /// unchanged. A hosted relay (Slice A) should populate it.
    public let ownerIdentityID: String?
    /// Canonical state-root digest (32 bytes) for `revision`, as described in
    /// `docs/companion-security.md`. Optional for the same back-compat
    /// reason as `ownerIdentityID`.
    public let stateRoot: Data?

    public init(operationID: String, revision: UInt64, result: RelayResult,
                ownerIdentityID: String? = nil, stateRoot: Data? = nil) throws {
        try requireIdentifier(operationID, name: "operation ID")
        guard revision > 0 else { throw CompanionError.malformed("invalid response revision") }
        if let ownerIdentityID { try requireIdentifier(ownerIdentityID, name: "response owner ID") }
        if let stateRoot { guard stateRoot.count == 32 else { throw CompanionError.malformed("invalid response state root") } }
        self.operationID = operationID
        self.revision = revision
        self.result = result
        self.ownerIdentityID = ownerIdentityID
        self.stateRoot = stateRoot
    }
}

public struct InboxResponse: Codable, Hashable, Sendable {
    /// Relay contract v1.1: present only when the fetching identity is the
    /// **owner** of this ledger (fetching their own inbox). Omitted for a
    /// pure helper inbox, since one helper identity's inbox items can span
    /// several different owners' ledgers, so there is no single ledger to
    /// attribute a revision/root to.
    public let ownerIdentityID: String?
    public let revision: UInt64
    public let requests: [TrustedRequest]
    /// Same presence rule as `ownerIdentityID` (owner-fetch only).
    public let stateRoot: Data?
    /// Every pairing where the fetching identity is the owner or the
    /// approver. This is how a helper's device learns about a pairing the
    /// owner confirmed — the friend never receives a `Pairing` value
    /// directly from `accept`. Additive; `nil` for a relay/test double that
    /// does not populate it.
    public let pairings: [Pairing]?
    /// The current, generation-bearing `RelationshipConsent` for each
    /// pairing in `pairings`. Additive; `nil` for a relay/test double that
    /// does not populate it.
    public let consents: [RelationshipConsent]?

    public init(ownerIdentityID: String?, revision: UInt64, requests: [TrustedRequest], stateRoot: Data? = nil,
                pairings: [Pairing]? = nil, consents: [RelationshipConsent]? = nil) throws {
        if let ownerIdentityID { try requireIdentifier(ownerIdentityID, name: "identity ID") }
        if let stateRoot { guard stateRoot.count == 32 else { throw CompanionError.malformed("invalid response state root") } }
        self.ownerIdentityID = ownerIdentityID
        self.revision = revision
        self.requests = requests
        self.stateRoot = stateRoot
        self.pairings = pairings
        self.consents = consents
    }
}

/// A transport failure is separate from a command outcome. A retryable
/// failure means the response was not received; retry the identical signed
/// operation and never mint a new operation ID. Server command errors are
/// terminal decisions for that operation.
public enum CompanionTransportError: Error, Equatable, Sendable {
    case unavailable
    case timedOut
    case malformedResponse
    case server(CompanionError)

    public var isRetryable: Bool {
        switch self {
        case .unavailable, .timedOut: return true
        case .malformedResponse, .server: return false
        }
    }

    public var code: String {
        switch self {
        case .unavailable: return "transport_unavailable"
        case .timedOut: return "transport_timed_out"
        case .malformedResponse: return "malformed_response"
        case .server(let error): return error.transportCode
        }
    }
}

public struct CompanionTransportErrorDTO: Codable, Hashable, Sendable {
    public let code: String
    public let operationID: String?
    public let retryable: Bool
    public let currentRevision: UInt64?

    public init(code: String, operationID: String? = nil, retryable: Bool,
                currentRevision: UInt64? = nil) throws {
        try requireIdentifier(code, name: "transport error code")
        if let operationID { try requireIdentifier(operationID, name: "operation ID") }
        self.code = code
        self.operationID = operationID
        self.retryable = retryable
        self.currentRevision = currentRevision
    }

    public init(error: CompanionTransportError, operationID: String? = nil,
                currentRevision: UInt64? = nil) throws {
        try self.init(code: error.code, operationID: operationID,
                      retryable: error.isRetryable, currentRevision: currentRevision)
    }
}

extension RelayResponse {
    func validated(for operation: SignedOperation) throws -> RelayResponse {
        guard operation.operationID == operationID else { throw CompanionError.malformed("response operation mismatch") }
        return self
    }

}
