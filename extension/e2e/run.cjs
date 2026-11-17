// End-to-end check of the built extension in a real Chromium (the same engine as Chrome and Helium).
// Loads extension/dist unpacked, serves a fake x.com post and a fake Capystore API/web, and walks:
//   1. the Save button appears on the post
//   2. a signed-out click opens the approve tab and shows the busy capy
//   3. once the pairing is approved, the extension stores the session and the click saves the post
//   4. reloading the extension under an open tab does not throw "Extension context invalidated"
// Nothing leaves the machine: every https request is answered by a route below.
//
//   cd extension && npm run build && npm run e2e         (needs `playwright` + its Chromium:
//   npx playwright install chromium, or a machine that already has them)
// Exit code 0 = all steps passed.
const { chromium } = require("playwright");
const path = require("node:path");

const DIST = process.env.EXT_DIST ? path.resolve(process.env.EXT_DIST) : path.resolve(__dirname, "../dist");
const KEY = "11111111-2222-4333-8444-555555555555";
const POST = "https://x.com/capy/status/123";

const X_PAGE = `<!doctype html><html><body>
<article data-testid="tweet"><a href="/capy/status/123"><time>now</time></a>
<div role="group"><button>reply</button><button>like</button></div></article></body></html>`;

let failures = 0;
const check = (ok, what) => {
    console.log(`${ok ? "ok  " : "FAIL"} ${what}`);
    if (!ok) failures++;
};

(async () => {
    const ctx = await chromium.launchPersistentContext("", {
        headless: true,
        channel: "chromium", // extensions need the full Chromium, not the headless shell
        args: [`--disable-extensions-except=${DIST}`, `--load-extension=${DIST}`],
    });
    const api = [];
    let approved = false;
    let polls = 0;
    await ctx.route("https://x.com/**", (r) => r.fulfill({ contentType: "text/html", body: X_PAGE }));
    await ctx.route("https://cobalt.capybaraharmony.com/**", (r) => r.fulfill({ contentType: "text/html", body: "<h1>approve</h1>" }));
    await ctx.route("https://api.capybaraharmony.com/**", async (r) => {
        const req = r.request();
        const u = new URL(req.url());
        api.push(`${req.method()} ${u.pathname}`);
        if (u.pathname === "/auth/extension/begin") {
            return r.fulfill({ status: 201, json: { status: "pending", device_code: "d".repeat(43), user_code: "u".repeat(43), expires_at: Date.now() + 60_000, interval: 1 } });
        }
        if (u.pathname === "/auth/extension/poll") {
            polls++;
            if (!approved) return r.fulfill({ status: 202, json: { status: "pending", interval: 1 } });
            return r.fulfill({ json: { status: "success", key: KEY, session: { id: "sess-1", device: "Browser extension – Chrome on Mac" } } });
        }
        if (u.pathname === "/studio" && req.method() === "POST") {
            const body = JSON.parse(req.postData() || "{}");
            const auth = req.headers()["authorization"];
            check(auth === `Api-Key ${KEY}`, "save sends the session key");
            check(body.url === POST && body.origin === "extension" && body.queue === true, "save posts the post URL with origin extension");
            return r.fulfill({ status: 201, json: { status: "success", id: "sid", url: "https://cobalt.capybaraharmony.com/studio/sid" } });
        }
        if (u.pathname === "/studio/sid") return r.fulfill({ json: { status: "ready", id: "sid" } });
        return r.fulfill({ status: 404, json: {} });
    });

    let [sw] = ctx.serviceWorkers();
    if (!sw) sw = await ctx.waitForEvent("serviceworker");
    const page = await ctx.newPage();
    const errors = [];
    const cdp = await ctx.newCDPSession(page);
    await cdp.send("Runtime.enable");
    cdp.on("Runtime.exceptionThrown", (e) => errors.push((e.exceptionDetails.exception?.description ?? e.exceptionDetails.text).split("\n")[0]));

    await page.goto(POST);
    const button = page.locator(".capystore-save button");
    await button.waitFor({ timeout: 5000 });
    check((await button.count()) === 1, "one Save button on the post");
    check(/Sign in/.test((await button.getAttribute("title")) ?? ""), "signed out: the button says sign in");

    const tab = ctx.waitForEvent("page");
    await button.click();
    const approve = await tab;
    await approve.waitForURL(/connect\/extension/, { timeout: 5000 }).catch(() => {});
    check(approve.url().startsWith("https://cobalt.capybaraharmony.com/connect/extension?user_code="), `click opens the approve tab (${approve.url()})`);
    const capy = page.locator(".capystore-save .capy");
    check(/saving/.test((await capy.getAttribute("class")) ?? ""), "the capy shows it is busy while waiting");

    approved = true;
    await page.waitForFunction(() => /saved/.test(document.querySelector(".capystore-save")?.shadowRoot?.querySelector(".capy")?.className ?? ""), null, { timeout: 10_000 }).then(
        () => check(true, "the first click goes on to save the post"),
        () => check(false, `the first click goes on to save the post (api: ${api.join(", ")})`),
    );
    const stored = await sw.evaluate(async () => (await chrome.storage.local.get("session")).session);
    check(stored?.key === KEY, "approval stored the session in the extension");

    errors.length = 0;
    await sw.evaluate(() => chrome.runtime.reload());
    await page.waitForTimeout(5000);
    await button.click(); // an old page's button, after the extension under it was reloaded
    await page.waitForTimeout(500);
    check(errors.filter((e) => /context invalidated/i.test(e)).length === 0, `no "Extension context invalidated" after a reload (${errors.join(" | ") || "none"})`);
    check(/reload this page/.test((await button.getAttribute("title")) ?? ""), "the orphaned button says to reload the page");

    await ctx.close();
    console.log(failures ? `\n${failures} failed` : "\nall passed");
    process.exit(failures ? 1 : 0);
})().catch((e) => {
    console.error(e);
    process.exit(1);
});
