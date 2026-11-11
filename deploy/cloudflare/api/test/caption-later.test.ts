// A gallery link's caption no longer holds the route that makes the link (APP-API-CONTRACT.md sections 24, 25, 26.1,
// 41): with a waitUntil the route answers first and the model is asked behind it, and the link's page waits for a
// caption that is on its way instead of answering without it (or asking the model a second time). Without a
// waitUntil the route waits as it always did: test/roast.test.ts and test/share-collections.test.ts hold that.
import { beforeEach, describe, expect, it } from "vitest";
import type { FakeD1 } from "../../test-support/d1-sqlite";
import { timedDb } from "../src/d1-timing";
import { hashKey } from "../src/keys";
import type { Caption, Captioner } from "../src/roast";
import { sharePage } from "../src/share";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { createBatchD1 } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const API = "https://api.capybaraharmony.com";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}`, "content-type": "application/json" };
const DISCORD = { "user-agent": "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)" };

let KEY_HASH = "";
let db: FakeD1;
let env: WorkerEnv;
let a = "";
let b = "";
let c = "";
// what the Worker's waitUntil was given
let later: Promise<unknown>[];
// a model that answers only when told to
let model: Captioner & { asked: number; answer(title?: string): void; fail(): void };

const container = { fetch: async () => new Response("{}", { headers: { "content-type": "application/json" } }) };

let n = 0;
const file = (over: Record<string, unknown>): string => {
    n++;
    const r = {
        id: `Item${String(n).padStart(12, "0")}`,
        kind: "private",
        source: "saved",
        bucket: "originals",
        r2_key: `originals/sess${n}.mp4`,
        url: null,
        name: `clip${n}.mp4`,
        content_type: "video/mp4",
        bytes: 4096,
        width: 480,
        height: 560,
        duration: 9.6,
        link: `https://x.com/someone/status/${n}`,
        session_id: null,
        key_id: "k",
        created_at: 1_000 + n,
        deleted_at: null,
        poster: null,
        visibility: "public",
        public_key: `PuBlIc${String(n).padStart(4, "0")}.mp4`,
        public_id: null,
        post_key: null,
        ...over,
    };
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at, poster, visibility, public_key, public_id, post_key)
             VALUES (@id,@kind,@source,@bucket,@r2_key,@url,@name,@content_type,@bytes,@width,@height,@duration,@link,@session_id,@key_id,@created_at,@deleted_at,@poster,@visibility,@public_key,@public_id,@post_key)`,
        )
        .run(r as any);
    return r.id;
};

const meta = (html: string, key: string): string | null => {
    const m = new RegExp(`<meta (?:property|name)="${key.replace(/[:.]/g, "\\$&")}" content="([^"]*)">`).exec(html);
    return m ? m[1]! : null;
};
const captionRow = (id: string) => db.raw.prepare("SELECT title, attempts FROM media_captions WHERE subject = ?").get(`set:${id}`) as { title: string | null; attempts: number } | undefined;
const pause = (ms: number) => new Promise((r) => setTimeout(r, ms));
// "answered" with the value, or "waiting" when `p` has not settled after `ms`
const within = async <T>(p: Promise<T>, ms: number): Promise<T | "waiting"> => Promise.race([p, pause(ms).then(() => "waiting" as const)]);

// the Worker as it runs in production: the real clock, and a waitUntil
const call = (url: string, init: RequestInit = {}, e: WorkerEnv = env) =>
    handleRequest(new Request(url, init), e, container, { now: () => Date.now(), captioner: model, waitUntil: (p) => void later.push(p) });
const create = (body: unknown) => call(`${API}/share/sets`, { method: "POST", headers: AUTH, body: JSON.stringify(body) });

beforeEach(async () => {
    KEY_HASH ||= await hashKey(CLIENT);
    db = createBatchD1();
    env = {
        API_URL: "https://api.capybaraharmony.com/",
        CORS_URL: "https://cobalt.capybaraharmony.com",
        COBALT_API_KEY: "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e",
        DB: db,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
    };
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", KEY_HASH, "0b5f2c3e", 1);
    [a, b, c] = [file({}), file({}), file({})];
    later = [];
    const waiting: { resolve(c: Caption): void; reject(e: Error): void }[] = [];
    model = {
        model: "fake-haiku",
        asked: 0,
        caption() {
            model.asked++;
            return new Promise<Caption>((resolve, reject) => waiting.push({ resolve, reject }));
        },
        answer: (title = "three sleepy clips (=^･ω･^=)") => waiting.splice(0).forEach((w) => w.resolve({ title, description: "" })),
        fail: () => waiting.splice(0).forEach((w) => w.reject(new Error("overloaded"))),
    };
});

describe("making a link", () => {
    it("answers before the model does, with the same body, and the caption still lands", async () => {
        const res = await within(create({ items: [a, b] }), 1500);
        if (res === "waiting") throw new Error("the route waited for the model");
        expect(res.status).toBe(201);
        const set = ((await res.json()) as any).set;
        // the body never carried the caption: `title` is the typed title, null here
        expect(Object.keys(set).sort()).toEqual(["created_at", "id", "items", "link", "private", "public_url", "title", "url"]);
        expect(set.title).toBeNull();
        // the model was asked, once, and has not answered: nothing is stored yet
        expect([model.asked, later.length, captionRow(set.id)]).toEqual([1, 1, undefined]);
        model.answer();
        await Promise.all(later);
        expect(captionRow(set.id)).toEqual({ title: "three sleepy clips (=^･ω･^=)", attempts: 1 });
    });

    it("a model that fails after the answer is recorded for the cron, and fails nothing", async () => {
        const res = await create({ items: [a, b] });
        const id = ((await res.json()) as any).set.id;
        model.fail();
        await Promise.all(later);
        expect(captionRow(id)).toEqual({ title: null, attempts: 1 });
    });
});

describe("the link's page", () => {
    it("waits for the caption that is on its way and never asks the model itself", async () => {
        const id = ((await (await create({ items: [a, b] })).json()) as any).set.id;
        // Discord opens the link while the model is still writing
        const page = call(`${SHARE}g/${id}`, { headers: DISCORD });
        expect(await within(page, 300)).toBe("waiting");
        model.answer();
        await Promise.all(later);
        const html = await (await page).text();
        expect(meta(html, "og:title")).toBe("three sleepy clips (=^･ω･^=)");
        expect(html).toContain("**three sleepy clips (=^･ω･^=)**");
        expect(model.asked).toBe(1);
    });

    it("of a private link waits the same way", async () => {
        const set = ((await (await create({ items: [a, b], private: true })).json()) as any).set;
        expect(set.private).toBe(true);
        const page = call(set.url);
        expect(await within(page, 300)).toBe("waiting");
        model.answer();
        expect(meta(await (await page).text(), "og:title")).toBe("three sleepy clips (=^･ω･^=)");
        expect(model.asked).toBe(1);
    });

    it("stops waiting once the failure is recorded", async () => {
        const id = ((await (await create({ items: [a, b] })).json()) as any).set.id;
        const page = call(`${SHARE}g/${id}`);
        expect(await within(page, 300)).toBe("waiting");
        model.fail();
        const res = await within(page, 1500);
        if (res === "waiting") throw new Error("the page kept waiting after the failure was recorded");
        expect(meta(await res.text(), "og:title")).toBe("2 files");
        expect(model.asked).toBe(1);
    });

    it("answers without a caption when the wait is over, and the next view has it", async () => {
        const id = ((await (await create({ items: [a, b] })).json()) as any).set.id;
        // the share host with a short wait (the Worker's is CAPTION_WAIT_MS, 6 s from when the link was made)
        const view = () => sharePage({ db, mediaBaseUrl: MEDIA, shareBaseUrl: SHARE, captioner: model, captionWaitMs: 500 }, new Request(`${SHARE}g/${id}`));
        const start = Date.now();
        expect(meta(await (await view()).text(), "og:title")).toBe("2 files");
        const took = Date.now() - start;
        expect(took).toBeGreaterThanOrEqual(300);
        expect(took).toBeLessThan(3000);
        model.answer();
        await Promise.all(later);
        expect(meta(await (await view()).text(), "og:title")).toBe("three sleepy clips (=^･ω･^=)");
        expect(model.asked).toBe(1);
    });

    it("waits for nothing when no caption is on its way: a typed title, an older link, captions off", async () => {
        const { db: counted, stats } = timedDb(db);
        const timed: WorkerEnv = { ...env, DB: counted };
        const trips = async (run: () => Promise<Response>) => {
            const before = stats.n;
            const res = await run();
            return [stats.n - before, meta(await res.text(), "og:title")];
        };
        const titled = ((await (await create({ items: [a, b], title: "trip" })).json()) as any).set.id;
        const fresh = ((await (await create({ items: [a, b] })).json()) as any).set.id;
        const old = ((await (await create({ items: [a, c] })).json()) as any).set.id;
        db.raw.prepare("UPDATE share_sets SET created_at = created_at - 60000 WHERE id = ?").run(old);
        // the model never answers in this test: any wait would show as more round trips, one for every look
        await call(`${SHARE}g/${titled}`, {}, timed); // (the first view of a database also asks whether posts can be hidden)
        const [plain, title] = await trips(() => call(`${SHARE}g/${titled}`, {}, timed));
        expect(title).toBe("trip");
        expect(await trips(() => call(`${SHARE}g/${old}`, {}, timed))).toEqual([plain, "2 files"]);
        // captions off on the share host: nothing is on its way
        expect(await trips(() => sharePage({ db: counted, mediaBaseUrl: MEDIA, shareBaseUrl: SHARE, captioner: null, loops: false }, new Request(`${SHARE}g/${fresh}`)))).toEqual([plain, "2 files"]);
        expect(model.asked).toBe(3);
    });
});

describe("changing and rerolling", () => {
    it("PATCH with new files answers before the model does; the new caption lands behind it", async () => {
        const id = ((await (await create({ items: [a, b] })).json()) as any).set.id;
        model.answer("two clips :3");
        await Promise.all(later);
        later = [];
        const res = await within(call(`${API}/share/sets/${id}`, { method: "PATCH", headers: AUTH, body: JSON.stringify({ items: [b, a, c] }) }), 1500);
        if (res === "waiting") throw new Error("the route waited for the model");
        expect(res.status).toBe(200);
        expect(((await res.json()) as any).set.items.map((i: any) => i.id)).toEqual([b, a, c]);
        // the caption of the old files shows until the new one is written
        expect([model.asked, later.length, captionRow(id)?.title]).toEqual([2, 1, "two clips :3"]);
        model.answer("three clips now >w<");
        await Promise.all(later);
        expect(captionRow(id)).toEqual({ title: "three clips now >w<", attempts: 2 });
        // a title alone asks the model nothing
        later = [];
        expect((await call(`${API}/share/sets/${id}`, { method: "PATCH", headers: AUTH, body: JSON.stringify({ title: "typed" }) })).status).toBe(200);
        expect([model.asked, later.length]).toEqual([2, 0]);
    });

    it("a reroll answers before its captions are written, and each new link gets one", async () => {
        const one = ((await (await create({ items: [a, b] })).json()) as any).set.id;
        const two = ((await (await create({ items: [b, c] })).json()) as any).set.id;
        model.answer();
        await Promise.all(later);
        const col = ((await (await call(`${API}/share/collections`, { method: "POST", headers: AUTH, body: JSON.stringify({ name: "picks", set_ids: [one, two] }) })).json()) as any).collection.id;
        later = [];
        const res = await within(call(`${API}/share/collections/${col}/reroll`, { method: "POST", headers: AUTH }), 1500);
        if (res === "waiting") throw new Error("the route waited for the model");
        expect(res.status).toBe(200);
        const body = (await res.json()) as any;
        const fresh = [body.replaced[one], body.replaced[two]];
        expect(body.collection.set_ids).toEqual(fresh);
        expect(later).toHaveLength(1);
        expect(fresh.map((id) => captionRow(id))).toEqual([undefined, undefined]);
        // the model is asked once the new links' files are read, behind the answer
        while (model.asked < 4) await pause(5);
        model.answer("rerolled (≧▽≦)");
        await Promise.all(later);
        expect(fresh.map((id) => captionRow(id)?.title)).toEqual(["rerolled (≧▽≦)", "rerolled (≧▽≦)"]);
        expect(model.asked).toBe(4);
    });
});
