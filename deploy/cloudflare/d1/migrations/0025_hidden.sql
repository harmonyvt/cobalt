-- Hidden posts and auto-hide rules (APP-API-CONTRACT.md section 37). Additive only: two new tables and one index.
-- The owner applies it before the API deploy (until then the hidden routes answer 503, no post is hidden, and
-- everything else behaves as before).

-- A post's hidden state, by its GET /library post key. 'hidden': out of the library and never shared (its files are
-- off: not public, no live private link). 'exempt': the owner (or the chat) unhid it, so no rule hides it again (it can
-- still be hidden by hand). 'held': a save that asked to be public waits on an 'about' rule (37.3). No row = normal.
CREATE TABLE media_hidden (
    post_key TEXT PRIMARY KEY,
    state    TEXT NOT NULL CHECK (state IN ('hidden', 'exempt', 'held')),
    by       TEXT NOT NULL CHECK (by IN ('you', 'rule', 'chat')),  -- who set the state
    rule_id  TEXT,                                                -- the rule that hid it; NULL otherwise
    at       INTEGER NOT NULL                                     -- ms
);
CREATE INDEX idx_media_hidden_state ON media_hidden (state, at);

-- A rule that hides new saves (and, on apply, saved posts). value is normalized (lower case, trimmed; '' for upload).
CREATE TABLE hidden_rules (
    id         TEXT PRIMARY KEY,                                 -- 16 base62 characters
    kind       TEXT NOT NULL CHECK (kind IN ('site', 'words', 'about', 'upload')),
    value      TEXT NOT NULL,
    enabled    INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    hits       INTEGER NOT NULL DEFAULT 0,                       -- posts this rule has hidden
    created_at INTEGER NOT NULL,                                 -- ms
    updated_at INTEGER NOT NULL                                  -- ms
);
