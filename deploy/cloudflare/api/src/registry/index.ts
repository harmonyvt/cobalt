// The registry every request and chat call goes through (APP-API-CONTRACT.md section 33). Add an area's ops here; each
// area keeps its ops in ops/<area>.ts.
import { BOX_OPS } from "./ops/box";
import { CHAT_OPS } from "./ops/chat";
import { LIBRARY_OPS } from "./ops/library";
import { Registry } from "./registry";
import { toolTypesFor } from "./typescript";

export const REGISTRY = new Registry([...LIBRARY_OPS, ...CHAT_OPS, ...BOX_OPS]);

// The model's cheat sheet for the sandbox API, generated from the ops (`search` only while meaning search is on, `box`
// only while the workbench is on).
export const toolTypes = (search: boolean, registry: Registry = REGISTRY, box = false): string => toolTypesFor(registry, { search, box });
export const TOOL_TYPES = toolTypes(true);

export { defineOp, ok, OpError, type Op, type OpContext, type OpReply } from "./op";
export { Registry } from "./registry";
export { handleOp } from "./http";
export { opBase, forCall, type OpBase } from "./context";
export { chatToolbox, runOp } from "./ai";
