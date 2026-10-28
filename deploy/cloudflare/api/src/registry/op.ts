// The op registry (APP-API-CONTRACT.md section 33): every backend feature defined once with `defineOp`. One definition
// gives the HTTP route (method, path, auth, CORS), the input check (zod), and the chat AI's tool (its tier, its call
// name and its line in the model's TypeScript cheat sheet). Free of Cloudflare imports: the tests run it under node.
//
// Routes the registry does not know fall through to the old chain (gate.ts + worker.ts), so ops move over one at a time.
import type { z } from "zod";
import type { AppDeps } from "../app-routes";
import type { ChatCollect, ChatTools } from "../chat-tools";
import type { ContainerStub, StageEdge } from "../deps";
import type { EmbedClient } from "../embed";
import type { EdgeDeps } from "../studio-edge";
import type { WorkerEnv } from "../worker";
import type { Registry } from "./registry";

export type HttpMethod = "GET" | "HEAD" | "POST" | "PUT" | "PATCH" | "DELETE";

// Who may call a route:
//  - "key":            an `Api-Key` client key (D1 lookup). The library service credential gets 404, like the gate.
//  - "key_or_service": a client key or the web Worker's library service credential (key id "service:library").
//  - "service":        the library service credential only (key id "service:library"); anyone else gets 401
//                      error.api.auth.key.invalid.
//  - "open":           anyone; the handler sees `ctx.keyId === null` (and `ctx.caller === "service"` for the service).
//  - "capability":     the path itself is the credential (a studio session id); no key is read.
export type OpAuth = "key" | "key_or_service" | "service" | "open" | "capability";

// How the chat AI may use an op:
//  - "free":   it runs when the model's code calls it.
//  - "ask":    it does not run: the call returns `{ pending_confirm }`, the code run stops, and Harmony gets a confirm
//              card (POST /chat/threads/<id>/confirm/<cid> runs or drops it).
//  - "hidden": the model never sees it (owner and system plumbing).
export type AiTier = "free" | "ask" | "hidden";

// The reply a handler gives: the HTTP status and JSON body (the AI gets `body` on a 2xx), or a whole Response for a
// `raw` op (streams, uploads).
export type OpReply = { status: number; body: unknown; headers?: Record<string, string> };

// A handler's refusal: an HTTP error reply, and the message the model reads when the AI called it.
export class OpError extends Error {
    constructor(
        readonly status: number,
        readonly code: string,
        message?: string,
    ) {
        super(message ?? code);
    }
}

export const ok = (body: unknown, status = 200): OpReply => ({ status, body });

// The per-call context. One shape for HTTP and chat calls, built by the registry (http.ts) or the chat toolbox (ai.ts).
export type OpContext = {
    env: WorkerEnv;
    db: D1Database;
    now: () => number;
    mediaBaseUrl: string;
    // the share host's base URL while it is on
    shareBaseUrl?: string;
    edge: EdgeDeps;
    container: ContainerStub;
    // the registry this call came through (ops may call each other through it)
    registry: Registry;
    // what the stage needs beyond the env (the StageRoom Durable Object; tests pass fakes)
    stageEdge: StageEdge;
    // lazily built, once per call
    app(): AppDeps;
    embed(): EmbedClient | null;
    // the verified key id ("service:library" for the service, "chat:<thread id>" for the chat AI); null on open routes
    keyId: string | null;
    caller: "key" | "service" | "chat" | "open";
    // HTTP calls only: the request (headers already stripped), its URL, query and path params
    request?: Request;
    url?: URL;
    query: URLSearchParams;
    params: Record<string, string>;
    // The main Durable Object, with this call's key id set (the client's Authorization never travels).
    durableObject(path: string, init?: RequestInit): Promise<Response>;
    // chat calls only
    chat?: ChatCallContext;
};

export type ChatCallContext = {
    threadId: string;
    collect: ChatCollect;
    // the read tools of chat-tools.ts, one instance per code run (it caches the library for the run)
    tools: ChatTools;
    // cobalt.jobs.onDone (section 33.14): hand a job to the server, which continues the chat when it ends. Absent: the
    // hook is off (no CHAT_JOBS binding, or a confirmed card's run).
    watchJob?: (job: string, note: string | null) => Promise<void>;
};

export type AiSpec<I> = {
    tier: AiTier;
    // one or two lines for the model's cheat sheet (and the confirm card's default summary)
    summary: string;
    // the call's name under `cobalt.` (default: the op name), e.g. "library.search" -> cobalt.library.search(...)
    call?: string;
    // older names that still work, so saved threads replay (e.g. "search" for cobalt.search)
    aliases?: string[];
    // only for the chat AI: never a route
    only?: boolean;
    // positional argument names, in order; a trailing plain object fills the remaining fields (the options)
    params?: string[];
    // the remaining fields come as one trailing options object (printed as `opts?: {...}`)
    options?: boolean;
    // a custom mapping from the call's arguments to the input (overrides params/options for parsing only)
    args?: (args: unknown[]) => unknown;
    // only offered while this holds (e.g. search while the Space is configured)
    when?: (flags: AiFlags) => boolean;
    // an ask op that only asks for some inputs (e.g. making something private, not public): false runs it at once
    asks?: (input: I) => boolean;
    // an ask op's card: the one-line summary and the effect (counts, sizes, links affected)
    preview?: (ctx: OpContext, input: I) => Promise<{ summary: string; effect: Record<string, unknown> }>;
    // what the model gets from a 2xx reply body (default: the body)
    result?: (body: unknown) => unknown;
};

// search: meaning search is configured; box: the workbench is on (section 33.11)
export type AiFlags = { search: boolean; box?: boolean };

// The hosts the Worker answers: the API (the default), the share host's link pages (section 22), the stage host
// (section 30.4), and any other studio.* host (a 404 page while the stage is off or elsewhere).
export type RouteHost = "api" | "share" | "stage" | "studio";

export type RouteSpec = {
    // "ANY": every method (a host's own page router, which answers methods itself)
    method: HttpMethod | "ANY";
    // "/library/items/:id/post": each `:name` segment must match `params[name]` (default: any non-empty segment).
    // A trailing "/*" matches the rest of the path, whatever it is (a host's catch-all).
    path: string;
    params?: Record<string, RegExp>;
    host?: RouteHost;
};

export type OpDef<I = any, O = any> = {
    name: string;
    route?: RouteSpec;
    auth: OpAuth;
    runs: "worker" | "durable_object";
    // the web app's origin gets `access-control-allow-origin` on the reply (auth errors always carry it, like the gate)
    cors: boolean;
    // `cache-control: no-store` on the reply
    noStore?: boolean;
    input: z.ZodType<I>;
    output?: z.ZodType<O>;
    // the error code a failed input check answers over HTTP (400)
    badRequest?: string;
    // How an HTTP request becomes the input. Default: path params, query and JSON body (POST/PUT/PATCH), merged.
    // Routes that wrap an older handler keep that handler's own parsing (it reads `ctx.query`) and accept any query here.
    http?: (ctx: OpContext) => Promise<unknown> | unknown;
    ai: AiSpec<I>;
    // the handler returns a Response itself (SSE, uploads, file bytes)
    raw?: boolean;
    handler?: (ctx: OpContext, input: I) => Promise<OpReply | Response>;
};

export type Op<I = any, O = any> = OpDef<I, O> & { callName: string };

export function defineOp<I, O = unknown>(def: OpDef<I, O>): Op<I, O> {
    if (!def.route && !def.ai.only) throw new Error(`op ${def.name}: a route or ai.only`);
    if (def.ai.only && def.route) throw new Error(`op ${def.name}: ai.only ops have no route`);
    if (def.ai.only && def.ai.tier === "hidden") throw new Error(`op ${def.name}: an ai.only op cannot be hidden`);
    if (def.runs === "worker" && !def.handler) throw new Error(`op ${def.name}: a worker op needs a handler`);
    if (def.ai.tier !== "hidden" && def.runs === "durable_object" && !def.route) throw new Error(`op ${def.name}: a DO op needs a route`);
    // a pattern imported through an import cycle is undefined when the op is defined, and would match any segment
    for (const [k, re] of Object.entries(def.route?.params ?? {})) {
        if (!(re instanceof RegExp)) throw new Error(`op ${def.name}: param ${k} has no pattern`);
    }
    return { ...def, callName: def.ai.call ?? def.name };
}
