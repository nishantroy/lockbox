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

public struct DurableOwnerLedger: Codable, Sendable {
    public let owner: DeviceIdentity
    public var revision: Int64
    public var operations: [String: DurableOperationRecord]
    public var invitations: [String: DurableInvitationRecord]
    public var pendingAcceptances: [String: PairingAcceptance]
    public var pairings: [String: DurablePairingRecord]
    public var pairingEpochs: [String: UInt64]
    public var sessions: [String: DurableSessionRecord]
    public var currentSessionID: String?
    public var requests: [String: DurableRequestRecord]
    public var approvals: [String: DurableApprovalRecord]
    public var approvalUses: [String: DurableApprovalUseRecord]
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
        self.rateLimits = rateLimits
        self.audit = audit
    }
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
    public let committedRevision: Int64
    public let committedAt: Date

    public init(operationID: String, ownerID: String, signer: DeviceIdentity, kind: String,
                bodyDigest: Data, responseKind: String, responseBody: Data,
                responseDigest: Data, committedRevision: Int64, committedAt: Date) {
        self.operationID = operationID; self.ownerID = ownerID; self.signer = signer
        self.kind = kind; self.bodyDigest = bodyDigest; self.responseKind = responseKind
        self.responseBody = responseBody; self.responseDigest = responseDigest
        self.committedRevision = committedRevision; self.committedAt = committedAt
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

    public init(database: DurableRelayDatabase) throws {
        try Self.validate(database)
        self.database = database
    }

    public convenience init(snapshot data: Data) throws {
        let decoder = JSONDecoder()
        guard let database = try? decoder.decode(DurableRelayDatabase.self, from: data) else {
            throw DurableStoreError.invalidSnapshot
        }
        try Self.validate(database)
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
                  ledger.revision >= 0, ledger.operations.count <= DurableRelayLimits.maxOperationRecords,
                  ledger.audit.count <= DurableRelayLimits.maxAuditEvents,
                  ledger.invitations.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.pendingAcceptances.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.pairings.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.sessions.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.requests.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.approvals.count <= CompanionLimits.maxSnapshotRecords,
                  ledger.approvalUses.count <= CompanionLimits.maxSnapshotRecords else {
                throw DurableStoreError.invalidSnapshot
            }
            try ledger.owner.validate()

            for (key, record) in ledger.operations {
                guard key == record.operationID, record.ownerID == ownerID,
                      record.committedRevision > 0, record.committedRevision <= ledger.revision,
                      record.bodyDigest.count == 32, record.responseDigest.count == 32,
                      record.responseDigest == Data(SHA256.hash(data: record.responseBody)) else {
                    throw DurableStoreError.invalidSnapshot
                }
                try record.signer.validate()
                try requireValidDate(record.committedAt)
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
                guard isValidIdentifier(key), epoch > 0 else { throw DurableStoreError.invalidSnapshot }
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
                if let date = request.cancelledAt { try requireValidDate(date) }
                if let date = request.expiredAt { try requireValidDate(date) }
                if let date = request.supersededAt { try requireValidDate(date) }
            }
            for (key, approval) in ledger.approvals {
                guard key == approval.approval.approvalID else { throw DurableStoreError.invalidSnapshot }
                try approval.approval.validateSignature(); try requireValidDate(approval.acceptedAt)
            }
            for (key, use) in ledger.approvalUses {
                guard key == use.useID, isValidIdentifier(use.useID),
                      isValidIdentifier(use.approvalID), isValidIdentifier(use.requestID),
                      use.committedRevision > 0, use.committedRevision <= ledger.revision else {
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
              targetedApproverIDs.count == targetBindings.count,
              Set(targetedApproverIDs).count == targetedApproverIDs.count,
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
        if let message = message, message.isEmpty || message.utf8.count > CompanionLimits.maxMessageBytes {
            throw CompanionError.malformed("invalid durable message")
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
