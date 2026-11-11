// Widgets for some write tools of the older set (MCP-APP-CONTRACT.md section 6.5) and the workbench box tools' terminal
// (section 5.1). The op runs as it always did and its text answer is unchanged; the view is built afterwards (from a fresh
// read, with the same helpers the app tools use, or from the op's own answer) and goes out as `structuredContent` with the
// tool's `_meta.ui.resourceUri`. Any failure of the read means no view: the caller then answers with the plain structured
// JSON of the op. Nothing here edits a registry op.
import type { PostSummary, View } from "./shapes";
import type { AppToolCtx } from "./types";
import { SLEEP_MS } from "../workbench-rules";
import { arr, num, readPosts, rec, signThumbs, str, strings, summaryOf } from "./tools/common";
import { readCollection, readLink } from "./tools/links";
import { showPost } from "./tools/post";

type Json = Record<string, unknown>;

export type Follow = {
    view: View;
    // the view's structuredContent, or null when the result does not name one thing to show
    build(ctx: AppToolCtx, input: unknown, result: unknown): Promise<Json | null>;
};

const collection: Follow = {
    view: "collections",
    // collections.create / add / update answer the collection itself
    async build(ctx, _input, result) {
        const id = str(rec(result).id);
        return id ? readCollection(ctx, id) : null;
    },
};

const link = (idOf: (result: Json) => string | null): Follow => ({
    view: "links",
    async build(ctx, _input, result) {
        const id = idOf(rec(result));
        return id ? readLink(ctx, id) : null;
    },
});

// the post a title / visibility / status call changed, when it is exactly one
const post = (idsOf: (input: Json) => string[]): Follow => ({
    view: "post",
    async build(ctx, input, _result) {
        const ids = [...new Set(idsOf(rec(input)))];
        return ids.length === 1 ? ((await showPost.run(ctx, { id: ids[0]! })).structured as Json) : null;
    },
});

// ---- the workbench box (MCP-APP-CONTRACT.md section 5.1): the op's own JSON plus what the terminal view needs ----------

// every box call keeps it awake for SLEEP_MS more; then it sleeps and its files are gone
const sleepsAt = (ctx: AppToolCtx) => new Date(ctx.op.now() + SLEEP_MS).toISOString();
// workbench-rules' Clip marks a stream cut past 8 KB like this
const CUT = /\n… \(\d+ bytes cut\) …\n/;

const boxRun: Follow = {
    view: "terminal",
    async build(ctx, input, result) {
        const r = rec(result);
        const cmd = str(rec(input).cmd);
        if (cmd === null || typeof r.code !== "number" || typeof r.stdout !== "string" || typeof r.stderr !== "string") return null;
        return { ...r, view: "terminal", tool: "run", cmd, timed_out: r.timed_out === true, ms: num(r.ms), stdout_cut: CUT.test(r.stdout), stderr_cut: CUT.test(r.stderr), sleeps_at: sleepsAt(ctx) };
    },
};

const boxPull: Follow = {
    view: "terminal",
    async build(ctx, _input, result) {
        const r = rec(result);
        if (!Array.isArray(r.files)) return null;
        return { ...r, view: "terminal", tool: "pull", files: arr(r.files), sleeps_at: sleepsAt(ctx) };
    },
};

// the post box.save made, as search and show_post show it (a private one's thumbnail signed into _meta); null when unreadable
async function savedPost(ctx: AppToolCtx, id: string): Promise<PostSummary | null> {
    try {
        const record = rec(await ctx.call("library.post", { id }));
        if (record.hidden === true) return null;
        const read = await readPosts(ctx.op, { posts: [id] });
        const post = summaryOf(record, read);
        if (post) await signThumbs(ctx, read, [post]);
        return post;
    } catch {
        return null;
    }
}

const boxSave: Follow = {
    view: "terminal",
    async build(ctx, _input, result) {
        const r = rec(result);
        const id = str(r.post_id);
        if (!id) return null;
        return { ...r, view: "terminal", tool: "save", public_url: str(r.public_url), post: await savedPost(ctx, id), sleeps_at: sleepsAt(ctx) };
    },
};

const idsOf = (i: Json) => (typeof i.ids === "string" ? [i.ids] : strings(i.ids));

// by chat call name
export const FOLLOWS: Record<string, Follow> = {
    "collections.create": collection,
    "collections.add": collection,
    "collections.update": collection,
    // a gallery link; a private link of one file is not a gallery link, so it has no view
    "links.update": link((r) => str(r.id)),
    "links.private": link((r) => (r.kind === "set" ? str(r.link) : null)),
    "links.rotate": link((r) => (r.kind === "set" ? str(r.link) : null)),
    "library.title": post((i) => (typeof i.id === "string" ? [i.id] : [])),
    "library.visibility": post(idsOf),
    "library.status": post(idsOf),
    // the box: offered (and so given its widget link) only while the workbench is on
    "box.run": boxRun,
    "box.pull": boxPull,
    "box.save": boxSave,
};
