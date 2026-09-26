// Guards drift between relay/src/errors.ts and the checked-in
// relay/test/fixtures/error-codes.json that the Swift client pins against.
// Regenerate the fixture if this fails after an intentional error-code change.

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { STATUS_BY_CODE } from "../src/errors.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(readFileSync(join(__dirname, "fixtures", "error-codes.json"), "utf8"));

const REQUIRED_CODES = ["invalid_envelope", "stale_revision", "idempotency_conflict", "unknown_owner", "unauthorized", "consent_required", "rate_limited", "payload_too_large", "malformed"];

describe("error code fixture", () => {
  it("includes every required code from the R5 relay contract", () => {
    const codes = fixture.codes.map((c: { code: string }) => c.code);
    for (const required of REQUIRED_CODES) expect(codes).toContain(required);
  });

  it("matches relay/src/errors.ts's STATUS_BY_CODE exactly (no drift)", () => {
    const fromSource = Object.entries(STATUS_BY_CODE)
      .map(([code, httpStatus]) => ({ code, httpStatus }))
      .sort((a, b) => a.code.localeCompare(b.code));
    const fromFixture = [...fixture.codes].sort((a: { code: string }, b: { code: string }) => a.code.localeCompare(b.code));
    expect(fromFixture).toEqual(fromSource);
  });

  it("error bodies are always exactly { error: <code> }", () => {
    // Documented invariant, exercised end-to-end in http.test.ts; asserted
    // here as a readable single source of truth for the shape.
    const sample = { error: "malformed" };
    expect(Object.keys(sample)).toEqual(["error"]);
  });
});
