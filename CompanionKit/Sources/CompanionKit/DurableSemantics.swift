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
    public let expectedRevision: UInt64?
    public let revision: UInt64
    public let response: RelayResult

    public init(operationID: String, signerIdentityID: String, kind: String,
                bodyDigest: Data, revision: UInt64, response: RelayResult,
                expectedRevision: UInt64? = nil) throws {
        try requireIdentifier(operationID, name: "operation ID")
        try requireIdentifier(signerIdentityID, name: "signer identity ID")
        try requireIdentifier(kind, name: "operation kind")
        guard bodyDigest.count == 32, revision > 0 else {
            throw CompanionError.malformed("invalid operation record")
        }
        self.operationID = operationID
        self.signerIdentityID = signerIdentityID
        self.kind = kind
        self.bodyDigest = bodyDigest
        self.expectedRevision = expectedRevision
        self.revision = revision
        self.response = response
    }

    public func validate() throws {
        _ = try RelayOperationRecord(operationID: operationID, signerIdentityID: signerIdentityID,
                                     kind: kind, bodyDigest: bodyDigest, revision: revision,
                                     response: response, expectedRevision: expectedRevision)
    }
}

public struct RelayResponse: Codable, Hashable, Sendable {
    public let operationID: String
    public let revision: UInt64
    public let result: RelayResult

    public init(operationID: String, revision: UInt64, result: RelayResult) throws {
        try requireIdentifier(operationID, name: "operation ID")
        guard revision > 0 else { throw CompanionError.malformed("invalid response revision") }
        self.operationID = operationID
        self.revision = revision
        self.result = result
    }
}

public struct InboxResponse: Codable, Hashable, Sendable {
    public let ownerIdentityID: String
    public let revision: UInt64
    public let requests: [TrustedRequest]

    public init(ownerIdentityID: String, revision: UInt64, requests: [TrustedRequest]) throws {
        try requireIdentifier(ownerIdentityID, name: "identity ID")
        self.ownerIdentityID = ownerIdentityID
        self.revision = revision
        self.requests = requests
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
