// What the Worker decides for a request, the op registry first and then the gate (worker.ts order, APP-API-CONTRACT.md
// 33.2), as one decision the gate tests can compare: a registered route reads like the gate's lookup or service decision
// with `op` (the op's name) in place of `then`. Auth is the registry's rule: `key` refuses the library service with a
// bodyless 404, `key_or_service` lets it through, a bad header is the gate's 401.
import { decide, parseAuthorization, type GateConfig, type GateRequest } from "../src/gate";
import { REGISTRY } from "../src/registry/index";

export type Dispatch = ReturnType<typeof decide> | { action: "lookup"; key: string; op: string; params?: Record<string, string> } | { action: "service"; op: string; params?: Record<string, string> };

export function dispatch(req: GateRequest, cfg: GateConfig): Dispatch {
    const m = req.method === "OPTIONS" ? null : REGISTRY.match(req.method, req.pathname);
    if (!m) return decide(req, cfg);
    const params = Object.keys(m.params).length > 0 ? { params: m.params } : {};
    if (m.op.auth === "open" || m.op.auth === "capability") return { action: "service", op: m.op.name, ...params };
    if (req.service) return m.op.auth === "key" ? { action: "reject", status: 404, errorCode: undefined } : { action: "service", op: m.op.name, ...params };
    const parsed = parseAuthorization(req.authorization);
    return "key" in parsed ? { action: "lookup", key: parsed.key, op: m.op.name, ...params } : { action: "reject", status: 401, errorCode: parsed.errorCode };
}
