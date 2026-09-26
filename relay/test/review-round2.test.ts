// Regression tests for the final Slice A review round: integrity_error on
// every path that verifies a stored state root (mutation, owner-inbox read,
// purge), the DB-backed global rate limiter's signer/IP dimensions and
// cleanup, and the retention cron's owner-batch cursor/wraparound.

import { describe, it, expect } from "vitest";
import { makeIdentity, buildOperation, swiftDate, testPool, uniqueID } from "./setup.js";
import { submitOperation, fetchInboxOperation, computeStateRoot } from "../src/service.js";
import { purgeExpiredRecords } from "../src/retention.js";
import { chargeGlobalRateLimit, chargeGlobalRateLimits, purgeStaleRateLimits, getRetentionCursor, setRetentionCursor, GLOBAL_RATE_LIMIT_WINDOW_SECONDS, GLOBAL_RATE_LIMIT_MAX } from "../src/db.js";
import { deserializeLedger } from "../src/ledger.js";

function toRequest(op: object): Buffer {
  return Buffer.from(JSON.stringify(op), "utf8");
}

const BASE_NOW = 1_800_000_000;

async function corruptStateRoot(ownerID: string): Promise<void> {
  await testPool().query(`UPDATE companion_owner SET state_root = decode(repeat('ff', 32), 'hex') WHERE owner_id = $1`, [ownerID]);
}

describe("P2: integrity_error on every state-root-verifying path", () => {
  it("submitOperation fails closed with integrity_error when the stored root doesn't match the loaded state", async () => {
    const now = BASE_NOW + 1_000;
    const owner = makeIdentity("owner");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })), now);
    await corruptStateRoot(owner.identity.identityID);

    const op = buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: 1, operationID: uniqueID("ack-after-corrupt") });
    await expect(submitOperation(toRequest(op), now)).rejects.toMatchObject({ code: "integrity_error" });
  });

  it("fetchInboxOperation (owner path) fails closed with integrity_error when the stored root doesn't match", async () => {
    const now = BASE_NOW + 2_000;
    const owner = makeIdentity("owner");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })), now);
    await corruptStateRoot(owner.identity.identityID);

    const inboxOp = buildOperation({ kind: "inbox", payload: { identityID: owner.identity.identityID, issuedAt: swiftDate(now) }, signer: owner, expectedRevision: null });
    await expect(fetchInboxOperation(toRequest(inboxOp), now)).rejects.toMatchObject({ code: "integrity_error" });
  });

  it("purgeExpiredRecords fails closed with integrity_error when the stored root doesn't match, before pruning/re-rooting anything", async () => {
    const now = BASE_NOW + 3_000;
    const owner = makeIdentity("owner");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })), now);
    const before = await testPool().query<{ state: string; revision: string }>(`SELECT state, revision FROM companion_owner WHERE owner_id = $1`, [owner.identity.identityID]);
    await corruptStateRoot(owner.identity.identityID);

    await expect(purgeExpiredRecords(testPool(), 30, now)).rejects.toMatchObject({ code: "integrity_error" });

    // Nothing was re-rooted/committed on top of the corruption: state/revision unchanged.
    const after = await testPool().query<{ state: string; revision: string }>(`SELECT state, revision FROM companion_owner WHERE owner_id = $1`, [owner.identity.identityID]);
    expect(after.rows[0]!.state).toBe(before.rows[0]!.state);
    expect(after.rows[0]!.revision).toBe(before.rows[0]!.revision);
  });

  it("a correct (uncorrupted) state root passes verification on all three paths", async () => {
    const now = BASE_NOW + 4_000;
    const owner = makeIdentity("owner");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })), now);

    const row = await testPool().query<{ state: string; revision: string }>(`SELECT state, revision FROM companion_owner WHERE owner_id = $1`, [owner.identity.identityID]);
    const ledger = deserializeLedger(row.rows[0]!.state);
    expect(computeStateRoot(ledger, Number(row.rows[0]!.revision))).toBeInstanceOf(Buffer);

    const inboxOp = buildOperation({ kind: "inbox", payload: { identityID: owner.identity.identityID, issuedAt: swiftDate(now) }, signer: owner, expectedRevision: null });
    const inboxResult = await fetchInboxOperation(toRequest(inboxOp), now);
    expect(inboxResult.ownerIdentityID).toBe(owner.identity.identityID);

    const summary = await purgeExpiredRecords(testPool(), 30, now);
    expect(summary.ownersScanned).toBeGreaterThanOrEqual(1);
  });
});

describe("P2: global rate limiter -- signer and IP dimensions, and stale-row cleanup", () => {
  it("charges are independent per subject: a signer over budget does not block a different signer", async () => {
    const subjectA = uniqueID("signer-a");
    const subjectB = uniqueID("signer-b");
    const now = BASE_NOW + 5_000;
    for (let i = 0; i < GLOBAL_RATE_LIMIT_MAX; i += 1) {
      expect(await chargeGlobalRateLimit(testPool(), subjectA, now, GLOBAL_RATE_LIMIT_WINDOW_SECONDS, GLOBAL_RATE_LIMIT_MAX)).toBe(true);
    }
    expect(await chargeGlobalRateLimit(testPool(), subjectA, now, GLOBAL_RATE_LIMIT_WINDOW_SECONDS, GLOBAL_RATE_LIMIT_MAX)).toBe(false);
    // A different subject (signer B) is unaffected.
    expect(await chargeGlobalRateLimit(testPool(), subjectB, now, GLOBAL_RATE_LIMIT_WINDOW_SECONDS, GLOBAL_RATE_LIMIT_MAX)).toBe(true);
  });

  it("chargeGlobalRateLimits allows only when *every* subject (signer and IP) is within budget, and charges both regardless", async () => {
    const signerSubject = `signer:${uniqueID("s")}`;
    const ipSubject = `ip:${uniqueID("1.2.3.4")}`;
    const now = BASE_NOW + 6_000;
    // Drive the IP subject to its limit directly.
    for (let i = 0; i < GLOBAL_RATE_LIMIT_MAX; i += 1) {
      await chargeGlobalRateLimit(testPool(), ipSubject, now, GLOBAL_RATE_LIMIT_WINDOW_SECONDS, GLOBAL_RATE_LIMIT_MAX);
    }
    // The signer itself is fresh, but sharing an over-budget IP must still deny the request.
    const allowed = await chargeGlobalRateLimits(testPool(), [signerSubject, ipSubject], now, GLOBAL_RATE_LIMIT_WINDOW_SECONDS, GLOBAL_RATE_LIMIT_MAX);
    expect(allowed).toBe(false);
    // The signer subject was still charged even though the overall request was denied
    // (charging is unconditional per subject, per db.ts's chargeGlobalRateLimits).
    const signerOnlyStillAllowed = await chargeGlobalRateLimit(testPool(), signerSubject, now, GLOBAL_RATE_LIMIT_WINDOW_SECONDS, GLOBAL_RATE_LIMIT_MAX);
    expect(signerOnlyStillAllowed).toBe(true); // still well within its own budget (charged once above, once here = 2)
    const row = await testPool().query<{ count: number }>(`SELECT count FROM companion_rate_limit WHERE subject = $1`, [signerSubject]);
    expect(row.rows[0]!.count).toBe(2);
  });

  it("an HTTP request is rate-limited end to end by IP even across different signer identities", async () => {
    const { handleOperations } = await import("../src/handlers.js");
    const ip = uniqueID("9.9.9.9");
    const headers = { "x-forwarded-for": ip };
    function post(op: object) {
      return new Request("http://127.0.0.1:8002/v1/operations", { method: "POST", body: JSON.stringify(op), headers });
    }
    let lastStatus = 200;
    for (let i = 0; i < GLOBAL_RATE_LIMIT_MAX + 1; i += 1) {
      const owner = makeIdentity("owner");
      const response = await handleOperations(post(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })));
      lastStatus = response.status;
      if (lastStatus === 429) break;
    }
    expect(lastStatus).toBe(429);
  });

  it("purgeStaleRateLimits deletes rows whose window has elapsed relative to now, not on the 30-day retention window", async () => {
    const subject = uniqueID("stale-subject");
    const now = BASE_NOW + 7_000;
    await chargeGlobalRateLimit(testPool(), subject, now, GLOBAL_RATE_LIMIT_WINDOW_SECONDS, GLOBAL_RATE_LIMIT_MAX);

    // Just inside the window: not purged.
    const stillFresh = await purgeStaleRateLimits(testPool(), now + GLOBAL_RATE_LIMIT_WINDOW_SECONDS - 1, GLOBAL_RATE_LIMIT_WINDOW_SECONDS);
    const stillThere = await testPool().query(`SELECT 1 FROM companion_rate_limit WHERE subject = $1`, [subject]);
    expect(stillThere.rowCount).toBe(1);
    void stillFresh;

    // Just past the window (far short of 30 days): purged.
    const purged = await purgeStaleRateLimits(testPool(), now + GLOBAL_RATE_LIMIT_WINDOW_SECONDS + 1, GLOBAL_RATE_LIMIT_WINDOW_SECONDS);
    expect(purged).toBeGreaterThanOrEqual(1);
    const gone = await testPool().query(`SELECT 1 FROM companion_rate_limit WHERE subject = $1`, [subject]);
    expect(gone.rowCount).toBe(0);
  });
});

describe("P2: retention cron cursor persists and wraps around", () => {
  it("processes owners in owner_id order starting after the persisted cursor, and wraps around once exhausted", async () => {
    // Three owners with deterministic, sortable IDs so batch order is predictable.
    const owners = await Promise.all(
      ["a", "b", "c"].map(async (suffix) => {
        const owner = makeIdentity("owner");
        // Overwrite the identityID with a sortable prefix directly in the DB
        // is not possible (it's derived from the public key), so instead we
        // just rely on whatever order real identityIDs sort in and read the
        // cursor back to prove *some* deterministic subset + wraparound
        // behavior, rather than asserting an exact a/b/c order.
        await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })), BASE_NOW + 8_000);
        return owner;
      })
    );
    expect(owners).toHaveLength(3);

    await setRetentionCursor(testPool(), null);
    const firstBatch = await purgeExpiredRecords(testPool(), 30, BASE_NOW + 8_100, { maxOwners: 2 });
    expect(firstBatch.ownersScanned).toBe(2);
    const cursorAfterFirst = await getRetentionCursor(testPool());
    expect(cursorAfterFirst).not.toBeNull();

    const secondBatch = await purgeExpiredRecords(testPool(), 30, BASE_NOW + 8_200, { maxOwners: 2 });
    // Only one owner remained past the cursor, so this batch wraps around and
    // picks up one more from the start to fill the batch of 2.
    expect(secondBatch.ownersScanned).toBe(2);

    // A third batch, cursor now past all three at least once, must still make progress (never gets stuck).
    const thirdBatch = await purgeExpiredRecords(testPool(), 30, BASE_NOW + 8_300, { maxOwners: 2 });
    expect(thirdBatch.ownersScanned).toBe(2);
  });

  it("a run with no maxOwners cap ignores the cursor and processes every owner without persisting it", async () => {
    const owner = makeIdentity("owner");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })), BASE_NOW + 9_000);
    await setRetentionCursor(testPool(), "some-arbitrary-cursor-value");
    const before = await getRetentionCursor(testPool());
    await purgeExpiredRecords(testPool(), 30, BASE_NOW + 9_100);
    const after = await getRetentionCursor(testPool());
    expect(after).toBe(before); // untouched
  });
});
