// Ed25519 signing/verification using only Node's built-in `node:crypto`
// (no third-party crypto dependency, per the R5 relay plan). CryptoKit's
// `Curve25519.Signing` is Ed25519 with 32-byte raw keys; Node's `crypto`
// module supports importing/exporting raw 32-byte Ed25519 keys via the JWK
// "OKP"/"Ed25519" representation (RFC 8037), which this module uses so no
// DER/PKCS8 wrapping code is needed.

import { createPrivateKey, createPublicKey, sign as nodeSign, verify as nodeVerify, generateKeyPairSync, type KeyObject } from "node:crypto";
import { base64url, fromBase64url } from "./canonical.js";

export interface Ed25519KeyPair {
  publicKey: Buffer;
  privateKeySeed: Buffer;
}

export function generateEd25519KeyPair(): Ed25519KeyPair {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const publicJwk = publicKey.export({ format: "jwk" }) as { x: string };
  const privateJwk = privateKey.export({ format: "jwk" }) as { d: string };
  return {
    publicKey: fromBase64url(publicJwk.x),
    privateKeySeed: fromBase64url(privateJwk.d)
  };
}

function publicKeyObject(rawPublicKey: Buffer): KeyObject {
  if (rawPublicKey.length !== 32) throw new Error("invalid Ed25519 public key length");
  return createPublicKey({
    key: { kty: "OKP", crv: "Ed25519", x: base64url(rawPublicKey) },
    format: "jwk"
  });
}

function privateKeyObject(rawSeed: Buffer, rawPublicKey: Buffer): KeyObject {
  if (rawSeed.length !== 32) throw new Error("invalid Ed25519 private key length");
  return createPrivateKey({
    key: { kty: "OKP", crv: "Ed25519", d: base64url(rawSeed), x: base64url(rawPublicKey) },
    format: "jwk"
  });
}

/** Derives the raw 32-byte Ed25519 public key from a raw 32-byte private seed. */
export function publicKeyFromSeed(rawSeed: Buffer): Buffer {
  if (rawSeed.length !== 32) throw new Error("invalid Ed25519 private key length");
  // Node can derive the public half via a private-key JWK export once the
  // key object exists; JWK import requires both d and x for a *private* key,
  // so build via PKCS8 DER instead, which only needs the seed.
  const pkcs8Prefix = Buffer.from("302e020100300506032b657004220420", "hex");
  const der = Buffer.concat([pkcs8Prefix, rawSeed]);
  const key = createPrivateKey({ key: der, format: "der", type: "pkcs8" });
  const publicKey = createPublicKey(key);
  const jwk = publicKey.export({ format: "jwk" }) as { x: string };
  return fromBase64url(jwk.x);
}

export function sign(message: Buffer, rawSeed: Buffer, rawPublicKey: Buffer): Buffer {
  const key = privateKeyObject(rawSeed, rawPublicKey);
  // `algorithm` must be `null` for Ed25519 (PureEdDSA, one-shot sign/verify).
  return nodeSign(null, message, key);
}

export function verify(message: Buffer, signature: Buffer, rawPublicKey: Buffer): boolean {
  if (signature.length !== 64 || rawPublicKey.length !== 32) return false;
  try {
    const key = publicKeyObject(rawPublicKey);
    return nodeVerify(null, message, key, signature);
  } catch {
    return false;
  }
}
