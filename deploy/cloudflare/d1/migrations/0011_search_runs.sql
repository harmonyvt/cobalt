-- The search indexer's runs (APP-API-CONTRACT.md sections 21 and 23). Additive only: one new table.
-- Apply before or after deploying the API Worker: without it the indexer still runs, it only keeps
-- no record (and GET /queue says null for running, last_run_at and rate_per_hour).
--
-- One row per run of src/embed.ts drainIndexer: the 15-minute cron's drain, or POST
-- /library/search/index. Updated after each pass while it runs; rows older than 7 days are deleted
-- when a new run starts.
CREATE TABLE search_index_runs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    trigger     TEXT NOT NULL,              -- 'cron' | 'request'
    started_at  INTEGER NOT NULL,           -- ms
    finished_at INTEGER,                    -- ms; NULL while running (or if the Worker died)
    passes      INTEGER NOT NULL DEFAULT 0,
    indexed     INTEGER NOT NULL DEFAULT 0, -- posts embedded by this run
    failed      INTEGER NOT NULL DEFAULT 0, -- posts the Space refused in this run
    unavailable INTEGER NOT NULL DEFAULT 0, -- 1 when the last pass found the Space asleep or down
    stop        TEXT                        -- empty | unavailable | budget | stalled | passes | error; NULL while running
);
CREATE INDEX idx_search_index_runs_started ON search_index_runs (started_at);
