// The editor's keyed routes (APP-API-CONTRACT.md section 31.12): shapes, codes, conflict, the idempotent render, cancel in
// each state, the capability, GET /queue and the cron's recovery. The Worker with real SQL on node:sqlite over every migration.
import { beforeEach, describe, expect, it } from "vitest";
import { editsRecover, editTablesPresent, renderProgress } from "../src/edits";
import { EDIT_MAX_CLIPS, EDIT_MAX_PROJECTS, EDIT_MAX_SECONDS } from "../../editor/helper/timeline.js";
import { AUTH, MEDIA_BASE, ids, mainClip, overlayClip, timeline, world, type World } from "./edits-world";

let w: World;
beforeEach(async () => {
    w = world();
    await w.addKey();
    w.seedLibrary();
    w.clock.t += 1000;
});

const create = async (tl: unknown = timeline(), extra: Record<string, unknown> = {}) => {
    const r = await w.api("POST", "/edits", { timeline: tl, ...extra });
    expect(r.status, r.text).toBe(201);
    return r.json.project as any;
};
const rowsOf = (sql: string, ...p: any[]) => w.db.raw.prepare(sql).all(...p) as any[];
const err = (r: { json: any }) => r.json?.error?.code;

describe("authentication and the off switch", () => {
    it("every route needs a key, answers no-store and carries no CORS header", async () => {
        const p = await create();
        for (const [m, url] of [
            ["GET", "/edits"],
            ["GET", `/edits/${p.id}`],
            ["GET", "/edits/renders"],
        ] as const) {
            const noKey = await w.api(m, url, undefined, {});
            expect(noKey.status, url).toBe(401);
            const ok = await w.api(m, url, undefined, { ...AUTH, origin: "https://cobalt.capybaraharmony.com" });
            expect(ok.status).toBe(200);
            expect(ok.res.headers.get("cache-control")).toBe("no-store");
            expect(ok.res.headers.get("access-control-allow-origin")).toBeNull();
        }
        const revoked = await w.api("GET", "/edits", undefined, { authorization: "Api-Key 11111111-2222-4333-8444-555555555555" });
        expect(revoked.status).toBe(401);
    });

    it("the library service credential gets a 404", async () => {
        const r = await w.call("/edits", { headers: { "x-cobalt-service": "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e" } });
        expect(r.status).toBe(404);
    });

    it("without the EDIT_RENDERER binding every route is 404 error.edit.off", async () => {
        const off = world({ binding: false });
        await off.addKey();
        for (const [m, url, body] of [
            ["GET", "/edits"],
            ["POST", "/edits", { timeline: timeline() }],
            ["GET", "/edits/Ab3dEf6hIj9kLm2n"],
            ["GET", "/edits/renders"],
            ["DELETE", "/edits/renders/Rq7sTu0vWx3yZa6bCd9e"],
        ] as const) {
            const r = await off.api(m, url, body);
            expect(r.status, `${m} ${url}`).toBe(404);
            expect(err(r)).toBe("error.edit.off");
        }
    });

    it("without migration 0021 every route is 503 error.api.generic", async () => {
        const old = world({ migrate: false });
        await old.addKey();
        for (const [m, url, body] of [
            ["GET", "/edits"],
            ["POST", "/edits", { timeline: timeline() }],
            ["GET", "/edits/Ab3dEf6hIj9kLm2n"],
            ["GET", "/edits/renders"],
            ["POST", "/edits/Ab3dEf6hIj9kLm2n/render", { revision: 1 }],
        ] as const) {
            const r = await old.api(m, url, body);
            expect(r.status, `${m} ${url}`).toBe(503);
            expect(err(r)).toBe("error.api.generic");
        }
    });

    it("a D1 outage is 503 error.api.generic", async () => {
        w.db.breakIt();
        const r = await w.api("GET", "/edits");
        expect(r.status).toBe(503);
    });
});

describe("POST /edits", () => {
    it("creates revision 1: the project shape, canonical timeline, default title, cover, nothing rendered", async () => {
        w.addItem({ id: "CoverVideo0000AA", poster: `${MEDIA_BASE}CoverXXXXX.jpg` });
        const tl = timeline({ main: [mainClip("CoverVideo0000AA", { id: "cA1b2C3d4", in: 2, out: 9.5, speed: 1.5 })] });
        const r = await w.api("POST", "/edits", { timeline: tl });
        expect(r.status).toBe(201);
        expect(r.json.status).toBe("success");
        const p = r.json.project;
        expect(p).toMatchObject({
            title: "untitled edit",
            revision: 1,
            canvas: { w: 1080, h: 1920, fps: 30 },
            duration: 5, // 7.5 s / 1.5
            clip_count: 1,
            cover_url: `${MEDIA_BASE}CoverXXXXX.jpg`,
            render: null,
            created_at: w.clock.t,
            updated_at: w.clock.t,
        });
        expect(p.id).toMatch(/^[A-Za-z0-9]{16}$/);
        expect(p.timeline.main[0]).toMatchObject({ item: "CoverVideo0000AA", in: 2, out: 9.5, speed: 1.5 });
        const row = rowsOf("SELECT * FROM edit_projects")[0];
        expect(row).toMatchObject({ revision: 1, canvas_w: 1080, canvas_h: 1920, fps: 30, frames: 150, clip_count: 1, cover_item: "CoverVideo0000AA", key_id: "key-row-1", updated_key: "key-row-1", deleted_at: null });
        // stored canonical: sorted keys, no whitespace
        expect(row.timeline).toBe(JSON.stringify(JSON.parse(row.timeline)));
        expect(row.timeline.startsWith('{"canvas":{"fps":30,"h":1920,"w":1080},"main":[')).toBe(true);
        expect(Object.keys(JSON.parse(row.timeline))).toEqual(["canvas", "main", "overlay", "version"]);
    });

    it("pitch (31.16): saved normalised to 0.5 st, dropped at 0, bad or out of range refused, and read back", async () => {
        const tl = timeline({ main: [mainClip(ids.a, { pitch: 3.2 })], overlay: [overlayClip(ids.b, { pitch: -0 })] });
        const p = await create(tl);
        expect(p.timeline.main[0].pitch).toBe(3);
        expect("pitch" in p.timeline.overlay[0]).toBe(false);
        const row = rowsOf("SELECT timeline FROM edit_projects")[0];
        expect(JSON.parse(row.timeline).main[0].pitch).toBe(3);
        expect(row.timeline).not.toContain('"pitch":0');
        const got = await w.api("GET", `/edits/${p.id}`);
        expect(got.json.project.timeline.main[0].pitch).toBe(3);
        const post = (t: unknown) => w.api("POST", "/edits", { timeline: t });
        const bad = await post(timeline({ main: [mainClip(ids.a, { pitch: "3" })] }));
        expect([bad.status, bad.json.path]).toEqual([400, "main[0].pitch"]);
        const range = await post(timeline({ main: [mainClip(ids.a, { pitch: 12.5 })] }));
        expect([range.status, range.json.path]).toEqual([400, "main[0].pitch"]);
    });

    it("takes a title (cleaned) and the overlay and counts clips and frames", async () => {
        const tl = timeline({ overlay: [overlayClip(ids.gif, { at: 1, out: 2 })] });
        const p = await create(tl, { title: "  Beach day  " });
        expect(p.title).toBe("Beach day");
        expect(p.clip_count).toBe(3);
        expect(p.duration).toBe(9);
        expect(rowsOf("SELECT frames FROM edit_projects")[0].frames).toBe(270);
    });

    it("a title that is not a string, has control characters, is empty or too long is bad_request at `title`", async () => {
        for (const title of [5, "a\u0007b", "", "   ", "x".repeat(81), null, {}]) {
            const r = await w.api("POST", "/edits", { timeline: timeline(), title });
            expect(r.status, JSON.stringify(title)).toBe(400);
            expect(err(r)).toBe("error.edit.bad_request");
            expect(r.json.path).toBe("title");
        }
        expect((await w.api("POST", "/edits", { timeline: timeline(), title: "x".repeat(80) })).status).toBe(201);
        expect(rowsOf("SELECT COUNT(*) AS n FROM edit_projects")[0].n).toBe(1);
    });

    it("bad bodies are bad_request: not JSON, not an object, unknown keys, no timeline, too large", async () => {
        const cases: [unknown, string | undefined][] = [
            ["not json", ""],
            ["[]", ""],
            ["null", ""],
            [{ timeline: timeline(), extra: 1 }, "extra"],
            [{ title: "x" }, "timeline"],
            [{ timeline: "nope" }, ""],
            [{ timeline: { ...timeline(), version: 2 } }, "version"],
        ];
        for (const [body, path] of cases) {
            const r = await w.api("POST", "/edits", body);
            expect(r.status, JSON.stringify(body)).toBe(400);
            expect(err(r)).toBe("error.edit.bad_request");
            if (path !== undefined) expect(r.json.path).toBe(path);
        }
        const big = await w.api("POST", "/edits", JSON.stringify({ timeline: timeline(), pad: "x".repeat(73 * 1024) }));
        expect(big.status).toBe(400);
        expect(err(big)).toBe("error.edit.bad_request");
        expect(rowsOf("SELECT COUNT(*) AS n FROM edit_projects")[0].n).toBe(0);
    });

    it("the validation answers: code, status and the path of the field", async () => {
        const post = (tl: unknown) => w.api("POST", "/edits", { timeline: tl });
        let r = await post({ ...timeline(), canvas: { w: 1000, h: 1000, fps: 30 } });
        expect([r.status, err(r)]).toEqual([400, "error.edit.canvas"]);
        r = await post({ ...timeline(), canvas: { w: 1080, h: 1920, fps: 24 } });
        expect([r.status, err(r), r.json.path]).toEqual([400, "error.edit.canvas", "canvas.fps"]);
        r = await post(timeline({ main: [] }));
        expect([r.status, err(r), r.json.path]).toEqual([400, "error.edit.empty", "main"]);
        r = await post(timeline({ main: [mainClip(ids.a, { speed: 5 })] }));
        expect([r.status, err(r), r.json.path]).toEqual([400, "error.edit.range", "main[0].speed"]);
        r = await post(timeline({ main: [mainClip(ids.a, { in: 3, out: 3 })] }));
        expect([r.status, err(r)]).toEqual([400, "error.edit.range"]);
        r = await post(timeline({ main: [mainClip(ids.a, { id: "dup" }), mainClip(ids.b, { id: "dup" })] }));
        expect([r.status, err(r)]).toEqual([400, "error.edit.bad_request"]);
        r = await post(timeline({ main: [{ ...mainClip(ids.a), extra: true }] }));
        expect([r.status, err(r), r.json.path]).toEqual([400, "error.edit.bad_request", "main[0].extra"]);
        r = await post(timeline({ main: [mainClip(ids.a, { item: "short" })] }));
        expect([r.status, err(r), r.json.path]).toEqual([400, "error.edit.bad_request", "main[0].item"]);
        r = await post(timeline({ main: Array.from({ length: EDIT_MAX_CLIPS }, (_, i) => mainClip(ids.a, { id: `m${i}` })), overlay: [overlayClip(ids.gif)] }));
        expect([r.status, err(r)]).toEqual([400, "error.edit.too_many_clips"]);
        const long = Array.from({ length: 7 }, (_, i) => mainClip(ids.a, { id: `m${i}`, in: 0, out: 100 }));
        r = await post(timeline({ main: long }));
        expect([r.status, err(r), r.json.path]).toEqual([400, "error.edit.too_long", "main"]);
        r = await post(timeline({ main: [mainClip(ids.a, { out: 2 })], overlay: [overlayClip(ids.gif, { at: 1, out: 3 })] }));
        expect([r.status, err(r)]).toEqual([400, "error.edit.overlay_past_end"]);
        r = await post(timeline({ overlay: [overlayClip(ids.gif, { id: "o1", at: 1, out: 3 }), overlay1()] }));
        expect([r.status, err(r)]).toEqual([400, "error.edit.overlay_overlap"]);
        expect(rowsOf("SELECT COUNT(*) AS n FROM edit_projects")[0].n).toBe(0);
        function overlay1() {
            return overlayClip(ids.photo, { id: "o2", at: 2, out: 1 });
        }
    });

    it("an overlay that runs off the bottom of the canvas is a range error once the library row knows the picture's size", async () => {
        // a 3024x4032 photo at w 0.35 on a 9:16 canvas: h = 0.35 x 1080/1920 x 4032/3024 = 0.2625 -> y 0.8 is too low
        const tl = timeline({ overlay: [overlayClip(ids.photo, { frame: { x: 0.6, y: 0.8, w: 0.35 } })] });
        const r = await w.api("POST", "/edits", { timeline: tl });
        expect([r.status, err(r)]).toEqual([400, "error.edit.range"]);
        expect(r.json.path).toBe("overlay[0].frame");
        const fits = timeline({ overlay: [overlayClip(ids.photo, { frame: { x: 0.6, y: 0.7, w: 0.35 } })] });
        expect((await w.api("POST", "/edits", { timeline: fits })).status).toBe(201);
    });

    it("saving does not need the sources to exist: a deleted or unknown clip is saved (the app shows it missing)", async () => {
        const tl = timeline({ main: [mainClip("UnknownItem00000"), mainClip(ids.a)] });
        const r = await w.api("POST", "/edits", { timeline: tl });
        expect(r.status).toBe(201);
    });

    it("a 201st project is 409 too_many", async () => {
        const stmt = w.db.raw.prepare(
            "INSERT INTO edit_projects (id, title, timeline, revision, canvas_w, canvas_h, fps, frames, clip_count, created_at, updated_at) VALUES (?, 't', '{}', 1, 1080, 1920, 30, 30, 1, 1, ?)",
        );
        for (let i = 0; i < EDIT_MAX_PROJECTS; i++) stmt.run(`Proj${String(i).padStart(12, "0")}`, i + 1);
        const r = await w.api("POST", "/edits", { timeline: timeline() });
        expect([r.status, err(r)]).toEqual([409, "error.edit.too_many"]);
        // a deleted one frees a place
        w.db.raw.prepare("UPDATE edit_projects SET deleted_at = 5 WHERE id = ?").run("Proj000000000000");
        expect((await w.api("POST", "/edits", { timeline: timeline() })).status).toBe(201);
    });
});

describe("GET /edits and GET /edits/<id>", () => {
    it("lists live projects, most recently updated first, as summaries (no timeline) with the newest render", async () => {
        const a = await create(timeline(), { title: "first" });
        w.clock.t += 1000;
        const b = await create(timeline(), { title: "second" });
        w.clock.t += 1000;
        await w.api("PATCH", `/edits/${a.id}`, { title: "first, renamed" });
        const d = await create(timeline(), { title: "gone" });
        await w.api("DELETE", `/edits/${d.id}`);
        const r = await w.api("GET", "/edits");
        expect(r.status).toBe(200);
        expect(r.json.status).toBe("success");
        expect(r.json.projects.map((p: any) => p.title)).toEqual(["first, renamed", "second"]);
        for (const p of r.json.projects) {
            expect(p.timeline).toBeUndefined();
            expect(Object.keys(p).sort()).toEqual(["canvas", "clip_count", "cover_url", "created_at", "duration", "id", "render", "revision", "title", "updated_at"]);
        }
        expect(r.json.projects[1].id).toBe(b.id);
        expect(r.json.projects[0].cover_url).toBe(`${MEDIA_BASE}CoverAAAAA.jpg`);
        // newest render per project
        const q = await w.api("POST", `/edits/${b.id}/render`, { revision: 1 });
        const list = await w.api("GET", "/edits");
        expect(list.json.projects.find((p: any) => p.id === b.id).render.id).toBe(q.json.render.id);
        expect(list.json.projects.find((p: any) => p.id === a.id).render).toBeNull();
    });

    it("an empty library of edits is an empty list", async () => {
        const r = await w.api("GET", "/edits");
        expect(r.json).toEqual({ status: "success", projects: [] });
    });

    it("lists at most 200", async () => {
        const stmt = w.db.raw.prepare(
            "INSERT INTO edit_projects (id, title, timeline, revision, canvas_w, canvas_h, fps, frames, clip_count, created_at, updated_at) VALUES (?, 't', '{}', 1, 1080, 1920, 30, 30, 1, 1, ?)",
        );
        for (let i = 0; i < 210; i++) stmt.run(`Proj${String(i).padStart(12, "0")}`, i + 1);
        const r = await w.api("GET", "/edits");
        expect(r.json.projects).toHaveLength(200);
        expect(r.json.projects[0].id).toBe("Proj000000000209");
    });

    it("GET /edits/<id> returns the project with its timeline and a source for every item", async () => {
        w.addItem({ id: "DeletedVideo0000", deleted: true, bytes: 10 });
        const tl = timeline({
            main: [mainClip(ids.a), mainClip("DeletedVideo0000", { id: "m2" }), mainClip("UnknownItem00000", { id: "m3" })],
            overlay: [overlayClip(ids.gif), overlayClip(ids.webm, { id: "ow", at: 3, out: 1 })],
        });
        const p = await create(tl);
        const r = await w.api("GET", `/edits/${p.id}`);
        expect(r.status).toBe(200);
        expect(r.json.project.timeline).toEqual(p.timeline);
        expect(Object.keys(r.json.sources).sort()).toEqual([ids.a, "DeletedVideo0000", "UnknownItem00000", ids.gif, ids.webm].sort());
        expect(r.json.sources[ids.a]).toEqual({
            id: ids.a,
            name: `${ids.a}.mp4`,
            kind: "video",
            content_type: "video/mp4",
            width: 1080,
            height: 1920,
            duration: 12,
            bytes: 1500,
            poster_url: `${MEDIA_BASE}CoverAAAAA.jpg`,
            source: "saved",
            available: true,
        });
        expect(r.json.sources[ids.gif]).toMatchObject({ kind: "gif", available: true });
        expect(r.json.sources[ids.webm]).toMatchObject({ kind: "unsupported", available: true });
        expect(r.json.sources["DeletedVideo0000"]).toMatchObject({ kind: "video", available: false });
        expect(r.json.sources["UnknownItem00000"]).toMatchObject({ kind: "unsupported", available: false, bytes: null, name: "" });
        const photo = await create(timeline({ overlay: [overlayClip(ids.photo)] }));
        expect((await w.api("GET", `/edits/${photo.id}`)).json.sources[ids.photo].kind).toBe("photo");
    });

    it("an unknown, deleted or malformed id is 404 error.edit.not_found (or a gate 404)", async () => {
        const unknown = await w.api("GET", "/edits/Ab3dEf6hIj9kLm2n");
        expect([unknown.status, err(unknown)]).toEqual([404, "error.edit.not_found"]);
        const p = await create();
        await w.api("DELETE", `/edits/${p.id}`);
        expect((await w.api("GET", `/edits/${p.id}`)).status).toBe(404);
        expect((await w.api("GET", "/edits/short")).status).toBe(404);
    });
});

describe("PUT /edits/<id>", () => {
    it("saves a change: revision + 1, the new timeline, the list columns, the title kept when absent", async () => {
        const p = await create(timeline(), { title: "mine" });
        w.clock.t += 5000;
        const tl = timeline({ main: [mainClip(ids.c, { out: 10 })], canvas: { w: 1920, h: 1080, fps: 60 } });
        const r = await w.api("PUT", `/edits/${p.id}`, { timeline: tl, base_revision: 1 });
        expect(r.status, r.text).toBe(200);
        expect(r.json.project).toMatchObject({ id: p.id, title: "mine", revision: 2, canvas: { w: 1920, h: 1080, fps: 60 }, duration: 10, clip_count: 1, updated_at: w.clock.t });
        expect(rowsOf("SELECT * FROM edit_projects")[0]).toMatchObject({ revision: 2, frames: 600, cover_item: ids.c, canvas_w: 1920, fps: 60 });
        const t = await w.api("PUT", `/edits/${p.id}`, { timeline: tl, base_revision: 2, title: "renamed" });
        expect(t.json.project).toMatchObject({ revision: 3, title: "renamed" });
    });

    it("a stale base_revision is 409 conflict with the current project, and nothing changes", async () => {
        const p = await create();
        await w.api("PUT", `/edits/${p.id}`, { timeline: timeline({ main: [mainClip(ids.c)] }), base_revision: 1 });
        const before = rowsOf("SELECT * FROM edit_projects")[0];
        const r = await w.api("PUT", `/edits/${p.id}`, { timeline: timeline(), base_revision: 1, title: "late" });
        expect([r.status, err(r)]).toEqual([409, "error.edit.conflict"]);
        expect(r.json.project).toMatchObject({ id: p.id, revision: 2, title: "untitled edit" });
        expect(r.json.project.timeline.main).toHaveLength(1);
        expect(rowsOf("SELECT * FROM edit_projects")[0]).toEqual(before);
        // a base_revision from the future is a conflict too
        expect(err(await w.api("PUT", `/edits/${p.id}`, { timeline: timeline(), base_revision: 9 }))).toBe("error.edit.conflict");
    });

    it("of two saves from the same revision only one wins", async () => {
        const p = await create();
        const [x, y] = await Promise.all([
            w.api("PUT", `/edits/${p.id}`, { timeline: timeline({ main: [mainClip(ids.a)] }), base_revision: 1 }),
            w.api("PUT", `/edits/${p.id}`, { timeline: timeline({ main: [mainClip(ids.b)] }), base_revision: 1 }),
        ]);
        expect([x.status, y.status].sort()).toEqual([200, 409]);
        expect(rowsOf("SELECT revision FROM edit_projects")[0].revision).toBe(2);
    });

    it("bad bodies and invalid timelines are 400 and change nothing; unknown project is 404", async () => {
        const p = await create();
        const before = rowsOf("SELECT * FROM edit_projects")[0];
        for (const body of [
            { timeline: timeline() },
            { timeline: timeline(), base_revision: 0 },
            { timeline: timeline(), base_revision: 1.5 },
            { timeline: timeline(), base_revision: "1" },
            { timeline: timeline(), base_revision: 1, extra: true },
            { timeline: timeline(), base_revision: 1, title: "" },
            { base_revision: 1 },
            { timeline: timeline({ main: [] }), base_revision: 1 },
        ]) {
            const r = await w.api("PUT", `/edits/${p.id}`, body);
            expect(r.status, JSON.stringify(body)).toBe(400);
        }
        expect(rowsOf("SELECT * FROM edit_projects")[0]).toEqual(before);
        const gone = await w.api("PUT", "/edits/Ab3dEf6hIj9kLm2n", { timeline: timeline(), base_revision: 1 });
        expect([gone.status, err(gone)]).toEqual([404, "error.edit.not_found"]);
    });
});

describe("PATCH and DELETE /edits/<id>", () => {
    it("PATCH renames without a revision check and bumps the revision", async () => {
        const p = await create();
        await w.api("PUT", `/edits/${p.id}`, { timeline: timeline(), base_revision: 1 });
        const r = await w.api("PATCH", `/edits/${p.id}`, { title: " New name " });
        expect(r.status).toBe(200);
        expect(r.json.project).toMatchObject({ title: "New name", revision: 3 });
        for (const body of [{}, { title: "" }, { title: 3 }, { title: "x", more: 1 }]) {
            expect((await w.api("PATCH", `/edits/${p.id}`, body)).status).toBe(400);
        }
        expect((await w.api("PATCH", "/edits/Ab3dEf6hIj9kLm2n", { title: "x" })).status).toBe(404);
    });

    it("DELETE is a soft delete, cancels its queued renders, lets a running one finish, and a repeat is 404", async () => {
        const p = await create();
        const queued = (await w.api("POST", `/edits/${p.id}/render`, { revision: 1 })).json.render;
        w.db.raw.prepare("UPDATE edit_renders SET status = 'rendering', instance = 'r0', attempts = 1 WHERE id = ?").run(queued.id);
        w.clock.t += 10;
        await w.api("PUT", `/edits/${p.id}`, { timeline: timeline({ main: [mainClip(ids.c)] }), base_revision: 1 });
        const second = (await w.api("POST", `/edits/${p.id}/render`, { revision: 2 })).json.render;
        const r = await w.api("DELETE", `/edits/${p.id}`);
        expect(r.status).toBe(200);
        expect(r.json).toEqual({ status: "success" });
        expect(rowsOf("SELECT deleted_at FROM edit_projects")[0].deleted_at).toBe(w.clock.t);
        const running = rowsOf("SELECT * FROM edit_renders WHERE id = ?", queued.id)[0];
        expect(running.status).toBe("rendering");
        const cancelled = rowsOf("SELECT * FROM edit_renders WHERE id = ?", second.id)[0];
        expect(cancelled).toMatchObject({ status: "cancelled", error_code: "error.edit.cancelled", cancel_requested: 1, finished_at: w.clock.t });
        const again = await w.api("DELETE", `/edits/${p.id}`);
        expect([again.status, err(again)]).toEqual([404, "error.edit.not_found"]);
        // the list no longer has it, and neither does the render's project
        expect((await w.api("GET", "/edits")).json.projects).toEqual([]);
        expect((await w.api("GET", `/edits/${p.id}`)).status).toBe(404);
        // the running render is still readable
        expect((await w.api("GET", `/edits/renders/${queued.id}`)).status).toBe(200);
    });
});

describe("POST /edits/<id>/render", () => {
  describe("accepted", () => {
    it("202 with the render, a queued row and a kick to BOTH instances", async () => {
        const p = await create(timeline(), { title: "Big edit" });
        const r = await w.api("POST", `/edits/${p.id}/render`, { revision: 1, notify: true });
        expect(r.status).toBe(202);
        expect(r.json.status).toBe("success");
        const render = r.json.render;
        expect(render).toEqual({
            id: render.id,
            kind: "edit",
            thread_id: null,
            project_id: p.id,
            revision: 1,
            title: "Big edit",
            status: "queued",
            queue_ahead: 0,
            progress: null,
            seconds_done: null,
            seconds_total: 9,
            error: null,
            item_id: null,
            poster_url: null,
            bytes: null,
            width: null,
            height: null,
            duration: null,
            cancel_requested: false,
            created_at: w.clock.t,
            started_at: null,
            finished_at: null,
        });
        expect(render.id).toMatch(/^[A-Za-z0-9]{20}$/);
        const row = rowsOf("SELECT * FROM edit_renders")[0];
        expect(row).toMatchObject({ project_id: p.id, revision: 1, title: "Big edit", status: "queued", notify: 1, key_id: "key-row-1", input_bytes: 4000, attempts: 0, instance: null });
        expect(JSON.parse(row.timeline)).toEqual(p.timeline);
        expect(w.renderers.kicks.map((k) => `${k.name}:${k.instance}:${k.method} ${k.path}`).sort()).toEqual(["r0:r0:POST /kick", "r1:r1:POST /kick"]);
        // the project now shows it
        expect((await w.api("GET", `/edits/${p.id}`)).json.project.render.id).toBe(render.id);
    });

    it("is idempotent for the same revision while it is queued, preparing, rendering or finishing: 200 with that render, one row, no new kick", async () => {
        const p = await create();
        const first = await w.api("POST", `/edits/${p.id}/render`, { revision: 1 });
        const kicks = w.renderers.kicks.length;
        for (const status of ["queued", "preparing", "rendering", "finishing"]) {
            w.db.raw.prepare("UPDATE edit_renders SET status = ? WHERE id = ?").run(status, first.json.render.id);
            const again = await w.api("POST", `/edits/${p.id}/render`, { revision: 1 });
            expect([again.status, again.json.render.id, again.json.render.status]).toEqual([200, first.json.render.id, status]);
        }
        expect(rowsOf("SELECT COUNT(*) AS n FROM edit_renders")[0].n).toBe(1);
        expect(w.renderers.kicks.length).toBe(kicks);
        // once it has ended, the same revision may be rendered again
        for (const status of ["done", "error", "cancelled"]) {
            w.db.raw.prepare("UPDATE edit_renders SET status = ? WHERE project_id = ?").run(status, p.id);
            const again = await w.api("POST", `/edits/${p.id}/render`, { revision: 1 });
            expect(again.status, status).toBe(202);
            expect(again.json.render.id).not.toBe(first.json.render.id);
            w.db.raw.prepare("UPDATE edit_renders SET status = 'done' WHERE id = ?").run(again.json.render.id);
        }
    });

    it("a kick that fails or hangs does not fail the render (the cron kicks again)", async () => {
        const p = await create();
        w.renderers.down.add("r0");
        w.renderers.hang.add("r1");
        const t0 = Date.now();
        const r = await w.api("POST", `/edits/${p.id}/render`, { revision: 1 });
        expect(r.status).toBe(202);
        expect(Date.now() - t0).toBeLessThan(5000);
        expect(rowsOf("SELECT status FROM edit_renders")[0].status).toBe("queued");
    });

    it("queue_ahead counts the queued renders created before it", async () => {
        const a = await create(timeline(), { title: "a" });
        const b = await create(timeline(), { title: "b" });
        const ra = (await w.api("POST", `/edits/${a.id}/render`, { revision: 1 })).json.render;
        w.clock.t += 1;
        const rb = (await w.api("POST", `/edits/${b.id}/render`, { revision: 1 })).json.render;
        expect(ra.queue_ahead).toBe(0);
        expect(rb.queue_ahead).toBe(1);
        expect((await w.api("GET", `/edits/renders/${rb.id}`)).json.render.queue_ahead).toBe(1);
        w.db.raw.prepare("UPDATE edit_renders SET status = 'preparing' WHERE id = ?").run(ra.id);
        expect((await w.api("GET", `/edits/renders/${rb.id}`)).json.render.queue_ahead).toBe(0);
        expect((await w.api("GET", `/edits/renders/${ra.id}`)).json.render.queue_ahead).toBeNull();
    });
  });

  describe("refused", () => {
    it("a revision that is not the current one is 409 conflict with the project; a bad body is 400; unknown is 404", async () => {
        const p = await create();
        await w.api("PATCH", `/edits/${p.id}`, { title: "x" });
        const r = await w.api("POST", `/edits/${p.id}/render`, { revision: 1 });
        expect([r.status, err(r)]).toEqual([409, "error.edit.conflict"]);
        expect(r.json.project).toMatchObject({ id: p.id, revision: 2 });
        for (const body of [{}, { revision: 0 }, { revision: "2" }, { revision: 2, notify: "yes" }, { revision: 2, extra: 1 }, "nope"]) {
            expect((await w.api("POST", `/edits/${p.id}/render`, body)).status, JSON.stringify(body)).toBe(400);
        }
        expect((await w.api("POST", "/edits/Ab3dEf6hIj9kLm2n/render", { revision: 1 })).status).toBe(404);
        expect(rowsOf("SELECT COUNT(*) AS n FROM edit_renders")[0].n).toBe(0);
        expect(w.renderers.kicks).toHaveLength(0);
    });

    it("the full check: a deleted or unknown source is 409 source_missing with the items", async () => {
        w.addItem({ id: "GoneVideo0000000", deleted: true });
        const p = await create(timeline({ main: [mainClip(ids.a), mainClip("GoneVideo0000000", { id: "m2" })], overlay: [overlayClip("UnknownItem00000")] }));
        const r = await w.api("POST", `/edits/${p.id}/render`, { revision: 1 });
        expect([r.status, err(r)]).toEqual([409, "error.edit.source_missing"]);
        expect(r.json.items.sort()).toEqual(["GoneVideo0000000", "UnknownItem00000"]);
        expect(typeof r.json.path).toBe("string");
        expect(rowsOf("SELECT COUNT(*) AS n FROM edit_renders")[0].n).toBe(0);
    });

    it("not_video (a photo on the main track), unsupported_source (webm), past_source_end", async () => {
        const render = async (tl: unknown) => {
            const p = await create(tl);
            return w.api("POST", `/edits/${p.id}/render`, { revision: 1 });
        };
        let r = await render(timeline({ main: [mainClip(ids.photo)] }));
        expect([r.status, err(r), r.json.items]).toEqual([409, "error.edit.not_video", [ids.photo]]);
        r = await render(timeline({ main: [mainClip(ids.a)], overlay: [overlayClip(ids.webm)] }));
        expect([r.status, err(r), r.json.items]).toEqual([409, "error.edit.unsupported_source", [ids.webm]]);
        r = await render(timeline({ main: [mainClip(ids.b, { in: 0, out: 6.2 })] }));
        expect([r.status, err(r)]).toEqual([409, "error.edit.past_source_end"]);
        expect(r.json.path).toBe("main[0].out");
        // within the 0.05 s slack it is accepted
        expect((await render(timeline({ main: [mainClip(ids.b, { in: 0, out: 6.04 })] }))).status).toBe(202);
    });

    it("inputs over 6 GiB together are 413 too_large", async () => {
        w.addItem({ id: "HugeVideo0000000", bytes: 4 * 1024 ** 3, object: false });
        w.addItem({ id: "HugeVideo0000001", bytes: 3 * 1024 ** 3, object: false });
        const p = await create(timeline({ main: [mainClip("HugeVideo0000000"), mainClip("HugeVideo0000001", { id: "m2" })] }));
        const r = await w.api("POST", `/edits/${p.id}/render`, { revision: 1 });
        expect([r.status, err(r)]).toEqual([413, "error.edit.too_large"]);
        // one item used twice counts once
        const once = await create(timeline({ main: [mainClip("HugeVideo0000000"), mainClip("HugeVideo0000000", { id: "m2" })] }));
        expect((await w.api("POST", `/edits/${once.id}/render`, { revision: 1 })).status).toBe(202);
    });

    it("20 renders queued or running is 429 queue_full", async () => {
        const p = await create();
        const ins = w.db.raw.prepare(
            "INSERT INTO edit_renders (id, project_id, revision, title, timeline, status, seconds_total, created_at, updated_at) VALUES (?, 'Other', 1, 't', '{}', ?, 9, ?, ?)",
        );
        for (let i = 0; i < 19; i++) ins.run(`Q${String(i).padStart(19, "0")}`, ["queued", "preparing", "rendering", "finishing"][i % 4], i + 1, i + 1);
        ins.run("D".repeat(20), "done", 1, 1);
        ins.run("E".repeat(20), "error", 1, 1);
        expect((await w.api("POST", `/edits/${p.id}/render`, { revision: 1 })).status).toBe(202);
        w.db.raw.prepare("UPDATE edit_projects SET revision = revision + 1").run();
        const full = await w.api("POST", `/edits/${p.id}/render`, { revision: 2 });
        expect([full.status, err(full)]).toEqual([429, "error.edit.queue_full"]);
    });
  });
});

describe("GET /edits/renders", () => {
    it("lists newest first, default 20, limit 1..50, the shape of a render", async () => {
        const p = await create();
        const ins = w.db.raw.prepare(
            "INSERT INTO edit_renders (id, project_id, revision, title, timeline, status, seconds_total, created_at, updated_at) VALUES (?, ?, 1, 't', '{}', 'done', 9, ?, ?)",
        );
        for (let i = 0; i < 30; i++) ins.run(`R${String(i).padStart(19, "0")}`, p.id, 100 + i, 100 + i);
        const r = await w.api("GET", "/edits/renders");
        expect(r.status).toBe(200);
        expect(r.json.renders).toHaveLength(20);
        expect(r.json.renders[0].id).toBe("R0000000000000000029");
        expect(r.json.renders[19].id).toBe("R0000000000000000010");
        expect((await w.api("GET", "/edits/renders?limit=3")).json.renders.map((x: any) => x.id)).toEqual(["R0000000000000000029", "R0000000000000000028", "R0000000000000000027"]);
        expect((await w.api("GET", "/edits/renders?limit=50")).json.renders).toHaveLength(30);
        for (const bad of ["0", "51", "x", "-1", "1.5", ""]) {
            const b = await w.api("GET", `/edits/renders?limit=${bad}`);
            expect(b.status, bad).toBe(400);
        }
    });

    it("GET /edits/renders/<rid>: 200 and the render, or 404 error.edit.not_found", async () => {
        const p = await create();
        const q = (await w.api("POST", `/edits/${p.id}/render`, { revision: 1 })).json.render;
        const r = await w.api("GET", `/edits/renders/${q.id}`);
        expect(r.json).toEqual({ status: "success", render: q });
        const none = await w.api("GET", "/edits/renders/Rq7sTu0vWx3yZa6bCd9e");
        expect([none.status, err(none)]).toEqual([404, "error.edit.not_found"]);
    });

    it("progress: preparing = 0.1 x sent / input; rendering = 0.1 + 0.85 x done / total; finishing 0.95; done 1; else null", () => {
        const base = { sent_bytes: null, input_bytes: null, seconds_done: null, seconds_total: 10 };
        expect(renderProgress({ ...base, status: "queued" })).toBeNull();
        expect(renderProgress({ ...base, status: "error" })).toBeNull();
        expect(renderProgress({ ...base, status: "cancelled" })).toBeNull();
        expect(renderProgress({ ...base, status: "preparing" })).toBe(0);
        expect(renderProgress({ ...base, status: "preparing", sent_bytes: 50, input_bytes: 100 })).toBeCloseTo(0.05, 10);
        expect(renderProgress({ ...base, status: "preparing", sent_bytes: 100, input_bytes: 100 })).toBeCloseTo(0.1, 10);
        expect(renderProgress({ ...base, status: "preparing", sent_bytes: 500, input_bytes: 100 })).toBeCloseTo(0.1, 10);
        expect(renderProgress({ ...base, status: "rendering" })).toBeCloseTo(0.1, 10);
        expect(renderProgress({ ...base, status: "rendering", seconds_done: 5 })).toBeCloseTo(0.525, 10);
        expect(renderProgress({ ...base, status: "rendering", seconds_done: 99 })).toBeCloseTo(0.95, 10);
        expect(renderProgress({ ...base, status: "finishing" })).toBe(0.95);
        expect(renderProgress({ ...base, status: "done" })).toBe(1);
    });

    it("a finished render carries its item, bytes, size and the item's poster", async () => {
        const p = await create();
        const q = (await w.api("POST", `/edits/${p.id}/render`, { revision: 1 })).json.render;
        w.addItem({ id: "ResultItem000000", bytes: 777, poster: `${MEDIA_BASE}PosterZZZZ.jpg` });
        w.db.raw
            .prepare("UPDATE edit_renders SET status = 'done', item_id = 'ResultItem000000', bytes = 777, width = 1080, height = 1920, duration = 9, finished_at = 5, started_at = 3 WHERE id = ?")
            .run(q.id);
        const r = (await w.api("GET", `/edits/renders/${q.id}`)).json.render;
        expect(r).toMatchObject({ status: "done", progress: 1, item_id: "ResultItem000000", poster_url: `${MEDIA_BASE}PosterZZZZ.jpg`, bytes: 777, width: 1080, height: 1920, duration: 9, started_at: 3, finished_at: 5, queue_ahead: null });
    });
});

describe("DELETE /edits/renders/<rid>: cancel in each state", () => {
    const make = async (status: string) => {
        const p = await create();
        const q = (await w.api("POST", `/edits/${p.id}/render`, { revision: 1 })).json.render;
        if (status !== "queued") w.db.raw.prepare("UPDATE edit_renders SET status = ?, instance = 'r0', attempts = 1 WHERE id = ?").run(status, q.id);
        return q.id as string;
    };

    it("queued ends at once: cancelled, error.edit.cancelled, finished_at", async () => {
        const id = await make("queued");
        w.clock.t += 50;
        const r = await w.api("DELETE", `/edits/renders/${id}`);
        expect(r.status).toBe(200);
        expect(r.json.render).toMatchObject({ id, status: "cancelled", error: "error.edit.cancelled", cancel_requested: true, finished_at: w.clock.t, progress: null, queue_ahead: null });
        expect(rowsOf("SELECT status FROM edit_renders")[0].status).toBe("cancelled");
        // a cancelled one is never claimed
        const claim = w.db.raw.prepare("SELECT id FROM edit_renders WHERE status = 'queued' AND cancel_requested = 0").all();
        expect(claim).toEqual([]);
    });

    it("preparing, rendering and finishing set cancel_requested; the status stays until the renderer stops it", async () => {
        for (const status of ["preparing", "rendering", "finishing"]) {
            const id = await make(status);
            const r = await w.api("DELETE", `/edits/renders/${id}`);
            expect(r.status, status).toBe(200);
            expect(r.json.render).toMatchObject({ id, status, cancel_requested: true, finished_at: null });
            expect(rowsOf("SELECT status, cancel_requested FROM edit_renders WHERE id = ?", id)[0]).toEqual({ status, cancel_requested: 1 });
            // asking again is the same answer
            expect((await w.api("DELETE", `/edits/renders/${id}`)).json.render).toMatchObject({ status, cancel_requested: true });
            w.db.raw.prepare("UPDATE edit_renders SET status = 'done' WHERE id = ?").run(id);
        }
    });

    it("already cancelled answers the same 200; done and error are 409 finished; unknown is 404", async () => {
        const id = await make("queued");
        const first = await w.api("DELETE", `/edits/renders/${id}`);
        const again = await w.api("DELETE", `/edits/renders/${id}`);
        expect([again.status, again.json.render.status]).toEqual([200, "cancelled"]);
        expect(again.json.render).toEqual(first.json.render);
        for (const status of ["done", "error"]) {
            const rid = await make(status);
            const r = await w.api("DELETE", `/edits/renders/${rid}`);
            expect([r.status, err(r)], status).toEqual([409, "error.edit.finished"]);
            expect(rowsOf("SELECT cancel_requested FROM edit_renders WHERE id = ?", rid)[0].cancel_requested).toBe(0);
        }
        const none = await w.api("DELETE", "/edits/renders/Rq7sTu0vWx3yZa6bCd9e");
        expect([none.status, err(none)]).toEqual([404, "error.edit.not_found"]);
    });
});

describe("GET /capabilities", () => {
    it("features.editor and the limits: on with the binding and the tables", async () => {
        const r = await w.api("GET", "/capabilities");
        expect(r.json.features.editor).toBe(true);
        expect(r.json.limits).toMatchObject({ edit_max_seconds: 600, edit_max_clips: 50, edit_max_projects: 200 });
        expect(r.json.limits.edit_pitch).toBe(true);
        expect([EDIT_MAX_SECONDS, EDIT_MAX_CLIPS, EDIT_MAX_PROJECTS]).toEqual([600, 50, 200]);
    });

    it("false without the binding, and false (still 200) without migration 0021", async () => {
        const noBinding = world({ binding: false });
        expect((await noBinding.api("GET", "/capabilities")).json.features.editor).toBe(false);
        const noTables = world({ migrate: false });
        const r = await noTables.api("GET", "/capabilities");
        expect(r.status).toBe(200);
        expect(r.json.features.editor).toBe(false);
        // and nothing else about the answer changed
        expect(r.json.features.queue).toBe(true);
    });

    it("probes the tables once per database: a positive answer is kept, a negative one asked again after a minute", async () => {
        const old = world({ migrate: false });
        expect(await editTablesPresent(old.db, 1_000)).toBe(false);
        old.db.raw.exec("CREATE TABLE edit_projects (id TEXT); CREATE TABLE edit_renders (id TEXT)");
        expect(await editTablesPresent(old.db, 2_000)).toBe(false);
        expect(await editTablesPresent(old.db, 62_000)).toBe(true);
        old.db.raw.exec("DROP TABLE edit_projects");
        expect(await editTablesPresent(old.db, 63_000)).toBe(true);
    });
});

describe("editTablesPresent: only a missing table means false", () => {
    const flaky = (db: any, fail: () => boolean) =>
        new Proxy(db, {
            get(t, k) {
                if (k === "prepare")
                    return (sql: string) => {
                        if (fail()) throw new Error("D1_ERROR: Network connection lost");
                        return t.prepare(sql);
                    };
                return t[k];
            },
        });

    it("a D1 blip is not cached and does not turn the flag off once it is known", async () => {
        const w = world();
        let down = true;
        const db = flaky(w.db, () => down);
        // a blip on the first ask: false for this call, remembered nowhere
        expect(await editTablesPresent(db, 1_000)).toBe(false);
        down = false;
        expect(await editTablesPresent(db, 1_001)).toBe(true);
        // known present, then a blip: still true
        down = true;
        expect(await editTablesPresent(db, 2_000)).toBe(true);
    });
});

describe("GET /queue: edits", () => {
    const fill = (id: string, status: string, created: number, finished: number | null = null) =>
        w.db.raw
            .prepare(
                "INSERT INTO edit_renders (id, project_id, revision, title, timeline, status, seconds_total, created_at, updated_at, finished_at) VALUES (?, 'P', 1, 't', '{}', ?, 9, ?, ?, ?)",
            )
            .run(id, status, created, created, finished);

    it("lists everything queued or running, then what ended in the last 30 minutes, newest first, at most 20; nulls are not there", async () => {
        const t = w.clock.t;
        fill("A".repeat(20), "queued", t - 5000);
        fill("B".repeat(20), "rendering", t - 4000);
        fill("C".repeat(20), "done", t - 3000, t - 60_000);
        fill("D".repeat(20), "error", t - 2000, t - 29 * 60_000);
        fill("E".repeat(20), "done", t - 1000, t - 31 * 60_000);
        fill("F".repeat(20), "cancelled", t - 500, t - 10_000);
        const r = await w.api("GET", "/queue");
        expect(r.status).toBe(200);
        expect(r.json.edits.map((e: any) => e.id[0])).toEqual(["B", "A", "F", "D", "C"].map((x) => x));
        expect(r.json.edits.find((e: any) => e.id[0] === "A").queue_ahead).toBe(0);
        expect(r.json.edits.find((e: any) => e.id[0] === "B").progress).toBeCloseTo(0.1, 10);
    });

    it("at most 20, and an empty list when there is nothing", async () => {
        expect((await w.api("GET", "/queue")).json.edits).toEqual([]);
        for (let i = 0; i < 25; i++) fill(`Q${String(i).padStart(19, "0")}`, "queued", w.clock.t - 1000 + i);
        const r = await w.api("GET", "/queue");
        expect(r.json.edits).toHaveLength(20);
    });

    it("is null while the tables are missing or the read fails, and the rest of the snapshot is untouched", async () => {
        const old = world({ migrate: false });
        await old.addKey();
        const r = await old.api("GET", "/queue");
        expect(r.status).toBe(200);
        expect(r.json.edits).toBeNull();
        expect(r.json.status).toBe("success");
        expect(Object.keys(r.json)).toEqual(expect.arrayContaining(["now", "line", "search", "posters", "edits"]));
    });

    it("never wakes a container: it reads D1 and nothing else of the editor", async () => {
        await w.api("GET", "/queue");
        expect(w.renderers.kicks).toEqual([]);
    });
});

describe("the cron's recovery (31.9)", () => {
    const ins = (id: string, status: string, o: Record<string, any> = {}) =>
        w.db.raw
            .prepare(
                "INSERT INTO edit_renders (id, project_id, revision, title, timeline, status, instance, attempts, cancel_requested, sent_bytes, seconds_done, seconds_total, created_at, updated_at, started_at) VALUES (?, 'P', 1, 't', '{}', ?, ?, ?, ?, 5, 2, 9, ?, ?, ?)",
            )
            .run(id, status, o.instance ?? null, o.attempts ?? 0, o.cancel ?? 0, o.created ?? 1, o.updated ?? w.clock.t, o.started ?? null);
    const status = (id: string) => rowsOf("SELECT * FROM edit_renders WHERE id = ?", id)[0];
    const deps = () => ({ db: w.db, now: w.clock.now, kick: async () => void (await w.renderers.get("r0").fetch(new Request("https://edit.internal/kick", { method: "POST" }))) });

    it("re-queues a claimed render nobody has written to for 10 minutes (attempts < 2) and kicks", async () => {
        const stale = w.clock.t - 11 * 60_000;
        for (const s of ["preparing", "rendering", "finishing"]) ins(`S${s}`.padEnd(20, "0"), s, { instance: "r0", attempts: 1, updated: stale, started: stale });
        const r = await editsRecover(deps());
        expect(r).toEqual({ requeued: 3, lost: 0, cancelled: 0, queued: 3 });
        for (const s of ["preparing", "rendering", "finishing"]) {
            expect(status(`S${s}`.padEnd(20, "0"))).toMatchObject({ status: "queued", instance: null, started_at: null, sent_bytes: null, seconds_done: null, attempts: 1, updated_at: w.clock.t });
        }
        expect(w.renderers.kicks).toHaveLength(1);
    });

    it("a second loss ends error.edit.lost (attempts >= 2); a cancel already asked ends cancelled; a fresh one is left alone", async () => {
        const stale = w.clock.t - 11 * 60_000;
        ins("LostLostLostLostLost".slice(0, 20), "rendering", { instance: "r1", attempts: 2, updated: stale });
        ins("Cancel0000000000000A", "preparing", { instance: "r0", attempts: 1, updated: stale, cancel: 1 });
        ins("Fresh00000000000000A", "rendering", { instance: "r0", attempts: 1, updated: w.clock.t - 9 * 60_000 });
        const r = await editsRecover(deps());
        expect(r).toMatchObject({ requeued: 0, lost: 1, cancelled: 1, queued: 0 });
        expect(status("LostLostLostLostLost".slice(0, 20))).toMatchObject({ status: "error", error_code: "error.edit.lost", finished_at: w.clock.t });
        expect(status("Cancel0000000000000A")).toMatchObject({ status: "cancelled", error_code: "error.edit.cancelled" });
        expect(status("Fresh00000000000000A").status).toBe("rendering");
        // nothing queued: no kick
        expect(w.renderers.kicks).toHaveLength(0);
    });

    it("kicks both instances when a render is queued and touches nothing else; D1 only when there is no work", async () => {
        ins("Queued0000000000000A", "queued", {});
        const r = await editsRecover({ db: w.db, now: w.clock.now, kick: async () => void w.renderers.kicks.push({ name: "x", instance: null, path: "", method: "" }) });
        expect(r).toEqual({ requeued: 0, lost: 0, cancelled: 0, queued: 1 });
        expect(w.renderers.kicks).toHaveLength(1);
        w.db.raw.prepare("DELETE FROM edit_renders").run();
        w.renderers.kicks.length = 0;
        expect((await editsRecover(deps())).queued).toBe(0);
        expect(w.renderers.kicks).toHaveLength(0);
    });

    it("a render cancelled while queued is not 'queued work' for the kick", async () => {
        ins("Queued0000000000000B", "queued", { cancel: 1 });
        expect((await editsRecover(deps())).queued).toBe(0);
    });
});
