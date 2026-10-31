// Chat videos (APP-API-CONTRACT.md section 45): the body, the frozen spec, the queue, and a 'chat' render through the
// step machine (inputs, the chat start body, a missing poster skipped, the library row).
import { beforeEach, describe, expect, it } from "vitest";
import { buildChatSpec, parseChatVideoOptions, pickMessages, queueChatVideo, type FileRow, type ThreadRead } from "../src/chat-video";
import { KEY_ID, MEDIA_BASE, coreWorld, ids, world, type CoreWorld } from "./edits-world";

const OPTS = { shape: "portrait", theme: "dark", speed: 1, from: null, to: null, notify: false } as const;

describe("the body (45.1)", () => {
    it("defaults, and every bad key or value is named", () => {
        expect(parseChatVideoOptions(undefined)).toEqual({ ok: true, options: OPTS });
        expect(parseChatVideoOptions({ shape: "square", theme: "light", speed: 1.5, from: "3", to: "9", notify: true })).toEqual({
            ok: true,
            options: { shape: "square", theme: "light", speed: 1.5, from: "3", to: "9", notify: true },
        });
        expect(parseChatVideoOptions({ shape: "tall" })).toEqual({ ok: false, path: "shape" });
        expect(parseChatVideoOptions({ theme: "pink" })).toEqual({ ok: false, path: "theme" });
        expect(parseChatVideoOptions({ speed: 3 })).toEqual({ ok: false, path: "speed" });
        expect(parseChatVideoOptions({ speed: "1" })).toEqual({ ok: false, path: "speed" });
        expect(parseChatVideoOptions({ from: "x1" })).toEqual({ ok: false, path: "from" });
        expect(parseChatVideoOptions({ notify: 1 })).toEqual({ ok: false, path: "notify" });
        expect(parseChatVideoOptions({ fps: 60 })).toEqual({ ok: false, path: "fps" });
        expect(parseChatVideoOptions([])).toEqual({ ok: false, path: "" });
    });
});

const POSTER = (name: string) => `${MEDIA_BASE}${name}.jpg`;
const step = (calls: any[]) => ({ id: "toolu_1", kind: "code", status: "done", duration_ms: 500, calls });
const searchCall = (hits: string[]) => ({ op: "library.search", ms: 100, status: "done", card: { type: "search", query: "q", within: null, total: hits.length, hits: hits.map((h) => ({ post_id: h, score: 0.5 })) } });
function read(): ThreadRead {
    return {
        thread: { id: "ThreadAAAAAAAAAA", title: "shrek clips" },
        messages: [
            { id: "1", role: "user", text: "find shrek", status: "done", post_ids: [], steps: [] },
            { id: "2", role: "assistant", text: "found him", status: "done", post_ids: ["PostV", "PostP"], steps: [step([searchCall(["PostV", "PostQ"])])] },
            { id: "3", role: "user", text: "thanks", status: "done", post_ids: [], steps: [] },
        ],
        posts: {
            PostV: { id: "PostV", title: "clip", custom_title: "So no costume?", kind: "video", poster_url: POSTER("PosterVVVV"), files: [{ id: ids.a, role: null, content_type: "video/mp4", width: 720, height: 1280, duration: 13 }] },
            PostP: { id: "PostP", title: "pic", kind: "photo", poster_url: null, files: [{ id: ids.photo, role: "item", content_type: "image/jpeg", width: 3024, height: 4032, duration: null }] },
            PostQ: { id: "PostQ", title: "other", kind: "video", poster_url: POSTER("PosterQQQQ"), files: [{ id: ids.b, role: null, content_type: "video/mp4", width: 1920, height: 1080, duration: 6 }] },
        },
    };
}
const rows = new Map<string, FileRow>([
    [ids.a, { id: ids.a, bucket: "originals", r2_key: `originals/${ids.a}.bin`, bytes: 1500, content_type: "video/mp4", deleted_at: null }],
    [ids.b, { id: ids.b, bucket: "originals", r2_key: `originals/${ids.b}.bin`, bytes: 2500, content_type: "video/mp4", deleted_at: null }],
    [ids.photo, { id: ids.photo, bucket: "originals", r2_key: `originals/${ids.photo}.bin`, bytes: 800, content_type: "image/jpeg", deleted_at: null }],
]);

describe("the frozen spec (45.4)", () => {
    it("names every file by its input: the shown video's bytes, posters from cobalt-media, a picture as its own poster", () => {
        const r = read();
        const { spec, seconds, inputBytes } = buildChatSpec(r, r.messages, rows, OPTS, MEDIA_BASE);
        expect(spec.kind).toBe("chat");
        expect(spec.thread_id).toBe("ThreadAAAAAAAAAA");
        expect(spec.inputs).toEqual([
            { n: 0, item: ids.a, bucket: "originals", key: `originals/${ids.a}.bin`, bytes: 1500, kind: "video" },
            { n: 1, item: ids.a, bucket: "media", key: "PosterVVVV.jpg", bytes: 0, kind: "photo" },
            { n: 2, item: ids.photo, bucket: "originals", key: `originals/${ids.photo}.bin`, bytes: 800, kind: "photo" },
            { n: 3, item: ids.b, bucket: "media", key: "PosterQQQQ.jpg", bytes: 0, kind: "photo" },
        ]);
        const posts = spec.snapshot.posts as any;
        expect(posts.PostV).toEqual({ id: "PostV", title: "So no costume?", kind: "video", poster: "1", files: [{ kind: "video", url: "0", width: 720, height: 1280, duration: 13 }] });
        expect(posts.PostP.poster).toBe("2");
        expect(posts.PostP.files[0].url).toBe("2");
        // a card thumbnail only: its poster, never its bytes
        expect(posts.PostQ.poster).toBe("3");
        expect(posts.PostQ.files[0].url).toBeNull();
        expect(inputBytes).toBe(2300);
        expect(seconds).toBeGreaterThan(13);
        expect(seconds).toBeLessThan(40);
        const m = (spec.snapshot.messages as any[])[1];
        expect(m.steps[0]).toEqual({ id: "toolu_1", kind: "code", status: "done", duration_ms: 500, calls: [searchCall(["PostV", "PostQ"])] });
        expect(JSON.stringify(spec)).not.toMatch(/"(code|logs|result)":/);
    });

    it("a deleted file or a poster on another host is left blank; posts outside the range are not used", () => {
        const r = read();
        r.posts.PostQ.poster_url = "https://elsewhere.example/x.jpg";
        const gone = new Map(rows);
        gone.set(ids.a, { ...rows.get(ids.a)!, deleted_at: 5 });
        const { spec } = buildChatSpec(r, r.messages, gone, OPTS, MEDIA_BASE);
        const posts = spec.snapshot.posts as any;
        expect(posts.PostV.files[0].url).toBeNull();
        expect(posts.PostQ.poster).toBeNull();
        const only = pickMessages(r.messages, "3", null)!;
        expect(only.map((x) => x.id)).toEqual(["3"]);
        expect(buildChatSpec(r, only, rows, OPTS, MEDIA_BASE).spec.inputs).toEqual([]);
        expect(pickMessages(r.messages, "9", null)).toBeNull();
        expect(pickMessages(r.messages, "1", "2")!.map((x) => x.id)).toEqual(["1", "2"]);
    });
});

describe("queueing (45.1, 45.3)", () => {
    it("inserts a 'chat' render and kicks both renderers; the render shape says kind and thread", async () => {
        const w = world();
        await w.addKey();
        w.seedLibrary();
        const d = { db: w.db, mediaBaseUrl: MEDIA_BASE, now: w.clock.now, keyId: KEY_ID, kick: async () => void (kicks += 1) };
        let kicks = 0;
        const r = await queueChatVideo(d, { status: 200, body: read() as any }, { ...OPTS, notify: true });
        expect(r.status).toBe(202);
        const render = (r.body as any).render;
        expect(render).toMatchObject({ kind: "chat", thread_id: "ThreadAAAAAAAAAA", project_id: "chat:ThreadAAAAAAAAAA", revision: 0, title: "shrek clips", status: "queued", queue_ahead: 0 });
        expect(kicks).toBe(1);
        const row = w.db.raw.prepare("SELECT * FROM edit_renders WHERE id = ?").get(render.id) as any;
        expect(row).toMatchObject({ kind: "chat", thread_id: "ThreadAAAAAAAAAA", notify: 1, key_id: KEY_ID, input_bytes: 2300 });
        expect(JSON.parse(row.timeline).kind).toBe("chat");
    });

    it("refuses a running reply, an empty range, a bad from, and passes a 404 through", async () => {
        const w = world();
        const d = { db: w.db, mediaBaseUrl: MEDIA_BASE, now: w.clock.now, keyId: KEY_ID, kick: async () => {} };
        const running = read();
        running.messages.push({ id: "4", role: "assistant", text: "", status: "running", post_ids: [], steps: [] });
        expect((await queueChatVideo(d, { status: 200, body: running as any }, OPTS)).body).toMatchObject({ error: { code: "error.chat.busy" } });
        // the chat asking about its own thread leaves its running reply out
        expect((await queueChatVideo(d, { status: 200, body: structuredClone(running) as any }, OPTS, true)).status).toBe(202);
        const empty = read();
        empty.messages = [{ id: "1", role: "system", text: "", status: "done", post_ids: [], steps: [] }] as any;
        expect((await queueChatVideo(d, { status: 200, body: empty as any }, OPTS)).body).toMatchObject({ error: { code: "error.chat.video.empty" } });
        expect(await queueChatVideo(d, { status: 200, body: read() as any }, { ...OPTS, from: "77" })).toMatchObject({ status: 400, body: { path: "from" } });
        const nf = { status: 404, body: { status: "error", error: { code: "error.chat.not_found" } } };
        expect(await queueChatVideo(d, nf, OPTS)).toBe(nf);
    });

    it("the route answers 404 error.chat.off while chat is off", async () => {
        const w = world();
        await w.addKey();
        const r = await w.api("POST", "/chat/threads/ThreadAAAAAAAAAA/video", {});
        expect(r.status).toBe(404);
        expect(r.json.error.code).toBe("error.chat.off");
    });
});

describe("a 'chat' render through the step machine", () => {
    let cw: CoreWorld;
    beforeEach(async () => {
        cw = coreWorld();
        await cw.addKey();
        cw.seedLibrary();
        cw.clock.t += 1000;
    });

    it("streams the inputs, skips one that is gone, starts with {chat, inputs}, files the mp4 as a chat video", async () => {
        const r = read();
        const { spec } = buildChatSpec(r, r.messages, rows, OPTS, MEDIA_BASE);
        // the video and the picture exist (seedLibrary); the two posters in cobalt-media do not
        const id = cw.queueRender({ kind: "chat", thread_id: "ThreadAAAAAAAAAA", project_id: "chat:ThreadAAAAAAAAAA", revision: 0, title: "shrek clips", timeline: spec, seconds_total: 20 });
        const core = cw.makeCore("r0");
        await cw.run(core);
        expect(cw.row(id)).toMatchObject({ status: "done", error_code: null });
        const started = [...cw.container.renders.values()][0]?.started ?? null;
        // the render's state is deleted at cleanup: read what the container saw through its call log instead
        expect(cw.container.calls.filter((c) => c.startsWith("PUT"))).toEqual(["PUT /renders/<rid>/inputs/0", "PUT /renders/<rid>/inputs/2"]);
        expect(started).toBeNull();
        const made = cw.db.raw.prepare("SELECT * FROM media_items WHERE source = 'studio'").get() as any;
        expect(JSON.parse(made.made_spec)).toEqual({ kind: "chat", thread: "ThreadAAAAAAAAAA", render: id });
        expect(JSON.parse(made.made_from)).toEqual([ids.a, ids.photo, ids.b]);
        expect(made.name).toBe("shrek clips.mp4");
    });

    it("the start body carries the snapshot and options, and only the inputs that arrived", async () => {
        const r = read();
        const { spec } = buildChatSpec(r, r.messages, rows, { ...OPTS, shape: "square", theme: "light", speed: 1.5 }, MEDIA_BASE);
        const id = cw.queueRender({ kind: "chat", thread_id: "ThreadAAAAAAAAAA", project_id: "chat:ThreadAAAAAAAAAA", revision: 0, title: "shrek clips", timeline: spec });
        let body: any = null;
        cw.container.onCall = (m, p) => {
            if (m === "POST" && p.endsWith("/start")) body = "seen";
        };
        const core = cw.makeCore("r0");
        // stop once the render is running to read the container's state before cleanup
        for (let i = 0; i < 20 && cw.row(id).status !== "rendering"; i++) {
            await core.tick();
            cw.clock.t += 5000;
        }
        expect(body).toBe("seen");
        const st = cw.container.renders.get(id)!;
        expect(st.started).toEqual({
            chat: { snapshot: spec.snapshot, options: { shape: "square", theme: "light", speed: 1.5 } },
            inputs: [
                { n: 0, item: ids.a, kind: "video" },
                { n: 2, item: ids.photo, kind: "photo" },
            ],
        });
    });
});
