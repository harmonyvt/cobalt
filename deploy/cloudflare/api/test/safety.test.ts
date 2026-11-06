// Per-file safety ratings (APP-API-CONTRACT.md section 51): levels, inheritance, the stage rule, Clef's request
// and answer, and one rating. No second model.
import { describe, expect, it } from "vitest";
import { safetyAudioKey, safetyClipKey, safetyStillKey } from "../src/about-store";
import { buildClefRequest, loadSafetyMedia, rateSafety } from "../src/safety-clef";
import { PILOT_LABELS_KEY, PILOT_REPORT_KEY, formatPilotReport, parsePilotLabels, readPilotLabels, readPilotReport } from "../src/safety-pilot";
import { postSafetyLevel } from "../src/safety-store";
import {
    CLEF_MODEL_ID,
    QUESTIONS_VERSION,
    SAFETY_MAX_ATTEMPTS,
    SAFETY_PILOT_PER_RUN,
    SAFETY_RETRY_MS,
    effectiveSafety,
    parseClefAnswer,
    rollupLevels,
    safetyConfigFrom,
    stageAllows,
    type SafetyConfig,
    type SafetySnapshot,
} from "../src/safety";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { MemoryOriginals } from "./studio-fakes";

const cfg: SafetyConfig = safetyConfigFrom({});

const row = (over: Partial<SafetySnapshot> & { item_id?: string } = {}): SafetySnapshot => ({
    level: "general",
    user_level: null,
    probs: JSON.stringify({ level: { general: 1, sensitive: 0, questionable: 0, explicit: 0 }, gore: 0, drawn: 0, minor_sexual: 0 }),
    gore: 0,
    drawn: 0,
    minor_sexual: 0,
    ...over,
});

const snap = (id: string, r: SafetySnapshot) => new Map([[id, r]]);

describe("levels, rollup and the stage rule", () => {
    it("rolls a post up to the strictest rated level, and to pending when any item is unrated", () => {
        expect(rollupLevels(["general", "explicit", "sensitive"])).toBe("explicit");
        expect(rollupLevels(["general", "pending"])).toBe("pending");
        expect(rollupLevels(["questionable", "failed"])).toBe("pending");
        expect(rollupLevels([])).toBe("pending");
    });

    it("lets only a rated general file through, and an override wins over the model level and over gore", () => {
        expect(stageAllows(effectiveSafety("a", snap("a", row()), new Map(), cfg), cfg)).toBe(true);
        expect(stageAllows(effectiveSafety("a", snap("a", row({ level: "pending" })), new Map(), cfg), cfg)).toBe(false);
        expect(stageAllows(effectiveSafety("a", snap("a", row({ level: "failed" })), new Map(), cfg), cfg)).toBe(false);
        expect(stageAllows(effectiveSafety("a", new Map(), new Map(), cfg), cfg)).toBe(false);
        expect(stageAllows(effectiveSafety("a", snap("a", row({ level: "sensitive" })), new Map(), cfg), cfg)).toBe(false);
        expect(stageAllows(effectiveSafety("a", snap("a", row({ level: "explicit", user_level: "general" })), new Map(), cfg), cfg)).toBe(true);
        expect(stageAllows(effectiveSafety("a", snap("a", row({ level: "general", user_level: "explicit" })), new Map(), cfg), cfg)).toBe(false);
        const gory = row({ probs: JSON.stringify({ level: { general: 1, sensitive: 0, questionable: 0, explicit: 0 }, gore: 0.9, drawn: 0, minor_sexual: 0 }), gore: 1 });
        expect(stageAllows(effectiveSafety("a", snap("a", gory), new Map(), cfg), cfg)).toBe(false);
        expect(stageAllows(effectiveSafety("a", snap("a", { ...gory, user_level: "general" }), new Map(), cfg), cfg)).toBe(true);
    });

    it("hard-blocks minor_sexual even when the level and the override are general", () => {
        const minor = row({
            probs: JSON.stringify({ level: { general: 1, sensitive: 0, questionable: 0, explicit: 0 }, gore: 0, drawn: 0, minor_sexual: 0.8 }),
            minor_sexual: 1,
            user_level: "general",
        });
        expect(stageAllows(effectiveSafety("a", snap("a", minor), new Map(), cfg), cfg)).toBe(false);
    });

    it("a derived file inherits the strictest rated source until it is rated itself", () => {
        const rows = new Map<string, SafetySnapshot>([
            ["src", row({ level: "explicit" })],
            ["other", row()],
            ["crop", row({ level: "pending" })],
        ]);
        const sources = new Map<string, string[]>([
            ["crop", ["src", "other"]],
            ["src", []],
            ["other", []],
        ]);
        expect(effectiveSafety("crop", rows, sources, cfg)).toMatchObject({ level: "explicit", inherited: true, rated: true });
        expect(stageAllows(effectiveSafety("crop", rows, sources, cfg), cfg)).toBe(false);
        rows.set("crop", row({ level: "general" }));
        expect(effectiveSafety("crop", rows, sources, cfg)).toMatchObject({ level: "general", inherited: false });
        rows.set("crop", row({ level: "pending" }));
        rows.set("other", row({ level: "pending" }));
        expect(effectiveSafety("crop", rows, sources, cfg).rated).toBe(false);
    });

    it("reads the stage cap and the flag lines from config", () => {
        expect(safetyConfigFrom({}).stageMax).toBe("general");
        expect(safetyConfigFrom({ SAFETY_STAGE_MAX: "sensitive", SAFETY_GORE_AT: "0.2", SAFETY_PER_RUN: "0", SAFETY_BACKFILL: "1" })).toMatchObject({
            stageMax: "sensitive",
            goreAt: 0.2,
            perRun: 0,
            backfill: true,
        });
        expect(safetyConfigFrom({ SAFETY_STAGE_MAX: "nope", SAFETY_GORE_AT: "nope" })).toMatchObject({ stageMax: "general", goreAt: 0.5 });
    });
});

const clef = (over: Record<string, unknown> = {}) => ({
    model: "clef-omni",
    answers: {
        level: { choice: "questionable", probabilities: { general: 0.05, sensitive: 0.1, questionable: 0.8, explicit: 0.05 } },
        gore: { noul: 0.01 },
        drawn: { noul: 0.9 },
        minor_sexual: { noul: 0.02 },
        ...over,
    },
});

describe("the Clef request and answer", () => {
    it("parses a choice plus the three noul flags, and a wrapped or partial answer", () => {
        const parsed = parseClefAnswer(clef());
        expect(parsed).toMatchObject({ level: "questionable", probs: { gore: 0.01, drawn: 0.9, minor_sexual: 0.02 } });
        expect(parsed!.probs.level.questionable).toBe(0.8);
        expect(parseClefAnswer({ result: { response: clef() } })!.level).toBe("questionable");
        expect(parseClefAnswer(JSON.stringify(clef()))!.level).toBe("questionable");
        // no per-option probabilities: the chosen level is stored as 1 so a later threshold still has numbers
        expect(parseClefAnswer(clef({ level: { choice: "explicit" } }))!.probs.level).toEqual({ general: 0, sensitive: 0, questionable: 0, explicit: 1 });
        expect(parseClefAnswer(clef({ gore: {} }))).toBeNull();
        expect(parseClefAnswer({ answers: { level: { choice: "spicy" }, gore: { noul: 0 }, drawn: { noul: 0 }, minor_sexual: { noul: 0 } } })).toBeNull();
    });

    it("sends at most two videos and four stills, and a ~3MB clip plus an mp3 stays a single binding body", () => {
        const tiny = new Uint8Array([1, 2, 3, 4]);
        const capped = buildClefRequest({ videos: [tiny, tiny, tiny], audio: null, images: [tiny, tiny, tiny, tiny, tiny] });
        expect(capped.videos).toHaveLength(2);
        expect(capped.images).toHaveLength(4);
        const clip = new Uint8Array(3 * 1024 * 1024);
        const mp3 = new Uint8Array(200 * 1024);
        const req = buildClefRequest({ videos: [clip], audio: mp3, images: [] });
        expect(req.model).toBe("clef-omni");
        expect(req.videos).toHaveLength(1);
        expect(req.images).toBeUndefined();
        expect((req.videos as string[])[0]).toMatch(/^data:video\/mp4;base64,/);
        expect((req.audio as string[])[0]).toMatch(/^data:audio\/mpeg;base64,/);
        const json = JSON.stringify(req);
        // base64 expands 4/3. The binding's max body size is undocumented; this is the pilot's payload shape.
        expect(json.length).toBeGreaterThan(3_000_000);
        expect(json.length).toBeLessThan(12_000_000);
        expect(req.questions).toMatchObject({ level: { type: "choice" }, gore: { type: "noul" }, drawn: { type: "noul" }, minor_sexual: { type: "noul" } });
    });
});

const item = (db: ReturnType<typeof createFakeD1>, id: string, post: string) => {
    db.raw
        .prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, created_at, post_key) VALUES (?, 'public', 'saved', 'originals', ?, ?, 'video/mp4', 1, ?)",
        )
        .run(id, `originals/${id}.mp4`, `${id}.mp4`, post);
};

describe("rating and the post rollup", () => {
    it("stores the probabilities, and a post is the max of its items", async () => {
        const db = createFakeD1();
        item(db, "aaaabbbbccccdddd", "post-1");
        item(db, "eeeeffffgggghhhh", "post-1");
        db.raw.prepare("INSERT INTO media_safety (item_id, level, prep, clips, has_audio, attempts, updated_at) VALUES ('aaaabbbbccccdddd', 'pending', 'ready', 1, 1, 0, 1)").run();
        db.raw.prepare("INSERT INTO media_safety (item_id, level, user_level, prep, questions_version, updated_at) VALUES ('eeeeffffgggghhhh', 'general', NULL, 'ready', 'v1', 1)").run();
        const originals = new MemoryOriginals();
        const mp4 = Uint8Array.from([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 1, 2, 3, 4]);
        const mp3 = Uint8Array.from([0x49, 0x44, 0x33, 4, 0]);
        originals.objects.set(safetyClipKey("aaaabbbbccccdddd", 1), { bytes: mp4, contentType: "video/mp4", meta: {} });
        originals.objects.set(safetyAudioKey("aaaabbbbccccdddd"), { bytes: mp3, contentType: "audio/mpeg", meta: {} });
        const calls: string[] = [];
        const gaps: number[] = [];
        const r = await rateSafety({
            db: db as unknown as D1Database,
            originals: originals as never,
            ai: { run: async (model) => (calls.push(model), clef()) },
            now: () => 5_000,
            gapMs: 0,
            sleep: async (ms) => void gaps.push(ms),
            cfg,
        });
        expect(r).toMatchObject({ rated: 1, failed: 0 });
        expect(calls).toEqual([CLEF_MODEL_ID]);
        const stored = db.raw.prepare("SELECT level, questions_version, gore, drawn, minor_sexual, attempts, model FROM media_safety WHERE item_id = 'aaaabbbbccccdddd'").get() as any;
        expect(stored).toMatchObject({ level: "questionable", questions_version: QUESTIONS_VERSION, gore: 0, drawn: 1, minor_sexual: 0, attempts: 0, model: CLEF_MODEL_ID });
        const probs = db.raw.prepare("SELECT probs FROM media_safety WHERE item_id = 'aaaabbbbccccdddd'").get() as { probs: string };
        expect(JSON.parse(probs.probs).level.questionable).toBe(0.8);
        expect(await postSafetyLevel(db as unknown as D1Database, "post-1", cfg)).toBe("questionable");
        expect(gaps).toEqual([]);
    });

    it("a missing clip fails the attempt, and three failures are enough", async () => {
        const db = createFakeD1();
        item(db, "aaaabbbbccccdddd", "p");
        db.raw.prepare("INSERT INTO media_safety (item_id, level, prep, clips, attempts, updated_at) VALUES ('aaaabbbbccccdddd', 'pending', 'ready', 1, 0, 1)").run();
        const originals = new MemoryOriginals();
        const once = await rateSafety({ db: db as unknown as D1Database, originals: originals as never, ai: { run: async () => clef() }, now: () => 9, gapMs: 0, cfg });
        expect(once.failed).toBe(1);
        expect(db.raw.prepare("SELECT level, attempts FROM media_safety").get()).toMatchObject({ level: "failed", attempts: 1 });
        db.raw.prepare("UPDATE media_safety SET attempts = 3, level = 'failed', failed_at = 1").run();
        const stopped = await rateSafety({ db: db as unknown as D1Database, originals: originals as never, ai: { run: async () => clef() }, now: () => 9, gapMs: 0, cfg });
        expect(stopped.rated + stopped.failed).toBe(0);
    });

    it("loads the stored clip, the second segment and up to four stills", async () => {
        const originals = new MemoryOriginals();
        const jpeg = Uint8Array.from([0xff, 0xd8, 0xff, 1]);
        originals.objects.set(safetyClipKey("i", 1), { bytes: Uint8Array.from([1]), contentType: "video/mp4", meta: {} });
        originals.objects.set(safetyClipKey("i", 2), { bytes: Uint8Array.from([2]), contentType: "video/mp4", meta: {} });
        originals.objects.set(safetyStillKey("i", 1), { bytes: jpeg, contentType: "image/jpeg", meta: {} });
        const media = await loadSafetyMedia(originals, "i", 2, 1, false);
        expect(media).toMatchObject({ videos: [Uint8Array.from([1]), Uint8Array.from([2])], audio: null });
        expect(media!.images).toEqual([jpeg]);
        expect(await loadSafetyMedia(originals, "i", 1, 0, true)).toBeNull();
    });
});

const NOW = 1_800_000_000_000;
const idN = (prefix: string, n: number) => `${prefix}${String(n).padStart(16 - prefix.length, "0")}`;
const mp4 = Uint8Array.from([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 1, 2, 3, 4]);

const visual = (db: ReturnType<typeof createFakeD1>, id: string) => {
    db.raw
        .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, created_at) VALUES (?, 'public', 'saved', 'originals', ?, ?, 'video/mp4', ?)")
        .run(id, `originals/${id}.mp4`, `${id}.mp4`, 1);
};

const putLabels = (originals: MemoryOriginals, items: { id: string; label: string }[]) => {
    originals.objects.set(PILOT_LABELS_KEY, {
        bytes: new TextEncoder().encode(JSON.stringify({ items })),
        contentType: "application/json",
        meta: {},
    });
};

const putClip = (originals: MemoryOriginals, id: string) => {
    originals.objects.set(safetyClipKey(id, 1), { bytes: mp4, contentType: "video/mp4", meta: {} });
};

describe("the pilot rating queue", () => {
    const rate = (db: ReturnType<typeof createFakeD1>, originals: MemoryOriginals, calls: string[]) =>
        rateSafety({
            db: db as unknown as D1Database,
            originals: originals as never,
            ai: { run: async (model) => (calls.push(model), clef()) },
            now: () => NOW,
            gapMs: 0,
            cfg,
        });

    it("rates a ready file that sits behind clips that are not ready, and does not spend the cap on them", async () => {
        const db = createFakeD1();
        const originals = new MemoryOriginals();
        const waiting = Array.from({ length: SAFETY_PILOT_PER_RUN }, (_, i) => idN("p", i));
        const ready = idN("r", 1);
        for (const id of waiting) {
            visual(db, id);
            db.raw.prepare("INSERT INTO media_safety (item_id, level, prep, updated_at) VALUES (?, 'pending', 'pending', 1)").run(id);
        }
        visual(db, ready);
        db.raw.prepare("INSERT INTO media_safety (item_id, level, prep, clips, has_audio, attempts, updated_at) VALUES (?, 'pending', 'ready', 1, 0, 0, 1)").run(ready);
        putClip(originals, ready);
        putLabels(originals, [...waiting.map((id) => ({ id, label: "not yet" })), { id: ready, label: "ready" }]);
        const calls: string[] = [];
        const r = await rate(db, originals, calls);
        expect(r).toMatchObject({ rated: 1, failed: 0, pilot: 1 });
        expect(calls).toEqual([CLEF_MODEL_ID]);
        const report = await readPilotReport(originals);
        expect(report?.rows.find((row) => row.id === ready)?.clef).toMatchObject({ level: "questionable" });
        expect(report?.rows.filter((row) => row.error === "not_ready").map((row) => row.id).sort()).toEqual([...waiting].sort());
        expect(await readPilotLabels(originals)).not.toBeNull();
    });

    it("records a prep failure that is not due as failed, and rates the file once its clip is ready", async () => {
        const db = createFakeD1();
        const originals = new MemoryOriginals();
        const blocked = idN("b", 1);
        const retrying = idN("y", 1);
        const ready = idN("r", 1);
        visual(db, blocked);
        visual(db, retrying);
        visual(db, ready);
        db.raw.prepare("INSERT INTO media_safety (item_id, level, prep, prep_at, prep_attempts, updated_at) VALUES (?, 'pending', 'failed', ?, 1, 1)").run(blocked, NOW);
        db.raw.prepare("INSERT INTO media_safety (item_id, level, prep, prep_at, prep_attempts, updated_at) VALUES (?, 'pending', 'failed', ?, 1, 1)").run(retrying, NOW - SAFETY_RETRY_MS - 1);
        db.raw.prepare("INSERT INTO media_safety (item_id, level, prep, clips, has_audio, attempts, updated_at) VALUES (?, 'pending', 'ready', 1, 0, 0, 1)").run(ready);
        putClip(originals, ready);
        putLabels(originals, [
            { id: blocked, label: "prep failed" },
            { id: retrying, label: "retry due" },
            { id: ready, label: "ready" },
        ]);
        const calls: string[] = [];
        const first = await rate(db, originals, calls);
        expect(first).toMatchObject({ rated: 1, pilot: 1 });
        expect(calls).toEqual([CLEF_MODEL_ID]);
        const report = await readPilotReport(originals);
        expect(report?.rows.find((row) => row.id === blocked)).toMatchObject({ clef: null, error: "failed" });
        expect(report?.rows.find((row) => row.id === retrying)).toMatchObject({ error: "not_ready" });
        expect(report?.rows.find((row) => row.id === ready)?.clef).toMatchObject({ level: "questionable" });
        // The blocked id still has a retry left, so the labels stay and the ordinary queue does not start.
        expect(await readPilotLabels(originals)).not.toBeNull();

        db.raw.prepare("UPDATE media_safety SET prep = 'ready', clips = 1, level = 'pending', prep_attempts = 0 WHERE item_id = ?").run(blocked);
        putClip(originals, blocked);
        const second = await rate(db, originals, calls);
        expect(second).toMatchObject({ rated: 1, pilot: 1 });
        expect(calls).toHaveLength(2);
        const after = await readPilotReport(originals);
        expect(after?.rows.find((row) => row.id === blocked)?.clef).toMatchObject({ level: "questionable" });
        expect(after?.rows.find((row) => row.id === blocked)?.error).toBeNull();
    });

    it("drops the labels once a prep failure has no retries left and nothing else is waiting", async () => {
        const db = createFakeD1();
        const originals = new MemoryOriginals();
        const blocked = idN("b", 1);
        visual(db, blocked);
        db.raw
            .prepare("INSERT INTO media_safety (item_id, level, prep, prep_at, prep_attempts, updated_at) VALUES (?, 'pending', 'failed', ?, ?, 1)")
            .run(blocked, NOW, SAFETY_MAX_ATTEMPTS);
        putLabels(originals, [{ id: blocked, label: "gave up" }]);
        const calls: string[] = [];
        const r = await rate(db, originals, calls);
        expect(r).toMatchObject({ rated: 0, failed: 0, pilot: 0 });
        expect(calls).toEqual([]);
        expect((await readPilotReport(originals))?.rows).toEqual([{ id: blocked, label: "gave up", clef: null, error: "failed" }]);
        expect(await readPilotLabels(originals)).toBeNull();
    });

    it("rates at most the pilot cap of ready files, in label order", async () => {
        const db = createFakeD1();
        const originals = new MemoryOriginals();
        const ids = Array.from({ length: SAFETY_PILOT_PER_RUN + 1 }, (_, i) => idN("q", i));
        for (const id of ids) {
            visual(db, id);
            db.raw.prepare("INSERT INTO media_safety (item_id, level, prep, clips, has_audio, attempts, updated_at) VALUES (?, 'pending', 'ready', 1, 0, 0, 1)").run(id);
            putClip(originals, id);
        }
        putLabels(originals, ids.map((id) => ({ id, label: "ready" })));
        const calls: string[] = [];
        const first = await rate(db, originals, calls);
        expect(first).toMatchObject({ rated: SAFETY_PILOT_PER_RUN, pilot: SAFETY_PILOT_PER_RUN });
        const report = await readPilotReport(originals);
        const rated = new Set((report?.rows ?? []).filter((row) => row.clef && row.error == null).map((row) => row.id));
        expect(rated).toEqual(new Set(ids.slice(0, SAFETY_PILOT_PER_RUN)));
        expect(rated.has(ids[SAFETY_PILOT_PER_RUN]!)).toBe(false);
        expect(await readPilotLabels(originals)).not.toBeNull();
        const second = await rate(db, originals, calls);
        expect(second).toMatchObject({ rated: 1, pilot: 1 });
        expect(await readPilotLabels(originals)).toBeNull();
    });
});

describe("the pilot list", () => {
    it("reads up to 60 labelled ids and lines Clef up next to the label", () => {
        const labels = parsePilotLabels({ items: [{ id: "aaaabbbbccccdddd", label: " fursuit " }, { id: "bad id", label: "x" }, { id: "aaaabbbbccccdddd", label: "again" }] });
        expect(labels).toEqual([{ id: "aaaabbbbccccdddd", label: "fursuit" }]);
        expect(parsePilotLabels({ items: [] })).toBeNull();
        const text = formatPilotReport(labels!, {
            labels_hash: "h",
            rows: [{ id: "aaaabbbbccccdddd", label: "fursuit", clef: { level: "sensitive", probs: {}, gore: false, drawn: true, minor_sexual: false, model: CLEF_MODEL_ID }, error: null }],
        });
        expect(text).toContain("aaaabbbbccccdddd\tfursuit\tsensitive\tno\tyes\tno");
        expect(PILOT_LABELS_KEY).toBe("about/pilot-labels.json");
        expect(PILOT_REPORT_KEY).toBe("about/pilot-report.json");
    });
});
