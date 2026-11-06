-- Stage reward `skip` (APP-API-CONTRACT.md section 30). Additive: the only change is that
-- stage_rewards.action may be 'skip'. SQLite cannot alter a CHECK, so the table is rebuilt and
-- every existing row is copied. Nothing else is touched. Apply before the API deploy.
-- The skip row itself is inserted by the API on read (INSERT OR IGNORE, same as the other rewards).

CREATE TABLE stage_rewards_next (
    action           TEXT PRIMARY KEY CHECK (action IN ('summon', 'chaos', 'shuffle', 'pin', 'skip')),
    twitch_reward_id TEXT,
    title            TEXT NOT NULL,
    prompt           TEXT NOT NULL,
    cost             INTEGER NOT NULL,
    cooldown_seconds INTEGER NOT NULL,
    enabled          INTEGER NOT NULL,
    synced           INTEGER NOT NULL DEFAULT 0,
    updated_at       INTEGER NOT NULL
);

INSERT INTO stage_rewards_next (action, twitch_reward_id, title, prompt, cost, cooldown_seconds, enabled, synced, updated_at)
SELECT action, twitch_reward_id, title, prompt, cost, cooldown_seconds, enabled, synced, updated_at FROM stage_rewards;

DROP TABLE stage_rewards;

ALTER TABLE stage_rewards_next RENAME TO stage_rewards;
