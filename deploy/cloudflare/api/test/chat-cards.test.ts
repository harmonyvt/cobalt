// Rich tool cards (APP-API-CONTRACT.md section 38): the chat toolbox records every cobalt.* call of a run with its card,
// against the real SQL and handlers; and the card builders on their own (emotes in both shapes, the edit timeline with
// overlay layers and what changed, jobs, the box, links).
import { describe, expect, it } from "vitest";
import { cardFor, cardPostIds, postIdsOf, type ToolCall } from "../src/chat-cards";
import { chatTools } from "../src/chat-tools";
import { chatToolbox } from "../src/registry/ai";
import { opBase, REGISTRY } from "../src/registry/index";
import { MEDIA, world } from "./stage-world";

const THREAD = "Thread0000000038";

async function setup() {
    const w = await world();
    const container = {
        async fetch(): Promise<Response> {
            throw new Error("the container must not be reached");
        },
    };
    const edge = { now: w.now, sleep: async () => {}, captioner: null, waitUntil: (p: Promise<unknown>) => void w.pending.push(p) };
    const base = opBase(w.env, container, edge, REGISTRY, { stageRoom: w.room, stageEmbed: null });
    const live: ToolCall[] = [];
    const box = () => {
        const collect = { look: [] as string[], show: [] as string[] };
        const legacy = chatTools({ db: w.env.DB, mediaBaseUrl: w.env.MEDIA_BASE_URL, shareBaseUrl: w.env.SHARE_BASE_URL, embed: null }, collect);
        return chatToolbox(REGISTRY, base, { threadId: THREAD, messageId: null, collect, legacy, flags: { search: false }, pending: null, onCall: (c) => live.push(c) });
    };
    return { ...w, box, live };
}

describe("the toolbox records each call", () => {
    it("chips for every call, cards where there is something to see, errors in place", async () => {
        const w = await setup();
        const a = w.file();
        const b = w.video();
        const tb = box(w);
        await tb.tools["library.list"]!({ kind: "video" });
        await tb.tools["look"]!([a.id, b.id]);
        const link = (await tb.tools["links.create"]!([a.id, b.id], { title: "two" })) as { url: string };
        await expect(tb.tools["library.post"]!("NoSuchPost000000")).rejects.toThrow();
        const calls = tb.calls();
        expect(calls.map((c) => [c.op, c.status, c.card?.type ?? null])).toEqual([
            ["library.list", "done", "search"],
            ["look", "done", "look"],
            ["links.create", "done", "link"],
            ["library.post", "error", null],
        ]);
        expect(calls[0]!.card).toMatchObject({ type: "search", query: "video", total: 1, hits: [{ post_id: b.id, score: null }] });
        expect(calls[1]!.card).toEqual({ type: "look", post_ids: [a.id, b.id] });
        expect(calls[2]!.card).toMatchObject({ type: "link", url: link.url, title: "two", files: 2 });
        expect(calls[3]!.error).toMatch(/NoSuchPost000000/);
        expect(calls.every((c) => typeof c.ms === "number" && c.ms >= 0)).toBe(true);
        // the same calls went out live, in order
        expect(w.live.map((c) => c.op)).toEqual(calls.map((c) => c.op));
        // the message's posts map gets the ids the cards name
        expect(cardPostIds([{ calls }])).toEqual([b.id, a.id]);
    });

    function box(w: Awaited<ReturnType<typeof setup>>) {
        return w.box();
    }
});

describe("card builders", () => {
    const d = (w: Awaited<ReturnType<typeof world>>, before?: unknown) => ({ db: w.env.DB, mediaBaseUrl: MEDIA, before });

    it("emotes.find: the old bare array and the paged { sort, items } both work; bad urls are dropped", async () => {
        const w = await world();
        const e = { id: "01F6MQ33FG000FFJ97ZB8MWV52", name: "catJAM", animated: true, preview_url: "https://cdn.7tv.app/emote/x/2x.webp", file_url: "https://cdn.7tv.app/emote/x/4x.webp", library_id: null };
        const old = await cardFor("emotes.find", { query: "catJAM" }, [e, { ...e, id: "bad", preview_url: "javascript:1", file_url: null }], d(w));
        expect(old).toEqual({ type: "emotes", query: "catJAM", sort: null, saved: false, emotes: [{ id: e.id, name: "catJAM", animated: true, url: e.preview_url, library_id: null }] });
        const paged = await cardFor("emotes.find", { sort: "trending_weekly" }, { sort: "trending_weekly", page: 1, has_more: true, items: [{ ...e, library_id: "Lib0000000000001" }] }, d(w));
        expect(paged).toMatchObject({ sort: "trending_weekly", query: null, emotes: [{ library_id: "Lib0000000000001" }] });
        expect(postIdsOf(paged!)).toEqual(["Lib0000000000001"]);
    });

    it("an edit: main clips back to back (speed counts), overlay layers by track, kinds from the files, new clips marked", async () => {
        const w = await world();
        const v1 = w.video();
        const v2 = w.video();
        const emote = w.file({ source: "emote", name: "catJAM.webp" });
        const cut = w.file({ content_type: "image/png", ext: "png", name: "capy_cutout.png" });
        const timeline = {
            version: 1,
            canvas: { w: 720, h: 1280, fps: 30 },
            main: [
                { id: "m1", item: v1.id, in: 0, out: 10, speed: 1 },
                { id: "m2", item: v2.id, in: 4, out: 14, speed: 2, pitch: 3 },
            ],
            overlay: [
                { id: "o2", item: cut.id, at: 6, in: 0, out: 4, track: 1 },
                { id: "o1", item: emote.id, at: 1, in: 0, out: 3 },
            ],
        };
        const before = { main: timeline.main, overlay: [timeline.overlay[0]] };
        const card = await cardFor("edits.update", { id: "Proj000000000001", timeline }, { id: "Proj000000000001", title: "shrek", revision: 4, duration: 15, render: null }, d(w, before));
        expect(card).toMatchObject({ type: "edit", project_id: "Proj000000000001", title: "shrek", revision: 4, duration: 15, width: 720, height: 1280, change: "updated" });
        if (card?.type !== "edit") throw new Error("not an edit card");
        expect(card.tracks.map((t) => [t.name, t.index, t.clips.map((c) => [c.id, c.kind, c.at, c.length, c.is_new])])).toEqual([
            ["main", 0, [["m1", "video", 0, 10, false], ["m2", "video", 10, 5, false]]],
            ["overlay", 0, [["o1", "emote", 1, 3, true]]],
            ["overlay", 1, [["o2", "cutout", 6, 4, false]]],
        ]);
        expect(card.tracks[0]!.clips[1]).toMatchObject({ speed: 2, pitch: 3, post_id: v2.id });
        // a picture: the emote's own public webp; a video: its poster
        expect(card.tracks[1]!.clips[0]!.picture).toBe(emote.url);
        expect(card.tracks[0]!.clips[0]!.picture).toMatch(/^https:\/\/media\.capybaraharmony\.com\/Poster/);
        // nothing is new when the card has no "before"
        const viewed = await cardFor("edits.get", { id: "Proj000000000001" }, { id: "Proj000000000001", title: "shrek", revision: 4, duration: 15, timeline }, d(w));
        expect(viewed?.type === "edit" && viewed.tracks.every((t) => t.clips.every((c) => !c.is_new))).toBe(true);
    });

    it("jobs, the box, files and saves", async () => {
        const w = await world();
        expect(await cardFor("make.webp", { id: "x" }, { job: "j1", status: "running", progress: 0.4 }, d(w))).toMatchObject({ type: "job", op: "make.webp", status: "running", progress: 0.4, post_id: null });
        expect(await cardFor("jobs.onDone", { job: "j1" }, { job: "j1", status: "running", watching: true }, d(w))).toMatchObject({ watching: true });
        const run = await cardFor("box.run", { cmd: "ffmpeg -i a b" }, { code: 0, stdout: "x".repeat(3000), stderr: "", timed_out: false }, d(w));
        expect(run).toMatchObject({ type: "box", cmd: "ffmpeg -i a b", code: 0, timed_out: false });
        expect(run?.type === "box" && run.stdout.length).toBeLessThanOrEqual(1501);
        expect(await cardFor("box.save", { path: "out/capy.png" }, { post_id: "Post000000000001", kind: "image", bytes: 10, processing: false, public_url: null }, d(w))).toEqual({
            type: "files",
            direction: "out",
            files: [{ name: "capy.png", bytes: 10 }],
            post_id: "Post000000000001",
        });
        expect(await cardFor("library.save", { url: "https://x.com/a" }, { status: "ready", post_id: "P1", title: "a", save_id: "s" }, d(w))).toEqual({ type: "saved", post_ids: ["P1"], title: "a", status: "ready" });
        // a call with nothing to see: a chip only
        expect(await cardFor("stage.get", {}, { on: true }, d(w))).toBeNull();
        // a builder that meets a strange result gives no card instead of throwing
        expect(await cardFor("edits.get", {}, "nonsense", d(w))).toBeNull();
    });
});
