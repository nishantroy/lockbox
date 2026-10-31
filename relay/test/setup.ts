// Shared test helpers: a real Postgres pool (started via `npm run db:start`),
// per-test cleanup, deterministic Ed25519 test identities, and small builders
// for constructing signed operations the way the real Swift clients do (raw
// payload body, `expectedRevision` used directly -- see protocol.ts's "Wire
// format note").

import { beforeAll, afterAll, afterEach } from "vitest";
import pg from "pg";
import { generateEd25519KeyPair, sign } from "../src/crypto.js";
import { deviceIdentityID, base64url, canonicalBytes, digest, COMPANION_VERSION, secondsToSwiftDate, inviteTokenHash, generateInviteToken } from "../src/canonical.js";
import type { DeviceIdentity, CompanionRole } from "../src/protocol.js";
import { migrate, closePool, resolveDatabaseURL } from "../src/db.js";

if (!process.env.DATABASE_URL) {
  process.env.DATABASE_URL = resolveDatabaseURL();
}

let pool: pg.Pool | undefined;

export function testPool(): pg.Pool {
  if (!pool) pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
  return pool;
}

beforeAll(async () => {
  await migrate(testPool());
});

afterEach(async () => {
  const p = testPool();
  await p.query("TRUNCATE companion_operation, companion_retention_marker, companion_approver_pairing, companion_invite_token, companion_owner");
});

afterAll(async () => {
  await testPool().end();
  await closePool();
});

export interface TestIdentity {
  identity: DeviceIdentity;
  privateKeySeed: Buffer;
}

export function makeIdentity(role: CompanionRole): TestIdentity {
  const { publicKey, privateKeySeed } = generateEd25519KeyPair();
  const identityID = deviceIdentityID(publicKey);
  return { identity: { identityID, role, publicKey }, privateKeySeed };
}

function signFields(identity: TestIdentity, domain: string, fields: string[]): Buffer {
  const bytes = canonicalBytes(domain, fields);
  return sign(bytes, identity.privateKeySeed, identity.identity.publicKey);
}

export function encodeDeviceIdentityWire(identity: DeviceIdentity): object {
  return { identityID: identity.identityID, role: identity.role, publicKey: identity.publicKey.toString("base64") };
}

export function swiftDate(unixSeconds: number): number {
  return secondsToSwiftDate(unixSeconds);
}

/**
 * Builds a `SignedOperation` exactly as the real Swift clients do: raw
 * payload body (no envelope), `operationID` derived the same way
 * `CompanionClient`'s private `operationIdentifier` does, and
 * `expectedRevision` sent as given (often `null`).
 */
export function buildOperation(params: { kind: string; payload: object; signer: TestIdentity; expectedRevision?: number | null; operationID?: string }): object {
  const bodyText = JSON.stringify(params.payload);
  const body = Buffer.from(bodyText, "utf8");
  const operationID = params.operationID ?? rawOperationID(params.kind, params.signer.identity, body);
  const expectedRevision = params.expectedRevision === undefined ? null : params.expectedRevision;
  const fields = [operationID, expectedRevision === null ? "none" : String(expectedRevision), params.kind, params.signer.identity.identityID, base64url(params.signer.identity.publicKey), base64url(digest(body))];
  const signature = signFields(params.signer, `${COMPANION_VERSION}.operation`, fields);
  return {
    operationID,
    ...(expectedRevision !== null ? { expectedRevision } : {}),
    kind: params.kind,
    signer: encodeDeviceIdentityWire(params.signer.identity),
    body: body.toString("base64"),
    signature: signature.toString("base64")
  };
}

function rawOperationID(kind: string, signer: DeviceIdentity, body: Buffer): string {
  const bytes = canonicalBytes(`${COMPANION_VERSION}.operation-id`, [kind, signer.identityID, base64url(digest(body))]);
  return base64url(digest(bytes)).slice(0, 32);
}

export function signPayloadFields(signer: TestIdentity, domain: string, fields: string[]): Buffer {
  return signFields(signer, domain, fields);
}

let counter = 0;
export function uniqueID(prefix: string): string {
  counter += 1;
  return `${prefix}-${Date.now()}-${counter}`;
}

// ---------------------------------------------------------------------------
// Pairing v3 builders (docs/r5-pairing-v3-plan.md)
// ---------------------------------------------------------------------------

export const ALL_R5_SCOPES = ["approveEarlyEnd", "receiveRequests"];

export interface BuiltInvite {
  inviteID: string;
  token: string;
  /** The wire `Invitation` (`{ payload, signature }`) exactly as the owner submits it. */
  invitation: { payload: Record<string, unknown>; signature: string };
}

/** Builds and owner-signs a v3 invite at explicit timestamps. `token` defaults to a fresh random one. */
export function buildInvite(
  owner: TestIdentity,
  now: number,
  opts: { inviteID?: string; token?: string; ttl?: number; ownerDisplayName?: string; grantedScopes?: string[]; nonce?: Buffer; tokenHash?: Buffer } = {}
): BuiltInvite {
  const inviteID = opts.inviteID ?? uniqueID("invite");
  const token = opts.token ?? generateInviteToken();
  const ttl = opts.ttl ?? 3600;
  const nonce = opts.nonce ?? Buffer.alloc(24, 7);
  const tokenHash = opts.tokenHash ?? inviteTokenHash(token);
  const grantedScopes = [...(opts.grantedScopes ?? ALL_R5_SCOPES)].sort();
  const fields = [
    inviteID,
    owner.identity.identityID,
    base64url(owner.identity.publicKey),
    String(Math.round(now * 1000)),
    String(Math.round((now + ttl) * 1000)),
    base64url(nonce),
    base64url(tokenHash),
    opts.ownerDisplayName ?? "",
    grantedScopes.join(",")
  ];
  const payload: Record<string, unknown> = {
    inviteID,
    owner: encodeDeviceIdentityWire(owner.identity),
    issuedAt: swiftDate(now),
    expiresAt: swiftDate(now + ttl),
    nonce: nonce.toString("base64"),
    tokenHash: tokenHash.toString("base64"),
    grantedScopes
  };
  if (opts.ownerDisplayName !== undefined) payload.ownerDisplayName = opts.ownerDisplayName;
  const signature = signFields(owner, `${COMPANION_VERSION}.invite.v3`, fields);
  return { inviteID, token, invitation: { payload, signature: signature.toString("base64") } };
}

/** Builds and approver-signs a v3 acceptance (`SignedAcceptance` wire shape). */
export function buildAcceptance(params: {
  owner: TestIdentity;
  approver: TestIdentity;
  inviteID: string;
  token: string;
  now: number;
  acceptanceID?: string;
  approverDisplayName?: string;
  acceptedScopes?: string[];
}): { acceptance: Record<string, unknown>; signature: string } {
  const acceptanceID = params.acceptanceID ?? uniqueID("acceptance");
  const acceptedScopes = [...(params.acceptedScopes ?? ALL_R5_SCOPES)].sort();
  const fields = [
    acceptanceID,
    params.inviteID,
    params.owner.identity.identityID,
    params.approver.identity.identityID,
    base64url(params.owner.identity.publicKey),
    base64url(params.approver.identity.publicKey),
    String(Math.round(params.now * 1000)),
    params.token,
    params.approverDisplayName ?? "",
    acceptedScopes.join(",")
  ];
  const acceptance: Record<string, unknown> = {
    acceptanceID,
    inviteID: params.inviteID,
    owner: encodeDeviceIdentityWire(params.owner.identity),
    approver: encodeDeviceIdentityWire(params.approver.identity),
    issuedAt: swiftDate(params.now),
    token: params.token,
    acceptedScopes
  };
  if (params.approverDisplayName !== undefined) acceptance.approverDisplayName = params.approverDisplayName;
  const signature = signFields(params.approver, `${COMPANION_VERSION}.acceptance.v3`, fields);
  return { acceptance, signature: signature.toString("base64") };
}

/**
 * Pairs `approver` with `owner` through the v3 flow (invite, then accept) and
 * returns the new pairing. The v2 flow used five revisions (invite, accept,
 * confirm, grant, accept) and left consent at generation 2; the v3 accept
 * produces generation 2 in one operation, and `legacyRevisionPad` (default 3)
 * owner-signed `ack`s keep the revision numbers hard-coded throughout the
 * older lifecycle suites unchanged. Pass 0 to see the true v3 revision count.
 */
export async function pairV3(params: {
  owner: TestIdentity;
  approver: TestIdentity;
  now: number;
  /** Server clock passed to `submitOperation`; omit to use the real clock. */
  clock?: number;
  startRevision?: number;
  legacyRevisionPad?: number;
  ownerDisplayName?: string;
  approverDisplayName?: string;
  nonceByte?: number;
}): Promise<{ pairingID: string; inviteID: string; token: string; nextRevision: number }> {
  const { submitOperation } = await import("../src/service.js");
  const send = (op: object) => submitOperation(Buffer.from(JSON.stringify(op), "utf8"), params.clock);
  let revision = params.startRevision ?? 0;
  const invite = buildInvite(params.owner, params.now, { ownerDisplayName: params.ownerDisplayName, nonce: Buffer.alloc(24, params.nonceByte ?? 7) });
  await send(buildOperation({ kind: "invite", payload: invite.invitation, signer: params.owner, expectedRevision: revision++ }));
  const accepted = buildAcceptance({
    owner: params.owner,
    approver: params.approver,
    inviteID: invite.inviteID,
    token: invite.token,
    now: params.now + 1,
    approverDisplayName: params.approverDisplayName
  });
  const response = await send(buildOperation({ kind: "accept", payload: accepted, signer: params.approver, expectedRevision: revision++ }));
  if (response.result.kind !== "pairing") throw new Error("accept did not return a pairing");
  for (let i = 0; i < (params.legacyRevisionPad ?? 3); i++) {
    await send(buildOperation({ kind: "ack", payload: {}, signer: params.owner, expectedRevision: revision++, operationID: uniqueID("pad") }));
  }
  return { pairingID: response.result.value.pairingID, inviteID: invite.inviteID, token: invite.token, nextRevision: revision };
}
