// Loads the unpacked extension in Chrome and screenshots fixture pages.
// The pages are served as https://x.com and https://www.instagram.com responses,
// so the content scripts run, and no real account is signed in.
//
//   node scripts/placement-shots.mjs before
//   node scripts/placement-shots.mjs after
import { mkdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const mode = process.argv[2];
if (mode !== "before" && mode !== "after") {
    console.error("usage: node scripts/placement-shots.mjs before|after");
    process.exit(2);
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dist = resolve(root, "dist");
const fixtures = resolve(root, "test/fixtures");
const outDir = "/opt/cursor/artifacts";
mkdirSync(outDir, { recursive: true });

const html = (name) => readFileSync(resolve(fixtures, name), "utf8");

// Chrome for Testing still honours --load-extension. Branded Google Chrome ignores it.
const chrome =
    process.env.CHROME ??
    "/home/ubuntu/.cache/ms-playwright/chromium-1208/chrome-linux64/chrome";
const context = await chromium.launchPersistentContext(`/tmp/capystore-ext-${mode}-${process.pid}`, {
    executablePath: chrome,
    headless: false,
    viewport: { width: 900, height: 900 },
    // Playwright's default args include --disable-extensions, which blocks the unpacked build.
    ignoreDefaultArgs: ["--disable-extensions"],
    args: [
        `--disable-extensions-except=${dist}`,
        `--load-extension=${dist}`,
        "--no-sandbox",
        "--disable-dev-shm-usage",
    ],
});

try {
    const page = context.pages()[0] ?? (await context.newPage());
    await page.route("https://x.com/**", (route) => route.fulfill({ status: 200, contentType: "text/html; charset=utf-8", body: html("x-action-bar.html") }));
    await page.route("https://www.instagram.com/**", (route) => {
        const path = new URL(route.request().url()).pathname;
        const body = path.startsWith("/reels/")
            ? html("ig-reels-rail.html")
            : path.startsWith("/reel/")
              ? html("ig-reel-single.html")
              : path.startsWith("/p/")
                ? html("ig-post.html")
                : html("ig-home-feed.html");
        return route.fulfill({ status: 200, contentType: "text/html; charset=utf-8", body });
    });

    await shotX(page);
    await shotReels(page);
    if (mode === "after") {
        await shotFeed(page);
        await shotPost(page);
        await shotReelSingle(page);
    }
    console.log("shots ok", mode);
} finally {
    await context.close();
}

async function shotX(page) {
    await page.goto("https://x.com/capy/status/1111111111111111111", { waitUntil: "domcontentloaded" });
    if (mode === "before") {
        await page.waitForSelector("#like-cell .capystore-save", { timeout: 10000 });
        const wrapped = await page.evaluate(() => {
            const host = document.querySelector("#like-cell .capystore-save");
            const bar = document.querySelector("#bar");
            const like = document.querySelector("#like-cell");
            const hostTop = host.getBoundingClientRect().top;
            const likeTop = like.getBoundingClientRect().top;
            return { inLike: like.contains(host), belowHeart: hostTop > likeTop + 8, barHeight: bar.getBoundingClientRect().height };
        });
        if (!wrapped.inLike || !wrapped.belowHeart) throw new Error(`before X placement was not under the heart: ${JSON.stringify(wrapped)}`);
    } else {
        await page.waitForSelector("#bar > .capystore-save.row", { timeout: 10000 });
        const placed = await page.evaluate(() => {
            const host = document.querySelector("#bar > .capystore-save");
            const bar = document.querySelector("#bar");
            const bookmark = document.querySelector("#bookmark-cell");
            const like = document.querySelector("#like-cell");
            const hb = host.getBoundingClientRect();
            const bb = bar.getBoundingClientRect();
            const mark = bookmark.getBoundingClientRect();
            return {
                count: document.querySelectorAll(".capystore-save").length,
                inLike: like.contains(host),
                afterBookmark: host.previousElementSibling === bookmark,
                sameRow: Math.abs(hb.top - mark.top) < 8,
                insideBar: hb.top >= bb.top - 1 && hb.bottom <= bb.bottom + 1,
            };
        });
        if (placed.count !== 1 || placed.inLike || !placed.afterBookmark || !placed.sameRow || !placed.insideBar) {
            throw new Error(`after X placement: ${JSON.stringify(placed)}`);
        }
    }
    await page.locator("article").screenshot({ path: `${outDir}/x-action-bar-${mode}.png` });
}

async function shotReels(page) {
    await page.goto("https://www.instagram.com/reels/Df0DRWXgk7j/", { waitUntil: "domcontentloaded" });
    if (mode === "before") {
        await page.waitForTimeout(1500);
        const n = await page.locator(".capystore-save").count();
        if (n !== 0) throw new Error(`before reels unexpectedly had ${n} buttons`);
        await page.locator("#stage").screenshot({ path: `${outDir}/ig-reels-before.png` });
        return;
    }
    await page.waitForSelector("#rail > .capystore-save.rail", { timeout: 10000 });
    const placed = await page.evaluate(() => {
        const host = document.querySelector("#rail > .capystore-save");
        const save = document.querySelector("#save-slot");
        const audio = document.querySelector("#audio");
        const hb = host.getBoundingClientRect();
        const sb = save.getBoundingClientRect();
        return {
            count: document.querySelectorAll(".capystore-save").length,
            aboveSave: host.nextElementSibling === save && hb.bottom <= sb.top + 2,
            beforeAudio: !!(audio && hb.top < audio.getBoundingClientRect().top),
            url: host.dataset.url,
        };
    });
    if (placed.count !== 1 || !placed.aboveSave || !placed.beforeAudio || placed.url !== "https://www.instagram.com/reel/Df0DRWXgk7j/") {
        throw new Error(`after reels placement: ${JSON.stringify(placed)}`);
    }
    await page.locator("#stage").screenshot({ path: `${outDir}/ig-reels-after.png` });

    await page.evaluate(() => history.pushState({}, "", "/reels/Df2a89TNsKv/"));
    await page.waitForFunction(
        () => document.querySelector("#rail > .capystore-save")?.dataset.url === "https://www.instagram.com/reel/Df2a89TNsKv/",
        null,
        { timeout: 5000 },
    );
    const next = await page.evaluate(() => ({
        count: document.querySelectorAll(".capystore-save").length,
        url: document.querySelector("#rail > .capystore-save")?.dataset.url,
        aboveSave: document.querySelector("#rail > .capystore-save")?.nextElementSibling?.id === "save-slot",
    }));
    if (next.count !== 1 || !next.aboveSave || next.url !== "https://www.instagram.com/reel/Df2a89TNsKv/") {
        throw new Error(`reels navigation: ${JSON.stringify(next)}`);
    }
    await page.locator("#stage").screenshot({ path: `${outDir}/ig-reels-next.png` });
}

async function shotFeed(page) {
    await page.setViewportSize({ width: 560, height: 1280 });
    await page.goto("https://www.instagram.com/", { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => document.querySelectorAll("article .capystore-save").length === 3, null, { timeout: 10000 });
    const placed = await page.evaluate(() => {
        const hosts = [...document.querySelectorAll(".capystore-save")];
        const feed = document.querySelector("#feed");
        return {
            urls: hosts.map((el) => el.dataset.url),
            inFeedGap: [...feed.children].some((el) => el.classList.contains("capystore-save")),
            inStories: !!document.querySelector("#stories .capystore-save"),
            photo: !!document.querySelector("#photo-icons > .capystore-save"),
            video: document.querySelector("#video-save")?.previousElementSibling?.classList.contains("capystore-save") === true,
            carousel: !!document.querySelector("#carousel-icons > .capystore-save"),
            inBurst: !!document.querySelector(".burst .capystore-save"),
            inComments: !!document.querySelector(".comments .capystore-save"),
        };
    });
    const want = [
        "https://www.instagram.com/p/PHOTOCODE11/",
        "https://www.instagram.com/reel/FEEDVID1111/",
        "https://www.instagram.com/p/CAROUSEL111/",
    ];
    if (placed.urls.join(",") !== want.join(",") || placed.inFeedGap || placed.inStories || !placed.photo || !placed.video || !placed.carousel || placed.inBurst || placed.inComments) {
        throw new Error(`feed placement: ${JSON.stringify(placed)}`);
    }
    await page.locator("#feed").screenshot({ path: `${outDir}/ig-home-feed.png` });
}

async function shotPost(page) {
    await page.setViewportSize({ width: 560, height: 900 });
    await page.goto("https://www.instagram.com/p/POSTPAGE01/", { waitUntil: "domcontentloaded" });
    await page.waitForSelector("#post-icons > .capystore-save", { timeout: 10000 });
    const info = await page.evaluate(() => ({
        count: document.querySelectorAll(".capystore-save").length,
        url: document.querySelector(".capystore-save")?.dataset.url,
        inIcons: !!document.querySelector("#post-icons > .capystore-save"),
        inComments: !!document.querySelector("#post-comments .capystore-save"),
        rail: document.querySelector(".capystore-save")?.classList.contains("rail") === true,
    }));
    if (info.count !== 1 || info.url !== "https://www.instagram.com/p/POSTPAGE01/" || !info.inIcons || info.inComments || info.rail) {
        throw new Error(`post page: ${JSON.stringify(info)}`);
    }
    await page.locator("#post").screenshot({ path: `${outDir}/ig-post.png` });
}

async function shotReelSingle(page) {
    await page.goto("https://www.instagram.com/reel/CCCCCCCCCCC/", { waitUntil: "domcontentloaded" });
    await page.waitForSelector("main .capystore-save", { timeout: 10000 });
    const info = await page.evaluate(() => ({
        count: document.querySelectorAll(".capystore-save").length,
        url: document.querySelector(".capystore-save")?.dataset.url,
    }));
    if (info.count !== 1 || info.url !== "https://www.instagram.com/reel/CCCCCCCCCCC/") throw new Error(`single reel: ${JSON.stringify(info)}`);
    await page.locator("main").screenshot({ path: `${outDir}/ig-reel-single-after.png` });
}
