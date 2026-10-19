-- Collection sets (APP-API-CONTRACT.md section 28). Additive only: two new tables.
-- A collection group ("set" in the app) is a named group of share link collections
-- (share_collections). A collection may sit in several groups; deleting a group never
-- deletes its collections; a deleted collection drops out of every group.
CREATE TABLE collection_groups (
    id          TEXT PRIMARY KEY,      -- 16 random letters and digits
    name        TEXT NOT NULL,         -- 1..60 code points
    key_id      TEXT,                  -- api_keys.id that made it
    created_at  INTEGER NOT NULL,      -- ms
    updated_at  INTEGER NOT NULL       -- ms: renamed, or a collection added or removed
);
CREATE TABLE collection_group_items (
    group_id      TEXT NOT NULL,
    collection_id TEXT NOT NULL,       -- share_collections.id
    added_at      INTEGER NOT NULL,    -- ms
    PRIMARY KEY (group_id, collection_id)
);
CREATE INDEX idx_collection_group_items_collection ON collection_group_items (collection_id);
