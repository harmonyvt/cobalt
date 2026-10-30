// The probe of "what it's about" (APP-API-CONTRACT.md section 34.2) at the level of the poster tests: the Durable
// Object's StudioService with its sweep, the internal POST /about/kick, a scripted helper answering POST /about, the
// private bucket the frames and sound land in, and the real SQL on node:sqlite. The helper itself (real ffmpeg) is in
// about-helper.test.ts.
import { describe, expect, it } from "vitest";
import { ABOUT_JOB_PREFIX, parseProbeAnswer } from "../src/about-probe";
import { KEY_ID_HEADER } from "../src/headers";
import { handleStudioRoute } from "../src/studio";
import { auth, world, type World } from "./poster-world";
import { fakeJpeg } from "./studio-fakes";

const DAY = 24 * 60 * 60 * 1000;
const b64 = (u: Uint8Array) => Buffer.from(u).toString("base64");
const MP3 = Uint8Array.from([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0, 0xff, 0xfb, 0x90]);
const answer = (frames = 3, audio = true) => ({ frames: Array.from({ length: frames }, (_, i) => b64(fakeJpeg(40, i + 1))), audio: audio ? b64(MP3) : null, duration: 9.6 });

type Reply = { status: number; body: unknown };
function probeWorld(replies: (Reply | (() => Reply))[] = []) {
    const calls: { path: string; bytes: number }[] = [];
    let w!: World;
    w = world({
        helperFn: async (path, init) => {
            if (!path.startsWith("/about")) return new Response(JSON.stringify({ status: "error", error: { code: "error.webp.not_found" } }), { status: 404 });
            const bytes = init?.body ? (await new Response(init.body as BodyInit).arrayBuffer()).byteLength : 0;
            calls.push({ path, bytes });
            const next = replies.shift() ?? { status: 200, body: answer() };
            const r = typeof next === "function" ? next() : next;
            return new Response(JSON.stringify(r.body), { status: r.status, headers: { "content-type": "application/json" } });
        },
    });
    const kick = async (limit = 25, key: string | null = "cron:about") => {
        const res = await handleStudioRoute(
            w.studio,
            new Request(`https://do.internal/about/kick?limit=${limit}`, { method: "POST", headers: key ? { [KEY_ID_HEADER]: key } : {} }),
        );
        return { status: res.status, body: res.status === 200 ? ((await res.json()) as any) : null };
    };
    const row = (post: string) => w.db.raw.prepare("SELECT * FROM media_about WHERE post_key = ?").get(post) as any;
    const jobs = () => [...w.kv.m.keys()].filter((k) => k.startsWith(ABOUT_JOB_PREFIX));
    const objects = () => [...w.originals.objects.keys()].filter((k) => k.startsWith("about/")).sort();
    return { w, calls, kick, row, jobs, objects };
}

describe("the about probe (34.2)", () => {
    it("a kick makes the rows and queues the videos; the sweep cuts one, stores frames and sound privately and marks it done", async () => {
        const p = probeWorld();
        const a = p.w.seed();
        expect((await p.kick(25, null)).status).toBe(403);
        expect((await p.kick()).body).toEqual({ status: "success", queued: 1, eligible: 1 });
        expect(p.row(a.sid)).toMatchObject({ item_id: a.itemId, probe_state: "pending", probe_attempts: 0 });
        expect(p.jobs()).toEqual([`${ABOUT_JOB_PREFIX}${a.itemId}`]);
        // queued once only
        expect((await p.kick()).body).toEqual({ status: "success", queued: 0, eligible: 1 });

        await p.w.studio.sweep();
        expect(p.calls).toEqual([{ path: `/about?id=${a.itemId}`, bytes: 4096 }]);
        expect(p.objects()).toEqual([`about/${a.itemId}/audio.mp3`, `about/${a.itemId}/frame-1.jpg`, `about/${a.itemId}/frame-2.jpg`, `about/${a.itemId}/frame-3.jpg`]);
        const frame = p.w.originals.objects.get(`about/${a.itemId}/frame-2.jpg`)!;
        expect(frame.contentType).toBe("image/jpeg");
        expect([...frame.bytes]).toEqual([...fakeJpeg(40, 2)]);
        expect(p.w.originals.objects.get(`about/${a.itemId}/audio.mp3`)!.contentType).toBe("audio/mpeg");
        // nothing went to the public bucket
        expect([...p.w.media.objects.keys()]).toEqual([]);
        expect(p.row(a.sid)).toMatchObject({ probe_state: "done", frames: 3, has_audio: 1, probe_attempts: 1, probe_at: p.w.clock.t });
        expect(p.jobs()).toEqual([]);
        expect((await p.kick()).body).toEqual({ status: "success", queued: 0, eligible: 0 });
        await p.w.studio.sweep();
        expect(p.calls).toHaveLength(1);
    });

    it("one job per pass, newest first; a still never gets one", async () => {
        const p = probeWorld();
        const a = p.w.seed();
        p.w.clock.t += 10;
        const b = p.w.seed();
        p.w.clock.t += 10;
        const still = p.w.seed({ content_type: "image/jpeg", r2_key: "originals/still.jpg" });
        expect((await p.kick()).body).toMatchObject({ queued: 2, eligible: 2 });
        expect(p.row(still.sid).probe_state).toBe("none");
        await p.w.studio.sweep();
        expect(p.calls).toHaveLength(1);
        await p.w.studio.sweep();
        expect(p.calls.map((c) => c.path).sort()).toEqual([`/about?id=${a.itemId}`, `/about?id=${b.itemId}`].sort());
        expect((await p.kick(1)).body).toMatchObject({ queued: 0 });
    });

    it("a busy helper is not an attempt; a file with no video becomes 'none'; a failure waits a day, three times at most", async () => {
        const p = probeWorld([
            { status: 429, body: { status: "error", error: { code: "error.webp.busy" } } },
            { status: 500, body: { status: "error", error: { code: "error.studio.upload_failed" } } },
        ]);
        const a = p.w.seed();
        await p.kick();
        await p.w.studio.sweep();
        expect(p.row(a.sid)).toMatchObject({ probe_state: "pending", probe_attempts: 0 });
        expect(p.w.kv.m.get(`${ABOUT_JOB_PREFIX}${a.itemId}`)).toMatchObject({ busy: 1 });
        await p.w.studio.sweep();
        expect(p.row(a.sid)).toMatchObject({ probe_state: "failed", probe_attempts: 1 });
        expect(p.jobs()).toEqual([]);
        expect((await p.kick()).body).toMatchObject({ queued: 0, eligible: 0 });
        p.w.clock.t += DAY + 1;
        expect((await p.kick()).body).toMatchObject({ queued: 1, eligible: 1 });
        p.w.db.raw.prepare("UPDATE media_about SET probe_attempts = 3").run();
        p.w.kv.m.clear();
        p.w.clock.t += DAY + 1;
        expect((await p.kick()).body).toMatchObject({ queued: 0, eligible: 0 });

        const q = probeWorld([{ status: 400, body: { status: "error", error: { code: "error.studio.not_video" } } }]);
        const s = q.w.seed();
        await q.kick();
        await q.w.studio.sweep();
        expect(q.row(s.sid).probe_state).toBe("none");
        expect(q.jobs()).toEqual([]);
    });

    it("an answer that is not frames and sound fails the attempt; a shorter answer clears what an older probe left", async () => {
        const p = probeWorld([{ status: 200, body: { frames: ["bm90IGEganBlZw=="], audio: null } }, { status: 200, body: answer(1, false) }]);
        const a = p.w.seed();
        await p.kick();
        await p.w.studio.sweep();
        expect(p.row(a.sid)).toMatchObject({ probe_state: "failed", probe_attempts: 1 });
        // an older probe's frames and sound
        for (const k of [`about/${a.itemId}/frame-2.jpg`, `about/${a.itemId}/frame-3.jpg`, `about/${a.itemId}/audio.mp3`]) {
            p.w.originals.objects.set(k, { bytes: new Uint8Array(3), contentType: "x", meta: {} });
        }
        p.w.clock.t += DAY + 1;
        await p.kick();
        await p.w.studio.sweep();
        expect(p.row(a.sid)).toMatchObject({ probe_state: "done", frames: 1, has_audio: 0, probe_attempts: 2 });
        expect(p.objects()).toEqual([`about/${a.itemId}/frame-1.jpg`]);
    });

    it("a file deleted after it was queued is dropped without a helper call", async () => {
        const p = probeWorld();
        const a = p.w.seed();
        await p.kick();
        p.w.db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE id = ?").run(a.itemId);
        await p.w.studio.sweep();
        expect(p.calls).toEqual([]);
        expect(p.jobs()).toEqual([]);
    });

    it("deleting the post deletes the frames, the sound and the row; a gone post's row goes on the next kick", async () => {
        const p = probeWorld();
        await p.w.addKey();
        const a = p.w.seed();
        const b = p.w.seed();
        await p.kick();
        await p.w.studio.sweep();
        await p.w.studio.sweep();
        expect(p.objects()).toHaveLength(8);
        const res = await p.w.call(`/library/items/${a.itemId}/post`, { method: "DELETE", headers: auth });
        expect(res.status).toBe(200);
        expect(p.objects().every((k) => k.startsWith(`about/${b.itemId}/`))).toBe(true);
        expect(p.row(a.sid)).toBeUndefined();
        // a path that marks the row deleted without the post delete (another route, a retention): the kick cleans up
        p.w.db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE id = ?").run(b.itemId);
        await p.kick();
        expect(p.row(b.sid)).toBeUndefined();
        expect(p.objects()).toEqual([]);
    });

    it("parseProbeAnswer accepts 1..3 JPEGs and an MP3 or null, nothing else", () => {
        expect(parseProbeAnswer(answer())).toMatchObject({ duration: 9.6 });
        expect(parseProbeAnswer(answer(1, false))!.audio).toBeNull();
        expect(parseProbeAnswer({ ...answer(), frames: [] })).toBeNull();
        expect(parseProbeAnswer({ ...answer(), frames: [...answer().frames, answer().frames[0]] })).toBeNull();
        expect(parseProbeAnswer({ ...answer(), audio: b64(fakeJpeg(10)) })).toBeNull();
        expect(parseProbeAnswer({ ...answer(), audio: "%%%" })).toBeNull();
        expect(parseProbeAnswer(null)).toBeNull();
        // an MP3 without an ID3 tag starts with a frame sync
        expect(parseProbeAnswer({ ...answer(), audio: b64(Uint8Array.from([0xff, 0xf3, 0x44])) })!.audio).not.toBeNull();
    });
});
