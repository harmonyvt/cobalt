// /logs page and /api/logs* (TELEMETRY-CONTRACT.md read side). The real handler runs
// on the real migration SQL (node:sqlite); R2 is an in-memory fake. The page's own
// script is executed against a small DOM stub that talks to the real handler.
import { readFileSync } from "node:fs";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import config from "../cloudflare.config";
import worker from "../src/index";
import {
    DEFAULT_CRASH_LIMIT, DEFAULT_EVENT_LIMIT, LOGS_CSP, MAX_CRASH_LIMIT, MAX_EVENT_LIMIT, handleLogs, matchRoute,
} from "../src/logs";
import { LOGS_HTML } from "../src/logs/page.generated";
import type { Env } from "../src/keys";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { AUD, NOW, OWNER, TEAM, WEB_ORIGIN, goodClaims, makeJwksFetch, makeSigner, newCache, type Signer } from "./support";

const CONTRACT_CSP =
    "default-src 'self'; base-uri 'none'; connect-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'";
const INSTALL = "3f2b8c1a-5d4e-4f6a-9b7c-0d1e2f3a4b5c";
const SECRET_KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";

// ---------- fakes ----------

class FakeR2 {
    objects = new Map<string, string>();
    gets: string[] = [];
    broken = false;
    async get(key: string) {
        this.gets.push(key);
        if (this.broken) throw new Error("R2 down");
        const body = this.objects.get(key);
        if (body === undefined) return null;
        return { size: new TextEncoder().encode(body).length, json: async () => JSON.parse(body) };
    }
}

let signer: Signer;
let token: string;
beforeAll(async () => {
    signer = await makeSigner();
    token = await signer.sign(goodClaims());
});

let db: FakeD1;
let originals: FakeR2;
let env: Env;
beforeEach(() => {
    db = createFakeD1();
    originals = new FakeR2();
    env = {
        DB: db,
        ASSETS: { fetch: async () => new Response("asset") } as unknown as Fetcher,
        ACCESS_TEAM_DOMAIN: TEAM,
        ACCESS_AUD: AUD,
        OWNER_EMAIL: OWNER,
        WEB_ORIGIN,
        MEDIA: {} as R2Bucket,
        ORIGINALS: originals as unknown as R2Bucket,
        MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
        API: { fetch: async () => new Response("no") } as unknown as Fetcher,
        COBALT_API_KEY: SECRET_KEY,
    };
});

const deps = () => ({ jwks: newCache(makeJwksFetch(() => [signer]).fetchFn), now: () => NOW });
function call(path: string, o: { method?: string; token?: string | null } = {}) {
    const headers = new Headers();
    const t = o.token === undefined ? token : o.token;
    if (t) headers.set("Cf-Access-Jwt-Assertion", t);
    return handleLogs(new Request(`${WEB_ORIGIN}${path}`, { method: o.method ?? "GET", headers }), env, deps());
}
const json = async (r: Response) => JSON.parse(await r.text());

// ---------- seeding ----------

let n = 0;
type Ev = Partial<{ id: string; ts: number; level: string; cat: string; msg: string; data: object | null; install: string; version: string; build: string; platform: string; device: string; process: string }>;
function seedEvent(o: Ev = {}) {
    n++;
    const row = {
        id: o.id ?? `ev${String(n).padStart(6, "0")}`, ts: o.ts ?? NOW - n * 1000, level: o.level ?? "info", cat: o.cat ?? "app",
        msg: o.msg ?? `message ${n}`, data: o.data === undefined ? null : o.data === null ? null : JSON.stringify(o.data),
    };
    db.raw.prepare(
        `INSERT INTO telemetry_events (id, key_id, install, ts, level, cat, msg, data, version, build, platform, device, process, received_at)
         VALUES (?, 'key-1', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(row.id, o.install ?? INSTALL, row.ts, row.level, row.cat, row.msg, row.data, o.version ?? "1.3", o.build ?? "4", o.platform ?? "ios", o.device ?? "iPhone18,1", o.process ?? "app", NOW);
    return row;
}

const PAYLOAD = {
    crashDiagnostics: [
        {
            version: "1.0.0",
            applicationVersion: "1.3",
            callStackTree: {
                callStackPerThread: true,
                callStacks: [
                    {
                        threadAttributed: true,
                        callStackRootFrames: [
                            {
                                binaryUUID: "11111111-1111-4111-8111-111111111111", offsetIntoBinaryTextSegment: 48392, binaryName: "Cobalt", address: 4372345672, sampleCount: 1,
                                subFrames: [
                                    {
                                        binaryUUID: "22222222-2222-4222-8222-222222222222", offsetIntoBinaryTextSegment: 1200, binaryName: "libswiftCore.dylib", address: 6500000000, sampleCount: 1,
                                        subFrames: [{ binaryUUID: "33333333-3333-4333-8333-333333333333", offsetIntoBinaryTextSegment: 77, binaryName: "libsystem_kernel.dylib", address: 6900000000, sampleCount: 1, subFrames: [] }],
                                    },
                                ],
                            },
                        ],
                    },
                    { threadAttributed: false, callStackRootFrames: [{ binaryUUID: "44444444-4444-4444-8444-444444444444", offsetIntoBinaryTextSegment: 9, binaryName: "libsystem_pthread.dylib", address: 6800000000, sampleCount: 1, subFrames: [] }] },
                ],
            },
            diagnosticMetaData: { exceptionType: 1, signal: 11, terminationReason: "Namespace SIGNAL, Code 11", virtualMemoryRegionInfo: "0 is not in any region." },
        },
    ],
};
const CRASH_TS = NOW - 60_000;
const LEAD = [
    { ts: CRASH_TS - 1000, level: "error", cat: "pipeline", msg: "encode failed", data: { frames: 12 } },
    { ts: CRASH_TS - 4000, level: "info", cat: "upload", msg: "upload started", data: null },
];
type Cr = Partial<{ id: string; ts: number; kind: string; summary: string; r2: boolean; doc: unknown }>;
function seedCrash(o: Cr = {}) {
    n++;
    const id = o.id ?? `crash${String(n).padStart(8, "0")}`;
    const ts = o.ts ?? CRASH_TS;
    const key = `telemetry/crashes/2027-01-15/${id}.json`;
    db.raw.prepare(
        `INSERT INTO telemetry_crashes (id, key_id, install, ts, kind, summary, r2_key, version, build, platform, device, process, received_at)
         VALUES (?, 'key-1', ?, ?, ?, ?, ?, '1.3', '4', 'ios', 'iPhone18,1', 'app', ?)`,
    ).run(id, INSTALL, ts, o.kind ?? "crash", o.summary ?? "EXC_BAD_ACCESS in Pipeline.run", key, NOW);
    if (o.r2 !== false) {
        const doc = o.doc === undefined
            ? { id, install: INSTALL, ts, kind: o.kind ?? "crash", app: { version: "1.3", build: "4", platform: "ios", os: "26.5", device: "iPhone18,1", process: "app" }, payload: PAYLOAD, events: LEAD }
            : o.doc;
        originals.objects.set(key, typeof doc === "string" ? doc : JSON.stringify(doc));
    }
    return { id, key, ts };
}

// ---------- routing and config ----------

describe("routing config", () => {
    it("runs the Worker first for /logs and /api/logs, and still binds D1 and the private bucket", () => {
        const w = (config as any).worker;
        expect(w.assets.runWorkerFirst).toEqual(expect.arrayContaining(["/logs", "/api/logs", "/api/logs/*"]));
        expect(w.env.DB).toBeDefined();
        expect(w.env.ORIGINALS).toMatchObject({ type: "r2", name: "cobalt-originals" });
    });
    it("matchRoute: the page, the lists and a crash id; nothing else", () => {
        expect(matchRoute("/logs")).toEqual({ name: "page" });
        expect(matchRoute("/api/logs")).toEqual({ name: "events" });
        expect(matchRoute("/api/logs/crashes")).toEqual({ name: "crashes" });
        expect(matchRoute("/api/logs/crashes/abcdef0123456789abcdef01")).toEqual({ name: "crash", id: "abcdef0123456789abcdef01" });
        for (const p of ["/logs/", "/logs/x", "/api/logs/", "/api/logs/x", "/api/logs/crashes/", "/api/logs/crashes/short", "/api/logs/crashes/a/b", "/api/logs/crashes/../../x", "/api/logs/crashes/abcdef0123456789%2e%2e"]) {
            expect(matchRoute(p)).toBeNull();
        }
    });
    it("the Worker entry dispatches /logs and /api/logs* to the handler, never to ASSETS", async () => {
        const seen: string[] = [];
        (env as any).ASSETS = { fetch: async (r: Request) => (seen.push(new URL(r.url).pathname), new Response("asset")) };
        for (const p of ["/logs", "/api/logs", "/api/logs/crashes", "/api/logs/crashes/abcdef0123456789abcdef01"]) {
            const res = await worker.fetch(new Request(WEB_ORIGIN + p), env); // no JWT
            expect(res.status).toBe(401);
        }
        expect(seen).toEqual([]);
        expect(await (await worker.fetch(new Request(WEB_ORIGIN + "/logsx"), env)).text()).toBe("asset");
    });
});

// ---------- Access ----------

const ROUTES = ["/logs", "/api/logs", "/api/logs?level=error", "/api/logs/crashes", "/api/logs/crashes/abcdef0123456789abcdef01"];

describe("Access is required", () => {
    it.each(ROUTES)("%s without a JWT is 401, with the error shape, and nothing is read", async (path) => {
        db.breakIt();
        originals.broken = true;
        const r = await call(path, { token: null });
        expect(r.status).toBe(401);
        expect(await json(r)).toEqual({ status: "error", error: { code: "unauthorized" } });
        expect(r.headers.get("cache-control")).toBe("no-store");
        expect(originals.gets).toEqual([]);
    });
    it.each(ROUTES)("%s with a JWT for the wrong person, audience, issuer or an expired one is 401", async (path) => {
        for (const claims of [goodClaims({ email: "someone@else.com" }), goodClaims({ aud: ["x"] }), goodClaims({ iss: "https://evil.cloudflareaccess.com" }), goodClaims({ exp: NOW / 1000 - 3600 })]) {
            expect((await call(path, { token: await signer.sign(claims) })).status).toBe(401);
        }
        expect((await call(path, { token: "a.b.c" })).status).toBe(401);
    });
    it("a JWKS outage fails closed", async () => {
        const bad = { jwks: newCache(async () => new Response("no", { status: 500 })), now: () => NOW };
        const r = await handleLogs(new Request(`${WEB_ORIGIN}/api/logs`, { headers: { "Cf-Access-Jwt-Assertion": token } }), env, bad);
        expect(r.status).toBe(401);
    });
    it("the owner gets through", async () => {
        expect((await call("/api/logs")).status).toBe(200);
        expect((await call("/logs")).status).toBe(200);
    });
});

describe("shape", () => {
    it("only GET (and HEAD for the page); anything else is a 405 with allow", async () => {
        for (const m of ["POST", "PUT", "DELETE", "PATCH"]) {
            for (const p of ["/logs", "/api/logs", "/api/logs/crashes", "/api/logs/crashes/abcdef0123456789abcdef01"]) {
                const r = await call(p, { method: m });
                expect(r.status).toBe(405);
                expect(await json(r)).toEqual({ status: "error", error: { code: "error.logs.method" } });
            }
        }
        expect((await call("/logs", { method: "POST" })).headers.get("allow")).toBe("GET, HEAD");
        expect((await call("/api/logs", { method: "HEAD" })).status).toBe(405);
    });
    it("an unknown path under /api/logs is a 404 with the error shape", async () => {
        const r = await call("/api/logs/nope");
        expect(r.status).toBe(404);
        expect(await json(r)).toEqual({ status: "error", error: { code: "error.logs.not_found" } });
    });
});

// ---------- the page ----------

describe("GET /logs", () => {
    it("serves the embedded page with the pinned CSP and no-store, and HEAD has no body", async () => {
        const r = await call("/logs");
        expect(r.status).toBe(200);
        expect(r.headers.get("content-type")).toBe("text/html; charset=utf-8");
        expect(r.headers.get("content-security-policy")).toBe(CONTRACT_CSP);
        expect(LOGS_CSP).toBe(CONTRACT_CSP);
        expect(r.headers.get("cache-control")).toBe("no-store");
        expect(r.headers.get("x-content-type-options")).toBe("nosniff");
        expect(r.headers.get("referrer-policy")).toBe("no-referrer");
        expect(await r.text()).toBe(LOGS_HTML);
        const head = await call("/logs", { method: "HEAD" });
        expect(head.status).toBe(200);
        expect(await head.text()).toBe("");
    });
    it("page.generated.ts is in sync with page.html (run npm run logs:build)", () => {
        expect(LOGS_HTML).toBe(readFileSync(new URL("../src/logs/page.html", import.meta.url), "utf8"));
    });
    it("is self-contained, CSP-clean, writes no HTML from data, and has a valid inline script", () => {
        expect(LOGS_HTML).toContain('name="viewport"');
        expect(LOGS_HTML).not.toMatch(/<script[^>]*\bsrc=/i);
        const hosts = new Set([...LOGS_HTML.matchAll(/https?:\/\/([a-z0-9.-]+)/gi)].map((m) => m[1]));
        for (const h of hosts) expect(["fonts.googleapis.com", "fonts.gstatic.com"]).toContain(h);
        // data from the app is only ever put in with textContent
        expect(LOGS_HTML).not.toMatch(/innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(/);
        expect(LOGS_HTML).toContain("IBM+Plex+Mono");
        expect(LOGS_HTML).toMatch(/prefers-color-scheme: dark/);
        expect(LOGS_HTML).toMatch(/max-width: 560px/);
        const m = /<script>([\s\S]*)<\/script>/.exec(LOGS_HTML);
        expect(m).toBeTruthy();
        expect(() => new Function(m![1]!)).not.toThrow();
    });
    it("never mentions API keys", () => {
        expect(LOGS_HTML.toLowerCase()).not.toContain("api-key");
        expect(LOGS_HTML).not.toContain("COBALT_API_KEY");
    });
});

// ---------- GET /api/logs (events) ----------

describe("GET /api/logs", () => {
    it("empty: success with no events and no cursor", async () => {
        expect(await json(await call("/api/logs"))).toEqual({ status: "success", events: [], next_before: null });
    });
    it("newest first (by the device's ts), with every field, data parsed, and no key id", async () => {
        seedEvent({ id: "a", ts: NOW - 3000, msg: "oldest" });
        seedEvent({ id: "b", ts: NOW - 1000, msg: "newest", level: "error", cat: "net", data: { status: 503, retry: true, host: "api" }, device: "iPhone17,1", process: "share" });
        seedEvent({ id: "c", ts: NOW - 2000, msg: "middle" });
        const r = await call("/api/logs");
        expect(r.headers.get("content-type")).toBe("application/json");
        expect(r.headers.get("cache-control")).toBe("no-store");
        const body = await json(r);
        expect(body.events.map((e: any) => e.msg)).toEqual(["newest", "middle", "oldest"]);
        expect(body.events[0]).toEqual({
            id: "b", install: INSTALL, ts: NOW - 1000, level: "error", cat: "net", msg: "newest",
            data: { status: 503, retry: true, host: "api" }, version: "1.3", build: "4", platform: "ios",
            device: "iPhone17,1", process: "share", received_at: NOW,
        });
        expect(body.events[1].data).toBeNull();
        expect(JSON.stringify(body)).not.toContain("key-1");
        expect(body.next_before).toBeNull();
    });
    it("a corrupt data column reads as null, not a 500", async () => {
        seedEvent({ id: "a" });
        db.raw.prepare("UPDATE telemetry_events SET data = '{nope' WHERE id = 'a'").run();
        expect((await json(await call("/api/logs"))).events[0].data).toBeNull();
    });
    it("filters by level, with commas for several", async () => {
        seedEvent({ level: "debug" }); seedEvent({ level: "info" }); seedEvent({ level: "warn" }); seedEvent({ level: "error" }); seedEvent({ level: "error" });
        const lv = async (q: string) => (await json(await call(`/api/logs?${q}`))).events.map((e: any) => e.level).sort();
        expect(await lv("level=error")).toEqual(["error", "error"]);
        expect(await lv("level=warn,error")).toEqual(["error", "error", "warn"]);
        expect(await lv("level=debug,info,warn,error")).toHaveLength(5);
        expect(await lv("level=")).toHaveLength(5);
    });
    it("filters by cat, and by level and cat together", async () => {
        seedEvent({ cat: "net", level: "error" }); seedEvent({ cat: "net", level: "info" }); seedEvent({ cat: "sync", level: "error" }); seedEvent({ cat: "photos", level: "warn" });
        const get = async (q: string) => (await json(await call(`/api/logs?${q}`))).events.map((e: any) => `${e.cat}/${e.level}`).sort();
        expect(await get("cat=net")).toEqual(["net/error", "net/info"]);
        expect(await get("cat=net,photos")).toEqual(["net/error", "net/info", "photos/warn"]);
        expect(await get("level=error&cat=net")).toEqual(["net/error"]);
        expect(await get("level=error&cat=ui")).toEqual([]);
    });
    it("paginates with next_before, including rows that share a millisecond, with no gaps or repeats", async () => {
        const ids: string[] = [];
        for (let i = 0; i < 12; i++) ids.push(seedEvent({ id: `e${String(i).padStart(2, "0")}`, ts: NOW - Math.floor(i / 3) * 1000 }).id); // 3 per ms
        const seen: string[] = [];
        let before: string | null = null;
        let pages = 0;
        do {
            const body: any = await json(await call(`/api/logs?limit=5${before ? `&before=${encodeURIComponent(before)}` : ""}`));
            expect(body.events.length).toBeLessThanOrEqual(5);
            seen.push(...body.events.map((e: any) => e.id));
            before = body.next_before;
            pages++;
        } while (before);
        expect(pages).toBe(3);
        expect(seen).toHaveLength(12);
        expect(new Set(seen).size).toBe(12);
        expect(seen).toEqual([...ids].sort((a, b) => { const ta = Math.floor(ids.indexOf(a) / 3), tb = Math.floor(ids.indexOf(b) / 3); return ta - tb || (a < b ? 1 : -1); }));
    });
    it("a plain-ms before returns strictly older events; a filter keeps applying across pages", async () => {
        seedEvent({ ts: NOW - 1000, level: "error", msg: "e1" }); seedEvent({ ts: NOW - 2000, level: "info", msg: "i2" }); seedEvent({ ts: NOW - 3000, level: "error", msg: "e3" });
        expect((await json(await call(`/api/logs?before=${NOW - 1000}`))).events.map((e: any) => e.msg)).toEqual(["i2", "e3"]);
        const p1: any = await json(await call("/api/logs?level=error&limit=1"));
        expect(p1.events.map((e: any) => e.msg)).toEqual(["e1"]);
        const p2: any = await json(await call(`/api/logs?level=error&limit=1&before=${encodeURIComponent(p1.next_before)}`));
        expect(p2.events.map((e: any) => e.msg)).toEqual(["e3"]);
        expect(p2.next_before).toBeNull();
    });
    it(`defaults to ${DEFAULT_EVENT_LIMIT} and caps at ${MAX_EVENT_LIMIT}`, async () => {
        db.raw.exec("BEGIN");
        for (let i = 0; i < 230; i++) seedEvent({ id: `x${String(i).padStart(4, "0")}`, ts: NOW - i });
        db.raw.exec("COMMIT");
        const d: any = await json(await call("/api/logs"));
        expect(d.events).toHaveLength(DEFAULT_EVENT_LIMIT);
        expect(d.next_before).toBeTruthy();
        expect((await json(await call(`/api/logs?limit=${MAX_EVENT_LIMIT}`))).events).toHaveLength(MAX_EVENT_LIMIT);
        expect((await call(`/api/logs?limit=${MAX_EVENT_LIMIT + 1}`)).status).toBe(400);
    });
    const bad = ["level=fatal", "level=error,nope", "cat=billing", "limit=0", "limit=-1", "limit=abc", "limit=1.5", "before=abc", "before=-5", "before=123_", "before=123_a/b", "before=1e9", "level=error;drop"];
    it.each(bad)("%s is a 400 error.logs.bad_request", async (q) => {
        const r = await call(`/api/logs?${q}`);
        expect(r.status).toBe(400);
        expect(await json(r)).toEqual({ status: "error", error: { code: "error.logs.bad_request" } });
    });
    it("a filter value cannot inject SQL (it is rejected, and the table is intact)", async () => {
        seedEvent();
        expect((await call("/api/logs?cat=app'%20OR%201=1--")).status).toBe(400);
        expect((await json(await call("/api/logs"))).events).toHaveLength(1);
    });
    it("D1 failure is a 500 error.logs.server, not a thrown error", async () => {
        db.breakIt();
        const r = await call("/api/logs");
        expect(r.status).toBe(500);
        expect(await json(r)).toEqual({ status: "error", error: { code: "error.logs.server" } });
    });
});

// ---------- GET /api/logs/crashes ----------

describe("GET /api/logs/crashes", () => {
    it("newest first, with the row's fields and neither the R2 key nor the key id", async () => {
        seedCrash({ id: "crashAAAAAAAA", ts: NOW - 5000, summary: "older", kind: "hang" });
        seedCrash({ id: "crashBBBBBBBB", ts: NOW - 1000, summary: "newer" });
        const body: any = await json(await call("/api/logs/crashes"));
        expect(body.crashes.map((c: any) => c.summary)).toEqual(["newer", "older"]);
        expect(body.crashes[0]).toEqual({
            id: "crashBBBBBBBB", install: INSTALL, ts: NOW - 1000, kind: "crash", summary: "newer", version: "1.3", build: "4",
            platform: "ios", device: "iPhone18,1", process: "app", received_at: NOW,
        });
        expect(JSON.stringify(body)).not.toMatch(/r2_key|telemetry\/crashes|key-1/);
        expect(body.next_before).toBeNull();
        expect(originals.gets).toEqual([]); // the list never reads R2
    });
    it("empty list", async () => {
        expect(await json(await call("/api/logs/crashes"))).toEqual({ status: "success", crashes: [], next_before: null });
    });
    it("filters by kind (several with commas) and rejects unknown kinds", async () => {
        seedCrash({ kind: "crash" }); seedCrash({ kind: "hang" }); seedCrash({ kind: "unclean_exit" });
        const kinds = async (q: string) => (await json(await call(`/api/logs/crashes?${q}`))).crashes.map((c: any) => c.kind).sort();
        expect(await kinds("kind=hang")).toEqual(["hang"]);
        expect(await kinds("kind=crash,unclean_exit")).toEqual(["crash", "unclean_exit"]);
        expect((await call("/api/logs/crashes?kind=panic")).status).toBe(400);
    });
    it(`paginates, defaults to ${DEFAULT_CRASH_LIMIT}, caps at ${MAX_CRASH_LIMIT}`, async () => {
        for (let i = 0; i < 7; i++) seedCrash({ ts: NOW - i * 1000, summary: `c${i}` });
        const p1: any = await json(await call("/api/logs/crashes?limit=3"));
        expect(p1.crashes.map((c: any) => c.summary)).toEqual(["c0", "c1", "c2"]);
        const p2: any = await json(await call(`/api/logs/crashes?limit=3&before=${encodeURIComponent(p1.next_before)}`));
        expect(p2.crashes.map((c: any) => c.summary)).toEqual(["c3", "c4", "c5"]);
        const p3: any = await json(await call(`/api/logs/crashes?limit=3&before=${encodeURIComponent(p2.next_before)}`));
        expect(p3.crashes.map((c: any) => c.summary)).toEqual(["c6"]);
        expect(p3.next_before).toBeNull();
        expect((await call(`/api/logs/crashes?limit=${MAX_CRASH_LIMIT + 1}`)).status).toBe(400);
        expect((await call(`/api/logs/crashes?limit=${MAX_CRASH_LIMIT}`)).status).toBe(200);
    });
});

// ---------- GET /api/logs/crashes/<id> ----------

describe("GET /api/logs/crashes/<id>", () => {
    it("returns the row plus the payload, the app and the lead-up events from R2", async () => {
        const c = seedCrash();
        const r = await call(`/api/logs/crashes/${c.id}`);
        expect(r.status).toBe(200);
        expect(r.headers.get("cache-control")).toBe("no-store");
        const body: any = await json(r);
        expect(body.status).toBe("success");
        expect(body.crash).toMatchObject({
            id: c.id, install: INSTALL, ts: c.ts, kind: "crash", summary: "EXC_BAD_ACCESS in Pipeline.run", version: "1.3", build: "4",
            platform: "ios", device: "iPhone18,1", process: "app", payload_missing: false,
            app: { version: "1.3", os: "26.5" },
        });
        expect(body.crash.payload).toEqual(PAYLOAD);
        expect(body.crash.events).toEqual(LEAD);
        expect(body.crash.r2_key).toBeUndefined();
        expect(JSON.stringify(body)).not.toContain("key-1");
        expect(originals.gets).toEqual([c.key]); // the object key came from the row
    });
    it("a crash with a null payload and no events", async () => {
        const c = seedCrash({ kind: "unclean_exit", doc: { id: "x", payload: null, events: [] } });
        const body: any = await json(await call(`/api/logs/crashes/${c.id}`));
        expect(body.crash).toMatchObject({ kind: "unclean_exit", payload: null, events: [], payload_missing: false });
    });
    it("a row whose R2 object is gone (or unreadable) still answers, flagged payload_missing", async () => {
        const gone = seedCrash({ r2: false });
        const corrupt = seedCrash({ doc: "{not json" });
        const arrayDoc = seedCrash({ doc: [1, 2] });
        for (const c of [gone, corrupt, arrayDoc]) {
            const r = await call(`/api/logs/crashes/${c.id}`);
            expect(r.status).toBe(200);
            expect((await json(r)).crash).toMatchObject({ id: c.id, payload: null, events: [], app: null, payload_missing: true });
        }
    });
    it("an oversized stored object is not parsed", async () => {
        const c = seedCrash({ doc: { payload: { pad: "x".repeat(1_100_000) } } });
        expect((await json(await call(`/api/logs/crashes/${c.id}`))).crash.payload_missing).toBe(true);
    });
    it("an unknown id is a 404; ids that are not ours never reach D1 or R2", async () => {
        const r = await call("/api/logs/crashes/doesnotexist0000");
        expect(r.status).toBe(404);
        expect(await json(r)).toEqual({ status: "error", error: { code: "error.logs.not_found" } });
        for (const p of ["short", "has space here", "..%2f..%2fsecret", "a".repeat(65)]) {
            expect((await call(`/api/logs/crashes/${p}`)).status).toBe(404);
        }
        expect(originals.gets).toEqual([]);
    });
    it("R2 down is a 500, not an exception", async () => {
        const c = seedCrash();
        originals.broken = true;
        expect((await call(`/api/logs/crashes/${c.id}`)).status).toBe(500);
    });
});

// ---------- the page's own script, run against the real handler ----------

class El {
    attrs: Record<string, string> = {};
    children: El[] = [];
    listeners: Record<string, ((e?: unknown) => void)[]> = {};
    parent: El | null = null;
    className = "";
    hidden = false;
    open = false;
    title = "";
    onclick: (() => void) | null = null;
    private own = "";
    constructor(public tag: string, public id = "") {}
    setAttribute(k: string, v: string) { this.attrs[k] = v; if (k === "class") this.className = v; }
    getAttribute(k: string) { return this.attrs[k] ?? null; }
    append(...nodes: (El | string)[]) {
        for (const n of nodes) {
            const el = typeof n === "string" ? Object.assign(new El("#text"), { own: n }) : n;
            el.parent = this;
            this.children.push(el);
        }
    }
    replaceChildren(...nodes: (El | string)[]) { this.children = []; this.append(...nodes); }
    addEventListener(t: string, f: (e?: unknown) => void) { (this.listeners[t] ??= []).push(f); }
    click() { this.onclick?.(); for (const f of this.listeners.click ?? []) f({}); }
    remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); this.parent = null; }
    scrollIntoView() {}
    set textContent(v: string) { this.children = []; this.own = String(v); }
    get textContent(): string { return this.own + this.children.map((c) => c.textContent).join(" "); }
    find(pred: (e: El) => boolean): El[] { return [...(pred(this) ? [this] : []), ...this.children.flatMap((c) => c.find(pred))]; }
    byClass(cls: string) { return this.find((e) => e.className.split(/\s+/).includes(cls)); }
}

async function until(cond: () => boolean, what: string) {
    for (let i = 0; i < 400; i++) {
        if (cond()) return;
        await new Promise((r) => setTimeout(r, 5));
    }
    throw new Error(`timed out waiting for ${what}`);
}

function boot(opts: { hash?: string; jwt?: string | null } = {}) {
    const ids = new Map<string, El>();
    for (const m of LOGS_HTML.matchAll(/\bid="([A-Za-z]+)"/g)) ids.set(m[1]!, new El("div", m[1]));
    const requests: string[] = [];
    const clip: string[] = [];
    const doc = { getElementById: (id: string) => ids.get(id)!, createElement: (t: string) => new El(t) };
    const fetchFn = async (path: string) => {
        requests.push(path);
        const headers = new Headers();
        const t = opts.jwt === undefined ? token : opts.jwt;
        if (t) headers.set("Cf-Access-Jwt-Assertion", t);
        return handleLogs(new Request(`${WEB_ORIGIN}${path}`, { headers }), env, deps());
    };
    const loc = { hash: opts.hash ?? "", pathname: "/logs", search: "" };
    const hist = { replaceState: (_s: unknown, _t: string, url: string) => { loc.hash = url.includes("#") ? url.slice(url.indexOf("#")) : ""; } };
    const script = /<script>([\s\S]*)<\/script>/.exec(LOGS_HTML)![1]!;
    const run = new Function("document", "fetch", "location", "history", "navigator", "window", "AbortController", script);
    run(doc, fetchFn, loc, hist, { clipboard: { writeText: async (s: string) => void clip.push(s) } }, { getSelection: () => "" }, AbortController);
    return { $: (id: string) => ids.get(id)!, requests, clip, loc };
}

describe("the page's script", () => {
    it("loads crashes and events, newest first, rendering app text as text (a hostile message stays inert)", async () => {
        seedCrash({ summary: "EXC_BAD_ACCESS in Pipeline.run" });
        seedEvent({ ts: NOW - 1000, msg: "<img src=x onerror=alert(1)> newest", level: "error", cat: "net" });
        seedEvent({ ts: NOW - 5000, msg: "older one", level: "info", cat: "sync" });
        const p = boot();
        await until(() => p.$("evList").byClass("ev").length === 2 && p.$("crashList").byClass("crow").length === 1, "first render");
        expect(p.requests).toContain("/api/logs/crashes?limit=20");
        expect(p.requests).toContain("/api/logs?limit=100");
        const rows = p.$("evList").byClass("ev");
        expect(rows[0]!.byClass("msg")[0]!.textContent).toBe("<img src=x onerror=alert(1)> newest");
        expect(rows[0]!.find((e) => e.tag === "img")).toEqual([]); // no element was created from the text
        expect(rows[1]!.byClass("msg")[0]!.textContent).toBe("older one");
        expect(p.$("crashList").byClass("sum")[0]!.textContent).toBe("EXC_BAD_ACCESS in Pipeline.run");
        expect(p.$("crashList").byClass("badge")[0]!.textContent).toBe("crash");
        expect(p.$("crashList").textContent).toContain("build 1.3 (4)");
        expect(p.$("crashList").textContent).toContain("ios · iPhone18,1 · app");
        expect(p.$("evCount").textContent).toBe("2");
        expect(p.$("evMore").hidden).toBe(true);
    });
    it("the chips refetch with level and cat filters, and clearing them drops the filter", async () => {
        seedEvent({ level: "error", cat: "net", msg: "boom" });
        seedEvent({ level: "info", cat: "sync", msg: "fine" });
        const p = boot();
        await until(() => p.$("evList").byClass("ev").length === 2, "unfiltered");
        const chip = (box: string, label: string) => p.$(box).byClass("chip").find((c) => c.textContent === label)!;
        chip("levelChips", "error").click();
        await until(() => p.requests.includes("/api/logs?limit=100&level=error") && p.$("evList").byClass("ev").length === 1, "level filter");
        expect(chip("levelChips", "error").getAttribute("aria-pressed")).toBe("true");
        expect(p.$("evList").byClass("msg")[0]!.textContent).toBe("boom");
        chip("catChips", "net").click();
        await until(() => p.requests.includes("/api/logs?limit=100&level=error&cat=net"), "level and cat filter");
        chip("levelChips", "error").click();
        await until(() => p.requests.includes("/api/logs?limit=100&cat=net"), "level cleared");
        chip("catChips", "net").click();
        await until(() => p.$("evList").byClass("ev").length === 2, "all cleared");
        expect(chip("catChips", "net").getAttribute("aria-pressed")).toBe("false");
    });
    it("a filter with no matches says so; load older appears only when there is more", async () => {
        for (let i = 0; i < 101; i++) seedEvent({ ts: NOW - i, id: `p${String(i).padStart(4, "0")}` });
        const p = boot();
        await until(() => p.$("evList").byClass("ev").length === 100, "first page");
        expect(p.$("evMore").hidden).toBe(false);
        expect(p.$("evCount").textContent).toBe("100+");
        p.$("evMoreBtn").click();
        await until(() => p.$("evList").byClass("ev").length === 101, "second page");
        expect(p.$("evMore").hidden).toBe(true);
        expect(p.requests.some((r) => /before=\d+_p0099/.test(r))).toBe(true);
        p.$("catChips").byClass("chip").find((c) => c.textContent === "photos")!.click();
        await until(() => p.$("evStatus").textContent.includes("no events match"), "empty filter");
    });
    it("tapping an event shows its data and where it came from; tapping again hides it", async () => {
        seedEvent({ msg: "retrying", data: { attempt: 2, host: "api", cached: false }, device: "Mac15,3", platform: "macos", process: "share" });
        const p = boot();
        await until(() => p.$("evList").byClass("ev").length === 1, "event");
        const row = p.$("evList").byClass("ev")[0]!;
        row.click();
        expect(row.getAttribute("aria-expanded")).toBe("true");
        expect(row.byClass("dat")[0]!.textContent).toContain("attempt");
        expect(row.byClass("dat")[0]!.textContent).toContain("2");
        expect(row.byClass("dat")[0]!.textContent).toContain("false");
        expect(row.byClass("sub")[0]!.textContent).toBe("1.3 (4) · macos · Mac15,3 · share");
        row.click();
        expect(row.getAttribute("aria-expanded")).toBe("false");
        expect(row.byClass("dat")).toEqual([]);
    });
    it("opening a crash renders the MetricKit tree as frames (binary, offset, address), the metadata and the lead-up events", async () => {
        const c = seedCrash();
        const p = boot();
        await until(() => p.$("crashList").byClass("crow").length === 1, "crash list");
        p.$("crashList").byClass("crow")[0]!.click();
        await until(() => p.$("detail").byClass("frame").length === 4, "detail");
        expect(p.$("detail").hidden).toBe(false);
        expect(p.$("crashCard").hidden).toBe(true);
        expect(p.loc.hash).toBe(`#crash=${c.id}`);
        expect(p.requests).toContain(`/api/logs/crashes/${c.id}`);
        const frames = p.$("detail").byClass("frame");
        // thread 0, a linear chain: it stays at one indent, in order; thread 1 has its own frame
        expect(frames.map((f) => f.byClass("fb")[0]!.textContent)).toEqual(["Cobalt", "libswiftCore.dylib", "libsystem_kernel.dylib", "libsystem_pthread.dylib"]);
        expect(frames[0]!.byClass("fo")[0]!.textContent).toBe("+48392");
        expect(frames[0]!.byClass("fa")[0]!.textContent).toBe("0x" + (4372345672).toString(16));
        expect(frames[0]!.getAttribute("title")).toBe("binary 11111111-1111-4111-8111-111111111111");
        expect(new Set(frames.map((f) => f.getAttribute("style")))).toEqual(new Set(["padding-left:0px"]));
        expect(p.$("detail").textContent).toContain("crashed here");
        const threads = p.$("detail").byClass("thread");
        expect(threads).toHaveLength(2);
        expect(threads[0]!.open).toBe(true); // the attributed thread is open, the other collapsed
        expect(threads[1]!.open).toBe(false);
        // metadata
        expect(p.$("detail").textContent).toContain("terminationReason");
        expect(p.$("detail").textContent).toContain("Namespace SIGNAL, Code 11");
        // meta block
        expect(p.$("detail").textContent).toContain("iPhone18,1");
        expect(p.$("detail").textContent).toContain("26.5");
        // the lead-up events, oldest first, relative to the crash, then the crash marker
        const lead = p.$("detail").byClass("ev");
        expect(lead.map((e) => e.byClass("msg")[0]!.textContent)).toEqual(["upload started", "encode failed", "crash: EXC_BAD_ACCESS in Pipeline.run"]);
        expect(lead.map((e) => e.byClass("t")[0]!.textContent)).toEqual(["-4.0 s", "-1.0 s", "0.0 s"]);
        // raw json is there, and copy frames puts the symbolication fields on the clipboard
        expect(p.$("detail").byClass("raw")[0]!.textContent).toContain('"binaryUUID": "11111111-1111-4111-8111-111111111111"');
        const copyFrames = p.$("detail").find((e) => e.tag === "button" && e.textContent === "copy frames")[0]!;
        copyFrames.click();
        expect(p.clip[0]!.split("\n")[0]).toContain("Cobalt");
        expect(p.clip[0]!.split("\n")[0]).toContain("+48392");
        expect(p.clip[0]!.split("\n")[0]).toContain("11111111-1111-4111-8111-111111111111");
        expect(p.clip[0]!.split("\n")).toHaveLength(3);
        // back to the list
        p.$("detail").find((e) => e.tag === "button" && e.textContent === "← all crashes")[0]!.click();
        expect(p.$("detail").hidden).toBe(true);
        expect(p.$("crashCard").hidden).toBe(false);
        expect(p.loc.hash).toBe("");
    });
    it("a branching (sampled) tree indents by one per branch level", async () => {
        const tree = {
            hangDiagnostics: [{ callStackTree: { callStackPerThread: false, callStacks: [{ threadAttributed: true, callStackRootFrames: [
                { binaryName: "A", sampleCount: 9, address: 1, offsetIntoBinaryTextSegment: 1, subFrames: [
                    { binaryName: "B", sampleCount: 5, address: 2, offsetIntoBinaryTextSegment: 2, subFrames: [] },
                    { binaryName: "C", sampleCount: 4, address: 3, offsetIntoBinaryTextSegment: 3, subFrames: [{ binaryName: "D", sampleCount: 4, address: 4, offsetIntoBinaryTextSegment: 4, subFrames: [] }] },
                ] }] }] }, diagnosticMetaData: { hangDuration: "2.1 s" } }],
        };
        const c = seedCrash({ kind: "hang", summary: "main thread hang", doc: { id: "x", payload: tree, events: [] } });
        const p = boot({ hash: `#crash=${c.id}` });
        await until(() => p.$("detail").byClass("frame").length === 4, "hang detail");
        const rows = p.$("detail").byClass("frame");
        expect(rows.map((f) => f.byClass("fb")[0]!.textContent + ":" + f.getAttribute("style"))).toEqual(["A:padding-left:0px", "B:padding-left:14px", "C:padding-left:14px", "D:padding-left:14px"]);
        expect(rows[0]!.byClass("fs")[0]!.textContent).toBe("x9");
        expect(p.$("detail").textContent).toContain("hangDuration");
        expect(p.$("detail").textContent).toContain("hang");
        expect(p.$("detail").textContent).toContain("the app sent no events");
    });
    it("a payload with no call stack tree shows the raw json; a null payload and a missing object say so", async () => {
        const odd = seedCrash({ summary: "odd", doc: { payload: { somethingElse: [1, 2, 3] }, events: [] } });
        let p = boot({ hash: `#crash=${odd.id}` });
        await until(() => p.$("detail").textContent.includes("no call stack tree"), "no tree");
        expect(p.$("detail").byClass("raw")[0]!.textContent).toContain("somethingElse");

        const nul = seedCrash({ kind: "unclean_exit", summary: "nul", doc: { payload: null, events: [] } });
        p = boot({ hash: `#crash=${nul.id}` });
        await until(() => p.$("detail").textContent.includes("no diagnostic payload"), "null payload");

        const gone = seedCrash({ summary: "gone", r2: false });
        p = boot({ hash: `#crash=${gone.id}` });
        await until(() => p.$("detail").textContent.includes("payload for this crash is gone"), "missing object");
        expect(p.$("detail").textContent).toContain("gone");
    });
    it("a crash that aged out says so; a failing load shows the error, not a blank page", async () => {
        const p = boot({ hash: "#crash=doesnotexist0000" });
        await until(() => p.$("detail").textContent.includes("aged out"), "404 text");
        db.breakIt();
        const q = boot();
        await until(() => q.$("evStatus").className === "status bad", "event error");
        expect(q.$("evStatus").textContent).toContain("couldn't load");
        expect(q.$("crashStatus").textContent).toContain("couldn't load");
    });
    it("an expired login shows the reload banner", async () => {
        const p = boot({ jwt: null });
        await until(() => !p.$("banner").hidden && p.$("evStatus").textContent.includes("login expired"), "banner");
    });
    it("an empty database reads as good news, not as an error", async () => {
        const p = boot();
        await until(() => p.$("crashStatus").textContent.includes("no crashes recorded"), "empty crashes");
        await until(() => p.$("evStatus").textContent.includes("no events yet"), "empty events");
    });
});
