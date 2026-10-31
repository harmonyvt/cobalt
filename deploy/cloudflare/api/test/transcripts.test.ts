// Timed transcripts (APP-API-CONTRACT.md section 47) on the real migrations (node:sqlite): Whisper's segments and words
// become subtitle lines; the cron's listening pass hears every probe with sound once (and again after a new probe), and
// the about writer reuses what it heard; moments get vectors; search says where the query was said ("words") or which
// moment matched ("meaning"); GET /library/transcript and its chat call. Whisper and the Space are fakes.
import { afterEach, describe, expect, it, vi } from "vitest";
import { ASSEMBLY_MODEL, transcriberFrom, whisperFrom, writeAbouts, type Describer, type Transcriber, type Transcript } from "../src/about-writer";
import { capabilities, type AppDeps } from "../src/app-routes";
import { EMBED_DIMS, EMBED_MODEL, librarySearch, normalize, runIndexer, type EmbedClient, type EmbedInput } from "../src/embed";
import { hashKey } from "../src/keys";
import { chatTools } from "../src/chat-tools";
import {
    LINE_MAX_CHARS,
    LINE_MAX_SECONDS,
    MAX_WORDS,
    indexMoments,
    linesOf,
    momentsOf,
    segmentsFromVtt,
    segmentsOf,
    timeTranscripts,
    transcriptModel,
    transcriptOf,
    type Line,
} from "../src/transcripts";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { type FakeD1 } from "../../test-support/d1-sqlite";
import { createBatchD1 } from "./d1-batch";
import { MemoryMedia, MemoryOriginals, fakeJpeg } from "./studio-fakes";

const MEDIA = "https://media.capybaraharmony.com/";
const SPACE = "https://capybaraharmony-cobalt-embed.hf.space";
const API = "https://api.capybaraharmony.com";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const T0 = 1_800_000_000_000;
const DAY = 24 * 60 * 60 * 1000;

const realFetch = globalThis.fetch;
afterEach(() => {
    globalThis.fetch = realFetch;
});

// ---- fakes ----------------------------------------------------------------------------------------------------------------

function wordVector(words: string): number[] {
    const v = new Array(EMBED_DIMS).fill(0);
    for (const w of words.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean)) {
        let h = 0;
        for (const c of w) h = (h * 31 + c.charCodeAt(0)) >>> 0;
        v[h % EMBED_DIMS] += 1;
    }
    v[EMBED_DIMS - 1] += 0.01;
    return normalize(v);
}

class FakeSpace implements EmbedClient {
    calls: { kind: string; inputs: EmbedInput[] }[] = [];
    down = false;
    async embed(kind: "document" | "query", inputs: EmbedInput[]) {
        this.calls.push({ kind, inputs });
        if (this.down) {
            const { EmbedError } = await import("../src/embed");
            throw new EmbedError("unavailable", 503);
        }
        return { model: EMBED_MODEL, vectors: inputs.map((i) => wordVector(`${kind === "document" ? (i.title ?? "") : ""} ${i.text}`)), images: inputs.map(() => false) };
    }
}

// Whisper's answer for a list of [start, end, "text"] segments, with each word's time spread over its segment.
function whisperAnswer(segs: [number, number, string][]) {
    return {
        text: segs.map((s) => s[2]).join(" "),
        transcription_info: { language: "en" },
        segments: segs.map(([start, end, text]) => {
            const ws = text.split(" ");
            const step = (end - start) / ws.length;
            return { start, end, text: ` ${text}`, words: ws.map((w, i) => ({ word: ` ${w}`, start: start + i * step, end: start + (i + 1) * step })) };
        }),
        vtt: "WEBVTT",
    };
}

class FakeWhisper implements Transcriber {
    model = "fake-whisper";
    calls = 0;
    fail = false;
    segs: [number, number, string][] = [
        [0.6, 3.4, "wait is that a fox in first class?"],
        [4.1, 7.9, "sir, you cannot bring the tail into the cabin."],
        [8.4, 10.6, "it is part of me."],
    ];
    async transcribe(_mp3: Uint8Array): Promise<Transcript> {
        this.calls++;
        if (this.fail) throw new Error("whisper down");
        const t = whisperFrom({ run: async () => whisperAnswer(this.segs) })!;
        return t.transcribe(new Uint8Array(1));
    }
}

class FakeHaiku implements Describer {
    model = "fake-haiku";
    seen: (string | null)[] = [];
    async describe(input: { transcript: string | null }) {
        this.seen.push(input.transcript);
        return { sentence: "A fox on a plane.", tags: ["fox", "plane"], sound_tags: ["speech"] };
    }
}

// ---- the library ------------------------------------------------------------------------------------------------------

let n = 0;
function addFile(db: FakeD1, over: { session_id: string; name?: string; content_type?: string }) {
    n++;
    const id = `item${String(n).padStart(12, "0")}`;
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, link, poster, session_id, role, item_index, public_id, visibility, bytes, created_at, deleted_at)
             VALUES (?, 'private', 'saved', 'originals', ?, NULL, ?, ?, NULL, NULL, ?, NULL, NULL, NULL, NULL, 4096, ?, NULL)`,
        )
        .run(id, `originals/${id}.mp4`, over.name ?? "clip.mp4", over.content_type ?? "video/mp4", over.session_id, T0 + n);
    return id;
}
const setAbout = (db: FakeD1, post_key: string, item_id: string, f: Record<string, unknown> = {}) => {
    const row = { post_key, item_id, probe_state: "done", probe_at: T0, frames: 1, has_audio: 1, updated_at: T0, ...f };
    const cols = Object.keys(row);
    db.raw.prepare(`INSERT OR REPLACE INTO media_about (${cols.join(", ")}) VALUES (${cols.map((c) => `@${c}`).join(", ")})`).run(row as any);
};
const aboutOf = (db: FakeD1, k: string) => db.raw.prepare("SELECT * FROM media_about WHERE post_key = ?").get(k) as any;
const transcriptRow = (db: FakeD1, k: string) => db.raw.prepare("SELECT * FROM media_transcripts WHERE post_key = ?").get(k) as any;

function world() {
    const db: FakeD1 = createBatchD1();
    let now = T0 + 1_000_000;
    const space = new FakeSpace();
    const originals = new MemoryOriginals();
    const media = new MemoryMedia();
    const d: AppDeps = {
        db: db as unknown as D1Database,
        originals,
        media,
        mediaBaseUrl: MEDIA,
        apiUrl: "https://api.capybaraharmony.com/",
        webUrl: "https://cobalt.capybaraharmony.com",
        now: () => now,
        fixedLength: () => {
            throw new Error("unused");
        },
        adopt: async () => {
            throw new Error("unused");
        },
    };
    const whisper = new FakeWhisper();
    // a probed video with sound (frames and audio in R2)
    const probed = (post: string, name = `${post}.mp4`, audio = true) => {
        const id = addFile(db, { session_id: post, name });
        originals.objects.set(`about/${id}/frame-1.jpg`, { bytes: fakeJpeg(50, 1), contentType: "image/jpeg", meta: {} });
        if (audio) originals.objects.set(`about/${id}/audio.mp3`, { bytes: Uint8Array.from([0x49, 0x44, 0x33, 1]), contentType: "audio/mpeg", meta: {} });
        setAbout(db, post, id, { has_audio: audio ? 1 : 0 });
        return id;
    };
    const listen = (o: { max?: number } = {}) =>
        timeTranscripts({ db: d.db, originals, transcriber: whisper, now: () => now, budgetMs: 60_000, concurrency: 1, ...o });
    const index = async () => {
        for (let i = 0; i < 20; i++) if ((await runIndexer({ db: d.db, client: space, mediaBaseUrl: MEDIA, now: () => now, batch: 50 })).pending === 0) break;
        await indexMoments({ db: d.db, client: space, now: () => now, budgetMs: 60_000 });
    };
    const search = (q: string, extra = "") => librarySearch({ ...d, embed: space }, new URLSearchParams(`q=${encodeURIComponent(q)}${extra}`));
    return { db, d, space, originals, media, whisper, probed, listen, index, search, tick: (ms: number) => (now += ms), now: () => now };
}

// ---- 47.1: lines ------------------------------------------------------------------------------------------------------------

describe("Whisper's answer becomes subtitle lines (47.1)", () => {
    it("keeps each word's time, breaks at segment ends, and joins the words of a line", () => {
        const lines = linesOf(segmentsOf(whisperAnswer([[0.6, 3.4, "wait is that a fox"], [4.1, 7.9, "sir you cannot"]])));
        expect(lines.map((l) => l.t)).toEqual(["wait is that a fox", "sir you cannot"]);
        expect(lines[0]).toMatchObject({ s: 0.6, e: 3.4 });
        expect(lines[0]!.w.map((w) => w.t)).toEqual(["wait", "is", "that", "a", "fox"]);
        expect(lines[0]!.w[1]).toEqual({ t: "is", s: 1.16, e: 1.72 });
        for (const l of lines) for (const w of l.w) expect(Math.round(w.s * 100) / 100).toBe(w.s);
    });

    it("breaks a long segment at a pause, after a sentence, and at the length limits", () => {
        const long = Array.from({ length: 40 }, (_, i) => `word${i}`).join(" ");
        const lines = linesOf(segmentsOf(whisperAnswer([[0, 30, long]])));
        expect(lines.length).toBeGreaterThan(4);
        for (const l of lines) {
            expect(l.t.length).toBeLessThanOrEqual(LINE_MAX_CHARS);
            expect(l.e - l.s).toBeLessThanOrEqual(LINE_MAX_SECONDS + 0.01);
        }
        expect(lines.flatMap((l) => l.w.map((w) => w.t)).join(" ")).toBe(long);
        // a pause of 1.2 s or more, and a sentence end once the line holds 24 characters
        const seg = {
            start: 0,
            end: 10,
            text: "",
            words: [
                { word: "one", start: 0, end: 0.4 },
                { word: "two", start: 2, end: 2.4 },
                { word: "this line is long enough now.", start: 2.5, end: 3 },
                { word: "next", start: 3.1, end: 3.4 },
            ],
        };
        expect(linesOf(segmentsOf({ segments: [seg] })).map((l) => l.t)).toEqual(["one", "two this line is long enough now.", "next"]);
    });

    it("never lets time run backwards, and caps the words", () => {
        const seg = { start: 0, end: 3, text: "a b c", words: [{ word: "a", start: 1, end: 1.5 }, { word: "b", start: 0.5, end: 0.4 }, { word: "c", start: 2, end: 3 }] };
        const [l] = linesOf(segmentsOf({ segments: [seg] }));
        expect(l!.w).toEqual([{ t: "a", s: 1, e: 1.5 }, { t: "b", s: 1, e: 1 }, { t: "c", s: 2, e: 3 }]);
        const many = Array.from({ length: MAX_WORDS + 50 }, (_, i) => ({ word: "w", start: i * 0.1, end: i * 0.1 + 0.05 }));
        const words = linesOf(segmentsOf({ segments: [{ start: 0, end: 1e5, text: "", words: many }] })).reduce((k, x) => k + x.w.length, 0);
        expect(words).toBe(MAX_WORDS);
    });

    it("a segment without words spreads its words over it; no segments falls back to the vtt cues", () => {
        const [l] = linesOf(segmentsOf({ segments: [{ start: 0, end: 2, text: "ab cd" }] }));
        expect(l).toEqual({ s: 0, e: 2, t: "ab cd", w: [{ t: "ab", s: 0, e: 1 }, { t: "cd", s: 1, e: 2 }] });
        const vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nhello there\n\n00:01:00.000 --> 00:01:01.000\nlater";
        expect(segmentsFromVtt(vtt)).toEqual([
            { start: 1, end: 2.5, text: "hello there", words: null },
            { start: 60, end: 61, text: "later", words: null },
        ]);
        expect(linesOf(segmentsOf({ vtt })).map((x) => [x.s, x.t])).toEqual([[1, "hello there"], [60, "later"]]);
        expect(segmentsOf({ segments: [{ start: "x" }, null, { start: 1, end: 2, text: "  " }] })).toEqual([]);
        expect(segmentsOf(null)).toEqual([]);
    });

    it("the Whisper adapter returns the lines with the text", async () => {
        const t = whisperFrom({ run: async () => whisperAnswer([[0, 1, "hi there"]]) })!;
        const r = await t.transcribe(new Uint8Array(1));
        expect(r).toMatchObject({ text: "hi there", language: "en" });
        expect(r.lines!.map((l: Line) => l.t)).toEqual(["hi there"]);
    });
});

// ---- 47.2: the listening pass and the writer --------------------------------------------------------------------------------

describe("the listening pass (47.2)", () => {
    it("hears each probe with sound once, stores the lines, and gives the post its plain transcript", async () => {
        const w = world();
        w.probed("postA");
        w.probed("postQuiet", "quiet.mp4", false);
        expect(await w.listen()).toEqual({ due: 1, heard: 1, failed: 0, removed: 0 });
        const t = transcriptRow(w.db, "postA");
        expect(t).toMatchObject({ state: "done", language: "en", model: transcriptModel("fake-whisper"), probe_at: T0, attempts: 0 });
        expect(JSON.parse(t.lines)).toHaveLength(3);
        expect(t.text).toBe("wait is that a fox in first class? sir, you cannot bring the tail into the cabin. it is part of me.");
        expect(aboutOf(w.db, "postA")).toMatchObject({ transcript: t.text, language: "en" });
        expect(transcriptRow(w.db, "postQuiet")).toBeUndefined();
        // heard: not due again; a new probe (or a new model) is
        expect((await w.listen()).due).toBe(0);
        w.db.raw.prepare("UPDATE media_about SET probe_at = ? WHERE post_key = 'postA'").run(T0 + 5);
        expect((await w.listen()).heard).toBe(1);
        expect(w.whisper.calls).toBe(2);
        w.whisper.model = "fake-whisper-2";
        expect((await w.listen()).heard).toBe(1);
    });

    it("no speech is stored as no_speech; a failure is retried a day later, at most three times", async () => {
        const w = world();
        w.probed("postA");
        w.whisper.segs = [];
        const silent = whisperFrom({ run: async () => ({ text: "  " }) })!;
        await timeTranscripts({ db: w.d.db, originals: w.originals, transcriber: { model: "fake-whisper", transcribe: (b) => silent.transcribe(b) }, now: w.now, budgetMs: 60_000 });
        expect(transcriptRow(w.db, "postA")).toMatchObject({ state: "no_speech", text: null, lines: "[]" });
        expect(aboutOf(w.db, "postA").transcript).toBeNull();

        const v = world();
        v.probed("postB");
        v.whisper.fail = true;
        expect(await v.listen()).toMatchObject({ heard: 0, failed: 1 });
        expect(transcriptRow(v.db, "postB")).toMatchObject({ state: "failed", attempts: 1 });
        expect((await v.listen()).due).toBe(0);
        v.tick(DAY + 1);
        await v.listen();
        expect(transcriptRow(v.db, "postB").attempts).toBe(2);
        v.tick(DAY + 1);
        await v.listen();
        v.tick(DAY + 1);
        expect((await v.listen()).due).toBe(0);
        expect(transcriptRow(v.db, "postB").attempts).toBe(3);
        // a missing sound object is a failure too
        const u = world();
        const id = u.probed("postC");
        u.originals.objects.delete(`about/${id}/audio.mp3`);
        expect(await u.listen()).toMatchObject({ failed: 1 });
    });

    it("removes the transcripts of posts that are gone or lost their sound, and keeps to its cap", async () => {
        const w = world();
        w.probed("postA");
        w.probed("postB");
        w.probed("postC");
        expect((await w.listen({ max: 2 })).heard).toBe(2);
        expect((await w.listen()).heard).toBe(1);
        w.db.raw.prepare("DELETE FROM media_about WHERE post_key = 'postA'").run();
        w.db.raw.prepare("UPDATE media_about SET has_audio = 0 WHERE post_key = 'postB'").run();
        expect((await w.listen()).removed).toBe(2);
        expect(transcriptRow(w.db, "postC")).toBeDefined();
    });

    it("the about writer reuses what was heard, and stores the timed lines when it hears first", async () => {
        const w = world();
        w.probed("postA");
        await w.listen();
        const haiku = new FakeHaiku();
        await writeAbouts({ db: w.d.db, originals: w.originals, mediaBaseUrl: MEDIA, describer: haiku, transcriber: w.whisper, now: w.now, budgetMs: 60_000 });
        expect(w.whisper.calls).toBe(1);
        expect(haiku.seen[0]).toContain("tail into the cabin");
        // a post the pass has not reached: the writer hears it, and the lines are kept
        w.probed("postB");
        const r = await writeAbouts({ db: w.d.db, originals: w.originals, mediaBaseUrl: MEDIA, describer: haiku, transcriber: w.whisper, now: w.now, budgetMs: 60_000 });
        expect(r.transcribed).toBe(1);
        expect(transcriptRow(w.db, "postB")).toMatchObject({ state: "done" });
        expect((await w.listen()).due).toBe(0);
    });
});

// ---- 47.4: moments and search ---------------------------------------------------------------------------------------------

describe("moments and search (47.4, 47.5)", () => {
    it("groups lines into stretches of about 120 characters or 12 s", () => {
        const line = (s: number, t: string): Line => ({ s, e: s + 1, t, w: [] });
        const ms = momentsOf([line(0, "a".repeat(60)), line(1, "b".repeat(70)), line(2, "c"), line(20, "d")]);
        expect(ms.map((m) => [m.idx, m.s, m.e])).toEqual([[0, 0, 2], [1, 2, 21]]);
        expect(momentsOf([])).toEqual([]);
    });

    it("embeds each stretch once, again when its words change, and drops the stretches of posts without a transcript", async () => {
        const w = world();
        w.probed("postA");
        await w.listen();
        const first = await indexMoments({ db: w.d.db, client: w.space, now: w.now, budgetMs: 60_000 });
        expect(first).toMatchObject({ posts: 1, embedded: 1, unavailable: false });
        expect(w.space.calls.at(-1)!.kind).toBe("document");
        expect((await indexMoments({ db: w.d.db, client: w.space, now: w.now, budgetMs: 60_000 })).embedded).toBe(0);
        w.whisper.segs = [[0, 2, "a completely different thing"]];
        w.db.raw.prepare("UPDATE media_about SET probe_at = ? WHERE post_key = 'postA'").run(T0 + 9);
        await w.listen();
        expect((await indexMoments({ db: w.d.db, client: w.space, now: w.now, budgetMs: 60_000 })).embedded).toBe(1);
        w.db.raw.prepare("DELETE FROM media_transcripts").run();
        expect((await indexMoments({ db: w.d.db, client: w.space, now: w.now, budgetMs: 60_000 })).removed).toBe(1);
        // the Space asleep: nothing lost, tried next run (postA is heard again too: its transcript went)
        w.probed("postB");
        await w.listen();
        w.space.down = true;
        expect(await indexMoments({ db: w.d.db, client: w.space, now: w.now, budgetMs: 60_000 })).toMatchObject({ embedded: 0, unavailable: true });
        w.space.down = false;
        expect((await indexMoments({ db: w.d.db, client: w.space, now: w.now, budgetMs: 60_000 })).embedded).toBe(2);
    });

    it("search says where the words were said, every line that holds them", async () => {
        const w = world();
        w.probed("postFox", "fox_in_first_class.mp4");
        w.probed("postOther", "other.mp4");
        w.whisper.segs = [[0, 2, "nothing to see here"]];
        await w.listen({ max: 1 }); // postOther is newest? both T0: heard in key order
        w.whisper.segs = [
            [0.6, 3.4, "wait is that a fox in first class?"],
            [4.1, 7.9, "sir, you cannot bring the tail into the cabin."],
            [15.3, 18.9, "the pilot said the tail can stay."],
        ];
        await w.listen();
        await w.index();
        const r = await w.search("tail");
        expect(r.status).toBe(200);
        const posts = (r.body as any).posts;
        const fox = posts.find((p: any) => p.said?.length);
        expect(fox.said).toEqual([
            { start: 4.1, end: 7.9, text: "sir, you cannot bring the tail into the cabin.", match: "words" },
            { start: 15.3, end: 18.9, text: "the pilot said the tail can stay.", match: "words" },
        ]);
        // a post with no transcript has no said
        for (const p of posts) if (p !== fox) expect(p.said).toBeUndefined();
    });

    it("a moment that matches by meaning lifts its post and is said with match meaning", async () => {
        const w = world();
        w.probed("postA", "clip_a.mp4");
        w.probed("postB", "clip_b.mp4");
        w.whisper.segs = [[3, 6, "airline cabin rules for passengers"]];
        await w.listen({ max: 1 });
        w.whisper.segs = [[0, 2, "hello there friend"]];
        await w.listen();
        await w.index();
        const heardRules = (w.db.raw.prepare("SELECT post_key FROM media_transcripts WHERE text LIKE '%airline%'").get() as any).post_key;
        // "passengers rules airline" is not a line's text as written, but its words are the moment's (the fake Space is a bag of words)
        const r = await w.search("passengers rules airline");
        const posts = (r.body as any).posts;
        expect(posts[0].id).toBe(heardRules);
        expect(posts[0].said).toEqual([{ start: 3, end: 6, text: "airline cabin rules for passengers", match: "meaning" }]);
    });

    it("the chat's search gives said too", async () => {
        const w = world();
        w.probed("postFox", "fox.mp4");
        await w.listen();
        await w.index();
        const tools = chatTools({ db: w.d.db, mediaBaseUrl: MEDIA, embed: w.space }, { look: [], show: [] });
        const [hit] = (await tools.search!("tail")) as any[];
        expect(hit.said).toEqual([{ at: 4.1, end: 7.9, text: "sir, you cannot bring the tail into the cabin.", match: "words" }]);
    });
});

// ---- 47.3: GET /library/transcript --------------------------------------------------------------------------------------------

describe("GET /library/transcript (47.3)", () => {
    async function http(withAi = true) {
        const w = world();
        w.db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", await hashKey(CLIENT), "0b5f2c3e", 1);
        globalThis.fetch = vi.fn(async () => {
            throw new Error("no fetch expected");
        }) as typeof fetch;
        const env: WorkerEnv = {
            API_URL: "https://api.capybaraharmony.com/",
            CORS_URL: "https://cobalt.capybaraharmony.com",
            COBALT_API_KEY: INTERNAL,
            DB: w.d.db,
            ORIGINALS: w.originals,
            MEDIA: w.media,
            MEDIA_BASE_URL: MEDIA,
            ...(withAi ? { AI: { run: async () => ({}) } } : {}),
        } as WorkerEnv;
        const container = { fetch: async () => new Response("container must not be called", { status: 500 }) };
        const call = (path: string, headers: Record<string, string> = { authorization: `Api-Key ${CLIENT}` }) =>
            handleRequest(new Request(`${API}${path}`, { headers }), env, container, { now: w.now });
        return { w, call };
    }

    it("answers the lines with every word's time", async () => {
        const { w, call } = await http();
        w.probed("postA");
        await w.listen();
        const r = await call("/library/transcript?key=postA");
        expect(r.status).toBe(200);
        expect(r.headers.get("cache-control")).toBe("no-store");
        const b = (await r.json()) as any;
        expect(Object.keys(b).sort()).toEqual(["language", "lines", "model", "post_key", "state", "status", "updated_at"]);
        expect(b).toMatchObject({ status: "success", post_key: "postA", state: "done", language: "en", model: transcriptModel("fake-whisper") });
        expect(b.lines).toHaveLength(3);
        expect(b.lines[1]).toMatchObject({ start: 4.1, end: 7.9, text: "sir, you cannot bring the tail into the cabin." });
        expect(b.lines[1].words[0]).toEqual({ text: "sir,", start: 4.1, end: 4.52 });
        const part = (await (await call("/library/transcript?key=postA&from=4&to=8")).json()) as any;
        expect(part.lines.map((l: any) => l.start)).toEqual([4.1]);
        // the library service may read it too
        expect((await call("/library/transcript?key=postA", { "x-cobalt-service": INTERNAL })).status).toBe(200);
    });

    it("says why there are no lines: pending, no_sound, no_speech, failed, off; 404 and 400", async () => {
        const { w, call } = await http();
        const state = async (k: string) => ((await (await call(`/library/transcript?key=${k}`)).json()) as any).state;
        addFile(w.db, { session_id: "postNew" });
        expect(await state("postNew")).toBe("pending");
        w.probed("postQuiet", "q.mp4", false);
        expect(await state("postQuiet")).toBe("no_sound");
        addFile(w.db, { session_id: "postPic", name: "p.png", content_type: "image/png" });
        expect(await state("postPic")).toBe("no_sound");
        w.probed("postHeard");
        expect(await state("postHeard")).toBe("pending");
        w.whisper.fail = true;
        for (let i = 0; i < 3; i++) {
            await w.listen();
            w.tick(DAY + 1);
        }
        expect(await state("postHeard")).toBe("failed");
        expect((await call("/library/transcript?key=nope")).status).toBe(404);
        expect((await call("/library/transcript")).status).toBe(400);
        expect((await call("/library/transcript?key=postNew&from=x")).status).toBe(400);
        expect((await call("/library/transcript?key=postNew", {})).status).toBe(401);
        const off = await http(false);
        addFile(off.w.db, { session_id: "postX" });
        expect(((await (await off.call("/library/transcript?key=postX")).json()) as any).state).toBe("off");
    });

    it("no_speech, and a new probe makes the old lines pending again", async () => {
        const w = world();
        w.probed("postA");
        await w.listen();
        expect((await transcriptOf({ db: w.d.db, soundOn: true }, "postA")).state).toBe("done");
        w.db.raw.prepare("UPDATE media_about SET probe_at = ? WHERE post_key = 'postA'").run(T0 + 1);
        expect(await transcriptOf({ db: w.d.db, soundOn: true }, "postA")).toMatchObject({ state: "pending", lines: [] });
        w.whisper.segs = [];
        const silent = whisperFrom({ run: async () => ({ text: "" }) })!;
        await timeTranscripts({ db: w.d.db, originals: w.originals, transcriber: { model: "fake-whisper", transcribe: (b) => silent.transcribe(b) }, now: w.now, budgetMs: 60_000 });
        expect((await transcriptOf({ db: w.d.db, soundOn: true }, "postA")).state).toBe("no_speech");
    });

    it("the capabilities flag follows about_sound", async () => {
        const w = world();
        const caps = async (about: boolean, sound: boolean) =>
            ((await capabilities(w.d, "missing", undefined, false, false, false, false, false, false, true, false, false, false, false, false, about, sound)).body as any).features;
        expect((await caps(true, true)).transcripts).toBe(true);
        expect((await caps(true, false)).transcripts).toBe(false);
    });
});

describe("the speech model switch (47.1)", () => {
    it("TRANSCRIBE_MODEL picks AssemblyAI by default and Whisper on request", async () => {
        const calls: { model: string; inputs: Record<string, unknown> }[] = [];
        const ai = {
            run: async (model: string, inputs: Record<string, unknown>) => {
                calls.push({ model, inputs });
                return {
                    text: "Hi there. Bring the tail",
                    language_code: "en",
                    words: [
                        { text: "Hi", start: 100, end: 300, confidence: 0.9 },
                        { text: "there.", start: 320, end: 700 },
                        { text: "Bring", start: 2500, end: 2800 },
                        { bad: 1 },
                        { text: "the", start: 2810, end: 2900 },
                        { text: "tail", start: 2910, end: 3300 },
                    ],
                };
            },
        };
        expect(transcriberFrom(ai, undefined)!.model).toBe(ASSEMBLY_MODEL);
        expect(transcriberFrom(ai, " Whisper ")!.model).toBe("@cf/openai/whisper-large-v3-turbo");
        expect(transcriberFrom(undefined, "assemblyai")).toBeNull();
        const t = transcriberFrom(ai, "AssemblyAI")!;
        expect(t.model).toBe(ASSEMBLY_MODEL);
        const heard = await t.transcribe(Uint8Array.from([1, 2, 3]));
        expect(calls[0]).toEqual({ model: ASSEMBLY_MODEL, inputs: { audio_url: "data:audio/mpeg;base64,AQID", language_detection: true } });
        expect(heard.text).toBe("Hi there. Bring the tail");
        expect(heard.language).toBe("en");
        expect(heard.lines).toEqual([
            { s: 0.1, e: 0.7, t: "Hi there.", w: [{ t: "Hi", s: 0.1, e: 0.3 }, { t: "there.", s: 0.32, e: 0.7 }] },
            { s: 2.5, e: 3.3, t: "Bring the tail", w: [{ t: "Bring", s: 2.5, e: 2.8 }, { t: "the", s: 2.81, e: 2.9 }, { t: "tail", s: 2.91, e: 3.3 }] },
        ]);
        const quiet = transcriberFrom({ run: async () => ({ text: "", words: [] }) }, "assemblyai")!;
        expect(await quiet.transcribe(new Uint8Array(1))).toEqual({ text: null, language: null, lines: [] });
        const bad = transcriberFrom({ run: async () => ({ nope: 1 }) }, "assemblyai")!;
        await expect(bad.transcribe(new Uint8Array(1))).rejects.toThrow();
    });

    it("AssemblyAI utterances start their own lines", async () => {
        const t = transcriberFrom(
            {
                run: async () => ({
                    text: "yes no",
                    utterances: [
                        { speaker: "A", words: [{ text: "yes", start: 0, end: 400 }] },
                        { speaker: "B", words: [{ text: "no", start: 450, end: 800 }] },
                    ],
                }),
            },
            "assemblyai",
        )!;
        expect((await t.transcribe(new Uint8Array(1))).lines!.map((l) => l.t)).toEqual(["yes", "no"]);
    });
});
