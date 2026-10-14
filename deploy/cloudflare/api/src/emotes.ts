// 7TV emotes (APP-API-CONTRACT.md section 20). The Worker asks 7TV, then stores
// one public webp. The phone never talks to 7TV. Search stores nothing.

import type { AppDeps } from "./app-routes";
import { insertMediaItem } from "./library";
import type { StudioReply } from "./studio";
import { getRow, itemShape } from "./visibility";
import { mintName } from "./webp";

const GQL = "https://7tv.io/v4/gql";
const CDN_HOST = "cdn.7tv.app";
const MAX_BYTES = 15_000_000;
const EMOTE_ID = /^[0-9A-Za-z]{20,32}$/;
const PREVIEW_SCALES = [2, 1, 3, 4];

const SEARCH = `query($query: String!, $perPage: Int!) {
  emotes { search(query: $query, sort: { sortBy: TOP_ALL_TIME, order: DESCENDING }, page: 1, perPage: $perPage) {
    items { id defaultName deleted flags { animated defaultZeroWidth private } images { url mime size scale width height frameCount } } } } }`;

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

async function gql(fetchImpl: typeof fetch, query: string, variables: Record<string, unknown>): Promise<unknown> {
    const res = await fetchImpl(GQL, {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/json" },
        body: JSON.stringify({ query, variables }),
        signal: AbortSignal.timeout(20_000),
    });
    if (!res.ok) throw new Error(`7tv ${res.status}`);
    const body = (await res.json()) as { data?: unknown; errors?: unknown };
    if (!body.data || (Array.isArray(body.errors) && body.errors.length > 0 && body.data == null)) {
        throw new Error("7tv graphql");
    }
    return body.data;
}

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

export async function searchEmotes(
    d: AppDeps,
    q: URLSearchParams,
    fetchImpl: typeof fetch = fetch,
): Promise<StudioReply> {
    const query = (q.get("q") ?? "").trim();
    if (query.length < 1 || query.length > 64) return err(400, "error.emote.query");
    let data: unknown;
    try {
        data = await gql(fetchImpl, SEARCH, { query, perPage: 24 });
    } catch {
        return err(502, "error.emote.unavailable");
    }
    const itemsRaw = (data as { emotes?: { search?: { items?: unknown } } })?.emotes?.search?.items;
    const hits = (Array.isArray(itemsRaw) ? itemsRaw : []).map(readEmote).filter((h): h is EmoteHit => h !== null);
    let saved = new Map<string, { id: string; url: string | null }>();
    try {
        saved = await savedIds(d.db, hits.map((h) => h.id));
    } catch {
        return err(502, "error.emote.unavailable");
    }
    const items = [];
    for (const hit of hits) {
        const preview = previewWebp(hit.images, hit.animated);
        const file = pickWebp(hit.images, hit.animated);
        if (!preview || !cdnHost(preview.url) || !file || !cdnHost(file.url)) continue;
        items.push({
            id: hit.id,
            name: hit.name,
            animated: hit.animated,
            preview_url: preview.url,
            file_url: file.url,
            library_id: saved.get(hit.id)?.id ?? null,
            library_url: saved.get(hit.id)?.url ?? null,
        });
    }
    return { status: 200, body: { items } };
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
        data = await gql(fetchImpl, ONE, { id });
    } catch {
        return err(502, "error.emote.unavailable");
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
    const stream = new ReadableStream<Uint8Array>({
        start(controller) {
            controller.enqueue(new Uint8Array(bytes));
            controller.close();
        },
    });
    try {
        await d.media.put(name, stream, {
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
