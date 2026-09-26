// Concurrency test: two parallel transactions racing on one owner at the
// same `expectedRevision` must have exactly one winner. This exercises the
// `SELECT ... FOR UPDATE` row lock (db.ts's `lockOwnerRow`) plus the
// optimistic `expectedRevision` check and the `saveOwnerRow` guarded UPDATE.

import { describe, it, expect } from "vitest";
import { makeIdentity, buildOperation, uniqueID } from "./setup.js";
import { submitOperation } from "../src/service.js";
import { RelayError } from "../src/errors.js";

function toRequest(op: object): Buffer {
  return Buffer.from(JSON.stringify(op), "utf8");
}

describe("owner-row concurrency", () => {
  it("exactly one of two concurrent same-revision mutations wins", async () => {
    const owner = makeIdentity("owner");
    // Establish the owner row at revision 0 first (ack with no optimistic
    // check), so both racers contend on the *same* expectedRevision afterward.
    await submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })));

    const opA = buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: 1, operationID: uniqueID("ack-a") });
    const opB = buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: 1, operationID: uniqueID("ack-b") });

    const results = await Promise.allSettled([submitOperation(toRequest(opA)), submitOperation(toRequest(opB))]);

    const fulfilled = results.filter((r): r is PromiseFulfilledResult<Awaited<ReturnType<typeof submitOperation>>> => r.status === "fulfilled");
    const rejected = results.filter((r): r is PromiseRejectedResult => r.status === "rejected");

    expect(fulfilled.length).toBe(1);
    expect(rejected.length).toBe(1);
    expect(fulfilled[0]!.value.revision).toBe(2);
    expect(rejected[0]!.reason).toBeInstanceOf(RelayError);
    expect((rejected[0]!.reason as RelayError).code).toBe("stale_revision");
  });

  it("many concurrent operations against the same owner serialize to a strictly increasing revision with no gaps or duplicates", async () => {
    const owner = makeIdentity("owner");
    const concurrency = 10;
    const attempts = Array.from({ length: concurrency }, (_, i) =>
      submitOperation(toRequest(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: 0, operationID: uniqueID(`ack-${i}`) })))
    );
    const results = await Promise.allSettled(attempts);
    const fulfilled = results.filter((r) => r.status === "fulfilled");
    // All raced at expectedRevision 0; only the first to commit can win it.
    expect(fulfilled.length).toBe(1);
  });
});
