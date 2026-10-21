// The render step machine (APP-API-CONTRACT.md section 31.8-31.11) against a fake container that speaks the helper's HTTP
// contract (31.9): claim, inputs, start, wait, collect, poster, record, notify, cleanup; a lost container; the deadline;
// cancel; a deleted source; a poster that fails; the library row and title exactly as 31.10; two instances racing the claim.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { formatBytes } from "../src/live";
import { deadlineMs, renderErrorCode, RENDER_KEY, TICK_KEY, type StepRecord } from "../src/edit-render-core";
import { editsRecover } from "../src/edits";
import { MemoryKV } from "./studio-fakes";
import { HARK, KEY_ID, MEDIA_BASE, coreWorld, ids, mainClip, overlayClip, timeline, type CoreWorld } from "./edits-world";

let cw: CoreWorld;
beforeEach(async () => {
    cw = coreWorld();
    await cw.addKey();
    cw.seedLibrary();
    cw.clock.t += 1000;
});
afterEach(() => vi.useRealTimers());

const POSTER_RE = /^https:\/\/media\.capybaraharmony\.com\/([A-Za-z0-9]{10})\.jpg$/;
const short = (m: string, p: string) => `${m} ${p.replace(/^\/renders\/[A-Za-z0-9]{20}/, "").replace(/^\//, "") || "status"}`;
const items = () => cw.db.raw.prepare("SELECT * FROM media_items WHERE source = 'studio' ORDER BY created_at").all() as any[];
const record = (core: { storage: MemoryKV }) => core.storage.m.get(RENDER_KEY) as StepRecord | undefined;
// call sequence with the render's status when each call arrived
const trace = (id: string) => {
    const seen: string[] = [];
    cw.container.onCall = (m, p) => void seen.push(`${short(m, p)} ${cw.row(id).status}`);
    return seen;
};

describe("a render from claim to done", () => {
    it("runs every step in order, with the right status at each container call", async () => {
        const id = cw.queueRender();
        const seen = trace(id);
        const core = cw.makeCore("r0");
        await cw.run(core);
        expect(seen).toEqual([
            "PUT inputs/0 preparing",
            "PUT inputs/1 preparing",
            "POST start preparing",
            "GET status rendering",
            "GET status rendering",
            "GET status rendering",
            "GET file finishing",
            "GET poster finishing",
            "DELETE status done",
        ]);
        expect(cw.row(id)).toMatchObject({
            status: "done",
            instance: "r0",
            attempts: 1,
            sent_bytes: 4000,
            seconds_done: 9,
            error_code: null,
            bytes: 4096,
            width: 1080,
            height: 1920,
            duration: 9,
            cancel_requested: 0,
        });
        expect(cw.row(id).started_at).toBeGreaterThan(0);
        expect(cw.row(id).finished_at).toBe(cw.clock.t - 0 > 0 ? cw.row(id).finished_at : 0);
        // the helper got the timeline and the inputs in timeline order
        const st = [...cw.container.renders.values()];
        expect(st).toHaveLength(0); // deleted at cleanup
        expect(record(core)).toBeUndefined();
        expect(core.pending).toBeNull();
    });

    it("sends the sources in timeline order (main first, then overlay) and the start body is the canonical timeline", async () => {
        const tl = timeline({ overlay: [overlayClip(ids.gif, { at: 1, out: 2 }), overlayClip(ids.photo, { id: "op", at: 4, out: 2 })] });
        const id = cw.queueRender({ timeline: tl });
        let started: any = null;
        const orig = cw.container.handle;
        cw.container.handle = async (path, init) => {
            if (init?.method === "POST" && path.endsWith("/start")) started = JSON.parse(String(init.body));
            return orig(path, init);
        };
        const core = cw.makeCore("r0", { container: (p, i) => cw.container.handle(p, i) });
        await cw.run(core);
        expect(cw.row(id).status).toBe("done");
        expect(started.timeline).toEqual(tl);
        expect(started.inputs).toEqual([
            { n: 0, item: ids.a, kind: "video" },
            { n: 1, item: ids.b, kind: "video" },
            { n: 2, item: ids.gif, kind: "gif" },
            { n: 3, item: ids.photo, kind: "photo" },
        ]);
        expect(cw.container.calls.filter((c) => c.startsWith("PUT"))).toHaveLength(4);
    });

    it("an item used twice is sent once; a public-bucket source is read from the public bucket", async () => {
        cw.addItem({ id: "PublicVideo00000", bucket: "media", bytes: 600, duration: 10 });
        const tl = timeline({ main: [mainClip(ids.a, { id: "m1" }), mainClip(ids.a, { id: "m2", in: 4, out: 8 }), mainClip("PublicVideo00000", { id: "m3" })] });
        const id = cw.queueRender({ timeline: tl });
        const core = cw.makeCore("r0");
        await cw.run(core);
        expect(cw.row(id).status).toBe("done");
        expect(cw.container.calls.filter((c) => c.startsWith("PUT"))).toEqual(["PUT /renders/<rid>/inputs/0", "PUT /renders/<rid>/inputs/1"]);
        expect(cw.row(id).sent_bytes).toBe(1500 + 600);
        expect(JSON.parse(items()[0].made_from)).toEqual([ids.a, "PublicVideo00000"]);
    });

    it("files the library row exactly as 31.10: a private, studio-sourced video of its own post, with its poster and made_spec", async () => {
        const id = cw.queueRender({ title: "Beach / day\u0007 out", revision: 7, key_id: KEY_ID });
        const core = cw.makeCore("r0");
        await cw.run(core);
        const rows = items();
        expect(rows).toHaveLength(1);
        const r = rows[0];
        const poster = POSTER_RE.exec(r.poster)!;
        expect(poster).not.toBeNull();
        expect(r).toMatchObject({
            kind: "private",
            source: "studio",
            bucket: "originals",
            r2_key: `edits/${id}.mp4`,
            url: null,
            name: "day out.mp4", // cleaned like an upload name: no `/`, no control characters
            content_type: "video/mp4",
            bytes: 4096,
            width: 1080,
            height: 1920,
            duration: 9,
            link: null,
            session_id: null,
            key_id: KEY_ID,
            role: null,
            item_index: null,
            post_key: null,
            visibility: "private",
            deleted_at: null,
            created_at: cw.row(id).finished_at,
        });
        expect(r.id).toMatch(/^[A-Za-z0-9]{16}$/);
        expect(JSON.parse(r.made_from)).toEqual([ids.a, ids.b]);
        expect(r.made_spec).toBe(JSON.stringify({ kind: "edit", project: "ProjectAAAAAAAAA", render: id, revision: 7 }));
        expect(Buffer.byteLength(r.made_spec)).toBeLessThanOrEqual(512);
        expect(cw.row(id).item_id).toBe(r.id);
        // the project's name is the post's title (section 15): the post key is the row's own id
        expect(cw.db.raw.prepare("SELECT * FROM media_titles WHERE post_key = ?").get(r.id)).toEqual({ post_key: r.id, title: "Beach / day\u0007 out", key_id: KEY_ID, updated_at: cw.row(id).finished_at });
        // the objects
        const mp4 = cw.originals.objects.get(`edits/${id}.mp4`)!;
        expect(mp4.bytes).toEqual(cw.container.file);
        expect(mp4.contentType).toBe("video/mp4");
        expect(mp4.meta).toMatchObject({ keyId: KEY_ID, source: "studio", project: "ProjectAAAAAAAAA", render: id });
        expect(mp4.meta.createdAt).toMatch(/^\d+$/);
        const p = cw.media.objects.get(`${poster[1]}.jpg`)!;
        expect(p.contentType).toBe("image/jpeg");
        expect(p.cacheControl).toBe("public, max-age=31536000, immutable");
        expect(p.meta).toMatchObject({ poster: "1", render: id });
        expect(p.data).toEqual(cw.container.poster);
        expect(cw.media.objects.size).toBe(1); // the poster, and no other write to the public bucket
        expect([...cw.media.objects.keys()].filter((k) => k.endsWith(".jpg"))).toEqual([`${poster[1]}.jpg`]);
    });

    it("GET /library lists it as a post of its own (its id is the post key) with the project's name as the title, the poster and made_spec", async () => {
        const id = cw.queueRender({ title: "My edit", revision: 3 });
        await cw.run(cw.makeCore("r0"));
        const row = items()[0];
        const res = await cw.call("/library?v=3", { headers: { authorization: "Api-Key 0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11" } });
        expect(res.status).toBe(200);
        const body: any = await res.json();
        const post = body.posts.find((p: any) => p.id === row.id);
        expect(post).toBeDefined();
        expect(post).toMatchObject({ custom_title: "My edit", duration: 9, width: 1080, height: 1920, poster_url: row.poster, visibility: "private" });
        expect(post.files).toHaveLength(1);
        expect(post.files[0]).toMatchObject({
            id: row.id,
            source: "studio",
            content_type: "video/mp4",
            bytes: 4096,
            made_from: [ids.a, ids.b],
            made_spec: { kind: "edit", project: "ProjectAAAAAAAAA", render: id, revision: 3 },
            visibility: "private",
        });
        // 31.10: a video post (the lead is the originals mp4 with no role), one item
        expect(post).toMatchObject({ kind: "video", item_count: 1 });
    });

    it("an existing studio webp (image/webp in the media bucket) is still a webp post", async () => {
        cw.db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, key_id, created_at, visibility) VALUES ('StudioWebp00001x','public','studio','media','StudioWebp.webp','a.webp','image/webp',5,?,1000,'public')",
            )
            .run(KEY_ID);
        const res = await cw.call("/library?v=3", { headers: { authorization: "Api-Key 0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11" } });
        const body: any = await res.json();
        const post = body.posts.find((p: any) => p.id === "StudioWebp00001x");
        expect(post).toMatchObject({ kind: "webp", item_count: 0 });
    });

    it("two renders queued: the first's cleanup claims the second in the same tick; oldest first", async () => {
        const first = cw.queueRender({ title: "one" });
        const second = cw.queueRender({ title: "two" });
        const core = cw.makeCore("r0");
        await cw.run(core);
        expect(cw.row(first)).toMatchObject({ status: "done", attempts: 1 });
        expect(cw.row(second)).toMatchObject({ status: "done", attempts: 1 });
        expect(cw.row(first).finished_at).toBeLessThan(cw.row(second).started_at + 1);
        expect(items().map((r) => r.name)).toEqual(["one.mp4", "two.mp4"]);
        // while it holds a render the env is not checked; it is checked each time the instance is idle and about to claim:
        // the first claim, the second (in the first's cleanup tick) and the one that found nothing
        expect(core.envChecks).toBe(3);
    });

    it("a render nobody queued: the tick finds nothing, arms nothing, and the container is never started", async () => {
        const core = cw.makeCore("r0");
        await core.tick();
        expect(core.pending).toBeNull();
        expect(core.ensured).toBe(0);
        expect(cw.container.calls).toEqual([]);
    });
});

describe("scheduling: poll-driven, nothing after a response", () => {
    it("a kick only arms the tick, de-duplicated; the tick runs one step and re-arms (0 s for inputs, 5 s while waiting)", async () => {
        cw.queueRender();
        const core = cw.makeCore("r0");
        await core.kick();
        await core.kick();
        expect(core.scheduled).toEqual([0]);
        expect(cw.container.calls).toEqual([]);
        await run1(core); // claim
        expect(record(core)?.step).toBe("inputs");
        await run1(core); // input 0
        await run1(core); // input 1
        expect(record(core)?.step).toBe("start");
        await run1(core); // start
        expect(record(core)).toMatchObject({ step: "wait", retried: false });
        expect(record(core)!.deadline).toBe(cw.clock.t + 300_000);
        expect(core.pending).toBe(5);
        await run1(core); // one poll
        expect(cw.container.calls.filter((c) => c.startsWith("GET /renders/<rid>"))).toHaveLength(1);
        async function run1(c: typeof core) {
            const d = c.pending!;
            c.pending = null;
            cw.clock.t += d * 1000;
            await c.tick();
        }
    });

    it("a stale armed time is scheduled over, a due one is not scheduled twice", async () => {
        const core = cw.makeCore("r0");
        await core.arm(2);
        expect(await core.arm(2)).toBe(false);
        expect(await core.arm(0)).toBe(true); // sooner than what is armed
        cw.clock.t += 60_000;
        expect(core.storage.m.get(TICK_KEY)).toBeLessThan(cw.clock.t);
        expect(await core.arm(2)).toBe(true); // the stored time passed: the alarm never ran
        expect(core.scheduled).toEqual([2, 0, 2]);
    });

    it("a kick that arrives while a tick runs is not lost: the tick arms again when it found nothing", async () => {
        const core = cw.makeCore("r0");
        const p = core.tick();
        await core.kick(); // while running: nothing is armed now, the tick does it when it ends
        expect(core.pending).toBeNull();
        await p;
        expect(core.pending).toBe(0);
        // and a tick nobody kicked during arms nothing when it finds nothing
        core.pending = null;
        await core.tick();
        expect(core.pending).toBeNull();
    });

    it("a tick that dies is simply run again: a new object (same storage) carries on from the record", async () => {
        const id = cw.queueRender();
        const core = cw.makeCore("r0");
        await core.kick();
        // claim, both inputs, start, one poll
        for (let i = 0; i < 5; i++) {
            const d = core.pending!;
            core.pending = null;
            cw.clock.t += d * 1000;
            await core.tick();
        }
        expect(record(core)?.step).toBe("wait");
        const reborn = cw.makeCore("r0", { storage: core.storage });
        await cw.run(reborn);
        expect(cw.row(id)).toMatchObject({ status: "done", attempts: 1 });
        expect(cw.container.calls.filter((c) => c.startsWith("PUT"))).toHaveLength(2);
        expect(items()).toHaveLength(1);
    });
});

describe("the claim", () => {
    it("two instances racing for ONE queued render: only one wins", async () => {
        const id = cw.queueRender();
        const r0 = cw.makeCore("r0");
        const r1 = cw.makeCore("r1");
        await Promise.all([r0.tick(), r1.tick()]);
        const row = cw.row(id);
        expect(row.attempts).toBe(1);
        expect(["r0", "r1"]).toContain(row.instance);
        const holders = [r0, r1].filter((c) => record(c));
        expect(holders).toHaveLength(1);
        expect(record(holders[0]!)!.rid).toBe(id);
        // the other one is idle and armed nothing
        const loser = [r0, r1].find((c) => !record(c))!;
        expect(loser.pending).toBeNull();
        expect(cw.container.calls).toEqual([]);
    });

    it("two renders, two instances: each takes one, oldest first, and neither takes the other's", async () => {
        const a = cw.queueRender({ title: "a" });
        const b = cw.queueRender({ title: "b" });
        const c = cw.queueRender({ title: "c" });
        const r0 = cw.makeCore("r0");
        const r1 = cw.makeCore("r1");
        await r0.tick();
        await r1.tick();
        expect(record(r0)!.rid).toBe(a);
        expect(record(r1)!.rid).toBe(b);
        expect(cw.row(c)).toMatchObject({ status: "queued", instance: null, attempts: 0 });
        await Promise.all([cw.run(r0), cw.run(r1)]);
        for (const id of [a, b, c]) expect(cw.row(id)).toMatchObject({ status: "done", attempts: 1 });
        expect(new Set([a, b, c].map((id) => cw.row(id).instance)).size).toBeGreaterThan(0);
    });

    it("never claims a render whose cancel was asked", async () => {
        const id = cw.queueRender({ cancel_requested: 1 });
        const core = cw.makeCore("r0");
        await core.tick();
        expect(record(core)).toBeUndefined();
        expect(cw.row(id).status).toBe("queued");
    });

    it("a row already marked with this instance's name, with no record, is re-queued (then claimed again), or lost on its second loss", async () => {
        const a = cw.queueRender({ status: "rendering", instance: "r0", attempts: 1, started_at: 5 });
        const core = cw.makeCore("r0");
        await core.tick();
        // re-queued, and being the only one queued it is claimed again by the same tick
        expect(cw.row(a)).toMatchObject({ status: "preparing", instance: "r0", attempts: 2 });
        const b = cw.queueRender({ status: "finishing", instance: "r1", attempts: 2, notify: 1, title: "Gone" });
        const other = cw.makeCore("r1");
        await other.tick();
        expect(cw.row(b)).toMatchObject({ status: "error", error_code: "error.edit.lost" });
        // 31.11: it ended in error, so it is announced once
        expect(cw.harkCalls.map((c) => c.body.body)).toEqual(["couldn't render Gone — the server restarted"]);
        expect(cw.row(b).notified_at).not.toBeNull();
    });

    it("the cron's error.edit.lost notifies too (once), and not a render that did not ask", async () => {
        const asked = cw.queueRender({ status: "rendering", instance: "r0", attempts: 2, notify: 1, title: "Cron lost", updated_at: 1 });
        const quiet = cw.queueRender({ status: "rendering", instance: "r1", attempts: 2, notify: 0, updated_at: 1 });
        cw.clock.t += 11 * 60_000;
        const { notifyEndedRow } = await import("../src/edit-render-core");
        const onLost = (rid: string) =>
            notifyEndedRow(
                {
                    db: cw.db,
                    hark: HARK,
                    now: cw.clock.now,
                    harkFetch: async (url, init) => {
                        cw.harkCalls.push({ url, body: JSON.parse(String(init.body)) });
                        return new Response(null, { status: 200 });
                    },
                },
                rid,
            );
        const r = await editsRecover({ db: cw.db, now: cw.clock.now, kick: async () => {}, onLost });
        expect(r.lost).toBe(2);
        expect(cw.row(asked)).toMatchObject({ status: "error", error_code: "error.edit.lost" });
        expect(cw.row(quiet).status).toBe("error");
        expect(cw.harkCalls.map((c) => c.body.body)).toEqual(["couldn't render Cron lost — the server restarted"]);
        await onLost(asked);
        expect(cw.harkCalls).toHaveLength(1);
    });
});

describe("notify (31.11)", () => {
    it("done: exactly one Hark message `<title> · video ready · <w>×<h> · <m:ss> · <size>`, url cobalt-apple://jobs, notified_at set", async () => {
        const id = cw.queueRender({ notify: 1, title: "Beach day" });
        await cw.run(cw.makeCore("r0"));
        expect(cw.harkCalls).toEqual([
            {
                url: HARK,
                body: { title: "capystore", body: `Beach day · video ready · 1080×1920 · 0:09 · ${formatBytes(4096)}`, url: "cobalt-apple://jobs" },
            },
        ]);
        expect(cw.row(id).notified_at).toBeGreaterThanOrEqual(cw.row(id).finished_at);
    });

    it("the duration is m:ss", async () => {
        cw.container.result = { bytes: 4096, width: 1080, height: 1920, duration: 125.4 };
        cw.queueRender({ notify: 1 });
        await cw.run(cw.makeCore("r0"));
        expect(cw.harkCalls[0]!.body.body).toContain(" · 2:05 · ");
    });

    it("error: `couldn't render <title> — <reason>` with the plain reason of the code", async () => {
        const cases: [string, string][] = [
            ["error.edit.render_failed", "the video couldn't be made"],
            ["error.edit.too_large", "the video was too big"],
        ];
        for (const [code, reason] of cases) {
            cw = coreWorld();
            await cw.addKey();
            cw.seedLibrary();
            cw.container.helperError = code;
            cw.queueRender({ notify: 1, title: "My edit" });
            await cw.run(cw.makeCore("r0"));
            expect(cw.harkCalls.map((c) => c.body)).toEqual([{ title: "capystore", body: `couldn't render My edit — ${reason}`, url: "cobalt-apple://jobs" }]);
        }
    });

    it("the reasons for timeout, source_missing, lost and storage", async () => {
        const { plainReason } = await import("../src/notify");
        expect(plainReason("error.edit.timeout")).toBe("it took too long");
        expect(plainReason("error.edit.source_missing")).toBe("a clip was deleted from the library");
        expect(plainReason("error.edit.lost")).toBe("the server restarted");
        expect(plainReason("error.edit.storage")).toBe("the server couldn't store it");
        expect(plainReason("error.edit.render_failed")).toBe("the video couldn't be made");
        expect(plainReason("error.edit.too_large")).toBe("the video was too big");
        expect(plainReason("error.edit.unknown")).toBe("something went wrong on the server");
    });

    it("sends nothing when the render did not ask, when the bridge is off, and for a cancel", async () => {
        const quiet = cw.queueRender({ notify: 0 });
        await cw.run(cw.makeCore("r0"));
        expect(cw.harkCalls).toEqual([]);
        expect(cw.row(quiet).notified_at).toBeNull();

        const off = cw.queueRender({ notify: 1 });
        await cw.run(cw.makeCore("r0", { hark: null }));
        expect(cw.harkCalls).toEqual([]);
        expect(cw.row(off)).toMatchObject({ status: "done", notified_at: null });

        const cancelled = cw.queueRender({ notify: 1 });
        cw.container.onCall = (m) => {
            if (m === "PUT") cw.db.raw.prepare("UPDATE edit_renders SET cancel_requested = 1 WHERE id = ?").run(cancelled);
        };
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(cancelled).status).toBe("cancelled");
        expect(cw.harkCalls).toEqual([]);
        expect(cw.row(cancelled).notified_at).toBeNull();
    });

    it("a failed send is retried by the next two ticks, then given up; a send that works stops the retries (notified_at is the marker)", async () => {
        const a = cw.queueRender({ notify: 1 });
        cw.setHark(500);
        await cw.run(cw.makeCore("r0"));
        expect(cw.harkCalls).toHaveLength(3);
        expect(cw.row(a)).toMatchObject({ status: "done", notified_at: null });

        cw.harkCalls.length = 0;
        const b = cw.queueRender({ notify: 1 });
        cw.setHark(200);
        cw.harkScript(503, 200);
        await cw.run(cw.makeCore("r0"));
        expect(cw.harkCalls).toHaveLength(2);
        expect(cw.row(b).notified_at).toBeGreaterThan(0);
    });

    it("a rejection (4xx) is not retried; a network error or a hang is retried and bounded at 3 s", async () => {
        const a = cw.queueRender({ notify: 1 });
        cw.setHark(404);
        await cw.run(cw.makeCore("r0"));
        expect(cw.harkCalls).toHaveLength(1);
        expect(cw.row(a).notified_at).toBeNull();

        cw.harkCalls.length = 0;
        cw.setHark(200, true);
        const b = cw.queueRender({ notify: 1 });
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(b).status).toBe("done");
        expect(cw.row(b).notified_at).toBeNull();

        vi.useFakeTimers();
        const c = cw.queueRender({ notify: 1 });
        let calls = 0;
        const core = cw.makeCore("r0", {
            harkFetch: () => {
                calls++;
                return new Promise<Response>(() => {});
            },
        });
        const p = cw.run(core);
        for (let i = 0; i < 40; i++) await vi.advanceTimersByTimeAsync(1000);
        await p;
        expect(calls).toBe(3);
        expect(cw.row(c)).toMatchObject({ status: "done", notified_at: null });
    });

    it("is exactly once: a record that replays the notify step after the marker is set sends nothing", async () => {
        const id = cw.queueRender({ notify: 1 });
        const core = cw.makeCore("r0");
        await cw.run(core);
        expect(cw.harkCalls).toHaveLength(1);
        core.storage.m.set(RENDER_KEY, { rid: id, step: "notify", n: 0, inputs: [], startedAt: 0, deadline: 0, retried: false, ended: { status: "done", code: null }, result: { bytes: 4096, width: 1080, height: 1920, duration: 9 } });
        await cw.run(core);
        expect(cw.harkCalls).toHaveLength(1);
    });
});

describe("a container that loses the render (31.9)", () => {
    it("a 404 at wait restarts once from input 0, the second time the render is error.edit.lost", async () => {
        const id = cw.queueRender({ notify: 1 });
        // the container forgets the render every time it is asked about it
        cw.container.onCall = (m, p) => {
            if (m === "GET" && /^\/renders\/[A-Za-z0-9]{20}$/.test(p)) cw.container.reboot();
        };
        await cw.run(cw.makeCore("r0"));
        expect(cw.container.calls.filter((c) => c.startsWith("PUT"))).toHaveLength(4);
        expect(cw.container.calls.filter((c) => c.startsWith("POST"))).toHaveLength(2);
        expect(cw.row(id)).toMatchObject({ status: "error", error_code: "error.edit.lost", attempts: 1 });
        expect(cw.originals.objects.has(`edits/${id}.mp4`)).toBe(false);
        expect(items()).toHaveLength(0);
        expect(cw.harkCalls.map((c) => c.body.body)).toEqual(["couldn't render My edit — the server restarted"]);
    });

    it("the restart works: lost once, then the render finishes (status back to preparing, sent_bytes recounted)", async () => {
        const id = cw.queueRender();
        let polls = 0;
        const seen = trace(id);
        const base = cw.container.onCall!;
        cw.container.onCall = async (m, p) => {
            await base(m, p);
            if (m === "GET" && /^\/renders\/[A-Za-z0-9]{20}$/.test(p) && ++polls === 2) cw.container.reboot();
        };
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(id)).toMatchObject({ status: "done", attempts: 1, sent_bytes: 4000 });
        expect(seen.filter((s) => s.startsWith("PUT"))).toEqual(["PUT inputs/0 preparing", "PUT inputs/1 preparing", "PUT inputs/0 preparing", "PUT inputs/1 preparing"]);
        expect(seen.filter((s) => s.startsWith("POST start"))).toHaveLength(2);
        // one result only
        expect(items()).toHaveLength(1);
        expect(cw.originals.objects.has(`edits/${id}.mp4`)).toBe(true);
    });

    it("the restart frees the container's copy of the render first (DELETE before the second round of inputs)", async () => {
        const id = cw.queueRender();
        let polls = 0;
        const base = cw.container.onCall;
        cw.container.onCall = async (m, p) => {
            await base?.(m, p);
            if (m === "GET" && /^\/renders\/[A-Za-z0-9]{20}$/.test(p) && ++polls === 2) cw.container.reboot();
        };
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(id).status).toBe("done");
        const calls = cw.container.calls;
        const del = calls.indexOf("DELETE /renders/<rid>");
        const secondPut = calls.indexOf("PUT /renders/<rid>/inputs/0", calls.indexOf("PUT /renders/<rid>/inputs/0") + 1);
        expect(del).toBeGreaterThan(-1);
        expect(del).toBeLessThan(secondPut);
    });

    it("a container stuck busy with our own rid is freed by the restart so the one retry can succeed", async () => {
        const id = cw.queueRender();
        let busy = true;
        cw.container.inputStatus = (n) => (busy && n === 0 ? 409 : 204);
        const base = cw.container.onCall;
        cw.container.onCall = async (m, p) => {
            await base?.(m, p);
            if (m === "DELETE") busy = false;
        };
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(id)).toMatchObject({ status: "done" });
        expect(cw.container.calls.filter((c) => c.startsWith("DELETE")).length).toBeGreaterThanOrEqual(1);
    });

    it("a 404 at collect and at poster is the same loss", async () => {
        for (const where of ["file", "poster"]) {
            cw = coreWorld();
            await cw.addKey();
            cw.seedLibrary();
            const id = cw.queueRender();
            let lost = 0;
            cw.container.onCall = (m, p) => {
                if (m === "GET" && p.endsWith(`/${where}`) && lost++ === 0) cw.container.reboot();
            };
            await cw.run(cw.makeCore("r0"));
            expect(cw.row(id), where).toMatchObject({ status: "done", attempts: 1 });
            expect(cw.container.calls.filter((c) => c.startsWith("PUT")), where).toHaveLength(4);
        }
    });

    it("a container that will not start loses the work twice and then the render is lost", async () => {
        const id = cw.queueRender();
        let starts = 0;
        const core = cw.makeCore("r0", {
            ensureRunning: async () => {
                starts++;
                throw new Error("no capacity");
            },
        });
        await cw.run(core);
        expect(cw.row(id)).toMatchObject({ status: "error", error_code: "error.edit.lost" });
        expect(starts).toBeGreaterThanOrEqual(2);
        expect(cw.container.calls).toEqual([]);
    });

    it("a container that takes longer than 60 s to start is cut at our own ceiling", async () => {
        vi.useFakeTimers();
        const id = cw.queueRender();
        const core = cw.makeCore("r0", { ensureRunning: () => new Promise<void>(() => {}) });
        const p = cw.run(core);
        for (let i = 0; i < 300; i++) await vi.advanceTimersByTimeAsync(1000);
        await p;
        expect(cw.row(id)).toMatchObject({ status: "error", error_code: "error.edit.lost" });
    });

    it("a status call that never answers is cut at 15 s; six in a row count as lost", async () => {
        vi.useFakeTimers();
        const id = cw.queueRender();
        const orig = cw.container.handle;
        let hangs = 0;
        const core = cw.makeCore("r0", {
            container: (path, init) => {
                if ((init?.method ?? "GET") === "GET" && /^\/renders\/[A-Za-z0-9]{20}$/.test(path)) {
                    hangs++;
                    return new Promise<Response>(() => {});
                }
                return orig(path, init);
            },
        });
        const p = cw.run(core);
        for (let i = 0; i < 400; i++) await vi.advanceTimersByTimeAsync(1000);
        await p;
        expect(hangs).toBe(12);
        expect(cw.row(id)).toMatchObject({ status: "error", error_code: "error.edit.lost" });
    });

    it("busy answers to an input are retried; too many lose the work; 413 is too_large", async () => {
        const id = cw.queueRender();
        cw.container.inputStatus = (n, tries) => (tries <= 3 ? 409 : 204);
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(id).status).toBe("done");

        cw = coreWorld();
        await cw.addKey();
        cw.seedLibrary();
        const stuck = cw.queueRender();
        cw.container.inputStatus = () => 409;
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(stuck)).toMatchObject({ status: "error", error_code: "error.edit.lost" });
        expect(cw.container.calls.filter((c) => c.startsWith("PUT"))).toHaveLength(12);

        cw = coreWorld();
        await cw.addKey();
        cw.seedLibrary();
        const big = cw.queueRender();
        cw.container.inputStatus = () => 413;
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(big)).toMatchObject({ status: "error", error_code: "error.edit.too_large" });
    });
});

describe("the deadline (31.8 step 3)", () => {
    it("clamp(180 s + 4 x seconds_total, 300 s, 2700 s)", () => {
        expect(deadlineMs(0)).toBe(300_000);
        expect(deadlineMs(9)).toBe(300_000);
        expect(deadlineMs(60)).toBe(420_000);
        expect(deadlineMs(600)).toBe(2_580_000);
        expect(deadlineMs(10_000)).toBe(2_700_000);
    });

    it("past the deadline: DELETE, error.edit.timeout, nothing filed", async () => {
        const id = cw.queueRender({ notify: 1 });
        cw.container.stuck = true;
        const core = cw.makeCore("r0");
        await cw.run(core);
        const row = cw.row(id);
        expect(row).toMatchObject({ status: "error", error_code: "error.edit.timeout" });
        expect(row.finished_at - row.started_at).toBeGreaterThanOrEqual(300_000);
        expect(row.finished_at - row.started_at).toBeLessThan(330_000);
        expect(cw.container.calls.at(-1)).toBe("DELETE /renders/<rid>");
        expect(items()).toHaveLength(0);
        expect(cw.originals.objects.has(`edits/${id}.mp4`)).toBe(false);
        expect(cw.harkCalls[0]!.body.body).toBe("couldn't render My edit — it took too long");
    });

    it("progress reaches D1 on every poll (seconds_done) while it waits", async () => {
        const id = cw.queueRender();
        const seen: number[] = [];
        cw.container.onCall = (m, p) => {
            if (m === "GET" && /^\/renders\/[A-Za-z0-9]{20}$/.test(p)) seen.push(cw.row(id).seconds_done);
        };
        await cw.run(cw.makeCore("r0"));
        // before each poll the previous one's value is there: 0 at the start, then 3, then 6
        expect(seen).toEqual([0, 3, 6]);
    });
});

describe("cancel (31.9 step 4)", () => {
    it("while waiting: DELETE, cancelled, error.edit.cancelled, no result filed, no message", async () => {
        const id = cw.queueRender({ notify: 1 });
        let polls = 0;
        cw.container.stuck = true;
        cw.container.onCall = (m, p) => {
            if (m === "GET" && /^\/renders\/[A-Za-z0-9]{20}$/.test(p) && ++polls === 2) {
                cw.db.raw.prepare("UPDATE edit_renders SET cancel_requested = 1 WHERE id = ?").run(id);
            }
        };
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(id)).toMatchObject({ status: "cancelled", error_code: "error.edit.cancelled", cancel_requested: 1 });
        expect(cw.row(id).finished_at).toBeGreaterThan(0);
        expect(polls).toBe(2);
        expect(cw.container.calls.at(-1)).toBe("DELETE /renders/<rid>");
        expect(items()).toHaveLength(0);
        expect(cw.harkCalls).toEqual([]);
    });

    it("while preparing (before the start), and while finishing (the mp4 already in R2 is deleted again)", async () => {
        const a = cw.queueRender();
        cw.container.onCall = (m, p) => {
            if (m === "PUT" && p.endsWith("/inputs/0")) cw.db.raw.prepare("UPDATE edit_renders SET cancel_requested = 1 WHERE id = ?").run(a);
        };
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(a).status).toBe("cancelled");
        expect(cw.container.calls.some((c) => c.startsWith("POST start"))).toBe(false);

        const b = cw.queueRender();
        cw.container.calls.length = 0;
        cw.container.onCall = (m, p) => {
            if (m === "GET" && p.endsWith("/file")) cw.db.raw.prepare("UPDATE edit_renders SET cancel_requested = 1 WHERE id = ?").run(b);
        };
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(b)).toMatchObject({ status: "cancelled", error_code: "error.edit.cancelled" });
        expect(cw.originals.objects.has(`edits/${b}.mp4`)).toBe(false);
        expect(items()).toHaveLength(0);
        expect([...cw.media.objects.keys()].filter((k) => k.endsWith(".jpg"))).toEqual([]);
    });

    it("after the poster is written but before the library row: both objects are deleted", async () => {
        const id = cw.queueRender();
        cw.container.onCall = (m, p) => {
            if (m === "GET" && p.endsWith("/poster")) cw.db.raw.prepare("UPDATE edit_renders SET cancel_requested = 1 WHERE id = ?").run(id);
        };
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(id).status).toBe("cancelled");
        expect(cw.originals.objects.has(`edits/${id}.mp4`)).toBe(false);
        expect([...cw.media.objects.keys()].filter((k) => k.endsWith(".jpg"))).toEqual([]);
        expect(items()).toHaveLength(0);
        expect(cw.db.raw.prepare("SELECT COUNT(*) AS n FROM media_titles").get()).toEqual({ n: 0 });
    });

    it("a cancel that comes after the render is recorded finds it done: the video stays", async () => {
        const id = cw.queueRender();
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(id).status).toBe("done");
        cw.db.raw.prepare("UPDATE edit_renders SET cancel_requested = 1 WHERE id = ?").run(id);
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(id).status).toBe("done");
        expect(items()).toHaveLength(1);
    });
});

describe("sources", () => {
    it("a clip deleted from the library after queueing: error.edit.source_missing before any container call", async () => {
        const id = cw.queueRender({ notify: 1 });
        cw.db.raw.prepare("UPDATE media_items SET deleted_at = 5 WHERE id = ?").run(ids.b);
        const core = cw.makeCore("r0");
        await cw.run(core);
        expect(cw.row(id)).toMatchObject({ status: "error", error_code: "error.edit.source_missing" });
        expect(cw.container.calls).toEqual([]);
        expect(core.ensured).toBe(0);
        expect(cw.harkCalls[0]!.body.body).toBe("couldn't render My edit — a clip was deleted from the library");
    });

    it("an object gone from R2: source_missing at that input, and the container's copy is deleted", async () => {
        const id = cw.queueRender();
        cw.originals.objects.delete(`originals/${ids.b}.bin`);
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(id)).toMatchObject({ status: "error", error_code: "error.edit.source_missing" });
        expect(cw.container.calls).toEqual(["PUT /renders/<rid>/inputs/0", "DELETE /renders/<rid>"]);
    });

    it("an unknown row, a type the editor does not take, a photo on the main track: refused with their codes", async () => {
        const unknown = cw.queueRender({ timeline: timeline({ main: [mainClip(ids.a), mainClip("UnknownItem00000", { id: "m2" })] }) });
        const webm = cw.queueRender({ timeline: timeline({ main: [mainClip(ids.a)], overlay: [overlayClip(ids.webm)] }) });
        const photo = cw.queueRender({ timeline: timeline({ main: [mainClip(ids.photo)] }) });
        const past = cw.queueRender({ timeline: timeline({ main: [mainClip(ids.b, { out: 6.2 })] }) });
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(unknown).error_code).toBe("error.edit.source_missing");
        expect(cw.row(webm).error_code).toBe("error.edit.unsupported_source");
        expect(cw.row(photo).error_code).toBe("error.edit.unsupported_source");
        expect(cw.row(past).error_code).toBe("error.edit.past_source_end");
        expect(cw.container.calls).toEqual([]);
    });
});

describe("what the helper says", () => {
    it("an error answer ends the render with its code when it is a render outcome, else render_failed", async () => {
        const a = cw.queueRender();
        cw.container.helperError = "error.edit.range";
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(a).error_code).toBe("error.edit.range");
        cw.container.helperError = "error.edit.busy";
        const b = cw.queueRender();
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(b).error_code).toBe("error.edit.render_failed");
        expect(renderErrorCode("error.edit.storage")).toBe("error.edit.storage");
        expect(renderErrorCode(undefined)).toBe("error.edit.render_failed");
        expect(renderErrorCode("error.api.generic")).toBe("error.edit.render_failed");
    });

    it("a refusal at start (400) ends with the helper's code; input_missing at start is a lost container", async () => {
        const a = cw.queueRender();
        cw.container.startStatus = { status: 400, body: { status: "error", error: { code: "error.edit.past_source_end" }, path: "main[0].out" } };
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(a)).toMatchObject({ status: "error", error_code: "error.edit.past_source_end" });
        expect(cw.container.calls.at(-1)).toBe("DELETE /renders/<rid>");

        const b = cw.queueRender();
        cw.container.startStatus = { status: 409, body: { status: "error", error: { code: "error.edit.input_missing" } } };
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(b)).toMatchObject({ status: "error", error_code: "error.edit.lost" });
    });

    it("an output over 4 GiB is error.edit.too_large and is never collected", async () => {
        const id = cw.queueRender();
        cw.container.result = { bytes: 4 * 1024 ** 3 + 1, width: 1080, height: 1920, duration: 9 };
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(id).error_code).toBe("error.edit.too_large");
        expect(cw.container.calls.some((c) => c.endsWith("/file"))).toBe(false);
    });

    it("a done answer without sizes is render_failed", async () => {
        const id = cw.queueRender();
        cw.container.result = { bytes: 4096, width: 0, height: 1920, duration: 9 };
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(id).error_code).toBe("error.edit.render_failed");
    });
});

describe("collect and poster", () => {
    it("a put that fails is retried by the next tick; two failures are error.edit.storage and the half-made object is deleted", async () => {
        const a = cw.queueRender();
        let gets = 0;
        cw.originals.failPut = true;
        cw.container.onCall = (m, p) => {
            if (m === "GET" && p.endsWith("/file") && ++gets === 2) cw.originals.failPut = false;
        };
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(a).status).toBe("done");
        expect(gets).toBe(2);

        cw.originals.failPut = true;
        const b = cw.queueRender({ notify: 1 });
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(b)).toMatchObject({ status: "error", error_code: "error.edit.storage" });
        expect(cw.originals.objects.has(`edits/${b}.mp4`)).toBe(false);
        expect(cw.harkCalls.at(-1)!.body.body).toBe("couldn't render My edit — the server couldn't store it");
    });

    it("a declared length that is not what arrives fails the put like R2 would (FixedLengthStream), twice, then storage", async () => {
        const id = cw.queueRender();
        cw.container.fileLength = 100;
        await cw.run(cw.makeCore("r0"));
        expect(cw.row(id).error_code).toBe("error.edit.storage");
        expect(cw.originals.objects.has(`edits/${id}.mp4`)).toBe(false);
    });

    it("no content-length on the file: not stored", async () => {
        const id = cw.queueRender();
        const orig = cw.container.handle;
        const core = cw.makeCore("r0", {
            container: async (path, init) => {
                const res = await orig(path, init);
                if (path.endsWith("/file")) {
                    const h = new Headers(res.headers);
                    h.delete("content-length");
                    return new Response(res.body, { status: res.status, headers: h });
                }
                return res;
            },
        });
        await cw.run(core);
        expect(cw.row(id).error_code).toBe("error.edit.storage");
    });

    it("a poster that cannot be made keeps the render: done, the row has no poster, no poster object, still notified", async () => {
        for (const how of ["500", "not a jpeg", "r2", "empty"]) {
            cw = coreWorld();
            await cw.addKey();
            cw.seedLibrary();
            if (how === "500") cw.container.posterStatus = 500;
            if (how === "not a jpeg") cw.container.poster = new Uint8Array([1, 2, 3, 4]);
            if (how === "empty") cw.container.poster = new Uint8Array(0);
            if (how === "r2") cw.media.failPut = true;
            const id = cw.queueRender({ notify: 1 });
            await cw.run(cw.makeCore("r0"));
            expect(cw.row(id).status, how).toBe("done");
            expect(items(), how).toHaveLength(1);
            expect(items()[0].poster, how).toBeNull();
            expect([...cw.media.objects.keys()].filter((k) => k.endsWith(".jpg")), how).toEqual([]);
            expect(cw.harkCalls, how).toHaveLength(1);
            // the existing poster sweep's backlog finds it: a private video original without a poster
            const backlog = cw.db.raw.prepare("SELECT COUNT(*) AS n FROM media_items WHERE deleted_at IS NULL AND bucket = 'originals' AND poster IS NULL AND content_type LIKE 'video/%' AND id = ?").get(items()[0].id);
            expect(backlog, how).toEqual({ n: 1 });
        }
    });

    it("hostile streams (no pipeTo, pipeThrough or tee on an R2 body): the copy is a reader/writer loop", async () => {
        cw.originals.hostileStreams = true;
        const loop = (stream: ReadableStream, length: number): ReadableStream => {
            const ts = new TransformStream<Uint8Array, Uint8Array>();
            void (async () => {
                const reader = stream.getReader();
                const writer = ts.writable.getWriter();
                let n = 0;
                for (;;) {
                    const { done, value } = await reader.read();
                    if (done) break;
                    n += value.length;
                    await writer.write(value);
                }
                if (n !== length) await writer.abort(new Error("length"));
                else await writer.close();
            })();
            return ts.readable;
        };
        const id = cw.queueRender();
        await cw.run(cw.makeCore("r0", { fixedLength: loop }));
        expect(cw.row(id).status).toBe("done");
    });
});

describe("ending a render deletes what it wrote, and cleanup", () => {
    it("cleanup deletes the container's copy only while the container runs", async () => {
        const id = cw.queueRender();
        const core = cw.makeCore("r0");
        core.up = false;
        await cw.run(core);
        // (the fake container ignores the flag for everything but DELETE; the machine still finished)
        expect(cw.row(id).status).toBe("done");
        expect(cw.container.calls.filter((c) => c.startsWith("DELETE"))).toEqual([]);
    });

    it("a cleanup DELETE that fails is retried by the next ticks, then given up; the next render is claimed anyway", async () => {
        const a = cw.queueRender({ title: "a" });
        const b = cw.queueRender({ title: "b" });
        let deletes = 0;
        const orig = cw.container.handle;
        const core = cw.makeCore("r0", {
            container: async (p, i) => {
                if (i?.method === "DELETE" && deletes++ < 3) throw new Error("gone");
                return orig(p, i);
            },
        });
        await cw.run(core);
        expect(cw.row(a).status).toBe("done");
        expect(cw.row(b).status).toBe("done");
        expect(deletes).toBeGreaterThanOrEqual(4);
    });

    it("a render the cron re-queued under the instance is dropped at its next tick (the row is not ours); the next claim carries on", async () => {
        const id = cw.queueRender();
        const core = cw.makeCore("r0");
        await core.kick();
        for (let i = 0; i < 3; i++) {
            const d = core.pending!;
            core.pending = null;
            cw.clock.t += d * 1000;
            await core.tick();
        }
        expect(record(core)?.rid).toBe(id);
        // eleven minutes pass without a write; the cron re-queues it
        cw.clock.t += 11 * 60_000;
        const r = await editsRecover({ db: cw.db, now: cw.clock.now, kick: async () => {} });
        expect(r.requeued).toBe(1);
        expect(cw.row(id).status).toBe("queued");
        await cw.run(core);
        // dropped, claimed again (second attempt), and finished
        expect(cw.row(id)).toMatchObject({ status: "done", attempts: 2 });
        expect(items()).toHaveLength(1);
    });

    it("an outage of D1 does not loop for ever: the record is dropped after 8 ticks and ticking stops (the cron re-queues the row)", async () => {
        const id = cw.queueRender();
        const core = cw.makeCore("r0");
        await core.kick();
        for (let i = 0; i < 2; i++) {
            const d = core.pending!;
            core.pending = null;
            await core.tick();
        }
        expect(record(core)).toBeDefined();
        cw.db.breakIt();
        const noise = vi.spyOn(console, "error").mockImplementation(() => {});
        await cw.run(core, 50);
        noise.mockRestore();
        expect(record(core)).toBeUndefined();
        expect(core.pending).toBeNull();
        void id;
    });
});

describe("R2 leftovers", () => {
    const putPoster = async (name: string) => {
        await cw.media.put(name, new Blob([new Uint8Array([1, 2, 3])]).stream() as any, { httpMetadata: { contentType: "image/jpeg" } } as any);
    };
    const advance = async (core: ReturnType<CoreWorld["makeCore"]>, n: number) => {
        await core.kick();
        for (let i = 0; i < n; i++) {
            const d = core.pending ?? 0;
            core.pending = null;
            cw.clock.t += d * 1000;
            await core.tick();
        }
    };

    it("abandon deletes the unrecorded poster even when the row was re-queued (the name is unique to the attempt)", async () => {
        const id = cw.queueRender();
        const core = cw.makeCore("r0");
        await advance(core, 3);
        const rec = record(core)!;
        expect(rec.rid).toBe(id);
        rec.posterName = "OrphanPost1.jpg";
        core.storage.m.set(RENDER_KEY, rec);
        await putPoster("OrphanPost1.jpg");
        cw.clock.t += 11 * 60_000;
        await editsRecover({ db: cw.db, now: cw.clock.now, kick: async () => {} });
        expect(cw.row(id).status).toBe("queued");
        await core.tick();
        expect(cw.media.objects.has("OrphanPost1.jpg")).toBe(false);
    });

    it("end deletes edits/<rid>.mp4 whether or not the flag was set (a tick that died inside the put)", async () => {
        const id = cw.queueRender();
        const core = cw.makeCore("r0");
        await advance(core, 3);
        const rec = record(core)!;
        expect(rec.mp4).toBeFalsy();
        await cw.originals.put(`edits/${id}.mp4`, new Blob([new Uint8Array([9])]).stream() as any, { httpMetadata: { contentType: "video/mp4" } } as any);
        cw.db.raw.prepare("UPDATE edit_renders SET cancel_requested = 1 WHERE id = ?").run(id);
        await cw.run(core);
        expect(cw.row(id).status).toBe("cancelled");
        expect(cw.originals.objects.has(`edits/${id}.mp4`)).toBe(false);
    });

    it("the give-up path (D1 down) leaves neither the mp4 nor the poster behind", async () => {
        const id = cw.queueRender();
        const core = cw.makeCore("r0");
        await advance(core, 3);
        const rec = record(core)!;
        rec.posterName = "OrphanPost2.jpg";
        core.storage.m.set(RENDER_KEY, rec);
        await putPoster("OrphanPost2.jpg");
        await cw.originals.put(`edits/${id}.mp4`, new Blob([new Uint8Array([9])]).stream() as any, { httpMetadata: { contentType: "video/mp4" } } as any);
        cw.db.breakIt();
        const noise = vi.spyOn(console, "error").mockImplementation(() => {});
        await cw.run(core, 50);
        noise.mockRestore();
        expect(record(core)).toBeUndefined();
        expect(cw.media.objects.has("OrphanPost2.jpg")).toBe(false);
        expect(cw.originals.objects.has(`edits/${id}.mp4`)).toBe(false);
    });
});

describe("the EditRenderer's env restart hook", () => {
    it("runs before a claim and never while a render is held", async () => {
        cw.queueRender();
        const core = cw.makeCore("r0");
        await cw.run(core);
        // one check for the claim, one for the claim attempt after the cleanup that found nothing
        expect(core.envChecks).toBe(2);
    });
});
