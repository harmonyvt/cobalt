-- Custom titles (APP-API-CONTRACT.md section 15, apple/CONTRACT-LIBRARY2.md section 6).
-- Additive only: one new table. Nothing is rewritten and no existing query changes
-- meaning, so apply this BEFORE deploying the API and web Workers (old code never
-- reads or writes it).
--
-- One custom title per POST, keyed by the same post key GET /library groups by
-- (api/src/app-routes.ts POST_KEY_SQL). A post with no row here has no custom title
-- (the app shows its default); the row is independent of whichever file carries the
-- post, so deleting one of its files never loses it. Deleting the whole post removes it.
CREATE TABLE media_titles (
    post_key   TEXT PRIMARY KEY,
    title      TEXT NOT NULL,      -- 1..80 code points, trimmed, no control characters
    key_id     TEXT,               -- api_keys.id (or service:library) that set it
    updated_at INTEGER NOT NULL    -- ms
);
