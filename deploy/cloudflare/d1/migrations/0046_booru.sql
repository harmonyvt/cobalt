-- The booru tab (APP-API-CONTRACT.md section 72): each key's (each device session's) content level and filters.
-- level: 'g' general, 's' sensitive, 'q' questionable. There is no explicit level, ever.
-- themes: JSON {theme id: "show" | "blur" | "hide"}; blacklist: Danbooru-style rules, one per line.
CREATE TABLE IF NOT EXISTS booru_settings (
    key_id TEXT PRIMARY KEY,
    level TEXT NOT NULL DEFAULT 'g' CHECK (level IN ('g', 's', 'q')),
    themes TEXT NOT NULL DEFAULT '{}',
    blacklist TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL
);
