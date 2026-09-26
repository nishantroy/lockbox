// Local dev server serving the same Web `Request -> Response` handlers Vercel
// would call, on a plain `node:http` server. No Vercel CLI/login needed for
// local development.
//
// Binds 127.0.0.1:8002 explicitly (loopback only) -- reserved for
// "phone-lockbox relay" in /Users/nishantroy/code/AGENTS.md's local HTTP
// port registry. Checked with `lsof -nP -iTCP:8002 -sTCP:LISTEN` before
// startup, per that registry's process.

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { handleOperations, handleInbox, handleHealth } from "../src/handlers.js";
import { closePool } from "../src/db.js";

const HOST = process.env.RELAY_HOST ?? "127.0.0.1";
const PORT = Number(process.env.RELAY_PORT ?? "8002");

type RouteHandler = (request: Request) => Promise<Response>;

const routes: Record<string, RouteHandler> = {
  "/v1/operations": handleOperations,
  "/v1/inbox": handleInbox,
  "/v1/health": handleHealth
};

async function toWebRequest(req: IncomingMessage, url: string): Promise<Request> {
  const headers = new Headers();
  for (const [key, value] of Object.entries(req.headers)) {
    if (typeof value === "string") headers.set(key, value);
    else if (Array.isArray(value)) headers.set(key, value.join(", "));
  }
  const hasBody = req.method !== "GET" && req.method !== "HEAD";
  let body: Buffer | undefined;
  if (hasBody) {
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
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
