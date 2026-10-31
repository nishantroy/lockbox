// Canonical/crypto parity against CompanionKit/Sources/CompanionVectorGen's
// Swift-generated golden vectors (test/fixtures/vectors.json). Regenerate
// with: swift run --package-path CompanionKit CompanionVectorGen <path>.
//
// Covers: raw canonical-framing byte layout, Date/Data wire encoding,
// invite-token hash derivation, every operation kind's signature (both the
// enveloped legacy-reference form and the raw form real clients actually
// send), tampered/cross-domain/wrong-key rejection, and the exact
// Swift-synthesized `RelayResult`/`RelayResponse`/`InboxResponse` JSON shape.

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  canonicalBytes,
  deviceIdentityID,
  inviteTokenHash,
  inviteLookupKey,
  acceptanceProof,
  isWellFormedInviteToken,
  secondsToSwiftDate
} from "../src/canonical.js";
import { verify as ed25519Verify, invitePossessionKeyPair } from "../src/crypto.js";
import {
  decodeSignedOperation,
  verifySignedOperationSignature,
  encodeRelayResult,
  encodeInboxResponse,
  decodeInvitation,
  encodeInvitation,
  verifyInvitationSignature,
  decodeApproval,
  verifyApprovalSignature,
  decodePairingReplacement,
  verifyPairingReplacementSignature,
  decodeSignedAcceptance,
  verifySignedAcceptanceSignature,
  verifyAcceptancePossession,
  encodeSignedAcceptance,
  decodePairing,
  encodePairing,
  encodeInviteLookupResponse,
  decodeConsentMutation,
  decodeActiveSession,
  decodeTrustedRequest,
  decodeApprovalUse,
  decodeRequestReference,
  decodePairingReference,
  decodeNaturalEnd,
  decodeInboxQuery
} from "../src/protocol.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(readFileSync(join(__dirname, "fixtures", "vectors.json"), "utf8"));

describe("canonical framing byte-for-byte parity", () => {
  for (const v of vectors.framing as Array<{ domain: string; fields: string[]; expectedBytesBase64: string }>) {
    it(`matches Swift for domain=${v.domain} fields=${JSON.stringify(v.fields)}`, () => {
      const bytes = canonicalBytes(v.domain, v.fields);
      expect(bytes.toString("base64")).toBe(v.expectedBytesBase64);
    });
  }
});

describe("Date/Data wire encoding parity", () => {
  it("Date encodes as seconds-since-reference-date (Foundation's default Codable behavior)", () => {
    const sample = vectors.encodingSamples.date;
    const encoded = JSON.parse(sample.encodedJSON);
    expect(secondsToSwiftDate(sample.unixSeconds)).toBe(encoded.date);
  });

  it("Data encodes as standard base64 (not base64url)", () => {
    const sample = vectors.encodingSamples.data;
    const encoded = JSON.parse(sample.encodedJSON);
    expect(Buffer.from(sample.inputBytesBase64, "base64").toString("base64")).toBe(encoded.data);
  });
});

describe("identity ID derivation", () => {
  it("matches DeviceIdentity.makeID for every fixture identity", () => {
    for (const [, identity] of Object.entries<any>(vectors.identities)) {
      const publicKey = Buffer.from(identity.publicKeyBase64, "base64");
      expect(deviceIdentityID(publicKey)).toBe(identity.identityID);
    }
  });
});

describe("invite token derivations (pairing v3)", () => {
  it("lookup key, invite token hash and acceptance proof match InviteToken in Swift", () => {
    const v = vectors.inviteToken;
    expect(isWellFormedInviteToken(v.token)).toBe(true);
    expect(v.token).toHaveLength(22);
    expect(inviteLookupKey(v.token).toString("base64")).toBe(v.lookupKeyBase64);
    expect(inviteTokenHash(v.token, Buffer.from(v.ownerPublicKeyBase64, "base64"), v.inviteID).toString("base64")).toBe(v.tokenHashBase64);
    expect(acceptanceProof(v.token, Buffer.from(v.approverPublicKeyBase64, "base64"), v.acceptanceID).toString("base64")).toBe(v.proofBase64);
    expect(invitePossessionKeyPair(v.token).publicKey.toString("base64")).toBe(v.possessionKeyBase64);
  });
});

describe("display names: Swift-signed invites with tricky names verify and round-trip in TS", () => {
  for (const entry of vectors.displayNameInvites as Array<{ label: string; name: string; invitationJSON: string }>) {
    it(entry.label, () => {
      const invitation = decodeInvitation(JSON.parse(entry.invitationJSON));
      expect(invitation.payload.ownerDisplayName).toBe(entry.name);
      expect(verifyInvitationSignature(invitation)).toBe(true);
      expect(encodeInvitation(invitation)).toEqual(JSON.parse(entry.invitationJSON));
    });
  }
});

describe("signature checks (generic crypto/domain-separation vectors)", () => {
  for (const check of vectors.signatureChecks as Array<{ label: string; canonicalBytesBase64: string; signatureBase64: string; publicKeyBase64: string; domain: string; fields: string[]; expectValid: boolean }>) {
    it(`${check.label} => expectValid=${check.expectValid}`, () => {
      const recomputedBytes = canonicalBytes(check.domain, check.fields);
      if (check.expectValid) {
        expect(recomputedBytes.toString("base64")).toBe(check.canonicalBytesBase64);
      }
      const ok = ed25519Verify(Buffer.from(check.canonicalBytesBase64, "base64"), Buffer.from(check.signatureBase64, "base64"), Buffer.from(check.publicKeyBase64, "base64"));
      expect(ok).toBe(check.expectValid);
    });
  }
});

function invitationPossessionKey(): Buffer {
  return Buffer.from(vectors.inviteToken.possessionKeyBase64, "base64");
}

const payloadDecoders: Record<string, (payload: unknown) => void> = {
  ack: (payload) => {
    expect(payload).toEqual({});
  },
  invite: (payload) => {
    const invitation = decodeInvitation(payload);
    expect(verifyInvitationSignature(invitation)).toBe(true);
    // The Swift-signed v3 invite covers the token hash, lookup key, owner name and granted scopes.
    expect(invitation.payload.tokenHash.toString("base64")).toBe(vectors.inviteToken.tokenHashBase64);
    expect(invitation.payload.lookupKey.toString("base64")).toBe(vectors.inviteToken.lookupKeyBase64);
    expect(invitation.payload.possessionKey.toString("base64")).toBe(vectors.inviteToken.possessionKeyBase64);
    expect(invitation.payload.ownerDisplayName).toBe("Alex");
    expect(invitation.payload.grantedScopes).toEqual(["approveEarlyEnd", "receiveRequests"]);
  },
  accept: (payload) => {
    const signed = decodeSignedAcceptance(payload);
    expect(signed.acceptance.acceptanceID.length).toBeGreaterThan(0);
    // The Swift-signed v3 acceptance verifies in TS and carries the token, name and scopes.
    expect(verifySignedAcceptanceSignature(signed)).toBe(true);
    expect(signed.acceptance.lookupKey.toString("base64")).toBe(vectors.inviteToken.lookupKeyBase64);
    expect(signed.acceptance.tokenProof.toString("base64")).toBe(vectors.inviteToken.proofBase64);
    // The Swift-made possession signature verifies against the Swift-derived possession key in TS.
    expect(verifyAcceptancePossession(signed.acceptance, invitationPossessionKey())).toBe(true);
    expect(signed.acceptance.approverDisplayName).toBe("Sam");
    expect(signed.acceptance.acceptedScopes).toEqual(["approveEarlyEnd", "receiveRequests"]);
  },
  consent: (payload) => {
    const mutation = decodeConsentMutation(payload);
    expect(mutation.pairingID.length).toBeGreaterThan(0);
  },
  session: (payload) => {
    const session = decodeActiveSession(payload);
    expect(session.sessionID.length).toBeGreaterThan(0);
  },
  request: (payload) => {
    const request = decodeTrustedRequest(payload);
    expect(request.requestID.length).toBeGreaterThan(0);
  },
  approval: (payload) => {
    const approval = decodeApproval(payload);
    expect(verifyApprovalSignature(approval)).toBe(true);
  },
  use: (payload) => {
    const use = decodeApprovalUse(payload);
    expect(use.useID.length).toBeGreaterThan(0);
  },
  cancel: (payload) => {
    const ref = decodeRequestReference(payload);
    expect(ref.requestID.length).toBeGreaterThan(0);
  },
  natural_end: (payload) => {
    const ref = decodeNaturalEnd(payload);
    expect(ref.sessionID.length).toBeGreaterThan(0);
  },
  revoke: (payload) => {
    const ref = decodePairingReference(payload);
    expect(ref.pairingID.length).toBeGreaterThan(0);
  },
  replace_pairing: (payload) => {
    const replacement = decodePairingReplacement(payload);
    expect(verifyPairingReplacementSignature(replacement)).toBe(true);
  }
};

describe("every operation kind: enveloped reference form decodes and verifies", () => {
  for (const op of vectors.operations as Array<{ name: string; kind: string; signedOperationJSON: string; decoded?: Record<string, unknown> }>) {
    it(op.name, () => {
      const json = JSON.parse(op.signedOperationJSON);
      const operation = decodeSignedOperation(json);
      expect(verifySignedOperationSignature(operation)).toBe(true);
      if (op.kind === "inbox") {
        const query = decodeInboxQuery(JSON.parse(operation.body.toString("utf8")));
        expect(query.identityID).toBe(op.decoded?.identityID);
        if (op.name === "inbox") {
          expect(query.issuedAt).toBeUndefined();
        } else if (op.name === "inbox_with_issued_at") {
          expect(query.issuedAt).toBeCloseTo(op.decoded?.issuedAtUnixSeconds as number, 3);
        }
        return;
      }
      const envelope = JSON.parse(operation.body.toString("utf8"));
      const payload = JSON.parse(Buffer.from(envelope.payload, "base64").toString("utf8"));
      payloadDecoders[op.kind]?.(payload);
    });
  }
});

describe("raw (actual client wire format) operations decode and verify", () => {
  for (const op of vectors.rawOperations as Array<{ name: string; kind: string; signedOperationJSON: string }>) {
    it(op.name, () => {
      const json = JSON.parse(op.signedOperationJSON);
      const operation = decodeSignedOperation(json);
      expect(verifySignedOperationSignature(operation)).toBe(true);
      payloadDecoders[op.kind]?.(JSON.parse(operation.body.toString("utf8")));
    });
  }

  it("raw_request_with_expected_revision_7 carries a non-null expectedRevision", () => {
    const op = (vectors.rawOperations as any[]).find((o) => o.name === "raw_request_with_expected_revision_7");
    const operation = decodeSignedOperation(JSON.parse(op.signedOperationJSON));
    expect(operation.expectedRevision).toBe(7);
  });

  it("raw_ack_no_expected_revision carries a null expectedRevision", () => {
    const op = (vectors.rawOperations as any[]).find((o) => o.name === "raw_ack_no_expected_revision");
    const operation = decodeSignedOperation(JSON.parse(op.signedOperationJSON));
    expect(operation.expectedRevision).toBeNull();
  });
});

describe("InboxResponse wire shape carries approvals (R5 Slice B2a, contract v1.2)", () => {
  it("an owner inbox sample's approvals array decodes and verifies against the fixture request", () => {
    const parsed = JSON.parse(vectors.inboxResponseSample);
    expect(Array.isArray(parsed.approvals)).toBe(true);
    expect(parsed.approvals).toHaveLength(1);
    const approval = decodeApproval(parsed.approvals[0]);
    expect(verifyApprovalSignature(approval)).toBe(true);
    expect(approval.decision).toBe("approved");
    const request = decodeTrustedRequest(parsed.requests[0]);
    expect(approval.requestID).toBe(request.requestID);
    expect(approval.sessionID).toBe(request.sessionID);
    expect(approval.activeSetID).toBe(request.activeSetID);
  });

  it("encodeInboxResponse reproduces the same approvals fields and values as the Swift vector", () => {
    const parsed = JSON.parse(vectors.inboxResponseSample);
    const approval = decodeApproval(parsed.approvals[0]);
    const request = decodeTrustedRequest(parsed.requests[0]);
    const encoded = encodeInboxResponse({
      ownerIdentityID: parsed.ownerIdentityID,
      stateRoot: undefined,
      revision: parsed.revision,
      requests: [request],
      pairings: [],
      consents: [],
      approvals: [approval]
    });
    // Key order differs (Swift's `.sortedKeys` vs. a TS object literal), but
    // every field and value must agree -- re-decoding either side through
    // `decodeApproval` and comparing proves the wire shape is equivalent,
    // not just textually identical.
    const reDecoded = decodeApproval((encoded as any).approvals[0]);
    expect(reDecoded).toEqual(approval);
  });

  it("a pure helper/approver inbox sample omits the approvals key entirely", () => {
    const parsed = JSON.parse(vectors.helperInboxResponseSample);
    expect(Object.prototype.hasOwnProperty.call(parsed, "approvals")).toBe(false);
  });
});

describe("InboxResponse wire shape carries pairings with names and acceptances (pairing v3, contract v1.4)", () => {
  it("an owner inbox sample's acceptances array decodes and verifies, and its pairing matches", () => {
    const parsed = JSON.parse(vectors.inboxResponseWithAcceptancesSample);
    expect(parsed.acceptances).toHaveLength(1);
    const signed = decodeSignedAcceptance(parsed.acceptances[0]);
    expect(verifySignedAcceptanceSignature(signed)).toBe(true);
    expect(signed.acceptance.acceptanceID).toBe("fixture-acceptance-01");
    const pairing = decodePairing(parsed.pairings[0]);
    expect(pairing.ownerDisplayName).toBe("Alex");
    expect(pairing.approverDisplayName).toBe("Sam");
    expect(pairing.approver.identityID).toBe(signed.acceptance.approver.identityID);
  });

  it("encodeInboxResponse reproduces the Swift vector's acceptances and pairings field for field", () => {
    const parsed = JSON.parse(vectors.inboxResponseWithAcceptancesSample);
    const signed = decodeSignedAcceptance(parsed.acceptances[0]);
    const pairing = decodePairing(parsed.pairings[0]);
    const request = decodeTrustedRequest(parsed.requests[0]);
    const encoded = encodeInboxResponse({
      ownerIdentityID: parsed.ownerIdentityID,
      stateRoot: undefined,
      revision: parsed.revision,
      requests: [request],
      pairings: [pairing],
      consents: [],
      acceptances: [signed]
    }) as any;
    expect(encoded.acceptances[0]).toEqual(parsed.acceptances[0]);
    expect(decodeSignedAcceptance(encoded.acceptances[0])).toEqual(signed);
    expect(encoded.pairings[0]).toEqual(parsed.pairings[0]);
  });

  it("a pure helper/approver inbox sample omits the acceptances key entirely", () => {
    const parsed = JSON.parse(vectors.helperInboxResponseSample);
    expect(Object.prototype.hasOwnProperty.call(parsed, "acceptances")).toBe(false);
  });

  it("the Swift-encoded pairing result round-trips through TS", () => {
    const parsed = JSON.parse(vectors.joinedPairingSample);
    const pairing = decodePairing(parsed.pairing._0);
    expect(encodePairing(pairing)).toEqual(parsed.pairing._0);
  });

  it("the Swift-encoded invite lookup response decodes and re-encodes identically", () => {
    const parsed = JSON.parse(vectors.inviteLookupResponseSample);
    const invitation = decodeInvitation(parsed.invitation);
    expect(verifyInvitationSignature(invitation)).toBe(true);
    expect(encodeInviteLookupResponse(invitation)).toEqual(parsed);
  });
});

describe("tampered/cross-domain/wrong-key operations are rejected", () => {
  for (const t of vectors.tamperedOperations as Array<{ label: string; signedOperationJSON: string; expectValid: boolean }>) {
    it(`${t.label} => rejected`, () => {
      let valid: boolean;
      try {
        const operation = decodeSignedOperation(JSON.parse(t.signedOperationJSON));
        valid = verifySignedOperationSignature(operation);
      } catch {
        valid = false;
      }
      expect(valid).toBe(t.expectValid);
    });
  }
});

describe("Ed25519 signature malleability / non-canonical encodings are rejected", () => {
  // Ed25519 signatures are `R || S` (32 + 32 bytes). A naive verifier that
  // only checks `[8][L]S = [8]R + [8][k]A` without also requiring `S < L`
  // (the group order) accepts an infinite family of malleable signatures
  // (S, S+L, S+2L, ...) for the same message/key -- a real (if here
  // low-impact, since nothing in this protocol keys off signature bytes)
  // class of Ed25519 implementation bugs. These vectors are generated here
  // rather than by CompanionVectorGen because malleability is a property of
  // the *verifier*, not something a well-formed Swift-signed vector would
  // ever exercise; what matters is proving Node's `crypto.verify` (which
  // this relay's Ed25519 verification is built on) rejects them.
  const L = Buffer.from("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010", "hex").subarray(0, 32);

  function addLittleEndian(a: Buffer, b: Buffer): Buffer {
    const out = Buffer.alloc(32);
    let carry = 0;
    for (let i = 0; i < 32; i += 1) {
      const sum = a[i]! + b[i]! + carry;
      out[i] = sum & 0xff;
      carry = sum >> 8;
    }
    return out;
  }

  it("rejects a signature with S replaced by S+L (non-canonical scalar)", async () => {
    const { generateEd25519KeyPair, sign, verify } = await import("../src/crypto.js");
    const kp = generateEd25519KeyPair();
    const message = Buffer.from("malleability-check", "utf8");
    const signature = sign(message, kp.privateKeySeed, kp.publicKey);
    expect(verify(message, signature, kp.publicKey)).toBe(true);

    const nonCanonicalS = addLittleEndian(signature.subarray(32, 64), L);
    const malleableSignature = Buffer.concat([signature.subarray(0, 32), nonCanonicalS]);
    expect(verify(message, malleableSignature, kp.publicKey)).toBe(false);
  });

  it("rejects a signature with an arbitrary out-of-range S", async () => {
    const { generateEd25519KeyPair, sign, verify } = await import("../src/crypto.js");
    const kp = generateEd25519KeyPair();
    const message = Buffer.from("malleability-check-2", "utf8");
    const signature = sign(message, kp.privateKeySeed, kp.publicKey);
    const garbageSignature = Buffer.concat([signature.subarray(0, 32), Buffer.alloc(32, 0xff)]);
    expect(verify(message, garbageSignature, kp.publicKey)).toBe(false);
  });
});

describe("decodeData rejects non-canonical base64", () => {
  it("rejects an unpadded base64 string that Swift's Data(base64Encoded:) would also reject", async () => {
    const { decodeData } = await import("../src/protocol.js");
    const properlyPadded = Buffer.from("hi", "utf8").toString("base64"); // "aGk="
    expect(properlyPadded.endsWith("=")).toBe(true);
    const unpadded = properlyPadded.replace(/=+$/, "");
    expect(() => decodeData(unpadded)).toThrow();
    expect(decodeData(properlyPadded).toString("utf8")).toBe("hi");
  });

  it("rejects a base64 string with stray characters", async () => {
    const { decodeData } = await import("../src/protocol.js");
    expect(() => decodeData("not base64!! @@")).toThrow();
  });
});

describe("RelayResult wire shape matches Swift's synthesized enum Codable", () => {
  it("acknowledgement encodes as {\"acknowledgement\":{}}", () => {
    expect(JSON.stringify(encodeRelayResult({ kind: "acknowledgement" }))).toBe(vectors.relayResultSamples.acknowledgement);
  });

  it("a single-associated-value case encodes as {case: {_0: value}}", () => {
    const parsed = JSON.parse(vectors.relayResultSamples.invitation);
    expect(Object.keys(parsed)).toEqual(["invitation"]);
    expect(Object.keys(parsed.invitation)).toEqual(["_0"]);
  });
});
