import { beforeEach, describe, expect, it } from "vitest";
import { KEY_ID_HEADER } from "../src/headers";
import { StudioService } from "../src/studio";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { MemoryOriginals, fixedLength } from "./studio-fakes";
import {
    MAX_WAIT_SECONDS,
    RECORD_TTL_MS,
    WebpService,
    handleWebpRoute,
    isWebpRoute,
    mintId,
    mintName,
    parseWait,
    randomBase62,
    serviceFromUrl,
    shapeSuccess,
    validateParams,
    type JobRecord,
    type KV,
    type MediaBucket,
    type WebpDeps,
} from "../src/webp";

const URL_OK = "https://twitter.com/X/status/1697304622749086011";
// no length: the whole video (the helper gates it with WEBP_MAX_SECONDS)
const defaults = { url: URL_OK, start: 0, width: 480, fps: 15, quality: "med" };

describe("validateParams", () => {
    it("fills the documented defaults", () => {
        expect(validateParams({ url: URL_OK })).toEqual({ ok: true, params: defaults });
    });
    it("leaves length unset when omitted, null or empty", () => {
        for (const length of [undefined, null, ""]) {
            const r = validateParams({ url: URL_OK, length });
            expect(r.ok && "length" in r.params).toBe(false);
        }
    });
    it("bounds length to 1..600", () => {
        expect(validateParams({ url: URL_OK, length: 600 })).toMatchObject({ ok: true, params: { length: 600 } });
        expect(validateParams({ url: URL_OK, length: "45" })).toMatchObject({ ok: true, params: { length: 45 } });
        expect(validateParams({ url: URL_OK, length: 1 }).ok).toBe(true);
        expect(validateParams({ url: URL_OK, length: 601 })).toEqual({ ok: false });
        expect(validateParams({ url: URL_OK, length: 0.5 })).toEqual({ ok: false });
    });
    it("accepts every field at its bounds", () => {
        const r = validateParams({ url: URL_OK, start: 3600, length: 600, width: 640, fps: 25, quality: "high" });
        expect(r).toMatchObject({ ok: true, params: { start: 3600, length: 600, width: 640, fps: 25, quality: "high" } });
        expect(validateParams({ url: URL_OK, start: 0, length: 1, width: 320, fps: 10, quality: "low" }).ok).toBe(true);
    });
    it("accepts numeric strings (Shortcuts) and treats empty/null as default", () => {
        expect(validateParams({ url: URL_OK, start: "12.5", length: "3", width: "320", fps: "20", quality: "" })).toMatchObject({
            ok: true,
            params: { start: 12.5, length: 3, width: 320, fps: 20, quality: "med" },
        });
        expect(validateParams({ url: URL_OK, start: null, length: "" }).ok).toBe(true);
    });
    it.each([
        ["not an object", "x"],
        ["array", []],
        ["null", null],
        ["no url", {}],
        ["empty url", { url: "" }],
        ["numeric url", { url: 5 }],
        ["url over 2048", { url: "https://a.test/" + "x".repeat(2040) }],
        ["not a url", { url: "not a url" }],
        ["ftp url", { url: "ftp://a.test/v" }],
        ["javascript url", { url: "javascript:alert(1)" }],
        ["start -1", { url: URL_OK, start: -1 }],
        ["start 3601", { url: URL_OK, start: 3601 }],
        ["start NaN string", { url: URL_OK, start: "abc" }],
        ["start Infinity", { url: URL_OK, start: "Infinity" }],
        ["length 0", { url: URL_OK, length: 0 }],
        ["length 600.5", { url: URL_OK, length: 600.5 }],
        ["length NaN string", { url: URL_OK, length: "abc" }],
        ["width 500", { url: URL_OK, width: 500 }],
        ["width 1080", { url: URL_OK, width: 1080 }],
        ["fps 9", { url: URL_OK, fps: 9 }],
        ["fps 26", { url: URL_OK, fps: 26 }],
        ["fps 12.5", { url: URL_OK, fps: 12.5 }],
        ["quality ultra", { url: URL_OK, quality: "ultra" }],
        ["quality number", { url: URL_OK, quality: 70 }],
        ["boolean start", { url: URL_OK, start: true }],
    ])("rejects %s", (_n, body) => {
        expect(validateParams(body)).toEqual({ ok: false });
    });
    it("accepts a url of exactly 2048 characters", () => {
        const u = "https://a.test/" + "x".repeat(2048 - 15);
        expect(u.length).toBe(2048);
        expect(validateParams({ url: u }).ok).toBe(true);
    });
});

describe("parseWait", () => {
    it("defaults to 20, clamps to 0..25, ignores junk", () => {
        expect(parseWait(null)).toBe(20);
        expect(parseWait("")).toBe(20);
        expect(parseWait("abc")).toBe(20);
        expect(parseWait("5")).toBe(5);
        expect(parseWait("0")).toBe(0);
        expect(parseWait("-3")).toBe(0);
        expect(parseWait("999")).toBe(MAX_WAIT_SECONDS);
    });
});

describe("ids and names", () => {
    it("mintId is 20 base62 characters, mintName is 10 + .webp", () => {
        for (let i = 0; i < 50; i++) {
            expect(mintId()).toMatch(/^[A-Za-z0-9]{20}$/);
            expect(mintName()).toMatch(/^[A-Za-z0-9]{10}\.webp$/);
        }
    });
    it("is not constant", () => {
        expect(new Set(Array.from({ length: 20 }, () => mintId())).size).toBe(20);
    });
    it("maps bytes deterministically and discards the biased range (>= 248)", () => {
        // 0..61 -> alphabet order; 62 wraps to '0'; 248..255 are skipped
        const seq = [0, 9, 10, 35, 36, 61, 62, 247, 248, 255, 1, 2];
        // 247 % 62 = 61 -> 'z'; 248 and 255 contribute nothing
        expect(randomBase62(9, () => Uint8Array.from(seq))).toBe("09AZaz0z1");
    });
    it("keeps asking for bytes until it has enough", () => {
        let calls = 0;
        const rb = (n: number) => {
            calls++;
            return new Uint8Array(n).fill(calls === 1 ? 255 : 3);
        };
        expect(randomBase62(4, rb)).toBe("3333");
        expect(calls).toBe(2);
    });
});

describe("serviceFromUrl and shapeSuccess", () => {
    it("takes the second-level label", () => {
        expect(serviceFromUrl("https://www.twitter.com/x")).toBe("twitter");
        expect(serviceFromUrl("https://x.com/a/status/1")).toBe("x");
        expect(serviceFromUrl("https://vm.tiktok.com/abc")).toBe("tiktok");
        expect(serviceFromUrl("nope")).toBe("unknown");
    });
    it("builds the public URL with exactly one slash", () => {
        const done = { bytes: 10, width: 480, height: 270, seconds: 6 };
        expect(shapeSuccess("i", "https://m.test/", "a.webp", done).url).toBe("https://m.test/a.webp");
        expect(shapeSuccess("i", "https://m.test", "a.webp", done).url).toBe("https://m.test/a.webp");
        expect(shapeSuccess("i", "https://m.test/", "a.webp", done)).toEqual({
            status: "success",
            id: "i",
            url: "https://m.test/a.webp",
            bytes: 10,
            width: 480,
            height: 270,
            seconds: 6,
        });
    });
});

// --- service with fakes ------------------------------------------------------

class MemKV implements KV {
    m = new Map<string, unknown>();
    async get<T>(k: string) {
        return this.m.get(k) as T | undefined;
    }
    async put(k: string, v: unknown) {
        this.m.set(k, v);
    }
    async delete(k: string) {
        return this.m.delete(k);
    }
    async list<T>(o: { prefix: string }) {
        return new Map([...this.m].filter(([k]) => k.startsWith(o.prefix))) as Map<string, T>;
    }
}

type HelperJob = { status: "pending"; phase?: unknown; frames_done?: unknown; frames_total?: unknown } | { status: "done"; bytes: number; width: number; height: number; seconds: number; service?: string } | { status: "error"; code: string };

let kv: MemKV;
let clock: number;
let puts: { key: string; size: number; opts: Parameters<MediaBucket["put"]>[2] }[];
let deletes: string[];
let helperCalls: { path: string; method: string }[];
let helperJobs: Map<string, HelperJob>;
let busy: boolean;
let helperDown: boolean;
let putFails: boolean;
let ensureFails: boolean;
let fileBytes: Uint8Array;
let svc: WebpService;
let deps: WebpDeps;

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status });

beforeEach(() => {
    kv = new MemKV();
    clock = 1_800_000_000_000;
    puts = [];
    deletes = [];
    helperCalls = [];
    helperJobs = new Map();
    busy = false;
    helperDown = false;
    putFails = false;
    ensureFails = false;
    fileBytes = new Uint8Array(1234).fill(7);

    deps = {
        storage: kv,
        bucket: {
            async put(key, value, opts) {
                if (putFails) throw new Error("r2 down");
                puts.push({ key, size: value.byteLength, opts });
            },
            async delete(key) {
                deletes.push(key);
                if (putFails) throw new Error("r2 down");
            },
        },
        mediaBaseUrl: "https://media.test/",
        now: () => clock,
        sleep: async (ms) => {
            clock += ms;
        },
        ensureRunning: async () => {
            if (ensureFails) throw new Error("no container");
        },
        helper: async (path, init) => {
            const method = init?.method ?? "GET";
            helperCalls.push({ path, method });
            if (helperDown) throw new Error("network");
            if (path === "/jobs" && method === "POST") {
                if (busy) return json(429, { status: "error", error: { code: "error.webp.busy" } });
                const b = JSON.parse(String(init!.body));
                helperJobs.set(b.id, { status: "pending" });
                return json(202, { status: "pending", id: b.id });
            }
            const m = path.match(/^\/jobs\/([A-Za-z0-9]+)(\/file)?$/)!;
            const job = helperJobs.get(m[1]);
            if (!job) return json(404, { status: "error", error: { code: "error.webp.not_found" } });
            if (method === "DELETE") {
                helperJobs.delete(m[1]);
                return json(200, { status: "success" });
            }
            if (m[2]) return new Response(fileBytes);
            if (job.status === "error") return json(200, { status: "error", error: { code: job.code } });
            return json(200, job);
        },
    };
    svc = new WebpService(deps);
});

const create = async (keyId = "k1", body: unknown = { url: URL_OK }) => {
    const r = await svc.create(keyId, JSON.stringify(body));
    return { ...r, id: (r.body as { id?: string }).id! };
};
const finishJob = (id: string, over: Partial<Extract<HelperJob, { status: "done" }>> = {}) =>
    helperJobs.set(id, { status: "done", bytes: 1234, width: 480, height: 270, seconds: 6, ...over });

describe("WebpService.create", () => {
    it("rejects bad bodies with invalid_params and does not touch the container", async () => {
        for (const raw of ["not json", "{}", '{"url":"x"}', JSON.stringify({ url: URL_OK, fps: 99 }), "x".repeat(9000)]) {
            const r = await svc.create("k1", raw);
            expect(r).toEqual({ status: 400, body: { status: "error", error: { code: "error.webp.invalid_params" } } });
        }
        expect(helperCalls).toHaveLength(0);
    });
    it("starts a helper job with the defaulted params and answers 202 pending", async () => {
        const r = await create();
        expect(r.status).toBe(202);
        expect(r.body).toEqual({ status: "pending", id: r.id });
        expect(r.id).toMatch(/^[A-Za-z0-9]{20}$/);
        expect(helperCalls).toEqual([{ path: "/jobs", method: "POST" }]);
        expect(await kv.get<JobRecord>(`job:${r.id}`)).toEqual({ keyId: "k1", createdAt: clock, params: defaults });
    });
    it("429 busy when the helper is encoding, and stores nothing", async () => {
        busy = true;
        const r = await create();
        expect(r).toMatchObject({ status: 429, body: { status: "error", error: { code: "error.webp.busy" } } });
        expect([...kv.m.keys()]).toEqual([]);
    });
    it("503 when the container cannot start, 502 when the helper is unreachable", async () => {
        ensureFails = true;
        expect(await create()).toMatchObject({ status: 503, body: { error: { code: "error.webp.unavailable" } } });
        ensureFails = false;
        helperDown = true;
        expect(await create()).toMatchObject({ status: 502, body: { error: { code: "error.webp.unavailable" } } });
    });
});

describe("WebpService.status", () => {
    it("404 not_found for an unknown id and for another key's job", async () => {
        const nf = { status: 404, body: { status: "error", error: { code: "error.webp.not_found" } } };
        expect(await svc.status("k1", "Z".repeat(20), 0)).toEqual(nf);
        const { id } = await create("k1");
        expect(await svc.status("k2", id, 0)).toEqual(nf);
        expect(helperCalls.filter((c) => c.path.startsWith(`/jobs/${id}`))).toHaveLength(0);
    });
    it("pending with wait=0 polls once; with wait=N it polls about once a second, then gives up pending", async () => {
        const { id } = await create();
        helperCalls.length = 0;
        expect(await svc.status("k1", id, 0)).toEqual({
            status: 200,
            body: { status: "pending", id, phase: null, frames_done: null, frames_total: null },
        });
        expect(helperCalls).toHaveLength(1);
        helperCalls.length = 0;
        const t0 = clock;
        expect(await svc.status("k1", id, 5)).toEqual({
            status: 200,
            body: { status: "pending", id, phase: null, frames_done: null, frames_total: null },
        });
        expect(helperCalls.length).toBe(6); // t = 0..5 s
        expect(clock - t0).toBe(5000);
    });
    it("returns as soon as the job finishes while waiting", async () => {
        const { id } = await create();
        let polls = 0;
        const orig = helperJobs.get.bind(helperJobs);
        helperJobs.get = (k: string) => {
            if (k === id && ++polls === 3) finishJob(id);
            return orig(k);
        };
        const r = await svc.status("k1", id, 20);
        expect(r.status).toBe(200);
        expect(r.body).toMatchObject({ status: "success", id });
        expect(clock).toBeLessThan(1_800_000_000_000 + 5000);
    });
    it("done: uploads to R2 with the pinned metadata, stores the result, frees the helper", async () => {
        const { id } = await create("k1", { url: URL_OK });
        finishJob(id);
        const r = await svc.status("k1", id, 0);
        expect(puts).toHaveLength(1);
        const put = puts[0];
        expect(put.key).toMatch(/^[A-Za-z0-9]{10}\.webp$/);
        expect(put.size).toBe(1234);
        expect(put.opts).toEqual({
            httpMetadata: { contentType: "image/webp", cacheControl: "public, max-age=31536000, immutable" },
            customMetadata: { keyId: "k1", source: URL_OK, service: "twitter", createdAt: String(clock) },
        });
        expect(r).toEqual({
            status: 200,
            body: { status: "success", id, url: `https://media.test/${put.key}`, bytes: 1234, width: 480, height: 270, seconds: 6 },
        });
        expect(await kv.get(`result:${id}`)).toEqual(r.body);
        expect(helperCalls.at(-1)).toEqual({ path: `/jobs/${id}`, method: "DELETE" });
        expect(helperJobs.has(id)).toBe(false);
    });
    it("uses the helper's service name when it sends one", async () => {
        const { id } = await create();
        finishJob(id, { service: "twitter-gif" });
        await svc.status("k1", id, 0);
        expect(puts[0].opts.customMetadata.service).toBe("twitter-gif");
    });
    it("a second poll returns the stored result without touching the helper or R2 again", async () => {
        const { id } = await create();
        finishJob(id);
        const first = await svc.status("k1", id, 0);
        helperCalls.length = 0;
        const second = await svc.status("k1", id, 20);
        expect(second).toEqual(first);
        expect(helperCalls).toHaveLength(0);
        expect(puts).toHaveLength(1);
    });
    it("concurrent polls of the same finished job upload exactly once and agree", async () => {
        const { id } = await create();
        finishJob(id);
        const [a, b, c] = await Promise.all([svc.status("k1", id, 0), svc.status("k1", id, 0), svc.status("k1", id, 0)]);
        expect(puts).toHaveLength(1);
        expect(b).toEqual(a);
        expect(c).toEqual(a);
        expect(a.body).toMatchObject({ status: "success" });
    });
    it("passes the helper's error code through, stably", async () => {
        const { id } = await create();
        helperJobs.set(id, { status: "error", code: "error.api.content.video.unavailable" });
        const want = { status: 200, body: { status: "error", error: { code: "error.api.content.video.unavailable" } } };
        expect(await svc.status("k1", id, 0)).toEqual(want);
        helperCalls.length = 0;
        expect(await svc.status("k1", id, 0)).toEqual(want);
        expect(helperCalls).toHaveLength(0);
        expect(puts).toHaveLength(0);
    });
    it("job_lost when the helper no longer knows the id (container restarted)", async () => {
        const { id } = await create();
        helperJobs.delete(id);
        expect(await svc.status("k1", id, 0)).toEqual({
            status: 200,
            body: { status: "error", error: { code: "error.webp.job_lost" } },
        });
    });
    it("an R2 failure is not stored: the next poll retries the upload", async () => {
        const { id } = await create();
        finishJob(id);
        putFails = true;
        expect(await svc.status("k1", id, 0)).toMatchObject({ status: 502, body: { error: { code: "error.webp.storage" } } });
        expect(await kv.get(`result:${id}`)).toBeUndefined();
        expect(helperJobs.has(id)).toBe(true);
        putFails = false;
        expect((await svc.status("k1", id, 0)).body).toMatchObject({ status: "success" });
        expect(puts).toHaveLength(1);
    });
    it("an unreachable helper just keeps the job pending until the deadline", async () => {
        const { id } = await create();
        helperDown = true;
        expect(await svc.status("k1", id, 2)).toEqual({
            status: 200,
            body: { status: "pending", id, phase: null, frames_done: null, frames_total: null },
        });
    });
});

describe("WebpService render progress (APP-API-CONTRACT.md section 4)", () => {
    const pending = (id: string, extra: Record<string, unknown>) => helperJobs.set(id, { status: "pending", ...extra });

    it("a pending answer carries the helper's phase and frame counts", async () => {
        const { id } = await create();
        pending(id, { phase: "decode", frames_done: 42, frames_total: 150 });
        expect(await svc.status("k1", id, 0)).toEqual({
            status: 200,
            body: { status: "pending", id, phase: "decode", frames_done: 42, frames_total: 150 },
        });
        pending(id, { phase: "pack", frames_done: 148, frames_total: 148 });
        expect((await svc.status("k1", id, 0)).body).toMatchObject({ phase: "pack", frames_done: 148, frames_total: 148 });
        pending(id, { phase: "fetching", frames_done: null, frames_total: null });
        expect((await svc.status("k1", id, 0)).body).toMatchObject({ phase: "fetching", frames_done: null, frames_total: null });
    });
    it("a wait that runs out answers with the latest progress it saw", async () => {
        const { id } = await create();
        pending(id, { phase: "decode", frames_done: 3, frames_total: 150 });
        const r = await svc.status("k1", id, 3);
        expect(r.body).toEqual({ status: "pending", id, phase: "decode", frames_done: 3, frames_total: 150 });
    });
    it("an unknown phase or junk counts are reported as unknown, never passed through", async () => {
        const { id } = await create();
        pending(id, { phase: "reticulating", frames_done: 5, frames_total: 10 });
        expect((await svc.status("k1", id, 0)).body).toMatchObject({ phase: null, frames_done: null, frames_total: null });
        pending(id, { phase: "decode", frames_done: -1, frames_total: 1.5 });
        expect((await svc.status("k1", id, 0)).body).toMatchObject({ phase: "decode", frames_done: null, frames_total: null });
        pending(id, { phase: "decode", frames_done: "7", frames_total: null });
        expect((await svc.status("k1", id, 0)).body).toMatchObject({ phase: "decode", frames_done: null, frames_total: null });
    });
    it("progress is per job and forgotten once the job ends", async () => {
        const a = await create();
        const b = await create();
        pending(a.id, { phase: "decode", frames_done: 9, frames_total: 10 });
        pending(b.id, { phase: "pack", frames_done: 4, frames_total: 4 });
        await svc.status("k1", a.id, 0);
        await svc.status("k1", b.id, 0);
        expect((await svc.status("k1", a.id, 0)).body).toMatchObject({ phase: "decode", frames_done: 9 });
        expect((await svc.status("k1", b.id, 0)).body).toMatchObject({ phase: "pack", frames_done: 4 });
        finishJob(a.id);
        expect((await svc.status("k1", a.id, 0)).body).toMatchObject({ status: "success" });
        // a stored result is final: no progress fields, and a later pending of
        // the same id (it cannot happen) would start from unknown again
        expect((await svc.status("k1", a.id, 0)).body).not.toHaveProperty("phase");
    });
    it("GET /webp/<id> shows it too", async () => {
        const { id } = await create();
        pending(id, { phase: "decode", frames_done: 1, frames_total: 2 });
        const res = await handleWebpRoute(svc, new Request(`https://x.test/webp/${id}?wait=0`, { headers: { [KEY_ID_HEADER]: "k1" } }));
        expect(await res.json()).toEqual({ status: "pending", id, phase: "decode", frames_done: 1, frames_total: 2 });
    });
});

describe("WebpService scheduleSweep and the sweep of a /webp job", () => {
    const pending = (id: string, extra: Record<string, unknown>) => helperJobs.set(id, { status: "pending", ...extra });
    it("create asks for a sweep once the job is stored, and a failing scheduler never fails the create", async () => {
        const calls: string[] = [];
        const s = new WebpService({
            ...deps,
            scheduleSweep: async () => {
                calls.push([...kv.m.keys()].some((k) => k.startsWith("job:")) ? "stored" : "before");
                throw new Error("scheduler down");
            },
        });
        const r = await s.create("k1", JSON.stringify({ url: URL_OK }));
        expect(r.status).toBe(202);
        expect(calls).toEqual(["stored"]);
    });
    it("a rejected create does not ask for a sweep", async () => {
        let n = 0;
        const s = new WebpService({ ...deps, scheduleSweep: () => void n++ });
        expect((await s.create("k1", "{}")).status).toBe(400);
        busy = true;
        expect((await s.create("k1", JSON.stringify({ url: URL_OK }))).status).toBe(429);
        expect(n).toBe(0);
    });
    it("createFromUpload asks for a sweep too", async () => {
        let n = 0;
        const s = new WebpService({
            ...deps,
            scheduleSweep: () => void n++,
            helper: async (path, init) => {
                if (path.startsWith("/jobs/upload")) {
                    await new Response(init!.body as ReadableStream).arrayBuffer();
                    return json(202, { status: "pending" });
                }
                return deps.helper(path, init);
            },
        });
        const params = { url: URL_OK, start: 0, width: 480 as const, fps: 15, quality: "med" as const };
        const r = await s.createFromUpload("studio:x", params, async () => ({ body: new Blob([new Uint8Array(10)]).stream(), size: 10 }));
        expect(r.status).toBe(202);
        expect(n).toBe(1);
    });
    it("sweep collects a /webp job nobody polls: the result is in R2 and the library, with the owner's key", async () => {
        const db = createFakeD1();
        const studio = new StudioService({
            db,
            storage: kv,
            originals: new MemoryOriginals(),
            webp: new WebpService({ ...deps, db }),
            webBaseUrl: "https://cobalt.test",
            now: () => clock,
            sleep: deps.sleep,
            ensureRunning: async () => {},
            helper: deps.helper,
            fixedLength,
        });
        const webp = (studio as unknown as { d: { webp: WebpService } }).d.webp;
        const r = await webp.create("k1", JSON.stringify({ url: URL_OK }));
        const id = (r.body as { id: string }).id;
        pending(id, { phase: "decode", frames_done: 1, frames_total: 10 });
        // still pending: counted, nothing stored
        expect(await studio.sweep()).toEqual({ pending: 1 });
        expect(puts).toHaveLength(0);
        // the encode finishes with nobody polling: the next sweep collects it
        finishJob(id);
        expect(await studio.sweep()).toEqual({ pending: 0 });
        expect(puts).toHaveLength(1);
        expect(await kv.get(`result:${id}`)).toMatchObject({ status: "success", id });
        const row = db.raw.prepare("SELECT * FROM media_items").get() as any;
        expect(row).toMatchObject({ source: "webp", kind: "public", key_id: "k1", link: URL_OK });
        // collected once: another sweep finds nothing to do
        expect(await studio.sweep()).toEqual({ pending: 0 });
        expect(puts).toHaveLength(1);
    });
});

// A client long-poll of GET /webp/<id> concurrent with the no-poll sweep (which
// calls status(owner, id, 0)) collecting the same job. Whoever collects deletes
// the helper's job, so the other caller's next helper poll is a 404: it must
// find the stored success, never overwrite it with job_lost. (Reproduced by the
// review, 2026-10-02: the macOS Shortcut saw job_lost for a webp that was in R2.)
describe("WebpService: a long-poll racing the sweep that collects the same job (finding 1)", () => {
    // sleeps are held until released, so the test decides when the client loop wakes
    const gated = () => {
        const waiting: Array<() => void> = [];
        const sleep = (ms: number) =>
            new Promise<void>((r) => {
                clock += ms;
                waiting.push(r);
            });
        const wake = () => waiting.splice(0).forEach((r) => r());
        return { sleep, wake, waiting };
    };
    const tick = () => new Promise((r) => setTimeout(r, 5));

    it("the client's next poll returns the success the sweep stored (it used to store job_lost over it)", async () => {
        const g = gated();
        const s = new WebpService({ ...deps, sleep: g.sleep });
        const id = ((await s.create("k1", JSON.stringify({ url: URL_OK }))).body as { id: string }).id;

        const client = s.status("k1", id, 20); // pending: sleeps before its next poll
        await tick();
        expect(g.waiting).toHaveLength(1);

        finishJob(id);
        const swept = await s.status("k1", id, 0); // the sweep collects it and drops the helper job
        expect(swept.body).toMatchObject({ status: "success", id });
        expect(helperJobs.has(id)).toBe(false);

        g.wake(); // the client's loop wakes and polls again
        const got = await client;
        expect(got).toEqual(swept);
        expect(await kv.get(`result:${id}`)).toMatchObject({ status: "success", id });
        expect(puts).toHaveLength(1); // collected once
    });
    it("a helper 404 that follows our own read of 'no result yet' returns the result stored in between", async () => {
        const { id } = await create();
        const orig = kv.get.bind(kv);
        let armed = true;
        kv.get = (async (k: string) => {
            const v = await orig(k);
            if (armed && k === `result:${id}`) {
                // the sweep wins right after this read: stores the success, drops the helper's job
                armed = false;
                await kv.put(`result:${id}`, { status: "success", id, url: "https://media.test/Zz9.webp", bytes: 1, width: 1, height: 1, seconds: 1 });
                helperJobs.delete(id);
            }
            return v;
        }) as typeof kv.get;
        const r = await svc.status("k1", id, 0);
        expect(r.status).toBe(200);
        expect(r.body).toMatchObject({ status: "success", id });
        expect(await kv.get(`result:${id}`)).toMatchObject({ status: "success" });
    });
    it("finish() never replaces a stored result, whatever the helper then says", async () => {
        const { id } = await create();
        const orig = kv.get.bind(kv);
        let armed = true;
        kv.get = (async (k: string) => {
            const v = await orig(k);
            if (armed && k === `result:${id}`) {
                armed = false;
                await kv.put(`result:${id}`, { status: "success", id, url: "https://media.test/Zz9.webp", bytes: 1, width: 1, height: 1, seconds: 1 });
            }
            return v;
        }) as typeof kv.get;
        helperJobs.set(id, { status: "error", code: "error.webp.encode_failed" }); // a late helper error
        const r = await svc.status("k1", id, 0);
        expect(r.body).toMatchObject({ status: "success", id });
        expect(await kv.get(`result:${id}`)).toMatchObject({ status: "success" });
    });
    it("a genuinely lost job (no result stored anywhere) is still job_lost, once, and then stable", async () => {
        const { id } = await create();
        helperJobs.delete(id); // the container restarted
        const body = { status: "error", error: { code: "error.webp.job_lost" } };
        expect((await svc.status("k1", id, 0)).body).toEqual(body);
        expect((await svc.status("k1", id, 0)).body).toEqual(body);
        expect(await kv.get(`result:${id}`)).toEqual(body);
    });
    it("the result file 404s because someone collected it first: the stored result, not a 502", async () => {
        const { id } = await create();
        finishJob(id);
        let armed = true;
        const s = new WebpService({
            ...deps,
            helper: async (path, init) => {
                if (armed && path === `/jobs/${id}/file`) {
                    armed = false;
                    await kv.put(`result:${id}`, { status: "success", id, url: "https://media.test/Zz9.webp", bytes: 1, width: 1, height: 1, seconds: 1 });
                    return json(404, { status: "error", error: { code: "error.webp.not_found" } });
                }
                return deps.helper(path, init);
            },
        });
        const r = await s.status("k1", id, 0);
        expect(r.status).toBe(200);
        expect(r.body).toMatchObject({ status: "success", id });
    });
});

// The Workers runtime does not honour AbortSignal timeouts on containerFetch, so
// every helper call is raced against a ceiling of our own (finding 2): a hung
// call must come back as an ordinary miss, never block a poll, a job start or
// the sweep (whose alarm() the container library awaits before it may sleep).
describe("WebpService: our own ceiling on every helper call (finding 2)", () => {
    const never = () => new Promise<Response>(() => {});
    const hanging = (match: (path: string, method: string) => boolean) =>
        new WebpService({
            ...deps,
            helperTimeoutMs: 30,
            helper: (path, init) => (match(path, init?.method ?? "GET") ? never() : deps.helper(path, init)),
        });
    const within = async <T>(p: Promise<T>, ms = 1500): Promise<T> => {
        const t0 = Date.now();
        const v = await p;
        expect(Date.now() - t0).toBeLessThan(ms);
        return v;
    };

    it("a hung poll of the job is a miss: status(wait=0) answers pending", async () => {
        const { id } = await create();
        const s = hanging((p) => p === `/jobs/${id}`);
        const r = await within(s.status("k1", id, 0));
        expect(r).toMatchObject({ status: 200, body: { status: "pending", id } });
    });
    it("a hung DELETE of the finished job does not hold the reply: the success is stored first and still returned", async () => {
        const { id } = await create();
        finishJob(id);
        const s = hanging((_p, m) => m === "DELETE");
        const r = await within(s.status("k1", id, 0));
        expect(r.body).toMatchObject({ status: "success", id });
        expect(await kv.get(`result:${id}`)).toMatchObject({ status: "success" });
    });
    it("a hung result download is 502 error.webp.upstream (the next poll retries)", async () => {
        const { id } = await create();
        finishJob(id);
        const s = hanging((p) => p.endsWith("/file"));
        const r = await within(s.status("k1", id, 0));
        expect(r).toEqual({ status: 502, body: { status: "error", error: { code: "error.webp.upstream" } } });
        expect(await kv.get(`result:${id}`)).toBeUndefined();
    });
    it("a hung job start is 502 error.webp.unavailable", async () => {
        const s = hanging((p, m) => p === "/jobs" && m === "POST");
        const r = await within(s.create("k1", JSON.stringify({ url: URL_OK })));
        expect(r).toEqual({ status: 502, body: { status: "error", error: { code: "error.webp.unavailable" } } });
    });
    it("a hung studio upload start is 502 error.webp.unavailable", async () => {
        const s = hanging((p) => p.startsWith("/jobs/upload"));
        const params = { url: URL_OK, start: 0, width: 480 as const, fps: 15, quality: "med" as const };
        const r = await within(s.createFromUpload("studio:x", params, async () => ({ body: new Blob([new Uint8Array(10)]).stream(), size: 10 })));
        expect(r).toEqual({ status: 502, body: { status: "error", error: { code: "error.webp.unavailable" } } });
    });
    it("the defaults: job calls 20 s, the result download 60 s, the studio upload 5 min", async () => {
        const { HELPER_CALL_MS, HELPER_FILE_MS, HELPER_UPLOAD_MS } = await import("../src/webp");
        expect([HELPER_CALL_MS, HELPER_FILE_MS, HELPER_UPLOAD_MS]).toEqual([20_000, 60_000, 300_000]);
    });
});

describe("WebpService.deleteMedia", () => {
    it("deletes and reports success, idempotently", async () => {
        expect(await svc.deleteMedia("Xy7Zk9Lm2Q.webp")).toEqual({ status: 200, body: { status: "success" } });
        expect(await svc.deleteMedia("Xy7Zk9Lm2Q.webp")).toEqual({ status: 200, body: { status: "success" } });
        expect(deletes).toEqual(["Xy7Zk9Lm2Q.webp", "Xy7Zk9Lm2Q.webp"]);
    });
    it("502 storage error when R2 fails", async () => {
        putFails = true;
        expect(await svc.deleteMedia("Xy7Zk9Lm2Q.webp")).toMatchObject({ status: 502 });
    });
});

describe("WebpService.prune", () => {
    it("drops job and result records older than the TTL when a new job starts", async () => {
        const old = await create("k1");
        finishJob(old.id);
        await svc.status("k1", old.id, 0);
        clock += RECORD_TTL_MS + 1;
        const fresh = await create("k1");
        expect(await kv.get(`job:${old.id}`)).toBeUndefined();
        expect(await kv.get(`result:${old.id}`)).toBeUndefined();
        expect(await kv.get(`job:${fresh.id}`)).toBeDefined();
    });
});

describe("handleWebpRoute", () => {
    const req = (method: string, path: string, headers: Record<string, string> = { [KEY_ID_HEADER]: "k1" }, body?: string) =>
        new Request(`https://x.test${path}`, { method, headers, body });

    it("isWebpRoute matches only /webp, /webp/* and /media/*", () => {
        for (const p of ["/webp", "/webp/x", "/media/x.webp"]) expect(isWebpRoute(p)).toBe(true);
        for (const p of ["/", "/tunnel", "/webpx", "/media"]) expect(isWebpRoute(p)).toBe(false);
    });
    it("403 without the Worker's key id header, before doing anything", async () => {
        const res = await handleWebpRoute(svc, req("POST", "/webp", {}, JSON.stringify({ url: URL_OK })));
        expect(res.status).toBe(403);
        expect(helperCalls).toHaveLength(0);
    });
    it("POST /webp -> 202 JSON", async () => {
        const res = await handleWebpRoute(svc, req("POST", "/webp", undefined, JSON.stringify({ url: URL_OK })));
        expect(res.status).toBe(202);
        expect(res.headers.get("content-type")).toBe("application/json");
        expect(await res.json()).toMatchObject({ status: "pending" });
    });
    it("GET /webp/:id honours ?wait and the owner check", async () => {
        const { id } = await create("k1");
        const mine = await handleWebpRoute(svc, req("GET", `/webp/${id}?wait=0`));
        expect(await mine.json()).toEqual({ status: "pending", id, phase: null, frames_done: null, frames_total: null });
        const theirs = await handleWebpRoute(svc, req("GET", `/webp/${id}?wait=0`, { [KEY_ID_HEADER]: "k2" }));
        expect(theirs.status).toBe(404);
    });
    it("malformed ids and names are 404, other methods too", async () => {
        expect((await handleWebpRoute(svc, req("GET", "/webp/short"))).status).toBe(404);
        expect((await handleWebpRoute(svc, req("DELETE", "/media/nope.webp"))).status).toBe(404);
        expect((await handleWebpRoute(svc, req("PUT", "/webp"))).status).toBe(404);
        expect((await handleWebpRoute(svc, req("GET", "/webp"))).status).toBe(404);
    });
    it("DELETE /media/:name -> 200 success", async () => {
        const res = await handleWebpRoute(svc, req("DELETE", "/media/Xy7Zk9Lm2Q.webp"));
        expect(res.status).toBe(200);
        expect(await res.json()).toEqual({ status: "success" });
    });
});
