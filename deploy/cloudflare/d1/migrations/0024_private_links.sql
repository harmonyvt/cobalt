-- Private share links (APP-API-CONTRACT.md section 36). Additive only: two new tables and one index.
-- The owner applies it before the API deploy (until then the private link routes answer 503, the share host answers
-- /p/* with a 404, and everything else behaves as before).

-- A private link: share.../p/<key> opens one file (kind 'item', a media_items id) or one gallery link (kind 'set', a
-- share_sets id). The key is stored as is: it opens that one thing and nothing else, so the app can always show and
-- copy it. Rotating revokes the row and makes the next one; revoked rows stay.
CREATE TABLE private_links (
    key            TEXT PRIMARY KEY,             -- 22 base62 characters (~131 bits)
    kind           TEXT NOT NULL CHECK (kind IN ('item', 'set')),
    target_id      TEXT NOT NULL,                -- a media_items id or a share_sets id
    created_at     INTEGER NOT NULL,             -- ms
    revoked_at     INTEGER,                      -- ms; NULL = live
    opened         INTEGER NOT NULL DEFAULT 0,   -- page GETs (not HEAD, not file fetches)
    last_opened_at INTEGER                       -- ms
);
-- at most one live link per file or gallery link
CREATE UNIQUE INDEX idx_private_links_live ON private_links (kind, target_id) WHERE revoked_at IS NULL;

-- One row (id 1): whether new gallery links start public or private. A missing row (or table) means 'public'.
CREATE TABLE share_settings (
    id         INTEGER PRIMARY KEY CHECK (id = 1),
    new_links  TEXT NOT NULL DEFAULT 'public' CHECK (new_links IN ('public', 'private')),
    updated_at INTEGER NOT NULL
);
