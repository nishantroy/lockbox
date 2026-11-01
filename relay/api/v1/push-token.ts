// Vercel Node function: APNs device-token registration. See
// relay/src/handlers.ts and docs/r5-apns-plan.md "Wire contract".

import { handlePushToken } from "../../src/handlers.js";

export const config = { runtime: "nodejs" };

export async function POST(request: Request): Promise<Response> {
  return handlePushToken(request);
}
