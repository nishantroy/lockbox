// Port of CompanionKit's `CompanionCanonical` (CompanionKit/Sources/CompanionKit/CompanionKit.swift).
//
// This module intentionally mirrors that Swift file's algorithms exactly:
//   - `canonicalBytes` == `CompanionCanonical.bytes(domain:fields:)`
//   - `sha256` / `digest` == `CompanionCanonical.digest`
//   - `base64url` / `fromBase64url` == the package-internal `base64URL` /
//     `dataFromBase64URL` free functions
//   - `swiftDateToSeconds` / `secondsToSwiftDate` encode Foundation's default
//     `Date: Codable` conformance (seconds since the 2001-01-01 reference
//     date), which Swift's `JSONEncoder` uses whenever no
//     `dateEncodingStrategy` is set -- exactly the case throughout
//     CompanionKit/CompanionRelayService.
//
// Byte-for-byte parity with these functions is verified in
// test/vectors.test.ts against CompanionKit/Sources/CompanionVectorGen's
// generated fixtures (relay/test/fixtures/vectors.json).

import { createHash, randomBytes as cryptoRandomBytes } from "node:crypto";

export const COMPANION_VERSION = "PhoneLockbox.Companion.v1";

/** Foundation's reference date (2001-01-01T00:00:00Z) in Unix seconds. */
export const SWIFT_DATE_REFERENCE_OFFSET_SECONDS = 978_307_200;

export function swiftDateToSeconds(referenceSeconds: number): number {
  return referenceSeconds + SWIFT_DATE_REFERENCE_OFFSET_SECONDS;
}

export function secondsToSwiftDate(unixSeconds: number): number {
  return unixSeconds - SWIFT_DATE_REFERENCE_OFFSET_SECONDS;
}

function lengthPrefixed(data: Buffer): Buffer {
  const length = Buffer.alloc(8);
  // Swift's `UInt64(value.count).bigEndian` written as raw bytes.
  length.writeBigUInt64BE(BigInt(data.length));
  return Buffer.concat([length, data]);
}

/** Port of `CompanionCanonical.bytes(domain:fields:)`. */
export function canonicalBytes(domain: string, fields: readonly string[]): Buffer {
  const chunks: Buffer[] = [lengthPrefixed(Buffer.from(domain, "utf8"))];
  for (const field of fields) {
    chunks.push(lengthPrefixed(Buffer.from(field, "utf8")));
  }
  return Buffer.concat(chunks);
}

/** Port of `CompanionCanonical.framed(domain:fields:)` (Data fields, not strings). */
export function canonicalFramed(domain: string, fields: readonly Buffer[]): Buffer {
  const chunks: Buffer[] = [lengthPrefixed(Buffer.from(domain, "utf8"))];
  for (const field of fields) {
    chunks.push(lengthPrefixed(field));
  }
  return Buffer.concat(chunks);
}

/** Port of `CompanionCanonical.digest(_:)`. */
export function digest(data: Buffer): Buffer {
  return createHash("sha256").update(data).digest();
}

/** Port of the package-internal `base64URL(_:)` helper (standard base64, URL-safe, unpadded). */
export function base64url(data: Buffer): string {
  return data.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Port of the package-internal `dataFromBase64URL(_:)` helper. */
export function fromBase64url(value: string): Buffer {
  if (value.length > 16_384) throw new Error("base64url value too long");
  let text = value.replace(/-/g, "+").replace(/_/g, "/");
  const pad = (4 - (text.length % 4)) % 4;
  text += "=".repeat(pad);
  return Buffer.from(text, "base64");
}

/** Port of the package-internal `milliseconds(_:)` helper: decimal integer milliseconds since Unix epoch. */
export function millisecondsString(unixSeconds: number): string {
  return String(Math.round(unixSeconds * 1_000));
}

/** Port of `DeviceIdentity.makeID(_:)`: base64url(SHA-256(publicKey)) truncated to 32 characters. */
export function deviceIdentityID(publicKey: Buffer): string {
  return base64url(digest(publicKey)).slice(0, 32);
}

/**
 * Pairing v3 (docs/r5-pairing-v3-plan.md): the invite token is a random
 * 128-bit value, 22 base64url characters, and it NEVER reaches the relay.
 * Three domain-separated values derive from it (must match `InviteToken` in
 * CompanionKit):
 *   - lookupKey  = H("invite-lookup", token): the only thing the relay stores
 *     or is asked for. Anyone with the link can compute it; the relay cannot
 *     invert it.
 *   - tokenHash  = H("invite-token", token, ownerPublicKey, inviteID): signed
 *     into the invite. Only a token holder can recompute it, so a friend can
 *     tell the invite was issued by that owner for that token, and a relay
 *     that knows only the lookup key cannot forge or swap an invite.
 *   - possession keypair = Ed25519 from seed H("invite-possession", token): the
 *     public key is signed into the invite and the acceptance carries a signature
 *     by the private key, which the RELAY verifies before consuming the invite.
 *   - proof      = H("accept-proof", token, approverPublicKey, acceptanceID):
 *     carried in the acceptance; only a token holder can compute it, so the
 *     owner can tell the acceptance came from the link holder, not the relay.
 */
export const INVITE_TOKEN_LENGTH = 22;
const INVITE_TOKEN_PATTERN = /^[A-Za-z0-9_-]{22}$/;
const LOOKUP_KEY_PATTERN = /^[A-Za-z0-9_-]{43}$/;

export function isWellFormedInviteToken(token: unknown): token is string {
  return typeof token === "string" && INVITE_TOKEN_PATTERN.test(token);
}

/** A lookup key on the wire: base64url, unpadded, of 32 bytes. */
export function isWellFormedLookupKey(value: unknown): value is string {
  return typeof value === "string" && LOOKUP_KEY_PATTERN.test(value);
}

export function inviteLookupKey(token: string): Buffer {
  return digest(canonicalBytes(`${COMPANION_VERSION}.invite-lookup`, [token]));
}

export function inviteTokenHash(token: string, ownerPublicKey: Buffer, inviteID: string): Buffer {
  return digest(canonicalBytes(`${COMPANION_VERSION}.invite-token`, [token, base64url(ownerPublicKey), inviteID]));
}

export function acceptanceProof(token: string, approverPublicKey: Buffer, acceptanceID: string): Buffer {
  return digest(canonicalBytes(`${COMPANION_VERSION}.accept-proof`, [token, base64url(approverPublicKey), acceptanceID]));
}

/** Seed of the token-derived possession keypair: H("invite-possession", token). */
export function invitePossessionSeed(token: string): Buffer {
  return digest(canonicalBytes(`${COMPANION_VERSION}.invite-possession`, [token]));
}

export function generateInviteToken(): string {
  return base64url(cryptoRandomBytes(16));
}

export function randomNonce(size = 24): Buffer {
  // 24 bytes, matching CompanionKit's client-side nonce generation
  // (>= 16 and <= 64 bytes is the protocol's validity range).
  return Buffer.from(cryptoRandomBytes(size));
}
