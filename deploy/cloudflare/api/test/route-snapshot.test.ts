// The route snapshot (APP-API-CONTRACT.md section 33.1): what the Worker answers for every path the gate knows, every
// method and every kind of caller, pinned in fixtures/route-snapshot.json. The op registry (src/registry/) takes routes
// over one at a time; each move must leave this file unchanged. A PR that ADDS a route adds lines here and nothing else.
//
// One row per request: status, error code, content type, CORS and cache headers, the body's top-level keys, and the
// container call it made (path and key id), if any. The database is empty and fresh for each path, so a keyed route that
// reads data answers its "nothing here" shape.
//
// To regenerate after an intended change: `npx vitest run test/route-snapshot.test.ts -u`, then read the diff.
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { handleRequest, type WorkerEnv } from "../src/worker";
import type { ChatModel, CodeRunner } from "../src/chat";
import { withBatch } from "./d1-batch";
import { MemoryMedia, MemoryOriginals } from "./studio-fakes";

const API = "https://api.capybaraharmony.com";
const WEB = "https://cobalt.capybaraharmony.com";
const MEDIA = "https://media.capybaraharmony.com/";
const SHARE = "https://share.capybaraharmony.com/";
const STAGE = "https://studio.capybaraharmony.com/";
const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const UNKNOWN = "11111111-2222-4333-8444-555555555555";
const NOW = 1_800_000_000_000;

const ID16 = "AbCdEfGh12345678";
const ID20 = "AbCdEfGh1234567890Zz";
const SID = "AbCdEfGh1234567890ZzYy";
const RUN = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";

// Every path family the gate decides on, plus a few that must stay 404.
export const PATHS: string[] = [
    "/",
    `/tunnel?id=a&exp=${NOW + 60_000}&sig=a&sec=a&iv=a`,
    `/tunnel?id=a&exp=${NOW - 60_000}&sig=a&sec=a&iv=a`,
    "/tunnel",
    "/capabilities",
    "/queue",
    "/telemetry",
    "/share/sets",
    "/share/sets/1234567890123456789",
    "/share/sets/bad",
    "/share/collections",
    `/share/collections/${ID16}`,
    `/share/collections/${ID16}/reroll`,
    "/share/collections/bad",
    "/share/groups",
    `/share/groups/${ID16}`,
    "/share/groups/bad",
    "/stage",
    "/stage/rotate",
    "/stage/action",
    "/stage/pool",
    "/stage/redemptions",
    "/stage/twitch",
    "/stage/twitch/connect",
    "/stage/rewards/summon",
    "/stage/rewards/bad",
    "/stage/other",
    "/edits",
    "/edits/renders",
    `/edits/renders/${ID20}`,
    "/edits/renders/bad",
    `/edits/${ID16}`,
    `/edits/${ID16}/render`,
    `/edits/${ID16}/other`,
    "/edits/bad",
    "/chat/threads",
    `/chat/threads/${ID16}`,
    `/chat/threads/${ID16}/messages`,
    `/chat/threads/${ID16}/messages/5/collage`,
    `/chat/threads/${ID16}/messages/5/collage?offset=0&limit=500`,
    `/chat/threads/${ID16}/other`,
    "/chat/threads/bad",
    "/library/adopt",
    "/emotes",
    "/library",
    "/library?limit=5",
    "/library?v=3&limit=bad",
    "/library/search",
    "/library/search?q=cats",
    "/library/search/post",
    `/library/search/post?id=${ID16}`,
    "/library/map",
    "/library/search/index",
    "/library/posters/backfill",
    "/library/visibility/migrate",
    `/library/items/${ID16}`,
    `/library/items/${ID16}/made`,
    `/library/items/${ID16}/file`,
    `/library/items/${ID16}/publish`,
    `/library/items/${ID16}/visibility`,
    `/library/items/${ID16}/studio`,
    `/library/items/${ID16}/studio?queue=maybe`,
    `/library/items/${ID16}/post`,
    `/library/items/${ID16}/other`,
    "/library/items/bad",
    "/library/other",
    "/webp",
    `/webp/${ID20}`,
    "/webp/bad",
    "/media/AbCdEfGh12.webp",
    "/media/bad",
    "/studio",
    "/studio/upload?name=clip.mp4",
    "/studio/recent",
    "/studio/line",
    "/studio/line/notify",
    `/studio/${SID}`,
    `/studio/${SID}/publish`,
    `/studio/${SID}/notify`,
    `/studio/${SID}/source`,
    `/studio/${SID}/render`,
    `/studio/${SID}/line`,
    `/studio/${SID}/slideshow`,
    `/studio/${SID}/gallery-image`,
    `/studio/${SID}/items/retry`,
    `/studio/${SID}/render/${ID20}`,
    `/studio/${SID}/other`,
    "/studio/bad",
    "/live/start-token",
    "/live/selftest",
    `/live/edits/${ID20}`,
    `/live/edits/${ID20}/push`,
    `/live/runs/${RUN}`,
    `/live/runs/${RUN}/state`,
    "/live/other",
    "/nope",
];

const METHODS = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"] as const;

type Caller = { name: string; headers: Record<string, string> };
// Who is asking. "web" is a keyed call from the web app's origin (the CORS header); the OPTIONS-only callers are the
// preflights from the right origin and a wrong one.
const CALLERS: Caller[] = [
    { name: "anon", headers: {} },
    { name: "not_api_key", headers: { authorization: `Bearer ${CLIENT}` } },
    { name: "malformed", headers: { authorization: "Api-Key NOT-A-UUID" } },
    { name: "unknown_key", headers: { authorization: `Api-Key ${UNKNOWN}` } },
    { name: "key", headers: { authorization: `Api-Key ${CLIENT}` } },
    { name: "service", headers: { "x-cobalt-service": INTERNAL } },
    { name: "web", headers: { authorization: `Api-Key ${CLIENT}`, origin: WEB } },
    { name: "web_service", headers: { "x-cobalt-service": INTERNAL, origin: WEB } },
    { name: "other_origin", headers: { authorization: `Api-Key ${CLIENT}`, origin: "https://evil.example" } },
];

// The public hosts answered before the gate: a few rows so a registry change that leaks onto them shows.
const HOST_CASES: { host: string; path: string }[] = [
    { host: SHARE, path: "/AbCdEfGh12" },
    { host: SHARE, path: "/g/1234567890123456789" },
    { host: SHARE, path: "/library" },
    { host: STAGE, path: "/live/abc" },
    { host: STAGE, path: "/store" },
    { host: STAGE, path: "/library" },
];

const model: ChatModel = {
    model: "claude-haiku-5-5",
    async turn() {
        return { content: [{ type: "text", text: "hi" }], stop_reason: "end_turn" };
    },
    async title() {
        return null;
    },
};
const runner: CodeRunner = async () => ({ result: null, logs: [], calls: 0 });

const renderers = {
    idFromName: (n: string) => n,
    get: () => ({ fetch: async () => new Response(null, { status: 202 }) }),
};

let KEY_HASH = "";
const realFetch = globalThis.fetch;
beforeAll(async () => {
    KEY_HASH = await hashKey(CLIENT);
    // nothing in a snapshot run may reach the internet
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
        throw new Error(`no network in the route snapshot: ${String(input instanceof Request ? input.url : input)}`);
    }) as typeof fetch;
});
afterAll(() => {
    globalThis.fetch = realFetch;
});

function freshWorld() {
    const db = withBatch(createFakeD1());
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run("key-1", "test", KEY_HASH, "0b5f2c3e", 1);
    const env: WorkerEnv = {
        API_URL: `${API}/`,
        CORS_URL: WEB,
        COBALT_API_KEY: INTERNAL,
        DB: db as unknown as D1Database,
        ORIGINALS: new MemoryOriginals(),
        MEDIA: new MemoryMedia(),
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
        STAGE_BASE_URL: STAGE,
        EDIT_RENDERER: renderers as unknown as DurableObjectNamespace,
    };
    const calls: string[] = [];
    const container = {
        async fetch(req: Request): Promise<Response> {
            const u = new URL(req.url);
            const key = req.headers.get("x-cobalt-key-id");
            const auth = req.headers.get("authorization");
            calls.push(
                `${req.method} ${u.pathname}${u.search}${key ? ` key=${key}` : ""}${auth ? ` auth=${auth === `Api-Key ${INTERNAL}` ? "internal" : "client"}` : ""}`,
            );
            await req.body?.cancel().catch(() => {});
            if (u.pathname === "/helper/caps") return Response.json({ gallery: true, make: true, direct: true, still: true });
            return Response.json({ status: "ok" });
        },
    };
    return { env, container, calls };
}

async function row(world: ReturnType<typeof freshWorld>, req: Request): Promise<string> {
    world.calls.length = 0;
    let res: Response;
    try {
        res = await handleRequest(req, world.env, world.container, {
            now: () => NOW,
            sleep: async () => {},
            chatModel: model,
            codeRunner: runner,
            stageEmbed: null,
        });
    } catch (e) {
        return `THREW ${e instanceof Error ? e.message : String(e)}`;
    }
    const ct = (res.headers.get("content-type") ?? "").split(";")[0]!.trim();
    let shape = "";
    if (req.method !== "HEAD" && ct === "application/json") {
        const body = await res.json().catch(() => undefined);
        if (body && typeof body === "object" && !Array.isArray(body)) {
            const code = (body as any)?.error?.code;
            shape = `${code ? ` code=${code}` : ""} keys=${Object.keys(body).sort().join(",")}`;
        } else shape = ` body=${JSON.stringify(body)}`;
    } else {
        await res.body?.cancel().catch(() => {});
    }
    const h = (n: string, label: string) => (res.headers.get(n) ? ` ${label}=${res.headers.get(n)}` : "");
    return [
        `${res.status}`,
        ct ? ` ct=${ct}` : "",
        h("access-control-allow-origin", "acao"),
        h("access-control-allow-methods", "acam"),
        h("cache-control", "cc"),
        shape,
        world.calls.length ? ` -> ${world.calls.join(" | ")}` : "",
    ].join("");
}

const bodyFor = (method: string) => (method === "POST" || method === "PUT" || method === "PATCH" ? "{}" : undefined);

export async function snapshotRows(): Promise<Record<string, string>> {
    const out: Record<string, string> = {};
    for (const path of PATHS) {
        const world = freshWorld();
        for (const method of METHODS) {
            for (const caller of CALLERS) {
                const body = bodyFor(method);
                const req = new Request(`${API}${path}`, {
                    method,
                    headers: { ...caller.headers, ...(body ? { "content-type": "application/json" } : {}) },
                    body,
                });
                out[`${method} ${path} [${caller.name}]`] = await row(world, req);
            }
        }
    }
    for (const c of HOST_CASES) {
        const world = freshWorld();
        for (const method of ["GET", "POST", "OPTIONS"]) {
            const req = new Request(`${c.host.replace(/\/$/, "")}${c.path}`, { method, body: bodyFor(method) });
            out[`${method} ${new URL(c.host).hostname}${c.path}`] = await row(world, req);
        }
    }
    return out;
}

describe("the route snapshot", () => {
    it("answers every pinned path, method and caller exactly as before", { timeout: 120_000 }, async () => {
        const rows = await snapshotRows();
        await expect(JSON.stringify(rows, null, 1) + "\n").toMatchFileSnapshot("fixtures/route-snapshot.json");
    });
});
