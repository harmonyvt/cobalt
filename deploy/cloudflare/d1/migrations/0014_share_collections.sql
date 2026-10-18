-- Share link collections (APP-API-CONTRACT.md section 26). Additive only: two new tables.
-- A collection is a named folder of gallery links (share_sets). A link may sit in several
-- collections; deleting a collection never revokes its links.
CREATE TABLE share_collections (
    id          TEXT PRIMARY KEY,      -- 16 random letters and digits
    name        TEXT NOT NULL,         -- 1..60 code points
    key_id      TEXT,                  -- api_keys.id that made it
    created_at  INTEGER NOT NULL,      -- ms
    updated_at  INTEGER NOT NULL       -- ms: renamed, or a link added or removed
);
CREATE TABLE share_collection_items (
    collection_id TEXT NOT NULL,
    set_id        TEXT NOT NULL,       -- share_sets.id
    added_at      INTEGER NOT NULL,    -- ms
    PRIMARY KEY (collection_id, set_id)
);
CREATE INDEX idx_share_collection_items_set ON share_collection_items (set_id);
