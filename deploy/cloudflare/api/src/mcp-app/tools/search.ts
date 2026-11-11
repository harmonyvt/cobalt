// search_library: meaning search when it is on, else the title/link match of library.list (MCP-APP-CONTRACT.md section 4).
import * as z from "zod";
import { SearchOut } from "../shapes";
import type { AppTool } from "../types";
import { arr, listText, plural, postLine, readPosts, rec, str, summaryOf } from "./common";

const Input = z.object({
    query: z.string().min(1).max(200),
    kind: z.enum(["video", "image", "gallery"]).optional(),
    since: z
        .string()
        .refine((s) => !Number.isNaN(Date.parse(s)), "an ISO date")
        .optional(),
    limit: z.number().int().min(1).max(24).default(12),
});

// meaning search scores every post and has no kind or date filter: with a filter, read deeper and cut here
const DEEP = 100;

export const searchLibrary: AppTool<z.infer<typeof Input>> = {
    name: "search_library",
    title: "Search the library",
    description:
        "Find videos, images and galleries in the capystore library by what they show or say (meaning search), or by title when meaning search is off. Shows the best matches as pictures.",
    input: Input,
    output: SearchOut,
    readOnly: true,
    annotations: { openWorldHint: false },
    view: "search",
    async run(ctx, input) {
        const since = input.since ? Date.parse(input.since) : null;
        const filtered = input.kind !== undefined || since !== null;
        let mode: "meaning" | "text" = "text";
        let rows: unknown[] | null = null;
        if (ctx.has("library.search")) {
            try {
                rows = arr(await ctx.call("library.search", { query: input.query, limit: filtered ? DEEP : input.limit }));
                mode = "meaning";
            } catch {
                // the search model is waking up or failed: the title match answers instead
            }
        }
        if (rows === null) {
            rows = arr(
                await ctx.call("library.list", {
                    query: input.query,
                    ...(input.kind ? { kind: input.kind } : {}),
                    ...(input.since ? { since: input.since } : {}),
                    limit: DEEP,
                }),
            );
        }
        const matches = rows.filter((r) => {
            const o = rec(r);
            if (input.kind && o.kind !== input.kind) return false;
            if (since !== null) {
                const t = Date.parse(str(o.saved_at) ?? "");
                if (!(t >= since)) return false;
            }
            return true;
        });
        // one batch for every match; a hidden post is not in it, so it never shows and is not counted
        const read = await readPosts(ctx.op, { posts: matches.map((r) => str(rec(r).id) ?? "") });
        const visible = matches.flatMap((r) => summaryOf(r, read) ?? []);
        const items = visible.slice(0, input.limit);
        const total = visible.length;
        const how = mode === "meaning" ? "by meaning" : "by title";
        const count = items.length === 0 ? `No posts found for “${input.query}” (searched ${how}).` : `${plural(total, "post")} for “${input.query}” (searched ${how}${total > items.length ? `, showing ${items.length}` : ""}).`;
        const text = items.length === 0 ? count : listText(count, items.map((p) => postLine(p, read.posts.get(p.id)?.share_url ?? null)), items.length);
        return { text, structured: { view: "search", query: input.query, mode, total, items } satisfies z.infer<typeof SearchOut> };
    },
};
