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
    mcpOps,
    mcpToolList,
    mcpToolName,
    runChatOp,
    type McpCaller,
    type McpTool,
    type ToolResult,
} from "../mcp";
import { OpError } from "../registry/op";
import type { Registry } from "../registry/registry";
import { APP_TOOLS } from "./tools";
import type { AppTool, AppToolCtx, Widget } from "./types";
import { WIDGETS } from "./widgets.generated";

type Json = Record<string, unknown>;

export type McpParts = { appTools?: AppTool[]; widgets?: Widget[] };

// ---- the app tools ----------------------------------------------------------------------------------------------------

function appToolEntry(tool: AppTool): McpTool & Json {
    const extra = (tool as { annotations?: Json }).annotations;
    const ui: Json = {};
    if (tool.view) {
        // as registerAppTool writes them: the nested key and the legacy flat one
        const uri = `ui://capystore/${tool.view}.html`;
        ui.resourceUri = uri;
    }
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

async function callAppTool(tool: AppTool, registry: Registry, caller: McpCaller, args: unknown): Promise<ToolResult> {
    const parsed = tool.input.safeParse(args);
    if (!parsed.success) {
        const parts = parsed.error.issues.slice(0, 4).map((i) => `${i.path.length ? i.path.join(".") : "input"}: ${i.message}`);
        return { content: [{ type: "text", text: `${tool.name}: ${parts.join("; ")}` }], isError: true };
    }
    const flags = mcpFlags(caller.ctx);
    const ops = mcpOps(registry, flags);
    const ctx: AppToolCtx = {
        op: caller.ctx,
        flags,
        origin: caller.origin,
        has: (callName) => ops.some((o) => o.callName === callName),
        call: async (callName, input) => {
            const op = ops.find((o) => o.callName === callName);
            if (!op) throw new OpError(404, "error.mcp.not_offered", `${callName} is not offered here`);
            return runChatOp(op, caller, input);
        },
    };
    try {
        const r = await tool.run(ctx, parsed.data);
        return { content: [{ type: "text", text: cutText(r.text) }], structuredContent: r.structured };
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
    return { resourceDomains: [...new Set(resource)], connectDomains: [caller.origin] };
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
        const old = mode.appOnly ? [] : mcpToolList(registry, mcpFlags(caller.ctx));
        return { tools: [...app, ...old] as never };
    });

    server.setRequestHandler("tools/call", async (req) => {
        const { name } = req.params;
        const args = req.params.arguments && typeof req.params.arguments === "object" && !Array.isArray(req.params.arguments) ? req.params.arguments : {};
        const app = toolsOffered(parts.appTools, caller).find((t) => t.name === name);
        if (app) return (await callAppTool(app, registry, caller, args)) as never;
        const op = mode.appOnly ? undefined : mcpOps(registry, mcpFlags(caller.ctx)).find((o) => mcpToolName(o.callName) === name);
        if (!op) throw new ProtocolError(ProtocolErrorCode.InvalidParams, `unknown tool ${name}`);
        return (await callTool(op, caller, args)) as never;
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
