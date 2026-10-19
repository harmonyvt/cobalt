// Stage (APP-API-CONTRACT.md section 30): settings, the pool, codes, the store and its lock, the canvas token,
// owner actions and capabilities. The Worker and the real SQL run together; the room and the Space are fakes.
import { describe, expect, it, vi } from "vitest";
import { AUTH, API, CLIENT, MEDIA, STAGE, T0, world, type World } from "./stage-world";
import { emptyRoom, nextChaosUntil, reduceRoom, roomPort, sameSecret, spotlightView, stageBaseFrom, stageRetention } from "../src/stage";
import { decide } from "../src/gate";

const COL = "Coll000000000001";
const COL2 = "Coll000000000002";
const GRP = "Grp0000000000001";
const SET1 = "1000000000000000001";
const SET2 = "1000000000000000002";
const SET3 = "1000000000000000003";

const ids = (items: { id: string }[]) => items.map((i) => i.id);
const poolOf = async (w: World) => (await w.siteJson(`/live/${await w.token()}/state`)).body.pool as any[];

describe("capabilities (30.1)", () => {
    const features = async (w: World) => ((await (await w.api("/capabilities")).json()) as any).features;

    it("stage is true exactly while STAGE_BASE_URL is an https URL, and stage_twitch needs all three secrets", async () => {
        expect(await features(await world())).toMatchObject({ stage: true, stage_twitch: true });
        expect(await features(await world({ twitch: false }))).toMatchObject({ stage: true, stage_twitch: false });
        expect(await features(await world({ env: { TWITCH_EVENTSUB_SECRET: "" } }))).toMatchObject({ stage: true, stage_twitch: false });
        expect(await features(await world({ env: { TWITCH_CLIENT_ID: "" } }))).toMatchObject({ stage: true, stage_twitch: false });
        expect(await features(await world({ stage: false }))).toMatchObject({ stage: false, stage_twitch: false });
        expect(await features(await world({ env: { STAGE_BASE_URL: "http://studio.capybaraharmony.com/" } }))).toMatchObject({ stage: false, stage_twitch: false });
        expect(await features(await world({ env: { STAGE_BASE_URL: "" } }))).toMatchObject({ stage: false });
        // no stage means no stage_twitch even with the secrets
        expect((await features(await world({ stage: false }))).stage_twitch).toBe(false);
    });

    it("with stage off every /stage* route is 404 error.stage.off and the stage host answers 404", async () => {
        const w = await world({ stage: false });
        for (const [m, p] of [["GET", "/stage"], ["PATCH", "/stage"], ["POST", "/stage/rotate"], ["GET", "/stage/pool"], ["GET", "/stage/redemptions"]] as const) {
            const r = await w.owner(m, p, m === "PATCH" ? {} : undefined);
            expect(r.status, `${m} ${p}`).toBe(404);
            expect(r.body.error.code).toBe("error.stage.off");
        }
        // the host is not routed at all: the gate 404s it
        const host = await w.handle(new Request(`${STAGE}store`));
        expect(host.status).toBe(404);
    });

    it("the studio host never falls through to the API: with stage off, or on another host, every path there is 404", async () => {
        const hostsOf = async (w: World, base: string) => {
            const out: Record<string, number> = {};
            for (const path of ["/capabilities", "/", "/stage", "/library", "/live/abc", "/health"]) {
                for (const method of ["GET", "POST"]) out[`${method} ${path}`] = (await w.handle(new Request(`${base}${path}`, { method, headers: AUTH }))).status;
            }
            return out;
        };
        for (const w of [await world({ stage: false }), await world({ env: { STAGE_BASE_URL: "" } })]) {
            // the API host still answers, so the 404s below are the host's, not a broken world
            expect((await w.api("/capabilities")).status).toBe(200);
            const seen = await hostsOf(w, "https://studio.capybaraharmony.com");
            expect(Object.values(seen).every((st) => st === 404), JSON.stringify(seen)).toBe(true);
        }
        // stage on at one host: a second studio.* name is not it either
        const on = await world();
        expect((await on.handle(new Request("https://studio.example.com/capabilities", { headers: AUTH }))).status).toBe(404);
        expect((await on.handle(new Request("https://studio.capybaraharmony.com/store"))).status).toBe(404);
        expect((await on.api("/capabilities")).status).toBe(200);
    });
});

describe("the gate (30.10)", () => {
    const req = (method: string, pathname: string, over: Record<string, unknown> = {}) =>
        decide({ method, pathname, searchParams: new URLSearchParams(), origin: null, authorization: `Api-Key ${CLIENT}`, ...over }, { corsUrl: "https://cobalt.capybaraharmony.com", now: T0 });

    it("routes the keyed stage paths and nothing else", () => {
        const then = (m: string, p: string) => (req(m, p) as any).then;
        expect(then("GET", "/stage")).toBe("stage_get");
        expect(then("PATCH", "/stage")).toBe("stage_patch");
        expect(then("POST", "/stage/rotate")).toBe("stage_rotate");
        expect(then("POST", "/stage/action")).toBe("stage_action");
        expect(then("GET", "/stage/pool")).toBe("stage_pool");
        expect(then("GET", "/stage/redemptions")).toBe("stage_redemptions");
        expect(then("POST", "/stage/twitch/connect")).toBe("stage_twitch_connect");
        expect(then("DELETE", "/stage/twitch")).toBe("stage_twitch_delete");
        expect(req("PATCH", "/stage/rewards/pin")).toMatchObject({ then: "stage_reward", params: { action: "pin" } });
        for (const [m, p] of [["POST", "/stage"], ["GET", "/stage/rotate"], ["PATCH", "/stage/rewards/bogus"], ["GET", "/stage/rewards/pin"], ["GET", "/stage/x"], ["PUT", "/stage/twitch"]]) {
            expect(req(m!, p!), `${m} ${p}`).toMatchObject({ action: "reject", status: 404 });
        }
    });

    it("needs a key (401) and gives a service credential a 404", () => {
        expect(req("GET", "/stage", { authorization: null })).toMatchObject({ action: "reject", status: 401 });
        expect(req("GET", "/stage", { authorization: null, service: true })).toMatchObject({ action: "reject", status: 404 });
    });

    it("answers with no-store", async () => {
        const w = await world();
        expect((await w.owner("GET", "/stage")).res.headers.get("cache-control")).toBe("no-store");
        const bad = await w.handle(new Request(`${API}/stage`));
        expect(bad.status).toBe(401);
    });
});

describe("settings (30.2, 30.10)", () => {
    it("are created on first read with the documented defaults, a 32-char token and four seeded rewards", async () => {
        const w = await world();
        const { body, status } = await w.owner("GET", "/stage");
        expect(status).toBe(200);
        expect(body.status).toBe("success");
        const s = body.stage;
        expect(s).toMatchObject({
            on_air: false,
            density: 30,
            tile_seconds: 10,
            tile_scale: 1,
            spotlight_auto: true,
            spotlight_seconds: 20,
            sound: true,
            sound_all: false,
            play_through: false,
            video_max: 12,
            store_open: false,
            store_hint: true,
            twitch: null,
            spotlight: null,
        });
        expect(s.pool).toMatchObject({ kind: "library", ref: null, name: "whole library", count: 0, missing: false });
        expect(w.stageRow().live_token).toMatch(/^[A-Za-z0-9]{32}$/);
        expect(s.live_url).toBe(`${STAGE}live/${w.stageRow().live_token}`);
        expect(s.store_url).toBe(`${STAGE}store`);
        expect(body.rewards).toEqual([
            { action: "summon", title: "summon", cost: 500, cooldown_seconds: 30, enabled: true, synced: false },
            { action: "chaos", title: "chaos", cost: 2000, cooldown_seconds: 300, enabled: true, synced: false },
            { action: "shuffle", title: "shuffle", cost: 1000, cooldown_seconds: 120, enabled: true, synced: false },
            { action: "pin", title: "pin", cost: 300, cooldown_seconds: 60, enabled: false, synced: false },
        ]);
        expect(w.one("SELECT prompt FROM stage_rewards WHERE action = 'summon'").prompt).toBe("a code from the store, or a few words");
        // a second read changes nothing
        const token = w.stageRow().live_token;
        await w.owner("GET", "/stage");
        expect(w.stageRow().live_token).toBe(token);
        expect(w.q("SELECT * FROM stage_rewards")).toHaveLength(4);
    });

    it("PATCH saves, clamps out-of-range numbers and answers the whole stage", async () => {
        const w = await world();
        const r = await w.owner("PATCH", "/stage", { density: 5000, tile_seconds: 1, tile_scale: 9, spotlight_seconds: 1, video_max: 99, sound: false, store_hint: false });
        expect(r.status).toBe(200);
        expect(r.body.stage).toMatchObject({ density: 100, tile_seconds: 3, tile_scale: 1.6, spotlight_seconds: 10, video_max: 24, sound: false, store_hint: false });
        const lo = await w.owner("PATCH", "/stage", { density: -4, tile_seconds: 500, tile_scale: 0.01, spotlight_seconds: 9999, video_max: -3 });
        expect(lo.body.stage).toMatchObject({ density: 5, tile_seconds: 120, tile_scale: 0.5, spotlight_seconds: 120, video_max: 0 });
        const mid = await w.owner("PATCH", "/stage", { density: 42.4, tile_scale: 1.2345, on_air: true, spotlight_auto: false });
        expect(mid.body.stage).toMatchObject({ density: 42, tile_scale: 1.23, on_air: true, spotlight_auto: false });
        expect(w.stageRow()).toMatchObject({ density: 42, on_air: 1, spotlight_auto: 0 });
    });

    it("PATCH takes the two video switches (sound_all, play_through) and the canvas sees them", async () => {
        const w = await world();
        const r = await w.owner("PATCH", "/stage", { sound_all: true, play_through: true });
        expect(r.status).toBe(200);
        expect(r.body.stage).toMatchObject({ sound_all: true, play_through: true });
        expect(w.stageRow()).toMatchObject({ sound_all: 1, play_through: 1 });
        const t = await w.token();
        const st = await w.siteJson(`/live/${t}/state`);
        expect(st.body.stage).toMatchObject({ sound_all: true, play_through: true });
        const off = await w.owner("PATCH", "/stage", { sound_all: false });
        expect(off.body.stage).toMatchObject({ sound_all: false, play_through: true });
        // not booleans: refused, nothing changes
        const bad = await w.owner("PATCH", "/stage", { play_through: "yes" });
        expect(bad.status).toBe(400);
        expect(w.stageRow()).toMatchObject({ sound_all: 0, play_through: 1 });
    });

    it("refuses what is not a number, a boolean or a pool", async () => {
        const w = await world();
        for (const body of [
            { density: "30" },
            { on_air: "yes" },
            { sound: 1 },
            { density: null },
            { pool: "library" },
            { pool: { kind: "nope" } },
            { pool: { kind: "collection" } },
            { pool: { kind: "collection", ref: COL } }, // unknown
            { pool: { kind: "collection", ref: "short" } },
            { pool: { kind: "group", ref: GRP } }, // unknown
            { pool: { kind: "search", ref: "   " } },
            { pool: { kind: "search" } },
        ]) {
            const r = await w.owner("PATCH", "/stage", body);
            expect(r.status, JSON.stringify(body)).toBe(400);
            expect(r.body.error.code).toBe("error.stage.bad_request");
        }
        const notJson = await w.api("/stage", { method: "PATCH", body: "x" });
        expect(notJson.status).toBe(400);
        expect(w.stageRow()?.density ?? 30).toBe(30);
    });

    it("pushes a settings event, and a pool event when the pool changed", async () => {
        const w = await world();
        await w.owner("PATCH", "/stage", { density: 50 });
        expect(w.room.types()).toEqual(["settings"]);
        expect(w.room.last("settings")!.stage).toMatchObject({ density: 50, on_air: false, store_url: null });
        w.room.events.length = 0;
        await w.owner("PATCH", "/stage", { pool: { kind: "library" } });
        expect(w.room.types()).toEqual(["settings", "pool"]);
    });

    it("keeps working when the room is down", async () => {
        const w = await world();
        w.room.broken = true;
        const r = await w.owner("PATCH", "/stage", { density: 60 });
        expect(r.status).toBe(200);
        expect(r.body.stage.density).toBe(60);
    });
});

describe("the pool (30.3)", () => {
    it("library: the public files, newest first; private, deleted and unplayable files never", async () => {
        const w = await world();
        const a = w.file();
        const b = w.video();
        w.file({ private: true });
        w.file({ deleted_at: T0 });
        w.file({ content_type: "image/heic", ext: "heic" });
        w.file({ content_type: "application/pdf", ext: "pdf" });
        const c = w.file({ visibility: null }); // not migrated yet: bucket 'media' reads as public
        const items = await poolOf(w);
        expect(ids(items)).toEqual([c.id, b.id, a.id]);
        expect(items.find((i) => i.id === b.id)).toMatchObject({ kind: "video", url: b.url, duration: 9.6, width: 480, height: 560 });
        expect(items.find((i) => i.id === b.id).poster_url).toMatch(/^https:\/\/media\.capybaraharmony\.com\/Poster\d+\.jpg$/);
        expect(items.find((i) => i.id === a.id)).toMatchObject({ kind: "image", url: a.url, poster_url: null, duration: null });
        const owner = await w.owner("GET", "/stage");
        expect(owner.body.stage.pool.count).toBe(3);
    });

    it("library: a public original keeps its public URL; a private one never shows", async () => {
        const w = await world();
        const pub = w.file({ source: "saved", bucket: "originals", r2_key: "originals/s1.mp4", public_key: "PubKey0001.mp4", url: `${MEDIA}PubKey0001.mp4`, content_type: "video/mp4", visibility: "public" });
        w.file({ source: "saved", bucket: "originals", r2_key: "originals/s2.mp4", public_key: "PubKey0002.mp4", url: `${MEDIA}PubKey0002.mp4`, content_type: "video/mp4", visibility: "private" });
        const items = await poolOf(w);
        expect(items).toHaveLength(1);
        expect(items[0]).toMatchObject({ id: pub.id, url: `${MEDIA}PubKey0001.mp4`, kind: "video" });
    });

    it("library: at most 2,000 files", async () => {
        const w = await world();
        w.db.raw.exec("BEGIN");
        for (let i = 0; i < 2105; i++) w.file();
        w.db.raw.exec("COMMIT");
        const r = await w.owner("GET", "/stage");
        expect(r.body.stage.pool.count).toBe(2000);
        expect(JSON.parse(w.stageRow().pool_ids)).toHaveLength(2000);
    });

    it("a file made private (or deleted) after the pool was resolved leaves at once", async () => {
        const w = await world();
        const a = w.file();
        const b = w.file();
        const c = w.file();
        expect(ids(await poolOf(w))).toEqual([c.id, b.id, a.id]);
        w.db.raw.prepare("UPDATE media_items SET visibility = 'private' WHERE id = ?").run(b.id);
        w.db.raw.prepare("UPDATE media_items SET deleted_at = ? WHERE id = ?").run(T0, c.id);
        expect(ids(await poolOf(w))).toEqual([a.id]);
        // the pool itself is 10 minutes old before it is resolved again
        expect(JSON.parse(w.stageRow().pool_ids)).toEqual([c.id, b.id, a.id]);
    });

    it("is resolved again when it is older than 10 minutes (new saves join)", async () => {
        const w = await world();
        const a = w.file();
        expect(ids(await poolOf(w))).toEqual([a.id]);
        const b = w.file();
        w.tick(9 * 60_000);
        expect(ids(await poolOf(w))).toEqual([a.id]);
        w.tick(2 * 60_000);
        expect(ids(await poolOf(w))).toEqual([b.id, a.id]);
    });

    it("collection: every file of every live link, in the collection's order; private files and revoked links excluded", async () => {
        const w = await world();
        const f = [w.file(), w.file(), w.file(), w.file(), w.file()];
        w.db.raw.prepare("UPDATE media_items SET visibility = 'private' WHERE id = ?").run(f[1]!.id);
        w.set(SET1, [f[0]!.id, f[1]!.id]);
        w.set(SET2, [f[2]!.id, f[3]!.id]);
        w.set(SET3, [f[4]!.id], { revoked_at: T0 });
        w.collection(COL, "tonight", [SET1, SET2, SET3]);
        const r = await w.owner("PATCH", "/stage", { pool: { kind: "collection", ref: COL } });
        expect(r.status).toBe(200);
        expect(r.body.stage.pool).toEqual({ kind: "collection", ref: COL, name: "tonight", count: 3, missing: false });
        expect(ids(await poolOf(w))).toEqual([f[0]!.id, f[2]!.id, f[3]!.id]);
        expect(w.room.types()).toEqual(["settings", "pool"]);
    });

    it("collection: a deleted collection is missing, the pool is empty", async () => {
        const w = await world();
        const f = w.file();
        w.set(SET1, [f.id]);
        w.collection(COL, "tonight", [SET1]);
        await w.owner("PATCH", "/stage", { pool: { kind: "collection", ref: COL } });
        expect(await poolOf(w)).toHaveLength(1);
        w.db.raw.prepare("DELETE FROM share_collections WHERE id = ?").run(COL);
        w.db.raw.prepare("DELETE FROM share_collection_items WHERE collection_id = ?").run(COL);
        const r = await w.owner("GET", "/stage");
        expect(r.body.stage.pool).toEqual({ kind: "collection", ref: COL, name: null, count: 0, missing: true });
        expect(await poolOf(w)).toEqual([]);
        const store = await w.siteJson("/store/api/pool");
        expect(store.status).toBe(404); // locked: still says nothing
        await w.owner("PATCH", "/stage", { store_open: true });
        expect((await w.siteJson("/store/api/pool")).body).toMatchObject({ total: 0, items: [], pool_name: "nothing" });
    });

    it("group: every file of every collection in the set", async () => {
        const w = await world();
        const f = [w.file(), w.file(), w.file()];
        w.set(SET1, [f[0]!.id]);
        w.set(SET2, [f[1]!.id, f[2]!.id]);
        w.collection(COL, "one", [SET1]);
        w.collection(COL2, "two", [SET2]);
        w.group(GRP, "both", [COL, COL2]);
        const r = await w.owner("PATCH", "/stage", { pool: { kind: "group", ref: GRP } });
        expect(r.body.stage.pool).toEqual({ kind: "group", ref: GRP, name: "both", count: 3, missing: false });
        expect(ids(await poolOf(w)).sort()).toEqual(ids(f).sort());
        w.db.raw.prepare("DELETE FROM collection_groups WHERE id = ?").run(GRP);
        expect((await w.owner("GET", "/stage")).body.stage.pool).toMatchObject({ missing: true, count: 0, name: null });
    });

    it("search: the posts that best match, best first, then their public files", async () => {
        const w = await world({ search: true });
        const cat1 = w.file({ name: "cat.webp" });
        const dog = w.file({ name: "dog.webp" });
        const cat2 = w.file({ name: "kitten.webp", content_type: "image/gif", ext: "gif" });
        const hidden = w.file({ name: "cat private", private: true });
        w.space.axes = { cats: 0 };
        w.embedding(cat1.id, 0);
        w.embedding(dog.id, 1);
        w.embedding(cat2.id, 0);
        w.embedding(hidden.id, 0);
        const r = await w.owner("PATCH", "/stage", { pool: { kind: "search", ref: "cats" } });
        expect(r.status).toBe(200);
        expect(r.body.stage.pool).toMatchObject({ kind: "search", ref: "cats", name: "cats" });
        const got = ids(await poolOf(w));
        // the two cat posts first (score 1), the dog post (score 0) is not a hit at all
        expect(got.slice(0, 2).sort()).toEqual([cat1.id, cat2.id].sort());
        expect(got).not.toContain(hidden.id);
        expect(got).not.toContain(dog.id);
    });

    it("search: with search off or asleep PATCH answers 503 and nothing changes", async () => {
        const off = await world();
        off.file();
        await off.owner("PATCH", "/stage", { density: 40 });
        const r = await off.owner("PATCH", "/stage", { density: 77, pool: { kind: "search", ref: "cats" } });
        expect(r.status).toBe(503);
        expect(r.body.error.code).toBe("error.stage.search_unavailable");
        expect(off.stageRow()).toMatchObject({ density: 40, pool_kind: "library" });
        expect(off.room.types()).toEqual(["settings"]); // only the first PATCH

        const asleep = await world({ search: true });
        asleep.space.down = true;
        const r2 = await asleep.owner("PATCH", "/stage", { pool: { kind: "search", ref: "cats" } });
        expect(r2.status).toBe(503);
        expect(r2.body.error.code).toBe("error.stage.search_unavailable");
        expect(asleep.stageRow()?.pool_kind ?? "library").toBe("library");
    });

    it("an empty pool is allowed", async () => {
        const w = await world();
        expect(await poolOf(w)).toEqual([]);
        await w.owner("PATCH", "/stage", { store_open: true });
        expect((await w.siteJson("/store/api/pool")).body).toMatchObject({ total: 0, next: null, items: [], pool_name: "everything" });
    });

    it("titles: the post's title, else the roast caption, else the file name", async () => {
        const w = await world();
        const named = w.file({ name: "plain name.webp" });
        const captioned = w.file({ name: "x.webp" });
        const titled = w.file({ name: "y.webp" });
        w.db.raw.prepare("INSERT INTO media_captions (subject, title, description, model, created_at, attempts) VALUES (?, 'a funny caption', '', 'm', ?, 1)").run(`item:${captioned.id}`, T0);
        w.db.raw.prepare("INSERT INTO media_captions (subject, title, description, model, created_at, attempts) VALUES (?, 'ignored caption', '', 'm', ?, 1)").run(`item:${titled.id}`, T0);
        w.title(titled.id, "my own title"); // the post key of a bare file is its id
        const byId = Object.fromEntries((await poolOf(w)).map((i: any) => [i.id, i.title]));
        expect(byId).toEqual({ [named.id]: "plain name", [captioned.id]: "a funny caption", [titled.id]: "my own title" });
    });
});

describe("codes (30.2)", () => {
    it("every pool item gets a unique 3-char code from the alphabet, kept forever, matched case-insensitively", async () => {
        const w = await world();
        const files = Array.from({ length: 40 }, () => w.file());
        const first = await poolOf(w);
        const codes = first.map((i: any) => i.code);
        expect(new Set(codes).size).toBe(40);
        for (const c of codes) expect(c).toMatch(/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{3}$/);
        expect(w.q("SELECT * FROM stage_codes")).toHaveLength(40);
        // resolved again later: the same codes
        w.tick(11 * 60_000);
        const second = await poolOf(w);
        expect(Object.fromEntries(second.map((i: any) => [i.id, i.code]))).toEqual(Object.fromEntries(first.map((i: any) => [i.id, i.code])));
        // new files get new codes, old ones are not reused
        const extra = w.file();
        w.tick(11 * 60_000);
        const third = await poolOf(w);
        expect(third.find((i: any) => i.id === extra.id).code).not.toBeUndefined();
        expect(new Set(third.map((i: any) => i.code)).size).toBe(41);
        void files;
    });

    it("the store finds an item by its code in any case", async () => {
        const w = await world();
        // titles with no letters or digits, so no piece of a code can match a title
        const a = w.file({ name: "---.webp" });
        w.file({ name: "+++.webp" });
        await w.owner("PATCH", "/stage", { store_open: true });
        const code = (await poolOf(w)).find((i: any) => i.id === a.id).code as string;
        for (const q of [code, code.toLowerCase()]) {
            const r = await w.siteJson(`/store/api/pool?q=${q}`);
            expect(ids(r.body.items)).toEqual([a.id]);
        }
        // a code is exact: a piece of it is not a title either
        expect((await w.siteJson(`/store/api/pool?q=${code.slice(0, 2)}`)).body.items.filter((i: any) => i.id === a.id)).toHaveLength(0);
    });

    it("are 4 chars once more than half of the 3-char codes are used", async () => {
        const w = await world();
        const fresh = w.file();
        // 16,385 of the 32,768 3-char codes are taken
        const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        w.db.raw.exec("BEGIN");
        const ins = w.db.raw.prepare("INSERT INTO stage_codes (code, item_id, created_at) VALUES (?, ?, 0)");
        let n = 0;
        outer: for (const a of alphabet) for (const b of alphabet) for (const c of alphabet) {
            ins.run(a + b + c, `gone${n}`);
            if (++n > 16384) break outer;
        }
        w.db.raw.exec("COMMIT");
        const items = await poolOf(w);
        expect(items[0].id).toBe(fresh.id);
        expect(items[0].code).toMatch(/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}$/);
    });
});

describe("the canvas token and pages (30.4)", () => {
    it("a wrong token is a plain 404 everywhere", async () => {
        const w = await world();
        await w.token();
        const bad = "x".repeat(32);
        for (const p of [`/live/${bad}`, `/live/${bad}/ws`, `/live/short`, `/live/`, `/live`, `/live/${bad}/nope`]) {
            const r = await w.site(p);
            expect(r.status, p).toBe(404);
        }
        const st = await w.siteJson(`/live/${bad}/state`);
        expect(st.status).toBe(404);
        expect(st.body.error.code).toBe("error.stage.not_found");
        expect(w.room.connects).toHaveLength(0);
    });

    it("the right token serves the page with no-store and noindex; ?preview=1 too", async () => {
        const w = await world();
        const t = await w.token();
        for (const p of [`/live/${t}`, `/live/${t}?preview=1`]) {
            const r = await w.site(p);
            expect(r.status).toBe(200);
            expect(r.headers.get("content-type")).toContain("text/html");
            expect(r.headers.get("cache-control")).toBe("no-store");
            expect(r.headers.get("x-robots-tag")).toBe("noindex");
            expect(await r.text()).toContain("<html");
        }
        // only GET (and HEAD): the host is not an API
        expect((await w.site(`/live/${t}`, { method: "POST" })).status).toBe(404);
        expect((await w.site("/api")).status).toBe(404);
        expect((await w.site("/")).status).toBe(404);
    });

    it("state: settings, the pool, the spotlight; store_url is null while the store is locked", async () => {
        const w = await world();
        const a = w.file();
        const t = await w.token();
        const locked = await w.siteJson(`/live/${t}/state`);
        expect(locked.status).toBe(200);
        expect(locked.body).toMatchObject({
            status: "success",
            stage: { on_air: false, density: 30, tile_seconds: 10, tile_scale: 1, spotlight_auto: true, spotlight_seconds: 20, sound: true, sound_all: false, play_through: false, video_max: 12, store_hint: true, store_url: null },
            spotlight: null,
        });
        expect(ids(locked.body.pool)).toEqual([a.id]);
        expect(locked.res.headers.get("cache-control")).toBe("no-store");
        await w.owner("PATCH", "/stage", { store_open: true });
        expect((await w.siteJson(`/live/${t}/state`)).body.stage.store_url).toBe(`${STAGE}store`);
    });

    it("ws: needs the upgrade, then the room takes the request", async () => {
        const w = await world();
        const t = await w.token();
        expect((await w.site(`/live/${t}/ws`)).status).toBe(426);
        const r = await w.site(`/live/${t}/ws`, { headers: { upgrade: "websocket" } });
        expect(r.headers.get("x-room")).toBe("ws");
        expect(w.room.connects).toHaveLength(1);
    });

    it("rotating the token kills the old one, tells the room, and keeps the settings", async () => {
        const w = await world();
        const old = await w.token();
        await w.owner("PATCH", "/stage", { density: 60 });
        const r = await w.owner("POST", "/stage/rotate");
        expect(r.status).toBe(200);
        const fresh = w.stageRow().live_token;
        expect(fresh).not.toBe(old);
        expect(fresh).toMatch(/^[A-Za-z0-9]{32}$/);
        expect(r.body.stage.live_url).toBe(`${STAGE}live/${fresh}`);
        expect(w.room.types()).toContain("rotated");
        expect((await w.site(`/live/${old}`)).status).toBe(404);
        expect((await w.siteJson(`/live/${old}/state`)).status).toBe(404);
        expect((await w.site(`/live/${fresh}`)).status).toBe(200);
        expect(w.stageRow().density).toBe(60);
    });

    it("state returns the room's spotlight only while it is fresh or pinned, and the chaos that is still on", async () => {
        const w = await world();
        const a = w.file();
        const t = await w.token();
        await w.goLive();
        const [item] = await poolOf(w);
        await w.room.send({ type: "summon", spotlight: { item, by: "Ann", action: "summon", pinned_until: null, at: w.now() }, toast: null });
        await w.room.send({ type: "chaos", until: w.now() + 30_000, toast: { by: "Ann", action: "chaos", cost: 2000, detail: "x" } });
        let s = (await w.siteJson(`/live/${t}/state`)).body;
        expect(s.spotlight).toMatchObject({ by: "Ann", action: "summon", pinned_until: null, at: T0, item: { id: a.id } });
        expect(s.chaos_until).toBe(T0 + 30_000);
        w.tick(21_000);
        s = (await w.siteJson(`/live/${t}/state`)).body;
        expect(s.spotlight).toBeNull();
        expect(s.chaos_until).toBe(T0 + 30_000);
        // a pin does not bring back a spotlight that had already run out (the canvas pins its own random one)
        await w.room.send({ type: "pin", pinned_until: w.now() + 120_000, toast: null });
        s = (await w.siteJson(`/live/${t}/state`)).body;
        expect(s.spotlight).toBeNull();
        await w.room.send({ type: "summon", spotlight: { item, by: "Bo", action: "summon", pinned_until: null, at: w.now() }, toast: null });
        await w.room.send({ type: "pin", pinned_until: w.now() + 120_000, toast: null });
        w.tick(40_000);
        s = (await w.siteJson(`/live/${t}/state`)).body;
        expect(s.spotlight).toMatchObject({ by: "Bo", pinned_until: w.now() - 40_000 + 120_000 });
        s = (await w.siteJson(`/live/${t}/state`)).body;
        expect(s.chaos_until).toBeNull();
    });
});

describe("the room's spotlight is checked against the library (30.4, 30.10)", () => {
    it("a spotlight whose file went private or was deleted is dropped from /state and GET /stage", async () => {
        const w = await world();
        const a = w.file({ name: "red cat.webp" });
        const b = w.file({ name: "blue dog.webp" });
        const t = await w.token();
        await w.goLive();
        const [item] = await poolOf(w);
        await w.room.send({ type: "summon", spotlight: { item, by: "Ann", action: "summon", pinned_until: null, at: w.now() }, toast: null });
        expect((await w.siteJson(`/live/${t}/state`)).body.spotlight.item.id).toBe(item.id);
        expect((await w.owner("GET", "/stage")).body.stage.spotlight.item.id).toBe(item.id);
        // private now
        w.db.raw.prepare("UPDATE media_items SET visibility = 'private', kind = 'private', bucket = 'originals', url = NULL WHERE id = ?").run(item.id);
        expect((await w.siteJson(`/live/${t}/state`)).body.spotlight).toBeNull();
        expect((await w.owner("GET", "/stage")).body.stage.spotlight).toBeNull();
        // deleted, and pinned: still gone
        const other = item.id === a.id ? b : a;
        await w.room.send({ type: "summon", spotlight: { item: { ...item, id: other.id }, by: "Bo", action: "summon", pinned_until: null, at: w.now() }, toast: null });
        await w.room.send({ type: "pin", pinned_until: w.now() + 120_000, toast: null });
        expect((await w.siteJson(`/live/${t}/state`)).body.spotlight).toMatchObject({ by: "Bo", pinned_until: expect.any(Number) });
        w.db.raw.prepare("UPDATE media_items SET deleted_at = ? WHERE id = ?").run(T0, other.id);
        expect((await w.siteJson(`/live/${t}/state`)).body.spotlight).toBeNull();
        expect((await w.owner("GET", "/stage")).body.stage.spotlight).toBeNull();
    });

    it("what the canvas gets is the file as it is now (a renamed post shows its new title)", async () => {
        const w = await world();
        w.file({ name: "red cat.webp", post_key: "p1" });
        const t = await w.token();
        await w.goLive();
        const [item] = await poolOf(w);
        await w.room.send({ type: "summon", spotlight: { item, by: "Ann", action: "summon", pinned_until: null, at: w.now() }, toast: null });
        w.title("p1", "renamed");
        expect((await w.siteJson(`/live/${t}/state`)).body.spotlight.item.title).toBe("renamed");
    });
});

describe("logs keep the canvas token out (30.4)", () => {
    it("a failing /live/<token>/state logs the path with the token replaced", async () => {
        const w = await world();
        const t = await w.token();
        const spy = vi.spyOn(console, "error").mockImplementation(() => undefined);
        try {
            const prepare = w.db.prepare.bind(w.db);
            let reads = 0;
            // the token check (the first settings read) passes, the state read after it fails
            (w.db as any).prepare = (sql: string) => {
                if (sql.includes("FROM stage_settings") && ++reads > 1) throw new Error("D1_ERROR: simulated outage");
                return prepare(sql);
            };
            const res = await w.site(`/live/${t}/state`);
            expect(res.status).toBe(503);
            const lines = spy.mock.calls.map((c) => c.map(String).join(" "));
            expect(lines.some((l) => l.includes("/live/<token>/state"))).toBe(true);
            expect(lines.join("\n")).not.toContain(t);
        } finally {
            spy.mockRestore();
        }
    });
});

describe("the store and its lock (30.4)", () => {
    it("locked (the default): /store is a 404 page that says only 'nothing here.', and every /store/api route is 404 store_locked", async () => {
        const w = await world();
        w.file();
        const page = await w.site("/store");
        expect(page.status).toBe(404);
        expect(page.headers.get("content-type")).toContain("text/html");
        expect(page.headers.get("cache-control")).toBe("no-store");
        const html = await page.text();
        expect(html).toContain("nothing here.");
        expect(html).not.toContain("<script");
        expect(html).not.toContain("twitch-client-id"); // the client id is not in it
        expect(html).not.toMatch(/id\.twitch\.tv/);
        for (const p of ["/store/api/pool", "/store/api/rewards", "/store/api/me", "/store/api/pool?q=a", "/store/api/other"]) {
            const r = await w.siteJson(p, { headers: { authorization: "Bearer abcdefghijklmnop" } });
            expect(r.status, p).toBe(404);
            expect(r.body.error.code).toBe("error.stage.store_locked");
            expect(r.res.headers.get("cache-control")).toBe("no-store");
        }
    });

    it("open: the page carries the Twitch client id only with Twitch configured; locking again closes it at once", async () => {
        const w = await world();
        await w.owner("PATCH", "/stage", { store_open: true });
        const page = await w.site("/store");
        expect(page.status).toBe(200);
        expect(page.headers.get("cache-control")).toBe("no-store");
        expect(await page.text()).toContain("twitch-client-id");
        expect((await w.siteJson("/store/api/pool")).status).toBe(200);

        await w.owner("PATCH", "/stage", { store_open: false });
        expect((await w.site("/store")).status).toBe(404);
        expect((await w.siteJson("/store/api/pool")).body.error.code).toBe("error.stage.store_locked");

        const plain = await world({ twitch: false });
        await plain.owner("PATCH", "/stage", { store_open: true });
        const html = await (await plain.site("/store")).text();
        expect(html).toContain("<html");
        expect(html).not.toContain("twitch-client-id");
    });

    it("pool: pages with next, filters by title substring, and carries store items (thumb_url, no url or duration)", async () => {
        const w = await world();
        const files = [w.file({ name: "red cat.webp" }), w.video({ name: "blue dog.mp4" }), w.file({ name: "red fox.webp" })];
        await w.owner("PATCH", "/stage", { store_open: true, on_air: true });
        const all = await w.siteJson("/store/api/pool");
        expect(all.body).toMatchObject({ status: "success", on_air: true, pool_name: "everything", total: 3, offset: 0, next: null });
        const item = all.body.items.find((i: any) => i.id === files[1]!.id);
        expect(item).toMatchObject({ kind: "video", title: "blue dog", thumb_url: expect.stringMatching(/Poster\d+\.jpg$/) });
        expect(item.code).toMatch(/^[A-Z2-9]{3}$/);
        expect(item).not.toHaveProperty("url");
        expect(item).not.toHaveProperty("duration");
        const image = all.body.items.find((i: any) => i.id === files[0]!.id);
        expect(image.thumb_url).toBe(files[0]!.url);

        const page1 = await w.siteJson("/store/api/pool?limit=2");
        expect(page1.body).toMatchObject({ total: 3, offset: 0, next: 2 });
        expect(page1.body.items).toHaveLength(2);
        const page2 = await w.siteJson("/store/api/pool?limit=2&offset=2");
        expect(page2.body).toMatchObject({ offset: 2, next: null });
        expect(page2.body.items).toHaveLength(1);

        const red = await w.siteJson("/store/api/pool?q=RED");
        expect(red.body.total).toBe(2);
        expect(red.body.items.map((i: any) => i.title).sort()).toEqual(["red cat", "red fox"]);

        for (const bad of ["limit=0", "limit=61", "limit=x", "offset=-1", `q=${"a".repeat(61)}`]) {
            expect((await w.siteJson(`/store/api/pool?${bad}`)).status, bad).toBe(400);
        }
    });

    it("pool_name is the collection's name, or the search words", async () => {
        const w = await world();
        const f = w.file();
        w.set(SET1, [f.id]);
        w.collection(COL, "friday night", [SET1]);
        await w.owner("PATCH", "/stage", { store_open: true, pool: { kind: "collection", ref: COL } });
        expect((await w.siteJson("/store/api/pool")).body.pool_name).toBe("friday night");
    });

    it("private files never reach the store", async () => {
        const w = await world();
        w.file({ private: true });
        const pub = w.file();
        await w.owner("PATCH", "/stage", { store_open: true });
        expect(ids((await w.siteJson("/store/api/pool")).body.items)).toEqual([pub.id]);
    });

    it("rewards: none and no channel until Twitch is connected; enabled ones after", async () => {
        const w = await world();
        await w.owner("PATCH", "/stage", { store_open: true });
        expect((await w.siteJson("/store/api/rewards")).body).toEqual({ status: "success", channel: null, rewards: [] });
        await w.connectTwitch();
        const r = (await w.siteJson("/store/api/rewards")).body;
        expect(r.channel).toBe("harmony");
        // pin is off by default
        expect(r.rewards.map((x: any) => x.action)).toEqual(["summon", "chaos", "shuffle"]);
        expect(r.rewards[0]).toEqual({ action: "summon", title: "summon", cost: 500, cooldown_seconds: 30, prompt: "a code from the store, or a few words" });
    });

    it("me: needs a token Twitch vouches for (our client id), lists the viewer's last 10 summons, keeps nothing", async () => {
        const w = await world();
        const a = w.file({ name: "alpha.webp" });
        await w.owner("PATCH", "/stage", { store_open: true });
        w.twitch.viewers.set("viewertoken1", { client_id: "twitch-client-id", login: "ann", user_id: "u-ann" });
        w.twitch.viewers.set("othertoken01", { client_id: "someone-elses-app", login: "bob", user_id: "u-bob" });
        const { items } = { items: await poolOf(w) };
        const ins = w.db.raw.prepare("INSERT INTO stage_redemptions (id, action, user_id, user_login, user_name, input, item_id, status, reason, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
        for (let i = 0; i < 12; i++) ins.run(`r${i}`, "summon", "u-ann", "ann", "Ann", `try ${i}`, i === 11 ? items[0].id : null, i === 11 ? "done" : "refunded", i === 11 ? null : "no_match", T0 + i);
        ins.run("rc", "chaos", "u-ann", "ann", "Ann", "", null, "done", null, T0 + 50);
        ins.run("ro", "summon", "u-other", "o", "O", "x", null, "done", null, T0 + 60);

        const me = await w.siteJson("/store/api/me", { headers: { authorization: "Bearer viewertoken1" } });
        expect(me.status).toBe(200);
        expect(me.body.user).toEqual({ id: "u-ann", login: "ann" });
        expect(me.body.summons).toHaveLength(10);
        expect(me.body.summons[0]).toMatchObject({ input: "try 11", status: "done", reason: null, created_at: T0 + 11, item: { id: a.id, title: "alpha" } });
        expect(me.body.summons[0].item).not.toHaveProperty("url");
        expect(me.body.summons[1]).toMatchObject({ item: null, status: "refunded", reason: "no_match" });
        expect(w.twitch.called("GET", "/oauth2/validate")).toHaveLength(1);
        expect(w.twitch.calls[0]!.headers.get("authorization")).toBe("OAuth viewertoken1");
        // nothing about the viewer was stored besides the redemptions
        expect(w.q("SELECT name FROM sqlite_master WHERE name LIKE '%viewer%'")).toEqual([]);

        for (const [header, code] of [
            [undefined, "error.stage.twitch_auth"],
            ["Bearer unknowntoken1", "error.stage.twitch_auth"],
            ["Bearer othertoken01", "error.stage.twitch_auth"],
            ["Basic abcdefghijkl", "error.stage.twitch_auth"],
        ] as const) {
            const r = await w.siteJson("/store/api/me", header ? { headers: { authorization: header } } : {});
            expect(r.status, String(header)).toBe(401);
            expect(r.body.error.code).toBe(code);
        }
    });

    it("me: 404 error.stage.off while Twitch is not configured", async () => {
        const w = await world({ twitch: false });
        await w.owner("PATCH", "/stage", { store_open: true });
        const r = await w.siteJson("/store/api/me", { headers: { authorization: "Bearer viewertoken1" } });
        expect(r.status).toBe(404);
        expect(r.body.error.code).toBe("error.stage.off");
    });
});

describe("owner actions (30.10)", () => {
    it("off air: 409 error.stage.off_air and nothing is sent", async () => {
        const w = await world();
        for (const type of ["skip", "pin", "unpin", "shuffle", "chaos"]) {
            const r = await w.owner("POST", "/stage/action", { type });
            expect(r.status, type).toBe(409);
            expect(r.body.error.code).toBe("error.stage.off_air");
        }
        expect(w.room.events).toEqual([]);
        expect(w.q("SELECT * FROM stage_redemptions")).toEqual([]);
    });

    it("bad bodies are 400", async () => {
        const w = await world();
        await w.goLive();
        for (const body of [{}, { type: "nope" }, { type: 5 }, { type: "spotlight", item_id: 5 }]) {
            expect((await w.owner("POST", "/stage/action", body)).status, JSON.stringify(body)).toBe(400);
        }
        expect((await w.api("/stage/action", { method: "POST", body: "x" })).status).toBe(400);
    });

    it("skip, pin, unpin, shuffle and chaos send their event and leave an owner redemption row", async () => {
        const w = await world();
        w.file();
        await w.goLive();
        w.room.events.length = 0;
        for (const type of ["skip", "pin", "unpin", "shuffle", "chaos"]) {
            const r = await w.owner("POST", "/stage/action", { type });
            expect(r.status, type).toBe(200);
            expect(r.body.stage.on_air).toBe(true);
        }
        expect(w.room.types()).toEqual(["skip", "pin", "unpin", "shuffle", "chaos"]);
        expect(w.room.last("pin")).toMatchObject({ pinned_until: T0 + 120_000, toast: null });
        expect(w.room.last("chaos")).toMatchObject({ until: T0 + 30_000 });
        const rows = w.q("SELECT * FROM stage_redemptions ORDER BY rowid");
        expect(rows.map((r) => r.action)).toEqual(["skip", "pin", "unpin", "shuffle", "chaos"]);
        for (const r of rows) {
            expect(r.id).toMatch(/^owner:[A-Za-z0-9]{16}$/);
            expect(r).toMatchObject({ user_name: "you", status: "done", reason: null, created_at: T0 });
        }
    });

    it("spotlight needs a pool item, is the owner's own pick, and clears a pin", async () => {
        const w = await world();
        const a = w.file({ name: "alpha.webp" });
        const hidden = w.file({ private: true });
        const other = w.file();
        await w.goLive({ pool: { kind: "library" } });
        w.db.raw.prepare("UPDATE media_items SET deleted_at = 1 WHERE id = ?").run(other.id);
        // unknown, private and (now) deleted ids are not in the pool
        for (const item_id of ["Nope000000000000", hidden.id, other.id]) {
            const r = await w.owner("POST", "/stage/action", { type: "spotlight", item_id });
            expect(r.status, item_id).toBe(404);
            expect(r.body.error.code).toBe("error.stage.not_found");
        }
        expect((await w.owner("POST", "/stage/action", { type: "spotlight" })).status).toBe(404);
        await w.owner("POST", "/stage/action", { type: "pin" });
        const ok = await w.owner("POST", "/stage/action", { type: "spotlight", item_id: a.id });
        expect(ok.status).toBe(200);
        const ev = w.room.last("summon")!;
        expect(ev.spotlight).toMatchObject({ by: null, action: "owner", pinned_until: null, at: T0, item: { id: a.id, title: "alpha", url: a.url } });
        expect(ok.body.stage.spotlight).toMatchObject({ action: "owner", item: { id: a.id }, pinned_until: null });
        const row = w.one("SELECT * FROM stage_redemptions WHERE action = 'spotlight'");
        expect(row).toMatchObject({ item_id: a.id, user_name: "you", status: "done" });
    });

    it("chaos lasts 30 s and another one extends it to at most 60 s from now", async () => {
        expect(nextChaosUntil(1000, 0)).toBe(31_000);
        expect(nextChaosUntil(1000, 500)).toBe(31_000);
        expect(nextChaosUntil(1000, 11_000)).toBe(41_000);
        expect(nextChaosUntil(1000, 31_000)).toBe(61_000);
        expect(nextChaosUntil(1000, 50_000)).toBe(61_000);
        const w = await world();
        await w.goLive();
        await w.owner("POST", "/stage/action", { type: "chaos" });
        w.tick(10_000);
        await w.owner("POST", "/stage/action", { type: "chaos" });
        expect(w.room.last("chaos")!.until).toBe(T0 + 60_000);
    });

    it("pool and redemptions routes page", async () => {
        const w = await world();
        const f = [w.file(), w.file(), w.file()];
        const p1 = await w.owner("GET", "/stage/pool?limit=2");
        expect(p1.body).toMatchObject({ status: "success", total: 3, offset: 0, next: 2 });
        expect(ids(p1.body.items)).toEqual([f[2]!.id, f[1]!.id]);
        expect(p1.body.items[0]).toHaveProperty("url");
        expect(p1.body.items[0]).toHaveProperty("duration");
        const p2 = await w.owner("GET", "/stage/pool?limit=2&offset=2");
        expect(p2.body).toMatchObject({ offset: 2, next: null });
        for (const bad of ["limit=0", "limit=101", "offset=x"]) expect((await w.owner("GET", `/stage/pool?${bad}`)).status, bad).toBe(400);

        await w.goLive();
        for (const type of ["skip", "shuffle", "chaos"]) {
            await w.owner("POST", "/stage/action", { type });
            w.tick(1000);
        }
        const all = await w.owner("GET", "/stage/redemptions");
        expect(all.body.redemptions.map((r: any) => r.action)).toEqual(["chaos", "shuffle", "skip"]);
        expect(all.body.redemptions[0]).toMatchObject({ user_name: "you", item: null, status: "done", reason: null, input: "" });
        const two = await w.owner("GET", "/stage/redemptions?limit=2");
        expect(two.body.redemptions).toHaveLength(2);
        const older = await w.owner("GET", `/stage/redemptions?before=${T0 + 1000}`);
        expect(older.body.redemptions.map((r: any) => r.action)).toEqual(["skip"]);
        for (const bad of ["limit=0", "limit=101", "before=x"]) expect((await w.owner("GET", `/stage/redemptions?${bad}`)).status, bad).toBe(400);
    });
});

describe("room state rules", () => {
    const item = { id: "a", code: "AAA", title: "t", kind: "image" as const, url: "u", poster_url: null, width: null, height: null, duration: null };
    const spot = (at: number) => ({ item, by: "x", action: "summon" as const, pinned_until: null, at });

    it("a summon replaces the spotlight and clears a pin; skip drops it", () => {
        let s = reduceRoom(emptyRoom(), { type: "summon", spotlight: spot(100), toast: null }, 100);
        s = reduceRoom(s, { type: "pin", pinned_until: 5000, toast: null }, 150);
        expect(spotlightView(s, 200, 20)!.pinned_until).toBe(5000);
        s = reduceRoom(s, { type: "summon", spotlight: spot(300), toast: null }, 300);
        expect(spotlightView(s, 400, 20)!.pinned_until).toBeNull();
        s = reduceRoom(s, { type: "skip" }, 400);
        expect(spotlightView(s, 400, 20)).toBeNull();
    });

    it("spotlightView: fresh within spotlight_seconds, forever while pinned", () => {
        let s = reduceRoom(emptyRoom(), { type: "summon", spotlight: spot(1000), toast: null }, 1000);
        expect(spotlightView(s, 1000 + 19_999, 20)).not.toBeNull();
        expect(spotlightView(s, 1000 + 20_000, 20)).toBeNull();
        s = reduceRoom(s, { type: "pin", pinned_until: 90_000, toast: null }, 1500);
        expect(spotlightView(s, 80_000, 20)!.pinned_until).toBe(90_000);
        expect(spotlightView(s, 90_000, 20)).toBeNull();
        s = reduceRoom(s, { type: "unpin" }, 2000);
        expect(spotlightView(s, 1500, 20)!.pinned_until).toBeNull();
    });

    it("a pin cannot bring back a spotlight that was already gone when it arrived", () => {
        // summon X at t0; ten minutes later the canvas shows a random spotlight Y (the room never hears of it) and
        // the viewer pins: the room has only X, which expired long before the pin
        const t0 = 1_000_000;
        let s = reduceRoom(emptyRoom(), { type: "summon", spotlight: spot(t0), toast: null }, t0);
        const pinAt = t0 + 10 * 60_000;
        s = reduceRoom(s, { type: "pin", pinned_until: pinAt + 120_000, toast: null }, pinAt);
        expect(spotlightView(s, pinAt + 1000, 20)).toBeNull();
        // while X was still up, the same pin does hold it
        let held = reduceRoom(emptyRoom(), { type: "summon", spotlight: spot(t0), toast: null }, t0);
        held = reduceRoom(held, { type: "pin", pinned_until: t0 + 5000 + 120_000, toast: null }, t0 + 5000);
        expect(spotlightView(held, t0 + 60_000, 20)!.pinned_until).toBe(t0 + 125_000);
        // and a state stored before pinned_at existed (0) keeps the old behaviour
        const legacy = { ...held, pinned_at: 0 };
        expect(spotlightView(legacy, t0 + 60_000, 20)!.pinned_until).toBe(t0 + 125_000);
    });
});

describe("retention (30.2)", () => {
    it("the daily cron deletes redemptions older than 30 days", async () => {
        const w = await world();
        await w.owner("GET", "/stage");
        const ins = w.db.raw.prepare("INSERT INTO stage_redemptions (id, action, user_id, user_login, user_name, input, status, created_at) VALUES (?, 'chaos', 'u', 'u', 'U', '', 'done', ?)");
        const day = 24 * 60 * 60 * 1000;
        ins.run("old", T0 - 31 * day);
        ins.run("edge", T0 - 30 * day + 1);
        ins.run("new", T0);
        w.db.raw.prepare("INSERT INTO stage_seen (id, seen_at) VALUES ('m1', ?), ('m2', ?)").run(T0 - 11 * 60_000, T0);
        const r = await stageRetention(w.env.DB, T0);
        expect(r).toEqual({ redemptions: 1, seen: 1 });
        expect(w.q("SELECT id FROM stage_redemptions ORDER BY id").map((x) => x.id)).toEqual(["edge", "new"]);
        expect(w.q("SELECT id FROM stage_seen").map((x) => x.id)).toEqual(["m2"]);
    });
});

describe("the room port (the Worker's side of the Durable Object)", () => {
    it("posts events, reads the state and hands the upgrade request over, all to the one 'main' object", async () => {
        const seen: { name?: string; method: string; url: string; body: string; upgrade: string | null }[] = [];
        let named = "";
        const ns = {
            idFromName(name: string) {
                named = name;
                return name;
            },
            get() {
                return {
                    async fetch(request: Request) {
                        seen.push({ name: named, method: request.method, url: request.url, body: request.method === "POST" ? await request.text() : "", upgrade: request.headers.get("upgrade") });
                        return new Response(request.url.endsWith("/state") ? JSON.stringify({ chaos_until: 9 }) : null, { status: request.url.endsWith("/ws") ? 200 : 200 });
                    },
                };
            },
        };
        const room = roomPort(ns);
        await room.send({ type: "skip" });
        expect(await room.state()).toEqual({ ...emptyRoom(), chaos_until: 9 });
        await room.connect(new Request("https://studio.capybaraharmony.com/live/tok/ws", { headers: { upgrade: "websocket" } }));
        expect(seen.map((x) => [x.name, x.method, new URL(x.url).pathname])).toEqual([["main", "POST", "/event"], ["main", "GET", "/state"], ["main", "GET", "/ws"]]);
        expect(seen[0]!.body).toBe('{"type":"skip"}');
        expect(seen[2]!.upgrade).toBe("websocket");
    });

    it("sameSecret compares whole strings", () => {
        expect(sameSecret("abc", "abc")).toBe(true);
        expect(sameSecret("abc", "abd")).toBe(false);
        expect(sameSecret("abc", "abcd")).toBe(false);
        expect(sameSecret("", "")).toBe(true);
    });
});

describe("config helpers", () => {
    it("stageBaseFrom accepts only https and adds the slash", () => {
        expect(stageBaseFrom({ STAGE_BASE_URL: "https://studio.capybaraharmony.com" })).toBe("https://studio.capybaraharmony.com/");
        expect(stageBaseFrom({ STAGE_BASE_URL: "http://x.com/" })).toBeNull();
        expect(stageBaseFrom({ STAGE_BASE_URL: "nonsense" })).toBeNull();
        expect(stageBaseFrom({})).toBeNull();
    });
});

void AUTH;
