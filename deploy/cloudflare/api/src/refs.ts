// Any capystore link or file name as a post (APP-API-CONTRACT.md section 60): what the chat AI and the MCP may pass where a
// post or file id is asked for. Agents are handed links, not ids: "unhide https://media.../vFhaasY6GA.webp". Each ref is
// resolved to the post (and, when it names one file, that file), hidden and private posts included:
//  - an id as it is: a post key, a file id or a file's old public id
//  - a public file: media.../<name>.<ext>, share.../<name>, or the bare "<name>.<ext>" / "<name>"; the name is the file's
//    public object (r2_key in the public bucket) or the public name it keeps after going private or hidden (public_key)
//  - a gallery link share.../g/<id> (every post in it), a private link share.../p/<key>[/<n>.<ext>] (its file or gallery)
//  - any other http(s) link: the post saved from that page (media_items.link)
// One D1 batch for the whole list. Free of Cloudflare imports: the tests run it under node.
import { POST_KEY_SQL } from "./post-key";

export type RefBases = { mediaBaseUrl: string; shareBaseUrl?: string | undefined };

export type ParsedRef =
    | { kind: "id"; id: string }
    | { kind: "name"; name: string; ext: string | null }
    | { kind: "gallery"; id: string }
    | { kind: "private"; key: string }
    | { kind: "source"; url: string };

// What a ref names. `posts`: the live posts (one, or a gallery link's several), hidden ones included; `file`: the one file it
// names, when it names one; `gone`: it named something that was deleted (posts is then empty).
export type ResolvedRef = { posts: string[]; file: string | null; via: ParsedRef["kind"]; gone: boolean };

// A plain id the ops take as they are (16 base62: post and file ids; 22: studio session ids, the key of most saved posts);
// never looked up by withRefs.
export const PLAIN_ID = /^(?:[A-Za-z0-9]{16}|[A-Za-z0-9]{22})$/;
const NAME = /^([A-Za-z0-9]{6,40})(?:\.([A-Za-z0-9]{1,8}))?$/;
const hostOf = (u: string | undefined) => {
    try {
        return u ? new URL(u).hostname.toLowerCase() : null;
    } catch {
        return null;
    }
};

// What the model pasted, cleaned: <url>, "quoted", `code`, a trailing full stop.
const clean = (raw: string) =>
    raw
        .trim()
        .replace(/^[<"'`(\[]+|[>"'`)\].,;]+$/g, "")
        .trim();

// Whether a string is a link or file name (as opposed to an id an op knows). A plain id never is.
export function looksLikeRef(raw: string): boolean {
    const s = clean(raw);
    if (PLAIN_ID.test(s)) return false;
    return /^https?:\/\//i.test(s) || /^[a-z0-9.-]+\.[a-z]{2,}\/\S/i.test(s) || NAME.test(s);
}

export function parseRef(raw: string, bases: RefBases): ParsedRef {
    const s = clean(raw);
    const urlish = /^https?:\/\//i.test(s) ? s : /^[a-z0-9.-]+\.[a-z]{2,}\/\S/i.test(s) ? `https://${s}` : null;
    if (!urlish) {
        const m = NAME.exec(s);
        // an id first (a post key can be any string); a bare name is tried as a file name too, in resolveRefs
        return m && m[2] ? { kind: "name", name: m[1]!, ext: m[2].toLowerCase() } : { kind: "id", id: s };
    }
    let url: URL;
    try {
        url = new URL(urlish);
    } catch {
        return { kind: "id", id: s };
    }
    const host = url.hostname.toLowerCase();
    const media = hostOf(bases.mediaBaseUrl);
    const share = hostOf(bases.shareBaseUrl);
    const parts = url.pathname.split("/").filter(Boolean);
    // the configured hosts, and the house names in case a link from another surface is pasted (media.* / share.*)
    const isMedia = host === media || (media === null && host.startsWith("media."));
    const isShare = host === share || (share === null && host.startsWith("share."));
    if (isMedia && parts.length === 1) {
        const m = NAME.exec(parts[0]!);
        if (m) return { kind: "name", name: m[1]!, ext: m[2]?.toLowerCase() ?? null };
    }
    if (isShare) {
        if (parts[0] === "g" && parts[1]) return { kind: "gallery", id: parts[1] };
        if (parts[0] === "p" && parts[1]) return { kind: "private", key: parts[1] };
        if (parts.length === 1) {
            const m = NAME.exec(parts[0]!);
            if (m) return { kind: "name", name: m[1]!, ext: m[2]?.toLowerCase() ?? null };
        }
    }
    return { kind: "source", url: url.toString() };
}

type Row = Record<string, unknown>;
const rows = (r: unknown): Row[] => ((r as { results?: Row[] } | null)?.results ?? []) as Row[];
const s = (v: unknown) => (typeof v === "string" ? v : null);

async function many(db: D1Database, stmts: D1PreparedStatement[]): Promise<unknown[]> {
    if (stmts.length === 0) return [];
    if (typeof (db as { batch?: unknown }).batch === "function") {
        try {
            return await db.batch(stmts);
        } catch {
            // a table of a migration not applied yet (private_links): each alone, a missing one reads as nothing
        }
    }
    return Promise.all(stmts.map((st) => st.all().catch(() => ({ results: [] }))));
}

// Every ref resolved (null: nothing in the library, live or deleted, matches it). Two round trips at most: the lookups,
// then which of the posts they found are live.
export async function resolveRefs(db: D1Database, refs: string[], bases: RefBases): Promise<Map<string, ResolvedRef | null>> {
    const list = [...new Set(refs.filter((r) => typeof r === "string" && r.length > 0 && r.length <= 2048))];
    const out = new Map<string, ResolvedRef | null>();
    if (list.length === 0) return out;
    const parsed = new Map(list.map((r) => [r, parseRef(r, bases)]));
    const J = (xs: string[]) => JSON.stringify([...new Set(xs)]);

    // ids: as a post key, a file id or public id. A bare token is also tried as a file name.
    const ids = list.filter((r) => parsed.get(r)!.kind === "id").map((r) => (parsed.get(r) as { id: string }).id);
    const bareNames = ids.filter((i) => NAME.test(i));
    const named = [...parsed.values()].filter((p): p is Extract<ParsedRef, { kind: "name" }> => p.kind === "name");
    const exact = named.filter((n) => n.ext).map((n) => `${n.name}.${n.ext}`);
    const prefixes = [...named.filter((n) => !n.ext).map((n) => n.name), ...bareNames];
    const galleries = [...parsed.values()].flatMap((p) => (p.kind === "gallery" ? [p.id] : []));
    const keys = [...parsed.values()].flatMap((p) => (p.kind === "private" ? [p.key] : []));
    const sources = [...parsed.values()].flatMap((p) => (p.kind === "source" ? [p.url, p.url.replace(/\/$/, "")] : []));

    const FILE_COLS = `m.id AS id, m.public_id AS public_id, m.r2_key AS r2_key, m.public_key AS public_key, m.link AS link, m.deleted_at AS deleted_at, ${POST_KEY_SQL} AS post_key`;
    const IN = (n: number) => `(SELECT value FROM json_each(?${n}))`;
    const stmts: D1PreparedStatement[] = [
        // 0: ids as post keys (live rows) and as file ids / public ids (any row)
        // (every ref as given too: a post saved from a page without a session is keyed by that page's link)
        db.prepare(`SELECT DISTINCT key FROM (SELECT m.deleted_at, ${POST_KEY_SQL} AS key FROM media_items m) WHERE deleted_at IS NULL AND key IN ${IN(1)}`).bind(J([...ids, ...list])),
        db.prepare(`SELECT ${FILE_COLS} FROM media_items m WHERE m.id IN ${IN(1)} OR m.public_id IN ${IN(1)}`).bind(J(ids)),
        // 2: public names, exact (<name>.<ext>) and by prefix (<name>.*): the public object or the name kept after it went private
        db
            .prepare(
                `SELECT ${FILE_COLS} FROM media_items m
                  WHERE (m.bucket = 'media' AND m.r2_key IN ${IN(1)}) OR m.public_key IN ${IN(1)}
                     OR EXISTS (SELECT 1 FROM json_each(?2) p WHERE (m.bucket = 'media' AND m.r2_key >= p.value || '.' AND m.r2_key < p.value || '/')
                                                              OR (m.public_key >= p.value || '.' AND m.public_key < p.value || '/'))`,
            )
            .bind(J(exact), J(prefixes)),
        // 3: gallery links (live or revoked: their posts are still the posts)
        db.prepare(`SELECT id, items FROM share_sets WHERE id IN ${IN(1)}`).bind(J(galleries)),
        // 4: source pages
        db.prepare(`SELECT ${FILE_COLS} FROM media_items m WHERE m.link IN ${IN(1)}`).bind(J(sources)),
        // 5: private links (any state)
        db.prepare(`SELECT key, kind, target_id FROM private_links WHERE key IN ${IN(1)}`).bind(J(keys)),
    ];
    const [postKeys, byId, byName, sets, bySource, priv] = (await many(db, stmts)).map(rows) as Row[][];

    // a private gallery link and a gallery link's files need a second look: their file ids
    const setItems = new Map<string, string[]>();
    for (const r of sets ?? []) {
        try {
            setItems.set(String(r.id), (JSON.parse(String(r.items)) as unknown[]).filter((x): x is string => typeof x === "string"));
        } catch {
            setItems.set(String(r.id), []);
        }
    }
    const privRows = new Map((priv ?? []).map((r) => [String(r.key), r]));
    const privSets = [...privRows.values()].filter((r) => r.kind === "set").map((r) => String(r.target_id)).filter((id) => !setItems.has(id));
    const fileIds = new Set<string>();
    for (const items of setItems.values()) items.forEach((i) => fileIds.add(i));
    for (const r of privRows.values()) if (r.kind === "item") fileIds.add(String(r.target_id));
    const second: D1PreparedStatement[] = [];
    if (privSets.length > 0) second.push(db.prepare(`SELECT id, items FROM share_sets WHERE id IN ${IN(1)}`).bind(J(privSets)));
    const extra = await many(db, second);
    for (const r of rows(extra[0])) {
        try {
            const items = (JSON.parse(String(r.items)) as unknown[]).filter((x): x is string => typeof x === "string");
            setItems.set(String(r.id), items);
            items.forEach((i) => fileIds.add(i));
        } catch {
            setItems.set(String(r.id), []);
        }
    }
    const fileRows = fileIds.size > 0 ? rows((await many(db, [db.prepare(`SELECT ${FILE_COLS} FROM media_items m WHERE m.id IN ${IN(1)}`).bind(J([...fileIds]))]))[0]) : [];

    // the candidate posts, then which are live (a hidden post is live; a deleted one is not)
    const all = [...(byId ?? []), ...(byName ?? []), ...(bySource ?? []), ...fileRows];
    const candidates = [...new Set(all.map((r) => s(r.post_key)).filter((k): k is string => !!k))];
    const directPosts = new Set((postKeys ?? []).map((r) => String(r.key)));
    const liveKeys = new Set(directPosts);
    if (candidates.length > 0) {
        const r = await db
            .prepare(`SELECT DISTINCT key FROM (SELECT m.deleted_at, ${POST_KEY_SQL} AS key FROM media_items m) WHERE deleted_at IS NULL AND key IN ${IN(1)}`)
            .bind(J(candidates))
            .all<{ key: string }>();
        for (const x of r.results) liveKeys.add(x.key);
    }
    const fileById = new Map(all.map((r) => [String(r.id), r]));
    const answer = (via: ParsedRef["kind"], files: Row[], one: boolean): ResolvedRef | null => {
        if (files.length === 0) return null;
        // live rows first, then the newest; a deleted row still names its post
        const sorted = [...files].sort((a, b) => Number(a.deleted_at !== null) - Number(b.deleted_at !== null));
        const posts = [...new Set(sorted.map((f) => s(f.post_key)).filter((k): k is string => !!k && liveKeys.has(k)))];
        const live = sorted.find((f) => f.deleted_at === null && liveKeys.has(String(f.post_key)));
        return { posts, file: one && live ? String(live.id) : null, via, gone: posts.length === 0 };
    };
    const byNameOf = (name: string, ext: string | null) =>
        (byName ?? []).filter((r) => {
            for (const k of [s(r.r2_key), s(r.public_key)]) {
                if (!k) continue;
                if (ext ? k === `${name}.${ext}` : k.startsWith(`${name}.`)) return true;
            }
            return false;
        });

    for (const ref of list) {
        const p = parsed.get(ref)!;
        if (directPosts.has(ref)) {
            out.set(ref, { posts: [ref], file: null, via: "id", gone: false });
            continue;
        }
        if (p.kind === "id") {
            if (directPosts.has(p.id)) {
                out.set(ref, { posts: [p.id], file: null, via: "id", gone: false });
                continue;
            }
            const f = (byId ?? []).filter((r) => r.id === p.id || r.public_id === p.id);
            const asFile = answer("id", f, true);
            const asName = NAME.test(p.id) ? answer("name", byNameOf(p.id, null), true) : null;
            out.set(ref, asFile && !asFile.gone ? asFile : asName && !asName.gone ? asName : (asFile ?? asName));
        } else if (p.kind === "name") {
            out.set(ref, answer("name", byNameOf(p.name, p.ext), true));
        } else if (p.kind === "source") {
            const want = new Set([p.url, p.url.replace(/\/$/, "")]);
            const f = (bySource ?? []).filter((r) => want.has(String(r.link)));
            out.set(ref, answer("source", f, false));
        } else {
            const link = p.kind === "private" ? privRows.get(p.key) : null;
            if (p.kind === "private" && !link) {
                out.set(ref, null);
                continue;
            }
            if (link && link.kind === "item") {
                out.set(ref, answer("private", fileRows.filter((r) => r.id === link.target_id), true));
                continue;
            }
            const setId = link ? String(link.target_id) : (p as { id: string }).id;
            const items = setItems.get(setId);
            if (!items) {
                out.set(ref, null);
                continue;
            }
            // the gallery's posts in its order
            const order = items.map((i) => fileById.get(i)).filter((r): r is Row => !!r);
            const res = answer(p.kind, order, false);
            out.set(ref, res ?? { posts: [], file: null, via: p.kind, gone: true });
        }
    }
    return out;
}

// A one-line reason a ref did not resolve, for the model.
export function unresolvedText(ref: string, r: ResolvedRef | null): string {
    if (r?.gone) return `${ref} was in the library but has been deleted`;
    return `nothing in the library matches ${ref} (a post or file id, a media/share link, a gallery or private link, a file name like abc123.webp, or the page it was saved from)`;
}
