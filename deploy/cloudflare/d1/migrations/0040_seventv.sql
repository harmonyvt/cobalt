-- 7TV account (APP-API-CONTRACT.md section 57): the one linked 7TV login. Additive, one empty table.
-- Apply BEFORE the API deploy that serves /7tv; until then the routes answer 503 error.seventv.not_ready.
-- Safe to apply again (IF NOT EXISTS).
--
-- token: AES-GCM, base64(iv).base64(ciphertext), key = HKDF-SHA-256 of COBALT_API_KEY (info "seventv-token").
-- 7TV sessions last 30 days from login; expires_at is the JWT's exp (ms) when it has one.
CREATE TABLE IF NOT EXISTS seventv_account (
    id TEXT PRIMARY KEY CHECK (id = 'main'),
    user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    avatar_url TEXT,
    token TEXT NOT NULL,
    expires_at INTEGER,
    linked_at INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'ok' CHECK (status IN ('ok', 'relink')),
    status_at INTEGER NOT NULL
);
