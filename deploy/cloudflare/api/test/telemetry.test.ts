// Crash and log telemetry (TELEMETRY-CONTRACT.md): POST /telemetry through the real
// Worker (gate -> D1 key lookup -> ingest), on the real migration SQL (node:sqlite),
// plus the retention run, the capability flag and the deploy config.
import { readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { beforeEach, describe, expect, it } from "vitest";
import config from "../cloudflare.config";
import { capabilities } from "../src/app-routes";
import { decide, type GateRequest } from "../src/gate";
import { SERVICE_HEADER } from "../src/headers";
import { hashKey } from "../src/keys";
import {
    CATS,
    KINDS,
    LEVELS,
    MAX_BATCHES_PER_MINUTE,
    MAX_BODY_BYTES,
    RETENTION_MS,
    RateLimiter,
    crashKey,
    ingestTelemetry,
    redact,
    resetTelemetryRateLimits,
    runTelemetryRetention,
} from "../src/telemetry";
import type { OriginalsBucket } from "../src/studio";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { Clock } from "./studio-fakes";

const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const CLIENT2 = "5c1c7a40-0a52-4d0e-a6b4-3d8d3f5a9e22";
const KEY_ID = "key-row-1";
const KEY_ID2 = "key-row-2";
const INSTALL = "3f2b8c1a-5d4e-4f6a-9b7c-0d1e2f3a4b5c";

// D1 with batch(): the node:sqlite fake has no batch, so statements run in order.
function withBatch(db: FakeD1) {
    const log = { batches: [] as number[], fail: false };
    (db as unknown as { batch: unknown }).batch = async (stmts: { run(): Promise<unknown> }[]) => {
        if (log.fail) throw new Error("D1_ERROR: batch failed");
        log.batches.push(stmts.length);
        const out = [];
        for (const s of stmts) out.push(await s.run());
        return out;
    };
    return log;
}

class TelemetryR2 {
    objects = new Map<string, { body: string; contentType?: string }>();
    putCalls: { key: string; valueType: string }[] = [];
    deleted: string[] = [];
    failPut = false;
    failDeleteFor = new Set<string>();
    async put(key: string, value: ReadableStream | string, o?: { httpMetadata?: { contentType?: string } }) {
        this.putCalls.push({ key, valueType: typeof value });
        if (this.failPut) throw new Error("R2 down");
        this.objects.set(key, { body: String(value), contentType: o?.httpMetadata?.contentType });
        return { size: String(value).length };
    }
    async delete(key: string) {
        if (this.failDeleteFor.has(key)) throw new Error("R2 delete failed");
        this.deleted.push(key);
        this.objects.delete(key);
    }
}

type World = Awaited<ReturnType<typeof world>>;

async function world() {
    const db: FakeD1 = createFakeD1();
    const batchLog = withBatch(db);
    const clock = new Clock();
    const r2 = new TelemetryR2();
    let containerCalls = 0;
    const container = {
        async fetch(): Promise<Response> {
            containerCalls++;
            return new Response('{"status":"container"}');
        },
    };
    const env: WorkerEnv = {
        API_URL: "https://api.capybaraharmony.com/",
        CORS_URL: "https://cobalt.capybaraharmony.com",
        COBALT_API_KEY: INTERNAL,
        DB: db,
        ORIGINALS: r2 as unknown as OriginalsBucket,
        MEDIA: {} as never,
        MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
    };
    for (const [id, key] of [
        [KEY_ID, CLIENT],
        [KEY_ID2, CLIENT2],
    ] as const) {
        db.raw
            .prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)")
            .run(id, id, await hashKey(key), key.slice(0, 8), 1);
    }
    const post = (body: BodyInit | null, headers: Record<string, string> = {}, key: string | null = CLIENT) =>
        handleRequest(
            new Request("https://api.capybaraharmony.com/telemetry", {
                method: "POST",
                headers: { ...(key ? { authorization: `Api-Key ${key}` } : {}), ...headers },
                body,
            }),
            env,
            container,
            { now: clock.now, sleep: clock.sleep },
        );
    const send = (batch: unknown, headers: Record<string, string> = {}, key: string | null = CLIENT) =>
        post(JSON.stringify(batch), { "content-type": "application/json", ...headers }, key);
    const events = () => db.raw.prepare("SELECT * FROM telemetry_events ORDER BY ts, id").all() as any[];
    const crashes = () => db.raw.prepare("SELECT * FROM telemetry_crashes ORDER BY ts, id").all() as any[];
    return { db, batchLog, clock, r2, env, post, send, events, crashes, containerCalls: () => containerCalls };
}

const APP = { version: "1.3", build: "4", platform: "ios", os: "26.5", device: "iPhone18,1", process: "app" };
const ev = (over: Record<string, unknown> = {}) => ({
    ts: 1_799_999_000_000,
    level: "info",
    cat: "sync",
    msg: "library refreshed",
    data: { items: 12, ok: true, source: "pull" },
    ...over,
});
const batch = (over: Record<string, unknown> = {}) => ({ app: APP, install: INSTALL, events: [ev()], crashes: [], ...over });
const MANGLED_STACK = {
    crashDiagnostics: [
        {
            callStackTree: {
                callStacks: [
                    {
                        threadAttributed: true,
                        callStackRootFrames: [
                            { binaryName: "Cobalt", address: 4372345672, offsetIntoBinaryTextSegment: 48392, binaryUUID: "AAAA", subFrames: [] },
                        ],
                    },
                ],
            },
        },
    ],
};
const crash = (over: Record<string, unknown> = {}) => ({
    ts: 1_799_999_500_000,
    kind: "crash",
    summary: "EXC_BAD_ACCESS in Pipeline.run",
    payload: MANGLED_STACK,
    events: [ev({ ts: 1_799_999_499_000, level: "error", cat: "pipeline", msg: "encode failed" })],
    ...over,
});

const code = async (r: Response) => ((await r.json()) as any).error.code;

beforeEach(() => resetTelemetryRateLimits());

// -------------------------------------------------------------------------------------

describe("gate", () => {
    const req = (over: Partial<GateRequest> = {}): GateRequest => ({
        method: "POST",
        pathname: "/telemetry",
        searchParams: new URLSearchParams(),
        origin: null,
        authorization: `Api-Key ${CLIENT}`,
        ...over,
    });
    const cfg = { corsUrl: "https://cobalt.capybaraharmony.com", now: 1 };

    it("POST /telemetry with a well-formed key is a keyed lookup", () => {
        expect(decide(req(), cfg)).toEqual({ action: "lookup", key: CLIENT, then: "telemetry_ingest" });
    });
    it("a missing, malformed or non-Api-Key authorization is a 401 with cobalt's codes", () => {
        expect(decide(req({ authorization: null }), cfg)).toMatchObject({ action: "reject", status: 401, errorCode: "error.api.auth.key.missing" });
        expect(decide(req({ authorization: "Api-Key nope" }), cfg)).toMatchObject({ status: 401, errorCode: "error.api.auth.key.invalid" });
        expect(decide(req({ authorization: `Bearer ${CLIENT}` }), cfg)).toMatchObject({ status: 401, errorCode: "error.api.auth.key.not_api_key" });
    });
    it("every other method is a 404, OPTIONS included (no CORS), and so is the library service", () => {
        for (const method of ["GET", "HEAD", "PUT", "DELETE", "PATCH"]) {
            expect(decide(req({ method }), cfg)).toMatchObject({ action: "reject", status: 404 });
        }
        expect(decide(req({ method: "OPTIONS", origin: cfg.corsUrl }), cfg)).toMatchObject({ action: "reject", status: 404 });
        expect(decide(req({ service: true }), cfg)).toMatchObject({ action: "reject", status: 404 });
    });
    it("only the exact path /telemetry", () => {
        expect(decide(req({ pathname: "/telemetry/" }), cfg)).toMatchObject({ action: "reject", status: 404 });
        expect(decide(req({ pathname: "/telemetry/x" }), cfg)).toMatchObject({ action: "reject", status: 404 });
    });
});

describe("POST /telemetry: auth", () => {
    it("no key: 401 and nothing written", async () => {
        const w = await world();
        const res = await w.send(batch(), {}, null);
        expect(res.status).toBe(401);
        expect(await code(res)).toBe("error.api.auth.key.missing");
        expect(w.events()).toHaveLength(0);
    });
    it("an unknown key: 401 error.api.auth.key.invalid", async () => {
        const w = await world();
        const res = await w.send(batch(), {}, "11111111-2222-4333-8444-555555555555");
        expect(res.status).toBe(401);
        expect(await code(res)).toBe("error.api.auth.key.invalid");
        expect(w.events()).toHaveLength(0);
    });
    it("a revoked key: 401", async () => {
        const w = await world();
        w.db.raw.prepare("UPDATE api_keys SET revoked_at = 5 WHERE id = ?").run(KEY_ID);
        expect((await w.send(batch())).status).toBe(401);
    });
    it("the library service credential is not accepted here (404)", async () => {
        const w = await world();
        const res = await w.send(batch(), { [SERVICE_HEADER]: INTERNAL }, null);
        expect(res.status).toBe(404);
        expect(w.events()).toHaveLength(0);
    });
    it("D1 down at the key lookup fails closed: 503, nothing stored", async () => {
        const w = await world();
        w.db.breakIt();
        expect((await w.send(batch())).status).toBe(503);
    });
    it("never reaches the container, and is not written to request_log", async () => {
        const w = await world();
        expect((await w.send(batch({ crashes: [crash()] }))).status).toBe(202);
        expect(w.containerCalls()).toBe(0);
        expect(w.db.raw.prepare("SELECT COUNT(*) AS n FROM request_log").get()).toEqual({ n: 0 });
    });
});

describe("POST /telemetry: accepting a batch", () => {
    it("202 {status:success, accepted:{events,crashes}} with no-store and JSON headers", async () => {
        const w = await world();
        const res = await w.send(batch({ events: [ev(), ev({ ts: 1_799_999_000_001 })], crashes: [crash()] }));
        expect(res.status).toBe(202);
        expect(res.headers.get("content-type")).toBe("application/json");
        expect(res.headers.get("cache-control")).toBe("no-store");
        expect(await res.json()).toEqual({ status: "success", accepted: { events: 2, crashes: 1 } });
    });
    it("stores every event column, taking app fields from the batch and the key id from the D1 lookup", async () => {
        const w = await world();
        await w.send(batch({ install: INSTALL.toUpperCase() }));
        const [row] = w.events();
        expect(row).toMatchObject({
            key_id: KEY_ID,
            install: INSTALL,
            ts: 1_799_999_000_000,
            level: "info",
            cat: "sync",
            msg: "library refreshed",
            version: "1.3",
            build: "4",
            platform: "ios",
            device: "iPhone18,1",
            process: "app",
            received_at: w.clock.t,
        });
        expect(JSON.parse(row.data)).toEqual({ items: 12, ok: true, source: "pull" });
        expect(row.id).toMatch(/^[0-9a-f]{24}$/);
    });
    it("an event with no data stores NULL; a numeric build is stored as text; os and device are optional", async () => {
        const w = await world();
        const res = await w.send(batch({ app: { version: "1.3", build: 4, platform: "macos", process: "share" }, events: [ev({ data: undefined })] }));
        expect(res.status).toBe(202);
        expect(w.events()[0]).toMatchObject({ data: null, build: "4", platform: "macos", process: "share", device: null });
    });
    it("a crash goes to R2 as telemetry/crashes/<day>/<id>.json (payload and events) and to D1 pointing at it", async () => {
        const w = await world();
        await w.send(batch({ events: [], crashes: [crash()] }));
        const [row] = w.crashes();
        expect(row).toMatchObject({
            key_id: KEY_ID,
            install: INSTALL,
            ts: 1_799_999_500_000,
            kind: "crash",
            summary: "EXC_BAD_ACCESS in Pipeline.run",
            version: "1.3",
            build: "4",
            platform: "ios",
            device: "iPhone18,1",
            process: "app",
        });
        expect(row.r2_key).toBe(crashKey(1_799_999_500_000, row.id));
        expect(row.r2_key).toMatch(/^telemetry\/crashes\/2027-01-15\/[0-9a-f]{24}\.json$/);
        const obj = w.r2.objects.get(row.r2_key)!;
        expect(obj.contentType).toBe("application/json");
        expect(w.r2.putCalls[0]!.valueType).toBe("string");
        const doc = JSON.parse(obj.body);
        expect(doc.payload).toEqual(MANGLED_STACK);
        expect(doc.events).toHaveLength(1);
        expect(doc.events[0]).toMatchObject({ level: "error", cat: "pipeline", msg: "encode failed" });
        expect(doc.app).toMatchObject({ version: "1.3", platform: "ios" });
        expect(doc).toMatchObject({ id: row.id, install: INSTALL, kind: "crash" });
        // the crash's own events are NOT also copied into the event stream
        expect(w.events()).toHaveLength(0);
    });
    it("a crash with a null payload and no events is stored", async () => {
        const w = await world();
        const res = await w.send(batch({ events: [], crashes: [crash({ kind: "unclean_exit", payload: null, events: undefined })] }));
        expect(res.status).toBe(202);
        const doc = JSON.parse(w.r2.objects.get(w.crashes()[0].r2_key)!.body);
        expect(doc).toMatchObject({ kind: "unclean_exit", payload: null, events: [] });
    });
    it("every contracted level, cat and crash kind is accepted", async () => {
        const w = await world();
        const events = CATS.flatMap((cat, i) => LEVELS.map((level, j) => ev({ cat, level, ts: 1000 + i * 10 + j, msg: `${cat}/${level}` })));
        const crashesIn = KINDS.map((kind, i) => crash({ kind, ts: 2000 + i, summary: kind }));
        const res = await w.send(batch({ events: events.slice(0, 40), crashes: crashesIn }));
        expect(res.status).toBe(202);
        expect(w.crashes().map((c) => c.kind).sort()).toEqual([...KINDS].sort());
    });
    it("an empty batch is accepted (0 and 0)", async () => {
        const w = await world();
        const res = await w.send(batch({ events: [], crashes: [] }));
        expect(await res.json()).toEqual({ status: "success", accepted: { events: 0, crashes: 0 } });
        expect((await w.send({ app: APP, install: INSTALL })).status).toBe(202);
    });
    it("500 events are stored (multi-row inserts, grouped into batch() calls)", async () => {
        const w = await world();
        const events = Array.from({ length: 500 }, (_, i) => ev({ ts: 1_000_000 + i, msg: `m${i}` }));
        const res = await w.send(batch({ events }));
        expect(res.status).toBe(202);
        expect(await res.json()).toMatchObject({ accepted: { events: 500 } });
        expect(w.events()).toHaveLength(500);
        expect(w.batchLog.batches.reduce((a, b) => a + b, 0)).toBe(Math.ceil(500 / 7));
        expect(Math.max(...w.batchLog.batches)).toBeLessThanOrEqual(50);
    });
    it("a retried batch does not duplicate rows or objects (deterministic ids)", async () => {
        const w = await world();
        const b = batch({ events: [ev(), ev({ msg: "other" })], crashes: [crash()] });
        await w.send(b);
        await w.send(b);
        expect(w.events()).toHaveLength(2);
        expect(w.crashes()).toHaveLength(1);
        expect(w.r2.objects.size).toBe(1);
    });
    it("the same message at another time or from another install is a different row", async () => {
        const w = await world();
        await w.send(batch({ events: [ev(), ev({ ts: 1_799_999_000_001 })] }));
        await w.send(batch({ install: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" }));
        expect(w.events()).toHaveLength(3);
    });
});

describe("POST /telemetry: sanitising what is accepted", () => {
    it("msg and string data values over 300 characters are cut, never rejected", async () => {
        const w = await world();
        const res = await w.send(batch({ events: [ev({ msg: "x".repeat(900), data: { long: "y".repeat(900) } })] }));
        expect(res.status).toBe(202);
        const row = w.events()[0];
        expect(row.msg).toHaveLength(300);
        expect(JSON.parse(row.data).long).toHaveLength(300);
    });
    it("data keeps at most 20 keys and only string, number and bool values", async () => {
        const w = await world();
        const data: Record<string, unknown> = { nested: { a: 1 }, list: [1], nothing: null, bad: Infinity };
        for (let i = 0; i < 30; i++) data[`k${i}`] = i;
        await w.send(batch({ events: [ev({ data })] }));
        const stored = JSON.parse(w.events()[0].data);
        expect(Object.keys(stored)).toHaveLength(20);
        expect(stored.nested).toBeUndefined();
        expect(stored.list).toBeUndefined();
        expect(stored.k0).toBe(0);
    });
    it("api keys and bearer tokens that slip into a message are blanked before storage", async () => {
        const w = await world();
        const leak = `Authorization: Api-Key ${CLIENT} failed`;
        await w.send(batch({ events: [ev({ msg: leak, data: { h: `Bearer abc.def-123` } })], crashes: [crash({ summary: `retry with Api-Key ${CLIENT}` })] }));
        const row = w.events()[0];
        expect(row.msg).toBe("Authorization: Api-Key [redacted] failed");
        expect(JSON.parse(row.data).h).toBe("Bearer [redacted]");
        expect(w.crashes()[0].summary).toBe("retry with Api-Key [redacted]");
        expect(JSON.stringify([...w.db.raw.prepare("SELECT * FROM telemetry_events").all()])).not.toContain(CLIENT);
        expect(redact("plain text")).toBe("plain text");
    });
});

describe("POST /telemetry: limits and invalid shapes", () => {
    it("a body over 256 KB is 413 error.telemetry.too_large (declared length)", async () => {
        const w = await world();
        const big = JSON.stringify(batch({ events: [ev({ msg: "x".repeat(10) })], pad: "p".repeat(MAX_BODY_BYTES) }));
        const res = await w.post(big, { "content-type": "application/json" });
        expect(res.status).toBe(413);
        expect(await code(res)).toBe("error.telemetry.too_large");
        expect(w.events()).toHaveLength(0);
    });
    it("a streamed body over 256 KB with no content-length is cut off at the limit: 413", async () => {
        const w = await world();
        const chunk = new TextEncoder().encode("x".repeat(64 * 1024));
        let sent = 0;
        const stream = new ReadableStream<Uint8Array>({
            pull(c) {
                sent += chunk.length;
                c.enqueue(chunk);
                if (sent > MAX_BODY_BYTES * 20) c.close();
            },
        });
        const res = await handleRequest(
            new Request("https://api.capybaraharmony.com/telemetry", {
                method: "POST",
                headers: { authorization: `Api-Key ${CLIENT}` },
                body: stream,
                duplex: "half",
            } as RequestInit),
            w.env,
            { fetch: async () => new Response("") },
            { now: w.clock.now },
        );
        expect(res.status).toBe(413);
        expect(sent).toBeLessThan(MAX_BODY_BYTES * 3); // it stopped reading, it did not drain the stream
    });
    it("exactly 256 KB is allowed", async () => {
        const w = await world();
        const base = JSON.stringify(batch({ events: [], pad: "" }));
        const body = JSON.stringify(batch({ events: [], pad: "p".repeat(MAX_BODY_BYTES - base.length) }));
        expect(new TextEncoder().encode(body).length).toBe(MAX_BODY_BYTES);
        expect((await w.post(body, { "content-type": "application/json" })).status).toBe(202);
    });
    it("501 events: 400 error.telemetry.invalid; 500 is fine", async () => {
        const w = await world();
        const mk = (n: number) => Array.from({ length: n }, (_, i) => ev({ ts: i + 1 }));
        const res = await w.send(batch({ events: mk(501) }));
        expect(res.status).toBe(400);
        expect(await code(res)).toBe("error.telemetry.invalid");
        expect(w.events()).toHaveLength(0);
        expect((await w.send(batch({ events: mk(500) }))).status).toBe(202);
    });
    it("11 crashes: 400; 10 is fine", async () => {
        const w = await world();
        const mk = (n: number) => Array.from({ length: n }, (_, i) => crash({ ts: i + 1 }));
        expect((await w.send(batch({ events: [], crashes: mk(11) }))).status).toBe(400);
        expect(w.r2.objects.size).toBe(0);
        const ok = await w.send(batch({ events: [], crashes: mk(10) }));
        expect(await ok.json()).toMatchObject({ accepted: { crashes: 10 } });
    });
    it("a crash carrying more than 500 events: 400", async () => {
        const w = await world();
        const events = Array.from({ length: 501 }, (_, i) => ev({ ts: i + 1 }));
        expect((await w.send(batch({ events: [], crashes: [crash({ events })] }))).status).toBe(400);
    });

    const bad: [string, unknown][] = [
        ["a JSON array", []],
        ["a JSON string", "hi"],
        ["no app", { install: INSTALL, events: [] }],
        ["app not an object", batch({ app: "ios" })],
        ["app with an unknown platform", batch({ app: { ...APP, platform: "android" } })],
        ["app with an unknown process", batch({ app: { ...APP, process: "watch" } })],
        ["app with no version", batch({ app: { ...APP, version: undefined } })],
        ["app with a non-string os", batch({ app: { ...APP, os: 26 } })],
        ["no install", { app: APP, events: [] }],
        ["install not a uuid", batch({ install: "install-1" })],
        ["events not an array", batch({ events: {} })],
        ["an event that is not an object", batch({ events: ["x"] })],
        ["an unknown level", batch({ events: [ev({ level: "fatal" })] })],
        ["an unknown cat", batch({ events: [ev({ cat: "billing" })] })],
        ["a non-numeric ts", batch({ events: [ev({ ts: "yesterday" })] })],
        ["a negative ts", batch({ events: [ev({ ts: -1 })] })],
        ["a non-string msg", batch({ events: [ev({ msg: 7 })] })],
        ["data that is an array", batch({ events: [ev({ data: [1] })] })],
        ["data that is a string", batch({ events: [ev({ data: "k=v" })] })],
        ["crashes not an array", batch({ crashes: "x" })],
        ["a crash with an unknown kind", batch({ crashes: [crash({ kind: "panic" })] })],
        ["a crash payload that is an array", batch({ crashes: [crash({ payload: [] })] })],
        ["a crash payload that is a string", batch({ crashes: [crash({ payload: "stack" })] })],
        ["a crash with no summary", batch({ crashes: [crash({ summary: undefined })] })],
        ["a crash with a bad event", batch({ crashes: [crash({ events: [ev({ level: "x" })] })] })],
    ];
    for (const [name, body] of bad) {
        it(`400 error.telemetry.invalid for ${name}, and nothing is stored`, async () => {
            const w = await world();
            const res = await w.send(body);
            expect(res.status).toBe(400);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.telemetry.invalid" } });
            expect(w.events()).toHaveLength(0);
            expect(w.crashes()).toHaveLength(0);
            expect(w.r2.objects.size).toBe(0);
        });
    }
    it("a body that is not JSON, or not UTF-8, is 400", async () => {
        const w = await world();
        expect((await w.post("{nope", { "content-type": "application/json" })).status).toBe(400);
        expect((await w.post(new Uint8Array([0xff, 0xfe, 0x7b, 0x7d]), { "content-type": "application/json" })).status).toBe(400);
        expect((await w.post("", {})).status).toBe(400);
    });
});

describe("POST /telemetry: gzip", () => {
    it("content-encoding: gzip is inflated", async () => {
        const w = await world();
        const res = await w.post(gzipSync(JSON.stringify(batch({ events: [ev(), ev({ ts: 5 })] }))), {
            "content-type": "application/json",
            "content-encoding": "gzip",
        });
        expect(res.status).toBe(202);
        expect(w.events()).toHaveLength(2);
    });
    it("a gzip bomb that inflates past 256 KB is 413, though it is tiny on the wire", async () => {
        const w = await world();
        const bomb = gzipSync(JSON.stringify({ pad: "0".repeat(10_000_000) }));
        expect(bomb.length).toBeLessThan(20_000);
        const res = await w.post(bomb, { "content-encoding": "gzip" });
        expect(res.status).toBe(413);
        expect(await code(res)).toBe("error.telemetry.too_large");
    });
    it("a gzip body over 256 KB on the wire is 413 too", async () => {
        const w = await world();
        const big = Buffer.from(Array.from({ length: MAX_BODY_BYTES + 100 }, () => Math.floor(Math.random() * 256)));
        expect((await w.post(gzipSync(big), { "content-encoding": "gzip" })).status).toBe(413);
    });
    it("broken gzip is 400; an unsupported encoding is 400; identity is fine", async () => {
        const w = await world();
        expect((await w.post(new Uint8Array([1, 2, 3, 4]), { "content-encoding": "gzip" })).status).toBe(400);
        expect((await w.post(JSON.stringify(batch()), { "content-encoding": "br" })).status).toBe(400);
        expect((await w.post(JSON.stringify(batch()), { "content-encoding": "identity" })).status).toBe(202);
    });
});

describe("POST /telemetry: rate limit (per key, in the isolate's memory)", () => {
    it("60 batches a minute pass, the 61st is 429 error.telemetry.rate_limited with retry-after", async () => {
        const w = await world();
        for (let i = 0; i < MAX_BATCHES_PER_MINUTE; i++) expect((await w.send(batch({ events: [] }))).status).toBe(202);
        const res = await w.send(batch({ events: [] }));
        expect(res.status).toBe(429);
        expect(await code(res)).toBe("error.telemetry.rate_limited");
        expect(Number(res.headers.get("retry-after"))).toBeGreaterThanOrEqual(1);
        expect(Number(res.headers.get("retry-after"))).toBeLessThanOrEqual(60);
    });
    it("another key has its own budget, and the window resets after a minute", async () => {
        const w = await world();
        for (let i = 0; i < MAX_BATCHES_PER_MINUTE + 1; i++) await w.send(batch({ events: [] }));
        expect((await w.send(batch({ events: [] }))).status).toBe(429);
        expect((await w.send(batch({ events: [] }), {}, CLIENT2)).status).toBe(202);
        w.clock.t += 60_000;
        expect((await w.send(batch({ events: [] }))).status).toBe(202);
    });
    it("a rejected (invalid or oversized) batch still counts", async () => {
        const w = await world();
        for (let i = 0; i < MAX_BATCHES_PER_MINUTE; i++) await w.send({ nope: true });
        expect((await w.send(batch())).status).toBe(429);
        expect(w.events()).toHaveLength(0);
    });
    it("an unauthenticated flood does not spend the key's budget", async () => {
        const w = await world();
        for (let i = 0; i < 100; i++) await w.send(batch(), {}, "11111111-2222-4333-8444-555555555555");
        expect((await w.send(batch())).status).toBe(202);
    });
    it("RateLimiter on its own: window arithmetic and pruning", () => {
        const rl = new RateLimiter(2, 1000);
        expect(rl.hit("a", 0).ok).toBe(true);
        expect(rl.hit("a", 10).ok).toBe(true);
        const third = rl.hit("a", 20);
        expect(third.ok).toBe(false);
        expect(third.retryAfterS).toBe(1);
        expect(rl.hit("a", 1000).ok).toBe(true);
        for (let i = 0; i < 300; i++) rl.hit(`k${i}`, 5000);
        rl.hit("late", 9000);
        expect(rl.hit("a", 9001).ok).toBe(true);
    });
});

describe("POST /telemetry: storage failures are retryable 503s", () => {
    const direct = (w: World, req: Request, keyId = KEY_ID) =>
        ingestTelemetry({ db: w.db, originals: w.r2 as unknown as OriginalsBucket, now: w.clock.now }, req, keyId);
    const raw = (body: unknown) =>
        new Request("https://x/telemetry", { method: "POST", body: JSON.stringify(body) });

    it("D1 batch failure: 503 error.telemetry.unavailable", async () => {
        const w = await world();
        w.batchLog.fail = true;
        const res = await direct(w, raw(batch()));
        expect(res).toEqual({ status: 503, body: { status: "error", error: { code: "error.telemetry.unavailable" } } });
    });
    it("R2 failure: 503 and no crash row (the row is written only after the object)", async () => {
        const w = await world();
        w.r2.failPut = true;
        const res = await direct(w, raw(batch({ events: [], crashes: [crash()] })));
        expect(res.status).toBe(503);
        expect(w.crashes()).toHaveLength(0);
    });
    it("D1 down: 503 (no throw)", async () => {
        const w = await world();
        w.db.breakIt();
        expect((await direct(w, raw(batch()))).status).toBe(503);
    });
});

describe("retention", () => {
    const DAY = 86_400_000;
    async function seed(w: World, ageDays: number, tag: string) {
        const at = w.clock.t - ageDays * DAY;
        const id = `${tag}`.padEnd(24, "0");
        w.db.raw
            .prepare(
                "INSERT INTO telemetry_events (id, key_id, install, ts, level, cat, msg, received_at) VALUES (?, ?, ?, ?, 'info', 'app', ?, ?)",
            )
            .run(`e${id}`, KEY_ID, INSTALL, at, tag, at);
        const key = `telemetry/crashes/2027-01-01/${id}.json`;
        w.r2.objects.set(key, { body: "{}" });
        w.db.raw
            .prepare(
                "INSERT INTO telemetry_crashes (id, key_id, install, ts, kind, summary, r2_key, received_at) VALUES (?, ?, ?, ?, 'crash', ?, ?, ?)",
            )
            .run(id, KEY_ID, INSTALL, at, tag, key, at);
        return { id, key };
    }
    const run = (w: World, ms?: number) =>
        runTelemetryRetention({ db: w.db, originals: w.r2 as unknown as OriginalsBucket, now: w.clock.now }, ms);

    it("deletes rows and R2 objects older than 30 days and keeps the rest", async () => {
        const w = await world();
        const old = await seed(w, 31, "old");
        const edge = await seed(w, 29, "edge");
        const fresh = await seed(w, 1, "fresh");
        const r = await run(w);
        expect(r).toEqual({ events: 1, crashes: 1, failed: 0 });
        expect(w.events().map((e) => e.msg)).toEqual(["edge", "fresh"]);
        expect(w.crashes().map((c) => c.id)).toEqual([edge.id, fresh.id]);
        expect(w.r2.objects.has(old.key)).toBe(false);
        expect(w.r2.objects.has(edge.key) && w.r2.objects.has(fresh.key)).toBe(true);
        expect(w.r2.deleted).toEqual([old.key]);
    });
    it("retention is 30 days and runs on received_at, not the device's ts", async () => {
        expect(RETENTION_MS).toBe(30 * DAY);
        const w = await world();
        // device clock years in the past, but it arrived today: kept
        w.db.raw
            .prepare("INSERT INTO telemetry_events (id, ts, level, cat, msg, received_at) VALUES ('x', 1, 'info', 'app', 'skewed', ?)")
            .run(w.clock.t);
        await run(w);
        expect(w.events()).toHaveLength(1);
    });
    it("a failed R2 delete keeps its row for the next run; the others are still cleaned", async () => {
        const w = await world();
        const a = await seed(w, 40, "aaa");
        const b = await seed(w, 41, "bbb");
        w.r2.failDeleteFor.add(a.key);
        const r = await run(w);
        expect(r).toMatchObject({ crashes: 1, failed: 1 });
        expect(w.crashes().map((c) => c.id)).toEqual([a.id]);
        w.r2.failDeleteFor.clear();
        expect((await run(w)).crashes).toBe(1);
        expect(w.crashes()).toHaveLength(0);
        expect(w.r2.objects.has(b.key) || w.r2.objects.has(a.key)).toBe(false);
    });
    it("when every delete fails it stops instead of looping on the same rows", async () => {
        const w = await world();
        const a = await seed(w, 40, "aaa");
        w.r2.failDeleteFor.add(a.key);
        const r = await run(w);
        expect(r.crashes).toBe(0);
        expect(r.failed).toBe(1);
    });
    it("works through more than one page of crashes and events", async () => {
        const w = await world();
        const at = w.clock.t - 40 * DAY;
        const ins = w.db.raw.prepare("INSERT INTO telemetry_events (id, ts, level, cat, msg, received_at) VALUES (?, ?, 'info', 'app', 'm', ?)");
        const insC = w.db.raw.prepare("INSERT INTO telemetry_crashes (id, ts, kind, summary, r2_key, received_at) VALUES (?, ?, 'crash', 's', ?, ?)");
        w.db.raw.exec("BEGIN");
        for (let i = 0; i < 2500; i++) ins.run(`e${i}`, at, at);
        for (let i = 0; i < 120; i++) {
            insC.run(`c${i}`, at, `telemetry/crashes/x/c${i}.json`, at + i);
            w.r2.objects.set(`telemetry/crashes/x/c${i}.json`, { body: "{}" });
        }
        w.db.raw.exec("COMMIT");
        const r = await run(w);
        expect(r).toEqual({ events: 2500, crashes: 120, failed: 0 });
        expect(w.r2.objects.size).toBe(0);
    });
    it("nothing to delete is a clean no-op", async () => {
        const w = await world();
        expect(await run(w)).toEqual({ events: 0, crashes: 0, failed: 0 });
    });
});

describe("capability and deploy config", () => {
    it("GET /capabilities reports features.telemetry: true", async () => {
        const w = await world();
        const res = await handleRequest(new Request("https://api.capybaraharmony.com/capabilities"), w.env, { fetch: async () => new Response("") });
        expect(((await res.json()) as any).features.telemetry).toBe(true);
        const direct = await capabilities({ db: w.db, mediaBaseUrl: "https://m/", now: w.clock.now }, "missing", undefined);
        expect((direct.body as any).features.telemetry).toBe(true);
    });
    it("the cf config has a daily cron trigger for the retention run and the private ORIGINALS bucket bound", () => {
        const worker = (config as any).worker;
        expect(worker.triggers).toEqual([{ type: "scheduled", schedule: "23 3 * * *" }]);
        expect(worker.env.ORIGINALS).toMatchObject({ type: "r2", name: "cobalt-originals" });
        expect(worker.domains).toEqual(["api.capybaraharmony.com"]);
    });
    it("the Worker entry exports a scheduled handler that runs the retention", () => {
        const src = readFileSync(new URL("../src/index.ts", import.meta.url), "utf8");
        expect(src).toMatch(/async scheduled\(/);
        expect(src).toMatch(/runTelemetryRetention\(\{ db: env\.DB, originals: env\.ORIGINALS/);
    });
});

describe("migration 0005_telemetry.sql", () => {
    const sql = readFileSync(new URL("../../d1/migrations/0005_telemetry.sql", import.meta.url), "utf8");
    it("is additive: only CREATE TABLE and CREATE INDEX statements", () => {
        const code = sql.replace(/--.*$/gm, "");
        const statements = code.split(";").map((s) => s.trim()).filter(Boolean);
        for (const s of statements) expect(s).toMatch(/^CREATE (TABLE|INDEX) /);
        expect(code).not.toMatch(/\b(DROP|ALTER|DELETE|UPDATE)\b/i);
    });
    it("has the contract's columns and indexes on ts, received_at and level", async () => {
        const w = await world();
        const cols = (t: string) => (w.db.raw.prepare(`PRAGMA table_info(${t})`).all() as any[]).map((c) => c.name);
        expect(cols("telemetry_events")).toEqual(["id", "key_id", "install", "ts", "level", "cat", "msg", "data", "version", "build", "platform", "device", "process", "received_at"]);
        expect(cols("telemetry_crashes")).toEqual(["id", "key_id", "install", "ts", "kind", "summary", "r2_key", "version", "build", "platform", "device", "process", "received_at"]);
        const idx = (t: string) => (w.db.raw.prepare(`PRAGMA index_list(${t})`).all() as any[]).map((i) => i.name);
        expect(idx("telemetry_events")).toEqual(expect.arrayContaining(["idx_telemetry_events_ts", "idx_telemetry_events_received", "idx_telemetry_events_level"]));
        expect(idx("telemetry_crashes")).toEqual(expect.arrayContaining(["idx_telemetry_crashes_ts", "idx_telemetry_crashes_received"]));
    });
});
