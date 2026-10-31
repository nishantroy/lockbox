-- Pairing v3 (docs/r5-pairing-v3-plan.md): invite token lookup index.
--
-- The owner generates a random 128-bit token (22 base64url characters) and
-- signs only its domain-separated SHA-256 hash into the invite payload. This
-- table maps that hash to the owner partition holding the signed invite, so
-- `POST /v1/invite/lookup {token}` can find it without knowing the owner. The
-- plaintext token is never stored. A row is written in the same transaction
-- as the owner-ledger update that stores the invite ("invite" op), and
-- deleted in the same transaction that consumes it ("accept" op); retention
-- deletes rows whose invite expired or was purged. ON DELETE CASCADE removes
-- an owner's tokens with the owner.
--
-- Pre-v3 invites have no token hash and never appear here; they cannot be
-- accepted (the v3 "accept" op requires a matching token) and simply expire.

CREATE TABLE IF NOT EXISTS companion_invite_token (
    token_hash BYTEA PRIMARY KEY CHECK (octet_length(token_hash) = 32),
    owner_id TEXT NOT NULL REFERENCES companion_owner(owner_id) ON DELETE CASCADE,
    invite_id TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    UNIQUE (owner_id, invite_id)
);

CREATE INDEX IF NOT EXISTS companion_invite_token_expires_idx ON companion_invite_token (expires_at);
