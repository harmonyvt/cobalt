// The webp of one photo (APP-API-CONTRACT.md 18.14): a still photo made into an ANIMATED webp so Discord offers
// "favourite" on it (Discord only offers it on animated files):
//  - animateStill, pure: a plain still (lossy, lossless, with alpha) or a one-frame animation becomes 2 frames of the same
//    bitstream; a real animation is left alone;
//  - the helper's start body and the Durable Object's plan: one photo is allowed for a webp (and 640 wide), never for the mp4;
//  - POST /studio/<sid>/slideshow against the fake helper: a photo item of a gallery, a single saved photo, a reopened
//    library photo (its post key), replace per photo, an older helper;
//  - the real encode (ffmpeg + img2webp; skipped with a logged reason when either is absent).
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { renderSlideshowWebp } from "../helper/make.js";
import { STILL_WEBP_FRAMES, animateStill as animateStillJs, parseVideoInfo, parseWebp, validateSlideshowStart } from "../helper/lib.js";
import { parseSlideshowPlan } from "../src/studio";
import { KEY_ID, asBody, auth, json } from "./poster-world";
import { lineWorld, type LW } from "./line-world";
import { itemRows, photos, saveGallery } from "./gallery-world";

// (typed loosely: the helper is plain JS whose Buffer type is not node's under this tsconfig)
const animateStill = (b: unknown, ms: number): any => animateStillJs(b as any, ms);

// ---- animateStill -----------------------------------------------------------------------------------------------------

const chunk = (fourcc: string, payload: Buffer) => {
    const head = Buffer.alloc(8);
    head.write(fourcc, 0, "latin1");
    head.writeUInt32LE(payload.length, 4);
    return Buffer.concat([head, payload, payload.length & 1 ? Buffer.alloc(1) : Buffer.alloc(0)]);
};
const riff = (...chunks: Buffer[]) => {
    const body = Buffer.concat([Buffer.from("WEBP", "latin1"), ...chunks]);
    const h = Buffer.alloc(8);
    h.write("RIFF", 0, "latin1");
    h.writeUInt32LE(body.length, 4);
    return Buffer.concat([h, body]);
};
// a lossy bitstream header of w x h (frame tag, start code, sizes) and some bytes; odd length on purpose (padding)
const vp8 = (w: number, h: number) => {
    const b = Buffer.alloc(31, 7);
    b.set([0x10, 0x02, 0x00, 0x9d, 0x01, 0x2a], 0);
    b.writeUInt16LE(w, 6);
    b.writeUInt16LE(h, 8);
    return chunk("VP8 ", b);
};
const vp8l = (w: number, h: number, alpha: boolean) => {
    const b = Buffer.alloc(20, 5);
    b[0] = 0x2f;
    b.writeUInt32LE(((w - 1) | ((h - 1) << 14) | (alpha ? 1 << 28 : 0)) >>> 0, 1);
    return chunk("VP8L", b);
};
// the chunks of each ANMF frame, by fourcc
const frameChunks = (buf: any) => {
    const out: { fourccs: string[]; w: number; h: number; ms: number; flags: number; payload: any }[] = [];
    let pos = 12;
    while (pos + 8 <= buf.length) {
        const cc = buf.toString("latin1", pos, pos + 4);
        const size = buf.readUInt32LE(pos + 4);
        if (cc === "ANMF") {
            const d = pos + 8;
            const fourccs: string[] = [];
            for (let p = d + 16; p + 8 <= d + size; ) {
                fourccs.push(buf.toString("latin1", p, p + 4));
                const s = buf.readUInt32LE(p + 4);
                p += 8 + s + (s & 1);
            }
            out.push({ fourccs, w: 1 + buf.readUIntLE(d + 6, 3), h: 1 + buf.readUIntLE(d + 9, 3), ms: buf.readUIntLE(d + 12, 3), flags: buf[d + 15]!, payload: buf.subarray(d + 16, d + size) });
        }
        pos += 8 + size + (size & 1);
    }
    return out;
};

describe("animateStill", () => {
    it("a plain lossy still (what img2webp writes for one photo) becomes 2 frames of the same bitstream, the time shared out", () => {
        const still = riff(vp8(480, 600));
        expect(parseWebp(still)).toMatchObject({ animated: false, frames: 0 });
        const out = animateStill(still, 2000)!;
        expect(parseWebp(out)).toEqual({ width: 480, height: 600, animated: true, frames: STILL_WEBP_FRAMES, durationMs: 2000 });
        const frames = frameChunks(out);
        expect(frames).toHaveLength(2);
        for (const f of frames) {
            expect(f).toMatchObject({ fourccs: ["VP8 "], w: 480, h: 600, ms: 1000, flags: 0x02 });
            expect(f.payload.equals(vp8(480, 600))).toBe(true);
        }
        // the RIFF size is the file less its 8-byte header; VP8X says animation and no alpha; ANIM loops forever
        expect(out.readUInt32LE(4)).toBe(out.length - 8);
        expect(out.toString("latin1", 12, 16)).toBe("VP8X");
        expect(out[20]).toBe(0x02);
        expect(out.toString("latin1", 30, 34)).toBe("ANIM");
        expect(out.readUInt16LE(42)).toBe(0);
    });

    it("a lossless still keeps its alpha flag; the size comes from the VP8L header", () => {
        const out = animateStill(riff(vp8l(300, 200, true)), 3000)!;
        expect(parseWebp(out)).toMatchObject({ width: 300, height: 200, frames: 2, durationMs: 3000 });
        expect(out[20]).toBe(0x12);
    });

    it("an extended still (VP8X + ALPH + VP8) carries the ALPH chunk into every frame; ICCP/EXIF are dropped", () => {
        const x = Buffer.alloc(10);
        x[0] = 0x10 | 0x08;
        x.writeUIntLE(63, 4, 3);
        x.writeUIntLE(31, 7, 3);
        const src = riff(chunk("VP8X", x), chunk("ALPH", Buffer.alloc(9, 1)), vp8(64, 32), chunk("EXIF", Buffer.alloc(4)));
        const out = animateStill(src, 1000)!;
        expect(frameChunks(out).map((f) => f.fourccs)).toEqual([["ALPH", "VP8 "], ["ALPH", "VP8 "]]);
        expect(parseWebp(out)).toMatchObject({ width: 64, height: 32, frames: 2 });
        expect(out[20]).toBe(0x12);
    });

    it("a one-frame animation is opened up into 2 frames", () => {
        const x = Buffer.alloc(10);
        x[0] = 0x02;
        x.writeUIntLE(479, 4, 3);
        x.writeUIntLE(599, 7, 3);
        const head = Buffer.alloc(16);
        head.writeUIntLE(479, 6, 3);
        head.writeUIntLE(599, 9, 3);
        head.writeUIntLE(2000, 12, 3);
        const src = riff(chunk("VP8X", x), chunk("ANIM", Buffer.alloc(6)), chunk("ANMF", Buffer.concat([head, vp8(480, 600)])));
        expect(parseWebp(src)!.frames).toBe(1);
        const out = animateStill(src, 2000)!;
        expect(parseWebp(out)).toMatchObject({ frames: 2, durationMs: 2000, width: 480, height: 600 });
        expect(frameChunks(out).every((f) => f.fourccs.join() === "VP8 ")).toBe(true);
    });

    it("a webp that already moves comes back as it is; junk is null; a frame is never under 20 ms", () => {
        const two = animateStill(riff(vp8(10, 10)), 2000)!;
        expect(animateStill(two, 9999)).toBe(two);
        expect(animateStill(Buffer.from("not a webp at all"), 1000)).toBeNull();
        expect(animateStill(riff(chunk("EXIF", Buffer.alloc(4))), 1000)).toBeNull();
        expect(frameChunks(animateStill(riff(vp8(10, 10)), 1)!).map((f) => f.ms)).toEqual([20, 20]);
    });
});

// ---- the shapes --------------------------------------------------------------------------------------------------------

describe("one photo in the start body and the plan", () => {
    const one = { width: 640, height: 800, fade: true, sound: "none", format: "webp", slides: [{ n: 0, seconds: 2 }] };
    it("the helper takes one slide, and 640 wide only then", () => {
        expect(validateSlideshowStart(one)).toMatchObject({ width: 640, slides: [{ n: 0, seconds: 2 }] });
        expect(validateSlideshowStart({ ...one, slides: [{ n: 0, seconds: 2 }, { n: 1, seconds: 2 }] })).toBeNull();
        expect(validateSlideshowStart({ ...one, width: 480 })).not.toBeNull();
    });
    it("the Durable Object takes one item for a webp (and 640 then), never for the mp4 or a plan chained to a save", () => {
        const parse = (o: Record<string, unknown>, stored = false) => parseSlideshowPlan({ items: [3], seconds: [2], ...o }, "error.webp.invalid_params", { stored });
        expect(parse({ format: "webp", width: 640 })).toMatchObject({ ok: true, plan: { items: [3], width: 640, format: "webp" } });
        expect(parse({ format: "webp" })).toMatchObject({ ok: true, plan: { width: 480 } });
        expect(parse({})).toMatchObject({ ok: false, code: "error.webp.invalid_params" });
        expect(parse({ format: "webp", chained: true }, true)).toMatchObject({ ok: false });
        expect(parseSlideshowPlan({ items: [0, 1], seconds: [2, 2], format: "webp", width: 640 }, "x")).toMatchObject({ ok: false });
    });
});

// ---- the route ---------------------------------------------------------------------------------------------------------

const still = (over: Record<string, unknown> = {}) => ({ items: [1], seconds: [2], fade: false, frame: "keep", format: "webp", quality: "high", width: 640, ...over });
const slide = (L: LW, sid: string, body: unknown) => L.studio.slideshow(KEY_ID, sid, json(body));
const madeRows = (L: LW) => L.rows("SELECT * FROM media_items WHERE role = 'slideshow' AND deleted_at IS NULL ORDER BY created_at, id");
async function make(L: LW, sid: string, body: unknown) {
    const r = await slide(L, sid, body);
    expect(r.status, JSON.stringify(r.body)).toBe(202);
    const job = asBody(r).job as string;
    return { job, done: asBody(await L.studio.renderStatus(sid, job, 0)) };
}

describe("the webp of one photo of a gallery", () => {
    it("one slide goes to the helper; the row is a 'still' webp of that photo, named animated.webp", async () => {
        const L = await lineWorld();
        const { sid } = await saveGallery(L as any, photos(3));
        const { job, done } = await make(L, sid, still());
        expect(L.helper.slideStarts).toEqual([
            { job, body: { width: 640, height: 800, fade: false, sound: "none", slides: [{ n: 0, seconds: 2 }], format: "webp", quality: "high", fps: 15 } },
        ]);
        expect(done).toMatchObject({ status: "success", format: "webp", replaced: [] });
        const row = madeRows(L)[0]!;
        expect(row).toMatchObject({ content_type: "image/webp", role: "slideshow", post_key: sid, r2_key: `originals/${sid}-s${job}.webp` });
        expect(row.name).toMatch(/-animated\.webp$/);
        expect(JSON.parse(row.made_from)).toEqual([itemRows(L as any, sid)[1].id]);
        expect(JSON.parse(row.made_spec)).toMatchObject({ format: "webp", still: true, items: [1], seconds: [2], width: 640 });
    });

    it("a video or gif alone is not a make (it is a render), and the mp4 of one item is refused", async () => {
        const L = await lineWorld();
        const { sid } = await saveGallery(L as any, [{ type: "photo" }, { type: "video", duration: 3 }]);
        const video = await slide(L, sid, still({ items: [1], seconds: [null] }));
        expect(video.status).toBe(400);
        expect(asBody(video).error.code).toBe("error.webp.invalid_params");
        const mp4 = await slide(L, sid, { items: [0], seconds: [2] });
        expect(mp4.status).toBe(400);
        expect(L.rows("SELECT * FROM studio_renders WHERE kind = 'slideshow'")).toEqual([]);
    });

    it("replace: a new still of the same photo replaces the old one; another photo's still and the slideshow webp stay", async () => {
        const L = await lineWorld();
        const { sid } = await saveGallery(L as any, photos(3));
        const first = await make(L, sid, still());
        const other = await make(L, sid, still({ items: [2] }));
        const show = await make(L, sid, { items: [0, 1, 2], seconds: [2, 2, 2], format: "webp" });
        expect(other.done.replaced).toEqual([]);
        expect(show.done.replaced).toEqual([]);
        const again = await make(L, sid, still());
        expect(again.done.replaced).toEqual([first.done.item_id]);
        expect(madeRows(L).map((r) => r.id).sort()).toEqual([other.done.item_id, show.done.item_id, again.done.item_id].sort());
        // and a new slideshow webp replaces only the slideshow webp
        const show2 = await make(L, sid, { items: [2, 1, 0], seconds: [1, 1, 1], format: "webp" });
        expect(show2.done.replaced).toEqual([show.done.item_id]);
    });

    it("a helper without still=1 ends the make error.webp.unavailable instead of writing a plain still", async () => {
        const L = await lineWorld();
        L.helper.stills = false;
        const { sid } = await saveGallery(L as any, photos(2));
        const r = await slide(L, sid, still());
        const done = asBody(await L.studio.renderStatus(sid, asBody(r).job, 0));
        expect(done).toMatchObject({ status: "error", error: { code: "error.webp.unavailable" } });
        expect(L.helper.slideStarts).toEqual([]);
    });
});

const PHOTO = { contentType: "image/jpeg", ext: "jpg", duration: null, width: 1080, height: 1350, title: "cat", service: "x", picker_count: null };

describe("the webp of a single saved photo (no item rows)", () => {
    it("its one photo is item 0: the webp joins the photo's post", async () => {
        const L = await lineWorld();
        L.helper.fetchDone = PHOTO;
        L.helper.videoBytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, ...new Array(500).fill(1)]);
        const res = await L.call("/studio", { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: json({ url: "https://x.com/a/status/1" }) });
        const sid = ((await res.json()) as any).id as string;
        expect(asBody(await L.settle(sid)).status).toBe("ready");
        const photo = L.rows("SELECT * FROM media_items WHERE session_id = ? AND deleted_at IS NULL", sid)[0]!;
        expect(photo).toMatchObject({ content_type: "image/jpeg", role: null });
        const { job } = await make(L, sid, still({ items: [0], width: 480 }));
        expect(L.helper.slideStarts[0]).toEqual({ job, body: expect.objectContaining({ width: 480, height: 600, slides: [{ n: 0, seconds: 2 }] }) });
        const row = madeRows(L)[0]!;
        expect(row).toMatchObject({ post_key: sid, session_id: sid });
        expect(JSON.parse(row.made_from)).toEqual([photo.id]);
        // item 1 does not exist; a render of the photo session is refused (its webp is this make)
        expect((await slide(L, sid, still({ items: [1] }))).status).toBe(400);
        const render = await L.render(sid, {});
        expect(render.status).toBe(409);
        expect(asBody(render).error.code).toBe("error.studio.not_video");
        // the library lists the webp in the photo's own post
        const lib = (await (await L.keyed("/library?v=3")).json()) as any;
        expect(lib.posts).toHaveLength(1);
        expect(lib.posts[0].files.map((f: any) => f.role)).toEqual(expect.arrayContaining(["slideshow"]));
    });
});

describe("the webp of a library photo whose session is over: reopened first", () => {
    it("POST /library/items/<id>/studio opens a photo session; its webp joins the original post, not the new session's", async () => {
        const L = await lineWorld();
        L.helper.fetchDone = PHOTO;
        L.helper.videoBytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, ...new Array(500).fill(1)]);
        const res = await L.call("/studio", { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: json({ url: "https://x.com/a/status/2" }) });
        const old = ((await res.json()) as any).id as string;
        await L.settle(old);
        const photo = L.rows("SELECT * FROM media_items WHERE session_id = ? AND deleted_at IS NULL", old)[0]!;
        // the old session is over
        L.db.raw.prepare("UPDATE studio_sessions SET expires_at = 1 WHERE id = ?").run(old);
        const opened = await L.keyed(`/library/items/${photo.id}/studio`, "POST");
        expect(opened.status).toBe(201);
        const sid = ((await opened.json()) as any).id as string;
        expect(sid).not.toBe(old);
        expect(asBody(await L.settle(sid)).status).toBe("ready");
        const { done } = await make(L, sid, still({ items: [0] }));
        expect(done.status).toBe("success");
        const row = madeRows(L)[0]!;
        expect(row).toMatchObject({ session_id: sid, post_key: old });
        const lib = (await (await L.keyed("/library?v=3")).json()) as any;
        expect(lib.posts).toHaveLength(1);
    });

    it("a HEIC photo is not reopened (no decoder here)", async () => {
        const L = await lineWorld();
        L.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, created_at, visibility) VALUES ('HeicRow000000001', 'private', 'upload', 'originals', 'uploads/HeicRow000000001.heic', 'a.heic', 'image/heic', 10, 1, 'private')")
            .run();
        const r = await L.keyed("/library/items/HeicRow000000001/studio", "POST");
        expect(r.status).toBe(400);
        expect(((await r.json()) as any).error.code).toBe("error.studio.not_video");
    });
});

describe("GET /capabilities: still_webp", () => {
    it("is on with a helper that said still=1, off without", async () => {
        const L = await lineWorld();
        await saveGallery(L as any, photos(2));
        expect(((await (await L.keyed("/capabilities")).json()) as any).features.still_webp).toBe(true);
        const M = await lineWorld();
        M.helper.stills = false;
        await saveGallery(M as any, photos(2));
        expect(((await (await M.keyed("/capabilities")).json()) as any).features.still_webp).toBe(false);
    });
});

// ---- the real encode ----------------------------------------------------------------------------------------------------

const has = (bin: string) => spawnSync(bin, ["-version"], { stdio: "ignore" }).status === 0 || spawnSync(bin, ["-h"], { stdio: "ignore" }).status === 0;
const real = has("ffmpeg") && has("img2webp");
if (!real) console.log("[still-webp tests] real encode skipped: ffmpeg or img2webp missing");
const tmp = mkdtempSync(path.join(tmpdir(), "still-webp-"));
afterAll(() => rmSync(tmp, { recursive: true, force: true }));

describe.skipIf(!real)("the real encode of one photo", () => {
    it("ffmpeg composes it, img2webp writes a still, and it comes out an animation of 2 frames that libwebp reads", async () => {
        const photo = path.join(tmp, "input-0");
        expect(spawnSync("ffmpeg", ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=1080x1350", "-frames:v", "1", "-f", "image2", "-c:v", "mjpeg", "-y", photo]).status).toBe(0);
        const probeAV = async (file: string) => {
            const r = spawnSync("ffmpeg", ["-hide_banner", "-i", file], { encoding: "utf8" });
            return { ...parseVideoInfo(r.stderr), hasAudio: false };
        };
        const output = path.join(tmp, "out.webp");
        const r = await renderSlideshowWebp({
            ffmpegBin: "ffmpeg",
            img2webpBin: "img2webp",
            dir: tmp,
            output,
            files: new Map([[0, photo]]),
            plan: { width: 640, height: 800, fade: false, quality: "high", slides: [{ n: 0, seconds: 2 }] },
            probeAV,
            timeoutMs: 60_000,
        });
        expect(r).toMatchObject({ width: 640, height: 800, frames: 2, duration: 2 });
        const info = parseWebp(readFileSync(output))!;
        expect(info).toMatchObject({ animated: true, frames: 2, durationMs: 2000 });
        if (has("webpinfo")) {
            const v = spawnSync("webpinfo", [output], { encoding: "utf8" });
            expect(v.stdout).toContain("No error detected");
            expect(v.stdout).toContain("Animation: 1");
        }
        expect(r.posterBytes).toBeGreaterThan(0);
    });
});
