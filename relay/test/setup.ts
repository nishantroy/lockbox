// Shared test helpers: a real Postgres pool (started via `npm run db:start`),
// per-test cleanup, deterministic Ed25519 test identities, and small builders
// for constructing signed operations the way the real Swift clients do (raw
// payload body, `expectedRevision` used directly -- see protocol.ts's "Wire
// format note").

import { beforeAll, afterAll, afterEach } from "vitest";
import pg from "pg";
import { generateEd25519KeyPair, sign } from "../src/crypto.js";
import { deviceIdentityID, base64url, canonicalBytes, digest, COMPANION_VERSION, secondsToSwiftDate } from "../src/canonical.js";
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
  await p.query("TRUNCATE companion_operation, companion_retention_marker, companion_approver_pairing, companion_owner");
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
