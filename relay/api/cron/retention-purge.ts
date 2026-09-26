// Vercel Cron target (see relay/vercel.json's daily schedule). Vercel Cron
// requests are GET by default and are signed with
// `Authorization: Bearer $CRON_SECRET`; this handler checks the same
// header/env var, compared in constant time, so the purge endpoint cannot be
// triggered (or have its secret recovered via a timing side-channel) by an
// arbitrary caller. `npm run retention:purge` can also hit this path
// directly with the same header for a manual/local run.
//
// Batched to stay within a Vercel Hobby function's execution-time limit: one
// invocation processes at most `maxDurationMs` worth of owners and reports
// `ownersRemaining` in its JSON body; a slow-to-fully-purge dataset finishes
// over several days of the (Hobby-only-allows-daily) cron schedule rather
// than risking a timeout in one run.

import { timingSafeEqual, createHash } from "node:crypto";
import { purgeExpiredRecords } from "../../src/retention.js";
import { getPool } from "../../src/db.js";

export const config = { runtime: "nodejs" };

function constantTimeEqual(a: string, b: string): boolean {
  // Compare fixed-length digests rather than the raw (length-leaking)
  // strings directly, so even the length comparison isn't a side channel.
  const hashA = createHash("sha256").update(Buffer.from(a, "utf8")).digest();
  const hashB = createHash("sha256").update(Buffer.from(b, "utf8")).digest();
  return timingSafeEqual(hashA, hashB);
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

export async function GET(request: Request): Promise<Response> {
  const expected = process.env.CRON_SECRET;
  const authorization = request.headers.get("authorization") ?? "";
  const presented = authorization.startsWith("Bearer ") ? authorization.slice("Bearer ".length) : "";
  if (!expected || !presented || !constantTimeEqual(presented, expected)) {
    return json(401, { error: "unauthorized" });
  }

  const retentionDays = Number(process.env.RETENTION_DAYS ?? "30");
  if (!Number.isFinite(retentionDays) || retentionDays < 1) {
    return json(500, { error: "internal" });
  }

  try {
    const summary = await purgeExpiredRecords(getPool(), retentionDays, Date.now() / 1000, { maxDurationMs: 8_000 });
    return json(200, { ok: true, ...summary });
  } catch {
    return json(500, { error: "internal" });
  }
}
