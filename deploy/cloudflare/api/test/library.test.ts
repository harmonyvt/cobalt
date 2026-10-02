// The library's API half (LIBRARY-CONTRACT.md): service auth, studio publish,
// library adopt (poll-driven probe), the media_items rows every source writes
// and the soft delete. The Worker, the Durable Object's services and the real
// SQL (node:sqlite on the real migrations) run together; the helper and R2 are
// the fakes from studio-fakes.ts.
import { beforeEach, describe, expect, it } from "vitest";
import { decide, type GateRequest } from "../src/gate";
import { KEY_ID_HEADER, PORT_HEADER, SERVICE_HEADER } from "../src/headers";
import { hashKey } from "../src/keys";
import { SERVICE_KEY_ID } from "../src/library";
import { serviceAuthorized } from "../src/service-auth";
import {
    BUSY_WAIT_MS,
    MAX_SOURCE_BYTES,
    SESSION_TTL_MS,
    UNAVAILABLE_AFTER_MS,
    StudioService,
    handleStudioRoute,
    isStudioRoute,
} from "../src/studio";
import { WebpService, handleWebpRoute, isWebpRoute } from "../src/webp";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { Clock, FakeHelper, MemoryKV, MemoryMedia, MemoryOriginals, fixedLength } from "./studio-fakes";

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
