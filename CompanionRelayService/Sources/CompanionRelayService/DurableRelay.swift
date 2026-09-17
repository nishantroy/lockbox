import Foundation
import CompanionKit

/// The service-core boundary for a durable mutation. The caller resolves the
/// owner from the authenticated request before invoking this method; the
/// mutation itself runs while that owner's ledger is exclusively locked.
public struct DurableAuthorizationPolicy: Sendable {
    public typealias ApproverAuthorization = @Sendable
        (_ operation: SignedOperation, _ owner: DeviceIdentity, _ ledger: DurableOwnerLedger) throws -> Bool
    public typealias ScopedAuthorization = @Sendable
        (_ operation: SignedOperation, _ envelope: DurableOperationEnvelope,
         _ owner: DeviceIdentity, _ ledger: DurableOwnerLedger, _ scope: CompanionScope) throws -> Bool

    private let ownerOnlyKinds: Set<String>
    private let approverKinds: Set<String>
    private let approverAuthorization: ApproverAuthorization
    private let requiredScopes: [String: CompanionScope]
    private let scopedAuthorization: ScopedAuthorization?

    public init(ownerOnlyKinds: Set<String>, approverKinds: Set<String>,
                requiredScopes: [String: CompanionScope] = [:],
                approverAuthorization: @escaping ApproverAuthorization,
                scopedAuthorization: ScopedAuthorization? = nil) {
        self.ownerOnlyKinds = ownerOnlyKinds
        self.approverKinds = approverKinds
        var effectiveScopes = requiredScopes
        if effectiveScopes["request"] == nil { effectiveScopes["request"] = .approveEarlyEnd }
        if effectiveScopes["approval"] == nil { effectiveScopes["approval"] = .approveEarlyEnd }
        self.requiredScopes = effectiveScopes
        self.approverAuthorization = approverAuthorization
        self.scopedAuthorization = scopedAuthorization
    }

    /// Source-compatible initializer for existing relay adapters that supply
    /// only pairing authorization.
    public init(ownerOnlyKinds: Set<String>, approverKinds: Set<String>,
                approverAuthorization: @escaping ApproverAuthorization) {
        self.init(ownerOnlyKinds: ownerOnlyKinds, approverKinds: approverKinds,
                  requiredScopes: [:], approverAuthorization: approverAuthorization,
                  scopedAuthorization: nil)
    }

    /// Safe default for the reference tests: only the explicitly listed kind
    /// can be submitted, and it must be signed by the target owner.
    public static func ownerOnly(kinds: Set<String> = ["ack"],
                                 requiredScopes: [String: CompanionScope] = [:]) -> Self {
        Self(ownerOnlyKinds: kinds, approverKinds: [], requiredScopes: requiredScopes,
             approverAuthorization: { _, _, _ in false }, scopedAuthorization: { operation, envelope, owner, ledger, scope in
                 try Self.authorizeScope(operation: operation, envelope: envelope,
                                         owner: owner, ledger: ledger, scope: scope)
             })
    }

    /// Convenience policy for operations whose approver must have an active,
    /// validated pairing in the target owner's ledger.
    public static func ownerAndActivePairing(ownerOnlyKinds: Set<String> = ["ack"],
                                             approverKinds: Set<String>,
                                             requiredScopes: [String: CompanionScope] = [:]) -> Self {
        Self(ownerOnlyKinds: ownerOnlyKinds, approverKinds: approverKinds,
             requiredScopes: requiredScopes,
             approverAuthorization: { operation, owner, ledger in
            guard operation.signer.role == .trustedApprover else { return false }
            return ledger.pairings.values.contains { record in
                record.pairing.owner == owner && record.pairing.approver == operation.signer &&
                record.pairing.state == .active && (try? record.pairing.validate()) != nil
            }
        }, scopedAuthorization: { operation, envelope, owner, ledger, scope in
            try DurableAuthorizationPolicy.authorizeScope(operation: operation, envelope: envelope,
                                                          owner: owner, ledger: ledger, scope: scope)
        })
    }

    fileprivate func authorize(operation: SignedOperation, envelope: DurableOperationEnvelope,
                               owner: DeviceIdentity, ledger: DurableOwnerLedger) throws {
        let ownerOperation = ownerOnlyKinds.contains(operation.kind)
        let approverOperation = approverKinds.contains(operation.kind)
        guard ownerOperation != approverOperation else {
            throw DurableRelayError.unsupportedOperation(operation.kind)
        }
        if ownerOperation {
            guard operation.signer == owner else { throw DurableRelayError.unauthorized }
        } else {
            guard operation.signer.role == .trustedApprover,
                  try approverAuthorization(operation, owner, ledger) else {
                throw DurableRelayError.unauthorized
            }
        }
        if let scope = requiredScopes[operation.kind] {
            guard scope.isR5, let scopedAuthorization,
                  try scopedAuthorization(operation, envelope, owner, ledger, scope) else {
                throw DurableRelayError.unauthorized
            }
        }
    }

    private static func authorizeScope(operation: SignedOperation,
                                       envelope: DurableOperationEnvelope,
                                       owner: DeviceIdentity,
                                       ledger: DurableOwnerLedger,
                                       scope: CompanionScope) throws -> Bool {
        guard scope.isR5 else { return false }
        let decoder = JSONDecoder()
        if operation.kind == "request" {
            guard let request = try? decoder.decode(TrustedRequest.self, from: envelope.payload),
                  request.owner == owner, request.purpose == .approveEarlyEnd else { return false }
            return request.targetBindings.allSatisfy { binding in
                guard let pairing = ledger.pairings[binding.pairingID]?.pairing,
                      pairing.owner == owner, pairing.state == .active,
                      pairing.epoch == binding.pairEpoch,
                      pairing.approver.identityID == binding.approverIdentityID,
                      let consent = ledger.relationshipConsents[binding.pairingID],
                      consent.pairEpoch == binding.pairEpoch else { return false }
                return consent.authorizes(scope)
                    && consent.authorizes(.approveEarlyEnd)
                    && consent.authorizes(.receiveRequests)
            }
        }
        if operation.kind == "approval" {
            guard let approval = try? decoder.decode(Approval.self, from: envelope.payload),
                  approval.approver.role == .trustedApprover,
                  approval.nonce.count >= 16,
                  let pairing = ledger.pairings[approval.pairingID]?.pairing,
                  pairing.owner == owner, pairing.state == .active,
                  pairing.approver == approval.approver, pairing.epoch == approval.pairEpoch,
                  let consent = ledger.relationshipConsents[approval.pairingID],
                  consent.pairEpoch == approval.pairEpoch else { return false }
            return consent.authorizes(scope)
                && consent.authorizes(.approveEarlyEnd)
                && consent.authorizes(.receiveRequests)
        }
        // No R5 scope authorizes delivery, summaries, start, extension, or
        // rule changes through a generic durable operation.
        return false
    }
}

public final class DurableRelayService: @unchecked Sendable {
    public let store: any DurableRelayStore
    public let authorization: DurableAuthorizationPolicy

    public init(store: any DurableRelayStore,
                authorization: DurableAuthorizationPolicy = .ownerOnly()) {
        self.store = store
        self.authorization = authorization
    }

    /// Applies one signed mutation and records its response in the same store
    /// transaction. A retry of an already committed operation returns the
    /// recorded response without invoking `mutation` again.
    ///
    /// The owner argument is deliberately explicit. It prevents a revision or
    /// operation ID in one owner's partition from authorizing a mutation in a
    /// different partition.
    public func submit(
        _ operation: SignedOperation,
        owner: DeviceIdentity,
        mutation: (inout DurableOwnerLedger, DurableOperationEnvelope) throws -> RelayResult
    ) throws -> DurableSubmitResult {
        try operation.validateSignature()
        guard owner.role == .owner else { throw DurableRelayError.unknownOwner }
        try owner.validate()

        let envelope: DurableOperationEnvelope
        do {
            let decoded = try JSONDecoder().decode(DurableOperationEnvelope.self, from: operation.body)
            envelope = try DurableOperationEnvelope(operationID: decoded.operationID,
                                                   expectedRevision: decoded.expectedRevision,
                                                   payload: decoded.payload)
        } catch let error as DurableRelayError {
            throw error
        } catch {
            throw DurableRelayError.invalidEnvelope
        }

        let bodyDigest = CompanionCanonical.digest(operation.body)
        return try store.transaction { database in
            var ledger = try ledger(for: owner, in: &database)
            try authorization.authorize(operation: operation, envelope: envelope, owner: owner, ledger: ledger)

            if let prior = ledger.operations[envelope.operationID] {
                guard prior.ownerID == owner.identityID,
                      prior.kind == operation.kind,
                      prior.signer == operation.signer,
                      prior.bodyDigest == bodyDigest else {
                    throw DurableRelayError.idempotencyConflict
                }
                guard prior.responseDigest == CompanionCanonical.digest(prior.responseBody) else {
                    throw DurableRelayError.responseCorrupt
                }
                let result = try DurableResultCodec.decode(kind: prior.responseKind,
                                                            body: prior.responseBody)
                let receipt = DurableOperationReceipt(operationID: prior.operationID,
                                                      ownerID: prior.ownerID,
                                                      revision: prior.committedRevision,
                                                      responseDigest: prior.responseDigest)
                return DurableSubmitResult(result: result, receipt: receipt)
            }

            guard envelope.expectedRevision == ledger.revision else {
                throw DurableRelayError.staleRevision(expected: envelope.expectedRevision,
                                                       actual: ledger.revision)
            }
            let baseRevision = ledger.revision
            guard baseRevision < Int64.max else { throw DurableRelayError.revisionOverflow }

            let result = try mutation(&ledger, envelope)
            guard ledger.revision == baseRevision else {
                throw DurableRelayError.mutationChangedRevision(expected: baseRevision,
                                                                 actual: ledger.revision)
            }
            let encoded = try DurableResultCodec.encode(result)
            let committedRevision = baseRevision + 1
            let record = DurableOperationRecord(
                operationID: envelope.operationID,
                ownerID: owner.identityID,
                signer: operation.signer,
                kind: operation.kind,
                bodyDigest: bodyDigest,
                responseKind: encoded.kind,
                responseBody: encoded.body,
                responseDigest: CompanionCanonical.digest(encoded.body),
                committedRevision: committedRevision,
                committedAt: Date()
            )
            ledger.revision = committedRevision
            ledger.operations[record.operationID] = record
            guard ledger.operations.count <= DurableRelayLimits.maxOperationRecords else {
                throw DurableStoreError.oversizedState
            }
            database.owners[owner.identityID] = ledger
            try InMemoryDurableRelayStore.validate(database)
            let receipt = DurableOperationReceipt(operationID: record.operationID,
                                                  ownerID: record.ownerID,
                                                  revision: record.committedRevision,
                                                  responseDigest: record.responseDigest)
            return DurableSubmitResult(result: result, receipt: receipt)
        }
    }

    private func ledger(for owner: DeviceIdentity,
                        in database: inout DurableRelayDatabase) throws -> DurableOwnerLedger {
        if let ledger = database.owners[owner.identityID] {
            guard ledger.owner == owner else { throw DurableRelayError.ambiguousOwner }
            return ledger
        }
        return DurableOwnerLedger(owner: owner)
    }
}

private enum DurableResultCodec {
    struct Encoded {
        let kind: String
        let body: Data
    }

    static func encode(_ result: RelayResult) throws -> Encoded {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch result {
        case .invitation(let value): return Encoded(kind: "invitation", body: try encoder.encode(value))
        case .consent(let value): return Encoded(kind: "consent", body: try encoder.encode(value))
        case .acceptance(let value): return Encoded(kind: "acceptance", body: try encoder.encode(value))
        case .pairing(let value): return Encoded(kind: "pairing", body: try encoder.encode(value))
        case .session(let value): return Encoded(kind: "session", body: try encoder.encode(value))
        case .request(let value): return Encoded(kind: "request", body: try encoder.encode(value))
        case .approval(let value): return Encoded(kind: "approval", body: try encoder.encode(value))
        case .verification(let value): return Encoded(kind: "verification", body: try encoder.encode(value))
        case .acknowledgement:
            return Encoded(kind: "acknowledgement", body: Data("{}".utf8))
        }
    }

    static func decode(kind: String, body: Data) throws -> RelayResult {
        let decoder = JSONDecoder()
        do {
            switch kind {
            case "invitation": return .invitation(try decoder.decode(Invitation.self, from: body))
            case "consent": return .consent(try decoder.decode(RelationshipConsent.self, from: body))
            case "acceptance": return .acceptance(try decoder.decode(PairingAcceptance.self, from: body))
            case "pairing": return .pairing(try decoder.decode(Pairing.self, from: body))
            case "session": return .session(try decoder.decode(ActiveSession.self, from: body))
            case "request": return .request(try decoder.decode(TrustedRequest.self, from: body))
            case "approval": return .approval(try decoder.decode(Approval.self, from: body))
            case "verification": return .verification(try decoder.decode(ApprovalVerification.self, from: body))
            case "acknowledgement":
                guard body == Data("{}".utf8) else { throw DurableRelayError.responseCorrupt }
                return .acknowledgement
            default: throw DurableRelayError.responseCorrupt
            }
        } catch let error as DurableRelayError {
            throw error
        } catch {
            throw DurableRelayError.responseCorrupt
        }
    }
}

// MARK: - PostgreSQL adapter contract

/// Contract for a future hosted adapter. This declaration documents the
/// relational uniqueness and locking requirements without adding a database
/// driver, listener, HTTP endpoint, or deployment configuration.
public enum PostgreSQLDurableStoreContract {
    public static let schemaSQL = """
    CREATE TABLE companion_owner (
        owner_id TEXT PRIMARY KEY,
        owner_identity JSONB NOT NULL,
        revision BIGINT NOT NULL CHECK (revision >= 0),
        state JSONB NOT NULL
    );

    CREATE TABLE companion_operation (
        owner_id TEXT NOT NULL REFERENCES companion_owner(owner_id),
        operation_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        signer_identity JSONB NOT NULL,
        request_digest BYTEA NOT NULL CHECK (octet_length(request_digest) = 32),
        response_kind TEXT NOT NULL,
        response_body BYTEA NOT NULL CHECK (octet_length(response_body) <= 32768),
        response_digest BYTEA NOT NULL CHECK (octet_length(response_digest) = 32),
        committed_revision BIGINT NOT NULL CHECK (committed_revision > 0),
        committed_at TIMESTAMPTZ NOT NULL,
        PRIMARY KEY (owner_id, operation_id),
        UNIQUE (owner_id, committed_revision)
    );
    """

    /// Executable transaction template. The adapter binds the numbered
    /// parameters documented below and supplies the already validated state
    /// produced by the service-core mutation.
    public static let transactionSQL = """
    BEGIN;
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

    INSERT INTO companion_owner (owner_id, owner_identity, revision, state)
    VALUES ($1, $2::jsonb, 0, $3::jsonb)
    ON CONFLICT (owner_id) DO NOTHING;

    SELECT owner_id, owner_identity, revision, state
      FROM companion_owner
     WHERE owner_id = $1
     FOR UPDATE;

    SELECT operation_id, kind, signer_identity, request_digest,
           response_kind, response_body, response_digest, committed_revision,
           committed_at
      FROM companion_operation
     WHERE owner_id = $1 AND operation_id = $4;

    -- If the operation row exists, compare kind, signer_identity, and
    -- request_digest. Return its response after COMMIT without mutating state.
    -- For a new operation, the service checks expected_revision against the
    -- locked revision and binds the following values:
    -- $5 new JSON state, $6 response kind, $7 response body, $8 response
    -- digest, $9 request digest, $10 kind, $11 signer JSON, $12 timestamp,
    -- $13 committed revision (locked revision + 1).
    UPDATE companion_owner
       SET state = $5::jsonb, revision = $13
     WHERE owner_id = $1 AND revision = $13 - 1;

    INSERT INTO companion_operation (
        owner_id, operation_id, kind, signer_identity, request_digest,
        response_kind, response_body, response_digest, committed_revision,
        committed_at
    ) VALUES ($1, $4, $10, $11::jsonb, $9, $6, $7, $8, $13, $12::timestamptz);

    COMMIT;
    -- Acknowledgement is emitted only after COMMIT succeeds. On SQLSTATE
    -- 40001 (serialization_failure), ROLLBACK and retry the complete
    -- transaction with the same operation ID and expected revision.
    """

    public static let parameterContract = "owner, ownerIdentityJSON, initialStateJSON, operationID, newStateJSON, responseKind, responseBody, responseDigest, requestDigest, kind, signerIdentityJSON, committedAt, committedRevision"
    public static let serializationRetrySQLState = "40001"
    public static let isolationLevel = "SERIALIZABLE with complete-transaction retry on SQLSTATE 40001"
}

public extension DurableOperationRecord {
    /// Name used by the service contract for the digest of the signed request
    /// body. `bodyDigest` remains the stored source-compatible field.
    var requestDigest: Data { bodyDigest }
}