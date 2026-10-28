// The chat AI's share and stage calls (APP-API-CONTRACT.md 33.7, 33.8): cobalt.links.*, cobalt.collections.*,
// cobalt.sets.*, cobalt.stage.* and cobalt.emotes.*, called through the registry's chat toolbox (the functions the
// sandbox dispatches to) against the real SQL, the real handlers and a fake StageRoom. Ask ops pause on a confirm card
// and run when it is answered yes.
import { describe, expect, it } from "vitest";
import { chatTools } from "../src/chat-tools";
import { chatToolbox, runConfirmed } from "../src/registry/ai";
import { opBase, REGISTRY } from "../src/registry/index";
import type { PendingConfirm, PendingPort } from "../src/registry/pending";
import { chunks } from "../src/registry/ops/stage";
import { SHARE, STAGE, world, type World } from "./stage-world";

const THREAD = "Thread0000000001";

class MemoryPending implements PendingPort {
    cards = new Map<string, PendingConfirm>();
    async put(thread: string, rec: PendingConfirm) {
        this.cards.set(thread, rec);
    }
    async take(thread: string, id: string) {
        const rec = this.cards.get(thread);
        if (!rec || rec.id !== id) return null;
        this.cards.delete(thread);
        return rec;
    }
    async drop(thread: string) {
        this.cards.delete(thread);
    }
}

async function setup(opts: Parameters<typeof world>[0] = {}) {
    const w = await world(opts);
    const container = {
        async fetch(): Promise<Response> {
            throw new Error("the container must not be reached");
        },
    };
    const edge = { now: w.now, sleep: async () => {}, captioner: null, waitUntil: (p: Promise<unknown>) => void w.pending.push(p) };
    const base = opBase(w.env, container, edge, REGISTRY, { stageRoom: w.room, stageEmbed: null });
    const cards = new MemoryPending();
    const toolbox = () => {
        const collect = { look: [] as string[], show: [] as string[] };
        const legacy = chatTools({ db: w.env.DB, mediaBaseUrl: w.env.MEDIA_BASE_URL, shareBaseUrl: w.env.SHARE_BASE_URL, embed: null }, collect);
        return chatToolbox(REGISTRY, base, { threadId: THREAD, messageId: null, collect, legacy, flags: { search: false }, pending: cards });
    };
    // a fresh toolbox per code run, as the chat makes one
    const call = (name: string, ...args: unknown[]) => toolbox().tools[name]!(...args) as Promise<any>;
    const confirm = async () => {
        const rec = cards.cards.get(THREAD)!;
        cards.cards.delete(THREAD);
        const collect = { look: [] as string[], show: [] as string[] };
        const legacy = chatTools({ db: w.env.DB, mediaBaseUrl: w.env.MEDIA_BASE_URL, shareBaseUrl: w.env.SHARE_BASE_URL, embed: null }, collect);
        return runConfirmed(REGISTRY, base, THREAD, rec, legacy, collect);
    };
    return { ...w, call, cards, confirm };
}

const gallery = (w: World, post: string, n: number, over: Record<string, unknown> = {}) =>
    Array.from({ length: n }, (_, i) => w.file({ post_key: post, role: "item", item_index: i, ...over }));

describe("cobalt.links.create", () => {
    it("makes one gallery link for posts and answers its share URL, made by the chat's key id", async () => {
        const w = await setup();
        const a = w.file();
        const b = w.video();
        const link = await w.call("links.create", [a.id, b.id], { title: "two things" });
        expect(link).toMatchObject({ title: "two things", files: 2 });
        expect(link.url).toBe(`${SHARE}g/${link.id}`);
        const row = w.one("SELECT items, key_id FROM share_sets WHERE id = ?", link.id);
        expect(JSON.parse(row.items)).toEqual([a.id, b.id]);
        expect(row.key_id).toBe(`chat:${THREAD}`);
        // a single id: the file's own share page, never the media URL
        const one = await w.call("links.create", a.id);
        expect(one).toEqual({ id: null, url: `${SHARE}${a.r2_key.split(".")[0]}`, title: null, files: 1 });
    });

    it("brings a gallery post's public items, and takes file ids too", async () => {
        const w = await setup();
        const items = gallery(w, "https://x.com/a/status/1", 3);
        w.file({ post_key: "https://x.com/a/status/1", role: "item", item_index: 3, visibility: "private" });
        const link = await w.call("links.create", ["https://x.com/a/status/1"]);
        expect(JSON.parse(w.one("SELECT items FROM share_sets WHERE id = ?", link.id).items)).toEqual(items.map((i) => i.id));
        const byFile = await w.call("links.create", [items[2]!.id, items[0]!.id]);
        expect(JSON.parse(w.one("SELECT items FROM share_sets WHERE id = ?", byFile.id).items)).toEqual([items[2]!.id, items[0]!.id]);
    });

    it("names private and unknown posts and refuses more than 10 files", async () => {
        const w = await setup();
        const a = w.file();
        const hidden = w.file({ visibility: "private" });
        await expect(w.call("links.create", [a.id, hidden.id])).rejects.toThrow(new RegExp(`not public.*${hidden.id}`));
        await expect(w.call("links.create", [a.id, "nope"])).rejects.toThrow(/no post or file with id nope/);
        const many = Array.from({ length: 11 }, () => w.file().id);
        await expect(w.call("links.create", many)).rejects.toThrow(/11 files.*at most 10/);
        await expect(w.call("links.create", [])).rejects.toThrow(/cobalt\.links\.create: ids/);
        expect(w.q("SELECT id FROM share_sets")).toEqual([]);
    });

    it("says share links are off when the share host is", async () => {
        const w = await setup({ env: { SHARE_BASE_URL: undefined } });
        const a = w.file();
        await expect(w.call("links.create", [a.id, w.file().id])).rejects.toThrow(/share links are off/);
    });
});

describe("cobalt.links.revoke (asks first)", () => {
    it("pauses with the link's effect, and revokes on yes", async () => {
        const w = await setup();
        w.set("1234567890123456789", [w.file().id, w.file().id]);
        w.collection("Coll000000000001", "memes", ["1234567890123456789"]);
        const r = await w.call("links.revoke", `${SHARE}g/1234567890123456789`);
        expect(r.pending_confirm).toMatchObject({ summary: "revoke this link", effect: { link: `${SHARE}g/1234567890123456789`, files: 2, collections: 1 } });
        expect(w.one("SELECT revoked_at FROM share_sets").revoked_at).toBeNull();
        expect(await w.confirm()).toEqual({ result: { revoked: "1234567890123456789" } });
        expect(w.one("SELECT revoked_at FROM share_sets").revoked_at).not.toBeNull();
    });

    it("refuses a link that does not exist before asking", async () => {
        const w = await setup();
        await expect(w.call("links.revoke", "1234567890123456789")).rejects.toThrow(/no live gallery link/);
        await expect(w.call("links.revoke", "bad")).rejects.toThrow(/19 digits/);
        expect(w.cards.cards.size).toBe(0);
    });
});

describe("cobalt.collections.*", () => {
    it("add makes the collection by name, then adds to it by name or id; links may be URLs", async () => {
        const w = await setup();
        w.set("1111111111111111111", [w.file().id, w.file().id]);
        w.set("2222222222222222222", [w.file().id, w.file().id]);
        const made = await w.call("collections.add", "Cats", "1111111111111111111");
        expect(made).toMatchObject({ name: "Cats", link_ids: ["1111111111111111111"], created: true });
        const more = await w.call("collections.add", "cats", [`${SHARE}g/2222222222222222222`]);
        expect(more).toMatchObject({ id: made.id, created: false, link_ids: ["2222222222222222222", "1111111111111111111"] });
        expect(w.q("SELECT key_id FROM share_collections")).toEqual([{ key_id: `chat:${THREAD}` }]);
        const renamed = await w.call("collections.update", made.id, { name: "cat pics", remove: ["1111111111111111111"] });
        expect(renamed).toEqual({ id: made.id, name: "cat pics", link_ids: ["2222222222222222222"] });
        await expect(w.call("collections.add", "dogs", "3333333333333333333")).rejects.toThrow(/does not exist or was revoked/);
        await expect(w.call("collections.update", "nobody")).rejects.toThrow(/no collection called/);
    });

    it("delete and reroll ask first; reroll revokes the old URLs on yes", async () => {
        const w = await setup();
        w.set("1111111111111111111", [w.file().id, w.file().id]);
        w.collection("Coll000000000001", "memes", ["1111111111111111111"]);
        const r = await w.call("collections.reroll", "memes");
        expect(r.pending_confirm).toMatchObject({ summary: 'reroll 1 link in "memes"', effect: { links: 1, old_links_stop_working: true } });
        const done = (await w.confirm()) as { result: any };
        expect(Object.keys(done.result.replaced)).toEqual(["1111111111111111111"]);
        expect(w.one("SELECT revoked_at FROM share_sets WHERE id = '1111111111111111111'").revoked_at).not.toBeNull();

        const d = await w.call("collections.delete", "Coll000000000001");
        expect(d.pending_confirm).toMatchObject({ summary: 'delete the collection "memes"', effect: { links: 1, links_stay_live: true } });
        expect(await w.confirm()).toEqual({ result: { deleted: "Coll000000000001" } });
        expect(w.q("SELECT id FROM share_collections")).toEqual([]);
    });
});

describe("cobalt.sets.*", () => {
    it("add makes a set of collections by name; list, update and delete (asks) work by name", async () => {
        const w = await setup();
        w.collection("Coll000000000001", "memes", []);
        w.collection("Coll000000000002", "cats", []);
        const made = await w.call("sets.add", "stream night", ["memes", "Coll000000000002"]);
        expect(made).toMatchObject({ name: "stream night", created: true });
        expect([...made.collection_ids].sort()).toEqual(["Coll000000000001", "Coll000000000002"]);
        expect(await w.call("sets.list")).toEqual([{ id: made.id, name: "stream night", collection_ids: made.collection_ids }]);
        expect(await w.call("sets.update", "Stream Night", { remove: "cats" })).toMatchObject({ collection_ids: ["Coll000000000001"] });
        await expect(w.call("sets.add", "stream night", "nope")).rejects.toThrow(/no collection called/);
        const d = await w.call("sets.delete", "stream night");
        expect(d.pending_confirm).toMatchObject({ effect: { set: "stream night", collections: 1, collections_stay: true } });
        await w.confirm();
        expect(w.q("SELECT id FROM collection_groups")).toEqual([]);
        expect(w.q("SELECT id FROM share_collections")).toHaveLength(2);
    });
});

describe("cobalt.stage.*", () => {
    it("pool(postIds) files the picks as gallery links in \"stage picks\" and points the studio at it", async () => {
        const w = await setup();
        const ids = Array.from({ length: 12 }, () => w.file().id);
        const hidden = w.file({ visibility: "private" }).id;
        const r = await w.call("stage.pool", [...ids, hidden]);
        expect(r).toMatchObject({ pool: { kind: "collection", name: "stage picks", count: 12 }, links: 2, not_public: [hidden] });
        const sets = w.q<{ items: string; title: string }>("SELECT items, title FROM share_sets ORDER BY created_at, id");
        expect(sets.map((s) => JSON.parse(s.items).length).sort()).toEqual([6, 6]);
        expect(sets.every((s) => s.title === "stage picks")).toBe(true);
        expect(w.room.events.some((m: any) => m.type === "pool")).toBe(true);
        // again: the collection holds only the new picks (the old links stay live)
        const again = await w.call("stage.pool", ids.slice(0, 3));
        expect(again).toMatchObject({ pool: { count: 3 }, links: 1 });
        expect(w.q("SELECT id FROM share_collections")).toHaveLength(1);
        expect(w.q("SELECT set_id FROM share_collection_items")).toHaveLength(1);
        await expect(w.call("stage.pool", [ids[0]])).rejects.toThrow(/at least 2 public files/);
    });

    it("pool takes the library, a collection or a set by name, and search words", async () => {
        const w = await setup();
        const a = w.file();
        const b = w.file();
        w.set("1111111111111111111", [a.id, b.id]);
        w.collection("Coll000000000001", "memes", ["1111111111111111111"]);
        w.group("Grp0000000000001", "night", ["Coll000000000001"]);
        expect((await w.call("stage.pool", { collection: "Memes" })).pool).toMatchObject({ kind: "collection", ref: "Coll000000000001", count: 2 });
        expect((await w.call("stage.pool", { set: "night" })).pool).toMatchObject({ kind: "group", ref: "Grp0000000000001", count: 2 });
        expect((await w.call("stage.pool", "library")).pool).toMatchObject({ kind: "library", ref: null });
        // search with the Space off: the stage's own error, nothing changes
        await expect(w.call("stage.pool", { search: "cats" })).rejects.toThrow(/search is asleep or off/);
        await expect(w.call("stage.pool", { collection: "nope" })).rejects.toThrow(/no collection called/);
        await expect(w.call("stage.pool", { kind: "library" })).rejects.toThrow(/cobalt\.stage\.pool/);
    });

    it("get, set and action; set never touches the store lock, which asks first", async () => {
        const w = await setup();
        const s = await w.call("stage.get");
        expect(s).toMatchObject({ on_air: false, store_open: false, store_url: `${STAGE}store` });
        await expect(w.call("stage.action", "shuffle")).rejects.toThrow(/off air/);
        expect(await w.call("stage.set", { on_air: true, density: 500 })).toMatchObject({ on_air: true, density: 100 });
        await expect(w.call("stage.set", { store_open: true })).rejects.toThrow(/store_open/);
        await expect(w.call("stage.set", {})).rejects.toThrow(/at least one setting/);
        expect(await w.call("stage.action", "shuffle")).toMatchObject({ on_air: true });
        expect(w.room.events.some((m: any) => m.type === "shuffle")).toBe(true);

        const lock = await w.call("stage.store", true);
        expect(lock.pending_confirm).toMatchObject({ summary: "unlock the viewer store", effect: { store_url: `${STAGE}store`, now: "locked", after: "open" } });
        expect(w.stageRow().store_open).toBe(0);
        const done = (await w.confirm()) as { result: any };
        expect(done.result.store_open).toBe(true);
        expect(w.stageRow().store_open).toBe(1);
    });

    it("items pages the pool", async () => {
        const w = await setup();
        w.file();
        w.file();
        await w.call("stage.pool", "library");
        const page = await w.call("stage.items", { limit: 1 });
        expect(page).toMatchObject({ total: 2, offset: 0, next: 1 });
        expect(page.items).toHaveLength(1);
    });

    it("says the studio is off while it is", async () => {
        const w = await setup({ stage: false });
        await expect(w.call("stage.get")).rejects.toThrow(/studio \(stage\) is off/);
    });
});

describe("the HTTP routes are the same handlers", () => {
    it("serve the app as before (collections, sets, stage)", async () => {
        const w = await setup();
        w.set("1111111111111111111", [w.file().id, w.file().id]);
        const c = await w.owner("POST", "/share/collections", { name: "memes", set_ids: ["1111111111111111111"] });
        expect(c.status).toBe(201);
        expect(c.res.headers.get("cache-control")).toBe("no-store");
        expect((await w.owner("GET", "/share/groups")).body).toEqual({ status: "success", groups: [] });
        expect((await w.owner("GET", "/stage/pool")).status).toBe(200);
    });
});

describe("chunks", () => {
    it("splits into links of 2..10, as even as they go", () => {
        const sizes = (n: number) => chunks(Array.from({ length: n }, (_, i) => i)).map((c) => c.length);
        expect(sizes(2)).toEqual([2]);
        expect(sizes(10)).toEqual([10]);
        expect(sizes(11)).toEqual([6, 5]);
        expect(sizes(21)).toEqual([7, 7, 7]);
        expect(sizes(200)).toHaveLength(20);
    });
});
