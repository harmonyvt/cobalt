// The MCP app's seams (MCP-APP-CONTRACT.md section 2): what the core (src/mcp.ts) gives an app tool, what an app tool
// gives back, and what a widget is. Free of Cloudflare imports.
import type * as z from "zod";
import type { AiFlags, OpContext } from "../registry/op";
import type { View } from "./shapes";

// What an app tool runs with. `call` runs a registry op by its chat call name ("library.search", "links.create"...)
// as the MCP thread, through the same runner, caps and Durable Object hop as the existing MCP tools; it throws OpError.
export type AppToolCtx = {
    op: OpContext;
    call(callName: string, input: unknown): Promise<unknown>;
    // false when the op is not offered now (e.g. "library.search" while search is off)
    has(callName: string): boolean;
    flags: AiFlags;
    // the API's public origin, e.g. https://api.capybaraharmony.com
    origin: string;
};

// `text` is the whole answer for a host with no widgets; `structured` matches the tool's `output` schema.
export type AppToolResult = { text: string; structured: Record<string, unknown> };

export type AppTool<I = any> = {
    // snake_case, unique among all MCP tools
    name: string;
    title: string;
    description: string;
    input: z.ZodType<I>;
    output: z.ZodType;
    readOnly: boolean;
    // extra MCP annotations (e.g. openWorldHint); readOnlyHint always comes from `readOnly`
    annotations?: Record<string, unknown>;
    // the widget view that draws its result; null: no widget (job_status)
    view: View | null;
    // only widgets call it (hidden from the model where the host supports tool visibility)
    appOnly?: boolean;
    // only offered while this holds
    when?: (flags: AiFlags) => boolean;
    run(ctx: AppToolCtx, input: I): Promise<AppToolResult>;
};

// One widget resource: `ui://capystore/<view>.html`, self-contained HTML.
export type Widget = { view: View; uri: string; title: string; html: string };
