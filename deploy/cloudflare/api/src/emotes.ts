// 7TV emotes (APP-API-CONTRACT.md section 20). The Worker asks 7TV, then stores
// one public webp. The phone never talks to 7TV. Search stores nothing.

import type { AppDeps } from "./app-routes";
import { insertMediaItem } from "./library";
import type { StudioReply } from "./studio";
import { getRow, itemShape } from "./visibility";
import { mintName } from "./webp";
import { retryAfterSeconds, type SevenTvGate } from "./seventv-gate";

const GQL = "https://7tv.io/v4/gql";
const CDN_HOST = "cdn.7tv.app";
const MAX_BYTES = 15_000_000;
const EMOTE_ID = /^[0-9A-Za-z]{20,32}$/;
const PREVIEW_SCALES = [2, 1, 3, 4];

// Sort keys (section 20.1) -> 7TV v4 SortBy. "global" is 7TV's global set, not a search.
export const EMOTE_SORTS = {
    top: "TOP_ALL_TIME",
    top_daily: "TOP_DAILY",
    top_weekly: "TOP_WEEKLY",
    top_monthly: "TOP_MONTHLY",
    trending_daily: "TRENDING_DAILY",
    trending_weekly: "TRENDING_WEEKLY",
    trending_monthly: "TRENDING_MONTHLY",
    new: "UPLOAD_DATE",
    global: null,
} as const;
export type EmoteSort = keyof typeof EMOTE_SORTS;
export const EMOTE_SORT_KEYS = Object.keys(EMOTE_SORTS) as EmoteSort[];
const PER_PAGE = 24;
const MAX_PAGE = 50;

const FIELDS = "id defaultName deleted flags { animated defaultZeroWidth private } images { url mime size scale width height frameCount }";

// An empty query (null) is "browse everything" in 7TV's v4 search.
const SEARCH = `query($query: String, $sort: Sort!, $page: Int!, $perPage: Int!) {
  emotes { search(query: $query, sort: $sort, page: $page, perPage: $perPage) {
    pageCount items { ${FIELDS} } } } }`;

const GLOBAL = `query($query: String, $page: Int!, $perPage: Int!) {
  emoteSets { global { emotes(query: $query, page: $page, perPage: $perPage) {
    pageCount items { emote { ${FIELDS} } } } } } }`;

const ONE = `query($id: Id!) {
  emotes { emote(id: $id) { id defaultName deleted flags { animated defaultZeroWidth private } images { url mime size scale width height frameCount } } } }`;

export type EmoteImage = {
    url: string;
    mime: string;
    size: number;
    scale: number;
    width: number;
    height: number;
    frameCount: number;
};

type EmoteHit = {
    id: string;
    name: string;
    animated: boolean;
    images: EmoteImage[];
};

const err = (status: number, code: string): StudioReply => ({
    status,
    body: { status: "error", error: { code } },
});

const linkFor = (id: string) => `7tv:${id}`;

// Animated emotes also publish a still `*_static.webp` (frameCount 1). Those are not the file.
export function webpCandidates(images: EmoteImage[], animated: boolean): EmoteImage[] {
    let rows = images.filter(
        (i) => i.mime === "image/webp" && i.url.startsWith("https://") && i.size >= 0 && i.scale > 0,
    );
    if (animated) rows = rows.filter((i) => i.frameCount > 1);
    else if (rows.some((i) => !i.url.includes("_static"))) rows = rows.filter((i) => !i.url.includes("_static"));
    return rows;
}

// Largest scale, then widest. A file over the cap steps down to the next scale.
export function pickWebp(images: EmoteImage[], animated: boolean): EmoteImage | null {
    const rows = webpCandidates(images, animated).slice().sort((a, b) => b.scale - a.scale || b.width - a.width);
    return rows.find((i) => i.size <= MAX_BYTES) ?? null;
}

// The grid picture: scale 2 when it exists, else 1, else 3, else 4.
export function previewWebp(images: EmoteImage[], animated: boolean): EmoteImage | null {
    const rows = webpCandidates(images, animated);
    for (const scale of PREVIEW_SCALES) {
        const hit = rows.filter((i) => i.scale === scale).sort((a, b) => b.width - a.width)[0];
        if (hit) return hit;
    }
    return null;
}

const cdnHost = (url: string) => {
    try {
        return new URL(url).host === CDN_HOST;
    } catch {
        return false;
    }
};

const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);

function readImage(raw: unknown): EmoteImage | null {
    if (!raw || typeof raw !== "object") return null;
    const o = raw as Record<string, unknown>;
    const url = typeof o.url === "string" ? o.url : "";
    const mime = typeof o.mime === "string" ? o.mime : "";
    const size = num(o.size);
    const scale = num(o.scale);
    const width = num(o.width);
    const height = num(o.height);
    const frameCount = num(o.frameCount);
    if (!url || size === null || scale === null || width === null || height === null || frameCount === null) return null;
    return { url, mime, size, scale, width, height, frameCount };
}

function readEmote(raw: unknown): EmoteHit | null {
    if (!raw || typeof raw !== "object") return null;
    const o = raw as Record<string, unknown>;
    if (typeof o.id !== "string" || !EMOTE_ID.test(o.id)) return null;
    if (o.deleted === true) return null;
    const flags = (o.flags && typeof o.flags === "object" ? o.flags : {}) as Record<string, unknown>;
    if (flags.defaultZeroWidth === true || flags.private === true) return null;
    const name = typeof o.defaultName === "string" ? o.defaultName.trim() : "";
    if (!name) return null;
    const images = Array.isArray(o.images) ? o.images.map(readImage).filter((i): i is EmoteImage => i !== null) : [];
    return { id: o.id, name, animated: flags.animated === true, images };
}

// A 7TV answer that was not an answer: its HTTP status (0: no answer) and Retry-After seconds.
class GqlFailure extends Error {
    constructor(
        readonly status: number,
        readonly retryAfter: number | null,
    ) {
        super(`7tv ${status}`);
    }
}

async function gql(fetchImpl: typeof fetch, query: string, variables: Record<string, unknown>, gate?: SevenTvGate | null, now: () => number = Date.now): Promise<unknown> {
    await gate?.slot("read");
    let res: Response;
    try {
        res = await fetchImpl(GQL, {
            method: "POST",
            headers: { "content-type": "application/json", accept: "application/json" },
            body: JSON.stringify({ query, variables }),
            signal: AbortSignal.timeout(20_000),
        });
    } catch {
        throw new GqlFailure(0, null);
    }
    if (res.status === 429) {
        await gate?.slow();
        throw new GqlFailure(429, retryAfterSeconds(res.headers.get("retry-after"), now()));
    }
    if (!res.ok) throw new GqlFailure(res.status, null);
    const body = (await res.json()) as { data?: unknown; errors?: unknown };
    if (!body.data || (Array.isArray(body.errors) && body.errors.length > 0 && body.data == null)) {
        throw new GqlFailure(502, null);
    }
    return body.data;
}

// A failed search as the routes answer it: a 429 keeps its own code and Retry-After (section 62.5).
const failed = (e: unknown): StudioReply =>
    e instanceof GqlFailure && e.status === 429
        ? { status: 429, body: { status: "error", error: { code: "error.emote.rate_limited", ...(e.retryAfter !== null ? { retry_after: e.retryAfter } : {}) } } }
        : err(502, "error.emote.unavailable");

async function savedIds(db: D1Database, ids: string[]): Promise<Map<string, { id: string; url: string | null }>> {
    const out = new Map<string, { id: string; url: string | null }>();
    if (ids.length === 0) return out;
    const links = ids.map(linkFor);
    const marks = links.map((_, i) => `?${i + 1}`).join(", ");
    const rows = await db
        .prepare(
            `SELECT id, link, url FROM media_items WHERE source = 'emote' AND deleted_at IS NULL AND link IN (${marks})`,
        )
        .bind(...links)
        .all<{ id: string; link: string; url: string | null }>();
    for (const row of rows.results ?? []) {
        if (row.link.startsWith("7tv:")) out.set(row.link.slice(4), { id: row.id, url: row.url });
    }
    return out;
}

async function rowFor(db: D1Database, emoteId: string) {
    const found = await db
        .prepare(
            "SELECT id FROM media_items WHERE source = 'emote' AND link = ?1 AND deleted_at IS NULL LIMIT 1",
        )
        .bind(linkFor(emoteId))
        .first<{ id: string }>();
    if (!found) return null;
    return getRow(db, found.id);
}

function shaped(row: NonNullable<Awaited<ReturnType<typeof getRow>>>, emoteId: string) {
    return { ...itemShape(row), emote_id: emoteId };
}

// ---- search (section 20.1), its 24 h cache and the batch (section 62.5) -----------------------------------------------

// One search hit as it is cached (no library fields: those are filled in on every answer).
type FoundEmote = { id: string; name: string; animated: boolean; preview_url: string; file_url: string; width: number; height: number };
type FoundPage = { items: FoundEmote[]; has_more: boolean };

// The Workers Cache API's shape (caches.default), or a fake in the tests.
export type EmoteCache = { match(key: Request): Promise<Response | undefined>; put(key: Request, res: Response): Promise<void> };
export const EMOTE_CACHE_S = 24 * 60 * 60;
export const FIND_MANY_MAX = 20;

const cacheOf = (d: Pick<AppDeps, "emoteCache">): EmoteCache | null => {
    if (d.emoteCache !== undefined) return d.emoteCache;
    const c = (globalThis as { caches?: { default?: EmoteCache } }).caches?.default;
    return c ?? null;
};
const normQuery = (q: string) => q.trim().toLowerCase().replace(/\s+/g, " ");
const cacheKey = (query: string, sort: EmoteSort, page: number) =>
    new Request(`https://emote-cache.internal/find?${new URLSearchParams({ q: normQuery(query), sort, page: String(page) })}`);

async function cached(d: Pick<AppDeps, "emoteCache">, query: string, sort: EmoteSort, page: number): Promise<FoundPage | null> {
    const c = cacheOf(d);
    if (!c) return null;
    try {
        const hit = await c.match(cacheKey(query, sort, page));
        return hit ? ((await hit.json()) as FoundPage) : null;
    } catch {
        return null;
    }
}

async function remember(d: Pick<AppDeps, "emoteCache">, query: string, sort: EmoteSort, page: number, found: FoundPage): Promise<void> {
    const c = cacheOf(d);
    if (!c) return;
    try {
        await c.put(cacheKey(query, sort, page), new Response(JSON.stringify(found), { headers: { "content-type": "application/json", "cache-control": `public, max-age=${EMOTE_CACHE_S}` } }));
    } catch {
        // a cache that cannot keep it: the next search asks 7TV again
    }
}

// 7TV's search answer (or the global set's) as the hits the app can use.
function foundOf(found: { pageCount?: unknown; items?: unknown } | undefined, sort: EmoteSort, page: number): FoundPage {
    const rawItems = Array.isArray(found?.items) ? found.items : [];
    const itemsRaw = sort === "global" ? rawItems.map((i) => (i as { emote?: unknown })?.emote) : rawItems;
    const pageCount = typeof found?.pageCount === "number" ? found.pageCount : 0;
    const items: FoundEmote[] = [];
    for (const hit of itemsRaw.map(readEmote).filter((h): h is EmoteHit => h !== null)) {
        const preview = previewWebp(hit.images, hit.animated);
        const file = pickWebp(hit.images, hit.animated);
        if (!preview || !cdnHost(preview.url) || !file || !cdnHost(file.url)) continue;
        items.push({ id: hit.id, name: hit.name, animated: hit.animated, preview_url: preview.url, file_url: file.url, width: file.width, height: file.height });
    }
    return { items, has_more: rawItems.length > 0 && page < Math.min(pageCount, MAX_PAGE) };
}

const searchVars = (query: string, sort: EmoteSort, page: number) =>
    sort === "global" ? { query: query || null, page, perPage: PER_PAGE } : { query: query || null, sort: { sortBy: EMOTE_SORTS[sort], order: "DESCENDING" }, page, perPage: PER_PAGE };
const foundIn = (data: unknown, sort: EmoteSort) =>
    sort === "global" ? (data as { emoteSets?: { global?: { emotes?: { pageCount?: unknown; items?: unknown } } } })?.emoteSets?.global?.emotes : (data as { emotes?: { search?: { pageCount?: unknown; items?: unknown } } })?.emotes?.search;

// The library fields (already saved?) on every answer, fresh.
async function withLibrary(d: AppDeps, items: FoundEmote[]) {
    const saved = await savedIds(d.db, items.map((h) => h.id));
    return items.map((h) => ({ ...h, library_id: saved.get(h.id)?.id ?? null, library_url: saved.get(h.id)?.url ?? null }));
}

export async function searchEmotes(
    d: AppDeps,
    q: URLSearchParams,
    fetchImpl: typeof fetch = fetch,
): Promise<StudioReply> {
    const query = (q.get("q") ?? "").trim();
    const sortRaw = q.get("sort");
    // No sort: the old search (a name is required, top of all time). With a sort the name is optional.
    if (sortRaw !== null && !(EMOTE_SORT_KEYS as string[]).includes(sortRaw)) return err(400, "error.emote.query");
    const sort: EmoteSort = (sortRaw as EmoteSort | null) ?? "top";
    if (query.length > 64 || (sortRaw === null && query.length < 1)) return err(400, "error.emote.query");
    const pageRaw = q.get("page");
    const page = pageRaw === null ? 1 : Number(pageRaw);
    if (!Number.isInteger(page) || page < 1 || page > MAX_PAGE) return err(400, "error.emote.query");

    let found = await cached(d, query, sort, page);
    const hit = found !== null;
    if (!found) {
        try {
            found = foundOf(foundIn(await gql(fetchImpl, sort === "global" ? GLOBAL : SEARCH, searchVars(query, sort, page), d.sevenTvGate, d.now), sort), sort, page);
        } catch (e) {
            return failed(e);
        }
        await remember(d, query, sort, page, found);
    }
    let items;
    try {
        items = await withLibrary(d, found.items);
    } catch {
        return err(502, "error.emote.unavailable");
    }
    return { status: 200, body: { items, sort, page, has_more: found.has_more, ...(hit ? { cached: true } : {}) } };
}

// Several names in one 7TV request (section 62.5): one aliased search per name not in the cache, first page only.
export async function findManyEmotes(d: AppDeps, queries: string[], sortRaw: string | undefined, fetchImpl: typeof fetch = fetch): Promise<StudioReply> {
    if (sortRaw !== undefined && !(EMOTE_SORT_KEYS as string[]).includes(sortRaw)) return err(400, "error.emote.query");
    const sort: EmoteSort = (sortRaw as EmoteSort | undefined) ?? "top";
    const list = queries.map((x) => x.trim());
    if (list.length < 1 || list.length > FIND_MANY_MAX || list.some((x) => x.length < 1 || x.length > 64)) return err(400, "error.emote.query");
    const found = new Map<string, { page: FoundPage; cached: boolean }>();
    for (const x of new Set(list.map(normQuery))) {
        const c = await cached(d, x, sort, 1);
        if (c) found.set(x, { page: c, cached: true });
    }
    const missing = [...new Set(list.map(normQuery))].filter((x) => !found.has(x));
    if (missing.length > 0) {
        const vars: Record<string, unknown> = { perPage: PER_PAGE, page: 1 };
        const defs = ["$perPage: Int!", "$page: Int!"];
        if (sort !== "global") {
            vars.sort = { sortBy: EMOTE_SORTS[sort], order: "DESCENDING" };
            defs.push("$sort: Sort!");
        }
        const parts = missing.map((x, i) => {
            vars[`q${i}`] = x;
            defs.push(`$q${i}: String`);
            return sort === "global"
                ? `s${i}: emoteSets { global { emotes(query: $q${i}, page: $page, perPage: $perPage) { pageCount items { emote { ${FIELDS} } } } } }`
                : `s${i}: emotes { search(query: $q${i}, sort: $sort, page: $page, perPage: $perPage) { pageCount items { ${FIELDS} } } }`;
        });
        let data: unknown;
        try {
            data = await gql(fetchImpl, `query(${defs.join(", ")}) { ${parts.join(" ")} }`, vars, d.sevenTvGate, d.now);
        } catch (e) {
            return failed(e);
        }
        for (const [i, x] of missing.entries()) {
            const one = (data as Record<string, unknown>)?.[`s${i}`];
            const page = foundOf(foundIn(sort === "global" ? { emoteSets: one } : { emotes: one }, sort), sort, 1);
            found.set(x, { page, cached: false });
            await remember(d, x, sort, 1, page);
        }
    }
    try {
        const results = [];
        for (const x of list) {
            const f = found.get(normQuery(x))!;
            results.push({ q: x, emotes: await withLibrary(d, f.page.items), cached: f.cached });
        }
        return { status: 200, body: { sort, results } };
    } catch {
        return err(502, "error.emote.unavailable");
    }
}

export async function saveEmote(
    d: AppDeps,
    request: Request,
    keyId: string,
    fetchImpl: typeof fetch = fetch,
): Promise<StudioReply> {
    let id = "";
    try {
        const body = (await request.json()) as { id?: unknown };
        id = typeof body.id === "string" ? body.id : "";
    } catch {
        return err(400, "error.emote.query");
    }
    if (!EMOTE_ID.test(id)) return err(400, "error.emote.query");

    let existing: Awaited<ReturnType<typeof getRow>>;
    try {
        existing = await rowFor(d.db, id);
    } catch {
        return err(502, "error.emote.unavailable");
    }
    if (existing) return { status: 200, body: shaped(existing, id) };

    let data: unknown;
    try {
        data = await gql(fetchImpl, ONE, { id }, d.sevenTvGate, d.now);
    } catch (e) {
        return failed(e);
    }
    const hit = readEmote((data as { emotes?: { emote?: unknown } })?.emotes?.emote);
    const chosen = hit ? pickWebp(hit.images, hit.animated) : null;
    if (!hit || !chosen || !cdnHost(chosen.url)) return err(404, "error.emote.not_found");

    let bytes: ArrayBuffer;
    try {
        const res = await fetchImpl(chosen.url, { signal: AbortSignal.timeout(20_000) });
        if (!res.ok || new URL(res.url).host !== CDN_HOST) return err(502, "error.emote.unavailable");
        bytes = await res.arrayBuffer();
    } catch {
        return err(502, "error.emote.unavailable");
    }
    if (bytes.byteLength === 0 || bytes.byteLength > MAX_BYTES) return err(400, "error.emote.too_big");

    const name = mintName(d.randomBytes);
    const url = (d.mediaBaseUrl.endsWith("/") ? d.mediaBaseUrl : `${d.mediaBaseUrl}/`) + name;
    try {
        // The bytes themselves. A default ReadableStream is not a byte stream, and R2 refuses it.
        await d.media.put(name, bytes, {
            httpMetadata: { contentType: "image/webp", cacheControl: "public, max-age=31536000, immutable" },
            customMetadata: { source: "emote", emoteId: id },
        });
    } catch {
        return err(502, "error.emote.unavailable");
    }

    const itemId = await insertMediaItem(d.db, {
        kind: "public",
        source: "emote",
        bucket: "media",
        r2_key: name,
        url,
        name: hit.name,
        content_type: "image/webp",
        bytes: bytes.byteLength,
        width: chosen.width,
        height: chosen.height,
        link: linkFor(id),
        key_id: keyId,
        created_at: d.now(),
    });
    if (!itemId) {
        await d.media.delete(name).catch(() => {});
        return err(502, "error.emote.unavailable");
    }
    const row = await getRow(d.db, itemId);
    if (!row) return err(502, "error.emote.unavailable");
    return { status: 201, body: shaped(row, id) };
}
