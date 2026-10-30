-- The MCP's private link (APP-API-CONTRACT.md section 35.5). Additive only: two new tables.
-- The owner applies it before the API deploy (until then the API acts as if the mode were 'public').

-- One row (id 1): how agents reach the MCP. 'public': POST /mcp with a client key in the header (the default, also
-- when the row is missing). 'private': only POST /mcp/k/<secret>; /mcp answers 404. 'off': both answer 404.
CREATE TABLE mcp_settings (
    id         INTEGER PRIMARY KEY CHECK (id = 1),
    mode       TEXT NOT NULL DEFAULT 'public' CHECK (mode IN ('off', 'public', 'private')),
    updated_at INTEGER NOT NULL
);

-- Private links. At most one is live (revoked_at NULL); rotating revokes it and makes the next. Only the SHA-256 of
-- the secret is stored, like api_keys; the link itself is shown once.
CREATE TABLE mcp_links (
    id           TEXT PRIMARY KEY,           -- random UUID
    link_hash    TEXT NOT NULL UNIQUE,       -- lowercase hex SHA-256 of the secret
    tail         TEXT NOT NULL,              -- the secret's last 4 characters, to tell links apart
    made_at      INTEGER NOT NULL,           -- ms
    revoked_at   INTEGER,                    -- ms
    last_used_at INTEGER,                    -- ms, the last POST
    used_by      TEXT,                       -- the client's name from its last initialize (clientInfo.name), <= 60
    calls_day    TEXT,                       -- UTC day (YYYY-MM-DD) that `calls` counts
    calls        INTEGER NOT NULL DEFAULT 0  -- POSTs on calls_day
);
CREATE UNIQUE INDEX idx_mcp_links_live ON mcp_links ((1)) WHERE revoked_at IS NULL;
