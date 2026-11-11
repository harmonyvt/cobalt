// The GET /library post key of a media_items row `m` (APP-API-CONTRACT.md section 5): one card per post, the owner's
// COALESCE(session_id, link, id), refined so an upload and the renders made from it (whose session's link is
// "upload:<item id>") land in one card. Migration 0009 added `post_key`. Migration 0038 stores that key on every row
// (a backfill, plus a fill on insert) and indexes it, so a trigger can name a post without recomputing this expression.
// `post_key` still wins when it is set: a row that names its post says so first.
//
// Its own module (no imports) so the hidden-post store (section 37) and visibility.ts can use it without an import cycle
// through app-routes.ts, which re-exports it.
export const POST_KEY_SQL = `COALESCE(
    m.post_key,
    (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = m.session_id AND s.link LIKE 'upload:%'),
    m.session_id, m.link, m.id)`;

// The same key for a row that is about to be inserted, as one SQL expression. `explicit` is the caller's post_key
// (NULL when it did not name one); the other three are the new row's session id, link and id.
export const postKeyInsertSql = (explicit: string, sessionId: string, link: string, id: string) =>
    `COALESCE(${explicit}, (SELECT substr(s.link, 8) FROM studio_sessions s WHERE s.id = ${sessionId} AND s.link LIKE 'upload:%'), ${sessionId}, ${link}, ${id})`;
