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

/** The docker-compose.yml/README-documented local Postgres, also relay/.env.example's default. */
export const DEFAULT_LOCAL_DATABASE_URL = "postgres://relay:relay@127.0.0.1:56330/companion_relay";

/**
 * Resolves `DATABASE_URL`, defaulting to the local Postgres
 * (`docker-compose.yml`'s `127.0.0.1:56330`) so `db:migrate`/`dev`/
 * `retention:purge` -- and the test suite -- work from a clean checkout with
 * no `.env` yet. Production must still set it explicitly: this default only
 * applies when `NODE_ENV !== "production"`, so a real deployment can never
 * silently fall back to a local address that doesn't exist there.
 */
export function resolveDatabaseURL(): string {
  const configured = process.env.DATABASE_URL;
  if (configured) return configured;
  if (process.env.NODE_ENV === "production") {
    throw new Error("DATABASE_URL is not set (required when NODE_ENV=production)");
  }
  // eslint-disable-next-line no-console
  console.error(`DATABASE_URL not set; defaulting to ${DEFAULT_LOCAL_DATABASE_URL} (NODE_ENV != "production")`);
  return DEFAULT_LOCAL_DATABASE_URL;
}

/**
 * Pool size and idle timeout are configurable via env vars because the right
 * values differ sharply between local dev/tests (many short-lived
 * connections are fine and even useful, e.g. test/race.test.ts's genuinely
 * concurrent DB-level race) and a Vercel serverless deployment, where each
 * function instance should hold only 1-2 connections and release them
 * quickly -- a serverless deployment should point `DATABASE_URL` at Neon's
 * *pooled* connection string (the one with `-pooler` in the hostname, which
 * routes through PgBouncer) and set `PGPOOL_MAX=2`, `PGPOOL_IDLE_TIMEOUT_MS`
 * to a few seconds. See relay/README.md.
 */
export function getPool(): pg.Pool {
  if (!pool) {
    const connectionString = resolveDatabaseURL();
    const max = Number(process.env.PGPOOL_MAX ?? "10");
    const idleTimeoutMillis = Number(process.env.PGPOOL_IDLE_TIMEOUT_MS ?? "30000");
    pool = new pg.Pool({ connectionString, max, idleTimeoutMillis });
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
  expectedRevision: number | null;
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
    `SELECT operation_id, owner_id, kind, signer_identity_id, signer_role, signer_public_key, expected_revision,
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
    expectedRevision: row.expected_revision === null ? null : Number(row.expected_revision),
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
       (owner_id, operation_id, kind, signer_identity_id, signer_role, signer_public_key, expected_revision,
        body_digest, signed_operation, response_kind, response_body, response_digest,
        disposition, state_root_after, committed_revision, committed_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15, to_timestamp($16))`,
    [
      op.ownerID,
      op.operationID,
      op.kind,
      op.signerIdentityID,
      op.signerRole,
      op.signerPublicKey,
      op.expectedRevision,
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

export class PairingRoutingConflictError extends Error {
  constructor() {
    super("pairing_routing_conflict");
  }
}

/**
 * Records a newly created pairing (from "confirm" or "replace_pairing") so
 * it can be found by approver identity across owners. `pairing_id` is the
 * sole routing key a bare `Approval` (or an approver's inbox fetch) can use
 * to find its owner, so it must stay globally unique. A caller-chosen
 * `replacementPairingID` (from `replace_pairing`, proposed by the
 * *replacement approver's* device) could otherwise collide with a value
 * already claimed by an unrelated owner -- either pre-claimed by an
 * attacker before the victim uses it, or claimed by the attacker to shadow
 * a victim's ID. Rather than silently ignoring the conflict (which used to
 * leave the index pointing at whichever owner claimed it first, silently
 * misrouting the other owner's approvals/inbox), a same-owner re-insert is
 * a harmless no-op (e.g. a partially-applied prior attempt) but a
 * different-owner conflict fails the whole transaction, so the "confirm"/
 * "replace_pairing" operation that tried to claim it is rejected outright
 * and nothing commits.
 */
export async function recordApproverPairing(client: pg.PoolClient, ownerID: string, pairingID: string, approverIdentityID: string): Promise<void> {
  const inserted = await client.query(
    `INSERT INTO companion_approver_pairing (pairing_id, approver_identity_id, owner_id) VALUES ($1, $2, $3)
     ON CONFLICT (pairing_id) DO NOTHING
     RETURNING owner_id`,
    [pairingID, approverIdentityID, ownerID]
  );
  if ((inserted.rowCount ?? 0) === 1) return;
  const existing = await client.query<{ owner_id: string }>(`SELECT owner_id FROM companion_approver_pairing WHERE pairing_id = $1`, [pairingID]);
  if (existing.rows[0]?.owner_id !== ownerID) {
    throw new PairingRoutingConflictError();
  }
}

/** Deletes an owner's approver-pairing routing row, scoped by owner so an unrelated colliding row (which recordApproverPairing now prevents from ever being created) can never be deleted out from under a different owner. */
export async function deleteApproverPairing(client: pg.Pool | pg.PoolClient, ownerID: string, pairingID: string): Promise<void> {
  await client.query(`DELETE FROM companion_approver_pairing WHERE pairing_id = $1 AND owner_id = $2`, [pairingID, ownerID]);
}

/** Returns the distinct set of owner IDs paired with `approverIdentityID`. */
export async function ownersForApprover(client: pg.Pool | pg.PoolClient, approverIdentityID: string): Promise<string[]> {
  const result = await client.query<{ owner_id: string }>(`SELECT DISTINCT owner_id FROM companion_approver_pairing WHERE approver_identity_id = $1`, [approverIdentityID]);
  return result.rows.map((r) => r.owner_id);
}

/** Shared window/budget for the global per-subject rate limiter (`chargeGlobalRateLimit(s)`/`purgeStaleRateLimits`), so the charging side (src/service.ts) and the purge side (src/retention.ts) agree on what "stale" means. */
export const GLOBAL_RATE_LIMIT_WINDOW_SECONDS = 60;
export const GLOBAL_RATE_LIMIT_MAX = 60;

let warnedAboutIgnoredOverride = false;

/**
 * Local-testing escape hatch: lets the dev server (`npm run dev:test`) raise a
 * rate limit so app integration tests need not sleep between runs. Honoured
 * only when the process is demonstrably the local dev server (`RELAY_LOCAL_DEV=1`, set
 * by scripts/dev-server.ts) and not a production deployment: it is
 * IGNORED (the strict default applies) otherwise, and whenever `VERCEL_ENV=production`,
 * `NODE_ENV=production` or any `VERCEL` marker is present, or when the value is
 * not a positive integer. Ignoring rather than throwing keeps a misconfigured
 * production deployment safe and serving.
 */
export function rateLimitMax(defaultMax: number, envName: string, env: NodeJS.ProcessEnv = process.env): number {
  const raw = env[envName];
  if (raw === undefined || raw === "") return defaultMax;
  // Needs a positive local opt-in that only scripts/dev-server.ts sets (RELAY_LOCAL_DEV=1), in
  // addition to none of the production markers being present.
  const production = env.RELAY_LOCAL_DEV !== "1" || env.VERCEL_ENV === "production" || env.NODE_ENV === "production" || env.VERCEL !== undefined;
  const value = Number(raw);
  if (production || !Number.isSafeInteger(value) || value <= 0) {
    if (!warnedAboutIgnoredOverride) {
      warnedAboutIgnoredOverride = true;
      // eslint-disable-next-line no-console
      console.error(`${envName} ignored (production environment or invalid value); using the default limit of ${defaultMax}`);
    }
    return defaultMax;
  }
  return value;
}

export function globalRateLimitMax(): number {
  return rateLimitMax(GLOBAL_RATE_LIMIT_MAX, "RELAY_RATE_LIMIT_MAX");
}

/**
 * Global, DB-backed, fixed-window rate limiter keyed by `subject` (e.g.
 * `signer:<identityID>` or `ip:<address>`). Charged in its own implicit
 * single-statement transaction *before* any owner row is resolved/locked, so
 * it bounds every request regardless of whether it succeeds, fails, targets
 * an owner that doesn't exist, or is an inbox fetch (none of which reach the
 * per-owner-ledger rate limiter in src/reducer.ts, which only runs once
 * inside an already-open owner transaction). Returns `true` if this one
 * subject is still within its budget for the window.
 */
export async function chargeGlobalRateLimit(pool: pg.Pool, subject: string, nowSeconds: number, windowSeconds: number, maxCount: number): Promise<boolean> {
  const result = await pool.query<{ count: number }>(
    `INSERT INTO companion_rate_limit (subject, window_start, count)
     VALUES ($1, to_timestamp($2), 1)
     ON CONFLICT (subject) DO UPDATE SET
       window_start = CASE WHEN companion_rate_limit.window_start < to_timestamp($2) - make_interval(secs => $3) THEN to_timestamp($2) ELSE companion_rate_limit.window_start END,
       count = CASE WHEN companion_rate_limit.window_start < to_timestamp($2) - make_interval(secs => $3) THEN 1 ELSE companion_rate_limit.count + 1 END
     RETURNING count`,
    [subject, nowSeconds, windowSeconds]
  );
  const count = result.rows[0]?.count ?? 0;
  return count <= maxCount;
}

/**
 * Charges every subject (typically the signer identity and, when known, the
 * client IP) unconditionally -- each attempt is recorded regardless of
 * whether another subject is already over budget -- and allows the request
 * only if *all* of them are still within budget. Charging (not just
 * checking) every subject even when one already denies the request means a
 * attacker who floods from many identities behind one IP still drives that
 * IP's counter up, and vice versa.
 */
export async function chargeGlobalRateLimits(pool: pg.Pool, subjects: readonly string[], nowSeconds: number, windowSeconds: number, maxCount: number): Promise<boolean> {
  const results = await Promise.all(subjects.map((subject) => chargeGlobalRateLimit(pool, subject, nowSeconds, windowSeconds, maxCount)));
  return results.every(Boolean);
}

/** Deletes rate-limit rows whose window is stale relative to `nowSeconds` (i.e. `window_start < now - windowSeconds`), not on the 30-day retention window -- a fixed-window counter's row is meaningless once its window has elapsed, regardless of the protocol's unrelated data-retention policy. */
export async function purgeStaleRateLimits(pool: pg.Pool, nowSeconds: number, windowSeconds: number): Promise<number> {
  const result = await pool.query(`DELETE FROM companion_rate_limit WHERE window_start < to_timestamp($1) - make_interval(secs => $2)`, [nowSeconds, windowSeconds]);
  return result.rowCount ?? 0;
}

/** Returns the retention purge owner-batch cursor (the last `owner_id` fully processed), or `null` if none has been recorded yet. */
export async function getRetentionCursor(pool: pg.Pool): Promise<string | null> {
  const result = await pool.query<{ last_owner_id: string | null }>(`SELECT last_owner_id FROM companion_retention_cursor WHERE id = 'default'`);
  return result.rows[0]?.last_owner_id ?? null;
}

/** Persists the retention purge owner-batch cursor. */
export async function setRetentionCursor(pool: pg.Pool, lastOwnerID: string | null): Promise<void> {
  await pool.query(
    `INSERT INTO companion_retention_cursor (id, last_owner_id) VALUES ('default', $1)
     ON CONFLICT (id) DO UPDATE SET last_owner_id = EXCLUDED.last_owner_id`,
    [lastOwnerID]
  );
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

// ---------------------------------------------------------------------------
// Pairing v3: invite token index (migrations/004_invite_token.sql)
// ---------------------------------------------------------------------------

export class InviteTokenConflictError extends Error {
  constructor() {
    super("invite_token_conflict");
  }
}

/** Records the lookup-key -> (owner, invite) routing row in the invite's own transaction. A key already claimed by any invite (live, consumed or not yet swept) is refused. */
export async function recordInviteToken(client: pg.PoolClient, lookupKey: Buffer, ownerID: string, inviteID: string, expiresAtSeconds: number): Promise<void> {
  const inserted = await client.query(
    `INSERT INTO companion_invite_token (lookup_key, owner_id, invite_id, expires_at) VALUES ($1, $2, $3, to_timestamp($4))
     ON CONFLICT (lookup_key) DO NOTHING
     RETURNING owner_id`,
    [lookupKey, ownerID, inviteID, expiresAtSeconds]
  );
  if ((inserted.rowCount ?? 0) === 1) return;
  throw new InviteTokenConflictError();
}

/** Marks an invite's token row consumed ("accept"). The row stays as a tombstone until it expires so the key cannot be re-registered by another owner. Idempotent. */
export async function consumeInviteToken(client: pg.Pool | pg.PoolClient, ownerID: string, inviteID: string, nowSeconds: number): Promise<void> {
  await client.query(`UPDATE companion_invite_token SET consumed_at = to_timestamp($3) WHERE owner_id = $1 AND invite_id = $2 AND consumed_at IS NULL`, [ownerID, inviteID, nowSeconds]);
}

/** Hard-deletes an invite's token row (only when the ledger invite itself is purged). Scoped by owner. */
export async function deleteInviteToken(client: pg.Pool | pg.PoolClient, ownerID: string, inviteID: string): Promise<void> {
  await client.query(`DELETE FROM companion_invite_token WHERE owner_id = $1 AND invite_id = $2`, [ownerID, inviteID]);
}

export interface InviteTokenRow {
  lookupKey: Buffer;
  ownerID: string;
  inviteID: string;
  expiresAt: number;
  consumed: boolean;
}

/** Looks up a token row by its lookup key. The key is a hash of an unguessable 128-bit token, so an index probe leaks nothing about near-miss tokens. */
export async function findInviteToken(client: pg.Pool | pg.PoolClient, lookupKey: Buffer): Promise<InviteTokenRow | null> {
  const result = await client.query<{ lookup_key: Buffer; owner_id: string; invite_id: string; expires_at: Date; consumed_at: Date | null }>(
    `SELECT lookup_key, owner_id, invite_id, expires_at, consumed_at FROM companion_invite_token WHERE lookup_key = $1`,
    [lookupKey]
  );
  const row = result.rows[0];
  if (!row) return null;
  return { lookupKey: row.lookup_key, ownerID: row.owner_id, inviteID: row.invite_id, expiresAt: row.expires_at.getTime() / 1000, consumed: row.consumed_at !== null };
}

/** Deletes token rows (live or tombstoned) whose invite expired before `cutoffSeconds`. Retention passes the 30-day cutoff so an expired or consumed lookup key stays registered (cannot be re-registered by another owner) until the ledger invite itself is purged. */
export async function purgeExpiredInviteTokens(client: pg.Pool | pg.PoolClient, cutoffSeconds: number): Promise<number> {
  const result = await client.query(`DELETE FROM companion_invite_token WHERE expires_at < to_timestamp($1)`, [cutoffSeconds]);
  return result.rowCount ?? 0;
}
