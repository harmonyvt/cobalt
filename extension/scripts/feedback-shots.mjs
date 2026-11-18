// Screenshots of the in-page save button, toast, and popup.
// The unpacked extension runs in Chromium against the X and Instagram fixtures.
// API answers are fixtures. No account is signed in for real.
//
//   npm run build && node scripts/feedback-shots.mjs
//
// Writes to /opt/cursor/artifacts. Before shots (the previous disc) are captured
// separately from the pre-change build and named before-*.png.
import { mkdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dist = resolve(root, "dist");
const fixtures = resolve(root, "test/fixtures");
const outDir = "/opt/cursor/artifacts";
mkdirSync(outDir, { recursive: true });
const read = (name) => readFileSync(resolve(fixtures, name), "utf8");
const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";

let phase = "queued";
const bodies = {
    queued: { status: "saving", step: "queued", queue_ahead: 2, service: "x", waking: false },
    download: { status: "saving", step: "fetching", waking: false, step_bytes: 14_200_000, step_total: 37_600_000, service: "x" },
    saved: { status: "ready", service: "x", public_url: "https://share.capybaraharmony.com/clip" },
    error: { status: "error", service: "x", error: { code: "error.webp.no_video" } },
};

function themed(html, theme) {
    const light = `<style id="cs-theme">
      html, body, article, #stage, #video { background:#fff !important; color:#0f1419 !important; }
      #bar, .count, time, .cell button, .slot button, .slot span, .text { color:#536471 !important; }
      .text { color:#0f1419 !important; }
      #stage { background:#f6f7f8 !important; }
      #video { background:linear-gradient(#f3f3f3,#e7e7e7) !important; }
    </style>`;
    const tagged = html.replace("<html>", `<html data-theme="${theme}">`);
    return theme === "light" ? tagged.replace("</head>", `${light}</head>`) : tagged;
}

const chrome = process.env.CHROME ?? "/home/ubuntu/.cache/ms-playwright/chromium-1208/chrome-linux64/chrome";
const context = await chromium.launchPersistentContext(`/tmp/capystore-feedback-${process.pid}`, {
    executablePath: chrome,
    headless: false,
    viewport: { width: 960, height: 900 },
    ignoreDefaultArgs: ["--disable-extensions"],
    args: [`--disable-extensions-except=${dist}`, `--load-extension=${dist}`, "--no-sandbox", "--disable-dev-shm-usage"],
});

try {
    let sw = context.serviceWorkers()[0];
    if (!sw) sw = await context.waitForEvent("serviceworker", { timeout: 15000 });
    const extId = new URL(sw.url()).host;
    await sw.evaluate(async (key) => {
        await chrome.storage.local.set({
            session: { key, id: "sess-1", device: "Browser extension – Chrome on Mac" },
            phone: true,
        });
    }, KEY);

    const page = context.pages()[0] ?? (await context.newPage());
    page.on("console", (m) => {
        if (m.type() === "error") console.log("PAGE", m.text().slice(0, 300));
    });
    await context.route("https://x.com/**", (route) => {
        const id = new URL(route.request().url()).pathname.split("/").filter(Boolean).pop() || "111";
        const theme = route.request().url().includes("theme=light") ? "light" : "dark";
        const body = themed(read("x-action-bar.html").replaceAll("1111111111111111111", id), theme);
        return route.fulfill({ status: 200, contentType: "text/html; charset=utf-8", body });
    });
    await context.route("https://www.instagram.com/**", (route) => {
        const theme = route.request().url().includes("theme=light") ? "light" : "dark";
        return route.fulfill({ status: 200, contentType: "text/html; charset=utf-8", body: themed(read("ig-reels-rail.html"), theme) });
    });
    await context.route("https://api.capybaraharmony.com/**", (route) => {
        const url = route.request().url();
        if (route.request().method() === "POST" && url.endsWith("/studio")) {
            const sent = JSON.parse(route.request().postData() || "{}");
            if (sent.origin !== "extension" || sent.queue !== true) throw new Error(`save body ${route.request().postData()}`);
            return route.fulfill({
                status: 201,
                contentType: "application/json",
                body: JSON.stringify({
                    status: "success",
                    id: "sid-" + sent.url.length,
                    url: "https://cobalt.capybaraharmony.com/studio/sid",
                    queued: phase === "queued",
                    queue_ahead: phase === "queued" ? 2 : 0,
                }),
            });
        }
        if (url.includes("/studio/sid")) {
            return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(bodies[phase] ?? bodies.queued) });
        }
        return route.fulfill({ status: 404, contentType: "application/json", body: "{}" });
    });

    const file = (name) => `${outDir}/${name}.png`;
    // Frame the button plus any visible tooltip or toast, so a long pill is not cropped.
    const clip = async (name) => {
        const box = await page.evaluate(() => {
            const host = document.querySelector(".capystore-save");
            if (!host?.shadowRoot) return null;
            const nodes = [host];
            for (const sel of [".cs-toast", ".cs-tip"]) {
                const node = host.shadowRoot.querySelector(sel);
                if (!node || node.hidden) continue;
                if (Number(getComputedStyle(node).opacity) < 0.5) continue;
                nodes.push(node);
            }
            const rects = nodes.map((node) => node.getBoundingClientRect());
            return {
                left: Math.min(...rects.map((r) => r.left)),
                top: Math.min(...rects.map((r) => r.top)),
                right: Math.max(...rects.map((r) => r.right)),
                bottom: Math.max(...rects.map((r) => r.bottom)),
            };
        });
        if (!box) throw new Error(`no button for ${name}`);
        const pad = 18;
        const view = page.viewportSize();
        const x = Math.max(0, Math.floor(box.left - pad));
        const y = Math.max(0, Math.floor(box.top - pad));
        const width = Math.max(1, Math.min(view.width - x, Math.ceil(box.right + pad) - x));
        const height = Math.max(1, Math.min(view.height - y, Math.ceil(box.bottom + pad) - y));
        await page.screenshot({ path: file(name), clip: { x, y, width, height } });
    };
    const waitToast = async (text) => {
        try {
            await page.locator(".cs-toast").filter({ hasText: text }).waitFor({ timeout: 10000 });
            await page.waitForFunction(() => {
                const toast = document.querySelector(".capystore-save")?.shadowRoot?.querySelector(".cs-toast");
                return !!toast && !toast.hidden && Number(getComputedStyle(toast).opacity) > 0.95;
            });
        } catch (e) {
            const dump = await page.evaluate(() => {
                const host = document.querySelector(".capystore-save");
                const root = host?.shadowRoot;
                return {
                    url: location.href,
                    host: host?.className ?? null,
                    theme: root?.querySelector(".cs-root")?.dataset.theme ?? null,
                    text: root?.textContent?.replace(/\s+/g, " ").slice(0, 400) ?? null,
                };
            });
            console.log("DUMP", JSON.stringify(dump));
            throw e;
        }
    };
    const shadow = (fn) => page.evaluate(fn);

    const shoot = async (site, theme) => {
        const url = site === "x"
            ? `https://x.com/capy/status/${theme === "light" ? "2222222222222222222" : "1111111111111111111"}${theme === "light" ? "?theme=light" : ""}`
            : `https://www.instagram.com/reels/${theme === "light" ? "LightReel01" : "DarkReel01"}/${theme === "light" ? "?theme=light" : ""}`;
        phase = "queued";
        await page.goto(url, { waitUntil: "domcontentloaded" });
        await page.waitForSelector(".capystore-save", { timeout: 10000 });
        await page.waitForFunction((want) => document.querySelector(".capystore-save")?.shadowRoot?.querySelector(".cs-root")?.dataset.theme === want, theme);
        await page.mouse.move(0, 0);
        const rest = await shadow(() => {
            const host = document.querySelector(".capystore-save");
            const btn = host.shadowRoot.querySelector(".cs-btn");
            const arc = host.shadowRoot.querySelector(".cs-arc");
            const bg = getComputedStyle(btn).backgroundColor;
            const hostBg = getComputedStyle(host).backgroundColor;
            return {
                bg,
                hostBg,
                arc: getComputedStyle(arc).opacity,
                word: host.shadowRoot.querySelector(".cs-word")?.textContent ?? "",
                label: btn.innerText.trim(),
            };
        });
        if (rest.bg !== "rgba(0, 0, 0, 0)") throw new Error(`${site} ${theme} button background ${rest.bg}`);
        if (rest.hostBg !== "rgba(0, 0, 0, 0)") throw new Error(`${site} ${theme} host background ${rest.hostBg}`);
        if (rest.arc !== "0") throw new Error(`${site} ${theme} arc visible at rest (${rest.arc})`);
        if (rest.word !== "" || rest.label !== "") throw new Error(`${site} ${theme} visible label ${JSON.stringify(rest)}`);
        await clip(`after-${site}-rest-${theme}`);
        if (site === "x") await page.locator("article").screenshot({ path: file(`after-x-bar-${theme}`) });
        else await page.locator("#stage").screenshot({ path: file(`after-ig-rail-${theme}`) });
        await page.locator(".cs-btn").hover();
        await page.waitForTimeout(120);
        await clip(`after-${site}-hover-${theme}`);
        const tip = await shadow(() => {
            const node = document.querySelector(".capystore-save").shadowRoot.querySelector(".cs-tip");
            return { opacity: getComputedStyle(node).opacity, text: node.textContent };
        });
        if (tip.opacity !== "1" || tip.text !== "Save to Capystore") throw new Error(`${site} ${theme} tooltip ${JSON.stringify(tip)}`);

        await page.locator(".cs-btn").click();
        await waitToast("2 ahead of you");
        await clip(`after-${site}-queued-${theme}`);
        phase = "download";
        await waitToast("14.2 of 37.6 MB");
        const arc = await shadow(() => {
            const root = document.querySelector(".capystore-save").shadowRoot.querySelector(".cs-root");
            const value = root.querySelector(".cs-value");
            return { p: root.style.getPropertyValue("--p"), width: getComputedStyle(value).strokeWidth, spin: root.classList.contains("spin") };
        });
        if (arc.p !== "38" || arc.spin) throw new Error(`${site} ${theme} arc ${JSON.stringify(arc)}`);
        if (arc.width !== "2px") throw new Error(`${site} ${theme} stroke ${arc.width}`);
        await clip(`after-${site}-downloading-${theme}`);
        if (site === "x" && theme === "dark") {
            const color = await sw.evaluate(() => chrome.action.getBadgeBackgroundColor({}));
            const text = await sw.evaluate(() => chrome.action.getBadgeText({}));
            if (text !== "1") throw new Error(`badge while saving: ${JSON.stringify(text)}`);
            if (color[0] !== 47 || color[1] !== 138 || color[2] !== 249) throw new Error(`badge color while saving: ${JSON.stringify(color)}`);
        }
        phase = "saved";
        await waitToast("Saved to Capystore");
        await page.locator(".cs-toast").getByRole("button", { name: "Open" }).waitFor();
        await page.locator(".cs-toast").getByRole("button", { name: "Copy link" }).waitFor();
        await page.waitForTimeout(350);
        await clip(`after-${site}-saved-${theme}`);
        const place = await shadow(() => {
            const host = document.querySelector(".capystore-save");
            const root = host.shadowRoot.querySelector(".cs-root");
            const toast = root.querySelector(".cs-toast");
            const hb = host.getBoundingClientRect();
            const tb = toast.getBoundingClientRect();
            return {
                left: root.classList.contains("place-left"),
                toastLeft: tb.left,
                toastRight: tb.right,
                toastTop: tb.top,
                toastBottom: tb.bottom,
                hostLeft: hb.left,
                vw: window.innerWidth,
                vh: window.innerHeight,
            };
        });
        if (place.toastLeft < -1 || place.toastRight > place.vw + 1 || place.toastTop < -1 || place.toastBottom > place.vh + 1) {
            throw new Error(`${site} ${theme} toast clipped ${JSON.stringify(place)}`);
        }
        if (site === "ig" && (!place.left || place.toastRight > place.hostLeft + 1)) {
            throw new Error(`${theme} rail toast did not flip left ${JSON.stringify(place)}`);
        }
        phase = "error";
        await page.locator(".cs-btn").click();
        await waitToast("Couldn't find a video in this post");
        await page.waitForTimeout(450);
        await clip(`after-${site}-error-${theme}`);
        if (site === "x" && theme === "dark") {
            await page.locator(".cs-toast").getByRole("button", { name: "Details" }).click();
            await page.locator(".cs-code").waitFor();
            await clip("after-x-error-details-dark");
            const color = await sw.evaluate(() => chrome.action.getBadgeBackgroundColor({}));
            if (color[0] !== 237 || color[1] !== 34 || color[2] !== 54) throw new Error(`badge color on error: ${JSON.stringify(color)}`);
        }
    };

    await shoot("x", "dark");
    await shoot("x", "light");
    await shoot("ig", "dark");
    await shoot("ig", "light");

    await page.emulateMedia({ reducedMotion: "reduce" });
    phase = "queued";
    await page.goto("https://x.com/capy/status/3333333333333333333", { waitUntil: "domcontentloaded" });
    await page.waitForSelector(".capystore-save");
    await page.locator(".cs-btn").click();
    await waitToast("2 ahead of you");
    const motion = await shadow(() => getComputedStyle(document.querySelector(".capystore-save").shadowRoot.querySelector(".cs-value")).animationName);
    if (motion !== "none") throw new Error(`reduced motion still animates (${motion})`);
    await clip("after-x-reduced-dark");
    await page.emulateMedia({ reducedMotion: "no-preference" });

    phase = "queued";
    await page.goto("https://x.com/capy/status/4444444444444444444", { waitUntil: "domcontentloaded" });
    await page.waitForSelector(".capystore-save");
    await page.addStyleTag({
        content: `button, span, div, svg, .capystore-save { background:#fff !important; border:8px solid #9aa0a6 !important; border-radius:999px !important; box-shadow:inset 0 0 0 6px #ccc !important; color:red !important; }`,
    });
    await page.waitForTimeout(250);
    const bled = await shadow(() => {
        const host = document.querySelector(".capystore-save");
        const btn = host.shadowRoot.querySelector(".cs-btn");
        return { host: getComputedStyle(host).backgroundColor, btn: getComputedStyle(btn).backgroundColor, border: getComputedStyle(btn).borderWidth };
    });
    if (bled.host !== "rgba(0, 0, 0, 0)" || bled.btn !== "rgba(0, 0, 0, 0)") throw new Error(`page CSS bled in ${JSON.stringify(bled)}`);
    await page.locator("article").screenshot({ path: file("after-x-bleed-dark") });

    // Let the in-page saves finish before the popup reads storage, or a poll overwrites the fixture.
    phase = "saved";
    await page.waitForTimeout(1600);

    const popupCases = [
        {
            name: "saving",
            recent: [{
                url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                status: "saving",
                at: Date.now(),
                studioUrl: "https://cobalt.capybaraharmony.com/studio/sid",
                progress: { step: "fetching", bytes: 14200000, total: 37600000, waking: false, queueAhead: null, service: "youtube", code: null, publicUrl: null },
            }],
            ready: "#card-headline",
            text: "Downloading from youtube",
        },
        {
            name: "saved",
            recent: [{
                url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                status: "saved",
                at: Date.now(),
                studioUrl: "https://cobalt.capybaraharmony.com/studio/sid",
                shareUrl: "https://share.capybaraharmony.com/clip",
                progress: { step: null, bytes: null, total: null, waking: false, queueAhead: null, service: "youtube", code: null, publicUrl: "https://share.capybaraharmony.com/clip" },
            }],
            ready: { role: "button", name: "Open in Studio" },
            text: "Saved to Capystore",
        },
        {
            name: "error",
            recent: [{
                url: "https://x.com/capy/status/9",
                status: "error",
                at: Date.now(),
                studioUrl: "https://cobalt.capybaraharmony.com/studio/err",
                error: "Couldn't find a video in this post",
                code: "error.webp.no_video",
                progress: { step: null, bytes: null, total: null, waking: false, queueAhead: null, service: null, code: "error.webp.no_video", publicUrl: null },
            }],
            ready: { role: "button", name: "Retry" },
            text: "Couldn't find a video in this post",
        },
    ];
    for (const scheme of ["dark", "light"]) {
        for (const item of popupCases) {
            await sw.evaluate(async (recent) => {
                await chrome.storage.local.set({ recent, phone: true });
            }, item.recent);
            const popup = await context.newPage();
            await popup.emulateMedia({ colorScheme: scheme });
            await popup.setViewportSize({ width: 360, height: 640 });
            await popup.goto(`chrome-extension://${extId}/popup.html`);
            if (item.ready === "#card-headline") await popup.locator("#card-headline").waitFor();
            else await popup.getByRole(item.ready.role, { name: item.ready.name }).waitFor();
            const headline = await popup.locator("#card-headline").innerText();
            if (!headline.includes(item.text)) throw new Error(`popup ${item.name} ${scheme}: ${headline}`);
            if (item.name === "saving") {
                const width = await popup.locator("#card-fill").evaluate((el) => el.style.width);
                if (width !== "38%") throw new Error(`popup bar ${width}`);
                if ((await popup.locator("#phone").isChecked()) !== true) throw new Error("iPhone toggle should start on");
            }
            await popup.locator("body").screenshot({ path: file(`after-popup-${item.name}-${scheme}`) });
            await popup.close();
        }
    }

    console.log("feedback shots ok");
} finally {
    await context.close();
}
