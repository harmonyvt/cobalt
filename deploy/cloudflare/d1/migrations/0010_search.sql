-- Library search (APP-API-CONTRACT.md section 21). Additive only: one new table. Apply before
-- deploying the API Worker that reads it.
--
-- One row per library post (the same post key GET /library groups by, app-routes.ts POST_KEY_SQL):
-- its EmbeddingGemma 2 vector from the post's title text and poster, made by the Hugging Face Space
-- (deploy/huggingface/embed). The API Worker's cron fills it (src/embed.ts) and GET /library/search
-- reads it. Rows of posts that are gone are deleted by the same cron.
CREATE TABLE media_embeddings (
    post_key    TEXT PRIMARY KEY,
    model       TEXT NOT NULL,      -- e.g. google/embeddinggemma-2
    dims        INTEGER NOT NULL,   -- 256
    vector      TEXT,               -- base64 of little-endian float32[dims], L2-normalized; NULL after a failure
    input_hash  TEXT NOT NULL,      -- SHA-256 of the inputs (model, dims, title, text, poster): a change re-embeds
    has_image   INTEGER NOT NULL DEFAULT 0, -- 1 when the poster went in with the text
    embedded_at INTEGER,            -- ms; when the vector was made
    failed_at   INTEGER,            -- ms; the last failed attempt for this input_hash (retried an hour later)
    attempts    INTEGER NOT NULL DEFAULT 0 -- failed attempts for this input_hash; 3 = give up until it changes
);
