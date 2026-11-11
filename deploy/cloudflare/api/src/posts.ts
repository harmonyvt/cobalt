// The one post loader. GET /sync reads posts through here, in the same D1 batch as the rest of the page, and the
// objects are built by shapeLibraryPosts — the same function GET /library uses — so a synced post is that object,
// including created_at and files. v=3 is what the current app asks GET /library for.
import { FILE_COLUMNS, shapeLibraryPosts } from "./app-routes";
import type { HiddenRow } from "./hidden-store";
import { privateUrl } from "./private-links";

export const SYNC_POST_VERSION = { v2: true, v3: true } as const;

// The changed posts inside a sync page. `?1` is since, `?2` is the page size (limit + 1, so the caller can see `more`).
// Repeated in each statement: a batch cannot pass one statement's rows to the next, and one batch is one round trip.
const pagePosts = `(SELECT id FROM (SELECT seq, entity, id, gone FROM changes WHERE seq > ?1 ORDER BY seq LIMIT ?2) WHERE entity = 'post' AND gone = 0)`;

export type PostRead = {
    latests: { post_key: string; latest: number }[];
    files: any[];
    sessions: any[];
    titles: { post_key: string; title: string }[];
    hidden: HiddenRow[];
    links: { key: string; target_id: string }[];
};

// Six statements, in this order. Each binds (since, take).
export function postReadStatements(db: D1Database, since: number, take: number): D1PreparedStatement[] {
    const bind = (sql: string) => db.prepare(sql).bind(since, take);
    return [
        bind(
            `SELECT post_key, MAX(created_at) AS latest FROM media_items
              WHERE deleted_at IS NULL AND post_key IN ${pagePosts} GROUP BY post_key`,
        ),
        bind(
            `SELECT ${FILE_COLUMNS} FROM media_items m
              WHERE m.deleted_at IS NULL AND m.post_key IN ${pagePosts}
              ORDER BY m.created_at DESC, m.id DESC`,
        ),
        bind(
            `SELECT * FROM (SELECT s.id, s.status, s.service, s.expires_at, s.created_at, s.items,
                                   CASE WHEN s.link LIKE 'upload:%' THEN substr(s.link, 8) ELSE s.id END AS post_key
                            FROM studio_sessions s)
              WHERE post_key IN ${pagePosts} ORDER BY created_at DESC, id DESC`,
        ),
        bind(`SELECT post_key, title FROM media_titles WHERE post_key IN ${pagePosts}`),
        bind(`SELECT post_key, state, by, rule_id, at FROM media_hidden WHERE post_key IN ${pagePosts}`),
        bind(
            `SELECT key, target_id FROM private_links
              WHERE kind = 'item' AND revoked_at IS NULL AND target_id IN (
                  SELECT m.id FROM media_items m WHERE m.deleted_at IS NULL AND m.post_key IN ${pagePosts})`,
        ),
    ];
}

export const POST_READ_COUNT = 6;

// `keys` is the posts to return, in the order the caller wants (the change log's order). A key with no live file is
// left out: the caller reports it as gone.
export function shapePosts(
    d: { apiUrl: string; shareBaseUrl?: string },
    keys: string[],
    read: PostRead,
    now: number,
): any[] {
    const want = new Set(keys);
    const latestOf = new Map(read.latests.filter((r) => want.has(r.post_key)).map((r) => [r.post_key, r.latest]));
    const page = keys.filter((k) => latestOf.has(k)).map((post_key) => ({ post_key, latest: latestOf.get(post_key)! }));
    const titles = new Map(read.titles.filter((t) => want.has(t.post_key)).map((t) => [t.post_key, t.title]));
    const hiddenOf = new Map(read.hidden.filter((h) => want.has(h.post_key)).map((h) => [h.post_key, h]));
    const priv = new Map<string, string>();
    if (d.shareBaseUrl) for (const r of read.links) priv.set(r.target_id, privateUrl(d.shareBaseUrl, r.key));
    return shapeLibraryPosts(
        d,
        page,
        {
            files: read.files.filter((f) => want.has(f.post_key)),
            sessions: read.sessions.filter((s) => want.has(s.post_key)),
            titles,
            tombs: new Map(),
            priv,
            hiddenOf,
        },
        { ...SYNC_POST_VERSION, now },
    );
}
