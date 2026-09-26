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

import type pg from "pg";
import { lockOwnerRow, saveOwnerRow, deleteRetentionMarker, readOwnerLedger } from "./db.js";
import { emptyLedger } from "./ledger.js";
import { computeStateRoot } from "./service.js";

export interface RetentionSummary {
  purgedRequests: number;
  purgedApprovals: number;
  purgedApprovalUses: number;
  purgedPairings: number;
  purgedConsents: number;
  purgedInvitations: number;
  purgedPendingAcceptances: number;
  purgedNonceMarkers: number;
  purgedOperationRows: number;
  ownersTouched: number;
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
    purgedNonceMarkers: 0,
    purgedOperationRows: 0,
    ownersTouched: 0
  };
}

export async function purgeExpiredRecords(pool: pg.Pool, retentionDays: number, nowSeconds: number): Promise<RetentionSummary> {
  const cutoff = nowSeconds - retentionDays * 86_400;
  const summary = empty();

  const ownerRows = await pool.query<{ owner_id: string }>(`SELECT owner_id FROM companion_owner`);
  for (const { owner_id } of ownerRows.rows) {
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      const touched = await purgeOwner(client, owner_id, cutoff, summary);
      await client.query("COMMIT");
      if (touched) summary.ownersTouched += 1;
    } catch (error) {
      await client.query("ROLLBACK").catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  }

  const purgedOperations = await pool.query(`DELETE FROM companion_operation WHERE committed_at < to_timestamp($1)`, [cutoff]);
  summary.purgedOperationRows = purgedOperations.rowCount ?? 0;

  return summary;
}

async function purgeOwner(client: pg.PoolClient, ownerID: string, cutoff: number, summary: RetentionSummary): Promise<boolean> {
  // Read the owner's real identity first (outside the row lock) so
  // `lockOwnerRow`'s ambiguous-owner check compares against the actual
  // stored public key rather than a placeholder.
  const preread = await readOwnerLedger(client, ownerID);
  if (!preread) return false;
  const row = await lockOwnerRow(client, preread.ledger.owner, emptyLedger, computeStateRoot);
  const ledger = row.ledger;
  let changed = false;

  const purgedRequestIDs: string[] = [];
  for (const [requestID, record] of Object.entries(ledger.requests)) {
    const terminalAt = record.cancelledAt ?? record.expiredAt ?? (record.request.status === "declined" ? record.request.expiresAt : null);
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
      await client.query(`DELETE FROM companion_approver_pairing WHERE pairing_id = $1`, [pairingID]);
    }
  }

  for (const [inviteID, record] of Object.entries(ledger.invitations)) {
    const terminalAt = record.consumedAt ?? record.invitation.payload.expiresAt;
    if (terminalAt < cutoff) {
      delete ledger.invitations[inviteID];
      summary.purgedInvitations += 1;
      changed = true;
    }
  }
  for (const [acceptanceID, acceptance] of Object.entries(ledger.pendingAcceptances)) {
    const invite = ledger.invitations[acceptance.inviteID];
    const terminalAt = invite ? invite.invitation.payload.expiresAt : acceptance.issuedAt;
    if (terminalAt < cutoff) {
      delete ledger.pendingAcceptances[acceptanceID];
      summary.purgedPendingAcceptances += 1;
      changed = true;
    }
  }

  for (const [key, marker] of Object.entries(ledger.usedConsentNonces)) {
    if (marker.createdAt < cutoff) {
      delete ledger.usedConsentNonces[key];
      summary.purgedNonceMarkers += 1;
      changed = true;
    }
  }
  for (const [key, marker] of Object.entries(ledger.usedApprovalNonces)) {
    if (marker.createdAt < cutoff) {
      delete ledger.usedApprovalNonces[key];
      summary.purgedNonceMarkers += 1;
      changed = true;
    }
  }
  for (const [key, marker] of Object.entries(ledger.usedApprovalIDs)) {
    if (marker.createdAt < cutoff) {
      delete ledger.usedApprovalIDs[key];
      summary.purgedNonceMarkers += 1;
      changed = true;
    }
  }

  for (const requestID of purgedRequestIDs) {
    await deleteRetentionMarker(client, ownerID, "request", requestID);
  }

  if (changed) {
    // Retention purge mutates ledger *content* but must never advance the
    // protocol revision counter (revision is an append-only ordering/
    // idempotency invariant tied to the operation log, not to what content
    // retention has chosen to keep). The state root is recomputed over the
    // pruned content at the *same* revision.
    const newRoot = computeStateRoot(ledger, row.revision);
    await saveOwnerRow(client, ownerID, row.revision, row.revision, ledger, newRoot);
  }
  return changed;
}
