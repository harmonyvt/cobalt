// search_library: meaning search when it is on, else the title/link match of library.list; with no query, the library
// newest first (MCP-APP-CONTRACT.md section 4). It takes every option library.search and library.list had.
import * as z from "zod";
import { OpError } from "../../registry/op";
import { SearchOut } from "../shapes";
import type { AppTool } from "../types";
import { arr, clock, cut, listText, num, plural, readPosts, rec, signThumbs, str, strings, summaryOf, type PostsRead } from "./common";

type Out = z.infer<typeof SearchOut>;
type Item = Out["items"][number];

const When = z.union([
    z.string().refine((s) => !Number.isNaN(Date.parse(s)), "an ISO date"),
    z.number(),
]);

// library.search's `within`: a collection (id or name), a gallery link, or a list of posts
const Within = z.union([
    z.string().min(1).max(200),
    z.object({ collection: z.string().min(1).max(200) }),
    z.object({ link: z.string().min(1).max(64) }),
    z.object({ posts: z.array(z.string().min(1).max(2048)).min(1).max(500) }),
]);

const Input = z.object({
    query: z.string().min(1).max(200).optional().describe("what to look for; leave it out to list the library newest first"),
    kind: z.enum(["video", "image", "gallery"]).optional(),
    since: When.optional().describe("ISO date or ms"),
    until: When.optional().describe("ISO date or ms"),
    source: z.string().min(1).optional().describe('a host, e.g. "tiktok.com"'),
    within: Within.optional().describe("only these (meaning search): { collection: id or name } | { link: id } | { posts: [ids] }"),
    match: z
        .enum(["meaning", "text"])
        .optional()
        .describe('"text": only the substring match of title, file names, link and caption (a find box; good for a link or a file name); default: meaning search when it is on'),
    // above 1000 is cut to 1000 (the older tools did that); no limit: 12, or up to 500 with `within`
    limit: z
        .number()
        .int()
        .min(1)
        .optional()
        .transform((n) => (n === undefined ? undefined : Math.min(n, 1000)))
        .describe("default 12 (500 with within); at most 500 with a query, 1000 without"),
});

// meaning search scores every post and has no kind or date filter: with a filter, read deeper and cut here
const DEEP = 100;
// the most library.search takes; library.list takes up to 1000
const SEARCH_MAX = 500;

const ms = (v: string | number | undefined): number | null => (v === undefined ? null : typeof v === "number" ? v : Date.parse(v));
const hostMatches = (host: unknown, wanted: string) => {
    const w = wanted.toLowerCase().replace(/^www\./, "");
    const h = str(host);
    return !!h && (h === w || h.endsWith(`.${w}`));
};

// One line per post: everything an agent needs for its next call (the id first among them), no widget needed.
function rowOf(p: Item, share: string | null, mode: Out["mode"]): string {
    const bits = [
        cut(p.title, 80),
        p.kind === "video" && p.duration_s !== null ? `video ${clock(p.duration_s)}` : p.kind === "gallery" ? `gallery of ${p.files}` : p.kind,
        p.id,
        p.saved_at.slice(0, 10),
        p.source_link ?? p.source_host,
        p.status === "public" ? share : p.status === "off" ? "not shared" : "private",
        mode === "meaning" && p.score !== null ? `score ${p.score}` : null,
        p.why && p.why.length > 0 ? `why: ${p.why.join(", ")}` : null,
        p.said && p.said.length > 0 ? `says @${clock(p.said[0]!.at)}: “${cut(p.said[0]!.text, 80)}”` : null,
    ];
    return bits.filter(Boolean).join(" · ");
}

function itemOf(record: unknown, read: PostsRead): Item | null {
    const summary = summaryOf(record, read);
    if (!summary) return null;
    const r = rec(record);
    const score = num(r.score);
    const why = Array.isArray(r.why) ? strings(r.why) : null;
    const said = Array.isArray(r.said)
        ? arr(r.said).flatMap((s) => {
              const o = rec(s);
              const text = str(o.text);
              return text !== null && num(o.at) !== null ? [{ at: num(o.at)!, end: num(o.end) ?? num(o.at)!, text, match: str(o.match) ?? "words" }] : [];
          })
        : null;
    return { ...summary, source_link: str(r.link), caption: str(r.caption), score, why, said: said && said.length > 0 ? said : null };
}

export const searchLibrary: AppTool<z.infer<typeof Input>> = {
    name: "search_library",
    title: "Search the library",
    description:
        "Find videos, images and galleries in the capystore library by what they show or say (meaning search), or by title when meaning search is off. With no query it lists the library newest first. match: text is a plain substring match of title, names, link and caption. Filters: kind, since/until (ISO date or ms), source (a host such as tiktok.com), within (a collection, link or list of posts; meaning search only). Shows the best matches as pictures and lists every row with its id in text.",
    input: Input,
    output: SearchOut,
    readOnly: true,
    annotations: { openWorldHint: false },
    view: "search",
    async run(ctx, input) {
        const since = ms(input.since);
        const until = ms(input.until);
        const query = input.query ?? null;
        if (query === null && input.within !== undefined) {
            throw new OpError(400, "error.search.within_needs_query", "within narrows a meaning search: add a query (what to look for), or leave within out to list the library");
        }
        // within with no limit: score deeper (a collection is often longer than 12) instead of cutting it to 12
        const limit = input.limit ?? (input.within !== undefined ? SEARCH_MAX : 12);
        const filtered = input.kind !== undefined || since !== null || until !== null || input.source !== undefined;
        let mode: Out["mode"] = query === null ? "list" : "text";
        let rows: unknown[] | null = null;
        if (query !== null && input.match !== "text" && ctx.has("library.search")) {
            try {
                rows = arr(
                    await ctx.call("library.search", {
                        query,
                        limit: Math.min(SEARCH_MAX, filtered ? Math.max(DEEP, limit) : limit),
                        ...(input.within !== undefined ? { within: input.within } : {}),
                    }),
                );
                mode = "meaning";
            } catch (e) {
                // the search model is waking up or failed: the title match answers instead (it cannot honour `within`)
                if (input.within !== undefined) {
                    throw new OpError(503, "error.search.within_needs_meaning", `searching within needs meaning search, which is not answering now (${e instanceof Error ? e.message : "off"}); try again in a minute, or search without within`);
                }
            }
        } else if (query !== null && input.within !== undefined) {
            throw new OpError(409, "error.search.within_needs_meaning", `searching within needs meaning search, which is ${input.match === "text" ? "not what match: text does" : "off on this server"}`);
        }
        if (rows === null) {
            rows = arr(
                await ctx.call("library.list", {
                    ...(query !== null ? { query } : {}),
                    ...(input.kind ? { kind: input.kind } : {}),
                    ...(input.since !== undefined ? { since: input.since } : {}),
                    ...(input.until !== undefined ? { until: input.until } : {}),
                    ...(input.source ? { source: input.source } : {}),
                    // the op filters and hides natively, so it is asked for exactly what was wanted
                    limit: limit,
                }),
            );
        }
        const matches = rows.filter((r) => {
            const o = rec(r);
            if (input.kind && o.kind !== input.kind) return false;
            if (since !== null || until !== null) {
                const t = Date.parse(str(o.saved_at) ?? "");
                if (since !== null && !(t >= since)) return false;
                if (until !== null && !(t < until)) return false;
            }
            if (input.source && !hostMatches(o.source, input.source)) return false;
            return true;
        });
        // one batch for every match; a hidden post is not in it, so it never shows and is not counted
        const read = await readPosts(ctx.op, { posts: matches.map((r) => str(rec(r).id) ?? "") });
        const visible = matches.flatMap((r) => itemOf(r, read) ?? []);
        const cap = mode === "meaning" ? Math.min(limit, SEARCH_MAX) : limit;
        const items = visible.slice(0, cap);
        const total = visible.length;
        await signThumbs(ctx, read, items);
        const how = mode === "meaning" ? "by meaning" : mode === "text" ? "by title" : "newest first";
        // the title match and the list stop at `limit` rows: when it was reached there may be more to ask for
        const more = mode !== "meaning" && rows.length >= limit;
        const tail = total > items.length ? `, showing ${items.length}` : more ? `, the first ${items.length}; there may be more: raise limit` : "";
        const count =
            items.length === 0
                ? query === null
                    ? "No posts in the library for those filters."
                    : `No posts found for “${query}” (searched ${how}).`
                : query === null
                  ? `${plural(total, "post")}, ${how}${tail}.`
                  : `${plural(total, "post")} for “${query}” (searched ${how}${tail}).`;
        const text = items.length === 0 ? count : listText(count, items.map((p) => rowOf(p, read.posts.get(p.id)?.share_url ?? null, mode)), items.length, limit);
        return { text, structured: { view: "search", query: query ?? "", mode, total, items } satisfies Out };
    },
};
