-- Persists where the retention cron's owner batch loop last stopped, so
-- successive daily invocations sweep through the whole owner set over time
-- (wrapping around once exhausted) instead of always re-processing the same
-- early-`owner_id` owners while later ones never get a turn under a
-- Vercel-Hobby-execution-time-bounded batch. See src/retention.ts.
CREATE TABLE IF NOT EXISTS companion_retention_cursor (
    id TEXT PRIMARY KEY,
    last_owner_id TEXT
);
