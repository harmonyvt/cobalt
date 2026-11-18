// Screenshots of the Instagram reels rail: one Save button, between share and save.
//   node scripts/reels-rail-shots.mjs before
//   node scripts/reels-rail-shots.mjs after
// `before` is the double button (heart slot and above Save). `after` expects one.
import { mkdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const mode = process.argv[2];
if (mode !== "before" && mode !== "after") {
    console.error("usage: node scripts/reels-rail-shots.mjs before|after");
    process.exit(2);
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dist = resolve(root, "dist");
const fixtures = resolve(root, "test/fixtures");
const outDir = "/opt/cursor/artifacts";
mkdirSync(outDir, { recursive: true });
const html = (name) => readFileSync(resolve(fixtures, name), "utf8");
const chrome = process.env.CHROME ?? "/home/ubuntu/.cache/ms-playwright/chromium-1208/chrome-linux64/chrome";

const context = await chromium.launchPersistentContext(`/tmp/capystore-reels-${mode}-${process.pid}`, {
    executablePath: chrome,
    headless: false,
    viewport: { width: 900, height: 900 },
    ignoreDefaultArgs: ["--disable-extensions"],
    args: [`--disable-extensions-except=${dist}`, `--load-extension=${dist}`, "--no-sandbox", "--disable-dev-shm-usage"],
});

try {
    let sw = context.serviceWorkers()[0];
    if (!sw) sw = await context.waitForEvent("serviceworker", { timeout: 15000 });
    await sw.evaluate(async () => {
        await chrome.storage.local.set({
            session: { key: "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11", id: "sess-1", device: "Browser extension" },
        });
    });
    const page = context.pages()[0] ?? (await context.newPage());
    await page.route("https://www.instagram.com/**", (route) => {
        const path = new URL(route.request().url()).pathname;
        const body = path.startsWith("/reels/") ? html("ig-reels-viewer.html") : html("ig-feed-reels.html");
        return route.fulfill({ status: 200, contentType: "text/html; charset=utf-8", body });
    });
    await page.route("https://x.com/**", (route) => route.fulfill({ status: 200, contentType: "text/html; charset=utf-8", body: html("x-action-bar.html") }));

    await page.goto("https://www.instagram.com/reels/Df0DRWXgk7j/", { waitUntil: "domcontentloaded" });
    const want = mode === "before" ? 2 : 1;
    await page.waitForFunction((n) => document.querySelectorAll(".capystore-save").length === n, want, { timeout: 10000 });
    const placed = await page.evaluate(() => {
        const hosts = [...document.querySelectorAll(".capystore-save")];
        const rail = document.querySelector("#rail");
        const like = document.querySelector("#like-button");
        return {
            count: hosts.length,
            urls: hosts.map((h) => h.dataset.url),
            inLike: hosts.filter((h) => like.contains(h)).length,
            direct: hosts.filter((h) => h.parentElement === rail).length,
            aboveSave: [...rail.children].some((el) => el.classList.contains("capystore-save") && el.nextElementSibling?.id === "save-slot"),
            marked: rail.dataset.capystoreRail ?? "",
        };
    });
    if (placed.count !== want) throw new Error(`${mode} count ${JSON.stringify(placed)}`);
    if (mode === "after") {
        if (placed.inLike !== 0 || placed.direct !== 1 || !placed.aboveSave) throw new Error(`after placement ${JSON.stringify(placed)}`);
        if (placed.urls[0] !== "https://www.instagram.com/reel/Df0DRWXgk7j/") throw new Error(`after url ${JSON.stringify(placed)}`);
        if (placed.marked !== "https://www.instagram.com/reel/Df0DRWXgk7j/") throw new Error(`rail marker ${JSON.stringify(placed)}`);
    }
    await page.locator("#stage").screenshot({ path: `${outDir}/ig-reels-rail-${mode}.png` });

    if (mode === "after") {
        await page.goto("https://www.instagram.com/", { waitUntil: "domcontentloaded" });
        await page.waitForFunction(() => document.querySelectorAll("article .capystore-save").length === 2, null, { timeout: 10000 });
        const feed = await page.evaluate(() => ({
            count: document.querySelectorAll(".capystore-save").length,
            perArticle: [...document.querySelectorAll("article")].map((a) => a.querySelectorAll(".capystore-save").length),
            urls: [...document.querySelectorAll(".capystore-save")].map((h) => h.dataset.url),
        }));
        if (feed.count !== 2 || feed.perArticle.some((n) => n !== 1)) throw new Error(`feed ${JSON.stringify(feed)}`);
        await page.locator("body").screenshot({ path: `${outDir}/ig-feed-reels-after.png` });

        await page.goto("https://x.com/capy/status/1111111111111111111", { waitUntil: "domcontentloaded" });
        await page.waitForSelector("#bar > .capystore-save.row", { timeout: 10000 });
        const x = await page.evaluate(() => document.querySelectorAll(".capystore-save").length);
        if (x !== 1) throw new Error(`x buttons ${x}`);
        await page.locator("article").screenshot({ path: `${outDir}/x-unaffected-after.png` });
    }
    console.log("reels rail shots ok", mode, placed);
} finally {
    await context.close();
}
