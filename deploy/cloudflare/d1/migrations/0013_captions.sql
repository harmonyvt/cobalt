-- Roast captions (APP-API-CONTRACT.md section 25). Additive only: one new table.
-- One AI-written title and description per public file ('item:<media_items id>') or gallery link
-- ('set:<share_sets id>'), written once by Claude Haiku and shown in link previews.
-- A failed attempt keeps title NULL and is retried after a day, at most 3 times.
CREATE TABLE media_captions (
    subject     TEXT PRIMARY KEY,      -- 'item:<id>' or 'set:<id>'
    title       TEXT,                  -- NULL until written
    description TEXT,
    model       TEXT,
    created_at  INTEGER NOT NULL,      -- ms, last attempt
    attempts    INTEGER NOT NULL DEFAULT 0
);
