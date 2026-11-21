// The emote editor's server half (APP-API-CONTRACT.md section 71): POST /7tv/emotes/make makes a draft with the
// container's emote fit (57.10, 71.3) and keeps it in R2 (src/emote-draft.ts); the draft routes read, delete and save it.
// No 7TV account is needed to make a draft. The upload of a draft is in src/seventv.ts (`draft` on POST /7tv/emotes).

import {
    DRAFT_ID,
    DRAFT_ID_LENGTH,
    DRAFT_TTL_MS,
    deleteDraft,
    putDraft,
    readDraft,
    type DraftBucket,
    type DraftInfo,
} from "./emote-draft";
import { randomBase62 } from "./ids";
import { insertMediaItem, mintItemId } from "./library";
import { cleanCrop, fail, fileRow, fitRefusal, FIT_INPUT_MAX, FIT_TYPES, UPLOAD_MAX, type EmoteFit } from "./seventv";
import { cleanTitle, upsertTitle, type StudioReply } from "./studio";

export type MakeDeps = {
    db: D1Database;
    now: () => number;
    keyId: string | null;
    originals: DraftBucket;
    media: { get(key: string): Promise<{ body: ReadableStream; size: number } | null> };
    fit?: EmoteFit;
    randomBytes?: (n: number) => Uint8Array;
};

export const MAKE_VIDEO_TYPES = ["video/mp4", "video/webm", "video/quicktime"];
export const MAKE_FORMATS = ["webp", "gif", "png"] as const;
const VIDEO_DEFAULT_SECONDS = 3;
const VIDEO_MIN_SECONDS = 0.2;
const VIDEO_MAX_SECONDS = 10;
const ok201 = (body: Record<string, unknown>): StudioReply => ({ status: 201, body: { status: "success", ...body } });
const num = (v: unknown, lo: number, hi: number) => typeof v === "number" && Number.isFinite(v) && v >= lo && v <= hi;
const absent = (v: unknown) => v === undefined || v === null;

type Body = Record<string, unknown>;

/** POST /7tv/emotes/make (71.1). */
export async function makeEmote(d: MakeDeps, body: Body): Promise<StudioReply> {
    const bad = (m: string) => fail(400, "error.seventv.bad", m);
    if (!d.keyId) return fail(404, "error.seventv.draft_not_found");
    const ref = typeof body.file === "string" ? body.file.trim() : "";
    if (!ref || ref.length > 64) return bad("file is a library file id, public id or post id");
    const crop = cleanCrop(body.crop);
    if (crop === false) return bad("crop is {x, y, w, h} as fractions of the picture");
    let stretch: { w: number; h: number } | null = null;
    if (!absent(body.stretch)) {
        const s = body.stretch as Record<string, unknown>;
        if (typeof s !== "object" || !num(s.w, 0.25, 4) || !num(s.h, 0.25, 4)) return bad("stretch is {w, h}, each 0.25 to 4");
        stretch = { w: s.w as number, h: s.h as number };
    }
    const intIn = (v: unknown, lo: number, hi: number) => typeof v === "number" && Number.isInteger(v) && v >= lo && v <= hi;
    if (!absent(body.size) && !intIn(body.size, 32, 1000)) return bad("size is 32 to 1000 px");
    if (!absent(body.format) && !(MAKE_FORMATS as readonly unknown[]).includes(body.format)) return bad("format is webp, gif or png");
    if (!absent(body.quality) && !intIn(body.quality, 1, 100)) return bad("quality is 1 to 100");
    if (!absent(body.fps) && !intIn(body.fps, 5, 50)) return bad("fps is 5 to 50");
    if (!absent(body.start) && !num(body.start, 0, 86400)) return bad("start is seconds");
    if (!absent(body.end) && !num(body.end, 0, 86400)) return bad("end is seconds");
    if (!absent(body.frame) && !num(body.frame, 0, 86400)) return bad("frame is seconds");
    if (!absent(body.bounce) && typeof body.bounce !== "boolean") return bad("bounce is true or false");
    if (!absent(body.replace) && !(typeof body.replace === "string" && DRAFT_ID.test(body.replace))) return bad("replace is a draft id");
    const format = (body.format as "webp" | "gif" | "png" | undefined) ?? "webp";

    const row = await fileRow(d.db, ref);
    if (!row) return fail(404, "error.seventv.file_not_found");
    const type = (row.content_type ?? "").toLowerCase().split(";")[0]!.trim();
    const video = MAKE_VIDEO_TYPES.includes(type);
    if (!video && !FIT_TYPES.includes(type)) return fail(415, "error.seventv.file_type");
    if (row.bytes !== null && row.bytes > FIT_INPUT_MAX) return fail(413, "error.seventv.too_big");
    let start = 0;
    let end = VIDEO_DEFAULT_SECONDS;
    if (video) {
        start = typeof body.start === "number" ? body.start : 0;
        end = typeof body.end === "number" ? body.end : start + VIDEO_DEFAULT_SECONDS;
        const span = end - start;
        if (!(span >= VIDEO_MIN_SECONDS - 1e-9 && span <= VIDEO_MAX_SECONDS + 1e-9)) return bad("end minus start is 0.2 to 10 seconds");
    }
    if (!d.fit) return fail(503, "error.seventv.fit_failed", "the media helper is not available");

    const obj = await (row.bucket === "media" ? d.media : d.originals).get(row.r2_key).catch(() => null);
    if (!obj) return fail(404, "error.seventv.file_not_found");
    if (obj.size > FIT_INPUT_MAX) {
        await obj.body.cancel().catch(() => {});
        return fail(413, "error.seventv.too_big");
    }
    const q = new URLSearchParams({ max_bytes: String(UPLOAD_MAX), type });
    if (crop) q.set("crop", [crop.x, crop.y, crop.w, crop.h].map((n) => +n.toFixed(5)).join(","));
    if (stretch) q.set("stretch", `${+stretch.w.toFixed(4)},${+stretch.h.toFixed(4)}`);
    if (typeof body.size === "number") q.set("size", String(body.size));
    if (body.format !== undefined && body.format !== null) q.set("format", format);
    if (typeof body.quality === "number") q.set("quality", String(body.quality));
    if (typeof body.fps === "number") q.set("fps", String(body.fps));
    if (video) {
        q.set("start", String(start));
        q.set("end", String(end));
    }
    if (body.bounce === true) q.set("bounce", "1");
    if (typeof body.frame === "number") q.set("frame", String(body.frame));

    let res: Response;
    try {
        res = await d.fit(obj.body, obj.size, q.toString());
    } catch {
        return fail(502, "error.seventv.fit_failed", "the resize step did not answer; try again");
    }
    if (!res.ok) return fitRefusal(res);
    const bytes = new Uint8Array(await res.arrayBuffer());
    const h = (k: string) => Number(res.headers.get(k)) || 0;
    const made = res.headers.get("x-emote-format") ?? format;
    if (made !== "webp" && made !== "gif" && made !== "png") return fail(502, "error.seventv.fit_failed");
    const now = d.now();
    const id = randomBase62(DRAFT_ID_LENGTH, d.randomBytes);
    const info: DraftInfo = {
        format: made,
        content_type: `image/${made}`,
        width: h("x-emote-width"),
        height: h("x-emote-height"),
        frames: h("x-emote-frames"),
        duration_ms: h("x-emote-duration"),
        bytes: bytes.byteLength,
        quality: h("x-emote-quality"),
        over_cap: res.headers.get("x-emote-over-cap") === "1",
        created: now,
    };
    try {
        await putDraft(d.originals, d.keyId, id, bytes, info);
    } catch (e) {
        console.error("[emote-make] R2 put failed", String(e));
        return fail(502, "error.seventv.draft_failed");
    }
    // each remake replaces the last one, once the new one is stored (a failed remake keeps the old draft usable)
    if (typeof body.replace === "string" && body.replace !== id) await deleteDraft(d.originals, d.keyId, body.replace).catch(() => {});
    const { created: _c, ...shown } = info;
    return ok201({ draft_id: id, ...shown, url: `/7tv/drafts/${id}`, expires_at: now + DRAFT_TTL_MS });
}

/** GET /7tv/drafts/:id (71.2): the file. */
export async function getDraftFile(d: Pick<MakeDeps, "originals" | "now" | "keyId">, id: string): Promise<Response> {
    const dr = d.keyId ? await readDraft(d.originals, d.keyId, id, d.now()) : null;
    if (!dr) return Response.json({ status: "error", error: { code: "error.seventv.draft_not_found" } }, { status: 404 });
    return new Response(dr.body, {
        status: 200,
        headers: { "content-type": dr.contentType, "content-length": String(dr.size), "cache-control": "private, max-age=3600" },
    });
}

/** DELETE /7tv/drafts/:id. */
export async function removeDraft(d: Pick<MakeDeps, "originals" | "keyId">, id: string): Promise<StudioReply> {
    const gone = d.keyId ? await deleteDraft(d.originals, d.keyId, id) : false;
    if (!gone) return fail(404, "error.seventv.draft_not_found");
    return { status: 200, body: { status: "success", deleted: true } };
}

/** POST /7tv/drafts/:id/save (71.2): a private library item from the draft; the draft is kept. */
export async function saveDraft(d: MakeDeps, id: string, body: Body): Promise<StudioReply> {
    let title = "emote";
    if (!absent(body.title)) {
        const t = cleanTitle(body.title);
        if (!t.ok) return fail(400, "error.seventv.bad", "title is not valid");
        title = t.title ?? "emote";
    }
    const dr = d.keyId ? await readDraft(d.originals, d.keyId, id, d.now()) : null;
    if (!dr) return fail(404, "error.seventv.draft_not_found");
    const m = dr.meta;
    const bytes = new Uint8Array(await new Response(dr.body).arrayBuffer());
    const now = d.now();
    const name = mintItemId(d.randomBytes);
    const key = `emotes/${name}.${dr.format}`;
    try {
        await d.originals.put(key, bytes, {
            httpMetadata: { contentType: dr.contentType },
            customMetadata: { keyId: d.keyId!, source: "emote", draft: id, createdAt: String(now) },
        });
    } catch (e) {
        console.error("[emote-make] R2 put failed", String(e));
        return fail(502, "error.seventv.draft_failed");
    }
    const base = title.replace(/[/\\\u0000-\u001F\u007F]/g, "").trim().slice(0, 116) || "emote";
    const itemId = await insertMediaItem(
        d.db,
        {
            kind: "private",
            source: "emote",
            bucket: "originals",
            r2_key: key,
            name: `${base}.${dr.format}`,
            content_type: dr.contentType,
            bytes: bytes.byteLength,
            width: Number(m.width) || null,
            height: Number(m.height) || null,
            duration: Number(m.duration_ms) ? Number(m.duration_ms) / 1000 : null,
            link: null,
            session_id: null,
            key_id: d.keyId,
            poster: null,
            role: null,
            made_from: null,
            made_spec: JSON.stringify({ kind: "emote", draft: id }),
            post_key: null,
            created_at: now,
        },
        d.randomBytes,
    );
    if (!itemId) {
        await d.originals.delete(key).catch(() => {});
        return fail(503, "error.api.generic");
    }
    await upsertTitle(d.db, itemId, title, d.keyId!, now).catch((e) => console.error("[emote-make] could not store the title", String(e)));
    // a single file is its own post: the item id is both
    return ok201({ item_id: itemId, file_id: itemId });
}
