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
 * Port of `PairingAcceptance.code(invite:approver:)`: a six-digit numeric
 * verification code derived from the invite/approver identity, not itself a
 * signature. See CompanionKit/Sources/CompanionKit/ProtocolModels.swift.
 */
export function pairingVerificationCode(params: {
  inviteID: string;
  ownerIdentityID: string;
  approverIdentityID: string;
  nonce: Buffer;
}): string {
  const bytes = canonicalBytes(`${COMPANION_VERSION}.pairing-code`, [
    params.inviteID,
    params.ownerIdentityID,
    params.approverIdentityID,
    base64url(params.nonce)
  ]);
  const hash = digest(bytes);
  const number = hash.subarray(0, 4).reduce((acc, byte) => ((acc << 8) | byte) >>> 0, 0) % 1_000_000;
  return String(number).padStart(6, "0");
}

export function randomNonce(size = 24): Buffer {
  // 24 bytes, matching CompanionKit's client-side nonce generation
  // (>= 16 and <= 64 bytes is the protocol's validity range).
  return Buffer.from(cryptoRandomBytes(size));
}
