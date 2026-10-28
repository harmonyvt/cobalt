// Per-thread daily caps for what the chat AI may start (APP-API-CONTRACT.md 33.7): renders (T4) and anything later
// that costs real money. One counter per thread and kind in the main Durable Object's storage
// (`chat:budget:<thread>:<kind>`, `{ day, n }`, reset when the UTC day changes). The Worker reaches it through internal
// paths the gate never routes (`/chat/budget/...` is a 404 from the internet), with key id `chat:<thread id>`, like the
// confirm cards (pending.ts). Free of Cloudflare imports.
import { KEY_ID_HEADER } from "../headers";

const THREAD_REGEX = /^[A-Za-z0-9]{16}$/;
const KIND_REGEX = /^[a-z_]{1,24}$/;

export const isChatBudgetRoute = (pathname: string) => pathname.startsWith("/chat/budget/");

const dayOf = (ms: number) => new Date(ms).toISOString().slice(0, 10);
const storageKey = (thread: string, kind: string) => `chat:budget:${thread}:${kind}`;

type Storage = {
    get<T>(key: string): Promise<T | undefined>;
    put(key: string, value: unknown): Promise<void>;
};
type Count = { day: string; n: number };

// POST /chat/budget/<thread>/<kind> {"limit": n}: takes one unit when fewer than `limit` were taken today and answers
// `{ ok: true, used }`, else `{ ok: false, used }` and takes nothing. {"refund": true} gives one back (a start that
// failed). The DO runs one request at a time, so the read and the write cannot interleave. Only the Worker's own key
// id for that thread is accepted.
export async function handleChatBudgetRoute(storage: Storage, request: Request, now: number): Promise<Response> {
    const [thread, kind, ...rest] = new URL(request.url).pathname.slice("/chat/budget/".length).split("/");
    const nope = () => Response.json({ status: "error", error: { code: "error.chat.not_found" } }, { status: 404 });
    if (
        request.method !== "POST" ||
        !THREAD_REGEX.test(thread ?? "") ||
        !KIND_REGEX.test(kind ?? "") ||
        rest.length > 0 ||
        request.headers.get(KEY_ID_HEADER) !== `chat:${thread}`
    ) {
        return nope();
    }
    const body = (await request.json().catch(() => null)) as { limit?: unknown; refund?: unknown } | null;
    const key = storageKey(thread!, kind!);
    const day = dayOf(now);
    const stored = await storage.get<Count>(key);
    const used = stored && stored.day === day ? stored.n : 0;
    if (body?.refund === true) {
        if (used > 0) await storage.put(key, { day, n: used - 1 } satisfies Count);
        return Response.json({ status: "success", ok: true, used: Math.max(0, used - 1) });
    }
    const limit = body?.limit;
    if (typeof limit !== "number" || !Number.isInteger(limit) || limit < 0) {
        return Response.json({ status: "error", error: { code: "error.chat.bad_request" } }, { status: 400 });
    }
    if (used >= limit) return Response.json({ status: "success", ok: false, used });
    await storage.put(key, { day, n: used + 1 } satisfies Count);
    return Response.json({ status: "success", ok: true, used: used + 1 });
}

export interface BudgetPort {
    // one unit of `kind` for this thread today: true when taken, false when the cap is reached
    take(thread: string, kind: string, limit: number): Promise<boolean>;
    // gives back one unit taken today (a start that did not happen); never throws
    refund(thread: string, kind: string): Promise<void>;
}

export function budgetPort(container: { fetch(r: Request): Promise<Response> }): BudgetPort {
    const call = (thread: string, kind: string, body: unknown) =>
        container.fetch(
            new Request(`https://do.internal/chat/budget/${thread}/${kind}`, {
                method: "POST",
                headers: { [KEY_ID_HEADER]: `chat:${thread}`, "content-type": "application/json" },
                body: JSON.stringify(body),
            }),
        );
    return {
        async take(thread, kind, limit) {
            const res = await call(thread, kind, { limit });
            if (!res.ok) {
                await res.body?.cancel().catch(() => {});
                throw new Error(`budget store answered ${res.status}`);
            }
            return ((await res.json()) as { ok: boolean }).ok === true;
        },
        async refund(thread, kind) {
            try {
                const res = await call(thread, kind, { refund: true });
                await res.body?.cancel().catch(() => {});
            } catch {
                // a lost refund only costs one unit of today's cap
            }
        },
    };
}

// The daily cap from a plain var (CHAT_DAILY_RENDERS): a whole number 0..1000, else the default.
export function dailyCap(raw: string | undefined, fallback: number): number {
    if (raw === undefined || raw.trim() === "" || !/^\d{1,4}$/.test(raw.trim())) return fallback;
    return Math.min(1000, Number(raw.trim()));
}
