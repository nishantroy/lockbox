// APNs wake-up notifications (docs/r5-apns-plan.md): token registration
// endpoint, recipient/banner logic for the four events, failure isolation,
// pruning, JWT shape and retention. A fake PushSender is injected; nothing
// here talks to Apple.

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { generateKeyPairSync, verify as cryptoVerify } from "node:crypto";
import { makeIdentity, buildOperation, pairV3, swiftDate, signPayloadFields, encodeDeviceIdentityWire, uniqueID, testPool, type TestIdentity } from "./setup.js";
import { submitOperation, registerPushToken } from "../src/service.js";
import { handlePushToken } from "../src/handlers.js";
import { base64url, COMPANION_VERSION } from "../src/canonical.js";
import {
  setPushSenderForTesting,
  setPushTimeoutForTesting,
  dispatchPush,
  buildApnsJWT,
  cachedApnsJWT,
  resetApnsJWTCacheForTesting,
  apnsConfigFromEnv,
  buildPushPayload,
  type PushSender,
  type PushMessage,
  type PushResult,
  type PushTarget
} from "../src/apns.js";
import { purgeExpiredRecords } from "../src/retention.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

function bytes(op: object): Buffer {
  return Buffer.from(JSON.stringify(op), "utf8");
}

function hexToken(seed: string): string {
  return seed.repeat(64).slice(0, 64);
}

const nowSec = () => Math.floor(Date.now() / 1000);

function pushTokenOp(signer: TestIdentity, over: { identityID?: string; issuedAt?: number; token?: string | null; environment?: string; omitIssuedAt?: boolean } = {}) {
  const payload: Record<string, unknown> = {
    identityID: over.identityID ?? signer.identity.identityID,
    token: over.token === undefined ? hexToken("ab") : over.token,
    environment: over.environment ?? "sandbox"
  };
  if (!over.omitIssuedAt) payload.issuedAt = swiftDate(over.issuedAt ?? nowSec());
  return buildOperation({ kind: "push_token", payload, signer, expectedRevision: null, operationID: uniqueID("pt") });
}

async function rows(identityID: string): Promise<Array<{ token: string; environment: string; updated_at: string }>> {
  const r = await testPool().query(`SELECT token, environment, updated_at FROM companion_push_token WHERE identity_id = $1 ORDER BY updated_at, token`, [identityID]);
  return r.rows;
}

class FakeSender implements PushSender {
  sent: Array<{ target: PushTarget; message: PushMessage }> = [];
  closed = 0;
  behavior: (target: PushTarget) => Promise<PushResult> | PushResult = () => "sent";
  async send(target: PushTarget, message: PushMessage): Promise<PushResult> {
    this.sent.push({ target, message });
    return this.behavior(target);
  }
  close(): void {
    this.closed += 1;
  }
}

let fake: FakeSender;
beforeEach(() => {
  fake = new FakeSender();
  setPushSenderForTesting(fake);
});
afterEach(() => {
  setPushSenderForTesting(undefined);
  setPushTimeoutForTesting(undefined);
});

describe("POST push-token registration", () => {
  it("registers a token and handles it through the HTTP handler", async () => {
    const approver = makeIdentity("trustedApprover");
    const response = await handlePushToken(new Request("http://x/v1/push-token", { method: "POST", body: JSON.stringify(pushTokenOp(approver)) }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    const stored = await rows(approver.identity.identityID);
    expect(stored).toHaveLength(1);
    expect(stored[0]).toMatchObject({ token: hexToken("ab"), environment: "sandbox" });
  });

  it("re-registering an existing token updates environment and timestamp instead of adding a row", async () => {
    const owner = makeIdentity("owner");
    const t = nowSec();
    await registerPushToken(bytes(pushTokenOp(owner, { environment: "sandbox", issuedAt: t })), t);
    await registerPushToken(bytes(pushTokenOp(owner, { environment: "production", issuedAt: t + 10 })), t + 10);
    const stored = await rows(owner.identity.identityID);
    expect(stored).toHaveLength(1);
    expect(stored[0]).toMatchObject({ environment: "production", updated_at: String(t + 10) });
  });

  it("keeps at most 5 tokens per identity, dropping the oldest", async () => {
    const owner = makeIdentity("owner");
    const t = nowSec();
    const seeds = ["a1", "b2", "c3", "d4", "e5", "f6", "07"];
    for (const [i, seed] of seeds.entries()) {
      await registerPushToken(bytes(pushTokenOp(owner, { token: hexToken(seed), issuedAt: t + i })), t + i);
    }
    const stored = await rows(owner.identity.identityID);
    expect(stored.map((r) => r.token)).toEqual(seeds.slice(2).map(hexToken));
  });

  it("the cap is per identity", async () => {
    const a = makeIdentity("owner");
    const b = makeIdentity("trustedApprover");
    const t = nowSec();
    for (let i = 0; i < 5; i++) await registerPushToken(bytes(pushTokenOp(a, { token: hexToken(`a${i}`), issuedAt: t + i })), t + i);
    await registerPushToken(bytes(pushTokenOp(b, { issuedAt: t })), t);
    expect(await rows(a.identity.identityID)).toHaveLength(5);
    expect(await rows(b.identity.identityID)).toHaveLength(1);
  });

  it("token: null unregisters only that environment's tokens for the signer", async () => {
    const owner = makeIdentity("owner");
    const other = makeIdentity("trustedApprover");
    await registerPushToken(bytes(pushTokenOp(owner, { token: hexToken("a1"), environment: "sandbox" })));
    await registerPushToken(bytes(pushTokenOp(owner, { token: hexToken("b2"), environment: "production" })));
    await registerPushToken(bytes(pushTokenOp(other, { token: hexToken("a1"), environment: "sandbox" })));
    await registerPushToken(bytes(pushTokenOp(owner, { token: null, environment: "sandbox" })));
    expect((await rows(owner.identity.identityID)).map((r) => r.environment)).toEqual(["production"]);
    expect(await rows(other.identity.identityID)).toHaveLength(1);
  });

  it("rejects an identityID that is not the signer's with unauthorized", async () => {
    const a = makeIdentity("owner");
    const b = makeIdentity("trustedApprover");
    await expect(registerPushToken(bytes(pushTokenOp(a, { identityID: b.identity.identityID })))).rejects.toMatchObject({ code: "unauthorized", status: 403 });
    expect(await rows(b.identity.identityID)).toHaveLength(0);
  });

  it("rejects stale and far-future issuedAt with expired", async () => {
    const a = makeIdentity("owner");
    const t = nowSec();
    await expect(registerPushToken(bytes(pushTokenOp(a, { issuedAt: t - 301 })), t)).rejects.toMatchObject({ code: "expired" });
    await expect(registerPushToken(bytes(pushTokenOp(a, { issuedAt: t + 61 })), t)).rejects.toMatchObject({ code: "expired" });
    await expect(registerPushToken(bytes(pushTokenOp(a, { issuedAt: t - 299 })), t)).resolves.toBeUndefined();
    await expect(registerPushToken(bytes(pushTokenOp(a, { issuedAt: t + 59, token: hexToken("cd") })), t)).resolves.toBeUndefined();
  });

  it("rejects bad hex, bad length, bad environment and missing issuedAt as malformed", async () => {
    const a = makeIdentity("owner");
    for (const token of ["ABCDEF".repeat(11), "zz".repeat(32), "ab".repeat(31), "ab".repeat(101), ""]) {
      await expect(registerPushToken(bytes(pushTokenOp(a, { token })))).rejects.toMatchObject({ code: "malformed" });
    }
    await expect(registerPushToken(bytes(pushTokenOp(a, { environment: "staging" })))).rejects.toMatchObject({ code: "malformed" });
    await expect(registerPushToken(bytes(pushTokenOp(a, { omitIssuedAt: true })))).rejects.toMatchObject({ code: "malformed" });
    expect(await rows(a.identity.identityID)).toHaveLength(0);
  });

  it("rejects the wrong kind, a non-null expectedRevision, garbage and a tampered signature", async () => {
    const a = makeIdentity("owner");
    const wrongKind = buildOperation({ kind: "inbox", payload: { identityID: a.identity.identityID }, signer: a });
    await expect(registerPushToken(bytes(wrongKind))).rejects.toMatchObject({ code: "malformed" });
    const withRevision = buildOperation({ kind: "push_token", payload: { identityID: a.identity.identityID, issuedAt: swiftDate(nowSec()), token: hexToken("ab"), environment: "sandbox" }, signer: a, expectedRevision: 3 });
    await expect(registerPushToken(bytes(withRevision))).rejects.toMatchObject({ code: "malformed" });
    await expect(registerPushToken(Buffer.from("not json"))).rejects.toMatchObject({ code: "malformed" });
    const tampered = pushTokenOp(a) as { signature: string };
    const sig = Buffer.from(tampered.signature, "base64");
    sig[0] = sig[0]! ^ 0xff;
    tampered.signature = sig.toString("base64");
    await expect(registerPushToken(bytes(tampered))).rejects.toMatchObject({ code: "invalid_signature", status: 401 });
    expect(await rows(a.identity.identityID)).toHaveLength(0);
  });

  it("maps an oversized body to 413 over HTTP", async () => {
    const response = await handlePushToken(new Request("http://x/v1/push-token", { method: "POST", body: "x".repeat(300_000) }));
    expect(response.status).toBe(413);
  });

  it("rejects a non-POST method", async () => {
    expect((await handlePushToken(new Request("http://x/v1/push-token", { method: "GET" }))).status).toBe(405);
  });

  it("accepts the hand-built fixture operation (body bytes are the sortedKeys layout)", async () => {
    const fixture = JSON.parse(readFileSync(join(__dirname, "fixtures", "push-token-op.json"), "utf8"));
    expect(Buffer.from(fixture.operation.body, "base64").toString("utf8")).toBe(fixture.bodyJSON);
    await registerPushToken(bytes(fixture.operation), fixture.issuedAtUnix);
    const stored = await rows(fixture.operation.signer.identityID);
    expect(stored).toHaveLength(1);
    expect(stored[0]!.token).toBe("0123456789abcdef".repeat(4));
  });
});

// ---------------------------------------------------------------------------
// Event recipients
// ---------------------------------------------------------------------------

interface Scenario {
  owner: TestIdentity;
  approver: TestIdentity;
  now: number;
  pairingID: string;
  sessionID: string;
  activeSetID: string;
}

const OWNER_TOKEN = hexToken("0a");
const APPROVER_TOKEN = hexToken("0b");

async function register(identity: TestIdentity, token: string, environment: "sandbox" | "production" = "sandbox") {
  await registerPushToken(bytes(pushTokenOp(identity, { token, environment })));
}

async function setupPaired(opts: { ownerName?: string; approverName?: string; nonceByte?: number } = {}): Promise<Scenario> {
  const owner = makeIdentity("owner");
  const approver = makeIdentity("trustedApprover");
  const now = nowSec();
  const { pairingID } = await pairV3({ owner, approver, now, ownerDisplayName: opts.ownerName, approverDisplayName: opts.approverName, nonceByte: opts.nonceByte });
  const sessionID = uniqueID("session");
  const activeSetID = uniqueID("activeset");
  const sessionPayload = { owner: encodeDeviceIdentityWire(owner.identity), sessionID, activeSetID, startsAt: swiftDate(now - 60), endsAt: swiftDate(now + 100_000) };
  await submitOperation(bytes(buildOperation({ kind: "session", payload: sessionPayload, signer: owner, expectedRevision: 5 })));
  return { owner, approver, now, pairingID, sessionID, activeSetID };
}

function requestPayload(s: Scenario, requestID: string) {
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
    createdAt: swiftDate(s.now + 6),
    expiresAt: swiftDate(s.now + 40_000),
    status: "pending",
    decisions: { [s.approver.identity.identityID]: "pending" }
  };
}

function approvalPayload(s: Scenario, requestID: string, decision: "approved" | "declined", nonceByte: number) {
  const approvalID = uniqueID("approval");
  const nonce = Buffer.alloc(20, nonceByte);
  const fields = [approvalID, requestID, s.pairingID, "1", "2", s.sessionID, s.activeSetID, s.approver.identity.identityID, base64url(s.approver.identity.publicKey), decision, String((s.now + 7) * 1000), base64url(nonce)];
  const signature = signPayloadFields(s.approver, `${COMPANION_VERSION}.approval`, fields);
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
    issuedAt: swiftDate(s.now + 7),
    signature: signature.toString("base64")
  };
}

const sendRequest = (s: Scenario, requestID: string) => buildOperation({ kind: "request", payload: requestPayload(s, requestID), signer: s.owner, expectedRevision: 6 });
const sendApproval = (s: Scenario, requestID: string, decision: "approved" | "declined", rev = 7) => buildOperation({ kind: "approval", payload: approvalPayload(s, requestID, decision, 3), signer: s.approver, expectedRevision: rev });

describe("push recipients per event", () => {
  it("Ask now notifies exactly the targeted approver, titled with the owner's signed name", async () => {
    const s = await setupPaired({ ownerName: "Nishant", approverName: "Sam" });
    await register(s.owner, OWNER_TOKEN);
    await register(s.approver, APPROVER_TOKEN);
    await submitOperation(bytes(sendRequest(s, uniqueID("request"))));
    expect(fake.sent).toHaveLength(1);
    expect(fake.sent[0]!.target).toEqual({ token: APPROVER_TOKEN, environment: "sandbox" });
    expect(fake.sent[0]!.message).toEqual({ title: "Nishant", body: "Asks you to approve ending a lock early.", kind: "request" });
  });

  it("approve notifies only the owner, titled with the approver's name", async () => {
    const s = await setupPaired({ ownerName: "Nishant", approverName: "Sam" });
    await register(s.owner, OWNER_TOKEN, "production");
    await register(s.approver, APPROVER_TOKEN);
    const requestID = uniqueID("request");
    await submitOperation(bytes(sendRequest(s, requestID)));
    fake.sent.length = 0;
    await submitOperation(bytes(sendApproval(s, requestID, "approved")));
    expect(fake.sent).toHaveLength(1);
    expect(fake.sent[0]!.target).toEqual({ token: OWNER_TOKEN, environment: "production" });
    expect(fake.sent[0]!.message).toEqual({ title: "Sam", body: "Approved your request. Open Phone Lockbox to end your lock.", kind: "answer" });
  });

  it("decline notifies only the owner", async () => {
    const s = await setupPaired({ ownerName: "Nishant", approverName: "Sam" });
    await register(s.owner, OWNER_TOKEN);
    await register(s.approver, APPROVER_TOKEN);
    const requestID = uniqueID("request");
    await submitOperation(bytes(sendRequest(s, requestID)));
    fake.sent.length = 0;
    await submitOperation(bytes(sendApproval(s, requestID, "declined")));
    expect(fake.sent).toHaveLength(1);
    expect(fake.sent[0]!.target.token).toBe(OWNER_TOKEN);
    expect(fake.sent[0]!.message).toEqual({ title: "Sam", body: "Declined your request.", kind: "answer" });
  });

  it("an invite accept notifies only the owner, titled with the friend's name", async () => {
    const owner = makeIdentity("owner");
    const approver = makeIdentity("trustedApprover");
    await register(owner, OWNER_TOKEN);
    await register(approver, APPROVER_TOKEN);
    await pairV3({ owner, approver, now: nowSec(), approverDisplayName: "Sam", legacyRevisionPad: 0 });
    expect(fake.sent).toHaveLength(1);
    expect(fake.sent[0]!.target.token).toBe(OWNER_TOKEN);
    expect(fake.sent[0]!.message).toEqual({ title: "Sam", body: "Joined as your trusted person.", kind: "joined" });
  });

  it("falls back to the title Phone Lockbox when a name is missing or blank", async () => {
    const s = await setupPaired({});
    await register(s.owner, OWNER_TOKEN);
    await register(s.approver, APPROVER_TOKEN);
    const requestID = uniqueID("request");
    await submitOperation(bytes(sendRequest(s, requestID)));
    expect(fake.sent[0]!.message.title).toBe("Phone Lockbox");
    await submitOperation(bytes(sendApproval(s, requestID, "approved")));
    expect(fake.sent[1]!.message.title).toBe("Phone Lockbox");
  });

  it("other operations (ack, session, revoke-style) send nothing", async () => {
    const owner = makeIdentity("owner");
    await register(owner, OWNER_TOKEN);
    await submitOperation(bytes(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: 0 })));
    expect(fake.sent).toHaveLength(0);
  });

  it("isolates owners: a request from owner B never notifies owner A's approver", async () => {
    const a = await setupPaired({ ownerName: "Alice", approverName: "Amy", nonceByte: 11 });
    const b = await setupPaired({ ownerName: "Bob", approverName: "Ben", nonceByte: 12 });
    const aToken = hexToken("a9");
    const bToken = hexToken("b9");
    await register(a.approver, aToken);
    await register(b.approver, bToken);
    await register(a.owner, hexToken("c9"));
    await submitOperation(bytes(sendRequest(b, uniqueID("request"))));
    expect(fake.sent.map((x) => x.target.token)).toEqual([bToken]);
    expect(fake.sent[0]!.message.title).toBe("Bob");
  });

  it("sends one banner per registered device (an identity may hold several tokens)", async () => {
    const s = await setupPaired({ ownerName: "Nishant" });
    await register(s.approver, hexToken("a1"));
    await register(s.approver, hexToken("b2"), "production");
    await submitOperation(bytes(sendRequest(s, uniqueID("request"))));
    expect(fake.sent.map((x) => x.target.token).sort()).toEqual([hexToken("a1"), hexToken("b2")]);
  });
});

describe("push never affects the operation", () => {
  it("sends nothing on an idempotent replay", async () => {
    const s = await setupPaired({ ownerName: "Nishant" });
    await register(s.approver, APPROVER_TOKEN);
    const op = sendRequest(s, uniqueID("request"));
    await submitOperation(bytes(op));
    expect(fake.sent).toHaveLength(1);
    await submitOperation(bytes(op));
    expect(fake.sent).toHaveLength(1);
  });

  it("sends nothing when the operation fails", async () => {
    const s = await setupPaired({ ownerName: "Nishant" });
    await register(s.approver, APPROVER_TOKEN);
    // Wrong expectedRevision -> stale_revision, rolled back.
    const stale = buildOperation({ kind: "request", payload: requestPayload(s, uniqueID("request")), signer: s.owner, expectedRevision: 99 });
    await expect(submitOperation(bytes(stale))).rejects.toMatchObject({ code: "stale_revision" });
    expect(fake.sent).toHaveLength(0);
  });

  it("a throwing sender does not fail or change the operation", async () => {
    const s = await setupPaired({ ownerName: "Nishant" });
    await register(s.approver, APPROVER_TOKEN);
    fake.behavior = () => {
      throw new Error("boom");
    };
    const response = await submitOperation(bytes(sendRequest(s, uniqueID("request"))));
    expect(response.result.kind).toBe("request");
    expect(response.revision).toBe(7);
  });

  it("a hanging sender is cut off by the time budget and the operation still succeeds", async () => {
    const s = await setupPaired({ ownerName: "Nishant" });
    await register(s.approver, APPROVER_TOKEN);
    fake.behavior = () => new Promise<PushResult>(() => undefined);
    setPushTimeoutForTesting(150);
    const started = Date.now();
    const response = await submitOperation(bytes(sendRequest(s, uniqueID("request"))));
    expect(response.result.kind).toBe("request");
    expect(Date.now() - started).toBeLessThan(2_000);
    expect(fake.closed).toBeGreaterThan(0);
  });

  it("push is disabled (no-op) when the APNs env vars are missing", async () => {
    setPushSenderForTesting(undefined);
    const saved = { p: process.env.APNS_KEY_P8, k: process.env.APNS_KEY_ID, t: process.env.APNS_TEAM_ID };
    delete process.env.APNS_KEY_P8;
    delete process.env.APNS_KEY_ID;
    delete process.env.APNS_TEAM_ID;
    try {
      expect(apnsConfigFromEnv()).toBeNull();
      const s = await setupPaired({ ownerName: "Nishant" });
      await register(s.approver, APPROVER_TOKEN);
      const response = await submitOperation(bytes(sendRequest(s, uniqueID("request"))));
      expect(response.result.kind).toBe("request");
      expect(await dispatchPush(testPool(), [{ identityID: s.approver.identity.identityID, message: { title: "x", body: "y", kind: "request" } }])).toEqual({ sent: 0, failed: 0, pruned: 0 });
      // Partially configured is still disabled.
      process.env.APNS_KEY_ID = "KEY";
      expect(apnsConfigFromEnv()).toBeNull();
    } finally {
      if (saved.p !== undefined) process.env.APNS_KEY_P8 = saved.p;
      if (saved.k !== undefined) process.env.APNS_KEY_ID = saved.k;
      else delete process.env.APNS_KEY_ID;
      if (saved.t !== undefined) process.env.APNS_TEAM_ID = saved.t;
    }
  });
});

describe("token pruning", () => {
  it("prunes a token the sender reports invalid (410 / BadDeviceToken) and keeps the others", async () => {
    const s = await setupPaired({ ownerName: "Nishant" });
    const bad = hexToken("de");
    const good = hexToken("90");
    await register(s.approver, bad);
    await register(s.approver, good);
    fake.behavior = (target) => (target.token === bad ? "invalid_token" : "sent");
    await submitOperation(bytes(sendRequest(s, uniqueID("request"))));
    expect((await rows(s.approver.identity.identityID)).map((r) => r.token)).toEqual([good]);
  });

  it("keeps a token when the send merely failed", async () => {
    const s = await setupPaired({ ownerName: "Nishant" });
    await register(s.approver, APPROVER_TOKEN);
    fake.behavior = () => "failed";
    await submitOperation(bytes(sendRequest(s, uniqueID("request"))));
    expect(await rows(s.approver.identity.identityID)).toHaveLength(1);
  });
});

describe("APNs provider token and payload", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
  const config = { keyP8: pem, keyID: "ABC123DEFG", teamID: "ABCDE12345", topic: "com.phone-lockbox.app" };

  it("builds an ES256 JWT with the right header and claims that verifies with the public key", () => {
    const jwt = buildApnsJWT(config, 1_800_000_000);
    const [h, c, sig] = jwt.split(".") as [string, string, string];
    expect(JSON.parse(Buffer.from(h, "base64url").toString())).toEqual({ alg: "ES256", kid: "ABC123DEFG" });
    expect(JSON.parse(Buffer.from(c, "base64url").toString())).toEqual({ iss: "ABCDE12345", iat: 1_800_000_000 });
    const signature = Buffer.from(sig, "base64url");
    expect(signature).toHaveLength(64);
    expect(cryptoVerify("sha256", Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, signature)).toBe(true);
    expect(cryptoVerify("sha256", Buffer.from(`${h}.${c}x`), { key: publicKey, dsaEncoding: "ieee-p1363" }, signature)).toBe(false);
  });

  it("caches the JWT for 50 minutes then refreshes", () => {
    resetApnsJWTCacheForTesting();
    const first = cachedApnsJWT(config, 1_800_000_000);
    expect(cachedApnsJWT(config, 1_800_000_000 + 49 * 60)).toBe(first);
    const refreshed = cachedApnsJWT(config, 1_800_000_000 + 51 * 60);
    expect(refreshed).not.toBe(first);
    resetApnsJWTCacheForTesting();
  });

  it("accepts a \\n-escaped PEM and defaults the topic", () => {
    const config2 = apnsConfigFromEnv({ APNS_KEY_P8: pem.trim().replace(/\n/g, "\\n"), APNS_KEY_ID: "K", APNS_TEAM_ID: "T" });
    expect(config2?.topic).toBe("com.phone-lockbox.app");
    expect(() => buildApnsJWT(config2!, 1_800_000_000)).not.toThrow();
    expect(apnsConfigFromEnv({ APNS_KEY_P8: pem, APNS_KEY_ID: "K", APNS_TEAM_ID: "T", APNS_TOPIC: "x.y" })?.topic).toBe("x.y");
  });

  it("the payload has exactly the allowed keys and nothing identifying", () => {
    const payload = buildPushPayload({ title: "Sam", body: "Declined your request.", kind: "answer" });
    expect(Object.keys(payload).sort()).toEqual(["aps", "kind"]);
    expect(Object.keys(payload.aps).sort()).toEqual(["alert", "sound", "thread-id"]);
    expect(Object.keys(payload.aps.alert).sort()).toEqual(["body", "title"]);
    expect(payload).toEqual({ aps: { alert: { title: "Sam", body: "Declined your request." }, sound: "default", "thread-id": "companion" }, kind: "answer" });
  });
});

describe("push token retention", () => {
  it("the purge sweep deletes tokens not refreshed for 90 days and keeps newer ones", async () => {
    const owner = makeIdentity("owner");
    const t = nowSec();
    await register(owner, hexToken("a1"));
    await register(owner, hexToken("b2"));
    await testPool().query(`UPDATE companion_push_token SET updated_at = $1 WHERE token = $2`, [t - 91 * 86_400, hexToken("a1")]);
    await testPool().query(`UPDATE companion_push_token SET updated_at = $1 WHERE token = $2`, [t - 89 * 86_400, hexToken("b2")]);
    const summary = await purgeExpiredRecords(testPool(), 30, t);
    expect(summary.purgedPushTokens).toBe(1);
    expect((await rows(owner.identity.identityID)).map((r) => r.token)).toEqual([hexToken("b2")]);
  });
});
