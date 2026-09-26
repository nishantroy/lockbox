// Postgres access layer. Implements the transactional contract sketched by
// `PostgreSQLDurableStoreContract` in
// CompanionRelayService/Sources/CompanionRelayService/DurableRelay.swift:
// one transaction per mutation, locking the owner's ledger row with
// `SELECT ... FOR UPDATE`, then committing the new state/revision together
// with the operation's durable receipt.

import pg from "pg";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import type { DeviceIdentity } from "./protocol.js";
import { deserializeLedger, serializeLedger, type Ledger } from "./ledger.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
export const MIGRATIONS_DIR = join(__dirname, "..", "migrations");

let pool: pg.Pool | undefined;

export function getPool(): pg.Pool {
  if (!pool) {
    const connectionString = process.env.DATABASE_URL;
    if (!connectionString) throw new Error("DATABASE_URL is not set");
    pool = new pg.Pool({ connectionString, max: 10 });
  }
  return pool;
}

export async function closePool(): Promise<void> {
  if (pool) {
    await pool.end();
    pool = undefined;
  }
}

export async function migrate(client: pg.Pool | pg.PoolClient = getPool()): Promise<void> {
  await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())`);
  const files = readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith(".sql"))
    .sort();
  for (const file of files) {
    const already = await client.query("SELECT 1 FROM schema_migrations WHERE name = $1", [file]);
    if ((already.rowCount ?? 0) > 0) continue;
    const sql = readFileSync(join(MIGRATIONS_DIR, file), "utf8");
    await client.query("BEGIN");
    try {
      await client.query(sql);
      await client.query("INSERT INTO schema_migrations (name) VALUES ($1)", [file]);
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    }
  }
}

export interface OwnerRow {
  ownerID: string;
  publicKey: Buffer;
  revision: number;
  ledger: Ledger;
  storedStateRoot: Buffer;
}

/**
 * Locks (creating if absent) and returns the owner's ledger row. Must be
 * called inside an open transaction (`BEGIN` already issued on `client`);
 * the caller commits or rolls back.
 */
export async function lockOwnerRow(client: pg.PoolClient, owner: DeviceIdentity, emptyLedgerFor: (o: DeviceIdentity) => Ledger, computeStateRoot: (ledger: Ledger, revision: number) => Buffer): Promise<OwnerRow> {
  await client.query(
    `INSERT INTO companion_owner (owner_id, owner_role, owner_public_key, revision, state, state_root)
     VALUES ($1, 'owner', $2, 0, $3, $4)
     ON CONFLICT (owner_id) DO NOTHING`,
    [owner.identityID, owner.publicKey, serializeLedger(emptyLedgerFor(owner)), computeStateRoot(emptyLedgerFor(owner), 0)]
  );
  const result = await client.query<{ owner_id: string; owner_public_key: Buffer; revision: string; state: string; state_root: Buffer }>(
    `SELECT owner_id, owner_public_key, revision, state, state_root FROM companion_owner WHERE owner_id = $1 FOR UPDATE`,
    [owner.identityID]
  );
  const row = result.rows[0];
  if (!row) throw new Error("owner row missing after insert");
  if (!row.owner_public_key.equals(owner.publicKey)) {
    // Ambiguous owner: the identity ID hash collided with a different public
    // key. Mirrors `DurableRelayError.ambiguousOwner`.
    throw new AmbiguousOwnerError();
  }
  return { ownerID: row.owner_id, publicKey: row.owner_public_key, revision: Number(row.revision), ledger: deserializeLedger(row.state), storedStateRoot: row.state_root };
}

/** Read-only owner ledger fetch (no row lock), used for inbox queries. */
export async function readOwnerLedger(client: pg.Pool | pg.PoolClient, ownerID: string): Promise<OwnerRow | null> {
  const result = await client.query<{ owner_id: string; owner_public_key: Buffer; revision: string; state: string; state_root: Buffer }>(
    `SELECT owner_id, owner_public_key, revision, state, state_root FROM companion_owner WHERE owner_id = $1`,
    [ownerID]
  );
  const row = result.rows[0];
  if (!row) return null;
  return { ownerID: row.owner_id, publicKey: row.owner_public_key, revision: Number(row.revision), ledger: deserializeLedger(row.state), storedStateRoot: row.state_root };
}

export class AmbiguousOwnerError extends Error {
  constructor() {
    super("ambiguous_owner");
  }
}

export async function saveOwnerRow(client: pg.PoolClient, ownerID: string, previousRevision: number, newRevision: number, ledger: Ledger, stateRoot: Buffer): Promise<void> {
  const result = await client.query(
    `UPDATE companion_owner SET revision = $1, state = $2, state_root = $3, updated_at = now()
     WHERE owner_id = $4 AND revision = $5`,
    [newRevision, serializeLedger(ledger), stateRoot, ownerID, previousRevision]
  );
  if (result.rowCount !== 1) {
    // Another transaction committed first; this is the "exactly one of two
    // concurrent same-revision mutations wins" case (see test/race.test.ts).
    throw new OwnerRowConflictError();
  }
}

export class OwnerRowConflictError extends Error {
  constructor() {
    super("owner_row_conflict");
  }
}

export interface StoredOperation {
  operationID: string;
  ownerID: string;
  kind: string;
  signerIdentityID: string;
  signerRole: string;
  signerPublicKey: Buffer;
  bodyDigest: Buffer;
  signedOperation: Buffer;
  responseKind: string;
  responseBody: Buffer;
  responseDigest: Buffer;
  disposition: "accepted" | "rejectedExpiredRequest";
  stateRootAfter: Buffer;
  committedRevision: number;
  committedAt: number;
}

export async function findOperation(client: pg.PoolClient, ownerID: string, operationID: string): Promise<StoredOperation | null> {
  const result = await client.query(
    `SELECT operation_id, owner_id, kind, signer_identity_id, signer_role, signer_public_key,
            body_digest, signed_operation, response_kind, response_body, response_digest,
            disposition, state_root_after, committed_revision, extract(epoch from committed_at) as committed_at
       FROM companion_operation WHERE owner_id = $1 AND operation_id = $2`,
    [ownerID, operationID]
  );
  const row = result.rows[0];
  if (!row) return null;
  return {
    operationID: row.operation_id,
    ownerID: row.owner_id,
    kind: row.kind,
    signerIdentityID: row.signer_identity_id,
    signerRole: row.signer_role,
    signerPublicKey: row.signer_public_key,
    bodyDigest: row.body_digest,
    signedOperation: row.signed_operation,
    responseKind: row.response_kind,
    responseBody: row.response_body,
    responseDigest: row.response_digest,
    disposition: row.disposition,
    stateRootAfter: row.state_root_after,
    committedRevision: Number(row.committed_revision),
    committedAt: Number(row.committed_at)
  };
}

export async function insertOperation(client: pg.PoolClient, op: StoredOperation): Promise<void> {
  await client.query(
    `INSERT INTO companion_operation
       (owner_id, operation_id, kind, signer_identity_id, signer_role, signer_public_key,
        body_digest, signed_operation, response_kind, response_body, response_digest,
        disposition, state_root_after, committed_revision, committed_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14, to_timestamp($15))`,
    [
      op.ownerID,
      op.operationID,
      op.kind,
      op.signerIdentityID,
      op.signerRole,
      op.signerPublicKey,
      op.bodyDigest,
      op.signedOperation,
      op.responseKind,
      op.responseBody,
      op.responseDigest,
      op.disposition,
      op.stateRootAfter,
      op.committedRevision,
      op.committedAt
    ]
  );
}

export async function upsertRetentionMarkers(client: pg.PoolClient, ownerID: string, markers: Array<{ recordKind: string; recordID: string; terminalAt: number }>): Promise<void> {
  for (const marker of markers) {
    await client.query(
      `INSERT INTO companion_retention_marker (owner_id, record_kind, record_id, terminal_at)
       VALUES ($1, $2, $3, to_timestamp($4))
       ON CONFLICT (owner_id, record_kind, record_id) DO UPDATE SET terminal_at = EXCLUDED.terminal_at`,
      [ownerID, marker.recordKind, marker.recordID, marker.terminalAt]
    );
  }
}

export async function deleteRetentionMarker(client: pg.PoolClient, ownerID: string, recordKind: string, recordID: string): Promise<void> {
  await client.query(`DELETE FROM companion_retention_marker WHERE owner_id = $1 AND record_kind = $2 AND record_id = $3`, [ownerID, recordKind, recordID]);
}

/** Resolves the owner partition for an approver-signed "approval" operation, which carries `pairingID` but no owner identity of its own. */
export async function resolveOwnerForPairing(client: pg.Pool | pg.PoolClient, pairingID: string): Promise<string | null> {
  const result = await client.query<{ owner_id: string }>(`SELECT owner_id FROM companion_approver_pairing WHERE pairing_id = $1`, [pairingID]);
  return result.rows[0]?.owner_id ?? null;
}

/** Records a newly created pairing (from "confirm" or "replace_pairing") so it can be found by approver identity across owners. */
export async function recordApproverPairing(client: pg.PoolClient, ownerID: string, pairingID: string, approverIdentityID: string): Promise<void> {
  await client.query(
    `INSERT INTO companion_approver_pairing (pairing_id, approver_identity_id, owner_id) VALUES ($1, $2, $3)
     ON CONFLICT (pairing_id) DO NOTHING`,
    [pairingID, approverIdentityID, ownerID]
  );
}

/** Returns the distinct set of owner IDs paired with `approverIdentityID`. */
export async function ownersForApprover(client: pg.Pool | pg.PoolClient, approverIdentityID: string): Promise<string[]> {
  const result = await client.query<{ owner_id: string }>(`SELECT DISTINCT owner_id FROM companion_approver_pairing WHERE approver_identity_id = $1`, [approverIdentityID]);
  return result.rows.map((r) => r.owner_id);
}

export async function withTransaction<T>(pool: pg.Pool, fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const value = await fn(client);
    await client.query("COMMIT");
    return value;
  } catch (error) {
    try {
      await client.query("ROLLBACK");
    } catch {
      // ignore rollback failure; original error is what matters
    }
    throw error;
  } finally {
    client.release();
  }
}
