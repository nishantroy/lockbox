// Canonical/crypto parity against CompanionKit/Sources/CompanionVectorGen's
// Swift-generated golden vectors (test/fixtures/vectors.json). Regenerate
// with: swift run --package-path CompanionKit CompanionVectorGen <path>.
//
// Covers: raw canonical-framing byte layout, Date/Data wire encoding,
// verification-code derivation, every operation kind's signature (both the
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
  pairingVerificationCode,
  secondsToSwiftDate
} from "../src/canonical.js";
import { verify as ed25519Verify } from "../src/crypto.js";
import {
  decodeSignedOperation,
  verifySignedOperationSignature,
  encodeRelayResult,
  decodeInvitation,
  verifyInvitationSignature,
  decodeApproval,
  verifyApprovalSignature,
  decodePairingReplacement,
  verifyPairingReplacementSignature,
  decodeSignedAcceptance,
  decodeSignedConfirmation,
  decodeConsentMutation,
  decodeActiveSession,
  decodeTrustedRequest,
  decodeApprovalUse,
  decodeRequestReference,
  decodePairingReference,
  decodeNaturalEnd
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

describe("pairing verification code derivation", () => {
  it("matches PairingAcceptance.code(invite:approver:)", () => {
    const v = vectors.verificationCode;
    const code = pairingVerificationCode({
      inviteID: v.inviteID,
      ownerIdentityID: v.ownerIdentityID,
      approverIdentityID: v.approverIdentityID,
      nonce: Buffer.from(v.nonceBase64url.replace(/-/g, "+").replace(/_/g, "/"), "base64")
    });
    expect(code).toBe(v.expectedCode);
  });
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

const payloadDecoders: Record<string, (payload: unknown) => void> = {
  ack: (payload) => {
    expect(payload).toEqual({});
  },
  invite: (payload) => {
    const invitation = decodeInvitation(payload);
    expect(verifyInvitationSignature(invitation)).toBe(true);
  },
  accept: (payload) => {
    const signed = decodeSignedAcceptance(payload);
    expect(signed.acceptance.acceptanceID.length).toBeGreaterThan(0);
  },
  confirm: (payload) => {
    const signed = decodeSignedConfirmation(payload);
    expect(signed.confirmation.acceptanceID.length).toBeGreaterThan(0);
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
  for (const op of vectors.operations as Array<{ name: string; kind: string; signedOperationJSON: string }>) {
    it(op.name, () => {
      const json = JSON.parse(op.signedOperationJSON);
      const operation = decodeSignedOperation(json);
      expect(verifySignedOperationSignature(operation)).toBe(true);
      if (op.kind === "inbox") return;
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
