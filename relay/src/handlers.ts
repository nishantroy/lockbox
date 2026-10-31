// Shared Web `Request -> Response` handlers for the three v1 endpoints. Used
// directly by relay/api/v1/*.ts (Vercel Node functions) and by
// relay/scripts/dev-server.ts (a plain Node http server that adapts to/from
// these Web Fetch types), so the two deployment targets share one code path.
//
// Privacy: never log request bodies, public keys, or identifiers beyond an
// opaque request id (docs/r5-relay-plan.md). Error bodies are always
// `{ "error": "<code>" }`; nothing else is ever echoed back.

import { submitOperation, fetchInboxOperation, lookupInvite } from "./service.js";
import { encodeRelayResponse, encodeInboxResponse, encodeInviteLookupResponse, MAX_RAW_BODY_BYTES } from "./protocol.js";
import { isRelayError } from "./errors.js";

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" }
  });
}

function errorResponse(error: unknown): Response {
  if (isRelayError(error)) return json(error.status, { error: error.code });
  // Never leak internals (stack traces, messages) to the client.
  return json(500, { error: "internal" });
}

/**
 * Vercel sets `x-forwarded-for` at the edge; the first entry is the actual
 * client (subsequent entries are intermediate proxies). `scripts/dev-server.ts`
 * sets this same header from the raw socket address for local dev, so this
 * extraction is uniform across both deployment targets and never needs its
 * own "look at the socket" fallback here.
 */
function clientIPFromRequest(request: Request): string | null {
  const header = request.headers.get("x-forwarded-for");
  if (!header) return null;
  const first = header.split(",")[0]?.trim();
  return first && first.length > 0 ? first : null;
}

async function readBody(request: Request): Promise<Buffer> {
  const contentLength = request.headers.get("content-length");
  if (contentLength && Number(contentLength) > MAX_RAW_BODY_BYTES) {
    throw Object.assign(new Error("payload_too_large"), { __oversized: true });
  }
  const arrayBuffer = await request.arrayBuffer();
  if (arrayBuffer.byteLength > MAX_RAW_BODY_BYTES) {
    throw Object.assign(new Error("payload_too_large"), { __oversized: true });
  }
  return Buffer.from(arrayBuffer);
}

export async function handleOperations(request: Request): Promise<Response> {
  if (request.method !== "POST") return json(405, { error: "malformed" });
  try {
    const body = await readBody(request);
    const response = await submitOperation(body, undefined, clientIPFromRequest(request));
    return json(200, encodeRelayResponse(response));
  } catch (error) {
    if (error instanceof Error && (error as { __oversized?: boolean }).__oversized) {
      return json(413, { error: "payload_too_large" });
    }
    return errorResponse(error);
  }
}

export async function handleInbox(request: Request): Promise<Response> {
  if (request.method !== "POST") return json(405, { error: "malformed" });
  try {
    const body = await readBody(request);
    const response = await fetchInboxOperation(body, undefined, clientIPFromRequest(request));
    return json(200, encodeInboxResponse(response));
  } catch (error) {
    if (error instanceof Error && (error as { __oversized?: boolean }).__oversized) {
      return json(413, { error: "payload_too_large" });
    }
    return errorResponse(error);
  }
}

/** Pairing v3: unauthenticated, rate-limited invite lookup by bearer token. */
export async function handleInviteLookup(request: Request): Promise<Response> {
  if (request.method !== "POST") return json(405, { error: "malformed" });
  try {
    const body = await readBody(request);
    const invitation = await lookupInvite(body, undefined, clientIPFromRequest(request));
    return json(200, encodeInviteLookupResponse(invitation));
  } catch (error) {
    if (error instanceof Error && (error as { __oversized?: boolean }).__oversized) {
      return json(413, { error: "payload_too_large" });
    }
    return errorResponse(error);
  }
}

export async function handleHealth(_request: Request): Promise<Response> {
  return json(200, { ok: true });
}
