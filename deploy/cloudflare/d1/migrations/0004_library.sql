-- cobalt library (see LIBRARY-CONTRACT.md): one row per file the owner has,
-- public (R2 `cobalt-media`, served at https://media.capybaraharmony.com/<name>)
-- or private (R2 `cobalt-originals`). Timestamps are ms since epoch. Deleting a
-- file sets deleted_at (and removes the R2 object); lists skip deleted rows.
CREATE TABLE media_items (
    id           TEXT PRIMARY KEY,      -- 16 base62 chars
    kind         TEXT NOT NULL,         -- 'public' | 'private'
    source       TEXT NOT NULL,         -- 'webp' | 'studio' | 'host' | 'upload' | 'saved'
    bucket       TEXT NOT NULL,         -- 'media' | 'originals'
    r2_key       TEXT NOT NULL,         -- object key inside that bucket
    url          TEXT,                  -- public items only
    name         TEXT NOT NULL,         -- display name
    content_type TEXT,
    bytes        INTEGER,
    width        INTEGER,
    height       INTEGER,
    duration     REAL,                  -- seconds
    link         TEXT,                  -- source page link, when there is one
    session_id   TEXT,                  -- studio_sessions.id, when there is one
    key_id       TEXT,                  -- api_keys.id (or service:library) that made it
    created_at   INTEGER NOT NULL,
    deleted_at   INTEGER                -- null while the file exists
);

CREATE INDEX idx_media_items_listing ON media_items (deleted_at, created_at DESC);
CREATE INDEX idx_media_items_session ON media_items (session_id);
