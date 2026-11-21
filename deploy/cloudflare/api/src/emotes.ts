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
// Variants (section 20.2): 7TV's own exact-name filter on the emote's default name (not a set's alias).
const SEARCH_EXACT = `query($query: String, $sort: Sort!, $page: Int!, $perPage: Int!) {
  emotes { search(query: $query, sort: $sort, filters: { exactMatch: true }, page: $page, perPage: $perPage) {
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
export class GqlFailure extends Error {
    constructor(
        readonly status: number,
        readonly retryAfter: number | null,
    ) {
        super(`7tv ${status}`);
    }
}

// The last answer's GraphQL errors, for the callers that cache (a partial answer is never kept): gql() answers data only.
const partialAnswers = new WeakSet<object>();
const isPartial = (data: unknown) => typeof data === "object" && data !== null && partialAnswers.has(data);

export async function publicGql(fetchImpl: typeof fetch, query: string, variables: Record<string, unknown>, gate?: SevenTvGate | null, now: () => number = Date.now): Promise<unknown> {
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
    if (Array.isArray(body.errors) && body.errors.length > 0 && typeof body.data === "object" && body.data !== null) partialAnswers.add(body.data);
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
type FoundEmote = { id: string; name: string; animated: boolean; preview_url: string; file_url: string; width: number; height: number; frames?: number };
type FoundPage = { items: FoundEmote[]; has_more: boolean };

// The Workers Cache API's shape (caches.default), or a fake in the tests.
export type EmoteCache = { match(key: Request): Promise<Response | undefined>; put(key: Request, res: Response): Promise<void> };
export const EMOTE_CACHE_S = 24 * 60 * 60;
// an answer with no emotes is kept only briefly: a new upload by that name shows up soon
export const EMOTE_CACHE_EMPTY_S = 10 * 60;
export const FIND_MANY_MAX = 20;

const cacheOf = (d: Pick<AppDeps, "emoteCache">): EmoteCache | null => {
    if (d.emoteCache !== undefined) return d.emoteCache;
    const c = (globalThis as { caches?: { default?: EmoteCache } }).caches?.default;
    return c ?? null;
};
const normQuery = (q: string) => q.trim().toLowerCase().replace(/\s+/g, " ");
const cacheKey = (query: string, sort: EmoteSort, page: number, exact = false) =>
    new Request(
        `https://emote-cache.internal/find?${new URLSearchParams({ q: normQuery(query), sort, page: String(page), ...(exact ? { exact: "1" } : {}) })}`,
    );

async function cached(d: Pick<AppDeps, "emoteCache">, query: string, sort: EmoteSort, page: number, exact = false): Promise<FoundPage | null> {
    const c = cacheOf(d);
    if (!c) return null;
    try {
        const hit = await c.match(cacheKey(query, sort, page, exact));
        return hit ? ((await hit.json()) as FoundPage) : null;
    } catch {
        return null;
    }
}

async function remember(d: Pick<AppDeps, "emoteCache">, query: string, sort: EmoteSort, page: number, found: FoundPage, exact = false): Promise<void> {
    const c = cacheOf(d);
    if (!c) return;
    try {
        const ttl = found.items.length > 0 ? EMOTE_CACHE_S : EMOTE_CACHE_EMPTY_S;
        await c.put(cacheKey(query, sort, page, exact), new Response(JSON.stringify(found), { headers: { "content-type": "application/json", "cache-control": `public, max-age=${ttl}` } }));
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
        items.push({ id: hit.id, name: hit.name, animated: hit.animated, preview_url: preview.url, file_url: file.url, width: file.width, height: file.height, frames: file.frameCount });
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
    // exact=1 (section 20.2): only emotes whose own 7TV name is the query (any case), a name required
    const exactRaw = q.get("exact");
    if (exactRaw !== null && exactRaw !== "1" && exactRaw !== "0") return err(400, "error.emote.query");
    const exact = exactRaw === "1";
    if (exact && query.length < 1) return err(400, "error.emote.query");

    let found = await cached(d, query, sort, page, exact);
    const hit = found !== null;
    if (!found) {
        try {
            const text = sort === "global" ? GLOBAL : exact ? SEARCH_EXACT : SEARCH;
            const data = await publicGql(fetchImpl, text, searchVars(query, sort, page), d.sevenTvGate, d.now);
            const raw = foundIn(data, sort);
            found = foundOf(raw, sort, page);
            if (exact) {
                // 7TV's filter matches the name as a token; keep only the same whole name (case aside)
                const want = query.toLowerCase();
                found = { ...found, items: found.items.filter((h) => h.name.toLowerCase() === want) };
            }
            // a partial answer (GraphQL errors) or a missing search is answered but never cached
            if (raw && !isPartial(data)) await remember(d, query, sort, page, found, exact);
        } catch (e) {
            return failed(e);
        }
    }
    let items;
    try {
        items = await withLibrary(d, found.items);
    } catch {
        return err(502, "error.emote.unavailable");
    }
    return { status: 200, body: { items, sort, page, has_more: found.has_more, ...(exact ? { exact: true } : {}), ...(hit ? { cached: true } : {}) } };
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
            data = await publicGql(fetchImpl, `query(${defs.join(", ")}) { ${parts.join(" ")} }`, vars, d.sevenTvGate, d.now);
        } catch (e) {
            return failed(e);
        }
        for (const [i, x] of missing.entries()) {
            const one = (data as Record<string, unknown>)?.[`s${i}`];
            const raw = one ? foundIn(sort === "global" ? { emoteSets: one } : { emotes: one }, sort) : undefined;
            const page = foundOf(raw, sort, 1);
            found.set(x, { page, cached: false });
            // an alias that came back null (its search failed) or any GraphQL error: not cached
            if (raw && !isPartial(data)) await remember(d, x, sort, 1, page);
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
        data = await publicGql(fetchImpl, ONE, { id }, d.sevenTvGate, d.now);
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

// ---- deep variant search (section 63.2) ---------------------------------------------------------------------------------

export const VARIANT_PAGES_MAX = 20;
export const VARIANT_WORDS_MAX = 8;
const PAGES_PER_REQUEST = 10;
// Seasonal words a season name stands for (any other word is used as given).
export const SEASON_WORDS: Record<string, string[]> = {
    christmas: ["xmas", "christmas", "santa", "winter", "snow", "festive"],
    halloween: ["halloween", "spooky", "pumpkin", "witch", "ghost"],
    valentine: ["valentine", "love", "heart"],
    easter: ["easter", "bunny"],
    newyear: ["newyear", "nye", "party"],
    summer: ["summer", "beach"],
};

type PageAsk = { query: string; exact: boolean; page: number };
const pageKey = (a: PageAsk) => `${a.exact ? "x" : "f"}:${normQuery(a.query)}:${a.page}`;

// Many search pages in as few 7TV requests as it takes (10 aliased searches each), the 24 h cache first.
async function searchPages(d: AppDeps, asks: PageAsk[], fetchImpl: typeof fetch): Promise<Map<string, FoundPage>> {
    const out = new Map<string, FoundPage>();
    const missing: PageAsk[] = [];
    for (const a of asks) {
        if (out.has(pageKey(a))) continue;
        const c = await cached(d, a.query, "top", a.page, a.exact);
        if (c) out.set(pageKey(a), c);
        else if (!missing.some((m) => pageKey(m) === pageKey(a))) missing.push(a);
    }
    for (let i = 0; i < missing.length; i += PAGES_PER_REQUEST) {
        const part = missing.slice(i, i + PAGES_PER_REQUEST);
        const vars: Record<string, unknown> = { sort: { sortBy: EMOTE_SORTS.top, order: "DESCENDING" }, perPage: PER_PAGE };
        const defs = ["$sort: Sort!", "$perPage: Int!"];
        const parts = part.map((a, k) => {
            vars[`q${k}`] = a.query;
            vars[`p${k}`] = a.page;
            defs.push(`$q${k}: String`, `$p${k}: Int!`);
            return `s${k}: emotes { search(query: $q${k}, sort: $sort, ${a.exact ? "filters: { exactMatch: true }, " : ""}page: $p${k}, perPage: $perPage) { pageCount items { ${FIELDS} } } }`;
        });
        const data = await publicGql(fetchImpl, `query(${defs.join(", ")}) { ${parts.join(" ")} }`, vars, d.sevenTvGate, d.now);
        for (const [k, a] of part.entries()) {
            const one = (data as Record<string, unknown>)?.[`s${k}`];
            const raw = one ? foundIn({ emotes: one }, "top") : undefined;
            const page = foundOf(raw, "top", a.page);
            out.set(pageKey(a), page);
            if (raw && !isPartial(data)) await remember(d, a.query, "top", a.page, page, a.exact);
        }
    }
    return out;
}

// Every page of one search, up to `max`: page 1 first, then the rest (as far as 7TV says there are) in batches.
async function allPages(d: AppDeps, query: string, exact: boolean, max: number, fetchImpl: typeof fetch): Promise<{ items: FoundEmote[]; pages: number; complete: boolean }> {
    const items: FoundEmote[] = [];
    let page = 1;
    let more = true;
    while (more && page <= max) {
        // one page to learn whether there are more, then up to PAGES_PER_REQUEST at once
        const want = page === 1 ? [1] : Array.from({ length: Math.min(PAGES_PER_REQUEST, max - page + 1) }, (_, k) => page + k);
        const got = await searchPages(d, want.map((p) => ({ query, exact, page: p })), fetchImpl);
        for (const p of want) {
            const f = got.get(pageKey({ query, exact, page: p }))!;
            items.push(...f.items);
            more = f.has_more;
            page = p + 1;
            if (!more) break;
        }
    }
    return { items, pages: page - 1, complete: !more };
}

export type VariantInput = {
    name?: string;
    emote_id?: string;
    season?: string;
    words?: string[];
    animated?: "same" | "any" | "yes" | "no";
    size?: "same" | "any";
    max_pages?: number;
};

/**
 * Every same-name and seasonal-named upload of an emote across all result pages (section 63.2). The emote by id gives
 * its own 7TV name, animated flag and shape to filter on; by name, only the name. Matches: same_name (the whole name,
 * any case), contains (the name inside a longer one, e.g. LaPeaceXmas), seasonal (contains it and a seasonal word).
 */
export async function deepVariants(d: AppDeps, input: VariantInput, fetchImpl: typeof fetch = fetch): Promise<StudioReply> {
    let name = (input.name ?? "").trim();
    let base: { id: string; animated: boolean; width: number; height: number } | null = null;
    try {
        if (input.emote_id) {
            const data = await publicGql(fetchImpl, ONE, { id: input.emote_id }, d.sevenTvGate, d.now);
            const hit = readEmoteAny((data as { emotes?: { emote?: unknown } })?.emotes?.emote);
            if (!hit) return err(404, "error.emote.not_found");
            const file = pickWebp(hit.images, hit.animated);
            base = { id: hit.id, animated: hit.animated, width: file?.width ?? 0, height: file?.height ?? 0 };
            if (!name) name = hit.name;
        }
        if (name.length < 1 || name.length > 64) return err(400, "error.emote.query");
        const words = [...new Set([...(input.season ? SEASON_WORDS[input.season.toLowerCase()] ?? [input.season] : []), ...(input.words ?? [])].map((w) => w.trim().toLowerCase()).filter((w) => w.length > 0))].slice(0, VARIANT_WORDS_MAX);
        const max = Math.min(VARIANT_PAGES_MAX, Math.max(1, input.max_pages ?? VARIANT_PAGES_MAX));
        const exact = await allPages(d, name, true, max, fetchImpl);
        const fuzzy = await allPages(d, name, false, max, fetchImpl);
        const seasonal = words.length > 0
            ? await searchPages(d, words.flatMap((w) => [`${name}${w}`, `${w}${name}`, `${name} ${w}`].map((q) => ({ query: q, exact: false, page: 1 }))), fetchImpl)
            : new Map<string, FoundPage>();
        const want = name.toLowerCase();
        const byId = new Map<string, FoundEmote & { match: "same_name" | "contains" | "seasonal"; word?: string }>();
        const add = (h: FoundEmote) => {
            if (base && h.id === base.id) return;
            const n = h.name.toLowerCase();
            let match: "same_name" | "contains" | "seasonal" | null = null;
            let word: string | undefined;
            if (n === want) match = "same_name";
            else if (n.includes(want)) {
                word = words.find((w) => n.includes(w));
                match = word ? "seasonal" : "contains";
            }
            if (!match) return;
            const prev = byId.get(h.id);
            if (!prev || (prev.match === "contains" && match === "seasonal")) byId.set(h.id, { ...h, match, ...(word ? { word } : {}) });
        };
        for (const h of exact.items) add(h);
        for (const h of fuzzy.items) add(h);
        for (const p of seasonal.values()) for (const h of p.items) add(h);

        const animatedRule = input.animated ?? (base ? "same" : "any");
        const sizeRule = input.size ?? (base ? "same" : "any");
        const ratio = base && base.height > 0 ? base.width / base.height : null;
        const dropped = { animated: 0, size: 0 };
        const kept = [...byId.values()].filter((h) => {
            const animOk =
                animatedRule === "any" ||
                (animatedRule === "yes" && h.animated) ||
                (animatedRule === "no" && !h.animated) ||
                (animatedRule === "same" && (!base || h.animated === base.animated));
            if (!animOk) {
                dropped.animated++;
                return false;
            }
            if (sizeRule === "same" && ratio !== null && h.height > 0 && Math.abs(h.width / h.height - ratio) > 0.08 * ratio) {
                dropped.size++;
                return false;
            }
            return true;
        });
        const order = { same_name: 0, seasonal: 1, contains: 2 } as const;
        kept.sort((a, b) => order[a.match] - order[b.match] || a.name.localeCompare(b.name) || (a.id < b.id ? -1 : 1));
        const lib = await withLibrary(d, kept);
        return {
            status: 200,
            body: {
                name,
                ...(base ? { base: { emote_id: base.id, animated: base.animated, width: base.width, height: base.height } } : {}),
                words,
                filters: { animated: animatedRule, size: sizeRule },
                pages_read: { same_name: exact.pages, contains: fuzzy.pages, seasonal: seasonal.size },
                complete: exact.complete && fuzzy.complete,
                found: byId.size,
                dropped,
                variants: lib.map((h, i) => ({
                    emote_id: h.id,
                    name: h.name,
                    match: kept[i]!.match,
                    ...(kept[i]!.word ? { word: kept[i]!.word } : {}),
                    animated: h.animated,
                    frames: h.frames ?? null,
                    width: h.width,
                    height: h.height,
                    preview_url: h.preview_url,
                    page_url: `https://7tv.app/emotes/${h.id}`,
                    library_id: h.library_id,
                })),
            },
        };
    } catch (e) {
        return failed(e);
    }
}

// An emote read by id, private and zero-width ones too (the variant search's base may be either).
function readEmoteAny(raw: unknown): EmoteHit | null {
    if (!raw || typeof raw !== "object") return null;
    const o = raw as Record<string, unknown>;
    if (o.flags && typeof o.flags === "object") return readEmote({ ...o, flags: { ...(o.flags as object), private: false, defaultZeroWidth: false } });
    return readEmote(o);
}
