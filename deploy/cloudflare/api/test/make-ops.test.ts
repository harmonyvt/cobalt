// The make ops (APP-API-CONTRACT.md 33.8, plan T4): the chat AI's cobalt.make.*, cobalt.edits.* and cobalt.jobs.wait,
// each called through the registry's chat toolbox (zod check, then the handler), plus one whole chat reply through the
// real sandbox source. The real SQL runs on node:sqlite; the Durable Object is a fake that keeps the daily cap and the
// confirm cards for real (their handlers on a Map) and answers the studio routes from a script.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { resumeAfterJobs, type ChatModel, type CodeRunner, type ModelTurn } from "../src/chat";
import { CHAT_JOBS_TICK_MS, ChatJobsCore, handleChatJobsRoute } from "../src/chat-jobs";
import { chatKeyId } from "../src/registry/ai";
import { forCall } from "../src/registry/context";
import { chatDepsFrom } from "../src/registry/ops/chat";
import { waitJob } from "../src/registry/ops/make";
import { sandboxModule } from "../src/chat-loader-module";
import { chatTools } from "../src/chat-tools";
import { hashKey } from "../src/keys";
import { chatToolbox, opBase, REGISTRY } from "../src/registry/index";
import { dailyCap, handleChatBudgetRoute } from "../src/registry/budget";
import { handleChatPendingRoute } from "../src/registry/pending";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}` };
const THREAD = "ThReAd0123456789";
const DAY = 24 * 60 * 60 * 1000;

const SID = "SessionAAAAAAAAAAAAAAA"; // a saved video, open
const GSID = "GallerySSSSSSSSSSSSSSS"; // a gallery: video, photo, photo
const PSID = "PhotoSessionPPPPPPPPPP"; // a saved photo, open
const OLDSID = "OldSessionOOOOOOOOOOOO"; // a saved video whose session expired
const NEWSID = "ReopenedNNNNNNNNNNNNNN"; // what reopening mints
const JOB = "JobJobJobJobJobJob01";

let KEY_HASH = "";
let db: FakeD1;
let env: WorkerEnv;
let clock = 0;
let storage: Map<string, unknown>;
let doCalls: { path: string; key: string | null; body: unknown }[];
// what the studio routes answer, in order (a default when the list is empty)
let renderAnswers: { status: number; body: unknown }[];
let statusAnswers: { status: number; body: unknown }[];
let advanceReady: boolean;
let kicks: number;

const st = {
    get: async <T,>(k: string) => storage.get(k) as T | undefined,
    put: async (k: string, v: unknown) => void storage.set(k, structuredClone(v)),
    delete: async (k: string) => storage.delete(k),
};

const container = {
    async fetch(req: Request): Promise<Response> {
        const u = new URL(req.url);
        const p = u.pathname;
        if (p.startsWith("/chat/budget/")) return handleChatBudgetRoute(st, req, clock);
        if (p.startsWith("/chat/pending/")) return handleChatPendingRoute(st, req, clock);
        const text = await req.text();
        const body = text ? JSON.parse(text) : null;
        doCalls.push({ path: `${req.method} ${p}${u.search}`, key: req.headers.get("x-cobalt-key-id"), body });
        if (p === "/studio/upload/adopt") {
            db.raw
                .prepare(
                    "INSERT INTO studio_sessions (id, key_id, link, service, title, status, r2_key, content_type, bytes, created_at, expires_at) VALUES (?, ?, ?, 'upload', ?, 'saving', ?, ?, ?, ?, ?)",
                )
                .run(NEWSID, req.headers.get("x-cobalt-key-id"), `upload:${body.item_id}`, body.name, body.r2_key, body.content_type, body.bytes, clock, clock + 7 * DAY);
            return Response.json({ status: "success", id: NEWSID, url: `${WEB}/studio/${NEWSID}` }, { status: 201 });
        }
        if (/^\/studio\/[A-Za-z0-9]{22}\/advance$/.test(p)) {
            const sid = p.split("/")[2]!;
            if (advanceReady) db.raw.prepare("UPDATE studio_sessions SET status = 'ready', duration = 9.6, width = 480, height = 560 WHERE id = ?").run(sid);
            return Response.json({ status: advanceReady ? "ready" : "saving", id: sid });
        }
        if (/^\/studio\/[A-Za-z0-9]{22}\/(render|slideshow|gallery-image)$/.test(p) && req.method === "POST") {
            const a = renderAnswers.shift() ?? { status: 202, body: { status: "pending", job: JOB, queued: false, queue_ahead: null } };
            return Response.json(a.body, { status: a.status });
        }
        if (/^\/studio\/[A-Za-z0-9]{22}\/render\/[A-Za-z0-9]{20}$/.test(p)) {
            const a = statusAnswers.shift() ?? { status: 200, body: { status: "pending", job: JOB, phase: "decode", frames_done: 30, frames_total: 120 } };
            return Response.json(a.body, { status: a.status });
        }
        return Response.json({ status: "error", error: { code: "error.test.unexpected" } }, { status: 500 });
    },
};

const renderers = {
    idFromName: (n: string) => n,
    get: () => ({
        fetch: async () => {
            kicks++;
            return new Response(null, { status: 202 });
        },
    }),
};

const edge = { now: () => clock, sleep: async (ms: number) => void (clock += ms) };

// The chat's `cobalt` for one code run, as chat.ts builds it.
function toolbox() {
    const collect = { look: [], show: [] };
    const legacy = chatTools({ db, mediaBaseUrl: MEDIA, shareBaseUrl: SHARE, embed: null }, collect);
    return chatToolbox(REGISTRY, opBase(env, container, edge, REGISTRY), {
        threadId: THREAD,
        messageId: "1",
        collect,
        legacy,
        flags: { search: false },
        pending: {
            put: async (t, r) => void storage.set(`chat:pending:${t}`, r),
            take: async () => null,
            drop: async () => {},
        },
    }).tools;
}
const cobalt = (name: string, ...args: unknown[]) => toolbox()[name]!(...args) as Promise<any>;
const thrown = async (p: Promise<unknown>) => {
    try {
        await p;
    } catch (e) {
        return (e as Error).message;
    }
    throw new Error("did not throw");
};

const session = (id: string, over: Record<string, unknown> = {}) => {
    const r = { key_id: "key-1", status: "ready", r2_key: `originals/${id}.mp4`, content_type: "video/mp4", created_at: clock, expires_at: clock + 7 * DAY, item_count: null, ...over };
    db.raw
        .prepare("INSERT INTO studio_sessions (id, key_id, link, service, title, status, r2_key, content_type, bytes, duration, width, height, created_at, expires_at, item_count) VALUES (?, ?, ?, 'x', 'clip', ?, ?, ?, 4096, 9.6, 480, 560, ?, ?, ?)")
        .run(id, r.key_id, `https://x.com/s/${id}`, r.status, r.r2_key, r.content_type, r.created_at, r.expires_at, r.item_count);
};
const file = (id: string, over: Record<string, unknown> = {}) => {
    const r = {
        session_id: null,
        role: null,
        item_index: null,
        content_type: "video/mp4",
        r2_key: `originals/${id}.mp4`,
        bucket: "originals",
        kind: "private",
        source: "saved",
        url: null,
        visibility: null,
        duration: 9.6,
        width: 480,
        height: 560,
        name: `${id}.mp4`,
        link: `https://x.com/s/${id}` as string | null,
        ...over,
    };
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, role, item_index, visibility)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, 4096, ?, ?, ?, ?, ?, 'key-1', ?, ?, ?, ?)`,
        )
        .run(id, r.kind, r.source, r.bucket, r.r2_key, r.url, r.name, r.content_type, r.width, r.height, r.duration, r.link, r.session_id, clock, r.role, r.item_index, r.visibility);
};

beforeEach(async () => {
    KEY_HASH ||= await hashKey(CLIENT);
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", KEY_HASH, "0b5f2c3e", 1);
    env = {
        API_URL: `${API}/`,
        CORS_URL: WEB,
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
        EDIT_RENDERER: renderers as unknown as DurableObjectNamespace,
    };
    clock = 1_800_000_000_000;
    storage = new Map();
    doCalls = [];
    renderAnswers = [];
    statusAnswers = [];
    advanceReady = true;
    kicks = 0;
    // a saved video with its session open; a gallery (video, photo, photo); a saved photo; a video saved 8 days ago
    session(SID);
    file("VideoFile0000001", { session_id: SID, r2_key: `originals/${SID}.mp4` });
    session(GSID, { item_count: 3, r2_key: `originals/${GSID}-0.mp4` });
    file("GalleryVideo0001", { session_id: GSID, role: "item", item_index: 0, r2_key: `originals/${GSID}-0.mp4` });
    file("GalleryPhoto0001", { session_id: GSID, role: "item", item_index: 1, content_type: "image/jpeg", r2_key: `originals/${GSID}-1.jpg`, duration: null });
    file("GalleryPhoto0002", { session_id: GSID, role: "item", item_index: 2, content_type: "image/jpeg", r2_key: `originals/${GSID}-2.jpg`, duration: null });
    session(PSID, { content_type: "image/jpeg", r2_key: `originals/${PSID}.jpg` });
    file("PhotoFile0000001", { session_id: PSID, content_type: "image/jpeg", r2_key: `originals/${PSID}.jpg`, duration: null });
    session(OLDSID, { created_at: clock - 8 * DAY, expires_at: clock - DAY });
    file("OldVideo00000001", { session_id: OLDSID, r2_key: `originals/${OLDSID}.mp4` });
});

const rendersUsed = () => (storage.get(`chat:budget:${THREAD}:renders`) as { n: number } | undefined)?.n ?? 0;

describe("cobalt.make.webp", () => {
    it("renders on the file's open session: the capability route, no key, queued, one unit of the cap", async () => {
        const job = await cobalt("make.webp", "VideoFile0000001", { start: 1, end: 4.5, crop: { x: 0.1, y: 0, w: 0.5, h: 1 } });
        expect(job).toEqual({ job: `studio:${SID}:${JOB}`, status: "running", queue_ahead: null });
        expect(doCalls).toEqual([
            { path: `POST /studio/${SID}/render`, key: null, body: { start: 1, length: 3.5, width: 480, quality: "med", crop: { x: 0.1, y: 0, w: 0.5, h: 1 }, queue: true } },
        ]);
        expect(rendersUsed()).toBe(1);
    });

    it("takes a post id too, and a gallery's video item renders on the gallery's session with its index", async () => {
        await cobalt("make.webp", GSID, { start: 0, end: 2, width: 320, quality: "low" });
        expect(doCalls[0]).toMatchObject({ path: `POST /studio/${GSID}/render`, body: { start: 0, length: 2, width: 320, quality: "low", item: 0, queue: true } });
    });

    it("reopens a file whose session expired, as the chat, and renders once it is ready (no item)", async () => {
        const job = await cobalt("make.webp", "OldVideo00000001", { start: 0, end: 3 });
        expect(job.job).toBe(`studio:${NEWSID}:${JOB}`);
        expect(doCalls.map((c) => c.path)).toEqual(["POST /studio/upload/adopt", `GET /studio/${NEWSID}/advance?wait=8`, `POST /studio/${NEWSID}/render`]);
        expect(doCalls[0]).toMatchObject({ key: `chat:${THREAD}`, body: { r2_key: `originals/${OLDSID}.mp4`, queue: true } });
        expect(doCalls[2]!.body).toEqual({ start: 0, length: 3, width: 480, quality: "med", queue: true });
    });

    it("a file still opening becomes an `open:` job, and jobs.wait starts the render when it is ready", async () => {
        advanceReady = false;
        const job = await cobalt("make.webp", "OldVideo00000001", { start: 0, end: 3 });
        expect(job.status).toBe("opening");
        expect(job.job).toMatch(new RegExp(`^open:${NEWSID}:[A-Za-z0-9_-]+$`));
        // nothing started, nothing counted yet
        expect(rendersUsed()).toBe(0);
        advanceReady = true;
        statusAnswers = [{ status: 200, body: { status: "pending", job: JOB, phase: "queued", frames_done: null, frames_total: null, queue_ahead: 2 } }];
        const waited = await cobalt("jobs.wait", job.job, 0);
        expect(waited).toEqual({ job: `studio:${NEWSID}:${JOB}`, status: "running", queue_ahead: null });
        expect(doCalls.at(-1)).toMatchObject({ path: `POST /studio/${NEWSID}/render`, body: { start: 0, length: 3, queue: true } });
        expect(rendersUsed()).toBe(1);
    });

    it("checks its arguments before anything starts", async () => {
        expect(await thrown(cobalt("make.webp", "VideoFile0000001", { start: 0, end: 12 }))).toMatch(/0\.5 to 10 s/);
        expect(await thrown(cobalt("make.webp", "VideoFile0000001", { start: 0 }))).toMatch(/^cobalt\.make\.webp: end: /);
        expect(await thrown(cobalt("make.webp", "PhotoFile0000001", { start: 0, end: 2 }))).toMatch(/not a video or gif/);
        expect(await thrown(cobalt("make.webp", "Nope", { start: 0, end: 2 }))).toMatch(/no post or file with id Nope/);
        expect(doCalls).toEqual([]);
        expect(rendersUsed()).toBe(0);
    });

    it("a refused start gives its unit back and says why", async () => {
        renderAnswers = [{ status: 409, body: { status: "error", error: { code: "error.studio.not_ready" } } }];
        expect(await thrown(cobalt("make.webp", "VideoFile0000001", { start: 0, end: 2 }))).toBe("cobalt.make.webp failed: error.studio.not_ready");
        expect(rendersUsed()).toBe(0);
    });
});

describe("cobalt.make.still, slideshow and galleryImage", () => {
    it("still: a slideshow of one photo as the session's owner, 640 wide", async () => {
        await cobalt("make.still", "PhotoFile0000001", { seconds: 3 });
        expect(doCalls).toEqual([
            { path: `POST /studio/${PSID}/slideshow`, key: "key-1", body: { items: [0], seconds: [3], format: "webp", width: 640, quality: "med", queue: true } },
        ]);
    });

    it("still: a gallery's photo keeps its index", async () => {
        await cobalt("make.still", "GalleryPhoto0002");
        expect(doCalls[0]).toMatchObject({ path: `POST /studio/${GSID}/slideshow`, body: { items: [2], seconds: [2] } });
        expect(await thrown(cobalt("make.still", "VideoFile0000001"))).toMatch(/not a photo/);
    });

    it("slideshow: every item in order, photo seconds and null for videos, as the owner", async () => {
        await cobalt("make.slideshow", GSID, { seconds: 1.5, format: "webp" });
        expect(doCalls[0]).toEqual({
            path: `POST /studio/${GSID}/slideshow`,
            key: "key-1",
            body: { items: [0, 1, 2], seconds: [null, 1.5, 1.5], format: "webp", width: 480, quality: "med", queue: true },
        });
        await cobalt("make.slideshow", "GalleryPhoto0001", { items: ["GalleryPhoto0002", "GalleryVideo0001"], sound: "own" });
        expect(doCalls[1]!.body).toEqual({ items: [2, 0], seconds: [2, null], format: "mp4", sound: "own", queue: true });
        expect(rendersUsed()).toBe(2);
    });

    it("slideshow: refuses what is not a gallery, a file of another post, and an expired gallery", async () => {
        expect(await thrown(cobalt("make.slideshow", "VideoFile0000001"))).toMatch(/not a gallery/);
        expect(await thrown(cobalt("make.slideshow", GSID, { items: ["VideoFile0000001", "GalleryPhoto0001"] }))).toMatch(/not an item of this gallery/);
        db.raw.prepare("UPDATE studio_sessions SET expires_at = ? WHERE id = ?").run(clock - 1, GSID);
        expect(await thrown(cobalt("make.slideshow", GSID))).toMatch(/within 7 days/);
        expect(doCalls).toEqual([]);
    });

    it("galleryImage: the photos only, grid2 by default", async () => {
        await cobalt("make.galleryImage", GSID);
        expect(doCalls[0]).toEqual({ path: `POST /studio/${GSID}/gallery-image`, key: "key-1", body: { items: [1, 2], layout: "grid2", queue: true } });
        expect(await thrown(cobalt("make.galleryImage", GSID, { items: ["GalleryVideo0001", "GalleryPhoto0001"] }))).toMatch(/photos only/);
    });
});

describe("cobalt.make.trim and crop: one-clip edits", () => {
    it("trim: a project with one clip of the file, rendered at once, made by the chat", async () => {
        const job = await cobalt("make.trim", "VideoFile0000001", { start: 1.25, end: 6 });
        expect(job.status).toBe("queued");
        expect(job.job).toMatch(/^edit:[A-Za-z0-9]{20}$/);
        const p = db.raw.prepare("SELECT * FROM edit_projects WHERE id = ?").get(job.project_id) as any;
        expect(p).toMatchObject({ title: "VideoFile0000001 trim", key_id: `chat:${THREAD}`, canvas_w: 1080, canvas_h: 1920 });
        expect(JSON.parse(p.timeline).main).toEqual([{ fit: "fit", id: "c1", in: 1.25, item: "VideoFile0000001", muted: false, out: 6, speed: 1, volume: 1 }]);
        const r = db.raw.prepare("SELECT * FROM edit_renders WHERE id = ?").get(job.job.slice(5)) as any;
        expect(r).toMatchObject({ project_id: job.project_id, status: "queued", key_id: `chat:${THREAD}` });
        expect(kicks).toBeGreaterThan(0);
        expect(rendersUsed()).toBe(1);
    });

    it("crop: the clip carries the crop and the canvas follows the cropped shape", async () => {
        const job = await cobalt("make.crop", "VideoFile0000001", { x: 0, y: 0.25, w: 1, h: 0.5 }, { end: 4 });
        const p = db.raw.prepare("SELECT * FROM edit_projects WHERE id = ?").get(job.project_id) as any;
        expect(JSON.parse(p.timeline).main[0]).toMatchObject({ in: 0, out: 4, crop: { aspect: "free", x: 0, y: 0.25, w: 1, h: 0.5 } });
        // 480 x 280 is wider than tall
        expect([p.canvas_w, p.canvas_h]).toEqual([1920, 1080]);
    });

    it("refuses a photo, a bad range, and an editor that is off", async () => {
        expect(await thrown(cobalt("make.trim", "PhotoFile0000001", { start: 0, end: 1 }))).toMatch(/not a video or gif/);
        expect(await thrown(cobalt("make.trim", "VideoFile0000001", { start: 3, end: 2 }))).toMatch(/end must be after start/);
        expect(await thrown(cobalt("make.trim", "VideoFile0000001", { start: 0, end: 30 }))).toBe("cobalt.make.trim: the video is 9.6 s long");
        // the editor's own render check, with its code and field: the one-clip project is not kept
        db.raw.prepare("UPDATE media_items SET content_type = 'video/webm' WHERE id = 'VideoFile0000001'").run();
        expect(await thrown(cobalt("make.trim", "VideoFile0000001", { start: 0, end: 2 }))).toBe("cobalt.make.trim: error.edit.unsupported_source at main[0].item");
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM edit_projects WHERE deleted_at IS NULL").get()).toEqual({ n: 0 });
        expect(rendersUsed()).toBe(0);
        db.raw.prepare("UPDATE media_items SET content_type = 'video/mp4', duration = 9.6 WHERE id = 'VideoFile0000001'").run();
        delete env.EDIT_RENDERER;
        expect(await thrown(cobalt("make.trim", "VideoFile0000001", { start: 0, end: 2 }))).toMatch(/the editor is off/);
    });
});

describe("cobalt.edits", () => {
    const timeline = (item = "VideoFile0000001") => ({
        version: 1,
        canvas: { w: 1080, h: 1920, fps: 30 },
        main: [{ id: "a", item, in: 0, out: 3, speed: 1, fit: "fill", volume: 1, muted: false }],
        overlay: [],
    });

    it("create, update, get and list; the timeline is checked by the editor's own validator", async () => {
        const p = await cobalt("edits.create", timeline(), { title: "my edit" });
        expect(p).toMatchObject({ title: "my edit", revision: 1, duration: 3, render: null });
        const u = await cobalt("edits.update", p.id, { ...timeline(), main: [{ ...timeline().main[0], out: 5 }] });
        expect(u).toMatchObject({ id: p.id, revision: 2, duration: 5 });
        const g = await cobalt("edits.get", p.id);
        expect(g.timeline.main[0].out).toBe(5);
        expect((await cobalt("edits.list")).map((x: any) => x.id)).toEqual([p.id]);
        expect(await thrown(cobalt("edits.create", { ...timeline(), main: [] }))).toBe("cobalt.edits.create: timeline: error.edit.empty at main");
        expect(await thrown(cobalt("edits.create", { ...timeline(), canvas: { w: 1000, h: 1000, fps: 30 } }))).toBe("cobalt.edits.create: timeline: error.edit.canvas at canvas");
        // the source checks run at render
        const missing = await cobalt("edits.create", timeline("Missing000000001"));
        expect(await thrown(cobalt("edits.render", missing.id))).toBe("cobalt.edits.render: error.edit.source_missing at main[0].item");
        expect(rendersUsed()).toBe(0);
    });

    it("render: a job, counted once; the same revision again is the same render and is not counted", async () => {
        const p = await cobalt("edits.create", timeline());
        const a = await cobalt("edits.render", p.id);
        const b = await cobalt("edits.render", p.id);
        expect(b.job).toBe(a.job);
        expect(rendersUsed()).toBe(1);
    });

    it("delete asks first: nothing runs, a confirm card is stored", async () => {
        const p = await cobalt("edits.create", timeline(), { title: "keep me?" });
        const r = await cobalt("edits.delete", p.id);
        expect(r.pending_confirm).toMatchObject({ summary: 'delete the edit "keep me?"', effect: { edits: 1, clips: 1 } });
        expect(storage.get(`chat:pending:${THREAD}`)).toMatchObject({ op: "edits.delete", input: { id: p.id } });
        expect((db.raw.prepare("SELECT deleted_at FROM edit_projects WHERE id = ?").get(p.id) as any).deleted_at).toBeNull();
    });
});

describe("the daily cap", () => {
    it("CHAT_DAILY_RENDERS caps what one thread starts in a UTC day; tomorrow it starts again", async () => {
        env.CHAT_DAILY_RENDERS = "2";
        await cobalt("make.webp", "VideoFile0000001", { start: 0, end: 2 });
        await cobalt("make.still", "PhotoFile0000001");
        const msg = await thrown(cobalt("make.trim", "VideoFile0000001", { start: 0, end: 2 }));
        expect(msg).toMatch(/^cobalt\.make\.trim: this chat already made 2 files today/);
        // the trim's project is not even made
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM edit_projects").get()).toEqual({ n: 0 });
        clock += DAY;
        await cobalt("make.webp", "VideoFile0000001", { start: 0, end: 2 });
        expect(rendersUsed()).toBe(1);
    });

    it("reads the var as a whole number, else 10", () => {
        expect(dailyCap(undefined, 10)).toBe(10);
        expect(dailyCap("", 10)).toBe(10);
        expect(dailyCap("abc", 10)).toBe(10);
        expect(dailyCap("-1", 10)).toBe(10);
        expect(dailyCap("0", 10)).toBe(0);
        expect(dailyCap(" 25 ", 10)).toBe(25);
    });

    it("the cap store only answers the Worker's own key id for that thread, and never from the internet", async () => {
        const take = (key: string | null, path = `/chat/budget/${THREAD}/renders`) =>
            handleChatBudgetRoute(st, new Request(`https://do.internal${path}`, { method: "POST", headers: key ? { "x-cobalt-key-id": key } : {}, body: '{"limit":5}' }), clock);
        expect((await take(null)).status).toBe(404);
        expect((await take("key-1")).status).toBe(404);
        expect((await take(`chat:${THREAD}`, `/chat/budget/${THREAD}/Renders`)).status).toBe(404);
        expect(await (await take(`chat:${THREAD}`)).json()).toEqual({ status: "success", ok: true, used: 1 });
        const res = await handleRequest(new Request(`${API}/chat/budget/${THREAD}/renders`, { method: "POST", headers: AUTH, body: '{"limit":5}' }), env, container, { now: () => clock });
        expect(res.status).toBe(404);
        expect(rendersUsed()).toBe(1);
    });
});

describe("cobalt.jobs.wait", () => {
    it("a studio job: polls the Durable Object until done, then names the file, its post and its share link", async () => {
        file("MadeWebp00000001", { session_id: SID, bucket: "media", kind: "public", source: "studio", content_type: "image/webp", url: `${MEDIA}AbCdEfGh12.webp`, r2_key: "AbCdEfGh12.webp" });
        statusAnswers = [
            { status: 200, body: { status: "pending", job: JOB, phase: "decode", frames_done: 30, frames_total: 120 } },
            { status: 200, body: { status: "success", job: JOB, url: `${MEDIA}AbCdEfGh12.webp`, bytes: 1234, width: 480, height: 560, seconds: 3 } },
        ];
        const r = await cobalt("jobs.wait", `studio:${SID}:${JOB}`, 20);
        expect(r).toEqual({
            job: `studio:${SID}:${JOB}`,
            status: "done",
            bytes: 1234,
            width: 480,
            height: 560,
            seconds: 3,
            file_id: "MadeWebp00000001",
            post_id: SID,
            kind: "image",
            public: true,
            share_url: `${SHARE}AbCdEfGh12`,
        });
        expect(doCalls.map((c) => c.path)).toEqual([`GET /studio/${SID}/render/${JOB}?wait=10`, `GET /studio/${SID}/render/${JOB}?wait=10`]);
    });

    it("a studio job still running when the time is up: its progress", async () => {
        const r = await cobalt("jobs.wait", `studio:${SID}:${JOB}`, 0);
        expect(r).toEqual({ job: `studio:${SID}:${JOB}`, status: "running", progress: 0.25, queue_ahead: null });
        statusAnswers = [{ status: 200, body: { status: "error", error: { code: "error.webp.encode_failed" } } }];
        expect(await cobalt("jobs.wait", `studio:${SID}:${JOB}`, 0)).toEqual({ job: `studio:${SID}:${JOB}`, status: "error", error: "error.webp.encode_failed" });
    });

    it("an edit render: D1 until it is done", async () => {
        const job = await cobalt("make.trim", "VideoFile0000001", { start: 0, end: 2 });
        const rid = job.job.slice(5);
        expect(await cobalt("jobs.wait", job.job, 0)).toMatchObject({ job: job.job, status: "queued" });
        file("EditResult000001", { source: "edit", visibility: "private", link: null });
        db.raw.prepare("UPDATE edit_renders SET status = 'done', item_id = 'EditResult000001', bytes = 99, width = 1080, height = 1080, duration = 2 WHERE id = ?").run(rid);
        expect(await cobalt("jobs.wait", job.job, 5)).toEqual({
            job: job.job,
            status: "done",
            bytes: 99,
            width: 1080,
            height: 1080,
            seconds: 2,
            file_id: "EditResult000001",
            post_id: "EditResult000001",
            kind: "video",
            public: false,
            share_url: null,
        });
        db.raw.prepare("UPDATE edit_renders SET status = 'error', error_code = 'error.edit.timeout' WHERE id = ?").run(rid);
        expect(await cobalt("jobs.wait", job.job, 0)).toEqual({ job: job.job, status: "error", error: "error.edit.timeout" });
    });

    it("waits at most 25 s and refuses ids it does not know", async () => {
        expect(await thrown(cobalt("jobs.wait", `studio:${SID}:${JOB}`, 60))).toMatch(/^cobalt\.jobs\.wait: seconds: /);
        expect(await thrown(cobalt("jobs.wait", "nope"))).toBe("cobalt.jobs.wait: nope is not a job id");
        expect(await thrown(cobalt("jobs.wait", `open:${NEWSID}:!!!`))).toMatch(/is not a job id/);
        expect(await thrown(cobalt("jobs.wait", `open:${NEWSID}:${btoa('{"route":"evil","body":{}}')}`))).toMatch(/is not a job id/);
    });
});

// ---- one whole reply through the real sandbox source ----------------------------------------------------------------

const runner: CodeRunner = async (code, tools) => {
    const mod = sandboxModule(code).replace(/^import .*$/m, "").replace("export default class Run", "return class Run");
    // eslint-disable-next-line @typescript-eslint/no-implied-eval
    const Run = new Function("WorkerEntrypoint", mod)(class {});
    let calls = 0;
    const d = {
        call: async (name: string, args: string) => {
            calls++;
            const fn = Object.prototype.hasOwnProperty.call(tools, name) ? tools[name] : undefined;
            if (!fn) return JSON.stringify({ error: `cobalt.${name} does not exist` });
            try {
                return JSON.stringify({ result: (await fn(...JSON.parse(args))) ?? null });
            } catch (e) {
                return JSON.stringify({ error: e instanceof Error ? e.message : String(e) });
            }
        },
    };
    const r = await new Run().evaluate(d);
    return r.error !== undefined ? { error: r.error, logs: r.logs, calls } : { result: JSON.parse(r.result), logs: r.logs, calls };
};

describe("through the chat", () => {
    it("the model's code makes a webp and waits for it; the system prompt tells it how", async () => {
        file("MadeWebp00000001", { session_id: SID, bucket: "media", kind: "public", source: "studio", content_type: "image/webp", url: `${MEDIA}AbCdEfGh12.webp`, r2_key: "AbCdEfGh12.webp" });
        statusAnswers = [{ status: 200, body: { status: "success", job: JOB, url: `${MEDIA}AbCdEfGh12.webp`, bytes: 1, width: 480, height: 560, seconds: 2 } }];
        const seen: { system: string; messages: any[] }[] = [];
        const say = (text: string): ModelTurn => ({ content: [{ type: "text", text }], stop_reason: "end_turn" });
        const script: ((s: { system: string; messages: any[] }) => ModelTurn)[] = [
            () => ({
                content: [
                    {
                        type: "tool_use",
                        id: "tu_1",
                        name: "run_code",
                        input: { code: `const j = await cobalt.make.webp("${SID}", { start: 0, end: 2 }); return await cobalt.jobs.wait(j.job, 20);` },
                    },
                ],
                stop_reason: "tool_use",
            }),
            (s) => {
                const r = JSON.parse(s.messages[s.messages.length - 1].content[0].content[0].text);
                expect(r.result).toMatchObject({ status: "done", post_id: SID, share_url: `${SHARE}AbCdEfGh12` });
                return say("made it (=^･ω･^=)");
            },
        ];
        const model: ChatModel = {
            model: "claude-haiku-5-5",
            async turn({ system, messages, onText }) {
                seen.push({ system, messages: JSON.parse(JSON.stringify(messages)) });
                const r = script.shift()!(seen[seen.length - 1]!);
                for (const b of r.content) if (b.type === "text") onText(b.text);
                return r;
            },
            async title() {
                return null;
            },
        };
        const call = (path: string, method: string, body?: unknown) =>
            handleRequest(
                new Request(`${API}${path}`, { method, headers: { ...AUTH, "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) }),
                env,
                container,
                { now: () => clock, sleep: async () => {}, chatModel: model, codeRunner: runner },
            );
        const t = ((await (await call("/chat/threads", "POST", {})).json()) as any).thread;
        const text = await (await call(`/chat/threads/${t.id}/messages`, "POST", { text: "make a webp of the first 2 s" })).text();
        expect(text).toContain("event: done");
        expect(script).toHaveLength(0);
        expect(seen[0]!.system).toContain("Making files: cobalt.make.*");
        expect(seen[0]!.system).toContain("webp(id: string, opts: {");
        expect(doCalls[0]).toMatchObject({ path: `POST /studio/${SID}/render`, key: null, body: { start: 0, length: 2, queue: true } });
        expect((storage.get(`chat:budget:${t.id}:renders`) as any).n).toBe(1);
    });
});

// ---- the job hook: cobalt.jobs.onDone (section 33.14) ---------------------------------------------------------------

describe("cobalt.jobs.onDone: the server continues the chat when a job ends", () => {
    const mapStorage = (m: Map<string, unknown>) => ({
        get: async <T,>(k: string) => m.get(k) as T | undefined,
        put: async (k: string, v: unknown) => void m.set(k, structuredClone(v)),
        delete: async (k: string) => m.delete(k),
        list: async <T,>(o: { prefix: string }) => new Map([...m].filter(([k]) => k.startsWith(o.prefix)).sort(([a], [b]) => a.localeCompare(b, "en", { numeric: true })) as [string, T][]),
    });

    it("hands a running webp over, ends the reply, then a new reply starts with the result when the server sees it end", async () => {
        file("MadeWebp00000001", { session_id: SID, bucket: "media", kind: "public", source: "studio", content_type: "image/webp", url: `${MEDIA}AbCdEfGh12.webp`, r2_key: "AbCdEfGh12.webp" });
        const seen: { system: string; messages: any[] }[] = [];
        const say = (text: string): ModelTurn => ({ content: [{ type: "text", text }], stop_reason: "end_turn" });
        const code = (id: string, src: string): ModelTurn => ({ content: [{ type: "tool_use", id, name: "run_code", input: { code: src } }], stop_reason: "tool_use" });
        const lastResult = (s: { messages: any[] }) => s.messages[s.messages.length - 1].content[0];
        const script: ((s: { system: string; messages: any[] }) => ModelTurn)[] = [
            () => code("tu_1", `const j = await cobalt.make.webp("${SID}", { start: 0, end: 2 }); return await cobalt.jobs.onDone(j.job, "show it and give the link");`),
            (s) => {
                const r = JSON.parse(lastResult(s).content[0].text);
                expect(r.result).toMatchObject({ job: `studio:${SID}:${JOB}`, status: "running", watching: true });
                expect(r.note).toMatch(/server is watching that job/);
                // a model that tries to poll anyway is refused
                return code("tu_2", `return await cobalt.jobs.wait("studio:${SID}:${JOB}", 25);`);
            },
            (s) => {
                expect(lastResult(s)).toMatchObject({ is_error: true, content: expect.stringMatching(/server continues this chat/) });
                return say("on its way (=^･ω･^=)");
            },
            // the continuation, started by the server
            (s) => {
                const opening = s.messages[s.messages.length - 1];
                expect(opening.role).toBe("user");
                const text = JSON.stringify(opening.content);
                expect(text).toContain("cobalt.jobs.onDone has ended");
                expect(text).toContain(`${SHARE}AbCdEfGh12`);
                expect(text).toContain("your note: show it and give the link");
                return code("tu_3", `await cobalt.show(["${SID}"]); return 1;`);
            },
            () => say("here it is ฅ^•ﻌ•^ฅ"),
        ];
        const model: ChatModel = {
            model: "claude-haiku-5-5",
            async turn({ system, messages, onText }) {
                seen.push({ system, messages: JSON.parse(JSON.stringify(messages)) });
                const r = script.shift()!(seen[seen.length - 1]!);
                for (const b of r.content) if (b.type === "text") onText(b.text);
                return r;
            },
            async title() {
                return null;
            },
        };
        const edgeDeps = { now: () => clock, sleep: async (ms: number) => void (clock += ms), chatModel: model, codeRunner: runner };

        // the thread's ChatJobs object: its rules for real on a Map; the job is looked at like jobs.wait, the chat resumed
        // with the route's own deps
        const jobsStore = new Map<string, unknown>();
        let alarmIn: number | null = null;
        const base = opBase(env, container, edgeDeps, REGISTRY);
        const core = new ChatJobsCore({
            storage: mapStorage(jobsStore),
            now: () => clock,
            setAlarm: async (ms) => void (alarmIn = ms),
            check: (thread, job) => waitJob(forCall(base, { keyId: chatKeyId(thread), caller: "chat", chat: { threadId: thread, collect: { look: [], show: [], collage: null }, tools: {} } }), job, 0),
            resume: (thread, ended) => resumeAfterJobs(chatDepsFrom(base)!, thread, ended),
        });
        env.CHAT_JOBS = {
            idFromName: (n: string) => n,
            get: () => ({ fetch: (r: Request) => handleChatJobsRoute(core, r, INTERNAL) }),
        } as unknown as DurableObjectNamespace;

        const call = (path: string, method: string, body?: unknown) =>
            handleRequest(
                new Request(`${API}${path}`, { method, headers: { ...AUTH, "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) }),
                env,
                container,
                edgeDeps,
            );
        const t = ((await (await call("/chat/threads", "POST", {})).json()) as any).thread;
        const text = await (await call(`/chat/threads/${t.id}/messages`, "POST", { text: "make a webp of the first 2 s" })).text();
        expect(text).toContain("event: done");
        expect(seen[0]!.system).toContain("cobalt.jobs.onDone(job, note)");
        expect(seen[0]!.system).toContain("Never poll");
        expect(seen[0]!.system).toContain("onDone(job: string, note?: string)");
        expect(alarmIn).toBe(CHAT_JOBS_TICK_MS);
        expect(await core.list()).toMatchObject([{ job: `studio:${SID}:${JOB}`, thread: t.id, note: "show it and give the link", message_id: expect.stringMatching(/^\d+$/) }]);

        // the reply ends with a waiting "job" step
        let thread = (await (await call(`/chat/threads/${t.id}`, "GET")).json()) as any;
        expect(thread.messages).toHaveLength(2);
        const jobStep = thread.messages[1].steps.find((s: any) => s.kind === "job");
        expect(jobStep).toMatchObject({ status: "running", job: { job: `studio:${SID}:${JOB}`, note: "show it and give the link", status: "waiting" } });

        // a tick while it still runs: nothing happens, the watch stays
        alarmIn = null;
        await core.tick();
        expect(await core.list()).toHaveLength(1);
        expect(alarmIn).toBe(CHAT_JOBS_TICK_MS);

        // the render finishes: the next tick continues the chat by itself
        statusAnswers = [{ status: 200, body: { status: "success", job: JOB, url: `${MEDIA}AbCdEfGh12.webp`, bytes: 1, width: 480, height: 560, seconds: 2 } }];
        alarmIn = null;
        await core.tick();
        expect(script).toHaveLength(0);
        expect(await core.list()).toHaveLength(0);
        expect([...jobsStore.keys()].filter((k) => k.startsWith("ended:"))).toEqual([]);
        expect(alarmIn).toBeNull();

        thread = (await (await call(`/chat/threads/${t.id}`, "GET")).json()) as any;
        expect(thread.messages).toHaveLength(3);
        expect(thread.messages[1].steps.find((s: any) => s.kind === "job")).toMatchObject({ status: "done", job: { status: "done" } });
        expect(thread.messages[2]).toMatchObject({ role: "assistant", status: "done", text: "here it is ฅ^•ﻌ•^ฅ", post_ids: [SID] });
        expect(thread.posts[SID]).toBeDefined();
    });

    it("a job that ends within a few seconds answers at once, with no watch", async () => {
        statusAnswers = [{ status: 200, body: { status: "error", error: { code: "error.webp.encode_failed" } } }];
        const watched: unknown[] = [];
        const collect = { look: [], show: [] };
        const legacy = chatTools({ db, mediaBaseUrl: MEDIA, shareBaseUrl: SHARE, embed: null }, collect);
        const box = chatToolbox(REGISTRY, opBase(env, container, edge, REGISTRY), {
            threadId: THREAD,
            messageId: "1",
            collect,
            legacy,
            flags: { search: false },
            pending: null,
            jobs: { watch: async (_t, w) => void watched.push(w) },
        });
        expect(await box.tools["jobs.onDone"]!(`studio:${SID}:${JOB}`)).toEqual({ job: `studio:${SID}:${JOB}`, status: "error", error: "error.webp.encode_failed" });
        expect(watched).toEqual([]);
        expect(box.waiting()).toEqual([]);
        // still running after the first wait: handed over
        expect(await box.tools["jobs.onDone"]!(`studio:${SID}:${JOB}`, "show it")).toMatchObject({ status: "running", watching: true });
        expect(watched).toEqual([{ job: `studio:${SID}:${JOB}`, message_id: "1", note: "show it" }]);
        expect(box.waiting()).toEqual([{ job: `studio:${SID}:${JOB}`, note: "show it" }]);
    });

    it("without the hook (no CHAT_JOBS) it only looks", async () => {
        const r = await cobalt("jobs.onDone", `studio:${SID}:${JOB}`);
        expect(r).toMatchObject({ job: `studio:${SID}:${JOB}`, status: "running" });
        expect(r.watching).toBeUndefined();
        expect(await thrown(cobalt("jobs.onDone", "nope"))).toMatch(/is not a job id/);
    });
});

describe("a hidden post (section 37.2)", () => {
    const hide = (postKey: string) => db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES (?, 'hidden', 'you', NULL, 1)").run(postKey);

    it("every make of it is refused before anything starts, with the unhide hint, and no unit is taken", async () => {
        hide(SID);
        hide(GSID);
        hide(PSID);
        for (const [call, ...args] of [
            ["make.webp", "VideoFile0000001", { start: 0, end: 2 }],
            ["make.webp", GSID, { start: 0, end: 2 }],
            ["make.still", "PhotoFile0000001", { seconds: 3 }],
            ["make.slideshow", GSID],
            ["make.galleryImage", GSID],
            ["make.trim", "VideoFile0000001", { start: 0, end: 2 }],
        ] as [string, ...unknown[]][]) {
            const msg = await thrown(cobalt(call, ...args));
            expect(msg, call).toMatch(/hidden; unhide it first with library\.status/);
        }
        expect(doCalls).toEqual([]);
        expect(rendersUsed()).toBe(0);
    });

    it("edits.render refuses a project with a clip of a hidden post (the route answers 409 with the file ids)", async () => {
        const p = await cobalt("edits.create", {
            version: 1,
            canvas: { w: 1080, h: 1920, fps: 30 },
            main: [{ id: "a", item: "VideoFile0000001", in: 0, out: 3, speed: 1, fit: "fill", volume: 1, muted: false }],
            overlay: [],
        });
        hide(SID);
        expect(await thrown(cobalt("edits.render", p.id))).toMatch(/^cobalt\.edits\.render: VideoFile0000001: it's hidden; unhide it first with library\.status$/);
        expect(rendersUsed()).toBe(0);
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM edit_renders").get()).toEqual({ n: 0 });
        const r = await handleRequest(
            new Request(`${API}/edits/${p.id}/render`, { method: "POST", headers: { authorization: `Api-Key ${CLIENT}`, "content-type": "application/json" }, body: JSON.stringify({ revision: 1 }) }),
            env,
            { fetch: async () => new Response(null, { status: 500 }) } as any,
            { now: () => clock, sleep: async () => {} } as any,
        );
        expect(r.status).toBe(409);
        expect(await r.json()).toEqual({ status: "error", error: { code: "error.hidden" }, ids: ["VideoFile0000001"] });
    });
});
