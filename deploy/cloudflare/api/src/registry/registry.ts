// The registry: the list of ops, matched by route and looked up by their chat call names (APP-API-CONTRACT.md 33).
import type { AiFlags, Op, RouteHost } from "./op";

type Compiled = { op: Op; host: RouteHost; rest: boolean; segments: ({ lit: string } | { param: string; re: RegExp | null })[] };

export type RouteMatch = { op: Op; params: Record<string, string> };

export class Registry {
    readonly ops: readonly Op[];
    #routes: Compiled[] = [];
    #byName = new Map<string, Op>();
    #byCall = new Map<string, Op>();

    constructor(ops: readonly Op[]) {
        this.ops = ops;
        const routeKeys = new Set<string>();
        for (const op of ops) {
            if (this.#byName.has(op.name)) throw new Error(`op ${op.name} is defined twice`);
            this.#byName.set(op.name, op);
            if (op.ai.tier !== "hidden") {
                for (const call of [op.callName, ...(op.ai.aliases ?? [])]) {
                    if (this.#byCall.has(call)) throw new Error(`chat call ${call} is taken (${op.name})`);
                    this.#byCall.set(call, op);
                }
            }
            if (!op.route) continue;
            const host = op.route.host ?? "api";
            const rest = op.route.path === "/*" || op.route.path.endsWith("/*");
            const segments = (rest ? op.route.path.slice(0, -2) : op.route.path)
                .split("/")
                .slice(1)
                .map((s) => (s.startsWith(":") ? { param: s.slice(1), re: op.route!.params?.[s.slice(1)] ?? null } : { lit: s }));
            const key = `${host} ${op.route.method} ${segments.map((s) => ("lit" in s ? s.lit : ":")).join("/")}${rest ? "/*" : ""}`;
            if (routeKeys.has(key)) throw new Error(`route ${op.route.method} ${op.route.path} is defined twice`);
            routeKeys.add(key);
            this.#routes.push({ op, host, rest, segments });
        }
        // A namespace and a call cannot share a name unless the call is an alias kept for old threads
        // (cobalt.library(...) and cobalt.library.list(...) both work).
    }

    op(name: string): Op | undefined {
        return this.#byName.get(name);
    }

    // The op a request is for, or null (gate.ts answers it). Exact segments only: a trailing slash, an extra segment or
    // a param that fails its pattern is not a match, unless the route ends in "/*".
    match(method: string, pathname: string, host: RouteHost = "api"): RouteMatch | null {
        const parts = pathname.split("/").slice(1);
        for (const r of this.#routes) {
            if (r.host !== host) continue;
            if (r.op.route!.method !== "ANY" && r.op.route!.method !== method) continue;
            if (r.rest ? parts.length < r.segments.length : r.segments.length !== parts.length) continue;
            const params: Record<string, string> = {};
            let hit = true;
            for (let i = 0; i < r.segments.length && hit; i++) {
                const seg = r.segments[i]!;
                const part = parts[i]!;
                if ("lit" in seg) hit = seg.lit === part;
                else if (part === "" || (seg.re && !seg.re.test(part))) hit = false;
                else params[seg.param] = part;
            }
            if (hit) return { op: r.op, params };
        }
        return null;
    }

    // The ops a surface may call. "chat": every op the model is allowed to see (free and ask), in definition order.
    toolsFor(surface: "chat", flags: AiFlags): Op[] {
        if (surface !== "chat") return [];
        return this.ops.filter((o) => o.ai.tier !== "hidden" && (o.ai.when ? o.ai.when(flags) : true));
    }

    // A chat call name (or an old alias) -> its op.
    byCall(name: string): Op | undefined {
        return this.#byCall.get(name);
    }
}
