-- Chat collages (APP-API-CONTRACT.md section 27.5): an assistant message can carry one big set of
-- results (up to 500 posts, e.g. every cat), shown as a paged masonry collage in the app.
-- JSON { "title": string|null, "ids": [post ids] }, or NULL.
ALTER TABLE chat_messages ADD COLUMN collage TEXT;
