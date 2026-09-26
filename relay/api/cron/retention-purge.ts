// Vercel Cron target (see relay/vercel.json's daily schedule). Vercel signs
// its own cron invocations with `Authorization: Bearer $CRON_SECRET`; this
// handler checks the same header/env var so the purge endpoint cannot be
// triggered by an arbitrary caller. `npm run retention:purge` can also hit
// this path directly with the same header for a manual/local run.

import { purgeExpiredRecords } from "../../src/retention.js";
import { getPool } from "../../src/db.js";

export const config = { runtime: "nodejs" };

export default async function handler(request: Request): Promise<Response> {
  const expected = process.env.CRON_SECRET;
  const authorization = request.headers.get("authorization");
  if (!expected || authorization !== `Bearer ${expected}`) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { "content-type": "application/json" } });
  }
  const retentionDays = Number(process.env.RETENTION_DAYS ?? "30");
  const summary = await purgeExpiredRecords(getPool(), retentionDays, Date.now() / 1000);
  return new Response(JSON.stringify({ ok: true, ...summary }), { status: 200, headers: { "content-type": "application/json" } });
}
