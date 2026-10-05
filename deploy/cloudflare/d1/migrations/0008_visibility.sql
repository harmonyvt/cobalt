-- One file per rendition, public or private (apple/CONTRACT-VISIBILITY.md, APP-API-CONTRACT.md section 16).
-- Additive only: nullable columns and two indexes. Nothing is rewritten here; the data step is the keyed route
-- POST /library/visibility/migrate. Old code names its columns, so apply this BEFORE deploying the Workers.

-- 'public' | 'private'. NULL = not migrated yet: read as bucket = 'media' -> 'public', else 'private'
-- (every reader uses COALESCE(visibility, CASE bucket WHEN 'media' THEN 'public' ELSE 'private' END)).
ALTER TABLE media_items ADD COLUMN visibility TEXT;
-- For a row whose canonical bytes are private (bucket 'originals'): the key in cobalt-media of its public
-- mirror (<10 base62>.<ext>). Kept after the row turns private, so turning it public again gives the same
-- link. NULL = never public. A webp that was switched private is such a row too: its bytes moved to
-- cobalt-originals under webps/<name> and public_key is its old public name.
ALTER TABLE media_items ADD COLUMN public_key TEXT;
-- For a saved or uploaded original that is or was public: the 16-base62 id old clients know its public
-- file by (the retired host row's id after the merge; minted at the first publish otherwise). Routes
-- resolve it like an id. NULL for webps (their own id is the id old clients know).
ALTER TABLE media_items ADD COLUMN public_id TEXT;
-- On a retired host row (deleted_at set by the merge, not by a delete): the id of the original it became.
ALTER TABLE media_items ADD COLUMN merged_into TEXT;

CREATE INDEX idx_media_items_public_id ON media_items (public_id);
CREATE INDEX idx_media_items_public_key ON media_items (public_key);
