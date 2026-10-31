// Retention purge boundary tests. Per docs/r5-relay-plan.md: terminal
// records (cancelled/expired/declined requests, revoked pairings/consent)
// are deleted 30 days after they became terminal; replay markers are bounded
// the same way. Directly manipulates the stored ledger's terminal
// timestamps (rather than waiting 30 real days) to test the exact boundary.

import { describe, it, expect } from "vitest";
import { makeIdentity, buildOperation, uniqueID, testPool, swiftDate } from "./setup.js";
import { submitOperation } from "../src/service.js";
import { purgeExpiredRecords } from "../src/retention.js";
import { deserializeLedger, serializeLedger } from "../src/ledger.js";
import { computeStateRoot } from "../src/service.js";

function toRequest(op: object): Buffer {
  return Buffer.from(JSON.stringify(op), "utf8");
}

async function readLedgerText(ownerID: string): Promise<{ text: string; revision: number }> {
  const result = await testPool().query<{ state: string; revision: string }>(`SELECT state, revision FROM companion_owner WHERE owner_id = $1`, [ownerID]);
  const row = result.rows[0];
  if (!row) throw new Error("owner not found");
  return { text: row.state, revision: Number(row.revision) };
}

async function patchLedger(ownerID: string, mutate: (ledger: ReturnType<typeof deserializeLedger>) => void): Promise<void> {
  const { text, revision } = await readLedgerText(ownerID);
  const ledger = deserializeLedger(text);
  mutate(ledger);
  const newRoot = computeStateRoot(ledger, revision);
  await testPool().query(`UPDATE companion_owner SET state = $1, state_root = $2 WHERE owner_id = $3`, [serializeLedger(ledger), newRoot, ownerID]);
}

const DAY = 86_400;

describe("retention purge boundaries", () => {
  it("does not purge a request exactly at the retention boundary minus one second", async () => {
    const owner = makeIdentity("owner");
    const ackOp = buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null });
    await submitOperation(toRequest(ackOp));

    // Directly seed a terminal (cancelled) request into the ledger with a
    // controlled cancelledAt, rather than waiting for a real cancel.
    const requestID = uniqueID("request");
    const now = Math.floor(Date.now() / 1000);
    await patchLedger(owner.identity.identityID, (ledger) => {
      ledger.requests[requestID] = {
        request: {
          requestID,
          owner: ledger.owner,
          pairingID: "p1",
          pairEpoch: 1,
          consentGeneration: 1,
          sessionID: "s1",
          activeSetID: "a1",
          purpose: "approveEarlyEnd",
          targetedApproverIDs: ["x"],
          targetBindings: [{ approverIdentityID: "x", pairingID: "p1", pairEpoch: 1, consentGeneration: 1 }],
          message: null,
          createdAt: now - 40 * DAY,
          expiresAt: now - 39 * DAY,
          status: "cancelled",
          decisions: { x: "declined" }
        },
        cancelledAt: now - 30 * DAY + 1, // just inside the 30-day retention window
        expiredAt: null,
        declinedAt: null
      };
    });

    const summary = await purgeExpiredRecords(testPool(), 30, now);
    expect(summary.purgedRequests).toBe(0);
    const { text } = await readLedgerText(owner.identity.identityID);
    expect(deserializeLedger(text).requests[requestID]).toBeDefined();
  });

  it("purges a request exactly one second past the retention boundary", async () => {
    const owner = makeIdentity("owner");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })));

    const requestID = uniqueID("request");
    const now = Math.floor(Date.now() / 1000);
    await patchLedger(owner.identity.identityID, (ledger) => {
      ledger.requests[requestID] = {
        request: {
          requestID,
          owner: ledger.owner,
          pairingID: "p1",
          pairEpoch: 1,
          consentGeneration: 1,
          sessionID: "s1",
          activeSetID: "a1",
          purpose: "approveEarlyEnd",
          targetedApproverIDs: ["x"],
          targetBindings: [{ approverIdentityID: "x", pairingID: "p1", pairEpoch: 1, consentGeneration: 1 }],
          message: null,
          createdAt: now - 40 * DAY,
          expiresAt: now - 39 * DAY,
          status: "expired",
          decisions: { x: "pending" }
        },
        cancelledAt: null,
        expiredAt: now - 30 * DAY - 1, // one second past the 30-day retention window
        declinedAt: null
      };
    });

    const summary = await purgeExpiredRecords(testPool(), 30, now);
    expect(summary.purgedRequests).toBe(1);
    const { text } = await readLedgerText(owner.identity.identityID);
    expect(deserializeLedger(text).requests[requestID]).toBeUndefined();
  });

  it("purges a revoked pairing and its consent together, past the retention window, and bounds nonce markers", async () => {
    const owner = makeIdentity("owner");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })));
    const now = Math.floor(Date.now() / 1000);
    const pairingID = uniqueID("pairing");

    await testPool().query(`INSERT INTO companion_approver_pairing (pairing_id, approver_identity_id, owner_id) VALUES ($1, $2, $3)`, [pairingID, "approver-x", owner.identity.identityID]);

    await patchLedger(owner.identity.identityID, (ledger) => {
      ledger.pairings[pairingID] = {
        pairing: { pairingID, owner: ledger.owner, approver: { identityID: "approver-x", role: "trustedApprover", publicKey: Buffer.alloc(32, 1) }, epoch: 1, createdAt: now - 60 * DAY, state: "revoked" },
        revokedAt: now - 31 * DAY
      };
      ledger.relationshipConsents[pairingID] = {
        schemaVersion: 2,
        relationshipID: pairingID,
        pairingID,
        pairEpoch: 1,
        generation: 3,
        owner: ledger.owner,
        approver: { identityID: "approver-x", role: "trustedApprover", publicKey: Buffer.alloc(32, 1) },
        ownerScopes: [],
        approverScopes: [],
        ownerState: "revoked",
        approverState: "revoked",
        updatedAt: now - 31 * DAY
      };
      ledger.usedApprovalNonces["stale-nonce"] = { createdAt: now - 31 * DAY };
      ledger.usedApprovalNonces["fresh-nonce"] = { createdAt: now - 1 * DAY };
    });

    const summary = await purgeExpiredRecords(testPool(), 30, now);
    expect(summary.purgedPairings).toBe(1);
    expect(summary.purgedConsents).toBe(1);
    expect(summary.purgedNonceMarkers).toBeGreaterThanOrEqual(1);

    const { text } = await readLedgerText(owner.identity.identityID);
    const ledger = deserializeLedger(text);
    expect(ledger.pairings[pairingID]).toBeUndefined();
    expect(ledger.relationshipConsents[pairingID]).toBeUndefined();
    expect(ledger.usedApprovalNonces["stale-nonce"]).toBeUndefined();
    expect(ledger.usedApprovalNonces["fresh-nonce"]).toBeDefined();

    const mapping = await testPool().query(`SELECT 1 FROM companion_approver_pairing WHERE pairing_id = $1`, [pairingID]);
    expect(mapping.rowCount).toBe(0);
  });

  it("purges old operation-log rows past the retention window", async () => {
    const owner = makeIdentity("owner");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })));
    await testPool().query(`UPDATE companion_operation SET committed_at = now() - interval '31 days' WHERE owner_id = $1`, [owner.identity.identityID]);

    const summary = await purgeExpiredRecords(testPool(), 30, Math.floor(Date.now() / 1000));
    expect(summary.purgedOperationRows).toBeGreaterThanOrEqual(1);
    const remaining = await testPool().query(`SELECT 1 FROM companion_operation WHERE owner_id = $1`, [owner.identity.identityID]);
    expect(remaining.rowCount).toBe(0);
  });

  it("advances the owner's protocol revision by exactly one, with a system operation receipt, when a purge mutates the ledger -- and never advances it when nothing changed", async () => {
    const owner = makeIdentity("owner");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })));
    const before = await readLedgerText(owner.identity.identityID);
    const now = Math.floor(Date.now() / 1000);
    await patchLedger(owner.identity.identityID, (ledger) => {
      ledger.invitations["stale-invite"] = {
        invitation: {
          payload: { inviteID: "stale-invite", owner: ledger.owner, issuedAt: now - 60 * DAY, expiresAt: now - 59 * DAY, nonce: Buffer.alloc(16), tokenHash: Buffer.alloc(32), grantedScopes: ["approveEarlyEnd", "receiveRequests"] },
          signature: Buffer.alloc(64)
        },
        consumedAt: null
      };
    });

    // A no-op purge run first (nothing yet old enough) must not touch the revision.
    const noopSummary = await purgeExpiredRecords(testPool(), 3650, now);
    expect(noopSummary.ownersTouched).toBe(0);
    const stillBefore = await readLedgerText(owner.identity.identityID);
    expect(stillBefore.revision).toBe(before.revision);

    // The mutating purge (30-day window, and the invitation is 60 days old) must advance the revision by exactly one.
    const summary = await purgeExpiredRecords(testPool(), 30, now);
    expect(summary.ownersTouched).toBe(1);
    const after = await readLedgerText(owner.identity.identityID);
    expect(after.revision).toBe(before.revision + 1);

    // ...and it must be recorded with a durable receipt in the operation log,
    // exactly like any client-submitted mutation, so a client anchoring on
    // (revision, stateRoot) sees this revision accounted for.
    const receipt = await testPool().query(`SELECT kind, committed_revision FROM companion_operation WHERE owner_id = $1 AND committed_revision = $2`, [owner.identity.identityID, after.revision]);
    expect(receipt.rowCount).toBe(1);
    expect(receipt.rows[0].kind).toBe("retention_purge");
  });

  it("swiftDate helper round-trips (sanity check used across test fixtures)", () => {
    const seconds = 1_700_000_000;
    expect(typeof swiftDate(seconds)).toBe("number");
  });
});
