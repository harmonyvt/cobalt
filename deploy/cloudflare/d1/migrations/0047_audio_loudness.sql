-- Audio loudness measurement & non-destructive leveling (Cobalt v10.1). Additive and idempotent.
-- Each video's EBU R128 measurement and leveling state lives in `media_audio` (keyed by parent `media_items.id`).
-- The leveled copy itself is a `media_items` row with `role = 'alt'`, `source = 'made'`,
-- `made_from = '["<parentId>"]'`, and `made_spec = '{"kind":"audio_level","target_lufs":-14,...}'`.
-- `audio_settings` holds the single-row owner configuration (`off` | `measure` | `auto`, target `-14` | `-16`,
-- default share link `orig` | `normal`).

CREATE TABLE IF NOT EXISTS media_audio (
    item_id          TEXT PRIMARY KEY,
    integrated_lufs  REAL,
    true_peak_dbtp   REAL,
    lra_lu           REAL,
    threshold_lufs   REAL,
    offset_db        REAL,
    zone             TEXT NOT NULL DEFAULT 'pending', -- pending | balanced | loud | quiet | silent
    state            TEXT NOT NULL DEFAULT 'pending', -- pending | measured | rendering | ready | skipped | failed
    target_lufs      REAL,
    output_lufs      REAL,
    output_true_peak REAL,
    alt_item_id      TEXT,
    attempts         INTEGER NOT NULL DEFAULT 0,
    error            TEXT,
    measured_at      INTEGER,
    leveled_at       INTEGER,
    updated_at       INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_media_audio_state ON media_audio (state, updated_at);
CREATE INDEX IF NOT EXISTS idx_media_audio_alt ON media_audio (alt_item_id) WHERE alt_item_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS audio_settings (
    id           INTEGER PRIMARY KEY CHECK (id = 1),
    mode         TEXT NOT NULL DEFAULT 'auto',   -- off | measure | auto
    target_lufs  REAL NOT NULL DEFAULT -14,      -- -14 | -16
    default_link TEXT NOT NULL DEFAULT 'orig',   -- orig | normal
    updated_at   INTEGER NOT NULL DEFAULT 0
);

INSERT OR IGNORE INTO audio_settings (id, mode, target_lufs, default_link, updated_at)
VALUES (1, 'auto', -14, 'orig', 0);

-- Bump the owning post in `changes` (migration 0038) whenever a file's audio loudness state lands or changes,
-- so incremental GET /sync picks up new measurements and leveled copies without a full library reload.
CREATE TRIGGER IF NOT EXISTS media_audio_sync_insert
AFTER INSERT ON media_audio
WHEN EXISTS (SELECT 1 FROM media_items WHERE id = NEW.item_id AND post_key IS NOT NULL)
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = (SELECT post_key FROM media_items WHERE id = NEW.item_id);
    INSERT INTO changes (entity, id, gone, at)
    SELECT 'post', m.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items x WHERE x.post_key = m.post_key AND x.deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000
    FROM media_items m WHERE m.id = NEW.item_id;
END;

CREATE TRIGGER IF NOT EXISTS media_audio_sync_update
AFTER UPDATE OF integrated_lufs, true_peak_dbtp, lra_lu, zone, state, target_lufs, output_lufs, output_true_peak, alt_item_id, error
ON media_audio
WHEN EXISTS (SELECT 1 FROM media_items WHERE id = NEW.item_id AND post_key IS NOT NULL)
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = (SELECT post_key FROM media_items WHERE id = NEW.item_id);
    INSERT INTO changes (entity, id, gone, at)
    SELECT 'post', m.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items x WHERE x.post_key = m.post_key AND x.deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000
    FROM media_items m WHERE m.id = NEW.item_id;
END;

CREATE TRIGGER IF NOT EXISTS media_audio_sync_delete
AFTER DELETE ON media_audio
WHEN EXISTS (SELECT 1 FROM media_items WHERE id = OLD.item_id AND post_key IS NOT NULL)
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = (SELECT post_key FROM media_items WHERE id = OLD.item_id);
    INSERT INTO changes (entity, id, gone, at)
    SELECT 'post', m.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items x WHERE x.post_key = m.post_key AND x.deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000
    FROM media_items m WHERE m.id = OLD.item_id;
END;

-- Clean up media_audio state automatically when a parent or audio_level alt item is soft-deleted,
-- keeping DELETE /library/items/<id> and DELETE /library/items/<id>/post at zero extra D1 round trips.
CREATE TRIGGER IF NOT EXISTS media_audio_cleanup_deleted
AFTER UPDATE OF deleted_at ON media_items
WHEN OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL
BEGIN
    DELETE FROM media_audio WHERE item_id = NEW.id;
    UPDATE media_audio
       SET alt_item_id = NULL,
           state = CASE WHEN integrated_lufs IS NOT NULL AND zone != 'silent' THEN 'measured'
                        WHEN zone = 'silent' THEN 'skipped'
                        ELSE 'pending' END,
           target_lufs = NULL,
           output_lufs = NULL,
           output_true_peak = NULL,
           leveled_at = NULL,
           updated_at = unixepoch() * 1000
     WHERE alt_item_id = NEW.id;
END;

