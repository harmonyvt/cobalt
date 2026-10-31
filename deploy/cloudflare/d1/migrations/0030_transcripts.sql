-- Timed transcripts and moments (APP-API-CONTRACT.md section 47). Additive only: two new tables. The owner applies it
-- before the API deploy (until then GET /library/transcript answers every post as "pending", search has no `said`, and
-- the cron's listening and moment passes only log).

-- What Whisper heard in a post's sound, with the time of every word. One row per post (the GET /library post key),
-- for the probe it heard (item_id + probe_at, media_about). lines: JSON
-- [{ "s": <start s>, "e": <end s>, "t": "<line text>", "w": [{ "t": "<word>", "s": <s>, "e": <s> }, ...] }, ...].
CREATE TABLE media_transcripts (
    post_key   TEXT PRIMARY KEY,
    item_id    TEXT NOT NULL,
    probe_at   INTEGER,                                          -- media_about.probe_at of the sound heard
    state      TEXT NOT NULL CHECK (state IN ('done', 'no_speech', 'failed')),
    language   TEXT,
    text       TEXT,                                             -- the lines' words, joined (null without speech)
    lines      TEXT,                                             -- JSON, see above
    model      TEXT,                                             -- the Whisper model + line version
    attempts   INTEGER NOT NULL DEFAULT 0,                       -- failures of this probe in a row
    failed_at  INTEGER,                                          -- ms
    created_at INTEGER NOT NULL,                                 -- ms
    updated_at INTEGER NOT NULL                                  -- ms
);

-- A stretch of a transcript (consecutive lines, about 120 characters or 12 s) and its search vector, for "moments by
-- meaning": the search finds the moment, not just the post.
CREATE TABLE media_moments (
    post_key   TEXT NOT NULL,
    idx        INTEGER NOT NULL,                                 -- 0.. in the post
    start      REAL NOT NULL,                                    -- s
    "end"      REAL NOT NULL,                                    -- s
    text       TEXT NOT NULL,
    input_hash TEXT NOT NULL,
    model      TEXT,
    dims       INTEGER,
    vector     TEXT,                                             -- base64 float32, like media_embeddings.vector
    updated_at INTEGER NOT NULL,                                 -- ms
    PRIMARY KEY (post_key, idx)
);
