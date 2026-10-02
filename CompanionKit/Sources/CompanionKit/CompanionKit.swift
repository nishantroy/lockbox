import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

// MARK: - Limits and errors

public enum CompanionError: Error, Equatable, Sendable {
    case malformed(String)
    case invalidSignature
    case unknownIdentity
    case unauthorized
    case revokedPairing
    case expired
    case replay
    case staleSession
    case wrongTarget
    case wrongVerificationCode
    case rateLimited
    case keyUnavailable
    case alreadyPaired
    case notFound
    case invalidTransition
    case staleRevision(expected: UInt64, actual: UInt64)
    case operationConflict
    case missingOperationRevision
    case unsupportedScope
    case consentRequired
    /// R5 Slice B2a review fix (N2): a **locally detected** rollback or fork
    /// in the relay's reported `(revision, stateRoot)` for one owner,
    /// raised only by `RollbackAnchor`/`HTTPCompanionTransport.validateAnchor`
    /// (`HTTPTransport.swift`) — never by the relay itself. This is
    /// distinct from `.staleRevision`, which is the *relay's own*
    /// optimistic-concurrency rejection of a stale `expectedRevision` on a
    /// mutation (a benign write race a caller may simply retry with a fresh
    /// revision). A `.relayRollback` means this device's own previously
    /// accepted checkpoint disagrees with what the relay just reported —
    /// the relay has gone backwards or forked — and is integrity-fatal: the
    /// caller must not retry the same request and must not treat this as a
    /// transient condition.
    case relayRollback(RelayRollbackReason)

    /// A transport may retry a command only when it can resend the exact same
    /// signed operation. These errors describe terminal command outcomes; the
    /// caller must not manufacture a new operation ID to work around them.
    public var isRetryable: Bool {
        switch self {
        case .staleRevision, .operationConflict, .missingOperationRevision,
             .malformed, .invalidSignature, .unknownIdentity, .unauthorized,
             .revokedPairing, .expired, .replay, .staleSession, .wrongTarget,
             .wrongVerificationCode, .rateLimited, .keyUnavailable,
             .alreadyPaired, .notFound, .invalidTransition, .unsupportedScope,
             .consentRequired, .relayRollback:
            return false
        }
    }

    public var transportCode: String {
        switch self {
        case .staleRevision: return "stale_revision"
        case .operationConflict: return "operation_conflict"
        case .missingOperationRevision: return "missing_operation_revision"
        case .malformed: return "malformed"
        case .invalidSignature: return "invalid_signature"
        case .unknownIdentity: return "unknown_identity"
        case .unauthorized: return "unauthorized"
        case .revokedPairing: return "revoked_pairing"
        case .expired: return "expired"
        case .replay: return "replay"
        case .staleSession: return "stale_session"
        case .wrongTarget: return "wrong_target"
        case .wrongVerificationCode: return "wrong_verification_code"
        case .rateLimited: return "rate_limited"
        case .keyUnavailable: return "key_unavailable"
        case .alreadyPaired: return "already_paired"
        case .notFound: return "not_found"
        case .invalidTransition: return "invalid_transition"
        case .unsupportedScope: return "unsupported_scope"
        case .consentRequired: return "consent_required"
        // This device's own local detection, never a code the relay sends
        // or that `fromTransportCode(_:)` ever decodes from the wire — used
        // only for local diagnostics/logging via `CompanionTransportError.code`.
        case .relayRollback: return "relay_rollback"
        }
    }
}

/// The specific way a relay's reported `(revision, stateRoot)` disagreed
/// with this device's own previously accepted checkpoint for one owner. See
/// `CompanionError.relayRollback`.
public enum RelayRollbackReason: Equatable, Sendable {
    /// The reported revision is lower than the last one this device
    /// accepted for this owner — the relay has gone backwards.
    case regressedRevision(expected: UInt64, actual: UInt64)
    /// The reported revision matches the last one this device accepted for
    /// this owner, but the state root differs — the relay has forked.
    case conflictingRoot(revision: UInt64)
}

public enum CompanionLimits {
    public static let maxIdentifierLength = 128
    public static let maxMessageBytes = 280
    public static let maxTargets = 16
    public static let maxInviteLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let maxRequestLifetime: TimeInterval = 24 * 60 * 60
    public static let maxSessionLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let maxSnapshotRecords = 10_000
    public static let maxRateOperations = 30
    public static let rateWindow: TimeInterval = 60
}

func requireIdentifier(_ value: String, name: String = "identifier") throws {
    guard !value.isEmpty, value.utf8.count <= CompanionLimits.maxIdentifierLength,
          !value.contains(where: { $0.isWhitespace }) else {
        throw CompanionError.malformed("invalid \(name)")
    }
}

func requireTimestamp(_ value: Date, name: String) throws {
    guard value.timeIntervalSince1970.isFinite,
          value >= Date(timeIntervalSince1970: 0),
          value <= Date(timeIntervalSince1970: 4_102_444_800) else {
        throw CompanionError.malformed("invalid \(name)")
    }
}

/// Checked counters are used for every durable epoch/revision transition.
/// Never rely on Swift's trapping integer operators for protocol state.
func checkedIncrement(_ value: UInt64, name: String) throws -> UInt64 {
    let (next, overflowed) = value.addingReportingOverflow(1)
    guard !overflowed else { throw CompanionError.malformed("\(name) exhausted") }
    return next
}

func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
}

func date(milliseconds value: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
}

// MARK: - Canonical signing

/// A small framed encoding is used for signatures. It deliberately does not use
/// Codable/JSON key order, so semantically equivalent payloads cannot acquire
/// different signatures through dictionary ordering.
public enum CompanionCanonical {
    public static let version = "PhoneLockbox.Companion.v1"

    public static func bytes(domain: String, fields: [String]) -> Data {
        var result = Data()
        append(domain, to: &result)
        for field in fields { append(field, to: &result) }
        return result
    }

    /// Framing for state roots. Callers sort semantically unordered members
    /// before passing them here; lengths make concatenation unambiguous.
    public static func framed(domain: String, fields: [Data]) -> Data {
        var result = Data()
        append(domain, to: &result)
        for field in fields { append(field, to: &result) }
        return result
    }

    /// JSON is used only as a leaf encoding. Sorted keys plus explicit sorting
    /// of set/dictionary members at the state-root call site makes this stable
    /// across snapshot serialization and does not omit any stored field.
    public static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func append(_ value: String, to data: inout Data) {
        append(Data(value.utf8), to: &data)
    }

    private static func append(_ value: Data, to data: inout Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }
}

/// A checkpoint is intentionally separate from a mutable snapshot. The
/// embedding must retain this exact revision/root in independent trusted
/// monotonic storage; a digest copied beside the snapshot is not an anchor.
public struct CompanionCheckpoint: Codable, Hashable, Sendable {
    public let ownerIdentityID: String
    public let revision: UInt64
    public let stateRoot: Data

    public init(ownerIdentityID: String, revision: UInt64, stateRoot: Data) throws {
        try requireIdentifier(ownerIdentityID, name: "checkpoint owner ID")
        guard stateRoot.count == 32 else { throw CompanionError.malformed("invalid checkpoint root") }
        self.ownerIdentityID = ownerIdentityID
        self.revision = revision
        self.stateRoot = stateRoot
    }

    public func validate() throws {
        _ = try CompanionCheckpoint(ownerIdentityID: ownerIdentityID, revision: revision, stateRoot: stateRoot)
    }
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func dataFromBase64URL(_ value: String) -> Data? {
    guard value.utf8.count <= 16_384 else { return nil }
    var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    text += String(repeating: "=", count: (4 - text.count % 4) % 4)
    return Data(base64Encoded: text)
}

// MARK: - Device identity and key storage

public enum CompanionRole: String, Codable, Sendable {
    case owner
    case trustedApprover
}

public struct DeviceIdentity: Codable, Hashable, Sendable {
    public let identityID: String
    public let role: CompanionRole
    public let publicKey: Data

    public init(identityID: String, role: CompanionRole, publicKey: Data) throws {
        try requireIdentifier(identityID, name: "identity ID")
        guard publicKey.count == 32 else { throw CompanionError.malformed("public key") }
        let expected = Self.makeID(publicKey)
        guard identityID == expected else { throw CompanionError.malformed("identity ID does not match key") }
        self.identityID = identityID
        self.role = role
        self.publicKey = publicKey
    }

    public static func makeID(_ publicKey: Data) -> String {
        base64URL(Data(SHA256.hash(data: publicKey))).prefix(32).description
    }

    public func validate() throws {
        _ = try DeviceIdentity(identityID: identityID, role: role, publicKey: publicKey)
    }
}

public protocol DeviceKeyStore: Sendable {
    func save(privateKey: Data, for identityID: String) throws
    func loadPrivateKey(for identityID: String) throws -> Data?
    func deletePrivateKey(for identityID: String) throws
}

/// Test and developer harness storage. Production iOS code should use
/// KeychainDeviceKeyStore, not this implementation.
public final class InMemoryDeviceKeyStore: DeviceKeyStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func save(privateKey: Data, for identityID: String) throws {
        guard privateKey.count == 32 else { throw CompanionError.malformed("private key") }
        try requireIdentifier(identityID, name: "identity ID")
        lock.lock(); defer { lock.unlock() }
        values[identityID] = privateKey
    }

    public func loadPrivateKey(for identityID: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[identityID]
    }

    public func deletePrivateKey(for identityID: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: identityID)
    }
}

#if canImport(Security)
/// Key material is stored in the Keychain and marked ThisDeviceOnly on iOS.
/// A missing item is a repair/re-pair state; it
/// is never silently regenerated for an existing identity.
public final class KeychainDeviceKeyStore: DeviceKeyStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.phone-lockbox.companion.keys") {
        self.service = service
    }

    public func save(privateKey: Data, for identityID: String) throws {
        guard privateKey.count == 32 else { throw CompanionError.malformed("private key") }
        try requireIdentifier(identityID, name: "identity ID")
        var query = baseQuery(identityID)
        query[kSecValueData as String] = privateKey
        #if os(iOS)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #else
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif
        let updateStatus = SecItemUpdate(baseQuery(identityID) as CFDictionary, [kSecValueData as String: privateKey] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else { throw CompanionError.keyUnavailable }
        } else if updateStatus != errSecSuccess {
            throw CompanionError.keyUnavailable
        }
    }

    public func loadPrivateKey(for identityID: String) throws -> Data? {
        var query = baseQuery(identityID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            throw CompanionError.keyUnavailable
        }
        return data
    }

    public func deletePrivateKey(for identityID: String) throws {
        let status = SecItemDelete(baseQuery(identityID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CompanionError.keyUnavailable }
    }

    private func baseQuery(_ identityID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: identityID]
    }
}
#endif

public struct DeviceSigner: Sendable {
    public let identity: DeviceIdentity
    private let keyStore: any DeviceKeyStore

    public init(identity: DeviceIdentity, keyStore: any DeviceKeyStore) throws {
        try identity.validate()
        guard try keyStore.loadPrivateKey(for: identity.identityID) != nil else {
            throw CompanionError.keyUnavailable
        }
        self.identity = identity
        self.keyStore = keyStore
    }

    public static func create(role: CompanionRole, keyStore: any DeviceKeyStore) throws -> DeviceSigner {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation
        let identity = try DeviceIdentity(identityID: DeviceIdentity.makeID(publicKey), role: role, publicKey: publicKey)
        try keyStore.save(privateKey: key.rawRepresentation, for: identity.identityID)
        return try DeviceSigner(identity: identity, keyStore: keyStore)
    }

    public func sign(domain: String, fields: [String]) throws -> Data {
        guard let raw = try keyStore.loadPrivateKey(for: identity.identityID) else { throw CompanionError.keyUnavailable }
        do {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            return try key.signature(for: CompanionCanonical.bytes(domain: domain, fields: fields))
        } catch {
            throw CompanionError.keyUnavailable
        }
    }

    public func verify(signature: Data, domain: String, fields: [String], publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: CompanionCanonical.bytes(domain: domain, fields: fields))
    }
}

public enum IdentityAvailability: Equatable, Sendable {
    case available
    case needsRepair
}

public struct StoredIdentity: Sendable {
    public let identity: DeviceIdentity
    public let availability: IdentityAvailability

    public init(identity: DeviceIdentity, availability: IdentityAvailability) {
        self.identity = identity
        self.availability = availability
    }
}

public struct IdentityManager: Sendable {
    public let keyStore: any DeviceKeyStore

    public init(keyStore: any DeviceKeyStore) { self.keyStore = keyStore }

    public func load(identity: DeviceIdentity) throws -> StoredIdentity {
        try identity.validate()
        return StoredIdentity(identity: identity,
                              availability: try keyStore.loadPrivateKey(for: identity.identityID) == nil ? .needsRepair : .available)
    }

    public func create(role: CompanionRole) throws -> StoredIdentity {
        let signer = try DeviceSigner.create(role: role, keyStore: keyStore)
        return StoredIdentity(identity: signer.identity, availability: .available)
    }
}
