import { readFileSync } from "node:fs";
import { Window } from "happy-dom";
import { describe, expect, it } from "vitest";
import { wire } from "../src/background";
import { start } from "../src/content";
import { badgeColor } from "../src/lib/brand";
import type { Ext, StorageArea } from "../src/lib/browser";
import { markRail, mountedHost, pruneRail, relocateHost, scanInstagram, scanTwitch, scanX, scanYouTube } from "../src/lib/find";
import { describeSave, friendlyError, sizePair } from "../src/lib/progress";
import { createSave, followSave, pollSave } from "../src/lib/save";
import { chromeApproveUrl, matchCode, parseRedirect, pkceChallenge, prefersWebAuthFlow, runSignIn, safariApproveUrl } from "../src/lib/signin";
import { buttonCss, hostCss, themeFromSignals } from "../src/lib/surface";
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


type Listener = (message: unknown, sender: { tab?: { id?: number } }, sendResponse?: (reply: unknown) => void) => unknown;
// The background answers through sendResponse (and returns true), the way Chromium and Safari both accept.
function ask(fn: Listener, message: unknown, sender: { tab?: { id?: number } }): Promise<unknown> {
    return new Promise((resolve) => {
        expect(fn(message, sender, resolve)).toBe(true);
    });
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
        expect(canonicalInstagram("/reels/audio/17890/", "https://www.instagram.com/reels/Df0DRWXgk7j/")).toBeNull();
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

    it("sits in the X action bar after bookmark, not inside the like control under the heart", () => {
        const doc = page(
            HOME,
            `<article data-testid="tweet">
                <a href="/capy/status/1111111111111111111"><time>1h</time></a>
                <div id="bar">
                    <div id="like-cell" role="group" aria-label="Like"><button data-testid="like" aria-label="Like">like</button></div>
                    <span id="like-count">3.4K</span>
                    <div id="reply-cell"><button data-testid="reply" aria-label="33 Replies. Reply">reply</button><span>33</span></div>
                    <div id="repost-cell"><button data-testid="retweet" aria-label="386 Reposts. Repost">repost</button><span>386</span></div>
                    <div id="share-cell"><button data-testid="share" aria-label="Share">share</button><span>1.9K</span></div>
                    <div id="bookmark-cell"><button data-testid="bookmark" aria-label="Bookmark">bookmark</button></div>
                </div>
                <article data-testid="tweet">
                    <a href="/other/status/222"><time>2h</time></a>
                    <div id="quoted-bar">
                        <button data-testid="reply" aria-label="Reply">reply</button>
                        <button data-testid="like" aria-label="Like">like</button>
                        <button data-testid="bookmark" aria-label="Bookmark">bookmark</button>
                    </div>
                </article>
            </article>`,
        );
        const found = scanX(doc, HOME);
        expect(found.map((f) => f.url)).toEqual(["https://x.com/capy/status/1111111111111111111", "https://x.com/other/status/222"]);
        expect(found[0]!.mount.id).toBe("bar");
        expect(found[0]!.fit).toBe("row");
        expect(found[0]!.after?.id).toBe("bookmark-cell");
        expect(found[0]!.mount.contains(doc.querySelector("#like-cell"))).toBe(true);
        expect(found[0]!.after?.contains(doc.querySelector('[data-testid="like"]'))).toBe(false);
        expect(found[1]!.mount.id).toBe("quoted-bar");
        expect(found[1]!.after?.getAttribute("data-testid")).toBe("bookmark");
        const host = doc.createElement("span");
        expect(relocateHost(host, found[0]!.mount, found[0]!.after)).toBe(true);
        expect(host.previousElementSibling?.id).toBe("bookmark-cell");
        expect(doc.querySelector("#like-cell")!.contains(host)).toBe(false);
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

    it("mounts on a search lockup's title row and skips a sponsored lockup", () => {
        const doc = page(
            "https://www.youtube.com/results?search_query=capy",
             `<yt-lockup-view-model id="sponsored">
               <a class="ytLockupViewModelContentImage" href="/watch?v=sponsored01"><img alt=""></a>
               <div class="yt-lockup-metadata-view-model-wiz" id="ad-meta">
                 <h3 id="ad-title"><a href="/watch?v=sponsored01">Sponsored</a></h3>
                 <ad-button-view-model id="cta"><a href="/watch?v=sponsored01">Watch</a><button>Download</button></ad-button-view-model>
               </div>
             </yt-lockup-view-model>
             <yt-lockup-view-model id="plain">
               <a class="thumbnail" href="/watch?v=abcdefghijk"><img alt=""></a>
               <div id="title-row"><a href="/watch?v=abcdefghijk">title</a></div>
             </yt-lockup-view-model>
             <yt-lockup-view-model id="shop">
               <a href="https://shop.example/sale">Shop now</a>
               <span>Sponsored</span>
             </yt-lockup-view-model>`,
        );
        const found = scanYouTube(doc, "https://www.youtube.com/results?search_query=capy");
        expect(found.map((f) => [f.url, f.variant, f.mount.id])).toEqual([["https://www.youtube.com/watch?v=abcdefghijk", "icon", "title-row"]]);
        expect(found.some((f) => f.url.includes("sponsored01"))).toBe(false);
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

    it("puts one button on a reels rail above Save, and keeps a feed post on its own article", () => {
        const reels = page(
            "https://www.instagram.com/reels/Df0DRWXgk7j/",
            `<main><div id="rail">
                <div id="like-slot"><button aria-label="Like"><svg aria-hidden="true"></svg></button></div>
                <div id="comment-slot"><button aria-label="Comment"><svg aria-hidden="true"></svg></button></div>
                <div id="repost-slot"><button aria-label="Repost"></button></div>
                <div id="share-slot"><button aria-label="Share"></button></div>
                <div id="save-slot"><button aria-label="Save"></button></div>
                <div id="audio"></div>
            </div></main>`,
        );
        const found = scanInstagram(reels, "https://www.instagram.com/reels/Df0DRWXgk7j/");
        expect(found).toHaveLength(1);
        expect(found[0]!.url).toBe("https://www.instagram.com/reel/Df0DRWXgk7j/");
        expect(found[0]!.mount.id).toBe("rail");
        expect(found[0]!.fit).toBe("rail");
        expect(found[0]!.before?.id).toBe("save-slot");
        const host = reels.createElement("span");
        host.className = "capystore-save";
        host.dataset.url = found[0]!.url;
        expect(relocateHost(host, found[0]!.mount, found[0]!.after, found[0]!.before)).toBe(true);
        expect(host.nextElementSibling?.id).toBe("save-slot");
        expect(mountedHost(found[0]!.mount, "capystore-save")).toBe(host);
        // The same rail, the next reel: one host, retargeted, not a second button.
        const next = scanInstagram(reels, "https://www.instagram.com/reels/Df2a89TNsKv/");
        expect(next).toHaveLength(1);
        expect(next[0]!.url).toBe("https://www.instagram.com/reel/Df2a89TNsKv/");
        expect(next[0]!.mount.id).toBe("rail");
        const again = mountedHost(next[0]!.mount, "capystore-save");
        expect(again).toBe(host);
        again!.dataset.url = next[0]!.url;
        expect(reels.querySelectorAll(".capystore-save")).toHaveLength(1);

        const paired = page(
            "https://www.instagram.com/reels/Df0DRWXgk7j/",
            `<div id="current"><a href="/reel/Df0DRWXgk7j/"></a>
                <button aria-label="Like"></button><button aria-label="Comment"></button><button aria-label="Save"></button>
            </div>
            <div id="upcoming"><a href="/reel/Df2a89TNsKv/"></a>
                <button aria-label="Like"></button><button aria-label="Comment"></button><button aria-label="Save"></button>
            </div>`,
        );
        const both = scanInstagram(paired, "https://www.instagram.com/reels/Df0DRWXgk7j/");
        expect(both.map((f) => [f.url, f.mount.id])).toEqual([
            ["https://www.instagram.com/reel/Df0DRWXgk7j/", "current"],
            ["https://www.instagram.com/reel/Df2a89TNsKv/", "upcoming"],
        ]);
    });

    it("puts one button on a live reels viewer, between share and save, and one on each feed reel", () => {
        const viewerUrl = "https://www.instagram.com/reels/Df0DRWXgk7j/";
        const viewer = page(viewerUrl, readFileSync(new URL("./fixtures/ig-reels-viewer.html", import.meta.url), "utf8"));
        const found = scanInstagram(viewer, viewerUrl);
        expect(found).toHaveLength(1);
        expect(found[0]!.url).toBe("https://www.instagram.com/reel/Df0DRWXgk7j/");
        expect(found[0]!.mount.id).toBe("rail");
        expect(found[0]!.fit).toBe("rail");
        expect(found[0]!.before?.id).toBe("save-slot");
        expect(viewer.getElementById("like-button")!.contains(found[0]!.mount)).toBe(false);
        // A rescan is the same single slot, not a second mount under the heart.
        const again = scanInstagram(viewer, viewerUrl);
        expect(again.map((f) => [f.url, (f.mount as HTMLElement).id, f.before?.id])).toEqual([
            ["https://www.instagram.com/reel/Df0DRWXgk7j/", "rail", "save-slot"],
        ]);
        // A button already under the heart, from an earlier inject, is removed. The rail keeps one.
        const stale = viewer.createElement("span");
        stale.className = "capystore-save";
        stale.dataset.url = found[0]!.url;
        viewer.getElementById("like-button")!.append(stale);
        const keep = viewer.createElement("span");
        keep.className = "capystore-save rail";
        keep.dataset.url = found[0]!.url;
        found[0]!.mount.insertBefore(keep, found[0]!.before ?? null);
        markRail(found[0]!.mount, found[0]!.url);
        markRail(found[0]!.mount, found[0]!.url);
        expect((found[0]!.mount as HTMLElement).dataset.capystoreRail).toBe(found[0]!.url);
        expect(pruneRail(found[0]!.mount, "capystore-save", keep)).toEqual([stale]);
        expect(viewer.querySelectorAll(".capystore-save")).toHaveLength(1);
        expect(keep.nextElementSibling?.id).toBe("save-slot");
        expect(viewer.getElementById("like-button")!.querySelector(".capystore-save")).toBeNull();

        const feed = page("https://www.instagram.com/", readFileSync(new URL("./fixtures/ig-feed-reels.html", import.meta.url), "utf8"));
        const posts = scanInstagram(feed, "https://www.instagram.com/");
        expect(posts.map((f) => f.url)).toEqual(["https://www.instagram.com/p/AAAAAAAAAAA/", "https://www.instagram.com/reel/FEEDREEL111/"]);
        expect(posts.every((f) => f.fit !== "rail")).toBe(true);
        expect(feed.querySelectorAll("article")).toHaveLength(2);
    });

    it("puts one button in each home-feed action row, including a video and a carousel", () => {
        const url = "https://www.instagram.com/";
        const doc = page(url, readFileSync(new URL("./fixtures/ig-home-feed.html", import.meta.url), "utf8"));
        const posts = scanInstagram(doc, url);
        expect(posts.map((f) => f.url)).toEqual([
            "https://www.instagram.com/p/PHOTOCODE11/",
            "https://www.instagram.com/reel/FEEDVID1111/",
            "https://www.instagram.com/p/CAROUSEL111/",
        ]);
        expect(posts.every((f) => f.fit !== "rail")).toBe(true);
        // Image and carousel: appended to the icon group, which sits beside Save. Not on the burst heart.
        expect(posts[0]!.mount.id).toBe("photo-icons");
        expect(posts[0]!.before).toBeUndefined();
        expect(posts[0]!.mount.closest("article")?.id).toBe("photo");
        expect(doc.querySelector(".burst")!.contains(posts[0]!.mount)).toBe(false);
        expect(posts[2]!.mount.id).toBe("carousel-icons");
        // Video: the row is flat, so the button is the slot before Save. The audio disc is not the URL.
        expect(posts[1]!.mount.id).toBe("video-actions");
        expect(posts[1]!.before?.id).toBe("video-save");
        expect(posts[1]!.url).not.toContain("/audio/");
        // Stories and the feed column itself are not a mount. Comment hearts are not posts.
        expect(posts.some((f) => f.mount.id === "feed" || f.mount.id === "stories" || f.mount.closest("#stories"))).toBe(false);
        expect(doc.querySelectorAll("#feed > .capystore-save, #stories .capystore-save")).toHaveLength(0);
        // A second scan is the same three slots.
        const again = scanInstagram(doc, url);
        expect(again.map((f) => [f.url, (f.mount as HTMLElement).id, f.before?.id ?? ""])).toEqual(
            posts.map((f) => [f.url, (f.mount as HTMLElement).id, f.before?.id ?? ""]),
        );
    });

    it("uses a comment permalink when a video post has no clean link of its own", () => {
        const doc = page(
            "https://www.instagram.com/",
            `<div id="feed">
              <article id="clip">
                <a href="/reels/audio/17890/">audio</a>
                <section id="row">
                  <div role="button" aria-label="Like"><svg aria-label="Like"></svg></div>
                  <div role="button" aria-label="Comment"></div>
                  <div role="button" aria-label="Share Post"></div>
                  <div id="save" role="button" aria-label="Save"></div>
                </section>
                <a href="/p/COMMENTONLY1/c/18130549336575775/">a comment</a>
              </article>
            </div>`,
        );
        const found = scanInstagram(doc, "https://www.instagram.com/");
        expect(found.map((f) => f.url)).toEqual(["https://www.instagram.com/p/COMMENTONLY1/"]);
        expect(found[0]!.mount.id).toBe("row");
        expect(found[0]!.before?.id).toBe("save");
        expect(found[0]!.fit).toBeUndefined();
    });

    it("puts one button on a single post page, in the icon row, not on each comment", () => {
        const url = "https://www.instagram.com/p/POSTPAGE01/";
        const doc = page(url, readFileSync(new URL("./fixtures/ig-post.html", import.meta.url), "utf8"));
        const found = scanInstagram(doc, url);
        expect(found).toHaveLength(1);
        expect(found[0]!.url).toBe(url);
        expect(found[0]!.fit).toBeUndefined();
        expect(found[0]!.mount.id).toBe("post-icons");
        expect(doc.getElementById("post-comments")!.contains(found[0]!.mount)).toBe(false);
        expect(doc.querySelector("article")).toBeNull();
        const again = scanInstagram(doc, url);
        expect(again).toHaveLength(1);
        expect(again[0]!.mount.id).toBe("post-icons");
    });

    it("keeps one button per feed post when posts are appended and when a row is redrawn", async () => {
        const win = new Window({ url: "https://www.instagram.com/" });
        win.document.write(readFileSync(new URL("./fixtures/ig-home-feed.html", import.meta.url), "utf8"));
        const previous = {
            window: globalThis.window,
            document: globalThis.document,
            location: globalThis.location,
            MutationObserver: globalThis.MutationObserver,
            getComputedStyle: globalThis.getComputedStyle,
            ShadowRoot: globalThis.ShadowRoot,
            Element: globalThis.Element,
            Node: globalThis.Node,
            HTMLElement: globalThis.HTMLElement,
            chrome: (globalThis as { chrome?: unknown }).chrome,
        };
        const g = globalThis as unknown as Record<string, unknown>;
        g.window = win;
        g.document = win.document;
        g.location = win.location;
        g.MutationObserver = win.MutationObserver;
        g.getComputedStyle = win.getComputedStyle.bind(win);
        g.ShadowRoot = win.ShadowRoot;
        g.Element = win.Element;
        g.Node = win.Node;
        g.HTMLElement = win.HTMLElement;
        g.chrome = {
            runtime: {
                id: "capystore-test",
                getURL: (path: string) => `chrome-extension://capystore/${path}`,
                sendMessage: async (message: { type?: string }) => {
                    if (message?.type === "get-sites") return { instagram: true };
                    if (message?.type === "auth-state") return { signedIn: true };
                    if (message?.type === "status") return { state: "idle", signedIn: true };
                    return {};
                },
                onMessage: { addListener() {} },
            },
            storage: {
                local: { async get() { return {}; }, async set() {}, async remove() {} },
                onChanged: { addListener() {} },
            },
            tabs: { async create() { return {}; }, async sendMessage() { return {}; } },
        };
        (g.__capystoreStarted as Set<string> | undefined)?.delete("instagram");
        const hosts = () => [...win.document.querySelectorAll(".capystore-save")];
        const hostUrl = (el: { getAttribute(name: string): string | null }) => el.getAttribute("data-url");
        const waitFor = async (pred: () => boolean) => {
            const deadline = Date.now() + 2000;
            while (Date.now() < deadline) {
                if (pred()) return;
                await new Promise((resolve) => setTimeout(resolve, 40));
            }
            throw new Error(`timed out with ${hosts().length} buttons: ${hosts().map((h) => hostUrl(h)).join(",")}`);
        };
        try {
            start("instagram", scanInstagram);
            await waitFor(() => hosts().length === 3);
            expect(hosts().map((h) => hostUrl(h))).toEqual([
                "https://www.instagram.com/p/PHOTOCODE11/",
                "https://www.instagram.com/reel/FEEDVID1111/",
                "https://www.instagram.com/p/CAROUSEL111/",
            ]);
            expect(win.document.querySelector("#feed > .capystore-save")).toBeNull();
            expect(win.document.querySelector("#photo-icons > .capystore-save")).not.toBeNull();
            expect(win.document.querySelector("#video-save")?.previousElementSibling?.classList.contains("capystore-save")).toBe(true);
            expect(win.document.querySelector("#carousel-icons > .capystore-save")).not.toBeNull();
            expect(win.document.querySelector("#stories .capystore-save")).toBeNull();

            const more = win.document.createElement("article");
            more.id = "more";
            more.innerHTML = `<a href="/p/SCROLLED111/"><time>now</time></a>
              <section class="actions"><div class="icons" id="more-icons">
                <div role="button" aria-label="Like"><svg aria-label="Like"></svg></div>
                <div role="button" aria-label="Comment"></div>
                <div role="button" aria-label="Share"></div>
              </div><div class="save" role="button" aria-label="Save"><svg aria-label="Save"></svg></div></section>`;
            win.document.getElementById("feed")!.append(more);
            await waitFor(() => hosts().length === 4);
            expect(hosts().filter((h) => hostUrl(h) === "https://www.instagram.com/p/SCROLLED111/")).toHaveLength(1);
            expect(win.document.querySelector("#more-icons > .capystore-save, #more .icons > .capystore-save")).not.toBeNull();

            // The site redraws the row and drops the button. The observer puts exactly one back.
            win.document.querySelector("#photo .capystore-save")!.remove();
            win.document.getElementById("photo-icons")!.append(win.document.createElement("span"));
            await waitFor(() => win.document.querySelectorAll("#photo .capystore-save").length === 1);
            expect(hosts().filter((h) => hostUrl(h) === "https://www.instagram.com/p/PHOTOCODE11/")).toHaveLength(1);
            expect(hosts()).toHaveLength(4);
        } finally {
            win.happyDOM.abort();
            (g.__capystoreStarted as Set<string> | undefined)?.delete("instagram");
            g.window = previous.window;
            g.document = previous.document;
            g.location = previous.location;
            g.MutationObserver = previous.MutationObserver;
            g.getComputedStyle = previous.getComputedStyle;
            g.ShadowRoot = previous.ShadowRoot;
            g.Element = previous.Element;
            g.Node = previous.Node;
            g.HTMLElement = previous.HTMLElement;
            g.chrome = previous.chrome;
        }
    });

    it("does not inject on an Instagram page that only says the post is unavailable", () => {
        const doc = page(
            "https://www.instagram.com/p/AAAAAAAAAAA/",
            `<main><section><h2>Sorry, this page isn't available.</h2><p>The link may be broken, or the post may have been removed.</p></section></main>`,
        );
        expect(scanInstagram(doc, "https://www.instagram.com/p/AAAAAAAAAAA/")).toEqual([]);
    });

    it("mounts beside Share Clip and ignores the same words in the top nav", () => {
        const doc = page(
            "https://www.twitch.tv/somechannel/clip/FunnySlug",
            `<nav><button aria-label="Share">Share</button></nav>
             <main id="shell">
               <div id="signup">Sign up</div>
               <div id="clip-actions"><button aria-label="Share Clip: Kevin Hart gets drenched">Share</button></div>
             </main>`,
        );
        const url = "https://www.twitch.tv/somechannel/clip/FunnySlug";
        const found = scanTwitch(doc, url);
        expect(found.map((f) => f.url)).toEqual([url]);
        expect(found[0]!.mount.id).toBe("clip-actions");
        expect(found[0]!.variant).toBe("pill");
        const navOnly = page("https://clips.twitch.tv/FunnySlug", `<header><button aria-label="Share Clip: somewhere"></button></header><main id="shell"></main>`);
        expect(scanTwitch(navOnly, "https://clips.twitch.tv/FunnySlug")).toEqual([]);
    });

    it("sits on the Edit/Share/like row, after the Share chip, not inside it", () => {
        const doc = page(
            "https://www.twitch.tv/somechannel/clip/FunnySlug",
            `<main id="shell">
               <div id="clip-row" class="Layout-sc-1xcs6mc-0">
                 <div id="edit-chip"><button aria-label="Edit">Edit</button></div>
                 <div class="Layout-sc-1xcs6mc-0">
                   <div class="Layout-sc-1xcs6mc-0" id="share-chip">
                     <button aria-label="Share Clip: Kevin Hart gets drenched">Share</button>
                   </div>
                 </div>
                 <div id="like-chip"><button aria-label="Like">Like</button></div>
                 <div id="overflow"><button aria-label="More">More</button></div>
               </div>
             </main>`,
        );
        const found = scanTwitch(doc, "https://www.twitch.tv/somechannel/clip/FunnySlug");
        const shareChip = doc.querySelector("#share-chip")!;
        expect(found).toHaveLength(1);
        expect(found[0]!.mount.id).toBe("clip-row");
        expect(found[0]!.after?.parentElement?.id).toBe("clip-row");
        expect(found[0]!.after?.contains(shareChip)).toBe(true);
        expect(found[0]!.after).not.toBe(shareChip);
        const host = doc.createElement("span");
        expect(relocateHost(host, found[0]!.mount, found[0]!.after)).toBe(true);
        expect(host.previousElementSibling).toBe(found[0]!.after);
        expect(host.parentElement?.id).toBe("clip-row");
        expect(shareChip.contains(host)).toBe(false);
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
        expect(started).toMatchObject({ kind: "saving", id: "sid", studioUrl: "https://cobalt.capybaraharmony.com/studio/sid" });
        expect(calls[0]!.init.credentials).toBe("omit");
        expect(JSON.parse(String(calls[0]!.init.body))).toEqual({ url: "https://x.com/capy/status/1", origin: "extension", queue: true, phone: true });
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
            message: "Capystore is busy. Try again in a moment.",
            code: "error.studio.busy",
        });
    });
});

describe("save progress copy", () => {
    it("names each step the way the button and the toast say it", () => {
        expect(describeSave("saving", { step: "queued", bytes: null, total: null, waking: false, queueAhead: 2, service: "youtube", code: null, publicUrl: null })).toMatchObject({
            label: "Queued",
            ring: "spin",
            toast: "Saving to Capystore · 2 ahead of you",
        });
        expect(describeSave("saving", { step: "fetching", bytes: null, total: null, waking: true, queueAhead: null, service: "youtube", code: null, publicUrl: null }).toast).toBe("Waking the server…");
        const down = describeSave("saving", { step: "fetching", bytes: 14_200_000, total: 37_600_000, waking: false, queueAhead: null, service: "youtube", code: null, publicUrl: null });
        expect(down.toast).toBe("Downloading from youtube · 14.2 of 37.6 MB");
        expect(down.label).toBe("38%");
        expect(sizePair(14_200_000, 37_600_000)).toBe("14.2 of 37.6 MB");
        expect(describeSave("saving", { step: "storing", bytes: 81, total: 100, waking: false, queueAhead: null, service: "youtube", code: null, publicUrl: null }).toast).toBe("Storing in your library · 81%");
        expect(describeSave("saved", { step: null, bytes: null, total: null, waking: false, queueAhead: null, service: "youtube", code: null, publicUrl: null })).toMatchObject({
            label: "Saved",
            toast: "Saved to Capystore · Open · Copy link",
            open: true,
            copy: true,
        });
        expect(friendlyError("error.webp.no_video")).toBe("Couldn't find a video in this post");
        expect(describeSave("error", { step: null, bytes: null, total: null, waking: false, queueAhead: null, service: null, code: "error.webp.no_video", publicUrl: null })).toMatchObject({
            label: "Retry",
            toast: "Couldn't find a video in this post",
            retry: true,
            details: true,
        });
    });
});

describe("save feedback surface", () => {
    it("uses the web accent for the badge and a thin arc instead of a filled disc", () => {
        expect(badgeColor()).toBe("#2f8af9");
        expect(badgeColor("1")).toBe("#2f8af9");
        expect(badgeColor("✓")).toBe("#30bd1b");
        expect(badgeColor("!")).toBe("#ed2236");
        for (const kind of ["icon", "pill", "rail"] as const) {
            const css = buttonCss(kind);
            expect(css).not.toContain("conic-gradient");
            expect(css).toContain("stroke-width: 2");
            expect(css).toContain("prefers-reduced-motion");
        }
        expect(hostCss()).toContain("background:transparent !important");
        expect(buttonCss("icon")).toContain("background: transparent");
    });

    it("follows an explicit site theme, then the page, then the OS", () => {
        expect(themeFromSignals({ hint: "dark", scheme: "light", luminance: 1, prefersDark: false })).toBe("dark");
        expect(themeFromSignals({ hint: "theme-light", scheme: "dark", luminance: 0, prefersDark: true })).toBe("light");
        expect(themeFromSignals({ hint: "", scheme: "light dark", luminance: 0, prefersDark: false })).toBe("dark");
        expect(themeFromSignals({ hint: "", scheme: "", luminance: 1, prefersDark: true })).toBe("light");
        expect(themeFromSignals({ hint: "", scheme: "dark", luminance: null, prefersDark: false })).toBe("dark");
        expect(themeFromSignals({ hint: "", scheme: "", luminance: null, prefersDark: true })).toBe("dark");
        expect(themeFromSignals({ hint: "", scheme: "", luminance: null, prefersDark: false })).toBe("light");
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

    it("the match code is the same one the approve page computes", async () => {
        // Same vector as deploy/cloudflare/web/test/connect.test.ts.
        expect(await matchCode("u".repeat(43))).toBe("TLY7-BN5Z");
        expect(await matchCode("capystore_user_code_fixture_000000000000000")).toBe("785C-3223");
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
        const codes: (string | null)[] = [];
        const result = await runSignIn({
            ua: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15",
            redirectUri: null,
            launch: null,
            onCode: (code) => codes.push(code),
            openTab: async (url) => {
                expect(codes).toEqual(["TLY7-BN5Z"]);
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
        let listener: Listener = () => true;
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
        const reply = await ask(listener, { type: "save", url: "https://x.com/capy/status/1", site: "x" }, { tab: { id: 7 } });
        expect(reply).toMatchObject({ state: "saving", url: "https://x.com/capy/status/1" });
        expect(JSON.stringify(reply)).not.toContain(KEY);
        expect(publicAuth({ key: KEY, id: "sess", device: "Browser extension – Chrome on Mac" }, false)).toEqual({
            signedIn: true,
            offline: false,
            device: "Browser extension – Chrome on Mac",
        });
        const auth = await ask(listener, { type: "auth-state" }, {});
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
        let listener: Listener = () => true;
        const ext = {
            runtime: { getURL: (p: string) => p, sendMessage: async () => ({}), onMessage: { addListener(fn: typeof listener) { listener = fn; } } },
            storage: { local: area, onChanged: { addListener() {} } },
            tabs: { async create() { return {}; }, async sendMessage() { return {}; } },
        } as Ext;
        wire(ext, (async () => Response.json({ error: { code: "error.api.auth.key.invalid" } }, { status: 401 })) as typeof fetch);
        const reply = await ask(listener, { type: "save", url: "https://x.com/capy/status/1", site: "x" }, {});
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
