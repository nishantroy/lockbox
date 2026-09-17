import Foundation

/// Capabilities are relationship-scoped. R5 contains only the controls needed
/// for exact-session early-end approval. `mutualPact` remains reserved until a
/// pairing-bound pact operation exists; the R6 values are schema reservations
/// and are never active in this package.
public enum CompanionScope: String, Codable, CaseIterable, Hashable, Sendable {
    case approveEarlyEnd
    case receiveRequests
    case mutualPact
    case earlyEndNotices
    case weeklySharedSummaries

    public var isR5: Bool {
        switch self {
        case .approveEarlyEnd, .receiveRequests: return true
        case .mutualPact, .earlyEndNotices, .weeklySharedSummaries: return false
        }
    }

    /// Reserved capabilities are represented for schema compatibility but are
    /// never accepted by consent or operation authorization.
    public var isReservedR6: Bool { !isR5 }
}

/// Ordered on the wire so consent mutations have deterministic operation
/// bodies. A Set would make semantically identical mutations acquire different
/// operation IDs through JSON ordering.
public struct CompanionScopeSet: Codable, Hashable, Sendable {
    public let scopes: [CompanionScope]

    public init(_ scopes: [CompanionScope] = []) throws {
        let unique = Set(scopes)
        guard unique.count == scopes.count else {
            throw CompanionError.malformed("duplicate relationship scope")
        }
        // R6 values are representable for forward schema compatibility. Relay
        // authorization rejects them until a separately reviewed R6 consent
        // capability exists.
        self.scopes = unique.sorted { $0.rawValue < $1.rawValue }
    }

    public init(_ scopes: Set<CompanionScope>) throws {
        try self.init(Array(scopes))
    }

    public func contains(_ scope: CompanionScope) -> Bool { scopes.contains(scope) }
    public var isEmpty: Bool { scopes.isEmpty }
    public var asSet: Set<CompanionScope> { Set(scopes) }
}

public enum ConsentSide: String, Codable, Hashable, Sendable {
    case pending
    case active
    case revoked
}

/// Bilateral consent for one exact pairing epoch. Consent is deliberately not
/// inferred from pairing: each side must explicitly opt into each R5 scope.
/// The schema can carry R6 names for migration/forward compatibility, but
/// activeScopes never authorizes an R6 capability.
public struct RelationshipConsent: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 2

    public let schemaVersion: UInt16
    public let relationshipID: String
    public let pairingID: String
    public let pairEpoch: UInt64
    /// Monotonically advances for every consent mutation. A zero value only
    /// exists on a migrated pre-generation record and is permanently denied.
    public private(set) var generation: UInt64
    public let owner: DeviceIdentity
    public let approver: DeviceIdentity
    public var ownerScopes: [CompanionScope]
    public var approverScopes: [CompanionScope]
    public var ownerState: ConsentSide
    public var approverState: ConsentSide
    public var updatedAt: Date

    public init(relationshipID: String, pairingID: String, pairEpoch: UInt64,
                owner: DeviceIdentity, approver: DeviceIdentity,
                ownerScopes: [CompanionScope] = [], approverScopes: [CompanionScope] = [],
                ownerState: ConsentSide = .pending, approverState: ConsentSide = .pending,
                updatedAt: Date, generation: UInt64 = 1,
                schemaVersion: UInt16 = currentSchemaVersion) throws {
        try requireIdentifier(relationshipID, name: "relationship ID")
        try requireIdentifier(pairingID, name: "pairing ID")
        guard pairEpoch > 0, relationshipID == pairingID,
              owner.role == .owner, approver.role == .trustedApprover,
              ownerScopes.count == Set(ownerScopes).count,
              approverScopes.count == Set(approverScopes).count,
              schemaVersion == Self.currentSchemaVersion,
              generation > 0 || (generation == 0 && ownerScopes.isEmpty && approverScopes.isEmpty
                                 && ownerState == .revoked && approverState == .revoked) else {
            throw CompanionError.malformed("invalid relationship consent")
        }
        try owner.validate(); try approver.validate()
        try requireTimestamp(updatedAt, name: "consent update time")
        guard Set(approverScopes).isSubset(of: Set(ownerScopes)) else {
            throw CompanionError.malformed("approver consent exceeds owner consent")
        }
        self.schemaVersion = schemaVersion
        self.relationshipID = relationshipID; self.pairingID = pairingID; self.pairEpoch = pairEpoch
        self.generation = generation
        self.owner = owner; self.approver = approver
        self.ownerScopes = ownerScopes.sorted { $0.rawValue < $1.rawValue }
        self.approverScopes = approverScopes.sorted { $0.rawValue < $1.rawValue }
        self.ownerState = ownerState; self.approverState = approverState; self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, relationshipID, pairingID, pairEpoch, generation, owner, approver,
             ownerScopes, approverScopes, ownerState, approverState, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchema = try c.decodeIfPresent(UInt16.self, forKey: .schemaVersion) ?? 0
        let relationshipID = try c.decode(String.self, forKey: .relationshipID)
        let pairingID = try c.decode(String.self, forKey: .pairingID)
        let pairEpoch = try c.decode(UInt64.self, forKey: .pairEpoch)
        let owner = try c.decode(DeviceIdentity.self, forKey: .owner)
        let approver = try c.decode(DeviceIdentity.self, forKey: .approver)
        let ownerScopes = try c.decode([CompanionScope].self, forKey: .ownerScopes)
        let approverScopes = try c.decode([CompanionScope].self, forKey: .approverScopes)
        let ownerState = try c.decode(ConsentSide.self, forKey: .ownerState)
        let approverState = try c.decode(ConsentSide.self, forKey: .approverState)
        let updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        guard decodedSchema == Self.currentSchemaVersion,
              let generation = try c.decodeIfPresent(UInt64.self, forKey: .generation), generation > 0 else {
            // Scope-era records have no generation. Do not carry active
            // authority forward into a later grant; migrate them to a
            // terminal, empty consent that can only be replaced by a new
            // signed mutation.
            try self.init(relationshipID: relationshipID, pairingID: pairingID, pairEpoch: pairEpoch,
                          owner: owner, approver: approver, ownerScopes: [], approverScopes: [],
                          ownerState: .revoked, approverState: .revoked, updatedAt: updatedAt,
                          generation: 0)
            return
        }
        try self.init(relationshipID: relationshipID, pairingID: pairingID, pairEpoch: pairEpoch,
                      owner: owner, approver: approver, ownerScopes: ownerScopes,
                      approverScopes: approverScopes, ownerState: ownerState,
                      approverState: approverState, updatedAt: updatedAt,
                      generation: generation, schemaVersion: Self.currentSchemaVersion)
    }

    /// Advances the bilateral authority generation exactly once. Callers must
    /// atomically invalidate requests and approvals before acknowledging the
    /// enclosing consent transaction.
    public mutating func advanceGeneration() throws {
        generation = try checkedIncrement(generation, name: "consent generation")
    }

    public func activeScopes() -> Set<CompanionScope> {
        guard ownerState == .active, approverState == .active else { return [] }
        return Set(ownerScopes).intersection(approverScopes).filter(\.isR5)
    }

    public func authorizes(_ scope: CompanionScope) -> Bool {
        // R6 is intentionally false even if a future/forward-decoded record
        // contains its name.
        scope.isR5 && activeScopes().contains(scope)
    }

    public func validate() throws {
        _ = try RelationshipConsent(relationshipID: relationshipID, pairingID: pairingID,
                                    pairEpoch: pairEpoch, owner: owner, approver: approver,
                                    ownerScopes: ownerScopes, approverScopes: approverScopes,
                                    ownerState: ownerState, approverState: approverState,
                                    updatedAt: updatedAt, generation: generation,
                                    schemaVersion: schemaVersion)
    }
}

public enum ConsentMutationAction: String, Codable, Hashable, Sendable {
    case ownerGrant
    case approverAccept
    case ownerRevoke
    case approverRevoke
}

/// A consent mutation is itself carried by a signed operation. The nonce is
/// independently one-use so a copied command cannot be replayed under a new
/// operation ID.
public struct RelationshipConsentMutation: Codable, Hashable, Sendable {
    public let relationshipID: String
    public let pairingID: String
    public let pairEpoch: UInt64
    public let owner: DeviceIdentity
    public let approver: DeviceIdentity
    public let action: ConsentMutationAction
    public let scopes: CompanionScopeSet
    public let nonce: Data
    public let issuedAt: Date

    public init(relationshipID: String, pairingID: String, pairEpoch: UInt64,
                owner: DeviceIdentity, approver: DeviceIdentity,
                action: ConsentMutationAction, scopes: CompanionScopeSet,
                nonce: Data, issuedAt: Date) throws {
        try requireIdentifier(relationshipID, name: "relationship ID")
        try requireIdentifier(pairingID, name: "pairing ID")
        guard relationshipID == pairingID, pairEpoch > 0,
              nonce.count >= 16, nonce.count <= 64 else {
            throw CompanionError.malformed("invalid consent mutation")
        }
        try owner.validate(); try approver.validate(); try requireTimestamp(issuedAt, name: "consent mutation time")
        guard owner.role == .owner, approver.role == .trustedApprover else {
            throw CompanionError.malformed("invalid consent participants")
        }
        self.relationshipID = relationshipID; self.pairingID = pairingID; self.pairEpoch = pairEpoch
        self.owner = owner; self.approver = approver; self.action = action
        self.scopes = scopes; self.nonce = nonce; self.issuedAt = issuedAt
    }
}

/// Exact-session release is the only trusted-person request purpose in R5.
/// There is intentionally no start, extension, rule-change, usage, or content
/// purpose in this enum.
public enum TrustedRequestPurpose: String, Codable, Hashable, Sendable {
    case approveEarlyEnd
}
