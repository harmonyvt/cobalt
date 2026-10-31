// Cutouts (APP-API-CONTRACT.md section 39.5): a picture with its background taken out, saved as a NEW private PNG in the
// library, linked to the picture it came from (made_from). Two ways in, one route, POST /library/items/<id>/cutout:
//  - JSON `{mode, color?, tolerance?, edges_only?, soften?, trim?, title?}`: the Worker makes it. `auto` lifts the subject
//    with Cloudflare Images' background removal (`segment: "foreground"`, the IMAGES binding); `white` and `color` take that
//    colour out in the Worker (cutout-core.ts) on the picture decoded by the IMAGES binding (or straight from a PNG).
//  - `content-type: image/png` with the PNG as the body: the app made the cutout on the device (Vision or the same colour
//    rules) and the server only stores it and records where it came from.
// No Cloudflare imports here beyond types: the tests run it under node with fakes.

import {
    CUTOUT_DEFAULTS,
    CUTOUT_MAX_SIDE,
    cutout,
    decodePng,
    encodePng,
    isPng,
    parseHexColor,
    pngSize,
    subjectBox,
    crop,
    type CutoutOptions,
    type Rgba,
} from "./cutout-core";
import { insertMediaItem, mintItemId } from "./library";
import { cleanTitle, upsertTitle } from "./studio";
import { getRow, itemShape, type MediaRow } from "./visibility";

export const CUTOUT_SOURCE_TYPES = ["image/jpeg", "image/png", "image/webp", "image/gif", "image/avif", "image/heic"];
/** The biggest source picture the server reads (bytes), and the biggest PNG the app may send. */
export const CUTOUT_MAX_SOURCE_BYTES = 30 * 1024 * 1024;
export const CUTOUT_MAX_UPLOAD_BYTES = 20 * 1024 * 1024;
/** The app's PNG may be at most this many pixels a side (Vision works on the full photo). */
export const CUTOUT_MAX_UPLOAD_SIDE = 8192;

export type CutoutMode = "auto" | "white" | "color";

type Bucket = {
    get(key: string): Promise<{ body: ReadableStream<Uint8Array>; size: number } | null>;
    put(key: string, value: ArrayBuffer | ArrayBufferView | ReadableStream, opts?: unknown): Promise<unknown>;
    delete(key: string): Promise<unknown>;
};

/** The few calls of the Images binding this uses (`env.IMAGES`). */
export type ImagesPort = {
    input(stream: ReadableStream<Uint8Array>): {
        transform(t: Record<string, unknown>): { output(o: { format: string }): Promise<{ response(): Response }> };
    };
};

export type CutoutDeps = {
    db: D1Database;
    originals: Bucket;
    media: Bucket;
    images: ImagesPort | null;
    now: () => number;
    randomBytes?: (n: number) => Uint8Array;
};

export type CutoutReply = { status: number; body: Record<string, unknown> };

const fail = (status: number, code: string, message?: string): CutoutReply => ({
    status,
    body: { status: "error", error: { code }, ...(message ? { message } : {}) },
});

export type CutoutSpec = {
    mode: CutoutMode;
    color?: string;
    tolerance?: number;
    edges_only?: boolean;
    soften?: number;
    trim?: boolean;
    title?: string;
};

/** Checks a JSON spec; the defaults of 39.5 filled in. */
export function parseSpec(b: unknown): { ok: true; spec: Required<Omit<CutoutSpec, "color" | "title">> & { color: string | null; title: string | null } } | { ok: false; path: string } {
    if (typeof b !== "object" || b === null || Array.isArray(b)) return { ok: false, path: "" };
    const o = b as Record<string, unknown>;
    for (const k of Object.keys(o)) if (!["mode", "color", "tolerance", "edges_only", "soften", "trim", "title"].includes(k)) return { ok: false, path: k };
    const mode = o.mode ?? "auto";
    if (mode !== "auto" && mode !== "white" && mode !== "color") return { ok: false, path: "mode" };
    let color: string | null = null;
    if (o.color !== undefined) {
        if (typeof o.color !== "string" || !parseHexColor(o.color)) return { ok: false, path: "color" };
        color = o.color;
    }
    if (mode === "color" && !color) return { ok: false, path: "color" };
    const num = (k: string, lo: number, hi: number, def: number) => {
        const v = o[k];
        if (v === undefined) return def;
        return typeof v === "number" && Number.isFinite(v) && v >= lo && v <= hi ? v : null;
    };
    const tolerance = num("tolerance", 0, 100, CUTOUT_DEFAULTS.tolerance);
    if (tolerance === null) return { ok: false, path: "tolerance" };
    const soften = num("soften", 0, 3, CUTOUT_DEFAULTS.soften);
    if (soften === null) return { ok: false, path: "soften" };
    const flag = (k: string, def: boolean) => (o[k] === undefined ? def : typeof o[k] === "boolean" ? (o[k] as boolean) : null);
    const edges = flag("edges_only", CUTOUT_DEFAULTS.edgesOnly);
    if (edges === null) return { ok: false, path: "edges_only" };
    const trim = flag("trim", CUTOUT_DEFAULTS.trim);
    if (trim === null) return { ok: false, path: "trim" };
    let title: string | null = null;
    if (o.title !== undefined) {
        const t = cleanTitle(o.title);
        if (!t.ok) return { ok: false, path: "title" };
        title = t.title;
    }
    return { ok: true, spec: { mode, color, tolerance, edges_only: edges, soften: Math.round(soften), trim, title } };
}

const isImage = (ct: string | null) => CUTOUT_SOURCE_TYPES.includes(String(ct ?? "").split(";")[0]!.trim().toLowerCase());

/** The title a cutout gets: the source post's title (or its file name), then " cutout", at most 80 code points. */
async function titleFor(db: D1Database, row: MediaRow): Promise<string> {
    const t = await db
        .prepare("SELECT title FROM media_titles WHERE post_key IN (?1, ?2) ORDER BY post_key = ?1 DESC LIMIT 1")
        .bind(row.id, row.session_id ?? row.id)
        .first<{ title: string }>()
        .catch(() => null);
    const base = (t?.title ?? row.name ?? "").replace(/\.[A-Za-z0-9]{1,5}$/, "").replace(/[\u0000-\u001F\u007F-\u009F\u2028\u2029]/g, "").trim();
    return [...(base ? `${base} cutout` : "cutout")].slice(0, 80).join("");
}

/**
 * POST /library/items/<id>/cutout. `keyId` = the caller's key id (the new row's owner). Answers 201 `{status: "success",
 * item: <item>, cutout: {width, height, mode}}`.
 */
export async function makeCutout(d: CutoutDeps, id: string, request: Request, keyId: string): Promise<CutoutReply> {
    const row = await getRow(d.db, id);
    if (!row || row.id !== id) return fail(404, "error.cutout.not_found");
    if (!isImage(row.content_type)) return fail(409, "error.cutout.not_image");

    const type = (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    if (type === "image/png") return storeUpload(d, row, request, keyId);

    let raw: unknown;
    try {
        const text = await request.text();
        if (text.length > 4096) return fail(400, "error.cutout.bad_request");
        raw = text.trim() === "" ? {} : JSON.parse(text);
    } catch {
        return fail(400, "error.cutout.bad_request");
    }
    const p = parseSpec(raw);
    if (!p.ok) return { status: 400, body: { status: "error", error: { code: "error.cutout.bad_request" }, path: p.path } };
    const spec = p.spec;
    if (Number(row.bytes) > CUTOUT_MAX_SOURCE_BYTES) return fail(413, "error.cutout.too_large");

    const bucket = row.bucket === "media" ? d.media : d.originals;
    const obj = await bucket.get(row.r2_key);
    if (!obj) return fail(404, "error.cutout.not_found");

    // the picture as a PNG we can decode, at most 2048 px a side (and with the subject lifted for `auto`)
    let png: Uint8Array;
    if (d.images) {
        try {
            const out = await d.images
                .input(obj.body)
                .transform({ width: CUTOUT_MAX_SIDE, height: CUTOUT_MAX_SIDE, fit: "scale-down", ...(spec.mode === "auto" ? { segment: "foreground" } : {}) })
                .output({ format: "image/png" });
            png = new Uint8Array(await out.response().arrayBuffer());
        } catch (e) {
            console.error("[cutout] images binding failed", String(e));
            return fail(502, "error.cutout.failed");
        }
    } else {
        if (spec.mode === "auto" || !String(row.content_type).startsWith("image/png")) {
            await obj.body.cancel().catch(() => {});
            return fail(503, "error.cutout.off", "this server has no Cloudflare Images binding");
        }
        png = new Uint8Array(await new Response(obj.body).arrayBuffer());
    }

    let img: Rgba;
    try {
        img = await decodePng(png, CUTOUT_MAX_SIDE * CUTOUT_MAX_SIDE);
    } catch {
        return fail(502, "error.cutout.failed");
    }
    let result: Rgba | null;
    if (spec.mode === "auto") {
        const box = subjectBox(img);
        result = box ? (spec.trim ? crop(img, box) : img) : null;
    } else {
        const opts: CutoutOptions = {
            mode: spec.mode,
            color: spec.mode === "color" ? (parseHexColor(spec.color!) ?? undefined) : undefined,
            tolerance: spec.tolerance,
            edgesOnly: spec.edges_only,
            soften: spec.soften,
            trim: spec.trim,
        };
        result = cutout(img, opts);
    }
    if (!result) return fail(422, "error.cutout.empty", "nothing was left: lower the tolerance or pick another mode");
    const bytes = await encodePng(result);
    const madeSpec = {
        kind: "cutout",
        from: row.id,
        mode: spec.mode,
        ...(spec.mode === "color" ? { color: spec.color } : {}),
        ...(spec.mode !== "auto" ? { tolerance: spec.tolerance, edges_only: spec.edges_only, soften: spec.soften } : {}),
        trim: spec.trim,
    };
    return store(d, row, bytes, result.width, result.height, madeSpec, spec.title, keyId);
}

async function storeUpload(d: CutoutDeps, row: MediaRow, request: Request, keyId: string): Promise<CutoutReply> {
    const declared = Number(request.headers.get("content-length") ?? "NaN");
    if (Number.isFinite(declared) && declared > CUTOUT_MAX_UPLOAD_BYTES) {
        void request.body?.cancel().catch(() => {});
        return fail(413, "error.cutout.too_large");
    }
    const buf = new Uint8Array(await request.arrayBuffer());
    if (buf.length > CUTOUT_MAX_UPLOAD_BYTES) return fail(413, "error.cutout.too_large");
    const size = isPng(buf) ? pngSize(buf) : null;
    if (!size || size.width < 1 || size.height < 1 || size.width > CUTOUT_MAX_UPLOAD_SIDE || size.height > CUTOUT_MAX_UPLOAD_SIDE) {
        return fail(400, "error.cutout.bad_request");
    }
    let title: string | null = null;
    const q = new URL(request.url).searchParams;
    if (q.has("title")) {
        const t = cleanTitle(q.get("title"));
        if (!t.ok) return fail(400, "error.cutout.bad_request");
        title = t.title;
    }
    const mode = q.get("mode");
    const madeSpec = { kind: "cutout", from: row.id, mode: mode === "auto" || mode === "white" || mode === "color" ? mode : "device", device: true };
    return store(d, row, buf, size.width, size.height, madeSpec, title, keyId);
}

async function store(
    d: CutoutDeps,
    from: MediaRow,
    bytes: Uint8Array,
    width: number,
    height: number,
    madeSpec: Record<string, unknown>,
    title: string | null,
    keyId: string,
): Promise<CutoutReply> {
    const now = d.now();
    const name = mintItemId(d.randomBytes);
    const key = `cutouts/${name}.png`;
    try {
        await d.originals.put(key, bytes, {
            httpMetadata: { contentType: "image/png" },
            customMetadata: { keyId, source: "studio", cutoutOf: from.id, createdAt: String(now) },
        });
    } catch (e) {
        console.error("[cutout] R2 put failed", String(e));
        return fail(502, "error.cutout.storage");
    }
    const t = title ?? (await titleFor(d.db, from));
    const base = t.replace(/[/\\\u0000-\u001F\u007F]/g, "").trim().slice(0, 116) || "cutout";
    const id = await insertMediaItem(
        d.db,
        {
            kind: "private",
            source: "studio",
            bucket: "originals",
            r2_key: key,
            name: `${base}.png`,
            content_type: "image/png",
            bytes: bytes.length,
            width,
            height,
            duration: null,
            link: null,
            session_id: null,
            key_id: keyId,
            poster: null,
            role: null,
            made_from: JSON.stringify([from.id]),
            made_spec: JSON.stringify(madeSpec),
            post_key: null,
            created_at: now,
        },
        d.randomBytes,
    );
    if (!id) {
        await d.originals.delete(key).catch(() => {});
        return fail(503, "error.api.generic");
    }
    await upsertTitle(d.db, id, t, keyId, now).catch((e) => console.error("[cutout] could not store the title", String(e)));
    const made = await getRow(d.db, id);
    return {
        status: 201,
        body: { status: "success", item: made ? itemShape(made) : { id }, title: t, cutout: { width, height, mode: madeSpec.mode } },
    };
}
