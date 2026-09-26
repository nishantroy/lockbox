// Vercel Node function using named HTTP-method exports with the Web
// `Request -> Response` signature (current Vercel Node runtime convention).
// See relay/src/handlers.ts for the shared implementation and
// docs/r5-relay-plan.md's HTTP API table for the contract.

import { handleInbox } from "../../src/handlers.js";

export const config = { runtime: "nodejs" };

export async function POST(request: Request): Promise<Response> {
  return handleInbox(request);
}
