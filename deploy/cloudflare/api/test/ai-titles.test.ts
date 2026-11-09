// AI video titles (APP-API-CONTRACT.md section 53): MiniMax on OpenRouter titles public video posts from the cron. A fake
// titler (or a fake fetch) stands in for OpenRouter; the real SQL, migration 0037 included, runs on node:sqlite.
import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import {
    AI_TITLE_KEY_ID,
    AI_TITLE_MAX_ATTEMPTS,
    AI_TITLE_RETRY_MS,
    AI_TITLE_STYLE,
    fitTitle,
    titleRequest,
    titlerFrom,
    titleVideos,
    userText,
    type TitleInput,
    type Titler,
} from "../src/ai-titles";

const MEDIA = "https://media.capybaraharmony.com/";
let db: FakeD1;
let n = 0;

const item = (over: Record<string, unknown> = {}) => {
    n++;
    const r = {
        id: `Item${String(n).padStart(12, "0")}`,
        kind: "private",
        source: "saved",
        bucket: "originals",
        r2_key: `originals/sess${n}.mp4`,
        name: `instagram_${n}.mp4`,
        content_type: "video/mp4",
        duration: 20,
        link: null, // the post key is then the item id
        created_at: 1_000 + n,
        visibility: "public",
        public_key: `Pub${String(n).padStart(7, "0")}.mp4`,
        role: "original",
        item_index: null,
        post_key: null,
        ...over,
    };
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, duration, link, key_id, created_at, visibility, public_key, role, item_index, post_key)
             VALUES (@id,@kind,@source,@bucket,@r2_key,@name,@content_type,4096,@duration,@link,'k',@created_at,@visibility,@public_key,@role,@item_index,@post_key)`,
        )
        .run(r as any);
    return r;
};

const titleOf = (postKey: string) => db.raw.prepare("SELECT title, key_id FROM media_titles WHERE post_key = ?").get(postKey) as { title: string; key_id: string } | undefined;
const stateOf = (postKey: string) => db.raw.prepare("SELECT * FROM media_ai_titles WHERE post_key = ?").get(postKey) as Record<string, any> | undefined;

let calls: TitleInput[];
let answer: (input: TitleInput) => string | Error;
const titler: Titler = {
    model: "minimax/minimax-m3.1-flash",
    async title(input) {
        calls.push(input);
        const a = answer(input);
        if (a instanceof Error) throw a;
        return { title: a, promptTokens: 3000, completionTokens: 40, cost: 0.0005 };
    },
};
const run = (now = 10_000) => titleVideos({ db, titler, mediaBaseUrl: MEDIA, now: () => now });

beforeEach(() => {
    db = createFakeD1();
    calls = [];
    answer = () => "Cat knocks a glass off the kitchen table";
});

describe("migration 0037", () => {
    it("comes right after 0036", () => {
        const dir = fileURLToPath(new URL("../../d1/migrations/", import.meta.url));
        const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
        const at = files.indexOf("0037_ai_titles.sql");
        expect(at).toBeGreaterThan(0);
        expect(files[at - 1]!.startsWith("0036")).toBe(true);
    });
});

describe("fitTitle", () => {
    it("keeps one plain line", () => {
        expect(fitTitle('"Man blends a protein smoothie."')).toBe("Man blends a protein smoothie");
        expect(fitTitle("Title: Dog surfs a wave\n\nextra")).toBe("Dog surfs a wave");
        expect(fitTitle("<think>hmm</think>\n**Minecraft tower falls on a player**")).toBe("Minecraft tower falls on a player");
        expect(fitTitle("   ")).toBeNull();
        expect(fitTitle(42)).toBeNull();
    });
    it("cuts a long one at a word, at most 80 code points", () => {
        const t = fitTitle("word ".repeat(30))!;
        expect(Array.from(t).length).toBeLessThanOrEqual(80);
        expect(t.endsWith("word")).toBe(true);
    });
});

describe("the request", () => {
    it("sends the video only for short clips, and the transcript for long ones", () => {
        expect(userText({ videoUrl: "u", duration: 60, transcript: "hello" })).toBe("Title this video.");
        expect(userText({ videoUrl: "u", duration: 300, transcript: "hello there" })).toContain("hello there");
        expect(userText({ videoUrl: "u", duration: 300, transcript: null })).toBe("Title this video.");
    });
    it("pins Together, low reasoning, and the video as a link", () => {
        const body = titleRequest("minimax/minimax-m3.1-flash", { videoUrl: `${MEDIA}abc123.mp4`, duration: 10, transcript: null }) as any;
        expect(body.provider).toEqual({ order: ["together"], allow_fallbacks: false });
        expect(body.reasoning).toEqual({ effort: "low" });
        expect(body.messages[1].content[0]).toEqual({ type: "video_url", video_url: { url: `${MEDIA}abc123.mp4` } });
    });
});

describe("titlerFrom", () => {
    it("is off without a key or with AI_TITLES 0", () => {
        expect(titlerFrom({})).toBeNull();
        expect(titlerFrom({ OPENROUTER_API_KEY: " " })).toBeNull();
        expect(titlerFrom({ OPENROUTER_API_KEY: "k", AI_TITLES: "0" })).toBeNull();
    });
    it("calls OpenRouter with the key and reads the title and usage", async () => {
        const seen: { url: string; init: RequestInit }[] = [];
        const fake = (async (url: string, init: RequestInit) => {
            seen.push({ url, init });
            return new Response(JSON.stringify({ choices: [{ message: { content: "Fursuiter explains Meta smart glasses." } }], usage: { prompt_tokens: 16498, completion_tokens: 28, cost: 0.00249 } }));
        }) as unknown as typeof fetch;
        const t = titlerFrom({ OPENROUTER_API_KEY: "sk-test" }, fake)!;
        expect(t.model).toBe("minimax/minimax-m3.1-flash");
        const a = await t.title({ videoUrl: `${MEDIA}x.mp4`, duration: 92, transcript: null });
        expect(a).toEqual({ title: "Fursuiter explains Meta smart glasses", promptTokens: 16498, completionTokens: 28, cost: 0.00249 });
        expect(seen[0]!.url).toBe("https://openrouter.ai/api/v1/chat/completions");
        expect((seen[0]!.init.headers as Record<string, string>).authorization).toBe("Bearer sk-test");
    });
    it("throws on an error answer or an empty title", async () => {
        const status = (async () => new Response(JSON.stringify({ error: { message: "No endpoints found" } }), { status: 404 })) as unknown as typeof fetch;
        await expect(titlerFrom({ OPENROUTER_API_KEY: "k" }, status)!.title({ videoUrl: "u", duration: 1, transcript: null })).rejects.toThrow(/404/);
        const empty = (async () => new Response(JSON.stringify({ choices: [{ message: { content: "" } }] }))) as unknown as typeof fetch;
        await expect(titlerFrom({ OPENROUTER_API_KEY: "k" }, empty)!.title({ videoUrl: "u", duration: 1, transcript: null })).rejects.toThrow(/empty/);
    });
});

describe("titleVideos", () => {
    it("titles public video posts from their public URL and records the cost", async () => {
        const v = item();
        const r = await run();
        expect(r).toEqual({ due: 1, written: 1, kept: 0, failed: 0 });
        expect(calls[0]!.videoUrl).toBe(`${MEDIA}${v.public_key}`);
        expect(titleOf(v.id)).toEqual({ title: "Cat knocks a glass off the kitchen table", key_id: AI_TITLE_KEY_ID });
        expect(stateOf(v.id)).toMatchObject({ state: "done", item_id: v.id, style: AI_TITLE_STYLE, prompt_tokens: 3000, cost: 0.0005, with_transcript: 0 });
        // done: not asked again
        expect(await run()).toEqual({ due: 0, written: 0, kept: 0, failed: 0 });
    });

    it("leaves private videos, pictures, galleries, hidden posts and owner titles alone", async () => {
        item({ visibility: "private" });
        item({ content_type: "image/jpeg", r2_key: "originals/p.jpg", public_key: "Picture001.jpg" });
        item({ role: "item", item_index: 0, post_key: "gallery1" });
        item({ role: "item", item_index: 1, post_key: "gallery1" });
        const hid = item();
        db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, at) VALUES (?, 'hidden', 'you', 1)").run(hid.id);
        const mine = item();
        db.raw.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES (?, 'my title', 'key-1', 1)").run(mine.id);
        const r = await run();
        expect(r.due).toBe(0);
        expect(calls).toHaveLength(0);
        expect(titleOf(mine.id)!.title).toBe("my title");
    });

    it("never replaces a title the owner set while the model was watching", async () => {
        const v = item();
        answer = () => {
            db.raw.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES (?, 'typed by Harmony', 'key-1', 2)").run(v.id);
            return "Model title";
        };
        expect(await run()).toMatchObject({ written: 0, kept: 1 });
        expect(titleOf(v.id)).toEqual({ title: "typed by Harmony", key_id: "key-1" });
        expect(stateOf(v.id)).toMatchObject({ state: "skipped", title: "Model title" });
    });

    it("replaces the file name and an older AI title (a new style rewrites)", async () => {
        const v = item();
        db.raw.prepare("INSERT INTO media_titles (post_key, title, key_id, updated_at) VALUES (?, 'old ai', ?, 1)").run(v.id, AI_TITLE_KEY_ID);
        db.raw
            .prepare("INSERT INTO media_ai_titles (post_key, item_id, state, title, model, style, attempts, updated_at) VALUES (?, ?, 'done', 'old ai', ?, 'v0', 0, 1)")
            .run(v.id, v.id, titler.model);
        expect(await run()).toMatchObject({ written: 1 });
        expect(titleOf(v.id)!.title).toBe("Cat knocks a glass off the kitchen table");
    });

    it("adds the transcript for videos over 2 minutes only", async () => {
        const short = item({ duration: 30 });
        const long = item({ duration: 325 });
        for (const p of [short, long]) {
            db.raw
                .prepare("INSERT INTO media_transcripts (post_key, item_id, state, text, lines, model, created_at, updated_at) VALUES (?, ?, 'done', ?, '[]', 'm', 1, 1)")
                .run(p.id, p.id, `words of ${p.id}`);
        }
        await run();
        const byUrl = new Map(calls.map((c) => [c.videoUrl, c]));
        expect(byUrl.get(`${MEDIA}${short.public_key}`)!.transcript).toBeNull();
        expect(byUrl.get(`${MEDIA}${long.public_key}`)!.transcript).toBe(`words of ${long.id}`);
        expect(stateOf(long.id)!.with_transcript).toBe(1);
    });

    it("records a failure and tries again a day later, at most 3 times", async () => {
        const v = item();
        answer = () => new Error("openrouter 502: upstream");
        expect(await run(10_000)).toMatchObject({ failed: 1 });
        expect(stateOf(v.id)).toMatchObject({ state: "failed", attempts: 1, error: "openrouter 502: upstream" });
        expect(titleOf(v.id)).toBeUndefined();
        expect((await run(20_000)).due).toBe(0);
        let now = 10_000;
        for (let i = 2; i <= AI_TITLE_MAX_ATTEMPTS; i++) {
            now += AI_TITLE_RETRY_MS + 1;
            expect(await run(now)).toMatchObject({ failed: 1 });
        }
        expect(stateOf(v.id)!.attempts).toBe(AI_TITLE_MAX_ATTEMPTS);
        expect((await run(now + AI_TITLE_RETRY_MS * 2)).due).toBe(0);
    });

    it("stays inside the run's cap, newest first", async () => {
        const vs = Array.from({ length: 5 }, () => item());
        const r = await titleVideos({ db, titler, mediaBaseUrl: MEDIA, now: () => 1, max: 2, concurrency: 1 });
        expect(r).toMatchObject({ due: 5, written: 2 });
        expect(calls.map((c) => c.videoUrl)).toEqual([vs[4]!, vs[3]!].map((v) => `${MEDIA}${v.public_key}`));
    });
});
