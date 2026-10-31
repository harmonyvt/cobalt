-- Shared chats (APP-API-CONTRACT.md section 46). Additive only: one new table and one index.
-- The owner applies it before the API deploy (until then the chat share routes answer 503 and the share host answers
-- /c/* with a 404; everything else behaves as before).

-- A shared chat: share.../c/<key> shows one chat thread up to `upto_id` (its messages after that stay out), with the
-- files it shows streamed through the link. The key is stored as is, like a private link's (section 36): it opens this
-- one chat and nothing else, so the app can always show and copy it. Rotating revokes the row and makes the next one;
-- revoked rows stay.
CREATE TABLE chat_shares (
    key            TEXT PRIMARY KEY,             -- 22 base62 characters (~131 bits)
    thread_id      TEXT NOT NULL,                -- chat_threads.id
    upto_id        INTEGER NOT NULL,             -- the last chat_messages.id the page shows
    media          INTEGER NOT NULL DEFAULT 1,   -- 1: the chat's videos and pictures play on the page; 0: titles only
    code           INTEGER NOT NULL DEFAULT 0,   -- 1: the model's code is on the page (folded); 0: left out
    files          TEXT NOT NULL DEFAULT '[]',   -- JSON: the media_items ids the link streams, in page order (/c/<key>/<n>)
    created_at     INTEGER NOT NULL,             -- ms
    updated_at     INTEGER NOT NULL,             -- ms: settings or upto_id changed
    revoked_at     INTEGER,                      -- ms; NULL = live
    opened         INTEGER NOT NULL DEFAULT 0,   -- page GETs (not HEAD, not file fetches)
    last_opened_at INTEGER                       -- ms
);
-- at most one live link per chat
CREATE UNIQUE INDEX idx_chat_shares_live ON chat_shares (thread_id) WHERE revoked_at IS NULL;
