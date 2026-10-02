// cobalt studio page: GET /studio/<sid>. The page is one self-contained HTML
// document (src/studio/page.html, embedded by scripts/build-studio.mjs). The
// session id is a 22-char base62 capability; the page talks to the API Worker
// directly (see ../../STUDIO-CONTRACT.md). Anything else under /studio is a 404.
import { STUDIO_HTML } from "./studio/page.generated";

export const STUDIO_SID = /^\/studio\/[0-9A-Za-z]{22}$/;

// Pinned by STUDIO-CONTRACT.md. No COEP/COOP: the video is cross-origin.
export const STUDIO_CSP =
    "default-src 'self'; connect-src https://api.capybaraharmony.com; " +
    "media-src https://api.capybaraharmony.com blob:; " +
    "img-src 'self' data: blob: https://media.capybaraharmony.com; " +
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " +
    "font-src https://fonts.gstatic.com; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'";

export const studioHeaders = (): Record<string, string> => ({
    "content-type": "text/html; charset=utf-8",
    "content-security-policy": STUDIO_CSP,
    "referrer-policy": "no-referrer",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
});

export async function handleStudio(request: Request, env: { ASSETS: Fetcher }): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (!STUDIO_SID.test(pathname)) return notFound(request, env);
    if (request.method !== "GET" && request.method !== "HEAD") {
        return new Response("method not allowed", {
            status: 405,
            headers: { allow: "GET, HEAD", "cache-control": "no-store" },
        });
    }
    return new Response(request.method === "HEAD" ? null : STUDIO_HTML, {
        status: 200,
        headers: studioHeaders(),
    });
}

// cobalt's own 404 page (the assets' not-found handling), never a 200.
async function notFound(request: Request, env: { ASSETS: Fetcher }): Promise<Response> {
    try {
        const res = await env.ASSETS.fetch(request);
        if (res.status >= 400) return res;
    } catch {
        // fall through to the plain response
    }
    return new Response("not found", {
        status: 404,
        headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" },
    });
}
