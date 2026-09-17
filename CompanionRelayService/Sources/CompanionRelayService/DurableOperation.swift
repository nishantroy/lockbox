import Foundation
import CompanionKit

public enum DurableRelayError: Error, Equatable, Sendable {
    case invalidEnvelope
    case invalidOperationID
    case staleRevision(expected: Int64, actual: Int64)
    case idempotencyConflict
    case unknownOwner
    case ambiguousOwner
    case responseCorrupt
    case revisionOverflow
    case unsupportedOperation(String)
    case unauthorized
    case mutationChangedRevision(expected: Int64, actual: Int64)
}

/// Metadata is part of the signed operation body. It cannot be supplied by a
/// transport header or changed by a proxy without invalidating SignedOperation.
public struct DurableOperationEnvelope: Codable, Hashable, Sendable {
    public let operationID: String
    public let expectedRevision: Int64
    public let payload: Data

    public init(operationID: String, expectedRevision: Int64, payload: Data) throws {
        guard isValidIdentifier(operationID), expectedRevision >= 0,
              payload.count <= DurableRelayLimits.maxPayloadBytes else {
            throw DurableRelayError.invalidEnvelope
        }
        self.operationID = operationID
        self.expectedRevision = expectedRevision
        self.payload = payload
    }
}

/// Natural end is an owner-authenticated lifecycle transition. The reducer
/// compares this exact session and active set with the current ledger before
/// terminally expiring outstanding requests.
public struct DurableNaturalEnd: Codable, Hashable, Sendable {
    public let sessionID: String
    public let activeSetID: String

    public init(sessionID: String, activeSetID: String) {
        self.sessionID = sessionID
        self.activeSetID = activeSetID
    }
}

public enum DurableDeliveryContract {
    /// APNs/push may wake a client, but carries no authority and is not state.
    public static let pushIsWakeHintOnly = true
    /// A foreground inbox fetch reads committed durable state and is authoritative.
    public static let foregroundFetchIsAuthoritative = true
}

public enum DurableOperationFactory {
    public static func make<T: Encodable>(kind: String, operationID: String,
                                          expectedRevision: Int64, payload: T,
                                          signer: DeviceSigner) throws -> SignedOperation {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(payload)
        let envelope = try DurableOperationEnvelope(operationID: operationID,
                                                     expectedRevision: expectedRevision,
                                                     payload: payloadData)
        let envelopeData = try encoder.encode(envelope)
        let unsigned = try SignedOperation(operationID: operationID, expectedRevision: nil,
                                           kind: kind, signer: signer.identity,
                                           body: envelopeData,
                                           signature: Data(repeating: 0, count: 64))
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).operation",
                                        fields: unsigned.signingFields())
        return try SignedOperation(operationID: operationID, expectedRevision: nil,
                                   kind: kind, signer: signer.identity,
                                   body: envelopeData, signature: signature)
    }

    public static func makeInbox(signer: DeviceSigner) throws -> SignedOperation {
        let query = InboxQuery(identityID: signer.identity.identityID)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(query)
        let fields = ["inbox", signer.identity.identityID, durableBase64URL(signer.identity.publicKey),
                      durableBase64URL(CompanionCanonical.digest(body))]
        let signature = try signer.sign(domain: "\(CompanionCanonical.version).operation", fields: fields)
        return try SignedOperation(kind: "inbox", signer: signer.identity, body: body,
                                   signature: signature)
    }
}

public extension InMemoryDurableRelayStore {
    /// A restart operation intentionally goes through the serialized snapshot
    /// boundary rather than sharing the old in-memory object.
    func restarted() throws -> InMemoryDurableRelayStore {
        try InMemoryDurableRelayStore(snapshot: snapshot())
    }
}

func isValidIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= CompanionLimits.maxIdentifierLength &&
    !value.contains(where: { $0.isWhitespace })
}

func durableDataFromBase64URL(_ value: String) -> Data? {
    var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    text += String(repeating: "=", count: (4 - text.count % 4) % 4)
    return Data(base64Encoded: text)
}

func durableBase64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func validateTimestamp(_ date: Date) throws {
    guard date.timeIntervalSince1970.isFinite,
          date >= Date(timeIntervalSince1970: 0),
          date <= Date(timeIntervalSince1970: 4_102_444_800) else {
        throw CompanionError.malformed("invalid timestamp")
    }
}

extension DurableRelayLimits {
    static let maxPayloadBytes = 32_768
}
