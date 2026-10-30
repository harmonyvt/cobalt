// /api/mcp and /api/mcp/rotate: the owner's MCP switch (APP-API-CONTRACT.md section 35.5), served by the web Worker.
// Cloudflare Access for the owner first, the web app's origin for POSTs, then the API Worker's own ops through the
// service binding (GET/POST /mcp/settings, POST /mcp/settings/rotate). The private link itself is only ever in the
// answer to the POST that made it.
import { verifyAccessJwt, type AccessConfig } from "./access";
import { jwksFor, type Deps, type Env } from "./keys";
import { API_BASE } from "./library";

const MAX_BODY_BYTES = 512;

const json = (status: number, body: unknown, extra: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json", "cache-control": "no-store", "x-content-type-options": "nosniff", ...extra },
    });
const error = (status: number, code: string, extra?: Record<string, string>) => json(status, { error: code }, extra);

export async function handleMcp(request: Request, env: Env, deps?: Partial<Deps>): Promise<Response> {
    const now = deps?.now ?? Date.now;
    const jwks = deps?.jwks ?? jwksFor(env.ACCESS_TEAM_DOMAIN);
    const access: AccessConfig = { teamDomain: env.ACCESS_TEAM_DOMAIN, aud: env.ACCESS_AUD, ownerEmail: env.OWNER_EMAIL };
    const auth = await verifyAccessJwt(request.headers.get("Cf-Access-Jwt-Assertion"), access, jwks, now());
    if (!auth.ok) return error(401, "unauthorized");

    const { pathname } = new URL(request.url);
    const method = request.method;
    const isSettings = pathname === "/api/mcp";
    const isRotate = pathname === "/api/mcp/rotate";
    if (!isSettings && !isRotate) return error(404, "not_found");
    const allowed = isSettings ? ["GET", "POST"] : ["POST"];
    if (!allowed.includes(method)) return error(405, "bad_request", { allow: allowed.join(", ") });
    if (method !== "GET" && request.headers.get("Origin") !== env.WEB_ORIGIN) return error(403, "forbidden");

    let body: string | undefined;
    if (method === "POST" && isSettings) {
        if ((request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase() !== "application/json") {
            return error(415, "bad_request");
        }
        if (Number(request.headers.get("content-length") ?? 0) > MAX_BODY_BYTES) return error(400, "bad_request");
        const text = await request.text();
        if (text.length > MAX_BODY_BYTES) return error(400, "bad_request");
        let mode: unknown;
        try {
            mode = (JSON.parse(text) as { mode?: unknown })?.mode;
        } catch {
            return error(400, "bad_request");
        }
        if (mode !== "off" && mode !== "public" && mode !== "private") return error(400, "bad_request");
        body = JSON.stringify({ mode });
    }

    if (!env.COBALT_API_KEY) return error(502, "upstream");
    const headers = new Headers({ "x-cobalt-service": env.COBALT_API_KEY, accept: "application/json" });
    if (body !== undefined) headers.set("content-type", "application/json");
    const path = isRotate ? "/mcp/settings/rotate" : "/mcp/settings";
    let res: Response;
    try {
        res = await env.API.fetch(new Request(API_BASE + path, { method, headers, body }));
    } catch {
        return error(502, "upstream");
    }
    // 401/403 from the API mean the service key is wrong: never an expired login to the page
    if (res.status === 401 || res.status === 403) return error(502, "upstream");
    if (res.status === 409) return error(409, "not_private");
    if (!res.ok) return error(res.status >= 500 ? 502 : res.status, "upstream");
    let answer: unknown;
    try {
        answer = await res.json();
    } catch {
        return error(502, "upstream");
    }
    return json(200, answer);
}
