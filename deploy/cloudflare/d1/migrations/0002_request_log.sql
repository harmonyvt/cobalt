-- Per-request log for keyed API calls (POST /, POST /webp). Holds what a client
-- sent and what came back, never keys. First used to debug the macOS Shortcut
-- sending an empty link (2026-09-30); also the basis for the activity page.
CREATE TABLE request_log (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts            INTEGER NOT NULL,          -- ms since epoch
    route         TEXT NOT NULL,             -- e.g. "POST /", "POST /webp"
    key_id        TEXT,                      -- api_keys.id of the caller
    user_agent    TEXT,
    content_type  TEXT,
    body_bytes    INTEGER,
    body_keys     TEXT,                      -- JSON keys present in the body, comma-separated
    url_type      TEXT,                      -- typeof body.url
    url_len       INTEGER,
    url_prefix    TEXT,                      -- first 80 chars of body.url
    status        INTEGER,                   -- HTTP status returned
    result        TEXT                       -- response `status` field
    , error_code  TEXT                       -- response error.code, if any
);

CREATE INDEX idx_request_log_ts ON request_log (ts DESC);
