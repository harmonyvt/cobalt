import { afterEach, describe, expect, it, vi } from "vitest";
import { z } from "zod";
import { defineOp, OpError, Registry, handleOp, runOp } from "../src/registry/index";
import {
    capture,
    cleanId,
    cronEvent,
    httpSurface,
    opEvent,
    postHogConfig,
    sendBatch,
    telemetryEvents,
    worthSending,
    type FetchLike,
    type MirrorBatch,
} from "../src/posthog";

const SESSION = "019a8ff2-7e99-7000-8000-e0457f33a638";

describe("posthog config", () => {
    it("is off without a token and defaults to US cloud", () => {
        expect(postHogConfig({})).toBeNull();
        expect(postHogConfig({ POSTHOG_PROJECT_TOKEN: "  " })).toBeNull();
        expect(postHogConfig({ POSTHOG_PROJECT_TOKEN: "phc_x" })).toEqual({ token: "phc_x", host: "https://us.i.posthog.com" });
        expect(postHogConfig({ POSTHOG_PROJECT_TOKEN: "phc_x", POSTHOG_HOST: "https://eu.i.posthog.com/" })?.host).toBe("https://eu.i.posthog.com");
    });
});

describe("op events", () => {
    it("tags the app's session and leaves out what it does not know", () => {
        const [e, ...rest] = opEvent(
            { op: "library.list", surface: "app", status: 200, ms: 41.6, keyId: "k1", session: SESSION.toUpperCase(), install: "nope", client: "ios" },
            Date.UTC(2026, 10, 14),
        );
        expect(rest).toEqual([]);
        expect(e.event).toBe("op");
        expect(e.distinct_id).toBe("owner");
        expect(e.timestamp).toBe("2026-11-14T00:00:00.000Z");
        expect(e.properties).toMatchObject({ op: "library.list", surface: "app", status: 200, ms: 42, ok: true, key_id: "k1", $session_id: SESSION, client: "ios" });
        expect(e.properties).not.toHaveProperty("install");
        expect(e.properties).not.toHaveProperty("error_code");
    });

    it("adds an exception for a server failure, not for a refusal", () => {
        const failed = opEvent({ op: "studio.save", surface: "mcp", status: 503, ms: 5, error: "error.api.generic", thread: "t1" }, 0);
        expect(failed.map((e) => e.event)).toEqual(["op", "$exception"]);
        expect(failed[1].properties.$exception_list).toEqual([
            { type: "OpFailed", value: "studio.save answered 503 error.api.generic", mechanism: { handled: true, synthetic: true } },
        ]);
        expect(opEvent({ op: "x", surface: "app", status: 404, ms: 1, error: "error.not_found" }, 0)).toHaveLength(1);
    });

    it("sends public hosts only when they fail, and never /telemetry", () => {
        expect(worthSending({ op: "share.page", surface: "public", status: 200, ms: 1 })).toBe(false);
        expect(worthSending({ op: "share.page", surface: "public", status: 502, ms: 1 })).toBe(true);
        expect(worthSending({ op: "telemetry", surface: "app", status: 202, ms: 1 })).toBe(false);
        expect(worthSending({ op: "library.list", surface: "tool", status: 200, ms: 1 })).toBe(true);
    });

    it("reads the surface from the caller and the app's client header", () => {
        const req = (client?: string) => new Request("https://api.test/", { headers: client ? { "x-capy-client": client } : {} });
        expect(httpSurface("key", req("ios"))).toBe("app");
        expect(httpSurface("key", req("macos"))).toBe("app");
        expect(httpSurface("key", req("web"))).toBe("web");
        expect(httpSurface("key", req())).toBe("tool");
        expect(httpSurface("key", req("evil"))).toBe("tool");
        expect(httpSurface("service", req())).toBe("service");
        expect(httpSurface("open", req("ios"))).toBe("public");
    });

    it("accepts only UUIDs as ids", () => {
        expect(cleanId(SESSION)).toBe(SESSION);
        expect(cleanId("abc")).toBeNull();
        expect(cleanId(null)).toBeNull();
    });
});

describe("telemetry mirror", () => {
    const batch: MirrorBatch = {
        app: { version: "8.7", build: "100", platform: "ios", os: "27.0", device: "iPhone18,1", process: "app" },
        install: SESSION,
        events: [
            { ts: 1, level: "debug", cat: "net", msg: "quiet", data: null },
            { ts: 2, level: "info", cat: "net", msg: "quiet too", data: null },
            { ts: 3, level: "warn", cat: "upload", msg: "slow", data: { ms: 9000 } },
            { ts: 4, level: "error", cat: "pipeline", msg: "save failed", data: { code: "x" } },
        ],
        crashes: [{ ts: 5, kind: "crash", summary: "EXC_BAD_ACCESS in LibraryGrid" }],
    };

    it("keeps warn and error lines and turns crashes into exceptions", () => {
        const out = telemetryEvents(batch, SESSION);
        expect(out.map((e) => e.event)).toEqual(["app_log", "app_log", "$exception"]);
        expect(out[0].properties).toMatchObject({ level: "warn", cat: "upload", msg: "slow", data_ms: 9000, platform: "ios", app_version: "8.7", $session_id: SESSION, install: SESSION });
        expect(out[2].properties).toMatchObject({ source: "app", crash_kind: "crash", $exception_level: "fatal" });
    });
});

describe("cron events", () => {
    it("keeps only flat details", () => {
        const e = cronEvent("daily", 0, 1234.4, true, { cron: "0 3 * * *", nested: { a: 1 } });
        expect(e.event).toBe("cron_run");
        expect(e.properties).toMatchObject({ job: "daily", ms: 1234, ok: true, cron: "0 3 * * *" });
        expect(e.properties).not.toHaveProperty("nested");
    });
});

describe("sending", () => {
    it("posts one batch to /batch/ with the token", async () => {
        const calls: { url: string; body: unknown }[] = [];
        const fetchFn: FetchLike = async (url, init) => {
            calls.push({ url, body: JSON.parse(String(init.body)) });
            return new Response("{}", { status: 200 });
        };
        const ok = await sendBatch({ token: "phc_t", host: "https://us.i.posthog.com" }, [cronEvent("daily", 0, 1, true)], fetchFn);
        expect(ok).toBe(true);
        expect(calls).toHaveLength(1);
        expect(calls[0].url).toBe("https://us.i.posthog.com/batch/");
        expect(calls[0].body).toMatchObject({ api_key: "phc_t", batch: [{ event: "cron_run" }] });
    });

    it("never throws, whatever PostHog does", async () => {
        const cfg = { token: "t", host: "https://h" };
        const ev = [cronEvent("x", 0, 1, true)];
        expect(await sendBatch(cfg, ev, async () => new Response("no", { status: 500 }))).toBe(false);
        expect(await sendBatch(cfg, ev, async () => Promise.reject(new TypeError("network")))).toBe(false);
    });

    it("sends nothing while off, and hands the send to waitUntil when on", async () => {
        let sent = 0;
        const fetchFn: FetchLike = async () => {
            sent++;
            return new Response("{}");
        };
        await capture({}, undefined, [cronEvent("x", 0, 1, true)], fetchFn);
        expect(sent).toBe(0);
        const kept: Promise<unknown>[] = [];
        await capture({ POSTHOG_PROJECT_TOKEN: "t" }, (p) => kept.push(p), [cronEvent("x", 0, 1, true)], fetchFn);
        expect(kept).toHaveLength(1);
        await Promise.all(kept);
        expect(sent).toBe(1);
    });
});

// ---- the hooks: handleOp (HTTP) and runOp (chat / MCP) -------------------------------------------

describe("op hooks", () => {
    afterEach(() => vi.unstubAllGlobals());

    const okOp = defineOp({
        name: "test.ok",
        route: { method: "GET", path: "/test-ok" },
        auth: "open",
        runs: "worker",
        cors: false,
        input: z.object({}),
        ai: { tier: "free", summary: "test" },
        handler: async () => ({ status: 200, body: { status: "success" } }),
    });
    const badOp = defineOp({
        name: "test.bad",
        route: { method: "GET", path: "/test-bad" },
        auth: "open",
        runs: "worker",
        cors: false,
        input: z.object({}),
        ai: { tier: "free", summary: "test" },
        handler: async () => {
            throw new OpError(503, "error.api.generic");
        },
    });
    const registry = new Registry([okOp, badOp]);

    function setup(token: string | undefined) {
        const sent: { event: string; properties: Record<string, unknown> }[][] = [];
        vi.stubGlobal("fetch", async (_url: string, init: RequestInit) => {
            sent.push(JSON.parse(String(init.body)).batch);
            return new Response("{}");
        });
        const kept: Promise<unknown>[] = [];
        const edge = { now: () => 0, waitUntil: (p: Promise<unknown>) => void kept.push(p) };
        const base = { env: token ? { POSTHOG_PROJECT_TOKEN: token } : {}, db: null, now: () => 0, edge, registry } as any;
        return { sent, kept, base };
    }
    const call = (path: string, headers: Record<string, string> = {}) => {
        const request = new Request(`https://api.test${path}`, { headers });
        return { request, url: new URL(request.url), service: false };
    };

    it("sends an op event with the app's session after an HTTP answer, and a failure's code", async () => {
        const { sent, kept, base } = setup("phc_t");
        const res = await handleOp(registry, base, call("/test-ok", { "x-capy-session": SESSION, "x-capy-client": "ios" }));
        expect(res?.status).toBe(200);
        // an open route reads as public: only failures go
        await Promise.all(kept);
        expect(sent).toEqual([]);
        const bad = await handleOp(registry, base, call("/test-bad", { "x-capy-session": SESSION }));
        expect(bad?.status).toBe(503);
        await Promise.all(kept);
        expect(sent.flat().map((e) => e.event)).toEqual(["op", "$exception"]);
        expect(sent[0][0].properties).toMatchObject({ op: "test.bad", status: 503, error_code: "error.api.generic", $session_id: SESSION });
    });

    it("sends nothing without a token and leaves the answer alone", async () => {
        const { sent, kept, base } = setup(undefined);
        const res = await handleOp(registry, base, call("/test-bad"));
        expect(res?.status).toBe(503);
        await Promise.all(kept);
        expect(sent).toEqual([]);
    });

    it("sends chat and MCP calls with their thread, and still throws the refusal", async () => {
        const { sent, kept, base } = setup("phc_t");
        const ctx = { ...base, keyId: "chat:t1", caller: "chat", query: new URLSearchParams(), params: {}, chat: { threadId: "t1", mcp: { origin: "x", clientKeyId: "k" } } };
        await runOp(okOp, ctx, {});
        await expect(runOp(badOp, ctx, {})).rejects.toBeInstanceOf(OpError);
        await Promise.all(kept);
        const events = sent.flat();
        expect(events.map((e) => e.event)).toEqual(["op", "op", "$exception"]);
        expect(events[0].properties).toMatchObject({ op: "test.ok", surface: "mcp", status: 200, thread: "t1", key_id: "chat:t1" });
        expect(events[1].properties).toMatchObject({ op: "test.bad", status: 503, error_code: "error.api.generic" });
    });
});
