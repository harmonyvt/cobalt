// Chat code mode limits and the runner's type (APP-API-CONTRACT.md section 27), shared by chat.ts and
// the sandbox pieces (chat-loader.ts, chat-loader-module.ts) without pulling in the model client.

import type { ChatTools } from "./chat-tools";

export const MAX_TOOL_CALLS = 50; // per run
// wall clock per run: a cobalt.library.save waits up to 60 s for its save (APP-API-CONTRACT.md 33.7)
export const CODE_TIMEOUT_MS = 90_000;
export const CODE_CPU_MS = 5_000;

export type CodeRun = { result?: unknown; error?: string; logs: string[]; calls: number };
export type CodeRunner = (code: string, tools: ChatTools) => Promise<CodeRun>;
