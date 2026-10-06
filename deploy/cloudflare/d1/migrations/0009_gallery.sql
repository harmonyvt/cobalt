-- Photos and galleries (APP-API-CONTRACT.md section 18, apple/CONTRACT-GALLERY.md). Additive only. Apply BEFORE deploying.
-- A gallery is one studio session whose items are N media_items rows sharing its session_id (one post).
ALTER TABLE media_items ADD COLUMN item_index INTEGER;   -- 0-based position in the source post; NULL = not a gallery item
ALTER TABLE media_items ADD COLUMN role TEXT;            -- 'item' | 'slideshow' | 'crop' | 'export'; NULL = legacy meaning (by source)
ALTER TABLE media_items ADD COLUMN made_from TEXT;       -- slideshow/crop/export: JSON array of the media_items ids it was made from
ALTER TABLE media_items ADD COLUMN made_spec TEXT;       -- crop/export/slideshow: the JSON spec it was made with (<= 512 bytes)
ALTER TABLE media_items ADD COLUMN post_key TEXT;        -- set on made rows (and gallery items): the post they belong to
ALTER TABLE studio_sessions ADD COLUMN item_count INTEGER;   -- picker items when it was resolved (NULL = single)
ALTER TABLE studio_sessions ADD COLUMN items TEXT;           -- JSON [{"i":0,"type":"photo","status":"ready"|"error","code":null}]
ALTER TABLE studio_renders ADD COLUMN kind TEXT;             -- NULL = 'webp' (today); 'slideshow'
ALTER TABLE studio_renders ADD COLUMN plan TEXT;             -- slideshow: the validated plan (18.5) as JSON
CREATE INDEX idx_media_items_session_item ON media_items (session_id, item_index);
