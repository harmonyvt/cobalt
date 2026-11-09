-- Post frames (APP-API-CONTRACT.md section 52.1): what a saved post showed (who posted it, when, what they wrote, the counts),
-- one row per source link, so a framed copy can be drawn after the post is gone. Additive only: a new table. Old code never
-- reads it; apply before deploying the API.
CREATE TABLE IF NOT EXISTS post_details (
    link        TEXT PRIMARY KEY,
    site        TEXT NOT NULL,           -- 'x' | 'instagram' | 'twitch' | 'youtube' | 'generic'
    found       INTEGER NOT NULL DEFAULT 0,
    name        TEXT,
    handle      TEXT,
    text        TEXT,
    title       TEXT,
    channel     TEXT,
    game        TEXT,
    clipper     TEXT,
    site_name   TEXT,
    posted_at   INTEGER,
    counts      TEXT,                    -- JSON {likes, reposts, replies, views, comments, subscribers}
    verified    INTEGER NOT NULL DEFAULT 0,
    avatar_key  TEXT,                    -- cobalt-originals key (post-avatars/<sha256>)
    fetched_at  INTEGER NOT NULL,
    edited_at   INTEGER
);
