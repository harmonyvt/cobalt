// Roast captions (APP-API-CONTRACT.md section 25): one AI title and description per public file and
// gallery link, stored in D1 and shown in the previews. A fake captioner stands in for Claude Haiku;
// the real SQL runs on node:sqlite.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { backfillCaptions, captionerFrom, parseCaption, ROAST_MAX_ATTEMPTS, ROAST_RETRY_MS, type Captioner, type RoastInput } from "../src/roast";
import { setRoastInput } from "../src/share-sets";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";

const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}` };
let KEY_HASH = "";
let db: FakeD1;
let containerCalls: string[];
let env: WorkerEnv;

const container = {
    async fetch(r: Request) {
        containerCalls.push(new URL(r.url).pathname);
        return new Response("{}", { headers: { "content-type": "application/json" } });
    },
};

let n = 0;
const row = (over: Record<string, unknown>) => {
    n++;
    const r = {
        id: `Item${String(n).padStart(12, "0")}`,
        kind: "private",
        source: "saved",
        bucket: "originals",
        r2_key: `originals/sess${n}.mp4`,
        url: null,
        name: "x_2105237035271258436.mp4",
        content_type: "video/mp4",
        bytes: 4096,
        width: 480,
        height: 560,
        duration: 9.6,
        link: "https://x.com/someone/status/1",
        session_id: null,
        key_id: "k",
        created_at: 1_000 + n,
        deleted_at: null,
        poster: null,
        visibility: null,
        public_key: null,
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
    return r;
};

let captioner: Captioner | null = null;
const get = (url: string, init: RequestInit = {}, e: WorkerEnv = env) =>
    handleRequest(new Request(url, init), e, container, { now: () => 5_000, captioner });

const meta = (html: string, key: string): string | null => {
    const m = new RegExp(`<meta (?:property|name)="${key.replace(/[:.]/g, "\\$&")}" content="([^"]*)">`).exec(html);
    return m ? m[1] : null;
};

beforeEach(async () => {
    KEY_HASH ||= await hashKey(CLIENT);
    db = createFakeD1();
    containerCalls = [];
    env = {
        API_URL: "https://api.capybaraharmony.com/",
        CORS_URL: "https://cobalt.capybaraharmony.com",
        COBALT_API_KEY: INTERNAL,
        DB: db,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
    };
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", KEY_HASH, "0b5f2c3e", 1);
});


const API = "https://api.capybaraharmony.com";
const create = async (body: unknown) => {
    const r = await get(`${API}/share/sets`, { method: "POST", headers: { ...AUTH, "content-type": "application/json" }, body: JSON.stringify(body) });
    return { status: r.status, body: (await r.json()) as any };
};
const list = async () => (await (await get(`${API}/share/sets`, { headers: AUTH })).json()) as any;

let video: any, webp: any, photo: any, privateOne: any, fifth: any;
beforeEach(() => {
    video = row({ visibility: "public", public_key: "ViDeO00001.mp4", poster: `${MEDIA}PoStEr0001.jpg`, width: 3840, height: 2160 });
    webp = row({ kind: "public", source: "webp", bucket: "media", r2_key: "WeBpWeBp01.webp", content_type: "image/webp", width: 480, height: 270 });
    photo = row({ visibility: "public", public_key: "PhOtO00001.jpg", content_type: "image/jpeg", width: 1080, height: 1350, duration: null });
    privateOne = row({ r2_key: "originals/private.mp4" });
    fifth = row({ kind: "public", source: "webp", bucket: "media", r2_key: "WeBpWeBp02.webp", content_type: "image/webp" });
});


const DISCORD = { "user-agent": "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)" };
let seen: RoastInput[];
const fake = (over: Partial<Captioner> = {}): Captioner => ({
    model: "fake-haiku",
    async caption(input) {
        seen.push(input);
        return { title: `Harmony saved ${input.files.length} again 🦫`, description: "Peak taste, as usual 🙄 <b>" };
    },
    ...over,
});
const captionRow = (subject: string) =>
    db.raw.prepare("SELECT * FROM media_captions WHERE subject = ?").get(subject) as any;

beforeEach(() => {
    seen = [];
    captioner = fake();
});

describe("gallery links", () => {
    it("get their roast at creation, shown in Open Graph and Discord's embed", async () => {
        const r = await create({ items: [video.id, photo.id] });
        expect(r.status).toBe(201);
        const id = r.body.set.id;
        expect(seen).toHaveLength(1);
        expect(seen[0]!.files.map((f) => [f.kind, f.imageUrl])).toEqual([
            ["video", `${MEDIA}PoStEr0001.jpg`],
            ["image", `${MEDIA}PhOtO00001.jpg`],
        ]);
        expect(seen[0]!.files[0]!.link).toBe("https://x.com/someone/status/1");
        expect(captionRow(`set:${id}`)).toMatchObject({ title: "Harmony saved 2 again 🦫", model: "fake-haiku", attempts: 1 });

        const html = await (await get(`${SHARE}g/${id}`, { headers: DISCORD })).text();
        expect(meta(html, "og:title")).toBe("Harmony saved 2 again 🦫");
        expect(meta(html, "og:description")).toBe("Peak taste, as usual 🙄 &lt;b&gt;");
        const doc = JSON.parse(/<script id="discord:component-embed" type="application\/json">([^<]*)<\/script>/.exec(html)![1]!);
        expect(doc.component.components[0].content).toBe("**Harmony saved 2 again 🦫**\nPeak taste, as usual 🙄 \\<b\\>");
    });

    it("a title Harmony typed wins over the roast; the description still shows", async () => {
        const r = await create({ items: [video.id, photo.id], title: "trip" });
        expect(seen[0]!.userTitle).toBe("trip");
        const html = await (await get(`${SHARE}g/${r.body.set.id}`)).text();
        expect(meta(html, "og:title")).toBe("trip");
        expect(meta(html, "og:description")).toBe("Peak taste, as usual 🙄 &lt;b&gt;");
    });

    it("a failing or slow model never blocks the link; the failure is recorded for the cron", async () => {
        captioner = fake({ caption: async () => Promise.reject(new Error("boom")) });
        const r = await create({ items: [video.id, photo.id] });
        expect(r.status).toBe(201);
        expect(captionRow(`set:${r.body.set.id}`)).toMatchObject({ title: null, attempts: 1 });
        const html = await (await get(`${SHARE}g/${r.body.set.id}`)).text();
        expect(meta(html, "og:title")).toBe("2 files");
        expect(meta(html, "og:description")).toBeNull();
    });

    it("captions off (no key): nothing is written and the page is as before", async () => {
        captioner = null;
        const r = await create({ items: [video.id, photo.id] });
        expect(r.status).toBe(201);
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM media_captions").get()).toEqual({ n: 0 });
    });
});

describe("single-file share pages", () => {
    it("use the file's roast; a title set in the app wins", async () => {
        db.raw.prepare("INSERT INTO media_captions (subject, title, description, model, created_at, attempts) VALUES (?, ?, ?, ?, ?, 1)").run(`item:${video.id}`, "Capy approves 🦫", "Harmony, why. 💀", "m", 1);
        let html = await (await get(`${SHARE}ViDeO00001`)).text();
        expect(meta(html, "og:title")).toBe("Capy approves 🦫");
        expect(meta(html, "og:description")).toBe("Harmony, why. 💀 · 0:10");
        db.raw.prepare("UPDATE media_items SET post_key = 'P1' WHERE id = ?").run(video.id);
        db.raw.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES ('P1', 'my clip', 'k', 1)").run();
        html = await (await get(`${SHARE}ViDeO00001`)).text();
        expect(meta(html, "og:title")).toBe("my clip");
        expect(meta(html, "og:description")).toBe("Harmony, why. 💀 · 0:10");
    });
});

describe("backfill", () => {
    const run = (over: Partial<Parameters<typeof backfillCaptions>[0]> = {}, now = 10_000) =>
        backfillCaptions({
            db,
            captioner: captioner!,
            mediaBaseUrl: MEDIA,
            now: () => now,
            budgetMs: 60_000,
            setInput: (id) => setRoastInput({ db, mediaBaseUrl: MEDIA }, id),
            ...over,
        });

    it("captions every public file and live gallery link once, never a private one", async () => {
        captioner = null;
        const r = await create({ items: [video.id, webp.id] });
        captioner = fake();
        const out = await run();
        // the set, then video, webp, photo, fifth (all public); not privateOne
        expect(out).toEqual({ written: 5, failed: 0 });
        expect(captionRow(`set:${r.body.set.id}`).title).toContain("2 again");
        expect(captionRow(`item:${privateOne.id}`)).toBeUndefined();
        expect(captionRow(`item:${fifth.id}`).title).toContain("1 again");
        seen = [];
        expect(await run()).toEqual({ written: 0, failed: 0 });
        expect(seen).toHaveLength(0);
    });

    it("retries a failure after a day, at most three times", async () => {
        captioner = fake({ caption: async () => Promise.reject(new Error("rate limited")) });
        expect((await run({}, 10_000)).failed).toBe(4);
        expect((await run({}, 10_000 + 1000)).failed).toBe(0); // not due yet
        expect((await run({}, 10_000 + ROAST_RETRY_MS + 1)).failed).toBe(4);
        expect((await run({}, 10_000 + 2 * ROAST_RETRY_MS + 2)).failed).toBe(4);
        expect(captionRow(`item:${video.id}`).attempts).toBe(ROAST_MAX_ATTEMPTS);
        expect((await run({}, 10_000 + 9 * ROAST_RETRY_MS)).failed).toBe(0); // given up
        captioner = fake();
        expect((await run({}, 10_000 + 9 * ROAST_RETRY_MS)).written).toBe(0);
    });

    it("a public row without a share page is marked and not picked again", async () => {
        const odd = row({ visibility: "public", public_key: "not/a/page.mp4" });
        await run();
        expect(captionRow(`item:${odd.id}`)).toMatchObject({ title: null, attempts: ROAST_MAX_ATTEMPTS });
    });

    it("stops at its budget", async () => {
        let t = 0;
        const out = await backfillCaptions({ db, captioner: captioner!, mediaBaseUrl: MEDIA, now: () => (t += 1000), budgetMs: 2500, concurrency: 1 });
        expect(out.written).toBeLessThan(4);
    });
});

describe("the model reply", () => {
    it("is clipped and cleaned", () => {
        const c = parseCaption(JSON.stringify({ title: "x".repeat(300), description: "a\n\nb" }));
        expect(Array.from(c.title)).toHaveLength(100);
        expect(c.title.endsWith("…")).toBe(true);
        expect(c.description).toBe("a b");
        expect(() => parseCaption('{"title":""}')).toThrow();
        expect(() => parseCaption("not json")).toThrow();
    });

    it("no key means captions are off", () => {
        expect(captionerFrom({})).toBeNull();
        expect(captionerFrom({ ANTHROPIC_API_KEY: "  " })).toBeNull();
        expect(captionerFrom({ ANTHROPIC_API_KEY: "sk-test" })?.model).toBe("claude-haiku-5-5");
        expect(captionerFrom({ ANTHROPIC_API_KEY: "sk-test", ROAST_MODEL: "claude-haiku-4-5" })?.model).toBe("claude-haiku-4-5");
    });
});
