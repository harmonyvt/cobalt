// 7TV accounts (APP-API-CONTRACT.md section 57): link a 7TV session token, read the channels it edits and their sets,
// and edit sets. The Worker, the registry, the real handlers and the real SQL on node:sqlite run together; 7TV's GraphQL
// is a fake that records every call.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { openToken, sealToken, tokenExpiry, cleanToken, channelsOf, setEmoteShape } from "../src/seventv";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { fixedLengthPair, MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";

const ME_ID = "01GZ0000000000000000000001";
const LIA = "01GZ0000000000000000000002";
const MOCHI = "01GZ0000000000000000000003";
const PENDING = "01GZ0000000000000000000004";
const SET_MAIN = "01HA0000000000000000000001";
const SET_XMAS = "01HA0000000000000000000002";
const SET_PERSONAL = "01HA0000000000000000000003";
const EMOTE = "01F6MZGCNG000255K4X1K7NTHR";

// header.payload.signature with exp = 1_802_592_000 (seconds)
const payload = Buffer.from(JSON.stringify({ u: ME_ID, exp: 1_802_592_000 })).toString("base64url");
const TOKEN = `eyJhbGciOiJIUzI1NiJ9.${payload}.c2lnbmF0dXJl`;

let db: FakeD1;
let env: WorkerEnv;
let clock: number;
let calls: { query: string; variables: any; auth: string | null }[];
let answer: (query: string, variables: any) => { status?: number; body: unknown };
let uploads: { auth: string | null; metadata: any; type: string; size: number }[];
let upload: { status: number; body: unknown };

// the Durable Object: only the emote fit (57.10) is asked for here
let fits: { url: string; key: string | null; size: number }[];
let fitAnswer: () => Response;
const container = {
    fetch: async (req: Request) => {
        const bytes = (await req.arrayBuffer()).byteLength;
        fits.push({ url: req.url, key: req.headers.get("x-internal-key"), size: bytes });
        return fitAnswer();
    },
};

const conn = (name: string) => ({ platformDisplayName: name, platformAvatarUrl: `https://cdn.7tv.app/pp/${name}.webp` });
const ME = {
    users: {
        me: {
            id: ME_ID,
            mainConnection: conn("capybaraharmony"),
            style: { activeEmoteSetId: SET_MAIN },
            editorFor: [
                { state: "ACCEPTED", userId: MOCHI, permissions: { superAdmin: false, emoteSet: { manage: true, create: false }, user: { manageProfile: false } }, user: { id: MOCHI, mainConnection: conn("mochi_vt"), style: { activeEmoteSetId: null } } },
                { state: "ACCEPTED", userId: LIA, permissions: { superAdmin: true, emoteSet: { manage: false, create: false }, user: { manageProfile: false } }, user: { id: LIA, mainConnection: conn("liacat"), style: { activeEmoteSetId: SET_XMAS } } },
                { state: "PENDING", userId: PENDING, permissions: { superAdmin: true, emoteSet: { manage: true, create: true }, user: { manageProfile: true } }, user: { id: PENDING, mainConnection: conn("someone"), style: {} } },
            ],
        },
    },
};

const img = (scale: number, frames = 12) => ({ url: `https://cdn.7tv.app/emote/${EMOTE}/${scale}x.webp`, mime: "image/webp", size: 1000 * scale, scale, width: 32 * scale, height: 32 * scale, frameCount: frames });

beforeEach(async () => {
    clock = 1_800_000_000_000;
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "app", await hashKey(CLIENT), "0b5f2c3e", 1);
    env = {
        API_URL: `${API}/`,
        CORS_URL: WEB,
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
    };
    calls = [];
    fits = [];
    fitAnswer = () =>
        new Response(new Uint8Array(4000), {
            headers: { "content-type": "image/webp", "x-emote-width": "512", "x-emote-height": "288", "x-emote-frames": "40", "x-emote-quality": "82" },
        });
    uploads = [];
    upload = { status: 201, body: { emote_id: "01JUP0000000000000000000AB" } };
    answer = (q) => (q.includes("me {") ? { body: { data: ME } } : { body: { data: null } });
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
        if (url === "https://api.7tv.app/v4/emotes") {
            const form = init.body as FormData;
            const file = form.get("file") as File;
            uploads.push({ auth: new Headers(init.headers).get("authorization"), metadata: JSON.parse(String(form.get("metadata"))), type: file.type, size: file.size });
            return Response.json(upload.body, { status: upload.status });
        }
        expect(url).toBe("https://7tv.io/v4/gql");
        const body = JSON.parse(String(init.body));
        calls.push({ query: body.query, variables: body.variables, auth: new Headers(init.headers).get("authorization") });
        const a = answer(body.query, body.variables);
        return Response.json(a.body, { status: a.status ?? 200 });
    });
});

afterEach(() => vi.unstubAllGlobals());

const send = (path: string, init: RequestInit = {}, key = CLIENT) =>
    handleRequest(
        new Request(`${API}${path}`, { ...init, headers: { authorization: `Api-Key ${key}`, "content-type": "application/json", ...(init.headers ?? {}) } }),
        env,
        container as any,
        { now: () => clock, sleep: async () => {}, fixedLength: fixedLengthPair },
    );
const json = async (res: Response) => ({ status: res.status, body: (await res.json()) as any });
const link = () => send("/7tv/link", { method: "POST", body: JSON.stringify({ token: `"${TOKEN}"` }) });

describe("helpers", () => {
    it("seals and opens the token, reads exp, cleans pasted forms", async () => {
        const sealed = await sealToken(INTERNAL, TOKEN);
        expect(sealed).not.toContain(TOKEN);
        expect(await openToken(INTERNAL, sealed)).toBe(TOKEN);
        await expect(openToken("another-secret", sealed)).rejects.toThrow();
        expect(tokenExpiry(TOKEN)).toBe(1_802_592_000_000);
        expect(tokenExpiry("a.b.c")).toBeNull();
        expect(cleanToken(`  "${TOKEN}" `)).toBe(TOKEN);
        expect(cleanToken(`Bearer ${TOKEN}`)).toBe(TOKEN);
        expect(cleanToken("not a token")).toBeNull();
        expect(cleanToken("a".repeat(5000) + ".b.c")).toBeNull();
    });

    it("lists own channel first, accepted editor channels by name, with their rights", () => {
        const ch = channelsOf(ME.users.me as any);
        expect(ch.map((c) => c.name)).toEqual(["capybaraharmony", "liacat", "mochi_vt"]);
        expect(ch[0]).toMatchObject({ you: true, active_set_id: SET_MAIN, can: { manage_sets: true, create_sets: true, make_live: true } });
        expect(ch[1]!.can).toEqual({ manage_sets: true, create_sets: true, make_live: true }); // superAdmin
        expect(ch[2]!.can).toEqual({ manage_sets: true, create_sets: false, make_live: false });
    });

    it("shapes a set emote with section 20's picks", () => {
        const e = setEmoteShape({ id: EMOTE, alias: "liaWave", addedAt: "2026-11-01T00:00:00Z", emote: { id: EMOTE, defaultName: "peepoHey", flags: { animated: true }, images: [img(1), img(2), img(4), { ...img(4, 1), url: "https://cdn.7tv.app/x_static.webp" }] } });
        expect(e).toEqual({
            emote_id: EMOTE,
            alias: "liaWave",
            name: "peepoHey",
            renamed: true,
            animated: true,
            preview_url: `https://cdn.7tv.app/emote/${EMOTE}/2x.webp`,
            file_url: `https://cdn.7tv.app/emote/${EMOTE}/4x.webp`,
            added_at: Date.parse("2026-11-01T00:00:00Z"),
        });
    });
});

describe("link, status, unlink (57.4)", () => {
    it("is not linked at first; linking checks the token with 7TV and stores it sealed", async () => {
        expect(await json(await send("/7tv"))).toEqual({ status: 200, body: { status: "success", linked: false } });
        const r = await json(await link());
        expect(r.status).toBe(200);
        expect(r.body.account).toEqual({ id: ME_ID, name: "capybaraharmony", avatar_url: "https://cdn.7tv.app/pp/capybaraharmony.webp", linked_at: clock, expires_at: 1_802_592_000_000, status: "ok" });
        expect(r.body.channels).toHaveLength(3);
        expect(calls[0]!.auth).toBe(`Bearer ${TOKEN}`);
        const row = db.raw.prepare("SELECT token, status FROM seventv_account").get() as any;
        expect(row.status).toBe("ok");
        expect(row.token).not.toContain(TOKEN);
        expect(await openToken(INTERNAL, row.token)).toBe(TOKEN);
        const s = await json(await send("/7tv"));
        expect(s.body.linked).toBe(true);
        expect(s.body.channels.map((c: any) => c.name)).toEqual(["capybaraharmony", "liacat", "mochi_vt"]);
    });

    it("refuses a malformed token without calling 7TV, and one 7TV rejects", async () => {
        expect((await json(await send("/7tv/link", { method: "POST", body: JSON.stringify({ token: "hello" }) }))).body.error.code).toBe("error.seventv.token_invalid");
        expect(calls).toHaveLength(0);
        answer = () => ({ status: 401, body: { error: "invalid session" } });
        const r = await json(await link());
        expect(r).toMatchObject({ status: 400, body: { error: { code: "error.seventv.token_invalid" } } });
        expect(db.raw.prepare("SELECT COUNT(*) AS n FROM seventv_account").get()).toEqual({ n: 0 });
    });

    it("a dead session turns the account to relink, and edits then answer 409 without calling 7TV", async () => {
        await link();
        answer = () => ({ status: 401, body: {} });
        const s = await json(await send("/7tv"));
        expect(s.body).toMatchObject({ linked: true, account: { status: "relink" }, channels: [] });
        calls = [];
        const r = await json(await send(`/7tv/channels/${ME_ID}/sets`));
        expect(r).toMatchObject({ status: 409, body: { error: { code: "error.seventv.relink" } } });
        expect(calls).toHaveLength(0);
        // linking again clears it
        answer = (q) => (q.includes("me {") ? { body: { data: ME } } : { body: { data: null } });
        await link();
        expect((db.raw.prepare("SELECT status FROM seventv_account").get() as any).status).toBe("ok");
    });

    it("a rotated COBALT_API_KEY makes the token unreadable: relink", async () => {
        await link();
        env.COBALT_API_KEY = "11111111-2222-4333-8444-555555555555";
        // the new internal key is not the old one, so the client key still works but the token does not open
        const s = await json(await send("/7tv"));
        expect(s.body.account.status).toBe("relink");
    });

    it("unlink forgets the token", async () => {
        await link();
        expect(await json(await send("/7tv", { method: "DELETE" }))).toEqual({ status: 200, body: { status: "success", linked: false } });
        expect((await json(await send(`/7tv/sets/${SET_MAIN}`))).body.error.code).toBe("error.seventv.not_linked");
    });

    it("needs a client key", async () => {
        expect((await send("/7tv", {}, "11111111-2222-4333-8444-555555555555")).status).toBe(401);
    });
});

describe("sets and edits (57.3, 57.4)", () => {
    beforeEach(async () => {
        await link();
        calls = [];
    });

    it("lists a channel's normal sets, live first", async () => {
        answer = () => ({
            body: {
                data: {
                    users: {
                        user: {
                            id: ME_ID,
                            style: { activeEmoteSetId: SET_MAIN },
                            ownedEmoteSets: [
                                { id: SET_XMAS, name: "christmas", kind: "NORMAL", capacity: 500, emotes: { totalCount: 92 } },
                                { id: SET_PERSONAL, name: "personal", kind: "PERSONAL", capacity: 5, emotes: { totalCount: 1 } },
                                { id: SET_MAIN, name: "main", kind: "NORMAL", capacity: 500, emotes: { totalCount: 310 } },
                            ],
                        },
                    },
                },
            },
        });
        const r = await json(await send(`/7tv/channels/${ME_ID}/sets`));
        expect(r.body).toEqual({
            status: "success",
            channel_id: ME_ID,
            active_set_id: SET_MAIN,
            sets: [
                { id: SET_MAIN, name: "main", capacity: 500, count: 310, live: true },
                { id: SET_XMAS, name: "christmas", capacity: 500, count: 92, live: false },
            ],
        });
        expect(calls[0]!.variables).toEqual({ id: ME_ID });
    });

    it("reads a set page", async () => {
        answer = () => ({
            body: {
                data: {
                    emoteSets: {
                        emoteSet: {
                            id: SET_MAIN,
                            name: "main",
                            kind: "NORMAL",
                            capacity: 500,
                            ownerId: ME_ID,
                            owner: { id: ME_ID, style: { activeEmoteSetId: SET_MAIN } },
                            emotes: { totalCount: 310, pageCount: 6, items: [{ id: EMOTE, alias: "catJAM", addedAt: "2026-11-01T00:00:00Z", emote: { id: EMOTE, defaultName: "catJAM", flags: { animated: true }, images: [img(2), img(4)] } }] },
                        },
                    },
                },
            },
        });
        const r = await json(await send(`/7tv/sets/${SET_MAIN}?page=2`));
        expect(r.body.set).toEqual({ id: SET_MAIN, name: "main", capacity: 500, count: 310, owner_id: ME_ID, live: true });
        expect(r.body).toMatchObject({ page: 2, has_more: true });
        expect(r.body.emotes[0]).toMatchObject({ emote_id: EMOTE, alias: "catJAM", renamed: false });
        expect(calls[0]!.variables).toEqual({ id: SET_MAIN, q: null, page: 2, perPage: 60 });
    });

    it("adds, renames and removes with 7TV's input shapes", async () => {
        answer = () => ({ body: { data: { emoteSets: { emoteSet: { addEmote: { id: SET_MAIN }, removeEmote: { id: SET_MAIN }, updateEmoteAlias: { alias: "liaWave" } } } } } });
        const add = await json(await send(`/7tv/sets/${SET_MAIN}/emotes`, { method: "POST", body: JSON.stringify({ emote_id: EMOTE, alias: "catDance" }) }));
        expect(add).toEqual({ status: 201, body: { status: "success", set_id: SET_MAIN, emote_id: EMOTE, alias: "catDance" } });
        expect(calls[0]!.query).toContain("addEmote(id: $e, overrideConflicts: $over)");
        expect(calls[0]!.variables).toEqual({ set: SET_MAIN, e: { emoteId: EMOTE, alias: "catDance" }, over: null });

        const ren = await json(await send(`/7tv/sets/${SET_MAIN}/emotes/${EMOTE}`, { method: "PATCH", body: JSON.stringify({ alias: "liaWave", from: "catDance" }) }));
        expect(ren.body).toEqual({ status: "success", set_id: SET_MAIN, emote_id: EMOTE, alias: "liaWave" });
        expect(calls[1]!.variables).toEqual({ set: SET_MAIN, e: { emoteId: EMOTE, alias: "catDance" }, alias: "liaWave" });

        const rm = await json(await send(`/7tv/sets/${SET_MAIN}/emotes/${EMOTE}?alias=liaWave`, { method: "DELETE" }));
        expect(rm.body).toEqual({ status: "success", set_id: SET_MAIN, emote_id: EMOTE, removed: true });
        expect(calls[2]!.variables).toEqual({ set: SET_MAIN, e: { emoteId: EMOTE, alias: "liaWave" } });
    });

    it("rejects an alias with spaces and bad ids before calling 7TV", async () => {
        expect((await json(await send(`/7tv/sets/${SET_MAIN}/emotes`, { method: "POST", body: JSON.stringify({ emote_id: EMOTE, alias: "two words" }) }))).body.error.code).toBe("error.seventv.bad");
        expect((await send(`/7tv/sets/nope/emotes`, { method: "POST", body: JSON.stringify({ emote_id: EMOTE }) })).status).toBe(404);
        expect(calls).toHaveLength(0);
    });

    it("passes 7TV's refusals on with their message", async () => {
        answer = () => ({ body: { data: null, errors: [{ message: "you do not have permission to manage this user's emote sets", extensions: { status: 403, code: "LACKING_PRIVILEGES" } }] } });
        const r = await json(await send(`/7tv/sets/${SET_MAIN}/emotes`, { method: "POST", body: JSON.stringify({ emote_id: EMOTE }) }));
        expect(r).toEqual({ status: 403, body: { status: "error", error: { code: "error.seventv.forbidden" }, message: "you do not have permission to manage this user's emote sets" } });
        answer = () => ({ body: { data: null, errors: [{ message: "emote name conflict", extensions: { status: 409 } }] } });
        expect((await json(await send(`/7tv/sets/${SET_MAIN}/emotes`, { method: "POST", body: JSON.stringify({ emote_id: EMOTE }) }))).body.error.code).toBe("error.seventv.rejected");
        answer = () => ({ status: 429, body: {} });
        expect((await send(`/7tv/sets/${SET_MAIN}/emotes`, { method: "POST", body: JSON.stringify({ emote_id: EMOTE }) })).status).toBe(429);
    });

    it("makes a set live, new set, rename set", async () => {
        answer = (q) => ({
            body: {
                data: q.includes("activeEmoteSet")
                    ? { users: { user: { activeEmoteSet: { id: LIA, style: { activeEmoteSetId: SET_XMAS } } } } }
                    : q.includes("create(")
                      ? { emoteSets: { create: { id: SET_XMAS, name: "subathon", capacity: 500 } } }
                      : { emoteSets: { emoteSet: { name: { id: SET_MAIN, name: "main 2", capacity: 500 } } } },
            },
        });
        expect((await json(await send(`/7tv/channels/${LIA}/live`, { method: "POST", body: JSON.stringify({ set_id: SET_XMAS }) }))).body).toEqual({ status: "success", channel_id: LIA, active_set_id: SET_XMAS });
        expect(calls[0]!.variables).toEqual({ user: LIA, set: SET_XMAS });
        const created = await json(await send("/7tv/sets", { method: "POST", body: JSON.stringify({ owner_id: LIA, name: "subathon" }) }));
        expect(created).toMatchObject({ status: 201, body: { set: { id: SET_XMAS, name: "subathon", owner_id: LIA, count: 0, live: false } } });
        expect(calls[1]!.variables).toEqual({ name: "subathon", owner: LIA });
        expect((await json(await send(`/7tv/sets/${SET_MAIN}`, { method: "PATCH", body: JSON.stringify({ name: "main 2" }) }))).body.set.name).toBe("main 2");
    });
});

describe("uploading a library picture as a new emote (57.9)", () => {
    const put = (id: string, type: string, bytes: number, bucket = "media", post = "post-1") => {
        db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, created_at, post_key) VALUES (?, 'public', 'webp', ?, ?, ?, ?, ?, ?, ?)",
            )
            .run(id, bucket, `${id}.bin`, id, type, bytes, 1, post);
        (bucket === "media" ? (env.MEDIA as any) : (env.ORIGINALS as any)).objects.set(`${id}.bin`, { bytes, meta: {}, contentType: type, data: new Uint8Array(bytes), viaStream: false });
    };

    beforeEach(async () => {
        await link();
        calls = [];
    });

    it("uploads the file's bytes with 7TV's metadata, then adds it to the set", async () => {
        put("file-webp", "image/webp", 1234);
        answer = () => ({ body: { data: { emoteSets: { emoteSet: { addEmote: { id: SET_MAIN } } } } } });
        const r = await json(await send("/7tv/emotes", { method: "POST", body: JSON.stringify({ file: "file-webp", name: "liaDance", tags: ["lia", "dance"], set_id: SET_MAIN }) }));
        expect(r).toEqual({
            status: 201,
            body: {
                status: "success",
                emote_id: "01JUP0000000000000000000AB",
                name: "liaDance",
                file_id: "file-webp",
                page_url: "https://7tv.app/emotes/01JUP0000000000000000000AB",
                pending: true,
                fitted: null,
                added: { set_id: SET_MAIN, alias: null },
            },
        });
        expect(uploads).toEqual([{ auth: `Bearer ${TOKEN}`, metadata: { name: "liaDance", tags: ["lia", "dance"], default_zero_width: false, private: false }, type: "image/webp", size: 1234 }]);
        expect(calls[0]!.variables).toEqual({ set: SET_MAIN, e: { emoteId: "01JUP0000000000000000000AB" }, over: null });
    });

    it("finds a post's first picture, and reports a failed add without losing the upload", async () => {
        put("file-gif", "image/gif", 50, "originals", "post-9");
        answer = () => ({ body: { data: null, errors: [{ message: "emote set is full", extensions: { status: 400 } }] } });
        const r = await json(await send("/7tv/emotes", { method: "POST", body: JSON.stringify({ file: "post-9", name: "x", set_id: SET_MAIN }) }));
        expect(r.status).toBe(201);
        expect(r.body).toMatchObject({ file_id: "file-gif", added: null, add_error: { code: "error.seventv.rejected", message: "emote set is full" } });
    });

    it("refuses videos, big files it cannot fit, bad names and tags before calling 7TV", async () => {
        put("file-mp4", "video/mp4", 100);
        put("file-big", "image/avif", 8 * 1024 * 1024);
        put("file-ok", "image/png", 10);
        const code = async (body: unknown) => (await json(await send("/7tv/emotes", { method: "POST", body: JSON.stringify(body) }))).body.error.code;
        expect(await code({ file: "file-mp4", name: "a" })).toBe("error.seventv.file_type");
        expect(await code({ file: "file-big", name: "a" })).toBe("error.seventv.too_big");
        expect(await code({ file: "nope", name: "a" })).toBe("error.seventv.file_not_found");
        expect(await code({ file: "file-ok", name: "two words" })).toBe("error.seventv.bad");
        db.raw.prepare("UPDATE media_items SET width = 1920, height = 1080, content_type = 'image/avif' WHERE id = 'file-ok'").run();
        expect(await code({ file: "file-ok", name: "a" })).toBe("error.seventv.too_large");
        expect(await code({ file: "file-ok", name: "a", size: 128 })).toBe("error.seventv.file_type");
        db.raw.prepare("UPDATE media_items SET width = 512, height = 128, content_type = 'image/png' WHERE id = 'file-ok'").run();
        expect(await code({ file: "file-ok", name: "a" })).toBe("error.seventv.too_large");
        db.raw.prepare("UPDATE media_items SET width = 300, height = 100 WHERE id = 'file-ok'").run();
        expect(await code({ file: "file-ok", name: "a", tags: ["x"] })).toBe("error.seventv.bad");
        expect(await code({ file: "file-ok", name: "a", crop: { x: 0.5, y: 0, w: 0.6, h: 1 } })).toBe("error.seventv.bad");
        expect(await code({ file: "file-ok", name: "a", size: 2000 })).toBe("error.seventv.bad");
        expect(await code({ file: "file-mp4", name: "a", crop: { x: 0, y: 0, w: 0.5, h: 0.5 } })).toBe("error.seventv.file_type");
        expect(uploads).toHaveLength(0);
        expect(fits).toHaveLength(0);
    });

    it("fits a picture that is too big for 7TV first (57.10), and sends the fitted webp", async () => {
        put("file-big", "image/gif", 9 * 1024 * 1024);
        const r = await json(await send("/7tv/emotes", { method: "POST", body: JSON.stringify({ file: "file-big", name: "bigCat" }) }));
        expect(r.status).toBe(201);
        expect(r.body.fitted).toEqual({ width: 512, height: 288, frames: 40, bytes: 4000, quality: 82 });
        expect(fits).toHaveLength(1);
        expect(fits[0]!.key).toBe(INTERNAL);
        expect(fits[0]!.size).toBe(9 * 1024 * 1024);
        const q = new URL(fits[0]!.url).searchParams;
        expect(q.get("max_bytes")).toBe(String(7 * 1024 * 1024 - 64 * 1024));
        expect(q.has("crop") || q.has("size")).toBe(false);
        expect(uploads).toEqual([expect.objectContaining({ type: "image/webp", size: 4000 })]);
    });

    it("crops and resizes when asked; a too-wide picture needs a crop box", async () => {
        put("file-wide", "image/png", 1000);
        db.raw.prepare("UPDATE media_items SET width = 1920, height = 200 WHERE id = 'file-wide'").run();
        const go = (body: object) => send("/7tv/emotes", { method: "POST", body: JSON.stringify({ file: "file-wide", name: "wide", ...body }) }).then(json);
        expect((await go({})).body.error.code).toBe("error.seventv.too_large");
        expect(fits).toHaveLength(0);
        const r = await go({ crop: { x: 0.25, y: 0, w: 0.25, h: 1 }, size: 256 });
        expect(r.status).toBe(201);
        const q = new URL(fits[0]!.url).searchParams;
        expect(q.get("crop")).toBe("0.25,0,0.25,1");
        expect(q.get("size")).toBe("256");
    });

    it("passes the fit's refusals on", async () => {
        put("file-big", "image/webp", 9 * 1024 * 1024);
        const go = async () => (await json(await send("/7tv/emotes", { method: "POST", body: JSON.stringify({ file: "file-big", name: "a" }) }))).body;
        const err = (status: number, code: string, detail?: string) => () => Response.json({ status: "error", error: { code, ...(detail ? { detail } : {}) } }, { status });
        fitAnswer = err(400, "error.seventv.fit_shape", "pick a crop box");
        expect(await go()).toMatchObject({ error: { code: "error.seventv.too_large" }, message: "pick a crop box" });
        fitAnswer = err(422, "error.seventv.fit_too_big");
        expect((await go()).error.code).toBe("error.seventv.too_big");
        fitAnswer = err(429, "error.webp.busy");
        expect((await go()).error.code).toBe("error.seventv.busy");
        fitAnswer = err(422, "error.seventv.fit_failed", "a frame would not decode");
        expect(await go()).toMatchObject({ error: { code: "error.seventv.fit_failed" }, message: "a frame would not decode" });
        expect(uploads).toHaveLength(0);
    });

    it("passes 7TV's REST refusals on", async () => {
        put("file-ok", "image/png", 10);
        upload = { status: 400, body: { status: "Bad Request", error_code: 0, error: "bad image format" } };
        expect((await json(await send("/7tv/emotes", { method: "POST", body: JSON.stringify({ file: "file-ok", name: "a" }) })))).toEqual({
            status: 400,
            body: { status: "error", error: { code: "error.seventv.rejected" }, message: "bad image format" },
        });
        upload = { status: 401, body: {} };
        expect((await json(await send("/7tv/emotes", { method: "POST", body: JSON.stringify({ file: "file-ok", name: "a" }) }))).body.error.code).toBe("error.seventv.relink");
        expect((db.raw.prepare("SELECT status FROM seventv_account").get() as any).status).toBe("relink");
    });

    it("GET /7tv/emotes/:id says whether 7TV is still processing it", async () => {
        answer = () => ({
            body: { data: { emotes: { emote: { id: EMOTE, defaultName: "liaDance", deleted: false, imagesPending: true, ownerId: ME_ID, flags: { animated: true, private: false, defaultZeroWidth: false }, images: [] } } } },
        });
        const r = await json(await send(`/7tv/emotes/${EMOTE}`));
        expect(r.body).toEqual({
            status: "success",
            emote_id: EMOTE,
            name: "liaDance",
            owner_id: ME_ID,
            pending: true,
            animated: true,
            private: false,
            zero_width: false,
            preview_url: null,
            file_url: null,
            page_url: `https://7tv.app/emotes/${EMOTE}`,
        });
    });
});
