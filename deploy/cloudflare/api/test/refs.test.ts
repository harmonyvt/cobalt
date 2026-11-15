// Links and file names where the chat AI and the MCP name posts (APP-API-CONTRACT.md section 60): src/refs.ts resolves them,
// registry/refs.ts swaps them in before an op's input is checked. The real SQL and handlers, hidden posts included: the
// case that started it was "unhide https://media.../vFhaasY6GA.webp", where the file was hidden and so private.
import { describe, expect, it } from "vitest";
import { chatTools } from "../src/chat-tools";
import { chatToolbox, runConfirmed } from "../src/registry/ai";
import { opBase, REGISTRY } from "../src/registry/index";
import type { PendingConfirm, PendingPort } from "../src/registry/pending";
import { looksLikeRef, parseRef, resolveRefs } from "../src/refs";
import { MEDIA, SHARE, world } from "./stage-world";

const THREAD = "Thread0000000059";
const BASES = { mediaBaseUrl: MEDIA, shareBaseUrl: SHARE };

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

async function setup() {
    const w = await world();
    const container = {
        async fetch(): Promise<Response> {
            throw new Error("the container must not be reached");
        },
    };
    const edge = { now: w.now, sleep: async () => {}, captioner: null, waitUntil: (p: Promise<unknown>) => void w.pending.push(p) };
    const base = opBase(w.env, container, edge, REGISTRY, { stageRoom: w.room, stageEmbed: null });
    const cards = new MemoryPending();
    const legacyFor = (collect: { look: string[]; show: string[] }) =>
        chatTools({ db: w.env.DB, mediaBaseUrl: w.env.MEDIA_BASE_URL, shareBaseUrl: w.env.SHARE_BASE_URL, embed: null }, collect);
    const call = (name: string, ...args: unknown[]) => {
        const collect = { look: [] as string[], show: [] as string[] };
        return chatToolbox(REGISTRY, base, { threadId: THREAD, messageId: null, collect, legacy: legacyFor(collect), flags: { search: false }, pending: cards }).tools[name]!(
            ...args,
        ) as Promise<any>;
    };
    const confirm = async () => {
        const rec = cards.cards.get(THREAD)!;
        cards.cards.delete(THREAD);
        const collect = { look: [] as string[], show: [] as string[] };
        return (await runConfirmed(REGISTRY, base, THREAD, rec, legacyFor(collect), collect)) as { result: any };
    };
    const row = (key: string) => w.one("SELECT state, by FROM media_hidden WHERE post_key = ?", key);
    return { ...w, call, cards, confirm, row };
}


describe("parseRef", () => {
    it("reads every kind of capystore link and name", () => {
        expect(parseRef(`${MEDIA}vFhaasY6GA.webp`, BASES)).toEqual({ kind: "name", name: "vFhaasY6GA", ext: "webp" });
        expect(parseRef("<media.capybaraharmony.com/vFhaasY6GA.WEBP>", BASES)).toEqual({ kind: "name", name: "vFhaasY6GA", ext: "webp" });
        expect(parseRef(`${SHARE}vFhaasY6GA`, BASES)).toEqual({ kind: "name", name: "vFhaasY6GA", ext: null });
        expect(parseRef(`${SHARE}g/1234567890123456789`, BASES)).toEqual({ kind: "gallery", id: "1234567890123456789" });
        expect(parseRef(`${SHARE}p/AbcdefghijAbcdefghij12/1.mp4`, BASES)).toEqual({ kind: "private", key: "AbcdefghijAbcdefghij12" });
        expect(parseRef("vFhaasY6GA.webp", BASES)).toEqual({ kind: "name", name: "vFhaasY6GA", ext: "webp" });
        expect(parseRef("vFhaasY6GA", BASES)).toEqual({ kind: "id", id: "vFhaasY6GA" });
        expect(parseRef("https://x.com/a/status/1", BASES)).toEqual({ kind: "source", url: "https://x.com/a/status/1" });
    });

    it("leaves plain ids alone (no lookup for them)", () => {
        expect(looksLikeRef("Item000000000001")).toBe(false);
        expect(looksLikeRef("Sess00000000000000000a")).toBe(false);
        expect(looksLikeRef("vFhaasY6GA")).toBe(true);
        expect(looksLikeRef(`${MEDIA}x.webp`)).toBe(true);
    });
});

describe("resolveRefs", () => {
    it("finds public, private, hidden, gallery, private-link and source refs; null for nothing, gone for deleted", async () => {
        const w = await setup();
        const pub = w.file();
        const name = pub.r2_key.split(".")[0]!;
        // a file that went private keeps its public name in public_key
        const priv = w.file({ visibility: "private", public_key: "Kept000001.webp" });
        const saved = w.video({ link: "https://x.com/a/status/9" });
        const gone = w.file({ deleted_at: 5 });
        w.db.raw.prepare("INSERT INTO share_sets (id, items, title, key_id, created_at, revoked_at) VALUES (?, ?, NULL, 'k', 1, NULL)").run("1111111111111111111", JSON.stringify([pub.id, saved.id]));
        w.db.raw.prepare("INSERT INTO private_links (key, kind, target_id, created_at, revoked_at, opened, last_opened_at) VALUES (?, 'item', ?, 1, NULL, 0, NULL)").run("PrivKey000000000000001", priv.id);
        await w.call("library.status", [priv.id], "hidden");
        const refs = [
            pub.url!,
            `${SHARE}${name}`,
            name,
            `${MEDIA}Kept000001.webp`,
            `${SHARE}g/1111111111111111111`,
            `${SHARE}p/PrivKey000000000000001`,
            "https://x.com/a/status/9",
            `${MEDIA}${gone.r2_key}`,
            `${MEDIA}Nothing123.webp`,
        ];
        const r = await resolveRefs(w.env.DB, refs, BASES);
        expect(r.get(pub.url!)).toEqual({ posts: [pub.id], file: pub.id, via: "name", gone: false });
        expect(r.get(`${SHARE}${name}`)?.posts).toEqual([pub.id]);
        expect(r.get(name)?.posts).toEqual([pub.id]);
        expect(r.get(`${MEDIA}Kept000001.webp`)).toEqual({ posts: [priv.id], file: priv.id, via: "name", gone: false });
        expect(r.get(`${SHARE}g/1111111111111111111`)?.posts).toEqual([pub.id, "https://x.com/a/status/9"]);
        expect(r.get(`${SHARE}p/PrivKey000000000000001`)).toMatchObject({ posts: [priv.id], file: priv.id });
        // a post saved without a session is keyed by its page: the link is its id
        expect(r.get("https://x.com/a/status/9")?.posts).toEqual(["https://x.com/a/status/9"]);
        expect((await resolveRefs(w.env.DB, ["https://x.com/a/status/9/"], BASES)).get("https://x.com/a/status/9/")?.posts).toEqual(["https://x.com/a/status/9"]);
        expect(r.get(`${MEDIA}${gone.r2_key}`)).toMatchObject({ posts: [], gone: true });
        expect(r.get(`${MEDIA}Nothing123.webp`)).toBeNull();
    });
});

describe("links where a call names posts", () => {
    it("unhides a hidden webp from its media link (the case that started it)", async () => {
        const w = await setup();
        const a = w.file();
        const link = a.url!;
        await w.call("library.status", [a.id], "hidden");
        expect(w.row(a.id).state).toBe("hidden");
        // hidden: its public object is gone, but the link still names it
        const off = await w.call("library.status", link, "off");
        expect(off.pending_confirm).toMatchObject({ effect: { status: "off", posts: 1, unhides: 1 } });
        // (the fake bucket holds no bytes for the file, so its link stays off: failed names it; the post is unhidden)
        expect((await w.confirm()).result).toMatchObject({ status: "off", posts: [{ id: a.id }] });
        expect(w.row(a.id)).toEqual({ state: "exempt", by: "chat" });
    });

    it("library.post, library.title and look take a link or a file id; a gallery link in a one-post field names its posts", async () => {
        const w = await setup();
        const a = w.file();
        const b = w.file();
        expect(await w.call("library.post", a.url)).toMatchObject({ id: a.id });
        expect(await w.call("library.post", `${SHARE}${a.r2_key.split(".")[0]}`)).toMatchObject({ id: a.id });
        w.db.raw.prepare("INSERT INTO share_sets (id, items, title, key_id, created_at, revoked_at) VALUES (?, ?, NULL, 'k', 1, NULL)").run("2222222222222222222", JSON.stringify([a.id, b.id]));
        await expect(w.call("library.post", `${SHARE}g/2222222222222222222`)).rejects.toThrow(/gallery link of 2 posts \(.*\): pass one of them/);
        expect(await w.call("look", [`${SHARE}g/2222222222222222222`])).toBe(2);
    });

    it("a link that names nothing fails before anything runs or is asked", async () => {
        const w = await setup();
        await expect(w.call("library.status", `${MEDIA}Nothing123.webp`, "off")).rejects.toThrow(/nothing in the library matches/);
        expect(w.cards.cards.size).toBe(0);
    });

    it("library.status that changes nothing is an error, never a bare success", async () => {
        const w = await setup();
        await expect(w.call("library.status", ["Item999999999999"], "hidden")).rejects.toThrow(/nothing changed\. Item999999999999: no such post or file/);
    });

    it("library.hidden lists each hidden post's public names", async () => {
        const w = await setup();
        const a = w.file();
        await w.call("library.status", [a.id], "hidden");
        const hidden = await w.call("library.hidden");
        expect(hidden.posts[0]).toMatchObject({ id: a.id, names: [a.r2_key] });
    });
});
