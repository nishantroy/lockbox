// Local dev server serving the same Web `Request -> Response` handlers Vercel
// would call, on a plain `node:http` server. No Vercel CLI/login needed for
// local development.
//
// Binds 127.0.0.1:8002 explicitly (loopback only) -- reserved for
// "phone-lockbox relay" in /Users/nishantroy/code/AGENTS.md's local HTTP
// port registry. Checked with `lsof -nP -iTCP:8002 -sTCP:LISTEN` before
// startup, per that registry's process.

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { handleOperations, handleInbox, handleInviteLookup, handleHealth } from "../src/handlers.js";
import { closePool } from "../src/db.js";
import { MAX_RAW_BODY_BYTES } from "../src/protocol.js";

/** Thrown by `toWebRequest` when a request body exceeds the size limit while still streaming in, so the caller can answer 413 without ever buffering the full (oversized) body. */
class PayloadTooLargeError extends Error {}

// Positive local opt-in required by the rate-limit overrides (src/db.ts `rateLimitMax`); only this script sets it.
process.env.RELAY_LOCAL_DEV = "1";

const HOST = process.env.RELAY_HOST ?? "127.0.0.1";
const PORT = Number(process.env.RELAY_PORT ?? "8002");

type RouteHandler = (request: Request) => Promise<Response>;

const routes: Record<string, RouteHandler> = {
  "/v1/operations": handleOperations,
  "/v1/inbox": handleInbox,
  "/v1/invite/lookup": handleInviteLookup,
  "/v1/health": handleHealth
};

async function toWebRequest(req: IncomingMessage, url: string): Promise<Request> {
  const headers = new Headers();
  for (const [key, value] of Object.entries(req.headers)) {
    if (typeof value === "string") headers.set(key, value);
    else if (Array.isArray(value)) headers.set(key, value.join(", "));
  }
  // Mirrors what Vercel's edge does for its functions: sets
  // `x-forwarded-for` from the real client address. A local dev client won't
  // send this header itself, so src/handlers.ts's `clientIPFromRequest` can
  // stay uniform across both deployment targets rather than needing its own
  // "fall back to the socket" special case.
  if (!headers.has("x-forwarded-for") && req.socket.remoteAddress) {
    headers.set("x-forwarded-for", req.socket.remoteAddress);
  }
  const hasBody = req.method !== "GET" && req.method !== "HEAD";
  let body: Buffer | undefined;
  if (hasBody) {
    const chunks: Buffer[] = [];
    let total = 0;
    for await (const chunk of req) {
      total += (chunk as Buffer).length;
      // Enforced while still streaming in, not after buffering the whole
      // body: an oversized (or effectively unbounded) request body must
      // never be fully accumulated in memory first just to then be rejected.
      // Deliberately does not destroy `req`/the socket here: it shares the
      // connection with `res`, and destroying it would prevent the 413
      // response below from ever reaching the client.
      if (total > MAX_RAW_BODY_BYTES) {
        throw new PayloadTooLargeError();
      }
      chunks.push(chunk as Buffer);
    }
    body = Buffer.concat(chunks);
  }
  const webBody = body && body.length > 0 ? new Uint8Array(body) : undefined;
  return new Request(url, { method: req.method, headers, body: webBody });
}

async function writeWebResponse(response: Response, res: ServerResponse): Promise<void> {
  res.statusCode = response.status;
  response.headers.forEach((value, key) => res.setHeader(key, value));
  const buffer = Buffer.from(await response.arrayBuffer());
  res.end(buffer);
}

const server = createServer((req, res) => {
  void (async () => {
    try {
      const url = `http://${HOST}:${PORT}${req.url ?? "/"}`;
      const path = new URL(url).pathname;
      const route = routes[path];
      if (!route) {
        res.statusCode = 404;
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ error: "not_found" }));
        return;
      }
      const request = await toWebRequest(req, url);
      const response = await route(request);
      await writeWebResponse(response, res);
    } catch (error) {
      if (error instanceof PayloadTooLargeError) {
        res.statusCode = 413;
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ error: "payload_too_large" }));
        return;
      }
      // Never echo internals; this path only handles adapter-level failures
      // (the handlers themselves already return typed error JSON).
      console.error("dev-server: unhandled adapter error");
      res.statusCode = 500;
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ error: "internal" }));
    }
  })();
});

server.listen(PORT, HOST, () => {
  console.log(`relay dev server listening on http://${HOST}:${PORT}`);
});

function shutdown() {
  server.close(() => {
    void closePool().finally(() => process.exit(0));
  });
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
