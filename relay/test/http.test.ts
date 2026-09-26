// HTTP-layer tests: status codes and the `{ "error": "<code>" }` error body
// shape, exercised through the actual Web Request/Response handlers
// (relay/src/handlers.ts) rather than calling service.ts directly. Business
// logic (authorization, reducer semantics) is covered in lifecycle.test.ts;
// this file only checks the HTTP adapter.

import { describe, it, expect } from "vitest";
import { handleOperations, handleInbox, handleHealth } from "../src/handlers.js";
import { makeIdentity, buildOperation } from "./setup.js";
import { MAX_RAW_BODY_BYTES } from "../src/protocol.js";

function post(body: unknown, headers: Record<string, string> = {}): Request {
  const text = typeof body === "string" ? body : JSON.stringify(body);
  return new Request("http://127.0.0.1:8002/v1/operations", { method: "POST", body: text, headers: { "content-type": "application/json", ...headers } });
}

describe("GET /v1/health", () => {
  it("returns 200 { ok: true }", async () => {
    const response = await handleHealth(new Request("http://127.0.0.1:8002/v1/health"));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
  });
});

describe("POST /v1/operations HTTP status codes", () => {
  it("200 on a valid operation", async () => {
    const owner = makeIdentity("owner");
    const op = buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null });
    const response = await handleOperations(post(op));
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.result).toEqual({ acknowledgement: {} });
    expect(typeof body.ownerIdentityID).toBe("string");
    expect(typeof body.stateRoot).toBe("string");
  });

  it("400 malformed for structurally invalid JSON", async () => {
    const response = await handleOperations(post("not json"));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "malformed" });
  });

  it("401 invalid_signature for a tampered signature", async () => {
    const owner = makeIdentity("owner");
    const op = buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null }) as any;
    op.signature = Buffer.alloc(64, 9).toString("base64");
    const response = await handleOperations(post(op));
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "invalid_signature" });
  });

  it("405 for a non-POST method", async () => {
    const response = await handleOperations(new Request("http://127.0.0.1:8002/v1/operations", { method: "GET" }));
    expect(response.status).toBe(405);
  });

  it("413 payload_too_large for an oversized body", async () => {
    const owner = makeIdentity("owner");
    const op = buildOperation({ kind: "ack", payload: { pad: "x".repeat(MAX_RAW_BODY_BYTES + 1024) }, signer: owner, expectedRevision: null });
    const response = await handleOperations(post(op));
    expect(response.status).toBe(413);
    expect(await response.json()).toEqual({ error: "payload_too_large" });
  });

  it("413 payload_too_large when Content-Length lies about a small body but the actual body is oversized", async () => {
    const response = await handleOperations(post("x".repeat(MAX_RAW_BODY_BYTES + 1)));
    expect(response.status).toBe(413);
  });

  it("never echoes request content in an error body", async () => {
    const response = await handleOperations(post("some-very-specific-secret-token-marker"));
    const text = await response.text();
    expect(text).not.toContain("some-very-specific-secret-token-marker");
    expect(JSON.parse(text)).toEqual({ error: "malformed" });
  });
});

describe("POST /v1/inbox", () => {
  it("200 with an owner's own inbox", async () => {
    const owner = makeIdentity("owner");
    await handleOperations(post(buildOperation({ kind: "ack", payload: {}, signer: owner, expectedRevision: null })));
    const inboxOp = buildOperation({ kind: "inbox", payload: { identityID: owner.identity.identityID }, signer: owner, expectedRevision: null });
    const response = await handleInbox(new Request("http://127.0.0.1:8002/v1/inbox", { method: "POST", body: JSON.stringify(inboxOp) }));
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(Array.isArray(body.requests)).toBe(true);
    expect(Array.isArray(body.pairings)).toBe(true);
    expect(Array.isArray(body.consents)).toBe(true);
  });

  it("405 for a non-POST method", async () => {
    const response = await handleInbox(new Request("http://127.0.0.1:8002/v1/inbox", { method: "GET" }));
    expect(response.status).toBe(405);
  });
});
