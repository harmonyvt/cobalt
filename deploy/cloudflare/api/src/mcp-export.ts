// Files an MCP client downloads (APP-API-CONTRACT.md section 63.6): a tool writes a file (a swarm's full results as
// JSON, pictures as data URIs or a sprite) to R2 `cobalt-originals` under exports/, and answers a signed one-hour link,
// GET /mcp/download/<token>, so an agent saves it with one curl instead of paging or re-typing a big answer. The token
// is signed with its own key (an upload link never opens as a download link, nor the other way), names the client key
// (checked again at download time, so revoking the key stops the link) and the R2 key. Exports older than a day are
// deleted when the next one is written. Free of Cloudflare imports: the tests run it under node.
import { b64url, fromB64url } from "./mcp";

export const DOWNLOAD_TTL_MS = 60 * 60 * 1000;
export const EXPORT_KEEP_MS = 24 * 60 * 60 * 1000;
export const DOWNLOAD_TOKEN_REGEX = /^[A-Za-z0-9_-]{16,600}\.[A-Za-z0-9_-]{43}$/;
export const EXPORT_PREFIX = "exports/";

export type DownloadClaims = { k: string; f: string; n: string; e: number };

async function hmac(secret: string, data: string): Promise<Uint8Array> {
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(`capystore-mcp-download:${secret}`), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    return new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data)));
}

export async function signDownloadToken(secret: string, claims: DownloadClaims): Promise<string> {
    const payload = b64url(new TextEncoder().encode(JSON.stringify(claims)));
    return `${payload}.${b64url(await hmac(secret, payload))}`;
}

export async function verifyDownloadToken(secret: string, token: string, now: number): Promise<DownloadClaims | null> {
    if (!DOWNLOAD_TOKEN_REGEX.test(token)) return null;
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
    let c: DownloadClaims;
    try {
        c = JSON.parse(new TextDecoder().decode(fromB64url(payload))) as DownloadClaims;
    } catch {
        return null;
    }
    if (typeof c.k !== "string" || typeof c.f !== "string" || typeof c.n !== "string" || typeof c.e !== "number") return null;
    if (!c.f.startsWith(EXPORT_PREFIX) || c.e <= now) return null;
    return c;
}

type ExportBucket = {
    put(key: string, value: Uint8Array | string, o?: { httpMetadata?: { contentType?: string }; customMetadata?: Record<string, string> }): Promise<unknown>;
    list(o: { prefix: string; limit?: number }): Promise<{ objects: { key: string; uploaded: Date }[] }>;
    delete(keys: string | string[]): Promise<unknown>;
};

export type ExportLink = { url: string; file: string; bytes: number; expires_at: string; curl: string };

const safeName = (n: string) => n.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 80) || "export";

/** Writes an export and answers its download link. Old exports (over a day) go first, a page of them at a time. */
export async function writeExport(
    d: { bucket: ExportBucket; secret: string; now: () => number; origin: string; clientKeyId: string; random?: () => string },
    name: string,
    body: string | Uint8Array,
    contentType: string,
): Promise<ExportLink> {
    const now = d.now();
    try {
        const old = await d.bucket.list({ prefix: EXPORT_PREFIX, limit: 100 });
        const stale = old.objects.filter((o) => now - o.uploaded.getTime() > EXPORT_KEEP_MS).map((o) => o.key);
        if (stale.length > 0) await d.bucket.delete(stale);
    } catch {
        // cleaning up is best effort: the export is written anyway
    }
    const file = safeName(name);
    const id = d.random?.() ?? crypto.randomUUID().replace(/-/g, "");
    const key = `${EXPORT_PREFIX}${id}/${file}`;
    const bytes = typeof body === "string" ? new TextEncoder().encode(body) : body;
    await d.bucket.put(key, bytes, { httpMetadata: { contentType }, customMetadata: { keyId: d.clientKeyId, createdAt: String(now) } });
    const e = now + DOWNLOAD_TTL_MS;
    const token = await signDownloadToken(d.secret, { k: d.clientKeyId, f: key, n: file, e });
    const url = `${d.origin}/mcp/download/${token}`;
    return { url, file, bytes: bytes.length, expires_at: new Date(e).toISOString(), curl: `curl -sS -o ${file} '${url}'` };
}
