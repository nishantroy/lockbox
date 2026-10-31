// Regression tests for the Slice A review fixes: the pairing_id routing
// collision (P1.1), consent replay after retention purge (P1.3), inbox
// freshness (P1.3), and the time-dependent invariants ported from
// CompanionKitTests/DurableRelayServiceTests using explicit `now` injection
// (P1.4) rather than real wall-clock timing.

import { describe, it, expect } from "vitest";
import { makeIdentity, buildOperation, pairV3, buildInvite, buildAcceptance, swiftDate, signPayloadFields, encodeDeviceIdentityWire, uniqueID, testPool, type TestIdentity } from "./setup.js";
import { submitOperation, fetchInboxOperation } from "../src/service.js";
import { base64url, COMPANION_VERSION } from "../src/canonical.js";
import { deserializeLedger, serializeLedger } from "../src/ledger.js";
import { computeStateRoot } from "../src/service.js";

function toRequest(op: object): Buffer {
  return Buffer.from(JSON.stringify(op), "utf8");
}

async function expectRejected(op: object, code: string, now?: number) {
  await expect(submitOperation(toRequest(op), now)).rejects.toMatchObject({ code });
}

const BASE_NOW = 1_700_000_000; // fixed, deterministic -- no dependency on real wall-clock time

interface Scenario {
  owner: TestIdentity;
  approver: TestIdentity;
  pairingID: string;
  sessionID: string;
  activeSetID: string;
  nextRevision: number;
}

/** invite -> accept -> confirm -> consent grant -> consent accept -> session, at explicit, fully-deterministic timestamps. */
async function setupPairedSession(now: number, overrides: Partial<{ scopes: string[] }> = {}): Promise<Scenario> {
  const owner = makeIdentity("owner");
  const approver = makeIdentity("trustedApprover");
  let revision = 0;

  const paired = await pairV3({ owner, approver, now, clock: now });
  const pairingID = paired.pairingID;
  revision = paired.nextRevision;

  const sessionID = uniqueID("session");
  const activeSetID = uniqueID("activeset");
  const sessionPayload = { owner: encodeDeviceIdentityWire(owner.identity), sessionID, activeSetID, startsAt: swiftDate(now - 60), endsAt: swiftDate(now + 100_000) };
  await submitOperation(toRequest(buildOperation({ kind: "session", payload: sessionPayload, signer: owner, expectedRevision: revision++ })), now);

  return { owner, approver, pairingID, sessionID, activeSetID, nextRevision: revision };
}

function requestPayload(s: Scenario, requestID: string, now: number, expiresAt: number) {
  return {
    requestID,
    owner: encodeDeviceIdentityWire(s.owner.identity),
    pairingID: s.pairingID,
    pairEpoch: 1,
    consentGeneration: 2,
    sessionID: s.sessionID,
    activeSetID: s.activeSetID,
    purpose: "approveEarlyEnd",
    targetedApproverIDs: [s.approver.identity.identityID],
    targetBindings: [{ approverIdentityID: s.approver.identity.identityID, pairingID: s.pairingID, pairEpoch: 1, consentGeneration: 2 }],
    message: null,
    createdAt: swiftDate(now),
    expiresAt: swiftDate(expiresAt),
    status: "pending",
    decisions: { [s.approver.identity.identityID]: "pending" }
  };
}

function approvalPayload(s: Scenario, requestID: string, approvalID: string, decision: "approved" | "declined", nonceByte: number, now: number) {
  const nonce = Buffer.alloc(20, nonceByte);
  const fields = [approvalID, requestID, s.pairingID, "1", "2", s.sessionID, s.activeSetID, s.approver.identity.identityID, base64url(s.approver.identity.publicKey), decision, String(now * 1000), base64url(nonce)];
  return {
    approvalID,
    nonce: nonce.toString("base64"),
    requestID,
    pairingID: s.pairingID,
    pairEpoch: 1,
    consentGeneration: 2,
    sessionID: s.sessionID,
    activeSetID: s.activeSetID,
    approver: encodeDeviceIdentityWire(s.approver.identity),
    decision,
    issuedAt: swiftDate(now),
    signature: signPayloadFields(s.approver, `${COMPANION_VERSION}.approval`, fields).toString("base64")
  };
}

// ---------------------------------------------------------------------------
// P1.1 -- pairing_id routing collision
// ---------------------------------------------------------------------------

describe("P1.1: pairing_id routing collision", () => {
  it("a second owner cannot pre-claim or hijack a pairing_id another owner already claimed via replace_pairing", async () => {
    const now = BASE_NOW + 1_000;
    const victim = await setupPairedSession(now);
    let victimRevision = victim.nextRevision;

    // Victim replaces their pairing, claiming a specific replacementPairingID.
    const newApproverA = makeIdentity("trustedApprover");
    const collidingPairingID = uniqueID("collide-pairing");
    const replaceFieldsA = [
      uniqueID("replace"),
      victim.pairingID,
      "1",
      collidingPairingID,
      victim.owner.identity.identityID,
      base64url(victim.owner.identity.publicKey),
      newApproverA.identity.identityID,
      base64url(newApproverA.identity.publicKey),
      "2",
      String(now * 1000)
    ];
    const replacementIDA = replaceFieldsA[0]!;
    const proposalA = {
      replacementID: replacementIDA,
      previousPairingID: victim.pairingID,
      previousEpoch: 1,
      replacementPairingID: collidingPairingID,
      replacement: encodeDeviceIdentityWire(newApproverA.identity),
      owner: encodeDeviceIdentityWire(victim.owner.identity),
      replacementEpoch: 2,
      issuedAt: swiftDate(now),
      signature: signPayloadFields(newApproverA, `${COMPANION_VERSION}.pairing-replacement`, replaceFieldsA).toString("base64")
    };
    const replaceResponseA = await submitOperation(toRequest(buildOperation({ kind: "replace_pairing", payload: proposalA, signer: victim.owner, expectedRevision: victimRevision++ })), now);
    expect((replaceResponseA.result as any).value.pairingID).toBe(collidingPairingID);

    // A second, unrelated owner pairs with a *different* approver but a
    // malicious replacement proposal chooses the *same* replacementPairingID
    // the victim already claimed.
    const attackerOwnerSession = await setupPairedSession(now + 10);
    let attackerRevision = attackerOwnerSession.nextRevision;
    const newApproverB = makeIdentity("trustedApprover");
    const replaceFieldsB = [
      uniqueID("replace"),
      attackerOwnerSession.pairingID,
      "1",
      collidingPairingID, // <-- same pairingID the victim owns
      attackerOwnerSession.owner.identity.identityID,
      base64url(attackerOwnerSession.owner.identity.publicKey),
      newApproverB.identity.identityID,
      base64url(newApproverB.identity.publicKey),
      "2",
      String((now + 10) * 1000)
    ];
    const proposalB = {
      replacementID: replaceFieldsB[0]!,
      previousPairingID: attackerOwnerSession.pairingID,
      previousEpoch: 1,
      replacementPairingID: collidingPairingID,
      replacement: encodeDeviceIdentityWire(newApproverB.identity),
      owner: encodeDeviceIdentityWire(attackerOwnerSession.owner.identity),
      replacementEpoch: 2,
      issuedAt: swiftDate(now + 10),
      signature: signPayloadFields(newApproverB, `${COMPANION_VERSION}.pairing-replacement`, replaceFieldsB).toString("base64")
    };
    const hijackOp = buildOperation({ kind: "replace_pairing", payload: proposalB, signer: attackerOwnerSession.owner, expectedRevision: attackerRevision });
    await expectRejected(hijackOp, "pairing_conflict", now + 10);

    // The victim's routing must be completely unaffected: an approval signed
    // by the victim's new approver, targeting the colliding pairingID, must
    // still resolve to the victim owner, not the attacker.
    const requestID = uniqueID("request");
    const victimRequest = {
      requestID,
      owner: encodeDeviceIdentityWire(victim.owner.identity),
      pairingID: collidingPairingID,
      pairEpoch: 2,
      consentGeneration: 1,
      sessionID: victim.sessionID,
      activeSetID: victim.activeSetID,
      purpose: "approveEarlyEnd",
      targetedApproverIDs: [newApproverA.identity.identityID],
      targetBindings: [{ approverIdentityID: newApproverA.identity.identityID, pairingID: collidingPairingID, pairEpoch: 2, consentGeneration: 1 }],
      message: null,
      createdAt: swiftDate(now + 20),
      expiresAt: swiftDate(now + 20_000),
      status: "pending",
      decisions: { [newApproverA.identity.identityID]: "pending" }
    };
    // (No consent was granted for the replacement pairing, so this specific
    // request will fail on consent -- but the important assertion is *which
    // owner's transaction it fails inside*: it must never reach the
    // attacker's ledger. We assert this indirectly via the approval path
    // below, which fails with `wrong_target`/`consent_required` scoped to
    // the victim, never `unknown_owner` or a silent no-op against the
    // attacker's ledger.)
    void victimRequest;

    const bogusApproval = approvalPayload({ ...victim, pairingID: collidingPairingID, approver: newApproverA }, requestID, uniqueID("approval"), "approved", 99, now + 20);
    const approvalOp = buildOperation({ kind: "approval", payload: bogusApproval, signer: newApproverA, expectedRevision: null });
    // Resolves to the *victim* owner (the only owner actually holding this
    // pairing_id in the routing index) and fails there for a request that
    // was never created, not `unknown_owner` (which would indicate it fell
    // through to no owner or the attacker's).
    await expectRejected(approvalOp, "wrong_target", now + 20);
  });

  it("purging a revoked pairing only removes that owner's own routing row, never a different owner's", async () => {
    // Simulates the "pre-claim victim's ID, then get it purged, hijacking
    // routing" shape directly against the index, since provoking a genuine
    // cross-owner collision through the protocol is prevented by the fix
    // above -- this proves the *retention* half of the fix independently.
    const now = BASE_NOW + 2_000;
    const a = await setupPairedSession(now);
    const sharedID = uniqueID("shared-pairing-id");
    await testPool().query(`INSERT INTO companion_approver_pairing (pairing_id, approver_identity_id, owner_id) VALUES ($1, $2, $3)`, [sharedID, a.approver.identity.identityID, a.owner.identity.identityID]);

    const { deleteApproverPairing } = await import("../src/db.js");
    const otherOwnerID = uniqueID("other-owner-id");
    // Attempting to delete the same pairing_id under a *different* owner_id must not touch the real row.
    await deleteApproverPairing(testPool(), otherOwnerID, sharedID);
    const stillThere = await testPool().query(`SELECT owner_id FROM companion_approver_pairing WHERE pairing_id = $1`, [sharedID]);
    expect(stillThere.rows[0]?.owner_id).toBe(a.owner.identity.identityID);

    // Deleting it under the *correct* owner does remove it.
    await deleteApproverPairing(testPool(), a.owner.identity.identityID, sharedID);
    const gone = await testPool().query(`SELECT 1 FROM companion_approver_pairing WHERE pairing_id = $1`, [sharedID]);
    expect(gone.rowCount).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// P1.3 -- consent replay after purge, and inbox freshness
// ---------------------------------------------------------------------------

describe("P1.3: consent max-age and inbox freshness", () => {
  it("rejects a consent mutation whose issuedAt is more than 24h in the past, even with a fresh nonce and correct signature", async () => {
    const now = BASE_NOW + 3_000;
    const s = await setupPairedSession(now);
    const staleIssuedAt = now - 25 * 3600; // 25h old
    const revokePayload = {
      relationshipID: s.pairingID,
      pairingID: s.pairingID,
      pairEpoch: 1,
      owner: encodeDeviceIdentityWire(s.owner.identity),
      approver: encodeDeviceIdentityWire(s.approver.identity),
      action: "ownerRevoke",
      scopes: { scopes: ["approveEarlyEnd", "receiveRequests"] },
      nonce: Buffer.alloc(20, 55).toString("base64"),
      issuedAt: swiftDate(staleIssuedAt)
    };
    const op = buildOperation({ kind: "consent", payload: revokePayload, signer: s.owner, expectedRevision: s.nextRevision });
    await expectRejected(op, "expired", now);
  });

  it("simulates the captured-old-grant replay after a 30-day purge: rejected by the age check even though the nonce/operation-log markers no longer exist", async () => {
    const t0 = BASE_NOW + 4_000;
    const s = await setupPairedSession(t0);

    // Owner revokes shortly after granting.
    const revokeNonce = Buffer.alloc(20, 61).toString("base64");
    const revokePayload = {
      relationshipID: s.pairingID,
      pairingID: s.pairingID,
      pairEpoch: 1,
      owner: encodeDeviceIdentityWire(s.owner.identity),
      approver: encodeDeviceIdentityWire(s.approver.identity),
      action: "ownerRevoke",
      scopes: { scopes: ["approveEarlyEnd", "receiveRequests"] },
      nonce: revokeNonce,
      issuedAt: swiftDate(t0 + 5)
    };
    await submitOperation(toRequest(buildOperation({ kind: "consent", payload: revokePayload, signer: s.owner, expectedRevision: s.nextRevision })), t0 + 5);

    // 31 days later, an attacker (who captured the *original* grant
    // operation from t0) replays it with a fresh operationID (as if the
    // original operation-log row and nonce marker had already been purged).
    const muchLater = t0 + 31 * 86_400;
    const originalGrantPayload = {
      relationshipID: s.pairingID,
      pairingID: s.pairingID,
      pairEpoch: 1,
      owner: encodeDeviceIdentityWire(s.owner.identity),
      approver: encodeDeviceIdentityWire(s.approver.identity),
      action: "ownerGrant",
      scopes: { scopes: ["approveEarlyEnd", "receiveRequests"] },
      nonce: Buffer.alloc(20, 9).toString("base64"), // the same nonce used inside setupPairedSession's original grant
      issuedAt: swiftDate(t0 + 3) // the *original* issuedAt -- now 31 days stale
    };
    const replayOp = buildOperation({ kind: "consent", payload: originalGrantPayload, signer: s.owner, operationID: uniqueID("replayed-grant"), expectedRevision: null });
    await expectRejected(replayOp, "expired", muchLater);
  });

  it("inbox: an issuedAt within the 5-minute window is accepted; one 5 minutes and 1 second stale is rejected", async () => {
    const now = BASE_NOW + 5_000;
    const owner = makeIdentity("owner");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })), now);

    const freshInbox = buildOperation({ kind: "inbox", payload: { identityID: owner.identity.identityID, issuedAt: swiftDate(now - 60) }, signer: owner, expectedRevision: null });
    const freshResult = await fetchInboxOperation(toRequest(freshInbox), now);
    expect(freshResult.ownerIdentityID).toBe(owner.identity.identityID);

    const staleInbox = buildOperation({ kind: "inbox", payload: { identityID: owner.identity.identityID, issuedAt: swiftDate(now - 301) }, signer: owner, expectedRevision: null });
    await expect(fetchInboxOperation(toRequest(staleInbox), now)).rejects.toMatchObject({ code: "expired" });

    // Future skew is bounded separately, at 60s (matching every other
    // `issuedAt` field in the protocol), not the 5-minute past window.
    const futureInbox = buildOperation({ kind: "inbox", payload: { identityID: owner.identity.identityID, issuedAt: swiftDate(now + 61) }, signer: owner, expectedRevision: null });
    await expect(fetchInboxOperation(toRequest(futureInbox), now)).rejects.toMatchObject({ code: "expired" });
  });

  it("inbox: a query with no issuedAt at all is rejected by default (REQUIRE_FRESH_INBOX defaults to true)", async () => {
    const now = BASE_NOW + 6_000;
    const owner = makeIdentity("owner");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })), now);
    const noTimestampInbox = buildOperation({ kind: "inbox", payload: { identityID: owner.identity.identityID }, signer: owner, expectedRevision: null });

    expect(process.env.REQUIRE_FRESH_INBOX).toBeUndefined();
    await expect(fetchInboxOperation(toRequest(noTimestampInbox), now)).rejects.toMatchObject({ code: "malformed" });
  });

  it("inbox: REQUIRE_FRESH_INBOX=\"false\" explicitly allows the legacy (issuedAt-less) form", async () => {
    const now = BASE_NOW + 6_500;
    const owner = makeIdentity("owner");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })), now);
    const noTimestampInbox = buildOperation({ kind: "inbox", payload: { identityID: owner.identity.identityID }, signer: owner, expectedRevision: null });

    process.env.REQUIRE_FRESH_INBOX = "false";
    try {
      const result = await fetchInboxOperation(toRequest(noTimestampInbox), now);
      expect(result.ownerIdentityID).toBe(owner.identity.identityID);
    } finally {
      delete process.env.REQUIRE_FRESH_INBOX;
    }
  });

  it("inbox fetches are never stored/replayed as idempotency receipts: two identical-identity fetches reflect current state across an intervening mutation", async () => {
    const now = BASE_NOW + 7_000;
    const s = await setupPairedSession(now);

    // Two fetches with the *same* signer identity (and, since `issuedAt` is
    // part of the signed body, they would even collide on operationID if
    // this were ever accidentally treated as a mutation to idempotency-check
    // against -- confirm it is not).
    const inboxQueryPayload = { identityID: s.owner.identity.identityID, issuedAt: swiftDate(now) };
    const inboxOp = buildOperation({ kind: "inbox", payload: inboxQueryPayload, signer: s.owner, expectedRevision: null });

    const before = await fetchInboxOperation(toRequest(inboxOp), now);
    expect(before.requests).toHaveLength(0);

    const requestID = uniqueID("request");
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(s, requestID, now, now + 40_000), signer: s.owner, expectedRevision: s.nextRevision })), now);

    // The exact same signed inbox operation body, refetched, must reflect
    // the new committed state -- not a cached/replayed response from the
    // first identical-body fetch.
    const after = await fetchInboxOperation(toRequest(inboxOp), now);
    expect(after.requests.map((r) => r.requestID)).toContain(requestID);
    expect(after.revision).toBeGreaterThan(before.revision);

    // And confirm inbox fetches never touch the operation log at all.
    const opLogRows = await testPool().query(`SELECT 1 FROM companion_operation WHERE owner_id = $1 AND kind = 'inbox'`, [s.owner.identity.identityID]);
    expect(opLogRows.rowCount).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// P1.4 -- time-dependent invariants, with `now` injected explicitly
// ---------------------------------------------------------------------------

describe("P1.4: time-dependent invariants", () => {
  it("natural end wins: an approved-but-unconsumed request is terminally expired by natural_end and cannot later be used", async () => {
    const now = BASE_NOW + 10_000;
    const s = await setupPairedSession(now);
    const requestID = uniqueID("request");
    let revision = s.nextRevision;
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(s, requestID, now, now + 500), signer: s.owner, expectedRevision: revision++ })), now);
    const approvalID = uniqueID("approval");
    const approval = approvalPayload(s, requestID, approvalID, "approved", 12, now);
    await submitOperation(toRequest(buildOperation({ kind: "approval", payload: approval, signer: s.approver, expectedRevision: revision++ })), now);

    // Session ends at `now + 100_000`; jump forward and call natural_end.
    const afterEnd = now + 100_001;
    const naturalEndOp = buildOperation({ kind: "natural_end", payload: { sessionID: s.sessionID, activeSetID: s.activeSetID }, signer: s.owner, expectedRevision: revision++ });
    const ackResponse = await submitOperation(toRequest(naturalEndOp), afterEnd);
    expect(ackResponse.result.kind).toBe("acknowledgement");

    // The approved request can no longer be used: natural end won the race.
    const useOp = buildOperation({ kind: "use", payload: { approval, requestID, useID: uniqueID("use"), consentGeneration: 2 }, signer: s.owner, expectedRevision: null });
    await expectRejected(useOp, "replay", afterEnd);
  });

  it("a command that arrives exactly at (or after) a request's expiry commits the terminal expiry and the disposition is idempotently replayed", async () => {
    const now = BASE_NOW + 11_000;
    const s = await setupPairedSession(now);
    const requestID = uniqueID("request");
    let revision = s.nextRevision;
    const expiresAt = now + 100;
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(s, requestID, now, expiresAt), signer: s.owner, expectedRevision: revision++ })), now);

    const cancelOp = buildOperation({ kind: "cancel", payload: { requestID }, signer: s.owner, expectedRevision: revision });
    // Submitted exactly at the boundary: `now >= request.expiresAt`.
    await expectRejected(cancelOp, "expired", expiresAt);

    // Idempotent replay of the exact same (now-committed, terminally
    // rejected) operation must report the same terminal outcome again, not
    // re-run the mutation or throw a different error.
    await expectRejected(cancelOp, "expired", expiresAt + 10);
  });

  it("session.endsAt boundary: a request cannot be created once the session has ended", async () => {
    const now = BASE_NOW + 12_000;
    const s = await setupPairedSession(now);
    // The scenario's session ends at `now + 100_000`; try to create a
    // request exactly at that boundary.
    const requestID = uniqueID("request");
    const op = buildOperation({ kind: "request", payload: requestPayload(s, requestID, now + 100_000, now + 100_500), signer: s.owner, expectedRevision: s.nextRevision });
    await expectRejected(op, "expired", now + 100_000);
  });

  it("v3 single use: two friends hold the same link, the first accept wins and the second is rejected (replay), with no second pairing", async () => {
    const now = BASE_NOW + 13_000;
    const owner = makeIdentity("owner");
    const approverA = makeIdentity("trustedApprover");
    const approverB = makeIdentity("trustedApprover");
    let revision = 0;
    const invite = buildInvite(owner, now);
    await submitOperation(toRequest(buildOperation({ kind: "invite", payload: invite.invitation, signer: owner, expectedRevision: revision++ })), now);
    const first = await submitOperation(
      toRequest(buildOperation({ kind: "accept", payload: buildAcceptance({ owner, approver: approverA, inviteID: invite.inviteID, token: invite.token, now: now + 1 }), signer: approverA, expectedRevision: revision++ })),
      now
    );
    expect(first.result.kind).toBe("pairing");
    const secondOp = buildOperation({ kind: "accept", payload: buildAcceptance({ owner, approver: approverB, inviteID: invite.inviteID, token: invite.token, now: now + 2 }), signer: approverB, expectedRevision: revision });
    await expectRejected(secondOp, "replay", now);
    const inbox = await fetchInboxOperation(toRequest(buildOperation({ kind: "inbox", payload: { identityID: owner.identity.identityID, issuedAt: swiftDate(now) }, signer: owner, expectedRevision: null })), now);
    expect(inbox.pairings).toHaveLength(1);
  });

  it("v3: a wrong token is rejected as unauthorized and the invite stays usable with the right one", async () => {
    const now = BASE_NOW + 14_000;
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    let revision = 0;
    const invite = buildInvite(owner, now);
    await submitOperation(toRequest(buildOperation({ kind: "invite", payload: invite.invitation, signer: owner, expectedRevision: revision++ })), now);
    const wrong = buildInvite(owner, now).token;
    const wrongOp = buildOperation({ kind: "accept", payload: buildAcceptance({ owner, approver, inviteID: invite.inviteID, token: wrong, now: now + 1 }), signer: approver, expectedRevision: revision });
    await expectRejected(wrongOp, "unauthorized", now);
    const rightOp = buildOperation({ kind: "accept", payload: buildAcceptance({ owner, approver, inviteID: invite.inviteID, token: invite.token, now: now + 1 }), signer: approver, expectedRevision: revision });
    expect((await submitOperation(toRequest(rightOp), now)).result.kind).toBe("pairing");
  });

  it("forged invite signature and a swapped receiver/issuer are both rejected", async () => {
    const now = BASE_NOW + 15_000;
    const owner = makeIdentity("owner");
    const attacker = makeIdentity("owner");

    // Forged: the payload names `owner` but is signed by the attacker's key.
    const forged = buildInvite(owner, now);
    const attackerSigned = buildInvite(attacker, now, { inviteID: forged.inviteID, token: forged.token });
    const forgedInvitation = { payload: forged.invitation.payload, signature: attackerSigned.invitation.signature };
    const forgedOp = buildOperation({ kind: "invite", payload: forgedInvitation, signer: owner, expectedRevision: 0 });
    await expectRejected(forgedOp, "invalid_signature", now);

    // Swapped issuer: the *operation* is signed by the attacker, not the
    // claimed invite owner, so it cannot even reach the invite-signature
    // check -- rejected as unauthorized for signing someone else's invite.
    const swappedOp = buildOperation({ kind: "invite", payload: forged.invitation, signer: attacker, expectedRevision: 0 });
    await expectRejected(swappedOp, "unauthorized", now);
  });

  it("R6/mutualPact scopes are denied (unsupported_scope), never authorizing anything", async () => {
    const now = BASE_NOW + 16_000;
    const s = await setupPairedSession(now);
    const grantPayload = {
      relationshipID: s.pairingID,
      pairingID: s.pairingID,
      pairEpoch: 1,
      owner: encodeDeviceIdentityWire(s.owner.identity),
      approver: encodeDeviceIdentityWire(s.approver.identity),
      action: "ownerGrant",
      scopes: { scopes: ["mutualPact"] },
      nonce: Buffer.alloc(20, 71).toString("base64"),
      issuedAt: swiftDate(now)
    };
    const op = buildOperation({ kind: "consent", payload: grantPayload, signer: s.owner, expectedRevision: s.nextRevision });
    await expectRejected(op, "unsupported_scope", now);
  });

  it("an approval nonce cannot be reused under a different approvalID", async () => {
    const now = BASE_NOW + 17_000;
    const s = await setupPairedSession(now);
    let revision = s.nextRevision;
    const requestID = uniqueID("request");
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(s, requestID, now, now + 40_000), signer: s.owner, expectedRevision: revision++ })), now);

    const nonce = Buffer.alloc(20, 33);
    const firstApprovalID = uniqueID("approval");
    const firstFields = [firstApprovalID, requestID, s.pairingID, "1", "2", s.sessionID, s.activeSetID, s.approver.identity.identityID, base64url(s.approver.identity.publicKey), "declined", String(now * 1000), base64url(nonce)];
    const firstApproval = {
      approvalID: firstApprovalID,
      nonce: nonce.toString("base64"),
      requestID,
      pairingID: s.pairingID,
      pairEpoch: 1,
      consentGeneration: 2,
      sessionID: s.sessionID,
      activeSetID: s.activeSetID,
      approver: encodeDeviceIdentityWire(s.approver.identity),
      decision: "declined",
      issuedAt: swiftDate(now),
      signature: signPayloadFields(s.approver, `${COMPANION_VERSION}.approval`, firstFields).toString("base64")
    };
    await submitOperation(toRequest(buildOperation({ kind: "approval", payload: firstApproval, signer: s.approver, expectedRevision: revision++ })), now);

    // Reusing the exact same nonce bytes under a *different* approvalID must be rejected.
    const secondApprovalID = uniqueID("approval-2");
    const secondFields = [secondApprovalID, requestID, s.pairingID, "1", "2", s.sessionID, s.activeSetID, s.approver.identity.identityID, base64url(s.approver.identity.publicKey), "approved", String(now * 1000), base64url(nonce)];
    const secondApproval = {
      approvalID: secondApprovalID,
      nonce: nonce.toString("base64"),
      requestID,
      pairingID: s.pairingID,
      pairEpoch: 1,
      consentGeneration: 2,
      sessionID: s.sessionID,
      activeSetID: s.activeSetID,
      approver: encodeDeviceIdentityWire(s.approver.identity),
      decision: "approved",
      issuedAt: swiftDate(now),
      signature: signPayloadFields(s.approver, `${COMPANION_VERSION}.approval`, secondFields).toString("base64")
    };
    const op = buildOperation({ kind: "approval", payload: secondApproval, signer: s.approver, expectedRevision: revision });
    await expectRejected(op, "wrong_target", now);
  });

  it("an approvalID cannot be reused across two different requests", async () => {
    const now = BASE_NOW + 18_000;
    const s = await setupPairedSession(now);
    let revision = s.nextRevision;
    const requestID1 = uniqueID("request");
    const requestID2 = uniqueID("request");
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(s, requestID1, now, now + 40_000), signer: s.owner, expectedRevision: revision++ })), now);
    await submitOperation(toRequest(buildOperation({ kind: "cancel", payload: { requestID: requestID1 }, signer: s.owner, expectedRevision: revision++ })), now);
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(s, requestID2, now, now + 40_000), signer: s.owner, expectedRevision: revision++ })), now);

    const sharedApprovalID = uniqueID("shared-approval");
    // First use against request1 fails only because request1 is cancelled,
    // establishing nothing in ledger.approvals -- so instead approve
    // request2 first to claim the approvalID, then try to reuse it (with a
    // fresh nonce) against a third fresh request.
    const requestID3 = uniqueID("request");
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(s, requestID3, now, now + 40_000), signer: s.owner, expectedRevision: revision++ })), now);

    const nonce2 = Buffer.alloc(20, 44);
    const fields2 = [sharedApprovalID, requestID2, s.pairingID, "1", "2", s.sessionID, s.activeSetID, s.approver.identity.identityID, base64url(s.approver.identity.publicKey), "approved", String(now * 1000), base64url(nonce2)];
    const approval2 = {
      approvalID: sharedApprovalID,
      nonce: nonce2.toString("base64"),
      requestID: requestID2,
      pairingID: s.pairingID,
      pairEpoch: 1,
      consentGeneration: 2,
      sessionID: s.sessionID,
      activeSetID: s.activeSetID,
      approver: encodeDeviceIdentityWire(s.approver.identity),
      decision: "approved",
      issuedAt: swiftDate(now),
      signature: signPayloadFields(s.approver, `${COMPANION_VERSION}.approval`, fields2).toString("base64")
    };
    await submitOperation(toRequest(buildOperation({ kind: "approval", payload: approval2, signer: s.approver, expectedRevision: revision++ })), now);

    const nonce3 = Buffer.alloc(20, 55);
    const fields3 = [sharedApprovalID, requestID3, s.pairingID, "1", "2", s.sessionID, s.activeSetID, s.approver.identity.identityID, base64url(s.approver.identity.publicKey), "approved", String(now * 1000), base64url(nonce3)];
    const approval3 = {
      approvalID: sharedApprovalID, // <-- collides with the one already accepted for request2
      nonce: nonce3.toString("base64"),
      requestID: requestID3,
      pairingID: s.pairingID,
      pairEpoch: 1,
      consentGeneration: 2,
      sessionID: s.sessionID,
      activeSetID: s.activeSetID,
      approver: encodeDeviceIdentityWire(s.approver.identity),
      decision: "approved",
      issuedAt: swiftDate(now),
      signature: signPayloadFields(s.approver, `${COMPANION_VERSION}.approval`, fields3).toString("base64")
    };
    const op = buildOperation({ kind: "approval", payload: approval3, signer: s.approver, expectedRevision: revision });
    await expectRejected(op, "wrong_target", now);
  });

  it("pairing replacement revokes exactly the old epoch, and consent is not copied to the replacement pairing", async () => {
    const now = BASE_NOW + 19_000;
    const s = await setupPairedSession(now);
    let revision = s.nextRevision;
    const newApprover = makeIdentity("trustedApprover");
    const replacementID = uniqueID("replace");
    const replacementPairingID = uniqueID("new-pairing");
    const fields = [replacementID, s.pairingID, "1", replacementPairingID, s.owner.identity.identityID, base64url(s.owner.identity.publicKey), newApprover.identity.identityID, base64url(newApprover.identity.publicKey), "2", String(now * 1000)];
    const proposal = {
      replacementID,
      previousPairingID: s.pairingID,
      previousEpoch: 1,
      replacementPairingID,
      replacement: encodeDeviceIdentityWire(newApprover.identity),
      owner: encodeDeviceIdentityWire(s.owner.identity),
      replacementEpoch: 2,
      issuedAt: swiftDate(now),
      signature: signPayloadFields(newApprover, `${COMPANION_VERSION}.pairing-replacement`, fields).toString("base64")
    };
    await submitOperation(toRequest(buildOperation({ kind: "replace_pairing", payload: proposal, signer: s.owner, expectedRevision: revision++ })), now);

    // The old epoch's consent must not authorize anything for the new
    // pairing: a request bound to the replacement pairing with the *old*
    // consent generation must be rejected (consent was not copied forward).
    const requestID = uniqueID("request");
    const carryoverRequest = {
      ...requestPayload(s, requestID, now, now + 40_000),
      pairingID: replacementPairingID,
      pairEpoch: 2,
      consentGeneration: 2, // the old pairing's consent generation
      targetedApproverIDs: [newApprover.identity.identityID],
      targetBindings: [{ approverIdentityID: newApprover.identity.identityID, pairingID: replacementPairingID, pairEpoch: 2, consentGeneration: 2 }],
      decisions: { [newApprover.identity.identityID]: "pending" }
    };
    const op = buildOperation({ kind: "request", payload: carryoverRequest, signer: s.owner, expectedRevision: revision });
    await expectRejected(op, "consent_required", now);

    // And the *old* pairing is fully revoked -- a consent mutation against it now fails.
    const oldConsentMutation = {
      relationshipID: s.pairingID,
      pairingID: s.pairingID,
      pairEpoch: 1,
      owner: encodeDeviceIdentityWire(s.owner.identity),
      approver: encodeDeviceIdentityWire(s.approver.identity),
      action: "ownerGrant",
      scopes: { scopes: ["approveEarlyEnd"] },
      nonce: Buffer.alloc(20, 88).toString("base64"),
      issuedAt: swiftDate(now)
    };
    const oldOp = buildOperation({ kind: "consent", payload: oldConsentMutation, signer: s.owner, expectedRevision: revision });
    await expectRejected(oldOp, "wrong_target", now);
  });

  it("same operationID + same expectedRevision are isolated per owner (no cross-owner idempotency collision)", async () => {
    const now = BASE_NOW + 20_000;
    const ownerA = makeIdentity("owner");
    const ownerB = makeIdentity("owner");
    const sharedOperationID = uniqueID("shared-op");
    const opA = buildOperation({ kind: "ack", payload: {}, signer: ownerA, expectedRevision: 0, operationID: sharedOperationID });
    const opB = buildOperation({ kind: "ack", payload: {}, signer: ownerB, expectedRevision: 0, operationID: sharedOperationID });
    const responseA = await submitOperation(toRequest(opA), now);
    const responseB = await submitOperation(toRequest(opB), now);
    expect(responseA.ownerIdentityID).toBe(ownerA.identity.identityID);
    expect(responseB.ownerIdentityID).toBe(ownerB.identity.identityID);
    expect(responseA.revision).toBe(1);
    expect(responseB.revision).toBe(1);
  });

  it("hostile cross-owner submission: an owner cannot mutate a different owner's ledger by naming them in the payload", async () => {
    const now = BASE_NOW + 21_000;
    const victim = makeIdentity("owner");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: victim, expectedRevision: 0 })), now);
    const attacker = makeIdentity("owner");
    // The operation is signed by the attacker but the reducer's "session"
    // case requires `session.owner === owner` where `owner` is resolved from
    // the *signer* -- an attacker cannot mutate the victim's ledger this way.
    const hostileSession = { owner: encodeDeviceIdentityWire(victim.identity), sessionID: uniqueID("s"), activeSetID: uniqueID("a"), startsAt: swiftDate(now - 10), endsAt: swiftDate(now + 1000) };
    const op = buildOperation({ kind: "session", payload: hostileSession, signer: attacker, expectedRevision: 0 });
    await expectRejected(op, "invalid_transition", now);
    // And the victim's own ledger was untouched.
    const ackReplay = await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: victim, expectedRevision: 1, operationID: uniqueID("ack-followup") })), now);
    expect(ackReplay.revision).toBe(2);
  });

  it("expiry reads and failed commands do not advance the revision", async () => {
    const now = BASE_NOW + 22_000;
    const s = await setupPairedSession(now);
    const before = await testPool().query<{ revision: string }>(`SELECT revision FROM companion_owner WHERE owner_id = $1`, [s.owner.identity.identityID]);
    // A read (inbox fetch) never touches revision.
    const inboxOp = buildOperation({ kind: "inbox", payload: { identityID: s.owner.identity.identityID, issuedAt: swiftDate(now) }, signer: s.owner, expectedRevision: null });
    await fetchInboxOperation(toRequest(inboxOp), now);
    // A failed command (wrong scope) is rejected before any state mutation commits.
    const badOp = buildOperation({ kind: "consent", payload: { relationshipID: s.pairingID, pairingID: s.pairingID, pairEpoch: 1, owner: encodeDeviceIdentityWire(s.owner.identity), approver: encodeDeviceIdentityWire(s.approver.identity), action: "ownerGrant", scopes: { scopes: ["mutualPact"] }, nonce: Buffer.alloc(20, 5).toString("base64"), issuedAt: swiftDate(now) }, signer: s.owner, expectedRevision: s.nextRevision });
    await expect(submitOperation(toRequest(badOp), now)).rejects.toBeTruthy();
    const after = await testPool().query<{ revision: string }>(`SELECT revision FROM companion_owner WHERE owner_id = $1`, [s.owner.identity.identityID]);
    expect(after.rows[0]!.revision).toBe(before.rows[0]!.revision);
  });

  it("revision overflow fails closed instead of wrapping", async () => {
    const now = BASE_NOW + 23_000;
    const owner = makeIdentity("owner");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })), now);
    await testPool().query(`UPDATE companion_owner SET revision = $1 WHERE owner_id = $2`, [Number.MAX_SAFE_INTEGER, owner.identity.identityID]);
    const row = await testPool().query<{ state: string }>(`SELECT state FROM companion_owner WHERE owner_id = $1`, [owner.identity.identityID]);
    const ledger = deserializeLedger(row.rows[0]!.state);
    const newRoot = computeStateRoot(ledger, Number.MAX_SAFE_INTEGER);
    await testPool().query(`UPDATE companion_owner SET state = $1, state_root = $2 WHERE owner_id = $3`, [serializeLedger(ledger), newRoot, owner.identity.identityID]);

    const op = buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: Number.MAX_SAFE_INTEGER, operationID: uniqueID("ack-overflow") });
    await expectRejected(op, "revision_overflow", now);
  });

  it("consent generation overflow fails closed", async () => {
    const now = BASE_NOW + 24_000;
    const s = await setupPairedSession(now);
    const row = await testPool().query<{ state: string }>(`SELECT state, revision FROM companion_owner WHERE owner_id = $1`, [s.owner.identity.identityID]);
    const ledger = deserializeLedger(row.rows[0]!.state);
    ledger.relationshipConsents[s.pairingID]!.generation = Number.MAX_SAFE_INTEGER;
    const revisionRow = await testPool().query<{ revision: string }>(`SELECT revision FROM companion_owner WHERE owner_id = $1`, [s.owner.identity.identityID]);
    const revision = Number(revisionRow.rows[0]!.revision);
    const newRoot = computeStateRoot(ledger, revision);
    await testPool().query(`UPDATE companion_owner SET state = $1, state_root = $2 WHERE owner_id = $3`, [serializeLedger(ledger), newRoot, s.owner.identity.identityID]);

    const revokePayload = {
      relationshipID: s.pairingID,
      pairingID: s.pairingID,
      pairEpoch: 1,
      owner: encodeDeviceIdentityWire(s.owner.identity),
      approver: encodeDeviceIdentityWire(s.approver.identity),
      action: "ownerRevoke",
      scopes: { scopes: ["approveEarlyEnd"] },
      nonce: Buffer.alloc(20, 91).toString("base64"),
      issuedAt: swiftDate(now)
    };
    const op = buildOperation({ kind: "consent", payload: revokePayload, signer: s.owner, expectedRevision: revision });
    await expectRejected(op, "revision_overflow", now);
  });

  it("one approver's decline does not invalidate another target's pending decision", async () => {
    const now = BASE_NOW + 25_000;
    const s = await setupPairedSession(now);
    let revision = s.nextRevision;
    const approverB = makeIdentity("trustedApprover");
    // Pair approverB too.
    const pairedB = await pairV3({ owner: s.owner, approver: approverB, now, clock: now, startRevision: revision, nonceByte: 66, legacyRevisionPad: 0 });
    const pairingBID = pairedB.pairingID;
    revision = pairedB.nextRevision;

    const requestID = uniqueID("request");
    const twoTargetRequest = {
      ...requestPayload(s, requestID, now, now + 40_000),
      targetedApproverIDs: [s.approver.identity.identityID, approverB.identity.identityID],
      targetBindings: [
        { approverIdentityID: s.approver.identity.identityID, pairingID: s.pairingID, pairEpoch: 1, consentGeneration: 2 },
        { approverIdentityID: approverB.identity.identityID, pairingID: pairingBID, pairEpoch: 1, consentGeneration: 2 }
      ],
      decisions: { [s.approver.identity.identityID]: "pending", [approverB.identity.identityID]: "pending" }
    };
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: twoTargetRequest, signer: s.owner, expectedRevision: revision++ })), now);

    // approver A declines.
    const declineFields = ["decline-a", requestID, s.pairingID, "1", "2", s.sessionID, s.activeSetID, s.approver.identity.identityID, base64url(s.approver.identity.publicKey), "declined", String(now * 1000), base64url(Buffer.alloc(20, 200))];
    const declineApproval = {
      approvalID: "decline-a",
      nonce: Buffer.alloc(20, 200).toString("base64"),
      requestID,
      pairingID: s.pairingID,
      pairEpoch: 1,
      consentGeneration: 2,
      sessionID: s.sessionID,
      activeSetID: s.activeSetID,
      approver: encodeDeviceIdentityWire(s.approver.identity),
      decision: "declined",
      issuedAt: swiftDate(now),
      signature: signPayloadFields(s.approver, `${COMPANION_VERSION}.approval`, declineFields).toString("base64")
    };
    const declineResponse = await submitOperation(toRequest(buildOperation({ kind: "approval", payload: declineApproval, signer: s.approver, expectedRevision: revision++ })), now);
    expect((declineResponse.result as any).value.decision).toBe("declined");

    // approver B can still approve -- their decision was not invalidated by A's decline.
    const approveFields = ["approve-b", requestID, pairingBID, "1", "2", s.sessionID, s.activeSetID, approverB.identity.identityID, base64url(approverB.identity.publicKey), "approved", String(now * 1000), base64url(Buffer.alloc(20, 201))];
    const approveApproval = {
      approvalID: "approve-b",
      nonce: Buffer.alloc(20, 201).toString("base64"),
      requestID,
      pairingID: pairingBID,
      pairEpoch: 1,
      consentGeneration: 2,
      sessionID: s.sessionID,
      activeSetID: s.activeSetID,
      approver: encodeDeviceIdentityWire(approverB.identity),
      decision: "approved",
      issuedAt: swiftDate(now),
      signature: signPayloadFields(approverB, `${COMPANION_VERSION}.approval`, approveFields).toString("base64")
    };
    const approveResponse = await submitOperation(toRequest(buildOperation({ kind: "approval", payload: approveApproval, signer: approverB, expectedRevision: revision })), now);
    expect((approveResponse.result as any).value.decision).toBe("approved");
  });
});

// ---------------------------------------------------------------------------
// P2 -- prototype pollution safety of ID-keyed ledger maps
// ---------------------------------------------------------------------------

describe("P2: __proto__/constructor/toString as free-form IDs cannot pollute the ledger's prototype", () => {
  it("a requestID of \"__proto__\" is stored as an ordinary key, never repoints the ledger map's prototype", async () => {
    const now = BASE_NOW + 26_000;
    const s = await setupPairedSession(now);
    const dangerousRequestID = "__proto__";
    const op = buildOperation({ kind: "request", payload: requestPayload(s, dangerousRequestID, now, now + 40_000), signer: s.owner, expectedRevision: s.nextRevision });
    const response = await submitOperation(toRequest(op), now);
    expect(response.result.kind).toBe("request");

    const row = await testPool().query<{ state: string }>(`SELECT state FROM companion_owner WHERE owner_id = $1`, [s.owner.identity.identityID]);
    const ledger = deserializeLedger(row.rows[0]!.state);
    // Stored as a normal own property, retrievable like any other key...
    expect(Object.prototype.hasOwnProperty.call(ledger.requests, dangerousRequestID)).toBe(true);
    expect(ledger.requests[dangerousRequestID]?.request.requestID).toBe(dangerousRequestID);
    // ...and critically, `Object.prototype` itself (and every other plain
    // object in the process) was never touched.
    expect(Object.getPrototypeOf({})).toBe(Object.prototype);
    expect(({} as Record<string, unknown>).polluted).toBeUndefined();
    // The map itself has no prototype at all.
    expect(Object.getPrototypeOf(ledger.requests)).toBeNull();
  });

  it("decisions keyed by \"constructor\"/\"toString\" round-trip as ordinary values, not inherited functions", async () => {
    const now = BASE_NOW + 27_000;
    const s = await setupPairedSession(now);
    // Exercise the decode layer directly with a target/decision key of
    // "constructor" and confirm `decodeTrustedRequest` stores it as a real
    // own property, not Object.prototype's constructor function.
    const { decodeTrustedRequest } = await import("../src/protocol.js");
    const payload = {
      ...requestPayload(s, uniqueID("request"), now, now + 40_000),
      targetedApproverIDs: ["constructor"],
      targetBindings: [{ approverIdentityID: "constructor", pairingID: s.pairingID, pairEpoch: 1, consentGeneration: 2 }],
      decisions: { constructor: "pending" }
    };
    const decoded = decodeTrustedRequest(payload);
    expect(decoded.decisions.constructor).toBe("pending");
    expect(typeof decoded.decisions.constructor).toBe("string");
    expect(Object.getPrototypeOf(decoded.decisions)).toBeNull();
  });
});
