// R5 pairing v2 (docs/r5-pairing-v2-plan.md's "Slice P2a"): the owner inbox's
// `pendingAcceptances` field delivers a verifiable `SignedAcceptance` for
// each outstanding "accept", so the owner device can confirm a friend's
// pairing with no typed six-digit code. Covers owner-only exposure,
// cross-owner isolation, clearing after confirm/expiry/retention, and
// graceful handling of a ledger row written before this change (no retained
// signature).

import { describe, it, expect } from "vitest";
import { makeIdentity, buildOperation, swiftDate, signPayloadFields, encodeDeviceIdentityWire, uniqueID, testPool, type TestIdentity } from "./setup.js";
import { submitOperation, fetchInboxOperation, computeStateRoot } from "../src/service.js";
import { pairingVerificationCode, base64url, COMPANION_VERSION } from "../src/canonical.js";
import { purgeExpiredRecords } from "../src/retention.js";
import { deserializeLedger, serializeLedger, type Ledger } from "../src/ledger.js";
import { verifySignedAcceptanceSignature, decodePairingAcceptance } from "../src/protocol.js";

function toRequest(op: object): Buffer {
  return Buffer.from(JSON.stringify(op), "utf8");
}

/** Same helper pattern as test/owner-approval-delivery.test.ts and test/retention.test.ts. */
async function readLedgerText(ownerID: string): Promise<{ text: string; revision: number }> {
  const result = await testPool().query<{ state: string; revision: string }>(`SELECT state, revision FROM companion_owner WHERE owner_id = $1`, [ownerID]);
  const row = result.rows[0];
  if (!row) throw new Error("owner not found");
  return { text: row.state, revision: Number(row.revision) };
}

async function patchLedger(ownerID: string, mutate: (ledger: Ledger) => void): Promise<void> {
  const { text, revision } = await readLedgerText(ownerID);
  const ledger = deserializeLedger(text);
  mutate(ledger);
  const newRoot = computeStateRoot(ledger, revision);
  await testPool().query(`UPDATE companion_owner SET state = $1, state_root = $2 WHERE owner_id = $3`, [serializeLedger(ledger), newRoot, ownerID]);
}

const BASE_NOW = 1_780_000_000; // fixed, deterministic, distinct from other suites' bases

interface InviteFlow {
  owner: TestIdentity;
  approver: TestIdentity;
  inviteID: string;
  acceptanceID: string;
  verificationCode: string;
  expiresAt: number;
  nextRevision: number;
}

async function createInviteAndAccept(now: number, validFor = 3_600): Promise<InviteFlow> {
  const owner = makeIdentity("owner");
  const approver = makeIdentity("trustedApprover");
  let revision = 0;

  const inviteID = uniqueID("invite");
  const nonce = Buffer.alloc(24, 7);
  const expiresAt = now + validFor;
  const invitePayload = { inviteID, owner: encodeDeviceIdentityWire(owner.identity), issuedAt: swiftDate(now), expiresAt: swiftDate(expiresAt), nonce: nonce.toString("base64") };
  const inviteFields = [inviteID, owner.identity.identityID, base64url(owner.identity.publicKey), String(now * 1000), String(expiresAt * 1000), base64url(nonce)];
  const invitation = { payload: invitePayload, signature: signPayloadFields(owner, `${COMPANION_VERSION}.invite`, inviteFields).toString("base64") };
  await submitOperation(toRequest(buildOperation({ kind: "invite", payload: invitation, signer: owner, expectedRevision: revision++ })), now);

  const acceptanceID = uniqueID("acceptance");
  const verificationCode = pairingVerificationCode({ inviteID, ownerIdentityID: owner.identity.identityID, approverIdentityID: approver.identity.identityID, nonce });
  const acceptancePayload = { acceptanceID, inviteID, owner: encodeDeviceIdentityWire(owner.identity), approver: encodeDeviceIdentityWire(approver.identity), issuedAt: swiftDate(now + 1), verificationCode };
  const acceptanceFields = [acceptanceID, inviteID, owner.identity.identityID, approver.identity.identityID, base64url(owner.identity.publicKey), base64url(approver.identity.publicKey), String((now + 1) * 1000), verificationCode];
  const signedAcceptance = { acceptance: acceptancePayload, signature: signPayloadFields(approver, `${COMPANION_VERSION}.acceptance`, acceptanceFields).toString("base64") };
  await submitOperation(toRequest(buildOperation({ kind: "accept", payload: signedAcceptance, signer: approver, expectedRevision: revision++ })), now);

  return { owner, approver, inviteID, acceptanceID, verificationCode, expiresAt, nextRevision: revision };
}

function inboxOp(identity: TestIdentity, now: number) {
  return buildOperation({ kind: "inbox", payload: { identityID: identity.identity.identityID, issuedAt: swiftDate(now) }, signer: identity, expectedRevision: null });
}

async function confirm(flow: InviteFlow, now: number, revision: number): Promise<void> {
  const confirmationPayload = { acceptanceID: flow.acceptanceID, inviteID: flow.inviteID, owner: encodeDeviceIdentityWire(flow.owner.identity), approverIdentityID: flow.approver.identity.identityID, verificationCode: flow.verificationCode, issuedAt: swiftDate(now + 2) };
  const confirmationFields = [flow.acceptanceID, flow.inviteID, flow.owner.identity.identityID, flow.approver.identity.identityID, flow.verificationCode, String((now + 2) * 1000)];
  const signedConfirmation = { confirmation: confirmationPayload, signature: signPayloadFields(flow.owner, `${COMPANION_VERSION}.confirmation`, confirmationFields).toString("base64") };
  await submitOperation(toRequest(buildOperation({ kind: "confirm", payload: signedConfirmation, signer: flow.owner, expectedRevision: revision })), now);
}

describe("R5 pairing v2: owner inbox pending-acceptance delivery", () => {
  it("the owner's inbox delivers a verifiable pending acceptance right after accept; a helper inbox omits the field entirely", async () => {
    const now = BASE_NOW + 1_000;
    const flow = await createInviteAndAccept(now);

    const ownerInbox = await fetchInboxOperation(toRequest(inboxOp(flow.owner, now)), now);
    expect(ownerInbox.ownerIdentityID).toBe(flow.owner.identity.identityID);
    expect(ownerInbox.pendingAcceptances).toHaveLength(1);
    const entry = ownerInbox.pendingAcceptances![0]!;
    expect(entry.acceptance.acceptanceID).toBe(flow.acceptanceID);
    expect(entry.acceptance.inviteID).toBe(flow.inviteID);
    expect(entry.acceptance.verificationCode).toBe(flow.verificationCode);
    expect(verifySignedAcceptanceSignature(entry)).toBe(true);

    const helperInbox = await fetchInboxOperation(toRequest(inboxOp(flow.approver, now)), now);
    expect(helperInbox.ownerIdentityID).toBeUndefined();
    expect(helperInbox.pendingAcceptances).toBeUndefined();
  });

  it("confirming the acceptance clears it from the owner's inbox", async () => {
    const now = BASE_NOW + 2_000;
    const flow = await createInviteAndAccept(now);
    const beforeConfirm = await fetchInboxOperation(toRequest(inboxOp(flow.owner, now)), now);
    expect(beforeConfirm.pendingAcceptances).toHaveLength(1);

    await confirm(flow, now, flow.nextRevision);

    const afterConfirm = await fetchInboxOperation(toRequest(inboxOp(flow.owner, now)), now);
    expect(afterConfirm.pendingAcceptances).toEqual([]);
  });

  it("an expired invite's pending acceptance is no longer delivered, even though the ledger row still exists", async () => {
    const now = BASE_NOW + 3_000;
    const flow = await createInviteAndAccept(now, 60); // expires 60s after `now`
    const stillPending = await fetchInboxOperation(toRequest(inboxOp(flow.owner, now)), now);
    expect(stillPending.pendingAcceptances).toHaveLength(1);

    const afterExpiry = flow.expiresAt + 1;
    const afterExpiryInbox = await fetchInboxOperation(toRequest(inboxOp(flow.owner, afterExpiry)), afterExpiry);
    expect(afterExpiryInbox.pendingAcceptances).toEqual([]);
  });

  it("cross-owner isolation: owner A's inbox never carries owner B's pending acceptances, even for the same approver identity", async () => {
    const now = BASE_NOW + 4_000;
    const flowA = await createInviteAndAccept(now);
    const flowB = await createInviteAndAccept(now);

    const inboxA = await fetchInboxOperation(toRequest(inboxOp(flowA.owner, now)), now);
    expect(inboxA.pendingAcceptances).toHaveLength(1);
    expect(inboxA.pendingAcceptances![0]!.acceptance.acceptanceID).toBe(flowA.acceptanceID);

    const inboxB = await fetchInboxOperation(toRequest(inboxOp(flowB.owner, now)), now);
    expect(inboxB.pendingAcceptances).toHaveLength(1);
    expect(inboxB.pendingAcceptances![0]!.acceptance.acceptanceID).toBe(flowB.acceptanceID);
  });

  it("the inbox projection never changes the owner's stored revision or state root", async () => {
    const now = BASE_NOW + 5_000;
    const flow = await createInviteAndAccept(now);
    const before = await readLedgerText(flow.owner.identity.identityID);
    await fetchInboxOperation(toRequest(inboxOp(flow.owner, now)), now);
    await fetchInboxOperation(toRequest(inboxOp(flow.owner, now)), now);
    const after = await readLedgerText(flow.owner.identity.identityID);
    expect(after.revision).toBe(before.revision);
    expect(after.text).toBe(before.text);
  });

  it("a ledger row written before this change (no retained signature) is skipped by the inbox, but confirm still succeeds for it", async () => {
    const now = BASE_NOW + 6_000;
    const flow = await createInviteAndAccept(now);

    // Simulate a pre-existing production row: the old reducer stored the
    // bare, unsigned PairingAcceptance directly (no `{acceptance, signature}`
    // wrapper) under `pendingAcceptances[acceptanceID]`.
    await patchLedger(flow.owner.identity.identityID, (ledger) => {
      const current = ledger.pendingAcceptances[flow.acceptanceID];
      expect(current).toBeDefined();
      const bareAcceptance = decodePairingAcceptance({
        acceptanceID: flow.acceptanceID,
        inviteID: flow.inviteID,
        owner: encodeDeviceIdentityWire(flow.owner.identity),
        approver: encodeDeviceIdentityWire(flow.approver.identity),
        issuedAt: swiftDate(now + 1),
        verificationCode: flow.verificationCode
      });
      // @ts-expect-error -- deliberately writing the legacy flat shape to
      // simulate a row this version of the reducer never produces itself.
      ledger.pendingAcceptances[flow.acceptanceID] = bareAcceptance;
    });

    const inbox = await fetchInboxOperation(toRequest(inboxOp(flow.owner, now)), now);
    expect(inbox.pendingAcceptances).toEqual([]);

    // Confirm never needed the retained signature (only the owner's own
    // confirmation signature), so it is unaffected by the legacy shape.
    await confirm(flow, now, flow.nextRevision);
    const afterConfirm = await fetchInboxOperation(toRequest(inboxOp(flow.owner, now)), now);
    expect(afterConfirm.pendingAcceptances).toEqual([]);
  });

  it("retention purge removes a pending acceptance 30 days after its invite expires, and it is already absent from the inbox well before that", async () => {
    const now = BASE_NOW + 7_000;
    const flow = await createInviteAndAccept(now, 60);
    const ownerID = flow.owner.identity.identityID;

    const justBeforePurge = flow.expiresAt + 30 * 86_400 - 1;
    await purgeExpiredRecords(testPool(), 30, justBeforePurge);
    const beforePurge = await readLedgerText(ownerID);
    const ledgerBefore = deserializeLedger(beforePurge.text);
    expect(Object.keys(ledgerBefore.pendingAcceptances)).toContain(flow.acceptanceID);

    const atPurge = flow.expiresAt + 30 * 86_400 + 1;
    await purgeExpiredRecords(testPool(), 30, atPurge);
    const afterPurge = await readLedgerText(ownerID);
    const ledgerAfter = deserializeLedger(afterPurge.text);
    expect(Object.keys(ledgerAfter.pendingAcceptances)).not.toContain(flow.acceptanceID);
  });

  // P2a review follow-up P2-3: a legacy flat row's stored root was computed
  // once, by whatever code was live when it was written -- this version's
  // `normalizePendingAcceptance`/inbox-filter logic must read it without
  // ever rewriting it, so a later read (inbox fetch) or an unrelated write
  // (any further mutation) must still verify cleanly against that
  // untouched root rather than fail closed with `integrity_error`.
  it("a legacy flat pendingAcceptances row, with its root computed once, still verifies on a later read and an unrelated mutation", async () => {
    const now = BASE_NOW + 8_000;
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })), now);

    const acceptanceID = uniqueID("acceptance");
    const inviteID = uniqueID("invite");
    const bareAcceptanceWire = {
      acceptanceID,
      inviteID,
      owner: encodeDeviceIdentityWire(owner.identity),
      approver: encodeDeviceIdentityWire(approver.identity),
      issuedAt: swiftDate(now),
      verificationCode: "123456"
    };

    // Write the legacy flat row and compute+store the root exactly once,
    // simulating a production row from before this change (no further
    // recompute happens anywhere below).
    await patchLedger(owner.identity.identityID, (ledger) => {
      // @ts-expect-error -- deliberately the legacy flat shape (no
      // `{acceptance, signature}` wrapper), what a pre-existing row looks
      // like.
      ledger.pendingAcceptances[acceptanceID] = decodePairingAcceptance(bareAcceptanceWire);
    });

    // A read must verify cleanly against that stored root: no
    // `integrity_error`, and the unsigned entry is skipped rather than
    // delivered unverifiable.
    const inboxQueryOp = buildOperation({ kind: "inbox", payload: { identityID: owner.identity.identityID, issuedAt: swiftDate(now) }, signer: owner, expectedRevision: null });
    const inbox = await fetchInboxOperation(toRequest(inboxQueryOp), now);
    expect(inbox.pendingAcceptances).toEqual([]);

    // An unrelated mutation (never touching pendingAcceptances) must also
    // verify cleanly against the same untouched root and commit normally --
    // asserting specifically that it resolves (no integrity_error, no any
    // other failure).
    await expect(
      submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })), now)
    ).resolves.toBeDefined();
  });
});
