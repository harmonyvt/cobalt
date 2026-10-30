// The GET /library post key of a media_items row `m` (APP-API-CONTRACT.md section 5): one card per post, the owner's
// COALESCE(session_id, link, id), refined so an upload and the renders made from it (whose session's link is
// "upload:<item id>") land in one card. Since migration 0009 (section 18.1) a row that names its post (`post_key`: a
// gallery item, a slideshow, a crop or an export) says so first; rows older than that have NULL.
//
// Its own module (no imports) so the hidden-post store (section 37) and visibility.ts can use it without an import cycle
// through app-routes.ts, which re-exports it.
export const POST_KEY_SQL = `COALESCE(
    m.post_key,
    (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = m.session_id AND s.link LIKE 'upload:%'),
    m.session_id, m.link, m.id)`;
