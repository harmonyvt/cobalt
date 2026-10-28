// `npm run gen` (APP-API-CONTRACT.md 33.13): the checked-in outputs match the registry, and the reply shapes the
// generated clients decode match what the handlers really answer.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { REGISTRY } from "../src/registry/index";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { openApi, outputs, ROUTES_BEGIN, ROUTES_END, swiftClient } from "../scripts/gen";
import { withBatch } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const ROOT = resolve(__dirname, "../../../..");
const read = (p: string) => readFileSync(resolve(ROOT, p), "utf8");

describe("the generated files", () => {
    it("are up to date (run `npm run gen` in deploy/cloudflare/api)", () => {
        const want = outputs(read("deploy/cloudflare/APP-API-CONTRACT.md"));
        expect(read("deploy/cloudflare/api/openapi.json")).toBe(want.openapi);
        expect(read("deploy/cloudflare/APP-API-CONTRACT.md")).toBe(want.contract);
        expect(read("apple/CobaltKit/Sources/CobaltKit/API/Generated/Endpoints.swift")).toBe(want.swift);
    });

    it("list every API route once in openapi.json, and every route in the contract's index", () => {
        const doc = openApi();
        const api = REGISTRY.ops.filter((o) => o.route && (o.route.host ?? "api") === "api");
        const ops = Object.values(doc.paths).flatMap((p: any) => Object.values(p).map((o: any) => o.operationId));
        expect(ops.sort()).toEqual(api.map((o) => o.name).sort());
        const contract = read("deploy/cloudflare/APP-API-CONTRACT.md");
        const table = contract.slice(contract.indexOf(ROUTES_BEGIN), contract.indexOf(ROUTES_END));
        for (const o of REGISTRY.ops.filter((x) => x.route)) expect(table, o.name).toContain(`| \`${o.name}\` |`);
    });

    it("give a typed Swift endpoint per API route, with the path's ids escaped", () => {
        const swift = swiftClient();
        expect(swift).toContain('static func shareCollectionsList() -> APIEndpoint<ShareCollectionsListResponse>');
        expect(swift).toContain('static func libraryIndex() -> APIEndpoint<LibraryIndexResponse>');
        expect(swift).toContain('path: "/library/items/\\(HTTPCobaltClient.encode(id))/file"');
        expect(swift).toContain("var collections: [Lossy<ShareCollection>]");
        expect(swift).toContain("var posts: [Lossy<LibraryPost>]");
    });
});

// ---- the shapes against real answers --------------------------------------------------------------------------------

const API = "https://api.capybaraharmony.com";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const AUTH = { authorization: `Api-Key ${CLIENT}` };
let KEY_HASH = "";
let db: ReturnType<typeof withBatch>;
let env: WorkerEnv;
const container = { fetch: async () => Response.json({ status: "ok" }) };

const call = (path: string, init: RequestInit = {}) =>
    handleRequest(new Request(`${API}${path}`, { ...init, headers: { ...AUTH, ...(init.headers ?? {}) } }), env, container, { now: () => 2_000_000 });

let n = 0;
function item(over: Record<string, unknown> = {}) {
    n++;
    const r = {
        id: `Item${String(n).padStart(12, "0")}`,
        kind: "private",
        source: "saved",
        bucket: "originals",
        r2_key: `originals/sess${n}.mp4`,
        url: null,
        name: `clip ${n}.mp4`,
        content_type: "video/mp4",
        bytes: 4096,
        width: 480,
        height: 560,
        duration: 9.6,
        link: "https://x.com/someone/status/1",
        session_id: null,
        key_id: "key-1",
        created_at: 1_000 + n,
        deleted_at: null,
        poster: null,
        visibility: null,
        public_key: null,
        public_id: null,
        post_key: null,
        ...over,
    };
    db.raw
        .prepare(
            `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at, poster, visibility, public_key, public_id, post_key)
             VALUES (@id,@kind,@source,@bucket,@r2_key,@url,@name,@content_type,@bytes,@width,@height,@duration,@link,@session_id,@key_id,@created_at,@deleted_at,@poster,@visibility,@public_key,@public_id,@post_key)`,
        )
        .run(r as any);
}

describe("the reply shapes match the handlers", () => {
    beforeEach(async () => {
        KEY_HASH ||= await hashKey(CLIENT);
        db = withBatch(createFakeD1());
        db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", KEY_HASH, "0b5f2c3e", 1);
        env = {
            API_URL: `${API}/`,
            CORS_URL: "https://cobalt.capybaraharmony.com",
            COBALT_API_KEY: "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e",
            DB: db as unknown as D1Database,
            ORIGINALS: new MemoryOriginals(),
            MEDIA: new MemoryMedia(),
            MEDIA_BASE_URL: "https://media.capybaraharmony.com/",
            SHARE_BASE_URL: "https://share.capybaraharmony.com/",
        };
    });

    it("GET /library, in every version, empty and with posts", async () => {
        const shape = REGISTRY.op("library.index")!.output!;
        const check = async (q: string) => {
            const r = await call(`/library${q}`);
            expect(r.status).toBe(200);
            const body = await r.json();
            expect(shape.safeParse(body).error?.issues ?? []).toEqual([]);
            return body as any;
        };
        expect((await check("")).posts).toEqual([]);
        item();
        item({ kind: "public", source: "studio", bucket: "media", r2_key: "AbCdEfGh12.webp", url: "https://media.capybaraharmony.com/AbCdEfGh12.webp", content_type: "image/webp", visibility: "public" });
        item({ name: "photo.jpg", content_type: "image/jpeg", duration: null, link: "https://x.com/someone/status/2" });
        for (const q of ["", "?v=2", "?v=3", "?v=3&limit=1"]) {
            const body = await check(q);
            expect(body.posts.length).toBeGreaterThan(0);
        }
        expect((await check("?v=3&limit=1")).next).toEqual(expect.any(String));
    });

    it("GET /share/collections, empty and with collections", async () => {
        const shape = REGISTRY.op("share_collections.list")!.output!;
        const list = async () => {
            const r = await call("/share/collections");
            expect(r.status).toBe(200);
            const body = await r.json();
            expect(shape.safeParse(body).error?.issues ?? []).toEqual([]);
            return body as any;
        };
        expect((await list()).collections).toEqual([]);
        for (const name of ["cats", "dogs"]) {
            const r = await call("/share/collections", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ name }) });
            expect(r.status).toBe(201);
        }
        expect((await list()).collections.map((c: any) => c.name).sort()).toEqual(["cats", "dogs"]);
    });
});
