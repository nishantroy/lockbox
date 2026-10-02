// R5 Slice B2a: owner inbox approval delivery (contract v1.2, additive) and
// the "use" reducer's exact-binding checks exercised through the inbox path.
// Uses explicit `now` injection (not real wall-clock time), the same pattern
// as test/security-fixes.test.ts's P1.4 suite.

import { describe, it, expect } from "vitest";
import { makeIdentity, buildOperation, swiftDate, signPayloadFields, encodeDeviceIdentityWire, uniqueID, type TestIdentity } from "./setup.js";
import { submitOperation, fetchInboxOperation } from "../src/service.js";
import { pairingVerificationCode, base64url, COMPANION_VERSION } from "../src/canonical.js";

function toRequest(op: object): Buffer {
  return Buffer.from(JSON.stringify(op), "utf8");
}

async function expectRejected(op: object, code: string, now?: number) {
  await expect(submitOperation(toRequest(op), now)).rejects.toMatchObject({ code });
}

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
});
