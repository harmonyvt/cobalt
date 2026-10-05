// "Public by default" (APP-API-CONTRACT.md section 13): `public: true` on POST /studio and
// `?public=1` on PUT /studio/upload make the server host the original publicly once the save is
// ready, through the SAME code as POST /studio/<sid>/publish; without the flag nothing changes.
// The Worker, the Durable Object's services and the real SQL run together; the helper and both
// R2 buckets are fakes.
import { beforeEach, describe, expect, it } from "vitest";
import { MAX_PUBLIC_ATTEMPTS, SESSION_TTL_MS } from "../src/studio";
import { HOST_URL, KEY_ID, LINK, MEDIA_BASE, POSTER_URL, asBody, auth, json, world, type World } from "./poster-world";

const publicRecords = (w: World) => [...w.kv.m.keys()].filter((k) => k.startsWith("public:"));
const hostRows = (w: World) => w.items().filter((i) => i.source === "host");

let w: World;
beforeEach(async () => {
    w = world();
    await w.addKey();
});

describe("POST /studio with public: true", () => {
    const create = async (body: unknown = { url: LINK, public: true }) => w.studio.create(KEY_ID, json(body));

    it("the response is exactly today's {status, id, url}; the row remembers the request as 'pending'", async () => {
        const r = await create();
        expect(r.status).toBe(201);
        expect(Object.keys(r.body as object).sort()).toEqual(["id", "status", "url"]);
        const sid = asBody(r).id as string;
        expect(w.session(sid)).toMatchObject({ status: "saving", public_state: "pending", public_url: null });
        expect(hostRows(w)).toEqual([]); // nothing is hosted before the save is ready
        const saving = asBody(await w.studio.advance(sid, 0));
        expect(saving.public_state === "pending" || saving.status === "ready").toBe(true);
    });

    it("when the save is ready the original is hosted: a public copy under a 10-char name, a `host` row, the session and its answer carry the URL", async () => {
        const sid = asBody(await create()).id as string;
        const done = asBody(await w.settle(sid));
        // the very answer that reports ready already has the URL (the copy ran before it was sent)
        expect(done).toMatchObject({ status: "ready", public_state: "ready" });
        expect(done.public_url).toMatch(HOST_URL);

        const host = hostRows(w);
        expect(host).toHaveLength(1);
        const name = host[0].r2_key as string;
        expect(name).toMatch(/^[A-Za-z0-9]{10}\.mp4$/);
        expect(done.public_url).toBe(`${MEDIA_BASE}${name}`);
        expect(host[0]).toMatchObject({
            kind: "public",
            source: "host",
            bucket: "media",
            url: `${MEDIA_BASE}${name}`,
            content_type: "video/mp4",
            bytes: w.helper.videoBytes.length,
            width: 480,
            height: 560,
            link: LINK,
            session_id: sid,
            key_id: KEY_ID,
            deleted_at: null,
        });
        expect(w.media.objects.get(name)).toMatchObject({
            contentType: "video/mp4",
            cacheControl: "public, max-age=31536000, immutable",
            viaStream: true,
            meta: { keyId: KEY_ID, sessionId: sid, source: LINK, published: "1" },
        });
        expect(w.media.objects.get(name)!.data).toEqual(w.helper.videoBytes);
        // the private original is still there, and still the original
        expect(w.originals.objects.has(w.session(sid).r2_key)).toBe(true);
        expect(w.items().filter((i) => i.source === "saved")).toHaveLength(1);
        expect(w.session(sid)).toMatchObject({ public_state: "ready", public_url: `${MEDIA_BASE}${name}` });
        expect(publicRecords(w)).toEqual([]);
        // GET /studio/<sid> says it too
        const get = (await (await w.call(`/studio/${sid}`)).json()) as any;
        expect(get).toMatchObject({ public_state: "ready", public_url: `${MEDIA_BASE}${name}` });
    });

    it("the helper and the save record are already free while the public copy runs (it cannot hold up the next save)", async () => {
        const sid = asBody(await create()).id as string;
        let release!: () => void;
        const gate = new Promise<void>((r) => (release = r));
        let started = 0;
        const put = w.media.put.bind(w.media);
        w.media.put = (async (...a: Parameters<typeof put>) => {
            started++;
            await gate;
            return put(...a);
        }) as typeof w.media.put;
        const running = w.settle(sid);
        for (let i = 0; i < 500 && started === 0; i++) await new Promise((r) => setTimeout(r, 1));
        expect(started).toBe(1);
        expect(w.session(sid).status).toBe("ready"); // ready is recorded before the copy
        expect(w.kv.m.has(`save:${sid}`)).toBe(false);
        expect(w.helper.calls).toContain(`DELETE /fetch/${sid}`);
        release();
        expect(asBody(await running)).toMatchObject({ status: "ready", public_state: "ready" });
    });

    it("the hosted copy is what POST /studio/<sid>/publish makes: same name shape, same row, same object metadata", async () => {
        const viaFlag = asBody(await create()).id as string;
        await w.settle(viaFlag);
        const manual = asBody(await w.studio.create(KEY_ID, json({ url: LINK }))).id as string;
        await w.settle(manual);
        const pub = await w.call(`/studio/${manual}/publish`, { method: "POST", headers: auth });
        expect(pub.status).toBe(201);

        const rowOf = (sid: string) => hostRows(w).find((r) => r.session_id === sid)!;
        const shape = (r: any) => ({ ...r, id: "-", r2_key: "-", url: "-", name: "-", session_id: "-", created_at: 0 });
        expect(shape(rowOf(viaFlag))).toEqual(shape(rowOf(manual)));
        const meta = (sid: string) => w.media.objects.get(rowOf(sid).r2_key)!;
        expect(Object.keys(meta(viaFlag).meta).sort()).toEqual(Object.keys(meta(manual).meta).sort());
        expect(meta(viaFlag).cacheControl).toBe(meta(manual).cacheControl);
        expect(meta(viaFlag).contentType).toBe(meta(manual).contentType);
    });

    it("no flag, false and null are today's behaviour: nothing hosted, no record, no public fields set", async () => {
        for (const body of [{ url: LINK }, { url: LINK, public: false }, { url: LINK, public: null }]) {
            const sid = asBody(await create(body)).id as string;
            expect(w.session(sid)).toMatchObject({ public_state: null, public_url: null });
            const done = asBody(await w.settle(sid));
            expect(done).toMatchObject({ status: "ready", public_state: null, public_url: null });
        }
        expect(hostRows(w)).toEqual([]);
        expect([...w.media.objects.keys()].filter((k) => !k.endsWith(".jpg"))).toEqual([]);
        expect(publicRecords(w)).toEqual([]);
        expect(w.media.puts).toEqual([]);
    });

    it.each([["yes"], ["true"], [1], [{}], [[]]])("public: %j is refused (400 error.studio.invalid_params) and nothing is created", async (v) => {
        const r = await create({ url: LINK, public: v });
        expect(r).toEqual({ status: 400, body: { status: "error", error: { code: "error.studio.invalid_params" } } });
        expect(w.db.raw.prepare("SELECT count(*) AS n FROM studio_sessions").get()).toEqual({ n: 0 });
        expect(w.helper.calls).toEqual([]);
    });

    it("through the Worker: free text with a link and public: true is normalised and the flag survives", async () => {
        const res = await w.call("/studio", {
            method: "POST",
            headers: { ...auth, "content-type": "application/json" },
            body: json({ url: `look ${LINK} nice`, public: true }),
        });
        expect(res.status).toBe(201);
        const { id } = (await res.json()) as any;
        expect(w.session(id)).toMatchObject({ link: LINK, public_state: "pending" });
        await w.settle(id);
        expect(w.session(id).public_state).toBe("ready");
    });

    it("a save that fails ends with no public state (nothing to host)", async () => {
        w.helper.fetchError = "error.api.fetch.fail";
        const sid = asBody(await create()).id as string;
        const done = asBody(await w.settle(sid));
        expect(done).toMatchObject({ status: "error", public_state: null, public_url: null });
        expect(hostRows(w)).toEqual([]);
    });

    it("the library carries it: the post's files include the public copy, the post says public_url, and the poster is shared", async () => {
        const sid = asBody(await create()).id as string;
        await w.settle(sid);
        await w.studio.sweep(); // the poster
        const b = (await (await w.call("/library", { headers: auth })).json()) as any;
        expect(b.posts).toHaveLength(1);
        const post = b.posts[0];
        const host = post.files.find((f: any) => f.source === "host");
        expect(host).toMatchObject({ kind: "public", content_type: "video/mp4", deletable: false });
        expect(host.url).toMatch(HOST_URL);
        expect(post.public_url).toBe(host.url);
        expect(post.poster_url).toMatch(POSTER_URL);
        expect(host.poster_url).toBe(post.poster_url);
        expect(post.files.find((f: any) => f.source === "saved").poster_url).toBe(post.poster_url);
        expect(b.counts).toEqual({ posts: 1, files: 2 });
    });
});

describe("when the copy does not go through", () => {
    it("a public bucket that refuses: the save stays ready, the sweep retries, and after MAX_PUBLIC_ATTEMPTS the state is 'failed' with the original still private", async () => {
        w.media.failPut = true;
        const sid = asBody(await w.studio.create(KEY_ID, json({ url: LINK, public: true }))).id as string;
        const done = asBody(await w.settle(sid));
        expect(done).toMatchObject({ status: "ready", public_state: "pending", public_url: null });
        expect(await w.kv.get(`public:${sid}`)).toMatchObject({ attempts: 1 });
        expect(w.sweepsArmed()).toBeGreaterThan(0);
        expect(hostRows(w)).toEqual([]);

        for (let i = 2; i <= MAX_PUBLIC_ATTEMPTS; i++) {
            const r = await w.studio.sweep();
            expect(r.pending).toBeGreaterThanOrEqual(1);
            expect(await w.kv.get(`public:${sid}`)).toMatchObject({ attempts: i });
        }
        await w.studio.sweep(); // one more: out of attempts
        expect(w.session(sid)).toMatchObject({ status: "ready", public_state: "failed", public_url: null });
        expect(publicRecords(w)).toEqual([]);
        expect(hostRows(w)).toEqual([]);
        expect(w.originals.objects.has(w.session(sid).r2_key)).toBe(true);
        expect(asBody(await w.studio.advance(sid, 0))).toMatchObject({ status: "ready", public_state: "failed" });
        // the owner can still host it by hand
        w.media.failPut = false;
        expect((await w.call(`/studio/${sid}/publish`, { method: "POST", headers: auth })).status).toBe(201);
    });

    it("an outage that ends before the attempts run out: the sweep finishes the job", async () => {
        w.media.failPut = true;
        const sid = asBody(await w.studio.create(KEY_ID, json({ url: LINK, public: true }))).id as string;
        await w.settle(sid);
        expect(w.session(sid).public_state).toBe("pending");
        w.media.failPut = false;
        const r = await w.studio.sweep();
        expect(w.session(sid)).toMatchObject({ public_state: "ready", public_url: expect.stringMatching(HOST_URL) });
        expect(hostRows(w)).toHaveLength(1);
        expect(publicRecords(w)).toEqual([]);
        // the same pass also made the poster, so nothing is left
        expect(r.pending).toBe(0);
        expect(w.posters()).toHaveLength(1);
    });

    it("an attempt that never ran (the Durable Object was evicted after 'ready'): the record is enough, the sweep hosts it", async () => {
        const { sid } = w.seed();
        w.db.raw.prepare("UPDATE studio_sessions SET public_state = 'pending' WHERE id = ?").run(sid);
        w.kv.m.set(`public:${sid}`, { attempts: 0, at: w.clock.t });
        const r = await w.studio.sweep();
        expect(w.session(sid)).toMatchObject({ public_state: "ready", public_url: expect.stringMatching(HOST_URL) });
        expect(r.pending).toBe(0);
    });

    it("idempotent: a session that is already hosted (an earlier attempt died before recording it) records the existing copy and copies nothing", async () => {
        const { sid } = w.seed();
        w.db.raw.prepare("UPDATE studio_sessions SET public_state = 'pending' WHERE id = ?").run(sid);
        w.db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, session_id, created_at) VALUES ('HostItem00000001','public','host','media','Hostmp4001.mp4',?,'a.mp4','video/mp4',?,?)",
            )
            .run(`${MEDIA_BASE}Hostmp4001.mp4`, sid, w.clock.t);
        w.kv.m.set(`public:${sid}`, { attempts: 1, at: w.clock.t });
        await w.studio.sweep();
        expect(w.session(sid)).toMatchObject({ public_state: "ready", public_url: `${MEDIA_BASE}Hostmp4001.mp4` });
        expect(w.media.puts).toEqual([]);
        expect(hostRows(w)).toHaveLength(1);
    });

    it("a session that expired or vanished before it could be hosted is 'failed', not retried for ever", async () => {
        const { sid } = w.seed({ expires_at: 1 });
        w.db.raw.prepare("UPDATE studio_sessions SET public_state = 'pending' WHERE id = ?").run(sid);
        w.kv.m.set(`public:${sid}`, { attempts: 0, at: w.clock.t });
        w.kv.m.set("public:" + "Z".repeat(22), { attempts: 0, at: w.clock.t }); // no such session
        await w.studio.sweep();
        expect(w.session(sid).public_state).toBe("failed");
        expect(publicRecords(w)).toEqual([]);
    });

    it("without the public bucket wired the save still succeeds and says 'failed'", async () => {
        const bare = world({ media: false });
        const sid = asBody(await bare.studio.create(KEY_ID, json({ url: LINK, public: true }))).id as string;
        const done = asBody(await bare.settle(sid));
        expect(done).toMatchObject({ status: "ready", public_state: "failed", public_url: null });
    });
});

describe("PUT /studio/upload?public=1", () => {
    const put = (type: string, name: string, query = "public=1", data = new Uint8Array(4096).fill(3)) =>
        w.call(`/studio/upload?name=${encodeURIComponent(name)}${query ? `&${query}` : ""}`, {
            method: "PUT",
            headers: { ...auth, "content-type": type, "content-length": String(data.byteLength) },
            body: data as unknown as BodyInit,
        });

    describe("a video", () => {
        it("201 with public_state 'pending'; the Durable Object hosts it when the session is ready (the same adopt path as without the flag)", async () => {
            const res = await put("video/quicktime", "IMG_0412.mov");
            expect(res.status).toBe(201);
            const b = (await res.json()) as any;
            expect(b).toMatchObject({ status: "success", studio_error: null, public_state: "pending", public_url: null });
            expect(b.id).toMatch(/^[A-Za-z0-9]{22}$/);
            expect(w.session(b.id)).toMatchObject({ public_state: "pending" });
            expect(hostRows(w)).toEqual([]);

            const done = asBody(await w.settle(b.id));
            expect(done).toMatchObject({ status: "ready", public_state: "ready" });
            expect(done.public_url).toMatch(/^https:\/\/media\.capybaraharmony\.com\/[A-Za-z0-9]{10}\.mov$/);
            const host = hostRows(w);
            expect(host).toHaveLength(1);
            expect(host[0]).toMatchObject({ kind: "public", content_type: "video/quicktime", session_id: b.id, key_id: KEY_ID, name: "IMG_0412.mov" });
            // the upload's own private item is untouched
            expect(w.items().filter((i) => i.source === "upload")).toHaveLength(1);
        });

        it("public=true is the same; public=0, public=false, an empty value and no flag are today's behaviour", async () => {
            const t = (await (await put("video/mp4", "a.mp4", "public=true")).json()) as any;
            expect(t.public_state).toBe("pending");
            for (const q of ["public=0", "public=false", "public=", ""]) {
                w.kv.m.clear();
                const b = (await (await put("video/mp4", "a.mp4", q)).json()) as any;
                expect(b).toMatchObject({ public_state: null, public_url: null });
                expect(w.session(b.id).public_state).toBeNull();
            }
        });

        it("the poster of the upload is made too, and shared with the public copy", async () => {
            const b = (await (await put("video/mp4", "clip.mp4")).json()) as any;
            await w.settle(b.id);
            await w.studio.sweep();
            const upload = w.items().find((i) => i.source === "upload")!;
            expect(upload.poster).toMatch(POSTER_URL);
            expect(hostRows(w)[0].poster).toBe(upload.poster);
            expect(w.session(b.id).poster).toBe(upload.poster);
        });

        it("when the session is refused (a save is running) the file is hosted right away by the library's own publish, still 201", async () => {
            w.kv.m.set("save:other", { phase: "fetching", startedAt: w.clock.t, attempts: 1, lastAdvance: w.clock.t });
            const res = await put("video/mp4", "clip.mp4");
            expect(res.status).toBe(201);
            const b = (await res.json()) as any;
            expect(b).toMatchObject({ id: null, url: null, studio_error: { code: "error.studio.busy" }, public_state: "ready" });
            expect(b.public_url).toMatch(HOST_URL);
            expect(hostRows(w)).toHaveLength(1);
            expect(hostRows(w)[0]).toMatchObject({ session_id: null, key_id: KEY_ID });
        });
    });

    describe("an image", () => {
        it.each([
            ["image/png", "png"],
            ["image/jpeg", "jpg"],
            ["image/webp", "webp"],
            ["image/heic", "heic"],
        ])("%s is hosted as it is, at once: public_state 'ready' with the URL, no session, the container untouched", async (type, ext) => {
            const res = await put(type, `photo.${ext}`);
            expect(res.status).toBe(201);
            const b = (await res.json()) as any;
            expect(b).toMatchObject({ id: null, url: null, studio_error: null, public_state: "ready" });
            expect(b.public_url).toMatch(new RegExp(`^https://media\\.capybaraharmony\\.com/[A-Za-z0-9]{10}\\.${ext}$`));
            expect(hostRows(w)).toHaveLength(1);
            expect(w.media.objects.size).toBe(1);
            expect(w.seen).toHaveLength(0);
            expect(w.items().filter((i) => i.source === "upload")).toHaveLength(1);
        });
        it("a public bucket that refuses leaves the private upload stored and says 'failed' (201)", async () => {
            w.media.failPut = true;
            const res = await put("image/png", "photo.png");
            expect(res.status).toBe(201);
            expect(await res.json()).toMatchObject({ public_state: "failed", public_url: null, item: { kind: "private" } });
            expect(hostRows(w)).toEqual([]);
        });
        it("without the flag nothing is hosted and both fields are null", async () => {
            const b = (await (await put("image/png", "photo.png", "")).json()) as any;
            expect(b).toMatchObject({ public_state: null, public_url: null });
            expect(hostRows(w)).toEqual([]);
            expect(w.media.objects.size).toBe(0);
        });
    });

    it("an unknown public value is refused before the body is read (400 error.library.bad_request) and nothing is stored", async () => {
        const res = await put("video/mp4", "a.mp4", "public=maybe");
        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({ status: "error", error: { code: "error.library.bad_request" } });
        expect(w.items()).toEqual([]);
        expect(w.originals.objects.size).toBe(0);
        expect(w.db.raw.prepare("SELECT count(*) AS n FROM studio_sessions").get()).toEqual({ n: 0 });
    });
});

describe("the contract's invariants", () => {
    it("a session is 7 days from creation whether or not it asked for public (the lifetime is not changed)", async () => {
        const sid = asBody(await w.studio.create(KEY_ID, json({ url: LINK, public: true }))).id as string;
        expect(w.session(sid).expires_at - w.session(sid).created_at).toBe(SESSION_TTL_MS);
    });
});
