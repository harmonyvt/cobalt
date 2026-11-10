-- Sync engine, slice 1 (design: stored post key, change log, GET /sync). Additive.
-- Apply BEFORE the API deploy that serves GET /sync. Until then the new route answers 503 and every
-- existing route behaves as it does today (the idempotency table and the change header are skipped
-- when these tables are missing).
--
-- Runtime on this library: about 700 videos plus the photos and renders beside them, well under
-- 40,000 media_items rows. The backfill below is 40 statements of 1,000 rows. Each is an update of
-- rows whose post_key is still NULL, and the session lookup is a primary-key read. On a library this
-- size that is a few seconds, not a long lock; empty batches after the rows are filled touch nothing.
-- Anything past 40,000 rows is filled by the 15-minute cron, 2,000 rows a run, and every insert fills
-- its own key in the same statement. The change log is then seeded once from the rows that exist.

-- Rows still waiting for a key. The cron's "is there anything left?" read uses this and stops at once
-- once the backfill is done. Dropped naturally as each row is filled.
CREATE INDEX idx_media_items_post_key_missing ON media_items (id) WHERE post_key IS NULL;

-- One counter for the whole library. One row per synced thing (entity, id); a newer change replaces
-- that row and takes the next seq, so the log stays the size of the library. gone = 1 is a delete
-- marker, the only rows that are trimmed.
CREATE TABLE changes (
    seq    INTEGER PRIMARY KEY AUTOINCREMENT,
    entity TEXT NOT NULL,                 -- post | link | collection | set | name | rule
    id     TEXT NOT NULL,
    gone   INTEGER NOT NULL DEFAULT 0,
    at     INTEGER NOT NULL               -- ms
);
CREATE UNIQUE INDEX changes_thing ON changes (entity, id);

-- Highest seq of a delete marker that has been thrown away. A client whose since is still below it
-- missed a deletion and must start again (410 sync.cursor_too_old). 0 = nothing trimmed.
CREATE TABLE sync_state (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    trimmed_seq INTEGER NOT NULL DEFAULT 0
);
INSERT INTO sync_state (id, trimmed_seq) VALUES (1, 0);

-- A retried write (Idempotency-Key) replays the first answer and does not apply again.
-- Kept for 7 days by the 15-minute cron; the app retries within minutes.
CREATE TABLE idempotency_keys (
    key         TEXT PRIMARY KEY,
    fingerprint TEXT NOT NULL,            -- method, path and body
    status      INTEGER NOT NULL,
    body        TEXT NOT NULL,
    seq         INTEGER NOT NULL,         -- the change number that answer carried
    created_at  INTEGER NOT NULL
);

-- ---- fill post_key on every insert that did not set it ------------------------------------------
-- AFTER INSERT, and created before the change trigger, so that trigger reads the stored key.
-- The UPDATE does not re-enter the change triggers: recursive_triggers stays off (SQLite's default,
-- and D1's), and the merge trigger ignores a key that was NULL.

CREATE TRIGGER media_items_fill_post_key
AFTER INSERT ON media_items
WHEN NEW.post_key IS NULL
BEGIN
    UPDATE media_items SET post_key = COALESCE(
        (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = NEW.session_id AND s.link LIKE 'upload:%'),
        NEW.session_id, NEW.link, NEW.id)
    WHERE id = NEW.id AND post_key IS NULL;
    -- The change is recorded here, not by the insert trigger below: that trigger runs when the INSERT
    -- already named a key. SQLite does not show this UPDATE to a sibling AFTER INSERT trigger.
    DELETE FROM changes WHERE entity = 'post' AND id = (SELECT post_key FROM media_items WHERE id = NEW.id);
    INSERT INTO changes (entity, id, gone, at)
    SELECT 'post', post_key,
        CASE WHEN NEW.deleted_at IS NULL OR EXISTS (
            SELECT 1 FROM media_items m WHERE m.post_key = media_items.post_key AND m.deleted_at IS NULL
        ) THEN 0 ELSE 1 END,
        unixepoch() * 1000
    FROM media_items WHERE id = NEW.id AND post_key IS NOT NULL;
END;

-- ---- posts: files, titles, hidden ----------------------------------------------------------------
-- A live insert is gone = 0 without a lookup. A delete (or the last file going) looks the key up on
-- idx_media_items_post_key, one probe, so a burst of title writes stays one indexed write plus that
-- probe and never scans the table. poster_at is not in the update list: the poster job's "try again
-- tomorrow" write is not a change a device needs.

CREATE TRIGGER media_items_sync_insert
AFTER INSERT ON media_items
WHEN NEW.post_key IS NOT NULL
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = NEW.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', NEW.post_key,
        CASE WHEN NEW.deleted_at IS NULL OR EXISTS (
            SELECT 1 FROM media_items WHERE post_key = NEW.post_key AND deleted_at IS NULL
        ) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER media_items_sync_update
AFTER UPDATE OF deleted_at, visibility, url, name, content_type, bytes, width, height, duration, poster, role, item_index, made_from, made_spec, link, kind, source, public_key, public_id, bucket, r2_key, session_id
ON media_items
WHEN NEW.post_key IS NOT NULL
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = NEW.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', NEW.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = NEW.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

-- A file moving from one post to another: both keys, so a device does not keep the old card.
CREATE TRIGGER media_items_sync_merge
AFTER UPDATE OF post_key ON media_items
WHEN OLD.post_key IS NOT NULL AND NEW.post_key IS NOT NULL AND OLD.post_key <> NEW.post_key
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = OLD.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', OLD.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = OLD.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
    DELETE FROM changes WHERE entity = 'post' AND id = NEW.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', NEW.post_key,
        CASE WHEN NEW.deleted_at IS NULL OR EXISTS (
            SELECT 1 FROM media_items WHERE post_key = NEW.post_key AND deleted_at IS NULL
        ) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER media_items_sync_delete
AFTER DELETE ON media_items
WHEN OLD.post_key IS NOT NULL
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = OLD.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', OLD.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = OLD.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER media_titles_sync_insert
AFTER INSERT ON media_titles
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = NEW.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', NEW.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = NEW.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER media_titles_sync_update
AFTER UPDATE ON media_titles
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = NEW.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', NEW.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = NEW.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER media_titles_sync_delete
AFTER DELETE ON media_titles
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = OLD.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', OLD.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = OLD.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER media_hidden_sync_insert
AFTER INSERT ON media_hidden
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = NEW.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', NEW.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = NEW.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER media_hidden_sync_update
AFTER UPDATE ON media_hidden
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = NEW.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', NEW.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = NEW.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER media_hidden_sync_delete
AFTER DELETE ON media_hidden
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = OLD.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', OLD.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = OLD.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

-- ---- links (gallery links), collections, sets, names, rules --------------------------------------
-- Membership edits bump the parent, and only while that parent still exists, so deleting the parent
-- after its members does not bring the marker back.

CREATE TRIGGER share_sets_sync_insert
AFTER INSERT ON share_sets
BEGIN
    DELETE FROM changes WHERE entity = 'link' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('link', NEW.id, CASE WHEN NEW.revoked_at IS NULL THEN 0 ELSE 1 END, unixepoch() * 1000);
END;

CREATE TRIGGER share_sets_sync_update
AFTER UPDATE ON share_sets
BEGIN
    DELETE FROM changes WHERE entity = 'link' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('link', NEW.id, CASE WHEN NEW.revoked_at IS NULL THEN 0 ELSE 1 END, unixepoch() * 1000);
END;

CREATE TRIGGER share_sets_sync_delete
AFTER DELETE ON share_sets
BEGIN
    DELETE FROM changes WHERE entity = 'link' AND id = OLD.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('link', OLD.id, 1, unixepoch() * 1000);
END;

CREATE TRIGGER share_collections_sync_insert
AFTER INSERT ON share_collections
BEGIN
    DELETE FROM changes WHERE entity = 'collection' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('collection', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER share_collections_sync_update
AFTER UPDATE ON share_collections
BEGIN
    DELETE FROM changes WHERE entity = 'collection' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('collection', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER share_collections_sync_delete
AFTER DELETE ON share_collections
BEGIN
    DELETE FROM changes WHERE entity = 'collection' AND id = OLD.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('collection', OLD.id, 1, unixepoch() * 1000);
END;

CREATE TRIGGER share_collection_items_sync_insert
AFTER INSERT ON share_collection_items
BEGIN
    DELETE FROM changes WHERE entity = 'collection' AND id = NEW.collection_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'collection', NEW.collection_id,
        CASE WHEN EXISTS (SELECT 1 FROM share_collections WHERE id = NEW.collection_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER share_collection_items_sync_delete
AFTER DELETE ON share_collection_items
BEGIN
    DELETE FROM changes WHERE entity = 'collection' AND id = OLD.collection_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'collection', OLD.collection_id,
        CASE WHEN EXISTS (SELECT 1 FROM share_collections WHERE id = OLD.collection_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER collection_groups_sync_insert
AFTER INSERT ON collection_groups
BEGIN
    DELETE FROM changes WHERE entity = 'set' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('set', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER collection_groups_sync_update
AFTER UPDATE ON collection_groups
BEGIN
    DELETE FROM changes WHERE entity = 'set' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('set', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER collection_groups_sync_delete
AFTER DELETE ON collection_groups
BEGIN
    DELETE FROM changes WHERE entity = 'set' AND id = OLD.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('set', OLD.id, 1, unixepoch() * 1000);
END;

CREATE TRIGGER collection_group_items_sync_insert
AFTER INSERT ON collection_group_items
BEGIN
    DELETE FROM changes WHERE entity = 'set' AND id = NEW.group_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'set', NEW.group_id,
        CASE WHEN EXISTS (SELECT 1 FROM collection_groups WHERE id = NEW.group_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER collection_group_items_sync_delete
AFTER DELETE ON collection_group_items
BEGIN
    DELETE FROM changes WHERE entity = 'set' AND id = OLD.group_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'set', OLD.group_id,
        CASE WHEN EXISTS (SELECT 1 FROM collection_groups WHERE id = OLD.group_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER search_names_sync_insert
AFTER INSERT ON search_names
BEGIN
    DELETE FROM changes WHERE entity = 'name' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('name', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER search_names_sync_update
AFTER UPDATE ON search_names
BEGIN
    DELETE FROM changes WHERE entity = 'name' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('name', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER search_names_sync_delete
AFTER DELETE ON search_names
BEGIN
    DELETE FROM changes WHERE entity = 'name' AND id = OLD.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('name', OLD.id, 1, unixepoch() * 1000);
END;

CREATE TRIGGER search_name_posts_sync_insert
AFTER INSERT ON search_name_posts
BEGIN
    DELETE FROM changes WHERE entity = 'name' AND id = NEW.name_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'name', NEW.name_id,
        CASE WHEN EXISTS (SELECT 1 FROM search_names WHERE id = NEW.name_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER search_name_posts_sync_update
AFTER UPDATE ON search_name_posts
BEGIN
    DELETE FROM changes WHERE entity = 'name' AND id = NEW.name_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'name', NEW.name_id,
        CASE WHEN EXISTS (SELECT 1 FROM search_names WHERE id = NEW.name_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER search_name_posts_sync_delete
AFTER DELETE ON search_name_posts
BEGIN
    DELETE FROM changes WHERE entity = 'name' AND id = OLD.name_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'name', OLD.name_id,
        CASE WHEN EXISTS (SELECT 1 FROM search_names WHERE id = OLD.name_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER hidden_rules_sync_insert
AFTER INSERT ON hidden_rules
BEGIN
    DELETE FROM changes WHERE entity = 'rule' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('rule', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER hidden_rules_sync_update
AFTER UPDATE ON hidden_rules
BEGIN
    DELETE FROM changes WHERE entity = 'rule' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('rule', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER hidden_rules_sync_delete
AFTER DELETE ON hidden_rules
BEGIN
    DELETE FROM changes WHERE entity = 'rule' AND id = OLD.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('rule', OLD.id, 1, unixepoch() * 1000);
END;

-- ---- backfill, then the index, then one change per thing that already exists --------------------

UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);
UPDATE media_items SET post_key = COALESCE(post_key, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = media_items.session_id AND s.link LIKE 'upload:%'), session_id, link, id) WHERE rowid IN (SELECT rowid FROM media_items WHERE post_key IS NULL ORDER BY rowid LIMIT 1000);

CREATE INDEX idx_media_items_post_key ON media_items (post_key);

INSERT INTO changes (entity, id, gone, at)
SELECT 'post', post_key, 0, unixepoch() * 1000 FROM media_items
WHERE deleted_at IS NULL AND post_key IS NOT NULL GROUP BY post_key;

INSERT INTO changes (entity, id, gone, at)
SELECT 'link', id, 0, unixepoch() * 1000 FROM share_sets WHERE revoked_at IS NULL;

INSERT INTO changes (entity, id, gone, at)
SELECT 'collection', id, 0, unixepoch() * 1000 FROM share_collections;

INSERT INTO changes (entity, id, gone, at)
SELECT 'set', id, 0, unixepoch() * 1000 FROM collection_groups;

INSERT INTO changes (entity, id, gone, at)
SELECT 'name', id, 0, unixepoch() * 1000 FROM search_names;

INSERT INTO changes (entity, id, gone, at)
SELECT 'rule', id, 0, unixepoch() * 1000 FROM hidden_rules;
