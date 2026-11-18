// Background service worker. Every API call happens here, with credentials omitted.
// Content scripts and the popup ask for state; the session token stays in extension storage.

import { getExt, type Ext } from "./lib/browser";
import { badgeColor } from "./lib/brand";
import { EMPTY_PROGRESS, type SaveProgress } from "./lib/progress";
import { createSave, followSave, LIBRARY_URL, type SaveOutcome } from "./lib/save";
import { runSignIn } from "./lib/signin";
import { DEFAULT_SITES, normalizeSites, publicAuth, type RecentSave, type SiteId, type StoredSession } from "./lib/view";

const SESSION = "session";
const RECENT = "recent";
const SITES = "sites";
const PHONE = "phone";
const MENU_ID = "save-to-capystore";
const RECENT_MAX = 20;
const loops = new Set<string>();
let offline = false;
let signingIn: Promise<unknown> | null = null;
// The match code of a polled sign-in in progress (signin.ts matchCode), shown in the popup.
let pairing: string | null = null;

type JobSite = SiteId | "web";
type Job = { id: string; url: string; studioUrl: string; site: JobSite; tabId?: number };

export function wire(ext: Ext, fetchImpl: typeof fetch = fetch): void {
    // Answer through sendResponse and return true: the form every Chromium (Helium, older Chrome) and Safari
    // accept. A listener that only returns a Promise answers undefined on Chromium builds without that support.
    ext.runtime.onMessage.addListener((message, sender, sendResponse) => {
        handle(ext, fetchImpl, message, sender?.tab?.id).then(
            (reply) => sendResponse?.(reply),
            () => sendResponse?.(undefined),
        );
        return true;
    });
    ext.alarms?.onAlarm.addListener((alarm) => {
        if (alarm.name === "capystore-saves") void resume(ext, fetchImpl);
    });
    installMenu(ext, fetchImpl);
    void resume(ext, fetchImpl);
}

async function handle(ext: Ext, fetchImpl: typeof fetch, message: unknown, tabId?: number): Promise<unknown> {
    const msg = message && typeof message === "object" ? (message as Record<string, unknown>) : {};
    switch (msg.type) {
        case "auth-state":
            return publicAuth(await session(ext), offline);
        case "recent":
            return authView(ext);
        case "sign-in":
            return signIn(ext, fetchImpl);
        case "sign-out":
            return signOut(ext, fetchImpl);
        case "save":
            if (typeof msg.url !== "string") return { state: "error", message: "Couldn't save this post." };
            return save(ext, fetchImpl, msg.url, siteOf(msg.site, msg.url), tabId);
        case "set-phone":
            await ext.storage.local.set({ [PHONE]: msg.on !== false });
            return { on: msg.on !== false };
        case "status":
            return statusOf(ext, fetchImpl, typeof msg.url === "string" ? msg.url : "", tabId);
        case "get-sites":
            return normalizeSites((await ext.storage.local.get(SITES))[SITES]);
        case "set-sites":
            await ext.storage.local.set({ [SITES]: normalizeSites(msg.sites) });
            return normalizeSites(msg.sites);
        case "open":
            if (msg.url === LIBRARY_URL || (typeof msg.url === "string" && msg.url.startsWith(`${LIBRARY_URL.replace("/library", "")}/studio/`))) {
                await ext.tabs.create({ url: msg.url });
            } else if (msg.url === "library") {
                await ext.tabs.create({ url: LIBRARY_URL });
            }
            return { ok: true };
        default:
            return { ok: false };
    }
}

async function authView(ext: Ext) {
    const view = publicAuth(await session(ext), offline);
    const jobs = await recent(ext);
    const phone = (await ext.storage.local.get(PHONE))[PHONE];
    return { ...view, saving: jobs.some((j) => j.status === "saving"), recent: jobs, pairing, phone: phone !== false };
}

async function signIn(ext: Ext, fetchImpl: typeof fetch): Promise<unknown> {
    if (signingIn) return signingIn;
    signingIn = (async () => {
        const redirectUri = ext.identity?.getRedirectURL?.() ?? null;
        // Always the tab + poll sign-in. launchWebAuthFlow's window does not finish in every Chromium build
        // (Helium, other forks), and a hung window looks like a dead button. A normal tab carries the browser's
        // own Access cookie and works in every browser; the popup shows the match code meanwhile.
        const launch = null;
        const result = await runSignIn({
            fetch: fetchImpl,
            ua: navigator.userAgent,
            redirectUri,
            launch,
            openTab: async (url) => {
                await ext.tabs.create({ url });
            },
            onCode: (code) => {
                pairing = code;
            },
        });
        if (!result.ok) return { ok: false, message: result.message, ...publicAuth(await session(ext), offline) };
        const stored: StoredSession = { key: result.key, id: result.id, device: result.device };
        await ext.storage.local.set({ [SESSION]: stored });
        offline = false;
        return { ok: true, ...publicAuth(stored, false) };
    })().finally(() => {
        signingIn = null;
        pairing = null;
    });
    return signingIn;
}

async function signOut(ext: Ext, fetchImpl: typeof fetch): Promise<unknown> {
    const current = await session(ext);
    if (current) {
        try {
            await fetchImpl("https://api.capybaraharmony.com/auth/signout", {
                method: "POST",
                headers: { authorization: `Api-Key ${current.key}`, "content-type": "application/json" },
                body: "{}",
                credentials: "omit",
                cache: "no-store",
            });
            offline = false;
        } catch {
            offline = true;
        }
    }
    await ext.storage.local.remove(SESSION);
    return publicAuth(null, offline);
}

async function save(ext: Ext, fetchImpl: typeof fetch, url: string, site: JobSite, tabId?: number): Promise<unknown> {
    const current = await session(ext);
    if (!current) return { state: "signed-out" };
    const existing = (await recent(ext)).find((r) => r.url === url && r.status === "saving");
    if (existing) return { state: "saving", url };
    const phone = (await ext.storage.local.get(PHONE))[PHONE] !== false;
    const created = await createSave(fetchImpl, current.key, url, phone);
    if (created.kind === "signed-out") {
        await ext.storage.local.remove(SESSION);
        return { state: "signed-out" };
    }
    if (created.kind === "offline") {
        offline = true;
        return { state: "offline" };
    }
    if (created.kind === "error") return { state: "error", message: created.message, code: created.code };
    const job: Job = { id: created.id, url, studioUrl: created.studioUrl, site, ...(tabId !== undefined ? { tabId } : {}) };
    await remember(ext, { url, status: "saving", at: Date.now(), studioUrl: created.studioUrl, progress: created.progress, site });
    void paintBadge(ext);
    tell(ext, job, "saving", created.progress);
    void follow(ext, fetchImpl, current.key, job);
    ext.alarms?.create("capystore-saves", { periodInMinutes: 1 });
    return { state: "saving", url, studioUrl: created.studioUrl };
}

async function follow(ext: Ext, fetchImpl: typeof fetch, key: string, job: Job): Promise<void> {
    if (loops.has(job.id)) return;
    loops.add(job.id);
    try {
        const outcome = await followSave({
            fetch: fetchImpl,
            key,
            id: job.id,
            studioUrl: job.studioUrl,
            waitSeconds: 20,
            onProgress: (step) => {
                if (step.kind !== "saving") return;
                void remember(ext, {
                    url: job.url,
                    status: "saving",
                    at: Date.now(),
                    studioUrl: job.studioUrl,
                    site: job.site,
                    progress: step.progress,
                }).then(() => tell(ext, job, "saving", step.progress));
            },
        });
        await apply(ext, job, outcome);
    } finally {
        loops.delete(job.id);
    }
}

async function apply(ext: Ext, job: Job, outcome: SaveOutcome): Promise<void> {
    if (outcome.kind === "signed-out") {
        await ext.storage.local.remove(SESSION);
        offline = false;
        tell(ext, job, "sleeping");
        return;
    }
    if (outcome.kind === "offline") {
        offline = true;
        tell(ext, job, "sleeping");
        return;
    }
    if (outcome.kind === "saving") return;
    offline = false;
    const status = outcome.kind === "saved" ? "saved" : "error";
    const progress: SaveProgress =
        outcome.kind === "saved"
            ? outcome.progress
            : { ...EMPTY_PROGRESS, code: outcome.code };
    await remember(ext, {
        url: job.url,
        status,
        at: Date.now(),
        studioUrl: job.studioUrl,
        site: job.site,
        progress,
        ...(outcome.kind === "error" ? { error: outcome.message, code: outcome.code } : { shareUrl: outcome.shareUrl }),
    });
    tell(ext, job, status, progress, outcome.kind === "saved" ? outcome.shareUrl : null);
    void flashBadge(ext, status === "saved" ? "✓" : "!");
}

function tell(ext: Ext, job: Job, state: string, progress?: SaveProgress, shareUrl?: string | null) {
    if (job.tabId === undefined) return;
    void ext.tabs
        .sendMessage(job.tabId, { type: "save-update", url: job.url, state, progress: progress ?? null, studioUrl: job.studioUrl, shareUrl: shareUrl ?? null })
        .catch(() => {});
}

let badgeTimer: ReturnType<typeof setTimeout> | undefined;
async function paintBadge(ext: Ext, text?: string) {
    const n = (await recent(ext)).filter((r) => r.status === "saving").length;
    const shown = text ?? (n > 0 ? String(Math.min(n, 9)) : "");
    try {
        await ext.action?.setBadgeBackgroundColor({ color: badgeColor(text) });
        await ext.action?.setBadgeTextColor?.({ color: "#ffffff" });
        await ext.action?.setBadgeText({ text: shown });
    } catch {
        // Safari builds that have no badge API.
    }
}

function flashBadge(ext: Ext, mark: "✓" | "!") {
    if (badgeTimer) clearTimeout(badgeTimer);
    void paintBadge(ext, mark);
    badgeTimer = setTimeout(() => void paintBadge(ext), 4000);
}

function installMenu(ext: Ext, fetchImpl: typeof fetch) {
    const menus = ext.contextMenus;
    if (!menus?.create || !menus.onClicked) return;
    try {
        menus.create({ id: MENU_ID, title: "Save to Capystore", contexts: ["image", "video", "link", "page"] });
    } catch {
        return;
    }
    menus.onClicked.addListener((info, tab) => {
        if (info.menuItemId !== MENU_ID) return;
        const url = info.srcUrl || info.linkUrl || info.pageUrl;
        if (!url || !/^https?:\/\//i.test(url)) return;
        void save(ext, fetchImpl, url, siteOf(undefined, url), tab?.id);
    });
}

function siteOf(given: unknown, url: string): JobSite {
    if (given === "x" || given === "youtube" || given === "twitch" || given === "instagram") return given;
    try {
        const host = new URL(url).hostname.replace(/^www\./, "");
        if (host === "youtu.be" || host.endsWith("youtube.com")) return "youtube";
        if (host.endsWith("twitch.tv")) return "twitch";
        if (host.endsWith("instagram.com")) return "instagram";
        if (host === "x.com" || host.endsWith("twitter.com")) return "x";
    } catch {
        // not a URL
    }
    return "web";
}

async function statusOf(ext: Ext, fetchImpl: typeof fetch, url: string, tabId?: number): Promise<unknown> {
    const row = (await recent(ext)).find((r) => r.url === url);
    const current = await session(ext);
    const auth = publicAuth(current, offline);
    if (row?.status === "saving" && row.studioUrl && current) {
        const id = row.studioUrl.split("/").pop();
        if (id) void follow(ext, fetchImpl, current.key, { id, url: row.url, studioUrl: row.studioUrl, site: "x", ...(tabId !== undefined ? { tabId } : {}) });
    }
    if (!auth.signedIn) return { state: "signed-out", ...auth };
    if (auth.offline) return { state: "sleeping", ...auth };
    if (!row) return { state: "idle", ...auth };
    return { state: row.status, url, progress: row.progress ?? null, studioUrl: row.studioUrl ?? null, shareUrl: row.shareUrl ?? null, code: row.code ?? null, ...auth };
}

async function resume(ext: Ext, fetchImpl: typeof fetch) {
    const current = await session(ext);
    if (!current) return;
    for (const row of await recent(ext)) {
        if (row.status !== "saving" || !row.studioUrl) continue;
        const id = row.studioUrl.split("/").pop();
        if (!id || loops.has(id)) continue;
        void follow(ext, fetchImpl, current.key, { id, url: row.url, studioUrl: row.studioUrl, site: "x" });
    }
}

async function session(ext: Ext): Promise<StoredSession | null> {
    const raw = (await ext.storage.local.get(SESSION))[SESSION];
    if (!raw || typeof raw !== "object") return null;
    const s = raw as StoredSession;
    if (typeof s.key !== "string" || typeof s.id !== "string") return null;
    return { key: s.key, id: s.id, device: typeof s.device === "string" ? s.device : "Browser extension" };
}

async function recent(ext: Ext): Promise<RecentSave[]> {
    const raw = (await ext.storage.local.get(RECENT))[RECENT];
    if (!Array.isArray(raw)) return [];
    return raw.filter((r): r is RecentSave => !!r && typeof r === "object" && typeof (r as RecentSave).url === "string");
}

async function remember(ext: Ext, row: RecentSave) {
    const rest = (await recent(ext)).filter((r) => r.url !== row.url);
    await ext.storage.local.set({ [RECENT]: [row, ...rest].slice(0, RECENT_MAX) });
}

const ext = getExt();
if (ext) wire(ext);

export { DEFAULT_SITES };
