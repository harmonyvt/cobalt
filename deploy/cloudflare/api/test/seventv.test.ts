// 7TV accounts (APP-API-CONTRACT.md section 57): link a 7TV session token, read the channels it edits and their sets,
// and edit sets. The Worker, the registry, the real handlers and the real SQL on node:sqlite run together; 7TV's GraphQL
// is a fake that records every call.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { openToken, sealToken, tokenExpiry, cleanToken, channelsOf, setEmoteShape, sevenTvAddMany, sevenTvClonePlan, sevenTvPermissions } from "../src/seventv";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { fixedLengthPair, MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const OTHER = "7c1d9e4a-0a3b-4f6e-8b21-5e9d2f3a4b60";

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

    it("unlink with logout=1 ends the 7TV session too, and forgets the token even when that fails (57.12)", async () => {
        await link();
        const logouts: (string | null)[] = [];
        let status = 204;
        const inner = globalThis.fetch;
        vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
            if (url === "https://api.7tv.app/v4/auth/logout") {
                logouts.push(new Headers(init.headers).get("authorization"));
                return new Response(null, { status });
            }
            return inner(url, init);
        });
        expect((await json(await send("/7tv?logout=1", { method: "DELETE" }))).body).toEqual({ status: "success", linked: false, logged_out: true });
        expect(logouts).toEqual([`Bearer ${TOKEN}`]);
        await link();
        status = 500;
        expect((await json(await send("/7tv?logout=1", { method: "DELETE" }))).body).toEqual({ status: "success", linked: false, logged_out: false });
        expect((await json(await send("/7tv"))).body.linked).toBe(false);
        await link();
        expect((await json(await send("/7tv", { method: "DELETE" }))).body).toEqual({ status: "success", linked: false });
        expect(logouts).toHaveLength(2);
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
        answer = () => ({ body: { data: null, errors: [{ message: "emote set is full", extensions: { status: 400 } }] } });
        expect((await json(await send(`/7tv/sets/${SET_MAIN}/emotes`, { method: "POST", body: JSON.stringify({ emote_id: EMOTE }) }))).body.error.code).toBe("error.seventv.rejected");
        answer = () => ({ status: 429, body: {} });
        expect((await send(`/7tv/sets/${SET_MAIN}/emotes`, { method: "POST", body: JSON.stringify({ emote_id: EMOTE }) })).status).toBe(429);
    });

    it("a name already in the set is error.seventv.name_taken (57.11)", async () => {
        answer = () => ({ body: { data: null, errors: [{ message: "emote name conflict", extensions: { status: 409, code: "CONFLICT" } }] } });
        const r = await json(await send(`/7tv/sets/${SET_MAIN}/emotes`, { method: "POST", body: JSON.stringify({ emote_id: EMOTE }) }));
        expect(r).toEqual({ status: 409, body: { status: "error", error: { code: "error.seventv.name_taken" }, message: "emote name conflict" } });
        const ren = await json(await send(`/7tv/sets/${SET_MAIN}/emotes/${EMOTE}`, { method: "PATCH", body: JSON.stringify({ alias: "taken" }) }));
        expect(ren.body.error.code).toBe("error.seventv.name_taken");
        answer = () => ({ body: { data: { emoteSets: { emoteSet: { addEmote: { id: SET_MAIN } } } } } });
        await send(`/7tv/sets/${SET_MAIN}/emotes`, { method: "POST", body: JSON.stringify({ emote_id: EMOTE, override_conflicts: true }) });
        expect(calls.at(-1)!.variables.over).toBe(true);
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

    it("remembers each upload and lists them newest first (57.11)", async () => {
        put("file-a", "image/webp", 10);
        put("file-b", "image/gif", 10);
        expect((await json(await send("/7tv/uploads"))).body).toEqual({ status: "success", uploads: [] });
        upload = { status: 201, body: { emote_id: "01JUP0000000000000000000AA" } };
        await send("/7tv/emotes", { method: "POST", body: JSON.stringify({ file: "file-a", name: "first" }) });
        clock += 1000;
        upload = { status: 201, body: { emote_id: "01JUP0000000000000000000AB" } };
        answer = () => ({ body: { data: { emoteSets: { emoteSet: { addEmote: { id: SET_MAIN } } } } } });
        await send("/7tv/emotes", { method: "POST", body: JSON.stringify({ file: "file-b", name: "second", set_id: SET_MAIN }) });
        expect((await json(await send("/7tv/uploads"))).body.uploads).toEqual([
            { file_id: "file-b", emote_id: "01JUP0000000000000000000AB", name: "second", set_id: SET_MAIN, created_at: clock },
            { file_id: "file-a", emote_id: "01JUP0000000000000000000AA", name: "first", set_id: null, created_at: clock - 1000 },
        ]);
    });

    it("GET /7tv/owned lists every owned emote, newest first, naming capystore's files (57.14)", async () => {
        put("file-a", "image/webp", 10);
        upload = { status: 201, body: { emote_id: "01JUP0000000000000000000AA" } };
        await send("/7tv/emotes", { method: "POST", body: JSON.stringify({ file: "file-a", name: "mine" }) });
        const raw = (id: string, name: string, extra: object = {}) => ({
            id, defaultName: name, deleted: false, imagesPending: false, flags: { animated: false, private: false, defaultZeroWidth: false }, images: [img(2, 1)], ...extra,
        });
        answer = (q) =>
            q.includes("ownedEmotes")
                ? { body: { data: { users: { me: { id: ME_ID, ownedEmotes: [raw("01F6MZGCNG000255K4X1K7NTHR", "old"), raw("01JUP0000000000000000000AA", "mine"), raw("01JUP0000000000000000000ZZ", "gone", { deleted: true })] } } } } }
                : { body: { data: null } };
        const r = await json(await send("/7tv/owned"));
        expect(r.status).toBe(200);
        expect(r.body.owner_id).toBe(ME_ID);
        expect(r.body.total).toBe(2);
        expect(r.body.emotes.map((e: any) => [e.emote_id, e.name, e.file_id])).toEqual([
            ["01JUP0000000000000000000AA", "mine", "file-a"],
            ["01F6MZGCNG000255K4X1K7NTHR", "old", null],
        ]);
        expect(r.body.emotes[1]).toMatchObject({ page_url: "https://7tv.app/emotes/01F6MZGCNG000255K4X1K7NTHR", pending: false, animated: false });
        expect(typeof r.body.emotes[1].created_at).toBe("number");
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

// section 63.4-63.5: many adds with one approval, a set copied with swaps, and what the account may do per channel.
// The fake set behaves like live 7TV (checked 2026-11-16): one failed add in a batch answers data null with an error for
// that alias alone, so the rest of the batch is unknown until the set is read again.
describe("many adds, set copies and permissions (63.4, 63.5)", () => {
    const id = (n: number) => `01HE${String(n).padStart(22, "0")}`;
    const deps = () => ({ db: db as unknown as D1Database, now: () => clock, secret: INTERNAL });
    let sets: Map<string, { name: string; capacity: number; items: { id: string; alias: string }[] }>;
    let refuse: (setId: string, emoteId: string) => { message: string; code: string; status: number } | null;
    let limitOnce: boolean;
    const setAnswer = (vars: any) => {
        const s = sets.get(vars.id);
        if (!s) return { body: { data: { emoteSets: { emoteSet: null } } } };
        const per = vars.perPage;
        const page = s.items.slice((vars.page - 1) * per, vars.page * per);
        return {
            body: {
                data: {
                    emoteSets: {
                        emoteSet: {
                            id: vars.id, name: s.name, kind: "NORMAL", capacity: s.capacity, ownerId: ME_ID, owner: { id: ME_ID, style: {} },
                            emotes: { totalCount: s.items.length, pageCount: Math.max(1, Math.ceil(s.items.length / per)), items: page.map((e) => ({ id: e.id, alias: e.alias, addedAt: null, emote: { id: e.id, defaultName: e.alias, flags: { animated: false }, images: [] } })) },
                        },
                    },
                },
            },
        };
    };
    const addAnswer = (q: string, vars: any) => {
        if (limitOnce) {
            limitOnce = false;
            return { status: 429, body: {} };
        }
        const s = sets.get(vars.set)!;
        const data: Record<string, unknown> = {};
        for (const m of q.matchAll(/(a\d+): emoteSets/g)) {
            const k = m[1]!.slice(1);
            const e = vars[`e${k}`];
            const no = refuse(vars.set, e.emoteId);
            if (no) return { body: { data: null, errors: [{ message: no.message, path: [m[1], "emoteSet"], extensions: { code: no.code, status: no.status } }] } };
            const alias = e.alias ?? e.emoteId;
            const at = s.items.findIndex((x) => x.alias.toLowerCase() === alias.toLowerCase());
            if (at >= 0 && !vars.over) return { body: { data: null, errors: [{ message: "emote name conflict", path: [m[1], "emoteSet"], extensions: { code: "CONFLICT", status: 409 } }] } };
            if (at >= 0) s.items.splice(at, 1);
            s.items.push({ id: e.emoteId, alias });
            data[m[1]!] = { emoteSet: { addEmote: { id: vars.set } } };
        }
        return { body: { data } };
    };

    beforeEach(async () => {
        await link();
        sets = new Map([
            [SET_MAIN, { name: "main", capacity: 1000, items: Array.from({ length: 70 }, (_, i) => ({ id: id(i), alias: `e${i}` })) }],
            [SET_XMAS, { name: "xmas", capacity: 1000, items: [{ id: id(1), alias: "e1" }] }],
        ]);
        refuse = () => null;
        limitOnce = false;
        answer = (q, v) => (q.startsWith("mutation(") ? addAnswer(q, v) : q.includes("emoteSet(id: $id)") ? setAnswer(v) : q.includes("me {") ? { body: { data: ME } } : { body: { data: null } });
    });

    it("adds in batches of 10, skips what is already there, and can be repeated", async () => {
        const items = Array.from({ length: 25 }, (_, i) => ({ emote_id: id(i), alias: `e${i}` }));
        const r = (await sevenTvAddMany(deps(), SET_XMAS, items, { sleep: async () => {} })).body as any;
        expect(r).toMatchObject({ set_name: "xmas", count_before: 1, count_after: 25, failed: [], remaining: [] });
        expect(r.added).toHaveLength(24);
        expect(r.skipped).toEqual([{ emote_id: id(1), alias: "e1", why: "already in the set under that name" }]);
        expect(calls.filter((c) => c.query.startsWith("mutation(")).map((c) => (c.query.match(/addEmote/g) ?? []).length)).toEqual([10, 10, 4]);
        const again = (await sevenTvAddMany(deps(), SET_XMAS, items, { sleep: async () => {} })).body as any;
        expect(again.added).toEqual([]);
        expect(again.skipped).toHaveLength(25);
    });

    it("an add that fails nulls its batch: the set is read again and the unknown ones are sent once more", async () => {
        const bad = id(503);
        refuse = (_s, e) => (e === bad ? { message: "emote not found", code: "LOAD_ERROR", status: 404 } : null);
        const items = [{ emote_id: id(500), alias: "x0" }, { emote_id: bad, alias: "x3" }, { emote_id: id(501), alias: "x1" }, { emote_id: id(502), alias: "x2" }];
        const r = (await sevenTvAddMany(deps(), SET_XMAS, items, { sleep: async () => {} })).body as any;
        // the fake stops at the failed add: x0 landed before it, x1 and x2 never ran
        expect(r.added.map((a: any) => a.alias).sort()).toEqual(["x0", "x1", "x2"]);
        expect(r.failed).toEqual([{ emote_id: bad, alias: "x3", code: "error.seventv.not_found", message: "emote not found" }]);
        expect(sets.get(SET_XMAS)!.items.map((e) => e.alias)).toEqual(["e1", "x0", "x1", "x2"]);
    });

    it("stops at the first LACKING_PRIVILEGES, with 7TV's own words and what was not sent", async () => {
        refuse = () => ({ message: "you do not have permission to manage this user's emote sets", code: "LACKING_PRIVILEGES", status: 403 });
        const items = Array.from({ length: 30 }, (_, i) => ({ emote_id: id(600 + i), alias: `n${i}` }));
        const r = (await sevenTvAddMany(deps(), SET_XMAS, items, { sleep: async () => {} })).body as any;
        expect(r.added).toEqual([]);
        expect(r.failed).toHaveLength(1);
        expect(r.failed[0].code).toBe("error.seventv.forbidden");
        expect(r.stopped).toContain("you do not have permission to manage this user's emote sets");
        expect(r.remaining.length).toBe(29);
        expect(calls.filter((c) => c.query.startsWith("mutation("))).toHaveLength(1);
    });

    it("waits out a rate limit and retries the batch", async () => {
        limitOnce = true;
        const waited: number[] = [];
        const r = (await sevenTvAddMany(deps(), SET_XMAS, [{ emote_id: id(700), alias: "r" }], { sleep: async (ms) => void waited.push(ms) })).body as any;
        expect(r.added).toEqual([{ emote_id: id(700), alias: "r" }]);
        expect(waited).toHaveLength(1);
    });

    it("refuses a call that does not fit, counting replaced names as no new room; dry_run sends nothing", async () => {
        sets.get(SET_XMAS)!.capacity = 3;
        const items = [{ emote_id: id(800), alias: "e1" }, { emote_id: id(801), alias: "a" }, { emote_id: id(802), alias: "b" }];
        const full = await sevenTvAddMany(deps(), SET_XMAS, items);
        expect(full.status).toBe(409);
        expect((full.body as any).error.code).toBe("error.seventv.set_full");
        const dry = (await sevenTvAddMany(deps(), SET_XMAS, items, { override_conflicts: true, dry_run: true })).body as any;
        expect(dry).toMatchObject({ dry_run: true, added: [] });
        expect(dry.would_add).toHaveLength(3);
        expect(calls.filter((c) => c.query.startsWith("mutation("))).toHaveLength(0);
        expect((await sevenTvAddMany(deps(), SET_XMAS, [{ emote_id: "nope", alias: "x" }])).status).toBe(400);
    });

    it("a copy keeps every alias, puts the swaps in, honours skip and only, and names swaps that matched nothing", async () => {
        const p = (await sevenTvClonePlan(deps(), { from_set_id: SET_MAIN, to_set_id: SET_XMAS, swap: [{ alias: "E2", emote_id: id(900) }, { alias: "ghost", emote_id: id(901) }], skip: ["e3"] })) as any;
        expect(p.from).toEqual({ id: SET_MAIN, name: "main", count: 70 }); // read across two pages of 60
        expect(p.items).toHaveLength(69);
        expect(p.items.find((i: any) => i.alias === "e2")).toEqual({ emote_id: id(900), alias: "e2" });
        expect(p.items.some((i: any) => i.alias === "e3")).toBe(false);
        expect(p.swapped).toBe(1);
        expect(p.unknown_swaps).toEqual(["ghost"]);
        const only = (await sevenTvClonePlan(deps(), { from_set_id: SET_MAIN, to_set_id: SET_XMAS, only: ["e5", "e6"] })) as any;
        expect(only.items.map((i: any) => i.alias)).toEqual(["e5", "e6"]);
        expect(((await sevenTvClonePlan(deps(), { from_set_id: SET_MAIN, to_set_id: SET_MAIN })) as any).status).toBe(400);
    });

    it("permissions: each channel's rights and the blockers in plain words", async () => {
        const me = structuredClone(ME.users.me) as any;
        me.permissions = { emoteSetLimit: 10, emoteSetCapacity: 1000, emote: { upload: true } };
        me.ownedEmoteSets = Array.from({ length: 10 }, (_, i) => ({ id: id(i), kind: i === 0 ? "PERSONAL" : "NORMAL" }));
        for (const e of me.editorFor) e.user.ownedEmoteSets = [{ id: id(50), kind: "NORMAL" }];
        answer = (q) => (q.includes("permissions { emoteSetLimit") ? { body: { data: { users: { me } } } } : { body: { data: ME } });
        const r = (await sevenTvPermissions(deps(), null)).body as any;
        expect(r.account).toEqual({ id: ME_ID, name: "capybaraharmony", set_limit: 10, set_capacity: 1000 });
        expect(r.channels.map((c: any) => c.name)).toEqual(["capybaraharmony", "liacat", "mochi_vt", "someone"]);
        expect(r.channels[0]).toMatchObject({ you: true, sets: 9, can: { add_remove_rename: true, create_sets: true, make_live: true, upload_emotes: true } });
        const mochi = r.channels.find((c: any) => c.name === "mochi_vt");
        expect(mochi.can).toEqual({ add_remove_rename: true, create_sets: false, make_live: false, upload_emotes: false });
        expect(mochi.blockers.join(" ")).toContain("LACKING_PRIVILEGES");
        const pending = r.channels.find((c: any) => c.name === "someone");
        expect(pending.can.add_remove_rename).toBe(false);
        expect(pending.blockers[0]).toContain("pending");
        me.ownedEmoteSets.push({ id: id(99), kind: "NORMAL" });
        const one = (await sevenTvPermissions(deps(), ME_ID)).body as any;
        expect(one.channels).toHaveLength(1);
        expect(one.channels[0].can.create_sets).toBe(false);
        expect(one.channels[0].blockers[0]).toContain("your limit is 10");
        expect((await sevenTvPermissions(deps(), id(12345))).status).toBe(404);
    });
});

describe("the emote editor: drafts (71)", () => {
    const DAY = 24 * 3600_000;
    const put = (id: string, type: string, bytes = 100, bucket = "media") => {
        db.raw
            .prepare("INSERT INTO media_items (id, kind, source, bucket, r2_key, name, content_type, bytes, created_at, post_key) VALUES (?, 'public', 'webp', ?, ?, ?, ?, ?, ?, ?)")
            .run(id, bucket, `${id}.bin`, id, type, bytes, 1, `post-${id}`);
        (bucket === "media" ? (env.MEDIA as any) : (env.ORIGINALS as any)).objects.set(`${id}.bin`, { bytes, meta: {}, contentType: type, data: new Uint8Array(bytes), viaStream: false });
    };
    const headers = (o: Record<string, string>) => ({ "content-type": o["x-emote-format"] ? `image/${o["x-emote-format"]}` : "image/webp", ...o });
    const make = (body: object, key = CLIENT) => send("/7tv/emotes/make", { method: "POST", body: JSON.stringify(body) }, key).then(json);
    const originals = () => (env.ORIGINALS as any).objects as Map<string, { bytes: Uint8Array; contentType: string; meta: Record<string, string> }>;
    const drafts = () => [...originals().keys()].filter((k) => k.startsWith("emote-drafts/"));
    const code = (r: { body: any }) => r.body.error?.code;

    beforeEach(() => {
        fitAnswer = () =>
            new Response(new Uint8Array(3000), {
                headers: headers({ "x-emote-format": "gif", "x-emote-width": "200", "x-emote-height": "150", "x-emote-frames": "18", "x-emote-quality": "50", "x-emote-duration": "3600", "x-emote-over-cap": "0" }),
            });
    });

    it("makes a draft: the fit gets every field, R2 holds it under the key, the answer is the contract's", async () => {
        put("file-gif", "image/gif", 5000);
        const r = await make({ file: "file-gif", crop: { x: 0.1, y: 0, w: 0.5, h: 1 }, stretch: { w: 0.5, h: 1 }, size: 200, format: "gif", quality: 50, fps: 10, bounce: true, frame: 1.5 });
        expect(r.status).toBe(201);
        const id = r.body.draft_id as string;
        expect(id).toMatch(/^[0-9A-Za-z]{22}$/);
        expect(r.body).toEqual({
            status: "success", draft_id: id, format: "gif", content_type: "image/gif", width: 200, height: 150, frames: 18, duration_ms: 3600,
            bytes: 3000, quality: 50, over_cap: false, url: `/7tv/drafts/${id}`, expires_at: clock + DAY,
        });
        const q = new URL(fits[0]!.url).searchParams;
        expect(Object.fromEntries(q)).toEqual({
            max_bytes: String(7 * 1024 * 1024 - 64 * 1024), type: "image/gif", crop: "0.1,0,0.5,1", stretch: "0.5,1", size: "200", format: "gif", quality: "50", fps: "10", bounce: "1", frame: "1.5",
        });
        expect(fits[0]!.key).toBe(INTERNAL);
        expect(drafts()).toEqual([`emote-drafts/key-1/${id}.gif`]);
        expect(originals().get(drafts()[0]!)).toMatchObject({ contentType: "image/gif", meta: { created: String(clock), width: "200", frames: "18", over_cap: "0" } });
        expect(originals().get(drafts()[0]!)!.bytes).toHaveLength(3000);
        // without a 7TV account linked: nothing was needed
        expect(uploads).toHaveLength(0);
    });

    it("sends only what was asked, and a video's moment with its type", async () => {
        put("file-png", "image/png");
        await make({ file: "file-png" });
        expect(Object.fromEntries(new URL(fits[0]!.url).searchParams)).toEqual({ max_bytes: String(7 * 1024 * 1024 - 64 * 1024), type: "image/png" });
        put("clip", "video/mp4", 2000);
        expect((await make({ file: "clip" })).status).toBe(201);
        expect(Object.fromEntries(new URL(fits[1]!.url).searchParams)).toMatchObject({ type: "video/mp4", start: "0", end: "3" });
        expect((await make({ file: "clip", start: 4, end: 6.5, fps: 25, format: "png", frame: 5 })).status).toBe(201);
        expect(Object.fromEntries(new URL(fits[2]!.url).searchParams)).toMatchObject({ start: "4", end: "6.5", fps: "25", format: "png", frame: "5" });
        expect((await make({ file: "clip", start: 2 })).status).toBe(201);
        expect(new URL(fits[3]!.url).searchParams.get("end")).toBe("5");
        // a picture ignores start and end
        expect((await make({ file: "file-png", start: 1, end: 1.1 })).status).toBe(201);
        expect(new URL(fits[4]!.url).searchParams.has("start")).toBe(false);
    });

    it("says over_cap when a fixed quality came out too big", async () => {
        put("file-png", "image/png");
        fitAnswer = () => new Response(new Uint8Array(10), { headers: headers({ "x-emote-format": "webp", "x-emote-width": "512", "x-emote-height": "512", "x-emote-frames": "3", "x-emote-quality": "90", "x-emote-duration": "300", "x-emote-over-cap": "1" }) });
        const r = await make({ file: "file-png", quality: 90 });
        expect(r.body).toMatchObject({ status: "success", format: "webp", content_type: "image/webp", over_cap: true, quality: 90 });
    });

    it("refuses bad fields, unknown and wrong files, and passes the fit's refusals on", async () => {
        put("file-png", "image/png");
        put("clip", "video/webm");
        put("pic", "image/avif");
        put("doc", "application/pdf");
        put("huge", "image/gif", 70 * 1024 * 1024);
        for (const bad of [
            { stretch: { w: 5, h: 1 } }, { stretch: { w: 1 } }, { size: 31 }, { size: 1001 }, { format: "avif" }, { quality: 0 }, { quality: 101 }, { fps: 4 }, { fps: 51 },
            { start: -1 }, { frame: -2 }, { bounce: "yes" }, { replace: "short" }, { crop: { x: 0.5, y: 0, w: 0.6, h: 1 } }, { file: "" },
        ]) {
            const r = await make({ file: "file-png", ...bad });
            expect([JSON.stringify(bad), r.status, code(r)]).toEqual([JSON.stringify(bad), 400, "error.seventv.bad"]);
        }
        expect(code(await make({ file: "clip", start: 1, end: 1.1 }))).toBe("error.seventv.bad");
        expect(code(await make({ file: "clip", start: 0, end: 10.5 }))).toBe("error.seventv.bad");
        expect(code(await make({ file: "nope" }))).toBe("error.seventv.file_not_found");
        expect((await make({ file: "pic" })).status).toBe(415);
        expect(code(await make({ file: "doc" }))).toBe("error.seventv.file_type");
        expect((await make({ file: "huge" })).status).toBe(413);
        expect(fits).toHaveLength(0);
        const err = (status: number, c: string, detail?: string) => () => Response.json({ status: "error", error: { code: c, ...(detail ? { detail } : {}) } }, { status });
        fitAnswer = err(400, "error.seventv.fit_shape", "too wide");
        expect(await make({ file: "file-png" })).toMatchObject({ status: 400, body: { error: { code: "error.seventv.too_large" }, message: "too wide" } });
        fitAnswer = err(429, "error.webp.busy");
        expect((await make({ file: "file-png" })).status).toBe(429);
        fitAnswer = err(422, "error.seventv.fit_failed", "no picture at that moment of the video");
        expect(await make({ file: "clip" })).toMatchObject({ status: 422, body: { error: { code: "error.seventv.fit_failed" }, message: "no picture at that moment of the video" } });
        fitAnswer = err(422, "error.seventv.fit_too_big");
        expect((await make({ file: "file-png" })).status).toBe(413);
        expect(drafts()).toEqual([]);
    });

    it("serves the file to its own key only, deletes it, and lets it expire after 24 h", async () => {
        put("file-png", "image/png");
        const a = (await make({ file: "file-png" })).body.draft_id as string;
        const got = await send(`/7tv/drafts/${a}`, { headers: { origin: WEB } });
        expect(got.status).toBe(200);
        expect(got.headers.get("content-type")).toBe("image/gif");
        expect(got.headers.get("cache-control")).toBe("private, max-age=3600");
        expect(got.headers.get("access-control-allow-origin")).toBe(WEB);
        expect((await got.arrayBuffer()).byteLength).toBe(3000);
        // another key sees nothing
        db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-2", "other", await hashKey(OTHER), "other-ke", 1);
        const other = await send(`/7tv/drafts/${a}`, {}, OTHER);
        expect(other.status).toBe(404);
        expect(((await other.json()) as any).error.code).toBe("error.seventv.draft_not_found");
        expect(code(await json(await send(`/7tv/drafts/${a}`, { method: "DELETE" }, OTHER)))).toBe("error.seventv.draft_not_found");
        expect(drafts()).toHaveLength(1);
        // expiry is checked when it is read
        clock += DAY - 1;
        expect((await send(`/7tv/drafts/${a}`)).status).toBe(200);
        clock += 1;
        expect((await send(`/7tv/drafts/${a}`)).status).toBe(404);
        expect(drafts()).toEqual([]);
        // delete
        const b = (await make({ file: "file-png" })).body.draft_id as string;
        expect(await json(await send(`/7tv/drafts/${b}`, { method: "DELETE" }))).toEqual({ status: 200, body: { status: "success", deleted: true } });
        expect((await send(`/7tv/drafts/${b}`)).status).toBe(404);
        expect(code(await json(await send(`/7tv/drafts/${b}`, { method: "DELETE" })))).toBe("error.seventv.draft_not_found");
        expect((await send("/7tv/drafts/not-an-id")).status).toBe(404);
    });

    it("replace deletes the last draft first, and only the key's own", async () => {
        put("file-png", "image/png");
        const a = (await make({ file: "file-png" })).body.draft_id as string;
        const b = (await make({ file: "file-png", replace: a })).body.draft_id as string;
        expect(drafts()).toEqual([`emote-drafts/key-1/${b}.gif`]);
        // a replace naming a missing or foreign draft is not an error
        expect((await make({ file: "file-png", replace: "A".repeat(22) })).status).toBe(201);
        expect(drafts()).toHaveLength(2);
    });

    it("saves a draft as a private library item (source emote) and keeps the draft", async () => {
        put("file-png", "image/png");
        const id = (await make({ file: "file-png" })).body.draft_id as string;
        const r = await json(await send(`/7tv/drafts/${id}/save`, { method: "POST", body: JSON.stringify({}) }));
        expect(r.status).toBe(201);
        expect(r.body).toMatchObject({ status: "success" });
        expect(r.body.item_id).toBe(r.body.file_id);
        const row = db.raw.prepare("SELECT * FROM media_items WHERE id = ?").get(r.body.file_id) as any;
        expect(row).toMatchObject({ source: "emote", kind: "private", bucket: "originals", content_type: "image/gif", bytes: 3000, width: 200, height: 150, key_id: "key-1", name: "emote.gif", visibility: "private" });
        expect(originals().get(row.r2_key)!.bytes).toHaveLength(3000);
        expect(drafts()).toHaveLength(1);
        const titled = await json(await send(`/7tv/drafts/${id}/save`, { method: "POST", body: JSON.stringify({ title: "lia dance" }) }));
        expect((db.raw.prepare("SELECT name FROM media_items WHERE id = ?").get(titled.body.file_id) as any).name).toBe("lia dance.gif");
        expect((db.raw.prepare("SELECT title FROM media_titles WHERE post_key = ?").get(titled.body.item_id) as any)?.title).toBe("lia dance");
        expect((await send(`/7tv/drafts/${"B".repeat(22)}/save`, { method: "POST", body: "{}" })).status).toBe(404);
    });

    describe("uploading a draft (71.2)", () => {
        beforeEach(async () => {
            await link();
            calls = [];
            put("file-png", "image/png");
        });

        it("sends the draft's bytes as they are, no fit, and remembers draft:<id>", async () => {
            const id = (await make({ file: "file-png" })).body.draft_id as string;
            fits.length = 0;
            answer = () => ({ body: { data: { emoteSets: { emoteSet: { addEmote: { id: SET_MAIN } } } } } });
            const r = await json(await send("/7tv/emotes", { method: "POST", body: JSON.stringify({ draft: id, name: "liaDance", set_id: SET_MAIN }) }));
            expect(r).toEqual({
                status: 201,
                body: { status: "success", emote_id: "01JUP0000000000000000000AB", name: "liaDance", file_id: null, page_url: "https://7tv.app/emotes/01JUP0000000000000000000AB", pending: true, fitted: null, added: { set_id: SET_MAIN, alias: null } },
            });
            expect(uploads).toEqual([{ auth: `Bearer ${TOKEN}`, metadata: { name: "liaDance", tags: [], default_zero_width: false, private: false }, type: "image/gif", size: 3000 }]);
            expect(fits).toHaveLength(0);
            expect((await json(await send("/7tv/uploads"))).body.uploads).toEqual([
                { file_id: `draft:${id}`, emote_id: "01JUP0000000000000000000AB", name: "liaDance", set_id: SET_MAIN, created_at: clock },
            ]);
        });

        it("refuses a missing, foreign or expired draft, a draft too big for 7TV, and draft with file, crop or size", async () => {
            const id = (await make({ file: "file-png" })).body.draft_id as string;
            const up = async (b: object) => json(await send("/7tv/emotes", { method: "POST", body: JSON.stringify({ name: "a", ...b }) }));
            expect(code(await up({ draft: "C".repeat(22) }))).toBe("error.seventv.draft_not_found");
            expect(code(await up({ draft: id, file: "file-png" }))).toBe("error.seventv.bad");
            expect(code(await up({ draft: id, size: 128 }))).toBe("error.seventv.bad");
            expect(code(await up({ draft: id, crop: { x: 0, y: 0, w: 1, h: 1 } }))).toBe("error.seventv.bad");
            expect(code(await up({ draft: "short" }))).toBe("error.seventv.bad");
            expect(code(await up({}))).toBe("error.seventv.bad");
            // over 7 MiB less 64 KiB (fixed quality came out over the cap)
            originals().get(drafts()[0]!)!.bytes = new Uint8Array(7 * 1024 * 1024);
            expect((await up({ draft: id })).status).toBe(413);
            expect(code(await up({ draft: id }))).toBe("error.seventv.too_big");
            clock += DAY;
            expect(code(await up({ draft: id }))).toBe("error.seventv.draft_not_found");
            expect(uploads).toHaveLength(0);
        });
    });
});
