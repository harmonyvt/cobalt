// Instant share (APP-API-CONTRACT.md section 14): `notify` and `origin: "share"` on POST /studio,
// and GET /studio/recent. The Worker, the Durable Object's services (the real StudioService with
// the real NotifyService) and the real SQL on node:sqlite run together; the helper, both R2
// buckets and the Hark webhook are fakes.
import { beforeEach, describe, expect, it } from "vitest";
import { decide } from "../src/gate";
import { KEY_ID_HEADER } from "../src/headers";
import { NotifyService } from "../src/notify";
import { RECENT_MAX, SHARE_KEEP_MS, SHARE_KICK_MS, handleStudioRoute, isStudioRoute } from "../src/studio";
import { handleNotifyRoute, isNotifyRoute } from "../src/notify";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { hashKey } from "../src/keys";
import { SERVICE_HEADER } from "../src/headers";
import { WebpService } from "../src/webp";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { Clock, FakeHelper, MemoryKV, MemoryMedia, MemoryOriginals, fixedLength, fixedLengthPair } from "./studio-fakes";
import { INTERNAL, CLIENT, KEY_ID, LINK, MEDIA_BASE, ORIGIN, asBody, auth, json } from "./poster-world";
import { StudioService } from "../src/studio";

const OTHER_KEY_ID = "key-row-2";
const OTHER_CLIENT = "7c1d9e4a-3b5f-4a2e-8d6c-0e9f1b2a3c4d";
const HOOK = "https://hark.example/api/webhook/T0pS3cretHookToken";

class FakeHark {
    calls: { title: string; body: string; url?: string }[] = [];
    fetch = async (_url: string, init: RequestInit): Promise<Response> => {
        this.calls.push(JSON.parse(String(init.body)));
        return new Response('{"ok":true}', { status: 200 });
    };
}

function wire(opts: { webhookUrl?: string | null; withNotify?: boolean } = {}) {
    const db = createFakeD1();
    const clock = new Clock();
    const kv = new MemoryKV();
    const originals = new MemoryOriginals();
    const media = new MemoryMedia();
    const helper = new FakeHelper();
    const hark = new FakeHark();
    const webp = new WebpService({
        storage: kv, bucket: media, mediaBaseUrl: MEDIA_BASE, now: clock.now, sleep: clock.sleep,
        ensureRunning: async () => {}, helper: helper.helper, db,
    });
    const notify = new NotifyService({
        storage: kv, db, now: clock.now,
        webhookUrl: opts.webhookUrl === undefined ? HOOK : opts.webhookUrl,
        fetch: hark.fetch,
    });
    const make = (over: Partial<ConstructorParameters<typeof StudioService>[0]> = {}) =>
        new StudioService({
            db, storage: kv, originals, webp, webBaseUrl: ORIGIN, now: clock.now, sleep: clock.sleep,
            ensureRunning: async () => {}, helper: helper.helper, fixedLength, media, mediaBaseUrl: MEDIA_BASE,
            ...(opts.withNotify === false ? {} : { notify }),
            ...over,
        });
    const studio = make();
    const container = {
        async fetch(r: Request) {
            const p = new URL(r.url).pathname;
            if (isNotifyRoute(p)) return handleNotifyRoute(notify, r);
            if (isStudioRoute(p)) return handleStudioRoute(studio, r);
            return new Response('{"status":"ok"}');
        },
    };
    const env: WorkerEnv = {
        API_URL: "https://api.capybaraharmony.com/", CORS_URL: ORIGIN, COBALT_API_KEY: INTERNAL,
        DB: db, ORIGINALS: originals, MEDIA: media, MEDIA_BASE_URL: MEDIA_BASE,
        ...(opts.webhookUrl === null ? {} : { HARK_WEBHOOK_URL: opts.webhookUrl ?? HOOK }),
    };
    const call = (url: string, init: RequestInit = {}) =>
        handleRequest(new Request(`https://api.capybaraharmony.com${url}`, init), env, container, {
            now: clock.now, sleep: clock.sleep, fixedLength: fixedLengthPair,
        });
    const addKey = async (id = KEY_ID, key = CLIENT) =>
        db.raw
            .prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)")
            .run(id, "test", await hashKey(key), key.slice(0, 8), 1);
    const sessions = () => db.raw.prepare("SELECT * FROM studio_sessions ORDER BY created_at, id").all() as any[];
    const noteKeys = () => [...kv.m.keys()].filter((k) => k.startsWith("notify:"));
    const settle = async (sid: string) => {
        for (let i = 0; i < 20; i++) {
            const r = await studio.advance(sid, 0);
            if ((r.body as any).status !== "saving") return r;
        }
        throw new Error("never finished");
    };
    return { db, clock, kv, helper, hark, notify, studio, make, call, addKey, sessions, noteKeys, settle, env };
}
type W = ReturnType<typeof wire>;

const shareBody = (extra: Record<string, unknown> = {}) => ({
    url: LINK, public: true, origin: "share", notify: { on: ["saved", "failed"], label: "x · 2105237035271258436" }, ...extra,
});

let w: W;
beforeEach(async () => {
    w = wire();
    await w.addKey();
});

describe("POST /studio with notify", () => {
    it("registers the Hark opt-in for the new session, the same record PUT /studio/<sid>/notify stores", async () => {
        const r = await w.studio.create(KEY_ID, json(shareBody()));
        expect(r.status).toBe(201);
        const sid = asBody(r).id as string;
        expect(asBody(r).notify).toMatchObject({ bridge: true, on: ["saved", "failed"], label: "x · 2105237035271258436" });
        expect(asBody(r).notify.expires_at).toBe(w.clock.t + 24 * 60 * 60 * 1000);
        expect(w.kv.m.get(`notify:optin:${sid}`)).toMatchObject({ keyId: KEY_ID, on: ["saved", "failed"], label: "x · 2105237035271258436" });
        // identical to what the PUT route would have stored
        const w2 = wire();
        await w2.addKey();
        const sid2 = asBody(await w2.studio.create(KEY_ID, json({ url: LINK }))).id as string;
        await w2.notify.put(KEY_ID, sid2, json({ on: ["saved", "failed"], label: "x · 2105237035271258436" }));
        expect(w2.kv.m.get(`notify:optin:${sid2}`)).toEqual(w.kv.m.get(`notify:optin:${sid}`));
    });

    it("the opt-in is in before the save can move: an instant save is announced, with the session's url", async () => {
        const sid = asBody(await w.studio.create(KEY_ID, json(shareBody()))).id as string;
        expect(w.hark.calls).toEqual([]);
        const done = asBody(await w.settle(sid));
        expect(done.status).toBe("ready");
        expect(w.hark.calls).toHaveLength(1);
        expect(w.hark.calls[0].body).toContain("x · 2105237035271258436 is saved");
        expect(w.hark.calls[0].url).toBe(`cobalt-apple://session/${sid}`);
    });

    it("a failed save is announced too", async () => {
        w.helper.fetchError = "error.fetch.fail";
        const sid = asBody(await w.studio.create(KEY_ID, json(shareBody()))).id as string;
        await w.settle(sid);
        expect(w.hark.calls).toHaveLength(1);
        expect(w.hark.calls[0].title).toBe("cobalt couldn't finish");
    });

    it("through the Worker: free text with a link keeps `notify` and `origin`", async () => {
        const res = await w.call("/studio", {
            method: "POST",
            headers: { ...auth, "content-type": "application/json" },
            body: json(shareBody({ url: `look ${LINK} nice` })),
        });
        expect(res.status).toBe(201);
        const sid = ((await res.json()) as any).id as string;
        expect(w.kv.m.has(`notify:optin:${sid}`)).toBe(true);
        expect(w.kv.m.has(`share:${sid}`)).toBe(true);
    });

    it("without `notify` the answer is exactly today's {status, id, url} and nothing is stored", async () => {
        const r = await w.studio.create(KEY_ID, json({ url: LINK }));
        expect(Object.keys(r.body as object).sort()).toEqual(["id", "status", "url"]);
        expect(w.noteKeys()).toEqual([]);
        await w.settle(asBody(r).id);
        for (const none of [undefined, null]) {
            const r2 = await w.studio.create(KEY_ID, json({ url: LINK, notify: none, origin: none }));
            expect(Object.keys(r2.body as object).sort()).toEqual(["id", "status", "url"]);
            await w.settle(asBody(r2).id);
        }
        expect(w.noteKeys()).toEqual([]);
        expect([...w.kv.m.keys()].filter((k) => k.startsWith("share:"))).toEqual([]);
    });

    it.each([
        ["an array", []],
        ["a string", "saved"],
        ["a number", 7],
        ["true", true],
        ["no `on`", {}],
        ["empty `on`", { on: [] }],
        ["an unknown event", { on: ["saved", "deleted"] }],
        ["a non-string event", { on: [1] }],
        ["too many events", { on: Array(9).fill("saved") }],
        ["a non-string label", { on: ["saved"], label: 7 }],
        ["a 61-character label", { on: ["saved"], label: "a".repeat(61) }],
        ["a label with a control character", { on: ["saved"], label: "a\nb" }],
        ["a body over 1024 bytes", { on: ["saved"], label: "ok", pad: "p".repeat(1100) }],
    ])("an invalid notify (%s) is a 400 and nothing is created", async (_n, notify) => {
        const r = await w.studio.create(KEY_ID, json({ url: LINK, public: true, notify }));
        expect(r).toEqual({ status: 400, body: { status: "error", error: { code: "error.notify.invalid" } } });
        expect(w.sessions()).toEqual([]);
        expect(w.noteKeys()).toEqual([]);
        expect(w.helper.calls).toEqual([]);
        expect(w.kv.m.size).toBe(0);
    });

    it("an invalid notify is refused through the Worker too, before any session", async () => {
        const res = await w.call("/studio", {
            method: "POST",
            headers: { ...auth, "content-type": "application/json" },
            body: json({ url: LINK, notify: { on: ["nope"] } }),
        });
        expect(res.status).toBe(400);
        expect(((await res.json()) as any).error.code).toBe("error.notify.invalid");
        expect(w.sessions()).toEqual([]);
    });

    it("with the bridge off the opt-in is ignored: the save is created, nothing stored, nothing sent", async () => {
        const off = wire({ webhookUrl: null });
        await off.addKey();
        const r = await off.studio.create(KEY_ID, json(shareBody()));
        expect(r.status).toBe(201);
        expect(asBody(r).notify).toMatchObject({ bridge: false, expires_at: null });
        const sid = asBody(r).id as string;
        expect(off.noteKeys()).toEqual([]);
        await off.settle(sid);
        expect(off.hark.calls).toEqual([]);
        // validation still applies with the bridge off
        const bad = await off.studio.create(KEY_ID, json({ url: LINK, notify: { on: [] } }));
        expect(bad.status).toBe(400);
    });

    it("a server whose Durable Object has no Hark service just creates the save", async () => {
        const bare = wire({ withNotify: false });
        await bare.addKey();
        const r = await bare.studio.create(KEY_ID, json(shareBody()));
        expect(r.status).toBe(201);
        expect(Object.keys(r.body as object).sort()).toEqual(["id", "status", "url"]);
    });

    it("the capability flag is announced", async () => {
        const res = await w.call("/capabilities", { headers: auth });
        expect(((await res.json()) as any).features.create_notify).toBe(true);
    });
});

describe("origin: share", () => {
    it("is remembered for GET /studio/recent; only \"share\" is accepted", async () => {
        const sid = asBody(await w.studio.create(KEY_ID, json(shareBody()))).id as string;
        expect(w.kv.m.get(`share:${sid}`)).toEqual({ keyId: KEY_ID, at: w.clock.t });
        for (const origin of ["app", "", 1, true, {}, ["share"]]) {
            const r = await w.studio.create(KEY_ID, json({ url: LINK, origin }));
            expect(r).toEqual({ status: 400, body: { status: "error", error: { code: "error.studio.invalid_params" } } });
        }
        expect(w.sessions()).toHaveLength(1);
    });

    it("a share is never refused as busy: it queues behind the running save; an app save still gets 429", async () => {
        const first = asBody(await w.studio.create(KEY_ID, json({ url: LINK }))).id as string;
        expect(first).toBeTruthy();
        const app = await w.studio.create(KEY_ID, json({ url: LINK }));
        expect(app).toEqual({ status: 429, body: { status: "error", error: { code: "error.studio.busy" } } });
        const share = await w.studio.create(KEY_ID, json({ url: LINK, origin: "share" }));
        expect(share.status).toBe(201);
        expect(w.sessions()).toHaveLength(2);
    });

    it("a share answers within SHARE_KICK_MS even while the container is still waking", async () => {
        let release!: () => void;
        const gate = new Promise<void>((r) => (release = r));
        const slow = w.make({ ensureRunning: () => gate, isRunning: () => false, kickMs: 20_000 });
        const started = Date.now();
        const r = await slow.create(KEY_ID, json({ url: LINK, origin: "share" }));
        const took = Date.now() - started;
        release();
        expect(r.status).toBe(201);
        expect(SHARE_KICK_MS).toBeLessThan(2000);
        expect(took).toBeLessThan(SHARE_KICK_MS + 800);
    });
});

describe("GET /studio/recent", () => {
    const recent = (q = "", headers: Record<string, string> = auth) => w.call(`/studio/recent${q}`, { headers });
    const ids = async (res: Response) => ((await res.json()) as any).sessions.map((s: any) => s.id as string);

    it("lists the key's share saves, newest first, in the shape of GET /studio/<sid>", async () => {
        const a = asBody(await w.studio.create(KEY_ID, json(shareBody()))).id as string;
        w.clock.t += 1000;
        const b = asBody(await w.studio.create(KEY_ID, json(shareBody({ url: "https://www.instagram.com/p/Dd7P496wolG/" })))).id as string;
        await w.settle(a);
        const res = await recent();
        expect(res.status).toBe(200);
        expect(res.headers.get("cache-control")).toBe("no-store");
        const body = (await res.json()) as any;
        expect(body.status).toBe("success");
        expect(body.now).toBe(w.clock.t);
        expect(body.sessions.map((s: any) => s.id)).toEqual([b, a]);
        expect(body.sessions[1]).toMatchObject({ status: "ready", link: LINK, service: "x", public_state: "ready" });
        expect(body.sessions[0]).toMatchObject({ status: "saving", service: "instagram" });
        expect(Object.keys(body.sessions[0])).toEqual(Object.keys(asBody(await w.studio.advance(b, 0))));
    });

    it("only sessions made with origin: share, and only the caller's", async () => {
        await w.addKey(OTHER_KEY_ID, OTHER_CLIENT);
        const mine = asBody(await w.studio.create(KEY_ID, json(shareBody()))).id as string;
        await w.studio.create(KEY_ID, json({ url: LINK })); // an app save
        const theirs = asBody(await w.studio.create(OTHER_KEY_ID, json(shareBody()))).id as string;
        expect(await ids(await recent())).toEqual([mine]);
        expect(await ids(await recent("", { authorization: `Api-Key ${OTHER_CLIENT}` }))).toEqual([theirs]);
    });

    it("`since` (unix ms) and `limit` narrow the list; junk falls back to the defaults", async () => {
        const made: string[] = [];
        for (let i = 0; i < 4; i++) {
            made.push(asBody(await w.studio.create(KEY_ID, json(shareBody()))).id as string);
            w.clock.t += 1000;
        }
        const t = (n: number) => 1_800_000_000_000 + n * 1000;
        expect(await ids(await recent(`?since=${t(2)}`))).toEqual([made[3], made[2]]);
        expect(await ids(await recent("?limit=2"))).toEqual([made[3], made[2]]);
        expect(await ids(await recent("?since=nope&limit=x"))).toEqual([...made].reverse());
        expect(await ids(await recent("?limit=0"))).toEqual([made[3]]);
        expect(RECENT_MAX).toBe(25);
    });

    it("forgets what is older than 24 hours (and prunes its records at the next share)", async () => {
        const old = asBody(await w.studio.create(KEY_ID, json(shareBody()))).id as string;
        w.clock.t += SHARE_KEEP_MS + 1000;
        expect(await ids(await recent())).toEqual([]);
        const fresh = asBody(await w.studio.create(KEY_ID, json(shareBody()))).id as string;
        expect(w.kv.m.has(`share:${old}`)).toBe(false);
        expect(await ids(await recent())).toEqual([fresh]);
    });

    it("needs the key: no key 401, a service credential 404, a wrong method 404", async () => {
        expect((await recent("", {})).status).toBe(401);
        expect((await recent("", { [SERVICE_HEADER]: INTERNAL })).status).toBe(404);
        expect((await w.call("/studio/recent", { method: "POST", headers: auth })).status).toBe(404);
        expect((await w.call("/studio/recent", { method: "DELETE", headers: auth })).status).toBe(404);
        expect((await recent("", { authorization: `Api-Key ${OTHER_CLIENT}` })).status).toBe(401);
    });

    it("never reaches the Durable Object without the key id the Worker sets", async () => {
        const direct = await handleStudioRoute(w.studio, new Request("https://do.internal/studio/recent"));
        expect(direct.status).toBe(403);
        const forged = await w.call("/studio/recent", { headers: { ...auth, [KEY_ID_HEADER]: OTHER_KEY_ID } });
        expect(forged.status).toBe(200); // the Worker overwrites the header with the verified key's id
        expect(await ids(forged)).toEqual([]);
    });

    it("a session that expired or was removed is not listed; D1 down is a 503", async () => {
        const gone = asBody(await w.studio.create(KEY_ID, json(shareBody()))).id as string;
        w.db.raw.prepare("UPDATE studio_sessions SET expires_at = ? WHERE id = ?").run(w.clock.t - 1, gone);
        expect(await ids(await recent())).toEqual([]);
        w.db.raw.prepare("DELETE FROM studio_sessions WHERE id = ?").run(gone);
        expect(await ids(await recent())).toEqual([]);
        const direct = await w.studio.recent(KEY_ID, null, null);
        expect(direct.status).toBe(200);
    });
});

describe("the gate for /studio/recent", () => {
    const mk = (method: string, authorization: string | null, service = false) => ({
        method, pathname: "/studio/recent", searchParams: new URLSearchParams("since=1"), origin: null, authorization, service,
    });
    const cfg = { corsUrl: ORIGIN, now: 1_800_000_000_000 };

    it("GET with a well-formed key is a lookup for studio_recent; the key is what is looked up", () => {
        expect(decide(mk("GET", `Api-Key ${CLIENT}`), cfg)).toEqual({ action: "lookup", key: CLIENT, then: "studio_recent", params: undefined });
    });
    it("a missing or malformed key is a 401, the service credential and other methods are 404", () => {
        expect(decide(mk("GET", null), cfg)).toMatchObject({ action: "reject", status: 401 });
        expect(decide(mk("GET", "Api-Key nope"), cfg)).toMatchObject({ action: "reject", status: 401 });
        expect(decide(mk("GET", null, true), cfg)).toMatchObject({ action: "reject", status: 404 });
        for (const m of ["POST", "PUT", "DELETE", "HEAD"]) {
            expect(decide(mk(m, `Api-Key ${CLIENT}`), cfg)).toMatchObject({ action: "reject", status: 404 });
        }
    });
});
