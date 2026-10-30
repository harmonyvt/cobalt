-- "What it's about" (APP-API-CONTRACT.md section 34). Additive only: two new tables and one new nullable column.
-- The owner applies it before the API deploy.

-- One row per library post (the GET /library post key): its frames and sound (the container's probe, 34.2) and the
-- words Claude Haiku wrote from them (34.3). The words go into the post's search vector (34.4).
CREATE TABLE media_about (
    post_key       TEXT PRIMARY KEY,
    item_id        TEXT NOT NULL,              -- the lead file (embed.ts postInputs' pick)
    probe_state    TEXT NOT NULL DEFAULT 'pending', -- 'pending' | 'done' | 'none' (no video to cut: an image) | 'failed'
    probe_at       INTEGER,                    -- ms, the last probe attempt
    probe_attempts INTEGER NOT NULL DEFAULT 0,
    frames         INTEGER NOT NULL DEFAULT 0, -- frame pictures stored in R2 about/<item id>/frame-N.jpg, 0..3
    has_audio      INTEGER NOT NULL DEFAULT 0, -- 1: about/<item id>/audio.mp3 is stored
    transcript     TEXT,                       -- Whisper's text, <= 4000 characters; NULL: no speech or no sound
    language       TEXT,
    sentence       TEXT,                       -- <= 160 characters
    tags           TEXT,                       -- JSON array, what Haiku wrote
    sound_tags     TEXT,                       -- JSON array
    user_tags      TEXT,                       -- JSON array; when not NULL it replaces `tags` everywhere (the owner's edit)
    model          TEXT,
    input_hash     TEXT,                       -- what the words were written from (a change rewrites them)
    written_at     INTEGER,                    -- ms
    failed_at      INTEGER,                    -- ms, the last failed write for input_hash
    attempts       INTEGER NOT NULL DEFAULT 0, -- failed writes for input_hash; 3 = wait until it changes
    updated_at     INTEGER NOT NULL
);
CREATE INDEX idx_media_about_item ON media_about (item_id);

-- The word list for "reads closest to" (34.5): starter words and every tag any post has, each with its query vector and
-- its average cosine over every indexed post (refreshed by the cron).
CREATE TABLE embed_terms (
    term       TEXT PRIMARY KEY,
    source     TEXT NOT NULL,                  -- 'starter' | 'tag'
    model      TEXT,
    dims       INTEGER,
    vector     TEXT,                           -- base64 float32 like media_embeddings.vector; NULL until embedded
    mean       REAL,
    created_at INTEGER NOT NULL
);

-- A chat reply's scored list (34.6, cobalt.rank): JSON { "title", "query", "within", "hits": [...] } or NULL.
ALTER TABLE chat_messages ADD COLUMN ranked TEXT;
