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
