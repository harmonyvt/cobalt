-- Chat (APP-API-CONTRACT.md section 27). Additive only: two new tables.
-- A thread is a conversation with Claude about the library; its messages are the user's and the
-- model's turns. `api` keeps the model's own turn (tool calls and results) so a thread can continue.
CREATE TABLE chat_threads (
    id          TEXT PRIMARY KEY,      -- 16 random letters and digits
    title       TEXT NOT NULL,         -- 1..60 code points
    titled_by   TEXT NOT NULL DEFAULT 'auto', -- 'auto' (first message), 'model' or 'user'
    key_id      TEXT,                  -- api_keys.id that made it
    created_at  INTEGER NOT NULL,      -- ms
    updated_at  INTEGER NOT NULL       -- ms: renamed or a message added
);
CREATE TABLE chat_messages (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id   TEXT NOT NULL,
    role        TEXT NOT NULL,         -- 'user' or 'assistant'
    text        TEXT NOT NULL DEFAULT '',
    post_ids    TEXT NOT NULL DEFAULT '[]', -- JSON array of library post ids
    steps       TEXT NOT NULL DEFAULT '[]', -- JSON array of code steps (assistant)
    api         TEXT,                  -- JSON: the model's messages for this reply (assistant)
    status      TEXT NOT NULL DEFAULT 'done', -- 'done', 'running' or 'error'
    error       TEXT,
    created_at  INTEGER NOT NULL,      -- ms
    updated_at  INTEGER NOT NULL       -- ms
);
CREATE INDEX idx_chat_messages_thread ON chat_messages (thread_id, id);
