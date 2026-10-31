-- Search names (APP-API-CONTRACT.md section 48): words the owner teaches library search, like "Lia" = "pink-haired cat
-- girl". Additive only: two new tables and one index. The owner applies it before the API deploy (until then the names
-- routes answer 503 and search behaves exactly as before).

-- One taught word. name_key and every alias are normalized (lower case, trimmed, single spaces) and unique across all
-- names (checked in code). vector is the meaning embedded in query mode; point is what search mixes in: the meaning and
-- the example posts' average blended by strength (48.2). Both are base64 float32 like media_embeddings.vector.
CREATE TABLE search_names (
    id           TEXT PRIMARY KEY,                               -- 16 base62 characters
    name         TEXT NOT NULL,                                  -- as typed, 1..40 characters
    name_key     TEXT NOT NULL UNIQUE,                           -- normalized name
    aliases      TEXT NOT NULL DEFAULT '[]',                     -- JSON array of normalized words, at most 8
    meaning      TEXT NOT NULL,                                  -- 1..300 characters
    strength     REAL NOT NULL DEFAULT 0.5,                      -- 0 = only the words, 1 = only the examples
    cutoff       REAL NOT NULL DEFAULT 0.5,                      -- cosine a post needs to carry the name
    enabled      INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    model        TEXT,
    dims         INTEGER,
    vector       TEXT,                                           -- the meaning's vector; NULL until embedded
    meaning_hash TEXT,                                           -- SHA-256 of the meaning the vector was made from
    point        TEXT,                                           -- NULL when there is neither a vector nor an example
    created_at   INTEGER NOT NULL,                               -- ms
    updated_at   INTEGER NOT NULL                                -- ms
);

-- Posts the owner marked: 'yes' (this is it, always carries the name) or 'no' (this is not, never carries it).
CREATE TABLE search_name_posts (
    name_id    TEXT NOT NULL,
    post_key   TEXT NOT NULL,
    kind       TEXT NOT NULL CHECK (kind IN ('yes', 'no')),
    created_at INTEGER NOT NULL,                                 -- ms
    PRIMARY KEY (name_id, post_key)
);
CREATE INDEX idx_search_name_posts_post ON search_name_posts (post_key);
