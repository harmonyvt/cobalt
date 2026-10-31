// The registry every request and chat call goes through (APP-API-CONTRACT.md section 33). Add an area's ops here; each
// area keeps its ops in ops/<area>.ts.
import { AGENT_OPS } from "./ops/agents";
import { AUTH_OPS } from "./ops/auth";
import { BOX_OPS } from "./ops/box";
import { CHAT_OPS } from "./ops/chat";
import { CHAT_VIDEO_OPS } from "./ops/chat-video";
import { CHAT_SHARE_OPS } from "./ops/chat-share";
import { EDITOR_OPS } from "./ops/editor";
import { FRAME_OPS } from "./ops/frames";
import { HIDDEN_OPS } from "./ops/hidden";
import { HOST_OPS } from "./ops/hosts";
import { LIBRARY_OPS } from "./ops/library";
import { LIBRARY_ADMIN_OPS } from "./ops/library-admin";
import { LIVE_OPS } from "./ops/live";
import { LIBRARY_WRITE_OPS } from "./ops/library-writes";
import { MAKE_OPS } from "./ops/make";
import { MCP_OPS } from "./ops/mcp";
import { PRIVATE_OPS } from "./ops/private";
import { SHARE_OPS } from "./ops/share";
import { STAGE_OPS } from "./ops/stage";
import { SYSTEM_OPS } from "./ops/system";
import { Registry } from "./registry";
import { toolTypesFor } from "./typescript";
import type { AiFlags } from "./op";

export const REGISTRY = new Registry([
    ...LIBRARY_OPS,
    ...LIBRARY_WRITE_OPS,
    ...LIBRARY_ADMIN_OPS,
    ...CHAT_OPS,
    ...CHAT_SHARE_OPS,
    ...MAKE_OPS,
    ...CHAT_VIDEO_OPS,
    ...AGENT_OPS,
    ...EDITOR_OPS,
    ...SHARE_OPS,
    ...PRIVATE_OPS,
    ...HIDDEN_OPS,
    ...STAGE_OPS,
    ...BOX_OPS,
    ...FRAME_OPS,
    ...LIVE_OPS,
    ...SYSTEM_OPS,
    ...MCP_OPS,
    ...AUTH_OPS,
    ...HOST_OPS,
]);

// The model's cheat sheet for the sandbox API, generated from the ops (`search` only while meaning search is on, `box`
// only while the workbench is on).
export const toolTypes = (search: boolean, registry: Registry = REGISTRY, box = false, extra: Partial<AiFlags> = {}): string =>
    toolTypesFor(registry, { ...extra, search, box });
export const TOOL_TYPES = toolTypes(true);

export { defineOp, ok, OpError, type Op, type OpContext, type OpReply } from "./op";
export { Registry } from "./registry";
export { handleOp } from "./http";
export { opBase, forCall, type OpBase } from "./context";
export { chatToolbox, runOp } from "./ai";
