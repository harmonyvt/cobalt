// Widgets for some write tools of the older set (MCP-APP-CONTRACT.md section 6.4). The op runs as it always did and its text
// answer is unchanged; the view is built afterwards from a fresh read, with the same helpers the app tools use, and goes
// out as `structuredContent` with the tool's `_meta.ui.resourceUri`. Any failure of the read means no view: the caller
// then answers with the plain structured JSON of the op. Nothing here edits a registry op.
import type { View } from "./shapes";
import type { AppToolCtx } from "./types";
import { rec, str, strings } from "./tools/common";
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
};
