// Direct media links, the API half (APP-API-CONTRACT.md section 19): a pasted link to a file that cobalt has no service
// for is saved by the helper as ONE file, and the Worker and the Durable Object treat the result exactly like a single
// photo or video save. The Worker, the real StudioService with the real NotifyService and the real SQL run together;
// the helper (in its direct-link answer), both R2 buckets and the Hark webhook are fakes. The helper's own rule is in
// direct-links.test.ts.
import { beforeEach, describe, expect, it } from "vitest";
import { handleRequest } from "../src/worker";
import { NotifyService, handleNotifyRoute, isNotifyRoute } from "../src/notify";
import { handleStudioRoute, isStudioRoute } from "../src/studio";
import { fixedLengthPair } from "./studio-fakes";
import { CLIENT, KEY_ID, auth, asBody, json, world, type World } from "./poster-world";

const HOOK = "https://hark.example/api/webhook/T0pS3cretHookToken";
// What the owner pastes: a Discord CDN attachment, with its signed query
const DISCORD =
    "https://cdn.discordapp.com/attachments/1425871290003177532/1425871327433318440/LiaPoor.png?ex=68f12b7a&is=68efd9fa&hm=9c1a5e3f7b0d4a62c8e1f4d3b2a09f8e7d6c5b4a39281706f5e4d3c2b1a09f8e&";
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...new Array(1600).fill(3)]);
const THUMB = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, ...new Array(60).fill(9)]);
const SAVED_PNG = { contentType: "image/png", ext: "png", duration: null, width: 1024, height: 768, title: "LiaPoor", service: "discordapp", picker_count: null, direct: true };

class FakeHark {
    calls: { title: string; body: string; url?: string }[] = [];
    fetch = async (_url: string, init: RequestInit): Promise<Response> => {
        this.calls.push(JSON.parse(String(init.body)));
        return new Response('{"ok":true}', { status: 200 });
    };
}

let w: World;
let hark: FakeHark;
let studio: ReturnType<World["make"]>;
let call: (url: string, init?: RequestInit) => Promise<Response>;

const post = (body: unknown, headers: Record<string, string> = auth) =>
    call("/studio", { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: json(body) });
const settle = async (sid: string) => {
    for (let i = 0; i < 20; i++) {
        const r = await studio.advance(sid, 0);
        if ((r.body as any).status !== "saving") return r;
    }
    throw new Error("never finished");
};
const library = async () => (await (await call("/library?v=3", { headers: auth })).json()) as any;

beforeEach(async () => {
    w = world();
    await w.addKey();
    hark = new FakeHark();
    const notify = new NotifyService({ storage: w.kv, db: w.db, now: w.clock.now, webhookUrl: HOOK, fetch: hark.fetch });
    studio = w.make({ notify });
    const container = {
        async fetch(r: Request) {
            const p = new URL(r.url).pathname;
            if (isNotifyRoute(p)) return handleNotifyRoute(notify, r);
            if (isStudioRoute(p)) return handleStudioRoute(studio, r);
            return new Response('{"status":"ok"}', { headers: { "content-type": "application/json" } });
        },
    };
    call = (url, init = {}) =>
        handleRequest(new Request(`https://api.capybaraharmony.com${url}`, init), w.env, container, {
            now: w.clock.now,
            sleep: w.clock.sleep,
            fixedLength: fixedLengthPair,
        });
    w.helper.videoBytes = PNG;
    w.helper.singleThumb = THUMB;
    w.helper.fetchDone = SAVED_PNG;
});

describe("a pasted Discord attachment link through POST /studio", () => {
    it("is saved as one photo, exactly like a single-photo save: the same rows, a poster from the thumb, public by default", async () => {
        const res = await post({ url: DISCORD, public: true, origin: "share", notify: { on: ["saved", "failed"], label: "discord · LiaPoor" } });
        expect(res.status).toBe(201);
        const sid = ((await res.json()) as any).id as string;

        // the helper was asked for the link whole, signed query and all (the Worker's link extraction keeps it)
        expect(w.helper.fetchBodies).toHaveLength(1);
        expect(w.helper.fetchBodies[0]).toMatchObject({ id: sid, url: DISCORD });

        const done = asBody(await settle(sid));
        expect(done).toMatchObject({ status: "ready", width: 1024, height: 768, duration: null, title: "LiaPoor", service: "discordapp" });
        expect(done).not.toHaveProperty("items"); // a single file reads as it always did
        expect(done).not.toHaveProperty("item_count");

        expect(w.session(sid)).toMatchObject({
            status: "ready", link: DISCORD.split("?")[0], service: "discordapp", title: "LiaPoor", r2_key: `originals/${sid}.png`,
            content_type: "image/png", duration: null, width: 1024, height: 768,
        });
        const rows = w.items();
        expect(rows).toHaveLength(1);
        expect(rows[0]).toMatchObject({
            source: "saved", bucket: "originals", r2_key: `originals/${sid}.png`, content_type: "image/png", duration: null,
            role: null, item_index: null, post_key: null, width: 1024, height: 768, session_id: sid, link: DISCORD.split("?")[0],
        });
        expect(rows[0].poster).toMatch(/^https:\/\/media\.capybaraharmony\.com\/[A-Za-z0-9]{10}\.jpg$/);
        expect(w.originals.objects.get(`originals/${sid}.png`)!.bytes).toEqual(PNG);
        expect(w.originals.objects.get(`originals/${sid}.png`)!.contentType).toBe("image/png");
        // public by default (section 13): the original is hosted when the save is ready
        expect(done.public_state).toBe("ready");
        expect(done.public_url).toMatch(/^https:\/\/media\.capybaraharmony\.com\/[A-Za-z0-9]{10}\.png$/);
    });

    it("shows up in the library as a single photo post titled from the file name", async () => {
        const sid = ((await (await post({ url: DISCORD })).json()) as any).id as string;
        await settle(sid);
        const lib = await library();
        expect(lib.posts).toHaveLength(1);
        const post1 = lib.posts[0];
        expect(post1).toMatchObject({ id: sid, kind: "photo", title: "LiaPoor", service: "discordapp", link: DISCORD.split("?")[0] });
        expect(post1.files).toHaveLength(1);
        expect(post1.files[0]).toMatchObject({ content_type: "image/png", width: 1024, height: 768, source: "saved" });
    });

    it("announces the save once, without the link or its token", async () => {
        const sid = ((await (await post({ url: DISCORD, notify: { on: ["saved", "failed"], label: "discord · LiaPoor" } })).json()) as any).id as string;
        await settle(sid);
        expect(hark.calls).toHaveLength(1);
        expect(hark.calls[0]!.body).toContain("discord · LiaPoor is saved");
        expect(hark.calls[0]!.url).toBe(`cobalt-apple://session/${sid}`);
        expect(JSON.stringify(hark.calls)).not.toMatch(/hm=|9c1a5e3f|cdn\.discordapp/);
    });

    it("a video link is a single video save (duration, no thumb path)", async () => {
        w.helper.fetchDone = { contentType: "video/mp4", ext: "mp4", duration: 12.4, width: 1280, height: 720, title: "clip", service: "example", picker_count: null, direct: true };
        w.helper.videoBytes = new Uint8Array(8192).fill(5);
        w.helper.singleThumb = null;
        const sid = ((await (await post({ url: "https://files.example.com/clips/clip.mp4?sig=abc" })).json()) as any).id as string;
        const done = asBody(await settle(sid));
        expect(done).toMatchObject({ status: "ready", duration: 12.4, width: 1280, height: 720, title: "clip", service: "example" });
        expect(w.items()).toHaveLength(1);
        expect(w.items()[0]).toMatchObject({ content_type: "video/mp4", r2_key: `originals/${sid}.mp4`, duration: 12.4, role: null });
    });

    it("`items: \"all\"` from a client that always asks for the whole post is still one file", async () => {
        const sid = ((await (await post({ url: DISCORD, items: "all" })).json()) as any).id as string;
        await settle(sid);
        expect(w.helper.fetchBodies[0]).toMatchObject({ items: "all" });
        expect(w.items()).toHaveLength(1);
        expect(w.items()[0]!.item_index).toBeNull();
    });

    it("a link the helper cannot use as a file ends with cobalt's own error, which the opt-in announces as a failure", async () => {
        w.helper.fetchError = "error.api.link.invalid";
        const sid = ((await (await post({ url: DISCORD, notify: { on: ["saved", "failed"], label: "discord · LiaPoor" } })).json()) as any).id as string;
        const done = asBody(await settle(sid));
        expect(done).toMatchObject({ status: "error", error: { code: "error.api.link.invalid" } });
        expect(w.items()).toEqual([]);
        expect(hark.calls).toHaveLength(1);
        expect(hark.calls[0]!.title).toBe("cobalt couldn't finish");
        expect(JSON.stringify(hark.calls)).not.toMatch(/hm=|9c1a5e3f/);
    });

    it("an oversize file is the studio's too-large error", async () => {
        w.helper.fetchError = "error.studio.too_large";
        const sid = ((await (await post({ url: DISCORD })).json()) as any).id as string;
        expect(asBody(await settle(sid))).toMatchObject({ status: "error", error: { code: "error.studio.too_large" } });
    });
});

describe("the request log never keeps a signed link's query", () => {
    it("url_prefix is cut at the `?`, whatever the length", async () => {
        const short = "https://cdn.discordapp.com/a/b.png?ex=1&hm=SECRETTOKEN";
        const res = await post({ url: short });
        expect(res.status).toBe(201);
        await post({ url: DISCORD });
        await post({ url: `https://example.com/photo.jpg#frag=SECRETFRAG` });
        const rows = w.db.raw.prepare("SELECT url_prefix, url_len FROM request_log WHERE route = 'POST /studio' ORDER BY ts, rowid").all() as any[];
        expect(rows).toHaveLength(3);
        expect(rows[0]).toEqual({ url_prefix: "https://cdn.discordapp.com/a/b.png", url_len: short.length });
        expect(rows[1].url_prefix).toBe(DISCORD.split("?")[0]!.slice(0, 80));
        expect(rows[2].url_prefix).toBe("https://example.com/photo.jpg");
        expect(JSON.stringify(rows)).not.toMatch(/SECRET|hm=|ex=/);
    });
});

describe("GET /capabilities: features.direct_links follows the helper's own header", () => {
    const features = async () => (((await (await call("/capabilities", { headers: auth })).json()) as any).features) as Record<string, unknown>;

    it("is false until the helper has said direct=1, then true", async () => {
        expect((await features()).direct_links).toBe(false);
        await settle(((await (await post({ url: DISCORD })).json()) as any).id);
        expect(await features()).toMatchObject({ direct_links: true, gallery: true, gallery_make: true });
    });

    it("stays false for a helper image that predates it (gallery and make unaffected)", async () => {
        w.helper.directs = false;
        await settle(((await (await post({ url: DISCORD })).json()) as any).id);
        expect(await features()).toMatchObject({ direct_links: false, gallery: true, gallery_make: true });
    });

    it("and for one that says nothing at all", async () => {
        w.helper.advertise = false;
        await settle(((await (await post({ url: DISCORD })).json()) as any).id);
        expect(await features()).toMatchObject({ direct_links: false, gallery: false });
    });

    it("the Durable Object keeps it across a restart (storage), like gallery and make", async () => {
        await settle(((await (await post({ url: DISCORD })).json()) as any).id);
        const fresh = w.make({});
        const body = (await fresh.helperCaps()).body as any;
        expect(body).toMatchObject({ gallery: true, make: true, direct: true });
        w.helper.directs = false;
        await settle(((await (await post({ url: DISCORD })).json()) as any).id);
        expect(((await w.make({}).helperCaps()).body as any).direct).toBe(false);
    });
});

// the key never reaches the helper's fetch (the Worker strips it; the helper has its own internal key)
describe("what the Durable Object hands the helper", () => {
    it("is the link and the options, never the client's API key", async () => {
        await post({ url: DISCORD });
        expect(JSON.stringify(w.helper.fetchBodies)).not.toContain(CLIENT);
        expect(Object.keys(w.helper.fetchBodies[0]!).sort()).toEqual(["id", "url"]);
        expect(KEY_ID).toBeTruthy();
    });
});

// S3: the signed query is a credential. It is needed to FETCH and nowhere after.
describe("a direct link's signed query is kept nowhere past the save", () => {
    const SECRET = /hm=|9c1a5e3f|ex=68f12b7a|is=68efd9fa/;
    const BARE = "https://cdn.discordapp.com/attachments/1425871290003177532/1425871327433318440/LiaPoor.png";
    const everything = (sid: string) => ({
        session: w.session(sid),
        items: w.items(),
        privateMeta: w.originals.objects.get(`originals/${sid}.png`)?.meta,
        publicMeta: [...w.media.objects.entries()].filter(([k]) => !k.endsWith(".jpg")).map(([k, o]: [string, any]) => [k, o.meta]),
    });

    it("the helper gets the full link while the save runs; once ready the session, the library row and both R2 objects hold it bare", async () => {
        const sid = ((await (await post({ url: DISCORD, public: true })).json()) as any).id as string;
        expect(w.session(sid).link).toBe(DISCORD); // saving: the fetch (and a restart of it) needs the whole link
        expect(w.helper.fetchBodies[0]).toMatchObject({ url: DISCORD });
        const done = asBody(await settle(sid));
        expect(done.public_state).toBe("ready");

        const all = everything(sid);
        expect(all.session.link).toBe(BARE);
        expect(all.items[0].link).toBe(BARE);
        expect(all.privateMeta).toMatchObject({ source: BARE, sessionId: sid });
        // the public copy (hosted when the save became ready) names the same bare source
        const hosted = all.publicMeta.filter(([, m]: any) => m?.published === "1");
        expect(hosted).toHaveLength(1);
        expect((hosted[0] as any)[1].source).toBe(BARE);
        expect(JSON.stringify(all)).not.toMatch(SECRET);
        // and no later read puts it back: the poll, the library listing
        expect(JSON.stringify(asBody(await studio.advance(sid, 0)))).not.toMatch(SECRET);
        expect(JSON.stringify(await library())).not.toMatch(SECRET);
        expect((await library()).posts[0].link).toBe(BARE);
    });

    it("a public mirror made later (the visibility toggle) is made from the bare row, not from anything signed", async () => {
        const sid = ((await (await post({ url: DISCORD })).json()) as any).id as string;
        await settle(sid);
        const itemId = w.items()[0]!.id;
        const res = await call(`/library/items/${itemId}/visibility`, { method: "PATCH", headers: { ...auth, "content-type": "application/json" }, body: '{"public":true}' });
        expect(res.status).toBe(200);
        const mirrors = [...w.media.objects.values()].filter((o: any) => o.meta?.mirror === "1");
        expect(mirrors).toHaveLength(1);
        expect((mirrors[0] as any).meta.source).toBe(BARE);
        expect(JSON.stringify([...w.media.objects.values()].map((o: any) => o.meta))).not.toMatch(SECRET);
    });

    it("userinfo goes with the query", async () => {
        w.helper.fetchDone = { ...SAVED_PNG };
        const sid = ((await (await post({ url: "https://user:hunter2@files.example.com/pics/a.png?sig=TOKEN#frag" })).json()) as any).id as string;
        await settle(sid);
        expect(w.session(sid).link).toBe("https://files.example.com/pics/a.png");
        expect(w.items()[0].link).toBe("https://files.example.com/pics/a.png");
        expect(JSON.stringify(everything(sid))).not.toMatch(/hunter2|TOKEN|frag/);
    });

    it("a failed save whose error says cobalt had no service for the link drops the query too", async () => {
        for (const code of ["error.api.link.invalid", "error.api.link.unsupported"]) {
            w.helper.fetchError = code;
            const sid = ((await (await post({ url: DISCORD })).json()) as any).id as string;
            expect(w.session(sid).link).toBe(DISCORD);
            await settle(sid);
            expect(w.session(sid)).toMatchObject({ status: "error", error_code: code, link: BARE });
        }
    });

    it("what is NOT a direct file keeps its link as it always did: a post's query can matter", async () => {
        // a save of a supported service's post (no `direct` flag), with a query that selects the video
        const YT = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s";
        w.helper.fetchDone = { contentType: "video/mp4", ext: "mp4", duration: 12.4, width: 1280, height: 720, title: "clip", service: "youtube" };
        const sid = ((await (await post({ url: YT, public: true })).json()) as any).id as string;
        await settle(sid);
        expect(w.session(sid).link).toBe(YT);
        expect(w.items()[0].link).toBe(YT);
        expect(w.originals.objects.get(`originals/${sid}.mp4`)!.meta.source).toBe(YT);
        // ... and a failed save of any other kind keeps it too
        w.helper.fetchError = "error.studio.unavailable";
        const sid2 = ((await (await post({ url: YT })).json()) as any).id as string;
        await settle(sid2);
        expect(w.session(sid2)).toMatchObject({ status: "error", link: YT });
    });
});

describe("the request log drops userinfo as well as the query", () => {
    it("url_prefix of a link with credentials", async () => {
        await post({ url: "https://user:hunter2@files.example.com/pics/a.png?sig=TOKEN" });
        const row = w.db.raw.prepare("SELECT url_prefix FROM request_log WHERE route = 'POST /studio'").get() as any;
        expect(row.url_prefix).toBe("https://files.example.com/pics/a.png");
    });
});
