// list_collections, list_share_links and create_share_link (MCP-APP-CONTRACT.md section 4): gallery share links and the
// collections (folders) they are in.
import * as z from "zod";
import { CollectionsOut, LinksOut } from "../shapes";
import type { AppTool, AppToolCtx } from "../types";
import { arr, cut, int, listText, plural, readPosts, rec, str, strings, type PostsRead } from "./common";

type Link = { id: string; url: string; title: string | null; private: boolean; created_at: string; post_ids: string[]; file_urls: (string | null)[] | null };
type Collection = { id: string; name: string; link_ids: string[]; post_ids: string[] };

const linksOf = (v: unknown): Link[] =>
    arr(v).flatMap((l) => {
        const o = rec(l);
        const id = str(o.id);
        const url = str(o.url);
        // a link with no URL (the share host is off) cannot be handed to anyone
        if (!id || !url) return [];
        return [{ id, url, title: str(o.title), private: o.private === true, created_at: str(o.created_at) ?? new Date(0).toISOString(), post_ids: strings(o.post_ids), file_urls: Array.isArray(o.file_urls) ? o.file_urls.map(str) : null }];
    });
const collectionsOf = (v: unknown): Collection[] =>
    arr(v).flatMap((c) => {
        const o = rec(c);
        const id = str(o.id);
        if (!id) return [];
        return [{ id, name: str(o.name) ?? id, link_ids: strings(o.link_ids), post_ids: strings(o.post_ids) }];
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

const CollectionsInput = z.object({ name: z.string().min(1).max(200).optional(), limit: z.number().int().min(1).max(500).default(20) });
const COLLECTION_THUMBS = 8;
// a few more posts than pictures wanted: some have no public picture
const THUMB_CANDIDATES = 16;

type CollectionOut = z.infer<typeof CollectionsOut>["collections"][number];

// The collections as the view draws them: their links with file counts, post counts and a few public pictures.
async function collectionsOut(ctx: AppToolCtx, shown: Collection[], links: Link[]): Promise<CollectionOut[]> {
    const linkOf = new Map(links.map((l) => [l.id, l]));
    const read = await readPosts(ctx.op, {
        posts: shown.flatMap((c) => c.post_ids.slice(0, THUMB_CANDIDATES)),
        sets: shown.flatMap((c) => c.link_ids),
    });
    return shown.map((c) => ({
        id: c.id,
        name: c.name,
        links: c.link_ids.flatMap((id) => {
            const l = linkOf.get(id);
            return l ? [{ id: l.id, url: l.url, files: read.setFiles.get(l.id) ?? l.post_ids.length, private: l.private }] : [];
        }),
        posts: c.post_ids.length,
        thumbs: picturesOf(read, c.post_ids.slice(0, THUMB_CANDIDATES), COLLECTION_THUMBS),
        link_ids: c.link_ids,
        post_ids: c.post_ids,
    }));
}

// One collection by id, as list_collections builds it (for the write tools that end on its view). Null when it is gone.
export async function readCollection(ctx: AppToolCtx, id: string): Promise<z.infer<typeof CollectionsOut> | null> {
    const { collections, links } = await fetchBoth(ctx);
    const found = collections.find((c) => c.id === id);
    if (!found) return null;
    return { view: "collections", total: 1, collections: await collectionsOut(ctx, [found], links) };
}

export const listCollections: AppTool<z.infer<typeof CollectionsInput>> = {
    name: "list_collections",
    title: "List collections",
    description:
        "List the collections (folders of share links) in the capystore library, with their link ids and post ids and a few pictures. name: part of a collection's name, or its id; limit up to 500.",
    input: CollectionsInput,
    output: CollectionsOut,
    readOnly: true,
    annotations: { openWorldHint: false },
    view: "collections",
    async run(ctx, input) {
        const { collections, links } = await fetchBoth(ctx);
        const found = input.name ? collections.filter((c) => matches(c.name, input.name!) || c.id === input.name) : collections;
        const out = await collectionsOut(ctx, found.slice(0, input.limit), links);
        const count =
            found.length === 0
                ? input.name
                    ? `No collection matches “${input.name}”.`
                    : "There are no collections yet."
                : `${plural(found.length, "collection")}${input.name ? ` match “${input.name}”` : ""}${found.length > out.length ? `, showing ${out.length}` : ""}.`;
        const rows = out.map((c) => `${cut(c.name, 60)} · ${plural(c.links.length, "link")} · ${plural(c.posts, "post")} · ${c.id}${c.links.length > 0 ? ` · links: ${c.links.map((l) => l.id).join(", ")}` : ""}`);
        return {
            text: found.length === 0 ? count : listText(count, rows, out.length, input.limit),
            structured: { view: "collections", total: found.length, collections: out } satisfies z.infer<typeof CollectionsOut>,
        };
    },
};

// ---- list_share_links -----------------------------------------------------------------------------------------------------

const LinksInput = z.object({
    collection: z.string().min(1).max(200).optional(),
    query: z.string().min(1).max(200).optional(),
    limit: z.number().int().min(1).max(500).default(20),
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
        post_ids: l.post_ids,
        file_urls: l.file_urls,
    };
}
const linkRow = (l: ShareLinkOut) =>
    `${cut(l.title ?? "Untitled link", 60)} · ${plural(l.files, "file")}${l.private ? " · private" : ""} · ${l.id} · ${l.url}${l.post_ids && l.post_ids.length > 0 ? ` · posts: ${l.post_ids.join(", ")}` : ""}${l.private && l.file_urls && l.file_urls.some(Boolean) ? ` · files: ${l.file_urls.filter(Boolean).join(", ")}` : ""}`;

// One link by id, as list_share_links builds it, with `created` set to it (for the write tools that end on the links
// view). Null when it is gone or has no URL.
export async function readLink(ctx: AppToolCtx, id: string): Promise<z.infer<typeof LinksOut> | null> {
    const { collections, links } = await fetchBoth(ctx);
    const l = links.find((x) => x.id === id);
    if (!l) return null;
    const read = await readPosts(ctx.op, { posts: l.post_ids.slice(0, LINK_THUMBS * 3), sets: [l.id] });
    const inCollection = collections.find((c) => c.link_ids.includes(l.id))?.name ?? null;
    return { view: "links", total: 1, links: [linkOut(l, read, inCollection)], created: l.id };
}

export const listShareLinks: AppTool<z.infer<typeof LinksInput>> = {
    name: "list_share_links",
    title: "List share links",
    description:
        "List the gallery share links in the capystore library (newest first), with their post ids, optionally only those in one collection or matching a title. limit up to 500.",
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
            text: found.length === 0 ? count : listText(count, out.map(linkRow), out.length, input.limit),
            structured: { view: "links", total: found.length, links: out, created: null } satisfies z.infer<typeof LinksOut>,
        };
    },
};

// ---- create_share_link ------------------------------------------------------------------------------------------------------

const CreateInput = z.object({
    // post ids or file ids; a gallery post brings its files (the link holds 10 files at most, the op says when it is too many)
    ids: z.union([z.array(z.string().min(1).max(2048)).min(1), z.string().min(1).max(2048)]),
    // "" was accepted by the older tool: it means no title
    title: z
        .string()
        .max(80)
        .optional()
        .transform((t) => (t === "" ? undefined : t)),
    private: z.boolean().optional(),
    collection: z.string().min(1).max(60).optional(),
});

export const createShareLink: AppTool<z.infer<typeof CreateInput>> = {
    name: "create_share_link",
    title: "Create a share link",
    description:
        "Make one share link (share.capybaraharmony.com) for posts, 10 files at most (one file gets its share page), optionally private and optionally put in a collection. Only public posts can be shared publicly; use private for the rest.",
    input: CreateInput,
    output: LinksOut,
    readOnly: false,
    annotations: { destructiveHint: false, openWorldHint: false },
    view: "links",
    async run(ctx, input) {
        const ids = typeof input.ids === "string" ? [input.ids] : input.ids;
        const made = rec(
            await ctx.call("links.create", {
                ids,
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
        const read = await readPosts(ctx.op, { posts: ids, files: ids });
        const postIds = [...new Set(ids.map((i) => read.postOfFile.get(i) ?? i))];
        const link: ShareLinkOut = {
            id,
            url,
            title: str(made.title),
            files: int(made.files, ids.length),
            private: made.private === true,
            created_at: new Date(ctx.op.now()).toISOString(),
            thumbs: picturesOf(read, postIds, LINK_THUMBS),
            collection,
            post_ids: postIds,
            file_urls: Array.isArray(made.file_urls) ? made.file_urls.map(str) : null,
        };
        const text = [
            `Made ${link.private ? "a private " : "a "}share link for ${plural(link.files, "file")}${link.title ? ` “${link.title}”` : ""}:`,
            url,
            link.private ? "Only people with this link can open it." : null,
            gallery ? `Link id: ${gallery}` : null,
            link.file_urls && link.file_urls.length > 0 ? `Direct file links:\n${link.file_urls.filter(Boolean).join("\n")}` : null,
            note,
        ]
            .filter(Boolean)
            .join("\n");
        return { text, structured: { view: "links", total: 1, links: [link], created: id } satisfies z.infer<typeof LinksOut> };
    },
};
