-- APNs wake-up notifications (docs/r5-apns-plan.md). A device token is a
-- delivery address only: never state, never a credential. Rows are keyed by
-- the registering identity (an owner or approver identity). At most 5 rows
-- per identity are kept (enforced on insert in push-store.ts); retention deletes rows
-- not refreshed for 90 days.

CREATE TABLE IF NOT EXISTS companion_push_token (
    identity_id TEXT NOT NULL,
    token TEXT NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
    updated_at BIGINT NOT NULL,
    PRIMARY KEY (identity_id, token)
);

CREATE INDEX IF NOT EXISTS companion_push_token_identity_idx ON companion_push_token (identity_id);
CREATE INDEX IF NOT EXISTS companion_push_token_updated_idx ON companion_push_token (updated_at);
