// The slideshow job (APP-API-CONTRACT.md section 18.5, lane GS2): POST /studio/<sid>/slideshow, the plan's validation,
// the line (focused ahead of waiting saves), the helper's wire (18.7, a fake that speaks it exactly), the phases, the
// result row and its visibility, the failures, and the slideshow a share sheet or a Shortcut asks for with the save.
import { describe, expect, it } from "vitest";
import { KEY_ID, MEDIA_BASE, asBody, auth, json } from "./poster-world";
import { auth2, lineWorld, type LW } from "./line-world";
import { POST, itemRows, photos, saveGallery } from "./gallery-world";
import type { GalleryItemSpec } from "./studio-fakes";

// 3 photos, a video and a gif, as an Instagram carousel with a reel in it
const mixed = (): GalleryItemSpec[] => [{ type: "photo" }, { type: "photo" }, { type: "photo" }, { type: "video", duration: 4 }, { type: "gif", duration: 2 }];
const plan = (over: Record<string, unknown> = {}) => ({ items: [0, 1, 2, 3], seconds: [3, 5.6, 3, null], fade: true, frame: "keep", sound: "own", ...over });
const slide = (L: LW, sid: string, body: unknown, keyId = KEY_ID) => L.studio.slideshow(keyId, sid, typeof body === "string" ? body : json(body));
const startsOf = (L: LW) => L.helper.calls.filter((c) => c === "POST /fetch" || c === "POST /jobs/upload" || c === "POST /slideshow/start");
const tick = () => new Promise<void>((r) => setTimeout(r, 0));

async function gallery(L: LW, specs = mixed(), body: Record<string, unknown> = {}) {
    const g = await saveGallery(L as any, specs, body);
    expect(g.done.status).toBe("ready");
    return g;
}
const renderRow = (L: LW, job: string) => L.rows("SELECT * FROM studio_renders WHERE id = ?", job)[0];
const slideRows = (L: LW, sid: string) => L.rows("SELECT * FROM media_items WHERE session_id = ? AND role = 'slideshow' AND deleted_at IS NULL", sid);

describe("a slideshow on a free helper", () => {
    it("202 {status, job, queued: false, queue_ahead: null}; the inputs go in by slot, the job starts with the decided frame", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        L.helper.calls.length = 0;
        const r = await slide(L, sid, plan({ queue: true, priority: "focused" }));
        expect(r.status).toBe(202);
        expect(r.body).toEqual({ status: "pending", job: expect.stringMatching(/^[A-Za-z0-9]{20}$/), queued: false, queue_ahead: null });
        const job = asBody(r).job as string;

        // the helper's wire (18.7): one PUT per input, in plan order, then the start
        expect(L.helper.calls.filter((c) => c.includes("slideshow"))).toEqual([
            "PUT /slideshow/" + job + "/inputs/0",
            "PUT /slideshow/" + job + "/inputs/1",
            "PUT /slideshow/" + job + "/inputs/2",
            "PUT /slideshow/" + job + "/inputs/3",
            "POST /slideshow/" + job + "/start",
        ]);
        const rows = itemRows(L as any, sid);
        const sent = L.helper.slideInputs.get(job)!;
        for (let n = 0; n < 4; n++) expect(sent.get(n), `input ${n}`).toBe(L.originals.objects.get(rows[n]!.r2_key)!.bytes.length);
        expect(L.helper.slideStarts).toEqual([
            { job, body: { width: 1080, height: 1350, fade: true, sound: "own", slides: [{ n: 0, seconds: 3 }, { n: 1, seconds: 5.6 }, { n: 2, seconds: 3 }, { n: 3, seconds: null }] } },
        ]);
        // the row, the job record the sweep collects by, nothing left in the line
        expect(renderRow(L, job)).toMatchObject({ session_id: sid, status: "pending", kind: "slideshow" });
        expect(JSON.parse(renderRow(L, job).plan)).toEqual({ items: [0, 1, 2, 3], seconds: [3, 5.6, 3, null], fade: true, frame: "keep", sound: "own" });
        expect(L.keys("job:")).toEqual([`job:${job}`]);
        expect(L.entries()).toEqual([]);
    });

    it("the status follows the helper (composing, encoding), then the result is stored as a role 'slideshow' row of the post", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const job = asBody(await slide(L, sid, plan())).job as string;
        const items = itemRows(L as any, sid);

        L.helper.slidePolls = 2;
        L.helper.slidePendingFields = { phase: "composing", done: 2, total: 3 };
        expect(asBody(await L.studio.renderStatus(sid, job, 0))).toEqual({ status: "pending", job, phase: "composing", frames_done: 2, frames_total: 3, queue_ahead: null });
        L.helper.slidePendingFields = { phase: "encoding", done: 7, total: 14.8 };
        expect(asBody(await L.studio.renderStatus(sid, job, 0))).toEqual({ status: "pending", job, phase: "encoding", frames_done: 7, frames_total: 14.8, queue_ahead: null });

        const done = await L.studio.renderStatus(sid, job, 0);
        expect(done.status).toBe(200);
        const row = slideRows(L, sid)[0]!;
        expect(done.body).toEqual({ status: "success", job, item_id: row.id, bytes: 5000, width: 1080, height: 1350, seconds: 12.3, format: "mp4", replaced: [] }); // private: no url
        expect(row).toMatchObject({
            kind: "private",
            source: "studio",
            bucket: "originals",
            r2_key: `originals/${sid}-s${job}.mp4`,
            content_type: "video/mp4",
            bytes: 5000,
            width: 1080,
            height: 1350,
            duration: 12.3,
            role: "slideshow",
            post_key: sid,
            session_id: sid,
            visibility: "private",
            url: null,
        });
        expect(JSON.parse(row.made_from)).toEqual([items[0]!.id, items[1]!.id, items[2]!.id, items[3]!.id]);
        expect(JSON.parse(row.made_spec)).toMatchObject({ items: [0, 1, 2, 3], seconds: [3, 5.6, 3, null], fade: true, sound: "own" });
        expect(L.originals.objects.get(`originals/${sid}-s${job}.mp4`)).toMatchObject({ contentType: "video/mp4" });
        expect(L.originals.objects.get(`originals/${sid}-s${job}.mp4`)!.bytes).toEqual(L.helper.slideFile);
        expect(renderRow(L, job)).toMatchObject({ status: "success", bytes: 5000, out_width: 1080, out_height: 1350, seconds: 12.3 });
        // the helper's copy goes, the helper is free, a repeat poll answers the same
        expect(L.helper.slideDeletes).toEqual([job]);
        expect(L.keys("result:")).toEqual([`result:${job}`]);
        expect(asBody(await L.studio.renderStatus(sid, job, 0))).toEqual(done.body);
        expect(slideRows(L, sid)).toHaveLength(1);
        // a poster is queued for the video (the sweep makes it)
        expect(L.keys("poster:")).toContain(`poster:${row.id}`);
        // the session's own answer lists webps only: the slideshow is not one of its `renders`
        const s = asBody(await L.studio.advance(sid, 0));
        expect(s.renders).toEqual([]);
        expect(s.item_count).toBe(5);
    });

    it("a public post makes the slideshow public (its lead item's visibility), and the answer carries the link", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L, mixed(), { public: true });
        const job = asBody(await slide(L, sid, plan())).job as string;
        const done = asBody(await L.studio.renderStatus(sid, job, 0));
        const row = slideRows(L, sid)[0]!;
        expect(row).toMatchObject({ visibility: "public", url: `${MEDIA_BASE}${row.public_key}` });
        expect(row.public_key).toMatch(/^[A-Za-z0-9]{10}\.mp4$/);
        expect(L.media.objects.has(row.public_key)).toBe(true);
        expect(done).toMatchObject({ status: "success", url: row.url, item_id: row.id });
        expect(renderRow(L, job).url).toBe(row.url);
    });

    it("the sweep collects it with nobody polling (a slideshow has the helper's 10 minutes, not a render's 6)", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const job = asBody(await slide(L, sid, plan())).job as string;
        L.clock.t += 8 * 60 * 1000; // past a render's window, inside a slideshow's
        await L.studio.sweep();
        expect(renderRow(L, job).status).toBe("success");
        expect(slideRows(L, sid)).toHaveLength(1);
        // and a job nobody collected for longer than that is left alone (the owner's poll still can)
    });

    it("a repeat of the same photo is not allowed but the order is the plan's, not the post's", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const job = asBody(await slide(L, sid, plan({ items: [2, 0, 3], seconds: [4, 4, null] }))).job as string;
        expect(L.helper.slideStarts[0]!.body.slides).toEqual([{ n: 0, seconds: 4 }, { n: 1, seconds: 4 }, { n: 2, seconds: null }]);
        const rows = itemRows(L as any, sid);
        await L.studio.renderStatus(sid, job, 0);
        expect(JSON.parse(slideRows(L, sid)[0]!.made_from)).toEqual([rows[2]!.id, rows[0]!.id, rows[3]!.id]);
    });

    it("the frame: 9:16 and 1:1 are fixed; keep takes the most common size", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L, [{ type: "photo", width: 1200, height: 1200 }, { type: "photo", width: 1200, height: 1200 }, { type: "photo", width: 1080, height: 1350 }]);
        const frames: Record<string, [number, number]> = { keep: [1080, 1080], "9:16": [1080, 1920], "1:1": [1080, 1080] };
        for (const [frame, [w, h]] of Object.entries(frames)) {
            const job = asBody(await slide(L, sid, { items: [0, 1, 2], seconds: [3, 3, 3], frame })).job as string;
            const start = L.helper.slideStarts.find((s) => s.job === job)!;
            expect([start.body.width, start.body.height], frame).toEqual([w, h]);
            await L.studio.renderStatus(sid, job, 0);
        }
    });
});

describe("validation: every bad request is refused before anything is created", () => {
    const table: [string, unknown, number, string][] = [
        ["not an object", "[1,2]", 400, "error.webp.invalid_params"],
        ["not JSON", "nope", 400, "error.webp.invalid_params"],
        ["one item", plan({ items: [0], seconds: [3] }), 400, "error.webp.invalid_params"],
        ["21 items", plan({ items: Array.from({ length: 21 }, (_, i) => i), seconds: Array(21).fill(3) }), 400, "error.webp.invalid_params"],
        ["a repeated index", plan({ items: [0, 0, 1, 3], seconds: [3, 3, 3, null] }), 400, "error.webp.invalid_params"],
        ["seconds of another length", plan({ seconds: [3, 3] }), 400, "error.webp.invalid_params"],
        ["a still under 0.5 s", plan({ seconds: [0.4, 3, 3, null] }), 400, "error.webp.invalid_params"],
        ["a still over 15 s", plan({ seconds: [16, 3, 3, null] }), 400, "error.webp.invalid_params"],
        ["two decimals", plan({ seconds: [3.25, 3, 3, null] }), 400, "error.webp.invalid_params"],
        ["a null for a photo", plan({ seconds: [null, 3, 3, null] }), 400, "error.webp.invalid_params"],
        ["seconds for a video", plan({ seconds: [3, 3, 3, 5] }), 400, "error.webp.invalid_params"],
        ["an item that is not saved", plan({ items: [0, 1, 2, 9], seconds: [3, 3, 3, null] }), 400, "error.webp.invalid_params"],
        ["sound own with no video in it", plan({ items: [0, 1, 2], seconds: [3, 3, 3], sound: "own" }), 400, "error.webp.invalid_params"],
        ["a frame that is not one", plan({ frame: "4:5" }), 400, "error.webp.invalid_params"],
        ["fade not a boolean", plan({ fade: "yes" }), 400, "error.webp.invalid_params"],
        ["sound not a value", plan({ sound: "music" }), 400, "error.webp.invalid_params"],
        ["priority without queue", plan({ priority: "focused" }), 400, "error.webp.invalid_params"],
        ["priority with queue false", plan({ queue: false, priority: "focused" }), 400, "error.webp.invalid_params"],
        ["priority that is not focused", plan({ queue: true, priority: "urgent" }), 400, "error.webp.invalid_params"],
        ["queue not a boolean", plan({ queue: "yes" }), 400, "error.webp.invalid_params"],
        ["notify not a boolean", plan({ notify: "yes" }), 400, "error.webp.invalid_params"],
    ];
    for (const [name, body, status, code] of table) {
        it(name, async () => {
            const L = await lineWorld();
            const { sid } = await gallery(L);
            L.helper.calls.length = 0;
            const r = await slide(L, sid, body);
            expect(r.status).toBe(status);
            expect(asBody(r).error.code).toBe(code);
            expect(L.rows("SELECT * FROM studio_renders WHERE kind = 'slideshow'")).toEqual([]);
            expect(L.entries()).toEqual([]);
            expect(L.helper.calls).toEqual([]);
        });
    }

    it("longer than 3:00 (the stills and the video's own length added): 400 error.webp.too_long", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L, [...photos(12), { type: "video", duration: 9 }]);
        const ok = await slide(L, sid, { items: [...Array(12).keys(), 12], seconds: [...Array(12).fill(14), null] }); // 168 + 9 = 177
        expect(ok.status).toBe(202);
        await L.studio.renderStatus(sid, asBody(ok).job, 0);
        const long = await slide(L, sid, { items: [...Array(12).keys(), 12], seconds: [...Array(12).fill(14.5), null] }); // 174 + 9 = 183
        expect(long.status).toBe(400);
        expect(asBody(long).error.code).toBe("error.webp.too_long");
        const stills = await slide(L, sid, { items: [...Array(12).keys()], seconds: Array(12).fill(15.5) });
        expect(asBody(stills).error.code).toBe("error.webp.invalid_params"); // over 15 s is the shape's error before the total
    });

    it("a body over 4 KB is refused", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        expect((await slide(L, sid, json(plan({ pad: "x".repeat(4100) })))).status).toBe(400);
    });

    it("fewer than 2 live items in the post: 409 not_gallery (a single save, or a gallery cut down to one)", async () => {
        const L = await lineWorld();
        const single = asBody(await L.studio.create(KEY_ID, json({ url: "https://x.com/a/status/1" }))).id as string;
        await L.settle(single);
        const r = await slide(L, single, { items: [0, 1], seconds: [3, 3] });
        expect(r.status).toBe(409);
        expect(asBody(r).error.code).toBe("error.studio.not_gallery");
        const { sid } = await gallery(L, photos(2));
        const rows = itemRows(L as any, sid);
        L.db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE id = ?").run(rows[1]!.id);
        expect(asBody(await slide(L, sid, { items: [0, 1], seconds: [3, 3] })).error.code).toBe("error.studio.not_gallery");
    });

    it("an expired session is 410, one still saving 409, someone else's and an unknown one 404", async () => {
        const L = await lineWorld();
        await L.addKey2();
        const { sid } = await gallery(L);
        expect((await slide(L, sid, plan(), "someone-else")).status).toBe(404);
        expect((await slide(L, "X".repeat(22), plan())).status).toBe(404);
        L.db.raw.prepare("UPDATE studio_sessions SET status = 'saving' WHERE id = ?").run(sid);
        const saving = await slide(L, sid, plan());
        expect(saving.status).toBe(409);
        expect(asBody(saving).error.code).toBe("error.studio.not_ready");
        L.db.raw.prepare("UPDATE studio_sessions SET status = 'ready', expires_at = ? WHERE id = ?").run(L.clock.t - 1, sid);
        expect((await slide(L, sid, plan())).status).toBe(410);
    });

    it("the gate: keyed POST only, the creating key only, never the library service", async () => {
        const L = await lineWorld();
        await L.addKey2();
        const { sid } = await gallery(L);
        const url = `/studio/${sid}/slideshow`;
        expect((await L.call(url, { method: "POST", body: json(plan()) })).status).toBe(401);
        expect((await L.call(url, { method: "GET", headers: auth })).status).toBe(404);
        expect((await L.call(url, { method: "PUT", headers: auth, body: json(plan()) })).status).toBe(404);
        expect((await L.call(url, { method: "POST", headers: { "x-cobalt-service": "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e" }, body: json(plan()) })).status).toBe(404);
        expect((await L.call(url, { method: "POST", headers: auth2, body: json(plan()) })).status).toBe(404); // another key's session
        expect((await L.call(`/studio/${sid}/slideshow/extra`, { method: "POST", headers: auth, body: json(plan()) })).status).toBe(404);
        const ok = await L.call(url, { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: json(plan()) });
        expect(ok.status).toBe(202);
        expect(await ok.json()).toMatchObject({ status: "pending", queued: false });
    });
});

describe("the line", () => {
    // a save that keeps the helper until released
    async function busy(L: LW) {
        L.helper.fetchPolls = 1e9;
        const r = asBody(await L.studio.create(KEY_ID, json({ url: "https://x.com/run/status/1" })));
        return { sid: r.id as string, release: () => (L.helper.fetchPolls = 0) };
    }

    it("a busy helper: 429 error.webp.busy without queue; with queue the job waits (phase queued, its place) and starts when its turn comes, polled or not", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const R = await busy(L);
        const refused = await slide(L, sid, plan());
        expect(refused.status).toBe(429);
        expect(asBody(refused).error.code).toBe("error.webp.busy");
        expect(L.rows("SELECT * FROM studio_renders WHERE kind = 'slideshow'")).toEqual([]);

        const q = asBody(await slide(L, sid, plan({ queue: true })));
        expect(q).toMatchObject({ status: "pending", queued: true, queue_ahead: 1 });
        expect(L.entries()).toHaveLength(1);
        expect(L.entries()[0]).toMatchObject({ kind: "slideshow", sid, job: q.job, keyId: KEY_ID });
        expect(asBody(await L.studio.renderStatus(sid, q.job, 0))).toEqual({ status: "pending", job: q.job, phase: "queued", frames_done: null, frames_total: null, queue_ahead: 1 });
        expect(L.helper.slideStarts).toEqual([]);

        R.release();
        await L.sweeps(2);
        expect(L.helper.slideStarts.map((s) => s.job)).toEqual([q.job]);
        await L.sweeps(2);
        expect(renderRow(L, q.job).status).toBe("success");
        expect(L.entries()).toEqual([]);
    });

    it("a focused slideshow goes ahead of the saves that are waiting; an unfocused one behind them; GET /studio/line shows it as a render", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const R = await busy(L);
        const a = asBody(await L.studio.create(KEY_ID, json({ url: "https://x.com/a/status/2", queue: true })));
        const plain = asBody(await slide(L, sid, plan({ queue: true })));
        const focused = asBody(await slide(L, sid, plan({ queue: true, priority: "focused" })));
        expect(a).toMatchObject({ queued: true, queue_ahead: 1 });
        expect(plain.queue_ahead).toBe(2);
        expect(focused.queue_ahead).toBe(1); // the running save, then it: ahead of `a`
        expect(L.entries().map((e) => e.key).sort().map((k) => k.slice(0, 7))).toEqual(["line:0:", "line:1:", "line:1:"]);
        const line = (await (await L.keyed("/studio/line")).json()) as any;
        expect(line.entries.map((e: any) => [e.kind, e.priority, e.position])).toEqual([["render", "focused", 2], ["save", null, 3], ["render", null, 4]]);
        expect(JSON.stringify(line)).not.toContain("slideshow");

        R.release();
        await L.studio.sweep();
        expect(L.helper.slideStarts.map((s) => s.job)).toEqual([focused.job]); // before `a`
        expect(L.helper.fetchBodies.map((b) => b.id).slice(1)).toEqual([R.sid]); // (the first is the gallery's own save)
        await L.sweeps(6);
        expect(L.helper.fetchBodies.map((b) => b.id).slice(1)).toEqual([R.sid, a.id]);
        expect(L.helper.slideStarts.map((s) => s.job)).toEqual([focused.job, plain.job]);
        expect(L.entries()).toEqual([]);
    });

    it("while its inputs go into the helper the status says uploading; the helper counts as held (a 429 for everyone else)", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        let release!: () => void;
        L.helper.slideGate = new Promise<void>((r) => (release = r));
        const starting = slide(L, sid, plan({ queue: true }));
        await tick();
        await tick();
        const entry = L.entries()[0]!;
        expect(entry.starting).not.toBeNull();
        const st = asBody(await L.studio.renderStatus(sid, entry.job, 0));
        expect(st).toMatchObject({ status: "pending", phase: "uploading", queue_ahead: 0 });
        expect(asBody(await L.studio.create(KEY_ID, json({ url: "https://x.com/b/status/3" }))).error?.code).toBe("error.studio.busy");
        release();
        const r = await starting;
        expect(r.status).toBe(202);
        expect(asBody(r).queued).toBe(false);
    });

    it("the owner cancels a slideshow that has not started: DELETE /studio/<sid>/render/<job>", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const R = await busy(L);
        const q = asBody(await slide(L, sid, plan({ queue: true })));
        const c = await L.keyed(`/studio/${sid}/render/${q.job}`, "DELETE");
        expect(c.status).toBe(200);
        expect(await c.json()).toEqual({ status: "success", cancelled: true });
        expect(renderRow(L, q.job)).toMatchObject({ status: "error", error_code: "error.webp.cancelled" });
        expect(L.entries()).toEqual([]);
        R.release();
        await L.sweeps(2);
        expect(L.helper.slideStarts).toEqual([]);
    });
});

describe("failures", () => {
    const start = async (L: LW, body: Record<string, unknown> = {}) => {
        const { sid } = await gallery(L);
        const r = await slide(L, sid, plan(body));
        return { sid, r, job: asBody(r).job as string };
    };

    it("the helper's encode fails: the render row says so with its code, the items are untouched, the helper is freed", async () => {
        const L = await lineWorld();
        const { sid, job } = await start(L);
        L.helper.slideError = "error.webp.encode_failed";
        const r = await L.studio.renderStatus(sid, job, 0);
        expect(r).toEqual({ status: 200, body: { status: "error", error: { code: "error.webp.encode_failed" } } });
        expect(renderRow(L, job)).toMatchObject({ status: "error", error_code: "error.webp.encode_failed" });
        expect(slideRows(L, sid)).toEqual([]);
        expect(itemRows(L as any, sid)).toHaveLength(5);
        expect(L.helper.slideDeletes).toEqual([job]);
        expect(L.keys("result:")).toEqual([`result:${job}`]);
        // a repeat is the same, and the helper takes a new job
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).error.code).toBe("error.webp.encode_failed");
        expect((await slide(L, sid, plan())).status).toBe(202);
    });

    it("the helper's 10 minute timeout is error.webp.timeout", async () => {
        const L = await lineWorld();
        const { sid, job } = await start(L);
        L.helper.slideError = "error.webp.timeout";
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).error.code).toBe("error.webp.timeout");
    });

    it("the helper forgot the job (the container restarted): error.webp.job_lost", async () => {
        const L = await lineWorld();
        const { sid, job } = await start(L);
        L.helper.slideGone = true;
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).error.code).toBe("error.webp.job_lost");
        expect(renderRow(L, job).status).toBe("error");
    });

    it("an input missing in R2: error.studio.missing, nothing started, the line is clear", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        const rows = itemRows(L as any, sid);
        L.originals.objects.delete(rows[1]!.r2_key);
        const r = await slide(L, sid, plan());
        const job = asBody(r).job as string;
        expect(L.helper.slideStarts).toEqual([]);
        expect(L.helper.slideDeletes).toEqual([job]); // what was uploaded is dropped
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).error.code).toBe("error.studio.missing");
        expect(L.entries()).toEqual([]);
        expect(L.keys("job:")).toEqual([]);
    });

    it("an input over the helper's cap (413) is error.studio.too_large; a 400 is invalid_params; a refused start is its code", async () => {
        for (const [set, code] of [
            [(L: LW) => (L.helper.slideInputStatus = 413), "error.studio.too_large"],
            [(L: LW) => (L.helper.slideInputStatus = 400), "error.webp.invalid_params"],
            [(L: LW) => (L.helper.slideStartStatus = 400), "error.webp.invalid_params"],
        ] as const) {
            const L = await lineWorld();
            const { sid } = await gallery(L);
            set(L);
            const r = await slide(L, sid, plan());
            const job = asBody(r).job as string;
            expect(asBody(await L.studio.renderStatus(sid, job, 0)).error.code).toBe(code);
            expect(L.entries()).toEqual([]);
        }
    });

    it("a start the helper answers 409 (an input went missing there) is error.studio.missing", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        L.helper.slideStartStatus = 409;
        const job = asBody(await slide(L, sid, plan())).job as string;
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).error.code).toBe("error.studio.missing");
    });

    it("the helper busy with something this object does not know (a 429 on the first input): the entry stays at the head and the next pass starts it", async () => {
        const L = await lineWorld();
        const { sid } = await gallery(L);
        L.helper.slideBusy = true;
        const r = await slide(L, sid, plan({ queue: true }));
        const job = asBody(r).job as string;
        expect(L.entries()).toHaveLength(1);
        expect(L.entries()[0]!.attempts).toBe(1);
        expect(L.helper.slideDeletes).toEqual([job]); // a half-uploaded job does not keep the helper
        expect(asBody(await L.studio.renderStatus(sid, job, 0)).phase).toBe("queued");
        L.helper.slideBusy = false;
        await L.studio.sweep();
        expect(L.helper.slideStarts.map((s) => s.job)).toEqual([job]);
        await L.studio.renderStatus(sid, job, 0);
        expect(renderRow(L, job).status).toBe("success");
    });

    it("storing the result fails (R2 down): the poll answers a transient 502 and the next one stores it", async () => {
        const L = await lineWorld();
        const { sid, job } = await start(L);
        const put = L.originals.put.bind(L.originals);
        L.originals.put = async () => {
            throw new Error("R2 down");
        };
        const r = await L.studio.renderStatus(sid, job, 0);
        expect(r.status).toBe(502);
        expect(renderRow(L, job).status).toBe("pending");
        L.originals.put = put;
        expect((await L.studio.renderStatus(sid, job, 0)).status).toBe(200);
        expect(slideRows(L, sid)).toHaveLength(1);
        expect([...L.originals.objects.keys()].filter((k) => k.includes("-s"))).toEqual([`originals/${sid}-s${job}.mp4`]);
    });

    it("an unknown job, and a job of another session, are 404", async () => {
        const L = await lineWorld();
        const { sid, job } = await start(L);
        expect((await L.studio.renderStatus(sid, "Z".repeat(20), 0)).status).toBe(404);
        await L.studio.renderStatus(sid, job, 0); // collected: the helper is free for another post
        const other = (await gallery(L)).sid;
        expect((await L.studio.renderStatus(other, job, 0)).status).toBe(404);
    });
});

describe("the slideshow asked for with the save (share sheet, Shortcuts: POST /studio `slideshow`)", () => {
    const create = (L: LW, body: Record<string, unknown>) => L.studio.create(KEY_ID, json({ url: POST, items: "all", item_count: 3, ...body }));
    const planOf = (over: Record<string, unknown> = {}) => ({ items: [0, 1, 2], seconds: [3, 3, 3], fade: true, frame: "keep", sound: "none", ...over });

    it("201 carries the job to poll; when the save is ready the job joins the line and runs; the result is a slideshow row of the post", async () => {
        const L = await lineWorld();
        L.helper.gallery = photos(3);
        const r = await create(L, { slideshow: planOf() });
        expect(r.status).toBe(201);
        const job20 = expect.stringMatching(/^[A-Za-z0-9]{20}$/);
        expect(r.body).toEqual({ status: "success", id: expect.any(String), url: expect.any(String), slideshow: { job: job20 }, make: { job: job20, kind: "slideshow" } });
        const { id: sid, slideshow } = asBody(r);
        // while the save runs the job answers queued
        expect(renderRow(L, slideshow.job)).toMatchObject({ kind: "slideshow", status: "pending", session_id: sid });
        await L.settle(sid);
        // the create's own kick finished the save and started the job (a warm helper)
        expect(L.helper.slideStarts.map((s) => s.job)).toEqual([slideshow.job]);
        const done = asBody(await L.studio.renderStatus(sid, slideshow.job, 0));
        expect(done).toMatchObject({ status: "success", job: slideshow.job });
        expect(slideRows(L, sid)).toHaveLength(1);
        // the GET /studio/<sid> answer never lists it as a webp
        expect(asBody(await L.studio.advance(sid, 0)).renders).toEqual([]);
    });

    it("a poll of the job while the save is still running says queued; a save that waits in the line keeps it pending", async () => {
        const L = await lineWorld();
        L.helper.gallery = photos(3);
        L.helper.fetchPolls = 1e9;
        const r = asBody(await create(L, { slideshow: planOf() }));
        expect(asBody(await L.studio.renderStatus(r.id, r.slideshow.job, 0))).toMatchObject({ status: "pending", phase: "queued", queue_ahead: null });
        L.helper.fetchPolls = 0;
        await L.settle(r.id);
        expect(asBody(await L.studio.renderStatus(r.id, r.slideshow.job, 0))).toMatchObject({ status: "success" });
    });

    it("a save that fails takes the job with it, with the same code", async () => {
        const L = await lineWorld();
        L.helper.gallery = [{ type: "photo", fail: "error.studio.fetch_failed" }, { type: "photo", fail: "error.studio.fetch_failed" }, { type: "photo", fail: "error.studio.fetch_failed" }];
        const r = asBody(await create(L, { slideshow: planOf() }));
        await L.settle(r.id);
        expect(renderRow(L, r.slideshow.job)).toMatchObject({ status: "error", error_code: "error.studio.fetch_failed" });
        expect(asBody(await L.studio.renderStatus(r.id, r.slideshow.job, 0)).error.code).toBe("error.studio.fetch_failed");
    });

    it("an item that did not save is dropped from the plan (18.12): the slideshow is made over the saved ones", async () => {
        const L = await lineWorld();
        L.helper.gallery = [{ type: "photo" }, { type: "photo", fail: "error.studio.fetch_failed" }, { type: "photo" }];
        const r = asBody(await create(L, { slideshow: planOf() }));
        await L.settle(r.id);
        expect(asBody(await L.studio.renderStatus(r.id, r.slideshow.job, 0)).status).toBe("success");
        expect(itemRows(L as any, r.id)).toHaveLength(2);
        expect(L.helper.slideStarts[0]!.body.slides).toEqual([{ n: 0, seconds: 3 }, { n: 1, seconds: 3 }]);
        expect(JSON.parse(slideRows(L, r.id)[0]!.made_from)).toEqual(itemRows(L as any, r.id).map((x) => x.id));
    });

    it("fewer than 2 items saved: the job ends not_gallery and the save stays", async () => {
        const L = await lineWorld();
        L.helper.gallery = [{ type: "photo" }, { type: "photo", fail: "error.studio.fetch_failed" }, { type: "photo", fail: "error.studio.fetch_failed" }];
        const r = asBody(await create(L, { slideshow: planOf() }));
        await L.settle(r.id);
        expect(asBody(await L.studio.renderStatus(r.id, r.slideshow.job, 0)).error.code).toBe("error.studio.not_gallery");
        expect(itemRows(L as any, r.id)).toHaveLength(1);
        expect(L.helper.slideStarts).toEqual([]);
    });

    it("a save that turns out to be a single file cannot have a slideshow: not_gallery", async () => {
        const L = await lineWorld();
        // the helper answers a plain done body (a link that is not a post of several items)
        const r = asBody(await create(L, { slideshow: planOf({ items: [0, 1], seconds: [3, 3] }) }));
        await L.settle(r.id);
        expect(asBody(await L.studio.renderStatus(r.id, r.slideshow.job, 0)).error.code).toBe("error.studio.not_gallery");
    });

    it("validation: only with items, only over items that are saved, the plan's own shape; nothing is created", async () => {
        const L = await lineWorld();
        const bad: [string, Record<string, unknown>][] = [
            ["no items", { items: undefined, slideshow: planOf() }],
            ["an item that will not be saved", { items: [0, 1], slideshow: planOf() }],
            ["a bad plan", { slideshow: planOf({ seconds: [0, 3, 3] }) }],
            ["a plan that is not an object", { slideshow: "yes" }],
        ];
        for (const [name, body] of bad) {
            const r = await create(L, body);
            expect(r.status, name).toBe(400);
            expect(asBody(r).error.code, name).toBe("error.studio.invalid_params");
        }
        expect(L.db.raw.prepare("SELECT count(*) AS n FROM studio_sessions").get()).toEqual({ n: 0 });
        expect(L.db.raw.prepare("SELECT count(*) AS n FROM studio_renders").get()).toEqual({ n: 0 });
        // a plan whose stills alone are over 3:00 says so
        const long = await L.studio.create(KEY_ID, json({ url: POST, items: "all", slideshow: { items: Array.from({ length: 13 }, (_, i) => i), seconds: Array(13).fill(15) } }));
        expect(asBody(long).error.code).toBe("error.webp.too_long");
        expect(L.db.raw.prepare("SELECT count(*) AS n FROM studio_sessions").get()).toEqual({ n: 0 });
    });

    it("a client that sent no slideshow sees today's 201 and its save has no render row", async () => {
        const L = await lineWorld();
        L.helper.gallery = photos(3);
        const r = await create(L, {});
        expect(Object.keys(r.body as object).sort()).toEqual(["id", "status", "url"]);
        expect(L.db.raw.prepare("SELECT count(*) AS n FROM studio_renders").get()).toEqual({ n: 0 });
    });

    it("cancelling a queued save takes its slideshow with it", async () => {
        const L = await lineWorld();
        L.helper.fetchPolls = 1e9;
        const running = asBody(await L.studio.create(KEY_ID, json({ url: "https://x.com/run/status/1" })));
        L.helper.gallery = photos(3);
        const r = asBody(await create(L, { queue: true, slideshow: planOf() }));
        expect(r.queued).toBe(true);
        const c = await L.keyed(`/studio/${r.id}/line`, "DELETE");
        expect(c.status).toBe(200);
        expect(renderRow(L, r.slideshow.job)).toMatchObject({ status: "error", error_code: "error.studio.cancelled" });
        void running;
    });
});
