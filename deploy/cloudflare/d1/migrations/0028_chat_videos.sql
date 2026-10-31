-- Chat videos (APP-API-CONTRACT.md section 45). Additive only: two columns on edit_renders.
-- A chat render is a second kind of editor render: `kind` 'chat', `thread_id` the chat thread, `project_id` "chat:<thread id>"
-- and `timeline` the frozen chat spec (45.4). Old code never sees a 'chat' row (only the new route makes them), so apply this
-- BEFORE deploying the API.
ALTER TABLE edit_renders ADD COLUMN kind TEXT NOT NULL DEFAULT 'edit';
ALTER TABLE edit_renders ADD COLUMN thread_id TEXT;
