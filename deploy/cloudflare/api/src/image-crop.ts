// Cropping pictures (APP-API-CONTRACT.md section 44.1): part of a picture, turned and flipped, optionally with its
// background removed (section 39), saved as a NEW private PNG in the library linked to the picture it came from. One
// route, POST /library/items/<id>/crop, two bodies:
//  - JSON `{crop?, rotate?, flip?, cutout?, title?}`: the Worker makes it from the picture decoded by the IMAGES binding
//    (at most 3072 px a side; a small enough PNG is read directly);
//  - `content-type: image/png`: the app cropped it on the device at full size; the server checks and stores it.
// No Cloudflare imports here beyond types: the tests run it under node with fakes.

import {
    CUTOUT_DEFAULTS,
    cutout,
    decodePng,
    encodePng,
    isPng,
    parseHexColor,
    pngSize,
    subjectBox,
    crop as cropRgba,
    type Rgba,
} from "./cutout-core";
import {
    CUTOUT_MAX_SOURCE_BYTES,
    CUTOUT_MAX_UPLOAD_BYTES,
    CUTOUT_MAX_UPLOAD_SIDE,
    CUTOUT_SOURCE_TYPES,
    parseSpec as parseCutoutSpec,
    storeMade,
    type CutoutDeps,
} from "./cutout";
import { flip, pixelBox, rotate, type CropBox, type Flip, type Rotate } from "./image-crop-core";
import { cleanTitle } from "./studio";
import { getRow, type MediaRow } from "./visibility";

/** The server decodes pictures at most this many pixels a side (a phone screenshot stays full size). */
export const CROP_MAX_SIDE = 3072;

export type CropReply = { status: number; body: Record<string, unknown> };

const fail = (status: number, code: string, message?: string, path?: string): CropReply => ({
    status,
    body: { status: "error", error: { code }, ...(path !== undefined ? { path } : {}), ...(message ? { message } : {}) },
});

type CutoutPart = { mode: "auto" | "white" | "color"; color: string | null; tolerance: number; edges_only: boolean; soften: number; trim: boolean };
export type CropSpec = { crop: CropBox | null; rotate: Rotate; flip: Flip; cutout: CutoutPart | null; title: string | null };

const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

/** Checks a JSON body (44.1); `path` names the first bad field. */
export function parseCropSpec(b: unknown): { ok: true; spec: CropSpec } | { ok: false; path: string } {
    if (typeof b !== "object" || b === null || Array.isArray(b)) return { ok: false, path: "" };
    const o = b as Record<string, unknown>;
    for (const k of Object.keys(o)) if (!["crop", "rotate", "flip", "cutout", "title"].includes(k)) return { ok: false, path: k };
    let box: CropBox | null = null;
    if (o.crop !== undefined && o.crop !== null) {
        const c = o.crop as Record<string, unknown>;
        if (typeof c !== "object" || Array.isArray(c)) return { ok: false, path: "crop" };
        for (const k of Object.keys(c)) if (!["x", "y", "w", "h"].includes(k)) return { ok: false, path: `crop.${k}` };
        for (const k of ["x", "y"]) if (!isNum(c[k]) || (c[k] as number) < 0 || (c[k] as number) >= 1) return { ok: false, path: `crop.${k}` };
        for (const k of ["w", "h"]) if (!isNum(c[k]) || (c[k] as number) <= 0 || (c[k] as number) > 1) return { ok: false, path: `crop.${k}` };
        box = { x: c.x as number, y: c.y as number, w: c.w as number, h: c.h as number };
        if (box.x + box.w > 1.001) return { ok: false, path: "crop.w" };
        if (box.y + box.h > 1.001) return { ok: false, path: "crop.h" };
    }
    const rot = o.rotate ?? 0;
    if (rot !== 0 && rot !== 90 && rot !== 180 && rot !== 270) return { ok: false, path: "rotate" };
    const fl = o.flip ?? "none";
    if (fl !== "none" && fl !== "h" && fl !== "v") return { ok: false, path: "flip" };
    let cut: CutoutPart | null = null;
    if (o.cutout === true) cut = { mode: "auto", color: null, tolerance: CUTOUT_DEFAULTS.tolerance, edges_only: CUTOUT_DEFAULTS.edgesOnly, soften: CUTOUT_DEFAULTS.soften, trim: CUTOUT_DEFAULTS.trim };
    else if (o.cutout !== undefined && o.cutout !== false && o.cutout !== null) {
        if (typeof o.cutout !== "object" || Array.isArray(o.cutout)) return { ok: false, path: "cutout" };
        if ("title" in (o.cutout as object)) return { ok: false, path: "cutout.title" };
        const p = parseCutoutSpec(o.cutout);
        if (!p.ok) return { ok: false, path: p.path ? `cutout.${p.path}` : "cutout" };
        const { title: _t, ...rest } = p.spec;
        cut = rest;
    }
    let title: string | null = null;
    if (o.title !== undefined) {
        const t = cleanTitle(o.title);
        if (!t.ok) return { ok: false, path: "title" };
        title = t.title;
    }
    if (!box && rot === 0 && fl === "none" && !cut) return { ok: false, path: "crop" };
    return { ok: true, spec: { crop: box, rotate: rot, flip: fl, cutout: cut, title } };
}

const isImage = (ct: string | null) => CUTOUT_SOURCE_TYPES.includes(String(ct ?? "").split(";")[0]!.trim().toLowerCase());

const CROP_STORE = { prefix: "crops", word: "crop", meta: "cropOf" } as const;

/** POST /library/items/<id>/crop. Answers 201 `{status: "success", item, title, crop: {width, height}}`. */
export async function makeImageCrop(d: CutoutDeps, id: string, request: Request, keyId: string): Promise<CropReply> {
    const row = await getRow(d.db, id);
    if (!row || row.id !== id) return fail(404, "error.crop.not_found");
    if (!isImage(row.content_type)) return fail(409, "error.crop.not_image");

    const type = (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    if (type === "image/png") return storeUpload(d, row, request, keyId);

    let raw: unknown;
    try {
        const text = await request.text();
        if (text.length > 4096) return fail(400, "error.crop.bad_request");
        raw = text.trim() === "" ? {} : JSON.parse(text);
    } catch {
        return fail(400, "error.crop.bad_request");
    }
    const p = parseCropSpec(raw);
    if (!p.ok) return fail(400, "error.crop.bad_request", undefined, p.path);
    const spec = p.spec;
    if (Number(row.bytes) > CUTOUT_MAX_SOURCE_BYTES) return fail(413, "error.crop.too_large");
    if (spec.cutout?.mode === "auto" && !d.images) return fail(503, "error.crop.off", "this server has no Cloudflare Images binding");

    const bucket = row.bucket === "media" ? d.media : d.originals;
    const obj = await bucket.get(row.r2_key);
    if (!obj) return fail(404, "error.crop.not_found");

    // the picture as a PNG we can decode, at most CROP_MAX_SIDE a side
    let png: Uint8Array;
    if (d.images) {
        try {
            const out = await d.images.input(obj.body).transform({ width: CROP_MAX_SIDE, height: CROP_MAX_SIDE, fit: "scale-down" }).output({ format: "image/png" });
            png = new Uint8Array(await out.response().arrayBuffer());
        } catch (e) {
            console.error("[crop] images binding failed", String(e));
            return fail(502, "error.crop.failed");
        }
    } else {
        if (!String(row.content_type).startsWith("image/png")) {
            await obj.body.cancel().catch(() => {});
            return fail(503, "error.crop.off", "this server has no Cloudflare Images binding");
        }
        png = new Uint8Array(await new Response(obj.body).arrayBuffer());
        const size = pngSize(png);
        if (!size || size.width > CROP_MAX_SIDE || size.height > CROP_MAX_SIDE) return fail(503, "error.crop.off", "this picture is too big to crop without Cloudflare Images");
    }

    let img: Rgba;
    try {
        img = await decodePng(png, CROP_MAX_SIDE * CROP_MAX_SIDE);
    } catch {
        return fail(502, "error.crop.failed");
    }
    if (spec.crop) {
        const box = pixelBox(spec.crop, img.width, img.height);
        if (!box) return fail(400, "error.crop.bad_request", "the crop is smaller than 2 x 2 pixels", "crop");
        img = cropRgba(img, box);
    }
    img = flip(rotate(img, spec.rotate), spec.flip);

    if (spec.cutout) {
        const c = spec.cutout;
        let result: Rgba | null;
        if (c.mode === "auto") {
            let lifted: Rgba;
            try {
                const bytes = await encodePng(img);
                const out = await d.images!
                    .input(new Response(bytes).body!)
                    .transform({ segment: "foreground" })
                    .output({ format: "image/png" });
                lifted = await decodePng(new Uint8Array(await out.response().arrayBuffer()), CROP_MAX_SIDE * CROP_MAX_SIDE);
            } catch (e) {
                console.error("[crop] background removal failed", String(e));
                return fail(502, "error.crop.failed");
            }
            const box = subjectBox(lifted);
            result = box ? (c.trim ? cropRgba(lifted, box) : lifted) : null;
        } else {
            result = cutout(img, {
                mode: c.mode,
                color: c.mode === "color" ? (parseHexColor(c.color!) ?? undefined) : undefined,
                tolerance: c.tolerance,
                edgesOnly: c.edges_only,
                soften: c.soften,
                trim: c.trim,
            });
        }
        if (!result) return fail(422, "error.crop.empty", "nothing was left after removing the background");
        img = result;
    }

    const bytes = await encodePng(img);
    const madeSpec: Record<string, unknown> = {
        kind: "crop",
        from: row.id,
        crop: spec.crop,
        rotate: spec.rotate,
        flip: spec.flip,
        ...(spec.cutout
            ? {
                  cutout: {
                      mode: spec.cutout.mode,
                      ...(spec.cutout.mode === "color" ? { color: spec.cutout.color } : {}),
                      ...(spec.cutout.mode !== "auto" ? { tolerance: spec.cutout.tolerance, edges_only: spec.cutout.edges_only, soften: spec.cutout.soften } : {}),
                      trim: spec.cutout.trim,
                  },
              }
            : {}),
    };
    return reply(await storeMade(d, row, bytes, img.width, img.height, madeSpec, spec.title, keyId, CROP_STORE));
}

function reply(r: Awaited<ReturnType<typeof storeMade>>): CropReply {
    if (!r.ok) return r.reply;
    return { status: 201, body: { status: "success", item: r.item, title: r.title, crop: { width: r.width, height: r.height } } };
}

/** The app's own crop: a PNG checked and stored; what it did comes in the query and is only recorded. */
async function storeUpload(d: CutoutDeps, row: MediaRow, request: Request, keyId: string): Promise<CropReply> {
    const declared = Number(request.headers.get("content-length") ?? "NaN");
    if (Number.isFinite(declared) && declared > CUTOUT_MAX_UPLOAD_BYTES) {
        void request.body?.cancel().catch(() => {});
        return fail(413, "error.crop.too_large");
    }
    const buf = new Uint8Array(await request.arrayBuffer());
    if (buf.length > CUTOUT_MAX_UPLOAD_BYTES) return fail(413, "error.crop.too_large");
    const size = isPng(buf) ? pngSize(buf) : null;
    if (!size || size.width < 1 || size.height < 1 || size.width > CUTOUT_MAX_UPLOAD_SIDE || size.height > CUTOUT_MAX_UPLOAD_SIDE) {
        return fail(400, "error.crop.bad_request", undefined, "body");
    }
    const q = new URL(request.url).searchParams;
    let title: string | null = null;
    if (q.has("title")) {
        const t = cleanTitle(q.get("title"));
        if (!t.ok) return fail(400, "error.crop.bad_request", undefined, "title");
        title = t.title;
    }
    // what the app says it did, recorded when it makes sense, dropped otherwise
    const frac = (k: string) => {
        const v = Number(q.get(k));
        return q.has(k) && Number.isFinite(v) && v >= 0 && v <= 1 ? v : null;
    };
    const [x, y, w, h] = ["x", "y", "w", "h"].map(frac);
    const rot = Number(q.get("rotate"));
    const fl = q.get("flip");
    const cut = q.get("cutout");
    const madeSpec: Record<string, unknown> = {
        kind: "crop",
        from: row.id,
        crop: x !== null && y !== null && w !== null && h !== null ? { x, y, w, h } : null,
        rotate: [0, 90, 180, 270].includes(rot) ? rot : 0,
        flip: fl === "h" || fl === "v" ? fl : "none",
        ...(cut === "auto" || cut === "white" || cut === "color" || cut === "true" ? { cutout: { mode: cut === "true" ? "auto" : cut } } : {}),
        device: true,
    };
    return reply(await storeMade(d, row, buf, size.width, size.height, madeSpec, title, keyId, CROP_STORE));
}
