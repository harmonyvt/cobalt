import { beforeEach, describe, expect, it } from "vitest";
import { KEY_ID_HEADER, PORT_HEADER } from "../src/headers";
import { hashKey } from "../src/keys";
import { SESSION_TTL_MS, SAVING_STUCK_MS, parseRange } from "../src/studio";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { Clock, MemoryMedia, MemoryOriginals } from "./studio-fakes";

const ORIGIN = "https://cobalt.capybaraharmony.com";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const KEY_ID = "key-row-1";
const SID = "aB3dE6gH9jK2mN5pQ8sTuV";
const JOB = "aB3dE6gH9jK2mN5pQ8sT";
const LINK = "https://x.com/maria_rcks/status/2105237035271258436";
const SIZE = 1000;

let db: FakeD1;
let clock: Clock;
let originals: MemoryOriginals;
let media: MemoryMedia;
let seen: Request[];
const container = {
    async fetch(r: Request) {
        seen.push(r);
        return new Response('{"status":"ok"}', { headers: { "content-type": "application/json" } });
    },
};
const env = (over: Partial<WorkerEnv> = {}): WorkerEnv => ({
    API_URL: "https://api.capybaraharmony.com/",
    CORS_URL: ORIGIN,
    COBALT_API_KEY: INTERNAL,
    DB: db,
    ORIGINALS: originals,
    MEDIA: media,
    MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
    ...over,
});
const call = (url: string, init: RequestInit = {}, e = env()) =>
    handleRequest(new Request(`https://api.capybaraharmony.com${url}`, init), e, container, {
        now: clock.now,
        sleep: clock.sleep,
    });
const auth = { authorization: `Api-Key ${CLIENT}` };
const acao = (r: Response) => r.headers.get("access-control-allow-origin");

const seed = (over: Record<string, unknown> = {}) => {
    const r = {
        id: SID,
        key_id: KEY_ID,
        link: LINK,
        service: "x",
        title: "x_2105237035271258436",
        status: "ready",
        error_code: null,
        r2_key: `originals/${SID}.mp4`,
        content_type: "video/mp4",
        bytes: SIZE,
        duration: 9.6,
        width: 480,
        height: 560,
        created_at: clock.t,
        expires_at: clock.t + SESSION_TTL_MS,
        ...over,
    };
    db.raw
        .prepare(
            "INSERT INTO studio_sessions (id, key_id, link, service, title, status, error_code, r2_key, content_type, bytes, duration, width, height, created_at, expires_at) VALUES (@id,@key_id,@link,@service,@title,@status,@error_code,@r2_key,@content_type,@bytes,@duration,@width,@height,@created_at,@expires_at)",
        )
        .run(r as any);
    return r;
};
const seedRender = (id: string, status: string, created: number, url: string | null = null) =>
    db.raw
        .prepare(
            "INSERT INTO studio_renders (id, session_id, status, url, start, length, width, quality, bytes, out_width, out_height, seconds, created_at) VALUES (?,?,?,?,2,5,480,'med',1500,480,560,5,?)",
        )
        .run(id, SID, status, url, created);

beforeEach(async () => {
    db = createFakeD1();
    clock = new Clock();
    originals = new MemoryOriginals();
    media = new MemoryMedia();
    seen = [];
    db.raw
        .prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)")
        .run(KEY_ID, "test", await hashKey(CLIENT), "0b5f2c3e", 1);
});

describe("CORS on /studio*", () => {
    it("OPTIONS preflight from the web origin: 204 with the contract headers, container untouched", async () => {
        for (const p of ["/studio", `/studio/${SID}`, `/studio/${SID}/source`, `/studio/${SID}/render`, `/studio/${SID}/render/${JOB}`]) {
            const res = await call(p, { method: "OPTIONS", headers: { origin: ORIGIN, "access-control-request-method": "POST" } });
            expect(res.status).toBe(204);
            expect(await res.text()).toBe("");
            expect(res.headers.get("access-control-allow-origin")).toBe(ORIGIN);
            expect(res.headers.get("access-control-allow-methods")).toBe("GET, POST, OPTIONS");
            expect(res.headers.get("access-control-allow-headers")).toBe("content-type, range");
            expect(res.headers.get("access-control-max-age")).toBe("600");
        }
        expect(seen).toHaveLength(0);
    });
    it("OPTIONS from another origin, or none, is 403 and never forwarded", async () => {
        expect((await call(`/studio/${SID}`, { method: "OPTIONS", headers: { origin: "https://evil.example" } })).status).toBe(403);
        expect((await call(`/studio/${SID}`, { method: "OPTIONS" })).status).toBe(403);
        expect(seen).toHaveLength(0);
    });
    it("every /studio response carries the web origin, with or without an Origin header, rejections included", async () => {
        seed();
        originals.objects.set(`originals/${SID}.mp4`, { bytes: new Uint8Array(SIZE), contentType: "video/mp4", meta: {} });
        const responses = [
            await call(`/studio/${SID}`),
            await call(`/studio/${SID}`, { headers: { origin: "https://evil.example" } }),
            await call(`/studio/${SID}/source`),
            await call(`/studio/${"z".repeat(22)}`), // unknown session: 404
            await call("/studio/short"), // gate 404, empty body
            await call("/studio", { method: "POST" }), // 401
            await call(`/studio/${SID}/render`, { method: "POST", body: "{}" }), // via the container
            await call(`/studio/${SID}/render/${JOB}`),
        ];
        for (const r of responses) expect(acao(r)).toBe(ORIGIN);
    });
    it("does not add studio CORS to other routes", async () => {
        expect(acao(await call(`/webp/${"a".repeat(20)}`, { headers: auth }))).toBeNull();
    });
});

describe("POST /studio", () => {
    const post = (body: string, headers: Record<string, string> = auth) =>
        call("/studio", { method: "POST", headers: { "content-type": "application/json", ...headers }, body });

    it("looks the key up and forwards to the DO with the key id, not the client key", async () => {
        const res = await post(JSON.stringify({ url: LINK }), { ...auth, [KEY_ID_HEADER]: "spoofed", [PORT_HEADER]: "9100" });
        expect(res.status).toBe(200); // the fake container's answer
        expect(seen).toHaveLength(1);
        const r = seen[0];
        expect(new URL(r.url).pathname).toBe("/studio");
        expect(r.method).toBe("POST");
        expect(r.headers.get(KEY_ID_HEADER)).toBe(KEY_ID);
        expect(r.headers.has("authorization")).toBe(false);
        expect(r.headers.has(PORT_HEADER)).toBe(false);
        expect(JSON.parse(await r.text())).toEqual({ url: LINK });
    });
    it("extracts the first link from free text (share input + clipboard) before forwarding", async () => {
        await post(JSON.stringify({ url: `check this ${LINK}, wow\nmy private clipboard text https://other.example/z` }));
        expect(JSON.parse(await seen[0].text())).toEqual({ url: LINK });
    });
    it("logs like POST /: route, key id, the extracted link prefix, never the raw text", async () => {
        await post(JSON.stringify({ url: `secret clipboard words ${LINK} more secret words` }));
        const rows = db.raw.prepare("SELECT route, key_id, url_type, url_prefix, status, result FROM request_log").all();
        expect(rows).toEqual([{ route: "POST /studio", key_id: KEY_ID, url_type: "string", url_prefix: LINK, status: 200, result: "ok" }]);
        expect(JSON.stringify(rows)).not.toContain("secret");
    });
    it("400 error.studio.no_link when no link is found, before the container; the attempt is logged without the text", async () => {
        const res = await post(JSON.stringify({ url: "private clipboard text, no link here" }));
        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.studio.no_link" } });
        expect(seen).toHaveLength(0);
        const row = db.raw.prepare("SELECT route, url_prefix, status, error_code FROM request_log").get();
        expect(row).toEqual({ route: "POST /studio", url_prefix: null, status: 400, error_code: "error.studio.no_link" });
    });
    it("400 no_link for a body with no url or that is not JSON", async () => {
        expect((await post("{}")).status).toBe(400);
        expect((await post("nope")).status).toBe(400);
        expect(seen).toHaveLength(0);
    });
    it("401 without a key, with a bad scheme, with an unknown key; never forwarded", async () => {
        expect((await post(JSON.stringify({ url: LINK }), {})).status).toBe(401);
        expect((await post(JSON.stringify({ url: LINK }), { authorization: "Bearer x" })).status).toBe(401);
        const unknown = await post(JSON.stringify({ url: LINK }), { authorization: "Api-Key 11111111-1111-4111-8111-111111111111" });
        expect(unknown.status).toBe(401);
        expect(await unknown.json()).toEqual({ status: "error", error: { code: "error.api.auth.key.invalid" } });
        expect(seen).toHaveLength(0);
    });
    it("503 when D1 is down, never forwarded", async () => {
        db.breakIt();
        expect((await post(JSON.stringify({ url: LINK }))).status).toBe(503);
        expect(seen).toHaveLength(0);
    });
});

describe("GET /studio/<sid>", () => {
    it("404 error.studio.not_found for an unknown id, never the container", async () => {
        const res = await call(`/studio/${SID}`);
        expect(res.status).toBe(404);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.studio.not_found" } });
        expect(seen).toHaveLength(0);
    });
    it("a ready session: the contract's body, newest successful renders first", async () => {
        seed();
        seedRender("r1", "success", 100, "https://media.capybaraharmony.com/aaaaaaaaaa.webp");
        seedRender("r2", "success", 200, "https://media.capybaraharmony.com/bbbbbbbbbb.webp");
        seedRender("r3", "error", 300);
        seedRender("r4", "pending", 400);
        const res = await call(`/studio/${SID}`);
        expect(res.status).toBe(200);
        expect(res.headers.get("content-type")).toBe("application/json");
        const b = (await res.json()) as any;
        expect(b).toMatchObject({
            status: "ready",
            id: SID,
            link: LINK,
            service: "x",
            title: "x_2105237035271258436",
            duration: 9.6,
            width: 480,
            height: 560,
            bytes: SIZE,
            // save progress is always present: nothing to report once ready
            step: null,
            step_bytes: null,
            step_total: null,
            waking: false,
            created_at: clock.t,
            expires_at: clock.t + SESSION_TTL_MS,
            error: null,
        });
        expect(b.renders.map((r: any) => r.id)).toEqual(["r2", "r1"]);
        expect(b.renders[0]).toEqual({
            id: "r2",
            url: "https://media.capybaraharmony.com/bbbbbbbbbb.webp",
            start: 2,
            length: 5,
            width: 480,
            quality: "med",
            bytes: 1500,
            created_at: 200,
        });
        // no internals leak
        expect(JSON.stringify(b)).not.toMatch(/key_id|r2_key|content_type/);
        expect(seen).toHaveLength(0);
    });
    it("an errored session carries the code (from D1, no forward)", async () => {
        seed({ status: "saving", r2_key: null, content_type: null, bytes: null, duration: null, width: null, height: null, title: null });
        db.raw.prepare("UPDATE studio_sessions SET status='error', error_code='error.api.fetch.fail'").run();
        expect(await (await call(`/studio/${SID}`)).json()).toMatchObject({ status: "error", error: { code: "error.api.fetch.fail" } });
    });
    it("410 error.studio.expired after expires_at (and 200 exactly at it)", async () => {
        seed();
        clock.t += SESSION_TTL_MS;
        expect((await call(`/studio/${SID}`)).status).toBe(200);
        clock.t += 1;
        const res = await call(`/studio/${SID}`);
        expect(res.status).toBe(410);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.studio.expired" } });
    });
    it("503 when D1 is down", async () => {
        seed();
        db.breakIt();
        expect((await call(`/studio/${SID}`)).status).toBe(503);
    });

    describe("a saving session is advanced by the Durable Object", () => {
        const saving = () => seed({ status: "saving", r2_key: null, content_type: null, bytes: null, duration: null, width: null, height: null, title: null });
        const pathOf = (r: Request) => new URL(r.url).pathname + new URL(r.url).search;

        it("forwards to /studio/<sid>/advance with the wait and returns the DO's answer as is", async () => {
            saving();
            const res = await call(`/studio/${SID}?wait=20`);
            expect(await res.json()).toEqual({ status: "ok" });
            expect(seen.map(pathOf)).toEqual([`/studio/${SID}/advance?wait=20`]);
            expect(seen[0].method).toBe("GET");
            expect(seen[0].headers.has("authorization")).toBe(false);
            expect(acao(res)).toBe(ORIGIN);
        });
        it("wait defaults to 0, is capped at 25 and junk is 0", async () => {
            saving();
            await call(`/studio/${SID}`);
            await call(`/studio/${SID}?wait=100`);
            await call(`/studio/${SID}?wait=abc`);
            expect(seen.map(pathOf)).toEqual([
                `/studio/${SID}/advance?wait=0`,
                `/studio/${SID}/advance?wait=25`,
                `/studio/${SID}/advance?wait=0`,
            ]);
        });
        it("the Worker itself never sleeps or polls D1 for it (the DO owns the wait)", async () => {
            saving();
            const t0 = clock.t;
            await call(`/studio/${SID}?wait=20`);
            expect(clock.t).toBe(t0);
        });
        it("passes the DO's 404 / 410 through", async () => {
            saving();
            const notFound = {
                async fetch() {
                    return new Response('{"status":"error","error":{"code":"error.studio.not_found"}}', {
                        status: 404,
                        headers: { "content-type": "application/json" },
                    });
                },
            };
            const res = await handleRequest(new Request(`https://api.capybaraharmony.com/studio/${SID}`), env(), notFound, {
                now: clock.now,
                sleep: clock.sleep,
            });
            expect(res.status).toBe(404);
        });
        it("if the DO cannot answer (throws or 5xx) the page still gets the saving session from D1", async () => {
            saving();
            const down = {
                async fetch(): Promise<Response> {
                    throw new Error("DO down");
                },
            };
            const broken = {
                async fetch() {
                    return new Response("nope", { status: 500 });
                },
            };
            for (const c of [down, broken]) {
                const res = await handleRequest(new Request(`https://api.capybaraharmony.com/studio/${SID}?wait=5`), env(), c, {
                    now: clock.now,
                    sleep: clock.sleep,
                });
                expect(res.status).toBe(200);
                expect(await res.json()).toMatchObject({
                    status: "saving",
                    id: SID,
                    title: null,
                    duration: null,
                    width: null,
                    height: null,
                    bytes: null,
                    // the Worker's own fallback knows no progress: null / false
                    step: null,
                    step_bytes: null,
                    step_total: null,
                    waking: false,
                    renders: [],
                    error: null,
                });
            }
        });
        it("only saving sessions are forwarded: ready, errored and expired ones come from D1", async () => {
            seed();
            expect(((await (await call(`/studio/${SID}?wait=20`)).json()) as any).status).toBe("ready");
            db.raw.prepare("UPDATE studio_sessions SET status='error', error_code='error.api.fetch.fail'").run();
            expect(await (await call(`/studio/${SID}?wait=20`)).json()).toMatchObject({ status: "error", error: { code: "error.api.fetch.fail" } });
            db.raw.prepare("UPDATE studio_sessions SET status='saving'").run();
            clock.t += SESSION_TTL_MS + 1;
            expect((await call(`/studio/${SID}?wait=5`)).status).toBe(410); // expired: not forwarded
            expect((await call(`/studio/${"z".repeat(22)}?wait=5`)).status).toBe(404);
            expect(seen).toHaveLength(0);
        });
        it("the Worker no longer fails old saving sessions itself (the DO measures from the last advance)", async () => {
            saving();
            clock.t += SAVING_STUCK_MS + 1;
            await call(`/studio/${SID}`);
            expect(db.raw.prepare("SELECT status FROM studio_sessions").get()).toEqual({ status: "saving" });
            expect(seen).toHaveLength(1);
        });
        it("the internal advance route is not public: /studio/<sid>/advance is a 404 that never reaches the DO", async () => {
            saving();
            for (const method of ["GET", "POST"]) {
                const res = await call(`/studio/${SID}/advance?wait=5`, { method });
                expect(res.status).toBe(404);
            }
            expect(seen).toHaveLength(0);
        });
    });
});

describe("GET /studio/<sid>/source", () => {
    const bytes = new Uint8Array(SIZE).map((_, i) => i % 251);
    beforeEach(() => {
        seed();
        originals.objects.set(`originals/${SID}.mp4`, { bytes, contentType: "video/mp4", meta: {} });
    });
    const get = (headers: Record<string, string> = {}, method = "GET") => call(`/studio/${SID}/source`, { method, headers });
    const body = async (r: Response) => new Uint8Array(await r.arrayBuffer());

    it("streams the whole video with the contract headers, without touching the container", async () => {
        const res = await get();
        expect(res.status).toBe(200);
        expect(await body(res)).toEqual(bytes);
        expect(res.headers.get("content-type")).toBe("video/mp4");
        expect(res.headers.get("accept-ranges")).toBe("bytes");
        expect(res.headers.get("cache-control")).toBe("private, max-age=3600");
        expect(res.headers.get("content-length")).toBe(String(SIZE));
        expect(res.headers.get("access-control-expose-headers")).toBe("content-range, content-length, accept-ranges");
        expect(res.headers.has("content-range")).toBe(false);
        expect(seen).toHaveLength(0);
        expect(originals.gets[0].range).toBeUndefined();
    });
    it("uses the object's stored content type", async () => {
        db.raw.prepare("UPDATE studio_sessions SET content_type='video/webm'").run();
        expect((await get()).headers.get("content-type")).toBe("video/webm");
    });
    it.each([
        ["bytes=0-", 0, 999],
        ["bytes=0-99", 0, 99],
        ["bytes=100-199", 100, 199],
        ["bytes=900-5000", 900, 999], // end clamped
        ["bytes=999-", 999, 999],
        ["bytes=-100", 900, 999], // suffix
        ["bytes=-5000", 0, 999], // suffix longer than the file
        ["bytes=0-0", 0, 0],
        ["BYTES=10-19", 10, 19],
    ])("Range %s -> 206 %i-%i", async (range, a, b) => {
        const res = await get({ range });
        expect(res.status).toBe(206);
        expect(res.headers.get("content-range")).toBe(`bytes ${a}-${b}/${SIZE}`);
        expect(res.headers.get("content-length")).toBe(String(b - a + 1));
        expect(await body(res)).toEqual(bytes.slice(a, b + 1));
        expect(res.headers.get("accept-ranges")).toBe("bytes");
    });
    it("asks R2 for just the range", async () => {
        await get({ range: "bytes=100-199" });
        expect(originals.gets[0].range).toEqual({ offset: 100, length: 100 });
    });
    it.each(["bytes=1000-", "bytes=5000-6000", "bytes=-0", "bytes=5-2", "bytes=abc", "bytes=-", "bytes=1-2-3", "bytes= -"])(
        "Range %s -> 416 with content-range bytes */size",
        async (range) => {
            const res = await get({ range });
            expect(res.status).toBe(416);
            expect(res.headers.get("content-range")).toBe(`bytes */${SIZE}`);
            expect(await res.json()).toMatchObject({ status: "error", error: { code: "error.studio.bad_range" } });
            expect(originals.gets).toHaveLength(0);
        },
    );
    it("another unit or several ranges are served whole (200)", async () => {
        for (const range of ["items=0-5", "bytes=0-1,5-6"]) {
            const res = await get({ range });
            expect(res.status).toBe(200);
            expect(await body(res)).toEqual(bytes);
        }
    });
    it("HEAD: same headers, no body, no R2 read", async () => {
        const res = await get({}, "HEAD");
        expect(res.status).toBe(200);
        expect(await res.text()).toBe("");
        expect(res.headers.get("content-length")).toBe(String(SIZE));
        expect(res.headers.get("accept-ranges")).toBe("bytes");
        expect(res.headers.get("content-type")).toBe("video/mp4");
        expect(originals.gets).toHaveLength(0);
        const r = await get({ range: "bytes=0-9" }, "HEAD");
        expect(r.status).toBe(206);
        expect(r.headers.get("content-range")).toBe(`bytes 0-9/${SIZE}`);
    });
    it("409 error.studio.not_ready while saving or after an error", async () => {
        db.raw.prepare("UPDATE studio_sessions SET status='saving', r2_key=NULL, bytes=NULL").run();
        const res = await get();
        expect(res.status).toBe(409);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.studio.not_ready" } });
        db.raw.prepare("UPDATE studio_sessions SET status='error', error_code='error.api.fetch.fail'").run();
        expect((await get()).status).toBe(409);
    });
    it("404 unknown, 410 expired", async () => {
        expect((await call(`/studio/${"z".repeat(22)}/source`)).status).toBe(404);
        clock.t += SESSION_TTL_MS + 1;
        const res = await get();
        expect(res.status).toBe(410);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.studio.expired" } });
    });
    it("404 when the object is missing from R2, 502 when R2 fails", async () => {
        originals.objects.clear();
        expect((await get()).status).toBe(404);
        originals.get = async () => {
            throw new Error("R2 down");
        };
        expect((await get()).status).toBe(502);
    });
    it("needs no key and ignores a bad one", async () => {
        expect((await get({ authorization: "Api-Key nope" })).status).toBe(200);
    });
    it("POST and DELETE on /source are 404", async () => {
        expect((await call(`/studio/${SID}/source`, { method: "POST" })).status).toBe(404);
        expect((await call(`/studio/${SID}/source`, { method: "DELETE" })).status).toBe(404);
    });
});

describe("GET /studio/<sid>/source?wait=N (APP-API-CONTRACT section 11)", () => {
    const bytes = new Uint8Array(SIZE).map((_, i) => i % 251);
    const key = `originals/${SID}.mp4`;
    const saving = () => db.raw.prepare("UPDATE studio_sessions SET status='saving', r2_key=NULL, bytes=NULL, content_type=NULL").run();
    const finish = () => {
        db.raw.prepare("UPDATE studio_sessions SET status='ready', r2_key=?, bytes=?, content_type='video/mp4' WHERE status='saving'").run(key, SIZE);
        originals.objects.set(key, { bytes, contentType: "video/mp4", meta: {} });
    };
    const fail = (code = "error.api.fetch.fail") =>
        db.raw.prepare("UPDATE studio_sessions SET status='error', error_code=? WHERE status='saving'").run(code);
    const get = (qs: string, headers: Record<string, string> = {}, method = "GET", c = container) =>
        handleRequest(new Request(`https://api.capybaraharmony.com/studio/${SID}/source${qs}`, { method, headers }), env(), c, {
            now: clock.now,
            sleep: clock.sleep,
        });
    const body = async (r: Response) => new Uint8Array(await r.arrayBuffer());
    const waits = () => seen.map((r) => new URL(r.url)).map((u) => `${u.pathname}${u.search}`);
    // A DO whose advance takes `ms` of (injected) time and runs `onCall(n)` after it.
    const slowDo = (ms: number, onCall: (n: number) => void = () => {}) => {
        let n = 0;
        return {
            async fetch(r: Request) {
                seen.push(r);
                clock.t += ms;
                onCall(++n);
                return new Response('{"status":"ok"}');
            },
        };
    };
    beforeEach(() => seed());

    it("wait=0, absent and junk behave exactly as before: a saving session is an immediate 409, the DO untouched", async () => {
        saving();
        for (const qs of ["", "?wait=0", "?wait=abc", "?wait=", "?wait=-5"]) {
            const t0 = clock.t;
            const res = await get(qs);
            expect(res.status).toBe(409);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.studio.not_ready" } });
            expect(clock.t).toBe(t0);
        }
        expect(seen).toHaveLength(0);
    });
    it("a ready session with wait answers at once, no DO call, no sleep", async () => {
        originals.objects.set(key, { bytes, contentType: "video/mp4", meta: {} });
        const t0 = clock.t;
        const res = await get("?wait=60");
        expect(res.status).toBe(200);
        expect(await body(res)).toEqual(bytes);
        expect(seen).toHaveLength(0);
        expect(clock.t).toBe(t0);
    });
    it("saving, then ready inside the wait: holds, advances the DO, then serves the whole video", async () => {
        saving();
        const c = slowDo(20_000, (n) => n === 2 && finish());
        const res = await get("?wait=60", {}, "GET", c);
        expect(res.status).toBe(200);
        expect(await body(res)).toEqual(bytes);
        expect(res.headers.get("content-length")).toBe(String(SIZE));
        expect(res.headers.get("content-type")).toBe("video/mp4");
        expect(res.headers.get("accept-ranges")).toBe("bytes");
        expect(res.headers.has("content-range")).toBe(false);
        expect(waits()).toEqual([`/studio/${SID}/advance?wait=25`, `/studio/${SID}/advance?wait=25`]);
        expect(acao(res)).toBe(ORIGIN);
    });
    it("each advance asks the DO only for what is left of the wait (capped at 25)", async () => {
        saving();
        const c = slowDo(15_000, (n) => n === 3 && finish());
        expect((await get("?wait=45", {}, "GET", c)).status).toBe(200);
        expect(waits()).toEqual([
            `/studio/${SID}/advance?wait=25`,
            `/studio/${SID}/advance?wait=25`,
            `/studio/${SID}/advance?wait=15`,
        ]);
    });
    it("a DO that answers at once cannot make the hold spin: the Worker sleeps between advances and stops at the deadline", async () => {
        saving();
        const c = slowDo(0);
        const t0 = clock.t;
        const res = await get("?wait=5", {}, "GET", c);
        expect(res.status).toBe(409);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.studio.not_ready" } });
        expect(clock.t - t0).toBe(5_000);
        expect(seen.length).toBeLessThanOrEqual(10);
        expect(seen.length).toBeGreaterThan(1);
    });
    it("a DO that throws is survived: the row is re-read and the hold continues until the deadline", async () => {
        saving();
        let n = 0;
        const c = {
            async fetch(r: Request): Promise<Response> {
                seen.push(r);
                if (++n === 3) finish();
                throw new Error("DO down");
            },
        };
        const res = await get("?wait=30", {}, "GET", c);
        expect(res.status).toBe(200);
        expect(await body(res)).toEqual(bytes);
    });
    it("still saving at the deadline: 409 error.studio.not_ready", async () => {
        saving();
        const res = await get("?wait=30", {}, "GET", slowDo(25_000));
        expect(res.status).toBe(409);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.studio.not_ready" } });
        expect(acao(res)).toBe(ORIGIN);
    });
    it("the save fails during the wait: 422 with the session's error code", async () => {
        saving();
        const c = slowDo(3_000, (n) => n === 1 && fail("error.api.fetch.fail"));
        const res = await get("?wait=60", {}, "GET", c);
        expect(res.status).toBe(422);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.api.fetch.fail" } });
        expect(seen).toHaveLength(1);
    });
    it("an already failed session with wait is the 422 at once; without wait it stays the 409", async () => {
        saving();
        fail("error.api.content.video.unavailable");
        const res = await get("?wait=30");
        expect(res.status).toBe(422);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.api.content.video.unavailable" } });
        expect(seen).toHaveLength(0);
        expect((await get("")).status).toBe(409);
    });
    it("a failed row without a code reports error.api.generic", async () => {
        saving();
        fail(null as unknown as string);
        const res = await get("?wait=10");
        expect(res.status).toBe(422);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.api.generic" } });
    });
    it.each([
        ["bytes=0-99", 0, 99],
        ["bytes=900-", 900, 999],
        ["bytes=-100", 900, 999],
    ])("Range %s is honoured after the wait (206)", async (range, a, b) => {
        saving();
        const c = slowDo(5_000, (n) => n === 1 && finish());
        const res = await get("?wait=60", { range }, "GET", c);
        expect(res.status).toBe(206);
        expect(res.headers.get("content-range")).toBe(`bytes ${a}-${b}/${SIZE}`);
        expect(await body(res)).toEqual(bytes.slice(a, b + 1));
        expect(originals.gets[0].range).toEqual({ offset: a, length: b - a + 1 });
    });
    it("an unsatisfiable Range after the wait is still the 416", async () => {
        saving();
        const c = slowDo(5_000, (n) => n === 1 && finish());
        const res = await get("?wait=60", { range: "bytes=5000-" }, "GET", c);
        expect(res.status).toBe(416);
        expect(res.headers.get("content-range")).toBe(`bytes */${SIZE}`);
    });
    it("wait is clamped to 90 seconds", async () => {
        saving();
        const t0 = clock.t;
        const res = await get("?wait=1000", {}, "GET", slowDo(0));
        expect(res.status).toBe(409);
        expect(clock.t - t0).toBe(90_000);
        expect(waits()[0]).toBe(`/studio/${SID}/advance?wait=25`);
    });
    it("HEAD ignores wait: 409 at once while saving, no DO call", async () => {
        saving();
        const t0 = clock.t;
        const res = await get("?wait=60", {}, "HEAD", slowDo(1_000));
        expect(res.status).toBe(409);
        expect(seen).toHaveLength(0);
        expect(clock.t).toBe(t0);
    });
    it("HEAD with wait on a ready session is the normal HEAD", async () => {
        const res = await get("?wait=60", { range: "bytes=0-9" }, "HEAD");
        expect(res.status).toBe(206);
        expect(res.headers.get("content-range")).toBe(`bytes 0-9/${SIZE}`);
        expect(await res.text()).toBe("");
    });
    it("unknown session: the same 404 as today, with or without wait, and no DO call", async () => {
        const other = "z".repeat(22);
        for (const qs of ["", "?wait=30"]) {
            const res = await handleRequest(new Request(`https://api.capybaraharmony.com/studio/${other}/source${qs}`), env(), slowDo(1_000), {
                now: clock.now,
                sleep: clock.sleep,
            });
            expect(res.status).toBe(404);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.studio.not_found" } });
        }
        expect(seen).toHaveLength(0);
    });
    it("a bad or wrong Api-Key changes nothing: the route has no key, the session id is the credential", async () => {
        saving();
        const c = slowDo(5_000, (n) => n === 1 && finish());
        const res = await get("?wait=60", { authorization: "Api-Key 00000000-0000-4000-8000-000000000000" }, "GET", c);
        expect(res.status).toBe(200);
        expect((await call(`/studio/${"y".repeat(21)}/source?wait=30`, { headers: auth })).status).toBe(404); // malformed id: gate 404
    });
    it("a session that expires during the hold is the 410", async () => {
        saving();
        const c = slowDo(SESSION_TTL_MS + 1);
        const res = await get("?wait=60", {}, "GET", c);
        expect(res.status).toBe(410);
    });
    it("D1 failing during the hold is the 503 as today", async () => {
        saving();
        const c = slowDo(1_000, () => db.breakIt());
        expect((await get("?wait=60", {}, "GET", c)).status).toBe(503);
    });
    it("the container never sees the public query: only the internal advance path", async () => {
        saving();
        await get("?wait=2", {}, "GET", slowDo(0));
        for (const r of seen) {
            const u = new URL(r.url);
            expect(u.host).toBe("do.internal");
            expect(u.pathname).toBe(`/studio/${SID}/advance`);
        }
    });

    describe("ready sessions are cached for range requests", () => {
        it("the second range request skips the session lookup (same bytes, same headers)", async () => {
            originals.objects.set(key, { bytes, contentType: "video/mp4", meta: {} });
            let lookups = 0;
            const realPrepare = db.prepare.bind(db);
            (db as any).prepare = (sql: string) => {
                if (/FROM studio_sessions/.test(sql)) lookups++;
                return realPrepare(sql);
            };
            const a = await get("", { range: "bytes=0-9" });
            const b = await get("", { range: "bytes=10-19" });
            expect(a.status).toBe(206);
            expect(await body(b)).toEqual(bytes.slice(10, 20));
            expect(lookups).toBe(1);
        });
        it("a cached session still turns 410 once it expires", async () => {
            originals.objects.set(key, { bytes, contentType: "video/mp4", meta: {} });
            expect((await get("")).status).toBe(200);
            clock.t += SESSION_TTL_MS + 1;
            expect((await get("")).status).toBe(410);
        });
        it("a saving session is never cached", async () => {
            saving();
            expect((await get("")).status).toBe(409);
            finish();
            expect((await get("")).status).toBe(200);
        });
        it("the cache is dropped after a minute", async () => {
            originals.objects.set(key, { bytes, contentType: "video/mp4", meta: {} });
            expect((await get("")).status).toBe(200);
            db.raw.prepare("DELETE FROM studio_sessions").run();
            expect((await get("")).status).toBe(200); // still cached
            clock.t += 61_000;
            expect((await get("")).status).toBe(404);
        });
    });
});

describe("render routes go to the Durable Object", () => {
    it("POST /studio/<sid>/render: forwarded as is, no key needed, internal headers stripped", async () => {
        const res = await call(`/studio/${SID}/render`, {
            method: "POST",
            headers: { "content-type": "application/json", [KEY_ID_HEADER]: "spoofed", [PORT_HEADER]: "9100" },
            body: '{"start":2,"length":5}',
        });
        expect(res.status).toBe(200);
        expect(seen).toHaveLength(1);
        const r = seen[0];
        expect(r.method).toBe("POST");
        expect(new URL(r.url).pathname).toBe(`/studio/${SID}/render`);
        expect(await r.text()).toBe('{"start":2,"length":5}');
        expect(r.headers.has(KEY_ID_HEADER)).toBe(false);
        expect(r.headers.has(PORT_HEADER)).toBe(false);
    });
    it("GET /studio/<sid>/render/<job>?wait=N keeps the query", async () => {
        await call(`/studio/${SID}/render/${JOB}?wait=20`);
        expect(seen.map((r) => new URL(r.url).pathname + new URL(r.url).search)).toEqual([`/studio/${SID}/render/${JOB}?wait=20`]);
        expect(seen[0].headers.has(KEY_ID_HEADER)).toBe(false);
    });
    it("malformed ids and wrong methods are 404 without waking anything", async () => {
        expect((await call("/studio/short/render", { method: "POST", body: "{}" })).status).toBe(404);
        expect((await call(`/studio/${SID}/render/short`)).status).toBe(404);
        expect((await call(`/studio/${SID}/render`)).status).toBe(404);
        expect(seen).toHaveLength(0);
    });
    it("a missing internal key is still a 503 that never reaches the container", async () => {
        expect((await call(`/studio/${SID}/render/${JOB}`, {}, env({ COBALT_API_KEY: "" }))).status).toBe(503);
        expect(seen).toHaveLength(0);
    });
});

describe("parseRange (pure)", () => {
    it("no header, junk header", () => {
        expect(parseRange(null, 10)).toEqual({ kind: "full" });
        expect(parseRange("", 10)).toEqual({ kind: "full" });
        expect(parseRange("bytes=0-", 0)).toEqual({ kind: "unsatisfiable" });
    });
    it("huge numbers do not overflow", () => {
        expect(parseRange("bytes=99999999999999999999-", 10)).toEqual({ kind: "unsatisfiable" });
        expect(parseRange("bytes=0-99999999999999999999", 10)).toEqual({ kind: "partial", offset: 0, length: 10 });
        expect(parseRange("bytes=-99999999999999999999", 10)).toEqual({ kind: "partial", offset: 0, length: 10 });
    });
});
