// A tiny Chrome DevTools Protocol driver for the chat renderer: launch headless Chromium, open one page, evaluate, take
// screenshots. No dependencies (Node's own WebSocket), so the editor image stays dependency-free.
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

export const CHROMIUM_ARGS = [
    "--headless=new", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage", "--hide-scrollbars", "--mute-audio",
    "--no-first-run", "--no-default-browser-check", "--disable-extensions", "--disable-background-networking",
    "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
    "--font-render-hinting=none", "--force-color-profile=srgb", "--remote-debugging-port=0", "about:blank",
];

/** The Chromium binary: CHAT_CHROMIUM, else the usual Alpine / Debian paths. */
export function chromiumPath() {
    return process.env.CHAT_CHROMIUM || "/usr/bin/chromium-browser";
}

/**
 * @param {{bin?: string, timeoutMs?: number}} [o]
 * @returns {Promise<{newPage: (w: number, h: number, scale: number) => Promise<Page>, close: () => Promise<void>}>}
 */
export async function launch(o = {}) {
    const profile = await mkdtemp(path.join(os.tmpdir(), "chat-chromium-"));
    const child = spawn(o.bin ?? chromiumPath(), [`--user-data-dir=${profile}`, ...CHROMIUM_ARGS], { stdio: ["ignore", "ignore", "pipe"] });
    const wsUrl = await new Promise((resolve, reject) => {
        let buf = "";
        const timer = setTimeout(() => reject(new Error(`chromium did not start: ${buf.slice(-500)}`)), o.timeoutMs ?? 30000);
        child.on("error", (e) => (clearTimeout(timer), reject(e)));
        child.on("exit", (code) => (clearTimeout(timer), reject(new Error(`chromium exited ${code}: ${buf.slice(-500)}`))));
        child.stderr.setEncoding("utf8").on("data", (d) => {
            buf = (buf + d).slice(-4000);
            const m = buf.match(/DevTools listening on (ws:\/\/\S+)/);
            if (m) {
                clearTimeout(timer);
                resolve(m[1]);
            }
        });
    });
    child.removeAllListeners("exit");
    const ws = new WebSocket(/** @type {string} */ (wsUrl));
    await new Promise((res, rej) => {
        ws.onopen = res;
        ws.onerror = () => rej(new Error("cdp connect failed"));
    });
    let id = 0;
    /** @type {Map<number, {resolve: Function, reject: Function}>} */
    const waiting = new Map();
    ws.onmessage = (ev) => {
        const msg = JSON.parse(String(ev.data));
        if (msg.id && waiting.has(msg.id)) {
            const w = /** @type {any} */ (waiting.get(msg.id));
            waiting.delete(msg.id);
            if (msg.error) w.reject(new Error(`${msg.error.message} ${msg.error.data ?? ""}`));
            else w.resolve(msg.result);
        }
    };
    ws.onclose = () => {
        for (const w of waiting.values()) w.reject(new Error("cdp closed"));
        waiting.clear();
    };
    /** @param {string} method @param {object} [params] @param {string} [sessionId] @returns {Promise<any>} */
    const send = (method, params = {}, sessionId) =>
        new Promise((resolve, reject) => {
            const n = ++id;
            waiting.set(n, { resolve, reject });
            ws.send(JSON.stringify({ id: n, method, params, ...(sessionId ? { sessionId } : {}) }));
        });

    return {
        async newPage(w, h, scale) {
            const { targetId } = await send("Target.createTarget", { url: "about:blank" });
            const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
            const s = (/** @type {string} */ m, /** @type {object} */ p) => send(m, p, sessionId);
            await s("Page.enable", {});
            await s("Runtime.enable", {});
            await s("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: scale, mobile: false });
            await s("Emulation.setDefaultBackgroundColorOverride", { color: { r: 0, g: 0, b: 0, a: 1 } });
            return {
                async goto(url) {
                    await s("Page.navigate", { url });
                },
                /** Evaluates an expression; awaits a promise it returns. */
                async evaluate(expression) {
                    const r = await s("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
                    if (r.exceptionDetails) throw new Error(`page: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
                    return r.result?.value;
                },
                /** One JPEG of the viewport at device pixels. */
                async jpeg(quality = 90) {
                    const r = await s("Page.captureScreenshot", { format: "jpeg", quality, optimizeForSpeed: true });
                    return Buffer.from(r.data, "base64");
                },
                async close() {
                    await send("Target.closeTarget", { targetId }).catch(() => {});
                },
            };
        },
        async close() {
            try {
                ws.close();
            } catch {}
            child.kill("SIGKILL");
            await rm(profile, { recursive: true, force: true }).catch(() => {});
        },
    };
}

/** @typedef {{goto: (url: string) => Promise<void>, evaluate: (expr: string) => Promise<any>, jpeg: (q?: number) => Promise<Buffer>, close: () => Promise<void>}} Page */
