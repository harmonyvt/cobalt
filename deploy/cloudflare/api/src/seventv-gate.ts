// One pace for every 7TV API call (APP-API-CONTRACT.md section 62.5): the chat, the MCP, swarms and the studio all ask the
// one `SevenTvGate` Durable Object (idFromName("gate"), bound SEVENTV_GATE) for a slot before calling 7TV's API. It hands
// out 5 reads a second and 1 write a second, and half as many for a minute after anyone saw a 429. Image downloads from
// cdn.7tv.app do not ask. Without the binding (tests, a deploy without it) nothing waits. The gate never fails a call: when
// it cannot be reached in time the call goes ahead.
// The rules (GateCore) are plain TypeScript, tested under node; the Durable Object is in seventv-gate-do.ts.

export type GateKind = "read" | "write";
export type SevenTvGate = { slot(kind: GateKind): Promise<void>; slow(): Promise<void> };

export const GATE_GAP_MS: Record<GateKind, number> = { read: 200, write: 1000 };
export const GATE_SLOW_MS = 60_000;
export const GATE_WAIT_MAX_MS = 30_000;
export const GATE_CALL_MS = 2000;

export class GateCore {
    private next: Record<GateKind, number> = { read: 0, write: 0 };
    private slowUntil = 0;
    constructor(private now: () => number) {}
    // How long the caller waits before its call: the slots go out one gap apart (two gaps while slowed).
    slot(kind: GateKind): number {
        const now = this.now();
        const gap = GATE_GAP_MS[kind] * (now < this.slowUntil ? 2 : 1);
        const at = Math.max(now, this.next[kind]);
        this.next[kind] = at + gap;
        return Math.min(GATE_WAIT_MAX_MS, at - now);
    }
    slow(): void {
        this.slowUntil = this.now() + GATE_SLOW_MS;
    }
    slowed(): boolean {
        return this.now() < this.slowUntil;
    }
}

// The Durable Object's routes: POST /slot?kind=read|write answers { wait }; POST /slow.
export async function handleGateRoute(core: GateCore, request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "POST") return new Response(null, { status: 405 });
    if (url.pathname === "/slot") {
        const kind = url.searchParams.get("kind");
        if (kind !== "read" && kind !== "write") return new Response(null, { status: 400 });
        return Response.json({ wait: core.slot(kind) });
    }
    if (url.pathname === "/slow") {
        core.slow();
        return Response.json({ slowed: true });
    }
    return new Response(null, { status: 404 });
}

type GateNamespace = { idFromName(name: string): unknown; get(id: never): { fetch(r: Request): Promise<Response> } };

const ports = new WeakMap<object, SevenTvGate>();
const realSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

// The gate for an env (one per namespace), or null without the binding.
export function gateOf(env: { SEVENTV_GATE?: unknown }, sleep: (ms: number) => Promise<void> = realSleep): SevenTvGate | null {
    const ns = env.SEVENTV_GATE as GateNamespace | undefined;
    if (!ns || typeof ns !== "object" || typeof ns.idFromName !== "function") return null;
    const had = ports.get(ns);
    if (had) return had;
    const stub = () => ns.get(ns.idFromName("gate") as never);
    const ask = async (path: string): Promise<Response | null> => {
        try {
            return await Promise.race([stub().fetch(new Request(`https://gate.internal${path}`, { method: "POST" })), new Promise<null>((r) => setTimeout(() => r(null), GATE_CALL_MS))]);
        } catch {
            return null;
        }
    };
    const port: SevenTvGate = {
        async slot(kind) {
            const res = await ask(`/slot?kind=${kind}`);
            const wait = res && res.ok ? Number(((await res.json().catch(() => ({}))) as { wait?: unknown }).wait) : 0;
            if (Number.isFinite(wait) && wait > 0) await sleep(Math.min(GATE_WAIT_MAX_MS, wait));
        },
        async slow() {
            const res = await ask("/slow");
            await res?.body?.cancel().catch(() => {});
        },
    };
    ports.set(ns, port);
    return port;
}

// A Retry-After header as seconds (a number or an HTTP date), or null.
export function retryAfterSeconds(v: string | null, now: number): number | null {
    if (!v) return null;
    const n = Number(v.trim());
    if (Number.isFinite(n) && n >= 0) return Math.min(600, n);
    const at = Date.parse(v);
    return Number.isFinite(at) ? Math.max(0, Math.min(600, Math.round((at - now) / 1000))) : null;
}
