// The MCP server's protocol side (MCP-APP-CONTRACT.md section 6): the official SDK's low-level server and its web-standard
// Streamable HTTP transport, one of each per request (stateless, JSON answers, no session id, no SSE). The low-level class
// rather than McpServer, because the existing tools' names, descriptions and input schemas come from the op registry per
// request (feature flags) and must reach the client byte for byte; McpServer would re-register and re-validate them.
// The validator is the SDK's @cfworker one (an interpreter): nothing here compiles code at runtime.
// Free of Cloudflare imports: the tests run it under node.
import { ProtocolError, ProtocolErrorCode, Server, WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/server";
import { CfWorkerJsonSchemaValidator } from "@modelcontextprotocol/server/validators/cf-worker";
import { RESOURCE_MIME_TYPE, RESOURCE_URI_META_KEY } from "@modelcontextprotocol/ext-apps/server";
import {
    callTool,
    cutText,
    errorText,
    INSTRUCTIONS,
    jsonSchemaOf,
    MCP_PROTOCOL_VERSIONS,
    MCP_SERVER_NAME,
    MCP_SERVER_VERSION,
    mcpFlags,
    mcpListedOps,
    mcpOps,
    mcpToolList,
    mcpToolName,
    MCP_RESULT_MAX,
    runChatOp,
    type McpCaller,
    type McpTool,
    type ToolResult,
} from "../mcp";
import { OpError } from "../registry/op";
import type { Registry } from "../registry/registry";
import { FOLLOWS } from "./follow";
import { PREVIEW_TTL_MS, previewUrl, signPreviewToken } from "../mcp-preview";
import { RETIRED_TOOLS } from "./retired";
import type { View } from "./shapes";
import { APP_TOOLS } from "./tools";
import { PREVIEW_META_KEY, type AppTool, type AppToolCtx, type PreviewMeta, type Widget } from "./types";
import { WIDGETS } from "./widgets.generated";

type Json = Record<string, unknown>;

export type McpParts = { appTools?: AppTool[]; widgets?: Widget[] };

// ---- the app tools ----------------------------------------------------------------------------------------------------

// _meta of a tool tied to a widget, as registerAppTool writes it: the nested key and the legacy flat one
const viewMeta = (view: View): Json => {
    const uri = `ui://capystore/${view}.html`;
    return { ui: { resourceUri: uri }, [RESOURCE_URI_META_KEY]: uri };
};

function appToolEntry(tool: AppTool): McpTool & Json {
    const extra = (tool as { annotations?: Json }).annotations;
    const ui: Json = {};
    if (tool.view) ui.resourceUri = `ui://capystore/${tool.view}.html`;
    if (tool.appOnly) ui.visibility = ["app"];
    const meta: Json = {};
    if (Object.keys(ui).length) meta.ui = ui;
    if (typeof ui.resourceUri === "string") meta[RESOURCE_URI_META_KEY] = ui.resourceUri;
    return {
        name: tool.name,
        title: tool.title,
        description: tool.description,
        inputSchema: jsonSchemaOf(tool.input, "input"),
        outputSchema: jsonSchemaOf(tool.output, "output"),
        annotations: { ...extra, readOnlyHint: tool.readOnly },
        ...(Object.keys(meta).length ? { _meta: meta } : {}),
    };
}

const toolsOffered = (tools: AppTool[], caller: McpCaller) => {
    const flags = mcpFlags(caller.ctx);
    return tools.filter((t) => (t.when ? t.when(flags) : true));
};

// What an app tool runs with: every op the MCP can run (the retired calls too), as this MCP thread.
function toolCtx(registry: Registry, caller: McpCaller): { ctx: AppToolCtx; previews: PreviewMeta } {
    const flags = mcpFlags(caller.ctx);
    const ops = mcpOps(registry, flags);
    const expires = caller.ctx.now() + PREVIEW_TTL_MS;
    const previews: PreviewMeta = {};
    const expiresAt = new Date(expires).toISOString();
    const ctx: AppToolCtx = {
        op: caller.ctx,
        flags,
        origin: caller.origin,
        previewExpires: expiresAt,
        preview: async (key, fileId, slot, poster = slot === "poster") => {
            const url = previewUrl(caller.origin, await signPreviewToken(caller.ctx.env.COBALT_API_KEY, { k: caller.clientKeyId, i: fileId, e: expires, p: poster ? 1 : 0 }), poster);
            (previews[key] ??= { expires_at: expiresAt })[slot] = url;
        },
        has: (callName) => ops.some((o) => o.callName === callName),
        call: async (callName, input) => {
            const op = ops.find((o) => o.callName === callName);
            if (!op) throw new OpError(404, "error.mcp.not_offered", `${callName} is not offered here`);
            return runChatOp(op, caller, input);
        },
    };
    return { ctx, previews };
}

// structuredContent past MCP_RESULT_MAX is trimmed: the longest list in it is halved until it fits. `trimmed` says how many rows
// of that list are left (null when nothing was cut).
export function fitStructured(value: Json): { value: Json; trimmed: string | null } {
    const size = (v: Json) => JSON.stringify(v).length;
    if (size(value) <= MCP_RESULT_MAX) return { value, trimmed: null };
    const out: Json = { ...value };
    let note: string | null = null;
    for (let guard = 0; guard < 20 && size(out) > MCP_RESULT_MAX; guard++) {
        const key = Object.keys(out)
            .filter((k) => Array.isArray(out[k]) && (out[k] as unknown[]).length > 1)
            .sort((a, b) => JSON.stringify(out[b]).length - JSON.stringify(out[a]).length)[0];
        if (!key) break;
        const rows = out[key] as unknown[];
        out[key] = rows.slice(0, Math.ceil(rows.length / 2));
        note = `${(out[key] as unknown[]).length} of ${rows.length} ${key}`;
    }
    return { value: out, trimmed: note };
}

async function callAppTool(tool: AppTool, registry: Registry, caller: McpCaller, args: unknown): Promise<ToolResult> {
    const parsed = tool.input.safeParse(args);
    if (!parsed.success) {
        const parts = parsed.error.issues.slice(0, 4).map((i) => `${i.path.length ? i.path.join(".") : "input"}: ${i.message}`);
        return { content: [{ type: "text", text: `${tool.name}: ${parts.join("; ")}` }], isError: true };
    }
    const { ctx, previews } = toolCtx(registry, caller);
    try {
        const r = await tool.run(ctx, parsed.data);
        const fit = fitStructured(r.structured as Json);
        // signed preview links ride in _meta (the widget reads them there); the model sees neither text nor structuredContent of them
        return {
            content: [{ type: "text", text: cutText(fit.trimmed ? `${r.text}\n(The structured list was cut to ${fit.trimmed}: ask for less, e.g. a smaller limit.)` : r.text) }],
            structuredContent: fit.value,
            ...(Object.keys(previews).length ? { _meta: { [PREVIEW_META_KEY]: previews } } : {}),
        };
    } catch (e) {
        return { content: [{ type: "text", text: errorText(tool.name, e) }], isError: true };
    }
}

// ---- the widgets ------------------------------------------------------------------------------------------------------

const originOf = (url: string | undefined) => {
    try {
        return url ? new URL(url).origin : null;
    } catch {
        return null;
    }
};

// What a widget's sandbox may load (resourceDomains: the public media and share links) and call (connectDomains: the
// API, for the upload PUT).
export function widgetCsp(caller: McpCaller): { resourceDomains: string[]; connectDomains: string[] } {
    const { mediaBaseUrl, shareBaseUrl } = caller.ctx;
    const resource = [originOf(mediaBaseUrl), originOf(shareBaseUrl)].filter((o): o is string => !!o);
    // the API origin too: signed previews (/mcp/media/<token>) are played and drawn from it
    return { resourceDomains: [...new Set([...resource, caller.origin])], connectDomains: [caller.origin] };
}

// Claude's sandbox origin for a connector: the first 32 hex characters of SHA-256 of the exact URL it connected to,
// then ".claudemcpcontent.com" (claude.com/docs/connectors/building/mcp-apps/getting-started). Other hosts format it
// their own way, so this is never sent to them.
export async function claudeUiDomain(serverUrl: string): Promise<string> {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(serverUrl)));
    const hex = Array.from(digest.subarray(0, 16), (b) => b.toString(16).padStart(2, "0")).join("");
    return `${hex}.claudemcpcontent.com`;
}

// Whether the request comes from Claude: its connector backend or app names itself in the User-Agent. Not verified
// against a live Claude; when it does not match, `domain` stays unset, which Claude accepts.
export const looksLikeClaude = (request: Request) => /claude|anthropic/i.test(request.headers.get("user-agent") ?? "");

async function widgetMeta(caller: McpCaller, request: Request): Promise<Json> {
    const ui: Json = { csp: widgetCsp(caller), permissions: { clipboardWrite: {} } };
    if (looksLikeClaude(request)) ui.domain = await claudeUiDomain(request.url);
    return { ui };
}

// ---- the server -------------------------------------------------------------------------------------------------------

export type McpMode = { appOnly: boolean };

function buildServer(registry: Registry, caller: McpCaller, request: Request, parts: Required<McpParts>, mode: McpMode): Server {
    const server = new Server(
        { name: MCP_SERVER_NAME, title: "capystore", version: MCP_SERVER_VERSION },
        {
            capabilities: { tools: { listChanged: false }, resources: {}, prompts: {} },
            instructions: INSTRUCTIONS,
            supportedProtocolVersions: [...MCP_PROTOCOL_VERSIONS],
            jsonSchemaValidator: new CfWorkerJsonSchemaValidator(),
        },
    );

    server.setRequestHandler("tools/list", async () => {
        const app = toolsOffered(parts.appTools, caller).map(appToolEntry);
        // the older tools; those whose result also draws a widget carry its link, like an app tool does
        const old = mode.appOnly
            ? []
            : mcpToolList(registry, mcpFlags(caller.ctx)).map((t) => {
                  const follow = Object.entries(FOLLOWS).find(([callName]) => mcpToolName(callName) === t.name)?.[1];
                  return follow ? { ...t, _meta: viewMeta(follow.view) } : t;
              });
        return { tools: [...app, ...old] as never };
    });

    server.setRequestHandler("tools/call", async (req) => {
        const { name } = req.params;
        const args = req.params.arguments && typeof req.params.arguments === "object" && !Array.isArray(req.params.arguments) ? req.params.arguments : {};
        const offered = toolsOffered(parts.appTools, caller);
        const app = offered.find((t) => t.name === name);
        if (app) return (await callAppTool(app, registry, caller, args)) as never;
        if (!mode.appOnly) {
            // A retired tool name (not listed any more) is answered by its replacement app tool, so old clients and saved
            // prompts keep working; the answer is the app tool's (text and structuredContent).
            const retired = Object.hasOwn(RETIRED_TOOLS, name) ? RETIRED_TOOLS[name]! : null;
            const replacement = retired ? offered.find((t) => t.name === retired.tool) : undefined;
            if (retired && replacement) return (await callAppTool(replacement, registry, caller, retired.map(args))) as never;
            const op = mcpListedOps(registry, mcpFlags(caller.ctx)).find((o) => mcpToolName(o.callName) === name);
            if (op) {
                const follow = FOLLOWS[op.callName];
                const view = follow
                    ? async (value: unknown, input: unknown) => {
                          const { ctx, previews } = toolCtx(registry, caller);
                          const structured = await follow.build(ctx, input, value);
                          return structured ? { structured, ...(Object.keys(previews).length ? { meta: { [PREVIEW_META_KEY]: previews } } : {}) } : null;
                      }
                    : undefined;
                return (await callTool(op, caller, args, view)) as never;
            }
        }
        throw new ProtocolError(ProtocolErrorCode.InvalidParams, `unknown tool ${name}`);
    });

    server.setRequestHandler("resources/list", async () => ({
        resources: parts.widgets.map((w) => ({ uri: w.uri, name: w.view, title: w.title, mimeType: RESOURCE_MIME_TYPE })),
    }));
    server.setRequestHandler("resources/templates/list", async () => ({ resourceTemplates: [] }));
    server.setRequestHandler("resources/read", async (req) => {
        const w = parts.widgets.find((x) => x.uri === req.params.uri);
        if (!w) throw new ProtocolError(ProtocolErrorCode.InvalidParams, `unknown resource ${req.params.uri}`);
        return { contents: [{ uri: w.uri, mimeType: RESOURCE_MIME_TYPE, text: w.html, _meta: await widgetMeta(caller, request) }] };
    });
    server.setRequestHandler("prompts/list", async () => ({ prompts: [] }));
    return server;
}

// The SDK words a request it cannot read with the validator's own issue list (a JSON dump) as an internal error. A client
// gets a plain -32602 instead, never the dump. (The known mistakes are answered before they get here, in registry/ops/mcp.ts.)
async function withoutSchemaDumps(res: Response): Promise<Response> {
    if (!(res.headers.get("content-type") ?? "").includes("application/json")) return res;
    const text = await res.clone().text();
    if (!/"code\\?":\\?\s*\\?"invalid_/.test(text)) return res;
    try {
        const body = JSON.parse(text) as { jsonrpc: "2.0"; id: unknown; error?: { code: number; message: string } };
        if (!body.error || !/"code":\s*"invalid_/.test(body.error.message)) return res;
        const issue = /"message":\s*"([^"]{1,120})"/.exec(body.error.message)?.[1];
        const fixed = { ...body, error: { code: -32602, message: `invalid params${issue ? `: ${issue}` : ""}` } };
        return new Response(JSON.stringify(fixed), { status: res.status, headers: res.headers });
    } catch {
        return res;
    }
}

// One POST answered. `body` is the parsed JSON (an object, or a batch already cut to its first 20), `request` the
// original (its URL and User-Agent). The transport is told the request is JSON that accepts JSON, since old clients
// of this server never sent those headers.
export async function serveMcpRequest(
    registry: Registry,
    caller: McpCaller,
    request: Request,
    body: unknown,
    parts: McpParts = {},
): Promise<Response> {
    const url = new URL(request.url);
    const mode: McpMode = { appOnly: url.searchParams.get("tools") === "app" };
    const server = buildServer(registry, caller, request, { appTools: parts.appTools ?? APP_TOOLS, widgets: parts.widgets ?? WIDGETS }, mode);
    const transport = new WebStandardStreamableHTTPServerTransport({ enableJsonResponse: true });
    await server.connect(transport);
    const headers = new Headers(request.headers);
    headers.set("content-type", "application/json");
    headers.set("accept", "application/json, text/event-stream");
    // the first server ignored this header; the SDK answers 400 to a version it does not know, so an unknown one is dropped
    const asked = headers.get("mcp-protocol-version");
    if (asked !== null && !(MCP_PROTOCOL_VERSIONS as readonly string[]).includes(asked)) headers.delete("mcp-protocol-version");
    try {
        return await withoutSchemaDumps(await transport.handleRequest(new Request(request.url, { method: "POST", headers }), { parsedBody: body }));
    } finally {
        await server.close().catch(() => {});
    }
}
