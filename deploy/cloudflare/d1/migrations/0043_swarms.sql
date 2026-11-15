-- Agent swarms (APP-API-CONTRACT.md section 59): one JSON program splits a list of items into batches and runs one
-- Haiku task per batch, after Harmony approves it. The `Swarm` Durable Object (src/swarm-do.ts) runs the tasks in its
-- alarm; everything it knows lives here, so a deploy or an eviction picks up from D1.

-- One swarm. `spec` is the checked program without its items (they are in swarm_tasks); `spec_hash` covers the program,
-- the frozen batches and `round` (a retry starts a new round, so an old approval never matches again).
CREATE TABLE swarms (
    id TEXT PRIMARY KEY,
    -- who planned it: a client key id, chat:<thread>, or the MCP's client key
    key_id TEXT NOT NULL,
    name TEXT NOT NULL,
    mode TEXT NOT NULL,
    spec TEXT NOT NULL,
    spec_hash TEXT NOT NULL,
    round INTEGER NOT NULL DEFAULT 1,
    -- awaiting_approval | running | stopping | done | failed | stopped | declined | expired
    status TEXT NOT NULL,
    item_count INTEGER NOT NULL,
    task_count INTEGER NOT NULL,
    est_low REAL NOT NULL,
    est_high REAL NOT NULL,
    cap_usd REAL NOT NULL,
    spent_usd REAL NOT NULL DEFAULT 0,
    stop_requested INTEGER NOT NULL DEFAULT 0,
    -- propose mode: none | ready | applying | applied | failed
    apply_status TEXT NOT NULL DEFAULT 'none',
    approved_by TEXT,
    reduce_result TEXT,
    error TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    approved_at INTEGER,
    finished_at INTEGER,
    expires_at INTEGER
);
CREATE INDEX swarms_key ON swarms (key_id, created_at);
CREATE INDEX swarms_status ON swarms (status);

-- One task (one batch). `state` is its conversation so far, so a task cut off by the alarm's time budget goes on where it
-- stopped; it is cleared when an attempt ends.
CREATE TABLE swarm_tasks (
    swarm TEXT NOT NULL,
    idx INTEGER NOT NULL,
    items TEXT NOT NULL,
    -- queued | running | done | failed | skipped
    status TEXT NOT NULL DEFAULT 'queued',
    attempts INTEGER NOT NULL DEFAULT 0,
    requeues INTEGER NOT NULL DEFAULT 0,
    thread_id TEXT,
    state TEXT,
    result TEXT,
    error TEXT,
    in_tokens INTEGER NOT NULL DEFAULT 0,
    out_tokens INTEGER NOT NULL DEFAULT 0,
    usd REAL NOT NULL DEFAULT 0,
    started_at INTEGER,
    heartbeat_at INTEGER,
    ended_at INTEGER,
    PRIMARY KEY (swarm, idx)
);

-- Propose mode: the changes the tasks proposed, numbered in task order. Harmony ticks (`keep`) and edits (`after`) them on
-- the review page; the executor applies the kept ones.
CREATE TABLE swarm_changes (
    swarm TEXT NOT NULL,
    n INTEGER NOT NULL,
    task INTEGER NOT NULL,
    op TEXT NOT NULL,
    args TEXT NOT NULL,
    target TEXT,
    before TEXT,
    after TEXT,
    edit_arg TEXT,
    preview_url TEXT,
    keep INTEGER NOT NULL DEFAULT 1,
    -- proposed | applying | done | failed | skipped
    status TEXT NOT NULL DEFAULT 'proposed',
    error TEXT,
    clash TEXT,
    PRIMARY KEY (swarm, n)
);

-- The idempotency ledger: every write a swarm made (act-mode tasks and the apply executor). A retried task or a second
-- apply skips a write that is already here.
CREATE TABLE swarm_writes (
    swarm TEXT NOT NULL,
    op TEXT NOT NULL,
    args_hash TEXT NOT NULL,
    task INTEGER,
    -- 'pending' is written before the write runs, 'done' after it: a pending row an alarm left behind means unknown
    status TEXT NOT NULL DEFAULT 'done',
    result TEXT,
    at INTEGER NOT NULL,
    PRIMARY KEY (swarm, op, args_hash)
);

-- Dollars spent on swarm model calls per UTC day (SWARM_DAILY_USD).
CREATE TABLE swarm_spend (
    day TEXT PRIMARY KEY,
    usd REAL NOT NULL DEFAULT 0
);
