-- Browser extension sign-in (APP-API-CONTRACT.md section 65).
-- A pending PKCE pairing for Safari (and any browser that cannot complete a redirect).
-- The device code and the user code are stored only as SHA-256. The session token is never
-- stored here: POST /auth/extension/poll mints it once the owner has approved on /connect/extension.
-- Chrome's redirect sign-in does not use this table; it reuses auth_handoffs (migration 0026).
--
-- Renumbered from 0039_extension_pairings.sql. Main already has 0040 and 0042-0044
-- (0041 is the open stage-music PR). 0039 was applied to production D1 on 2026-11-12,
-- so this file is idempotent: applying it again does not change an existing table.
--
-- The owner applies it (not the agent that added the file):
--   cd deploy/cloudflare/web && npx cf d1 migrations apply 42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir ../d1/migrations
CREATE TABLE IF NOT EXISTS extension_pairings (
    device_hash TEXT PRIMARY KEY,     -- SHA-256 hex of the device code (the extension's secret)
    user_hash   TEXT NOT NULL UNIQUE, -- SHA-256 hex of the user code (carried in the approve page URL)
    challenge   TEXT NOT NULL,        -- base64url(SHA-256(verifier)), PKCE S256, 43 chars
    state       TEXT NOT NULL,
    device      TEXT NOT NULL,        -- placeholder until approve, then "Browser extension – Chrome on Mac"
    email       TEXT,                 -- the Access email, set when the owner approves
    created_at  INTEGER NOT NULL,
    expires_at  INTEGER NOT NULL,     -- created_at + 5 min
    approved_at INTEGER,
    used_at     INTEGER
);
