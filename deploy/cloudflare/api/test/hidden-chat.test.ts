// The chat AI's and the MCP's hidden-post calls (APP-API-CONTRACT.md 37.6), through the registry's chat toolbox against
// the real SQL and handlers: library.status (hidden/off run at once, public/private and unhiding ask), library.hidden,
// the rule calls (add asks only with apply), what a hidden post is left out of, and the MCP tool list.
import { describe, expect, it } from "vitest";
import { chatTools } from "../src/chat-tools";
import { mcpToolList } from "../src/mcp";
import { chatToolbox, runConfirmed } from "../src/registry/ai";
import { opBase, REGISTRY } from "../src/registry/index";
import type { PendingConfirm, PendingPort } from "../src/registry/pending";
import { world } from "./stage-world";

const THREAD = "Thread0000000037";

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

describe("library.status in the chat", () => {
    it("hidden runs at once (by chat); the post leaves library.list and shows in library.hidden", async () => {
        const w = await setup();
        const a = w.file({ visibility: "private" });
        const b = w.file({ visibility: "private" });
        const r = await w.call("library.status", [a.id], "hidden");
        expect(w.cards.cards.size).toBe(0);
        expect(r).toMatchObject({ status: "hidden", posts: [{ id: a.id, files: 1, links: [] }], failed: [] });
        expect(w.row(a.id)).toEqual({ state: "hidden", by: "chat" });
        const ids = JSON.stringify(await w.call("library.list"));
        expect(ids).toContain(b.id);
        expect(ids).not.toContain(a.id);
        const hidden = await w.call("library.hidden");
        expect(hidden.next).toBeNull();
        expect(hidden.posts).toHaveLength(1);
        expect(hidden.posts[0]).toMatchObject({ id: a.id, hidden_by: "chat", hidden_rule: null });
        // opening it by id still works, and says it is hidden
        expect(await w.call("library.post", a.id)).toMatchObject({ id: a.id, hidden: true });
        expect((await w.call("library.post", b.id)).hidden).toBeUndefined();
    });

    it("off on a hidden post asks first, and confirming unhides it (exempt)", async () => {
        const w = await setup();
        const a = w.file({ visibility: "private" });
        await w.call("library.status", [a.id], "hidden");
        const off = await w.call("library.status", [a.id], "off");
        expect(off.pending_confirm).toMatchObject({ effect: { status: "off", posts: 1, unhides: 1 } });
        expect(w.row(a.id).state).toBe("hidden");
        expect((await w.confirm()).result).toMatchObject({ status: "off", failed: [] });
        expect(w.row(a.id)).toEqual({ state: "exempt", by: "chat" });
        // off on a post that is not hidden just runs
        const b = w.file({ visibility: "private" });
        expect((await w.call("library.status", [b.id], "off")).pending_confirm).toBeUndefined();
    });

    it("public and private always ask", async () => {
        const w = await setup();
        const a = w.file({ visibility: "private" });
        for (const s of ["public", "private"]) {
            expect((await w.call("library.status", [a.id], s)).pending_confirm).toMatchObject({ effect: { status: s } });
            w.cards.cards.clear();
        }
    });

    it("links.create on a hidden post is refused with the unhide hint", async () => {
        const w = await setup();
        const a = w.file();
        const b = w.file();
        await w.call("library.status", [a.id], "hidden");
        await expect(w.call("links.create", [a.id, b.id])).rejects.toThrow(/hidden; unhide it first with library\.status/);
    });
});

describe("the rule calls in the chat", () => {
    it("add runs at once without apply and asks with it; list (and its alias) shows them", async () => {
        const w = await setup();
        const r = await w.call("hidden.rules.add", "words", "spoiler");
        expect(r.rule).toMatchObject({ kind: "words", value: "spoiler", enabled: true, hits: 0 });
        expect(w.cards.cards.size).toBe(0);
        const ask = await w.call("hidden.rules.add", "site", "x.com", { apply: true });
        expect(ask.pending_confirm).toBeDefined();
        expect(w.one("SELECT COUNT(*) AS n FROM hidden_rules").n).toBe(1);
        const listed = await w.call("hidden.rules.list");
        expect(listed).toMatchObject({ hidden: 0, held: 0 });
        expect(listed.rules).toHaveLength(1);
        expect(await w.call("hidden.rules")).toEqual(listed);
        await expect(w.call("hidden.rules.delete", r.rule.id)).resolves.toMatchObject({ pending_confirm: expect.anything() });
    });
});

describe("the MCP", () => {
    it("serves the hidden calls, with the ask ones marked destructive", () => {
        const tools = mcpToolList(REGISTRY, { search: true, mcp: true }) as any[];
        const by = new Map(tools.map((t) => [t.name, t]));
        for (const n of ["library_status", "library_hidden", "hidden_rules_list", "hidden_rules_add", "hidden_rules_update", "hidden_rules_delete", "hidden_rules_preview"]) {
            expect(by.has(n), n).toBe(true);
        }
        for (const n of ["library_status", "hidden_rules_add", "hidden_rules_update", "hidden_rules_delete"]) expect(by.get(n).annotations?.destructiveHint, n).toBe(true);
        for (const n of ["library_hidden", "hidden_rules_list", "hidden_rules_preview"]) expect(by.get(n).annotations, n).toBeUndefined();
        // the owner's route ops are not tools
        expect(tools.some((t) => t.name.startsWith("hidden_rules.") || t.name === "library_status_route")).toBe(false);
    });
});
