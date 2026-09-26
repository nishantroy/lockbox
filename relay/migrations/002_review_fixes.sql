-- Follow-up schema for the Slice A review fixes.

-- P2 idempotency: the idempotency comparison must also compare
-- `expectedRevision`, not just signer/kind/body digest, so a resubmission
-- under the same operationID with a different (or newly-added/removed)
-- expectedRevision is treated as a conflict rather than silently replayed.
ALTER TABLE companion_operation ADD COLUMN IF NOT EXISTS expected_revision BIGINT;

-- P2 rate limiting: a DB-backed limiter keyed by signer identity (charged in
-- its own transaction before the owner row lock), so a flood of operations
-- from one signer -- including failed attempts, inbox fetches, and
-- approver-signed operations aimed at owners that don't exist -- is bounded
-- before ever touching (or creating) an owner ledger row. This is separate
-- from the per-owner-ledger `rateLimits` map in src/ledger.ts (a port of
-- `InMemoryCompanionRelay.charge`, scoped to one owner's already-open
-- transaction); this table exists precisely for requests that never reach
-- that point.
CREATE TABLE IF NOT EXISTS companion_rate_limit (
    subject TEXT PRIMARY KEY,
    window_start TIMESTAMPTZ NOT NULL,
    count INT NOT NULL
);
