import Foundation
import CryptoKit

/// Durable identity state is metadata, not a replacement for the private key.
/// In particular, `.needsRepair` never causes a new key to be generated.
public enum IdentityLifecycleState: String, Codable, Hashable, Sendable {
    case active
    case needsRepair
    case replacementPending
    case revoked
}

public struct IdentityLifecycle: Codable, Hashable, Sendable {
    public let identity: DeviceIdentity
    public let epoch: UInt64
    public let state: IdentityLifecycleState
    public let updatedAt: Date

    public init(identity: DeviceIdentity, epoch: UInt64 = 1,
                state: IdentityLifecycleState, updatedAt: Date) throws {
        try identity.validate()
        try requireTimestamp(updatedAt, name: "identity update time")
        guard epoch > 0 else { throw CompanionError.malformed("invalid identity epoch") }
        self.identity = identity
        self.epoch = epoch
        self.state = state
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        _ = try IdentityLifecycle(identity: identity, epoch: epoch, state: state, updatedAt: updatedAt)
    }
}

/// A replacement is explicit and signed by the replacement device. The owner
/// still authorizes the relay command, while this proof establishes possession
/// of the new device key. The previous identity is never silently reused.
public struct IdentityReplacement: Codable, Hashable, Sendable {
    public let replacementID: String
    public let previous: DeviceIdentity
    public let replacement: DeviceIdentity
    public let previousEpoch: UInt64
    public let replacementEpoch: UInt64
    public let issuedAt: Date
    public let signature: Data

    public init(replacementID: String, previous: DeviceIdentity, replacement: DeviceIdentity,
                previousEpoch: UInt64, replacementEpoch: UInt64, issuedAt: Date,
                signature: Data) throws {
        try requireIdentifier(replacementID, name: "replacement ID")
        try previous.validate(); try replacement.validate()
        try requireTimestamp(issuedAt, name: "replacement time")
        guard previous.role == replacement.role,
              previous != replacement,
              previousEpoch > 0,
              replacementEpoch == previousEpoch + 1,
              signature.isEmpty || signature.count == 64 else {
            throw CompanionError.malformed("invalid identity replacement")
        }
        self.replacementID = replacementID
        self.previous = previous
        self.replacement = replacement
        self.previousEpoch = previousEpoch
        self.replacementEpoch = replacementEpoch
        self.issuedAt = issuedAt
        self.signature = signature
    }

    public func signingFields() -> [String] {
        [replacementID,
         previous.identityID, base64URL(previous.publicKey),
         replacement.identityID, base64URL(replacement.publicKey),
         String(previousEpoch), String(replacementEpoch), String(milliseconds(issuedAt))]
    }

    public func validateSignature() throws {
        guard signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: replacement.publicKey),
              key.isValidSignature(signature, for: CompanionCanonical.bytes(
                domain: "\(CompanionCanonical.version).identity-replacement",
                fields: signingFields())) else {
            throw CompanionError.invalidSignature
        }
    }

    public static func propose(replacementID: String, previous: DeviceIdentity,
                               signer: DeviceSigner, previousEpoch: UInt64,
                               issuedAt: Date) throws -> IdentityReplacement {
        guard signer.identity.role == previous.role, signer.identity != previous else {
            throw CompanionError.unauthorized
        }
        let replacement = try IdentityReplacement(
            replacementID: replacementID, previous: previous, replacement: signer.identity,
            previousEpoch: previousEpoch, replacementEpoch: previousEpoch + 1,
            issuedAt: issuedAt, signature: Data())
        let signature = try signer.sign(
            domain: "\(CompanionCanonical.version).identity-replacement",
            fields: replacement.signingFields())
        return try IdentityReplacement(
            replacementID: replacementID, previous: previous, replacement: signer.identity,
            previousEpoch: previousEpoch, replacementEpoch: previousEpoch + 1,
            issuedAt: issuedAt, signature: signature)
    }
}

/// Pairing replacement binds the new key to one exact old pairing. Applying
/// this record revokes the old epoch and activates only the replacement epoch.
public struct PairingReplacement: Codable, Hashable, Sendable {
    public let replacementID: String
    public let previousPairingID: String
    public let previousEpoch: UInt64
    public let replacementPairingID: String
    public let replacement: DeviceIdentity
    public let owner: DeviceIdentity
    public let replacementEpoch: UInt64
    public let issuedAt: Date
    public let signature: Data

    public init(replacementID: String, previousPairing: Pairing, replacementPairingID: String,
                replacement: DeviceIdentity, replacementEpoch: UInt64, issuedAt: Date,
                signature: Data) throws {
        try requireIdentifier(replacementID, name: "replacement ID")
        try requireIdentifier(replacementPairingID, name: "replacement pairing ID")
        try previousPairing.validate(); try replacement.validate()
        try requireTimestamp(issuedAt, name: "replacement time")
        guard previousPairing.state == .active,
              replacement.role == .trustedApprover,
              replacement != previousPairing.approver,
              replacementEpoch == previousPairing.epoch + 1,
              signature.isEmpty || signature.count == 64 else {
            throw CompanionError.malformed("invalid pairing replacement")
        }
        self.replacementID = replacementID
        self.previousPairingID = previousPairing.pairingID
        self.previousEpoch = previousPairing.epoch
        self.replacementPairingID = replacementPairingID
        self.replacement = replacement
        self.owner = previousPairing.owner
        self.replacementEpoch = replacementEpoch
        self.issuedAt = issuedAt
        self.signature = signature
    }

    public func signingFields() -> [String] {
        [replacementID, previousPairingID, String(previousEpoch), replacementPairingID,
         owner.identityID, base64URL(owner.publicKey), replacement.identityID,
         base64URL(replacement.publicKey), String(replacementEpoch), String(milliseconds(issuedAt))]
    }

    public func validateSignature() throws {
        guard signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: replacement.publicKey),
              key.isValidSignature(signature, for: CompanionCanonical.bytes(
                domain: "\(CompanionCanonical.version).pairing-replacement",
                fields: signingFields())) else {
            throw CompanionError.invalidSignature
        }
    }

    public static func propose(replacementID: String, previousPairing: Pairing,
                               replacementPairingID: String, signer: DeviceSigner,
                               issuedAt: Date) throws -> PairingReplacement {
        guard signer.identity.role == .trustedApprover,
              signer.identity != previousPairing.approver else { throw CompanionError.unauthorized }
        let unsigned = try PairingReplacement(
            replacementID: replacementID, previousPairing: previousPairing,
            replacementPairingID: replacementPairingID, replacement: signer.identity,
            replacementEpoch: previousPairing.epoch + 1, issuedAt: issuedAt, signature: Data())
        let signature = try signer.sign(
            domain: "\(CompanionCanonical.version).pairing-replacement",
            fields: unsigned.signingFields())
        return try PairingReplacement(
            replacementID: replacementID, previousPairing: previousPairing,
            replacementPairingID: replacementPairingID, replacement: signer.identity,
            replacementEpoch: previousPairing.epoch + 1, issuedAt: issuedAt, signature: signature)
    }
}

public extension IdentityManager {
    /// Reattaches an already-authenticated private key to its known identity.
    /// The key's public half must match exactly; no key is generated here.
    func repair(identity: DeviceIdentity, privateKey: Data, updatedAt: Date) throws -> StoredIdentity {
        guard privateKey.count == 32 else { throw CompanionError.malformed("private key") }
        let key: Curve25519.Signing.PrivateKey
        do { key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) }
        catch { throw CompanionError.keyUnavailable }
        guard key.publicKey.rawRepresentation == identity.publicKey else {
            throw CompanionError.unauthorized
        }
        try keyStore.save(privateKey: privateKey, for: identity.identityID)
        _ = try IdentityLifecycle(identity: identity, state: .active, updatedAt: updatedAt)
        return StoredIdentity(identity: identity, availability: .available)
    }

    /// Generates a replacement only when the caller explicitly asks for one.
    /// The previous key remains untouched in the key store.
    func prepareReplacement(for previous: DeviceIdentity, replacementID: String,
                            previousEpoch: UInt64, issuedAt: Date) throws -> (StoredIdentity, IdentityReplacement) {
        let replacement = try DeviceSigner.create(role: previous.role, keyStore: keyStore)
        let proposal = try IdentityReplacement.propose(replacementID: replacementID,
                                                       previous: previous, signer: replacement,
                                                       previousEpoch: previousEpoch, issuedAt: issuedAt)
        return (StoredIdentity(identity: replacement.identity, availability: .available), proposal)
    }
}
