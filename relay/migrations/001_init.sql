-- R5 relay schema. Mirrors the relational contract sketched by the Swift
-- reference implementation in
-- CompanionRelayService/Sources/CompanionRelayService/DurableRelay.swift
-- (`PostgreSQLDurableStoreContract`): one row per owner partition holding the
-- current revision and protocol state, and an append-only per-owner
-- operation log used for idempotent receipts and the durable audit trail.
--
-- `state` is a TEXT column (not a native jsonb column) so the relay controls
-- (de)serialization itself -- in particular, restoring Buffer-valued fields
-- from a `{"$b64": "..."}` marker (see src/ledger.ts) -- instead of relying
-- on the driver's automatic jsonb <-> JS object conversion.

CREATE TABLE IF NOT EXISTS companion_owner (
    owner_id TEXT PRIMARY KEY,
    owner_role TEXT NOT NULL CHECK (owner_role = 'owner'),
    owner_public_key BYTEA NOT NULL CHECK (octet_length(owner_public_key) = 32),
    revision BIGINT NOT NULL CHECK (revision >= 0),
    state TEXT NOT NULL,
    state_root BYTEA NOT NULL CHECK (octet_length(state_root) = 32),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS companion_operation (
    owner_id TEXT NOT NULL REFERENCES companion_owner(owner_id) ON DELETE CASCADE,
    operation_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    signer_identity_id TEXT NOT NULL,
    signer_role TEXT NOT NULL,
    signer_public_key BYTEA NOT NULL CHECK (octet_length(signer_public_key) = 32),
    body_digest BYTEA NOT NULL CHECK (octet_length(body_digest) = 32),
    signed_operation BYTEA NOT NULL CHECK (octet_length(signed_operation) <= 40960),
    response_kind TEXT NOT NULL,
    response_body BYTEA NOT NULL CHECK (octet_length(response_body) <= 40960),
    response_digest BYTEA NOT NULL CHECK (octet_length(response_digest) = 32),
    disposition TEXT NOT NULL CHECK (disposition IN ('accepted', 'rejectedExpiredRequest')),
    -- Canonical owner state root immediately after this operation committed.
    -- Persisted per-operation (not just on companion_owner) so a later
    -- idempotent replay of this exact operationID can report the
    -- (revision, stateRoot) pair as it was at THIS commit, not the owner's
    -- current (possibly further-advanced) state.
    state_root_after BYTEA NOT NULL CHECK (octet_length(state_root_after) = 32),
    committed_revision BIGINT NOT NULL CHECK (committed_revision > 0),
    committed_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (owner_id, operation_id),
    UNIQUE (owner_id, committed_revision)
);

CREATE INDEX IF NOT EXISTS companion_operation_committed_at_idx ON companion_operation (committed_at);

-- Retention bookkeeping: a compact table of terminal-record markers so the
-- purge job (src/retention.ts) can find records older than the retention
-- window without deserializing every owner's full state blob. A row here
-- represents one terminal sub-record (a request, a revoked pairing, a fully
-- revoked consent, a used approval/consent nonce, ...); the purge job deletes
-- both this marker and the corresponding entry inside `companion_owner.state`
-- in the same transaction.
CREATE TABLE IF NOT EXISTS companion_retention_marker (
    owner_id TEXT NOT NULL REFERENCES companion_owner(owner_id) ON DELETE CASCADE,
    record_kind TEXT NOT NULL,
    record_id TEXT NOT NULL,
    terminal_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (owner_id, record_kind, record_id)
);

CREATE INDEX IF NOT EXISTS companion_retention_marker_terminal_at_idx ON companion_retention_marker (terminal_at);

-- Cross-owner routing index. The relay is multi-tenant (many owner
-- partitions in one deployment), but a pairing's approver identity is not
-- itself an owner partition key, and two things need to resolve "which
-- owner(s) is/are relevant to this trusted-approver identity" without a full
-- table scan:
--   - "approval" (an approver-signed operation) carries `pairingID` but not
--     the owner identity, so this index resolves the target owner from
--     `pairingID` before the owning transaction begins.
--   - `POST /v1/inbox` for a trusted approver spans every owner they are
--     paired with (to list requests targeting them and to report their
--     pairings/consents), so this index finds those owners without scanning
--     every owner ledger.
-- Populated when a pairing is created ("confirm" or "replace_pairing"), in
-- the same database transaction as the owner-ledger update, and removed by
-- the retention job together with the pairing it describes.

CREATE TABLE IF NOT EXISTS companion_approver_pairing (
    pairing_id TEXT PRIMARY KEY,
    approver_identity_id TEXT NOT NULL,
    owner_id TEXT NOT NULL REFERENCES companion_owner(owner_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS companion_approver_pairing_approver_idx ON companion_approver_pairing (approver_identity_id);
