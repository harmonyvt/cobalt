-- Editor (APP-API-CONTRACT.md section 31, apple/CONTRACT-EDITOR.md). Additive only: two new tables.
-- A project is a timeline saved for every device; a render is one revision of it made into an MP4 by the render container.
CREATE TABLE edit_projects (
    id          TEXT PRIMARY KEY,      -- 16 base62
    title       TEXT NOT NULL,         -- 1..80 code points, trimmed, no control characters (section 15.2 rules)
    timeline    TEXT NOT NULL,         -- canonical JSON (31.2), <= 64 KiB
    revision    INTEGER NOT NULL,      -- 1 at create, +1 on every change (timeline or title)
    canvas_w    INTEGER NOT NULL,      -- copied from the timeline for the list (no JSON parse there)
    canvas_h    INTEGER NOT NULL,
    fps         INTEGER NOT NULL,
    frames      INTEGER NOT NULL,      -- N (31.4)
    clip_count  INTEGER NOT NULL,      -- main + overlay
    cover_item  TEXT,                  -- media_items.id of main[0].item (its poster is the project's cover)
    key_id      TEXT,                  -- api_keys.id that created it (bookkeeping; every key of the owner sees every project)
    updated_key TEXT,                  -- api_keys.id of the last change
    created_at  INTEGER NOT NULL,      -- ms
    updated_at  INTEGER NOT NULL,
    deleted_at  INTEGER                -- soft delete
);
CREATE INDEX idx_edit_projects_listing ON edit_projects (deleted_at, updated_at DESC);

CREATE TABLE edit_renders (
    id              TEXT PRIMARY KEY,  -- 20 base62 (like a render job id)
    project_id      TEXT NOT NULL,
    revision        INTEGER NOT NULL,  -- the project revision this renders
    title           TEXT NOT NULL,     -- the project title at render time (the result's name and title)
    timeline        TEXT NOT NULL,     -- the canonical timeline of that revision (the project may change meanwhile)
    status          TEXT NOT NULL,     -- 'queued' | 'preparing' | 'rendering' | 'finishing' | 'done' | 'error' | 'cancelled'
    cancel_requested INTEGER NOT NULL DEFAULT 0,
    instance        TEXT,              -- 'r0' | 'r1': the EditRenderer that claimed it
    attempts        INTEGER NOT NULL DEFAULT 0,  -- claims (a lost container restarts it once: 31.9)
    input_bytes     INTEGER,           -- sum of the inputs' bytes
    sent_bytes      INTEGER,           -- inputs streamed into the container so far
    seconds_done    REAL,              -- encoded so far (ffmpeg out_time)
    seconds_total   REAL NOT NULL,     -- N / F
    error_code      TEXT,
    item_id         TEXT,              -- media_items.id of the result
    bytes           INTEGER,
    width           INTEGER,
    height          INTEGER,
    duration        REAL,
    notify          INTEGER NOT NULL DEFAULT 0,  -- 1: one Hark message when it ends (31.11)
    notified_at     INTEGER,
    key_id          TEXT,              -- who asked
    created_at      INTEGER NOT NULL,
    started_at      INTEGER,           -- claimed
    updated_at      INTEGER NOT NULL,  -- every progress write (the stale check, 31.9)
    finished_at     INTEGER
);
CREATE INDEX idx_edit_renders_status ON edit_renders (status, created_at);
CREATE INDEX idx_edit_renders_project ON edit_renders (project_id, created_at DESC);
