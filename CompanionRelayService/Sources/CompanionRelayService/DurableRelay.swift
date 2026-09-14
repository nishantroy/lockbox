import Foundation
import CompanionKit

/// The service-core boundary for a durable mutation. The caller resolves the
/// owner from the authenticated request before invoking this method; the
/// mutation itself runs while that owner's ledger is exclusively locked.
public final class DurableRelayService: @unchecked Sendable {
    public let store: any DurableRelayStore

    public init(store: any DurableRelayStore) {
        self.store = store
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
            guard ledger.revision < Int64.max else { throw DurableRelayError.revisionOverflow }

            let result = try mutation(&ledger, envelope)
            let encoded = try DurableResultCodec.encode(result)
            let committedRevision = ledger.revision + 1
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
        revision BIGINT NOT NULL CHECK (revision >= 0)
    );

    CREATE TABLE companion_operation (
        owner_id TEXT NOT NULL REFERENCES companion_owner(owner_id),
        operation_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        signer_identity JSONB NOT NULL,
        request_digest BYTEA NOT NULL CHECK (octet_length(request_digest) = 32),
        response_kind TEXT NOT NULL,
        response_body BYTEA NOT NULL,
        response_digest BYTEA NOT NULL CHECK (octet_length(response_digest) = 32),
        committed_revision BIGINT NOT NULL CHECK (committed_revision > 0),
        committed_at TIMESTAMPTZ NOT NULL,
        PRIMARY KEY (owner_id, operation_id),
        UNIQUE (owner_id, committed_revision)
    );
    """

    public static let transactionSQL = """
    -- Every mutation, including the idempotency record, is one transaction.
    BEGIN;
    SELECT revision FROM companion_owner WHERE owner_id = $1 FOR UPDATE;
    -- Missing owner rows are inserted with revision 0 under the same transaction.
    SELECT kind, signer_identity, request_digest, response_kind, response_body,
           response_digest, committed_revision
      FROM companion_operation
     WHERE owner_id = $1 AND operation_id = $2;
    -- If found: require kind, signer identity, and request_digest to match;
    -- return the stored response without invoking the mutation.
    -- Otherwise require expected_revision = locked owner.revision.
    -- Apply the mutation, increment revision, insert operation, then:
    UPDATE companion_owner SET revision = $new_revision WHERE owner_id = $1;
    COMMIT;
    -- Send the acknowledgement only after COMMIT succeeds. A retry after a
    -- lost acknowledgement finds the committed operation above.
    """

    public static let isolationLevel = "SERIALIZABLE (or an equivalent owner-row FOR UPDATE lock)"
}

public extension DurableOperationRecord {
    /// Name used by the service contract for the digest of the signed request
    /// body. `bodyDigest` remains the stored source-compatible field.
    var requestDigest: Data { bodyDigest }
}