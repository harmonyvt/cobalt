-- Stage (APP-API-CONTRACT.md section 29): the 1080p stream canvas OBS loads, the public viewer store,
-- and Twitch channel-point redemptions. Additive only: new tables, nothing existing is touched, so
-- apply this BEFORE deploying the API Worker (old code never reads it).
--
-- "studio" already means the save/trim session in this codebase, so everything here is `stage`.

-- Exactly one row, id = 'main', created on first read with these defaults (src/stage.ts).
CREATE TABLE stage_settings (
    id                TEXT PRIMARY KEY CHECK (id = 'main'),
    on_air            INTEGER NOT NULL DEFAULT 0,
    pool_kind         TEXT NOT NULL DEFAULT 'library' CHECK (pool_kind IN ('library', 'collection', 'group', 'search')),
    pool_ref          TEXT,                              -- collection or group id, or the search words; NULL for library
    pool_ids          TEXT NOT NULL DEFAULT '[]',        -- JSON array of media_items ids: the resolved pool (<= 2000)
    pool_at           INTEGER NOT NULL DEFAULT 0,        -- ms the pool was last resolved
    density           INTEGER NOT NULL DEFAULT 30,       -- 5..100 tiles on screen
    tile_seconds      INTEGER NOT NULL DEFAULT 10,       -- 3..30
    tile_scale        REAL NOT NULL DEFAULT 1.0,         -- 0.5..1.6
    spotlight_auto    INTEGER NOT NULL DEFAULT 1,
    spotlight_seconds INTEGER NOT NULL DEFAULT 20,       -- 10..120
    sound             INTEGER NOT NULL DEFAULT 1,
    video_max         INTEGER NOT NULL DEFAULT 12,       -- 0..24 tiles playing video at once
    store_open        INTEGER NOT NULL DEFAULT 0,        -- the store starts locked
    store_hint        INTEGER NOT NULL DEFAULT 1,
    live_token        TEXT NOT NULL,                     -- 32 base62: the secret in the OBS URL
    oauth_state       TEXT,                              -- the Twitch connect flow's state (single use)
    oauth_state_at    INTEGER,
    updated_at        INTEGER NOT NULL
);

-- At most one row, id = 'main': the broadcaster the owner connected. The tokens are AES-GCM encrypted
-- (key = HKDF-SHA-256 of TWITCH_CLIENT_SECRET, info "stage-twitch-tokens"), stored base64(iv).base64(ciphertext).
CREATE TABLE stage_twitch (
    id             TEXT PRIMARY KEY CHECK (id = 'main'),
    broadcaster_id TEXT NOT NULL,
    login          TEXT NOT NULL,
    display_name   TEXT NOT NULL,
    access_token   TEXT NOT NULL,
    refresh_token  TEXT NOT NULL,
    expires_at     INTEGER NOT NULL,                     -- ms the access token expires
    scopes         TEXT NOT NULL DEFAULT '',             -- space separated
    eventsub_id    TEXT,                                 -- the webhook subscription, NULL until created
    connected_at   INTEGER NOT NULL,
    last_event_at  INTEGER,
    -- 'setting_up' | 'ok' | 'reconnect' | 'not_affiliate' (what GET /stage reports); status_at is when it last changed
    status         TEXT NOT NULL DEFAULT 'setting_up',
    status_at      INTEGER NOT NULL DEFAULT 0
);

-- One row per action, seeded on first read: summon 500, chaos 2000, shuffle 1000, pin 300.
CREATE TABLE stage_rewards (
    action           TEXT PRIMARY KEY CHECK (action IN ('summon', 'chaos', 'shuffle', 'pin')),
    twitch_reward_id TEXT,                               -- NULL until the reward exists on Twitch
    title            TEXT NOT NULL,                      -- the title used on Twitch (prefixed if the bare word was taken)
    prompt           TEXT NOT NULL,
    cost             INTEGER NOT NULL,
    cooldown_seconds INTEGER NOT NULL,
    enabled          INTEGER NOT NULL,
    synced           INTEGER NOT NULL DEFAULT 0,         -- 1 = Twitch has these values
    updated_at       INTEGER NOT NULL
);

-- Every redemption (Twitch's id) and every owner action ('owner:<16 base62>'). Rows older than 30 days
-- are deleted by the daily cron.
CREATE TABLE stage_redemptions (
    id         TEXT PRIMARY KEY,
    action     TEXT NOT NULL,                            -- summon | chaos | shuffle | pin (owner: also skip | unpin | spotlight)
    user_id    TEXT NOT NULL,
    user_login TEXT NOT NULL,
    user_name  TEXT NOT NULL,
    input      TEXT NOT NULL DEFAULT '',                 -- <= 200
    item_id    TEXT,                                     -- NULL unless a summon resolved
    status     TEXT NOT NULL CHECK (status IN ('done', 'refunded', 'failed')),
    reason     TEXT,                                     -- NULL | off_air | no_match | disabled | error
    created_at INTEGER NOT NULL
);
CREATE INDEX idx_stage_redemptions_at ON stage_redemptions (created_at DESC);
CREATE INDEX idx_stage_redemptions_user ON stage_redemptions (user_id, created_at DESC);

-- A pool item's short code (3 chars, 4 once more than half are used), never changes.
CREATE TABLE stage_codes (
    code       TEXT PRIMARY KEY,                         -- upper case, ABCDEFGHJKLMNPQRSTUVWXYZ23456789
    item_id    TEXT NOT NULL UNIQUE,                     -- media_items.id
    created_at INTEGER NOT NULL
);

-- EventSub message ids seen in the last 10 minutes (Twitch redelivers): a repeat is answered and ignored.
CREATE TABLE stage_seen (
    id      TEXT PRIMARY KEY,
    seen_at INTEGER NOT NULL
);
