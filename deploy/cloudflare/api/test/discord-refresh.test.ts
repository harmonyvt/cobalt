// Old Discord attachment links (APP-API-CONTRACT.md section 19.6). Discord refuses an attachment link without its
// `ex`/`is`/`hm` signature, and one whose signature expired, from anywhere. With a bot token the helper asks
// `POST /attachments/refresh-urls` for a fresh link and saves that. One local HTTP origin plays both the CDN (it serves
// the file only to the current signature) and Discord's API. The helper is the real one; cobalt and probe are stubs.
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { createHelper, HELPER_CAPS, HELPER_CAPS_DISCORD } from "../helper/server.js";
import { JobError, hasDiscordSignature, isDiscordAttachment, isPublicIp, refreshDiscordUrl, sniffVideo } from "../helper/lib.js";

vi.setConfig({ testTimeout: 30_000 });

const KEY = "internal-key";
const TOKEN = "MTIzNDU2Nzg5.TESTBOT.TOKENSECRET";
const u16le = (n: number) => Buffer.from([n & 255, (n >> 8) & 255]);
const GIF = Buffer.concat([Buffer.from("GIF89a"), u16le(160), u16le(120), Buffer.alloc(2400, 3)]);
const ATTACHMENT = "/attachments/911068860487192596/1505800458986590279/Big_Reveal.gif";

const root = mkdtempSync(path.join(tmpdir(), "discord-refresh-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
const rid = () => Array.from({ length: 24 }, () => "abcdefghijklmnopqrstuvwxyz0123456789"[Math.floor(Math.random() * 36)]).join("");

// --- the origin: CDN + Discord API -----------------------------------------------------------------------------

let origin: http.Server;
let port: number;
/** every request: path + query, the authorization header, the JSON body of an API call */
let hits: { url: string; auth?: string; body?: any }[];
/** the signature the CDN accepts now; anything else is a 404, like Discord's */
let validHm: string;
/** the CDN no longer has the file at all (deleted message) */
let deleted: boolean;
/** what the fake API does: answer normally, refuse, or answer something unusable */
let api: { status: number; refreshed?: (sent: string) => unknown };

beforeAll(async () => {
    origin = http.createServer((req, res) => {
        const url = req.url ?? "";
        const [p, q = ""] = url.split("?");
        if (p === "/api/v10/attachments/refresh-urls" && req.method === "POST") {
            let raw = "";
            req.on("data", (c) => (raw += c));
            req.on("end", () => {
                const body = JSON.parse(raw);
                hits.push({ url, auth: req.headers.authorization, body });
                if (api.status !== 200) {
                    res.writeHead(api.status, { "content-type": "application/json" });
                    return void res.end('{"message": "401: Unauthorized", "code": 0}');
                }
                const sent = body.attachment_urls[0];
                const refreshed = api.refreshed ? api.refreshed(sent) : `${sent}${sent.includes("?") ? "&" : "?"}ex=6a00&is=69ff&hm=${validHm}&`;
                res.writeHead(200, { "content-type": "application/json" });
                res.end(JSON.stringify({ refreshed_urls: [{ original: sent, refreshed }] }));
            });
            return;
        }
        hits.push({ url, auth: req.headers.authorization });
        const hm = new URLSearchParams(q).get("hm");
        if (p !== ATTACHMENT || deleted || hm !== validHm) {
            res.writeHead(404, { "content-type": "text/plain" });
            return void res.end("This content is no longer available.");
        }
        res.writeHead(200, { "content-type": "image/gif", "content-length": GIF.length });
        res.end(GIF);
    });
    await new Promise<void>((r) => origin.listen(0, "127.0.0.1", () => r()));
    port = (origin.address() as any).port;
});
afterAll(() => {
    origin?.closeAllConnections?.();
    origin?.close();
});

// the "CDN" is cdn.discord.test (resolved to the origin); other names stand for any other host
const DNS: Record<string, string> = { "cdn.discord.test": "127.0.0.1", "media.test": "127.0.0.1" };
const lookup = (host: string, o: any, cb: Function) => {
    const a = DNS[host];
    if (!a) return cb(Object.assign(new Error("ENOTFOUND"), { code: "ENOTFOUND" }));
    if (o?.all) cb(null, [{ address: a, family: 4 }]);
    else cb(null, a, 4);
};
const policy = { ports: null, isPublicIp: (ip: string) => ip === "127.0.0.1" || isPublicIp(ip), lookup };
const HOSTS = ["cdn.discord.test"];
const CDN = (q = "", p = ATTACHMENT, host = "cdn.discord.test") => `http://${host}:${port}${p}${q}`;
const apiBase = () => `http://127.0.0.1:${port}/api/v10`;

beforeEach(() => {
    hits = [];
    validHm = "f00dfeed" + rid();
    deleted = false;
    api = { status: 200 };
});

// --- the helper --------------------------------------------------------------------------------------------------

let helper: ReturnType<typeof createHelper>;
let base: string;
let logged: string[];

function startHelper(extra: Record<string, unknown> = {}) {
    const id = rid();
    helper = createHelper({
        internalKey: KEY,
        workDir: path.join(root, id, "webp"),
        fetchDir: path.join(root, id, "fetch"),
        probeDir: path.join(root, id, "probe"),
        posterDir: path.join(root, id, "poster"),
        slideshowDir: path.join(root, id, "slideshow"),
        waitForCobalt: async () => {},
        ffmpegPath: () => "/nonexistent/ffmpeg",
        probe: async (file: string) => {
            const video = sniffVideo(readFileSync(file).subarray(0, 12)) !== null;
            return { duration: video ? 3.5 : 1.2, width: 160, height: 120 };
        },
        fetchPolicy: policy,
        // cobalt has no Discord service: every link here is "invalid" to it, as in production
        resolveSource: async () => {
            throw new JobError("error.api.link.invalid");
        },
        discordToken: TOKEN,
        discordApi: apiBase(),
        discordHosts: HOSTS,
        ...extra,
    } as any);
    return new Promise<void>((r) =>
        helper.server.listen(0, "127.0.0.1", () => {
            base = `http://127.0.0.1:${(helper.server.address() as any).port}`;
            r();
        }),
    );
}
const call = (p: string, init: RequestInit = {}) => fetch(`${base}${p}`, { ...init, headers: { "x-internal-key": KEY, ...(init.headers as any) } });
const save = async (url: string) => {
    const id = rid();
    const r = await call("/fetch", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ id, url }) });
    expect(r.status).toBe(202);
    for (let i = 0; i < 600; i++) {
        const b = (await (await call(`/fetch/${id}`)).json()) as any;
        if (b.status !== "pending") return { id, done: b };
        await new Promise((res) => setTimeout(res, 20));
    }
    throw new Error("timed out");
};
const INVALID = { status: "error", error: { code: "error.api.link.invalid" } };
const apiCalls = () => hits.filter((h) => h.url.startsWith("/api/"));
const cdnCalls = () => hits.filter((h) => !h.url.startsWith("/api/")).map((h) => h.url);

beforeEach(async () => {
    logged = [];
    for (const m of ["log", "error", "warn", "info"] as const) {
        vi.spyOn(console, m).mockImplementation((...a: unknown[]) => void logged.push(a.map(String).join(" ")));
    }
    await startHelper();
});
afterEach(async () => {
    vi.restoreAllMocks();
    await helper.close();
});

describe("refreshed: an old Discord link saves", () => {
    it("an unsigned link is refreshed BEFORE any download, then saved from the fresh link", async () => {
        const { id, done } = await save(CDN());
        expect(done).toMatchObject({ status: "done", contentType: "image/gif", ext: "gif", title: "Big_Reveal", direct: true });
        // one API call, with the bot token and the bare link; then exactly one CDN request, the signed one
        expect(apiCalls()).toHaveLength(1);
        expect(apiCalls()[0]!.auth).toBe(`Bot ${TOKEN}`);
        expect(apiCalls()[0]!.body).toEqual({ attachment_urls: [CDN()] });
        expect(cdnCalls()).toEqual([`${ATTACHMENT}?ex=6a00&is=69ff&hm=${validHm}&`]);
        const file = await call(`/fetch/${id}/file`);
        expect(Buffer.from(await file.arrayBuffer()).equals(GIF)).toBe(true);
    });

    it("an expired signed link is downloaded first; Discord's 404 makes it refresh once, without the old signature", async () => {
        const { done } = await save(CDN("?ex=60000000&is=5fff0000&hm=EXPIREDSIG&size=4"));
        expect(done).toMatchObject({ status: "done", contentType: "image/gif" });
        // the old signature is dropped from what Discord is asked; other parameters stay
        expect(apiCalls().map((h) => h.body)).toEqual([{ attachment_urls: [CDN("?size=4")] }]);
        expect(cdnCalls()).toEqual([`${ATTACHMENT}?ex=60000000&is=5fff0000&hm=EXPIREDSIG&size=4`, `${ATTACHMENT}?size=4&ex=6a00&is=69ff&hm=${validHm}&`]);
    });

    it("a signed link that still works is never sent to Discord's API", async () => {
        const { done } = await save(CDN(`?ex=6a00&is=69ff&hm=${validHm}&`));
        expect(done).toMatchObject({ status: "done" });
        expect(apiCalls()).toEqual([]);
    });

    it("never logs the token or a signature, only host and path", async () => {
        await save(CDN());
        await save(CDN("?ex=1&is=2&hm=EXPIREDSIG"));
        const text = logged.join("\n");
        expect(text).toMatch(/discord link refreshed/);
        expect(text).not.toMatch(/TOKENSECRET|EXPIREDSIG|f00dfeed|hm=|\?/);
    });
});

describe("still refused: today's error", () => {
    it("a deleted attachment: refreshed, still a 404, so error.api.link.invalid", async () => {
        deleted = true;
        expect((await save(CDN())).done).toEqual(INVALID);
        expect(apiCalls()).toHaveLength(1);
        // the expired kind: one download, one refresh, one more download, then stop
        hits = [];
        expect((await save(CDN("?ex=1&is=2&hm=OLD"))).done).toEqual(INVALID);
        expect(apiCalls()).toHaveLength(1);
        expect(cdnCalls()).toHaveLength(2);
    });

    it("Discord refuses the refresh (bad token): the link is tried as it is, once, and fails as before", async () => {
        api = { status: 401 };
        expect((await save(CDN())).done).toEqual(INVALID);
        expect(cdnCalls()).toEqual([ATTACHMENT]);
        hits = [];
        expect((await save(CDN("?ex=1&is=2&hm=OLD"))).done).toEqual(INVALID);
        expect(apiCalls()).toHaveLength(1);
        expect(cdnCalls()).toHaveLength(1);
    });

    it.each([
        ["another host", (s: string) => s.replace("cdn.discord.test", "media.test") + "?hm=x"],
        ["another attachment", (s: string) => s.replace("Big_Reveal", "Other") + "?hm=x"],
        ["not a URL", () => "nope"],
        ["no answer at all", () => undefined],
        ["a private address", () => `http://10.0.0.5${ATTACHMENT}?hm=x`],
    ])("an answer pointing at %s is not used", async (_n, refreshed) => {
        api = { status: 200, refreshed };
        expect((await save(CDN())).done).toEqual(INVALID);
        expect(cdnCalls()).toEqual([ATTACHMENT]);
    });
});

describe("no token: exactly as before", () => {
    beforeEach(async () => {
        await helper.close();
        await startHelper({ discordToken: "" });
    });

    it("an unsigned link fails with today's error and Discord's API is never called", async () => {
        expect((await save(CDN())).done).toEqual(INVALID);
        expect(apiCalls()).toEqual([]);
        expect(cdnCalls()).toEqual([ATTACHMENT]);
    });

    it("an expired link too", async () => {
        expect((await save(CDN("?ex=1&is=2&hm=OLD"))).done).toEqual(INVALID);
        expect(apiCalls()).toEqual([]);
    });

    it("a working signed link still saves", async () => {
        expect((await save(CDN(`?ex=6a00&is=69ff&hm=${validHm}`))).done).toMatchObject({ status: "done" });
    });

    it("the caps header has no discord=1; with a token it does", async () => {
        expect((await call("/fetch/nope")).headers.get("x-cobalt-helper")).toBe(HELPER_CAPS);
        await helper.close();
        await startHelper();
        expect((await call("/fetch/nope")).headers.get("x-cobalt-helper")).toBe(HELPER_CAPS_DISCORD);
        expect(HELPER_CAPS_DISCORD).toBe("gallery=1,make=1,direct=1,still=1,discord=1");
    });
});

describe("non-Discord links are never refreshed", () => {
    it("a 404 on any other host keeps today's error with no API call", async () => {
        expect((await save(CDN("?ex=1&is=2&hm=OLD", ATTACHMENT, "media.test"))).done).toEqual(INVALID);
        expect((await save(CDN("", ATTACHMENT, "media.test"))).done).toEqual(INVALID);
        expect(apiCalls()).toEqual([]);
    });

    it("a Discord CDN path that is not an attachment (an avatar, an emoji) is not refreshed", async () => {
        expect((await save(CDN("", "/avatars/1/abc.png"))).done).toEqual(INVALID);
        expect((await save(CDN("", "/emojis/123.gif"))).done).toEqual(INVALID);
        expect(apiCalls()).toEqual([]);
    });
});

describe("the pure rules", () => {
    it("isDiscordAttachment: the two real CDN hosts, attachment paths only", () => {
        const yes = (s: string) => expect(isDiscordAttachment(new URL(s)), s).toBe(true);
        const no = (s: string) => expect(isDiscordAttachment(new URL(s)), s).toBe(false);
        yes("https://cdn.discordapp.com/attachments/911068860487192596/1505800458986590279/Big_Reveal.gif");
        yes("https://media.discordapp.net/attachments/1/2/a.png?ex=1&is=2&hm=3&width=400");
        yes("https://CDN.discordapp.com./ephemeral-attachments/1/2/a.mp4");
        no("https://cdn.discordapp.com/avatars/1/2.png");
        no("https://cdn.discordapp.com/attachments/1/2/a.png/extra");
        no("https://cdn.discordapp.com/attachments/x/2/a.png");
        no("https://evil.example/attachments/1/2/a.png");
        no("https://cdn.discordapp.com.evil.example/attachments/1/2/a.png");
    });

    it("hasDiscordSignature: all three parameters, each non-empty", () => {
        expect(hasDiscordSignature(new URL("https://x.test/a?ex=1&is=2&hm=3"))).toBe(true);
        expect(hasDiscordSignature(new URL("https://x.test/a?ex=1&is=2"))).toBe(false);
        expect(hasDiscordSignature(new URL("https://x.test/a?ex=1&is=2&hm="))).toBe(false);
        expect(hasDiscordSignature(new URL("https://x.test/a"))).toBe(false);
    });

    it("refreshDiscordUrl: null without a token, and when the network fails; never throws", async () => {
        const u = new URL("https://cdn.discordapp.com/attachments/1/2/a.png");
        const spy = vi.fn();
        expect(await refreshDiscordUrl(u, { token: "", fetchImpl: spy as any })).toBeNull();
        expect(spy).not.toHaveBeenCalled();
        expect(await refreshDiscordUrl(u, { token: "t", fetchImpl: (async () => { throw new Error("down"); }) as any })).toBeNull();
        expect(await refreshDiscordUrl(u, { token: "t", fetchImpl: (async () => new Response("not json")) as any })).toBeNull();
    });

    it("refreshDiscordUrl: the real endpoint and body shape (POST /api/v10/attachments/refresh-urls)", async () => {
        const seen: { url: string; init: RequestInit }[] = [];
        const u = new URL("https://cdn.discordapp.com/attachments/1/2/a.png?ex=1&is=2&hm=old");
        const r = await refreshDiscordUrl(u, {
            token: "abc",
            fetchImpl: (async (url: string, init: RequestInit) => {
                seen.push({ url, init });
                return Response.json({ refreshed_urls: [{ original: "x", refreshed: "https://cdn.discordapp.com/attachments/1/2/a.png?ex=9&is=8&hm=new" }] });
            }) as any,
        });
        expect(r).toBe("https://cdn.discordapp.com/attachments/1/2/a.png?ex=9&is=8&hm=new");
        expect(seen[0]!.url).toBe("https://discord.com/api/v10/attachments/refresh-urls");
        expect(seen[0]!.init.method).toBe("POST");
        expect((seen[0]!.init.headers as any).authorization).toBe("Bot abc");
        expect(JSON.parse(String(seen[0]!.init.body))).toEqual({ attachment_urls: ["https://cdn.discordapp.com/attachments/1/2/a.png"] });
    });
});
