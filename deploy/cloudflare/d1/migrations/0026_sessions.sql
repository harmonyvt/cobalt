-- Device sessions (APP-API-CONTRACT.md section 42): a sign-in through Cloudflare Access mints an api_keys row with
-- kind = 'session'. Its token has the shape of a client key, so every route and key_id column works unchanged.
ALTER TABLE api_keys ADD COLUMN kind TEXT NOT NULL DEFAULT 'key';   -- 'key' | 'session'
ALTER TABLE api_keys ADD COLUMN device TEXT;          -- session: device name (<= 40 chars)
ALTER TABLE api_keys ADD COLUMN platform TEXT;        -- session: 'ios' | 'ipados' | 'mac' | 'web'
ALTER TABLE api_keys ADD COLUMN email TEXT;           -- session: the Access email that signed it in
ALTER TABLE api_keys ADD COLUMN expires_at INTEGER;   -- session: ms, slides 90 days on each use; NULL for keys
ALTER TABLE api_keys ADD COLUMN last_country TEXT;    -- cf.country of the last use
ALTER TABLE api_keys ADD COLUMN replaced_by TEXT;     -- key: the session id that took over from this pasted key

-- One-time codes from the web Worker's /api/auth/app to the API's POST /auth/exchange (PKCE S256, 2 minutes).
CREATE TABLE auth_handoffs (
    code_hash  TEXT PRIMARY KEY,
    challenge  TEXT NOT NULL,
    device     TEXT NOT NULL,
    platform   TEXT NOT NULL,
    email      TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at    INTEGER
);

CREATE INDEX idx_api_keys_sessions ON api_keys (kind, revoked_at, last_used_at DESC);
