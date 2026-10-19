-- Moving previews for gallery links (APP-API-CONTRACT.md section 29). Additive only: one new table.
-- A video in a gallery link gets a short silent animated WebP, made by the container from the stored
-- file and kept in the PUBLIC bucket under an unguessable name. Discord plays animated images on its
-- own, so the link's gallery moves without a tap. Nothing else reads this table; a missing table
-- only means no previews.
CREATE TABLE media_loops (
    item_id   TEXT PRIMARY KEY,   -- media_items.id of the video
    url       TEXT,               -- public URL of the webp; NULL = not made (yet)
    r2_key    TEXT,               -- its object name in cobalt-media
    bytes     INTEGER,
    tried_at  INTEGER,            -- ms of the last attempt that gave up (a day's cooldown)
    made_at   INTEGER             -- ms
);
