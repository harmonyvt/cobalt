// The registry's HTTP side (APP-API-CONTRACT.md 33.2): match a request, check its caller the way the gate does, check
// its input, build one context, run the handler (in the Worker or through the Durable Object), and answer with the op's
// CORS and cache headers. Runs in worker.ts before the gate; anything not registered falls through to it.
import { parseAuthorization } from "../gate";
import { KEY_ID_HEADER } from "../headers";
import { countryOf, lookupKey } from "../keys";
import { SERVICE_KEY_ID } from "../library";
import { forCall, type OpBase } from "./context";
import { OpError, type Op, type OpContext, type OpReply, type RouteHost } from "./op";
import type { Registry } from "./registry";

const json = (status: number, body: unknown, allowOrigin?: string, extra: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), {
        status,
        headers: {
            "content-type": "application/json",
            ...(allowOrigin ? { "access-control-allow-origin": allowOrigin } : {}),
            ...extra,
        },
    });

const errBody = (code: string) => ({ status: "error", error: { code } });

export type HttpCall = {
    request: Request; // internal headers already stripped
    url: URL;
    service: boolean; // the library service credential, already checked
    allowOrigin?: string; // the web origin, when the request came from it
    host?: RouteHost; // which of the Worker's hosts it came to (default the API)
    country?: string | null; // the original request's cf.country (section 42.2); default: read from `request`
};

// The registry's answer, or null when no op has this method and path.
export async function handleOp(registry: Registry, base: OpBase, call: HttpCall): Promise<Response | null> {
    const host = call.host ?? "api";
    // The API's preflights stay with the gate (its OPTIONS rule covers every path); the other hosts answer their own.
    if (host === "api" && call.request.method === "OPTIONS") return null;
    const m = registry.match(call.request.method, call.url.pathname, host);
    if (!m) return null;
    const { op, params } = m;
    const { allowOrigin } = call;

    // ---- who is asking (the gate's rules, then the Worker's D1 lookup) ----
    let keyId: string | null = null;
    let caller: OpContext["caller"] = "open";
    const country = call.country ?? countryOf(call.request);
    if (op.auth === "service") {
        // the web Worker's library service only; any other caller is told its key is invalid, like the gate did
        if (!call.service) return json(401, errBody("error.api.auth.key.invalid"), allowOrigin);
        keyId = SERVICE_KEY_ID;
        caller = "service";
    } else if (op.auth === "open" && call.service) {
        // an open route may answer the service differently (GET /capabilities); there is still no key id
        caller = "service";
    } else if (op.auth === "key" || op.auth === "key_or_service") {
        if (call.service) {
            if (op.auth === "key") return new Response(null, { status: 404 });
            keyId = SERVICE_KEY_ID;
            caller = "service";
        } else {
            const parsed = parseAuthorization(call.request.headers.get("Authorization"));
            if (!("key" in parsed)) return json(401, errBody(parsed.errorCode), allowOrigin);
            try {
                keyId = await lookupKey(base.db, parsed.key, base.now(), country);
            } catch {
                // fail closed: never run an op when D1 cannot vouch for the key
                return json(503, errBody("error.api.generic"), allowOrigin);
            }
            if (keyId === null) return json(401, errBody("error.api.auth.key.invalid"), allowOrigin);
            caller = "key";
        }
    }

    const ctx = forCall(base, { keyId, caller, request: call.request, url: call.url, params, country });
    const headers: Record<string, string> = op.noStore ? { "cache-control": "no-store" } : {};
    const origin = op.cors ? allowOrigin : undefined;

    try {
        if (op.runs === "durable_object" && !op.handler) {
            // the Durable Object owns it: the request goes on with the verified key id, never the client's key
            const h = new Headers(call.request.headers);
            h.delete("Authorization");
            if (keyId) h.set(KEY_ID_HEADER, keyId);
            return withHeaders(await base.container.fetch(new Request(call.request, { headers: h })), origin, headers);
        }
        const input = await httpInput(op, ctx);
        const out = await op.handler!(ctx, input);
        if (out instanceof Response) return withHeaders(out, origin, headers);
        return json(out.status, out.body, origin, { ...headers, ...out.headers });
    } catch (e) {
        if (e instanceof OpError) return json(e.status, errBody(e.code), origin, headers);
        console.error(`[ops] ${op.name} failed`, e instanceof Error ? e.message : String(e));
        return json(503, errBody("error.api.generic"), origin, headers);
    }
}

// The request's input: the op's own reader, or path params + query + JSON body, checked against the schema.
async function httpInput(op: Op, ctx: OpContext): Promise<unknown> {
    const bad = () => new OpError(400, op.badRequest ?? "error.api.bad_request");
    let raw: unknown;
    if (op.http) raw = await op.http(ctx);
    else {
        const obj: Record<string, unknown> = { ...Object.fromEntries(ctx.query), ...ctx.params };
        const m = ctx.request!.method;
        if (m === "POST" || m === "PUT" || m === "PATCH") {
            const text = await ctx.request!.clone().text();
            if (text.trim() !== "") {
                let body: unknown;
                try {
                    body = JSON.parse(text);
                } catch {
                    throw bad();
                }
                if (!body || typeof body !== "object" || Array.isArray(body)) throw bad();
                Object.assign(obj, body, ctx.params);
            }
        }
        raw = obj;
    }
    const r = op.input.safeParse(raw);
    if (!r.success) throw bad();
    return r.data;
}

function withHeaders(res: Response, allowOrigin: string | undefined, extra: Record<string, string>): Response {
    if (!allowOrigin && Object.keys(extra).length === 0) return res;
    const out = new Response(res.body, res);
    if (allowOrigin) out.headers.set("access-control-allow-origin", allowOrigin);
    for (const [k, v] of Object.entries(extra)) if (!out.headers.has(k)) out.headers.set(k, v);
    return out;
}

export type { OpReply };
