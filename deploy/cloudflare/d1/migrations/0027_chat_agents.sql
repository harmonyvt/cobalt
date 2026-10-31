-- Sub-agents for the chat AI and MCP (APP-API-CONTRACT.md section 43). Additive only: two new tables and two indexes.
-- The owner applies it before the API deploy (until then cobalt.agents.* answers 503 and everything else behaves as
-- before).

-- A sub-agent: a chat AI working on one task for a parent (a chat thread or an MCP thread). Its own steps and messages
-- live in chat_threads / chat_messages under the same id, so the app can open it like a thread (it is left out of the
-- thread list).
CREATE TABLE chat_agents (
    id         TEXT PRIMARY KEY,                -- 16 letters and digits: also its chat_threads id
    parent     TEXT NOT NULL,                   -- the parent thread id (a chat thread, or an MCP thread)
    name       TEXT NOT NULL,                   -- 1..40 code points, unique among the parent's agents
    task       TEXT NOT NULL,                   -- what the parent asked, 1..4000 characters
    status     TEXT NOT NULL CHECK (status IN ('queued', 'running', 'done', 'error', 'stopped')),
    result     TEXT,                            -- its last reply's text when it ended
    post_ids   TEXT NOT NULL DEFAULT '[]',      -- JSON: the posts it showed
    error      TEXT,                            -- an error code when status is 'error'
    activity   TEXT,                            -- what it is doing now ("library.search"), while running
    turns      INTEGER NOT NULL DEFAULT 0,      -- replies it ran (its task, then each wake by a message)
    created_at INTEGER NOT NULL,                -- ms
    updated_at INTEGER NOT NULL,                -- ms
    ended_at   INTEGER                          -- ms: its last reply ended
);
CREATE INDEX idx_chat_agents_parent ON chat_agents (parent, created_at);

-- Messages between a parent and its agents, and between sibling agents. sender / recipient: 'parent' or an agent id.
CREATE TABLE chat_agent_mail (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    parent     TEXT NOT NULL,
    sender     TEXT NOT NULL,
    recipient  TEXT NOT NULL,
    text       TEXT NOT NULL,                   -- 1..2000 characters
    created_at INTEGER NOT NULL,                -- ms
    read_at    INTEGER                          -- ms: the recipient got it; NULL while unread
);
CREATE INDEX idx_chat_agent_mail_to ON chat_agent_mail (parent, recipient, read_at);
