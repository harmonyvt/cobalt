// src/apns.ts (APP-API-CONTRACT.md 8.4 and 8.6): the ES256 provider token, the
// request headers, the answer table, the logs and the two transports. Node's
// WebCrypto with a generated P-256 key; time is a virtual clock; Apple is a script.
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import {
    APNS_CALL_MS,
    APNS_WAKE_MS,
    APNS_HOSTS,
    ApnsClient,
    JWT_MIN_REFRESH_MS,
    JWT_STORAGE_KEY,
    JWT_REUSE_MS,
    SkippedPush,
    apnsConfigFrom,
    base64url,
    fetchTransport,
    helperTransport,
    livePushConfigured,
    pemToDer,
    type ApnsAnswer,
    type ApnsPush,
    type ApnsRequest,
    type Transport,
    type TransportMeta,
} from "../src/apns";
import { Clock, MemoryKV } from "./studio-fakes";

const TOKEN = "ab".repeat(32); // 64 hex
const RUN = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const KEY_ID = "ABC123DEFG";
const TEAM_ID = "TEAM123456";
const BUNDLE = "com.capybaraharmony.cobalt";

let pem: string;
let publicKey: CryptoKey;

beforeAll(async () => {
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
    publicKey = pair.publicKey;
    const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
    let b64 = btoa(String.fromCharCode(...der));
    b64 = b64.match(/.{1,64}/g)!.join("\n");
    pem = `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`;
});

const ok = (apnsId = "APNS-ID-1"): ApnsAnswer => ({ status: 200, reason: null, apnsId });
const bad = (status: number, reason: string | null): ApnsAnswer => ({ status, reason, apnsId: null });

// Apple, scripted: each call takes the next answer (a function may inspect the request).
class Apple {
    calls: { req: ApnsRequest; meta: TransportMeta }[] = [];
    constructor(public script: (ApnsAnswer | Error | ((r: ApnsRequest, n: number) => ApnsAnswer | Promise<ApnsAnswer>))[] = []) {}
    transport: Transport = async (req, meta) => {
        const n = this.calls.length;
        this.calls.push({ req, meta });
        const step = this.script[Math.min(n, this.script.length - 1)] ?? ok();
        if (step instanceof Error) throw step;
        return typeof step === "function" ? step(req, n) : step;
    };
    get hosts() {
        return this.calls.map((c) => c.req.host);
    }
}

function make(apple: Apple, over: Partial<ConstructorParameters<typeof ApnsClient>[0]> = {}) {
    const clock = new Clock();
    const lines: string[] = [];
    const client = new ApnsClient({
        keyP8: pem,
        keyId: KEY_ID,
        teamId: TEAM_ID,
        bundleId: BUNDLE,
        via: "worker",
        transport: apple.transport,
        now: clock.now,
        log: (l) => lines.push(l),
        ...over,
    });
    return { client, clock, lines };
}

const push = (over: Partial<ApnsPush> = {}): ApnsPush => ({
    event: "update",
    priority: 10,
    expiration: 1_800_003_600,
    payload: { aps: { timestamp: 1_800_000_000, event: "update", "content-state": { stage: "fetching" } } },
    ...over,
});

const decodeJwt = (jwt: string) => {
    const [h, c, s] = jwt.split(".");
    const dec = (x: string) => JSON.parse(atob(x.replace(/-/g, "+").replace(/_/g, "/")));
    return { header: dec(h!), claims: dec(c!), signed: `${h}.${c}`, sig: s! };
};
const bearer = (req: ApnsRequest) => req.headers.authorization!.replace(/^bearer /, "");

describe("configuration", () => {
    const full = { APNS_KEY_P8: "p8", APNS_KEY_ID: "k", APNS_TEAM_ID: "t" };
    it("is configured only when all three secrets are non-empty strings", () => {
        expect(apnsConfigFrom(full)).toMatchObject({ keyP8: "p8", keyId: "k", teamId: "t", bundleId: BUNDLE, via: "worker" });
        expect(livePushConfigured(full)).toBe(true);
        for (const missing of ["APNS_KEY_P8", "APNS_KEY_ID", "APNS_TEAM_ID"]) {
            expect(livePushConfigured({ ...full, [missing]: undefined })).toBe(false);
            expect(livePushConfigured({ ...full, [missing]: "" })).toBe(false);
            expect(livePushConfigured({ ...full, [missing]: "   " })).toBe(false);
            expect(livePushConfigured({ ...full, [missing]: 5 })).toBe(false);
        }
        expect(livePushConfigured({})).toBe(false);
    });
    it("APNS_VIA picks the transport (worker by default), APNS_BUNDLE_ID overrides the bundle id", () => {
        expect(apnsConfigFrom({ ...full, APNS_VIA: "helper" })?.via).toBe("helper");
        expect(apnsConfigFrom({ ...full, APNS_VIA: " Helper " })?.via).toBe("helper");
        expect(apnsConfigFrom({ ...full, APNS_VIA: "worker" })?.via).toBe("worker");
        expect(apnsConfigFrom({ ...full, APNS_VIA: "nonsense" })?.via).toBe("worker");
        expect(apnsConfigFrom({ ...full, APNS_BUNDLE_ID: "com.example.app" })?.bundleId).toBe("com.example.app");
    });
});

describe("the provider token (ES256)", () => {
    it("has the pinned header and claims and a signature that verifies with the public key", async () => {
        const apple = new Apple();
        const { client, clock } = make(apple);
        await client.deliver(TOKEN, "sandbox", push(), RUN);
        const jwt = bearer(apple.calls[0]!.req);
        const { header, claims, signed, sig } = decodeJwt(jwt);
        expect(header).toEqual({ alg: "ES256", kid: KEY_ID });
        expect(claims).toEqual({ iss: TEAM_ID, iat: Math.floor(clock.t / 1000) });
        const raw = Uint8Array.from(atob(sig.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
        expect(raw.length).toBe(64); // raw r||s, not DER
        expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, raw, new TextEncoder().encode(signed))).toBe(true);
        // a different message does not verify
        expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, raw, new TextEncoder().encode(`${signed}x`))).toBe(false);
        expect(jwt).not.toMatch(/[+/=]/); // base64url, no padding
    });

    it("accepts the PEM with real newlines or with literal backslash-n (a doubly escaped secrets file)", async () => {
        const apple = new Apple();
        const { client } = make(apple, { keyP8: pem.replace(/\n/g, "\\n") });
        expect((await client.deliver(TOKEN, "sandbox", push(), RUN)).kind).toBe("sent");
        expect(pemToDer(pem).length).toBe(pemToDer(pem.replace(/\n/g, "\\n")).length);
    });

    it("is reused for 50 minutes and signed again after", async () => {
        const apple = new Apple();
        const { client, clock } = make(apple);
        await client.deliver(TOKEN, "sandbox", push(), RUN);
        clock.t += JWT_REUSE_MS - 1000;
        await client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(bearer(apple.calls[1]!.req)).toBe(bearer(apple.calls[0]!.req));
        clock.t += 1000;
        await client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(bearer(apple.calls[2]!.req)).not.toBe(bearer(apple.calls[0]!.req));
        expect(decodeJwt(bearer(apple.calls[2]!.req)).claims.iat).toBe(Math.floor(clock.t / 1000));
    });

    it("never signs again within 20 minutes, except once after 403 ExpiredProviderToken", async () => {
        const apple = new Apple([bad(403, "ExpiredProviderToken"), ok()]);
        const { client, clock } = make(apple);
        clock.t += 0;
        const first = await client.deliver(TOKEN, "sandbox", push(), RUN); // minted at t
        // the first answer was Expired -> one fresh token, one retry (the same push)
        expect(first.kind).toBe("sent");
        expect(apple.calls).toHaveLength(2);
        expect(bearer(apple.calls[1]!.req)).not.toBe(bearer(apple.calls[0]!.req));
        // later pushes within 20 minutes reuse the refreshed token
        clock.t += JWT_MIN_REFRESH_MS - 1000;
        await client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(bearer(apple.calls[2]!.req)).toBe(bearer(apple.calls[1]!.req));
    });

    it("a second ExpiredProviderToken on the same push is a failure, not a loop (one re-sign, one retry)", async () => {
        const apple = new Apple([bad(403, "ExpiredProviderToken")]);
        const { client } = make(apple);
        const r = await client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(apple.calls).toHaveLength(2);
        expect(r).toMatchObject({ kind: "unhealthy", status: 403, reason: "ExpiredProviderToken" });
    });

    it("an Expired answer right after a forced re-sign (inside 20 minutes) does not sign a third time", async () => {
        const apple = new Apple([bad(403, "ExpiredProviderToken")]);
        const { client, clock } = make(apple);
        await client.deliver(TOKEN, "sandbox", push(), RUN); // sign, expired, forced re-sign, expired again
        const before = apple.calls.length;
        clock.t += 60_000;
        const r = await client.deliver(TOKEN, "sandbox", push(), RUN);
        // the token in use was forced a minute ago: Expired again gets no new token
        expect(apple.calls.length - before).toBe(1);
        expect(r.kind).toBe("unhealthy");
    });

    it("concurrent pushes share one signing", async () => {
        const apple = new Apple();
        const { client } = make(apple);
        await Promise.all([1, 2, 3].map(() => client.deliver(TOKEN, "sandbox", push(), RUN)));
        expect(new Set(apple.calls.map((c) => bearer(c.req))).size).toBe(1);
    });

    it("an unusable key is an unhealthy delivery with a jwt reason (never throws, never names the key)", async () => {
        const apple = new Apple();
        const { client, lines } = make(apple, { keyP8: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----" });
        const r = await client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(r).toMatchObject({ kind: "unhealthy", status: 0 });
        expect((r as { reason: string }).reason).toMatch(/^jwt: /);
        expect(apple.calls).toHaveLength(0);
        expect(lines.join("\n")).not.toContain("AAAA");
    });
});

describe("the request", () => {
    it.each([
        ["sandbox", "api.sandbox.push.apple.com"],
        ["production", "api.push.apple.com"],
    ] as const)("%s: the host, path and exact headers", async (env, host) => {
        const apple = new Apple();
        const { client } = make(apple);
        await client.deliver(TOKEN, env, push({ priority: 5, expiration: 1_800_000_060 }), RUN);
        const { req, meta } = apple.calls[0]!;
        expect(APNS_HOSTS[env]).toBe(host);
        expect(req.host).toBe(host);
        expect(req.path).toBe(`/3/device/${TOKEN}`);
        expect(Object.keys(req.headers).sort()).toEqual(
            ["apns-expiration", "apns-priority", "apns-push-type", "apns-topic", "authorization", "content-type"],
        );
        expect(req.headers).toMatchObject({
            "apns-topic": "com.capybaraharmony.cobalt.push-type.liveactivity",
            "apns-push-type": "liveactivity",
            "apns-priority": "5",
            "apns-expiration": "1800000060",
            "content-type": "application/json",
        });
        expect(req.headers.authorization).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
        expect(JSON.parse(req.body)).toEqual(push().payload);
        expect(meta).toEqual({ event: "update", wake: false });
    });
    it("the topic follows APNS_BUNDLE_ID, and start / end wake a sleeping relay", async () => {
        const apple = new Apple();
        const { client } = make(apple, { bundleId: "com.example.app" });
        await client.deliver(TOKEN, "production", push({ event: "start" }), RUN);
        await client.deliver(TOKEN, "production", push({ event: "end" }), RUN);
        expect(apple.calls[0]!.req.headers["apns-topic"]).toBe("com.example.app.push-type.liveactivity");
        expect(apple.calls.map((c) => c.meta)).toEqual([
            { event: "start", wake: true },
            { event: "end", wake: true },
        ]);
    });
});

describe("the answer table", () => {
    it("200: sent, with the environment it was accepted on and the apns-id", async () => {
        const apple = new Apple([ok("ID-9")]);
        const { client } = make(apple);
        expect(await client.deliver(TOKEN, "sandbox", push(), RUN)).toEqual({ kind: "sent", env: "sandbox", status: 200, apnsId: "ID-9" });
    });

    it("400 BadDeviceToken retries once on the other host; a 200 there is remembered (the delivery says which environment)", async () => {
        const apple = new Apple([bad(400, "BadDeviceToken"), ok()]);
        const { client } = make(apple);
        const r = await client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(apple.hosts).toEqual(["api.sandbox.push.apple.com", "api.push.apple.com"]);
        expect(r).toMatchObject({ kind: "sent", env: "production" });
        // and the other way round
        const apple2 = new Apple([bad(400, "BadDeviceToken"), ok()]);
        const r2 = await make(apple2).client.deliver(TOKEN, "production", push(), RUN);
        expect(apple2.hosts).toEqual(["api.push.apple.com", "api.sandbox.push.apple.com"]);
        expect(r2).toMatchObject({ kind: "sent", env: "sandbox" });
    });
    it("BadDeviceToken on both hosts drops the token (and tries exactly twice)", async () => {
        const apple = new Apple([bad(400, "BadDeviceToken")]);
        const r = await make(apple).client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(apple.calls).toHaveLength(2);
        expect(r).toMatchObject({ kind: "drop", status: 400, reason: "BadDeviceToken" });
    });
    it("the host retry that meets another failure is judged by that failure", async () => {
        const apple = new Apple([bad(400, "BadDeviceToken"), bad(500, null)]);
        expect((await make(apple).client.deliver(TOKEN, "sandbox", push(), RUN)).kind).toBe("unhealthy");
    });

    it("410 (any reason) and 400 ExpiredToken drop the token", async () => {
        for (const a of [bad(410, "Unregistered"), bad(410, null), bad(410, "ExpiredToken"), bad(400, "ExpiredToken"), bad(400, "DeviceTokenNotForTopic")]) {
            const apple = new Apple([a]);
            const r = await make(apple).client.deliver(TOKEN, "sandbox", push(), RUN);
            expect(r.kind).toBe("drop");
            expect(apple.calls).toHaveLength(1);
        }
    });

    it("403 other than ExpiredProviderToken, 5xx and unlisted failures are unhealthy (pushing false for 10 minutes)", async () => {
        for (const a of [bad(403, "InvalidProviderToken"), bad(403, "TopicDisallowed"), bad(403, null), bad(500, null), bad(503, "ServiceUnavailable"), bad(400, "BadTopic"), bad(413, "PayloadTooLarge")]) {
            const r = await make(new Apple([a])).client.deliver(TOKEN, "sandbox", push(), RUN);
            expect(r).toMatchObject({ kind: "unhealthy", status: a.status });
        }
    });

    it("a network error and the transport ceiling are unhealthy with a 'transport:' reason", async () => {
        const down = await make(new Apple([new Error("Network connection lost.")])).client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(down).toMatchObject({ kind: "unhealthy", status: 0, reason: "transport: Network connection lost." });

        const hang: Transport = () => new Promise(() => {});
        const { client } = make(new Apple(), { transport: hang, callMs: 20 });
        const t0 = Date.now();
        const r = await client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(Date.now() - t0).toBeLessThan(1000);
        expect(r).toMatchObject({ kind: "unhealthy", status: 0, reason: "transport: timed out" });
        expect(APNS_CALL_MS).toBeLessThan(3000); // inside the studio's LIVE_PUSH_MS
    });

    it("429 changes nothing (the next event retries)", async () => {
        const r = await make(new Apple([bad(429, "TooManyRequests")])).client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(r).toMatchObject({ kind: "quiet", status: 429 });
    });

    it("a counter the helper transport skips (container asleep) is quiet: nothing recorded", async () => {
        const skip: Transport = async () => {
            throw new SkippedPush("container asleep");
        };
        const r = await make(new Apple(), { transport: skip }).client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(r).toMatchObject({ kind: "quiet", status: 0 });
    });
});

describe("logs", () => {
    afterEach(() => vi.restoreAllMocks());

    it("one line per push: status, reason, event, priority, run and token prefixes, apns-id", async () => {
        const apple = new Apple([ok("A-B-C")]);
        const { client, lines } = make(apple);
        await client.deliver(TOKEN, "sandbox", push({ priority: 5 }), RUN);
        expect(lines).toEqual([`[live] apns 200 - event=update pri=5 run=0b5f2c3e token=${TOKEN.slice(0, 8)} apns-id=A-B-C`]);
        const apple2 = new Apple([bad(403, "InvalidProviderToken")]);
        const m2 = make(apple2);
        await m2.client.deliver(TOKEN, "production", push({ event: "end" }), RUN);
        expect(m2.lines[0]).toBe(`[live] apns 403 InvalidProviderToken event=end pri=10 run=0b5f2c3e token=${TOKEN.slice(0, 8)} apns-id=-`);
    });

    it("no console line ever contains the device token, the jwt or the key", async () => {
        const spies = (["log", "info", "warn", "error", "debug"] as const).map((m) => vi.spyOn(console, m).mockImplementation(() => {}));
        const apple = new Apple([
            ok(),
            bad(400, "BadDeviceToken"),
            ok(),
            bad(403, "ExpiredProviderToken"),
            ok(),
            new Error(`connect failed for https://api.push.apple.com/3/device/${TOKEN}`),
            bad(410, null),
            bad(500, null),
        ]);
        const jwts = new Set<string>();
        // default logger (console.log) on purpose
        const clock = new Clock();
        const client = new ApnsClient({
            keyP8: pem, keyId: KEY_ID, teamId: TEAM_ID, bundleId: BUNDLE, via: "worker", now: clock.now,
            transport: async (req, meta) => {
                jwts.add(bearer(req));
                return apple.transport(req, meta);
            },
        });
        for (let i = 0; i < 6; i++) await client.deliver(TOKEN, "sandbox", push(), RUN);
        await client.selftest({}, 1);
        const out = spies.flatMap((s) => s.mock.calls.map((c) => c.map(String).join(" "))).join("\n");
        expect(out).toContain("[live] apns");
        expect(out).not.toContain(TOKEN);
        for (const j of jwts) {
            expect(out).not.toContain(j);
            expect(out).not.toContain(j.split(".")[2]!);
        }
        const body = pem.split("\n").slice(1, 3).join("");
        expect(out).not.toContain(body.slice(0, 20));
        expect(out).not.toContain("BEGIN PRIVATE KEY");
        // the transport error that carried the token is scrubbed to its prefix
        expect(out).toContain(`transport: connect failed for https://api.push.apple.com/3/device/${TOKEN.slice(0, 8)}`);
    });
});

describe("selftest (8.6)", () => {
    const payload = { aps: { event: "update" } };

    it("one update to the SANDBOX host for the token of 64 zeros, with the real topic; no retry on the other host", async () => {
        const apple = new Apple([bad(400, "BadDeviceToken")]);
        const { client } = make(apple);
        const r = await client.selftest(payload, 1_800_000_060);
        expect(apple.calls).toHaveLength(1);
        const { req } = apple.calls[0]!;
        expect(req.host).toBe("api.sandbox.push.apple.com");
        expect(req.path).toBe(`/3/device/${"0".repeat(64)}`);
        expect(req.headers["apns-topic"]).toBe("com.capybaraharmony.cobalt.push-type.liveactivity");
        expect(req.headers["apns-push-type"]).toBe("liveactivity");
        expect(JSON.parse(req.body)).toEqual(payload);
        expect(r).toEqual({
            transport: "worker",
            host: "api.sandbox.push.apple.com",
            jwt: "ok",
            apns_status: 400,
            apns_reason: "BadDeviceToken",
        });
        expect(JSON.stringify(r)).not.toMatch(/bearer|ey[A-Za-z0-9]{10}/);
    });
    it("a network error is a 'transport:' reason with no status", async () => {
        const { client } = make(new Apple([new Error("fetch failed")]));
        expect(await client.selftest(payload, 1)).toMatchObject({ jwt: "ok", apns_status: null, apns_reason: "transport: fetch failed" });
    });
    it("InvalidProviderToken and TopicDisallowed come back as Apple said them", async () => {
        expect(await make(new Apple([bad(403, "InvalidProviderToken")])).client.selftest(payload, 1)).toMatchObject({ apns_status: 403, apns_reason: "InvalidProviderToken" });
        expect(await make(new Apple([bad(400, "TopicDisallowed")])).client.selftest(payload, 1)).toMatchObject({ apns_reason: "TopicDisallowed" });
    });
    it("an unusable key reports jwt: error and sends nothing", async () => {
        const apple = new Apple();
        const { client } = make(apple, { keyP8: "garbage" });
        expect(await client.selftest(payload, 1)).toMatchObject({ jwt: "error", apns_status: null });
        expect(apple.calls).toHaveLength(0);
    });
    it("reports the transport it used", async () => {
        const { client } = make(new Apple([bad(400, "BadDeviceToken")]), { via: "helper" });
        expect((await client.selftest(payload, 1)).transport).toBe("helper");
    });
});

describe("fetchTransport (the worker way)", () => {
    it("POSTs to https://<host><path> with the headers and body and reads status, reason and apns-id", async () => {
        const seen: { url: string; init: RequestInit }[] = [];
        const t = fetchTransport(async (url, init) => {
            seen.push({ url, init });
            return new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400, headers: { "apns-id": "X-1" } });
        });
        const req: ApnsRequest = { host: "api.push.apple.com", path: "/3/device/ab", headers: { authorization: "bearer t" }, body: "{}" };
        expect(await t(req, { event: "update", wake: false })).toEqual({ status: 400, reason: "BadDeviceToken", apnsId: "X-1" });
        expect(seen[0]!.url).toBe("https://api.push.apple.com/3/device/ab");
        expect(seen[0]!.init).toMatchObject({ method: "POST", headers: { authorization: "bearer t" }, body: "{}" });
    });
    it("a 200 with an empty body is a plain success", async () => {
        const t = fetchTransport(async () => new Response(null, { status: 200, headers: { "apns-id": "OK-2" } }));
        expect(await t({ host: "h", path: "/p", headers: {}, body: "" }, { event: "end", wake: true })).toEqual({ status: 200, reason: null, apnsId: "OK-2" });
    });
});

describe("helperTransport (APNS_VIA=helper)", () => {
    const req: ApnsRequest = { host: "api.push.apple.com", path: "/3/device/ab", headers: { authorization: "bearer t" }, body: '{"a":1}' };
    function relay(running: boolean, answer: () => Response = () => new Response(JSON.stringify({ status: 200, reason: null, apns_id: "H-1" }))) {
        const helperCalls: { path: string; init?: RequestInit }[] = [];
        const wakes: number[] = [];
        const t = helperTransport({
            helper: async (path, init) => {
                helperCalls.push({ path, init });
                return answer();
            },
            isRunning: () => running,
            ensureRunning: async () => {
                wakes.push(1);
                running = true;
            },
        });
        return { t, helperCalls, wakes };
    }

    it("posts {host, path, headers, body} to the helper's /apns and maps the answer", async () => {
        const { t, helperCalls } = relay(true);
        expect(await t(req, { event: "update", wake: false })).toEqual({ status: 200, reason: null, apnsId: "H-1" });
        expect(helperCalls).toHaveLength(1);
        expect(helperCalls[0]!.path).toBe("/apns");
        expect(JSON.parse(helperCalls[0]!.init!.body as string)).toEqual({ host: req.host, path: req.path, headers: req.headers, body: req.body });
    });
    it("a counter while the container sleeps is skipped; start and end wake it in `prepare` (not in the attempt)", async () => {
        const asleep = relay(false);
        await expect(asleep.t.prepare!({ event: "update", wake: false })).rejects.toBeInstanceOf(SkippedPush);
        await expect(asleep.t(req, { event: "update", wake: false })).rejects.toBeInstanceOf(SkippedPush);
        expect(asleep.helperCalls).toHaveLength(0);
        expect(asleep.wakes).toHaveLength(0);

        const start = relay(false);
        await start.t.prepare!({ event: "start", wake: true });
        expect(start.wakes).toHaveLength(1);
        await start.t(req, { event: "start", wake: true });
        expect(start.wakes).toHaveLength(1); // the attempt itself never wakes anything
        expect(start.helperCalls).toHaveLength(1);
    });
    it("a relay that errors or answers without a status is a transport failure", async () => {
        await expect(relay(true, () => new Response("nope", { status: 502 })).t(req, { event: "update", wake: false })).rejects.toThrow(/502/);
        await expect(relay(true, () => new Response("{}")).t(req, { event: "update", wake: false })).rejects.toThrow(/status/);
    });
    it("through the client: Apple's answer drives the same table, and a skip is quiet", async () => {
        const answer = () => new Response(JSON.stringify({ status: 400, reason: "BadDeviceToken", apns_id: null }));
        const { t, helperCalls } = relay(true, answer);
        const { client } = make(new Apple(), { transport: t, via: "helper" });
        const r = await client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(r.kind).toBe("drop");
        expect(helperCalls).toHaveLength(2); // sandbox, then production
        const asleep = relay(false);
        const q = await make(new Apple(), { transport: asleep.t, via: "helper" }).client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(q.kind).toBe("quiet");
    });
});

// ---- review fixes (2026-10-02) ----------------------------------------------------------

describe("helper transport: the cold start is outside the per-attempt ceiling (finding 1)", () => {
    const req: ApnsRequest = { host: "api.push.apple.com", path: "/3/device/ab", headers: {}, body: "{}" };
    const sleepMs = (ms: number) => new Promise((r) => setTimeout(r, ms));
    function cold(opts: { wakeMs: number | "never"; relayMs?: number }) {
        let running = false;
        const helperCalls: string[] = [];
        const t = helperTransport({
            isRunning: () => running,
            ensureRunning: async () => {
                if (opts.wakeMs === "never") return new Promise<void>(() => {});
                await sleepMs(opts.wakeMs);
                running = true;
            },
            helper: async (path) => {
                helperCalls.push(path);
                if (opts.relayMs) await sleepMs(opts.relayMs);
                return new Response(JSON.stringify({ status: 200, reason: null, apns_id: "H-1" }));
            },
        });
        return { t, helperCalls };
    }

    it("a container that takes longer to wake than the per-attempt ceiling still gets the push, once, and the key stays healthy", async () => {
        const { t, helperCalls } = cold({ wakeMs: 150 });
        // callMs 40 ms stands for APNS_CALL_MS (2.5 s); the wake takes 150 ms > 40 ms
        const { client } = make(new Apple(), { transport: t, via: "helper", callMs: 40, wakeMs: 2000 });
        for (const event of ["start", "end"] as const) {
            const r = await client.deliver(TOKEN, "sandbox", push({ event }), RUN);
            expect(r.kind, event).toBe("sent");
            if (event === "start") expect(helperCalls).toEqual(["/apns"]);
        }
        expect(helperCalls).toEqual(["/apns", "/apns"]);
    });

    it("the per-attempt ceiling still bounds the relay itself after the wake (outcome unknown: maybeDelivered)", async () => {
        const { t } = cold({ wakeMs: 5, relayMs: 300 });
        const { client } = make(new Apple(), { transport: t, via: "helper", callMs: 40, wakeMs: 2000 });
        const r = await client.deliver(TOKEN, "sandbox", push({ event: "start" }), RUN);
        expect(r).toMatchObject({ kind: "unhealthy", status: 0, reason: "transport: timed out", maybeDelivered: true });
    });

    it("a wake that outlasts its own budget is unhealthy 'wake: timed out' and provably sent nothing", async () => {
        const { t, helperCalls } = cold({ wakeMs: "never" });
        const { client, lines } = make(new Apple(), { transport: t, via: "helper", callMs: 40, wakeMs: 30 });
        const r = await client.deliver(TOKEN, "sandbox", push({ event: "start" }), RUN);
        expect(r).toMatchObject({ kind: "unhealthy", status: 0, reason: "wake: timed out", maybeDelivered: false });
        expect(helperCalls).toEqual([]);
        expect(lines).toHaveLength(1);
        expect(lines[0]).not.toContain(TOKEN);
    });

    it("the wake budget is 30 s and the per-attempt ceiling stays under the studio's 3 s hook ceiling", () => {
        expect(APNS_WAKE_MS).toBe(30_000);
        expect(APNS_CALL_MS).toBeLessThan(3000);
    });

    it("the self-test wakes the container in prepare too, and reports a failed wake as the reason", async () => {
        const ok = cold({ wakeMs: 100 });
        const a = make(new Apple(), { transport: ok.t, via: "helper", callMs: 40, wakeMs: 2000 });
        expect(await a.client.selftest({}, 1)).toMatchObject({ jwt: "ok", apns_status: 200 });
        const never = cold({ wakeMs: "never" });
        const b = make(new Apple(), { transport: never.t, via: "helper", callMs: 40, wakeMs: 30 });
        expect(await b.client.selftest({}, 1)).toMatchObject({ jwt: "ok", apns_status: null, apns_reason: "wake: timed out" });
    });

    it("maybeDelivered: a transport error or timeout after sending is; an answered refusal, a jwt failure and a skip are not", async () => {
        const down = await make(new Apple([new Error("Network connection lost.")])).client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(down).toMatchObject({ kind: "unhealthy", maybeDelivered: true });
        for (const a of [bad(500, null), bad(503, "ServiceUnavailable"), bad(403, "TopicDisallowed")]) {
            const r = await make(new Apple([a])).client.deliver(TOKEN, "sandbox", push(), RUN);
            expect(r, String(a.status)).toMatchObject({ kind: "unhealthy", maybeDelivered: false });
        }
        const badKey = await make(new Apple(), { keyP8: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----" }).client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(badKey).toMatchObject({ kind: "unhealthy", maybeDelivered: false });
    });
});

describe("the provider token survives a Durable Object eviction (finding 2)", () => {
    it("a new client over the same storage reuses the token instead of re-signing (within 50 minutes)", async () => {
        const kv = new MemoryKV();
        const apple1 = new Apple();
        const one = make(apple1, { storage: kv });
        await one.client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(kv.m.has(JWT_STORAGE_KEY)).toBe(true);
        // the DO is evicted: a fresh instance, the same storage, 10 minutes later
        const apple2 = new Apple();
        const two = make(apple2, { storage: kv });
        two.clock.t = one.clock.t + 10 * 60_000;
        await two.client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(bearer(apple2.calls[0]!.req)).toBe(bearer(apple1.calls[0]!.req));
        // 50 minutes after the first signing it is signed again (and stored again)
        two.clock.t = one.clock.t + JWT_REUSE_MS;
        await two.client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(bearer(apple2.calls[1]!.req)).not.toBe(bearer(apple1.calls[0]!.req));
        expect((kv.m.get(JWT_STORAGE_KEY) as { token: string }).token).toBe(bearer(apple2.calls[1]!.req));
    });

    it("the forced flag survives too: after an eviction an Expired answer inside 20 minutes of a forced re-sign signs nothing", async () => {
        const kv = new MemoryKV();
        const apple1 = new Apple([bad(403, "ExpiredProviderToken"), ok()]);
        const one = make(apple1, { storage: kv });
        expect((await one.client.deliver(TOKEN, "sandbox", push(), RUN)).kind).toBe("sent"); // signed, expired, forced re-sign
        expect(kv.m.get(JWT_STORAGE_KEY)).toMatchObject({ forced: true });
        const apple2 = new Apple([bad(403, "ExpiredProviderToken")]);
        const two = make(apple2, { storage: kv });
        two.clock.t = one.clock.t + 60_000;
        const r = await two.client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(apple2.calls).toHaveLength(1); // no third token inside the 20 minutes
        expect(r.kind).toBe("unhealthy");
    });

    it("a token minted for another key id or team id (a rotated secret) is not reused; a storage failure only means signing again", async () => {
        const kv = new MemoryKV();
        const apple1 = new Apple();
        await make(apple1, { storage: kv }).client.deliver(TOKEN, "sandbox", push(), RUN);
        const apple2 = new Apple();
        const rotated = make(apple2, { storage: kv, keyId: "ZZZZZZZZZZ" });
        rotated.clock.t += 60_000;
        await rotated.client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(bearer(apple2.calls[0]!.req)).not.toBe(bearer(apple1.calls[0]!.req));

        const broken = new MemoryKV();
        broken.get = async () => {
            throw new Error("storage down");
        };
        broken.put = async () => {
            throw new Error("storage down");
        };
        vi.spyOn(console, "error").mockImplementation(() => {});
        const apple3 = new Apple();
        const r = await make(apple3, { storage: broken }).client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(r.kind).toBe("sent");
        vi.restoreAllMocks();
    });

    it("the stored token is never logged", async () => {
        const kv = new MemoryKV();
        const spies = (["log", "info", "warn", "error", "debug"] as const).map((m) => vi.spyOn(console, m).mockImplementation(() => {}));
        const apple = new Apple();
        const { client } = make(apple, { storage: kv, log: undefined });
        await client.deliver(TOKEN, "sandbox", push(), RUN);
        const jwt = (kv.m.get(JWT_STORAGE_KEY) as { token: string }).token;
        for (const s of spies) for (const c of s.mock.calls) expect(c.join(" ")).not.toContain(jwt);
        vi.restoreAllMocks();
    });
});

describe("429 TooManyProviderTokenUpdates is not silent (finding 2)", () => {
    it("is unhealthy with its reason, and the log line carries the reason", async () => {
        const { client, lines } = make(new Apple([bad(429, "TooManyProviderTokenUpdates")]));
        const r = await client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(r).toMatchObject({ kind: "unhealthy", status: 429, reason: "TooManyProviderTokenUpdates", maybeDelivered: false });
        expect(lines[0]).toContain("429 TooManyProviderTokenUpdates");
    });
    it("a plain 429 (the push itself throttled) stays quiet", async () => {
        const r = await make(new Apple([bad(429, "TooManyRequests")])).client.deliver(TOKEN, "sandbox", push(), RUN);
        expect(r).toMatchObject({ kind: "quiet", status: 429 });
    });
});

describe("base64url", () => {
    it("encodes without padding and with the url alphabet", () => {
        expect(base64url(new Uint8Array([0xfb, 0xff, 0xfe]))).toBe("-__-");
        expect(base64url(new Uint8Array([1]))).toBe("AQ");
        expect(base64url(new Uint8Array([]))).toBe("");
    });
});
