// The capystore MCP server (APP-API-CONTRACT.md section 35): the chat AI's tools, served to any MCP client (Claude Code,
// Claude Desktop, other agents) over Streamable HTTP at POST /mcp on the API host. The tools ARE the op registry's chat
// calls (src/registry/): same ops, same zod checks, same handlers, same daily caps, so the MCP and the chat never drift.
//
// Stateless: every POST is one JSON-RPC message (or a batch) answered with JSON; no session id, no SSE stream.
// Each client key gets its own stable "thread" (mcpThreadId): its calls run as that thread's chat key, so the per-thread
// caps (saves, renders) and the workbench box behave as they do for one chat thread.
// Free of Cloudflare imports: the tests run it under node.
import * as z from "zod";
import { chatTools, type ChatCollect } from "./chat-tools";
import { lookImages, type LookOpts } from "./look-pictures";
import { chatKeyId, runOp } from "./registry/ai";
import { forCall } from "./registry/context";
import { OpError, type AiFlags, type Op, type OpContext } from "./registry/op";
import type { Registry } from "./registry/registry";
import { argsToInput } from "./registry/typescript";
import { workbenchOn } from "./workbench-rules";

export const MCP_PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"] as const;
export const MCP_SERVER_NAME = "capystore";
export const MCP_SERVER_VERSION = "1.0.0";

// Chat calls that only mean something inside the chat app's own reply (thumbnails, the collage, continuing a chat).
export const MCP_SKIPPED_CALLS = new Set(["show", "collage", "jobs.onDone"]);

// A tool's text result is cut here (the chat cuts its own results too).
export const MCP_RESULT_MAX = 200_000;
// look: at most this many pictures per call, each at most this big
export const MCP_LOOK_MAX = 4;
export const MCP_PICTURE_MAX_BYTES = 4_000_000;

const BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

// The MCP "thread" of a client key: 16 base62 characters from SHA-256("mcp:" + key id). Stable, so the daily caps hold
// across connections; a key never shares one with another key or a chat thread (whose ids are random).
export async function mcpThreadId(clientKeyId: string): Promise<string> {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`mcp:${clientKeyId}`)));
    let out = "";
    for (let i = 0; i < 16; i++) out += BASE62[digest[i]! % 62];
    return out;
}

export const mcpToolName = (callName: string) => callName.replace(/\./g, "_");

// What the MCP offers: the chat's tools (free and ask, with the same feature switches), minus the chat-only ones, plus the
// MCP-only ops (`when: f => f.mcp`).
export function mcpFlags(ctx: Pick<OpContext, "env" | "embed">): AiFlags {
    return { search: ctx.embed() !== null, box: workbenchOn(ctx.env), mcp: true };
}

export function mcpOps(registry: Registry, flags: AiFlags): Op[] {
    return registry.toolsFor("chat", flags).filter((op) => !MCP_SKIPPED_CALLS.has(op.callName));
}

const ASK_NOTE =
    "Changes or removes things for good (in the capystore chat this asks Harmony first): check with the user before calling it.";

// The MCP description of a call: its cheat-sheet summary, with the chat's wording made general.
function describeOp(op: Op): string {
    let text = op.ai.summary.replace(/\n/g, " ");
    if (op.callName === "look")
        text = `See these posts' pictures (poster or image, private ones too), returned as images. grid: lines every 0.1 to read off a crop box for make_cropImage; frames: up to 3 frames across a video. Max ${MCP_LOOK_MAX} per call.`;
    if (op.ai.tier === "ask") text += ` ${ASK_NOTE}`;
    return text;
}

type Json = Record<string, unknown>;

// The JSON Schema of an op's input, as the client sends it (`io: "input"`), always an object.
export function inputSchemaOf(op: Op): Json {
    let schema: Json;
    try {
        schema = z.toJSONSchema(op.input, { target: "draft-2020-12", unrepresentable: "any", io: "input" }) as Json;
    } catch {
        schema = { type: "object" };
    }
    delete schema.$schema;
    if (schema.type !== "object") return { type: "object", additionalProperties: true };
    return schema;
}

export type McpTool = { name: string; description: string; inputSchema: Json; annotations?: Json };

export function mcpToolList(registry: Registry, flags: AiFlags): McpTool[] {
    return mcpOps(registry, flags).map((op) => ({
        name: mcpToolName(op.callName),
        description: describeOp(op),
        inputSchema: inputSchemaOf(op),
        ...(op.ai.tier === "ask" ? { annotations: { destructiveHint: true, readOnlyHint: false } } : {}),
    }));
}

const INSTRUCTIONS = [
    "capystore is Harmony's media library: videos, images and galleries saved from links or uploaded, with public share links.",
    "Posts are found with library_list or library_search (meaning search) and opened with library_post; use the post `id` they return.",
    "Save a link (TikTok, X, YouTube, Instagram, a direct file...) with library_save. Upload a local file with upload_begin, then PUT the file's bytes to the upload_url it returns (its `curl` field is ready to run).",
    "Make ops (make_*, edits_render) answer a job: check on it with jobs_wait. Share links: links_create; collections and sets group them.",
    "To use part of a picture (a sticker in a screenshot) in a video: look with grid: true (a moment of a video: make_frames first saves frames as pictures), make_cropImage with the box (cutout: true for just the thing), look at the crop to check it, then edits_addOverlay.",
    "Tools marked destructive delete or change things for good: confirm with the user first.",
].join("\n");

// ---- JSON-RPC ---------------------------------------------------------------------------------------------------------

type RpcRequest = { jsonrpc?: unknown; id?: unknown; method?: unknown; params?: unknown };
type RpcReply = { jsonrpc: "2.0"; id: unknown; result?: unknown; error?: { code: number; message: string } };

const rpcError = (id: unknown, code: number, message: string): RpcReply => ({ jsonrpc: "2.0", id, error: { code, message } });

// Who is calling and how to reach the rest of the server. `ctx` is the POST /mcp op's context (its key already checked).
// `threadKey` names the MCP thread when it is not the client key's own (every private link shares one, section 35.5).
export type McpCaller = { ctx: OpContext; clientKeyId: string; threadKey?: string; origin: string; fetch?: typeof fetch };

// One JSON-RPC message in, its reply out (null for a notification).
export async function mcpMessage(registry: Registry, caller: McpCaller, msg: RpcRequest): Promise<RpcReply | null> {
    const isRequest = msg && typeof msg === "object" && "id" in msg && msg.id !== null && msg.id !== undefined;
    const id = isRequest ? msg.id : null;
    if (!msg || typeof msg !== "object" || msg.jsonrpc !== "2.0" || typeof msg.method !== "string") {
        return rpcError(id, -32600, "invalid request");
    }
    if (!isRequest) return null; // notifications (initialized, cancelled...) need no answer
    const params = (msg.params && typeof msg.params === "object" ? msg.params : {}) as Json;
    switch (msg.method) {
        case "initialize": {
            const asked = typeof params.protocolVersion === "string" ? params.protocolVersion : "";
            const version = (MCP_PROTOCOL_VERSIONS as readonly string[]).includes(asked) ? asked : MCP_PROTOCOL_VERSIONS[0];
            return {
                jsonrpc: "2.0",
                id,
                result: {
                    protocolVersion: version,
                    capabilities: { tools: { listChanged: false } },
                    serverInfo: { name: MCP_SERVER_NAME, title: "capystore", version: MCP_SERVER_VERSION },
                    instructions: INSTRUCTIONS,
                },
            };
        }
        case "ping":
            return { jsonrpc: "2.0", id, result: {} };
        case "tools/list":
            return { jsonrpc: "2.0", id, result: { tools: mcpToolList(registry, mcpFlags(caller.ctx)) } };
        case "tools/call": {
            const name = params.name;
            if (typeof name !== "string") return rpcError(id, -32602, "tools/call needs a name");
            const op = mcpOps(registry, mcpFlags(caller.ctx)).find((o) => mcpToolName(o.callName) === name);
            if (!op) return rpcError(id, -32602, `unknown tool ${name}`);
            const args = params.arguments && typeof params.arguments === "object" && !Array.isArray(params.arguments) ? params.arguments : {};
            return { jsonrpc: "2.0", id, result: await callTool(op, caller, args as Json) };
        }
        default:
            return rpcError(id, -32601, `method ${msg.method} is not supported`);
    }
}

type Content = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };
type ToolResult = { content: Content[]; isError?: boolean };

const textResult = (value: unknown, isError = false): ToolResult => {
    let text = typeof value === "string" ? value : JSON.stringify(value ?? null, null, 1);
    if (text.length > MCP_RESULT_MAX) text = `${text.slice(0, MCP_RESULT_MAX)}… (cut: ask for less, e.g. a smaller limit)`;
    return { content: [{ type: "text", text }], ...(isError ? { isError: true } : {}) };
};

// Run one tool as the client's MCP thread. Its arguments are the op's input object, checked by the op's own schema.
async function callTool(op: Op, caller: McpCaller, args: Json): Promise<ToolResult> {
    const collect: ChatCollect = { look: [], show: [], collage: null };
    const threadId = await mcpThreadId(caller.threadKey ?? caller.clientKeyId);
    // the MCP request itself never reaches the op (no request, url or query of its own, like a chat call)
    const { request: _r, url: _u, query: _q, params: _p, chat: _c, keyId: _k, caller: _w, durableObject: _d, ...base } = caller.ctx;
    const ctx = forCall(base, {
        keyId: chatKeyId(threadId),
        caller: "chat",
        chat: {
            threadId,
            collect,
            tools: chatTools({ db: base.db, mediaBaseUrl: base.mediaBaseUrl, shareBaseUrl: base.shareBaseUrl, embed: base.embed() }, collect),
            mcp: { origin: caller.origin, clientKeyId: caller.clientKeyId },
        },
    });
    // an op with its own argument mapping (collage) takes the object as its options
    const raw = op.ai.args ? argsToInput(op, [args]) : args;
    const parsed = op.input.safeParse(raw);
    if (!parsed.success) {
        const parts = parsed.error.issues.slice(0, 4).map((i) => `${i.path.length ? i.path.join(".") : "input"}: ${i.message}`);
        return textResult(`${mcpToolName(op.callName)}: ${parts.join("; ")}`, true);
    }
    try {
        if (op.callName === "look") {
            const l = parsed.data as { ids: string[]; grid?: boolean; frames?: boolean };
            return await look(ctx, caller, l.ids, { grid: l.grid === true, frames: l.frames === true });
        }
        // the chat's own runner, so a route op goes through the Durable Object exactly as the chat's does
        return textResult((await runOp(op, ctx, parsed.data)) ?? null);
    } catch (e) {
        if (e instanceof OpError) return textResult(e.message === e.code ? `${mcpToolName(op.callName)} failed: ${e.code}` : e.message, true);
        return textResult(e instanceof Error ? e.message : String(e), true);
    }
}

// look: the posts' pictures as MCP images (section 44.3: private ones read from R2, a grid or video frames when asked).
async function look(ctx: OpContext, caller: McpCaller, ids: string[], o: LookOpts = {}): Promise<ToolResult> {
    const wanted = [...new Set(ids)].slice(0, MCP_LOOK_MAX);
    const env = ctx.env as { ORIGINALS?: unknown; MEDIA?: unknown; IMAGES?: unknown };
    const opts = Object.fromEntries(wanted.map((id) => [id, o]));
    const imgs = await lookImages(
        { db: ctx.db, mediaBaseUrl: ctx.mediaBaseUrl, originals: env.ORIGINALS as never, media: env.MEDIA as never, images: (env.IMAGES ?? null) as never },
        wanted,
        opts,
    );
    const doFetch = caller.fetch ?? fetch;
    const content: Content[] = [];
    for (const id of wanted) {
        const list = imgs.get(id) ?? [];
        if (list.length === 0) {
            content.push({ type: "text", text: `Post ${id} has no picture to look at.` });
            continue;
        }
        for (const im of list) {
            if (im.data) {
                content.push({ type: "text", text: im.label });
                content.push({ type: "image", data: im.data, mimeType: im.mediaType! });
                continue;
            }
            content.push({ type: "text", text: `${im.label} ${im.url}` });
            try {
                const res = await doFetch(im.url!);
                const type = (res.headers.get("content-type") ?? "").split(";")[0]!.trim();
                const bytes = res.ok && type.startsWith("image/") ? new Uint8Array(await res.arrayBuffer()) : null;
                if (bytes && bytes.length <= MCP_PICTURE_MAX_BYTES) content.push({ type: "image", data: toBase64(bytes), mimeType: type });
                else await res.body?.cancel().catch(() => {});
            } catch {
                // the URL above stays as the answer
            }
        }
        if (o.frames && !list.some((i) => i.label.startsWith("Frame "))) content.push({ type: "text", text: `Post ${id} has no stored frames (not a video, or not described yet).` });
    }
    if (ids.length > MCP_LOOK_MAX) content.push({ type: "text", text: `Only the first ${MCP_LOOK_MAX} were shown.` });
    return { content };
}

function toBase64(bytes: Uint8Array): string {
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(s);
}

// ---- upload links -----------------------------------------------------------------------------------------------------
// upload_begin hands the agent a short-lived URL it PUTs a file's bytes to (PUT /mcp/upload/<token>), since JSON-RPC
// cannot carry a video. The token is signed with a key derived from the internal key; it names the client key (checked
// again at upload time, so revoking the key stops its links) and the MCP thread the file is uploaded as.

export const UPLOAD_TOKEN_TTL_MS = 15 * 60 * 1000;
export const UPLOAD_TOKEN_REGEX = /^[A-Za-z0-9_-]{16,400}\.[A-Za-z0-9_-]{43}$/;

export type UploadClaims = { k: string; t: string; e: number };

const b64url = (bytes: Uint8Array) => toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const fromB64url = (s: string) => {
    const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
};

async function hmac(secret: string, data: string): Promise<Uint8Array> {
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(`capystore-mcp-upload:${secret}`), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    return new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data)));
}

export async function signUploadToken(secret: string, claims: UploadClaims): Promise<string> {
    const payload = b64url(new TextEncoder().encode(JSON.stringify(claims)));
    return `${payload}.${b64url(await hmac(secret, payload))}`;
}

// The token's claims, or null when it is malformed, forged or expired.
export async function verifyUploadToken(secret: string, token: string, now: number): Promise<UploadClaims | null> {
    if (!UPLOAD_TOKEN_REGEX.test(token)) return null;
    const [payload, sig] = token.split(".") as [string, string];
    const want = await hmac(secret, payload);
    let got: Uint8Array;
    try {
        got = fromB64url(sig);
    } catch {
        return null;
    }
    if (got.length !== want.length) return null;
    let diff = 0;
    for (let i = 0; i < want.length; i++) diff |= want[i]! ^ got[i]!;
    if (diff !== 0) return null;
    let claims: UploadClaims;
    try {
        claims = JSON.parse(new TextDecoder().decode(fromB64url(payload))) as UploadClaims;
    } catch {
        return null;
    }
    if (typeof claims.k !== "string" || typeof claims.t !== "string" || typeof claims.e !== "number") return null;
    if (claims.e <= now) return null;
    return claims;
}

// The `Authorization` of an MCP client: `Api-Key <uuid>` (the app's own scheme) or `Bearer <uuid>` (what most MCP
// clients send). Returns the key, or the error code the gate would give.
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export function mcpAuthorization(header: string | null): { key: string } | { errorCode: string } {
    if (header === null) return { errorCode: "error.api.auth.key.missing" };
    const m = /^(Api-Key|Bearer) (\S+)$/i.exec(header);
    if (!m) return { errorCode: "error.api.auth.key.not_api_key" };
    if (!UUID_REGEX.test(m[2]!)) return { errorCode: "error.api.auth.key.invalid" };
    return { key: m[2]! };
}
