-- Pairing v3 review fixes: the relay now indexes invites by a LOOKUP KEY,
-- H("invite-lookup", token), and never sees the token. Rows written by 004
-- hold the old token hash, are unusable under the new scheme (and v3 has not
-- shipped), so they are discarded. `consumed_at` turns a consumed row into a
-- tombstone that stays until the invite expires, so another owner cannot
-- re-register the same key.
--
-- NOTE: databases that ran an earlier, unreviewed build of this slice (commit d4b0ea3)
-- must be recreated, not migrated: that build's invite payloads and ledger rows use a
-- different shape. Pairing v3 has not shipped, so only local/dev databases are affected.

DELETE FROM companion_invite_token;
ALTER TABLE companion_invite_token RENAME COLUMN token_hash TO lookup_key;
ALTER TABLE companion_invite_token ADD COLUMN IF NOT EXISTS consumed_at TIMESTAMPTZ;
