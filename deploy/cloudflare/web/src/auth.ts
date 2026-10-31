// /api/auth/*: signing in through Cloudflare Access (APP-API-CONTRACT.md section 42), served by the web Worker.
// Access sits in front of this hostname; the Worker still verifies the Access JWT for the owner's email itself before
// anything touches D1 (the same check as /api/keys).
//  - GET  /api/auth/app (42.3): stores a one-time code (2 minutes, PKCE S256 challenge) and answers 302 to the app's
//    fixed callback cobalt-apple://signed-in?code=<code>. The app trades it at the API's POST /auth/exchange.
//  - POST /api/auth/web (42.4): a new device session for this browser, platform `web`.
// Codes and tokens are never logged; only their SHA-256 is stored.
import { verifyAccessJwt, type AccessConfig } from "./access";
import { hashKey, jwksFor, type Deps, type Env } from "./keys";
import { cleanDevice, countryOf, deviceFromUserAgent, mintSession } from "./sessions";

// Fixed: the scheme and path never come from the request.
export const APP_CALLBACK = "cobalt-apple://signed-in";
export const HANDOFF_TTL_MS = 2 * 60 * 1000;
const APP_PLATFORMS = ["ios", "ipados", "mac"] as const;
const CHALLENGE_REGEX = /^[A-Za-z0-9_-]{43}$/;
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MAX_BODY_BYTES = 1024;

const json = (status: number, body: unknown, extra: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json", "cache-control": "no-store", "x-content-type-options": "nosniff", ...extra },
    });
const error = (status: number, code: string, extra?: Record<string, string>) => json(status, { error: code }, extra);

// The browser-facing pages of GET /api/auth/app: fixed text, nothing from the request in them.
const page = (status: number, title: string, text: string, extra: Record<string, string> = {}) =>
    new Response(
        `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title></head>` +
            `<body style="font-family:-apple-system,system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem"><h1 style="font-size:1.2rem">${title}</h1><p>${text}</p></body></html>`,
        {
            status,
            headers: {
                "content-type": "text/html; charset=utf-8",
                "cache-control": "no-store",
                "x-content-type-options": "nosniff",
                "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'",
                "referrer-policy": "no-referrer",
                ...extra,
            },
        },
    );

const b64url = (bytes: Uint8Array) => {
    let s = "";
    for (const b of bytes) s += String.fromCharCode(b);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

// 32 random bytes, base64url: 43 characters.
export const newCode = () => b64url(crypto.getRandomValues(new Uint8Array(32)));

export async function handleAuth(request: Request, env: Env, deps?: Partial<Deps>): Promise<Response> {
    const now = deps?.now ?? Date.now;
    const jwks = deps?.jwks ?? jwksFor(env.ACCESS_TEAM_DOMAIN);
    const access: AccessConfig = { teamDomain: env.ACCESS_TEAM_DOMAIN, aud: env.ACCESS_AUD, ownerEmail: env.OWNER_EMAIL };
    const url = new URL(request.url);
    const isApp = url.pathname === "/api/auth/app";
    const isWeb = url.pathname === "/api/auth/web";

    // 1. Authenticate. Fails closed on any problem, including JWKS outages.
    const auth = await verifyAccessJwt(request.headers.get("Cf-Access-Jwt-Assertion"), access, jwks, now());
    if (!auth.ok) {
        return isApp ? page(401, "not signed in", "Cloudflare Access did not vouch for this request. Close this window and try again.") : error(401, "unauthorized");
    }

    if (!isApp && !isWeb) return error(404, "not_found");
    const allowed = isApp ? "GET" : "POST";
    if (request.method !== allowed) return error(405, "bad_request", { allow: allowed });

    try {
        if (isApp) return await appSignIn(url, env, auth.email, now());
        // 2. CSRF: only the web app itself may mint a browser session.
        if (request.headers.get("Origin") !== env.WEB_ORIGIN) return error(403, "forbidden");
        return await webSignIn(request, env, auth.email, now());
    } catch {
        return isApp ? page(500, "something went wrong", "The sign-in could not be started. Close this window and try again.") : error(500, "server_error");
    }
}

// GET /api/auth/app?platform=<ios|ipados|mac>&device=<name>&challenge=<base64url(SHA-256(verifier))>
async function appSignIn(url: URL, env: Env, email: string, now: number): Promise<Response> {
    const q = url.searchParams;
    const platform = q.get("platform");
    const device = cleanDevice(q.get("device"));
    const challenge = q.get("challenge");
    if (!platform || !(APP_PLATFORMS as readonly string[]).includes(platform) || device === null || !challenge || !CHALLENGE_REGEX.test(challenge)) {
        return page(400, "this sign-in link is not right", "Open sign in from the cobalt app again.");
    }
    const code = newCode();
    // old handoffs are dead weight once expired: dropped here, so the table stays small
    await env.DB.prepare("DELETE FROM auth_handoffs WHERE expires_at < ?1").bind(now - HANDOFF_TTL_MS).run();
    await env.DB.prepare(
        "INSERT INTO auth_handoffs (code_hash, challenge, device, platform, email, created_at, expires_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    )
        .bind(await hashKey(code), challenge, device, platform, email, now, now + HANDOFF_TTL_MS)
        .run();
    return new Response(null, {
        status: 302,
        headers: { location: `${APP_CALLBACK}?code=${code}`, "cache-control": "no-store", "referrer-policy": "no-referrer" },
    });
}

// POST /api/auth/web, body { "replace"?: "<old token>" } (or empty)
async function webSignIn(request: Request, env: Env, email: string, now: number): Promise<Response> {
    if (Number(request.headers.get("content-length") ?? 0) > MAX_BODY_BYTES) return error(400, "bad_request");
    const text = await request.text();
    if (text.length > MAX_BODY_BYTES) return error(400, "bad_request");
    let replace: string | null = null;
    if (text.trim() !== "") {
        let body: unknown;
        try {
            body = JSON.parse(text);
        } catch {
            return error(400, "bad_request");
        }
        if (typeof body !== "object" || body === null || Array.isArray(body)) return error(400, "bad_request");
        const r = (body as Record<string, unknown>).replace;
        if (r !== undefined && r !== null && typeof r !== "string") return error(400, "bad_request");
        replace = typeof r === "string" ? r : null;
    }
    // The browser re-signing itself in: its old session goes (a key is never revoked here).
    if (replace && UUID_REGEX.test(replace)) {
        await env.DB.prepare("UPDATE api_keys SET revoked_at = ?1 WHERE key_hash = ?2 AND kind = 'session' AND revoked_at IS NULL")
            .bind(now, await hashKey(replace))
            .run();
    }
    const minted = await mintSession(
        env.DB,
        { device: deviceFromUserAgent(request.headers.get("User-Agent")), platform: "web", email, country: countryOf(request) },
        now,
    );
    return json(200, { key: minted.key, session: minted.session });
}
