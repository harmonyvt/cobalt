// Signed preview links for the MCP app's widgets (MCP-APP-CONTRACT.md section 9). A widget runs in a sandboxed iframe with no
// headers, so it cannot play a private file. The app tools mint `GET /mcp/media/<token>` (the file) and
// `/mcp/media/<token>/poster` (its poster): the token is an HMAC-signed { client credential, file id, expiry } that lasts
// one hour. Nothing is stored. The file is read from R2 with Range support. A hidden or deleted file is a 404 whatever the
// token says, and the credential that minted it must still be live (revoking the key, or rotating the private link, kills
// its previews). Free of Cloudflare imports (the tests run it under node).
import { b64url, fromB64url } from "./mcp";
import { NOT_HIDDEN_SQL } from "./hidden-store";
import { typeOf } from "./share";
import { streamObject, type ByteBucket } from "./share-private";
import { ITEM_COLUMNS, type MediaRow } from "./visibility";

export const PREVIEW_TTL_MS = 60 * 60 * 1000;
export const PREVIEW_TOKEN_REGEX = /^[A-Za-z0-9_-]{16,400}\.[A-Za-z0-9_-]{43}$/;

// k: the client credential (a key id, or link:<id> for the private link); i: the file id; e: expiry (ms); p: 1 when the
// token opens the file's poster only, 0 when it opens the file itself (a poster token never opens the original)
export type PreviewClaims = { k: string; i: string; e: number; p: 0 | 1 };

async function hmac(secret: string, data: string): Promise<Uint8Array> {
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(`capystore-mcp-preview:${secret}`), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    return new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data)));
}

export async function signPreviewToken(secret: string, claims: PreviewClaims): Promise<string> {
    const payload = b64url(new TextEncoder().encode(JSON.stringify(claims)));
    return `${payload}.${b64url(await hmac(secret, payload))}`;
}

// The token's claims, or null when it is malformed, forged or expired.
export async function verifyPreviewToken(secret: string, token: string, now: number): Promise<PreviewClaims | null> {
    if (!PREVIEW_TOKEN_REGEX.test(token)) return null;
    const [payload, sig] = token.split(".") as [string, string];
    const want = await hmac(secret, payload);
    let got: Uint8Array;
    try {
        got = fromB64url(sig);
    } catch {
        return null;
    }
    if (got.length !== want.length) return null;
    let diff = 0;
    for (let i = 0; i < want.length; i++) diff |= want[i]! ^ got[i]!;
    if (diff !== 0) return null;
    let claims: PreviewClaims;
    try {
        claims = JSON.parse(new TextDecoder().decode(fromB64url(payload))) as PreviewClaims;
    } catch {
        return null;
    }
    if (typeof claims.k !== "string" || typeof claims.i !== "string" || typeof claims.e !== "number") return null;
    if (claims.p !== 0 && claims.p !== 1) return null;
    if (claims.e <= now) return null;
    return claims;
}

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);

// The link of a file's bytes (`poster: false`) or of its poster.
export const previewUrl = (origin: string, token: string, poster = false) => `${origin.replace(/\/+$/, "")}/mcp/media/${token}${poster ? "/poster" : ""}`;

export const PREVIEW_CORS = {
    "access-control-allow-origin": "*",
    "access-control-expose-headers": "content-length, content-range, accept-ranges",
};
const refuse = (status: number) => new Response(status === 404 ? "not found\n" : "forbidden\n", { status, headers: { ...PREVIEW_CORS, "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });

// The live, not hidden file a token names. Fails closed: when the hidden-posts probe cannot be answered this throws (the
// route answers 503) instead of serving a file that might be hidden.
export async function previewRow(db: D1Database, id: string): Promise<MediaRow | null> {
    const probe = await db.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name IN ('media_hidden', 'hidden_rules')").first<{ n: number }>();
    if (!probe) throw new Error("hidden-posts probe unanswered");
    const hidden = Number(probe.n) === 2 ? NOT_HIDDEN_SQL : "";
    const cols = ITEM_COLUMNS.split(", ").map((c) => `m.${c}`).join(", ");
    return (
        (await db
            .prepare(`SELECT ${cols} FROM media_items m WHERE m.id = ?1 AND m.deleted_at IS NULL${hidden}`)
            .bind(id)
            .first<MediaRow>()) ?? null
    );
}

export type PreviewDeps = { db: D1Database; mediaBaseUrl: string; media?: ByteBucket; originals?: ByteBucket };

// The answer to GET /mcp/media/<token>[/poster], once the token and its credential are known good: 404 for a hidden,
// deleted or missing file (or a poster it does not have), else the bytes (Range aware, 206 for a range, 416 past the end).
export async function servePreview(d: PreviewDeps, request: Request, claims: PreviewClaims, poster: boolean): Promise<Response> {
    const row = await previewRow(d.db, claims.i);
    if (!row) return refuse(404);
    let res: Response;
    if (poster) {
        const media = withSlash(d.mediaBaseUrl);
        if (!d.media || !row.poster || !row.poster.startsWith(media)) return refuse(404);
        res = await streamObject(d.media, row.poster.slice(media.length), request, "image/jpeg");
    } else {
        // the bytes live where the row says: a public file in the public bucket, the rest in the private one
        const bucket = row.bucket === "media" ? d.media : d.originals;
        if (!bucket) return refuse(404);
        res = await streamObject(bucket, row.r2_key, request, typeOf(row, row.r2_key));
    }
    const headers = new Headers(res.headers);
    for (const [k, v] of Object.entries(PREVIEW_CORS)) headers.set(k, v);
    return new Response(res.body, { status: res.status, headers });
}

export { refuse as previewRefusal };
