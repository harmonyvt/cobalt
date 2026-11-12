// /connect/extension: the browser extension's approve page (APP-API-CONTRACT.md section 55).
// Access sits in front of this hostname; the Worker still verifies the Access JWT before anything touches D1,
// the same check as /api/auth. GET only shows a form. POST is the only request that approves.
//
// Chrome (launchWebAuthFlow): the form carries a PKCE challenge, a state and a https://<id>.chromiumapp.org/
// redirect. POST stores an auth_handoffs row (the same table as /api/auth/app) and answers 302 to that redirect
// with a one-time code. The extension trades the code at the API's POST /auth/exchange. The redirect host is
// checked here; it never comes from anywhere but that check.
//
// Safari (no launchWebAuthFlow): the extension has already called POST /auth/extension/begin. The form carries
// that user code. POST marks the pairing approved. The extension's poll mints the session, so this page never
// sees the token.
//
// Codes and tokens are never logged. The page does not read or set the API session; the browser tab only has
// the Access cookie it already had.
import { verifyAccessJwt, type AccessConfig } from "./access";
import { HANDOFF_TTL_MS, newCode } from "./auth";
import { hashKey, jwksFor, type Deps, type Env } from "./keys";
import { extensionDeviceName } from "./sessions";

const CHALLENGE_REGEX = /^[A-Za-z0-9_-]{43}$/;
const STATE_REGEX = /^[A-Za-z0-9_-]{16,128}$/;
const CODE_REGEX = /^[A-Za-z0-9_-]{43}$/;
const MAX_BODY_BYTES = 4096;

// The only redirect a Chrome extension sign-in may use: Chrome's chromiumapp.org host for that extension.
// The id is 32 characters from a-p. No userinfo, no port, no hash, no query, no nested path.
export function chromiumAppRedirect(raw: string): URL | null {
    let u: URL;
    try {
        u = new URL(raw);
    } catch {
        return null;
    }
    if (u.protocol !== "https:") return null;
    if (u.username !== "" || u.password !== "") return null;
    // The URL parser drops the default port, so an explicit :443 has to be refused from the raw string.
    if (u.port !== "" || /:\/\/[^/?#]+:[0-9]+/.test(raw) || u.hash !== "" || u.search !== "") return null;
    if (!/^[a-p]{32}\.chromiumapp\.org$/.test(u.hostname)) return null;
    if (!/^\/[A-Za-z0-9._~-]{0,64}$/.test(u.pathname)) return null;
    return u;
}

const esc = (s: string) =>
    s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

const page = (status: number, title: string, body: string) =>
    new Response(
        `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title>` +
            `<style>body{font-family:-apple-system,system-ui,sans-serif;background:#141414;color:#f4f1ea;margin:0}` +
            `main{max-width:28rem;margin:4rem auto;padding:0 1.25rem}h1{font-size:1.35rem;font-weight:650;letter-spacing:-.02em}` +
            `p{line-height:1.45;color:#d9d3c7}.card{background:#221f1c;border-radius:14px;padding:.9rem 1rem;margin:1.25rem 0}` +
            `.name{font-weight:650}button{appearance:none;border:0;background:#f4f1ea;color:#1a1614;font:inherit;font-weight:650;border-radius:999px;padding:.7rem 1.2rem;cursor:pointer}` +
            `a{color:#f4f1ea}</style></head><body><main><h1>${esc(title)}</h1>${body}</main></body></html>`,
        {
            status,
            headers: {
                "content-type": "text/html; charset=utf-8",
                "cache-control": "no-store",
                "x-content-type-options": "nosniff",
                "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'",
                "referrer-policy": "no-referrer",
                "x-frame-options": "DENY",
            },
        },
    );

const hidden = (name: string, value: string) => `<input type="hidden" name="${esc(name)}" value="${esc(value)}">`;

const consent = (device: string, fields: string) =>
    page(
        200,
        "Save to Capystore",
        `<p>This browser is asking to save posts to your library.</p>` +
            `<div class="card"><div class="name">${esc(device)}</div><p>A device session. You can sign it out later in Settings, under Account.</p></div>` +
            `<form method="post" action="/connect/extension">${fields}<button type="submit">Approve</button></form>` +
            `<p>The extension does not read this site's cookies. Approving gives it its own session, and nothing else.</p>`,
    );

type Mode =
    | { kind: "redirect"; challenge: string; state: string; redirect: URL }
    | { kind: "poll"; userCode: string }
    | { kind: "bad" };

function modeOf(q: URLSearchParams): Mode {
    const userCode = q.get("user_code");
    const challenge = q.get("challenge");
    const state = q.get("state");
    const redirectRaw = q.get("redirect_uri");
    const hasPoll = userCode !== null && userCode !== "";
    const hasRedirect = (challenge ?? "") !== "" || (state ?? "") !== "" || (redirectRaw ?? "") !== "";
    if (hasPoll && hasRedirect) return { kind: "bad" };
    if (hasPoll) {
        if (!userCode || !CODE_REGEX.test(userCode)) return { kind: "bad" };
        return { kind: "poll", userCode };
    }
    if (!hasRedirect) return { kind: "bad" };
    const redirect = redirectRaw ? chromiumAppRedirect(redirectRaw) : null;
    if (!challenge || !CHALLENGE_REGEX.test(challenge) || !state || !STATE_REGEX.test(state) || !redirect) return { kind: "bad" };
    return { kind: "redirect", challenge, state, redirect };
}

export async function handleConnect(request: Request, env: Env, deps?: Partial<Deps>): Promise<Response> {
    const now = deps?.now ?? Date.now;
    const jwks = deps?.jwks ?? jwksFor(env.ACCESS_TEAM_DOMAIN);
    const access: AccessConfig = { teamDomain: env.ACCESS_TEAM_DOMAIN, aud: env.ACCESS_AUD, ownerEmail: env.OWNER_EMAIL };
    const url = new URL(request.url);
    if (url.pathname !== "/connect/extension") {
        return page(404, "not found", "<p>That page is not here.</p>");
    }
    const auth = await verifyAccessJwt(request.headers.get("Cf-Access-Jwt-Assertion"), access, jwks, now());
    if (!auth.ok) {
        return page(401, "not signed in", "<p>Cloudflare Access did not vouch for this request. Close this window and try again from the extension.</p>");
    }
    if (request.method !== "GET" && request.method !== "POST") {
        return page(405, "not found", "<p>Open sign in from the Save to Capystore extension.</p>");
    }
    try {
        if (request.method === "GET") return await show(url.searchParams, request, env, auth.email, now());
        return await approve(request, env, auth.email, now());
    } catch {
        return page(500, "something went wrong", "<p>The sign-in could not be finished. Close this window and try again from the extension.</p>");
    }
}

async function show(q: URLSearchParams, request: Request, env: Env, _email: string, now: number): Promise<Response> {
    const mode = modeOf(q);
    if (mode.kind === "bad") return page(400, "this sign-in link is not right", "<p>Open sign in from the Save to Capystore extension again.</p>");
    const device = extensionDeviceName(request.headers.get("User-Agent"));
    if (mode.kind === "poll") {
        const row = await env.DB.prepare("SELECT approved_at, used_at, expires_at FROM extension_pairings WHERE user_hash = ?1")
            .bind(await hashKey(mode.userCode))
            .first<{ approved_at: number | null; used_at: number | null; expires_at: number }>();
        if (!row || row.used_at || row.expires_at <= now) {
            return page(400, "this sign-in has expired", "<p>Start again from the Save to Capystore extension.</p>");
        }
        if (row.approved_at) return page(200, "already approved", `<p>This sign-in is already approved. You can close this tab.</p><p><a href="/library">Open the library</a></p>`);
        return consent(device, hidden("user_code", mode.userCode));
    }
    return consent(device, hidden("challenge", mode.challenge) + hidden("state", mode.state) + hidden("redirect_uri", mode.redirect.toString()));
}

async function approve(request: Request, env: Env, email: string, now: number): Promise<Response> {
    if (request.headers.get("Origin") !== env.WEB_ORIGIN) {
        return page(403, "not signed in", "<p>That approval did not come from Capystore. Close this window and try again from the extension.</p>");
    }
    const site = request.headers.get("sec-fetch-site");
    if (site && site !== "same-origin") {
        return page(403, "not signed in", "<p>That approval did not come from Capystore. Close this window and try again from the extension.</p>");
    }
    if (Number(request.headers.get("content-length") ?? 0) > MAX_BODY_BYTES) {
        return page(400, "this sign-in link is not right", "<p>Open sign in from the Save to Capystore extension again.</p>");
    }
    const text = await request.text();
    if (text.length > MAX_BODY_BYTES) return page(400, "this sign-in link is not right", "<p>Open sign in from the Save to Capystore extension again.</p>");
    const mode = modeOf(new URLSearchParams(text));
    if (mode.kind === "bad") return page(400, "this sign-in link is not right", "<p>Open sign in from the Save to Capystore extension again.</p>");
    const device = extensionDeviceName(request.headers.get("User-Agent"));
    if (mode.kind === "poll") return approvePoll(env, mode.userCode, device, email, now);
    return approveRedirect(env, mode, device, email, now);
}

async function approvePoll(env: Env, userCode: string, device: string, email: string, now: number): Promise<Response> {
    const hash = await hashKey(userCode);
    const updated = await env.DB.prepare(
        `UPDATE extension_pairings SET approved_at = ?1, email = ?2, device = ?3
         WHERE user_hash = ?4 AND approved_at IS NULL AND used_at IS NULL AND expires_at > ?1
         RETURNING device`,
    )
        .bind(now, email, device, hash)
        .first<{ device: string }>();
    if (updated) {
        return page(200, "approved", `<p>Signed in as ${esc(updated.device)}. You can close this tab and go back to the extension.</p><p><a href="/library">Open the library</a></p>`);
    }
    const row = await env.DB.prepare("SELECT approved_at, used_at, expires_at FROM extension_pairings WHERE user_hash = ?1")
        .bind(hash)
        .first<{ approved_at: number | null; used_at: number | null; expires_at: number }>();
    if (row && row.approved_at && !row.used_at && row.expires_at > now) {
        return page(200, "already approved", `<p>This sign-in is already approved. You can close this tab.</p><p><a href="/library">Open the library</a></p>`);
    }
    return page(400, "this sign-in has expired", "<p>Start again from the Save to Capystore extension.</p>");
}

async function approveRedirect(
    env: Env,
    mode: { challenge: string; state: string; redirect: URL },
    device: string,
    email: string,
    now: number,
): Promise<Response> {
    const code = newCode();
    await env.DB.prepare("DELETE FROM auth_handoffs WHERE expires_at < ?1").bind(now - HANDOFF_TTL_MS).run();
    await env.DB.prepare(
        "INSERT INTO auth_handoffs (code_hash, challenge, device, platform, email, created_at, expires_at) VALUES (?1, ?2, ?3, 'extension', ?4, ?5, ?6)",
    )
        .bind(await hashKey(code), mode.challenge, device, email, now, now + HANDOFF_TTL_MS)
        .run();
    const dest = new URL(mode.redirect.toString());
    dest.searchParams.set("code", code);
    dest.searchParams.set("state", mode.state);
    return new Response(null, {
        status: 302,
        headers: { location: dest.toString(), "cache-control": "no-store", "referrer-policy": "no-referrer" },
    });
}
