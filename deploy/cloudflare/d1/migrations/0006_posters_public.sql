-- Server-made posters and "public by default" (APP-API-CONTRACT.md section 13).
-- Additive only: nullable columns and one index. Nothing is rewritten, no existing
-- query or row changes meaning; old code (which names its columns) keeps working on
-- the migrated database, so apply this BEFORE deploying the API and web Workers.
--
-- A poster is a small JPEG the container's ffmpeg cuts out of a stored video. It lives
-- in the PUBLIC bucket `cobalt-media` under an unguessable name (<10 base62>.jpg), so
-- `poster` holds its public URL (like `url` does for files). One poster object may be
-- shared by an original and the public copy hosted from it; deleting a row deletes the
-- object only when no other live row still names it.

-- The poster of a library row (private originals get one; a public host copy of a video
-- shares the original's). `poster_at` is when the last attempt to make one ended without
-- success (or when it succeeded): a row with no poster is retried no sooner than a day later.
ALTER TABLE media_items ADD COLUMN poster TEXT;
ALTER TABLE media_items ADD COLUMN poster_at INTEGER;

-- The same URL mirrored on the studio session of that original, so GET /studio/<sid>
-- needs no join. `public_state` is set when the save asked for public hosting
-- (`public: true`): 'pending' until the server has copied the original to the public
-- bucket, then 'ready' (public_url is the hosted file) or 'failed'. NULL = never asked.
ALTER TABLE studio_sessions ADD COLUMN poster TEXT;
ALTER TABLE studio_sessions ADD COLUMN public_state TEXT;
ALTER TABLE studio_sessions ADD COLUMN public_url TEXT;

-- Finding the row of a stored object (poster jobs, session lookups, the insert guard).
CREATE INDEX idx_media_items_object ON media_items (bucket, r2_key);
