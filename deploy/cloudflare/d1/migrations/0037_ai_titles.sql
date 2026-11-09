-- AI video titles (APP-API-CONTRACT.md section 53). Additive only: one new table. Apply before the API deploy
-- (old code never reads or writes it; new code without it just logs and writes nothing).
--
-- One row per post the title pass has looked at: what MiniMax was given (the lead video), what it answered and
-- what that cost. The title itself is written to media_titles with key_id 'ai:titles', so every reader of custom
-- titles shows it; a title the owner set (any other key_id) is never replaced. Undo all AI titles with
-- DELETE FROM media_titles WHERE key_id = 'ai:titles' (the file names are untouched).
CREATE TABLE media_ai_titles (
    post_key          TEXT PRIMARY KEY,
    item_id           TEXT NOT NULL,     -- the lead video that was watched
    state             TEXT NOT NULL CHECK (state IN ('done', 'failed', 'skipped')),
    title             TEXT,              -- what the model wrote (also when the owner's title kept it out)
    model             TEXT,
    style             TEXT,              -- AI_TITLE_STYLE when written; a new style rewrites every AI title
    with_transcript   INTEGER NOT NULL DEFAULT 0,
    prompt_tokens     INTEGER,
    completion_tokens INTEGER,
    cost              REAL,              -- USD, as OpenRouter reported it
    attempts          INTEGER NOT NULL DEFAULT 0,
    error             TEXT,
    updated_at        INTEGER NOT NULL   -- ms
);
