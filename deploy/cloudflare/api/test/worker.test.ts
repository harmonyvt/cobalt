import { beforeEach, describe, expect, it } from "vitest";
import { KEY_ID_HEADER, PORT_HEADER } from "../src/headers";
import { hashKey } from "../src/keys";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const ORIGIN = "https://cobalt.capybaraharmony.com";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const KEY_ID = "key-row-1";
const ID = "aB3dE6gH9jK2mN5pQ8sT";
const NAME = "Xy7Zk9Lm2Q.webp";

let db: FakeD1;
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
    ORIGINALS: new MemoryOriginals(),
    MEDIA: new MemoryMedia(),
    MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
    ...over,
});
const call = (url: string, init: RequestInit = {}, e = env()) =>
    handleRequest(new Request(`https://api.capybaraharmony.com${url}`, init), e, container);

beforeEach(async () => {
    db = createFakeD1();
    seen = [];
    db.raw
        .prepare(
            "INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)",
        )
        .run(KEY_ID, "test", await hashKey(CLIENT), "0b5f2c3e", 1);
});

const auth = { authorization: `Api-Key ${CLIENT}` };
const tunnel = () =>
    `/tunnel?id=${"a".repeat(21)}&exp=${Date.now() + 60_000}&sig=${"s".repeat(43)}&sec=${"c".repeat(43)}&iv=${"i".repeat(22)}`;

describe("cf-container-target-port never reaches the container", () => {
    const evil = { [PORT_HEADER]: "9100", "CF-Container-Target-Port": "9100" };
    const cases: [string, string, RequestInit][] = [
        ["GET /", "/", { headers: { origin: ORIGIN, ...evil } }],
        ["OPTIONS /", "/", { method: "OPTIONS", headers: { origin: ORIGIN, ...evil } }],
        ["GET /tunnel", tunnel(), { headers: evil }],
        ["POST /", "/", { method: "POST", headers: { ...auth, ...evil }, body: "{}" }],
        ["POST /webp", "/webp", { method: "POST", headers: { ...auth, ...evil }, body: "{}" }],
        ["GET /webp/:id", `/webp/${ID}`, { headers: { ...auth, ...evil } }],
        ["DELETE /media/:name", `/media/${NAME}`, { method: "DELETE", headers: { ...auth, ...evil } }],
    ];
    it.each(cases)("%s", async (_n, url, init) => {
        const res = await call(url, init);
        expect(res.status).toBe(200);
        expect(seen).toHaveLength(1);
        expect(seen[0].headers.has(PORT_HEADER)).toBe(false);
    });
});

describe("POST / (unchanged behaviour)", () => {
    it("forwards with the internal key swapped in", async () => {
        await call("/", { method: "POST", headers: auth, body: '{"url":"x"}' });
        expect(seen).toHaveLength(1);
        expect(seen[0].headers.get("authorization")).toBe(`Api-Key ${INTERNAL}`);
        expect(await seen[0].text()).toBe('{"url":"x"}');
        expect(seen[0].headers.has(KEY_ID_HEADER)).toBe(false);
    });
    it("401s an unknown key and never forwards", async () => {
        const res = await call("/", {
            method: "POST",
            headers: { authorization: "Api-Key 11111111-1111-4111-8111-111111111111" },
        });
        expect(res.status).toBe(401);
        expect(seen).toHaveLength(0);
    });
    it("503s when D1 is down and never forwards", async () => {
        db.breakIt();
        expect((await call("/", { method: "POST", headers: auth })).status).toBe(503);
        expect(seen).toHaveLength(0);
    });
    it("503s on a missing or malformed internal key without waking the container", async () => {
        expect((await call("/", { method: "POST", headers: auth }, env({ COBALT_API_KEY: "" }))).status).toBe(503);
        expect((await call("/", {}, env({ COBALT_API_KEY: "nope" }))).status).toBe(503);
        expect(seen).toHaveLength(0);
    });
});

describe("/webp and /media", () => {
    it("POST /webp: forwards to the DO with the D1 key id, body intact, client key not passed on", async () => {
        const res = await call("/webp", {
            method: "POST",
            headers: { ...auth, "content-type": "application/json", [KEY_ID_HEADER]: "spoofed" },
            body: '{"url":"https://x.test/v"}',
        });
        expect(res.status).toBe(200);
        expect(seen).toHaveLength(1);
        const r = seen[0];
        expect(new URL(r.url).pathname).toBe("/webp");
        expect(r.method).toBe("POST");
        expect(r.headers.get(KEY_ID_HEADER)).toBe(KEY_ID);
        expect(r.headers.has("authorization")).toBe(false);
        expect(await r.text()).toBe('{"url":"https://x.test/v"}');
    });
    it("GET /webp/:id and DELETE /media/:name carry the key id too", async () => {
        await call(`/webp/${ID}?wait=5`, { headers: auth });
        await call(`/media/${NAME}`, { method: "DELETE", headers: auth });
        expect(seen.map((r) => [r.method, new URL(r.url).pathname + new URL(r.url).search])).toEqual([
            ["GET", `/webp/${ID}?wait=5`],
            ["DELETE", `/media/${NAME}`],
        ]);
        expect(seen.every((r) => r.headers.get(KEY_ID_HEADER) === KEY_ID)).toBe(true);
    });
    it("a spoofed key id without a valid key is a 401 and never forwarded", async () => {
        const res = await call("/webp", {
            method: "POST",
            headers: { [KEY_ID_HEADER]: KEY_ID },
        });
        expect(res.status).toBe(401);
        expect(seen).toHaveLength(0);
        const bad = await call(`/webp/${ID}`, {
            headers: { authorization: "Api-Key 11111111-1111-4111-8111-111111111111", [KEY_ID_HEADER]: KEY_ID },
        });
        expect(bad.status).toBe(401);
        expect(seen).toHaveLength(0);
    });
    it("a client-supplied key id is stripped from requests that are forwarded without a lookup", async () => {
        await call("/", { headers: { origin: ORIGIN, [KEY_ID_HEADER]: KEY_ID } });
        expect(seen[0].headers.has(KEY_ID_HEADER)).toBe(false);
    });
    it("adds the CORS header for the web origin, and only then", async () => {
        const withOrigin = await call("/webp", { method: "POST", headers: { ...auth, origin: ORIGIN } });
        expect(withOrigin.headers.get("access-control-allow-origin")).toBe(ORIGIN);
        const other = await call("/webp", { method: "POST", headers: { ...auth, origin: "https://evil.example" } });
        expect(other.headers.has("access-control-allow-origin")).toBe(false);
        const none = await call(`/webp/${ID}`, { headers: auth });
        expect(none.headers.has("access-control-allow-origin")).toBe(false);
    });
    it("malformed ids and names 404 before any lookup", async () => {
        expect((await call("/webp/short", { headers: auth })).status).toBe(404);
        expect((await call("/media/x.webp", { method: "DELETE", headers: auth })).status).toBe(404);
        expect(seen).toHaveLength(0);
    });
});

describe("the app's routes (capabilities, upload, library)", () => {
    const evil = { [PORT_HEADER]: "9100", [KEY_ID_HEADER]: "victim", "x-cobalt-service": "nope" };
    const ITEM = "Ab3dE6gH9jK2mN5p";

    it("GET /capabilities answers from the Worker: never forwarded, whatever headers it carries", async () => {
        for (const headers of [{}, auth, evil, { ...auth, ...evil }]) {
            const res = await call("/capabilities", { headers });
            expect(res.status).toBe(200);
            expect(((await res.json()) as any).server).toBe("cobalt-cloudflare");
        }
        expect(seen).toHaveLength(0);
    });
    it("key states: missing, invalid (unknown and malformed), valid with its name, unknown when D1 is down", async () => {
        const key = async (headers: Record<string, string>) => ((await (await call("/capabilities", { headers })).json()) as any).key;
        expect(await key({})).toBe("missing");
        expect(await key({ authorization: "Api-Key 11111111-1111-4111-8111-111111111111" })).toBe("invalid");
        expect(await key({ authorization: "Bearer x" })).toBe("invalid");
        expect(await key(auth)).toBe("valid");
        expect(((await (await call("/capabilities", { headers: auth })).json()) as any).key_name).toBe("test");
        db.breakIt();
        expect(await key(auth)).toBe("unknown");
        expect((await call("/capabilities", { headers: auth })).status).toBe(200);
    });
    it("GET /library and the item routes are answered by the Worker (D1 + R2) and never reach the container", async () => {
        for (const [method, p] of [
            ["GET", "/library"],
            ["GET", `/library/items/${ITEM}/file`],
            ["HEAD", `/library/items/${ITEM}/file`],
            ["POST", `/library/items/${ITEM}/publish`],
        ] as const) {
            const res = await call(p, { method, headers: { ...auth, ...evil } });
            expect([200, 404]).toContain(res.status); // an empty library, an unknown item
        }
        expect(seen).toHaveLength(0);
    });
    it("POST /library/items/<id>/studio reaches the Durable Object only for a private video, only on the internal adopt path, with the D1 key id", async () => {
        db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, created_at) VALUES (?, 'private', 'upload', 'originals', ?, 'a.mp4', 'video/mp4', 10, 1)")
            .run(ITEM, `uploads/${ITEM}.mp4`);
        const res = await call(`/library/items/${ITEM}/studio`, { method: "POST", headers: { ...auth, ...evil } });
        expect(res.status).toBe(502); // the fake container answers 200 with no session: not an adopt
        expect(seen).toHaveLength(1);
        expect(new URL(seen[0].url).pathname).toBe("/studio/upload/adopt");
        expect(seen[0].headers.get(KEY_ID_HEADER)).toBe(KEY_ID);
        expect(seen[0].headers.has(PORT_HEADER)).toBe(false);
        expect(seen[0].headers.has("x-cobalt-service")).toBe(false);
        expect(seen[0].headers.has("authorization")).toBe(false);
    });
    it("PUT /studio/upload with spoofed internal headers: the only container call is the adopt, carrying the D1 key id", async () => {
        const res = await call("/studio/upload?name=a.mp4", {
            method: "PUT",
            headers: { ...auth, ...evil, "content-type": "video/mp4", "content-length": "10" },
            body: new Uint8Array(10),
        });
        expect(res.status).toBe(201); // stored; the fake container's adopt answer is not a session: studio_error
        expect(((await res.json()) as any).studio_error).toEqual({ code: "error.api.generic" });
        expect(seen.map((r) => new URL(r.url).pathname)).toEqual(["/studio/upload/adopt"]);
        expect(seen[0].headers.get(KEY_ID_HEADER)).toBe(KEY_ID);
        expect(seen[0].headers.has(PORT_HEADER)).toBe(false);
        expect(seen[0].headers.has("x-cobalt-service")).toBe(false);
    });
    it("the internal adopt path is never reachable from outside", async () => {
        const res = await call("/studio/upload/adopt", { method: "POST", headers: { ...auth, [KEY_ID_HEADER]: KEY_ID }, body: "{}" });
        expect(res.status).toBe(404);
        expect(seen).toHaveLength(0);
    });
});

// ---- Live Activity push (APP-API-CONTRACT.md section 8) ------------------------------------------

describe("the /live routes (Worker side)", () => {
    const RUN = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
    const evil = { [PORT_HEADER]: "9100", [KEY_ID_HEADER]: "victim", "x-cobalt-service": "nope" };
    const logRows = () => (db.raw.prepare("SELECT count(*) AS n FROM request_log").get() as { n: number }).n;
    const routes: [string, string][] = [
        ["PUT", "/live/start-token"],
        ["DELETE", "/live/start-token"],
        ["PUT", `/live/runs/${RUN}`],
        ["DELETE", `/live/runs/${RUN}`],
        ["POST", `/live/runs/${RUN}/state`],
        ["GET", "/live/selftest"],
    ];

    it.each(routes)("%s %s: forwarded to the Durable Object at the same path with the D1 key id and without Authorization", async (method, p) => {
        const body = method === "GET" || method === "DELETE" ? undefined : '{"state":{"stage":"reading"}}';
        const res = await call(p, { method, headers: { ...auth, ...evil, "content-type": "application/json" }, body });
        expect(res.status).toBe(200);
        expect(seen).toHaveLength(1);
        const r = seen[0]!;
        expect(r.method).toBe(method);
        expect(new URL(r.url).pathname).toBe(p);
        expect(r.headers.get(KEY_ID_HEADER)).toBe(KEY_ID); // the spoofed one was replaced
        expect(r.headers.has("authorization")).toBe(false); // the client's key goes no further
        expect(r.headers.has(PORT_HEADER)).toBe(false);
        expect(r.headers.has("x-cobalt-service")).toBe(false);
        if (body) expect(await r.text()).toBe(body); // the body was not consumed on the way
    });

    it("never reaches request_log, whatever the method (a relay can arrive once a second)", async () => {
        for (const [method, p] of routes) {
            const body = method === "GET" || method === "DELETE" ? undefined : "{}";
            await call(p, { method, headers: { ...auth, "content-type": "application/json" }, body });
        }
        expect(seen).toHaveLength(routes.length);
        expect(logRows()).toBe(0);
        // while a plain keyed POST still is logged, so the assertion above means something
        await call("/webp", { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: '{"url":"https://x.test/v"}' });
        expect(logRows()).toBe(1);
    });

    it("the body is never read by the Worker (no describeBody, no link extraction): a body that cannot be cloned still arrives whole", async () => {
        const stream = new ReadableStream({
            start(c) {
                c.enqueue(new TextEncoder().encode('{"state":'));
                c.enqueue(new TextEncoder().encode('{"stage":"ready"}}'));
                c.close();
            },
        });
        const res = await call(`/live/runs/${RUN}/state`, {
            method: "POST",
            headers: { ...auth, "content-type": "application/json" },
            body: stream,
            duplex: "half",
        } as RequestInit);
        expect(res.status).toBe(200);
        expect(await seen[0]!.text()).toBe('{"state":{"stage":"ready"}}');
    });

    it("keyed: no key, a malformed key and an unknown key are a 401 and nothing is forwarded", async () => {
        for (const headers of [{}, { authorization: "Api-Key nope" }, { authorization: "Api-Key 11111111-1111-4111-8111-111111111111" }] as Record<string, string>[]) {
            const res = await call("/live/start-token", { method: "PUT", headers, body: "{}" });
            expect(res.status).toBe(401);
        }
        expect(seen).toHaveLength(0);
    });
    it("D1 down: 503 and nothing is forwarded (fail closed)", async () => {
        db.breakIt();
        expect((await call("/live/selftest", { headers: auth })).status).toBe(503);
        expect(seen).toHaveLength(0);
    });
    it("the library service credential, wrong methods, bad run ids and unknown paths are 404s that never reach the Durable Object", async () => {
        const svc = { "x-cobalt-service": INTERNAL };
        expect((await call("/live/selftest", { headers: svc })).status).toBe(404);
        expect((await call(`/live/runs/${RUN}`, { method: "PUT", headers: { ...svc, ...auth } })).status).toBe(404);
        expect((await call(`/live/runs/${RUN}`, { method: "GET", headers: auth })).status).toBe(404);
        expect((await call("/live/runs/not-a-uuid", { method: "PUT", headers: auth })).status).toBe(404);
        expect((await call("/live/nope", { headers: auth })).status).toBe(404);
        expect((await call("/live", { headers: auth })).status).toBe(404);
        expect(seen).toHaveLength(0);
    });
    it("no CORS header, even for the web origin (the app sends no Origin)", async () => {
        const res = await call("/live/selftest", { headers: { ...auth, origin: ORIGIN } });
        expect(res.headers.has("access-control-allow-origin")).toBe(false);
    });
});

describe("GET /capabilities features.live_activity_push", () => {
    const flag = async (e: WorkerEnv) => ((await (await call("/capabilities", {}, e)).json()) as any).features.live_activity_push;
    const secrets = { APNS_KEY_P8: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----", APNS_KEY_ID: "ABC123DEFG", APNS_TEAM_ID: "TEAM123456" };

    it("false without the secrets (an older deploy, or secrets not set yet)", async () => {
        expect(await flag(env())).toBe(false);
    });
    it("true only with all three secrets non-empty", async () => {
        expect(await flag(env(secrets))).toBe(true);
        expect(await flag(env({ ...secrets, APNS_BUNDLE_ID: "com.example", APNS_VIA: "helper" }))).toBe(true);
        for (const k of Object.keys(secrets) as (keyof typeof secrets)[]) {
            expect(await flag(env({ ...secrets, [k]: undefined }))).toBe(false);
            expect(await flag(env({ ...secrets, [k]: "" }))).toBe(false);
        }
        expect(await flag(env({ APNS_BUNDLE_ID: "com.example", APNS_VIA: "helper" }))).toBe(false);
    });
    it("is a plain boolean, and the answer never contains a secret", async () => {
        const res = await call("/capabilities", {}, env(secrets));
        const text = await res.text();
        expect(JSON.parse(text).features.live_activity_push).toBe(true);
        expect(text).not.toContain("AAAA");
        expect(text).not.toContain("ABC123DEFG");
        expect(text).not.toContain("TEAM123456");
    });
});

// ---- Hark notification bridge (APP-API-CONTRACT.md section 9) ---------------------------------

describe("PUT|DELETE /studio/<sid>/notify (Worker side)", () => {
    const SID = "aB3dE6gH9jK2mN5pQ8sTuV";
    const evil = { [PORT_HEADER]: "9100", [KEY_ID_HEADER]: "victim", "x-cobalt-service": "nope" };
    const logRows = () => (db.raw.prepare("SELECT count(*) AS n FROM request_log").get() as { n: number }).n;
    const body = '{"on":["saved","rendered","failed"],"label":"x · 2105435404002562056"}';

    it.each(["PUT", "DELETE"])("%s: forwarded to the Durable Object at the same path with the D1 key id and without Authorization", async (method) => {
        const res = await call(`/studio/${SID}/notify`, {
            method,
            headers: { ...auth, ...evil, "content-type": "application/json" },
            body: method === "PUT" ? body : undefined,
        });
        expect(res.status).toBe(200);
        expect(seen).toHaveLength(1);
        const r = seen[0]!;
        expect(r.method).toBe(method);
        expect(new URL(r.url).pathname).toBe(`/studio/${SID}/notify`);
        expect(r.headers.get(KEY_ID_HEADER)).toBe(KEY_ID);
        expect(r.headers.has("authorization")).toBe(false);
        expect(r.headers.has(PORT_HEADER)).toBe(false);
        expect(r.headers.has("x-cobalt-service")).toBe(false);
        if (method === "PUT") expect(await r.text()).toBe(body);
    });
    it("never reaches request_log (no body is read by the Worker)", async () => {
        await call(`/studio/${SID}/notify`, { method: "PUT", headers: { ...auth, "content-type": "application/json" }, body });
        await call(`/studio/${SID}/notify`, { method: "DELETE", headers: auth });
        expect(seen).toHaveLength(2);
        expect(logRows()).toBe(0);
    });
    it("keyed: no key, a bad key and an unknown key are a 401 and nothing is forwarded; D1 down fails closed", async () => {
        for (const headers of [{}, { authorization: "Api-Key nope" }, { authorization: "Api-Key 11111111-1111-4111-8111-111111111111" }] as Record<string, string>[]) {
            expect((await call(`/studio/${SID}/notify`, { method: "PUT", headers, body })).status).toBe(401);
        }
        db.breakIt();
        expect((await call(`/studio/${SID}/notify`, { method: "PUT", headers: auth, body })).status).toBe(503);
        expect(seen).toHaveLength(0);
    });
    it("the library service credential, other methods and bad ids are 404s that never reach the Durable Object", async () => {
        const svc = { "x-cobalt-service": INTERNAL };
        expect((await call(`/studio/${SID}/notify`, { method: "PUT", headers: { ...svc, ...auth }, body })).status).toBe(404);
        expect((await call(`/studio/${SID}/notify`, { method: "GET", headers: auth })).status).toBe(404);
        expect((await call(`/studio/${SID}/notify`, { method: "POST", headers: auth, body })).status).toBe(404);
        expect((await call("/studio/short/notify", { method: "PUT", headers: auth, body })).status).toBe(404);
        expect(seen).toHaveLength(0);
    });
    it("carries the studio page's CORS origin like every /studio response", async () => {
        const res = await call(`/studio/${SID}/notify`, { method: "PUT", headers: { ...auth, origin: ORIGIN }, body });
        expect(res.headers.get("access-control-allow-origin")).toBe(ORIGIN);
    });
});

describe("GET /capabilities features.source_wait", () => {
    it("is always true (the hold needs no secret or binding), with or without a key", async () => {
        for (const e of [env(), env({ HARK_WEBHOOK_URL: "" })]) {
            const res = (await (await call("/capabilities", {}, e)).json()) as any;
            expect(res.features.source_wait).toBe(true);
        }
    });
});

describe("GET /capabilities features.delete_post", () => {
    it("is always true (D1 + R2 only, no secret or binding beyond the two buckets), with or without a key", async () => {
        for (const e of [env(), env({ HARK_WEBHOOK_URL: "" })]) {
            const res = (await (await call("/capabilities", {}, e)).json()) as any;
            expect(res.features.delete_post).toBe(true);
        }
    });
});

describe("GET /capabilities features.notify_bridge", () => {
    const flag = async (e: WorkerEnv) => ((await (await call("/capabilities", {}, e)).json()) as any).features.notify_bridge;
    const HOOK = "https://hark.example/api/webhook/T0pS3cretHookToken";

    it("false without the secret, or with it empty, blank, not a URL or not https", async () => {
        expect(await flag(env())).toBe(false);
        for (const v of ["", "   ", "not a url", "http://hark.example/x"]) {
            expect(await flag(env({ HARK_WEBHOOK_URL: v })), v).toBe(false);
        }
    });
    it("true with an https webhook URL, independent of the APNs flag", async () => {
        const res = await (await call("/capabilities", {}, env({ HARK_WEBHOOK_URL: HOOK }))).json();
        expect((res as any).features.notify_bridge).toBe(true);
        expect((res as any).features.live_activity_push).toBe(false);
    });
    it("is a plain boolean, and the answer never contains the secret", async () => {
        const text = await (await call("/capabilities", {}, env({ HARK_WEBHOOK_URL: HOOK }))).text();
        expect(typeof JSON.parse(text).features.notify_bridge).toBe("boolean");
        expect(text).not.toContain("T0pS3cretHookToken");
        expect(text).not.toContain("hark.example");
    });
});
