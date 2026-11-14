-- 7TV uploads made through capystore (APP-API-CONTRACT.md 57.11): which library file became which 7TV emote, so the
-- 7tv tab can mark "on 7tv" and list recent uploads. Additive, one empty table. Numbering: 0041 is the open
-- stage-music PR. Until it is applied, uploads still work and GET /7tv/uploads answers an empty list.
-- Safe to apply again (IF NOT EXISTS).
CREATE TABLE IF NOT EXISTS seventv_uploads (
    emote_id TEXT PRIMARY KEY,
    file_id TEXT NOT NULL,
    name TEXT NOT NULL,
    set_id TEXT,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS seventv_uploads_file ON seventv_uploads (file_id);
CREATE INDEX IF NOT EXISTS seventv_uploads_created ON seventv_uploads (created_at DESC);
