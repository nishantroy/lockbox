// Local/manual runner for the retention purge job. The Vercel Cron
// deployment instead hits api/cron/retention-purge.ts on a daily schedule
// (see relay/vercel.json); this script calls the same purge logic directly
// against DATABASE_URL, without going over HTTP.

import { purgeExpiredRecords } from "../src/retention.js";
import { getPool, closePool } from "../src/db.js";

async function main() {
  const retentionDays = Number(process.env.RETENTION_DAYS ?? "30");
  const summary = await purgeExpiredRecords(getPool(), retentionDays, Date.now() / 1000);
  console.log(`retention purge complete (window: ${retentionDays} days)`);
  console.log(JSON.stringify(summary, null, 2));
}

main()
  .catch((error) => {
    console.error("retention purge failed:", error instanceof Error ? error.message : error);
    process.exitCode = 1;
  })
  .finally(() => closePool());
