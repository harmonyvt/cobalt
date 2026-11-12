import { readFileSync } from "node:fs";
import { Window } from "happy-dom";
import { describe, expect, it } from "vitest";
import { wire } from "../src/background";
import type { Ext, StorageArea } from "../src/lib/browser";
import { relocateHost, scanInstagram, scanTwitch, scanX, scanYouTube } from "../src/lib/find";
import { createSave, followSave, pollSave } from "../src/lib/save";
import { chromeApproveUrl, parseRedirect, pkceChallenge, prefersWebAuthFlow, runSignIn, safariApproveUrl } from "../src/lib/signin";
import { popupView, publicAuth, spriteCss } from "../src/lib/view";
import { canonicalInstagram, canonicalTwitch, canonicalX, canonicalYouTube } from "../src/lib/urls";

const HOME = "https://x.com/home";
const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const CODE = "c".repeat(43);

function page(url: string, html: string): Document {
    const window = new Window({ url });
    window.document.body.innerHTML = html;
    return window.document as unknown as Document;
}

describe("canonical post URLs", () => {
    it("uses the post, not the feed, and drops a photo suffix and tracking", () => {
        expect(canonicalX("/capy/status/1234567890123456789/photo/1?s=20", HOME)).toBe("https://x.com/capy/status/1234567890123456789");
        expect(canonicalX("https://twitter.com/capy/status/99", "https://twitter.com/home")).toBe("https://x.com/capy/status/99");
        expect(canonicalX("https://x.com/home", HOME)).toBeNull();
        expect(canonicalX("https://x.com/i/status/99", HOME)).toBeNull();
    });
    it("keeps a YouTube video id and a Shorts id, and drops the playlist", () => {
        expect(canonicalYouTube("/watch?v=dQw4w9WgXcQ&list=PLxxxx", "https://www.youtube.com/")).toBe("https://www.youtube.com/watch?v=dQw4w9WgXcQ");
        expect(canonicalYouTube("/shorts/dQw4w9WgXcQ", "https://www.youtube.com/")).toBe("https://www.youtube.com/shorts/dQw4w9WgXcQ");
        expect(canonicalYouTube("https://youtu.be/dQw4w9WgXcQ", "https://www.youtube.com/")).toBe("https://www.youtube.com/watch?v=dQw4w9WgXcQ");
        expect(canonicalYouTube("/watch?v=short", "https://www.youtube.com/")).toBeNull();
    });
    it("keeps a Twitch clip slug, including clips.twitch.tv", () => {
        expect(canonicalTwitch("/somechannel/clip/FunnySlug", "https://www.twitch.tv/directory")).toBe("https://www.twitch.tv/somechannel/clip/FunnySlug");
        expect(canonicalTwitch("/FunnySlug", "https://clips.twitch.tv/")).toBe("https://clips.twitch.tv/FunnySlug");
        expect(canonicalTwitch("/somechannel/videos/1", "https://www.twitch.tv/")).toBeNull();
    });
    it("canonicalises Instagram posts and reels", () => {
        expect(canonicalInstagram("/capy/p/Dc2QA4ng-US/?img_index=1", "https://www.instagram.com/")).toBe("https://www.instagram.com/p/Dc2QA4ng-US/");
        expect(canonicalInstagram("/reel/AbCdEfGhijk/", "https://www.instagram.com/")).toBe("https://www.instagram.com/reel/AbCdEfGhijk/");
        expect(canonicalInstagram("/reels/AbCdEfGhijk/", "https://www.instagram.com/reels/")).toBe("https://www.instagram.com/reel/AbCdEfGhijk/");
        expect(canonicalInstagram("/", "https://www.instagram.com/")).toBeNull();
    });
});

describe("finding posts in a page", () => {
    it("puts a button on every X post, including one quoted inside another, and not on the home URL", () => {
        const doc = page(
            HOME,
            `<article data-testid="tweet">
                <a href="/capy/status/111"><time>1h</time></a>
                <div role="group"></div>
                <a href="/other/status/222">quoted</a>
            </article>
            <article data-testid="tweet">
                <a href="/third/status/333/photo/2"><time>2h</time></a>
                <div role="group"></div>
            </article>`,
        );
        const found = scanX(doc, HOME);
        expect(found.map((f) => f.url)).toEqual(["https://x.com/capy/status/111", "https://x.com/third/status/333"]);
        expect(found[0]!.mount.getAttribute("role")).toBe("group");
        expect(found.every((f) => f.url !== HOME)).toBe(true);
    });

    it("reads a YouTube card out of an open shadow root, and the watch-page action row", () => {
        const doc = page(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            `<ytd-rich-item-renderer id="card"></ytd-rich-item-renderer>
             <div id="top-level-buttons-computed"></div>`,
        );
        const card = doc.querySelector("#card")!;
        const shadow = card.attachShadow({ mode: "open" });
        shadow.innerHTML = `<a id="thumbnail" href="/watch?v=abcdefghijk&list=PL"></a><h3 id="meta"></h3>`;
        const found = scanYouTube(doc, "https://www.youtube.com/watch?v=dQw4w9WgXcQ");
        expect(found.map((f) => [f.url, f.variant])).toEqual([
            ["https://www.youtube.com/watch?v=abcdefghijk", "icon"],
            ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "pill"],
        ]);
        expect(found[0]!.mount.id).toBe("meta");
        expect(found[1]!.mount.id).toBe("top-level-buttons-computed");
    });

    it("finds a Shorts card and a Twitch clip card without using the listing URL", () => {
        const shorts = page(
            "https://www.youtube.com/",
            `<ytd-reel-item-renderer><a href="/shorts/abcdefghijk"></a></ytd-reel-item-renderer>`,
        );
        expect(scanYouTube(shorts, "https://www.youtube.com/").map((f) => f.url)).toEqual(["https://www.youtube.com/shorts/abcdefghijk"]);

        const clips = page(
            "https://www.twitch.tv/directory/clips",
            `<article id="card"><a data-a-target="preview-card-image-link" href="/somechannel/clip/FunnySlug"></a><a id="title" href="/somechannel/clip/FunnySlug">title</a></article>`,
        );
        const twitch = scanTwitch(clips, "https://www.twitch.tv/directory/clips");
        expect(twitch.map((f) => f.url)).toEqual(["https://www.twitch.tv/somechannel/clip/FunnySlug"]);
        expect(twitch[0]!.mount.id).toBe("title");
        expect(twitch[0]!.mount.tagName).toBe("A");
    });

    it("skips a YouTube lockup that has no title row, and mounts on the metadata when it has one", () => {
        const doc = page(
            "https://www.youtube.com/results?search_query=capy",
            `<yt-lockup-view-model id="bare"><a href="/watch?v=abcdefghijk">thumb</a></yt-lockup-view-model>
             <yt-lockup-view-model id="full">
               <a href="/watch?v=dQw4w9WgXcQ">thumb</a>
               <yt-lockup-metadata-view-model id="meta"><a href="/watch?v=dQw4w9WgXcQ">title</a></yt-lockup-metadata-view-model>
             </yt-lockup-view-model>`,
        );
        const found = scanYouTube(doc, "https://www.youtube.com/results?search_query=capy");
        expect(found.map((f) => f.url)).toEqual(["https://www.youtube.com/watch?v=dQw4w9WgXcQ"]);
        expect(found[0]!.mount.id).toBe("meta");
        expect(found[0]!.mount).not.toBe(doc.querySelector("#full"));
    });

    it("finds each Instagram post in the feed, and a reel permalink that has no card link", () => {
        const feed = page(
            "https://www.instagram.com/",
            `<article>
                <a href="/p/AAAAAAAAAAA/"></a>
                <section><svg aria-label="Like"></svg></section>
            </article>
            <article>
                <a href="/reel/BBBBBBBBBBB/"></a>
                <section><svg aria-label="Like"></svg></section>
            </article>`,
        );
        expect(scanInstagram(feed, "https://www.instagram.com/").map((f) => f.url)).toEqual([
            "https://www.instagram.com/p/AAAAAAAAAAA/",
            "https://www.instagram.com/reel/BBBBBBBBBBB/",
        ]);
        const reel = page("https://www.instagram.com/reel/CCCCCCCCCCC/", `<main><section><svg aria-label="Like"></svg></section></main>`);
        expect(scanInstagram(reel, "https://www.instagram.com/reel/CCCCCCCCCCC/").map((f) => f.url)).toEqual([
            "https://www.instagram.com/reel/CCCCCCCCCCC/",
        ]);
    });

    it("does not inject on an Instagram page that only says the post is unavailable", () => {
        const doc = page(
            "https://www.instagram.com/p/AAAAAAAAAAA/",
            `<main><section><h2>Sorry, this page isn't available.</h2><p>The link may be broken, or the post may have been removed.</p></section></main>`,
        );
        expect(scanInstagram(doc, "https://www.instagram.com/p/AAAAAAAAAAA/")).toEqual([]);
    });

    it("waits for Share on a Twitch clip page, then mounts beside it", () => {
        const doc = page("https://www.twitch.tv/somechannel/clip/FunnySlug", `<main id="shell"><div id="signup">Sign up</div></main>`);
        const url = "https://www.twitch.tv/somechannel/clip/FunnySlug";
        expect(scanTwitch(doc, url)).toEqual([]);
        const actions = doc.createElement("div");
        actions.id = "actions";
        actions.innerHTML = `<button data-a-target="share-button">Share</button>`;
        doc.querySelector("#shell")!.appendChild(actions);
        const found = scanTwitch(doc, url);
        expect(found.map((f) => f.url)).toEqual([url]);
        expect(found[0]!.mount).toBe(actions);
        expect(found[0]!.variant).toBe("pill");
    });

    it("moves a host off <main> once Share's row exists", () => {
        const doc = page("https://www.twitch.tv/somechannel/clip/FunnySlug", `<main id="shell"></main><div id="actions"></div>`);
        const host = doc.createElement("span");
        host.className = "capystore-save";
        doc.querySelector("#shell")!.appendChild(host);
        expect(relocateHost(host, doc.querySelector("#actions")!)).toBe(true);
        expect(host.parentElement?.id).toBe("actions");
        expect(relocateHost(host, doc.querySelector("#actions")!)).toBe(false);
    });
});

describe("saving and polling", () => {
    it("posts origin extension, omits credentials, and polls until ready", async () => {
        const calls: { url: string; init: RequestInit }[] = [];
        let polls = 0;
        const fetchImpl = async (url: string, init?: RequestInit) => {
            calls.push({ url, init: init ?? {} });
            if (init?.method === "POST") {
                return Response.json({ status: "success", id: "sid", url: "https://cobalt.capybaraharmony.com/studio/sid" }, { status: 201 });
            }
            polls += 1;
            return Response.json({ status: polls < 2 ? "saving" : "ready", id: "sid" });
        };
        const started = await createSave(fetchImpl, KEY, "https://x.com/capy/status/1");
        expect(started).toEqual({ kind: "saving", id: "sid", studioUrl: "https://cobalt.capybaraharmony.com/studio/sid" });
        expect(calls[0]!.init.credentials).toBe("omit");
        expect(JSON.parse(String(calls[0]!.init.body))).toEqual({ url: "https://x.com/capy/status/1", origin: "extension", queue: true });
        expect(String(calls[0]!.init.headers && (calls[0]!.init.headers as Record<string, string>).authorization)).toBe(`Api-Key ${KEY}`);

        let t = 0;
        const done = await followSave({
            fetch: fetchImpl,
            key: KEY,
            id: "sid",
            studioUrl: "https://cobalt.capybaraharmony.com/studio/sid",
            now: () => t,
            sleep: async (ms) => {
                t += ms;
            },
            deadlineMs: 10_000,
        });
        expect(done.kind).toBe("saved");
        expect(calls.at(-1)!.init.credentials).toBe("omit");
    });

    it("a 401 is signed out, a network failure is offline, and a studio error is an error", async () => {
        const json = async (status: number, body: unknown) => Response.json(body, { status });
        expect((await createSave(async () => json(401, { error: { code: "error.api.auth.key.invalid" } }), KEY, "https://x.com/a/status/1")).kind).toBe("signed-out");
        expect((await createSave(async () => { throw new Error("offline"); }, KEY, "https://x.com/a/status/1")).kind).toBe("offline");
        expect(await pollSave(async () => json(200, { status: "error", error: { code: "error.studio.busy" } }), KEY, "sid", "https://cobalt.capybaraharmony.com/studio/sid")).toEqual({
            kind: "error",
            message: "error.studio.busy",
        });
    });
});

describe("sign-in", () => {
    it("Chrome trades the redirect code and checks state", async () => {
        const calls: string[] = [];
        const result = await runSignIn({
            ua: "Mozilla/5.0 Chrome/140.0.0.0 Safari/537.36",
            redirectUri: "https://" + "a".repeat(32) + ".chromiumapp.org/",
            launch: async (url) => {
                const state = new URL(url).searchParams.get("state");
                expect(new URL(url).pathname).toBe("/connect/extension");
                return `https://${"a".repeat(32)}.chromiumapp.org/?code=${CODE}&state=${state}`;
            },
            openTab: async () => {
                throw new Error("chrome should not open a tab");
            },
            fetch: async (url, init) => {
                calls.push(String(url));
                expect(init?.credentials).toBe("omit");
                const body = JSON.parse(String(init?.body));
                expect(body.verifier).toBeTypeOf("string");
                expect(body.code).toBe(CODE);
                return Response.json({ status: "success", key: KEY, session: { id: "sess-1", device: "Browser extension – Chrome on Mac" } });
            },
        });
        expect(result).toEqual({ ok: true, key: KEY, id: "sess-1", device: "Browser extension – Chrome on Mac" });
        expect(calls).toEqual(["https://api.capybaraharmony.com/auth/exchange"]);
    });

    it("a mismatched state is not exchanged", async () => {
        let fetched = false;
        const result = await runSignIn({
            ua: "Mozilla/5.0 Chrome/140.0.0.0",
            redirectUri: "https://" + "a".repeat(32) + ".chromiumapp.org/",
            launch: async () => `https://${"a".repeat(32)}.chromiumapp.org/?code=${CODE}&state=nope-nope-nope-nope`,
            openTab: async () => {},
            fetch: async () => {
                fetched = true;
                return Response.json({});
            },
        });
        expect(result.ok).toBe(false);
        expect(fetched).toBe(false);
    });

    it("Safari polls until the approve page has been used", async () => {
        let t = 1_000;
        const opened: string[] = [];
        let polls = 0;
        const result = await runSignIn({
            ua: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15",
            redirectUri: null,
            launch: null,
            openTab: async (url) => {
                opened.push(url);
            },
            now: () => t,
            sleep: async (ms) => {
                t += ms;
            },
            fetch: async (url) => {
                if (String(url).endsWith("/begin")) {
                    return Response.json({ status: "pending", device_code: "d".repeat(43), user_code: "u".repeat(43), expires_at: t + 20_000, interval: 1 }, { status: 201 });
                }
                polls += 1;
                if (polls === 1) return Response.json({ status: "pending", interval: 1 }, { status: 202 });
                return Response.json({ status: "success", key: KEY, session: { id: "sess-2", device: "Browser extension – Safari on Mac" } });
            },
        });
        expect(opened[0]).toContain("user_code=" + "u".repeat(43));
        expect(result).toEqual({ ok: true, key: KEY, id: "sess-2", device: "Browser extension – Safari on Mac" });
        expect(prefersWebAuthFlow("Version/19 Safari/605", true)).toBe(false);
        expect(prefersWebAuthFlow("Chrome/140 Safari/537", true)).toBe(true);
        expect(prefersWebAuthFlow("Chrome/140", false)).toBe(false);
    });

    it("pkce and the approve URLs", async () => {
        const verifier = "dBjftJeZ4CVP-mJ92K9q-r6SmQ8z3-e0UhMcbuqJw0k";
        expect(await pkceChallenge(verifier)).toHaveLength(43);
        const chrome = new URL(chromeApproveUrl({ challenge: "c".repeat(43), state: "s".repeat(20), redirectUri: "https://" + "a".repeat(32) + ".chromiumapp.org/" }));
        expect(chrome.pathname).toBe("/connect/extension");
        expect(chrome.searchParams.get("redirect_uri")).toContain(".chromiumapp.org");
        expect(new URL(safariApproveUrl("u".repeat(43))).searchParams.get("user_code")).toHaveLength(43);
        expect(parseRedirect(`https://ext.chromiumapp.org/?code=${CODE}&state=abc`, "abc")).toEqual({ ok: true, code: CODE });
        expect(parseRedirect(`https://ext.chromiumapp.org/?code=${CODE}&state=no`, "abc").ok).toBe(false);
    });
});

describe("the background worker", () => {
    it("saves with the stored session and does not hand the token back", async () => {
        const data: Record<string, unknown> = { session: { key: KEY, id: "sess", device: "Browser extension – Chrome on Mac" } };
        const area: StorageArea = {
            async get(keys) {
                const list = keys == null ? Object.keys(data) : typeof keys === "string" ? [keys] : keys;
                return Object.fromEntries(list.map((k) => [k, data[k]]));
            },
            async set(items) {
                Object.assign(data, items);
            },
            async remove(keys) {
                for (const k of typeof keys === "string" ? [keys] : keys) delete data[k];
            },
        };
        let listener: (message: unknown, sender: { tab?: { id?: number } }) => Promise<unknown> = async () => ({});
        const ext = {
            runtime: { getURL: (p: string) => p, sendMessage: async () => ({}), onMessage: { addListener(fn: typeof listener) { listener = fn; } } },
            storage: { local: area, onChanged: { addListener() {} } },
            tabs: { async create() { return {}; }, async sendMessage() { return {}; } },
        } as Ext;
        const fetchImpl = async (url: string, init?: RequestInit) => {
            if (init?.method === "POST") return Response.json({ status: "success", id: "sid", url: "https://cobalt.capybaraharmony.com/studio/sid" }, { status: 201 });
            return Response.json({ status: "ready", id: "sid" });
        };
        wire(ext, fetchImpl as typeof fetch);
        const reply = await listener({ type: "save", url: "https://x.com/capy/status/1", site: "x" }, { tab: { id: 7 } });
        expect(reply).toMatchObject({ state: "saving", url: "https://x.com/capy/status/1" });
        expect(JSON.stringify(reply)).not.toContain(KEY);
        expect(publicAuth({ key: KEY, id: "sess", device: "Browser extension – Chrome on Mac" }, false)).toEqual({
            signedIn: true,
            offline: false,
            device: "Browser extension – Chrome on Mac",
        });
        const auth = await listener({ type: "auth-state" }, {});
        expect(JSON.stringify(auth)).not.toContain(KEY);
        expect(auth).toMatchObject({ signedIn: true, device: "Browser extension – Chrome on Mac" });
    });

    it("a 401 drops the session", async () => {
        const data: Record<string, unknown> = { session: { key: KEY, id: "sess", device: "Browser extension" } };
        const area: StorageArea = {
            async get(keys) {
                const list = typeof keys === "string" ? [keys] : keys ?? [];
                return Object.fromEntries(list.map((k) => [k, data[k]]));
            },
            async set(items) { Object.assign(data, items); },
            async remove(keys) { for (const k of typeof keys === "string" ? [keys] : keys) delete data[k]; },
        };
        let listener: (message: unknown, sender: { tab?: { id?: number } }) => Promise<unknown> = async () => ({});
        const ext = {
            runtime: { getURL: (p: string) => p, sendMessage: async () => ({}), onMessage: { addListener(fn: typeof listener) { listener = fn; } } },
            storage: { local: area, onChanged: { addListener() {} } },
            tabs: { async create() { return {}; }, async sendMessage() { return {}; } },
        } as Ext;
        wire(ext, (async () => Response.json({ error: { code: "error.api.auth.key.invalid" } }, { status: 401 })) as typeof fetch);
        const reply = await listener({ type: "save", url: "https://x.com/capy/status/1", site: "x" }, {});
        expect(reply).toEqual({ state: "signed-out" });
        expect(data.session).toBeUndefined();
    });
});

describe("popup and manifest", () => {
    it("sleeps when signed out or offline, and saves while a save is running", () => {
        expect(popupView({ signedIn: false, offline: false, device: null, saving: false, recent: [] }).sprite).toBe("sleeping");
        expect(popupView({ signedIn: true, offline: true, device: "Browser extension – Safari on Mac", saving: false, recent: [] }).sprite).toBe("sleeping");
        expect(popupView({ signedIn: true, offline: false, device: "Browser extension – Chrome on Mac", saving: true, recent: [] }).sprite).toBe("saving");
        expect(popupView({ signedIn: true, offline: false, device: "Browser extension – Chrome on Mac", saving: false, recent: [] })).toMatchObject({
            sprite: "idle",
            showSignOut: true,
            showSignIn: false,
        });
        expect(spriteCss()).toContain("steps(6)");
        expect(spriteCss()).toContain("steps(3)");
    });

    it("does not ask for cookies, and calls the API from the worker", () => {
        const manifest = JSON.parse(readFileSync(new URL("../src/manifest.json", import.meta.url), "utf8"));
        expect(manifest.permissions).not.toContain("cookies");
        expect(manifest.host_permissions).toContain("https://api.capybaraharmony.com/*");
        expect(manifest.background.service_worker).toBe("background.js");
        expect(manifest.content_scripts).toHaveLength(4);
        expect(manifest.action.default_icon["16"]).toBe("assets/icons/idle-16.png");
    });
});
