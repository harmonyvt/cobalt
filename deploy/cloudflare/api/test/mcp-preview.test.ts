// The signed preview route (MCP-APP-CONTRACT.md section 9): GET /mcp/media/<token>[/poster] plays a private file for a
// widget that has no headers. Valid, expired, tampered, hidden, revoked, wrong mode, Range, HEAD, preflight, CORS.
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { PREVIEW_TTL_MS, signPreviewToken, verifyPreviewToken } from "../src/mcp-preview";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "./d1-batch";
import { fixedLengthPair, MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const NOW = 1_800_000_000_000;
const BYTES = new Uint8Array(Array.from({ length: 200 }, (_, i) => i));

let db: FakeD1;
let env: WorkerEnv;
let originals: MemoryOriginals;
let media: MemoryMedia;
const container = { fetch: async () => Response.json({ status: "error" }, { status: 503 }) };
const send = (req: Request) => handleRequest(req, env, container, { now: () => NOW, sleep: async () => {}, fixedLength: fixedLengthPair });
const tok = (over: Partial<{ k: string; i: string; e: number; p: 0 | 1 }> = {}) => signPreviewToken(INTERNAL, { k: "key-1", i: "PrivVideo", e: NOW + PREVIEW_TTL_MS, p: 0, ...over });
const get = (token: string, init: RequestInit = {}, suffix = "") => send(new Request(`${API}/mcp/media/${token}${suffix}`, init));

const row = (id: string, o: { bucket: string; key: string; poster?: string | null; type?: string }) =>
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, key_id, created_at, poster, visibility, post_key)
             VALUES (?, ?, 'saved', ?, ?, NULL, ?, ?, 200, 720, 1280, 5, NULL, 'k', ?, ?, ?, ?)`,
        )
        .run(id, o.bucket === "media" ? "public" : "private", o.bucket, o.key, `${id}.mp4`, o.type ?? "video/mp4", NOW, o.poster ?? null, o.bucket === "media" ? "public" : "private", id);

beforeEach(async () => {
    db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "agent", await hashKey(CLIENT), "0b5f2c3e", 1);
    originals = new MemoryOriginals();
    media = new MemoryMedia();
    env = { API_URL: `${API}/`, CORS_URL: WEB, COBALT_API_KEY: INTERNAL, DB: db as unknown as D1Database, ORIGINALS: originals, MEDIA: media, MEDIA_BASE_URL: MEDIA, SHARE_BASE_URL: "https://share.capybaraharmony.com/" } as WorkerEnv;
    originals.objects.set("originals/PrivVideo.mp4", { bytes: BYTES, contentType: "video/mp4", meta: {} });
    media.objects.set("PosterP.jpg", { bytes: 4, meta: {}, contentType: "image/jpeg", data: new Uint8Array([1, 2, 3, 4]), viaStream: false });
    row("PrivVideo", { bucket: "originals", key: "originals/PrivVideo.mp4", poster: `${MEDIA}PosterP.jpg` });
});

describe("token", () => {
    it("round-trips, and a changed byte, a wrong secret or a past expiry is null", async () => {
        const t = await tok();
        expect(await verifyPreviewToken(INTERNAL, t, NOW)).toEqual({ k: "key-1", i: "PrivVideo", e: NOW + PREVIEW_TTL_MS, p: 0 });
        expect(await verifyPreviewToken("other-secret", t, NOW)).toBeNull();
        expect(await verifyPreviewToken(INTERNAL, t, NOW + PREVIEW_TTL_MS)).toBeNull();
        const [p, s] = t.split(".");
        expect(await verifyPreviewToken(INTERNAL, `${p}.${s!.slice(0, -1)}${s!.endsWith("A") ? "B" : "A"}`, NOW)).toBeNull();
        // an upload token is not a preview token (separate signing domains)
        expect(await verifyPreviewToken(INTERNAL, "x".repeat(20) + "." + "y".repeat(43), NOW)).toBeNull();
    });
});

describe("GET /mcp/media/<token>", () => {
    it("streams a private file with its type, Range support and open CORS", async () => {
        const res = await get(await tok());
        expect(res.status).toBe(200);
        expect(res.headers.get("content-type")).toBe("video/mp4");
        expect(res.headers.get("accept-ranges")).toBe("bytes");
        expect(res.headers.get("access-control-allow-origin")).toBe("*");
        expect(res.headers.get("cache-control")).toMatch(/no-store/);
        expect(new Uint8Array(await res.arrayBuffer())).toEqual(BYTES);
    });

    it("answers a range with 206 and the right bytes; past the end is 416", async () => {
        const t = await tok();
        const part = await get(t, { headers: { range: "bytes=10-19" } });
        expect(part.status).toBe(206);
        expect(part.headers.get("content-range")).toBe("bytes 10-19/200");
        expect(part.headers.get("content-length")).toBe("10");
        expect(new Uint8Array(await part.arrayBuffer())).toEqual(BYTES.slice(10, 20));
        const tail = await get(t, { headers: { range: "bytes=190-" } });
        expect(tail.status).toBe(206);
        expect(new Uint8Array(await tail.arrayBuffer())).toEqual(BYTES.slice(190));
        expect((await get(t, { headers: { range: "bytes=500-600" } })).status).toBe(416);
    });

    it("HEAD gives the headers and no body; OPTIONS is a CORS preflight for any origin", async () => {
        const t = await tok();
        const head = await get(t, { method: "HEAD" });
        expect(head.status).toBe(200);
        expect(head.headers.get("content-length")).toBe("200");
        expect(await head.text()).toBe("");
        const pre = await get(t, { method: "OPTIONS", headers: { origin: "https://abc.claudemcpcontent.com", "access-control-request-method": "GET", "access-control-request-headers": "range" } });
        expect(pre.status).toBe(204);
        expect(pre.headers.get("access-control-allow-origin")).toBe("*");
        expect((await get(t, { method: "POST" })).status).toBe(405);
    });

    it("the poster comes from the media bucket as image/jpeg; a file with no poster has none", async () => {
        const res = await get(await tok({ p: 1 }), {}, "/poster");
        expect(res.status).toBe(200);
        expect(res.headers.get("content-type")).toBe("image/jpeg");
        expect(new Uint8Array(await res.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3, 4]));
        row("NoPoster", { bucket: "originals", key: "originals/NoPoster.mp4" });
        originals.objects.set("originals/NoPoster.mp4", { bytes: BYTES, contentType: "video/mp4", meta: {} });
        expect((await get(await tok({ i: "NoPoster", p: 1 }), {}, "/poster")).status).toBe(404);
    });

    it("an expired token is 403", async () => {
        const res = await get(await tok({ e: NOW - 1 }));
        expect(res.status).toBe(403);
        expect(res.headers.get("access-control-allow-origin")).toBe("*");
    });

    it("a tampered or forged token is 403 and never reaches the bucket", async () => {
        const t = await tok();
        const [p, s] = t.split(".") as [string, string];
        expect((await get(`${p}.${"A".repeat(43)}`)).status).toBe(403);
        const other = (await tok({ i: "Other" })).split(".")[0]!;
        expect((await get(`${other}.${s}`)).status).toBe(403);
        expect((await get(await signPreviewToken("not-the-secret", { k: "key-1", i: "PrivVideo", e: NOW + 1000, p: 0 }))).status).toBe(403);
        expect(originals.gets).toHaveLength(0);
    });

    it("a poster token never opens the original, and a file token never opens the poster", async () => {
        const poster = await tok({ p: 1 });
        const file = await tok();
        expect((await get(poster)).status).toBe(403);
        expect((await get(file, {}, "/poster")).status).toBe(403);
        expect(originals.gets).toHaveLength(0);
        expect((await get(poster, {}, "/poster")).status).toBe(200);
        expect((await get(file)).status).toBe(200);
        // a token with no p claim (or a bad one) is not valid at all
        const t = await signPreviewToken(INTERNAL, { k: "key-1", i: "PrivVideo", e: NOW + 1000 } as never);
        expect(await verifyPreviewToken(INTERNAL, t, NOW)).toBeNull();
    });

    it("a session key that has expired no longer plays previews", async () => {
        db.raw.prepare("UPDATE api_keys SET expires_at = ?1 WHERE id = 'key-1'").run(NOW - 1);
        expect((await get(await tok())).status).toBe(403);
        db.raw.prepare("UPDATE api_keys SET expires_at = ?1 WHERE id = 'key-1'").run(NOW + 1000);
        expect((await get(await tok())).status).toBe(200);
    });

    it("fails closed (503, nothing served) when the hidden-posts probe cannot be answered", async () => {
        const prepare = (db as any).prepare.bind(db);
        (db as any).prepare = (sql: string) => {
            if (sql.includes("sqlite_master") && sql.includes("media_hidden")) throw new Error("D1 unreachable");
            return prepare(sql);
        };
        const res = await get(await tok());
        expect(res.status).toBe(503);
        expect(originals.gets).toHaveLength(0);
    });

    it("a hidden post is 404 whatever the token says, and so is a deleted file", async () => {
        const t = await tok();
        db.raw.prepare("INSERT INTO media_hidden (post_key, state, by, rule_id, at) VALUES ('PrivVideo', 'hidden', 'you', NULL, ?)").run(NOW);
        expect((await get(t)).status).toBe(404);
        expect((await get(await tok({ p: 1 }), {}, "/poster")).status).toBe(404);
        expect(originals.gets).toHaveLength(0);
        db.raw.prepare("DELETE FROM media_hidden").run();
        expect((await get(t)).status).toBe(200);
        db.raw.prepare("UPDATE media_items SET deleted_at = ? WHERE id = 'PrivVideo'").run(NOW);
        expect((await get(t)).status).toBe(404);
    });

    it("a revoked key stops its previews", async () => {
        const t = await tok();
        expect((await get(t)).status).toBe(200);
        db.raw.prepare("UPDATE api_keys SET revoked_at = ? WHERE id = 'key-1'").run(NOW);
        expect((await get(t)).status).toBe(403);
    });

    it("a public file's bytes come from the public bucket", async () => {
        row("PubVideo", { bucket: "media", key: "NmPub.mp4" });
        media.objects.set("NmPub.mp4", { bytes: 3, meta: {}, contentType: "video/mp4", data: new Uint8Array([9, 8, 7]), viaStream: false });
        const res = await get(await tok({ i: "PubVideo" }));
        expect(new Uint8Array(await res.arrayBuffer())).toEqual(new Uint8Array([9, 8, 7]));
    });
});
