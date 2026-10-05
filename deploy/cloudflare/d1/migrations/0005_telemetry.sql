-- Self-hosted crash and log telemetry from the native app (see
-- TELEMETRY-CONTRACT.md). Additive only: two new tables and their indexes.
-- Timestamps are ms since epoch. `ts` is the device's clock (when it happened),
-- `received_at` is the server's (when it arrived; retention runs on it).
-- Rows are deleted after 30 days by the API Worker's daily cron.

-- One row per log event. `data` is a flat JSON object (string/number/bool values)
-- or NULL. id is deterministic (hash of install, ts, level, cat, msg, data) so a
-- batch retried after a lost response does not duplicate rows (INSERT OR IGNORE).
CREATE TABLE telemetry_events (
    id          TEXT PRIMARY KEY,
    key_id      TEXT,               -- api_keys.id that sent the batch
    install     TEXT,               -- the app's per-install uuid
    ts          INTEGER NOT NULL,
    level       TEXT NOT NULL,      -- debug | info | warn | error
    cat         TEXT NOT NULL,      -- app | pipeline | upload | share | photos | sync | net | store | ui | live
    msg         TEXT NOT NULL,
    data        TEXT,
    version     TEXT,
    build       TEXT,
    platform    TEXT,               -- ios | macos
    device      TEXT,
    process     TEXT,               -- app | share | widgets
    received_at INTEGER NOT NULL
);

CREATE INDEX idx_telemetry_events_ts ON telemetry_events (ts DESC, id DESC);
CREATE INDEX idx_telemetry_events_received ON telemetry_events (received_at);
CREATE INDEX idx_telemetry_events_level ON telemetry_events (level, ts DESC);

-- One row per crash, hang, cpu/disk exception, launch diagnostic or unclean exit.
-- The MetricKit payload and the events leading up to it live in the PRIVATE R2
-- bucket cobalt-originals at r2_key (telemetry/crashes/<yyyy-mm-dd>/<id>.json).
CREATE TABLE telemetry_crashes (
    id          TEXT PRIMARY KEY,   -- deterministic, like telemetry_events.id
    key_id      TEXT,
    install     TEXT,
    ts          INTEGER NOT NULL,
    kind        TEXT NOT NULL,      -- crash | hang | cpu | disk | launch | unclean_exit
    summary     TEXT NOT NULL,
    r2_key      TEXT NOT NULL,
    version     TEXT,
    build       TEXT,
    platform    TEXT,
    device      TEXT,
    process     TEXT,
    received_at INTEGER NOT NULL
);

CREATE INDEX idx_telemetry_crashes_ts ON telemetry_crashes (ts DESC, id DESC);
CREATE INDEX idx_telemetry_crashes_received ON telemetry_crashes (received_at);
CREATE INDEX idx_telemetry_crashes_kind ON telemetry_crashes (kind, ts DESC);
