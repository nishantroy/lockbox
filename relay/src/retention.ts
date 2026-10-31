// Retention purge job. Per docs/r5-relay-plan.md's owner decision: "finished
// records (terminal requests, approvals, revoked pairings/consent) are
// deleted 30 days after they become terminal. Active pairings/consent
// persist until revoked. Replay markers are kept at least as long as the
// operation they protect remains valid" -- and are bounded thereafter so
// they cannot grow unboundedly.
//
// A pairing is only fully purged once it is revoked (consent tied to it can
// never be revived: `replace_pairing`/`revoke` mint a fresh, never-reused
// pairingID for any future re-pair, since pairingIDs are a deterministic
// hash of a one-time-use inviteID). Purging a revoked pairing's consent
// alongside it is therefore safe: nothing live can reference that exact
// pairingID's consent generation again.
//
// The owner-operation log (`companion_operation`) is purged on the same
// window. This means a client retry of an operationID older than the
// retention window is no longer idempotency-checked; 30 days is long enough
// relative to this protocol's request/session lifetimes (at most 7 days)
// that this is an accepted prototype trade-off, called out in the README.
//
// A purge that mutates a ledger commits a *system* operation record and
// advances the owner's `revision`, exactly like any client-submitted
// mutation. The client-side rollback anchor treats the same revision
// reported twice with two different `stateRoot`s as a fork/rollback; purging
// content changes the root without this, so it must advance the revision to
// stay honest about "this owner's state changed".

import type pg from "pg";
import {
  lockOwnerRow,
  saveOwnerRow,
  deleteRetentionMarker,
  deleteApproverPairing,
  deleteInviteToken,
  purgeExpiredInviteTokens,
  readOwnerLedger,
  insertOperation,
  purgeStaleRateLimits,
  getRetentionCursor,
  setRetentionCursor,
  GLOBAL_RATE_LIMIT_WINDOW_SECONDS,
  type StoredOperation
} from "./db.js";
import { emptyLedger, type Marker } from "./ledger.js";
import { computeStateRoot } from "./service.js";
import { digest } from "./canonical.js";
import { randomUUID } from "node:crypto";
import { relayError } from "./errors.js";

export interface RetentionSummary {
  purgedRequests: number;
  purgedApprovals: number;
  purgedApprovalUses: number;
  purgedPairings: number;
  purgedConsents: number;
  purgedInvitations: number;
  purgedPendingAcceptances: number;
  /** Pairing v3: `companion_invite_token` rows deleted (expired, or removed with a purged invite). */
  purgedInviteTokens: number;
  purgedNonceMarkers: number;
  purgedSessions: number;
  purgedRateLimitSignerEntries: number;
  purgedOperationRows: number;
  purgedRateLimitRows: number;
  ownersTouched: number;
  ownersScanned: number;
  ownersRemaining: number;
}

function empty(): RetentionSummary {
  return {
    purgedRequests: 0,
    purgedApprovals: 0,
    purgedApprovalUses: 0,
    purgedPairings: 0,
    purgedConsents: 0,
    purgedInvitations: 0,
    purgedPendingAcceptances: 0,
    purgedInviteTokens: 0,
    purgedNonceMarkers: 0,
    purgedSessions: 0,
    purgedRateLimitSignerEntries: 0,
    purgedOperationRows: 0,
    purgedRateLimitRows: 0,
    ownersTouched: 0,
    ownersScanned: 0,
    ownersRemaining: 0
  };
}

export interface PurgeOptions {
  /** Caps how many owners one invocation processes, so a single Vercel Hobby cron invocation (with its execution-time limit) cannot be starved by an unbounded owner count. Defaults to processing all owners found within `maxDurationMs`. */
  maxOwners?: number;
  /** Wall-clock budget for the owner loop; once exceeded, the function returns a partial summary (`ownersRemaining` tells the caller more owners are left for the next run). */
  maxDurationMs?: number;
}

const DEFAULT_MAX_DURATION_MS = 8_000; // leaves headroom under Vercel Hobby's default 10s function timeout

/**
 * Fetches the owners one batch should process. With no `maxOwners` cap
 * (tests, manual/local runs), this is simply every owner in order and the
 * persisted cursor is left untouched. With a cap (the production cron path),
 * it resumes just after the last cursor position and wraps around to the
 * start once it runs out, so a bounded-duration batch sweeps through every
 * owner over successive invocations instead of only ever reaching the same
 * early-`owner_id` owners.
 */
async function fetchOwnerBatch(pool: pg.Pool, maxOwners: number | undefined): Promise<{ ownerIDs: string[]; usingCursor: boolean }> {
  if (maxOwners === undefined) {
    const all = await pool.query<{ owner_id: string }>(`SELECT owner_id FROM companion_owner ORDER BY owner_id`);
    return { ownerIDs: all.rows.map((r) => r.owner_id), usingCursor: false };
  }
  const cursor = await getRetentionCursor(pool);
  const firstBatch = await pool.query<{ owner_id: string }>(
    cursor !== null ? `SELECT owner_id FROM companion_owner WHERE owner_id > $1 ORDER BY owner_id LIMIT $2` : `SELECT owner_id FROM companion_owner ORDER BY owner_id LIMIT $1`,
    cursor !== null ? [cursor, maxOwners] : [maxOwners]
  );
  let ownerIDs = firstBatch.rows.map((r) => r.owner_id);
  if (ownerIDs.length < maxOwners && cursor !== null) {
    const remaining = maxOwners - ownerIDs.length;
    const wrapBatch = await pool.query<{ owner_id: string }>(`SELECT owner_id FROM companion_owner WHERE owner_id <= $1 ORDER BY owner_id LIMIT $2`, [cursor, remaining]);
    ownerIDs = ownerIDs.concat(wrapBatch.rows.map((r) => r.owner_id));
  }
  return { ownerIDs, usingCursor: true };
}

export async function purgeExpiredRecords(pool: pg.Pool, retentionDays: number, nowSeconds: number, options: PurgeOptions = {}): Promise<RetentionSummary> {
  if (!Number.isFinite(retentionDays) || retentionDays < 1) {
    throw new Error(`invalid retentionDays: ${retentionDays} (must be a finite number >= 1)`);
  }
  const cutoff = nowSeconds - retentionDays * 86_400;
  const summary = empty();
  const maxDurationMs = options.maxDurationMs ?? DEFAULT_MAX_DURATION_MS;
  const started = Date.now();

  const { ownerIDs, usingCursor } = await fetchOwnerBatch(pool, options.maxOwners);

  let index = 0;
  let lastProcessedOwnerID: string | null = null;
  for (; index < ownerIDs.length; index += 1) {
    if (Date.now() - started > maxDurationMs) break;
    const ownerID = ownerIDs[index]!;
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      const touched = await purgeOwner(client, ownerID, cutoff, nowSeconds, summary);
      await client.query("COMMIT");
      summary.ownersScanned += 1;
      if (touched) summary.ownersTouched += 1;
      lastProcessedOwnerID = ownerID;
    } catch (error) {
      await client.query("ROLLBACK").catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  }
  summary.ownersRemaining = ownerIDs.length - index;

  if (usingCursor && lastProcessedOwnerID !== null) {
    await setRetentionCursor(pool, lastProcessedOwnerID);
  }

  const purgedOperations = await pool.query(`DELETE FROM companion_operation WHERE committed_at < to_timestamp($1)`, [cutoff]);
  summary.purgedOperationRows = purgedOperations.rowCount ?? 0;
  // Pairing v3 invite tokens are useless the moment their invite expires, so they are swept at `now`, not at the 30-day cutoff.
  summary.purgedInviteTokens += await purgeExpiredInviteTokens(pool, nowSeconds);
  summary.purgedRateLimitRows = await purgeStaleRateLimits(pool, nowSeconds, GLOBAL_RATE_LIMIT_WINDOW_SECONDS);

  return summary;
}

function pruneMarkers(map: Record<string, Marker>, cutoff: number): number {
  let removed = 0;
  for (const key of Object.keys(map)) {
    if (map[key]!.createdAt < cutoff) {
      delete map[key];
      removed += 1;
    }
  }
  return removed;
}

async function purgeOwner(client: pg.PoolClient, ownerID: string, cutoff: number, now: number, summary: RetentionSummary): Promise<boolean> {
  // Read the owner's real identity first (outside the row lock) so
  // `lockOwnerRow`'s ambiguous-owner check compares against the actual
  // stored public key rather than a placeholder.
  const preread = await readOwnerLedger(client, ownerID);
  if (!preread) return false;
  const row = await lockOwnerRow(client, preread.ledger.owner, emptyLedger, computeStateRoot);
  const ledger = row.ledger;
  let changed = false;

  // Fail closed exactly like the mutation path (src/service.ts's
  // submitOperation) and the owner-inbox read path do: verify the stored
  // root against the loaded state *before* pruning/re-rooting anything, so
  // a purge never silently re-roots an already-corrupt/tampered record on
  // top of the mismatch.
  if (!computeStateRoot(ledger, row.revision).equals(row.storedStateRoot)) {
    throw relayError("integrity_error");
  }

  // Requests that lapsed without any later activity are only lazily marked
  // "expired" when something touches them (approval/use/cancel/session
  // publish); the purge job computes expiry itself for anything still
  // "pending"/"approved" whose own expiry (or session end) is already well
  // within the retention window, rather than waiting for that lazy touch.
  for (const record of Object.values(ledger.requests)) {
    if (record.request.status !== "pending" && record.request.status !== "approved") continue;
    const session = ledger.sessions[record.request.sessionID]?.session;
    const sessionEnded = session ? session.endsAt < cutoff : false;
    if (record.request.expiresAt < cutoff || sessionEnded) {
      record.request = { ...record.request, status: "expired" };
      record.expiredAt = record.request.expiresAt < cutoff ? record.request.expiresAt : session!.endsAt;
      changed = true;
    }
  }

  const purgedRequestIDs: string[] = [];
  for (const [requestID, record] of Object.entries(ledger.requests)) {
    const terminalAt = record.cancelledAt ?? record.expiredAt ?? record.declinedAt;
    if (terminalAt !== null && terminalAt < cutoff) {
      delete ledger.requests[requestID];
      purgedRequestIDs.push(requestID);
      summary.purgedRequests += 1;
      changed = true;
    }
  }
  for (const [approvalID, record] of Object.entries(ledger.approvals)) {
    if (purgedRequestIDs.includes(record.approval.requestID)) {
      delete ledger.approvals[approvalID];
      summary.purgedApprovals += 1;
      changed = true;
    }
  }
  for (const [useID, record] of Object.entries(ledger.approvalUses)) {
    if (purgedRequestIDs.includes(record.requestID)) {
      delete ledger.approvalUses[useID];
      summary.purgedApprovalUses += 1;
      changed = true;
    }
  }

  for (const [pairingID, record] of Object.entries(ledger.pairings)) {
    if (record.revokedAt !== null && record.revokedAt < cutoff) {
      delete ledger.pairings[pairingID];
      summary.purgedPairings += 1;
      changed = true;
      if (ledger.relationshipConsents[pairingID]) {
        delete ledger.relationshipConsents[pairingID];
        summary.purgedConsents += 1;
      }
      await deleteRetentionMarker(client, ownerID, "pairing", pairingID);
      // Scoped by owner: recordApproverPairing (db.ts) now refuses to let a
      // different owner ever claim this pairing_id while this row exists, so
      // it is safe to delete only *this* owner's row for it.
      await deleteApproverPairing(client, ownerID, pairingID);
    }
  }

  for (const [inviteID, record] of Object.entries(ledger.invitations)) {
    const terminalAt = record.consumedAt ?? record.invitation.payload.expiresAt;
    if (terminalAt < cutoff) {
      delete ledger.invitations[inviteID];
      summary.purgedInvitations += 1;
      changed = true;
      // Pairing v3: the token index row goes with its invite (it is normally
      // already gone -- deleted on accept, or swept at expiry below).
      await deleteInviteToken(client, ownerID, inviteID);
    }
  }
  // Pairing v2 leftovers: an unconfirmed v2 acceptance can never be confirmed
  // any more (v3 removed "confirm"); drop it once its invite is old enough.
  for (const [acceptanceID, raw] of Object.entries(ledger.pendingAcceptances ?? {})) {
    const legacy = (raw ?? {}) as { acceptance?: { inviteID?: string; issuedAt?: number }; inviteID?: string; issuedAt?: number };
    const acceptance = legacy.acceptance ?? legacy;
    const invite = acceptance.inviteID ? ledger.invitations[acceptance.inviteID] : undefined;
    const terminalAt = invite ? invite.invitation.payload.expiresAt : (acceptance.issuedAt ?? 0);
    if (terminalAt < cutoff) {
      delete ledger.pendingAcceptances![acceptanceID];
      summary.purgedPendingAcceptances += 1;
      changed = true;
    }
  }

  // Ended sessions: any request still referencing one is, by construction
  // (`request.expiresAt <= session.endsAt` is enforced at creation), at
  // least as old, so it is already resolved as terminal above by the time
  // its session is old enough to purge here.
  for (const [sessionID, record] of Object.entries(ledger.sessions)) {
    if (record.session.endsAt < cutoff) {
      delete ledger.sessions[sessionID];
      summary.purgedSessions += 1;
      changed = true;
      if (ledger.currentSessionID === sessionID) ledger.currentSessionID = null;
    }
  }

  const noncesPurged = pruneMarkers(ledger.usedConsentNonces, cutoff) + pruneMarkers(ledger.usedApprovalNonces, cutoff) + pruneMarkers(ledger.usedApprovalIDs, cutoff);
  if (noncesPurged > 0) {
    summary.purgedNonceMarkers += noncesPurged;
    changed = true;
  }

  // Per-owner-ledger rate-limit timestamps (src/reducer.ts's `chargeRateLimit`)
  // are already self-pruning on every charge for an identity that keeps
  // submitting, but an identity that never submits again leaves its (small)
  // entry behind forever; drop entries wholly older than the window.
  for (const [identityID, timestamps] of Object.entries(ledger.rateLimits)) {
    if (timestamps.length === 0 || timestamps.every((t) => t < cutoff)) {
      delete ledger.rateLimits[identityID];
      summary.purgedRateLimitSignerEntries += 1;
      changed = true;
    }
  }

  for (const requestID of purgedRequestIDs) {
    await deleteRetentionMarker(client, ownerID, "request", requestID);
  }

  if (changed) {
    const committedRevision = row.revision + 1;
    const newRoot = computeStateRoot(ledger, committedRevision);
    await saveOwnerRow(client, ownerID, row.revision, committedRevision, ledger, newRoot);
    await insertOperation(client, systemPurgeOperation(ownerID, committedRevision, now, newRoot));
  }
  return changed;
}

/**
 * A synthetic operation-log receipt for a retention purge, so the append-only
 * operation log (and the `(revision, stateRoot)` a client anchors on)
 * accounts for every revision advance, including this system-initiated one
 * -- not just client-submitted mutations. It is not (and does not claim to
 * be) a signed client operation: `signer` is the ledger's own owner identity
 * (a purge is an owner-partition-local, not third-party, event), and
 * `signedOperation`/digests are internally-consistent placeholders, never
 * independently re-verified as a real signature anywhere in this codebase.
 * `stateRootAfter` is the *real* `newRoot` this purge just committed (not a
 * placeholder): the whole point of persisting it per-operation is so a later
 * read can recover the exact `(revision, stateRoot)` pair as of this commit,
 * and a placeholder would silently break that for this revision forever.
 */
function systemPurgeOperation(ownerID: string, committedRevision: number, now: number, newRoot: Buffer): StoredOperation {
  const marker = Buffer.from(JSON.stringify({ system: "retention_purge", ownerID, committedRevision }), "utf8");
  const responseBody = Buffer.from("{}", "utf8");
  return {
    operationID: `retention-purge:${randomUUID()}`,
    ownerID,
    kind: "retention_purge",
    signerIdentityID: ownerID,
    signerRole: "owner",
    signerPublicKey: Buffer.alloc(32),
    expectedRevision: null,
    bodyDigest: digest(marker),
    signedOperation: marker,
    responseKind: "acknowledgement",
    responseBody,
    responseDigest: digest(responseBody),
    disposition: "accepted",
    stateRootAfter: newRoot,
    committedRevision,
    committedAt: now
  };
}
