// Share ops (APP-API-CONTRACT.md 33.7): gallery links (section 24), their collections (26) and the collection sets
// (28). Two kinds of op:
//  - the routes, tier hidden, wrapping the existing handlers unchanged (same parsing, bodies, codes and headers);
//  - the chat AI's calls (ai.only): cobalt.links.create/revoke, cobalt.collections.create/add/update/reroll/delete and
//    cobalt.sets.list/create/add/update/delete. They run the same handlers. Links are always share host URLs, never
//    raw media URLs. Revoking a link, rerolling a collection (it revokes every old URL) and deleting a collection or a
//    set ask Harmony first.
import * as z from "zod";
import { POST_KEY_SQL } from "../../app-routes";
import { loadPosts } from "../../chat-tools";
import { createGroup, deleteGroup, GROUP_ID_REGEX, listGroups, updateGroup, type GroupDeps } from "../../collection-groups";
import { KEY_ID_HEADER } from "../../headers";
import { captionerFrom } from "../../roast";
import {
    COLLECTION_ID_REGEX,
    createCollection,
    deleteCollection,
    listCollections,
    rerollCollection,
    updateCollection,
    type CollectionDeps,
} from "../../share-collections";
import { createShareSet, listShareSets, revokeShareSet, SET_ID_REGEX, SHARE_SET_MAX, type ShareSetDeps } from "../../share-sets";
import type { StudioReply } from "../../studio";
import { effectiveVisibility } from "../../visibility";
import { defineOp, ok, OpError, type OpContext, type OpReply } from "../op";

// ---- deps, built exactly as worker.ts built them ---------------------------------------------------------------------

const shareOff = () => new OpError(404, "error.share.off", "share links are off on this server");

// Gallery links: D1 only. The captioner writes the link's roast caption at creation (section 25); a new link's videos
// get moving previews while GALLERY_LOOPS is "1" (section 29).
export function shareSetDeps(ctx: OpContext, o: { captions?: boolean } = {}): ShareSetDeps | null {
    const { env, edge, container } = ctx;
    if (!ctx.shareBaseUrl) return null;
    return {
        db: ctx.db,
        mediaBaseUrl: ctx.mediaBaseUrl,
        shareBaseUrl: ctx.shareBaseUrl,
        now: ctx.now,
        captioner: o.captions === false ? null : (edge.captioner ?? captionerFrom(env, edge.modelFetch)),
        kickLoops:
            env.GALLERY_LOOPS !== "1"
                ? undefined
                : async () => {
                      const p = container
                          .fetch(
                              new Request("https://do.internal/loops/kick", {
                                  method: "POST",
                                  headers: { [KEY_ID_HEADER]: "worker:loops" },
                              }),
                          )
                          .then(
                              (res) => void res.body?.cancel().catch(() => {}),
                              (e) => console.error("[loops] kick failed", e instanceof Error ? e.name : "error"),
                          );
                      if (edge.waitUntil) edge.waitUntil(p);
                      else await p;
                  },
    };
}

export function collectionDeps(ctx: OpContext): CollectionDeps | null {
    if (!ctx.shareBaseUrl) return null;
    return {
        db: ctx.db,
        now: ctx.now,
        mediaBaseUrl: ctx.mediaBaseUrl,
        shareBaseUrl: ctx.env.SHARE_BASE_URL,
        captioner: ctx.edge.captioner === undefined ? captionerFrom(ctx.env, ctx.edge.modelFetch) : ctx.edge.captioner,
    };
}

const groupDeps = (ctx: OpContext): GroupDeps | null => (ctx.shareBaseUrl ? { db: ctx.db, now: ctx.now } : null);

// ---- the routes (tier hidden) ---------------------------------------------------------------------------------------

// The handlers read the body themselves; the route only names the path.
const NoInput = z.object({});
const routeInput = () => ({});
const offReply = (): OpReply => ({ status: 404, body: { status: "error", error: { code: "error.share.off" } } });
// Replies carry no-store; the "share is off" 404 never did.
const stored = (r: StudioReply): OpReply => ({ status: r.status, body: r.body, headers: { "cache-control": "no-store" } });

const route = (
    name: string,
    method: "GET" | "POST" | "PATCH" | "DELETE",
    path: string,
    run: (ctx: OpContext, keyId: string) => Promise<StudioReply> | null,
    params?: Record<string, RegExp>,
) =>
    defineOp({
        name,
        route: { method, path, ...(params ? { params } : {}) },
        auth: "key",
        runs: "worker",
        cors: true,
        input: NoInput,
        http: routeInput,
        ai: { tier: "hidden", summary: `${method} ${path}` },
        handler: async (ctx) => {
            const p = run(ctx, ctx.keyId!);
            return p ? stored(await p) : offReply();
        },
    });

const withSets = (ctx: OpContext, f: (d: ShareSetDeps) => Promise<StudioReply>) => {
    const d = shareSetDeps(ctx);
    return d ? f(d) : null;
};
const withCollections = (ctx: OpContext, f: (d: CollectionDeps) => Promise<StudioReply>) => {
    const d = collectionDeps(ctx);
    return d ? f(d) : null;
};
const withGroups = (ctx: OpContext, f: (d: GroupDeps) => Promise<StudioReply>) => {
    const d = groupDeps(ctx);
    return d ? f(d) : null;
};

const ROUTE_OPS = [
    // gallery links (section 24)
    route("share_sets.list", "GET", "/share/sets", (ctx) => withSets(ctx, (d) => listShareSets(d))),
    route("share_sets.create", "POST", "/share/sets", (ctx, key) => withSets(ctx, (d) => createShareSet(d, ctx.request!, key))),
    route("share_sets.revoke", "DELETE", "/share/sets/:id", (ctx) => withSets(ctx, (d) => revokeShareSet(d, ctx.params.id!)), { id: SET_ID_REGEX }),
    // collections (section 26)
    route("share_collections.list", "GET", "/share/collections", (ctx) => withCollections(ctx, (d) => listCollections(d))),
    route("share_collections.create", "POST", "/share/collections", (ctx, key) => withCollections(ctx, (d) => createCollection(d, ctx.request!, key))),
    route(
        "share_collections.update",
        "PATCH",
        "/share/collections/:id",
        (ctx) => withCollections(ctx, (d) => updateCollection(d, ctx.request!, ctx.params.id!)),
        { id: COLLECTION_ID_REGEX },
    ),
    route(
        "share_collections.delete",
        "DELETE",
        "/share/collections/:id",
        (ctx) => withCollections(ctx, (d) => deleteCollection(d, ctx.params.id!)),
        { id: COLLECTION_ID_REGEX },
    ),
    route(
        "share_collections.reroll",
        "POST",
        "/share/collections/:id/reroll",
        (ctx, key) => withCollections(ctx, (d) => rerollCollection(d, ctx.params.id!, key)),
        { id: COLLECTION_ID_REGEX },
    ),
    // collection sets (section 28)
    route("share_groups.list", "GET", "/share/groups", (ctx) => withGroups(ctx, (d) => listGroups(d))),
    route("share_groups.create", "POST", "/share/groups", (ctx, key) => withGroups(ctx, (d) => createGroup(d, ctx.request!, key))),
    route("share_groups.update", "PATCH", "/share/groups/:id", (ctx) => withGroups(ctx, (d) => updateGroup(d, ctx.request!, ctx.params.id!)), {
        id: GROUP_ID_REGEX,
    }),
    route("share_groups.delete", "DELETE", "/share/groups/:id", (ctx) => withGroups(ctx, (d) => deleteGroup(d, ctx.params.id!)), {
        id: GROUP_ID_REGEX,
    }),
];

// ---- helpers for the chat AI's calls ---------------------------------------------------------------------------------

// A JSON request for a handler that reads its own body (the chat has no HTTP request).
export const bodyRequest = (method: string, body: unknown) =>
    new Request("https://chat.internal/", { method, headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

const codeOf = (body: unknown): string => {
    const c = (body as { error?: { code?: unknown } } | null)?.error?.code;
    return typeof c === "string" ? c : "error.api.generic";
};

// A handler's reply as the body the model gets, or an OpError with a line the model can act on.
export function unwrap<T = Record<string, unknown>>(r: StudioReply, messages: Record<string, string> = {}): T {
    if (r.status >= 200 && r.status <= 299) return r.body as T;
    const code = codeOf(r.body);
    throw new OpError(r.status, code, messages[code]);
}

// "1234…" or a share URL ".../g/1234…" -> the link id.
const linkIdOf = (v: string): string => /\/g\/([0-9]{19})\/?$/.exec(v.trim())?.[1] ?? v.trim();
const OneOrMany = (inner: z.ZodType<string>) =>
    z.preprocess((v) => (Array.isArray(v) ? v : v === undefined ? v : [v]), z.array(inner).min(1));
const LinkId = z.string().transform(linkIdOf).pipe(z.string().regex(SET_ID_REGEX, "a gallery link id (19 digits) or its share URL"));
const LinkIds = OneOrMany(LinkId);
// a collection or a set: its id or its name
const Ref = z.string().trim().min(1).max(60);

const CollectionShape = z.object({ id: z.string(), name: z.string(), link_ids: z.array(z.string()) }).meta({ id: "Collection" });
const SetShape = z.object({ id: z.string(), name: z.string(), collection_ids: z.array(z.string()) }).meta({ id: "CollectionSet" });
const LinkShape = z
    .object({
        id: z.string().nullable().describe("the gallery link's id; null for a one-file link (the file's own page)"),
        url: z.string().describe("the share.capybaraharmony.com link to give Harmony"),
        title: z.string().nullable(),
        files: z.number(),
    })
    .meta({ id: "ShareLink" });

const collectionOut = (c: { id: string; name: string; set_ids: string[] }) => ({ id: c.id, name: c.name, link_ids: c.set_ids });
const setOut = (g: { id: string; name: string; collection_ids: string[] }) => ({ id: g.id, name: g.name, collection_ids: g.collection_ids });

// A collection by id, else by name (case-insensitive, the most recently changed when two share it).
export async function findCollection(db: D1Database, ref: string): Promise<{ id: string; name: string } | null> {
    const r = ref.trim();
    return (
        (await db
            .prepare("SELECT id, name FROM share_collections WHERE id = ?1 OR lower(name) = lower(?1) ORDER BY (id = ?1) DESC, updated_at DESC LIMIT 1")
            .bind(r)
            .first<{ id: string; name: string }>()) ?? null
    );
}

async function findGroup(db: D1Database, ref: string): Promise<{ id: string; name: string } | null> {
    const r = ref.trim();
    return (
        (await db
            .prepare("SELECT id, name FROM collection_groups WHERE id = ?1 OR lower(name) = lower(?1) ORDER BY (id = ?1) DESC, updated_at DESC LIMIT 1")
            .bind(r)
            .first<{ id: string; name: string }>()) ?? null
    );
}

const needCollection = async (ctx: OpContext, ref: string) => {
    const c = await findCollection(ctx.db, ref);
    if (!c) throw new OpError(404, "error.collection.not_found", `no collection called or with id "${ref}" (cobalt.collections.list() lists them)`);
    return c;
};
const needGroup = async (ctx: OpContext, ref: string) => {
    const g = await findGroup(ctx.db, ref);
    if (!g) throw new OpError(404, "error.group.not_found", `no set called or with id "${ref}" (cobalt.sets.list() lists them)`);
    return g;
};

const COLLECTION_MESSAGES: Record<string, string> = {
    "error.collection.link_not_found": "one of those gallery links does not exist or was revoked (cobalt.links.list() lists the live ones)",
    "error.collection.too_many": "there are already 100 collections",
    "error.collection.full": "a collection holds at most 200 links",
    "error.collection.bad_request": "a collection name is 1 to 60 characters",
    "error.collection.empty": "that collection has no live links to reroll",
};
const GROUP_MESSAGES: Record<string, string> = {
    "error.group.collection_not_found": "one of those collections does not exist",
    "error.group.too_many": "there are already 100 sets",
    "error.group.full": "a set holds at most 100 collections",
    "error.group.bad_request": "a set name is 1 to 60 characters",
};

type Row = Awaited<ReturnType<typeof loadPosts>>[number]["rows"][number];
type LinkFiles = { files: { id: string; url: string }[]; notPublic: string[]; unknown: string[] };

// The public files that stand for each id, in order: a post id (a gallery gives its public items, any other post its
// lead file when public, else its newest public file) or a file id from cobalt.library.post. Duplicates are dropped.
export async function linkFiles(ctx: Pick<OpContext, "db" | "mediaBaseUrl">, ids: string[]): Promise<LinkFiles> {
    const { results: direct } = await ctx.db
        .prepare(
            `SELECT m.id AS id, ${POST_KEY_SQL} AS post_key FROM media_items m
              WHERE m.deleted_at IS NULL AND m.id IN (SELECT value FROM json_each(?1))`,
        )
        .bind(JSON.stringify(ids))
        .all<{ id: string; post_key: string }>();
    const postOfFile = new Map(direct.map((r) => [r.id, r.post_key]));
    const posts = new Map((await loadPosts(ctx, [...new Set([...ids, ...postOfFile.values()])])).map((p) => [p.record.id, p]));
    const isPublic = (r: Row) => effectiveVisibility(r) === "public" && !!r.url;
    const out: LinkFiles = { files: [], notPublic: [], unknown: [] };
    const seen = new Set<string>();
    const take = (r: Row) => {
        if (seen.has(r.id)) return;
        seen.add(r.id);
        out.files.push({ id: r.id, url: r.url! });
    };
    for (const id of ids) {
        const post = posts.get(id);
        if (post) {
            const items = post.rows.filter((r) => r.role === "item").sort((a, b) => (a.item_index ?? 0) - (b.item_index ?? 0));
            if (items.length > 1) {
                const pub = items.filter(isPublic);
                if (pub.length === 0) out.notPublic.push(id);
                pub.forEach(take);
                continue;
            }
            const pick = [post.lead, ...post.rows].find(isPublic);
            if (pick) take(pick);
            else out.notPublic.push(id);
            continue;
        }
        const row = postOfFile.has(id) ? posts.get(postOfFile.get(id)!)?.rows.find((r) => r.id === id) : undefined;
        if (!row) out.unknown.push(id);
        else if (isPublic(row)) take(row);
        else out.notPublic.push(id);
    }
    return out;
}

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);

// One link for these files: a gallery link (2..10 files), or the file's own share page for one file.
export async function makeLink(
    ctx: OpContext,
    fileIds: { id: string; url: string }[],
    title: string | undefined,
    o: { captions?: boolean } = {},
): Promise<z.infer<typeof LinkShape>> {
    const d = shareSetDeps(ctx, o);
    if (!d) throw shareOff();
    if (fileIds.length === 1) {
        const name = /\/([A-Za-z0-9]{6,40})\.[A-Za-z0-9]{1,8}$/.exec(fileIds[0]!.url)?.[1];
        if (!name) throw new OpError(409, "error.share.not_public", "that file has no share page");
        return { id: null, url: `${withSlash(d.shareBaseUrl)}${name}`, title: null, files: 1 };
    }
    const r = await createShareSet(d, bodyRequest("POST", { items: fileIds.map((f) => f.id), ...(title ? { title } : {}) }), ctx.keyId!);
    const body = unwrap<{ set: { id: string; url: string; title: string | null; items: unknown[] } }>(r, {
        "error.share.not_public": "some of those files are not public any more",
        "error.share.bad_request": `a gallery link holds 2 to ${SHARE_SET_MAX} files and a title of at most 80 characters`,
    });
    return { id: body.set.id, url: body.set.url, title: body.set.title, files: body.set.items.length };
}

// ---- the chat AI's calls --------------------------------------------------------------------------------------------

export const linksCreateOp = defineOp({
    name: "links.create",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        ids: OneOrMany(z.string().min(1).max(2048)).describe("post ids (or file ids from post())"),
        title: z.string().max(80).optional().describe("shown on the link's preview; leave it out and a caption is written"),
    }),
    output: LinkShape,
    ai: {
        tier: "free",
        only: true,
        summary: `Make one share link for these posts and return it: a gallery link (share.capybaraharmony.com/g/<id>, 2 to ${SHARE_SET_MAX} files) or, for a single file, that file's share page.\nA gallery post brings all its public files. Only public files can be shared: a private post throws and is named. Give Harmony the url, never a media URL.`,
        params: ["ids"],
        options: true,
    },
    handler: async (ctx, input) => {
        if (!ctx.shareBaseUrl) throw shareOff();
        const found = await linkFiles(ctx, input.ids);
        if (found.unknown.length > 0) throw new OpError(404, "error.share.not_found", `no post or file with id ${found.unknown.join(", ")}`);
        if (found.notPublic.length > 0) {
            throw new OpError(409, "error.share.not_public", `not public, so they cannot be shared: ${found.notPublic.join(", ")}. Ask Harmony to make them public first`);
        }
        if (found.files.length > SHARE_SET_MAX) {
            throw new OpError(400, "error.share.bad_request", `that is ${found.files.length} files and a link holds at most ${SHARE_SET_MAX}: make several links`);
        }
        return ok(await makeLink(ctx, found.files, input.title));
    },
});

async function linkPreview(ctx: OpContext, id: string) {
    const row = await ctx.db
        .prepare("SELECT title, items FROM share_sets WHERE id = ?1 AND revoked_at IS NULL")
        .bind(id)
        .first<{ title: string | null; items: string }>();
    if (!row) throw new OpError(404, "error.share.not_found", `no live gallery link ${id}`);
    let files = 0;
    try {
        files = (JSON.parse(row.items) as unknown[]).length;
    } catch {
        /* a bad row counts no files */
    }
    const inCollections = await ctx.db
        .prepare("SELECT COUNT(*) AS n FROM share_collection_items WHERE set_id = ?1")
        .bind(id)
        .first<{ n: number }>();
    return { title: row.title, files, collections: inCollections?.n ?? 0 };
}

export const linksRevokeOp = defineOp({
    name: "links.revoke",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ link: LinkId.describe("the link's id or its share URL") }),
    output: z.object({ revoked: z.string() }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Revoke a gallery link: its URL stops working for everyone, at once.",
        params: ["link"],
        preview: async (ctx, input) => {
            const p = await linkPreview(ctx, input.link);
            const url = `${withSlash(ctx.shareBaseUrl ?? "")}g/${input.link}`;
            return {
                summary: `revoke ${p.title ? `"${p.title}"` : "this link"}`,
                effect: { link: url, files: p.files, collections: p.collections },
            };
        },
    },
    handler: async (ctx, input) => {
        const d = shareSetDeps(ctx);
        if (!d) throw shareOff();
        unwrap(await revokeShareSet(d, input.link), { "error.share.not_found": `no gallery link ${input.link}` });
        return ok({ revoked: input.link });
    },
});

export const collectionsCreateOp = defineOp({
    name: "collections.create",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ name: z.string().trim().min(1).max(60), links: LinkIds.optional().describe("gallery link ids or URLs to put in it") }),
    output: CollectionShape,
    ai: { tier: "free", only: true, summary: "Make a collection (a folder of gallery links), optionally with links in it.", params: ["name"], options: true },
    handler: async (ctx, input) => {
        const d = collectionDeps(ctx);
        if (!d) throw shareOff();
        const r = await createCollection(d, bodyRequest("POST", { name: input.name, set_ids: input.links ?? [] }), ctx.keyId!);
        return ok(collectionOut(unwrap<{ collection: any }>(r, COLLECTION_MESSAGES).collection), 201);
    },
});

export const collectionsAddOp = defineOp({
    name: "collections.add",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        collection: Ref.describe("its id or name; a new name makes the collection"),
        links: LinkIds.describe("gallery link ids or URLs"),
    }),
    output: z.intersection(CollectionShape, z.object({ created: z.boolean() })),
    ai: {
        tier: "free",
        only: true,
        summary: "Put gallery links in a collection, found by id or name. It is made when no collection has that name.",
        params: ["collection", "links"],
    },
    handler: async (ctx, input) => {
        const d = collectionDeps(ctx);
        if (!d) throw shareOff();
        const c = await findCollection(ctx.db, input.collection);
        if (!c) {
            const r = await createCollection(d, bodyRequest("POST", { name: input.collection, set_ids: input.links }), ctx.keyId!);
            return ok({ ...collectionOut(unwrap<{ collection: any }>(r, COLLECTION_MESSAGES).collection), created: true });
        }
        const r = await updateCollection(d, bodyRequest("PATCH", { add: input.links }), c.id);
        return ok({ ...collectionOut(unwrap<{ collection: any }>(r, COLLECTION_MESSAGES).collection), created: false });
    },
});

export const collectionsUpdateOp = defineOp({
    name: "collections.update",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        collection: Ref.describe("its id or name"),
        name: z.string().trim().min(1).max(60).optional().describe("a new name"),
        add: LinkIds.optional(),
        remove: LinkIds.optional().describe("taken out of the collection; the links stay live"),
    }),
    output: CollectionShape,
    ai: { tier: "free", only: true, summary: "Rename a collection, or add and take out links.", params: ["collection"], options: true },
    handler: async (ctx, input) => {
        const d = collectionDeps(ctx);
        if (!d) throw shareOff();
        const c = await needCollection(ctx, input.collection);
        const body = { ...(input.name ? { name: input.name } : {}), add: input.add ?? [], remove: input.remove ?? [] };
        if (!input.name && body.add.length === 0 && body.remove.length === 0) throw new OpError(400, "error.collection.bad_request", "give a name, add or remove");
        return ok(collectionOut(unwrap<{ collection: any }>(await updateCollection(d, bodyRequest("PATCH", body), c.id), COLLECTION_MESSAGES).collection));
    },
});

async function collectionPreview(ctx: OpContext, ref: string) {
    const c = await needCollection(ctx, ref);
    const n = await ctx.db
        .prepare(
            "SELECT COUNT(*) AS n FROM share_collection_items i JOIN share_sets s ON s.id = i.set_id WHERE i.collection_id = ?1 AND s.revoked_at IS NULL",
        )
        .bind(c.id)
        .first<{ n: number }>();
    return { ...c, links: n?.n ?? 0 };
}

export const collectionsRerollOp = defineOp({
    name: "collections.reroll",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ collection: Ref.describe("its id or name") }),
    output: z.intersection(CollectionShape, z.object({ replaced: z.record(z.string(), z.string()).describe("old link id -> new link id") })),
    ai: {
        tier: "ask",
        only: true,
        summary: "Give every link in a collection a new URL (fresh previews and captions). Every old URL stops working.",
        params: ["collection"],
        preview: async (ctx, input) => {
            const c = await collectionPreview(ctx, input.collection);
            return { summary: `reroll ${c.links} ${c.links === 1 ? "link" : "links"} in "${c.name}"`, effect: { collection: c.name, links: c.links, old_links_stop_working: true } };
        },
    },
    handler: async (ctx, input) => {
        const d = collectionDeps(ctx);
        if (!d) throw shareOff();
        const c = await needCollection(ctx, input.collection);
        const body = unwrap<{ collection: any; replaced: Record<string, string> }>(await rerollCollection(d, c.id, ctx.keyId!), COLLECTION_MESSAGES);
        return ok({ ...collectionOut(body.collection), replaced: body.replaced });
    },
});

export const collectionsDeleteOp = defineOp({
    name: "collections.delete",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ collection: Ref.describe("its id or name") }),
    output: z.object({ deleted: z.string() }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Delete a collection. Its links stay live; it also leaves every set.",
        params: ["collection"],
        preview: async (ctx, input) => {
            const c = await collectionPreview(ctx, input.collection);
            return { summary: `delete the collection "${c.name}"`, effect: { collection: c.name, links: c.links, links_stay_live: true } };
        },
    },
    handler: async (ctx, input) => {
        const d = collectionDeps(ctx);
        if (!d) throw shareOff();
        const c = await needCollection(ctx, input.collection);
        unwrap(await deleteCollection(d, c.id), COLLECTION_MESSAGES);
        return ok({ deleted: c.id });
    },
});

// collections as ids: each one an id or a name
async function collectionIdsOf(ctx: OpContext, refs: string[]): Promise<string[]> {
    const out: string[] = [];
    for (const r of refs) out.push((await needCollection(ctx, r)).id);
    return [...new Set(out)];
}
const CollectionRefs = OneOrMany(Ref);

export const setsListOp = defineOp({
    name: "sets.list",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({}),
    output: z.array(SetShape),
    ai: { tier: "free", only: true, summary: "The sets: named groups of collections, newest changed first." },
    handler: async (ctx) => {
        const d = groupDeps(ctx);
        if (!d) throw shareOff();
        return ok(unwrap<{ groups: any[] }>(await listGroups(d)).groups.map(setOut));
    },
});

export const setsCreateOp = defineOp({
    name: "sets.create",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ name: z.string().trim().min(1).max(60), collections: CollectionRefs.optional().describe("collection ids or names") }),
    output: SetShape,
    ai: { tier: "free", only: true, summary: "Make a set (a named group of collections), optionally with collections in it.", params: ["name"], options: true },
    handler: async (ctx, input) => {
        const d = groupDeps(ctx);
        if (!d) throw shareOff();
        const ids = await collectionIdsOf(ctx, input.collections ?? []);
        return ok(setOut(unwrap<{ group: any }>(await createGroup(d, bodyRequest("POST", { name: input.name, collection_ids: ids }), ctx.keyId!), GROUP_MESSAGES).group), 201);
    },
});

export const setsAddOp = defineOp({
    name: "sets.add",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ set: Ref.describe("its id or name; a new name makes the set"), collections: CollectionRefs.describe("collection ids or names") }),
    output: z.intersection(SetShape, z.object({ created: z.boolean() })),
    ai: {
        tier: "free",
        only: true,
        summary: "Put collections in a set, found by id or name. It is made when no set has that name.",
        params: ["set", "collections"],
    },
    handler: async (ctx, input) => {
        const d = groupDeps(ctx);
        if (!d) throw shareOff();
        const ids = await collectionIdsOf(ctx, input.collections);
        const g = await findGroup(ctx.db, input.set);
        if (!g) {
            const r = await createGroup(d, bodyRequest("POST", { name: input.set, collection_ids: ids }), ctx.keyId!);
            return ok({ ...setOut(unwrap<{ group: any }>(r, GROUP_MESSAGES).group), created: true });
        }
        const r = await updateGroup(d, bodyRequest("PATCH", { add: ids }), g.id);
        return ok({ ...setOut(unwrap<{ group: any }>(r, GROUP_MESSAGES).group), created: false });
    },
});

export const setsUpdateOp = defineOp({
    name: "sets.update",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        set: Ref.describe("its id or name"),
        name: z.string().trim().min(1).max(60).optional().describe("a new name"),
        add: CollectionRefs.optional(),
        remove: CollectionRefs.optional().describe("taken out of the set; the collections stay"),
    }),
    output: SetShape,
    ai: { tier: "free", only: true, summary: "Rename a set, or add and take out collections.", params: ["set"], options: true },
    handler: async (ctx, input) => {
        const d = groupDeps(ctx);
        if (!d) throw shareOff();
        const g = await needGroup(ctx, input.set);
        const body = {
            ...(input.name ? { name: input.name } : {}),
            add: await collectionIdsOf(ctx, input.add ?? []),
            remove: await collectionIdsOf(ctx, input.remove ?? []),
        };
        if (!input.name && body.add.length === 0 && body.remove.length === 0) throw new OpError(400, "error.group.bad_request", "give a name, add or remove");
        return ok(setOut(unwrap<{ group: any }>(await updateGroup(d, bodyRequest("PATCH", body), g.id), GROUP_MESSAGES).group));
    },
});

export const setsDeleteOp = defineOp({
    name: "sets.delete",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ set: Ref.describe("its id or name") }),
    output: z.object({ deleted: z.string() }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Delete a set. Its collections and links stay.",
        params: ["set"],
        preview: async (ctx, input) => {
            const g = await needGroup(ctx, input.set);
            const n = await ctx.db.prepare("SELECT COUNT(*) AS n FROM collection_group_items WHERE group_id = ?1").bind(g.id).first<{ n: number }>();
            return { summary: `delete the set "${g.name}"`, effect: { set: g.name, collections: n?.n ?? 0, collections_stay: true } };
        },
    },
    handler: async (ctx, input) => {
        const d = groupDeps(ctx);
        if (!d) throw shareOff();
        const g = await needGroup(ctx, input.set);
        unwrap(await deleteGroup(d, g.id), GROUP_MESSAGES);
        return ok({ deleted: g.id });
    },
});

export const SHARE_OPS = [
    ...ROUTE_OPS,
    linksCreateOp,
    linksRevokeOp,
    collectionsCreateOp,
    collectionsAddOp,
    collectionsUpdateOp,
    collectionsRerollOp,
    collectionsDeleteOp,
    setsListOp,
    setsCreateOp,
    setsAddOp,
    setsUpdateOp,
    setsDeleteOp,
];
