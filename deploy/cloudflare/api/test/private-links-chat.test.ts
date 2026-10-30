// The chat AI's private link calls (APP-API-CONTRACT.md 36.5): links.create({ private }), links.list's live URLs,
// links.private (asks only when turning one off) and links.rotate (asks), through the registry's chat toolbox against the
// real SQL and handlers. The owner-only routes (rotate-all, the settings) are never tools.
import { describe, expect, it } from "vitest";
import { chatTools } from "../src/chat-tools";
import { mcpOps } from "../src/mcp";
import { chatToolbox, runConfirmed } from "../src/registry/ai";
import { opBase, REGISTRY } from "../src/registry/index";
import type { PendingConfirm, PendingPort } from "../src/registry/pending";
import { SHARE, world } from "./stage-world";

const THREAD = "Thread0000000002";
const PRIVATE = /^https:\/\/share\.capybaraharmony\.com\/p\/[A-Za-z0-9]{22}$/;

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
    return { ...w, call, cards, confirm };
}

describe("links.create with private", () => {
    it("makes a private gallery link of files that are not public, and links.list shows its live URL", async () => {
        const w = await setup();
        const a = w.file({ visibility: "private" });
        const b = w.file({ visibility: "private" });
        await expect(w.call("links.create", [a.id, b.id])).rejects.toThrow(/not public/);
        const link = await w.call("links.create", [a.id, b.id], { private: true });
        expect(link).toMatchObject({ files: 2, private: true });
        expect(link.url).toMatch(PRIVATE);
        const listed = (await w.call("links.list")).find((l: any) => l.id === link.id);
        expect(listed).toMatchObject({ private: true, url: link.url });
    });

    it("one file with private: its private link is turned on", async () => {
        const w = await setup();
        const a = w.file({ visibility: "private" });
        const link = await w.call("links.create", a.id, { private: true });
        expect(link).toMatchObject({ id: null, files: 1, private: true });
        expect(link.url).toMatch(PRIVATE);
        expect(w.one("SELECT kind, target_id FROM private_links WHERE revoked_at IS NULL")).toEqual({ kind: "item", target_id: a.id });
    });
});

describe("links.private and links.rotate", () => {
    it("turning one on runs at once; turning it off asks first and answers the public URL", async () => {
        const w = await setup();
        w.set("1234567890123456789", [w.file().id, w.file().id]);
        const on = await w.call("links.private", "1234567890123456789", true);
        expect(on).toMatchObject({ link: "1234567890123456789", kind: "set", private: true });
        expect(on.url).toMatch(PRIVATE);
        expect(w.cards.cards.size).toBe(0);

        const off = await w.call("links.private", on.url, false);
        expect(off.pending_confirm).toMatchObject({ effect: { link: "1234567890123456789", kind: "set", public_again: true } });
        expect(w.one("SELECT COUNT(*) AS n FROM private_links WHERE revoked_at IS NULL").n).toBe(1);
        expect((await w.confirm()).result).toEqual({ link: "1234567890123456789", kind: "set", private: false, url: `${SHARE}g/1234567890123456789` });
        expect(w.one("SELECT COUNT(*) AS n FROM private_links WHERE revoked_at IS NULL").n).toBe(0);
    });

    it("rotate asks, then answers a new URL; one with no link is refused before asking", async () => {
        const w = await setup();
        const f = w.file({ visibility: "private" });
        await expect(w.call("links.rotate", f.id)).rejects.toThrow(/no private link/);
        expect(w.cards.cards.size).toBe(0);
        const on = await w.call("links.private", f.id, true);
        const r = await w.call("links.rotate", on.url);
        expect(r.pending_confirm).toMatchObject({ effect: { link: on.url, old_link_stops_working: true } });
        const done = (await w.confirm()).result;
        expect(done.url).toMatch(PRIVATE);
        expect(done.url).not.toBe(on.url);
    });

    it("the owner's calls are not tools, in the chat or the MCP", () => {
        const chat = REGISTRY.toolsFor("chat", { search: true }).map((o) => o.callName);
        expect(chat).toEqual(expect.arrayContaining(["links.private", "links.rotate", "links.create", "links.list"]));
        for (const hidden of ["share_private.rotate_all", "share_private.settings", "share_private.list"]) expect(chat).not.toContain(hidden);
        const mcp = mcpOps(REGISTRY, { search: true, mcp: true }).map((o) => o.callName);
        expect(mcp).toEqual(expect.arrayContaining(["links.private", "links.rotate"]));
        expect(mcp.some((n) => n.startsWith("share_private"))).toBe(false);
    });
});
