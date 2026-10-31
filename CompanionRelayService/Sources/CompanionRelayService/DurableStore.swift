import Foundation
import CryptoKit
import CompanionKit

// MARK: - Durable relational state contract

/// The durable aggregate is partitioned by owner identity. A hosted adapter
/// maps each field to relational rows; this value type is intentionally not a
/// JSON protocol or a wire response.
public struct DurableRelayDatabase: Codable, Sendable {
    public var owners: [String: DurableOwnerLedger]

    public init(owners: [String: DurableOwnerLedger] = [:]) {
        self.owners = owners
    }
}

/// The durable snapshot's checkpoint covers every owner partition. The
/// revision map is the exact monotonic revision for each owner; it is retained
/// outside the mutable snapshot by the embedding.
public struct DurableCheckpoint: Codable, Hashable, Sendable {
    public let ownerRevisions: [String: Int64]
    public let stateRoot: Data

    public init(ownerRevisions: [String: Int64], stateRoot: Data) throws {
        guard stateRoot.count == 32,
              ownerRevisions.allSatisfy({ isValidIdentifier($0.key) && $0.value >= 0 }) else {
            throw DurableStoreError.invalidSnapshot
        }
        self.ownerRevisions = ownerRevisions
        self.stateRoot = stateRoot
    }

    public func validate() throws {
        _ = try DurableCheckpoint(ownerRevisions: ownerRevisions, stateRoot: stateRoot)
    }
}

public struct DurableOwnerLedger: Codable, Sendable {
    public let owner: DeviceIdentity
    public var revision: Int64
    public var operations: [String: DurableOperationRecord]
    public var invitations: [String: DurableInvitationRecord]
    /// Pairing v2 leftover: v3 has no pending-acceptance step, so nothing writes this any more.
    public var pendingAcceptances: [String: PairingAcceptance]
    public var pairings: [String: DurablePairingRecord]
    public var pairingEpochs: [String: UInt64]
    public var sessions: [String: DurableSessionRecord]
    public var currentSessionID: String?
    public var requests: [String: DurableRequestRecord]
    public var approvals: [String: DurableApprovalRecord]
    public var approvalUses: [String: DurableApprovalUseRecord]
    public var relationshipConsents: [String: RelationshipConsent]
    public var usedConsentNonces: Set<String>
    public var usedApprovalIDs: Set<String>
    public var usedApprovalNonces: Set<String>
    public var rateLimits: [String: DurableRateLimitRecord]
    public var audit: [DurableAuditEvent]

    public init(owner: DeviceIdentity, revision: Int64 = 0,
                operations: [String: DurableOperationRecord] = [:],
                invitations: [String: DurableInvitationRecord] = [:],
                pendingAcceptances: [String: PairingAcceptance] = [:],
                pairings: [String: DurablePairingRecord] = [:],
                pairingEpochs: [String: UInt64] = [:],
                sessions: [String: DurableSessionRecord] = [:], currentSessionID: String? = nil,
                requests: [String: DurableRequestRecord] = [:],
                approvals: [String: DurableApprovalRecord] = [:],
                approvalUses: [String: DurableApprovalUseRecord] = [:],
                relationshipConsents: [String: RelationshipConsent] = [:],
                usedConsentNonces: Set<String> = [],
                usedApprovalIDs: Set<String> = [],
                usedApprovalNonces: Set<String> = [],
                rateLimits: [String: DurableRateLimitRecord] = [:],
                audit: [DurableAuditEvent] = []) {
        self.owner = owner
        self.revision = revision
        self.operations = operations
        self.invitations = invitations
        self.pendingAcceptances = pendingAcceptances
        self.pairings = pairings
        self.pairingEpochs = pairingEpochs
        self.sessions = sessions
        self.currentSessionID = currentSessionID
        self.requests = requests
        self.approvals = approvals
        self.approvalUses = approvalUses
        self.relationshipConsents = relationshipConsents
        self.usedConsentNonces = usedConsentNonces
        self.usedApprovalIDs = usedApprovalIDs
        self.usedApprovalNonces = usedApprovalNonces
        self.rateLimits = rateLimits
        self.audit = audit
    }

    private enum CodingKeys: String, CodingKey {
        case owner, revision, operations, invitations, pendingAcceptances, pairings,
             pairingEpochs, sessions, currentSessionID, requests, approvals, approvalUses,
             relationshipConsents, usedConsentNonces, usedApprovalIDs, usedApprovalNonces,
             rateLimits, audit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.owner = try c.decode(DeviceIdentity.self, forKey: .owner)
        self.revision = try c.decode(Int64.self, forKey: .revision)
        self.operations = try c.decode([String: DurableOperationRecord].self, forKey: .operations)
        self.invitations = try c.decode([String: DurableInvitationRecord].self, forKey: .invitations)
        self.pendingAcceptances = try c.decode([String: PairingAcceptance].self, forKey: .pendingAcceptances)
        self.pairings = try c.decode([String: DurablePairingRecord].self, forKey: .pairings)
        self.pairingEpochs = try c.decode([String: UInt64].self, forKey: .pairingEpochs)
        self.sessions = try c.decode([String: DurableSessionRecord].self, forKey: .sessions)
        self.currentSessionID = try c.decodeIfPresent(String.self, forKey: .currentSessionID)
        self.requests = try c.decode([String: DurableRequestRecord].self, forKey: .requests)
        self.approvals = try c.decode([String: DurableApprovalRecord].self, forKey: .approvals)
        let decodedUses = try c.decode([String: DurableApprovalUseRecord].self, forKey: .approvalUses)
        self.approvalUses = decodedUses
        self.relationshipConsents = try c.decodeIfPresent([String: RelationshipConsent].self, forKey: .relationshipConsents) ?? [:]
        self.usedConsentNonces = try c.decodeIfPresent(Set<String>.self, forKey: .usedConsentNonces) ?? []
        let migratedApprovalIDs = Set(decodedUses.values.flatMap { [$0.useID, $0.approvalID] })
        self.usedApprovalIDs = try c.decodeIfPresent(Set<String>.self, forKey: .usedApprovalIDs) ?? migratedApprovalIDs
        let migratedApprovalNonces = Set(self.approvals.values.compactMap {
            $0.approval.nonce.isEmpty ? nil : durableBase64URL($0.approval.nonce)
        })
        self.usedApprovalNonces = try c.decodeIfPresent(Set<String>.self, forKey: .usedApprovalNonces) ?? migratedApprovalNonces
        self.rateLimits = try c.decode([String: DurableRateLimitRecord].self, forKey: .rateLimits)
        self.audit = try c.decode([DurableAuditEvent].self, forKey: .audit)
    }
}

public enum DurableOperationDisposition: String, Codable, Hashable, Sendable {
    case accepted
    /// The signed command arrived at/after its request expiry. The request
    /// was terminally expired in the same transaction, but the command itself
    /// was rejected and can only replay this terminal outcome.
    case rejectedExpiredRequest
}

public struct DurableOperationRecord: Codable, Hashable, Sendable {
    public let operationID: String
    public let ownerID: String
    public let signer: DeviceIdentity
    public let kind: String
    public let bodyDigest: Data
    public let responseKind: String
    public let responseBody: Data
    public let responseDigest: Data
    /// Exact signed envelope retained for restore graph validation.
    public let signedOperation: Data
    public let committedRevision: Int64
    public let committedAt: Date
    public let disposition: DurableOperationDisposition

    public init(operationID: String, ownerID: String, signer: DeviceIdentity, kind: String,
                bodyDigest: Data, responseKind: String, responseBody: Data,
                responseDigest: Data, committedRevision: Int64, committedAt: Date,
                disposition: DurableOperationDisposition = .accepted,
                signedOperation: Data = Data()) {
        self.operationID = operationID; self.ownerID = ownerID; self.signer = signer
        self.kind = kind; self.bodyDigest = bodyDigest; self.responseKind = responseKind
        self.responseBody = responseBody; self.responseDigest = responseDigest
        self.signedOperation = signedOperation
        self.committedRevision = committedRevision; self.committedAt = committedAt
        self.disposition = disposition
    }

    private enum CodingKeys: String, CodingKey {
        case operationID, ownerID, signer, kind, bodyDigest, responseKind, responseBody,
             responseDigest, signedOperation, committedRevision, committedAt, disposition
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.operationID = try c.decode(String.self, forKey: .operationID)
        self.ownerID = try c.decode(String.self, forKey: .ownerID)
        self.signer = try c.decode(DeviceIdentity.self, forKey: .signer)
        self.kind = try c.decode(String.self, forKey: .kind)
        self.bodyDigest = try c.decode(Data.self, forKey: .bodyDigest)
        self.responseKind = try c.decode(String.self, forKey: .responseKind)
        self.responseBody = try c.decode(Data.self, forKey: .responseBody)
        self.responseDigest = try c.decode(Data.self, forKey: .responseDigest)
        self.signedOperation = try c.decodeIfPresent(Data.self, forKey: .signedOperation) ?? Data()
        self.committedRevision = try c.decode(Int64.self, forKey: .committedRevision)
        self.committedAt = try c.decode(Date.self, forKey: .committedAt)
        self.disposition = try c.decodeIfPresent(DurableOperationDisposition.self,
                                                  forKey: .disposition) ?? .accepted
    }
}

public struct DurableInvitationRecord: Codable, Hashable, Sendable {
    public let invitation: Invitation
    public var consumedAt: Date?

    public init(invitation: Invitation, consumedAt: Date? = nil) {
        self.invitation = invitation; self.consumedAt = consumedAt
    }
}

public struct DurablePairingRecord: Codable, Hashable, Sendable {
    public var pairing: Pairing
    public var revokedAt: Date?

    public init(pairing: Pairing, revokedAt: Date? = nil) {
        self.pairing = pairing; self.revokedAt = revokedAt
    }
}

public struct DurableSessionRecord: Codable, Hashable, Sendable {
    public let session: ActiveSession
    public let publishedAt: Date

    public init(session: ActiveSession, publishedAt: Date) {
        self.session = session; self.publishedAt = publishedAt
    }
}

public struct DurableRequestRecord: Codable, Hashable, Sendable {
    public var request: TrustedRequest
    public var cancelledAt: Date?
    public var expiredAt: Date?
    public var supersededAt: Date?

    public init(request: TrustedRequest, cancelledAt: Date? = nil, expiredAt: Date? = nil,
                supersededAt: Date? = nil) {
        self.request = request; self.cancelledAt = cancelledAt
        self.expiredAt = expiredAt; self.supersededAt = supersededAt
    }
}

/// Approval is immutable. Consumption is represented only by a separate use
/// row, allowing an auditor to prove the exact approval that was consumed.
public struct DurableApprovalRecord: Codable, Hashable, Sendable {
    public let approval: Approval
    public let acceptedAt: Date

    public init(approval: Approval, acceptedAt: Date) {
        self.approval = approval; self.acceptedAt = acceptedAt
    }
}

public struct DurableApprovalUseRecord: Codable, Hashable, Sendable {
    public let useID: String
    public let approvalID: String
    public let requestID: String
    public let usedAt: Date
    public let committedRevision: Int64

    public init(useID: String, approvalID: String, requestID: String, usedAt: Date,
                committedRevision: Int64) {
        self.useID = useID; self.approvalID = approvalID; self.requestID = requestID
        self.usedAt = usedAt; self.committedRevision = committedRevision
    }
}

public struct DurableRateLimitRecord: Codable, Hashable, Sendable {
    public var acceptedOperationTimes: [Date]

    public init(acceptedOperationTimes: [Date] = []) {
        self.acceptedOperationTimes = acceptedOperationTimes
    }
}

public struct DurableAuditEvent: Codable, Hashable, Sendable {
    public let revision: Int64
    public let operationID: String
    public let kind: String
    public let signerID: String
    public let occurredAt: Date
    public let outcome: String

    public init(revision: Int64, operationID: String, kind: String, signerID: String,
                occurredAt: Date, outcome: String) {
        self.revision = revision; self.operationID = operationID; self.kind = kind
        self.signerID = signerID; self.occurredAt = occurredAt; self.outcome = outcome
    }
}

public struct DurableOperationReceipt: Codable, Hashable, Sendable {
    public let operationID: String
    public let ownerID: String
    public let revision: Int64
    public let responseDigest: Data

    public init(operationID: String, ownerID: String, revision: Int64, responseDigest: Data) {
        self.operationID = operationID; self.ownerID = ownerID
        self.revision = revision; self.responseDigest = responseDigest
    }
}

public struct DurableSubmitResult: Sendable {
    public let result: RelayResult
    public let receipt: DurableOperationReceipt

    public init(result: RelayResult, receipt: DurableOperationReceipt) {
        self.result = result; self.receipt = receipt
    }
}

// MARK: - Store interface and deterministic transactional reference adapter

public enum DurableStoreError: Error, Equatable, Sendable {
    case crashBeforeCommit
    case crashAfterCommitBeforeAcknowledgement
    case invalidSnapshot
    case oversizedState
}

public enum DurableStoreFailurePoint: Sendable {
    case beforeCommit
    case afterCommitBeforeAcknowledgement
}

/// A store transaction must hold the owner partition lock from read through
/// commit. A SQL adapter should implement this contract with SERIALIZABLE (or
/// an equivalent owner-row lock), and must not acknowledge until COMMIT wins.
public protocol DurableRelayStore: Sendable {
    func read() throws -> DurableRelayDatabase
    func transaction<T>(_ body: (inout DurableRelayDatabase) throws -> T) throws -> T
}

/// This adapter is deliberately a strict reference implementation, not a
/// claimed production database. It provides atomic copy-on-write transactions,
/// restart snapshots, and crash injection for application-layer tests.
public final class InMemoryDurableRelayStore: DurableRelayStore, @unchecked Sendable {
    private let lock = NSLock()
    private var database: DurableRelayDatabase
    private var failurePoint: DurableStoreFailurePoint?

    public init() {
        self.database = DurableRelayDatabase()
    }

    init(database: DurableRelayDatabase) throws {
        try Self.validate(database)
        self.database = database
    }

    /// Unanchored snapshot decoding is test-only. Production callers must use
    /// the checkpoint overload below with an independently retained root.
    convenience init(snapshot data: Data) throws {
        let decoder = JSONDecoder()
        guard let database = try? decoder.decode(DurableRelayDatabase.self, from: data) else {
            throw DurableStoreError.invalidSnapshot
        }
        try Self.validate(database)
        try self.init(database: database)
    }

    public convenience init(snapshot data: Data, checkpoint: DurableCheckpoint) throws {
        let decoder = JSONDecoder()
        guard let database = try? decoder.decode(DurableRelayDatabase.self, from: data) else {
            throw DurableStoreError.invalidSnapshot
        }
        try Self.validate(database)
        try checkpoint.validate()
        let revisions = database.owners.mapValues(\.revision)
        guard revisions == checkpoint.ownerRevisions,
              try database.canonicalStateRoot() == checkpoint.stateRoot else {
            throw DurableStoreError.invalidSnapshot
        }
        try self.init(database: database)
    }

    public func read() throws -> DurableRelayDatabase {
        lock.lock(); defer { lock.unlock() }
        return database
    }

    public func snapshot() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(database)
    }

    /// Checkpoints are observational outputs and must be persisted by the
    /// embedding only after the transaction that produced this state commits.
    public func checkpoint() throws -> DurableCheckpoint {
        lock.lock(); defer { lock.unlock() }
        return try DurableCheckpoint(ownerRevisions: database.owners.mapValues(\.revision),
                                     stateRoot: database.canonicalStateRoot())
    }

    public func injectFailure(_ point: DurableStoreFailurePoint?) {
        lock.lock(); defer { lock.unlock() }
        failurePoint = point
    }

    public func transaction<T>(_ body: (inout DurableRelayDatabase) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var working = database
        let value = try body(&working)
        try Self.validate(working)
        switch failurePoint {
        case .beforeCommit:
            failurePoint = nil
            throw DurableStoreError.crashBeforeCommit
        case .afterCommitBeforeAcknowledgement:
            failurePoint = nil
            database = working
            throw DurableStoreError.crashAfterCommitBeforeAcknowledgement
        case nil:
            database = working
            return value
        }
    }

    static func validate(_ database: DurableRelayDatabase) throws {
        guard database.owners.count <= 10_000 else { throw DurableStoreError.oversizedState }
        for (ownerID, ledger) in database.owners {
            guard ownerID == ledger.owner.identityID, ledger.owner.role == .owner,
                  ledger.revision >= 0,
                  ledger.revision <= Int64(DurableRelayLimits.maxOperationRecords),
                  ledger.operations.count <= DurableRelayLimits.maxOperationRecords,
                  ledger.audit.count <= DurableRelayLimits.maxAuditEvents,
                  ledger.invitations.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.pendingAcceptances.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.pairings.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.sessions.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.requests.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.approvals.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.approvalUses.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.relationshipConsents.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.usedConsentNonces.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.usedApprovalIDs.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.usedApprovalNonces.count <= CompanionLimits.maxSnapshotRecords else {
                throw DurableStoreError.invalidSnapshot
            }
            try ledger.owner.validate()

            var operationRevisions = Set<Int64>()
            let ownerSignedKinds: Set<String> = ["ack", "invite", "consent", "session",
                                                   "request", "use", "cancel", "natural_end", "revoke",
                                                   "replace_pairing"]
            let approverSignedKinds: Set<String> = ["accept", "approval"]
            let responseKinds: [String: String] = [
                "ack": "acknowledgement", "invite": "invitation", "accept": "pairing",
                "consent": "consent", "session": "session",
                "request": "request", "approval": "approval", "use": "verification",
                "cancel": "acknowledgement", "natural_end": "acknowledgement",
                "revoke": "acknowledgement", "replace_pairing": "pairing"
            ]
            for (key, record) in ledger.operations {
                guard key == record.operationID, isValidIdentifier(record.operationID),
                      record.ownerID == ownerID,
                      responseKinds[record.kind] != nil,
                      record.committedRevision > 0, record.committedRevision <= ledger.revision,
                      operationRevisions.insert(record.committedRevision).inserted,
                      record.bodyDigest.count == 32, record.responseDigest.count == 32,
                      record.signedOperation.count > 0,
                      record.responseDigest == Data(SHA256.hash(data: record.responseBody)),
                      record.responseKind == (record.disposition == .rejectedExpiredRequest
                                              ? "acknowledgement" : responseKinds[record.kind]) else {
                    throw DurableStoreError.invalidSnapshot
                }
                let signed = try decodeDurableSignedOperation(record.signedOperation)
                guard signed.operationID == record.operationID,
                      signed.kind == record.kind,
                      signed.signer == record.signer,
                      record.bodyDigest == CompanionCanonical.digest(signed.body) else {
                    throw DurableStoreError.invalidSnapshot
                }
                try signed.validateSignature()
                try record.signer.validate()
                guard (ownerSignedKinds.contains(record.kind) && record.signer == ledger.owner)
                    || (approverSignedKinds.contains(record.kind) && record.signer.role == .trustedApprover)
                    || (record.kind == "consent" && record.signer.role == .trustedApprover) else {
                    throw DurableStoreError.invalidSnapshot
                }
                if record.disposition == .rejectedExpiredRequest {
                    guard record.responseBody == Data("{}".utf8),
                          record.kind == "approval" || record.kind == "use" || record.kind == "cancel" else {
                        throw DurableStoreError.invalidSnapshot
                    }
                } else {
                    do {
                        let result = try DurableResultCodec.decode(kind: record.responseKind,
                                                                    body: record.responseBody)
                        guard resultMatchesLedger(result, record: record, ledger: ledger) else {
                            throw DurableStoreError.invalidSnapshot
                        }
                    } catch let error as DurableStoreError {
                        throw error
                    } catch {
                        throw DurableStoreError.invalidSnapshot
                    }
                }
                try requireValidDate(record.committedAt)
            }
            if ledger.revision == 0 {
                guard operationRevisions.isEmpty else { throw DurableStoreError.invalidSnapshot }
            } else {
                guard operationRevisions == Set((1...Int(ledger.revision)).map(Int64.init)) else {
                    throw DurableStoreError.invalidSnapshot
                }
            }
            for (key, invitation) in ledger.invitations {
                guard key == invitation.invitation.payload.inviteID,
                      invitation.invitation.payload.owner == ledger.owner else {
                    throw DurableStoreError.invalidSnapshot
                }
                try invitation.invitation.validateSignature()
                if let consumedAt = invitation.consumedAt { try requireValidDate(consumedAt) }
            }
            for (key, acceptance) in ledger.pendingAcceptances {
                guard key == acceptance.acceptanceID, acceptance.owner == ledger.owner else {
                    throw DurableStoreError.invalidSnapshot
                }
                try acceptance.validate()
            }
            for (key, pairing) in ledger.pairings {
                guard key == pairing.pairing.pairingID, pairing.pairing.owner == ledger.owner else {
                    throw DurableStoreError.invalidSnapshot
                }
                try pairing.pairing.validate()
                if let revokedAt = pairing.revokedAt { try requireValidDate(revokedAt) }
            }
            for (key, epoch) in ledger.pairingEpochs {
                guard isValidIdentifier(key), epoch > 0, epoch < UInt64.max,
                      let pairing = ledger.pairings[key]?.pairing,
                      pairing.epoch == epoch else { throw DurableStoreError.invalidSnapshot }
            }
            for (key, session) in ledger.sessions {
                guard key == session.session.sessionID, session.session.owner == ledger.owner else {
                    throw DurableStoreError.invalidSnapshot
                }
                try session.session.validate(); try requireValidDate(session.publishedAt)
            }
            if let currentSessionID = ledger.currentSessionID {
                guard ledger.sessions[currentSessionID] != nil else { throw DurableStoreError.invalidSnapshot }
            }
            for (key, request) in ledger.requests {
                guard key == request.request.requestID, request.request.owner == ledger.owner else {
                    throw DurableStoreError.invalidSnapshot
                }
                try request.request.validateShapeForDurableStore()
                guard request.request.purpose == .approveEarlyEnd,
                      request.request.message == nil,
                      (request.request.consentGeneration > 0
                       && request.request.targetBindings.allSatisfy({ $0.consentGeneration > 0 })
                       || (request.request.status == .expired && request.request.consentGeneration == 0
                           && request.request.targetBindings.allSatisfy({ $0.consentGeneration == 0 }))) else {
                    throw DurableStoreError.invalidSnapshot
                }
                guard request.request.targetBindings.allSatisfy({ binding in
                    guard let pairing = ledger.pairings[binding.pairingID]?.pairing else { return false }
                    let stateIsCompatible = request.request.status == .pending || request.request.status == .approved
                        ? pairing.state == .active : true
                    return pairing.owner == ledger.owner
                        && pairing.approver.identityID == binding.approverIdentityID
                        && pairing.epoch == binding.pairEpoch
                        && stateIsCompatible
                }) else { throw DurableStoreError.invalidSnapshot }
                switch request.request.status {
                case .expired:
                    guard request.expiredAt != nil else { throw DurableStoreError.invalidSnapshot }
                case .cancelled:
                    guard request.cancelledAt != nil else { throw DurableStoreError.invalidSnapshot }
                default:
                    guard request.cancelledAt == nil, request.expiredAt == nil else {
                        throw DurableStoreError.invalidSnapshot
                    }
                }
                guard ledger.sessions[request.request.sessionID] != nil,
                      ledger.sessions[request.request.sessionID]?.session.activeSetID == request.request.activeSetID else {
                    throw DurableStoreError.invalidSnapshot
                }
                if let date = request.cancelledAt { try requireValidDate(date) }
                if let date = request.expiredAt { try requireValidDate(date) }
                if let date = request.supersededAt { try requireValidDate(date) }
            }
            for request in ledger.requests.values {
                let records = ledger.operations.values.filter { record in
                    guard record.kind == "request",
                          let signed = try? decodeDurableSignedOperation(record.signedOperation),
                          signed.signer == ledger.owner,
                          let envelope = try? JSONDecoder().decode(DurableOperationEnvelope.self, from: signed.body),
                          let initial = try? JSONDecoder().decode(TrustedRequest.self, from: envelope.payload) else { return false }
                    return initial.requestID == request.request.requestID
                }
                guard records.count == 1,
                      let record = records.first,
                      let signed = try? decodeDurableSignedOperation(record.signedOperation),
                      let envelope = try? JSONDecoder().decode(DurableOperationEnvelope.self, from: signed.body),
                      let initial = try? JSONDecoder().decode(TrustedRequest.self, from: envelope.payload),
                      requestImmutableFieldsMatch(request.request, initial),
                      initial.status == .pending,
                      initial.decisions.values.allSatisfy({ $0 == .pending }) else {
                    throw DurableStoreError.invalidSnapshot
                }
            }
            var approvalTargets: [String: Set<String>] = [:]
            var approvalNonces = Set<String>()
            for (key, approval) in ledger.approvals {
                guard key == approval.approval.approvalID else { throw DurableStoreError.invalidSnapshot }
                try approval.approval.validateSignature(); try requireValidDate(approval.acceptedAt)
                guard approval.approval.decision != .pending,
                      let request = ledger.requests[approval.approval.requestID]?.request,
                      request.sessionID == approval.approval.sessionID,
                      request.activeSetID == approval.approval.activeSetID,
                      request.binding(for: approval.approval.approver.identityID)?.pairingID == approval.approval.pairingID,
                      request.binding(for: approval.approval.approver.identityID)?.pairEpoch == approval.approval.pairEpoch,
                      request.binding(for: approval.approval.approver.identityID)?.consentGeneration == approval.approval.consentGeneration,
                      approvalTargets[approval.approval.requestID, default: []].insert(approval.approval.approver.identityID).inserted,
                      (approval.approval.nonce.isEmpty || approvalNonces.insert(durableBase64URL(approval.approval.nonce)).inserted) else {
                    throw DurableStoreError.invalidSnapshot
                }
            }
            guard ledger.usedApprovalNonces.isSuperset(of: approvalNonces.filter { !$0.isEmpty }) else {
                throw DurableStoreError.invalidSnapshot
            }
            for (key, consent) in ledger.relationshipConsents {
                guard key == consent.relationshipID, consent.owner == ledger.owner else {
                    throw DurableStoreError.invalidSnapshot
                }
                try consent.validate()
                guard let pairing = ledger.pairings[consent.pairingID]?.pairing,
                      pairing.owner == ledger.owner,
                      pairing.approver == consent.approver,
                      pairing.epoch == consent.pairEpoch else {
                    throw DurableStoreError.invalidSnapshot
                }
            }
            for nonce in ledger.usedConsentNonces {
                guard let data = durableDataFromBase64URL(nonce), data.count >= 16, data.count <= 64 else {
                    throw DurableStoreError.invalidSnapshot
                }
            }
            for approvalID in ledger.usedApprovalIDs {
                guard isValidIdentifier(approvalID) else { throw DurableStoreError.invalidSnapshot }
            }
            for nonce in ledger.usedApprovalNonces {
                guard let data = durableDataFromBase64URL(nonce), data.count >= 16, data.count <= 64 else {
                    throw DurableStoreError.invalidSnapshot
                }
            }
            for (key, use) in ledger.approvalUses {
                guard key == use.useID, isValidIdentifier(use.useID),
                      isValidIdentifier(use.approvalID), isValidIdentifier(use.requestID),
                      use.committedRevision > 0, use.committedRevision <= ledger.revision,
                      ledger.usedApprovalIDs.contains(use.useID), ledger.usedApprovalIDs.contains(use.approvalID),
                      ledger.approvals[use.approvalID]?.approval.requestID == use.requestID else {
                    throw DurableStoreError.invalidSnapshot
                }
                try requireValidDate(use.usedAt)
            }
            for (key, limit) in ledger.rateLimits {
                guard isValidIdentifier(key), limit.acceptedOperationTimes.count <= DurableRelayLimits.maxRateTimestamps,
                      limit.acceptedOperationTimes.allSatisfy({ $0.timeIntervalSince1970.isFinite }) else {
                    throw DurableStoreError.invalidSnapshot
                }
                for timestamp in limit.acceptedOperationTimes { try requireValidDate(timestamp) }
            }
            for event in ledger.audit {
                guard event.revision > 0, event.revision <= ledger.revision,
                      isValidIdentifier(event.operationID), isValidIdentifier(event.kind),
                      isValidIdentifier(event.signerID) else { throw DurableStoreError.invalidSnapshot }
                try requireValidDate(event.occurredAt)
            }
        }
    }
}

private func resultMatchesLedger(_ result: RelayResult,
                                 record: DurableOperationRecord,
                                 ledger: DurableOwnerLedger) -> Bool {
    switch result {
    case .invitation(let invitation):
        return ledger.invitations[invitation.payload.inviteID]?.invitation.payload.owner == ledger.owner
    case .consent(let consent):
        return ledger.relationshipConsents[consent.relationshipID]?.pairingID == consent.pairingID
            && ledger.relationshipConsents[consent.relationshipID]?.owner == ledger.owner
    case .acceptance(let acceptance):
        if let stored = ledger.pendingAcceptances[acceptance.acceptanceID] {
            return stored == acceptance && stored.owner == ledger.owner
        }
        let pairingID = durableBase64URL(Data(SHA256.hash(data: CompanionCanonical.bytes(
            domain: "\(CompanionCanonical.version).pairing",
            fields: [acceptance.inviteID, acceptance.approver.identityID])))).prefix(32).description
        return ledger.pairings[pairingID]?.pairing.owner == ledger.owner
            && ledger.pairings[pairingID]?.pairing.approver == acceptance.approver
    case .pairing(let pairing):
        return ledger.pairings[pairing.pairingID]?.pairing.epoch == pairing.epoch
            && ledger.pairings[pairing.pairingID]?.pairing.owner == ledger.owner
    case .session(let session):
        return ledger.sessions[session.sessionID]?.session.activeSetID == session.activeSetID
            && ledger.sessions[session.sessionID]?.session.owner == ledger.owner
    case .request(let request):
        return ledger.requests[request.requestID]?.request.sessionID == request.sessionID
            && ledger.requests[request.requestID]?.request.owner == ledger.owner
    case .approval(let approval):
        return ledger.approvals[approval.approvalID]?.approval.requestID == approval.requestID
            && ledger.approvals[approval.approvalID]?.approval.consentGeneration == approval.consentGeneration
    case .verification(let verification):
        guard let use = ledger.approvalUses[verification.useID],
              use.approvalID == verification.approval.approvalID,
              use.requestID == verification.approval.requestID else { return false }
        return ledger.usedApprovalIDs.contains(verification.useID)
            && ledger.usedApprovalIDs.contains(verification.approval.approvalID)
    case .acknowledgement:
        return true
    }
}

public enum DurableRelayLimits {
    public static let maxAuditEvents = 512
    public static let maxRateTimestamps = 30
    public static let rateWindow: TimeInterval = 60
    public static let maxOperationRecords = 10_000
}

private extension TrustedRequest {
    /// The protocol's persisted validator is intentionally package-internal;
    /// the service rechecks the public shape and all durable cross-references.
    func validateShapeForDurableStore() throws {
        try owner.validate()
        guard !requestID.isEmpty, requestID.utf8.count <= CompanionLimits.maxIdentifierLength,
              !sessionID.isEmpty, !activeSetID.isEmpty, !pairingID.isEmpty,
              pairEpoch > 0, !targetedApproverIDs.isEmpty,
              targetedApproverIDs.count <= CompanionLimits.maxTargets,
              targetedApproverIDs.count == targetBindings.count,
              Set(targetedApproverIDs).count == targetedApproverIDs.count,
              targetBindings.map(\.approverIdentityID) == targetedApproverIDs,
              targetBindings.first?.pairingID == pairingID,
              targetBindings.first?.pairEpoch == pairEpoch,
              targetBindings.first?.consentGeneration == consentGeneration,
              Set(decisions.keys) == Set(targetedApproverIDs), expiresAt > createdAt,
              expiresAt.timeIntervalSince(createdAt) <= CompanionLimits.maxRequestLifetime else {
            throw CompanionError.malformed("invalid durable request")
        }
        for target in targetedApproverIDs {
            guard !target.isEmpty, target.utf8.count <= CompanionLimits.maxIdentifierLength else {
                throw CompanionError.malformed("invalid durable target")
            }
            guard decisions[target] != nil else { throw CompanionError.malformed("missing durable decision") }
        }
        for binding in targetBindings { try binding.validateShape() }
        guard message == nil,
              (consentGeneration > 0 && targetBindings.allSatisfy({ $0.consentGeneration > 0 })
               || (status == .expired && consentGeneration == 0
                   && targetBindings.allSatisfy({ $0.consentGeneration == 0 }))) else {
            throw CompanionError.malformed("invalid durable request authority")
        }
        try requireValidDate(createdAt); try requireValidDate(expiresAt)
    }
}

private func requireValidDate(_ date: Date) throws {
    guard date.timeIntervalSince1970.isFinite, date >= Date(timeIntervalSince1970: 0),
          date <= Date(timeIntervalSince1970: 4_102_444_800) else {
        throw CompanionError.malformed("invalid durable date")
    }
}

private func decodeDurableSignedOperation(_ data: Data) throws -> SignedOperation {
    do { return try JSONDecoder().decode(SignedOperation.self, from: data) }
    catch { throw DurableStoreError.invalidSnapshot }
}

private func requestImmutableFieldsMatch(_ current: TrustedRequest, _ initial: TrustedRequest) -> Bool {
    current.requestID == initial.requestID && current.owner == initial.owner &&
    current.pairingID == initial.pairingID && current.pairEpoch == initial.pairEpoch &&
    current.consentGeneration == initial.consentGeneration && current.sessionID == initial.sessionID &&
    current.activeSetID == initial.activeSetID && current.purpose == initial.purpose &&
    current.targetedApproverIDs == initial.targetedApproverIDs &&
    current.targetBindings == initial.targetBindings && current.message == initial.message &&
    current.createdAt == initial.createdAt && current.expiresAt == initial.expiresAt
}

public extension DurableRelayDatabase {
    /// Canonical root for all owner partitions and all ledger fields. Set and
    /// dictionary members are explicitly sorted; no authority-bearing field
    /// is omitted from the root.
    func canonicalStateRoot() throws -> Data {
        func optional<T: Encodable>(_ value: T?) throws -> Data {
            guard let value else { return Data("null".utf8) }
            return try CompanionCanonical.encoded(value)
        }
        func dictionary<T: Encodable>(_ value: [String: T]) throws -> Data {
            var fields: [Data] = []
            for key in value.keys.sorted() {
                fields.append(try CompanionCanonical.encoded(key))
                fields.append(try CompanionCanonical.encoded(value[key]!))
            }
            return CompanionCanonical.framed(domain: "\(CompanionCanonical.version).state-dictionary", fields: fields)
        }
        func strings(_ value: Set<String>) throws -> Data {
            try CompanionCanonical.framed(domain: "\(CompanionCanonical.version).state-set",
                                          fields: value.sorted().map { try CompanionCanonical.encoded($0) })
        }
        func ledger(_ value: DurableOwnerLedger) throws -> Data {
            let fields: [Data] = [
                try CompanionCanonical.encoded(value.owner),
                try CompanionCanonical.encoded(value.revision),
                try dictionary(value.operations),
                try dictionary(value.invitations),
                try dictionary(value.pendingAcceptances),
                try dictionary(value.pairings),
                try dictionary(value.pairingEpochs),
                try dictionary(value.sessions),
                try optional(value.currentSessionID),
                try dictionary(value.requests),
                try dictionary(value.approvals),
                try dictionary(value.approvalUses),
                try dictionary(value.relationshipConsents),
                try strings(value.usedConsentNonces),
                try strings(value.usedApprovalIDs),
                try strings(value.usedApprovalNonces),
                try dictionary(value.rateLimits),
                try CompanionCanonical.framed(domain: "\(CompanionCanonical.version).state-audit",
                                              fields: value.audit.map { try CompanionCanonical.encoded($0) })
            ]
            return CompanionCanonical.framed(domain: "\(CompanionCanonical.version).owner-ledger", fields: fields)
        }
        var ownerFields: [Data] = []
        for ownerID in owners.keys.sorted() {
            ownerFields.append(try CompanionCanonical.encoded(ownerID))
            ownerFields.append(try ledger(owners[ownerID]!))
        }
        return CompanionCanonical.digest(CompanionCanonical.framed(
            domain: "\(CompanionCanonical.version).durable-state-root", fields: ownerFields))
    }
}
