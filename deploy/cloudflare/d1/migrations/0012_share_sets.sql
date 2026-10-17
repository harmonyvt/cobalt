-- Gallery share links (APP-API-CONTRACT.md section 24). Additive only: one new table.
-- One row per link; `items` is the JSON array of media_items ids in the order shown.
-- Revoking sets revoked_at (the page is a 404 from then on); rows are never reused.
CREATE TABLE share_sets (
    id          TEXT PRIMARY KEY,      -- 19 random digits
    items       TEXT NOT NULL,         -- JSON ["<media_items id>", ...], 2..4
    title       TEXT,                  -- 1..80 code points, or NULL
    key_id      TEXT,                  -- api_keys.id that made it
    created_at  INTEGER NOT NULL,      -- ms
    revoked_at  INTEGER                -- ms; NULL = live
);
CREATE INDEX idx_share_sets_live ON share_sets (revoked_at, created_at DESC);
