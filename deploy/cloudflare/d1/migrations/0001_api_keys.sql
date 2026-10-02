-- Per-owner API keys for the cobalt API Worker (cobalt-keys D1 database).
-- Only the SHA-256 (lowercase hex) of a key is stored; the plaintext UUID is
-- shown once, when the owner creates it. Timestamps are ms since epoch.
CREATE TABLE api_keys (
    id           TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    key_hash     TEXT NOT NULL UNIQUE,   -- UNIQUE also gives the lookup index used by the API Worker
    prefix       TEXT NOT NULL,          -- first 8 chars of the key, for display only
    created_at   INTEGER NOT NULL,
    last_used_at INTEGER,
    revoked_at   INTEGER
);

-- Listing and counting active keys (revoked_at IS NULL), newest first.
CREATE INDEX idx_api_keys_active ON api_keys (revoked_at, created_at DESC);
