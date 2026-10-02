// R5 Slice B2a: owner inbox approval delivery (contract v1.2, additive) and
// the "use" reducer's exact-binding checks exercised through the inbox path.
// Uses explicit `now` injection (not real wall-clock time), the same pattern
// as test/security-fixes.test.ts's P1.4 suite.

import { describe, it, expect } from "vitest";
import { makeIdentity, buildOperation, swiftDate, signPayloadFields, encodeDeviceIdentityWire, uniqueID, testPool, type TestIdentity } from "./setup.js";
import { submitOperation, fetchInboxOperation, computeStateRoot } from "../src/service.js";
import { pairingVerificationCode, base64url, COMPANION_VERSION } from "../src/canonical.js";
import { purgeExpiredRecords } from "../src/retention.js";
import { deserializeLedger, serializeLedger } from "../src/ledger.js";

function toRequest(op: object): Buffer {
  return Buffer.from(JSON.stringify(op), "utf8");
}

async function expectRejected(op: object, code: string, now?: number) {
  await expect(submitOperation(toRequest(op), now)).rejects.toMatchObject({ code });
}

/** Same helper pattern as test/retention.test.ts: read/patch the stored ledger directly, for scenarios the normal protocol flow can't reach quickly (an old terminal timestamp, past the retention window). */
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

const BASE_NOW = 1_750_000_000; // fixed, deterministic, distinct from other suites' bases

interface Scenario {
  owner: TestIdentity;
  approver: TestIdentity;
  pairingID: string;
  sessionID: string;
  activeSetID: string;
  nextRevision: number;
}

async function setupPairedSession(now: number, overrides: Partial<{ scopes: string[] }> = {}): Promise<Scenario> {
  const owner = makeIdentity("owner");
  const approver = makeIdentity("trustedApprover");
  let revision = 0;

  const inviteID = uniqueID("invite");
  const nonce = Buffer.alloc(24, 7);
  const invitePayload = { inviteID, owner: encodeDeviceIdentityWire(owner.identity), issuedAt: swiftDate(now), expiresAt: swiftDate(now + 3600), nonce: nonce.toString("base64") };
  const inviteFields = [inviteID, owner.identity.identityID, base64url(owner.identity.publicKey), String(now * 1000), String((now + 3600) * 1000), base64url(nonce)];
  const invitation = { payload: invitePayload, signature: signPayloadFields(owner, `${COMPANION_VERSION}.invite`, inviteFields).toString("base64") };
  await submitOperation(toRequest(buildOperation({ kind: "invite", payload: invitation, signer: owner, expectedRevision: revision++ })), now);

  const acceptanceID = uniqueID("acceptance");
  const verificationCode = pairingVerificationCode({ inviteID, ownerIdentityID: owner.identity.identityID, approverIdentityID: approver.identity.identityID, nonce });
  const acceptancePayload = { acceptanceID, inviteID, owner: encodeDeviceIdentityWire(owner.identity), approver: encodeDeviceIdentityWire(approver.identity), issuedAt: swiftDate(now + 1), verificationCode };
  const acceptanceFields = [acceptanceID, inviteID, owner.identity.identityID, approver.identity.identityID, base64url(owner.identity.publicKey), base64url(approver.identity.publicKey), String((now + 1) * 1000), verificationCode];
  const signedAcceptance = { acceptance: acceptancePayload, signature: signPayloadFields(approver, `${COMPANION_VERSION}.acceptance`, acceptanceFields).toString("base64") };
  await submitOperation(toRequest(buildOperation({ kind: "accept", payload: signedAcceptance, signer: approver, expectedRevision: revision++ })), now);

  const confirmationPayload = { acceptanceID, inviteID, owner: encodeDeviceIdentityWire(owner.identity), approverIdentityID: approver.identity.identityID, verificationCode, issuedAt: swiftDate(now + 2) };
  const confirmationFields = [acceptanceID, inviteID, owner.identity.identityID, approver.identity.identityID, verificationCode, String((now + 2) * 1000)];
  const signedConfirmation = { confirmation: confirmationPayload, signature: signPayloadFields(owner, `${COMPANION_VERSION}.confirmation`, confirmationFields).toString("base64") };
  const confirmResponse = await submitOperation(toRequest(buildOperation({ kind: "confirm", payload: signedConfirmation, signer: owner, expectedRevision: revision++ })), now);
  const pairingID = (confirmResponse.result as any).value.pairingID as string;

  const scopes = overrides.scopes ?? ["approveEarlyEnd", "receiveRequests"];
  const grantPayload = { relationshipID: pairingID, pairingID, pairEpoch: 1, owner: encodeDeviceIdentityWire(owner.identity), approver: encodeDeviceIdentityWire(approver.identity), action: "ownerGrant", scopes: { scopes }, nonce: Buffer.alloc(20, 9).toString("base64"), issuedAt: swiftDate(now + 3) };
  await submitOperation(toRequest(buildOperation({ kind: "consent", payload: grantPayload, signer: owner, expectedRevision: revision++ })), now);

  const acceptPayload = { relationshipID: pairingID, pairingID, pairEpoch: 1, owner: encodeDeviceIdentityWire(owner.identity), approver: encodeDeviceIdentityWire(approver.identity), action: "approverAccept", scopes: { scopes }, nonce: Buffer.alloc(20, 11).toString("base64"), issuedAt: swiftDate(now + 4) };
  await submitOperation(toRequest(buildOperation({ kind: "consent", payload: acceptPayload, signer: approver, expectedRevision: revision++ })), now);

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

function inboxOp(identity: TestIdentity, now: number) {
  return buildOperation({ kind: "inbox", payload: { identityID: identity.identity.identityID, issuedAt: swiftDate(now) }, signer: identity, expectedRevision: null });
}

describe("R5 Slice B2a: owner inbox approval delivery", () => {
  it("the owner's inbox omits approvals for a pending (not-yet-approved) request, then includes it once approved; a helper inbox never includes approvals", async () => {
    const now = BASE_NOW + 1_000;
    const s = await setupPairedSession(now);
    const requestID = uniqueID("request");
    let revision = s.nextRevision;
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(s, requestID, now, now + 40_000), signer: s.owner, expectedRevision: revision++ })), now);

    const beforeApproval = await fetchInboxOperation(toRequest(inboxOp(s.owner, now)), now);
    expect(beforeApproval.ownerIdentityID).toBe(s.owner.identity.identityID);
    expect(beforeApproval.approvals).toEqual([]);

    const approvalID = uniqueID("approval");
    const approval = approvalPayload(s, requestID, approvalID, "approved", 21, now);
    await submitOperation(toRequest(buildOperation({ kind: "approval", payload: approval, signer: s.approver, expectedRevision: revision++ })), now);

    const ownerInbox = await fetchInboxOperation(toRequest(inboxOp(s.owner, now)), now);
    expect(ownerInbox.approvals).toHaveLength(1);
    expect(ownerInbox.approvals?.[0]?.approvalID).toBe(approvalID);
    expect(ownerInbox.approvals?.[0]?.requestID).toBe(requestID);
    expect(ownerInbox.approvals?.[0]?.decision).toBe("approved");

    const helperInbox = await fetchInboxOperation(toRequest(inboxOp(s.approver, now)), now);
    expect(helperInbox.ownerIdentityID).toBeUndefined();
    expect(helperInbox.approvals).toBeUndefined();
    expect(helperInbox.requests.map((r) => r.requestID)).toContain(requestID);
  });

  it("the approval stays visible in the owner's inbox after use, and again after natural end flips the used request's status away from approved", async () => {
    const now = BASE_NOW + 2_000;
    const s = await setupPairedSession(now);
    const requestID = uniqueID("request");
    let revision = s.nextRevision;
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(s, requestID, now, now + 40_000), signer: s.owner, expectedRevision: revision++ })), now);
    const approvalID = uniqueID("approval");
    const approval = approvalPayload(s, requestID, approvalID, "approved", 22, now);
    await submitOperation(toRequest(buildOperation({ kind: "approval", payload: approval, signer: s.approver, expectedRevision: revision++ })), now);

    const useID = uniqueID("use");
    await submitOperation(toRequest(buildOperation({ kind: "use", payload: { approval, requestID, useID, consentGeneration: 2 }, signer: s.owner, expectedRevision: revision++ })), now);

    const afterUse = await fetchInboxOperation(toRequest(inboxOp(s.owner, now)), now);
    expect(afterUse.approvals?.map((a) => a.approvalID)).toEqual([approvalID]);
    expect(afterUse.requests.find((r) => r.requestID === requestID)?.status).toBe("approved");

    // Natural end flips the now-used request's status away from "approved"
    // (expireRequest does not treat "used" as terminal), but the approval
    // must remain deliverable -- the inbox's "has a recorded use" fallback.
    const afterEnd = now + 100_001;
    await submitOperation(toRequest(buildOperation({ kind: "natural_end", payload: { sessionID: s.sessionID, activeSetID: s.activeSetID }, signer: s.owner, expectedRevision: revision++ })), afterEnd);

    const afterNaturalEnd = await fetchInboxOperation(toRequest(inboxOp(s.owner, afterEnd)), afterEnd);
    const expiredRequest = afterNaturalEnd.requests.find((r) => r.requestID === requestID);
    expect(expiredRequest?.status).not.toBe("approved");
    expect(afterNaturalEnd.approvals?.map((a) => a.approvalID)).toEqual([approvalID]);
  });

  it("cross-owner isolation: owner A's inbox never carries owner B's approvals, even for the same approver identity", async () => {
    const now = BASE_NOW + 3_000;
    const sA = await setupPairedSession(now);
    const approver = makeIdentity("trustedApprover");
    // A second, independent owner paired with a *different* approver identity.
    const sB = await setupPairedSession(now);
    void approver;

    const requestIDA = uniqueID("request");
    let revisionA = sA.nextRevision;
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(sA, requestIDA, now, now + 40_000), signer: sA.owner, expectedRevision: revisionA++ })), now);
    const approvalA = approvalPayload(sA, requestIDA, uniqueID("approval"), "approved", 23, now);
    await submitOperation(toRequest(buildOperation({ kind: "approval", payload: approvalA, signer: sA.approver, expectedRevision: revisionA++ })), now);

    const requestIDB = uniqueID("request");
    let revisionB = sB.nextRevision;
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(sB, requestIDB, now, now + 40_000), signer: sB.owner, expectedRevision: revisionB++ })), now);
    const approvalB = approvalPayload(sB, requestIDB, uniqueID("approval"), "approved", 24, now);
    await submitOperation(toRequest(buildOperation({ kind: "approval", payload: approvalB, signer: sB.approver, expectedRevision: revisionB++ })), now);

    const ownerAInbox = await fetchInboxOperation(toRequest(inboxOp(sA.owner, now)), now);
    expect(ownerAInbox.approvals?.map((a) => a.approvalID)).toEqual([approvalA.approvalID]);
    expect(ownerAInbox.requests.map((r) => r.requestID)).not.toContain(requestIDB);

    const ownerBInbox = await fetchInboxOperation(toRequest(inboxOp(sB.owner, now)), now);
    expect(ownerBInbox.approvals?.map((a) => a.approvalID)).toEqual([approvalB.approvalID]);
    expect(ownerBInbox.requests.map((r) => r.requestID)).not.toContain(requestIDA);
  });

  it("use with a mismatched activeSetID is rejected (replay) and never consumes the approval", async () => {
    const now = BASE_NOW + 4_000;
    const s = await setupPairedSession(now);
    const requestID = uniqueID("request");
    let revision = s.nextRevision;
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(s, requestID, now, now + 40_000), signer: s.owner, expectedRevision: revision++ })), now);
    const approvalID = uniqueID("approval");
    const approval = approvalPayload(s, requestID, approvalID, "approved", 25, now);
    await submitOperation(toRequest(buildOperation({ kind: "approval", payload: approval, signer: s.approver, expectedRevision: revision++ })), now);

    // Tamper the client-held approval's activeSetID before submitting "use" --
    // the stored accepted approval (keyed by approvalID) no longer matches,
    // so `approvalsEqual` fails and the reducer rejects the whole command.
    const tamperedApproval = { ...approval, activeSetID: "wrong-active-set" };
    const useOp = buildOperation({ kind: "use", payload: { approval: tamperedApproval, requestID, useID: uniqueID("use"), consentGeneration: 2 }, signer: s.owner, expectedRevision: revision });
    await expectRejected(useOp, "replay", now);

    // The real approval can still be used afterwards -- the rejected attempt
    // did not consume it.
    const realUseOp = buildOperation({ kind: "use", payload: { approval, requestID, useID: uniqueID("use-real"), consentGeneration: 2 }, signer: s.owner, expectedRevision: revision });
    const response = await submitOperation(toRequest(realUseOp), now);
    expect(response.result.kind).toBe("verification");
  });

  // ---------------------------------------------------------------------
  // Review round (P1-1, P1-2): idempotent-replay anchor fix and coverage.
  // ---------------------------------------------------------------------

  it("a replayed use returns the SAME result but the ledger's CURRENT revision/stateRoot, not the historical commit-time pair", async () => {
    const now = BASE_NOW + 5_000;
    const s = await setupPairedSession(now);
    const requestID = uniqueID("request");
    let revision = s.nextRevision;
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(s, requestID, now, now + 40_000), signer: s.owner, expectedRevision: revision++ })), now);
    const approval = approvalPayload(s, requestID, uniqueID("approval"), "approved", 26, now);
    await submitOperation(toRequest(buildOperation({ kind: "approval", payload: approval, signer: s.approver, expectedRevision: revision++ })), now);

    const useOp = buildOperation({ kind: "use", payload: { approval, requestID, useID: uniqueID("use"), consentGeneration: 2 }, signer: s.owner, expectedRevision: revision });
    const first = await submitOperation(toRequest(useOp), now);
    expect(first.result.kind).toBe("verification");

    // An unrelated mutation advances the owner's revision after "use"
    // committed but before the replay arrives (R5 Slice B2a review fix,
    // P1-1: before the fix, the replay below would return the stale
    // (revision, stateRoot) pair from this "use" operation's original
    // commit, which a client's RollbackAnchor -- having already accepted
    // this later ack's higher revision -- would reject as a regression).
    const ackOp = buildOperation({ kind: "ack", payload: {}, signer: s.owner, expectedRevision: first.revision });
    const ackResponse = await submitOperation(toRequest(ackOp), now);
    expect(ackResponse.revision).toBeGreaterThan(first.revision);

    const replay = await submitOperation(toRequest(useOp), now);
    expect(replay.result).toEqual(first.result);
    expect(replay.revision).toBe(ackResponse.revision);
    expect(replay.revision).toBeGreaterThan(first.revision);
    expect(replay.stateRoot.equals(ackResponse.stateRoot)).toBe(true);

    // A genuinely different useID on the now-consumed approval is still a
    // hard rejection, not a replay.
    const differentUseID = buildOperation({ kind: "use", payload: { approval, requestID, useID: uniqueID("use-different"), consentGeneration: 2 }, signer: s.owner, expectedRevision: ackResponse.revision });
    await expectRejected(differentUseID, "replay", now);
  });

  it("the inbox projection never changes the owner's stored revision or state root", async () => {
    const now = BASE_NOW + 6_000;
    const s = await setupPairedSession(now);
    const requestID = uniqueID("request");
    let revision = s.nextRevision;
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(s, requestID, now, now + 40_000), signer: s.owner, expectedRevision: revision++ })), now);

    const before = await fetchInboxOperation(toRequest(inboxOp(s.owner, now)), now);
    const after = await fetchInboxOperation(toRequest(inboxOp(s.owner, now)), now);
    expect(after.revision).toBe(before.revision);
    expect(before.stateRoot).toBeInstanceOf(Buffer);
    expect(after.stateRoot).toBeInstanceOf(Buffer);
    expect(after.stateRoot!.equals(before.stateRoot!)).toBe(true);

    const { revision: storedRevision } = await readLedgerText(s.owner.identity.identityID);
    expect(storedRevision).toBe(before.revision);
  });

  it("a purged terminal request's approval is no longer delivered in the owner's inbox", async () => {
    const now = BASE_NOW + 7_000;
    const s = await setupPairedSession(now);
    const requestID = uniqueID("request");
    let revision = s.nextRevision;
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(s, requestID, now, now + 40_000), signer: s.owner, expectedRevision: revision++ })), now);
    const approvalID = uniqueID("approval");
    const approval = approvalPayload(s, requestID, approvalID, "approved", 27, now);
    await submitOperation(toRequest(buildOperation({ kind: "approval", payload: approval, signer: s.approver, expectedRevision: revision++ })), now);
    // Use it (so the approval stays deliverable via the "has a recorded
    // use" rule even once natural end below flips the request's status
    // away from "approved"), then naturally end the session so the request
    // becomes terminal (expiredAt is set) and purge-eligible.
    await submitOperation(toRequest(buildOperation({ kind: "use", payload: { approval, requestID, useID: uniqueID("use"), consentGeneration: 2 }, signer: s.owner, expectedRevision: revision++ })), now);
    const afterEnd = now + 100_001;
    await submitOperation(toRequest(buildOperation({ kind: "natural_end", payload: { sessionID: s.sessionID, activeSetID: s.activeSetID }, signer: s.owner, expectedRevision: revision++ })), afterEnd);

    const beforePurge = await fetchInboxOperation(toRequest(inboxOp(s.owner, afterEnd)), afterEnd);
    expect(beforePurge.requests.find((r) => r.requestID === requestID)?.status).not.toBe("approved");
    expect(beforePurge.approvals?.map((a) => a.approvalID)).toContain(approvalID);

    // Push the request's terminal (expiredAt) timestamp back past the
    // 30-day retention window, directly in storage, exactly as
    // test/retention.test.ts does.
    await patchLedger(s.owner.identity.identityID, (ledger) => {
      const record = ledger.requests[requestID]!;
      ledger.requests[requestID] = { ...record, expiredAt: afterEnd - 31 * DAY };
    });

    const summary = await purgeExpiredRecords(testPool(), 30, afterEnd);
    expect(summary.purgedRequests).toBeGreaterThanOrEqual(1);
    expect(summary.purgedApprovals).toBeGreaterThanOrEqual(1);

    const afterPurge = await fetchInboxOperation(toRequest(inboxOp(s.owner, afterEnd)), afterEnd);
    expect(afterPurge.requests.map((r) => r.requestID)).not.toContain(requestID);
    expect(afterPurge.approvals?.map((a) => a.approvalID)).not.toContain(approvalID);
  });

  it("use is rejected once a newer session supersedes the one the approval was bound to", async () => {
    const now = BASE_NOW + 8_000;
    const s = await setupPairedSession(now);
    const requestID = uniqueID("request");
    let revision = s.nextRevision;
    await submitOperation(toRequest(buildOperation({ kind: "request", payload: requestPayload(s, requestID, now, now + 40_000), signer: s.owner, expectedRevision: revision++ })), now);
    const approval = approvalPayload(s, requestID, uniqueID("approval"), "approved", 28, now);
    await submitOperation(toRequest(buildOperation({ kind: "approval", payload: approval, signer: s.approver, expectedRevision: revision++ })), now);

    // Publish a new session -- becomes `currentSessionID` and immediately
    // expires every outstanding request still bound to the old session.
    const newSessionPayload = {
      owner: encodeDeviceIdentityWire(s.owner.identity),
      sessionID: uniqueID("session"),
      activeSetID: uniqueID("activeset"),
      startsAt: swiftDate(now),
      endsAt: swiftDate(now + 100_000)
    };
    await submitOperation(toRequest(buildOperation({ kind: "session", payload: newSessionPayload, signer: s.owner, expectedRevision: revision++ })), now);

    const useOp = buildOperation({ kind: "use", payload: { approval, requestID, useID: uniqueID("use"), consentGeneration: 2 }, signer: s.owner, expectedRevision: revision });
    await expectRejected(useOp, "replay", now);
  });
});
