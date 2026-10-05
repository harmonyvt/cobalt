// The library's API half (LIBRARY-CONTRACT.md): service auth, studio publish,
// library adopt (poll-driven probe), the media_items rows every source writes
// and the soft delete. The Worker, the Durable Object's services and the real
// SQL (node:sqlite on the real migrations) run together; the helper and R2 are
// the fakes from studio-fakes.ts.
import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it } from "vitest";
import { MAX_UPLOAD_BYTES } from "../src/app-routes";
import { decide, type GateRequest } from "../src/gate";
import { KEY_ID_HEADER, PORT_HEADER, SERVICE_HEADER } from "../src/headers";
import { hashKey } from "../src/keys";
import { SERVICE_KEY_ID } from "../src/library";
import { serviceAuthorized } from "../src/service-auth";
import {
    BUSY_WAIT_MS,
    MAX_RENDER_SECONDS,
    MAX_SOURCE_BYTES,
    MIN_RENDER_SECONDS,
    RENDER_FPS,
    RENDER_QUALITIES,
    RENDER_WIDTHS,
    SESSION_TTL_MS,
    UNAVAILABLE_AFTER_MS,
    StudioService,
    handleStudioRoute,
    isStudioRoute,
} from "../src/studio";
import { WebpService, handleWebpRoute, isWebpRoute } from "../src/webp";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { Clock, FakeHelper, MemoryKV, MemoryMedia, MemoryOriginals, fixedLength, fixedLengthPair } from "./studio-fakes";

const ORIGIN = "https://cobalt.capybaraharmony.com";
const MEDIA_BASE = "https://media.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const KEY_ID = "key-row-1";
const SID = "aB3dE6gH9jK2mN5pQ8sTuV";
const LINK = "https://x.com/maria_rcks/status/2105237035271258436";
const ITEM = "Ab3dE6gH9jK2mN5p";
const ADOPT = {
    r2_key: `uploads/${ITEM}.mp4`,
    name: "holiday.mp4",
    content_type: "video/mp4",
    bytes: 4096,
    item_id: ITEM,
};

function world() {
    const db: FakeD1 = createFakeD1();
    const clock = new Clock();
    const kv = new MemoryKV();
    const originals = new MemoryOriginals();
    const media = new MemoryMedia();
    const helper = new FakeHelper();
    const webp = new WebpService({
        storage: kv,
        bucket: media,
        mediaBaseUrl: MEDIA_BASE,
        now: clock.now,
        sleep: clock.sleep,
        ensureRunning: async () => {},
        helper: helper.helper,
        db,
    });
    const make = (over: Partial<ConstructorParameters<typeof StudioService>[0]> = {}) =>
        new StudioService({
            db,
            storage: kv,
            originals,
            webp,
            webBaseUrl: ORIGIN,
            now: clock.now,
            sleep: clock.sleep,
            ensureRunning: async () => {},
            helper: helper.helper,
            fixedLength,
            ...over,
        });
    const studio = make();

    // The Durable Object, as the Worker sees it.
    const seen: Request[] = [];
    const container = {
        async fetch(r: Request) {
            seen.push(r);
            const p = new URL(r.url).pathname;
            if (isStudioRoute(p)) return handleStudioRoute(studio, r);
            if (isWebpRoute(p)) return handleWebpRoute(webp, r);
            return new Response('{"status":"ok"}', { headers: { "content-type": "application/json" } });
        },
    };
    const env: WorkerEnv = {
        API_URL: "https://api.capybaraharmony.com/",
        CORS_URL: ORIGIN,
        COBALT_API_KEY: INTERNAL,
        DB: db,
        ORIGINALS: originals,
        MEDIA: media,
        MEDIA_BASE_URL: MEDIA_BASE,
    };
    const call = (url: string, init: RequestInit = {}, e: WorkerEnv = env) =>
        handleRequest(new Request(`https://api.capybaraharmony.com${url}`, init), e, container, {
            now: clock.now,
            sleep: clock.sleep,
            fixedLength: fixedLengthPair,
        });

    const items = () => db.raw.prepare("SELECT * FROM media_items ORDER BY created_at, id").all() as any[];
    const session = (sid: string) => db.raw.prepare("SELECT * FROM studio_sessions WHERE id = ?").get(sid) as any;
    const seed = (over: Record<string, unknown> = {}, withObject = true) => {
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
            bytes: 4096,
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
        if (withObject && r.r2_key) {
            originals.objects.set(r.r2_key as string, {
                bytes: new Uint8Array((r.bytes as number) ?? 0).fill(7),
                contentType: (r.content_type as string) ?? "video/mp4",
                meta: {},
            });
        }
        return r;
    };
    // D1 refuses writes to media_items only (everything else keeps working).
    const breakItems = () => {
        const orig = db.prepare.bind(db);
        (db as any).prepare = (sql: string) => {
            if (/INSERT INTO media_items|UPDATE media_items/.test(sql)) throw new Error("D1_ERROR: media_items down");
            return orig(sql);
        };
    };
    return { db, clock, kv, originals, media, helper, webp, studio, make, seen, container, env, call, items, session, seed, breakItems };
}
type World = ReturnType<typeof world>;

const jsonBody = (o: unknown) => JSON.stringify(o);
const asBody = (r: { body: unknown }) => r.body as any;
const BASE62_16 = /^[A-Za-z0-9]{16}$/;

const addKey = async (w: World) =>
    w.db.raw
        .prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)")
        .run(KEY_ID, "test", await hashKey(CLIENT), "0b5f2c3e", 1);

const svc = { [SERVICE_HEADER]: INTERNAL };
const auth = { authorization: `Api-Key ${CLIENT}` };

// ---------------------------------------------------------------------------------
describe("service auth: the gate", () => {
    const cfg = { corsUrl: ORIGIN, now: 1_800_000_000_000 };
    const req = (o: Partial<GateRequest>): GateRequest => ({
        method: "GET",
        pathname: "/",
        searchParams: new URLSearchParams(),
        origin: null,
        authorization: null,
        ...o,
    });
    const JOB = "aB3dE6gH9jK2mN5pQ8sT";
    const NAME = "Xy7Zk9Lm2Q.webp";

    it("a service caller is authenticated on every keyed route, with no key", () => {
        const s = (method: string, pathname: string) => decide(req({ method, pathname, service: true }), cfg);
        expect(s("POST", "/")).toEqual({ action: "service" });
        expect(s("POST", "/webp")).toEqual({ action: "service", then: "webp_create" });
        expect(s("GET", `/webp/${JOB}`)).toEqual({ action: "service", then: "webp_status", params: { id: JOB } });
        expect(s("DELETE", `/media/${NAME}`)).toEqual({ action: "service", then: "media_delete", params: { name: NAME } });
        expect(s("POST", "/studio")).toEqual({ action: "service", then: "studio_create" });
        expect(s("POST", `/studio/${SID}/publish`)).toEqual({
            action: "service",
            then: "studio_publish",
            params: { sid: SID },
        });
        expect(s("POST", "/library/adopt")).toEqual({ action: "service", then: "library_adopt" });
    });
    it("without the service credential: publish needs an Api-Key, adopt is refused outright", () => {
        expect(decide(req({ method: "POST", pathname: `/studio/${SID}/publish` }), cfg)).toMatchObject({
            action: "reject",
            status: 401,
            errorCode: "error.api.auth.key.missing",
        });
        expect(decide(req({ method: "POST", pathname: `/studio/${SID}/publish`, authorization: `Api-Key ${CLIENT}` }), cfg)).toEqual({
            action: "lookup",
            key: CLIENT,
            then: "studio_publish",
            params: { sid: SID },
        });
        // an Api-Key client never reaches adopt
        expect(decide(req({ method: "POST", pathname: "/library/adopt", authorization: `Api-Key ${CLIENT}` }), cfg)).toMatchObject({
            action: "reject",
            status: 401,
        });
        expect(decide(req({ method: "POST", pathname: "/library/adopt" }), cfg)).toMatchObject({ status: 401 });
    });
    it("publish and adopt accept POST only; ids are format-checked", () => {
        expect(decide(req({ method: "GET", pathname: `/studio/${SID}/publish`, service: true }), cfg)).toMatchObject({ status: 404 });
        expect(decide(req({ method: "GET", pathname: "/library/adopt", service: true }), cfg)).toMatchObject({ status: 404 });
        expect(decide(req({ method: "POST", pathname: "/studio/short/publish", service: true }), cfg)).toMatchObject({ status: 404 });
        expect(decide(req({ method: "POST", pathname: `/studio/${SID}/publish/x`, service: true }), cfg)).toMatchObject({ status: 404 });
    });
    it("the service flag opens no unrelated route", () => {
        expect(decide(req({ method: "GET", pathname: "/admin", service: true }), cfg)).toMatchObject({ status: 404 });
        expect(decide(req({ method: "GET", pathname: "/tunnel", service: true }), cfg)).toMatchObject({ status: 404 });
    });
});

describe("service auth: the Worker", () => {
    let w: World;
    beforeEach(async () => {
        w = world();
        await addKey(w);
    });

    it("serviceAuthorized: exact match only, constant-time shape", async () => {
        expect(await serviceAuthorized(INTERNAL, INTERNAL)).toBe(true);
        expect(await serviceAuthorized(INTERNAL.slice(0, -1), INTERNAL)).toBe(false);
        expect(await serviceAuthorized(INTERNAL + "x", INTERNAL)).toBe(false);
        expect(await serviceAuthorized(INTERNAL.toUpperCase(), INTERNAL)).toBe(false);
        expect(await serviceAuthorized("", INTERNAL)).toBe(false);
        expect(await serviceAuthorized(null, INTERNAL)).toBe(false);
        expect(await serviceAuthorized(INTERNAL, "")).toBe(false);
        expect(await serviceAuthorized(INTERNAL, undefined)).toBe(false);
    });

    it("accepts the right header: authenticated as service:library, header and Authorization never forwarded", async () => {
        const res = await w.call("/webp", {
            method: "POST",
            headers: { ...svc, "content-type": "application/json" },
            body: jsonBody({ url: "https://x.test/v" }),
        });
        expect(res.status).not.toBe(401);
        const r = w.seen.at(-1)!;
        expect(new URL(r.url).pathname).toBe("/webp");
        expect(r.headers.get(KEY_ID_HEADER)).toBe(SERVICE_KEY_ID);
        expect(r.headers.has(SERVICE_HEADER)).toBe(false);
        expect(r.headers.has("authorization")).toBe(false);
        expect(r.headers.has(PORT_HEADER)).toBe(false);
    });
    it("POST / is forwarded to cobalt with the internal key swapped in, no service header", async () => {
        await w.call("/", { method: "POST", headers: svc, body: '{"url":"x"}' });
        const r = w.seen.at(-1)!;
        expect(r.headers.get("authorization")).toBe(`Api-Key ${INTERNAL}`);
        expect(r.headers.has(SERVICE_HEADER)).toBe(false);
        expect(r.headers.has(KEY_ID_HEADER)).toBe(false);
    });
    it("POST /studio, GET /webp/<id>, DELETE /media/<name> work with the service header too", async () => {
        const created = await w.call("/studio", {
            method: "POST",
            headers: { ...svc, "content-type": "application/json" },
            body: jsonBody({ url: LINK }),
        });
        expect(created.status).toBe(201);
        const sid = ((await created.json()) as any).id;
        expect(w.session(sid).key_id).toBe(SERVICE_KEY_ID);
        const st = await w.call(`/webp/aB3dE6gH9jK2mN5pQ8sT`, { headers: svc });
        expect(st.status).toBe(404); // unknown job, but past the gate
        expect((await w.call("/media/Xy7Zk9Lm2Q.webp", { method: "DELETE", headers: svc })).status).toBe(200);
    });
    it("a wrong, truncated or empty header is ignored as if absent: no key, no entry; with a good Api-Key it is that key", async () => {
        for (const bad of ["nope", INTERNAL.slice(0, 20), INTERNAL + "0", ""]) {
            const headers = { [SERVICE_HEADER]: bad };
            const res = await w.call("/webp", { method: "POST", headers });
            expect(res.status).toBe(401);
            expect((await w.call("/library/adopt", { method: "POST", headers, body: jsonBody(ADOPT) })).status).toBe(401);
            expect((await w.call(`/studio/${SID}/publish`, { method: "POST", headers })).status).toBe(401);
        }
        expect(w.seen).toHaveLength(0);

        await w.call("/webp", { method: "POST", headers: { ...auth, [SERVICE_HEADER]: "nope" }, body: "{}" });
        const r = w.seen.at(-1)!;
        expect(r.headers.get(KEY_ID_HEADER)).toBe(KEY_ID);
        expect(r.headers.has(SERVICE_HEADER)).toBe(false);
    });
    it("a service header that is correct for ANOTHER secret does not authenticate", async () => {
        const other = { ...w.env, COBALT_API_KEY: "11111111-1111-4111-8111-111111111111" };
        expect((await w.call("/webp", { method: "POST", headers: svc }, other)).status).toBe(401);
    });
    it("is stripped from every request that reaches the container, authenticated or not", async () => {
        const evil = { [SERVICE_HEADER]: "whatever", [KEY_ID_HEADER]: "victim" };
        await w.call("/", { headers: { origin: ORIGIN, ...evil } }); // forwarded without a lookup
        await w.call(`/studio/${SID}/render`, { method: "POST", headers: evil, body: "{}" }); // capability route
        await w.call("/library/adopt", { method: "POST", headers: { ...svc, [KEY_ID_HEADER]: "victim" }, body: jsonBody(ADOPT) });
        await w.call("/webp", { method: "POST", headers: { ...auth, ...evil }, body: "{}" });
        expect(w.seen.length).toBeGreaterThanOrEqual(4);
        for (const r of w.seen) expect(r.headers.has(SERVICE_HEADER)).toBe(false);
        // and a client-sent key id never survives: only the Worker's own
        const ids = w.seen.map((r) => r.headers.get(KEY_ID_HEADER));
        expect(ids).toEqual([null, null, SERVICE_KEY_ID, KEY_ID]);
    });
    it("the Durable Object refuses an adopt call that does not carry the service key id", async () => {
        const direct = (headers: Record<string, string>) =>
            handleStudioRoute(
                w.studio,
                new Request("https://do.internal/library/adopt", { method: "POST", headers, body: jsonBody(ADOPT) }),
            );
        expect((await direct({})).status).toBe(403);
        expect((await direct({ [KEY_ID_HEADER]: KEY_ID })).status).toBe(403);
        expect((await direct({ [KEY_ID_HEADER]: SERVICE_KEY_ID })).status).toBe(201);
    });
});

// ---------------------------------------------------------------------------------
describe("POST /studio/<sid>/publish", () => {
    let w: World;
    const publish = (headers: Record<string, string> = svc, sid = SID) =>
        w.call(`/studio/${sid}/publish`, { method: "POST", headers });
    beforeEach(async () => {
        w = world();
        await addKey(w);
    });

    it("copies the original into the public bucket: 201, new 10-char name, bytes, content type, cache control, host row", async () => {
        w.seed();
        const res = await publish();
        expect(res.status).toBe(201);
        const body = (await res.json()) as any;
        expect(body.status).toBe("success");
        expect(body.url).toMatch(/^https:\/\/media\.capybaraharmony\.com\/[A-Za-z0-9]{10}\.mp4$/);
        expect(body.bytes).toBe(4096);
        expect(body.content_type).toBe("video/mp4");
        expect(body.item_id).toMatch(BASE62_16);

        const name = body.url.split("/").pop();
        const obj = w.media.objects.get(name)!;
        expect(obj.data).toEqual(new Uint8Array(4096).fill(7));
        expect(obj.contentType).toBe("video/mp4");
        expect(obj.cacheControl).toBe("public, max-age=31536000, immutable");
        expect(obj.meta).toMatchObject({ keyId: SERVICE_KEY_ID, sessionId: SID, source: LINK });
        // the private original stays where it was
        expect(w.originals.objects.has(`originals/${SID}.mp4`)).toBe(true);

        const rows = w.items();
        expect(rows).toHaveLength(1);
        expect(rows[0]).toMatchObject({
            id: body.item_id,
            kind: "public",
            source: "host",
            bucket: "media",
            r2_key: name,
            url: body.url,
            name: "x_2105237035271258436.mp4",
            content_type: "video/mp4",
            bytes: 4096,
            width: 480,
            height: 560,
            duration: 9.6,
            link: LINK,
            session_id: SID,
            key_id: SERVICE_KEY_ID,
            deleted_at: null,
        });
        // answered by the Worker: the container was never involved
        expect(w.seen).toHaveLength(0);
    });
    it("works with an Api-Key and records that key's id; the media name is new each time", async () => {
        w.seed();
        const a = (await (await publish(auth)).json()) as any;
        const b = (await (await publish(auth)).json()) as any;
        expect(a.url).not.toBe(b.url);
        expect(w.items().map((r) => r.key_id)).toEqual([KEY_ID, KEY_ID]);
    });
    it("copies without pipeTo: the stored object's own body is handed to the public bucket (pipeTo/pipeThrough/tee throw here)", async () => {
        w.seed();
        w.originals.hostileStreams = true;
        const res = await publish();
        expect(res.status).toBe(201);
        const put = w.media.puts.at(-1)!;
        expect(put.value).toBeInstanceOf(ReadableStream);
        expect(w.media.objects.get(put.key)!.viaStream).toBe(true);
        expect(w.media.objects.get(put.key)!.data).toHaveLength(4096);
    });
    it("takes the extension from the stored key (an upload) and does not double it in the display name", async () => {
        w.seed({ id: SID, r2_key: `uploads/${ITEM}.mov`, content_type: "video/quicktime", title: "Clip.MOV", service: "upload", link: `upload:${ITEM}` });
        const body = (await (await publish()).json()) as any;
        expect(body.url).toMatch(/\.mov$/);
        expect(body.content_type).toBe("video/quicktime");
        expect(w.items()[0]).toMatchObject({ name: "Clip.MOV", link: null, content_type: "video/quicktime" });
    });

    it("401 without a key or the service credential, nothing copied", async () => {
        w.seed();
        expect((await publish({})).status).toBe(401);
        expect(w.media.puts).toHaveLength(0);
        expect(w.items()).toHaveLength(0);
    });
    it("409 error.studio.not_ready for a session that is saving or failed", async () => {
        w.seed({ status: "saving", r2_key: null, content_type: null, bytes: null, duration: null, width: null, height: null }, false);
        for (const status of ["saving", "error"]) {
            w.db.raw.prepare("UPDATE studio_sessions SET status = ? WHERE id = ?").run(status, SID);
            const res = await publish();
            expect(res.status).toBe(409);
            expect(((await res.json()) as any).error.code).toBe("error.studio.not_ready");
        }
        expect(w.media.puts).toHaveLength(0);
    });
    it("404 for an unknown session, 410 once it has expired", async () => {
        const res = await publish();
        expect(res.status).toBe(404);
        expect(((await res.json()) as any).error.code).toBe("error.studio.not_found");
        w.seed();
        w.clock.t += SESSION_TTL_MS + 1;
        const gone = await publish();
        expect(gone.status).toBe(410);
        expect(((await gone.json()) as any).error.code).toBe("error.studio.expired");
        expect(w.media.puts).toHaveLength(0);
    });
    it("502 error.studio.storage when the original is missing, unreadable, or the copy fails; no row, no object", async () => {
        w.seed({}, false);
        const missing = await publish();
        expect(missing.status).toBe(502);
        expect(((await missing.json()) as any).error.code).toBe("error.studio.storage");

        w.originals.objects.set(`originals/${SID}.mp4`, { bytes: new Uint8Array(4096), contentType: "video/mp4", meta: {} });
        w.originals.failGet = true;
        expect((await publish()).status).toBe(502);
        w.originals.failGet = false;

        w.media.failPut = true;
        const failed = await publish();
        expect(failed.status).toBe(502);
        expect(((await failed.json()) as any).error.code).toBe("error.studio.storage");
        expect(w.media.objects.size).toBe(0);
        expect(w.items()).toHaveLength(0);
    });
    it("a failing media_items insert does not fail the publish (item_id is null)", async () => {
        w.seed();
        w.breakItems();
        const res = await publish();
        expect(res.status).toBe(201);
        const body = (await res.json()) as any;
        expect(body.item_id).toBeNull();
        expect(w.media.objects.size).toBe(1);
    });
    it("carries the studio CORS origin like every /studio* answer", async () => {
        w.seed();
        expect((await publish()).headers.get("access-control-allow-origin")).toBe(ORIGIN);
        expect((await publish({})).headers.get("access-control-allow-origin")).toBe(ORIGIN);
    });
});

// ---------------------------------------------------------------------------------
describe("POST /library/adopt", () => {
    let w: World;
    const put = (over: Record<string, unknown> = {}) => {
        const r = { ...ADOPT, ...over } as typeof ADOPT;
        w.originals.objects.set(r.r2_key, { bytes: new Uint8Array(r.bytes).fill(5), contentType: r.content_type, meta: {} });
    };
    const adopt = (body: unknown = ADOPT) => w.studio.adopt(SERVICE_KEY_ID, typeof body === "string" ? body : jsonBody(body));
    const sessionRows = () => w.db.raw.prepare("SELECT * FROM studio_sessions").all() as any[];
    beforeEach(async () => {
        w = world();
        await addKey(w);
    });

    describe("validation (nothing is created)", () => {
        const cases: [string, unknown, number, string][] = [
            ["not JSON", "nope", 400, "error.studio.invalid_params"],
            ["a JSON array", [], 400, "error.studio.invalid_params"],
            ["no r2_key", { ...ADOPT, r2_key: undefined }, 400, "error.studio.invalid_params"],
            ["r2_key outside uploads/", { ...ADOPT, r2_key: `originals/${ITEM}.mp4` }, 400, "error.studio.invalid_params"],
            ["r2_key with a path trick", { ...ADOPT, r2_key: "uploads/../originals/x.mp4" }, 400, "error.studio.invalid_params"],
            ["r2_key without extension", { ...ADOPT, r2_key: `uploads/${ITEM}` }, 400, "error.studio.invalid_params"],
            ["empty name", { ...ADOPT, name: "  " }, 400, "error.studio.invalid_params"],
            ["name over 200", { ...ADOPT, name: "x".repeat(201) }, 400, "error.studio.invalid_params"],
            ["no item_id", { ...ADOPT, item_id: undefined }, 400, "error.studio.invalid_params"],
            ["item_id with punctuation", { ...ADOPT, item_id: "a:b" }, 400, "error.studio.invalid_params"],
            ["no content_type", { ...ADOPT, content_type: undefined }, 400, "error.studio.invalid_params"],
            ["image/png", { ...ADOPT, content_type: "image/png" }, 400, "error.studio.not_video"],
            ["image/webp", { ...ADOPT, content_type: "image/webp" }, 400, "error.studio.not_video"],
            ["application/pdf", { ...ADOPT, content_type: "application/pdf" }, 400, "error.studio.not_video"],
            ["video/ with junk", { ...ADOPT, content_type: "video/x y" }, 400, "error.studio.not_video"],
            ["bytes 0", { ...ADOPT, bytes: 0 }, 400, "error.studio.invalid_params"],
            ["bytes as a string", { ...ADOPT, bytes: "4096" }, 400, "error.studio.invalid_params"],
            ["fractional bytes", { ...ADOPT, bytes: 10.5 }, 400, "error.studio.invalid_params"],
            ["bytes over 200 MB", { ...ADOPT, bytes: MAX_SOURCE_BYTES + 1 }, 413, "error.studio.too_large"],
        ];
        it.each(cases)("%s", async (_n, body, status, code) => {
            const r = await adopt(body);
            expect(r.status).toBe(status);
            expect(asBody(r).error.code).toBe(code);
            expect(sessionRows()).toHaveLength(0);
            expect(w.kv.m.size).toBe(0);
        });
    });

    it("201 with a studio URL; the row is saving, points at the upload, and the helper is not called yet", async () => {
        put();
        const r = await adopt();
        expect(r.status).toBe(201);
        const sid = asBody(r).id as string;
        expect(sid).toMatch(/^[A-Za-z0-9]{22}$/);
        expect(asBody(r).url).toBe(`${ORIGIN}/studio/${sid}`);
        expect(w.session(sid)).toMatchObject({
            status: "saving",
            link: `upload:${ITEM}`,
            service: "upload",
            title: "holiday.mp4",
            r2_key: ADOPT.r2_key,
            content_type: "video/mp4",
            bytes: 4096,
            key_id: SERVICE_KEY_ID,
            duration: null,
            width: null,
            height: null,
        });
        expect(w.session(sid).expires_at - w.session(sid).created_at).toBe(SESSION_TTL_MS);
        expect(w.helper.calls).toEqual([]); // nothing runs after the response
        expect((w.kv.m.get(`save:${sid}`) as any).phase).toBe("probing");
        expect(w.items()).toHaveLength(0);
    });
    it("accepts a gif and other video types", async () => {
        for (const ct of ["image/gif", "video/quicktime", "video/webm", "VIDEO/MP4"]) {
            w.kv.m.clear();
            expect((await adopt({ ...ADOPT, content_type: ct })).status).toBe(201);
        }
    });
    it("429 error.studio.busy while a save is running", async () => {
        w.kv.m.set("save:other", { phase: "fetching", startedAt: w.clock.t, attempts: 1, lastAdvance: w.clock.t });
        const r = await adopt();
        expect(r.status).toBe(429);
        expect(asBody(r).error.code).toBe("error.studio.busy");
    });

    describe("the probe is poll-driven", () => {
        it("a poll streams the stored object into the helper and the session turns ready with its measures", async () => {
            put();
            const sid = asBody(await adopt()).id;
            expect(w.session(sid).status).toBe("saving");

            const polled = await w.studio.advance(sid, 0);
            expect(polled.status).toBe(200);
            expect(asBody(polled)).toMatchObject({
                status: "ready",
                id: sid,
                link: `upload:${ITEM}`,
                title: "holiday.mp4",
                duration: 4.2,
                width: 640,
                height: 360,
                bytes: 4096,
                error: null,
                renders: [],
            });
            // exactly one helper call: the probe, with the whole object streamed in; no cobalt fetch
            expect(w.helper.calls).toEqual(["POST /probe"]);
            expect(w.helper.probedBytes).toEqual([4096]);
            expect(w.kv.m.has(`save:${sid}`)).toBe(false);
            // the upload's own item is not duplicated as a 'saved' item
            expect(w.items()).toHaveLength(0);
            expect(w.session(sid)).toMatchObject({ status: "ready", duration: 4.2, width: 640, height: 360 });
        });
        it("the Worker's GET /studio/<sid> advances it (through the Durable Object) and then answers from D1", async () => {
            put();
            const created = await w.call("/library/adopt", { method: "POST", headers: svc, body: jsonBody(ADOPT) });
            expect(created.status).toBe(201);
            const sid = ((await created.json()) as any).id;
            const first = await w.call(`/studio/${sid}?wait=0`);
            expect(((await first.json()) as any).status).toBe("ready");
            expect(w.seen.map((r) => new URL(r.url).pathname)).toEqual(["/library/adopt", `/studio/${sid}/advance`]);
            const second = await w.call(`/studio/${sid}`);
            expect(((await second.json()) as any).status).toBe("ready");
            expect(w.seen).toHaveLength(2); // a ready session no longer touches the container
            // and the stored copy streams like any saved one
            const src = await w.call(`/studio/${sid}/source`);
            expect(src.status).toBe(200);
            expect(src.headers.get("content-length")).toBe("4096");
        });
        it("a gif without a duration is ready with duration null", async () => {
            put({ r2_key: "uploads/GifGifGifGifGifG.gif", content_type: "image/gif" });
            w.helper.probeResult = { duration: null, width: 200, height: 100 };
            const sid = asBody(await adopt({ ...ADOPT, r2_key: "uploads/GifGifGifGifGifG.gif", content_type: "image/gif" })).id;
            expect(asBody(await w.studio.advance(sid, 0))).toMatchObject({ status: "ready", duration: null, width: 200, height: 100 });
        });
        it("a ready adopted session renders exactly like a saved one", async () => {
            put();
            const sid = asBody(await adopt()).id;
            await w.studio.advance(sid, 0);
            const r = await w.studio.render(sid, jsonBody({ start: 0, length: 3 }));
            expect(r.status).toBe(202);
            expect(w.helper.calls.at(-1)).toBe("POST /jobs/upload");
            const done = await w.studio.renderStatus(sid, asBody(r).job, 5);
            expect(asBody(done).status).toBe("success");
            // a studio render of an upload carries no page link
            expect(w.items()).toHaveLength(1);
            expect(w.items()[0]).toMatchObject({ source: "studio", session_id: sid, link: null, name: "holiday.webp" });
        });
        it("a busy helper is retried, not failed: still saving, then ready on a later poll", async () => {
            put();
            w.helper.probeBusy = 1;
            const sid = asBody(await adopt()).id;
            expect(asBody(await w.studio.advance(sid, 0)).status).toBe("saving");
            expect(w.session(sid).status).toBe("saving");
            expect(asBody(await w.studio.advance(sid, 0)).status).toBe("ready");
            expect(w.helper.probedBytes).toEqual([4096]);
        });
        it("a helper busy for longer than BUSY_WAIT_MS ends as error.studio.busy (the upload stays)", async () => {
            put();
            w.helper.probeBusy = 1000;
            const sid = asBody(await adopt()).id;
            await w.studio.advance(sid, 0);
            w.clock.t += BUSY_WAIT_MS + 1;
            const r = await w.studio.advance(sid, 0);
            expect(asBody(r)).toMatchObject({ status: "error", error: { code: "error.studio.busy" } });
            expect(w.originals.objects.has(ADOPT.r2_key)).toBe(true);
        });
        it("a lost save record still probes (never fetches the upload: link)", async () => {
            put();
            const sid = asBody(await adopt()).id;
            w.kv.m.clear();
            expect(asBody(await w.studio.advance(sid, 0)).status).toBe("ready");
            expect(w.helper.calls).toEqual(["POST /probe"]);
        });
    });

    describe("probe failures end the session; the uploaded object is never touched", () => {
        const fails = async (code: string) => {
            put();
            const sid = asBody(await adopt()).id;
            const r = await w.studio.advance(sid, 0);
            expect(asBody(r)).toMatchObject({ status: "error", error: { code } });
            expect(w.session(sid)).toMatchObject({ status: "error", error_code: code });
            expect(w.kv.m.has(`save:${sid}`)).toBe(false);
            expect(w.originals.objects.has(ADOPT.r2_key)).toBe(true);
            expect(w.items()).toHaveLength(0);
            return sid;
        };
        it("the helper says not a video (400)", async () => {
            w.helper.probeError = { status: 400, code: "error.studio.not_video" };
            await fails("error.studio.not_video");
        });
        it("the helper says too large (413)", async () => {
            w.helper.probeError = { status: 413, code: "error.studio.too_large" };
            await fails("error.studio.too_large");
        });
        it("the helper answers without a video size", async () => {
            w.helper.probeResult = { duration: 3, width: null, height: null };
            await fails("error.studio.not_video");
        });
        it("the object is gone from storage", async () => {
            const sid = asBody(await adopt()).id; // nothing put
            expect(asBody(await w.studio.advance(sid, 0))).toMatchObject({ status: "error", error: { code: "error.studio.storage" } });
        });
        it("storage cannot be read", async () => {
            put();
            w.originals.failGet = true;
            const sid = asBody(await adopt()).id;
            expect(asBody(await w.studio.advance(sid, 0))).toMatchObject({ status: "error", error: { code: "error.studio.storage" } });
        });
        it("a helper that stays unreachable for 30 s is error.studio.unavailable", async () => {
            put();
            w.helper.unreachable = true;
            const sid = asBody(await adopt()).id;
            expect(asBody(await w.studio.advance(sid, 0)).status).toBe("saving");
            w.clock.t += UNAVAILABLE_AFTER_MS + 1;
            expect(asBody(await w.studio.advance(sid, 0))).toMatchObject({ status: "error", error: { code: "error.studio.unavailable" } });
        });
    });
    it("a probe call that hangs is cut off by our own timeout, and the next poll succeeds", async () => {
        put();
        const studio = w.make({ probeTimeoutMs: 20 });
        w.helper.probeHang = true;
        const sid = asBody(await studio.adopt(SERVICE_KEY_ID, jsonBody(ADOPT))).id;
        expect(asBody(await studio.advance(sid, 0)).status).toBe("saving");
        w.helper.probeHang = false;
        expect(asBody(await studio.advance(sid, 0)).status).toBe("ready");
    });
});

// ---------------------------------------------------------------------------------
describe("media_items: every source", () => {
    let w: World;
    beforeEach(async () => {
        w = world();
        await addKey(w);
    });

    describe("webp: every successful POST /webp job", () => {
        const start = async (keyId = KEY_ID) => {
            const r = await w.webp.createFromUpload(
                keyId,
                { url: LINK, start: 0, length: 3, width: 480, fps: 15, quality: "med" },
                async () => ({ body: new Blob([new Uint8Array(100)]).stream() as ReadableStream, size: 100 }),
            );
            return (r.body as any).id as string;
        };
        it("one public row per job, with the job's key id and the source link", async () => {
            const id = await start();
            const r = await w.webp.status(KEY_ID, id, 5);
            expect(r.status).toBe(200);
            const url = (r.body as any).url as string;
            const rows = w.items();
            expect(rows).toHaveLength(1);
            expect(rows[0]).toMatchObject({
                kind: "public",
                source: "webp",
                bucket: "media",
                r2_key: url.split("/").pop(),
                url,
                content_type: "image/webp",
                bytes: 1500,
                width: 480,
                height: 560,
                duration: 5,
                link: LINK,
                session_id: null,
                key_id: KEY_ID,
                deleted_at: null,
            });
            expect(rows[0].id).toMatch(BASE62_16);
            expect(rows[0].name).toMatch(/\.webp$/);
        });
        it("polling a finished job again does not add a second row", async () => {
            const id = await start();
            await w.webp.status(KEY_ID, id, 5);
            await w.webp.status(KEY_ID, id, 5);
            expect(w.items()).toHaveLength(1);
        });
        it("a failed job writes nothing", async () => {
            w.helper.jobError = "error.webp.encode_failed";
            const id = await start();
            expect((await w.webp.status(KEY_ID, id, 5)).body).toMatchObject({ status: "error" });
            expect(w.items()).toHaveLength(0);
        });
        it("a studio render's WebP is recorded once, as 'studio', not as 'webp'", async () => {
            const id = await start(`studio:${SID}`);
            await w.webp.status(`studio:${SID}`, id, 5);
            expect(w.items()).toHaveLength(0);
        });
        it("a failing insert does not fail the job", async () => {
            const id = await start();
            w.breakItems();
            const r = await w.webp.status(KEY_ID, id, 5);
            expect(r.status).toBe(200);
            expect(r.body).toMatchObject({ status: "success" });
            expect(w.media.objects.size).toBe(1);
        });
    });

    describe("studio: every successful render", () => {
        const renderOnce = async () => {
            const r = await w.studio.render(SID, jsonBody({ start: 2, length: 5 }));
            return asBody(r).job as string;
        };
        it("one public row per collected render, tied to its session", async () => {
            w.seed();
            const job = await renderOnce();
            const done = await w.studio.renderStatus(SID, job, 5);
            expect(asBody(done).status).toBe("success");
            const rows = w.items();
            expect(rows).toHaveLength(1);
            expect(rows[0]).toMatchObject({
                kind: "public",
                source: "studio",
                bucket: "media",
                url: asBody(done).url,
                r2_key: asBody(done).url.split("/").pop(),
                name: "x_2105237035271258436.webp",
                content_type: "image/webp",
                bytes: 1500,
                width: 480,
                height: 560,
                duration: 5,
                link: LINK,
                session_id: SID,
                key_id: KEY_ID,
            });
            // collected again (the page polls): still one row
            await w.studio.renderStatus(SID, job, 5);
            expect(w.items()).toHaveLength(1);
        });
        it("two renders, two rows; an errored render adds none", async () => {
            w.seed();
            const a = await renderOnce();
            await w.studio.renderStatus(SID, a, 5);
            const b = await renderOnce();
            await w.studio.renderStatus(SID, b, 5);
            w.helper.jobError = "error.webp.encode_failed";
            const c = await renderOnce();
            expect(asBody(await w.studio.renderStatus(SID, c, 5))).toMatchObject({ status: "error" });
            expect(w.items()).toHaveLength(2);
        });
        it("a failing insert does not fail the render", async () => {
            w.seed();
            const job = await renderOnce();
            w.breakItems();
            expect(asBody(await w.studio.renderStatus(SID, job, 5)).status).toBe("success");
            expect(w.db.raw.prepare("SELECT status FROM studio_renders WHERE id = ?").get(job)).toEqual({ status: "success" });
        });
    });

    describe("saved: a studio save that becomes ready", () => {
        it("the stored private original becomes one private row", async () => {
            const sid = asBody(await w.studio.create(KEY_ID, jsonBody({ url: LINK }))).id as string;
            const r = await w.studio.advance(sid, 10);
            expect(asBody(r).status).toBe("ready");
            const rows = w.items();
            expect(rows).toHaveLength(1);
            expect(rows[0]).toMatchObject({
                kind: "private",
                source: "saved",
                bucket: "originals",
                r2_key: `originals/${sid}.mp4`,
                url: null,
                name: "x_2105237035271258436",
                content_type: "video/mp4",
                bytes: 4096,
                width: 480,
                height: 560,
                duration: 9.6,
                link: LINK,
                session_id: sid,
                key_id: KEY_ID,
                deleted_at: null,
            });
            await w.studio.advance(sid, 0);
            expect(w.items()).toHaveLength(1);
        });
        it("a save that fails writes nothing", async () => {
            w.helper.fetchError = "error.api.fetch.fail";
            const sid = asBody(await w.studio.create(KEY_ID, jsonBody({ url: LINK }))).id as string;
            await w.studio.advance(sid, 10);
            expect(w.items()).toHaveLength(0);
        });
        it("a failing insert does not fail the save", async () => {
            w.breakItems();
            const sid = asBody(await w.studio.create(KEY_ID, jsonBody({ url: LINK }))).id as string;
            expect(asBody(await w.studio.advance(sid, 10)).status).toBe("ready");
            expect(w.originals.objects.has(`originals/${sid}.mp4`)).toBe(true);
        });
    });

    it("host: see POST /studio/<sid>/publish above (one 'host' row per publish)", async () => {
        w.seed();
        await w.call(`/studio/${SID}/publish`, { method: "POST", headers: svc });
        expect(w.items().map((r) => [r.source, r.kind, r.bucket])).toEqual([["host", "public", "media"]]);
    });

    it("the same stored object is never listed twice (bucket + key)", async () => {
        const { insertMediaItem } = await import("../src/library");
        const base = { kind: "private" as const, source: "saved" as const, bucket: "originals" as const, r2_key: "originals/a.mp4", name: "a", created_at: 1 };
        expect(await insertMediaItem(w.db, base)).toMatch(BASE62_16);
        expect(await insertMediaItem(w.db, base)).toBeNull();
        expect(await insertMediaItem(w.db, { ...base, bucket: "media" })).toMatch(BASE62_16);
        expect(w.items()).toHaveLength(2);
        expect(await insertMediaItem(undefined, base)).toBeNull();
    });
});

// ---------------------------------------------------------------------------------
describe("DELETE /media/<name> soft-deletes the library row", () => {
    let w: World;
    const NAME = "Xy7Zk9Lm2Q.webp";
    const row = (id: string, bucket: string, key: string, deleted: number | null = null) =>
        w.db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, name, created_at, deleted_at) VALUES (?,?,?,?,?,?,?,?)")
            .run(id, "public", "webp", bucket, key, key, 1, deleted);
    const deletedAt = (id: string) => (w.db.raw.prepare("SELECT deleted_at FROM media_items WHERE id = ?").get(id) as any).deleted_at;
    beforeEach(async () => {
        w = world();
        await addKey(w);
    });

    it("sets deleted_at on the matching live row, removes the object, leaves other rows alone", async () => {
        w.media.objects.set(NAME, { bytes: 1, meta: {}, data: new Uint8Array(1), viaStream: false });
        row("item-a", "media", NAME);
        row("item-b", "media", "Other12345.webp");
        row("item-c", "originals", NAME); // same key, other bucket: untouched
        const res = await w.call(`/media/${NAME}`, { method: "DELETE", headers: auth });
        expect(res.status).toBe(200);
        expect(await res.json()).toEqual({ status: "success" });
        expect(w.media.objects.has(NAME)).toBe(false);
        expect(deletedAt("item-a")).toBe(w.clock.t);
        expect(deletedAt("item-b")).toBeNull();
        expect(deletedAt("item-c")).toBeNull();
    });
    it("does not move deleted_at of a row that is already deleted; a file without a row is fine", async () => {
        row("item-a", "media", NAME, 123);
        await w.call(`/media/${NAME}`, { method: "DELETE", headers: auth });
        expect(deletedAt("item-a")).toBe(123);
        const none = await w.call("/media/Zz9Zz9Zz9Z.webp", { method: "DELETE", headers: svc });
        expect(none.status).toBe(200);
    });
    it("a failing D1 update does not fail the delete", async () => {
        row("item-a", "media", NAME);
        w.breakItems();
        const res = await w.call(`/media/${NAME}`, { method: "DELETE", headers: auth });
        expect(res.status).toBe(200);
        expect(deletedAt("item-a")).toBeNull();
    });
});

// =================================================================================
// The app's routes (APP-API-CONTRACT.md): capabilities, upload with a key, and the
// library with a key. The Worker, the Durable Object's services and the real SQL
// run together; R2 and the helper are the fakes.
// =================================================================================

const API_PACKAGE_VERSION = (
    JSON.parse(readFileSync(new URL("../../../../api/package.json", import.meta.url), "utf8")) as { version: string }
).version;

describe("GET /capabilities", () => {
    let w: World;
    const caps = (headers: Record<string, string> = {}, e?: WorkerEnv) => w.call("/capabilities", { headers }, e);
    beforeEach(async () => {
        w = world();
        await addKey(w);
    });

    it("with no key: 200, the fork marker, the features and the limits taken from the code that enforces them", async () => {
        const res = await caps();
        expect(res.status).toBe(200);
        expect(res.headers.get("content-type")).toBe("application/json");
        expect(res.headers.get("cache-control")).toBe("no-store");
        expect(await res.json()).toEqual({
            status: "success",
            server: "cobalt-cloudflare",
            cobalt: { version: API_PACKAGE_VERSION },
            features: {
                studio: true,
                upload: true,
                library: true,
                save_progress: true,
                render_progress: true,
                finishes_unpolled: true,
                live_activity_push: false,
                notify_bridge: false,
                crop: true,
                source_wait: true,
                delete_post: true,
                telemetry: true,
                poster: true,
                public_default: true,
                create_notify: true,
            },
            limits: {
                max_webp_seconds: 10,
                min_webp_seconds: 0.5,
                webp_widths: [320, 480],
                webp_qualities: ["low", "med", "high"],
                render_fps: 15,
                max_upload_bytes: 100000000,
                max_source_bytes: 209715200,
                session_ttl_ms: 604800000,
            },
            media_base_url: "https://media.capybaraharmony.com/",
            key: "missing",
            key_name: null,
        });
    });
    it("cobalt.version is upstream's api/package.json version, read at bundle time", async () => {
        expect(API_PACKAGE_VERSION).toMatch(/^\d+\.\d+/);
        expect(((await (await caps()).json()) as any).cobalt).toEqual({ version: API_PACKAGE_VERSION });
    });
    it("the limits are the enforced constants, not retyped numbers", async () => {
        const b = (await (await caps()).json()) as any;
        expect(b.limits).toEqual({
            max_webp_seconds: MAX_RENDER_SECONDS,
            min_webp_seconds: MIN_RENDER_SECONDS,
            webp_widths: [...RENDER_WIDTHS],
            webp_qualities: [...RENDER_QUALITIES],
            render_fps: RENDER_FPS,
            max_upload_bytes: MAX_UPLOAD_BYTES,
            max_source_bytes: MAX_SOURCE_BYTES,
            session_ttl_ms: SESSION_TTL_MS,
        });
    });
    it("a valid key: key valid with its name, and the use is stamped like on any keyed call", async () => {
        const b = (await (await caps(auth)).json()) as any;
        expect(b).toMatchObject({ key: "valid", key_name: "test" });
        expect((w.db.raw.prepare("SELECT last_used_at FROM api_keys WHERE id = ?").get(KEY_ID) as any).last_used_at).toBe(w.clock.t);
    });
    it("a well-formed key that is unknown or revoked: invalid, still a 200 (never a 401)", async () => {
        const unknown = await caps({ authorization: "Api-Key 11111111-1111-4111-8111-111111111111" });
        expect(unknown.status).toBe(200);
        expect(await unknown.json()).toMatchObject({ key: "invalid", key_name: null });
        w.db.raw.prepare("UPDATE api_keys SET revoked_at = 5 WHERE id = ?").run(KEY_ID);
        const revoked = await caps(auth);
        expect(revoked.status).toBe(200);
        expect(await revoked.json()).toMatchObject({ key: "invalid", key_name: null });
    });
    it("a malformed header: invalid, and D1 is not asked", async () => {
        w.db.breakIt();
        for (const authorization of ["Bearer abc", "Api-Key nope", ""]) {
            const res = await caps({ authorization });
            expect(res.status).toBe(200);
            expect(await res.json()).toMatchObject({ key: "invalid", key_name: null });
        }
    });
    it("D1 failing on the lookup: unknown (the app keeps its last answer), not an error and not a 'valid'", async () => {
        w.db.breakIt();
        const res = await caps(auth);
        expect(res.status).toBe(200);
        expect(await res.json()).toMatchObject({ status: "success", server: "cobalt-cloudflare", key: "unknown", key_name: null });
    });
    it("D1 failing only on the name lookup: the key is still valid, just unnamed", async () => {
        const orig = w.db.prepare.bind(w.db);
        (w.db as any).prepare = (sql: string) => {
            if (/SELECT name FROM api_keys/.test(sql)) throw new Error("D1_ERROR");
            return orig(sql);
        };
        expect(await (await caps(auth)).json()).toMatchObject({ key: "valid", key_name: null });
    });
    it("the library service credential: valid, named service", async () => {
        expect(await (await caps(svc)).json()).toMatchObject({ key: "valid", key_name: "service" });
    });
    it("a wrong service header counts as no credential at all", async () => {
        expect(await (await caps({ [SERVICE_HEADER]: "nope" })).json()).toMatchObject({ key: "missing" });
    });
    it("never wakes the container, and answers from the Worker even with a stripped-down environment", async () => {
        await caps();
        await caps(auth);
        await caps({ ...auth, [KEY_ID_HEADER]: "victim", [PORT_HEADER]: "9100", [SERVICE_HEADER]: "x" });
        expect(w.seen).toHaveLength(0);
    });
    it("a missing internal key is the Worker's generic 503 (misconfiguration), like every route", async () => {
        expect((await caps({}, { ...w.env, COBALT_API_KEY: "" })).status).toBe(503);
    });
    it("a trailing slash is added to the media base URL when the binding lacks one", async () => {
        const res = await caps({}, { ...w.env, MEDIA_BASE_URL: "https://media.test" });
        expect(((await res.json()) as any).media_base_url).toBe("https://media.test/");
    });
    it("only GET; the request log is not written", async () => {
        for (const method of ["POST", "PUT", "DELETE", "HEAD"]) {
            expect((await w.call("/capabilities", { method, headers: auth })).status).toBe(404);
        }
        await caps(auth);
        expect(w.db.raw.prepare("SELECT count(*) AS n FROM request_log").get()).toEqual({ n: 0 });
    });
});

// ---------------------------------------------------------------------------------
describe("PUT /studio/upload", () => {
    let w: World;
    const bytesOf = (n: number, fill = 1) => new Uint8Array(n).fill(fill);
    const put = (
        data: Uint8Array,
        type: string | null,
        name: string | null = "IMG_0412.mov",
        headers: Record<string, string> = auth,
        o: { length?: string | null } = {},
    ) => {
        const h: Record<string, string> = { ...headers };
        if (type) h["content-type"] = type;
        if (o.length !== null) h["content-length"] = o.length ?? String(data.byteLength);
        return w.call(`/studio/upload${name === null ? "" : `?name=${encodeURIComponent(name)}`}`, {
            method: "PUT",
            headers: h,
            body: data as unknown as BodyInit,
        });
    };
    // A body that records how often it is pulled and whether it is cancelled.
    // It never ends: code that tried to read a refused upload would pull
    // without bound. (Node's own Request constructor pipes a request's body
    // through an identity transform when the Worker re-wraps the request to
    // strip headers, which pulls it once or twice by itself; the Workers
    // runtime does not. That is the only reading there is.)
    const spy = (n = 10) => {
        const state = { pulls: 0, cancelled: false };
        const stream = new ReadableStream<Uint8Array>(
            {
                pull(c) {
                    state.pulls++;
                    c.enqueue(new Uint8Array(n));
                    if (state.pulls >= 1000) c.close(); // long enough to notice, short enough to end
                },
                cancel() {
                    state.cancelled = true;
                },
            },
            { highWaterMark: 0 },
        );
        return { stream, state };
    };
    const NOT_READ = 2;
    const putStream = (stream: ReadableStream, headers: Record<string, string>, name = "x.mp4") =>
        w.call(`/studio/upload?name=${name}`, { method: "PUT", headers, body: stream, duplex: "half" } as RequestInit);
    const logRows = () => w.db.raw.prepare("SELECT * FROM request_log ORDER BY id").all() as any[];
    const noTraces = () => {
        expect(w.items()).toHaveLength(0);
        expect(w.originals.objects.size).toBe(0);
        expect(w.db.raw.prepare("SELECT count(*) AS n FROM studio_sessions").get()).toEqual({ n: 0 });
    };
    beforeEach(async () => {
        w = world();
        await addKey(w);
    });

    describe("a video", () => {
        it("201: stored in R2 as a stream, a private upload item with the caller's key id, and a studio session through the internal adopt path", async () => {
            const data = bytesOf(4096, 9);
            const res = await put(data, "video/quicktime", "IMG_0412.mov");
            expect(res.status).toBe(201);
            const b = (await res.json()) as any;
            expect(b.status).toBe("success");
            expect(b.id).toMatch(/^[A-Za-z0-9]{22}$/);
            expect(b.url).toBe(`${ORIGIN}/studio/${b.id}`);
            expect(b.studio_error).toBeNull();

            // item: the web's itemShape, no r2_key leaked
            expect(b.item).toEqual({
                id: expect.stringMatching(BASE62_16),
                kind: "private",
                source: "upload",
                name: "IMG_0412.mov",
                url: null,
                content_type: "video/quicktime",
                bytes: 4096,
                width: null,
                height: null,
                duration: null,
                link: null,
                session_id: null,
                created_at: w.clock.t,
                poster_url: null,
            });
            // no `public` flag: today's behaviour, the answer only carries the two idle fields
            expect(b.public_state).toBeNull();
            expect(b.public_url).toBeNull();
            const key = `uploads/${b.item.id}.mov`;
            expect(w.originals.putValueTypes).toEqual(["ReadableStream"]); // streamed, never buffered
            expect(w.originals.objects.get(key)!.bytes).toEqual(data);
            expect(w.originals.objects.get(key)!.contentType).toBe("video/quicktime");
            expect(w.items()).toHaveLength(1);
            expect(w.items()[0]).toMatchObject({
                id: b.item.id,
                kind: "private",
                source: "upload",
                bucket: "originals",
                r2_key: key,
                url: null,
                key_id: KEY_ID,
                created_at: w.clock.t,
                deleted_at: null,
            });

            // the session: the same adopt a library "open in studio" makes
            expect(w.session(b.id)).toMatchObject({
                status: "saving",
                key_id: KEY_ID,
                link: `upload:${b.item.id}`,
                service: "upload",
                title: "IMG_0412.mov",
                r2_key: key,
                content_type: "video/quicktime",
                bytes: 4096,
            });
            expect(w.seen).toHaveLength(1);
            const call = w.seen[0]!;
            expect(new URL(call.url).pathname).toBe("/studio/upload/adopt");
            expect(call.method).toBe("POST");
            expect(call.headers.get(KEY_ID_HEADER)).toBe(KEY_ID);
            expect(call.headers.has("authorization")).toBe(false);
        });
        it("the returned id polls exactly like a pasted link's session: saving, then ready with its size", async () => {
            const b = (await (await put(bytesOf(4096), "video/mp4", "clip.mp4")).json()) as any;
            const first = (await (await w.call(`/studio/${b.id}?wait=0`)).json()) as any;
            expect(first).toMatchObject({ status: "ready", id: b.id, title: "clip.mp4", width: 640, height: 360, duration: 4.2, step: null, waking: false });
            expect(w.items()).toHaveLength(1); // the adopted upload is not duplicated as a 'saved' item
        });
        it.each([
            ["video/mp4", "mp4"],
            ["video/quicktime", "mov"],
            ["image/gif", "gif"],
        ])("%s is adopted into a session (stored as .%s)", async (type, ext) => {
            const b = (await (await put(bytesOf(200), type, `f.${ext}`)).json()) as any;
            expect(b.id).toMatch(/^[A-Za-z0-9]{22}$/);
            expect(w.items()[0]!.r2_key).toMatch(new RegExp(`^uploads/[A-Za-z0-9]{16}\\.${ext}$`));
            expect(w.session(b.id)).toMatchObject({ content_type: type });
        });
        it("content-type parameters and case do not matter", async () => {
            expect((await put(bytesOf(10), "Video/MP4; codecs=avc1")).status).toBe(201);
        });
        it("a refused adopt (the helper is busy with a save): still 201, the file is stored, id null, studio_error carries the code", async () => {
            await w.call("/studio", { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: jsonBody({ url: LINK }) });
            w.seen.length = 0;
            const res = await put(bytesOf(500), "video/mp4", "late.mp4");
            expect(res.status).toBe(201);
            const b = (await res.json()) as any;
            expect(b).toMatchObject({ status: "success", id: null, url: null, studio_error: { code: "error.studio.busy" } });
            expect(b.item).toMatchObject({ name: "late.mp4", kind: "private", source: "upload", bytes: 500 });
            expect(w.originals.objects.has(`uploads/${b.item.id}.mp4`)).toBe(true);
            expect(w.items()).toHaveLength(1);
            // the app retries with POST /library/items/<id>/studio once the helper is free
            await w.studio.advance(
                (w.db.raw.prepare("SELECT id FROM studio_sessions").get() as any).id,
                30,
            );
            const retry = await w.call(`/library/items/${b.item.id}/studio`, { method: "POST", headers: auth });
            expect(retry.status).toBe(201);
        });
        it("a Durable Object that cannot be reached: 201 with studio_error error.api.generic (never loses the upload)", async () => {
            const broken = { fetch: async () => Promise.reject(new Error("do down")) };
            const res = await handleRequest(
                new Request("https://api.capybaraharmony.com/studio/upload?name=a.mp4", {
                    method: "PUT",
                    headers: { ...auth, "content-type": "video/mp4", "content-length": "20" },
                    body: bytesOf(20) as unknown as BodyInit,
                }),
                w.env,
                broken,
                { now: w.clock.now, sleep: w.clock.sleep, fixedLength: fixedLengthPair },
            );
            expect(res.status).toBe(201);
            expect(await res.json()).toMatchObject({ id: null, url: null, studio_error: { code: "error.api.generic" } });
            expect(w.items()).toHaveLength(1);
        });
        it("a Durable Object answering with something that is not JSON is the same generic studio_error", async () => {
            const garbage = { fetch: async () => new Response("<html>1101</html>", { status: 500 }) };
            const res = await handleRequest(
                new Request("https://api.capybaraharmony.com/studio/upload?name=a.mp4", {
                    method: "PUT",
                    headers: { ...auth, "content-type": "video/mp4", "content-length": "20" },
                    body: bytesOf(20) as unknown as BodyInit,
                }),
                w.env,
                garbage,
                { now: w.clock.now, sleep: w.clock.sleep, fixedLength: fixedLengthPair },
            );
            expect(res.status).toBe(201);
            expect(await res.json()).toMatchObject({ id: null, studio_error: { code: "error.api.generic" } });
        });
    });

    describe("an image", () => {
        it.each([
            ["image/png", "png"],
            ["image/jpeg", "jpg"],
            ["image/webp", "webp"],
            ["image/heic", "heic"],
        ])("%s: stored as .%s, id null, url null, studio_error null, and the container is never touched", async (type, ext) => {
            const res = await put(bytesOf(300, 4), type, `photo.${ext}`);
            expect(res.status).toBe(201);
            const b = (await res.json()) as any;
            expect(b).toMatchObject({ status: "success", id: null, url: null, studio_error: null });
            expect(b.item).toMatchObject({ kind: "private", source: "upload", name: `photo.${ext}`, content_type: type, bytes: 300, session_id: null });
            expect(w.originals.objects.has(`uploads/${b.item.id}.${ext}`)).toBe(true);
            expect(w.items()[0]).toMatchObject({ key_id: KEY_ID, bucket: "originals" });
            expect(w.seen).toHaveLength(0);
            expect(w.db.raw.prepare("SELECT count(*) AS n FROM studio_sessions").get()).toEqual({ n: 0 });
        });
        it("the app hosts it as it is with POST /library/items/<id>/publish (route 5c)", async () => {
            const b = (await (await put(bytesOf(300, 4), "image/png", "photo.png")).json()) as any;
            const pub = await w.call(`/library/items/${b.item.id}/publish`, { method: "POST", headers: auth });
            expect(pub.status).toBe(201);
            expect(((await pub.json()) as any).url).toMatch(/^https:\/\/media\.capybaraharmony\.com\/[A-Za-z0-9]{10}\.png$/);
        });
    });

    describe("the caller", () => {
        it("the service credential uploads as service:library", async () => {
            const b = (await (await put(bytesOf(100), "image/png", "a.png", svc)).json()) as any;
            expect(w.items()[0]).toMatchObject({ key_id: SERVICE_KEY_ID });
            expect(b.item.id).toMatch(BASE62_16);
        });
        it("a client-sent key id, service header and port header change nothing: the row carries the real key's id", async () => {
            const res = await put(bytesOf(100), "video/mp4", "a.mp4", { ...auth, [KEY_ID_HEADER]: "victim", [PORT_HEADER]: "9100", [SERVICE_HEADER]: "nope" });
            expect(res.status).toBe(201);
            expect(w.items()[0]).toMatchObject({ key_id: KEY_ID });
            expect(w.seen.map((r) => r.headers.get(KEY_ID_HEADER))).toEqual([KEY_ID]);
            for (const r of w.seen) {
                expect(r.headers.has(PORT_HEADER)).toBe(false);
                expect(r.headers.has(SERVICE_HEADER)).toBe(false);
            }
        });
        it("the studio CORS header rides along on /studio/* (harmless: the app sends no Origin)", async () => {
            const res = await put(bytesOf(10), "image/png");
            expect(res.headers.get("access-control-allow-origin")).toBe(ORIGIN);
        });
    });

    describe("auth failures store nothing and read no body", () => {
        it.each([
            ["no key", {}, "error.api.auth.key.missing"],
            ["a Bearer header", { authorization: "Bearer abc" }, "error.api.auth.key.not_api_key"],
            ["a malformed key", { authorization: "Api-Key nope" }, "error.api.auth.key.invalid"],
            ["an unknown key", { authorization: "Api-Key 11111111-1111-4111-8111-111111111111" }, "error.api.auth.key.invalid"],
        ])("%s: 401", async (_n, headers, code) => {
            const s = spy();
            const res = await putStream(s.stream, { ...headers, "content-type": "video/mp4", "content-length": "10" });
            expect(res.status).toBe(401);
            expect(await res.json()).toEqual({ status: "error", error: { code } });
            expect(s.state.pulls).toBeLessThanOrEqual(NOT_READ);
            noTraces();
            expect(w.seen).toHaveLength(0);
        });
        it("a revoked key is 401", async () => {
            w.db.raw.prepare("UPDATE api_keys SET revoked_at = 5 WHERE id = ?").run(KEY_ID);
            expect((await put(bytesOf(10), "image/png")).status).toBe(401);
            noTraces();
        });
        it("a wrong service header with no key is 401", async () => {
            expect((await put(bytesOf(10), "image/png", "a.png", { [SERVICE_HEADER]: "nope" })).status).toBe(401);
        });
        it("D1 down at the key lookup: 503 and nothing stored", async () => {
            w.db.breakIt();
            const res = await put(bytesOf(10), "image/png");
            expect(res.status).toBe(503);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.api.generic" } });
            expect(w.originals.objects.size).toBe(0);
        });
        it("GET, POST and DELETE on /studio/upload are 404, with or without a key", async () => {
            for (const method of ["GET", "POST", "DELETE"]) {
                expect((await w.call("/studio/upload", { method, headers: auth })).status).toBe(404);
                expect((await w.call("/studio/upload", { method })).status).toBe(404);
            }
            expect(w.seen).toHaveLength(0);
        });
        it("the internal adopt path is a 404 from outside, for every credential, and reaches nothing", async () => {
            for (const headers of [{}, auth, svc, { ...auth, [KEY_ID_HEADER]: KEY_ID }]) {
                for (const method of ["POST", "PUT", "GET"]) {
                    const res = await w.call("/studio/upload/adopt", { method, headers, body: method === "GET" ? undefined : jsonBody(ADOPT) });
                    expect(res.status).toBe(404);
                }
            }
            expect(w.seen).toHaveLength(0);
            expect(w.db.raw.prepare("SELECT count(*) AS n FROM studio_sessions").get()).toEqual({ n: 0 });
        });
        it("the Durable Object itself refuses the internal adopt without the Worker's key id header", async () => {
            const direct = (headers: Record<string, string>) =>
                handleStudioRoute(
                    w.studio,
                    new Request("https://do.internal/studio/upload/adopt", { method: "POST", headers, body: jsonBody(ADOPT) }),
                );
            expect((await direct({})).status).toBe(403);
            expect((await direct({ [KEY_ID_HEADER]: KEY_ID })).status).toBe(201);
        });
    });

    describe("limits and bad requests are refused before the body is read (and it is cancelled)", () => {
        const refused = async (headers: Record<string, string>, status: number, code: string) => {
            const s = spy();
            const res = await putStream(s.stream, { ...auth, ...headers });
            expect(res.status).toBe(status);
            expect(await res.json()).toEqual({ status: "error", error: { code } });
            expect(s.state.pulls).toBeLessThanOrEqual(NOT_READ);
            expect(s.state.cancelled).toBe(true);
            noTraces();
            expect(w.seen).toHaveLength(0);
        };
        it("415 for an unsupported or missing content type", async () => {
            await refused({ "content-type": "text/plain", "content-length": "10" }, 415, "error.library.unsupported");
            await refused({ "content-type": "application/octet-stream", "content-length": "10" }, 415, "error.library.unsupported");
            await refused({ "content-type": "image/svg+xml", "content-length": "10" }, 415, "error.library.unsupported");
            await refused({ "content-type": "video/webm", "content-length": "10" }, 415, "error.library.unsupported");
            await refused({ "content-length": "10" }, 415, "error.library.unsupported");
        });
        it("411 without a numeric content-length", async () => {
            const s = spy();
            const res = await putStream(s.stream, { ...auth, "content-type": "video/mp4" });
            expect(res.status).toBe(411);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.length_required" } });
            expect(s.state.pulls).toBeLessThanOrEqual(NOT_READ);
            for (const len of ["abc", "-5", "1e6", "10.5", "", "0x10"]) {
                await refused({ "content-type": "video/mp4", "content-length": len }, 411, "error.library.length_required");
            }
        });
        it("413 over 100 000 000 bytes (101 MB), checked on the header alone", async () => {
            await refused({ "content-type": "video/mp4", "content-length": "100000001" }, 413, "error.library.too_large");
            await refused({ "content-type": "video/mp4", "content-length": "101000000" }, 413, "error.library.too_large");
            await refused({ "content-type": "image/png", "content-length": "999999999999" }, 413, "error.library.too_large");
        });
        it("exactly 100 000 000 is not too large (it passes the limit; this body is short, so it is 'incomplete')", async () => {
            const res = await put(bytesOf(10), "video/mp4", "a.mp4", auth, { length: "100000000" });
            expect(res.status).toBe(400);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.incomplete" } });
            noTraces();
        });
        it("a 100 000 000-byte body is accepted and streamed in full", async () => {
            const total = MAX_UPLOAD_BYTES;
            const chunk = new Uint8Array(1_000_000).fill(1);
            let sent = 0;
            const stream = new ReadableStream<Uint8Array>({
                pull(c) {
                    if (sent >= total) return c.close();
                    c.enqueue(chunk);
                    sent += chunk.length;
                },
            });
            const res = await putStream(stream, { ...auth, "content-type": "image/png", "content-length": String(total) }, "big.png");
            expect(res.status).toBe(201);
            expect(((await res.json()) as any).item.bytes).toBe(total);
        });
        it("400 for an empty body (content-length 0)", async () => {
            await refused({ "content-type": "image/png", "content-length": "0" }, 400, "error.library.empty");
        });
        it("a body shorter than its content-length is 400 incomplete, the object is removed and no row is made", async () => {
            const res = await put(bytesOf(5), "image/png", "a.png", auth, { length: "10" });
            expect(res.status).toBe(400);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.incomplete" } });
            noTraces();
        });
        it("the content-length is the contract's check order: type, then length, then size", async () => {
            // unsupported type AND too large: the type is reported first
            await refused({ "content-type": "text/plain", "content-length": "999999999" }, 415, "error.library.unsupported");
        });
    });

    describe("the name", () => {
        const nameOf = async (name: string | null) =>
            ((await (await put(bytesOf(10), "image/png", name)).json()) as any).item.name as string;
        it("is kept as given", async () => {
            expect(await nameOf("IMG_0412.png")).toBe("IMG_0412.png");
            expect(await nameOf("日本語 の ファイル.png")).toBe("日本語 の ファイル.png");
        });
        it("falls back to upload.<ext> when it is missing, blank or only dots", async () => {
            expect(await nameOf(null)).toBe("upload.png");
            expect(await nameOf("   ")).toBe("upload.png");
            expect(await nameOf(".")).toBe("upload.png");
            expect(await nameOf("..")).toBe("upload.png");
        });
        it("loses any path and control characters", async () => {
            expect(await nameOf("../../etc/passwd")).toBe("passwd");
            expect(await nameOf("C:\\Users\\me\\a.png")).toBe("a.png");
            expect(await nameOf("a\u0000b\u001f\u007fc.png")).toBe("abc.png");
            expect(await nameOf("a\nb\r\n.png")).toBe("ab.png");
            expect(await nameOf("/")).toBe("upload.png");
        });
        it("is cut to 120 characters (by character, not by byte)", async () => {
            expect(await nameOf("x".repeat(300))).toBe("x".repeat(120));
            expect(Array.from(await nameOf("日".repeat(300)))).toHaveLength(120);
        });
        it("is never the R2 key: the key is uploads/<16 base62>.<ext> whatever the name says", async () => {
            const b = (await (await put(bytesOf(10), "image/png", "../../originals/evil.png")).json()) as any;
            expect(w.items()[0]!.r2_key).toBe(`uploads/${b.item.id}.png`);
        });
    });

    describe("storage failures", () => {
        it("R2 failing the put: 502 error.library.storage, no row, no session", async () => {
            w.originals.failPut = true;
            const res = await put(bytesOf(10), "video/mp4");
            expect(res.status).toBe(502);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.storage" } });
            noTraces();
            expect(w.seen).toHaveLength(0);
        });
        it("D1 failing the insert: 503 error.api.generic and the object is removed again", async () => {
            w.breakItems();
            const res = await put(bytesOf(10), "image/png");
            expect(res.status).toBe(503);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.api.generic" } });
            expect(w.originals.objects.size).toBe(0);
            expect(w.seen).toHaveLength(0);
        });
        it("the row was inserted but reading it back failed: the object is KEPT (no row without a file), the upload still succeeds without an item (finding 6)", async () => {
            const orig = w.db.prepare.bind(w.db);
            (w.db as any).prepare = (sql: string) => {
                if (/^SELECT .* FROM media_items WHERE id = \?1/.test(sql)) throw new Error("D1_ERROR: read down");
                return orig(sql);
            };
            const res = await put(bytesOf(4096), "video/mp4", "clip.mp4");
            expect(res.status).toBe(201);
            const b = (await res.json()) as any;
            expect(b.item).toBeNull();
            // the row and its file both exist
            expect(w.items()).toHaveLength(1);
            expect(w.originals.objects.has(w.items()[0].r2_key)).toBe(true);
            // and the video still continued into a studio session
            expect(b.id).toMatch(/^[A-Za-z0-9]{22}$/);
        });
    });

    describe("the request log never holds a body", () => {
        it("one row with route PUT /studio/upload: the sizes, the type and the caller, and nothing of the content", async () => {
            const marker = new TextEncoder().encode("TOP-SECRET-BODY-MARKER https://secret.example/clip");
            const data = new Uint8Array(2048);
            data.set(marker, 100);
            const res = await put(data, "video/mp4", "clip.mp4", { ...auth, "user-agent": "cobalt-app/1.0" });
            expect(res.status).toBe(201);
            const rows = logRows();
            expect(rows).toHaveLength(1);
            expect(rows[0]).toMatchObject({
                route: "PUT /studio/upload",
                key_id: KEY_ID,
                user_agent: "cobalt-app/1.0",
                content_type: "video/mp4",
                body_bytes: 2048,
                body_keys: "",
                url_type: "upload",
                url_len: null,
                url_prefix: null,
                status: 201,
                result: "success",
                error_code: null,
            });
            expect(JSON.stringify(rows)).not.toContain("TOP-SECRET");
            expect(JSON.stringify(rows)).not.toContain("secret.example");
        });
        it("a refused upload is logged too, with its error code, and the body was never read", async () => {
            const s = spy();
            await putStream(s.stream, { ...auth, "content-type": "video/mp4", "content-length": "100000001" });
            expect(s.state.pulls).toBeLessThanOrEqual(NOT_READ);
            expect(logRows()).toEqual([expect.objectContaining({ route: "PUT /studio/upload", body_bytes: 100000001, status: 413, result: "error", error_code: "error.library.too_large" })]);
        });
        it("an unauthenticated upload is not logged (no key to attribute it to)", async () => {
            await put(bytesOf(10), "image/png", "a.png", {});
            expect(logRows()).toHaveLength(0);
        });
        it("the library routes make no request_log rows", async () => {
            await w.call("/library", { headers: auth });
            expect(logRows()).toHaveLength(0);
        });
    });
});

// ---------------------------------------------------------------------------------
describe("GET /library (grouped into posts)", () => {
    let w: World;
    const T = 1_800_000_000_000;
    const S2 = "AdoptSess0000000000000a"; // 22 chars
    const S3 = "OldSession00000000000bb"; // 22 chars
    const U = "UploadItem000001"; // 16 chars
    const L2 = "https://www.instagram.com/reel/Dd7P496wolG/";
    const API = "https://api.capybaraharmony.com";
    const MEDIA_URL = "https://media.capybaraharmony.com";

    let n = 0;
    const item = (over: Record<string, unknown>) => {
        const r: Record<string, unknown> = {
            id: `Item${String(++n).padStart(12, "0")}`,
            kind: "public",
            source: "webp",
            bucket: "media",
            r2_key: `Key${String(n).padStart(7, "0")}.webp`,
            url: null,
            name: "n",
            content_type: "image/webp",
            bytes: 100,
            width: null,
            height: null,
            duration: null,
            link: null,
            session_id: null,
            key_id: null,
            created_at: T,
            deleted_at: null,
            ...over,
        };
        if (r.kind === "public" && r.url === null) r.url = `${MEDIA_URL}/${r.r2_key}`;
        w.db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at) VALUES (@id,@kind,@source,@bucket,@r2_key,@url,@name,@content_type,@bytes,@width,@height,@duration,@link,@session_id,@key_id,@created_at,@deleted_at)",
            )
            .run(r as any);
        return r as any;
    };
    const sess = (over: Record<string, unknown>) =>
        w.seed({ expires_at: T + SESSION_TTL_MS, created_at: T, ...over }, false);
    const list = async (q = "", headers: Record<string, string> = auth) => w.call(`/library${q}`, { headers });
    const body = async (q = "") => {
        const res = await list(q);
        expect(res.status).toBe(200);
        return (await res.json()) as any;
    };
    const ids = (b: any) => b.posts.map((p: any) => p.id);
    beforeEach(async () => {
        w = world();
        w.clock.t = T + 10_000; // "now": later than every fixture
        await addKey(w);
        n = 0;
    });

    // Post A: a saved link, the webp rendered from it and a hosted copy of the video: ONE post
    const seedPostA = () => {
        sess({ id: SID, link: LINK, service: "x", title: "x_2105237035271258436" });
        const saved = item({ id: "SavedItem0000001", kind: "private", source: "saved", bucket: "originals", r2_key: `originals/${SID}.mp4`, name: "x_2105237035271258436", content_type: "video/mp4", bytes: 4331778, width: 720, height: 1280, duration: 14.77, link: LINK, session_id: SID, created_at: T + 1000 });
        const host = item({ id: "HostItem00000001", source: "host", r2_key: "Klmnopqrst.mp4", name: "x_2105237035271258436.mp4", content_type: "video/mp4", bytes: 4331778, width: 720, height: 1280, duration: 14.77, link: LINK, session_id: SID, created_at: T + 2000 });
        const render = item({ id: "RenderItem000001", source: "studio", r2_key: "Abcdefghij.webp", name: "x_2105237035271258436.webp", bytes: 4500000, width: 480, height: 854, duration: 10.1, link: LINK, session_id: SID, created_at: T + 3000 });
        return { saved, host, render };
    };

    it("saved + render + host of one session are ONE post, files newest first, with the post's own facts", async () => {
        seedPostA();
        const b = await body();
        expect(b.status).toBe("success");
        expect(b.posts).toHaveLength(1);
        const p = b.posts[0];
        expect(p).toMatchObject({
            id: SID,
            service: "x",
            link: LINK,
            title: "x_2105237035271258436",
            duration: 14.77,
            width: 720,
            height: 1280,
            created_at: T + 3000,
            session: { id: SID, status: "ready", expires_at: T + SESSION_TTL_MS, source_url: `${API}/studio/${SID}/source` },
        });
        expect(p.files.map((f: any) => f.id)).toEqual(["RenderItem000001", "HostItem00000001", "SavedItem0000001"]);
        expect(p.files[0]).toEqual({
            id: "RenderItem000001",
            kind: "public",
            source: "studio",
            name: "x_2105237035271258436.webp",
            url: `${MEDIA_URL}/Abcdefghij.webp`,
            content_type: "image/webp",
            bytes: 4500000,
            width: 480,
            height: 854,
            duration: 10.1,
            created_at: T + 3000,
            media_name: "Abcdefghij.webp",
            deletable: true,
            poster_url: null,
        });
        expect(p.files[2]).toEqual({
            id: "SavedItem0000001",
            kind: "private",
            source: "saved",
            name: "x_2105237035271258436",
            url: null,
            content_type: "video/mp4",
            bytes: 4331778,
            width: 720,
            height: 1280,
            duration: 14.77,
            created_at: T + 1000,
            media_name: null,
            deletable: false,
            poster_url: null,
        });
        expect(b.counts).toEqual({ posts: 1, files: 3 });
        expect(b.next).toBeNull();
    });

    it("deletable is exactly what DELETE /media/<name> accepts: only public .webp with a 10-char name; hosted mp4s and private files are not", async () => {
        seedPostA();
        item({ source: "webp", r2_key: "Short1.webp", link: LINK, session_id: SID }); // not the 10-char shape
        item({ source: "webp", r2_key: "Abcdefgh12.WEBP", link: LINK, session_id: SID });
        const files = (await body()).posts[0].files as any[];
        const byName = Object.fromEntries(files.map((f) => [f.media_name ?? f.name, f.deletable]));
        expect(byName["Abcdefghij.webp"]).toBe(true);
        expect(byName["Klmnopqrst.mp4"]).toBe(false);
        expect(byName["Short1.webp"]).toBe(false);
        expect(byName["Abcdefgh12.WEBP"]).toBe(false);
        expect(byName["x_2105237035271258436"]).toBe(false);
        // and the claim holds against the real route
        for (const f of files.filter((f) => f.deletable)) {
            w.media.objects.set(f.media_name, { bytes: 1, meta: {}, data: new Uint8Array(1), viaStream: false });
            expect((await w.call(`/media/${f.media_name}`, { method: "DELETE", headers: auth })).status).toBe(200);
        }
    });

    it("a /webp job (no session) is its own post, keyed by its link; two jobs of one link share it", async () => {
        item({ id: "WebpItem00000001", r2_key: "Uvwxyz0123.webp", link: L2, name: "instagram_Dd7P496wolG.webp", width: 480, height: 854, duration: 9.5, created_at: T + 500 });
        item({ id: "WebpItem00000002", r2_key: "Abcdef0123.webp", link: L2, name: "instagram_Dd7P496wolG.webp", width: 320, height: 570, duration: 8, created_at: T + 600 });
        const b = await body();
        expect(b.posts).toHaveLength(1);
        expect(b.posts[0]).toMatchObject({
            id: L2,
            service: "instagram",
            link: L2,
            title: "instagram_Dd7P496wolG.webp",
            // no private original: the newest video-ish file speaks for the post
            duration: 8,
            width: 320,
            height: 570,
            created_at: T + 600,
            session: null,
        });
        expect(b.posts[0].files.map((f: any) => f.id)).toEqual(["WebpItem00000002", "WebpItem00000001"]);
        expect(b.counts).toEqual({ posts: 1, files: 2 });
    });

    it("an upload and the webps made from its adopted session are ONE post (keyed by the upload's item id)", async () => {
        item({ id: U, kind: "private", source: "upload", bucket: "originals", r2_key: `uploads/${U}.mov`, name: "IMG_0412.mov", content_type: "video/quicktime", bytes: 18234112, width: 1080, height: 1920, duration: 6.2, created_at: T + 100 });
        sess({ id: S2, link: `upload:${U}`, service: "upload", title: "IMG_0412.mov", r2_key: `uploads/${U}.mov` });
        item({ id: "RenderOfUpload01", source: "studio", r2_key: "Rndr012345.webp", name: "IMG_0412.webp", link: null, session_id: S2, width: 480, height: 854, duration: 5, created_at: T + 200 });
        item({ id: "HostOfUpload0001", source: "host", r2_key: "Hst0123456.mov", name: "IMG_0412.mov", content_type: "video/quicktime", link: null, session_id: S2, created_at: T + 150 });
        const b = await body();
        expect(b.posts).toHaveLength(1);
        const p = b.posts[0];
        expect(p).toMatchObject({
            id: U,
            service: "upload",
            link: null,
            title: "IMG_0412.mov",
            duration: 6.2,
            width: 1080,
            height: 1920,
            created_at: T + 200,
            session: { id: S2, status: "ready", source_url: `${API}/studio/${S2}/source` },
        });
        expect(p.files.map((f: any) => f.id)).toEqual(["RenderOfUpload01", "HostOfUpload0001", U]);
        expect(b.counts).toEqual({ posts: 1, files: 3 });
    });

    it("an upload that was never opened in a studio is a post of its own, service null (no session, no link)", async () => {
        item({ id: U, kind: "private", source: "upload", bucket: "originals", r2_key: `uploads/${U}.png`, name: "a.png", content_type: "image/png", bytes: 5, created_at: T + 100 });
        const p = (await body()).posts[0];
        expect(p).toMatchObject({ id: U, service: null, link: null, title: "a.png", duration: null, session: null });
    });

    it("the known gap: an image hosted from an upload is a second post next to its private upload", async () => {
        item({ id: U, kind: "private", source: "upload", bucket: "originals", r2_key: `uploads/${U}.png`, name: "a.png", content_type: "image/png", created_at: T + 50 });
        item({ id: "HostImg00000001", source: "host", r2_key: "Img0123456.png", name: "a.png", content_type: "image/png", created_at: T + 60 });
        const b = await body();
        expect(ids(b)).toEqual(["HostImg00000001", U]);
        expect(b.counts).toEqual({ posts: 2, files: 2 });
    });

    it("deleted rows are excluded everywhere: files, counts, usage, and a post with nothing left disappears", async () => {
        seedPostA();
        item({ id: "GoneRender00001", source: "studio", r2_key: "Gone012345.webp", link: LINK, session_id: SID, created_at: T + 9000, deleted_at: T + 9500 });
        item({ id: "GonePost0000001", source: "webp", r2_key: "Gone112345.webp", link: "https://gone.example/p", created_at: T + 9100, deleted_at: T + 9500, bytes: 777 });
        const b = await body();
        expect(ids(b)).toEqual([SID]);
        expect(b.posts[0].files.map((f: any) => f.id)).not.toContain("GoneRender00001");
        expect(b.posts[0].created_at).toBe(T + 3000); // the deleted newest file does not bump the post
        expect(b.counts).toEqual({ posts: 1, files: 3 });
        expect(b.usage.public_bytes + b.usage.private_bytes).toBe(4500000 + 4331778 + 4331778);
    });

    it("posts are ordered by their newest file, newest first", async () => {
        item({ link: "https://a.example/1", created_at: T + 10 });
        item({ link: "https://b.example/2", created_at: T + 30 });
        item({ link: "https://c.example/3", created_at: T + 20 });
        // a later file in the oldest post lifts the whole post
        item({ link: "https://a.example/1", created_at: T + 40 });
        expect(ids(await body())).toEqual(["https://a.example/1", "https://b.example/2", "https://c.example/3"]);
    });

    it("session: the newest one that is not expired and is saving or ready; error and expired sessions are not offered", async () => {
        item({ source: "saved", kind: "private", bucket: "originals", r2_key: `originals/${SID}.mp4`, session_id: SID, link: LINK, created_at: T + 1 });
        sess({ id: SID, link: LINK, status: "ready", created_at: T + 1 });
        sess({ id: S3, link: LINK, status: "error", created_at: T + 5, error_code: "error.api.fetch.fail", r2_key: null });
        let p = (await body()).posts[0];
        // only SID's own session matches the post key (the post is keyed by the session id)
        expect(p.session).toMatchObject({ id: SID });
        w.db.raw.prepare("UPDATE studio_sessions SET expires_at = ? WHERE id = ?").run(w.clock.t - 1, SID);
        p = (await body()).posts[0];
        expect(p.session).toBeNull();
        w.db.raw.prepare("UPDATE studio_sessions SET expires_at = ?, status = 'saving' WHERE id = ?").run(w.clock.t + 1000, SID);
        expect((await body()).posts[0].session).toMatchObject({ id: SID, status: "saving" });
        w.db.raw.prepare("UPDATE studio_sessions SET status = 'error' WHERE id = ?").run(SID);
        expect((await body()).posts[0].session).toBeNull();
    });

    it("an upload post offers the newest open adopted session, not an expired older one", async () => {
        item({ id: U, kind: "private", source: "upload", bucket: "originals", r2_key: `uploads/${U}.mp4`, name: "a.mp4", content_type: "video/mp4", created_at: T + 1 });
        sess({ id: S3, link: `upload:${U}`, service: "upload", created_at: T + 2, expires_at: w.clock.t - 1 });
        sess({ id: S2, link: `upload:${U}`, service: "upload", created_at: T + 3 });
        expect((await body()).posts[0].session).toMatchObject({ id: S2 });
    });

    it("service comes from the post's newest session, else from the link, else null", async () => {
        item({ source: "saved", kind: "private", bucket: "originals", r2_key: `originals/${SID}.mp4`, session_id: SID, link: LINK, created_at: T + 3 });
        sess({ id: SID, link: LINK, service: "twitter-from-session" });
        item({ link: "https://vimeo.com/123", created_at: T + 2 });
        item({ created_at: T + 1 }); // no session, no link: its own post keyed by the item id
        const b = await body();
        const by = Object.fromEntries(b.posts.map((p: any) => [p.service ?? "none", p]));
        expect(by["twitter-from-session"].id).toBe(SID);
        expect(by["vimeo"].id).toBe("https://vimeo.com/123");
        expect(by["none"].link).toBeNull();
    });

    it("title, duration, width and height come from the private original, not from a newer render", async () => {
        const { saved } = seedPostA();
        const p = (await body()).posts[0];
        expect(p).toMatchObject({ title: saved.name, duration: saved.duration, width: saved.width, height: saved.height });
        // the webp (480x854, 10.1 s) is newer but does not speak for the post
        expect(p.width).not.toBe(480);
    });

    it("counts and usage cover the whole library, not the page", async () => {
        for (let i = 0; i < 5; i++) item({ link: `https://p.example/${i}`, created_at: T + i, bytes: 10 });
        item({ kind: "private", source: "upload", bucket: "originals", r2_key: "uploads/PrivOne000000000.png", created_at: T + 99, bytes: 1000 });
        const b = await body("?limit=2");
        expect(b.posts).toHaveLength(2);
        expect(b.counts).toEqual({ posts: 6, files: 6 });
        expect(b.usage).toEqual({ public_bytes: 50, private_bytes: 1000 });
        expect(b.next).not.toBeNull();
    });

    it("an empty library: no posts, zero counts, next null", async () => {
        expect(await body()).toEqual({ status: "success", posts: [], counts: { posts: 0, files: 0 }, usage: { public_bytes: 0, private_bytes: 0 }, next: null });
    });

    describe("pagination", () => {
        const all = async (limit: number) => {
            const seen: string[] = [];
            let cursor: string | null = null;
            for (let guard = 0; guard < 50; guard++) {
                const b: any = await body(`?limit=${limit}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`);
                expect(b.posts.length).toBeLessThanOrEqual(limit);
                seen.push(...ids(b));
                cursor = b.next;
                if (!cursor) return seen;
            }
            throw new Error("did not terminate");
        };

        it("pages through every post once, newest first, with a null next on the last page", async () => {
            for (let i = 0; i < 7; i++) item({ link: `https://p.example/${i}`, created_at: T + i * 10 });
            const expected = [6, 5, 4, 3, 2, 1, 0].map((i) => `https://p.example/${i}`);
            expect(await all(3)).toEqual(expected);
            expect(await all(1)).toEqual(expected);
            expect(await all(7)).toEqual(expected);
            expect((await body("?limit=7")).next).toBeNull();
            expect((await body("?limit=6")).next).not.toBeNull();
        });
        it("posts that share a newest timestamp are split stably by post key, descending, with nothing lost or repeated", async () => {
            const keys = ["https://t.example/a.b", "https://t.example/c", "https://t.example/d.e.f", "https://t.example/b", "https://t.example/a"];
            for (const k of keys) item({ link: k, created_at: T + 5 });
            item({ link: "https://t.example/older", created_at: T + 1 });
            const expected = [...keys].sort().reverse().concat("https://t.example/older");
            for (const limit of [1, 2, 3, 4, 5, 6]) expect(await all(limit)).toEqual(expected);
        });
        it("a file added between pages does not duplicate or skip an older post", async () => {
            for (let i = 0; i < 4; i++) item({ link: `https://p.example/${i}`, created_at: T + i * 10 });
            const first = await body("?limit=2");
            expect(ids(first)).toEqual(["https://p.example/3", "https://p.example/2"]);
            item({ link: "https://p.example/new", created_at: T + 500 }); // lands before the cursor: not in the next pages
            const second = await body(`?limit=2&cursor=${encodeURIComponent(first.next)}`);
            expect(ids(second)).toEqual(["https://p.example/1", "https://p.example/0"]);
            expect(second.next).toBeNull();
        });
        it("the cursor is opaque base64url (it round-trips keys that contain dots, colons and non-ASCII)", async () => {
            item({ link: "https://日本.example/a.b:c?x=1&y=2#z", created_at: T + 1 });
            item({ link: "https://t.example/second", created_at: T + 2 });
            const first = await body("?limit=1");
            expect(first.next).toMatch(/^[A-Za-z0-9_-]+$/);
            const second = await body(`?limit=1&cursor=${first.next}`);
            expect(ids(second)).toEqual(["https://日本.example/a.b:c?x=1&y=2#z"]);
            expect(second.next).toBeNull();
        });
        it("a post keeps all its files across the page boundary (the second query is by key, not by row)", async () => {
            for (let i = 0; i < 3; i++) item({ link: "https://big.example/post", created_at: T + 100 + i });
            for (let i = 0; i < 3; i++) item({ link: `https://small.example/${i}`, created_at: T + i });
            const first = await body("?limit=1");
            expect(first.posts[0].files).toHaveLength(3);
            const next = await body(`?limit=1&cursor=${first.next}`);
            expect(ids(next)).toEqual(["https://small.example/2"]);
        });
        it("default limit is 20, the maximum is 50", async () => {
            for (let i = 0; i < 55; i++) item({ link: `https://p.example/${String(i).padStart(2, "0")}`, created_at: T + i });
            expect((await body()).posts).toHaveLength(20);
            expect((await body("?limit=50")).posts).toHaveLength(50);
            expect((await body("?limit=1")).posts).toHaveLength(1);
        });
        it.each([["0"], ["51"], ["-1"], ["1.5"], ["abc"], [""], ["1e1"], ["0x10"], ["1000"], [" 5"]])("limit=%s is 400 error.library.bad_request", async (limit) => {
            const res = await list(`?limit=${encodeURIComponent(limit)}`);
            expect(res.status).toBe(400);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.bad_request" } });
        });
        it.each([
            ["not base64url", "!!!"],
            ["empty", ""],
            ["valid base64url but not '<ms>.<key>'", "aGVsbG8"],
            ["no key", "MTIzLg"],
            ["a non-numeric ms", "YWJjLmtleQ"],
            ["invalid UTF-8", "_-8"],
            ["padded", "MTIzLmtleQ=="],
        ])("cursor %s is 400 error.library.bad_request", async (_n, cursor) => {
            const res = await list(`?cursor=${encodeURIComponent(cursor)}`);
            expect(res.status).toBe(400);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.bad_request" } });
        });
    });

    describe("auth", () => {
        it("401 without a key, with a bad one, or revoked; the container is never touched", async () => {
            seedPostA();
            expect((await list("", {})).status).toBe(401);
            expect((await list("", { authorization: "Api-Key nope" })).status).toBe(401);
            expect((await list("", { authorization: "Api-Key 11111111-1111-4111-8111-111111111111" })).status).toBe(401);
            w.db.raw.prepare("UPDATE api_keys SET revoked_at = 5 WHERE id = ?").run(KEY_ID);
            expect((await list()).status).toBe(401);
            expect(w.seen).toHaveLength(0);
        });
        it("the service credential reads it too; D1 down is a 503; only GET", async () => {
            seedPostA();
            expect((await list("", svc)).status).toBe(200);
            for (const method of ["POST", "PUT", "DELETE"]) expect((await w.call("/library", { method, headers: auth })).status).toBe(404);
            w.db.breakIt();
            expect((await list()).status).toBe(503);
        });
        it("D1 failing after the key lookup (the list queries) is a 503 error.api.generic, not a 500", async () => {
            seedPostA();
            const orig = w.db.prepare.bind(w.db);
            (w.db as any).prepare = (sql: string) => {
                if (/FROM media_items/.test(sql)) throw new Error("D1_ERROR: media_items down");
                return orig(sql);
            };
            const res = await list();
            expect(res.status).toBe(503);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.api.generic" } });
        });
        it("never wakes the container, and no CORS header is added (the app sends no Origin)", async () => {
            seedPostA();
            const res = await list();
            // the one Durable Object call is the internal "queue the missing posters" kick (it only
            // writes records; the helper and the container are not involved); a library whose
            // originals all have a poster makes no call at all (section 13)
            expect(w.seen.map((r) => new URL(r.url).pathname)).toEqual(["/posters/kick"]);
            expect(res.headers.has("access-control-allow-origin")).toBe(false);
            w.db.raw.prepare("UPDATE media_items SET poster = 'https://media.capybaraharmony.com/Pstr000001.jpg'").run();
            w.seen.length = 0;
            await list();
            expect(w.seen).toHaveLength(0);
        });
    });
});

// ---------------------------------------------------------------------------------
describe("GET|HEAD /library/items/<id>/file", () => {
    let w: World;
    const ID = "PrivFile00000001";
    const data = Uint8Array.from({ length: 1000 }, (_, i) => i % 251);
    const seedFile = (over: Record<string, unknown> = {}, withObject = true) => {
        const r: Record<string, unknown> = {
            id: ID,
            kind: "private",
            source: "upload",
            bucket: "originals",
            r2_key: `uploads/${ID}.mov`,
            name: "IMG_0412.mov",
            content_type: "video/quicktime",
            bytes: 1000,
            created_at: 1,
            deleted_at: null,
            ...over,
        };
        w.db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, created_at, deleted_at) VALUES (@id,@kind,@source,@bucket,@r2_key,@name,@content_type,@bytes,@created_at,@deleted_at)",
            )
            .run(r as any);
        if (withObject) w.originals.objects.set(r.r2_key as string, { bytes: data, contentType: "video/quicktime", meta: {} });
    };
    const get = (range?: string, headers: Record<string, string> = auth, method = "GET", id = ID) =>
        w.call(`/library/items/${id}/file`, { method, headers: { ...headers, ...(range ? { range } : {}) } });
    const bytes = async (res: Response) => new Uint8Array(await res.arrayBuffer());
    beforeEach(async () => {
        w = world();
        await addKey(w);
    });

    it("200: the whole file with the row's type, length, accept-ranges and a private cache header", async () => {
        seedFile();
        const res = await get();
        expect(res.status).toBe(200);
        expect(res.headers.get("content-type")).toBe("video/quicktime");
        expect(res.headers.get("content-length")).toBe("1000");
        expect(res.headers.get("accept-ranges")).toBe("bytes");
        expect(res.headers.get("cache-control")).toBe("private, max-age=3600");
        expect(await bytes(res)).toEqual(data);
        expect(w.seen).toHaveLength(0); // never the container
    });
    it("works long after a session's seven days (it is not a session route)", async () => {
        seedFile();
        w.clock.t += 400 * 24 * 3600 * 1000;
        expect((await get()).status).toBe(200);
    });
    it("HEAD: the same headers, no body, and R2 is not read", async () => {
        seedFile();
        const res = await get(undefined, auth, "HEAD");
        expect(res.status).toBe(200);
        expect(res.headers.get("content-length")).toBe("1000");
        expect(await res.text()).toBe("");
        expect(w.originals.gets).toHaveLength(0);
    });
    it.each([
        ["bytes=0-99", 0, 99, 100],
        ["bytes=900-", 900, 999, 100],
        ["bytes=-100", 900, 999, 100],
        ["bytes=500-2000", 500, 999, 500],
        ["bytes=0-0", 0, 0, 1],
        ["bytes=999-999", 999, 999, 1],
        ["bytes=-5000", 0, 999, 1000],
    ])("Range %s: 206 with content-range bytes %i-%i/1000", async (range, from, to, length) => {
        seedFile();
        const res = await get(range);
        expect(res.status).toBe(206);
        expect(res.headers.get("content-range")).toBe(`bytes ${from}-${to}/1000`);
        expect(res.headers.get("content-length")).toBe(String(length));
        expect(res.headers.get("accept-ranges")).toBe("bytes");
        expect(await bytes(res)).toEqual(data.slice(from, to + 1));
        expect(w.originals.gets.at(-1)!.range).toEqual({ offset: from, length });
    });
    it("a HEAD with a Range answers the 206 headers only", async () => {
        seedFile();
        const res = await get("bytes=10-19", auth, "HEAD");
        expect(res.status).toBe(206);
        expect(res.headers.get("content-range")).toBe("bytes 10-19/1000");
        expect(await res.text()).toBe("");
    });
    it("a multi-range request is served in full (200), like the source route", async () => {
        seedFile();
        const res = await get("bytes=0-9,20-29");
        expect(res.status).toBe(200);
        expect((await bytes(res)).length).toBe(1000);
    });
    it.each([["bytes=1000-"], ["bytes=5000-6000"], ["bytes=abc"], ["bytes=-"], ["bytes=-0"], ["bytes=9-5"]])("Range %s: 416 error.studio.bad_range with content-range bytes */1000", async (range) => {
        seedFile();
        const res = await get(range);
        expect(res.status).toBe(416);
        expect(res.headers.get("content-range")).toBe("bytes */1000");
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.studio.bad_range" } });
    });
    it("another range unit is ignored (full 200)", async () => {
        seedFile();
        expect((await get("items=0-5")).status).toBe(200);
    });
    it("a row with no recorded size takes it from the object", async () => {
        seedFile({ bytes: null });
        const res = await get();
        expect(res.status).toBe(200);
        expect(res.headers.get("content-length")).toBe("1000");
        expect(await bytes(res)).toEqual(data);
        const part = await get("bytes=-10");
        expect(part.status).toBe(206);
        expect(part.headers.get("content-range")).toBe("bytes 990-999/1000");
        expect(await bytes(part)).toEqual(data.slice(990));
    });
    it("the type falls back to the object's, then to octet-stream", async () => {
        seedFile({ content_type: null });
        expect((await get(undefined, auth, "HEAD")).headers.get("content-type")).toBe("video/quicktime");
        w.originals.objects.get(`uploads/${ID}.mov`)!.contentType = "";
        expect((await get(undefined, auth, "HEAD")).headers.get("content-type")).toBe("application/octet-stream");
    });
    describe("the object's real size, not the row's (finding 7)", () => {
        it("HEAD for an object that is gone is 404 error.library.missing, not a 200 quoting the row's size", async () => {
            seedFile({}, false); // the row says 1000 bytes, R2 has nothing
            const res = await get(undefined, auth, "HEAD");
            expect(res.status).toBe(404);
            expect(w.originals.heads).toEqual([`uploads/${ID}.mov`]);
            const body = await get();
            expect(body.status).toBe(404);
            expect(await body.json()).toEqual({ status: "error", error: { code: "error.library.missing" } });
            expect((await get("bytes=0-9", auth, "HEAD")).status).toBe(404);
        });
        it("a stale row size: HEAD, a full GET and a Range all use the object's size", async () => {
            seedFile({ bytes: 5000 }); // the object is 1000 bytes
            const head = await get(undefined, auth, "HEAD");
            expect(head.status).toBe(200);
            expect(head.headers.get("content-length")).toBe("1000");
            const full = await get();
            expect(full.headers.get("content-length")).toBe("1000");
            expect(await bytes(full)).toEqual(data);
            const part = await get("bytes=-10");
            expect(part.status).toBe(206);
            expect(part.headers.get("content-range")).toBe("bytes 990-999/1000");
            expect(await bytes(part)).toEqual(data.slice(990));
            // 1500 is inside the stale 5000 but past the real end
            const past = await get("bytes=1500-");
            expect(past.status).toBe(416);
            expect(past.headers.get("content-range")).toBe("bytes */1000");
        });
        it("R2 failing on the size lookup: 502 error.library.storage", async () => {
            seedFile();
            w.originals.failHead = true;
            expect((await get(undefined, auth, "HEAD")).status).toBe(502);
            expect((await get()).status).toBe(502);
        });
    });
    it("a public row: 409 error.library.public (use its url)", async () => {
        seedFile({ kind: "public", bucket: "media", r2_key: "Abcdefghij.webp" }, false);
        const res = await get();
        expect(res.status).toBe(409);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.public" } });
    });
    it("unknown or deleted: 404 error.library.not_found; a missing object: 404 error.library.missing", async () => {
        expect(await (await get()).json()).toEqual({ status: "error", error: { code: "error.library.not_found" } });
        seedFile({ deleted_at: 5 });
        expect((await get()).status).toBe(404);
        w.db.raw.prepare("UPDATE media_items SET deleted_at = NULL").run();
        w.originals.objects.clear();
        const res = await get();
        expect(res.status).toBe(404);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.missing" } });
        // ...and the same for a ranged read
        expect(((await (await get("bytes=0-5")).json()) as any).error.code).toBe("error.library.missing");
    });
    it("R2 failing: 502 error.library.storage", async () => {
        seedFile();
        w.originals.failGet = true;
        const res = await get();
        expect(res.status).toBe(502);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.storage" } });
    });
    it("needs a key: 401 without, with a bad one or a revoked one; the service credential works", async () => {
        seedFile();
        expect((await get(undefined, {})).status).toBe(401);
        expect((await get(undefined, { authorization: "Api-Key nope" })).status).toBe(401);
        expect((await get(undefined, svc)).status).toBe(200);
        w.db.raw.prepare("UPDATE api_keys SET revoked_at = 5 WHERE id = ?").run(KEY_ID);
        expect((await get()).status).toBe(401);
        expect((await get(undefined, auth, "HEAD")).status).toBe(401);
    });
    it("ids of 15 or 17 characters, other methods and other sub-paths are 404 before any lookup", async () => {
        seedFile();
        expect((await get(undefined, auth, "GET", ID.slice(0, 15))).status).toBe(404);
        expect((await get(undefined, auth, "GET", ID + "x")).status).toBe(404);
        expect((await w.call(`/library/items/${ID}/file`, { method: "POST", headers: auth })).status).toBe(404);
        expect((await w.call(`/library/items/${ID}/file`, { method: "DELETE", headers: auth })).status).toBe(404);
        expect((await w.call(`/library/items/${ID}`, { headers: auth })).status).toBe(404);
        expect(w.originals.gets).toHaveLength(0);
    });
});

// ---------------------------------------------------------------------------------
describe("POST /library/items/<id>/publish", () => {
    let w: World;
    const ID = "PrivItem00000001";
    const data = Uint8Array.from({ length: 3000 }, (_, i) => (i * 7) % 256);
    const seedPriv = (over: Record<string, unknown> = {}, withObject = true) => {
        const r: Record<string, unknown> = {
            id: ID,
            kind: "private",
            source: "upload",
            bucket: "originals",
            r2_key: `uploads/${ID}.mov`,
            name: "IMG_0412.mov",
            content_type: "video/quicktime",
            bytes: 3000,
            width: 1080,
            height: 1920,
            duration: 6.2,
            link: LINK,
            session_id: SID,
            key_id: "someone-else",
            created_at: 1,
            deleted_at: null,
            ...over,
        };
        w.db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at) VALUES (@id,@kind,@source,@bucket,@r2_key,@name,@content_type,@bytes,@width,@height,@duration,@link,@session_id,@key_id,@created_at,@deleted_at)",
            )
            .run(r as any);
        if (withObject) w.originals.objects.set(r.r2_key as string, { bytes: data, contentType: "video/quicktime", meta: {} });
    };
    const publish = (headers: Record<string, string> = auth, id = ID) => w.call(`/library/items/${id}/publish`, { method: "POST", headers });
    const hostRows = () => w.db.raw.prepare("SELECT * FROM media_items WHERE source = 'host'").all() as any[];
    beforeEach(async () => {
        w = world();
        await addKey(w);
    });

    it("201 {status, url, bytes, content_type, item_id}: copied under a new 10-char name with the immutable cache header and the caller's key", async () => {
        seedPriv();
        const res = await publish();
        expect(res.status).toBe(201);
        const b = (await res.json()) as any;
        expect(b).toEqual({
            status: "success",
            url: expect.stringMatching(/^https:\/\/media\.capybaraharmony\.com\/[A-Za-z0-9]{10}\.mov$/),
            bytes: 3000,
            content_type: "video/quicktime",
            item_id: expect.stringMatching(BASE62_16),
        });
        const name = b.url.split("/").pop();
        const obj = w.media.objects.get(name)!;
        expect(obj.data).toEqual(data);
        expect(obj.contentType).toBe("video/quicktime");
        expect(obj.cacheControl).toBe("public, max-age=31536000, immutable");
        expect(obj.viaStream).toBe(true);
        expect(obj.meta).toMatchObject({ keyId: KEY_ID, source: LINK, sessionId: SID, published: "1" });
        // the original is untouched
        expect(w.originals.objects.get(`uploads/${ID}.mov`)!.bytes).toEqual(data);
        expect(w.items().find((r) => r.id === ID)).toMatchObject({ kind: "private", deleted_at: null });
    });
    it("the new host row copies session, link, size and duration from the source and records the caller", async () => {
        seedPriv();
        const b = (await (await publish()).json()) as any;
        const rows = hostRows();
        expect(rows).toHaveLength(1);
        expect(rows[0]).toMatchObject({
            id: b.item_id,
            kind: "public",
            source: "host",
            bucket: "media",
            r2_key: b.url.split("/").pop(),
            url: b.url,
            name: "IMG_0412.mov",
            content_type: "video/quicktime",
            bytes: 3000,
            width: 1080,
            height: 1920,
            duration: 6.2,
            link: LINK,
            session_id: SID,
            key_id: KEY_ID,
            created_at: w.clock.t,
            deleted_at: null,
        });
    });
    it("it copes with streams whose pipeTo / pipeThrough / tee are not implemented (this runtime): the copy is a reader/writer loop", async () => {
        seedPriv();
        w.originals.hostileStreams = true;
        const res = await publish();
        expect(res.status).toBe(201);
        const name = ((await res.json()) as any).url.split("/").pop();
        expect(w.media.objects.get(name)!.data).toEqual(data);
    });
    it("a larger file is copied chunk by chunk (nothing is buffered whole), the length checked by the fixed-length stream", async () => {
        const big = new Uint8Array(3_000_000).fill(3);
        seedPriv({ bytes: big.length });
        w.originals.objects.set(`uploads/${ID}.mov`, { bytes: big, contentType: "video/quicktime", meta: {} });
        const res = await publish();
        expect(res.status).toBe(201);
        const name = ((await res.json()) as any).url.split("/").pop();
        expect(w.media.objects.get(name)!.bytes).toBe(3_000_000);
    });
    it("an image is hosted as it is (the app's 'host as-is'): .png, image/png", async () => {
        seedPriv({ r2_key: `uploads/${ID}.png`, content_type: "image/png", name: "a.png", link: null, session_id: null });
        const b = (await (await publish()).json()) as any;
        expect(b.url).toMatch(/\.png$/);
        expect(b.content_type).toBe("image/png");
        expect(hostRows()[0]).toMatchObject({ link: null, session_id: null });
    });
    it("the content type falls back to the object's, then octet-stream", async () => {
        seedPriv({ content_type: null });
        expect(((await (await publish()).json()) as any).content_type).toBe("video/quicktime");
    });
    it("the service credential publishes as service:library", async () => {
        seedPriv();
        expect((await publish(svc)).status).toBe(201);
        expect(hostRows()[0]).toMatchObject({ key_id: SERVICE_KEY_ID });
    });
    it("404 not_found for an unknown or deleted item; nothing is copied", async () => {
        expect(await (await publish()).json()).toEqual({ status: "error", error: { code: "error.library.not_found" } });
        seedPriv({ deleted_at: 5 });
        expect((await publish()).status).toBe(404);
        expect(w.media.objects.size).toBe(0);
    });
    it("409 already_public for a public row", async () => {
        seedPriv({ kind: "public", bucket: "media", r2_key: "Abcdefghij.webp", content_type: "image/webp" }, false);
        const res = await publish();
        expect(res.status).toBe(409);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.already_public" } });
        expect(w.media.objects.size).toBe(0);
    });
    it("404 missing when the object is gone from R2", async () => {
        seedPriv({}, false);
        const res = await publish();
        expect(res.status).toBe(404);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.missing" } });
        expect(hostRows()).toHaveLength(0);
    });
    it("R2 failing to read: 502 storage; failing the put: 502 storage, and no row", async () => {
        seedPriv();
        w.originals.failGet = true;
        expect((await publish()).status).toBe(502);
        w.originals.failGet = false;
        w.media.failPut = true;
        const res = await publish();
        expect(res.status).toBe(502);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.storage" } });
        expect(hostRows()).toHaveLength(0);
        expect(w.media.objects.size).toBe(0);
    });
    it("a copy that does not match the declared length fails (fixed-length stream) as 502 and leaves no row", async () => {
        seedPriv();
        // the object's body is longer than the size the stream was told
        const real = w.originals.get.bind(w.originals);
        w.originals.get = async (key, options) => {
            const o = await real(key, options);
            return o ? { ...o, size: o.size - 1 } : o;
        };
        const res = await publish();
        expect(res.status).toBe(502);
        expect(hostRows()).toHaveLength(0);
    });
    it("D1 failing the insert after the copy: 503 and the public object is removed again", async () => {
        seedPriv();
        w.breakItems();
        const res = await publish();
        expect(res.status).toBe(503);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.api.generic" } });
        expect(w.media.objects.size).toBe(0);
    });
    it("needs a key; item ids of the wrong length and other methods are 404", async () => {
        seedPriv();
        expect((await publish({})).status).toBe(401);
        expect((await publish({ authorization: "Api-Key nope" })).status).toBe(401);
        expect((await publish(auth, ID.slice(0, 15))).status).toBe(404);
        expect((await publish(auth, ID + "0")).status).toBe(404);
        expect((await w.call(`/library/items/${ID}/publish`, { method: "GET", headers: auth })).status).toBe(404);
        expect(w.media.objects.size).toBe(0);
        expect(w.seen).toHaveLength(0);
    });
});

// ---------------------------------------------------------------------------------
describe("POST /library/items/<id>/studio", () => {
    let w: World;
    const ID = "PrivVideo0000001";
    const seedPriv = (over: Record<string, unknown> = {}, withObject = true) => {
        const r: Record<string, unknown> = {
            id: ID,
            kind: "private",
            source: "upload",
            bucket: "originals",
            r2_key: `uploads/${ID}.mp4`,
            name: "holiday.mp4",
            content_type: "video/mp4",
            bytes: 4096,
            session_id: null,
            created_at: 1,
            deleted_at: null,
            ...over,
        };
        w.db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, session_id, created_at, deleted_at) VALUES (@id,@kind,@source,@bucket,@r2_key,@name,@content_type,@bytes,@session_id,@created_at,@deleted_at)",
            )
            .run(r as any);
        if (withObject) w.originals.objects.set(r.r2_key as string, { bytes: new Uint8Array(4096).fill(5), contentType: "video/mp4", meta: {} });
    };
    const open = (headers: Record<string, string> = auth, id = ID) => w.call(`/library/items/${id}/studio`, { method: "POST", headers });
    beforeEach(async () => {
        w = world();
        await addKey(w);
    });

    it("adopts a private video: 201 {status, id, url}, a session through the internal path with the caller's key", async () => {
        seedPriv();
        const res = await open();
        expect(res.status).toBe(201);
        const b = (await res.json()) as any;
        expect(b).toEqual({ status: "success", id: expect.stringMatching(/^[A-Za-z0-9]{22}$/), url: `${ORIGIN}/studio/${b.id}` });
        expect(w.session(b.id)).toMatchObject({
            status: "saving",
            key_id: KEY_ID,
            link: `upload:${ID}`,
            service: "upload",
            title: "holiday.mp4",
            r2_key: `uploads/${ID}.mp4`,
            content_type: "video/mp4",
            bytes: 4096,
        });
        expect(w.seen.map((r) => new URL(r.url).pathname)).toEqual(["/studio/upload/adopt"]);
        expect(w.seen[0]!.headers.get(KEY_ID_HEADER)).toBe(KEY_ID);
        // and it polls to ready like any session
        expect(((await (await w.call(`/studio/${b.id}`)).json()) as any).status).toBe("ready");
    });
    it("a gif is a video here", async () => {
        seedPriv({ r2_key: `uploads/${ID}.gif`, content_type: "image/gif", name: "a.gif" });
        expect((await open()).status).toBe(201);
    });
    it("a saved original whose own session is still open is reopened (200), not adopted again; the container is not touched", async () => {
        seedPriv({ source: "saved", r2_key: `originals/${SID}.mp4`, session_id: SID, name: "x_2105237035271258436" });
        w.seed({}, false);
        const res = await open();
        expect(res.status).toBe(200);
        expect(await res.json()).toEqual({ status: "success", id: SID, url: `${ORIGIN}/studio/${SID}` });
        expect(w.seen).toHaveLength(0);
        expect(w.db.raw.prepare("SELECT count(*) AS n FROM studio_sessions").get()).toEqual({ n: 1 });
    });
    it.each([
        ["expired", { expires_at: 1 }],
        ["still saving", { status: "saving" }],
        ["failed", { status: "error", error_code: "error.studio.save_lost" }],
        ["for another object", { r2_key: "originals/OtherOtherOtherOtherOo.mp4" }],
    ])("a saved original whose session is %s is adopted afresh (201)", async (_n, over) => {
        seedPriv({ source: "saved", r2_key: `originals/${SID}.mp4`, session_id: SID, name: "x_2105237035271258436" });
        w.seed({ expires_at: w.clock.t + SESSION_TTL_MS, ...over }, false);
        w.originals.objects.set(`originals/${SID}.mp4`, { bytes: new Uint8Array(4096).fill(5), contentType: "video/mp4", meta: {} });
        const res = await open();
        expect(res.status).toBe(201);
        const b = (await res.json()) as any;
        expect(b.id).not.toBe(SID);
        // the new session names the saved original's own session id (finding 4)
        expect(w.session(b.id)).toMatchObject({ link: `upload:${SID}`, key_id: KEY_ID });
    });
    it("reopening an expired saved original: its new renders group under the original session id, so the post stays ONE card (finding 4)", async () => {
        seedPriv({ source: "saved", r2_key: `originals/${SID}.mp4`, session_id: SID, name: "x_2105237035271258436", created_at: 1000 });
        w.seed({ expires_at: 1 }, false); // the old studio expired
        w.originals.objects.set(`originals/${SID}.mp4`, { bytes: new Uint8Array(4096).fill(5), contentType: "video/mp4", meta: {} });
        const b = (await (await open()).json()) as any;
        expect(await (await w.call(`/studio/${b.id}`)).json()).toMatchObject({ status: "ready" });
        const made = await w.studio.render(b.id, jsonBody({ start: 0, length: 2 }));
        expect(made.status).toBe(202);
        expect(asBody(await w.studio.renderStatus(b.id, asBody(made).job, 5)).status).toBe("success");

        const lib = (await (await w.call("/library", { headers: auth })).json()) as any;
        expect(lib.posts).toHaveLength(1);
        expect(lib.posts[0].id).toBe(SID);
        expect(lib.posts[0].files.map((f: any) => f.source).sort()).toEqual(["saved", "studio"]);
        expect(lib.posts[0].session).toMatchObject({ id: b.id, status: "ready" });
        expect(lib.counts.posts).toBe(1);
    });
    it("an uploaded original keeps its own item id as the post key (the reopened studio names it)", async () => {
        seedPriv();
        const b = (await (await open()).json()) as any;
        expect(w.session(b.id).link).toBe(`upload:${ID}`);
    });
    it("a saved row with no session id falls back to its item id", async () => {
        seedPriv({ source: "saved", r2_key: `originals/${SID}.mp4`, session_id: null });
        w.originals.objects.set(`originals/${SID}.mp4`, { bytes: new Uint8Array(4096).fill(5), contentType: "video/mp4", meta: {} });
        const b = (await (await open()).json()) as any;
        expect(w.session(b.id).link).toBe(`upload:${ID}`);
    });
    it("a busy helper: 429 error.studio.busy, nothing created (the app retries later)", async () => {
        seedPriv();
        await w.call("/studio", { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: jsonBody({ url: LINK }) });
        const before = w.db.raw.prepare("SELECT count(*) AS n FROM studio_sessions").get();
        const res = await open();
        expect(res.status).toBe(429);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.studio.busy" } });
        expect(w.db.raw.prepare("SELECT count(*) AS n FROM studio_sessions").get()).toEqual(before);
    });
    it("404 not_found for an unknown or deleted item", async () => {
        expect(await (await open()).json()).toEqual({ status: "error", error: { code: "error.library.not_found" } });
        seedPriv({ deleted_at: 3 });
        expect((await open()).status).toBe(404);
    });
    it("409 not_private for a public item", async () => {
        seedPriv({ kind: "public", bucket: "media", r2_key: "Abcdefghij.webp", content_type: "image/webp" }, false);
        const res = await open();
        expect(res.status).toBe(409);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.not_private" } });
    });
    it.each([["image/png"], ["image/jpeg"], ["image/heic"], ["image/webp"], [null]])("400 error.studio.not_video for %s", async (type) => {
        seedPriv({ r2_key: `uploads/${ID}.png`, content_type: type, name: "a.png" });
        const res = await open();
        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.studio.not_video" } });
        expect(w.seen).toHaveLength(0);
    });
    it("a row with no recorded size takes it from the object (head), so a backfilled row can be opened (finding 5)", async () => {
        seedPriv({ bytes: null });
        const res = await open();
        expect(res.status).toBe(201);
        const b = (await res.json()) as any;
        expect(w.originals.heads).toEqual([`uploads/${ID}.mp4`]);
        expect(w.session(b.id)).toMatchObject({ status: "saving", bytes: 4096 });
        expect(((await (await w.call(`/studio/${b.id}`)).json()) as any).status).toBe("ready");
    });
    it("a row with a recorded size does not head the object", async () => {
        seedPriv();
        expect((await open()).status).toBe(201);
        expect(w.originals.heads).toEqual([]);
    });
    it("a row with no recorded size and no object: 404 error.library.missing, nothing created", async () => {
        seedPriv({ bytes: null }, false);
        const res = await open();
        expect(res.status).toBe(404);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.missing" } });
        expect(w.db.raw.prepare("SELECT count(*) AS n FROM studio_sessions").get()).toEqual({ n: 0 });
        expect(w.seen).toHaveLength(0);
    });
    it("a row with no recorded size and R2 failing: 502 error.library.storage", async () => {
        seedPriv({ bytes: null });
        w.originals.failHead = true;
        const res = await open();
        expect(res.status).toBe(502);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.storage" } });
    });
    it("the service credential adopts as service:library", async () => {
        seedPriv();
        const res = await open(svc);
        expect(res.status).toBe(201);
        expect(w.session(((await res.json()) as any).id).key_id).toBe(SERVICE_KEY_ID);
    });
    it("a Durable Object that cannot be reached: 503 error.api.generic", async () => {
        seedPriv();
        const broken = { fetch: async () => Promise.reject(new Error("do down")) };
        const res = await handleRequest(
            new Request(`https://api.capybaraharmony.com/library/items/${ID}/studio`, { method: "POST", headers: auth }),
            w.env,
            broken,
            { now: w.clock.now, sleep: w.clock.sleep, fixedLength: fixedLengthPair },
        );
        expect(res.status).toBe(503);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.api.generic" } });
    });
    it("needs a key; wrong id lengths and other methods are 404", async () => {
        seedPriv();
        expect((await open({})).status).toBe(401);
        expect((await open({ authorization: "Api-Key nope" })).status).toBe(401);
        expect((await open(auth, ID.slice(0, 15))).status).toBe(404);
        expect((await open(auth, ID + "0")).status).toBe(404);
        expect((await w.call(`/library/items/${ID}/studio`, { method: "GET", headers: auth })).status).toBe(404);
        expect(w.seen).toHaveLength(0);
    });
    it("a client cannot pick the key id the session is created under", async () => {
        seedPriv();
        const res = await open({ ...auth, [KEY_ID_HEADER]: "victim" });
        expect(w.session(((await res.json()) as any).id).key_id).toBe(KEY_ID);
    });
});

// ---------------------------------------------------------------------------------
describe("DELETE /library/items/<id>/post (APP-API-CONTRACT.md section 12)", () => {
    let w: World;
    const T = 1_800_000_000_000;
    const NOW = T + 3_600_000; // an hour after every fixture
    const MIN = 60_000;
    const L2 = "https://www.instagram.com/reel/Dd7P496wolG/";
    const L3 = "https://www.instagram.com/reel/OtherPostXX/";
    const SIDB = "BsessionOtherPost00000b"; // 22 chars
    const S3 = "ReopenedSession0000000c"; // 22 chars
    const U = "UploadItem000001"; // 16 chars
    const SAVED = "SavedItem0000001";
    const HOST = "HostItem00000001";
    const R1 = "RenderItem000001";
    const R2 = "RenderItem000002";

    let n = 0;
    const item = (over: Record<string, unknown>) => {
        const r: Record<string, unknown> = {
            id: `Item${String(++n).padStart(12, "0")}`,
            kind: "public",
            source: "webp",
            bucket: "media",
            r2_key: `Key${String(n).padStart(7, "0")}.webp`,
            url: null,
            name: "n",
            content_type: "image/webp",
            bytes: 100,
            width: null,
            height: null,
            duration: null,
            link: null,
            session_id: null,
            key_id: null,
            created_at: T,
            deleted_at: null,
            ...over,
        };
        if (r.kind === "public" && r.url === null) r.url = `${MEDIA_BASE}${r.r2_key}`;
        w.db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at) VALUES (@id,@kind,@source,@bucket,@r2_key,@url,@name,@content_type,@bytes,@width,@height,@duration,@link,@session_id,@key_id,@created_at,@deleted_at)",
            )
            .run(r as any);
        // the object behind the row
        const store = r.bucket === "media" ? w.media.objects : (w.originals.objects as Map<string, any>);
        if (r.bucket === "media") {
            w.media.objects.set(r.r2_key as string, { bytes: 3, meta: {}, data: new Uint8Array(3), viaStream: false });
        } else {
            store.set(r.r2_key as string, { bytes: new Uint8Array(3), contentType: "video/mp4", meta: {} });
        }
        return r as any;
    };
    const sess = (over: Record<string, unknown>) =>
        w.seed({ expires_at: T + SESSION_TTL_MS, created_at: T, ...over }, false);
    const render = (id: string, session: string, status: string, created_at: number) =>
        w.db.raw
            .prepare("INSERT INTO studio_renders (id, session_id, status, created_at) VALUES (?, ?, ?, ?)")
            .run(id, session, status, created_at);
    const del = (id: string, headers: Record<string, string> = auth) =>
        w.call(`/library/items/${id}/post`, { method: "DELETE", headers });
    const row = (id: string) => w.db.raw.prepare("SELECT deleted_at FROM media_items WHERE id = ?").get(id) as any;
    const live = () =>
        (w.db.raw.prepare("SELECT id FROM media_items WHERE deleted_at IS NULL ORDER BY id").all() as any[]).map((r) => r.id);
    const expiresAt = (sid: string) => (w.session(sid) as any).expires_at;
    const hasMedia = (k: string) => w.media.objects.has(k);
    const hasOrig = (k: string) => w.originals.objects.has(k);

    // Post A: a saved original, two renders and a hosted copy, all of one session
    const seedPostA = () => {
        sess({ id: SID, link: LINK, r2_key: `originals/${SID}.mp4` });
        item({ id: SAVED, kind: "private", source: "saved", bucket: "originals", r2_key: `originals/${SID}.mp4`, content_type: "video/mp4", bytes: 1000, link: LINK, session_id: SID, created_at: T + 1000 });
        item({ id: HOST, source: "host", r2_key: "Klmnopqrst.mp4", content_type: "video/mp4", bytes: 2000, link: LINK, session_id: SID, created_at: T + 2000 });
        item({ id: R1, source: "studio", r2_key: "Abcdefghij.webp", bytes: 300, link: LINK, session_id: SID, created_at: T + 3000 });
        item({ id: R2, source: "studio", r2_key: "Abcdefghik.webp", bytes: 40, link: LINK, session_id: SID, created_at: T + 4000 });
    };
    // Post B: an unrelated saved post that must never be touched
    const seedPostB = () => {
        sess({ id: SIDB, link: L3, r2_key: `originals/${SIDB}.mp4` });
        item({ id: "OtherSaved000001", kind: "private", source: "saved", bucket: "originals", r2_key: `originals/${SIDB}.mp4`, content_type: "video/mp4", link: L3, session_id: SIDB, created_at: T + 500 });
        item({ id: "OtherRender00001", source: "studio", r2_key: "Zzzzzzzzz1.webp", link: L3, session_id: SIDB, created_at: T + 600 });
    };

    beforeEach(async () => {
        w = world();
        w.clock.t = NOW;
        await addKey(w);
        n = 0;
    });

    it("a post of a saved original, two webps and a hosted mp4: every row soft-deleted, all four objects gone, the session expired, counts back", async () => {
        seedPostA();
        seedPostB();
        const res = await del(HOST); // any file of the post is the anchor
        expect(res.status).toBe(200);
        expect(res.headers.get("cache-control")).toBe("no-store");
        expect(res.headers.get("content-type")).toBe("application/json");
        expect(await res.json()).toEqual({ status: "success", post: SID, deleted: { files: 4, bytes: 3340 }, remaining: [] });
        for (const id of [SAVED, HOST, R1, R2]) expect(row(id).deleted_at, id).toBe(NOW);
        for (const k of ["Klmnopqrst.mp4", "Abcdefghij.webp", "Abcdefghik.webp"]) expect(hasMedia(k), k).toBe(false);
        expect(hasOrig(`originals/${SID}.mp4`)).toBe(false);
        expect(expiresAt(SID)).toBe(NOW);
        // the other post: rows, objects and session as they were
        expect(live()).toEqual(["OtherRender00001", "OtherSaved000001"]);
        expect(hasMedia("Zzzzzzzzz1.webp")).toBe(true);
        expect(hasOrig(`originals/${SIDB}.mp4`)).toBe(true);
        expect(expiresAt(SIDB)).toBe(T + SESSION_TTL_MS);
        expect(w.seen).toHaveLength(0); // never the container nor a Durable Object
    });

    it("GET /library afterwards no longer lists the post, and the counts and usage drop", async () => {
        seedPostA();
        seedPostB();
        const before = (await (await w.call("/library", { headers: auth })).json()) as any;
        expect(before.posts.map((p: any) => p.id).sort()).toEqual([SID, SIDB].sort());
        expect(before.counts).toEqual({ posts: 2, files: 6 });
        expect((await del(R1)).status).toBe(200);
        const after = (await (await w.call("/library", { headers: auth })).json()) as any;
        expect(after.posts.map((p: any) => p.id)).toEqual([SIDB]);
        expect(after.counts).toEqual({ posts: 1, files: 2 });
    });

    it("idempotent: a second call, and a call anchored on an already deleted row, are 200 with zeros", async () => {
        seedPostA();
        expect((await del(SAVED)).status).toBe(200);
        w.clock.t += 5 * MIN;
        const again = await del(SAVED);
        expect(again.status).toBe(200);
        expect(await again.json()).toEqual({ status: "success", post: SID, deleted: { files: 0, bytes: 0 }, remaining: [] });
        const other = await del(R2); // deleted too: still resolves the same post
        expect(other.status).toBe(200);
        expect(await other.json()).toEqual({ status: "success", post: SID, deleted: { files: 0, bytes: 0 }, remaining: [] });
        // deleted_at keeps the first call's time
        expect(row(SAVED).deleted_at).toBe(NOW);
    });

    it("an anchor that is itself soft-deleted (one webp deleted earlier) still deletes the rest of the post", async () => {
        seedPostA();
        w.db.raw.prepare("UPDATE media_items SET deleted_at = ? WHERE id = ?").run(T + 9, R1);
        w.media.objects.delete("Abcdefghij.webp");
        const res = await del(R1);
        expect(res.status).toBe(200);
        expect(((await res.json()) as any).deleted).toEqual({ files: 3, bytes: 3040 });
        expect(live()).toEqual([]);
        expect(row(R1).deleted_at).toBe(T + 9);
    });

    it("an upload post (the session's link is upload:<item id>): the original and its renders go together", async () => {
        sess({ id: S3, link: `upload:${U}`, r2_key: `uploads/${U}.mp4` });
        item({ id: U, kind: "private", source: "upload", bucket: "originals", r2_key: `uploads/${U}.mp4`, content_type: "video/mp4", bytes: 500, session_id: S3, created_at: T + 100 });
        item({ id: R1, source: "studio", r2_key: "Upload0001.webp", bytes: 70, session_id: S3, created_at: T + 200 });
        seedPostB();
        const res = await del(R1);
        expect(res.status).toBe(200);
        expect(await res.json()).toEqual({ status: "success", post: U, deleted: { files: 2, bytes: 570 }, remaining: [] });
        expect(live()).toEqual(["OtherRender00001", "OtherSaved000001"]);
        expect(hasOrig(`uploads/${U}.mp4`)).toBe(false);
        expect(expiresAt(S3)).toBe(NOW);
    });

    it("a reopened saved session: its renders stay in the original's post, so the whole post goes and both sessions are expired", async () => {
        sess({ id: SID, link: LINK, r2_key: `originals/${SID}.mp4` });
        sess({ id: S3, link: `upload:${SID}`, r2_key: `originals/${SID}.mp4`, created_at: T + 50 });
        item({ id: SAVED, kind: "private", source: "saved", bucket: "originals", r2_key: `originals/${SID}.mp4`, content_type: "video/mp4", bytes: 1000, link: LINK, session_id: SID, created_at: T + 100 });
        item({ id: R1, source: "studio", r2_key: "Reopened01.webp", bytes: 8, link: `upload:${SID}`, session_id: S3, created_at: T + 200 });
        item({ id: R2, source: "studio", r2_key: "Reopened02.webp", bytes: 9, link: LINK, session_id: SID, created_at: T + 300 });
        seedPostB();
        const res = await del(R1);
        expect(res.status).toBe(200);
        expect(((await res.json()) as any)).toMatchObject({ post: SID, deleted: { files: 3, bytes: 1017 } });
        expect(live()).toEqual(["OtherRender00001", "OtherSaved000001"]);
        expect(expiresAt(SID)).toBe(NOW);
        expect(expiresAt(S3)).toBe(NOW);
        expect(expiresAt(SIDB)).toBe(T + SESSION_TTL_MS);
    });

    it("a /webp-job post (no session, keyed by its link): only its rows go; another post with a different link is untouched", async () => {
        const a = item({ source: "webp", r2_key: "WebpJob0001.webp", bytes: 11, link: L2, created_at: T + 10 });
        const b = item({ source: "webp", r2_key: "WebpJob0002.webp", bytes: 12, link: L2, created_at: T + 20 });
        const c = item({ source: "webp", r2_key: "WebpJob0003.webp", bytes: 13, link: L3, created_at: T + 30 });
        const solo = item({ source: "webp", r2_key: "WebpJob0004.webp", bytes: 14, created_at: T + 40 }); // no link: its own post
        const res = await del(b.id);
        expect(res.status).toBe(200);
        expect(await res.json()).toEqual({ status: "success", post: L2, deleted: { files: 2, bytes: 23 }, remaining: [] });
        expect(row(a.id).deleted_at).toBe(NOW);
        expect(row(b.id).deleted_at).toBe(NOW);
        expect(row(c.id).deleted_at).toBeNull();
        expect(row(solo.id).deleted_at).toBeNull();
        expect(hasMedia("WebpJob0001.webp") || hasMedia("WebpJob0002.webp")).toBe(false);
        expect(hasMedia("WebpJob0003.webp") && hasMedia("WebpJob0004.webp")).toBe(true);
        // a row with nothing to group by is a post of one
        const one = await del(solo.id);
        expect(await one.json()).toEqual({ status: "success", post: solo.id, deleted: { files: 1, bytes: 14 }, remaining: [] });
    });

    it("a session's stored original with no row of its own is deleted too (and a session with no object is fine)", async () => {
        sess({ id: SID, link: LINK, r2_key: `originals/${SID}.mp4` });
        w.originals.objects.set(`originals/${SID}.mp4`, { bytes: new Uint8Array(9), contentType: "video/mp4", meta: {} });
        sess({ id: S3, link: `upload:${SID}`, r2_key: null });
        item({ id: R1, source: "studio", r2_key: "NoRowOrig01.webp", link: LINK, session_id: SID, created_at: T + 10 });
        expect((await del(R1)).status).toBe(200);
        expect(hasOrig(`originals/${SID}.mp4`)).toBe(false);
        expect(expiresAt(SID)).toBe(NOW);
    });

    describe("busy", () => {
        const untouched = () => {
            expect(live()).toEqual([HOST, R1, R2, SAVED].sort());
            expect(hasMedia("Abcdefghij.webp") && hasMedia("Klmnopqrst.mp4")).toBe(true);
            expect(hasOrig(`originals/${SID}.mp4`)).toBe(true);
            expect(expiresAt(SID)).toBe(T + SESSION_TTL_MS);
        };
        it("a render started 5 minutes ago and still pending: 409 error.library.busy and nothing changes", async () => {
            seedPostA();
            render("PendingJob0000000001", SID, "pending", NOW - 5 * MIN);
            const res = await del(R1);
            expect(res.status).toBe(409);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.busy" } });
            untouched();
        });
        it("a render of a reopened session of the post counts too", async () => {
            seedPostA();
            sess({ id: S3, link: `upload:${SID}`, r2_key: `originals/${SID}.mp4`, created_at: T + 50 });
            render("PendingJob0000000002", S3, "pending", NOW - MIN);
            expect((await del(R1)).status).toBe(409);
            untouched();
        });
        it("a save that started 5 minutes ago and is still running: 409", async () => {
            seedPostA();
            w.db.raw.prepare("UPDATE studio_sessions SET status = 'saving', created_at = ? WHERE id = ?").run(NOW - 5 * MIN, SID);
            expect((await del(R1)).status).toBe(409);
            untouched();
        });
        it("a pending render, or a save, older than 15 minutes is a lost job: the delete proceeds", async () => {
            seedPostA();
            render("PendingJob0000000003", SID, "pending", NOW - 16 * MIN);
            expect((await del(R1)).status).toBe(200);
            expect(live()).toEqual([]);
            // and a saving session older than 15 minutes
            w = world();
            w.clock.t = NOW;
            await addKey(w);
            n = 0;
            seedPostA();
            w.db.raw.prepare("UPDATE studio_sessions SET status = 'saving', created_at = ? WHERE id = ?").run(NOW - 20 * MIN, SID);
            expect((await del(R1)).status).toBe(200);
            expect(live()).toEqual([]);
        });
        it("a finished render (success or error) never blocks; a pending render of another post does not either", async () => {
            seedPostA();
            seedPostB();
            render("DoneJob000000000001", SID, "success", NOW - MIN);
            render("FailJob00000000001", SID, "error", NOW - MIN);
            render("PendingJob0000000004", SIDB, "pending", NOW - MIN);
            expect((await del(R1)).status).toBe(200);
            expect(live()).toEqual(["OtherRender00001", "OtherSaved000001"]);
        });
        it("exactly 15 minutes old no longer blocks (the window is strictly newer than 15 minutes)", async () => {
            seedPostA();
            render("PendingJob0000000005", SID, "pending", NOW - 15 * MIN);
            expect((await del(R1)).status).toBe(200);
        });
    });

    describe("storage failures", () => {
        it("R2 failing for one key: 502 error.library.partial listing that file, its row stays live, the others are gone; a retry finishes with 200", async () => {
            seedPostA();
            const real = w.media.delete.bind(w.media);
            let failing = true;
            w.media.delete = async (k: string) => {
                if (failing && k === "Abcdefghik.webp") throw new Error("R2 down");
                return real(k);
            };
            const res = await del(SAVED);
            expect(res.status).toBe(502);
            expect(res.headers.get("cache-control")).toBe("no-store");
            expect(await res.json()).toEqual({
                status: "error",
                error: { code: "error.library.partial" },
                post: SID,
                deleted: { files: 3, bytes: 3300 },
                remaining: [R2],
            });
            expect(live()).toEqual([R2]);
            expect(row(R1).deleted_at).toBe(NOW);
            expect(hasMedia("Abcdefghik.webp")).toBe(true);
            expect(expiresAt(SID)).toBe(NOW); // the session was expired first
            failing = false;
            const retry = await del(SAVED);
            expect(retry.status).toBe(200);
            expect(await retry.json()).toEqual({ status: "success", post: SID, deleted: { files: 1, bytes: 40 }, remaining: [] });
            expect(live()).toEqual([]);
            expect(hasMedia("Abcdefghik.webp")).toBe(false);
        });
        it("the private bucket failing for the original: that row is the one reported", async () => {
            seedPostA();
            w.originals.delete = async () => {
                throw new Error("R2 down");
            };
            const res = await del(R1);
            expect(res.status).toBe(502);
            expect(((await res.json()) as any).remaining).toEqual([SAVED]);
            expect(live()).toEqual([SAVED]);
        });
        it("D1 refusing the row updates after the objects are gone: all reported as remaining (a retry re-deletes the missing objects and finishes)", async () => {
            seedPostA();
            // the lookups and the session expiry work; only media_items writes fail
            w.breakItems();
            const res = await del(R1);
            expect(res.status).toBe(502);
            expect(((await res.json()) as any).remaining).toEqual([SAVED, HOST, R1, R2]);
            expect(expiresAt(SID)).toBe(NOW);
        });
        it("D1 failing before anything changed: 503 error.api.generic, nothing deleted", async () => {
            seedPostA();
            // D1 answers the key lookup, then fails the post lookup itself
            const orig = w.db.prepare.bind(w.db);
            (w.db as any).prepare = (sql: string) => {
                if (/FROM media_items m WHERE m\.id = \?1/.test(sql)) throw new Error("D1_ERROR: down");
                return orig(sql);
            };
            const res = await del(R1);
            expect(res.status).toBe(503);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.api.generic" } });
            expect(hasMedia("Abcdefghij.webp")).toBe(true);
            expect(hasOrig(`originals/${SID}.mp4`)).toBe(true);
        });
    });

    describe("auth and the gate", () => {
        it("unknown id: 404 error.library.not_found", async () => {
            seedPostA();
            const res = await del("Nope000000000000");
            expect(res.status).toBe(404);
            expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.not_found" } });
            expect(live()).toHaveLength(4);
        });
        it("no key: 401 with the API's code, and nothing is read or deleted", async () => {
            seedPostA();
            const res = await del(R1, {});
            expect(res.status).toBe(401);
            expect(((await res.json()) as any).error.code).toBe("error.api.auth.key.missing");
            const bad = await del(R1, { authorization: `Api-Key ${"1".repeat(8)}-1111-4111-8111-111111111111` });
            expect(bad.status).toBe(401);
            expect(live()).toHaveLength(4);
        });
        it("the web Worker's service header works as a key", async () => {
            seedPostA();
            const res = await del(R1, svc);
            expect(res.status).toBe(200);
            expect(live()).toEqual([]);
        });
        it("a 15 or 17 character id is 404, as are GET, POST and PUT on .../post, before D1 is read", async () => {
            seedPostA();
            for (const id of [R1.slice(0, 15), R1 + "x"]) expect((await del(id)).status, id).toBe(404);
            for (const method of ["GET", "POST", "PUT", "HEAD"]) {
                const res = await w.call(`/library/items/${R1}/post`, { method, headers: auth });
                expect(res.status, method).toBe(404);
            }
            expect(live()).toHaveLength(4);
        });
        it("a browser Origin gets no CORS header: the web page does not call this route", async () => {
            seedPostA();
            const res = await del(R1, { ...auth, origin: ORIGIN });
            expect(res.status).toBe(200);
            expect(res.headers.get("access-control-allow-origin")).toBeNull();
        });
    });

    it("the existing per-file routes are unchanged: DELETE /media/<name> still removes one webp and leaves the post", async () => {
        seedPostA();
        const res = await w.call("/media/Abcdefghij.webp", { method: "DELETE", headers: auth });
        expect(res.status).toBe(200);
        expect(live()).toEqual([HOST, R2, SAVED].sort());
    });
});

// ---------------------------------------------------------------------------------
describe("the rest of the Worker, with the app routes in place", () => {
    let w: World;
    beforeEach(async () => {
        w = world();
        await addKey(w);
    });
    it("/library/adopt is still service only", async () => {
        expect((await w.call("/library/adopt", { method: "POST", headers: auth, body: jsonBody(ADOPT) })).status).toBe(401);
        expect((await w.call("/library/adopt", { method: "POST", body: jsonBody(ADOPT) })).status).toBe(401);
        w.originals.objects.set(ADOPT.r2_key, { bytes: new Uint8Array(4096), contentType: "video/mp4", meta: {} });
        expect((await w.call("/library/adopt", { method: "POST", headers: svc, body: jsonBody(ADOPT) })).status).toBe(201);
    });
    it("GET /studio/<sid>/render/<job> pending carries the helper's progress (phase, frames_done, frames_total)", async () => {
        w.seed();
        const started = await w.call(`/studio/${SID}/render`, { method: "POST", body: jsonBody({ start: 2, length: 5 }) });
        const job = ((await started.json()) as any).job;
        w.helper.jobPolls = 1e9;
        w.helper.jobPendingFields = { phase: "decode", frames_done: 12, frames_total: 75 };
        const pending = (await (await w.call(`/studio/${SID}/render/${job}?wait=0`)).json()) as any;
        expect(pending).toEqual({ status: "pending", job, phase: "decode", frames_done: 12, frames_total: 75 });
    });
    it("a render that nobody polls is collected by the sweep and the next GET .../render/<job> just returns it", async () => {
        w.seed();
        const started = await w.call(`/studio/${SID}/render`, { method: "POST", body: jsonBody({ start: 2, length: 5 }) });
        expect(started.status).toBe(202);
        const job = ((await started.json()) as any).job;
        // nobody polls; the Durable Object's sweep runs
        await w.studio.sweep();
        expect(w.db.raw.prepare("SELECT status FROM studio_renders WHERE id = ?").get(job)).toEqual({ status: "success" });
        const res = await w.call(`/studio/${SID}/render/${job}`);
        expect(await res.json()).toMatchObject({ status: "success", job });
        // and it shows up in the app's library as one post with the webp in it
        const lib = (await (await w.call("/library", { headers: auth })).json()) as any;
        expect(lib.posts).toHaveLength(1);
        expect(lib.posts[0].files[0]).toMatchObject({ source: "studio", deletable: true });
    });
    it("GET /studio/<sid> of a saving session shows the progress fields through the Worker and the DO", async () => {
        const created = await w.call("/studio", { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: jsonBody({ url: LINK }) });
        expect(created.status).toBe(201);
        const id = ((await created.json()) as any).id;
        w.helper.fetchPolls = 1e9;
        w.helper.fetchPendingFields = { stage: "downloading", bytes: 1500, total: 6000 };
        const first = (await (await w.call(`/studio/${id}?wait=0`)).json()) as any;
        expect(first).toMatchObject({ status: "saving", step: "fetching", step_bytes: 1500, step_total: 6000, waking: false });
    });
    it("when the Durable Object cannot answer, the Worker's own fallback still has the four fields (null / false)", async () => {
        const created = await w.call("/studio", { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: jsonBody({ url: LINK }) });
        const id = ((await created.json()) as any).id;
        const broken = { fetch: async () => Promise.reject(new Error("do down")) };
        const res = await handleRequest(new Request(`https://api.capybaraharmony.com/studio/${id}`), w.env, broken, {
            now: w.clock.now,
            sleep: w.clock.sleep,
        });
        expect(res.headers.get("x-studio-advance")).toContain("do down");
        expect(await res.json()).toMatchObject({ status: "saving", step: null, step_bytes: null, step_total: null, waking: false });
    });
});
