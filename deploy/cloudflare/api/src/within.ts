// Search inside a collection, a gallery link or a list of posts (APP-API-CONTRACT.md section 34.6): which posts `within`
// names. A collection's posts are the posts of its live links' files; a link's are its files' posts. Free of Cloudflare
// imports so it runs under node in the tests.

import { POST_KEY_SQL } from "./app-routes";

export const WITHIN_POSTS_MAX = 500;
const CHUNK = 90;

export type WithinSpec = { collection: string } | { link: string } | { posts: string[] };
export type Within = { kind: "collection" | "link" | "posts"; id: string | null; name: string | null; postKeys: Set<string> };

export class WithinError extends Error {
    constructor(
        readonly status: number,
        readonly code: string,
    ) {
        super(code);
        this.name = "WithinError";
    }
}

const parseItems = (s: string): string[] => {
    try {
        const v = JSON.parse(s);
        return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
    } catch {
        return [];
    }
};

// The live posts of these files (a file is named by its id or its public copy's id, as share links store them).
export async function postsOfItems(db: D1Database, itemIds: string[]): Promise<Set<string>> {
    const out = new Set<string>();
    const ids = [...new Set(itemIds)];
    for (let i = 0; i < ids.length; i += CHUNK) {
        const part = ids.slice(i, i + CHUNK);
        const marks = part.map((_, j) => `?${j + 1}`).join(", ");
        const { results } = await db
            .prepare(
                `SELECT DISTINCT post_key FROM (SELECT m.id, m.public_id, m.deleted_at, ${POST_KEY_SQL} AS post_key FROM media_items m)
                  WHERE deleted_at IS NULL AND (id IN (${marks}) OR public_id IN (${marks}))`,
            )
            .bind(...part)
            .all<{ post_key: string }>();
        for (const r of results) out.add(r.post_key);
    }
    return out;
}

// The ones of these post ids that are live posts.
export async function livePosts(db: D1Database, postIds: string[]): Promise<Set<string>> {
    const out = new Set<string>();
    const ids = [...new Set(postIds)];
    for (let i = 0; i < ids.length; i += CHUNK) {
        const part = ids.slice(i, i + CHUNK);
        const { results } = await db
            .prepare(
                `SELECT DISTINCT post_key FROM (SELECT m.deleted_at, ${POST_KEY_SQL} AS post_key FROM media_items m)
                  WHERE deleted_at IS NULL AND post_key IN (${part.map((_, j) => `?${j + 1}`).join(", ")})`,
            )
            .bind(...part)
            .all<{ post_key: string }>();
        for (const r of results) out.add(r.post_key);
    }
    return out;
}

// A collection by its id, else by its name (case and outer spaces ignored; the most recently changed one wins).
async function findCollection(db: D1Database, idOrName: string): Promise<{ id: string; name: string } | null> {
    const byId = await db.prepare("SELECT id, name FROM share_collections WHERE id = ?1").bind(idOrName).first<{ id: string; name: string }>();
    if (byId) return byId;
    const want = idOrName.trim().replace(/\s+/g, " ").toLowerCase();
    if (!want) return null;
    const { results } = await db.prepare("SELECT id, name FROM share_collections ORDER BY updated_at DESC, id DESC").all<{ id: string; name: string }>();
    return results.find((c) => c.name.trim().replace(/\s+/g, " ").toLowerCase() === want) ?? null;
}

// The posts a collection holds: every live link in it, every file of those links.
export async function collectionPostIds(db: D1Database, collectionId: string): Promise<Set<string>> {
    const { results } = await db
        .prepare(
            `SELECT s.items FROM share_collection_items i JOIN share_sets s ON s.id = i.set_id
              WHERE i.collection_id = ?1 AND s.revoked_at IS NULL`,
        )
        .bind(collectionId)
        .all<{ items: string }>();
    return postsOfItems(db, results.flatMap((r) => parseItems(r.items)));
}

export async function resolveWithin(db: D1Database, spec: WithinSpec): Promise<Within> {
    if ("collection" in spec) {
        const c = await findCollection(db, spec.collection);
        if (!c) throw new WithinError(404, "error.collection.not_found");
        return { kind: "collection", id: c.id, name: c.name, postKeys: await collectionPostIds(db, c.id) };
    }
    if ("link" in spec) {
        const s = await db
            .prepare("SELECT id, items, title FROM share_sets WHERE id = ?1 AND revoked_at IS NULL")
            .bind(spec.link)
            .first<{ id: string; items: string; title: string | null }>();
        if (!s) throw new WithinError(404, "error.share.not_found");
        return { kind: "link", id: s.id, name: s.title, postKeys: await postsOfItems(db, parseItems(s.items)) };
    }
    return { kind: "posts", id: null, name: null, postKeys: await livePosts(db, spec.posts.slice(0, WITHIN_POSTS_MAX)) };
}

// `within` from GET /library/search's query: exactly one of collection, link, posts. null: none given; "bad": more
// than one, or a malformed one.
export function withinFromQuery(q: URLSearchParams): WithinSpec | null | "bad" {
    const given = ["collection", "link", "posts"].filter((k) => q.has(k));
    if (given.length === 0) return null;
    if (given.length > 1) return "bad";
    const raw = (q.get(given[0]!) ?? "").trim();
    if (raw === "" || raw.length > 60_000) return "bad";
    if (given[0] === "collection") return raw.length <= 200 ? { collection: raw } : "bad";
    if (given[0] === "link") return raw.length <= 64 ? { link: raw } : "bad";
    const ids = raw.split(",").map((x) => x.trim());
    if (ids.length > WITHIN_POSTS_MAX || ids.some((x) => x.length === 0 || x.length > 2048)) return "bad";
    return { posts: ids };
}
