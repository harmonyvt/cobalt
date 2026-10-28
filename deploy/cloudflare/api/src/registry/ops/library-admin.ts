// The remaining library and studio routes as ops (APP-API-CONTRACT.md 33.12, plan thread T7): a session's status and
// source (the session id is the credential), a private file's bytes, the web Worker's adopt, and the owner's
// maintenance routes (search index, posters backfill, the visibility data step). All tier hidden. Each wraps the code
// worker.ts ran for it, unchanged.
import * as z from "zod";
import { libraryFile, libraryPostersBackfill, libraryVisibilityMigrate } from "../../app-routes";
import { librarySearchIndex, librarySearchPost } from "../../embed";
import { ITEM_ID_REGEX, STUDIO_SID_REGEX } from "../../gate";
import { logRequest } from "../../request-log";
import { parseSourceWait, parseStudioWait } from "../../studio";
import { studioSource, studioStatus } from "../../studio-edge";
import { defineOp, type HttpMethod, type OpReply } from "../op";
import { loggedPost, toDurableObject } from "./system";

const NoInput = z.object({});
const none = () => ({});
const reply = (r: { status: number; body: unknown }): OpReply => ({ status: r.status, body: r.body });

// GET /studio/<sid> (section 2): a save's progress, long-polled with ?wait. Every /studio* answer carries the studio
// page's CORS (worker.ts adds it).
export const studioStatusOp = defineOp({
    name: "studio.status",
    route: { method: "GET", path: "/studio/:sid", params: { sid: STUDIO_SID_REGEX } },
    auth: "capability",
    runs: "worker",
    cors: false,
    input: NoInput,
    http: none,
    raw: true,
    ai: { tier: "hidden", summary: "A save's progress (GET /studio/<sid>)." },
    handler: async (ctx) =>
        studioStatus(ctx.db, ctx.container, ctx.params.sid!, parseStudioWait(ctx.query.get("wait")), ctx.edge),
});

// GET|HEAD /studio/<sid>/source (sections 7, 11): the stored original's bytes, Range aware; GET may hold with ?wait.
const sourceOp = (method: HttpMethod) =>
    defineOp({
        name: method === "GET" ? "studio.source" : "studio.source.head",
        route: { method, path: "/studio/:sid/source", params: { sid: STUDIO_SID_REGEX } },
        auth: "capability",
        runs: "worker",
        cors: false,
        input: NoInput,
        http: none,
        raw: true,
        ai: { tier: "hidden", summary: "A save's original file (GET /studio/<sid>/source)." },
        handler: async (ctx) =>
            studioSource(ctx.db, ctx.env.ORIGINALS, ctx.params.sid!, ctx.request!, ctx.edge, {
                container: ctx.container,
                seconds: parseSourceWait(ctx.query.get("wait")),
            }),
    });

// GET|HEAD /library/items/<id>/file (section 5): a private file's bytes, Range aware. No CORS.
const fileOp = (method: HttpMethod) =>
    defineOp({
        name: method === "GET" ? "library.file" : "library.file.head",
        route: { method, path: "/library/items/:id/file", params: { id: ITEM_ID_REGEX } },
        auth: "key_or_service",
        runs: "worker",
        cors: false,
        input: NoInput,
        http: none,
        raw: true,
        ai: { tier: "hidden", summary: "A private file's bytes (GET /library/items/<id>/file)." },
        handler: async (ctx) => libraryFile(ctx.app(), ctx.params.id!, ctx.request!),
    });

// POST /library/adopt: the web Worker's library service only (a client key is told it is invalid). The Durable Object
// adopts a web save; logged like the other keyed POSTs.
export const libraryAdoptOp = defineOp({
    name: "library.adopt",
    route: { method: "POST", path: "/library/adopt" },
    auth: "service",
    runs: "worker",
    cors: true,
    input: NoInput,
    http: none,
    raw: true,
    ai: { tier: "hidden", summary: "The web library's adopt (service only)." },
    handler: async (ctx) => {
        const { request, log } = await loggedPost(ctx.request!);
        const res = await ctx.container.fetch(toDurableObject(request, ctx.keyId!));
        await logRequest(ctx.db, "POST /library/adopt", ctx.keyId!, request, log, res);
        return res;
    },
});

// The owner's maintenance routes: keyed or the service, no CORS, no-store.
const maintenance = (name: string, method: HttpMethod, path: string, summary: string, run: Parameters<typeof defineOp>[0]["handler"]) =>
    defineOp({
        name,
        route: { method, path },
        auth: "key_or_service",
        runs: "worker",
        cors: false,
        noStore: true,
        input: NoInput,
        http: none,
        ai: { tier: "hidden", summary },
        handler: run,
    });

export const LIBRARY_ADMIN_OPS = [
    studioStatusOp,
    sourceOp("GET"),
    sourceOp("HEAD"),
    fileOp("GET"),
    fileOp("HEAD"),
    libraryAdoptOp,
    // section 21: one post's index status, and an index pass
    maintenance("library.search.post", "GET", "/library/search/post", "One post's search index status.", async (ctx) =>
        reply(await librarySearchPost({ db: ctx.db, mediaBaseUrl: ctx.mediaBaseUrl, searchEnabled: ctx.embed() !== null }, ctx.query)),
    ),
    maintenance("library.search.index", "POST", "/library/search/index", "Index the posts not yet indexed.", async (ctx) =>
        reply(await librarySearchIndex({ ...ctx.app(), embed: ctx.embed() }, ctx.query)),
    ),
    // section 13: queue the server-made posters still missing
    maintenance("library.posters.backfill", "POST", "/library/posters/backfill", "Queue the missing posters.", async (ctx) => {
        const raw = ctx.query.get("limit");
        const limit = raw !== null && /^\d{1,4}$/.test(raw) ? Number(raw) : undefined;
        return reply(await libraryPostersBackfill(ctx.app(), limit));
    }),
    // section 16.4: the one-row-per-file data step
    maintenance("library.visibility.migrate", "POST", "/library/visibility/migrate", "The one-row-per-file data step.", async (ctx) =>
        reply(await libraryVisibilityMigrate(ctx.app(), ctx.query)),
    ),
];
