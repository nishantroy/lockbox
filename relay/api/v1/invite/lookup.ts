// Vercel Node function: `POST /v1/invite/lookup` (pairing v3). See
// relay/src/handlers.ts / relay/src/service.ts `lookupInvite` and
// docs/r5-relay-plan.md's HTTP API table.

import { handleInviteLookup } from "../../../src/handlers.js";

export const config = { runtime: "nodejs" };

export async function POST(request: Request): Promise<Response> {
  return handleInviteLookup(request);
}
