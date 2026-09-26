// Vercel Node function (Web `Request -> Response` signature). See
// relay/src/handlers.ts for the shared implementation and
// docs/r5-relay-plan.md's HTTP API table for the contract.

import { handleHealth } from "../../src/handlers.js";

export const config = { runtime: "nodejs" };

export default function handler(request: Request): Promise<Response> {
  return handleHealth(request);
}
