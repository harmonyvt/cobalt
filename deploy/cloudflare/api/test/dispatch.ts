// What the Worker decides for a request, the op registry first and then the gate's last rule (worker.ts order,
// APP-API-CONTRACT.md 33.2 and 33.12), as one decision the routing tests can compare: a registered route reads like a
// lookup or service decision with `op` (the op's name). Auth is the registry's rule: `key` refuses the library service
// with a bodyless 404, `key_or_service` lets it through, `service` refuses everyone else with 401 invalid, a bad header
// is the 401 with cobalt's codes.
//
// The few routes whose first answer depends on the request itself read as they always did: GET /capabilities as
// `{ action: "capabilities", auth, key? }`, GET / and GET /tunnel as `forward` or a 404.
import { decide, parseAuthorization, type GateConfig, type GateRequest } from "../src/gate";
import { REGISTRY } from "../src/registry/index";
import { capabilitiesAuth, infoAllowed, tunnelOpen } from "../src/registry/ops/system";

type Params = { params?: Record<string, string> };
export type Dispatch =
    | ReturnType<typeof decide>
    | { action: "reject"; status: number; errorCode?: string }
    | ({ action: "lookup"; key: string; op: string } & Params)
    | ({ action: "service"; op: string } & Params)
    | { action: "capabilities"; auth: string; key?: string };

export function dispatch(req: GateRequest, cfg: GateConfig): Dispatch {
    const m = req.method === "OPTIONS" ? null : REGISTRY.match(req.method, req.pathname);
    if (!m) return decide(req, cfg);
    const params = Object.keys(m.params).length > 0 ? { params: m.params } : {};
    const op = m.op.name;
    if (op === "capabilities") return { action: "capabilities", ...capabilitiesAuth(!!req.service, req.authorization) };
    if (op === "cobalt.info") return infoAllowed(req.origin, cfg.corsUrl) ? { action: "forward" } : { action: "reject", status: 404 };
    if (op === "cobalt.tunnel") return tunnelOpen(req.searchParams, cfg.now) ? { action: "forward" } : { action: "reject", status: 404 };
    // no key is read: reads like the service (nothing to look up)
    if (m.op.auth === "open" || m.op.auth === "capability") return { action: "service", op, ...params };
    if (m.op.auth === "service") {
        return req.service ? { action: "service", op, ...params } : { action: "reject", status: 401, errorCode: "error.api.auth.key.invalid" };
    }
    if (req.service) return m.op.auth === "key" ? { action: "reject", status: 404, errorCode: undefined } : { action: "service", op, ...params };
    const parsed = parseAuthorization(req.authorization);
    return "key" in parsed ? { action: "lookup", key: parsed.key, op, ...params } : { action: "reject", status: 401, errorCode: parsed.errorCode };
}
