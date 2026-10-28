// Confirm cards (APP-API-CONTRACT.md 33.5): an `ask` op the chat AI called waits here until Harmony answers. One per
// thread, in the main Durable Object's storage (`chat:pending:<thread id>`), 15 minutes. The Worker reaches it through
// internal paths the gate never routes (`/chat/pending/...` is a 404 from the internet), with key id `chat:<thread id>`.
// Free of Cloudflare imports: the DO side takes its storage, the Worker side its container stub.
import { KEY_ID_HEADER } from "../headers";

export const CONFIRM_TTL_MS = 15 * 60 * 1000;
export const CONFIRM_ID_REGEX = /^[A-Za-z0-9]{16}$/;

export type PendingConfirm = {
    id: string; // the card's id (16 letters/digits)
    op: string; // the op's name
    input: unknown; // the checked input it runs with
    summary: string;
    effect: Record<string, unknown>;
    message_id: string | null; // the assistant message that shows the card
    created_at: number;
    expires_at: number;
};

export interface PendingPort {
    put(thread: string, rec: PendingConfirm): Promise<void>;
    // The card's call, removed: null when there is none, it expired, or the id is not the thread's current card.
    take(thread: string, id: string): Promise<PendingConfirm | null>;
    drop(thread: string): Promise<void>;
}

const THREAD_REGEX = /^[A-Za-z0-9]{16}$/;
const storageKey = (thread: string) => `chat:pending:${thread}`;

// ---- the Durable Object side ----------------------------------------------------------------------------------------

type Storage = {
    get<T>(key: string): Promise<T | undefined>;
    put(key: string, value: unknown): Promise<void>;
    delete(key: string): Promise<boolean>;
};

export const isChatPendingRoute = (pathname: string) => pathname.startsWith("/chat/pending/");

// PUT /chat/pending/<thread> <record>, POST /chat/pending/<thread>/take {"id"}, DELETE /chat/pending/<thread>.
// Only the Worker's own key id for that thread is accepted (the Worker strips the header from every client request).
export async function handleChatPendingRoute(storage: Storage, request: Request, now: number): Promise<Response> {
    const [thread, sub, ...rest] = new URL(request.url).pathname.slice("/chat/pending/".length).split("/");
    const nope = () => Response.json({ status: "error", error: { code: "error.chat.not_found" } }, { status: 404 });
    if (!THREAD_REGEX.test(thread ?? "") || rest.length > 0 || request.headers.get(KEY_ID_HEADER) !== `chat:${thread}`) return nope();
    const key = storageKey(thread!);
    if (sub === undefined && request.method === "PUT") {
        const rec = (await request.json().catch(() => null)) as PendingConfirm | null;
        if (!rec || typeof rec.id !== "string" || !CONFIRM_ID_REGEX.test(rec.id) || typeof rec.op !== "string") {
            return Response.json({ status: "error", error: { code: "error.chat.bad_request" } }, { status: 400 });
        }
        await storage.put(key, rec);
        return Response.json({ status: "success" });
    }
    if (sub === undefined && request.method === "DELETE") {
        await storage.delete(key);
        return Response.json({ status: "success" });
    }
    if (sub === "take" && request.method === "POST") {
        const body = (await request.json().catch(() => null)) as { id?: unknown } | null;
        const rec = await storage.get<PendingConfirm>(key);
        if (!rec) return nope();
        if (rec.expires_at <= now) {
            await storage.delete(key);
            return nope();
        }
        if (rec.id !== body?.id) return nope();
        await storage.delete(key);
        return Response.json({ status: "success", pending: rec });
    }
    return nope();
}

// ---- the Worker side ------------------------------------------------------------------------------------------------

export function pendingPort(container: { fetch(r: Request): Promise<Response> }): PendingPort {
    const call = (thread: string, path: string, method: string, body?: unknown) =>
        container.fetch(
            new Request(`https://do.internal/chat/pending/${thread}${path}`, {
                method,
                headers: { [KEY_ID_HEADER]: `chat:${thread}`, ...(body === undefined ? {} : { "content-type": "application/json" }) },
                body: body === undefined ? undefined : JSON.stringify(body),
            }),
        );
    return {
        async put(thread, rec) {
            const res = await call(thread, "", "PUT", rec);
            await res.body?.cancel().catch(() => {});
            if (!res.ok) throw new Error(`pending store answered ${res.status}`);
        },
        async take(thread, id) {
            const res = await call(thread, "/take", "POST", { id });
            if (res.status === 404) {
                await res.body?.cancel().catch(() => {});
                return null;
            }
            if (!res.ok) throw new Error(`pending store answered ${res.status}`);
            return ((await res.json()) as { pending: PendingConfirm }).pending;
        },
        async drop(thread) {
            const res = await call(thread, "", "DELETE");
            await res.body?.cancel().catch(() => {});
        },
    };
}
