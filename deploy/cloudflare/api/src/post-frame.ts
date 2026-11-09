// Post frames (APP-API-CONTRACT.md section 52.2 and 52.5): POST /library/items/<id>/post-frame's body checked, the spec
// frozen and queued as an editor render of kind 'post'. No Cloudflare imports.
import { EDIT_QUEUE_MAX, getRender, renderShape, type EditsDeps } from "./edits";
import type { InputRef } from "./edit-render-core";
import { randomBase62 } from "./ids";
import { PATCH_FIELDS, POST_SITES, detailsShape, parsePatch, siteOf, type DetailsPatch, type DetailsRow, type PostSite } from "./post-details";
import type { StudioReply } from "./studio";

export const POST_THEMES = ["dark", "light"] as const;
export const POST_CANVASES = ["fit", "portrait", "square"] as const;
export const POST_SHOW = ["avatar", "text", "counts", "time"] as const;
// at most this much of the source is framed (52.2)
export const POST_FRAME_MAX_SECONDS = 600;
// the inputs (31's caps): one video at most this big
export const POST_FRAME_MAX_BYTES = 6 * 1024 ** 3;

export type PostFrameOptions = {
    style: PostSite | null;
    theme: (typeof POST_THEMES)[number];
    canvas: (typeof POST_CANVASES)[number];
    show: Record<(typeof POST_SHOW)[number], boolean>;
    from: number | null;
    to: number | null;
    details: DetailsPatch;
    notify: boolean;
};

const KEYS = new Set(["style", "theme", "canvas", "show", "from", "to", "details", "notify"]);

/** The route's body (52.2), checked: the key that is wrong, or the options. */
export function parsePostFrameOptions(b: unknown): { ok: true; options: PostFrameOptions } | { ok: false; path: string } {
    if (b === undefined || b === null) b = {};
    if (typeof b !== "object" || Array.isArray(b)) return { ok: false, path: "" };
    const o = b as Record<string, unknown>;
    for (const k of Object.keys(o)) if (!KEYS.has(k)) return { ok: false, path: k };
    const style = o.style ?? null;
    if (style !== null && (typeof style !== "string" || !(POST_SITES as readonly string[]).includes(style))) return { ok: false, path: "style" };
    const theme = o.theme ?? "dark";
    if (typeof theme !== "string" || !(POST_THEMES as readonly string[]).includes(theme)) return { ok: false, path: "theme" };
    const canvas = o.canvas ?? "fit";
    if (typeof canvas !== "string" || !(POST_CANVASES as readonly string[]).includes(canvas)) return { ok: false, path: "canvas" };
    const show = { avatar: true, text: true, counts: true, time: true };
    if (o.show !== undefined && o.show !== null) {
        if (typeof o.show !== "object" || Array.isArray(o.show)) return { ok: false, path: "show" };
        for (const [k, v] of Object.entries(o.show as Record<string, unknown>)) {
            if (!(POST_SHOW as readonly string[]).includes(k) || typeof v !== "boolean") return { ok: false, path: `show.${k}` };
            show[k as keyof typeof show] = v;
        }
    }
    const sec = (k: "from" | "to"): number | null | undefined => {
        const v = o[k];
        if (v === undefined || v === null) return null;
        return typeof v === "number" && Number.isFinite(v) && v >= 0 && v < 1e6 ? Math.round(v * 1000) / 1000 : undefined;
    };
    const from = sec("from"), to = sec("to");
    if (from === undefined) return { ok: false, path: "from" };
    if (to === undefined || (to !== null && to <= (from ?? 0))) return { ok: false, path: "to" };
    let details: DetailsPatch = {};
    if (o.details !== undefined && o.details !== null) {
        const p = parsePatch(o.details);
        if (!p.ok) return { ok: false, path: p.path ? `details.${p.path}` : "details" };
        details = p.patch;
    }
    if (o.notify !== undefined && typeof o.notify !== "boolean") return { ok: false, path: "notify" };
    return {
        ok: true,
        options: { style: style as PostSite | null, theme: theme as PostFrameOptions["theme"], canvas: canvas as PostFrameOptions["canvas"], show, from, to, details, notify: o.notify === true },
    };
}

// The frozen spec (`edit_renders.timeline` when `kind` is 'post'; 52.5).
export type PostSpec = {
    kind: "post";
    item: string;
    style: PostSite;
    theme: string;
    canvas: string;
    show: Record<string, boolean>;
    from: number;
    to: number | null;
    host: string | null;
    details: Record<string, unknown>;
    video: { width: number | null; height: number | null };
    inputs: InputRef[];
};

/** The inputs of a post spec, checked; null when the text is not one. */
export function postSpecInputs(text: string): InputRef[] | null {
    let spec: PostSpec;
    try {
        spec = JSON.parse(text) as PostSpec;
    } catch {
        return null;
    }
    if (!spec || spec.kind !== "post" || !Array.isArray(spec.inputs) || spec.inputs.length < 1 || spec.inputs.length > 2) return null;
    const out: InputRef[] = [];
    for (const [i, x] of spec.inputs.entries()) {
        if (!x || x.n !== i || typeof x.item !== "string" || typeof x.key !== "string" || (x.bucket !== "media" && x.bucket !== "originals")) return null;
        if (x.kind !== (i === 0 ? "video" : "photo")) return null;
        out.push({ n: x.n, item: x.item, bucket: x.bucket, key: x.key, bytes: Number(x.bytes) || 0, kind: x.kind });
    }
    return out;
}

/** What the container gets (`{"post": …}` on start, 52.5): the spec without its inputs. */
export function postStartSpec(spec: PostSpec): Omit<PostSpec, "inputs"> {
    const { inputs: _i, ...rest } = spec;
    return rest;
}

export type PostItemRow = {
    id: string;
    bucket: string;
    r2_key: string;
    bytes: number | null;
    content_type: string | null;
    width: number | null;
    height: number | null;
    duration: number | null;
    link: string | null;
    name: string | null;
    deleted_at: number | null;
};

/** Builds the spec. Pure. `row` the stored details (52.1); `options.details` overrides them for this render. */
export function buildPostSpec(item: PostItemRow, row: DetailsRow | null, options: PostFrameOptions): PostSpec {
    const { site, host } = siteOf(item.link);
    const shaped = row ? detailsShape(row, null) : null;
    const details: Record<string, unknown> = {};
    if (shaped) {
        for (const k of ["name", "handle", "text", "title", "channel", "game", "clipper", "site_name", "posted_at", "verified", "counts"] as const) {
            const v = shaped[k];
            if (v !== null && v !== undefined) details[k] = v;
        }
    }
    for (const k of PATCH_FIELDS) {
        if (k in options.details) {
            const v = options.details[k];
            if (v === null || v === undefined) delete details[k];
            else details[k] = v;
        }
    }
    const inputs: InputRef[] = [{ n: 0, item: item.id, bucket: item.bucket as "media" | "originals", key: item.r2_key, bytes: item.bytes ?? 0, kind: "video" }];
    if (row?.avatar_key) inputs.push({ n: 1, item: item.id, bucket: "originals", key: row.avatar_key, bytes: 0, kind: "photo" });
    const from = options.from ?? 0;
    const to = options.to !== null ? Math.min(options.to, from + POST_FRAME_MAX_SECONDS) : null;
    return {
        kind: "post",
        item: item.id,
        style: options.style ?? (row?.site as PostSite | undefined) ?? site,
        theme: options.theme,
        canvas: options.canvas,
        show: options.show,
        from,
        to,
        host,
        details,
        video: { width: item.width, height: item.height },
        inputs,
    };
}

/** The seconds a render of `spec` makes (for the progress), when the duration is known. */
export function postSeconds(spec: PostSpec, duration: number | null): number {
    const end = spec.to ?? duration ?? spec.from + POST_FRAME_MAX_SECONDS;
    return Math.max(0.1, Math.min(POST_FRAME_MAX_SECONDS, end - spec.from));
}

const err = (status: number, code: string, extra: Record<string, unknown> = {}): StudioReply => ({ status, body: { status: "error", error: { code }, ...extra } });

/** Queues a framed copy (52.2) and kicks the renderers. `title` is the source post's title. */
export async function queuePostFrame(d: EditsDeps, item: PostItemRow, row: DetailsRow | null, options: PostFrameOptions, title: string): Promise<StudioReply> {
    if (!String(item.content_type ?? "").toLowerCase().startsWith("video/")) return err(409, "error.post.not_video");
    if ((item.bytes ?? 0) > POST_FRAME_MAX_BYTES) return err(413, "error.edit.too_large");
    const spec = buildPostSpec(item, row, options);
    const busy = await d.db.prepare("SELECT COUNT(*) AS n FROM edit_renders WHERE status IN ('queued', 'preparing', 'rendering', 'finishing')").first<{ n: number }>();
    if ((busy?.n ?? 0) >= EDIT_QUEUE_MAX) return err(429, "error.edit.queue_full");
    const rid = randomBase62(20, d.randomBytes);
    const now = d.now();
    const inputBytes = spec.inputs.reduce((a, i) => a + i.bytes, 0);
    await d.db
        .prepare(
            `INSERT INTO edit_renders (id, kind, thread_id, project_id, revision, title, timeline, status, cancel_requested, attempts, input_bytes, seconds_total, notify, key_id, created_at, updated_at)
             VALUES (?1, 'post', NULL, ?2, 0, ?3, ?4, 'queued', 0, 0, ?5, ?6, ?7, ?8, ?9, ?9)`,
        )
        .bind(rid, `post:${item.id}`, `${title} (post)`.slice(0, 200), JSON.stringify(spec), inputBytes, postSeconds(spec, item.duration), options.notify ? 1 : 0, d.keyId, now)
        .run();
    await d.kick().catch(() => {});
    const made = await getRender(d.db, rid);
    return made ? { status: 202, body: { status: "success", render: renderShape(made) } } : err(503, "error.api.generic");
}

/** features.post_frame's migration check: migration 0036 is applied. */
export async function postFrameReady(db: D1Database): Promise<boolean> {
    try {
        await db.prepare("SELECT link FROM post_details LIMIT 0").all();
        return true;
    } catch {
        return false;
    }
}
