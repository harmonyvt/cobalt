// Chat code mode limits and the runner's type (APP-API-CONTRACT.md section 27), shared by chat.ts and
// the sandbox pieces (chat-loader.ts, chat-loader-module.ts) without pulling in the model client.

import type { ChatTools } from "./chat-tools";

export const MAX_TOOL_CALLS = 50; // per run
export const CODE_TIMEOUT_MS = 30_000;
export const CODE_CPU_MS = 5_000;
// a run whose code calls the workbench box (section 33.11): a wake, a 120 s command and a save fit
export const CODE_TIMEOUT_BOX_MS = 240_000;

export type CodeRun = { result?: unknown; error?: string; logs: string[]; calls: number };
export type CodeRunOptions = { timeoutMs?: number };
export type CodeRunner = (code: string, tools: ChatTools, opts?: CodeRunOptions) => Promise<CodeRun>;
