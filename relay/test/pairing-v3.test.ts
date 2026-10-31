// Pairing v3 (docs/r5-pairing-v3-plan.md, slice P3a): owner creates an invite
// keyed by a random token, the friend looks it up and accepts, and the relay
// activates the pairing and both-sided consent in one transaction. Explicit
// `now` injection throughout (no dependence on wall-clock timing).

import { describe, it, expect } from "vitest";
import {
  makeIdentity,
  buildOperation,
  buildInvite,
  buildAcceptance,
  swiftDate,
  uniqueID,
  testPool,
  signPayloadFields,
  encodeDeviceIdentityWire,
  type TestIdentity
} from "./setup.js";
import { submitOperation, fetchInboxOperation, lookupInvite, LOOKUP_RATE_LIMIT_MAX } from "../src/service.js";
import { handleInviteLookup, handleOperations } from "../src/handlers.js";
import { purgeExpiredRecords } from "../src/retention.js";
import { decodeInvitation, verifyInvitationSignature, verifySignedAcceptanceSignature } from "../src/protocol.js";
import { inviteTokenHash, generateInviteToken, isWellFormedInviteToken, COMPANION_VERSION, base64url } from "../src/canonical.js";
import { deserializeLedger, serializeLedger } from "../src/ledger.js";
import { computeStateRoot } from "../src/service.js";

const NOW = 1_700_000_000;
const TTL = 3600;

function toBuffer(op: object): Buffer {
  return Buffer.from(JSON.stringify(op), "utf8");
}

function send(op: object, now = NOW) {
  return submitOperation(toBuffer(op), now);
}

async function expectRejected(op: object, code: string, now = NOW) {
  await expect(submitOperation(toBuffer(op), now)).rejects.toMatchObject({ code });
}

function lookup(token: string, now = NOW, ip: string | null = "198.51.100.1") {
  return lookupInvite(Buffer.from(JSON.stringify({ token }), "utf8"), now, ip);
}

function inbox(identity: TestIdentity, now = NOW) {
  return fetchInboxOperation(toBuffer(buildOperation({ kind: "inbox", payload: { identityID: identity.identity.identityID, issuedAt: swiftDate(now) }, signer: identity, expectedRevision: null })), now);
}

async function createInvite(owner: TestIdentity, opts: Parameters<typeof buildInvite>[2] = {}, revision = 0, now = NOW) {
  const invite = buildInvite(owner, now, opts);
  await send(buildOperation({ kind: "invite", payload: invite.invitation, signer: owner, expectedRevision: revision }), now);
  return invite;
}

function acceptOp(owner: TestIdentity, approver: TestIdentity, invite: { inviteID: string; token: string }, opts: Partial<Parameters<typeof buildAcceptance>[0]> = {}, revision: number | null = null, now = NOW + 1) {
  return buildOperation({
    kind: "accept",
    payload: buildAcceptance({ owner, approver, inviteID: invite.inviteID, token: invite.token, now, ...opts }),
    signer: approver,
    expectedRevision: revision
  });
}

async function tokenRowCount(): Promise<number> {
  return (await testPool().query(`SELECT 1 FROM companion_invite_token`)).rowCount ?? 0;
}

describe("pairing v3: invite token and lookup", () => {
  it("generated tokens are 22 base64url characters (128 bits) and well formed", () => {
    const tokens = new Set(Array.from({ length: 50 }, () => generateInviteToken()));
    expect(tokens.size).toBe(50);
    for (const t of tokens) {
      expect(t).toHaveLength(22);
      expect(isWellFormedInviteToken(t)).toBe(true);
    }
    expect(isWellFormedInviteToken("short")).toBe(false);
    expect(isWellFormedInviteToken("a".repeat(23))).toBe(false);
    expect(isWellFormedInviteToken("a".repeat(21) + "+")).toBe(false);
  });

  it("lookup returns the owner-signed invitation for a live token, and the signature, token hash, name and scopes verify", async () => {
    const owner = makeIdentity("owner");
    const invite = await createInvite(owner, { ownerDisplayName: "Alex" });
    const found = await lookup(invite.token);
    expect(found.payload.inviteID).toBe(invite.inviteID);
    expect(found.payload.ownerDisplayName).toBe("Alex");
    expect(found.payload.grantedScopes).toEqual(["approveEarlyEnd", "receiveRequests"]);
    expect(found.payload.tokenHash.equals(inviteTokenHash(invite.token))).toBe(true);
    expect(verifyInvitationSignature(found)).toBe(true);
    // The relay never stores the plaintext token anywhere in the ledger row or the token index.
    const row = await testPool().query<{ state: string }>(`SELECT state FROM companion_owner WHERE owner_id = $1`, [owner.identity.identityID]);
    expect(row.rows[0]!.state).not.toContain(invite.token);
    const tokens = await testPool().query<{ token_hash: Buffer }>(`SELECT token_hash FROM companion_invite_token`);
    expect(tokens.rows).toHaveLength(1);
    expect(tokens.rows[0]!.token_hash.equals(inviteTokenHash(invite.token))).toBe(true);
  });

  it("an unknown token and a malformed token are distinguished only by form: wrong token is not_found, bad shape is malformed", async () => {
    const owner = makeIdentity("owner");
    await createInvite(owner);
    await expect(lookup(generateInviteToken())).rejects.toMatchObject({ code: "not_found" });
    await expect(lookup("short")).rejects.toMatchObject({ code: "malformed" });
    await expect(lookupInvite(Buffer.from("not json"), NOW, "198.51.100.2")).rejects.toMatchObject({ code: "malformed" });
    await expect(lookupInvite(Buffer.from(JSON.stringify({ token: 42 })), NOW, "198.51.100.2")).rejects.toMatchObject({ code: "malformed" });
  });

  it("an expired invite is not_found (and indistinguishable from an unknown token)", async () => {
    const owner = makeIdentity("owner");
    const invite = await createInvite(owner);
    await expect(lookup(invite.token, NOW + TTL - 1)).resolves.toBeDefined();
    await expect(lookup(invite.token, NOW + TTL)).rejects.toMatchObject({ code: "not_found" });
    await expect(lookup(invite.token, NOW + TTL + 100)).rejects.toMatchObject({ code: "not_found" });
  });

  it("lookup is rate limited per client IP, and one IP's budget does not affect another", async () => {
    const t = generateInviteToken();
    for (let i = 0; i < LOOKUP_RATE_LIMIT_MAX; i++) {
      await expect(lookup(t, NOW, "203.0.113.9")).rejects.toMatchObject({ code: "not_found" });
    }
    await expect(lookup(t, NOW, "203.0.113.9")).rejects.toMatchObject({ code: "rate_limited" });
    await expect(lookup(t, NOW, "203.0.113.10")).rejects.toMatchObject({ code: "not_found" });
    // The window rolls over.
    await expect(lookup(t, NOW + 61, "203.0.113.9")).rejects.toMatchObject({ code: "not_found" });
  });

  it("HTTP: 200 with the invitation, 404 not_found, 400 malformed, 405 for GET, and a limiter that returns 429", async () => {
    const owner = makeIdentity("owner");
    const invite = buildInvite(owner, Math.floor(Date.now() / 1000));
    await handleOperations(new Request("http://x/v1/operations", { method: "POST", body: JSON.stringify(buildOperation({ kind: "invite", payload: invite.invitation, signer: owner, expectedRevision: 0 })) }));
    const post = (body: unknown, ip = "192.0.2.1") =>
      handleInviteLookup(new Request("http://x/v1/invite/lookup", { method: "POST", body: JSON.stringify(body), headers: { "x-forwarded-for": ip } }));
    const ok = await post({ token: invite.token });
    expect(ok.status).toBe(200);
    const body = await ok.json();
    const decoded = decodeInvitation(body.invitation);
    expect(decoded.payload.inviteID).toBe(invite.inviteID);
    expect(verifyInvitationSignature(decoded)).toBe(true);
    const missing = await post({ token: generateInviteToken() });
    expect(missing.status).toBe(404);
    expect(await missing.json()).toEqual({ error: "not_found" });
    expect((await post({ token: "x" })).status).toBe(400);
    expect((await handleInviteLookup(new Request("http://x/v1/invite/lookup", { method: "GET" }))).status).toBe(405);
    let last = 200;
    for (let i = 0; i < LOOKUP_RATE_LIMIT_MAX + 1; i++) last = (await post({ token: generateInviteToken() }, "192.0.2.77")).status;
    expect(last).toBe(429);
  });
});

describe("pairing v3: accept creates pairing and consent atomically", () => {
  it("a single accept yields an active pairing and active both-sided consent, visible to both sides with names and the joined time", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    const invite = await createInvite(owner, { ownerDisplayName: "Alex" });
    const response = await send(acceptOp(owner, approver, invite, { approverDisplayName: "Sam" }, 1));
    expect(response.result.kind).toBe("pairing");
    const pairing = (response.result as { kind: "pairing"; value: any }).value;
    expect(pairing.state).toBe("active");
    expect(pairing.epoch).toBe(1);
    expect(pairing.createdAt).toBe(NOW);
    expect(pairing.ownerDisplayName).toBe("Alex");
    expect(pairing.approverDisplayName).toBe("Sam");

    for (const viewer of [owner, approver]) {
      const view = await inbox(viewer);
      expect(view.pairings).toHaveLength(1);
      expect(view.pairings[0]!.pairingID).toBe(pairing.pairingID);
      expect(view.pairings[0]!.ownerDisplayName).toBe("Alex");
      expect(view.pairings[0]!.approverDisplayName).toBe("Sam");
      expect(view.pairings[0]!.createdAt).toBe(NOW);
      expect(view.consents).toHaveLength(1);
      const consent = view.consents[0]!;
      expect(consent.pairingID).toBe(pairing.pairingID);
      expect(consent.ownerState).toBe("active");
      expect(consent.approverState).toBe("active");
      expect(consent.ownerScopes).toEqual(["approveEarlyEnd", "receiveRequests"]);
      expect(consent.approverScopes).toEqual(["approveEarlyEnd", "receiveRequests"]);
      expect(consent.generation).toBe(2);
      expect(consent.pairEpoch).toBe(1);
    }
    // Two operations only (invite, accept): no confirm or consent step was needed.
    expect((await inbox(owner)).revision).toBe(2);
  });

  it("the owner's inbox carries the friend-signed acceptance for each pairing (verifiable), and the friend's inbox does not", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    const invite = await createInvite(owner);
    await send(acceptOp(owner, approver, invite, { approverDisplayName: "Sam" }, 1));
    const ownerView = await inbox(owner);
    expect(ownerView.acceptances).toHaveLength(1);
    const signed = ownerView.acceptances![0]!;
    expect(verifySignedAcceptanceSignature(signed)).toBe(true);
    expect(signed.acceptance.inviteID).toBe(invite.inviteID);
    expect(signed.acceptance.approver.identityID).toBe(approver.identity.identityID);
    expect(inviteTokenHash(signed.acceptance.token).equals(inviteTokenHash(invite.token))).toBe(true);
    expect((await inbox(approver)).acceptances).toBeUndefined();
  });

  it("names are optional and absent names stay absent on the pairing", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    const invite = await createInvite(owner);
    const response = await send(acceptOp(owner, approver, invite));
    const pairing = (response.result as { kind: "pairing"; value: any }).value;
    expect(pairing.ownerDisplayName).toBeUndefined();
    expect(pairing.approverDisplayName).toBeUndefined();
  });

  it("a failed accept is atomic: no pairing, no consent, invite stays unconsumed and still usable", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    const invite = await createInvite(owner);
    // Wrong scopes: the friend must accept exactly what was granted.
    await expectRejected(acceptOp(owner, approver, invite, { acceptedScopes: ["approveEarlyEnd"] }), "consent_required");
    const afterFailure = await inbox(owner);
    expect(afterFailure.pairings).toHaveLength(0);
    expect(afterFailure.consents).toHaveLength(0);
    expect(afterFailure.revision).toBe(1);
    await expect(lookup(invite.token)).resolves.toBeDefined();
    await expect(send(acceptOp(owner, approver, invite))).resolves.toMatchObject({ result: { kind: "pairing" } });
  });

  it("the invite is single use: the second accept (same friend or another) is rejected and lookup stops resolving the token", async () => {
    const owner = makeIdentity("owner");
    const a = makeIdentity("trustedApprover");
    const b = makeIdentity("trustedApprover");
    const invite = await createInvite(owner);
    await send(acceptOp(owner, a, invite));
    await expectRejected(acceptOp(owner, b, invite, {}, null, NOW + 2), "replay");
    await expectRejected(acceptOp(owner, a, invite, { acceptanceID: uniqueID("again") }, null, NOW + 2), "replay");
    await expect(lookup(invite.token)).rejects.toMatchObject({ code: "not_found" });
    expect(await tokenRowCount()).toBe(0);
    expect((await inbox(owner)).pairings).toHaveLength(1);
  });

  it("an exact idempotent re-send of the accept operation returns the committed receipt without creating anything new", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    const invite = await createInvite(owner);
    const op = acceptOp(owner, approver, invite);
    const first = await send(op);
    const replay = await send(op, NOW + 5);
    expect(replay.result).toEqual(first.result);
    expect((await inbox(owner, NOW + 5)).pairings).toHaveLength(1);
  });

  it("an expired invite cannot be accepted even with the right token", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    const invite = await createInvite(owner);
    await expectRejected(acceptOp(owner, approver, invite, {}, null, NOW + TTL - 1), "expired", NOW + TTL);
  });

  it("the same friend accepting a second invite creates a second, distinct pairing (same-identity pairings are supported)", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    const first = await createInvite(owner);
    const paired = await send(acceptOp(owner, approver, first));
    const second = await createInvite(owner, {}, 2);
    const again = await send(acceptOp(owner, approver, second, {}, null, NOW + 2), NOW + 2);
    const a = (paired.result as { kind: "pairing"; value: any }).value;
    const b = (again.result as { kind: "pairing"; value: any }).value;
    expect(b.pairingID).not.toBe(a.pairingID);
    expect((await inbox(owner, NOW + 2)).pairings).toHaveLength(2);
    // A revoked pairing never blocked anything either.
    const revoke = buildOperation({ kind: "revoke", payload: { pairingID: a.pairingID, epoch: 1 }, signer: owner, expectedRevision: null });
    await send(revoke, NOW + 3);
    const third = await createInvite(owner, {}, 5, NOW + 3);
    await expect(send(acceptOp(owner, approver, third, {}, null, NOW + 4), NOW + 4)).resolves.toMatchObject({ result: { kind: "pairing" } });
  });

  it("existing consent operations keep working after a v3 pairing (later revoke / opt-out)", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    const invite = await createInvite(owner);
    const paired = await send(acceptOp(owner, approver, invite));
    const pairing = (paired.result as { kind: "pairing"; value: any }).value;
    const mutation = (action: string, signer: TestIdentity, scopes: string[], nonceByte: number) =>
      buildOperation({
        kind: "consent",
        payload: {
          relationshipID: pairing.pairingID,
          pairingID: pairing.pairingID,
          pairEpoch: 1,
          owner: encodeDeviceIdentityWire(owner.identity),
          approver: encodeDeviceIdentityWire(approver.identity),
          action,
          scopes: { scopes },
          nonce: Buffer.alloc(20, nonceByte).toString("base64"),
          issuedAt: swiftDate(NOW + 2)
        },
        signer,
        expectedRevision: null
      });
    // The friend opts out of receiving requests; the pairing stays, only that scope is withdrawn.
    const out = await send(mutation("approverRevoke", approver, ["receiveRequests"], 1), NOW + 2);
    const consent = (out.result as { kind: "consent"; value: any }).value;
    expect(consent.approverScopes).toEqual(["approveEarlyEnd"]);
    expect(consent.generation).toBe(3);
    // The owner revokes everything.
    const revoked = await send(mutation("ownerRevoke", owner, ["approveEarlyEnd", "receiveRequests"], 2), NOW + 3);
    expect((revoked.result as { kind: "consent"; value: any }).value.ownerState).toBe("revoked");
  });

  it("replace_pairing carries both display names to the replacement pairing", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    const invite = await createInvite(owner, { ownerDisplayName: "Alex" });
    const paired = await send(acceptOp(owner, approver, invite, { approverDisplayName: "Sam" }));
    const pairing = (paired.result as { kind: "pairing"; value: any }).value;
    const replacement = makeIdentity("trustedApprover");
    const replacementPairingID = uniqueID("replacement-pairing");
    const replaceID = uniqueID("replace");
    const fields = [replaceID, pairing.pairingID, "1", replacementPairingID, owner.identity.identityID, base64url(owner.identity.publicKey), replacement.identity.identityID, base64url(replacement.identity.publicKey), "2", String((NOW + 2) * 1000)];
    const proposal = {
      replacementID: replaceID,
      previousPairingID: pairing.pairingID,
      previousEpoch: 1,
      replacementPairingID,
      replacement: encodeDeviceIdentityWire(replacement.identity),
      owner: encodeDeviceIdentityWire(owner.identity),
      replacementEpoch: 2,
      issuedAt: swiftDate(NOW + 2),
      signature: signPayloadFields(replacement, `${COMPANION_VERSION}.pairing-replacement`, fields).toString("base64")
    };
    const replaced = await send(buildOperation({ kind: "replace_pairing", payload: proposal, signer: owner, expectedRevision: null }), NOW + 2);
    const activated = (replaced.result as { kind: "pairing"; value: any }).value;
    expect(activated.ownerDisplayName).toBe("Alex");
    expect(activated.approverDisplayName).toBe("Sam");
  });
});

describe("pairing v3: isolation between owners", () => {
  it("an owner's invite never appears in or affects another owner's partition", async () => {
    const ownerA = makeIdentity("owner");
    const ownerB = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    const inviteA = await createInvite(ownerA);
    const inviteB = await createInvite(ownerB);
    // Lookup resolves each token only to its own owner's invitation.
    expect((await lookup(inviteA.token)).payload.owner.identityID).toBe(ownerA.identity.identityID);
    expect((await lookup(inviteB.token)).payload.owner.identityID).toBe(ownerB.identity.identityID);
    // Accepting A's invite in B's partition (naming B as owner) fails: B has no such invite.
    await expectRejected(
      buildOperation({ kind: "accept", payload: buildAcceptance({ owner: ownerB, approver, inviteID: inviteA.inviteID, token: inviteA.token, now: NOW + 1 }), signer: approver, expectedRevision: null }),
      "unauthorized"
    );
    // A's token with B's inviteID is equally useless.
    await expectRejected(
      buildOperation({ kind: "accept", payload: buildAcceptance({ owner: ownerB, approver, inviteID: inviteB.inviteID, token: inviteA.token, now: NOW + 1 }), signer: approver, expectedRevision: null }),
      "unauthorized"
    );
    await send(acceptOp(ownerA, approver, inviteA));
    expect((await inbox(ownerA)).pairings).toHaveLength(1);
    expect((await inbox(ownerB)).pairings).toHaveLength(0);
    // B's invite is untouched by A's consumption.
    await expect(lookup(inviteB.token)).resolves.toBeDefined();
  });

  it("an owner cannot claim a token hash that is already registered (even by themselves, or another owner)", async () => {
    const ownerA = makeIdentity("owner");
    const ownerB = makeIdentity("owner");
    const inviteA = await createInvite(ownerA);
    const clone = buildInvite(ownerB, NOW, { token: inviteA.token });
    await expectRejected(buildOperation({ kind: "invite", payload: clone.invitation, signer: ownerB, expectedRevision: 0 }), "replay");
    // B's failed op left nothing behind and A's token still resolves to A.
    expect((await lookup(inviteA.token)).payload.owner.identityID).toBe(ownerA.identity.identityID);
    expect(await tokenRowCount()).toBe(1);
  });
});

describe("pairing v3: signature coverage", () => {
  function tamperedInvite(owner: TestIdentity, mutate: (payload: any) => void) {
    const invite = buildInvite(owner, NOW, { ownerDisplayName: "Alex" });
    mutate(invite.invitation.payload);
    return invite;
  }

  it("the owner signature covers ownerDisplayName, grantedScopes and tokenHash", async () => {
    const owner = makeIdentity("owner");
    for (const mutate of [
      (p: any) => (p.ownerDisplayName = "Mallory"),
      (p: any) => delete p.ownerDisplayName,
      (p: any) => (p.grantedScopes = ["approveEarlyEnd"]),
      (p: any) => (p.tokenHash = inviteTokenHash(generateInviteToken()).toString("base64"))
    ]) {
      const invite = tamperedInvite(owner, mutate);
      await expectRejected(buildOperation({ kind: "invite", payload: invite.invitation, signer: owner, expectedRevision: null }), "invalid_signature");
    }
  });

  it("the friend signature covers approverDisplayName, acceptedScopes, the token and the invite binding", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    const invite = await createInvite(owner);
    const base = buildAcceptance({ owner, approver, inviteID: invite.inviteID, token: invite.token, now: NOW + 1, approverDisplayName: "Sam" });
    const mutations: Array<(a: any) => void> = [
      (a) => (a.acceptance.approverDisplayName = "Mallory"),
      (a) => delete a.acceptance.approverDisplayName,
      (a) => (a.acceptance.acceptedScopes = ["approveEarlyEnd"]),
      (a) => (a.acceptance.issuedAt = swiftDate(NOW + 2))
    ];
    for (const mutate of mutations) {
      const copy = JSON.parse(JSON.stringify(base));
      mutate(copy);
      await expectRejected(buildOperation({ kind: "accept", payload: copy, signer: approver, expectedRevision: null }), "unauthorized");
    }
    // Replacing the token with a different (wrong) one fails on the token itself.
    const wrongToken = JSON.parse(JSON.stringify(base));
    wrongToken.acceptance.token = generateInviteToken();
    await expectRejected(buildOperation({ kind: "accept", payload: wrongToken, signer: approver, expectedRevision: null }), "unauthorized");
    // Nothing above consumed the invite.
    await expect(send(buildOperation({ kind: "accept", payload: base, signer: approver, expectedRevision: null }))).resolves.toMatchObject({ result: { kind: "pairing" } });
  });

  it("the operation signer must be the acceptance's approver", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    const other = makeIdentity("trustedApprover");
    const invite = await createInvite(owner);
    const payload = buildAcceptance({ owner, approver, inviteID: invite.inviteID, token: invite.token, now: NOW + 1 });
    await expectRejected(buildOperation({ kind: "accept", payload, signer: other, expectedRevision: null }), "unauthorized");
  });

  it("a signature made under the v2 domain does not verify as v3 (domain separation)", async () => {
    const owner = makeIdentity("owner");
    const invite = buildInvite(owner, NOW);
    const p = invite.invitation.payload as any;
    const fields = [p.inviteID, owner.identity.identityID, base64url(owner.identity.publicKey), String(NOW * 1000), String((NOW + TTL) * 1000), base64url(Buffer.from(p.nonce, "base64")), base64url(Buffer.from(p.tokenHash, "base64")), "", p.grantedScopes.join(",")];
    const wrongDomain = signPayloadFields(owner, `${COMPANION_VERSION}.invite`, fields).toString("base64");
    await expectRejected(buildOperation({ kind: "invite", payload: { payload: p, signature: wrongDomain }, signer: owner, expectedRevision: null }), "invalid_signature");
  });
});

describe("pairing v3: compatibility and validation", () => {
  it("a pre-v3 invite (no token hash / scopes) and a pre-v3 acceptance (verification code) are rejected as malformed, and confirm is no longer an operation", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    const v3 = buildInvite(owner, NOW);
    const v2Invite = JSON.parse(JSON.stringify(v3.invitation));
    delete v2Invite.payload.tokenHash;
    delete v2Invite.payload.grantedScopes;
    await expectRejected(buildOperation({ kind: "invite", payload: v2Invite, signer: owner, expectedRevision: null }), "malformed");

    const invite = await createInvite(owner);
    const v2Accept = {
      acceptance: {
        acceptanceID: uniqueID("a"),
        inviteID: invite.inviteID,
        owner: encodeDeviceIdentityWire(owner.identity),
        approver: encodeDeviceIdentityWire(approver.identity),
        issuedAt: swiftDate(NOW + 1),
        verificationCode: "123456"
      },
      signature: Buffer.alloc(64, 1).toString("base64")
    };
    await expectRejected(buildOperation({ kind: "accept", payload: v2Accept, signer: approver, expectedRevision: null }), "malformed");
    await expectRejected(buildOperation({ kind: "confirm", payload: {}, signer: owner, expectedRevision: null }), "unsupported_operation");
  });

  it("a v2 invite already in a stored ledger (no token hash) cannot be accepted", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    await send(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null }));
    const legacyID = "legacy-v2-invite";
    const { rows } = await testPool().query<{ state: string; revision: string }>(`SELECT state, revision FROM companion_owner WHERE owner_id = $1`, [owner.identity.identityID]);
    const ledger = deserializeLedger(rows[0]!.state);
    ledger.invitations[legacyID] = { invitation: { payload: { inviteID: legacyID, owner: ledger.owner, issuedAt: NOW, expiresAt: NOW + TTL, nonce: Buffer.alloc(24, 7) } as any, signature: Buffer.alloc(64) }, consumedAt: null };
    await testPool().query(`UPDATE companion_owner SET state = $1, state_root = $2 WHERE owner_id = $3`, [serializeLedger(ledger), computeStateRoot(ledger, Number(rows[0]!.revision)), owner.identity.identityID]);
    await expectRejected(acceptOp(owner, approver, { inviteID: legacyID, token: generateInviteToken() }), "unauthorized");
  });

  it("display names: 40 scalars OK (including multi-byte), 41 rejected, control characters and whitespace-only rejected", async () => {
    const owner = makeIdentity("owner");
    const ok40 = "😀".repeat(40);
    await createInvite(owner, { ownerDisplayName: ok40 });
    for (const bad of ["😀".repeat(41), "A".repeat(41), "Bad\nName", "tab\there", "   ", ""]) {
      const invite = buildInvite(owner, NOW, { ownerDisplayName: bad });
      // An explicit empty string is not a legal encoding of "no name".
      if (bad === "") invite.invitation.payload.ownerDisplayName = "";
      await expectRejected(buildOperation({ kind: "invite", payload: invite.invitation, signer: owner, expectedRevision: null }), "malformed");
    }
    const approver = makeIdentity("trustedApprover");
    const invite = await createInvite(owner, {}, 1);
    await expectRejected(acceptOp(owner, approver, invite, { approverDisplayName: "B".repeat(41) }), "malformed");
  });

  it("granted scopes must be a non-empty set of R5 scopes (reserved R6 scopes, duplicates and empty are malformed)", async () => {
    const owner = makeIdentity("owner");
    for (const scopes of [[], ["mutualPact"], ["approveEarlyEnd", "approveEarlyEnd"], ["bogus"]]) {
      const invite = buildInvite(owner, NOW, { grantedScopes: scopes });
      await expectRejected(buildOperation({ kind: "invite", payload: invite.invitation, signer: owner, expectedRevision: null }), "malformed");
    }
    // A single-scope grant is legal and the friend must accept exactly it.
    const approver = makeIdentity("trustedApprover");
    const invite = await createInvite(owner, { grantedScopes: ["approveEarlyEnd"] });
    await expectRejected(acceptOp(owner, approver, invite), "consent_required");
    const response = await send(acceptOp(owner, approver, invite, { acceptedScopes: ["approveEarlyEnd"] }));
    expect(response.result.kind).toBe("pairing");
    expect((await inbox(owner)).consents[0]!.ownerScopes).toEqual(["approveEarlyEnd"]);
  });
});

describe("pairing v3: retention", () => {
  it("expired token rows are swept immediately at expiry and their consumed or expired ledger invites are purged on the 30-day window", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    const live = await createInvite(owner);
    const used = await createInvite(owner, {}, 1);
    await send(acceptOp(owner, approver, used, {}, null, NOW + 1));
    expect(await tokenRowCount()).toBe(1); // the consumed invite's row went with the accept
    expect((await lookup(live.token)).payload.inviteID).toBe(live.inviteID);

    // Before expiry nothing is swept.
    let summary = await purgeExpiredRecords(testPool(), 30, NOW + TTL - 10);
    expect(summary.purgedInviteTokens).toBe(0);
    expect(await tokenRowCount()).toBe(1);

    // At expiry the token row is swept even though the ledger invite is retained for 30 days.
    summary = await purgeExpiredRecords(testPool(), 30, NOW + TTL + 5);
    expect(summary.purgedInviteTokens).toBe(1);
    expect(await tokenRowCount()).toBe(0);
    await expect(lookup(live.token, NOW + TTL + 5)).rejects.toMatchObject({ code: "not_found" });

    // 31 days later the (expired and consumed) invites are purged from the ledger too.
    summary = await purgeExpiredRecords(testPool(), 30, NOW + 31 * 86_400);
    expect(summary.purgedInvitations).toBe(2);
    const row = await testPool().query<{ state: string }>(`SELECT state FROM companion_owner WHERE owner_id = $1`, [owner.identity.identityID]);
    expect(Object.keys(deserializeLedger(row.rows[0]!.state).invitations)).toHaveLength(0);
  });

  it("deleting an owner cascades to their token rows", async () => {
    const owner = makeIdentity("owner");
    await createInvite(owner);
    expect(await tokenRowCount()).toBe(1);
    await testPool().query(`DELETE FROM companion_owner WHERE owner_id = $1`, [owner.identity.identityID]);
    expect(await tokenRowCount()).toBe(0);
  });
});
