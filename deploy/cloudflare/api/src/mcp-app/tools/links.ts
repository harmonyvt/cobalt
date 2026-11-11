// list_collections, list_share_links and create_share_link (MCP-APP-CONTRACT.md section 4): gallery share links and the
// collections (folders) they are in.
import * as z from "zod";
import { CollectionsOut, LinksOut } from "../shapes";
import type { AppTool, AppToolCtx } from "../types";
import { arr, cut, int, listText, plural, readPosts, rec, str, type PostsRead } from "./common";

type Link = { id: string; url: string; title: string | null; private: boolean; created_at: string; post_ids: string[] };
type Collection = { id: string; name: string; link_ids: string[]; post_ids: string[] };

const linksOf = (v: unknown): Link[] =>
    arr(v).flatMap((l) => {
        const o = rec(l);
        const id = str(o.id);
        const url = str(o.url);
        // a link with no URL (the share host is off) cannot be handed to anyone
        if (!id || !url) return [];
        return [{ id, url, title: str(o.title), private: o.private === true, created_at: str(o.created_at) ?? new Date(0).toISOString(), post_ids: arr(o.post_ids).filter((x): x is string => typeof x === "string") }];
    });
const collectionsOf = (v: unknown): Collection[] =>
    arr(v).flatMap((c) => {
        const o = rec(c);
        const id = str(o.id);
        if (!id) return [];
        return [{ id, name: str(o.name) ?? id, link_ids: arr(o.link_ids).filter((x): x is string => typeof x === "string"), post_ids: arr(o.post_ids).filter((x): x is string => typeof x === "string") }];
    });

const fetchBoth = async (ctx: AppToolCtx) => {
    const [collections, links] = await Promise.all([ctx.call("collections.list", {}), ctx.call("links.list", {})]);
    return { collections: collectionsOf(collections), links: linksOf(links) };
};

// the first n public pictures among these posts, in their order
const picturesOf = (read: PostsRead, postIds: string[], n: number): string[] => {
    const out: string[] = [];
    for (const id of postIds) {
        const t = read.posts.get(id)?.thumb_url;
        if (t && !out.includes(t)) out.push(t);
        if (out.length >= n) break;
    }
    return out;
};

const matches = (name: string, wanted: string) => name.toLowerCase().includes(wanted.toLowerCase());

// ---- list_collections ---------------------------------------------------------------------------------------------------

const CollectionsInput = z.object({ name: z.string().min(1).max(200).optional(), limit: z.number().int().min(1).max(50).default(20) });
const COLLECTION_THUMBS = 8;
// a few more posts than pictures wanted: some have no public picture
const THUMB_CANDIDATES = 16;

export const listCollections: AppTool<z.infer<typeof CollectionsInput>> = {
    name: "list_collections",
    title: "List collections",
    description: "List the collections (folders of share links) in the capystore library, with their links and a few pictures.",
    input: CollectionsInput,
    output: CollectionsOut,
    readOnly: true,
    annotations: { openWorldHint: false },
    view: "collections",
    async run(ctx, input) {
        const { collections, links } = await fetchBoth(ctx);
        const found = input.name ? collections.filter((c) => matches(c.name, input.name!) || c.id === input.name) : collections;
        const shown = found.slice(0, input.limit);
        const linkOf = new Map(links.map((l) => [l.id, l]));
        const read = await readPosts(ctx.op, {
            posts: shown.flatMap((c) => c.post_ids.slice(0, THUMB_CANDIDATES)),
            sets: shown.flatMap((c) => c.link_ids),
        });
        const out = shown.map((c) => ({
            id: c.id,
            name: c.name,
            links: c.link_ids.flatMap((id) => {
                const l = linkOf.get(id);
                return l ? [{ id: l.id, url: l.url, files: read.setFiles.get(l.id) ?? l.post_ids.length, private: l.private }] : [];
            }),
            posts: c.post_ids.length,
            thumbs: picturesOf(read, c.post_ids.slice(0, THUMB_CANDIDATES), COLLECTION_THUMBS),
        }));
        const count =
            found.length === 0
                ? input.name
                    ? `No collection matches “${input.name}”.`
                    : "There are no collections yet."
                : `${plural(found.length, "collection")}${input.name ? ` match “${input.name}”` : ""}${found.length > out.length ? `, showing ${out.length}` : ""}.`;
        const rows = out.map((c) => `${cut(c.name, 60)} · ${plural(c.links.length, "link")} · ${plural(c.posts, "post")} · ${c.id}`);
        return {
            text: found.length === 0 ? count : listText(count, rows, out.length),
            structured: { view: "collections", total: found.length, collections: out } satisfies z.infer<typeof CollectionsOut>,
        };
    },
};

// ---- list_share_links -----------------------------------------------------------------------------------------------------

const LinksInput = z.object({
    collection: z.string().min(1).max(200).optional(),
    query: z.string().min(1).max(200).optional(),
    limit: z.number().int().min(1).max(50).default(20),
});
const LINK_THUMBS = 4;

type ShareLinkOut = z.infer<typeof LinksOut>["links"][number];

function linkOut(l: Link, read: PostsRead, collectionName: string | null): ShareLinkOut {
    return {
        id: l.id,
        url: l.url,
        title: l.title,
        files: read.setFiles.get(l.id) ?? l.post_ids.length,
        private: l.private,
        created_at: l.created_at,
        thumbs: picturesOf(read, l.post_ids, LINK_THUMBS),
        collection: collectionName,
    };
}
const linkRow = (l: ShareLinkOut) => `${cut(l.title ?? "Untitled link", 60)} · ${plural(l.files, "file")}${l.private ? " · private" : ""} · ${l.id} · ${l.url}`;

export const listShareLinks: AppTool<z.infer<typeof LinksInput>> = {
    name: "list_share_links",
    title: "List share links",
    description: "List the gallery share links in the capystore library (newest first), optionally only those in one collection or matching a title.",
    input: LinksInput,
    output: LinksOut,
    readOnly: true,
    annotations: { openWorldHint: false },
    view: "links",
    async run(ctx, input) {
        const { collections, links } = await fetchBoth(ctx);
        // the first collection a link is in names it
        const collectionOf = new Map<string, string>();
        for (const c of collections) for (const id of c.link_ids) if (!collectionOf.has(id)) collectionOf.set(id, c.name);
        let found = links;
        let inCollection: string | null = null;
        if (input.collection) {
            const c = collections.find((x) => x.id === input.collection) ?? collections.find((x) => x.name.toLowerCase() === input.collection!.toLowerCase()) ?? collections.find((x) => matches(x.name, input.collection!));
            inCollection = c?.name ?? null;
            const ids = new Set(c?.link_ids ?? []);
            found = found.filter((l) => ids.has(l.id));
        }
        if (input.query) found = found.filter((l) => matches(`${l.title ?? ""} ${l.id} ${l.url}`, input.query!));
        const shown = found.slice(0, input.limit);
        const read = await readPosts(ctx.op, { posts: shown.flatMap((l) => l.post_ids.slice(0, LINK_THUMBS * 3)), sets: shown.map((l) => l.id) });
        const out = shown.map((l) => linkOut(l, read, collectionOf.get(l.id) ?? null));
        const scope = input.collection ? (inCollection ? ` in “${inCollection}”` : ` in a collection named “${input.collection}” (none found)`) : "";
        const count = found.length === 0 ? `No share links${scope}${input.query ? ` matching “${input.query}”` : ""}.` : `${plural(found.length, "share link")}${scope}${found.length > out.length ? `, showing ${out.length}` : ""}.`;
        return {
            text: found.length === 0 ? count : listText(count, out.map(linkRow), out.length),
            structured: { view: "links", total: found.length, links: out, created: null } satisfies z.infer<typeof LinksOut>,
        };
    },
};

// ---- create_share_link ------------------------------------------------------------------------------------------------------

const CreateInput = z.object({
    ids: z.array(z.string().min(1).max(2048)).min(1).max(10),
    title: z.string().min(1).max(80).optional(),
    private: z.boolean().optional(),
    collection: z.string().min(1).max(60).optional(),
});

export const createShareLink: AppTool<z.infer<typeof CreateInput>> = {
    name: "create_share_link",
    title: "Create a share link",
    description:
        "Make one share link (share.capybaraharmony.com) for up to 10 posts, optionally private and optionally put in a collection. Only public posts can be shared publicly; use private for the rest.",
    input: CreateInput,
    output: LinksOut,
    readOnly: false,
    annotations: { destructiveHint: false, openWorldHint: false },
    view: "links",
    async run(ctx, input) {
        const made = rec(
            await ctx.call("links.create", {
                ids: input.ids,
                ...(input.title !== undefined ? { title: input.title } : {}),
                ...(input.private !== undefined ? { private: input.private } : {}),
            }),
        );
        const url = str(made.url) ?? "";
        // one file has a share page, not a gallery link: it has no id of its own
        const gallery = str(made.id);
        const id = gallery ?? url.split("/").filter(Boolean).pop() ?? "link";
        let collection: string | null = null;
        let note: string | null = null;
        if (input.collection) {
            if (gallery) {
                const c = rec(await ctx.call("collections.add", { collection: input.collection, links: [gallery] }));
                collection = str(c.name) ?? input.collection;
                note = c.created === true ? `Made the collection “${collection}” for it.` : `Added it to the collection “${collection}”.`;
            } else {
                note = `A single file has a share page, not a gallery link, so it was not put in “${input.collection}”.`;
            }
        }
        const read = await readPosts(ctx.op, { posts: input.ids, files: input.ids });
        const link: ShareLinkOut = {
            id,
            url,
            title: str(made.title),
            files: int(made.files, input.ids.length),
            private: made.private === true,
            created_at: new Date(ctx.op.now()).toISOString(),
            thumbs: picturesOf(read, [...new Set([...input.ids.map((i) => read.postOfFile.get(i) ?? i)])], LINK_THUMBS),
            collection,
        };
        const text = [
            `Made ${link.private ? "a private " : "a "}share link for ${plural(link.files, "file")}${link.title ? ` “${link.title}”` : ""}:`,
            url,
            link.private ? "Only people with this link can open it." : null,
            note,
        ]
            .filter(Boolean)
            .join("\n");
        return { text, structured: { view: "links", total: 1, links: [link], created: id } satisfies z.infer<typeof LinksOut> };
    },
};
