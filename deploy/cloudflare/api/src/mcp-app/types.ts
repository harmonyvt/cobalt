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
    // Signs a one-hour link a widget can play (MCP-APP-CONTRACT.md section 9) and files it under `key` in the result's
    // `_meta["capystore/preview"]`, never in structuredContent or text. `slot` is where it goes: "url" (the file's bytes),
    // "poster" (its poster) or "thumb" (a post's picture: the file itself, or its poster when `poster` is true). A
    // poster-slot link opens the poster only. Only for a file the caller already read through a post that is not hidden.
    preview(key: string, fileId: string, slot: "url" | "poster" | "thumb", poster?: boolean): Promise<void>;
    // when those links stop working (ISO 8601)
    previewExpires: string;
};

// `text` is the whole answer for a host with no widgets; `structured` matches the tool's `output` schema.
export type AppToolResult = { text: string; structured: Record<string, unknown> };

// The signed links of one result, by post, file or project id: { url?, poster?, thumb?, expires_at }
export type PreviewMeta = Record<string, { url?: string; poster?: string; thumb?: string; expires_at: string }>;
export const PREVIEW_META_KEY = "capystore/preview";

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
