-- Swarms in the apps (APP-API-CONTRACT.md section 61): messages between a swarm's agents and the agent that planned it
-- (or Harmony), a short step log per agent, and each agent's counts for its outcome and score (section 62.3). Additive: one
-- new table, three new columns on swarm_tasks.

-- One message. `dir` 'up' is an agent to its owner ('ask' waits for an answer, 'tell' is a report); 'down' is the owner or
-- Harmony to one agent (`task` = its idx) or to every agent (`task` NULL): 'reply' answers an open ask, 'note' is anything
-- else. `read_at` is the owner's inbox (NULL = unread, up messages only); `answered_at` marks an answered ask.
CREATE TABLE swarm_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    swarm TEXT NOT NULL,
    task INTEGER,
    -- up | down
    dir TEXT NOT NULL,
    -- ask | tell | reply | note
    kind TEXT NOT NULL,
    -- agent | owner | you
    sender TEXT NOT NULL,
    text TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    read_at INTEGER,
    answered_at INTEGER
);
CREATE INDEX swarm_messages_swarm ON swarm_messages (swarm, id);

-- The last 20 steps of an agent, JSON [{ at, text }] (text at most 80 characters), written by the runner.
ALTER TABLE swarm_tasks ADD COLUMN steps TEXT;
-- Set while the agent waits for an answer to its question (status 'waiting'): when the question was asked.
ALTER TABLE swarm_tasks ADD COLUMN asked_at INTEGER;
-- Section 62.3: the agent's counts, JSON { tool_calls, tool_errors, waits, turns, answered, score } (score 0..1 once it ended).
ALTER TABLE swarm_tasks ADD COLUMN stats TEXT;
