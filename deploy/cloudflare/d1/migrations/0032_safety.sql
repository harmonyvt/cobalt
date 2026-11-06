-- Per-file safety ratings (APP-API-CONTRACT.md section 51). Additive only: one new table.
-- The owner applies it before the API deploy. Until then the stage treats every file as unrated.

-- One row per media item (not per post). Clef-omni is the only automated gate. `user_level` is Harmony's
-- override and wins over `level` everywhere except `minor_sexual`, which hard-blocks whatever the level says.
-- `probs` keeps every answer's probabilities so a threshold change does not re-rate. A question change does
-- (`questions_version`). Derived files with no rating of their own inherit in code, not in this table.
CREATE TABLE media_safety (
    item_id           TEXT PRIMARY KEY,                                          -- media_items.id
    level             TEXT NOT NULL DEFAULT 'pending'
                      CHECK (level IN ('general', 'sensitive', 'questionable', 'explicit', 'pending', 'failed')),
    probs             TEXT,                                                      -- JSON: { level: {general,sensitive,questionable,explicit}, gore, drawn, minor_sexual }
    gore              INTEGER NOT NULL DEFAULT 0 CHECK (gore IN (0, 1)),         -- snapshot at rate time; the stage re-reads `probs` when it is there
    drawn             INTEGER NOT NULL DEFAULT 0 CHECK (drawn IN (0, 1)),
    minor_sexual      INTEGER NOT NULL DEFAULT 0 CHECK (minor_sexual IN (0, 1)),
    user_level        TEXT CHECK (user_level IS NULL OR user_level IN ('general', 'sensitive', 'questionable', 'explicit')),
    model             TEXT,                                                      -- @cf/cloudflare/clef-omni
    questions_version TEXT,                                                      -- bumping the questions re-rates
    input_hash        TEXT,                                                      -- what this rating was decided from
    rated_at          INTEGER,                                                   -- ms
    failed_at         INTEGER,                                                   -- ms, the last failed Clef call
    attempts          INTEGER NOT NULL DEFAULT 0,                                -- failed Clef calls; 3 = wait until the input changes
    prep              TEXT NOT NULL DEFAULT 'pending' CHECK (prep IN ('pending', 'ready', 'failed')),
    prep_at           INTEGER,                                                   -- ms, the last clip attempt
    prep_attempts     INTEGER NOT NULL DEFAULT 0,
    clips             INTEGER NOT NULL DEFAULT 0,                                -- safety mp4 parts in R2, 0..2
    stills            INTEGER NOT NULL DEFAULT 0,                                -- 768 px jpegs, 0..4
    has_audio         INTEGER NOT NULL DEFAULT 0 CHECK (has_audio IN (0, 1)),    -- about/<id>/safety-audio.mp3, first 300 s
    updated_at        INTEGER NOT NULL
);
CREATE INDEX idx_media_safety_due ON media_safety (prep, level);
