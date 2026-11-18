// Screenshots of the save ring, toast, badge, popup and context menu.
// The unpacked extension runs in Chromium. API answers are fixtures. No account is signed in.
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dist = resolve(root, "dist");
const outDir = "/opt/cursor/artifacts";
mkdirSync(outDir, { recursive: true });
const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";

let phase = "queued";
const bodies = {
    queued: { status: "saving", step: "queued", queue_ahead: 2, service: "youtube", waking: false },
    waking: { status: "saving", step: "fetching", waking: true, service: "youtube" },
    download: { status: "saving", step: "fetching", waking: false, step_bytes: 14_200_000, step_total: 37_600_000, service: "youtube" },
    store: { status: "saving", step: "storing", waking: false, step_bytes: 81, step_total: 100, service: "youtube" },
    saved: { status: "ready", service: "youtube", public_url: "https://share.capybaraharmony.com/clip" },
    error: { status: "error", service: "youtube", error: { code: "error.webp.no_video" } },
};

const html = `<!doctype html><html><head><meta charset="utf-8"><style>
  body{margin:0;background:#000;color:#e7e9ea;font:15px/1.3 system-ui}
  article{width:560px;padding:16px}
  #bar{display:flex;align-items:center;max-width:480px;color:#71767b}
  .cell{display:flex;align-items:center;flex:1}
  button{width:34px;height:34px;border:0;background:transparent;color:inherit;border-radius:999px}
</style></head><body>
<article data-testid="tweet">
  <a href="/capy/status/1111111111111111111"><time>1h</time></a>
  <p>a post in the timeline</p>
  <div id="bar">
    <div class="cell"><button data-testid="like" aria-label="Like">♥</button><span>3.4K</span></div>
    <div class="cell"><button data-testid="reply" aria-label="Reply">💬</button></div>
    <div class="cell"><button data-testid="retweet" aria-label="Repost">↻</button></div>
    <div class="cell"><button data-testid="share" aria-label="Share">↗</button></div>
    <div id="bookmark-cell" class="cell"><button data-testid="bookmark" aria-label="Bookmark">🔖</button></div>
  </div>
</article>
<img id="pic" alt="a picture" src="https://example.com/capy.png" width="80" height="80">
</body></html>`;

const grab = (file) => {
    const display = process.env.DISPLAY || ":1";
    execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-f", "x11grab", "-video_size", "1440x900", "-i", display, "-frames:v", "1", file]);
};

const chrome = process.env.CHROME ?? "/home/ubuntu/.cache/ms-playwright/chromium-1208/chrome-linux64/chrome";
const context = await chromium.launchPersistentContext(`/tmp/capystore-feedback-${process.pid}`, {
    executablePath: chrome,
    headless: false,
    viewport: { width: 720, height: 640 },
    ignoreDefaultArgs: ["--disable-extensions"],
    args: [`--disable-extensions-except=${dist}`, `--load-extension=${dist}`, "--no-sandbox", "--disable-dev-shm-usage"],
});

try {
    let sw = context.serviceWorkers()[0];
    if (!sw) sw = await context.waitForEvent("serviceworker");
    const extId = new URL(sw.url()).host;
    await sw.evaluate(async (key) => {
        await chrome.storage.local.set({
            session: { key, id: "sess-1", device: "Browser extension – Chrome on Mac" },
            phone: true,
        });
    }, KEY);

    const page = context.pages()[0] ?? (await context.newPage());
    page.on("console", (m) => console.log("PAGE", m.type(), m.text().slice(0, 240)));
    sw.on("console", (m) => console.log("SW", m.type(), m.text().slice(0, 240)));
    await context.route("https://x.com/**", (route) => route.fulfill({ status: 200, contentType: "text/html; charset=utf-8", body: html }));
    await context.route("https://api.capybaraharmony.com/**", (route) => {
        const url = route.request().url();
        if (route.request().method() === "POST" && url.endsWith("/studio")) {
            const sent = JSON.parse(route.request().postData() || "{}");
            if (sent.phone !== true || sent.origin !== "extension") throw new Error(`save body ${route.request().postData()}`);
            return route.fulfill({
                status: 201,
                contentType: "application/json",
                body: JSON.stringify({ status: "success", id: "sid", url: "https://cobalt.capybaraharmony.com/studio/sid", queued: phase === "queued", queue_ahead: phase === "queued" ? 2 : 0 }),
            });
        }
        if (url.includes("/studio/sid")) {
            return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(bodies[phase]) });
        }
        return route.fulfill({ status: 404, contentType: "application/json", body: "{}" });
    });

    await page.goto("https://x.com/capy/status/1111111111111111111", { waitUntil: "domcontentloaded" });
    await page.locator(".capystore-save").locator("button").click();

    const shot = async (name, text) => {
        try {
            await page.locator(".capystore-save").locator(".toast").filter({ hasText: text }).waitFor({ timeout: 8000 });
        } catch (e) {
            const dump = {
                text: await page.locator(".capystore-save").allInnerTexts().catch((err) => String(err)),
                toasts: await page.locator(".toast").count().catch((err) => String(err)),
                labels: await page.locator(".label").allInnerTexts().catch((err) => String(err)),
            };
            console.log("DUMP", JSON.stringify(dump));
            throw e;
        }
        await page.screenshot({ path: `${outDir}/${name}.png` });
    };
    await shot("save-queued", "2 ahead of you");
    phase = "waking";
    await shot("save-waking", "Waking the server");
    phase = "download";
    await shot("save-downloading", "14.2 of 37.6 MB");
    phase = "store";
    await shot("save-storing", "Storing in your library · 81%");
    const badgeSaving = await sw.evaluate(() => chrome.action.getBadgeText({}));
    if (badgeSaving !== "1") throw new Error(`badge while saving: ${JSON.stringify(badgeSaving)}`);
    grab(`${outDir}/badge-count.png`);
    phase = "saved";
    await shot("save-saved", "Saved to Capystore · Open · Copy link");
    await page.waitForTimeout(500);
    const badgeDone = await sw.evaluate(() => chrome.action.getBadgeText({}));
    if (badgeDone !== "✓") throw new Error(`badge on save: ${JSON.stringify(badgeDone)}`);
    grab(`${outDir}/badge-done.png`);

    phase = "error";
    await page.locator(".capystore-save").locator("button").first().click();
    await shot("save-error", "Couldn't find a video in this post");
    await page.locator(".capystore-save").locator(".toast").getByRole("button", { name: "Details" }).click();
    await page.locator(".capystore-save").locator(".code").waitFor();
    await page.screenshot({ path: `${outDir}/save-error-details.png` });

    await sw.evaluate(async () => {
        await chrome.storage.local.set({
            recent: [
                {
                    url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                    status: "saving",
                    at: Date.now(),
                    studioUrl: "https://cobalt.capybaraharmony.com/studio/sid",
                    progress: { step: "fetching", bytes: 14200000, total: 37600000, waking: false, queueAhead: null, service: "youtube", code: null, publicUrl: null },
                },
                {
                    url: "https://x.com/capy/status/9",
                    status: "error",
                    at: Date.now() - 1000,
                    studioUrl: "https://cobalt.capybaraharmony.com/studio/err",
                    error: "Couldn't find a video in this post",
                    code: "error.webp.no_video",
                    progress: { step: null, bytes: null, total: null, waking: false, queueAhead: null, service: null, code: "error.webp.no_video", publicUrl: null },
                },
            ],
        });
    });
    const popup = await context.newPage();
    await popup.goto(`chrome-extension://${extId}/popup.html`);
    await popup.locator("#card-headline").waitFor();
    await popup.locator("body").screenshot({ path: `${outDir}/popup-saving.png` });
    if ((await popup.locator("#phone").isChecked()) !== true) throw new Error("iPhone toggle should start on");
    if (!(await popup.locator("#card-headline").innerText()).includes("Downloading from youtube")) throw new Error("popup headline");

    await sw.evaluate(async () => {
        const recent = (await chrome.storage.local.get("recent")).recent;
        recent[0] = {
            ...recent[0],
            status: "saved",
            shareUrl: "https://share.capybaraharmony.com/clip",
            progress: { step: null, bytes: null, total: null, waking: false, queueAhead: null, service: "youtube", code: null, publicUrl: "https://share.capybaraharmony.com/clip" },
        };
        await chrome.storage.local.set({ recent });
    });
    await popup.reload();
    await popup.getByRole("button", { name: "Open in Studio" }).waitFor();
    await popup.locator("body").screenshot({ path: `${outDir}/popup-saved.png` });

    await sw.evaluate(async () => {
        const recent = (await chrome.storage.local.get("recent")).recent;
        recent[0] = recent[1];
        await chrome.storage.local.set({ recent });
    });
    await popup.reload();
    await popup.getByRole("button", { name: "Retry" }).waitFor();
    await popup.locator("body").screenshot({ path: `${outDir}/popup-error.png` });

    await page.bringToFront();
    await page.locator("#pic").click({ button: "right" });
    await page.waitForTimeout(600);
    grab(`${outDir}/context-menu.png`);
    const menus = await sw.evaluate(() => chrome.contextMenus);
    if (!menus) throw new Error("contextMenus missing");
    console.log("feedback shots ok", { badgeSaving, badgeDone });
} finally {
    await context.close();
}
