// Timeline v2 on the keyed edit routes (APP-API-CONTRACT.md section 69). Stored JSON stays the version that was
// saved. An older client is shown v1 only when that conversion loses nothing.
import { beforeEach, describe, expect, it } from "vitest";
import { canonicalJSON, parseTimeline, timelineV1ToV2 } from "../../editor/helper/timeline.js";
import { AUTH, ids, mainClip, overlayClip, timeline, world, type World } from "./edits-world";

let w: World;
beforeEach(async () => {
    w = world();
    await w.addKey();
    w.seedLibrary();
});

const err = (r: { json: any }) => r.json?.error?.code;
const rowsOf = (sql: string, ...p: any[]) => w.db.raw.prepare(sql).all(...p) as any[];
const V2 = { "x-cobalt-timeline-version": "2" };
const headers = (extra: Record<string, string> = {}) => ({ ...AUTH, "content-type": "application/json", ...extra });

const gap = () => ({
    version: 2,
    canvas: { w: 1080, h: 1920, fps: 30 },
    clips: [
        { id: "a", item: ids.a, lane: 0, at: 0, in: 0, out: 1 },
        { id: "b", item: ids.a, lane: 0, at: 3, in: 0, out: 1 },
    ],
});

describe("POST /edits version 2", () => {
    it("stores the canonical v2 document, counts every clip, and covers with the first lane-0 clip", async () => {
        const r = await w.api("POST", "/edits", { timeline: gap() });
        expect(r.status, r.text).toBe(201);
        const p = r.json.project;
        expect(p.timeline.version).toBe(2);
        expect(p.clip_count).toBe(2);
        expect(p.duration).toBe(4);
        expect(p.cover_url).toContain("CoverAAAAA");
        const row = rowsOf("SELECT timeline, frames, clip_count, cover_item FROM edit_projects")[0];
        expect(row.frames).toBe(120);
        expect(row.clip_count).toBe(2);
        expect(row.cover_item).toBe(ids.a);
        const parsed = parseTimeline(gap());
        expect(parsed.ok).toBe(true);
        if (!parsed.ok) return;
        expect(row.timeline).toBe(canonicalJSON(parsed.timeline));
        expect(row.timeline).toBe(JSON.stringify(p.timeline));
    });

    it("a picture on lane 0 is a clip, and it is the cover", async () => {
        const tl = {
            version: 2,
            canvas: { w: 1080, h: 1920, fps: 30 },
            clips: [{ id: "pic", item: ids.photo, lane: 0, at: 0, in: 0, out: 3 }],
        };
        const r = await w.api("POST", "/edits", { timeline: tl });
        expect(r.status, r.text).toBe(201);
        expect(r.json.project).toMatchObject({ clip_count: 1, duration: 3, timeline: { version: 2 } });
        expect(rowsOf("SELECT cover_item, clip_count FROM edit_projects")[0]).toEqual({ cover_item: ids.photo, clip_count: 1 });
    });

    it("with no lane 0 clip the cover is the earliest clip on the lowest lane", async () => {
        const tl = {
            version: 2,
            canvas: { w: 720, h: 720, fps: 30 },
            clips: [
                { id: "hi", item: ids.b, lane: 4, at: 0, in: 0, out: 1 },
                { id: "lo", item: ids.c, lane: 2, at: 1, in: 0, out: 1 },
                { id: "first", item: ids.a, lane: 2, at: 0, in: 0, out: 0.5 },
            ],
        };
        const r = await w.api("POST", "/edits", { timeline: tl });
        expect(r.status, r.text).toBe(201);
        expect(rowsOf("SELECT cover_item, clip_count FROM edit_projects")[0]).toEqual({ cover_item: ids.a, clip_count: 3 });
    });

    it("refuses an overlap, a 65th lane, an empty list, and a gif whose in is not 0", async () => {
        const canvas = { w: 1080, h: 1920, fps: 30 };
        const post = (clips: unknown[]) => w.api("POST", "/edits", { timeline: { version: 2, canvas, clips } });
        let r = await post([
            { id: "a", item: ids.a, lane: 2, at: 0, in: 0, out: 2 },
            { id: "b", item: ids.b, lane: 2, at: 1, in: 0, out: 1 },
        ]);
        expect([r.status, err(r), r.json.path]).toEqual([400, "error.edit.overlay_overlap", "clips[1]"]);
        r = await post([{ id: "x", item: ids.a, lane: 64, at: 0, in: 0, out: 1 }]);
        expect([r.status, err(r), r.json.path]).toEqual([400, "error.edit.range", "clips[0].lane"]);
        r = await post([]);
        expect([r.status, err(r), r.json.path]).toEqual([400, "error.edit.empty", "clips"]);
        expect(rowsOf("SELECT COUNT(*) AS n FROM edit_projects")[0].n).toBe(0);
        // A picture's `in` is checked with the library row, at render, the same way a v1 overlay is.
        const gif = await post([{ id: "g", item: ids.gif, lane: 0, at: 0, in: 1, out: 2 }]);
        expect(gif.status, gif.text).toBe(201);
        const rend = await w.api("POST", `/edits/${gif.json.project.id}/render`, { revision: 1 });
        expect([rend.status, err(rend), rend.json.path]).toEqual([400, "error.edit.range", "clips[0].in"]);
    });

    it("a v1 save stays v1, byte for byte, including after a v2 project exists", async () => {
        const v1 = timeline();
        const saved = await w.api("POST", "/edits", { timeline: v1 });
        expect(saved.status).toBe(201);
        const parsed = parseTimeline(v1);
        expect(parsed.ok).toBe(true);
        if (!parsed.ok) return;
        const stored = rowsOf("SELECT timeline FROM edit_projects WHERE id = ?", saved.json.project.id)[0].timeline as string;
        expect(stored).toBe(canonicalJSON(parsed.timeline));
        expect(JSON.parse(stored).version).toBe(1);
        await w.api("POST", "/edits", { timeline: gap() });
        const again = rowsOf("SELECT timeline FROM edit_projects WHERE id = ?", saved.json.project.id)[0].timeline as string;
        expect(again).toBe(stored);
    });
});

describe("reading a v2 project", () => {
    it("serves v2 to a client that asks, and refuses an older client when the edit cannot be v1", async () => {
        const made = await w.api("POST", "/edits", { timeline: gap() }, headers(V2));
        expect(made.status).toBe(201);
        const id = made.json.project.id as string;
        const stored = rowsOf("SELECT timeline, revision, title FROM edit_projects WHERE id = ?", id)[0];

        const old = await w.api("GET", `/edits/${id}`);
        expect([old.status, err(old)]).toEqual([409, "error.edit.needs_timeline_v2"]);
        expect(old.json.timeline).toBeUndefined();
        expect(old.json.project).toBeUndefined();
        expect(old.json.project_id).toBe(id);

        const asked = await w.api("GET", `/edits/${id}`, undefined, headers(V2));
        expect(asked.status).toBe(200);
        expect(asked.json.project.timeline.version).toBe(2);
        expect(JSON.stringify(asked.json.project.timeline)).toBe(stored.timeline);

        const query = await w.api("GET", `/edits/${id}?timeline_version=2`);
        expect(query.status).toBe(200);
        expect(query.json.project.timeline.version).toBe(2);

        const renamed = await w.api("PATCH", `/edits/${id}`, { title: "gap" });
        expect([renamed.status, err(renamed)]).toEqual([409, "error.edit.needs_timeline_v2"]);
        expect(rowsOf("SELECT title, revision FROM edit_projects WHERE id = ?", id)[0]).toEqual({ title: stored.title, revision: stored.revision });

        const renamedNew = await w.api("PATCH", `/edits/${id}`, { title: "gap" }, headers(V2));
        expect(renamedNew.status).toBe(200);
        expect(renamedNew.json.project.timeline.version).toBe(2);
        expect(renamedNew.json.project.title).toBe("gap");
    });

    it("an older client gets v1 when the conversion loses nothing, and the row stays v2", async () => {
        const v1 = timeline({
            main: [mainClip(ids.a, { id: "cA1b2C3d4", in: 0, out: 4 })],
            overlay: [overlayClip(ids.b, { id: "oVidBBBBB", at: 1, in: 0, out: 2 })],
        });
        const parsed = parseTimeline(v1);
        expect(parsed.ok).toBe(true);
        if (!parsed.ok) return;
        const asV2 = timelineV1ToV2(parsed.timeline);
        expect(asV2.ok).toBe(true);
        if (!asV2.ok) return;
        const made = await w.api("POST", "/edits", { timeline: JSON.parse(canonicalJSON(asV2.timeline)) });
        expect(made.status, made.text).toBe(201);
        const id = made.json.project.id as string;
        expect(rowsOf("SELECT timeline FROM edit_projects WHERE id = ?", id)[0].timeline).toContain('"version":2');

        const old = await w.api("GET", `/edits/${id}`);
        expect(old.status).toBe(200);
        expect(canonicalJSON(old.json.project.timeline)).toBe(canonicalJSON(parsed.timeline));
        expect(rowsOf("SELECT timeline FROM edit_projects WHERE id = ?", id)[0].timeline).toContain('"version":2');

        const put = await w.api("PUT", `/edits/${id}`, { timeline: old.json.project.timeline, base_revision: 1 });
        expect(put.status, put.text).toBe(200);
        expect(put.json.project.timeline.version).toBe(1);
        expect(rowsOf("SELECT timeline FROM edit_projects WHERE id = ?", id)[0].timeline).toBe(canonicalJSON(parsed.timeline));
    });
});
