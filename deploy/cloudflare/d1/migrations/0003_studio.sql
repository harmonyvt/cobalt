-- cobalt studio (see STUDIO-CONTRACT.md): a session is one saved source video
-- (private copy in R2 `cobalt-originals`, key originals/<id>.<ext>) that the
-- studio page renders animated WebPs from. Timestamps are ms since epoch.
-- The session id is a capability (22 base62 chars); nothing here holds keys.
CREATE TABLE studio_sessions (
    id           TEXT PRIMARY KEY,
    key_id       TEXT,                  -- api_keys.id that created it
    link         TEXT,                  -- the http(s) link that was saved (never the raw share text)
    service      TEXT,                  -- second-level host label, e.g. "x"
    title        TEXT,                  -- from cobalt's filename, when it gave one
    status       TEXT NOT NULL,         -- saving | ready | error
    error_code   TEXT,                  -- set when status = error
    r2_key       TEXT,                  -- originals/<id>.<ext>, set when ready
    content_type TEXT,
    bytes        INTEGER,
    duration     REAL,                  -- seconds; null when ffmpeg could not tell
    width        INTEGER,
    height       INTEGER,
    created_at   INTEGER NOT NULL,
    expires_at   INTEGER NOT NULL       -- created_at + 7 days; expired sessions answer 410
);

CREATE INDEX idx_studio_sessions_key ON studio_sessions (key_id, created_at DESC);
CREATE INDEX idx_studio_sessions_expires ON studio_sessions (expires_at);

-- One row per render request of a session (one encode at a time).
CREATE TABLE studio_renders (
    id          TEXT PRIMARY KEY,       -- job id, 20 base62 chars
    session_id  TEXT NOT NULL,          -- studio_sessions.id
    status      TEXT NOT NULL,          -- pending | success | error
    error_code  TEXT,
    url         TEXT,                   -- public https://media.../<name>.webp when success
    start       REAL,
    length      REAL,
    width       INTEGER,                -- requested width, never above the source width
    quality     TEXT,                   -- low | med | high
    bytes       INTEGER,
    out_width   INTEGER,
    out_height  INTEGER,
    seconds     REAL,
    created_at  INTEGER NOT NULL
);

CREATE INDEX idx_studio_renders_session ON studio_renders (session_id, created_at DESC);
