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
--
-- Safe to apply again: every CREATE is IF NOT EXISTS and every seed row is OR IGNORE, so a second run
-- (or a run that follows one cut short) ends in the same state as one clean run and never fails on
-- something the first run left behind.

-- Rows still waiting for a key. The cron's "is there anything left?" read uses this and stops at once
-- once the backfill is done. Dropped naturally as each row is filled.
CREATE INDEX IF NOT EXISTS idx_media_items_post_key_missing ON media_items (id) WHERE post_key IS NULL;

-- One counter for the whole library. One row per synced thing (entity, id); a newer change replaces
-- that row and takes the next seq, so the log stays the size of the library. gone = 1 is a delete
-- marker, the only rows that are trimmed.
CREATE TABLE IF NOT EXISTS changes (
    seq    INTEGER PRIMARY KEY AUTOINCREMENT,
    entity TEXT NOT NULL,                 -- post | link | collection | set | name | rule
    id     TEXT NOT NULL,
    gone   INTEGER NOT NULL DEFAULT 0,
    at     INTEGER NOT NULL               -- ms
);
CREATE UNIQUE INDEX IF NOT EXISTS changes_thing ON changes (entity, id);

-- Highest seq of a delete marker that has been thrown away. A client whose since is still below it
-- missed a deletion and must start again (410 sync.cursor_too_old). 0 = nothing trimmed.
CREATE TABLE IF NOT EXISTS sync_state (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    trimmed_seq INTEGER NOT NULL DEFAULT 0
);
INSERT OR IGNORE INTO sync_state (id, trimmed_seq) VALUES (1, 0);

-- A retried write (Idempotency-Key) replays the first answer and does not apply again.
-- Kept for 7 days by the 15-minute cron; the app retries within minutes. A key belongs to the caller
-- that sent it: two devices that happen to send the same key never see each other's answer.
CREATE TABLE IF NOT EXISTS idempotency_keys (
    caller      TEXT NOT NULL,            -- a hash of the caller's credential, never the credential
    key         TEXT NOT NULL,            -- the Idempotency-Key header
    fingerprint TEXT NOT NULL,            -- method, path and body
    status      INTEGER NOT NULL,
    body        TEXT NOT NULL,
    seq         INTEGER NOT NULL,         -- the change number that answer carried
    created_at  INTEGER NOT NULL,
    PRIMARY KEY (caller, key)
);

-- ---- fill post_key on every insert that did not set it ------------------------------------------
-- AFTER INSERT, and created before the change trigger, so that trigger reads the stored key.
-- The UPDATE does not re-enter the change triggers: recursive_triggers stays off (SQLite's default,
-- and D1's), and the merge trigger ignores a key that was NULL.

CREATE TRIGGER IF NOT EXISTS media_items_fill_post_key
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

CREATE TRIGGER IF NOT EXISTS media_items_sync_insert
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

CREATE TRIGGER IF NOT EXISTS media_items_sync_update
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
CREATE TRIGGER IF NOT EXISTS media_items_sync_merge
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

CREATE TRIGGER IF NOT EXISTS media_items_sync_delete
AFTER DELETE ON media_items
WHEN OLD.post_key IS NOT NULL
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = OLD.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', OLD.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = OLD.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS media_titles_sync_insert
AFTER INSERT ON media_titles
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = NEW.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', NEW.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = NEW.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS media_titles_sync_update
AFTER UPDATE ON media_titles
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = NEW.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', NEW.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = NEW.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS media_titles_sync_delete
AFTER DELETE ON media_titles
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = OLD.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', OLD.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = OLD.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS media_hidden_sync_insert
AFTER INSERT ON media_hidden
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = NEW.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', NEW.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = NEW.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS media_hidden_sync_update
AFTER UPDATE ON media_hidden
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = NEW.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', NEW.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = NEW.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS media_hidden_sync_delete
AFTER DELETE ON media_hidden
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = OLD.post_key;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', OLD.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items WHERE post_key = OLD.post_key AND deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

-- ---- posts: the studio session and the private links a post shows ----------------------------------
-- A post carries its session (id, status, expires_at), its service and a gallery's failed items, all
-- read from studio_sessions, and each file's private link, read from private_links. Several writes
-- touch only those tables (a reopened or closed studio, a retried gallery, a link turned on, off or
-- rotated), so they are logged here. The session's post is the one GET /library gives it: the post
-- named by an 'upload:<post>' link, else the session id. Only a post with a live file is logged: a
-- session is written before its first file, and that file's insert logs the post.

CREATE TRIGGER IF NOT EXISTS studio_sessions_sync_insert
AFTER INSERT ON studio_sessions
WHEN EXISTS (
    SELECT 1 FROM media_items
    WHERE post_key = CASE WHEN NEW.link LIKE 'upload:%' THEN substr(NEW.link, 8) ELSE NEW.id END AND deleted_at IS NULL)
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = CASE WHEN NEW.link LIKE 'upload:%' THEN substr(NEW.link, 8) ELSE NEW.id END;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', CASE WHEN NEW.link LIKE 'upload:%' THEN substr(NEW.link, 8) ELSE NEW.id END, 0, unixepoch() * 1000);
END;

-- Only when a value the post shows really changed: the studio rewrites other columns (its clip, its
-- poster) many times in a session.
CREATE TRIGGER IF NOT EXISTS studio_sessions_sync_update
AFTER UPDATE OF status, service, expires_at, items, link ON studio_sessions
WHEN (NEW.status IS NOT OLD.status OR NEW.service IS NOT OLD.service OR NEW.expires_at IS NOT OLD.expires_at
      OR NEW.items IS NOT OLD.items OR NEW.link IS NOT OLD.link)
 AND EXISTS (
    SELECT 1 FROM media_items
    WHERE post_key = CASE WHEN NEW.link LIKE 'upload:%' THEN substr(NEW.link, 8) ELSE NEW.id END AND deleted_at IS NULL)
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = CASE WHEN NEW.link LIKE 'upload:%' THEN substr(NEW.link, 8) ELSE NEW.id END;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', CASE WHEN NEW.link LIKE 'upload:%' THEN substr(NEW.link, 8) ELSE NEW.id END, 0, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS studio_sessions_sync_delete
AFTER DELETE ON studio_sessions
WHEN EXISTS (
    SELECT 1 FROM media_items
    WHERE post_key = CASE WHEN OLD.link LIKE 'upload:%' THEN substr(OLD.link, 8) ELSE OLD.id END AND deleted_at IS NULL)
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = CASE WHEN OLD.link LIKE 'upload:%' THEN substr(OLD.link, 8) ELSE OLD.id END;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'post', CASE WHEN OLD.link LIKE 'upload:%' THEN substr(OLD.link, 8) ELSE OLD.id END, 0, unixepoch() * 1000);
END;

-- A file's private link: turned on (insert), turned off or rotated (revoked_at, then a new row).
-- kind 'item' only. A gallery link's private link (kind 'set') is not part of the link GET /sync
-- sends, so it changes nothing a device holds. "opened" counts every view and is left out.
CREATE TRIGGER IF NOT EXISTS private_links_sync_insert
AFTER INSERT ON private_links
WHEN NEW.kind = 'item' AND EXISTS (SELECT 1 FROM media_items WHERE id = NEW.target_id AND post_key IS NOT NULL)
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = (SELECT post_key FROM media_items WHERE id = NEW.target_id);
    INSERT INTO changes (entity, id, gone, at)
    SELECT 'post', m.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items x WHERE x.post_key = m.post_key AND x.deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000
    FROM media_items m WHERE m.id = NEW.target_id;
END;

CREATE TRIGGER IF NOT EXISTS private_links_sync_update
AFTER UPDATE OF revoked_at ON private_links
WHEN NEW.kind = 'item' AND NEW.revoked_at IS NOT OLD.revoked_at
 AND EXISTS (SELECT 1 FROM media_items WHERE id = NEW.target_id AND post_key IS NOT NULL)
BEGIN
    DELETE FROM changes WHERE entity = 'post' AND id = (SELECT post_key FROM media_items WHERE id = NEW.target_id);
    INSERT INTO changes (entity, id, gone, at)
    SELECT 'post', m.post_key,
        CASE WHEN EXISTS (SELECT 1 FROM media_items x WHERE x.post_key = m.post_key AND x.deleted_at IS NULL) THEN 0 ELSE 1 END,
        unixepoch() * 1000
    FROM media_items m WHERE m.id = NEW.target_id;
END;

-- ---- links (gallery links), collections, sets, names, rules --------------------------------------
-- Membership edits bump the parent, and only while that parent still exists, so deleting the parent
-- after its members does not bring the marker back.

CREATE TRIGGER IF NOT EXISTS share_sets_sync_insert
AFTER INSERT ON share_sets
BEGIN
    DELETE FROM changes WHERE entity = 'link' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('link', NEW.id, CASE WHEN NEW.revoked_at IS NULL THEN 0 ELSE 1 END, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS share_sets_sync_update
AFTER UPDATE ON share_sets
BEGIN
    DELETE FROM changes WHERE entity = 'link' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('link', NEW.id, CASE WHEN NEW.revoked_at IS NULL THEN 0 ELSE 1 END, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS share_sets_sync_delete
AFTER DELETE ON share_sets
BEGIN
    DELETE FROM changes WHERE entity = 'link' AND id = OLD.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('link', OLD.id, 1, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS share_collections_sync_insert
AFTER INSERT ON share_collections
BEGIN
    DELETE FROM changes WHERE entity = 'collection' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('collection', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS share_collections_sync_update
AFTER UPDATE ON share_collections
BEGIN
    DELETE FROM changes WHERE entity = 'collection' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('collection', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS share_collections_sync_delete
AFTER DELETE ON share_collections
BEGIN
    DELETE FROM changes WHERE entity = 'collection' AND id = OLD.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('collection', OLD.id, 1, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS share_collection_items_sync_insert
AFTER INSERT ON share_collection_items
BEGIN
    DELETE FROM changes WHERE entity = 'collection' AND id = NEW.collection_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'collection', NEW.collection_id,
        CASE WHEN EXISTS (SELECT 1 FROM share_collections WHERE id = NEW.collection_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

-- A reroll moves every collection's row for the old link to the new one with an UPDATE, and only the
-- rerolled collection is written beside it. Both owners, so a row that changed hands leaves the old one.
CREATE TRIGGER IF NOT EXISTS share_collection_items_sync_update
AFTER UPDATE ON share_collection_items
BEGIN
    DELETE FROM changes WHERE entity = 'collection' AND id = OLD.collection_id AND OLD.collection_id <> NEW.collection_id;
    INSERT INTO changes (entity, id, gone, at)
    SELECT 'collection', OLD.collection_id,
        CASE WHEN EXISTS (SELECT 1 FROM share_collections WHERE id = OLD.collection_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000
    WHERE OLD.collection_id <> NEW.collection_id;
    DELETE FROM changes WHERE entity = 'collection' AND id = NEW.collection_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'collection', NEW.collection_id,
        CASE WHEN EXISTS (SELECT 1 FROM share_collections WHERE id = NEW.collection_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS share_collection_items_sync_delete
AFTER DELETE ON share_collection_items
BEGIN
    DELETE FROM changes WHERE entity = 'collection' AND id = OLD.collection_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'collection', OLD.collection_id,
        CASE WHEN EXISTS (SELECT 1 FROM share_collections WHERE id = OLD.collection_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS collection_groups_sync_insert
AFTER INSERT ON collection_groups
BEGIN
    DELETE FROM changes WHERE entity = 'set' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('set', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS collection_groups_sync_update
AFTER UPDATE ON collection_groups
BEGIN
    DELETE FROM changes WHERE entity = 'set' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('set', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS collection_groups_sync_delete
AFTER DELETE ON collection_groups
BEGIN
    DELETE FROM changes WHERE entity = 'set' AND id = OLD.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('set', OLD.id, 1, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS collection_group_items_sync_insert
AFTER INSERT ON collection_group_items
BEGIN
    DELETE FROM changes WHERE entity = 'set' AND id = NEW.group_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'set', NEW.group_id,
        CASE WHEN EXISTS (SELECT 1 FROM collection_groups WHERE id = NEW.group_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS collection_group_items_sync_update
AFTER UPDATE ON collection_group_items
BEGIN
    DELETE FROM changes WHERE entity = 'set' AND id = OLD.group_id AND OLD.group_id <> NEW.group_id;
    INSERT INTO changes (entity, id, gone, at)
    SELECT 'set', OLD.group_id,
        CASE WHEN EXISTS (SELECT 1 FROM collection_groups WHERE id = OLD.group_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000
    WHERE OLD.group_id <> NEW.group_id;
    DELETE FROM changes WHERE entity = 'set' AND id = NEW.group_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'set', NEW.group_id,
        CASE WHEN EXISTS (SELECT 1 FROM collection_groups WHERE id = NEW.group_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS collection_group_items_sync_delete
AFTER DELETE ON collection_group_items
BEGIN
    DELETE FROM changes WHERE entity = 'set' AND id = OLD.group_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'set', OLD.group_id,
        CASE WHEN EXISTS (SELECT 1 FROM collection_groups WHERE id = OLD.group_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS search_names_sync_insert
AFTER INSERT ON search_names
BEGIN
    DELETE FROM changes WHERE entity = 'name' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('name', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS search_names_sync_update
AFTER UPDATE ON search_names
BEGIN
    DELETE FROM changes WHERE entity = 'name' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('name', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS search_names_sync_delete
AFTER DELETE ON search_names
BEGIN
    DELETE FROM changes WHERE entity = 'name' AND id = OLD.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('name', OLD.id, 1, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS search_name_posts_sync_insert
AFTER INSERT ON search_name_posts
BEGIN
    DELETE FROM changes WHERE entity = 'name' AND id = NEW.name_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'name', NEW.name_id,
        CASE WHEN EXISTS (SELECT 1 FROM search_names WHERE id = NEW.name_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS search_name_posts_sync_update
AFTER UPDATE ON search_name_posts
BEGIN
    DELETE FROM changes WHERE entity = 'name' AND id = NEW.name_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'name', NEW.name_id,
        CASE WHEN EXISTS (SELECT 1 FROM search_names WHERE id = NEW.name_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS search_name_posts_sync_delete
AFTER DELETE ON search_name_posts
BEGIN
    DELETE FROM changes WHERE entity = 'name' AND id = OLD.name_id;
    INSERT INTO changes (entity, id, gone, at) VALUES (
        'name', OLD.name_id,
        CASE WHEN EXISTS (SELECT 1 FROM search_names WHERE id = OLD.name_id) THEN 0 ELSE 1 END,
        unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS hidden_rules_sync_insert
AFTER INSERT ON hidden_rules
BEGIN
    DELETE FROM changes WHERE entity = 'rule' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('rule', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS hidden_rules_sync_update
AFTER UPDATE ON hidden_rules
BEGIN
    DELETE FROM changes WHERE entity = 'rule' AND id = NEW.id;
    INSERT INTO changes (entity, id, gone, at) VALUES ('rule', NEW.id, 0, unixepoch() * 1000);
END;

CREATE TRIGGER IF NOT EXISTS hidden_rules_sync_delete
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

CREATE INDEX IF NOT EXISTS idx_media_items_post_key ON media_items (post_key);

-- The seed. Lowest numbers first is the order a first pull receives, so the newest posts go in first:
-- a device shows recent saves after its first page, not an arbitrary slice by key. OR IGNORE, because a
-- write from the live API between two statements of this file (the triggers above already exist) may
-- have logged a thing first, and because the file may be applied again: a thing that has its row keeps
-- it, with the number it has. NOT EXISTS as well, so that a row which is skipped does not use up a number.
INSERT OR IGNORE INTO changes (entity, id, gone, at)
SELECT 'post', post_key, 0, unixepoch() * 1000
FROM (SELECT post_key, MAX(created_at) AS latest FROM media_items
      WHERE deleted_at IS NULL AND post_key IS NOT NULL GROUP BY post_key) p
WHERE NOT EXISTS (SELECT 1 FROM changes c WHERE c.entity = 'post' AND c.id = p.post_key)
ORDER BY latest DESC, post_key DESC;

INSERT OR IGNORE INTO changes (entity, id, gone, at)
SELECT 'link', id, 0, unixepoch() * 1000 FROM share_sets WHERE revoked_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM changes c WHERE c.entity = 'link' AND c.id = share_sets.id) ORDER BY created_at DESC, id DESC;

INSERT OR IGNORE INTO changes (entity, id, gone, at)
SELECT 'collection', id, 0, unixepoch() * 1000 FROM share_collections
WHERE NOT EXISTS (SELECT 1 FROM changes c WHERE c.entity = 'collection' AND c.id = share_collections.id) ORDER BY updated_at DESC, id DESC;

INSERT OR IGNORE INTO changes (entity, id, gone, at)
SELECT 'set', id, 0, unixepoch() * 1000 FROM collection_groups
WHERE NOT EXISTS (SELECT 1 FROM changes c WHERE c.entity = 'set' AND c.id = collection_groups.id) ORDER BY updated_at DESC, id DESC;

INSERT OR IGNORE INTO changes (entity, id, gone, at)
SELECT 'name', id, 0, unixepoch() * 1000 FROM search_names
WHERE NOT EXISTS (SELECT 1 FROM changes c WHERE c.entity = 'name' AND c.id = search_names.id) ORDER BY created_at, id;

INSERT OR IGNORE INTO changes (entity, id, gone, at)
SELECT 'rule', id, 0, unixepoch() * 1000 FROM hidden_rules
WHERE NOT EXISTS (SELECT 1 FROM changes c WHERE c.entity = 'rule' AND c.id = hidden_rules.id) ORDER BY created_at, id;
