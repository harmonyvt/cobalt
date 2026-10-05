import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it } from "vitest";
import worker from "../src/index";
import { STUDIO_CSP, STUDIO_SID } from "../src/studio";
import { STUDIO_HTML } from "../src/studio/page.generated";
import config from "../cloudflare.config";
import type { Env } from "../src/keys";

const SID = "q3Zk9vT1mW8aLm2xPq8Rt4";
const ORIGIN = "https://cobalt.capybaraharmony.com";

// The exact header set pinned in STUDIO-CONTRACT.md.
const CONTRACT_CSP =
    "default-src 'self'; connect-src https://api.capybaraharmony.com; media-src https://api.capybaraharmony.com blob:; img-src 'self' data: blob: https://media.capybaraharmony.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'";

let assetCalls: string[];
let assetStatus: number;
let env: Env;
beforeEach(() => {
    assetCalls = [];
    assetStatus = 200;
    env = {
        ASSETS: {
            fetch: async (r: Request) => (assetCalls.push(new URL(r.url).pathname), new Response("asset", { status: assetStatus })),
        } as unknown as Fetcher,
    } as Env;
});

const get = (path: string, init?: RequestInit) => worker.fetch(new Request(ORIGIN + path, init), env);

describe("routing config", () => {
    it("runs the Worker first for /studio and keeps /api/keys", () => {
        const rwf = (config as any).worker.assets.runWorkerFirst as string[];
        expect(rwf).toEqual(expect.arrayContaining(["/api/keys", "/api/keys/*", "/studio", "/studio/*"]));
        expect(rwf).toHaveLength(11); // plus the library and logs routes, see library.test.ts and logs.test.ts
    });
});

describe("GET /studio/<sid>", () => {
    it("serves the page with exactly the contract headers and never touches ASSETS", async () => {
        const res = await get(`/studio/${SID}`);
        expect(res.status).toBe(200);
        expect(res.headers.get("content-security-policy")).toBe(CONTRACT_CSP);
        expect(STUDIO_CSP).toBe(CONTRACT_CSP);
        expect(res.headers.get("referrer-policy")).toBe("no-referrer");
        expect(res.headers.get("cache-control")).toBe("no-store");
        expect(res.headers.get("x-content-type-options")).toBe("nosniff");
        expect(res.headers.get("content-type")).toBe("text/html; charset=utf-8");
        expect(res.headers.get("cross-origin-embedder-policy")).toBeNull();
        expect(res.headers.get("cross-origin-opener-policy")).toBeNull();
        expect(await res.text()).toBe(STUDIO_HTML);
        expect(assetCalls).toEqual([]);
    });

    it("answers HEAD with the headers and no body, and rejects other methods", async () => {
        const head = await get(`/studio/${SID}`, { method: "HEAD" });
        expect(head.status).toBe(200);
        expect(head.headers.get("content-security-policy")).toBe(CONTRACT_CSP);
        expect(await head.text()).toBe("");
        for (const method of ["POST", "PUT", "DELETE"]) {
            const r = await get(`/studio/${SID}`, { method });
            expect(r.status).toBe(405);
            expect(r.headers.get("allow")).toBe("GET, HEAD");
        }
        expect(assetCalls).toEqual([]);
    });

    it("accepts base62 ids only: exactly 22 chars of [0-9A-Za-z]", () => {
        expect(STUDIO_SID.test(`/studio/${SID}`)).toBe(true);
        expect(STUDIO_SID.test("/studio/" + "0".repeat(22))).toBe(true);
        expect(STUDIO_SID.test("/studio/" + "Z".repeat(22))).toBe(true);
    });

    it.each([
        ["/studio"],
        ["/studio/"],
        ["/studio/short"],
        ["/studio/" + "a".repeat(21)],
        ["/studio/" + "a".repeat(23)],
        [`/studio/${SID.slice(0, 21)}-`],
        [`/studio/${SID.slice(0, 21)}_`],
        [`/studio/${SID.slice(0, 21)}.`],
        [`/studio/${SID}/`],
        [`/studio/${SID}/source`],
        [`/studio/${SID}/render`],
        [`/studio/${SID}%2f`],
        ["/studios/" + SID],
    ])("answers %s with a 404 that is never the page", async (path) => {
        assetStatus = 404;
        const res = await get(path);
        if (path.startsWith("/studios/")) {
            // not a studio path: goes straight to the assets like any other page
            expect(assetCalls).toEqual([path]);
            return;
        }
        expect(res.status).toBe(404);
        expect(res.headers.get("content-security-policy")).toBeNull();
        expect(await res.text()).not.toContain("<video");
    });

    it("never turns an unexpected asset 200 under /studio into a page", async () => {
        assetStatus = 200;
        const res = await get(`/studio/${SID}x`);
        expect(res.status).toBe(404);
    });
});

describe("other paths", () => {
    it.each([["/"], ["/about"], ["/studio.html"], ["/favicon.png"], ["/api/other"]])("%s still goes to ASSETS", async (path) => {
        const res = await get(path);
        expect(await res.text()).toBe("asset");
        expect(assetCalls).toEqual([path]);
    });
});

describe("embedded page", () => {
    it("page.generated.ts is in sync with page.html (run npm run studio:build)", () => {
        const html = readFileSync(new URL("../src/studio/page.html", import.meta.url), "utf8");
        expect(STUDIO_HTML).toBe(html);
    });

    it("is self-contained and CSP-clean", () => {
        expect(STUDIO_HTML).toMatch(/<video id="vid" crossorigin="anonymous" playsinline/);
        expect(STUDIO_HTML).toContain('name="viewport"');
        // only inline scripts (CSP script-src is 'self' 'unsafe-inline')
        expect(STUDIO_HTML).not.toMatch(/<script[^>]*\bsrc=/i);
        // every absolute URL it may load is on the CSP allow list
        const hosts = new Set([...STUDIO_HTML.matchAll(/https?:\/\/([a-z0-9.-]+)/gi)].map((m) => m[1]));
        for (const h of hosts) {
            expect(["api.capybaraharmony.com", "fonts.googleapis.com", "fonts.gstatic.com", "media.capybaraharmony.com"]).toContain(h);
        }
    });

    it("has a valid inline script", () => {
        const m = /<script>([\s\S]*)<\/script>/.exec(STUDIO_HTML);
        expect(m).toBeTruthy();
        expect(() => new Function(m![1])).not.toThrow();
    });

    it("only honours ?api= on localhost", () => {
        expect(STUDIO_HTML).toMatch(/\^\(localhost\|127\\\.0\\\.0\\\.1\|\\\[::1\\\]\)\$/);
    });
});
