// Direct media links (APP-API-CONTRACT.md section 19). Four halves:
//  - the pure rules: which addresses and URLs are public, how a file's bytes are typed, what a log may keep;
//  - makeSafeFetch against a REAL local HTTP origin (a fake resolver stands in for DNS): redirects checked hop by hop,
//    private destinations refused before a socket is opened, the byte cap enforced mid-stream, timeouts, no credentials sent;
//  - POST /fetch through the real helper server (stubbed cobalt that has no service for the link, stubbed probe) for the
//    whole rule: what is accepted, what keeps today's error, and that picker items are hardened the same way;
//  - one real-helper test with the REAL ffmpeg (skipped when no ffmpeg is found: FFMPEG_PATH or `ffmpeg` on PATH).
// Fixtures are generated at test time; nothing binary is committed.
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import http from "node:http";
import net from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { createHelper, HELPER_CAPS } from "../helper/server.js";
import {
    JobError,
    checkPublicUrl,
    downloadToFile,
    directHeadOk,
    filenameFromUrl,
    imageDimensions,
    isPublicIp,
    logUrl,
    makeSafeFetch,
    sniffType,
    sniffVideo,
} from "../helper/lib.js";

vi.setConfig({ testTimeout: 60_000 });

const KEY = "internal-key";
const FFMPEG = process.env.FFMPEG_PATH || "ffmpeg";
const hasFfmpeg = spawnSync(FFMPEG, ["-version"]).status === 0;
const real = hasFfmpeg ? describe : describe.skip;

const root = mkdtempSync(path.join(tmpdir(), "direct-links-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
const rid = () => Array.from({ length: 24 }, () => "abcdefghijklmnopqrstuvwxyz0123456789"[Math.floor(Math.random() * 36)]).join("");

// ---- the pure rules ---------------------------------------------------------------------------------------------

describe("isPublicIp: v4 and v6, every spelling of a private address is refused", () => {
    it.each([
        "8.8.8.8", "1.1.1.1", "93.184.216.34", "172.15.255.255", "172.32.0.1", "100.63.255.255", "100.128.0.1",
        "2606:4700:4700::1111", "2001:4860:4860::8888", "2a00:1450:4001:81b::200e", "[2606:4700:4700::1111]",
        "::ffff:8.8.8.8", "::ffff:808:808", "64:ff9b::808:808", "2002:808:808::1",
    ])("%s is public", (ip) => expect(isPublicIp(ip)).toBe(true));

    it.each([
        "0.0.0.0", "10.0.0.1", "10.255.255.255", "127.0.0.1", "127.1.2.3", "169.254.169.254", "169.254.0.1", "172.16.0.1",
        "172.31.255.255", "192.168.0.1", "192.168.255.255", "100.64.0.1", "100.127.255.255", "192.0.0.1", "192.0.2.1",
        "198.18.0.1", "198.19.255.255", "198.51.100.7", "203.0.113.9", "224.0.0.1", "239.255.255.250", "240.0.0.1", "255.255.255.255",
        "::", "::1", "[::1]", "fe80::1", "fe80::1%en0", "fc00::1", "fd12:3456:789a::1", "fec0::1", "ff02::1", "2001:db8::1",
        "2001:0:4136:e378:8000:63bf:3fff:fdd2", // Teredo
        "::ffff:127.0.0.1", "::ffff:7f00:1", "::ffff:10.0.0.1", "::ffff:a00:1", "::ffff:169.254.169.254", "::ffff:a9fe:a9fe",
        "::127.0.0.1", "::10.1.2.3", "0:0:0:0:0:ffff:7f00:1", "0000:0000:0000:0000:0000:ffff:c0a8:0101",
        "64:ff9b::7f00:1", "64:ff9b::a00:1", "64:ff9b::a9fe:a9fe", "2002:7f00:1::1", "2002:a9fe:a9fe::1",
        "100::1", "1:2:3:4:5:6:7:8", "not an ip", "", "999.1.1.1", "1.2.3", "0x7f.0.0.1",
    ])("%s is not", (ip) => expect(isPublicIp(ip)).toBe(false));
});

describe("checkPublicUrl: the URL half of the rule", () => {
    const ok = (u: string, o?: any) => expect(checkPublicUrl(u, o), u).toBeInstanceOf(URL);
    const no = (u: unknown, o?: any) => expect(checkPublicUrl(u, o), String(u)).toBeNull();

    it("a Discord attachment link passes, query and all", () => {
        const u = checkPublicUrl("https://cdn.discordapp.com/attachments/1/2/LiaPoor.png?ex=68f0&is=68ee&hm=abc123&")!;
        expect(u.hostname).toBe("cdn.discordapp.com");
        ok("http://example.com/a.jpg");
        ok("https://example.com:443/a.jpg");
        ok("http://example.com:80/a.jpg");
        ok("https://93.184.216.34/a.jpg");
        ok("https://[2606:4700:4700::1111]/a.jpg");
        ok("https://example.com./a.jpg"); // the trailing dot
    });
    it("only http and https", () => {
        for (const u of ["file:///etc/passwd", "ftp://example.com/a.png", "gopher://example.com/", "data:image/png;base64,AAAA", "javascript:alert(1)", "ws://example.com/"]) no(u);
    });
    it("no credentials", () => {
        no("https://user:pass@example.com/a.png");
        no("https://user@example.com/a.png");
        no("https://:pass@example.com/a.png");
    });
    it("ports: 80 and 443 only, whichever scheme; `ports: null` lifts it (tests)", () => {
        for (const p of [8080, 8443, 22, 25, 6379, 9000, 3000, 1, 65535]) no(`https://example.com:${p}/a.png`);
        no("http://example.com:8000/a.png");
        ok("http://example.com:443/a.png"); // the number is the rule
        ok("https://example.com:80/a.png");
        ok("http://example.com:8080/a.png", { ports: null });
    });
    it("private names, private literals in every spelling, single-label hosts", () => {
        for (const h of ["localhost", "LOCALHOST", "localhost.", "a.localhost", "printer.local", "metadata.google.internal", "foo.internal", "intranet", "nas"]) no(`http://${h}/a.png`);
        for (const h of ["127.0.0.1", "127.1", "0x7f.0.0.1", "2130706433", "017700000001", "0.0.0.0", "10.0.0.1", "192.168.1.1", "172.16.0.9", "169.254.169.254", "[::1]", "[::]", "[fe80::1]", "[fd00::1]", "[::ffff:127.0.0.1]", "[::ffff:7f00:1]", "[::ffff:a9fe:a9fe]", "[64:ff9b::7f00:1]"]) {
            no(`http://${h}/a.png`);
            no(`https://${h}/a.png`);
        }
    });
    it("junk and over-long input", () => {
        for (const u of [undefined, null, 5, {}, "", "not a url", "//example.com/a.png", "example.com/a.png", "http://", "https://" + "a".repeat(2100) + ".com/"]) no(u);
    });
    it("a policy can allow a given address (tests only), the rest of the rule stays", () => {
        const o = { ports: null, isPublicIp: (ip: string) => ip === "127.0.0.1" || isPublicIp(ip) };
        ok("http://127.0.0.1:8123/a.png", o);
        no("http://10.0.0.1:8123/a.png", o);
        no("http://user:pw@127.0.0.1:8123/a.png", o);
    });
});

describe("filenameFromUrl and logUrl", () => {
    it("the file name of the path, decoded, never the query", () => {
        expect(filenameFromUrl(new URL("https://cdn.discordapp.com/attachments/1/2/LiaPoor.png?ex=1&hm=2"))).toBe("LiaPoor.png");
        expect(filenameFromUrl(new URL("https://x.com/a/My%20Photo%20(1).jpg"))).toBe("My Photo (1).jpg");
        expect(filenameFromUrl(new URL("https://x.com/a/%E2%98%83.png"))).toBe("☃.png");
        expect(filenameFromUrl(new URL("https://x.com/a/%ZZ.png"))).toBe("%ZZ.png"); // undecodable: kept
        expect(filenameFromUrl(new URL("https://x.com/a/b/"))).toBe("b");
        expect(filenameFromUrl(new URL("https://x.com/"))).toBeNull();
        expect(filenameFromUrl(new URL("https://x.com/a/%0a%00x.png"))).toBe("x.png");
    });
    it("a log line keeps host and path only", () => {
        const l = logUrl("https://cdn.discordapp.com/attachments/1/2/LiaPoor.png?ex=68f0&is=68ee&hm=SECRET#frag");
        expect(l).toBe("cdn.discordapp.com/attachments/1/2/LiaPoor.png");
        expect(l).not.toMatch(/SECRET|ex=|\?|#/);
        expect(logUrl("::nope")).toBe("(unparseable url)");
    });
});

describe("sniffVideo: a container the studio stores, or nothing", () => {
    const box = (brand: string) => Buffer.concat([Buffer.from([0, 0, 0, 0x18]), Buffer.from("ftyp" + brand), Buffer.alloc(40)]);
    it.each([
        ["isom", "mp4"], ["mp42", "mp4"], ["avc1", "mp4"], ["dash", "mp4"], ["3gp4", "mp4"], ["qt  ", "mov"], ["M4V ", "m4v"],
    ])("ftyp %s is %s", (brand, ext) => expect(sniffVideo(box(brand))).toMatchObject({ ext }));
    it("webm and matroska are told apart by the DocType", () => {
        const ebml = (doc: string) => Buffer.concat([Buffer.from([0x1a, 0x45, 0xdf, 0xa3, 0x9f, 0x42, 0x82, 0x84]), Buffer.from(doc), Buffer.alloc(30)]);
        expect(sniffVideo(ebml("webm"))).toEqual({ ext: "webm", contentType: "video/webm" });
        expect(sniffVideo(ebml("matroska"))).toEqual({ ext: "mkv", contentType: "video/x-matroska" });
    });
    it.each([
        ["M4A audio", box("M4A ")], ["M4B audiobook", box("M4B ")], ["heic still", box("heic")], ["avif still", box("avif")],
        ["mp3 (ID3)", Buffer.from("ID3\x03\x00\x00\x00\x00\x00\x00" + "x".repeat(40))], ["html", Buffer.from("<!doctype html><html></html>")],
        ["json", Buffer.from('{"a":1}')], ["AVI", Buffer.from("RIFF\x00\x00\x00\x00AVI LIST")], ["mpeg-ts", Buffer.from([0x47, 0x40, 0x00, 0x10, ...Array(40).fill(0)])],
        ["empty", Buffer.alloc(0)], ["3 bytes", Buffer.from([0x1a, 0x45, 0xdf])], ["a png", Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0])],
    ])("%s is not a video", (_n, head) => expect(sniffVideo(head)).toBeNull());
    it("sniffType still types the stills and the gif (unchanged)", () => {
        expect(sniffType(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]))).toMatchObject({ ext: "png" });
        expect(sniffType(Buffer.from("GIF89a" + "x".repeat(10)))).toMatchObject({ type: "gif" });
    });
});

// ---- a real local origin ---------------------------------------------------------------------------------------

// Files with a real header (the pixel size is read from it) and filler after: no decoder ever reads these.
const u16 = (n: number) => Buffer.from([n >> 8, n & 255]);
const u16le = (n: number) => Buffer.from([n & 255, n >> 8]);
const u32 = (n: number) => Buffer.from([(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]);
const u32le = (n: number) => Buffer.from([n & 255, (n >>> 8) & 255, (n >>> 16) & 255, (n >>> 24) & 255]);
const u24le = (n: number) => Buffer.from([n & 255, (n >>> 8) & 255, (n >>> 16) & 255]);
const pngOf = (w: number, h: number, pad = 2400) =>
    Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), u32(13), Buffer.from("IHDR"), u32(w), u32(h), Buffer.from([8, 6, 0, 0, 0]), u32(0), Buffer.alloc(pad, 1)]);
// an EXIF-sized APP1 before the frame header, a progressive SOF2 (the dimension marker is not always SOF0)
const jpegOf = (w: number, h: number, sof = 0xc0, app = 14) =>
    Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe1]), u16(app + 2), Buffer.alloc(app, 0x45), Buffer.from([0xff, sof, 0x00, 0x11, 8]), u16(h), u16(w), Buffer.from([3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]), Buffer.from([0xff, 0xda, 0, 2]), Buffer.alloc(2400, 2)]);
const gifOf = (w: number, h: number) => Buffer.concat([Buffer.from("GIF89a"), u16le(w), u16le(h), Buffer.alloc(2400, 3)]);
const riff = (...chunks: Buffer[]) => {
    const body = Buffer.concat([Buffer.from("WEBP"), ...chunks]);
    return Buffer.concat([Buffer.from("RIFF"), u32le(body.length), body]);
};
const webpX = (w: number, h: number) => riff(Buffer.concat([Buffer.from("VP8X"), u32le(10), Buffer.from([0x10, 0, 0, 0]), u24le(w - 1), u24le(h - 1), Buffer.alloc(400, 6)]));
const webpL = (w: number, h: number) => riff(Buffer.concat([Buffer.from("VP8L"), u32le(405), Buffer.from([0x2f]), u32le(((h - 1) << 14) | (w - 1)), Buffer.alloc(400, 6)]));
const webpLossy = (w: number, h: number) => riff(Buffer.concat([Buffer.from("VP8 "), u32le(410), Buffer.from([0x10, 0x02, 0x00, 0x9d, 0x01, 0x2a]), u16le(w), u16le(h), Buffer.alloc(400, 6)]));
const box = (type: string, ...kids: Buffer[]) => {
    const body = Buffer.concat(kids);
    return Buffer.concat([u32(8 + body.length), Buffer.from(type), body]);
};
const ispe = (w: number, h: number) => box("ispe", u32(0), u32(w), u32(h));
const ftypHeic = box("ftyp", Buffer.from("heic"), u32(0), Buffer.from("mif1heic"));
const heicOf = (w: number, h: number, thumb?: [number, number]) =>
    Buffer.concat([ftypHeic, box("meta", u32(0), box("iprp", box("ipco", ispe(w, h), ...(thumb ? [ispe(...thumb)] : [])))), box("mdat", Buffer.alloc(2000, 7))]);
const PNG = pngOf(640, 360);
const JPEG = jpegOf(640, 360);
const GIF = gifOf(160, 120);
const MP4 = Buffer.concat([Buffer.from([0, 0, 0, 0x18]), Buffer.from("ftypmp42"), Buffer.alloc(4000, 4)]);
const WEBM = Buffer.concat([Buffer.from([0x1a, 0x45, 0xdf, 0xa3, 0x9f, 0x42, 0x82, 0x84]), Buffer.from("webm"), Buffer.alloc(4000, 5)]);
const HTML = Buffer.from("<!doctype html><html><body>sign in to continue</body></html>");
const JSON_BODY = Buffer.from('{"message":"Not Found","code":0}');
const MP3 = Buffer.concat([Buffer.from("ID3\x03\x00\x00\x00\x00\x00\x00"), Buffer.alloc(3000, 6)]);
const NOISE = Buffer.from(Array.from({ length: 3000 }, (_, i) => (i * 37 + 11) % 251));

type Hit = { url: string; headers: http.IncomingHttpHeaders };
let origin: http.Server;
let port: number;
let hits: Hit[];
let streamed: { written: number; closed: boolean }[];
let routes: Record<string, (req: http.IncomingMessage, res: http.ServerResponse) => void>;

const send = (body: Buffer, type: string) => (_req: http.IncomingMessage, res: http.ServerResponse) => {
    res.writeHead(200, { "content-type": type, "content-length": body.length });
    res.end(body);
};
const redirectTo = (loc: string, status = 302) => (_req: http.IncomingMessage, res: http.ServerResponse) => {
    res.writeHead(status, { location: loc });
    res.end();
};
// a body that never ends (chunked, no content-length), 64 KiB at a time, until the client goes away
// (`pace` ms between chunks: 0 = as fast as the socket takes them)
const endless = (type = "image/png", head = PNG, pace = 0) => (_req: http.IncomingMessage, res: http.ServerResponse) => {
    const rec = { written: 0, closed: false };
    streamed.push(rec);
    res.writeHead(200, { "content-type": type });
    res.write(head);
    rec.written += head.length;
    const chunk = Buffer.alloc(64 * 1024, 9);
    const tick = () => {
        if (rec.closed || rec.written > 64 * 1024 * 1024) return res.end();
        rec.written += chunk.length;
        if (pace) {
            res.write(chunk);
            setTimeout(tick, pace);
        } else if (res.write(chunk)) setImmediate(tick);
        else res.once("drain", tick);
    };
    res.on("close", () => (rec.closed = true));
    tick();
};

beforeAll(async () => {
    origin = http.createServer((req, res) => {
        const key = (req.url ?? "").split("?")[0]!;
        hits.push({ url: req.url ?? "", headers: req.headers });
        const r = routes[key];
        if (!r) {
            res.writeHead(404);
            return void res.end();
        }
        r(req, res);
    });
    await new Promise<void>((r) => origin.listen(0, "127.0.0.1", () => r()));
    port = (origin.address() as any).port;
});
afterAll(() => {
    origin?.closeAllConnections?.();
    origin?.close();
});

// names the fake resolver knows; everything else does not resolve
const DNS: Record<string, string[]> = {
    "media.test": ["127.0.0.1"],
    "cdn.media.test": ["127.0.0.1"],
    "rebind.test": ["10.0.0.7"],
    "metadata.test": ["169.254.169.254"],
    "v6loop.test": ["::1"],
    "mapped.test": ["::ffff:127.0.0.1"],
    "mixed.test": ["127.0.0.1", "10.0.0.8"],
};
const lookup = (host: string, o: any, cb: Function) => {
    const list = DNS[host];
    if (!list) return cb(Object.assign(new Error("ENOTFOUND"), { code: "ENOTFOUND" }));
    const all = list.map((address) => ({ address, family: address.includes(":") ? 6 : 4 }));
    if (o?.all) cb(null, all);
    else cb(null, all[0]!.address, all[0]!.family);
};
// the origin is on 127.0.0.1 and any port; the REST of the rule is the real one
const policy = { ports: null, isPublicIp: (ip: string) => ip === "127.0.0.1" || isPublicIp(ip), lookup };
const U = (p: string, host = "media.test") => `http://${host}:${port}${p}`;
const hitPaths = () => hits.map((h) => h.url.split("?")[0]);

beforeEach(() => {
    hits = [];
    streamed = [];
    routes = {
        "/a.png": send(PNG, "image/png"),
        "/a.jpg": send(JPEG, "text/plain"),
        "/a.gif": send(GIF, "image/gif"),
        "/v.mp4": send(MP4, "video/mp4"),
        "/v.webm": send(WEBM, "video/webm"),
        "/wrongname.png": send(MP4, "image/png"),
        "/page.html": send(HTML, "text/html"),
        "/image.png": send(HTML, "image/png"), // html under an image name and type
        "/data.json": send(JSON_BODY, "application/json"),
        "/song.mp3": send(MP3, "audio/mpeg"),
        "/noise.bin": send(NOISE, "application/octet-stream"),
        "/empty.png": send(Buffer.alloc(0), "image/png"),
        "/big.png": endless(),
        "/slow.png": endless("image/png", PNG, 20),
        "/big.mp4": endless("video/mp4", MP4),
        "/r1": redirectTo("/r2"),
        "/r2": redirectTo("/r3"),
        "/r3": redirectTo("/a.png"),
        "/c1": redirectTo("/c2"),
        "/c2": redirectTo("/c3"),
        "/c3": redirectTo("/c4"),
        "/c4": redirectTo("/a.png"),
        "/loop": redirectTo("/loop"),
        "/nolocation": (_q, res) => {
            res.writeHead(302);
            res.end();
        },
        "/rel": redirectTo("a.png"),
        "/abs": redirectTo(`http://cdn.media.test:${port}/a.png`, 301),
        "/to-private": redirectTo("http://10.0.0.5/secret.png"),
        "/to-192": redirectTo("http://192.168.1.1/admin"),
        "/to-metadata": redirectTo("http://169.254.169.254/latest/meta-data/iam/security-credentials/"),
        "/to-metadata-name": redirectTo(`http://metadata.test:${port}/a.png`),
        "/to-v6loop": redirectTo("http://[::1]/a.png"),
        "/to-mapped": redirectTo("http://[::ffff:127.0.0.1]/a.png"),
        "/to-mapped-hex": redirectTo("http://[::ffff:7f00:1]/a.png"),
        "/to-localhost": redirectTo("http://localhost/a.png"),
        "/to-internal": redirectTo("http://metadata.google.internal/computeMetadata/v1/"),
        "/to-rebind": redirectTo(`http://rebind.test:${port}/a.png`),
        "/to-decimal": redirectTo("http://2852039166/latest/meta-data/"), // 169.254.169.254 in decimal
        "/to-file": redirectTo("file:///etc/passwd"),
        "/to-ftp": redirectTo("ftp://example.com/a.png"),
        "/to-creds": redirectTo(`http://user:pw@media.test:${port}/a.png`),
        "/to-port": redirectTo("http://example.com:6379/a.png"),
        "/to-junk": redirectTo("http://[bad/a.png"),
        "/stall": (_q, res) => {
            res.writeHead(200, { "content-type": "image/png", "content-length": "99999" });
            res.write(PNG.subarray(0, 100)); // then nothing
        },
        "/hang": () => {
            // never answers
        },
        "/declared-big": (_q, res) => {
            res.writeHead(200, { "content-type": "image/png", "content-length": String(900 * 1024 * 1024) });
            res.write(PNG);
        },
        "/gone": (_q, res) => {
            res.writeHead(410);
            res.end();
        },
    };
});

// ---- makeSafeFetch (+ downloadToFile) --------------------------------------------------------------------------

describe("makeSafeFetch with downloadToFile: the destination rule, against a real origin", () => {
    const dl = (url: string, o: Record<string, unknown> = {}, pol: object = policy) =>
        downloadToFile({ url, dest: path.join(root, rid()), fetchImpl: makeSafeFetch(pol as any), ...o } as any);
    const refused = (url: string, pol?: object) => expect(dl(url, {}, pol)).rejects.toMatchObject({ code: "error.webp.bad_source" });

    it("fetches a file and counts the bytes; the query reaches the origin intact", async () => {
        const dest = path.join(root, rid());
        const n = await downloadToFile({ url: U("/a.png?ex=1&is=2&hm=tok"), dest, fetchImpl: makeSafeFetch(policy) });
        expect(n).toBe(PNG.length);
        expect(Buffer.from(readFileSync(dest)).equals(PNG)).toBe(true);
        expect(hits.map((h) => h.url)).toEqual(["/a.png?ex=1&is=2&hm=tok"]);
    });

    it("sends the origin a user agent and accept and nothing else: no cookie, no authorization, no referer, no internal key, no encoding", async () => {
        await dl(U("/a.png"));
        const h = hits[0]!.headers;
        expect(h["user-agent"]).toMatch(/cobalt-studio/);
        expect(h["accept-encoding"]).toBe("identity");
        expect(h.host).toBe(`media.test:${port}`);
        for (const k of ["cookie", "authorization", "referer", "origin", "x-internal-key", "proxy-authorization"]) expect(h[k], k).toBeUndefined();
        expect(Object.keys(h).sort()).toEqual(["accept", "accept-encoding", "connection", "host", "user-agent"]);
    });

    it("follows up to 3 redirects (relative and absolute Locations, on the same or another public name)", async () => {
        const n = await dl(U("/r1"));
        expect(n).toBe(PNG.length);
        expect(hitPaths()).toEqual(["/r1", "/r2", "/r3", "/a.png"]);
        hits.length = 0;
        await dl(U("/rel"));
        await dl(U("/abs"));
        expect(hitPaths()).toEqual(["/rel", "/a.png", "/abs", "/a.png"]);
        expect(hits[3]!.headers.host).toBe(`cdn.media.test:${port}`);
    });

    it("a fourth redirect is refused, and the file at the end of the chain is never requested", async () => {
        await refused(U("/c1"));
        expect(hitPaths()).toEqual(["/c1", "/c2", "/c3", "/c4"]);
    });

    it("a redirect loop ends at the limit; a redirect with no Location is just a non-ok answer", async () => {
        await refused(U("/loop"));
        expect(hits).toHaveLength(4);
        hits.length = 0;
        await expect(dl(U("/nolocation"))).rejects.toMatchObject({ code: "error.webp.download_failed" });
        await expect(dl(U("/gone"))).rejects.toMatchObject({ code: "error.webp.download_failed" });
    });

    it.each([
        "/to-private", "/to-192", "/to-metadata", "/to-metadata-name", "/to-v6loop", "/to-mapped", "/to-mapped-hex", "/to-localhost",
        "/to-internal", "/to-rebind", "/to-decimal", "/to-file", "/to-ftp", "/to-creds", "/to-port", "/to-junk",
    ])("a redirect to a private or forbidden destination (%s) is refused; only the first hop was ever requested", async (route) => {
        // `/to-port` runs with the origin's own port allowed (and 80/443) so only the redirect's :6379 is out of bounds
        await refused(U(route), route === "/to-port" ? { ...policy, ports: [port, 80, 443] } : policy);
        expect(hitPaths()).toEqual([route]);
    });

    it("a name that resolves to a private address never gets a socket (the lookup is the connection's own)", async () => {
        await refused(U("/a.png", "rebind.test"));
        await refused(U("/a.png", "metadata.test"));
        await refused(U("/a.png", "v6loop.test"));
        await refused(U("/a.png", "mapped.test"));
        expect(hits).toEqual([]);
    });

    it("one private address among the public ones is enough to refuse", async () => {
        await refused(U("/a.png", "mixed.test"));
        expect(hits).toEqual([]);
    });

    it("a name that does not resolve is a failed download, not a refusal", async () => {
        await expect(dl(U("/a.png", "nowhere.test"))).rejects.toMatchObject({ code: "error.webp.download_failed" });
    });

    it("credentials in the URL are refused before anything is sent", async () => {
        await refused(`http://user:pass@media.test:${port}/a.png`);
        await refused(`http://user@media.test:${port}/a.png`);
        expect(hits).toEqual([]);
    });

    it("the real policy allows ports 80 and 443 only: any other port is refused before anything is sent", async () => {
        const strict = { ...policy, ports: undefined };
        await refused(U("/a.png"), strict);
        await refused("http://media.test:8080/a.png", strict);
        await refused("https://media.test:6379/a.png", strict);
        expect(hits).toEqual([]);
    });

    it("loopback, private and link-local literals and names are refused with the real isPublicIp", async () => {
        const real = { ports: null, lookup };
        for (const u of [`http://127.0.0.1:${port}/a.png`, "http://10.1.2.3/a.png", "http://169.254.169.254/latest/", "http://[::1]/a.png", "http://[::ffff:127.0.0.1]/a.png", "http://localhost/a.png", "http://nas/a.png", "file:///etc/passwd", "ftp://media.test/a.png"]) {
            await refused(u, real);
        }
        expect(hits).toEqual([]);
    });

    it("the byte cap is enforced while streaming, not by trusting content-length: an endless body is cut and the origin sees the socket close", async () => {
        await expect(dl(U("/big.png"), { maxBytes: 1_000_000 })).rejects.toMatchObject({ code: "error.webp.too_large" });
        await vi.waitFor(() => expect(streamed[0]!.closed).toBe(true), { timeout: 5000 });
        // it stopped near the cap, nowhere near the 64 MB the origin was ready to send
        expect(streamed[0]!.written).toBeLessThan(8 * 1024 * 1024);
    });

    it("a declared size over the cap is refused before the body is read", async () => {
        await expect(dl(U("/declared-big"), { maxBytes: 1_000_000 })).rejects.toMatchObject({ code: "error.webp.too_large" });
    });

    it("an idle socket is dropped (a body that stalls) and so is a server that never answers", async () => {
        await expect(dl(U("/stall"), {}, { ...policy, idleMs: 250 })).rejects.toMatchObject({ code: "error.webp.timeout" });
        await expect(dl(U("/hang"), {}, { ...policy, idleMs: 250 })).rejects.toMatchObject({ code: "error.webp.timeout" });
    });

    it("the caller's signal ends it too, at the connection or in the body", async () => {
        await expect(dl(U("/hang"), { signal: AbortSignal.timeout(200) })).rejects.toMatchObject({ code: "error.webp.timeout" });
        await expect(dl(U("/slow.png"), { signal: AbortSignal.timeout(300), maxBytes: 1 << 30 })).rejects.toMatchObject({ code: "error.webp.timeout" });
        await vi.waitFor(() => expect(streamed.at(-1)!.closed).toBe(true), { timeout: 5000 });
    });

    it("progress and the response are reported like the plain fetch's", async () => {
        const seen: number[] = [];
        let type: string | null = null;
        await dl(U("/a.png"), { onProgress: (b: number) => seen.push(b), onResponse: (r: Response) => (type = r.headers.get("content-type")) });
        expect(type).toBe("image/png");
        expect(seen.at(-1)).toBe(PNG.length);
    });
});

// ---- POST /fetch through the helper server ----------------------------------------------------------------------

describe("the helper's HELPER_CAPS header says direct=1", () => {
    it("is part of what every answer carries", () => {
        expect(HELPER_CAPS).toBe("gallery=1,make=1,direct=1");
    });
});

type Opts = Record<string, unknown>;
let helper: ReturnType<typeof createHelper>;
let base: string;
let cobalt: () => Promise<any>;
let logged: string[];
const probeStub = async (file: string) => {
    const head = readFileSync(file).subarray(0, 12);
    const video = sniffVideo(head) !== null;
    return { duration: video ? 3.5 : null, width: 640, height: 360 };
};

function startHelper(extra: Opts = {}) {
    const id = rid();
    helper = createHelper({
        internalKey: KEY,
        workDir: path.join(root, id, "webp"),
        fetchDir: path.join(root, id, "fetch"),
        probeDir: path.join(root, id, "probe"),
        posterDir: path.join(root, id, "poster"),
        slideshowDir: path.join(root, id, "slideshow"),
        waitForCobalt: async () => {},
        ffmpegPath: () => "/nonexistent/ffmpeg", // a thumb is best effort
        probe: probeStub,
        fetchPolicy: policy,
        resolveSource: async (o: any) => {
            const body = await cobalt();
            if (body.status === "error") throw new JobError(body.error.code);
            if (body.status === "picker") return { url: null, filename: null, picker: body.picker };
            return { url: body.url, filename: body.filename ?? null };
        },
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
const json = async (r: Response) => (await r.json()) as any;
const post = (p: string, b: unknown) => call(p, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(b) });
const until = async (p: string) => {
    for (let i = 0; i < 600; i++) {
        const b = await json(await call(p));
        if (b.status !== "pending") return b;
        await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error("timed out waiting for " + p);
};
const saveLink = async (url: string, extra: Record<string, unknown> = {}) => {
    const id = rid();
    const r = await post("/fetch", { id, url, ...extra });
    expect(r.status).toBe(202);
    return { id, done: await until(`/fetch/${id}`) };
};
const INVALID = { status: "error", error: { code: "error.api.link.invalid" } };
const UNSUPPORTED = { status: "error", error: { code: "error.api.link.unsupported" } };
const DISCORD = (name: string) => U(`/${name}?ex=68f0aa11&is=68eb2991&hm=0123456789abcdefSECRETTOKEN&`);

describe("POST /fetch of a link cobalt has no service for: the link is tried as a file", () => {
    beforeEach(async () => {
        cobalt = async () => INVALID;
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

    it("a PNG on a Discord-style signed link: one saved photo, typed by its bytes, titled from the file name, service from the host", async () => {
        const { id, done } = await saveLink(DISCORD("a.png"));
        expect(done).toEqual({
            status: "done", bytes: PNG.length, contentType: "image/png", ext: "png", duration: null, width: 640, height: 360,
            title: "a", service: "media", picker_count: null, direct: true,
        });
        expect(done).not.toHaveProperty("items");
        expect(hits.map((h) => h.url)).toEqual(["/a.png?ex=68f0aa11&is=68eb2991&hm=0123456789abcdefSECRETTOKEN&"]);
        const file = await call(`/fetch/${id}/file`);
        expect(file.status).toBe(200);
        expect(Buffer.from(await file.arrayBuffer()).equals(PNG)).toBe(true);
    });

    it("the type is the bytes', whatever the name or the content-type say", async () => {
        expect(await saveLink(U("/a.jpg")).then((r) => r.done)).toMatchObject({ status: "done", contentType: "image/jpeg", ext: "jpg", title: "a" });
        expect(await saveLink(U("/a.gif")).then((r) => r.done)).toMatchObject({ status: "done", contentType: "image/gif", ext: "gif", duration: null });
        // an mp4 served as image/png under a .png name is a video
        expect(await saveLink(U("/wrongname.png")).then((r) => r.done)).toMatchObject({ status: "done", contentType: "video/mp4", ext: "mp4", duration: 3.5, title: "wrongname" });
    });

    it("videos: mp4 and webm, with their duration", async () => {
        expect((await saveLink(U("/v.mp4"))).done).toMatchObject({ status: "done", contentType: "video/mp4", ext: "mp4", duration: 3.5, width: 640, height: 360, service: "media", title: "v" });
        expect((await saveLink(U("/v.webm"))).done).toMatchObject({ status: "done", contentType: "video/webm", ext: "webm", duration: 3.5 });
    });

    it("`error.api.link.unsupported` is treated the same way", async () => {
        cobalt = async () => UNSUPPORTED;
        expect((await saveLink(U("/a.png"))).done).toMatchObject({ status: "done", contentType: "image/png", service: "media" });
    });

    it("`items: \"all\"` and `first-video` on a plain file are still one file (today's rule for a link that is not a picker)", async () => {
        expect((await saveLink(U("/a.png"), { items: "all" })).done).toMatchObject({ status: "done", contentType: "image/png", picker_count: null });
        expect((await saveLink(U("/a.png"), { items: "first-video" })).done).toMatchObject({ status: "done" });
    });

    it.each([
        ["html", "/page.html"],
        ["html under an image name and type", "/image.png"],
        ["json", "/data.json"],
        ["audio (mp3)", "/song.mp3"],
        ["unknown bytes", "/noise.bin"],
        ["an empty body", "/empty.png"],
        ["a 404", "/missing.png"],
        ["a 410", "/gone"],
    ])("%s keeps today's error (error.api.link.invalid), and nothing is left behind", async (_n, route) => {
        const { done } = await saveLink(U(route));
        expect(done).toEqual({ status: "error", error: { code: "error.api.link.invalid" } });
    });

    it("the answer cobalt gave is the one that stays (unsupported stays unsupported)", async () => {
        cobalt = async () => UNSUPPORTED;
        expect((await saveLink(U("/page.html"))).done).toEqual({ status: "error", error: { code: "error.api.link.unsupported" } });
    });

    it("other cobalt errors are not a reason to try the link: the origin is never contacted", async () => {
        for (const code of ["error.api.fetch.fail", "error.api.content.video.unavailable", "error.api.link.unsupported.x", "error.webp.upstream"]) {
            cobalt = async () => ({ status: "error", error: { code } });
            expect((await saveLink(U("/a.png"))).done).toEqual({ status: "error", error: { code } });
        }
        expect(hits).toEqual([]);
    });

    it("a file over the cap says so: error.studio.too_large; the origin sees the socket close", async () => {
        await helper.close();
        await startHelper({ maxFetchBytes: 1_000_000 });
        expect((await saveLink(U("/big.png"))).done).toEqual({ status: "error", error: { code: "error.studio.too_large" } });
        expect((await saveLink(U("/big.mp4"))).done).toEqual({ status: "error", error: { code: "error.studio.too_large" } });
        await vi.waitFor(() => expect(streamed.every((s) => s.closed)).toBe(true), { timeout: 5000 });
        expect(Math.max(...streamed.map((s) => s.written))).toBeLessThan(8 * 1024 * 1024);
    });

    it("a redirect chain longer than 3 keeps today's error and never reaches the file", async () => {
        expect((await saveLink(U("/c1"))).done).toEqual({ status: "error", error: { code: "error.api.link.invalid" } });
        expect(hitPaths()).toEqual(["/c1", "/c2", "/c3", "/c4"]);
        hits.length = 0;
        // 3 hops are fine
        expect((await saveLink(U("/r1"))).done).toMatchObject({ status: "done", contentType: "image/png" });
    });

    it.each(["/to-private", "/to-metadata", "/to-mapped", "/to-localhost", "/to-rebind", "/to-file", "/to-creds"])(
        "a redirect to %s keeps today's error; only the first hop was requested",
        async (route) => {
            expect((await saveLink(U(route))).done).toEqual({ status: "error", error: { code: "error.api.link.invalid" } });
            expect(hitPaths()).toEqual([route]);
        },
    );

    it("a link to a private host, with credentials, or on another port keeps today's error without a request", async () => {
        const strict = { ...policy, ports: undefined };
        for (const url of [
            "http://127.0.0.1:9000/tunnel?id=x", "http://10.0.0.5/a.png", "http://169.254.169.254/latest/meta-data/", "http://[::1]/a.png", "http://localhost/a.png",
            `http://user:pass@media.test:${port}/a.png`, U("/a.png", "rebind.test"),
        ]) {
            expect((await saveLink(url)).done, url).toEqual({ status: "error", error: { code: "error.api.link.invalid" } });
        }
        // a non-http(s) scheme never gets as far as a job: the helper's own input check answers 400
        expect((await post("/fetch", { id: rid(), url: "file:///etc/passwd" })).status).toBe(400);
        await helper.close();
        await startHelper({ fetchPolicy: strict });
        expect((await saveLink(U("/a.png"))).done).toEqual({ status: "error", error: { code: "error.api.link.invalid" } });
        expect((await saveLink("http://media.test:8080/a.png")).done).toEqual({ status: "error", error: { code: "error.api.link.invalid" } });
        expect(hits).toEqual([]);
    });

    it("never logs the query of the link (a signed token), only host and path", async () => {
        await saveLink(DISCORD("a.png"));
        await saveLink(DISCORD("page.html"));
        const text = logged.join("\n");
        expect(text).toMatch(/direct link/);
        expect(text).toContain("media.test:" + port + "/a.png");
        expect(text).not.toMatch(/SECRETTOKEN|hm=|ex=|is=2|\?/);
    });

    it("an `items` list that names an item the file does not have fails with today's error", async () => {
        expect((await saveLink(U("/a.png"), { items: [3] })).done).toEqual({ status: "error", error: { code: "error.api.link.invalid" } });
        expect((await saveLink(U("/a.png"), { item_count: 4 })).done).toEqual({ status: "error", error: { code: "error.api.link.invalid" } });
    });
});

describe("picker and redirect items are fetched with the same rule (no downloadToFile injected)", () => {
    beforeEach(async () => {
        logged = [];
        await startHelper();
    });
    afterEach(() => helper.close());

    it("a public picker item downloads; one that redirects somewhere private fails alone, with error.webp.bad_source", async () => {
        cobalt = async () => ({
            status: "picker",
            picker: [
                { i: 0, type: "photo", url: U("/a.png") },
                { i: 1, type: "photo", url: U("/to-metadata") },
                { i: 2, type: "photo", url: U("/r1") },
                { i: 3, type: "photo", url: U("/a.jpg") },
            ],
        });
        const { done } = await saveLink("https://x.com/a/status/1", { items: "all", item_count: 4 });
        expect(done.status).toBe("done");
        expect(done.items.map((i: any) => [i.i, i.status, i.code ?? i.contentType])).toEqual([
            [0, "done", "image/png"],
            [1, "error", "error.webp.bad_source"],
            [2, "done", "image/png"],
            [3, "done", "image/jpeg"],
        ]);
        expect(hitPaths()).toEqual(["/a.png", "/to-metadata", "/r1", "/r2", "/r3", "/a.png", "/a.jpg"]);
    });

    it("a redirect item on a forbidden port or to a private address is refused; the job still fails whole with the same code", async () => {
        cobalt = async () => ({ status: "redirect", url: U("/to-private"), filename: "x.mp4" });
        // a plain redirect answer reaches resolveSource as {url, filename}
        const { done } = await saveLink("https://x.com/a/status/1");
        expect(done).toEqual({ status: "error", error: { code: "error.webp.bad_source" } });
    });

    it("cobalt's own /tunnel is still fetched plainly (it is on the loopback, by design); any other path on that origin is not", async () => {
        await helper.close();
        await startHelper({ cobaltOrigin: `http://127.0.0.1:${port}`, fetchPolicy: { ports: null, lookup } }); // the REAL address rule
        routes["/tunnel"] = send(PNG, "image/png");
        cobalt = async () => ({ status: "tunnel", url: `http://127.0.0.1:${port}/tunnel?id=abc&sig=def`, filename: "clip.png" });
        const { done } = await saveLink("https://x.com/a/status/1");
        expect(done).toMatchObject({ status: "done", contentType: "image/png", service: "x", title: "clip" });
        expect(hits.map((h) => h.url)).toEqual(["/tunnel?id=abc&sig=def"]);
        // the loopback origin's other paths (a redirect item pointing at it, say) go through the public-only fetch
        hits.length = 0;
        cobalt = async () => ({ status: "redirect", url: `http://127.0.0.1:${port}/a.png`, filename: "a.png" });
        expect((await saveLink("https://x.com/a/status/2")).done).toEqual({ status: "error", error: { code: "error.webp.bad_source" } });
        expect(hits).toEqual([]);
    });
});

// ---- the real helper, the real ffmpeg --------------------------------------------------------------------------

real("a direct link through the real helper with the real ffmpeg", () => {
    const fx: Record<string, string> = {};
    const mk = (name: string, args: string[]) => {
        const out = path.join(root, `real-${name}`);
        const r = spawnSync(FFMPEG, ["-v", "error", "-y", ...args, out]);
        if (r.status !== 0) throw new Error(`ffmpeg ${name}: ${r.stderr}`);
        fx[name] = out;
    };
    beforeAll(() => {
        mk("lia.png", ["-f", "lavfi", "-i", "testsrc2=s=800x600:r=1", "-frames:v", "1"]);
        mk("a.jpg", ["-f", "lavfi", "-i", "testsrc2=s=600x800:r=1", "-frames:v", "1", "-q:v", "3"]);
        mk("a.gif", ["-f", "lavfi", "-i", "testsrc2=s=160x120:d=1:r=10"]);
        mk("v.mp4", ["-f", "lavfi", "-i", "testsrc2=s=640x360:d=1:r=30", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an"]);
        mk("v.mov", ["-f", "lavfi", "-i", "testsrc2=s=320x240:d=1:r=30", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an"]);
        // audio only, in an mp4 container: a container we know, with nothing to show
        mk("audio.m4a", ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "aac"]);
        mk("audio-in.mp4", ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "aac", "-f", "mp4"]);
    });

    beforeEach(async () => {
        logged = [];
        for (const [name, file] of Object.entries(fx)) {
            const type = name.endsWith(".png") ? "image/png" : name.endsWith(".jpg") ? "image/jpeg" : name.endsWith(".gif") ? "image/gif" : "application/octet-stream";
            routes[`/${name}`] = send(readFileSync(file), type);
        }
        cobalt = async () => INVALID;
        // the real probe, the real thumb: only the policy (a local origin) and the stubbed cobalt differ
        await startHelper({ ffmpegPath: () => FFMPEG, probe: undefined });
    });
    afterEach(() => helper.close());

    it("a PNG: probed, a JPEG thumb made, the file and the thumb served", async () => {
        const { id, done } = await saveLink(DISCORD("lia.png"));
        expect(done).toMatchObject({ status: "done", contentType: "image/png", ext: "png", duration: null, width: 800, height: 600, title: "lia", service: "media" });
        const thumb = await call(`/fetch/${id}/thumb`);
        expect(thumb.status).toBe(200);
        expect(thumb.headers.get("content-type")).toBe("image/jpeg");
        const file = await call(`/fetch/${id}/file`);
        expect(Buffer.from(await file.arrayBuffer()).equals(readFileSync(fx["lia.png"]!))).toBe(true);
    });

    it("a JPEG, a GIF, an mp4 and a mov are saved as what they are", async () => {
        expect((await saveLink(U("/a.jpg"))).done).toMatchObject({ status: "done", contentType: "image/jpeg", width: 600, height: 800 });
        expect((await saveLink(U("/a.gif"))).done).toMatchObject({ status: "done", contentType: "image/gif", ext: "gif", width: 160, height: 120 });
        const mp4 = (await saveLink(U("/v.mp4"))).done;
        expect(mp4).toMatchObject({ status: "done", contentType: "video/mp4", ext: "mp4", width: 640, height: 360 });
        expect(mp4.duration).toBeGreaterThan(0.5);
        expect(mp4.duration).toBeLessThan(1.5);
        expect((await saveLink(U("/v.mov"))).done).toMatchObject({ status: "done", contentType: "video/quicktime", ext: "mov", width: 320, height: 240 });
    });

    it("html, an audio file and an audio-only mp4 keep today's error", async () => {
        routes["/page.html"] = send(HTML, "text/html");
        for (const route of ["/page.html", "/audio.m4a", "/audio-in.mp4"]) {
            expect((await saveLink(U(route))).done, route).toEqual({ status: "error", error: { code: "error.api.link.invalid" } });
        }
    });
});

// ---- security review fixes (S1 hang, S2 pixel bombs, S4 early sniff, nits) ---------------------------------------

describe("S1: a socket that closes without a response settles the fetch (it used to hang forever)", () => {
    let raw: net.Server;
    let rawPort: number;
    let mode: "101" | "close" | "reset-after-headers" | "status-999" | "status-100-then-close";
    beforeAll(async () => {
        raw = net.createServer((sock) => {
            sock.on("error", () => {});
            sock.once("data", () => {
                if (mode === "101") sock.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n");
                else if (mode === "close") return void sock.end();
                else if (mode === "reset-after-headers") {
                    sock.write("HTTP/1.1 200 OK\r\ncontent-type: image/png\r\ncontent-length: 5000\r\n\r\nabc");
                    return void setTimeout(() => sock.destroy(), 20);
                } else if (mode === "status-999") return void sock.end("HTTP/1.1 999 Odd\r\ncontent-length: 0\r\n\r\n");
                else if (mode === "status-100-then-close") sock.write("HTTP/1.1 100 Continue\r\n\r\n");
                if (mode === "101") setTimeout(() => sock.destroy(), 20);
                if (mode === "status-100-then-close") setTimeout(() => sock.destroy(), 20);
            });
        });
        await new Promise<void>((r) => raw.listen(0, "127.0.0.1", () => r()));
        rawPort = (raw.address() as any).port;
    });
    afterAll(() => raw?.close());
    const R = () => `http://media.test:${rawPort}/x.png`;
    const dl = (o: Record<string, unknown> = {}) =>
        downloadToFile({ url: R(), dest: path.join(root, rid()), fetchImpl: makeSafeFetch({ ...policy, idleMs: 20_000 }), signal: AbortSignal.timeout(10_000), ...o } as any);

    it.each([
        ["a 101 Switching Protocols", "101"],
        ["a close with no response at all", "close"],
        ["a 100 Continue and then a close", "status-100-then-close"],
    ] as const)("%s rejects at once (download_failed), long before the idle or job timers", async (_n, m) => {
        mode = m;
        const t0 = Date.now();
        await expect(dl()).rejects.toMatchObject({ code: "error.webp.download_failed" });
        expect(Date.now() - t0).toBeLessThan(2000);
    });

    it("a connection reset mid-body is a failed download", async () => {
        mode = "reset-after-headers";
        await expect(dl()).rejects.toMatchObject({ code: "error.webp.download_failed" });
    });

    it("a status outside 200-599 is a failed download, not a RangeError", async () => {
        mode = "status-999";
        await expect(dl()).rejects.toMatchObject({ code: "error.webp.download_failed" });
    });

    it("through the helper: the job ends with today's error (and frees the helper), it does not hang", async () => {
        cobalt = async () => INVALID;
        await startHelper();
        try {
            for (const m of ["101", "close", "status-999"] as const) {
                mode = m;
                const t0 = Date.now();
                expect((await saveLink(R())).done, m).toEqual({ status: "error", error: { code: "error.api.link.invalid" } });
                expect(Date.now() - t0).toBeLessThan(3000);
            }
            // the helper took the next job straight away
            expect((await saveLink(U("/a.png"))).done).toMatchObject({ status: "done" });
        } finally {
            await helper.close();
        }
    });
});

describe("imageDimensions: the pixel size from header bytes, no decoder", () => {
    it.each([
        ["png", pngOf(16000, 12000), 16000, 12000],
        ["jpeg (SOF0 after an APP1)", jpegOf(8000, 6000), 8000, 6000],
        ["jpeg (progressive SOF2)", jpegOf(4032, 3024, 0xc2), 4032, 3024],
        ["jpeg (a 60 KB EXIF before the frame)", jpegOf(1920, 1080, 0xc0, 60_000), 1920, 1080],
        ["gif", gifOf(480, 270), 480, 270],
        ["webp VP8X", webpX(12000, 9000), 12000, 9000],
        ["webp VP8L", webpL(4000, 3000), 4000, 3000],
        ["webp VP8", webpLossy(1600, 1200), 1600, 1200],
        ["heic", heicOf(8064, 6048), 8064, 6048],
        ["heic (the biggest ispe wins: a grid and its tiles)", heicOf(512, 512, [8192, 6144]), 8192, 6144],
    ])("%s", (_n, bytes, w, h) => expect(imageDimensions(bytes)).toEqual({ width: w, height: h }));

    it.each([
        ["a png with no IHDR", Buffer.concat([pngOf(10, 10).subarray(0, 12), Buffer.from("JUNK"), Buffer.alloc(20)])],
        ["a truncated png", pngOf(10, 10).subarray(0, 20)],
        ["a jpeg that reaches the scan with no frame header", Buffer.from([0xff, 0xd8, 0xff, 0xda, 0, 2, 0, 0, 0, 0])],
        ["a jpeg with a zero-length segment", Buffer.from([0xff, 0xd8, 0xff, 0xe1, 0, 0, 0, 0, 0, 0, 0, 0])],
        ["a truncated jpeg", jpegOf(10, 10).subarray(0, 25)],
        ["a heic with only an ftyp box (12 magic bytes and nothing behind them)", Buffer.concat([ftypHeic, Buffer.alloc(100)])],
        ["a heic whose ftyp box claims 4 GB", Buffer.concat([u32(0xffffffff), Buffer.from("ftypheic"), Buffer.alloc(100)])],
        ["a heic whose meta is cut off", heicOf(100, 100).subarray(0, 40)],
        ["an mp4", MP4],
        ["empty", Buffer.alloc(0)],
    ])("%s is null", (_n, bytes) => expect(imageDimensions(bytes)).toBeNull());

    it("directHeadOk: the first 64 bytes of an accepted file, nothing else", () => {
        for (const ok of [PNG, JPEG, GIF, webpX(10, 10), heicOf(10, 10), MP4, WEBM]) expect(directHeadOk(ok.subarray(0, 64)), String(ok.subarray(0, 12))).toBe(true);
        for (const no of [HTML, JSON_BODY, MP3, NOISE, Buffer.alloc(0), Buffer.concat([u32(0xffffffff), Buffer.from("ftypheic"), Buffer.alloc(60)]), Buffer.concat([u32(12), Buffer.from("ftypheic")])]) {
            expect(directHeadOk(no.subarray(0, 64))).toBe(false);
        }
    });
});

describe("S2: pixel bombs are refused from the header, before probe, thumb or ffmpeg", () => {
    let probes: string[];
    beforeEach(async () => {
        cobalt = async () => INVALID;
        probes = [];
        logged = [];
        await startHelper({
            probe: async (f: string) => {
                probes.push(f);
                return probeStub(f);
            },
        });
        routes["/bomb.png"] = send(pngOf(16000, 16000), "image/png"); // a few KB on the wire, 256 MP decoded
        routes["/bomb.jpg"] = send(jpegOf(20000, 20000), "image/jpeg");
        routes["/bomb.gif"] = send(gifOf(12000, 12000), "image/gif");
        routes["/bomb.webp"] = send(webpX(16000, 16000), "image/webp");
        routes["/bomb.heic"] = send(heicOf(16000, 16000), "image/heic");
        routes["/edge-ok.png"] = send(pngOf(8000, 8000), "image/png"); // exactly 64 MP
        routes["/edge-over.png"] = send(pngOf(8001, 8000), "image/png");
        routes["/ok.heic"] = send(heicOf(4032, 3024), "image/heic");
        routes["/bare.heic"] = send(Buffer.concat([ftypHeic, Buffer.alloc(3000)]), "image/heic");
        routes["/liar.heic"] = send(Buffer.concat([u32(0xffffffff), Buffer.from("ftypheic"), Buffer.alloc(3000)]), "image/heic");
        routes["/nodims.png"] = send(Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(3000, 1)]), "image/png");
    });
    afterEach(() => helper.close());
    const TOO_LARGE = { status: "error", error: { code: "error.studio.too_large" } };

    it.each(["/bomb.png", "/bomb.jpg", "/bomb.gif", "/bomb.webp", "/bomb.heic"])("a direct link to %s: error.studio.too_large, no probe", async (route) => {
        expect((await saveLink(U(route))).done).toEqual(TOO_LARGE);
        expect(probes).toEqual([]);
    });

    it("the limit is 64 MP, exactly (a 48 MP phone photo saves)", async () => {
        expect((await saveLink(U("/edge-ok.png"))).done).toMatchObject({ status: "done", contentType: "image/png" });
        expect((await saveLink(U("/edge-over.png"))).done).toEqual(TOO_LARGE);
        await helper.close();
        await startHelper({ probe: probeStub, maxSavePixels: 1_000_000 });
        expect((await saveLink(U("/a.png"))).done).toMatchObject({ status: "done" }); // 640x360
        routes["/mp.png"] = send(pngOf(1000, 1001), "image/png");
        expect((await saveLink(U("/mp.png"))).done).toEqual(TOO_LARGE);
    });

    it("a direct link whose header does not say its size is not an image (bad bytes keep today's error)", async () => {
        for (const route of ["/nodims.png", "/bare.heic", "/liar.heic"]) {
            expect((await saveLink(U(route))).done, route).toEqual({ status: "error", error: { code: "error.api.link.invalid" } });
        }
        expect(probes).toEqual([]);
        // a HEIC with its ispe is fine
        expect((await saveLink(U("/ok.heic"))).done).toMatchObject({ status: "done", contentType: "image/heic", ext: "heic" });
    });

    it("picker and gallery photo items get the same refusal, per item (the others are saved)", async () => {
        cobalt = async () => ({
            status: "picker",
            picker: [
                { i: 0, type: "photo", url: U("/a.png") },
                { i: 1, type: "photo", url: U("/bomb.png") },
                { i: 2, type: "photo", url: U("/bomb.heic") },
                { i: 3, type: "photo", url: U("/a.jpg") },
            ],
        });
        const { done } = await saveLink("https://x.com/a/status/1", { items: "all", item_count: 4 });
        expect(done.status).toBe("done");
        expect(done.items.map((i: any) => [i.i, i.status, i.code ?? i.contentType])).toEqual([
            [0, "done", "image/png"],
            [1, "error", "error.studio.too_large"],
            [2, "error", "error.studio.too_large"],
            [3, "done", "image/jpeg"],
        ]);
        expect(probes).toHaveLength(2); // only the two good photos were ever probed
        // a single photo post (a plain answer) is the same
        cobalt = async () => ({ status: "redirect", url: U("/bomb.jpg"), filename: "p.jpg" });
        expect((await saveLink("https://x.com/a/status/2")).done).toEqual(TOO_LARGE);
    });

    it("a still whose header the reader cannot parse on a picker item keeps today's path (ffmpeg decides), not a new refusal", async () => {
        cobalt = async () => ({ status: "redirect", url: U("/nodims.png"), filename: "p.png" });
        expect((await saveLink("https://x.com/a/status/3")).done).toMatchObject({ status: "done", contentType: "image/png" });
    });
});

real("S2 with the real ffmpeg: a 16000x16000 PNG never reaches the thumb step", () => {
    it("is refused from its header (a few KB), and nothing but the header was read", async () => {
        cobalt = async () => INVALID;
        // a real PNG of that size is highly compressible: ffmpeg writes it in a moment, at a few hundred KB
        const out = path.join(root, "bomb-real.png");
        const r = spawnSync(FFMPEG, ["-v", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=16000x16000", "-frames:v", "1", "-compression_level", "9", out]);
        expect(r.status).toBe(0);
        routes["/bomb-real.png"] = send(readFileSync(out), "image/png");
        await startHelper({ ffmpegPath: () => FFMPEG, probe: undefined });
        try {
            const t0 = Date.now();
            expect((await saveLink(U("/bomb-real.png"))).done).toEqual({ status: "error", error: { code: "error.studio.too_large" } });
            expect(Date.now() - t0).toBeLessThan(5000);
        } finally {
            await helper.close();
        }
    });
});

describe("S4: a direct link's first bytes decide; an unacceptable body is never downloaded", () => {
    it("a large html body is cut at its first chunk: the origin sees the socket close, only a chunk or two were sent", async () => {
        cobalt = async () => INVALID;
        routes["/huge.html"] = endless("text/html", Buffer.from("<!doctype html><html><body>"));
        routes["/huge.mp3"] = endless("audio/mpeg", MP3);
        routes["/huge.bin"] = endless("application/octet-stream", Buffer.from(Array.from({ length: 200 }, (_, i) => (i * 7 + 3) % 251)));
        await startHelper();
        try {
            for (const route of ["/huge.html", "/huge.mp3", "/huge.bin"]) {
                expect((await saveLink(U(route))).done, route).toEqual({ status: "error", error: { code: "error.api.link.invalid" } });
            }
            await vi.waitFor(() => expect(streamed.length === 3 && streamed.every((s) => s.closed)).toBe(true), { timeout: 5000 });
            // the cap is 200 MB: the first 64 bytes were enough to stop, so no more than a few chunks were ever sent
            expect(Math.max(...streamed.map((s) => s.written))).toBeLessThan(2 * 1024 * 1024);
        } finally {
            await helper.close();
        }
    });

    it("downloadToFile's acceptHead judges a body shorter than the head on its own, and ends the download at the first bad chunk", async () => {
        const dl = (url: string, accept: (h: Buffer) => boolean) =>
            downloadToFile({ url, dest: path.join(root, rid()), fetchImpl: makeSafeFetch(policy), acceptHead: accept } as any);
        const seen: number[] = [];
        const accept = (h: Buffer) => (seen.push(h.length), sniffType(h) !== null);
        await expect(dl(U("/page.html"), accept)).rejects.toMatchObject({ code: "error.webp.bad_source" });
        expect(seen).toEqual([HTML.length]); // shorter than 64 bytes: judged whole, at the end
        seen.length = 0;
        await expect(dl(U("/a.png"), accept)).resolves.toBe(PNG.length);
        expect(seen).toEqual([64]);
        await expect(dl(U("/empty.png"), accept)).rejects.toMatchObject({ code: "error.webp.bad_source" });
    });
});

describe("nits", () => {
    it("filenameFromUrl strips C1 controls, zero-width and bidi override/isolate characters from the title", () => {
        const f = (p: string) => filenameFromUrl(new URL(`https://x.com/a/${p}`));
        expect(f("%E2%80%AEgnp.exe")).toBe("gnp.exe"); // U+202E right-to-left override
        expect(f("a%E2%81%A6b%E2%81%A9c.png")).toBe("abc.png"); // isolates
        expect(f("a%E2%80%8Bb%EF%BB%BFc.png")).toBe("abc.png"); // zero-width space, BOM
        expect(f("a%C2%85b%C2%9Fc.png")).toBe("abc.png"); // C1
        expect(f("%E2%80%AE%E2%80%8B")).toBeNull();
    });
    it("logUrl never shows userinfo or the query", () => {
        expect(logUrl("https://user:hunter2@cdn.example.com/a/b.png?x=1")).toBe("cdn.example.com/a/b.png");
    });
});
