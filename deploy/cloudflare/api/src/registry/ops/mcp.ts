// The MCP server's routes and its one MCP-only call (APP-API-CONTRACT.md section 35). The protocol and the tool mapping
// live in src/mcp.ts; the tools themselves are the chat's ops.
//  - POST /mcp: JSON-RPC over Streamable HTTP (stateless, JSON answers). The client key comes as `Api-Key <uuid>` or
//    `Bearer <uuid>`; a browser origin other than the web app's is refused.
//  - GET and DELETE /mcp: 405 (no SSE stream, no sessions to end).
//  - PUT /mcp/upload/<token>: the bytes of an upload_begin link, the same upload code as PUT /studio/upload.
//  - upload.begin (MCP only): mints that link.
import * as z from "zod";
import { MAX_UPLOAD_BYTES, studioUpload, UPLOAD_TYPES, uploadLogInfo } from "../../app-routes";
import { lookupKey } from "../../keys";
import { mcpAuthorization, mcpMessage, signUploadToken, UPLOAD_TOKEN_REGEX, UPLOAD_TOKEN_TTL_MS, verifyUploadToken } from "../../mcp";
import { logRequest } from "../../request-log";
import { chatKeyId } from "../ai";
import { defineOp, OpError } from "../op";

const NoInput = z.object({});
const none = () => ({});
const json = (status: number, body: unknown, headers: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...headers } });
const errBody = (code: string) => ({ status: "error", error: { code } });

// Bodies above this are refused before they are parsed (a tools/call is small; files go through upload links).
export const MCP_BODY_MAX = 1_000_000;

export const mcpOp = defineOp({
    name: "mcp",
    route: { method: "POST", path: "/mcp" },
    auth: "open",
    runs: "worker",
    cors: false,
    noStore: true,
    raw: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "The MCP server (POST /mcp, section 35)." },
    handler: async (ctx) => {
        const request = ctx.request!;
        // DNS rebinding: a browser page may only call it from the web app's origin
        const origin = request.headers.get("Origin");
        if (origin !== null && origin !== ctx.env.CORS_URL) return json(403, errBody("error.mcp.origin"));
        const auth = mcpAuthorization(request.headers.get("Authorization"));
        if (!("key" in auth)) return json(401, errBody(auth.errorCode));
        let clientKeyId: string | null;
        try {
            clientKeyId = await lookupKey(ctx.db, auth.key, Date.now());
        } catch {
            return json(503, errBody("error.api.generic"));
        }
        if (clientKeyId === null) return json(401, errBody("error.api.auth.key.invalid"));

        const declared = Number(request.headers.get("content-length") ?? "0");
        if (declared > MCP_BODY_MAX) return json(413, { jsonrpc: "2.0", id: null, error: { code: -32600, message: "request too large" } });
        const text = await request.text();
        if (text.length > MCP_BODY_MAX) return json(413, { jsonrpc: "2.0", id: null, error: { code: -32600, message: "request too large" } });
        let body: unknown;
        try {
            body = JSON.parse(text);
        } catch {
            return json(400, { jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
        }
        const caller = { ctx, clientKeyId, origin: ctx.url!.origin };
        if (Array.isArray(body)) {
            if (body.length === 0) return json(400, { jsonrpc: "2.0", id: null, error: { code: -32600, message: "empty batch" } });
            const replies = [];
            for (const m of body.slice(0, 20)) {
                const r = await mcpMessage(ctx.registry, caller, m);
                if (r) replies.push(r);
            }
            return replies.length ? json(200, replies) : new Response(null, { status: 202 });
        }
        const reply = await mcpMessage(ctx.registry, caller, body as object);
        return reply ? json(200, reply) : new Response(null, { status: 202 });
    },
});

// GET (the optional SSE stream) and DELETE (ending a session): this server has neither, so 405 as the spec asks.
const mcpNotHere = (name: string, method: "GET" | "DELETE", what: string) =>
    defineOp({
        name,
        route: { method, path: "/mcp" },
        auth: "open",
        runs: "worker",
        cors: false,
        raw: true,
        input: NoInput,
        http: none,
        ai: { tier: "hidden", summary: `${method} /mcp: 405 (${what}).` },
        handler: async () => new Response(null, { status: 405, headers: { allow: "POST" } }),
    });
export const mcpStreamOp = mcpNotHere("mcp.stream", "GET", "no server-sent event stream");
export const mcpEndOp = mcpNotHere("mcp.end", "DELETE", "no sessions to end");

// PUT /mcp/upload/<token>: the token is the credential (its client key must still be live). Uploaded as the MCP
// thread's chat key, like the chat's box.save, through PUT /studio/upload's own code (types, sniffing, 100 MB cap,
// ?name ?title ?public ?queue).
export const mcpUploadOp = defineOp({
    name: "mcp.upload",
    route: { method: "PUT", path: "/mcp/upload/:token", params: { token: UPLOAD_TOKEN_REGEX } },
    auth: "capability",
    runs: "worker",
    cors: false,
    noStore: true,
    raw: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "The bytes of an MCP upload link (PUT /mcp/upload/<token>)." },
    handler: async (ctx) => {
        const request = ctx.request!;
        const refuse = (status: number, code: string) => {
            void request.body?.cancel().catch(() => {});
            return json(status, errBody(code));
        };
        const claims = await verifyUploadToken(ctx.env.COBALT_API_KEY, ctx.params.token!, ctx.now());
        if (!claims) return refuse(401, "error.mcp.upload_link");
        let live: { id: string } | null;
        try {
            live = await ctx.db.prepare("SELECT id FROM api_keys WHERE id = ?1 AND revoked_at IS NULL").bind(claims.k).first<{ id: string }>();
        } catch {
            return refuse(503, "error.api.generic");
        }
        if (!live) return refuse(401, "error.api.auth.key.invalid");
        const keyId = chatKeyId(claims.t);
        const r = await studioUpload(ctx.app(), request, keyId, ctx.query);
        const res = json(r.status, r.body);
        await logRequest(ctx.db, "PUT /mcp/upload", keyId, request, uploadLogInfo(request), res);
        return res;
    },
});

const UploadLinkSchema = z.object({
    upload_url: z.string().describe("PUT the file's bytes here (any HTTP client; no other header is needed)"),
    method: z.literal("PUT"),
    expires_at: z.string().describe("ISO date; the link works until then, once per file"),
    max_bytes: z.number(),
    types: z.array(z.string()),
    curl: z.string().describe("a ready command: replace FILE with the file's path"),
});

export const uploadBeginOp = defineOp({
    name: "upload.begin",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        name: z.string().min(1).max(200).optional().describe("the file name the library shows, e.g. clip.mp4"),
        title: z.string().min(1).max(200).optional().describe("the post's title"),
        public: z.boolean().optional().describe("host it publicly (a share link) once it is ready"),
        queue: z.boolean().optional().describe("wait in the server's line when it is busy instead of failing"),
    }),
    output: UploadLinkSchema,
    ai: {
        tier: "free",
        only: true,
        summary:
            `Upload a local video or image into the library: returns a link (15 min) to PUT the file's bytes to, e.g. with curl -T. ` +
            `mp4 mov gif jpg png webp heic, max ${MAX_UPLOAD_BYTES / 1_000_000} MB, typed by its bytes. The PUT answers the new item ` +
            "(a video also opens a studio session, `sid`). For a link on the web use library_save instead.",
        options: true,
        when: (f) => f.mcp === true,
    },
    handler: async (ctx, input) => {
        const mcp = ctx.chat?.mcp;
        if (!ctx.chat || !mcp) throw new OpError(404, "error.mcp.only", "upload.begin: only the MCP server can call this");
        const expires = ctx.now() + UPLOAD_TOKEN_TTL_MS;
        const token = await signUploadToken(ctx.env.COBALT_API_KEY, { k: mcp.clientKeyId, t: ctx.chat.threadId, e: expires });
        const q = new URLSearchParams();
        if (input.name) q.set("name", input.name);
        if (input.title) q.set("title", input.title);
        if (input.public) q.set("public", "1");
        if (input.queue) q.set("queue", "1");
        const qs = q.toString();
        const url = `${mcp.origin}/mcp/upload/${token}${qs ? `?${qs}` : ""}`;
        return {
            status: 200,
            body: {
                upload_url: url,
                method: "PUT",
                expires_at: new Date(expires).toISOString(),
                max_bytes: MAX_UPLOAD_BYTES,
                types: Object.keys(UPLOAD_TYPES),
                curl: `curl -sS -T FILE '${url}'`,
            },
        };
    },
});

export const MCP_OPS = [mcpOp, mcpStreamOp, mcpEndOp, mcpUploadOp, uploadBeginOp];
