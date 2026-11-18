// Background removal (section 67): the route, with Bria mocked, and the filter the job sends.
import { beforeEach, describe, expect, it } from "vitest";
import { hashKey } from "../src/keys";
import { briaInput, estimateUsd, handleRmbgRoute, RmbgService, RMBG_MODEL, videoUrlOf } from "../src/rmbg";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { MemoryKV, MemoryOriginals } from "./studio-fakes";

const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const KEY_ID = "key-row-1";
const ITEM = "Ab3dE6gH9jK2mN5p";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";

let db: FakeD1;
let originals: MemoryOriginals;
let jobs: Promise<unknown>[];
let aiCalls: { model: string; input: Record<string, unknown> }[];
let service: RmbgService;

const ai = {
    async run(model: string, input: Record<string, unknown>) {
        aiCalls.push({ model, input });
        return { state: "Completed", result: { video: "https://bria.example/out.mov" } };
    },
};

beforeEach(async () => {
    db = createFakeD1();
    originals = new MemoryOriginals();
    jobs = [];
    aiCalls = [];
    originals.objects.set("originals/a.mp4", { bytes: new Uint8Array([1, 2, 3]), contentType: "video/mp4", meta: {} });
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run(KEY_ID, "test", await hashKey(CLIENT), "0b5f2c3e", 1);
    db.raw
        .prepare(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, duration, width, height, created_at) VALUES (?, 'private', 'saved', 'originals', 'originals/a.mp4', 'clip.mp4', 'video/mp4', 3, ?, 320, 180, 1)",
        )
        .run(ITEM, 4);
    service = new RmbgService({
        storage: new MemoryKV(),
        db: db as unknown as D1Database,
        originals,
        ai,
        now: () => 1_000,
        sleep: async () => {},
        fetch: async () => new Response(new Uint8Array([9, 9, 9, 9])),
        waitUntil: (p) => {
            jobs.push(p);
        },
    });
});

const env = (): WorkerEnv => ({
    API_URL: "https://api.capybaraharmony.com/",
    CORS_URL: "https://cobalt.capybaraharmony.com",
    COBALT_API_KEY: INTERNAL,
    DB: db as unknown as D1Database,
    ORIGINALS: originals,
    MEDIA: { async put() { return null; }, async delete() {}, async get() { return null; }, async head() { return null; } } as never,
    MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
    AI: ai,
});

const container = {
    async fetch(r: Request) {
        const path = new URL(r.url).pathname;
        if (path === "/rmbg" || /^\/rmbg\/[^/]+$/.test(path)) return handleRmbgRoute(service, r);
        return new Response("no", { status: 404 });
    },
};

const auth = { authorization: `Api-Key ${CLIENT}` };

describe("bria input", () => {
    it("is the documented call: transparent prores, spill, a public video url", () => {
        expect(briaInput("https://api.example/rmbg/media/tok", 0.4)).toEqual({
            video: "https://api.example/rmbg/media/tok",
            background_color: "Transparent",
            output_container_and_codec: "mov_proresks",
            preserve_audio: true,
            spill_suppression: 0.4,
            auto_zoom: false,
        });
        expect(estimateUsd(4)).toBeCloseTo(0.09, 5);
        expect(estimateUsd(60)).toBeCloseTo(1.35, 5);
        expect(videoUrlOf({ state: "Completed", result: { video: "https://x/y.mov", warning: "kept" } })).toEqual({ video: "https://x/y.mov", warning: "kept" });
        expect(videoUrlOf({ state: "Queued" })).toBeNull();
    });
});

describe("POST /library/items/:id/rmbg", () => {
    it("refuses a clip over 60 s and does not call Bria", async () => {
        db.raw.prepare("UPDATE media_items SET duration = 61 WHERE id = ?").run(ITEM);
        const res = await handleRequest(new Request(`https://api.capybaraharmony.com/library/items/${ITEM}/rmbg`, { method: "POST", headers: auth, body: "{}" }), env(), container);
        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.rmbg.too_long" } });
        expect(aiCalls).toEqual([]);
    });

    it("starts a job, calls Bria with a signed url, and stores a private prores alternate", async () => {
        const res = await handleRequest(
            new Request(`https://api.capybaraharmony.com/library/items/${ITEM}/rmbg`, { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: JSON.stringify({ spill: 0.4 }) }),
            env(),
            container,
        );
        expect(res.status).toBe(202);
        const started = (await res.json()) as { id: string; estimate_usd: number; seconds: number };
        expect(started.seconds).toBe(4);
        expect(started.estimate_usd).toBeCloseTo(0.09, 5);
        await Promise.all(jobs);
        expect(aiCalls).toHaveLength(1);
        expect(aiCalls[0]!.model).toBe(RMBG_MODEL);
        expect(aiCalls[0]!.input.background_color).toBe("Transparent");
        expect(aiCalls[0]!.input.output_container_and_codec).toBe("mov_proresks");
        expect(aiCalls[0]!.input.spill_suppression).toBe(0.4);
        expect(String(aiCalls[0]!.input.video)).toMatch(/^https:\/\/api\.capybaraharmony\.com\/rmbg\/media\//);
        const quote = await handleRequest(new Request(`https://api.capybaraharmony.com/library/items/${ITEM}/rmbg`, { headers: auth }), env(), container);
        expect((await quote.json()) as { estimate_usd: number }).toMatchObject({ seconds: 4, max_seconds: 60, too_long: false });
        const got = await handleRequest(new Request(`https://api.capybaraharmony.com/library/items/${ITEM}/rmbg/${started.id}`, { headers: auth }), env(), container);
        const body = (await got.json()) as { status: string; item_id: string; content_type: string };
        expect(body.status).toBe("success");
        expect(body.content_type).toBe("video/quicktime");
        const row = db.raw.prepare("SELECT role, content_type, made_spec, made_from FROM media_items WHERE id = ?").get(body.item_id) as { role: string; content_type: string; made_spec: string; made_from: string };
        expect(row.role).toBe("alt");
        expect(row.content_type).toBe("video/quicktime");
        expect(JSON.parse(row.made_spec).kind).toBe("rmbg");
        expect(JSON.parse(row.made_from)).toEqual([ITEM]);
        expect([...originals.objects.keys()].some((k) => k.startsWith("rmbg/") && k.endsWith(".mov"))).toBe(true);
    });

    it("tells the Live Activity this is background removal, not a webp", async () => {
        const seen: { kind: string; work?: string }[] = [];
        db.raw.prepare("UPDATE media_items SET session_id = ? WHERE id = ?").run("S".repeat(22), ITEM);
        const live = {
            onRender: async (_sid: string, _job: string, e: { kind: string; work?: string }) => {
                seen.push({ kind: e.kind, work: e.work });
            },
        };
        const watched = new RmbgService({
            storage: new MemoryKV(),
            db: db as unknown as D1Database,
            originals,
            ai,
            now: () => 1_000,
            sleep: async () => {},
            fetch: async () => new Response(new Uint8Array([9, 9, 9, 9])),
            waitUntil: (p) => {
                jobs.push(p);
            },
            live,
        });
        const local = {
            async fetch(r: Request) {
                const path = new URL(r.url).pathname;
                if (path === "/rmbg" || /^\/rmbg\/[^/]+$/.test(path)) return handleRmbgRoute(watched, r);
                return new Response("no", { status: 404 });
            },
        };
        const res = await handleRequest(
            new Request(`https://api.capybaraharmony.com/library/items/${ITEM}/rmbg`, { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: "{}" }),
            env(),
            local,
        );
        expect(res.status).toBe(202);
        await Promise.all(jobs);
        expect(seen.map((e) => e.kind)).toEqual(["accepted", "pending", "success"]);
        expect(seen.every((e) => e.work === "rmbg")).toBe(true);
    });
});
