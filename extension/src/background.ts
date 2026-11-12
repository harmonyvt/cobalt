// Background service worker. Every API call happens here, with credentials omitted.
// Content scripts and the popup ask for state; the session token stays in extension storage.

import { getExt, type Ext } from "./lib/browser";
import { createSave, followSave, LIBRARY_URL, type SaveOutcome } from "./lib/save";
import { runSignIn } from "./lib/signin";
import { DEFAULT_SITES, normalizeSites, publicAuth, type RecentSave, type SiteId, type StoredSession } from "./lib/view";

const SESSION = "session";
const RECENT = "recent";
const SITES = "sites";
const RECENT_MAX = 20;
const loops = new Set<string>();
let offline = false;
let signingIn: Promise<unknown> | null = null;

type Job = { id: string; url: string; studioUrl: string; site: SiteId; tabId?: number };

export function wire(ext: Ext, fetchImpl: typeof fetch = fetch): void {
    ext.runtime.onMessage.addListener((message, sender) => handle(ext, fetchImpl, message, sender?.tab?.id));
    ext.alarms?.onAlarm.addListener((alarm) => {
        if (alarm.name === "capystore-saves") void resume(ext, fetchImpl);
    });
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
            if (typeof msg.url !== "string" || !isSite(msg.site)) return { state: "error", message: "Couldn't save this post." };
            return save(ext, fetchImpl, msg.url, msg.site, tabId);
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
    return { ...view, saving: jobs.some((j) => j.status === "saving"), recent: jobs };
}

async function signIn(ext: Ext, fetchImpl: typeof fetch): Promise<unknown> {
    if (signingIn) return signingIn;
    signingIn = (async () => {
        const redirectUri = ext.identity?.getRedirectURL?.() ?? null;
        const launch = ext.identity?.launchWebAuthFlow ? (url: string) => ext.identity!.launchWebAuthFlow({ url, interactive: true }) : null;
        const result = await runSignIn({
            fetch: fetchImpl,
            ua: navigator.userAgent,
            redirectUri,
            launch,
            openTab: async (url) => {
                await ext.tabs.create({ url });
            },
        });
        if (!result.ok) return { ok: false, message: result.message, ...publicAuth(await session(ext), offline) };
        const stored: StoredSession = { key: result.key, id: result.id, device: result.device };
        await ext.storage.local.set({ [SESSION]: stored });
        offline = false;
        return { ok: true, ...publicAuth(stored, false) };
    })().finally(() => {
        signingIn = null;
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

async function save(ext: Ext, fetchImpl: typeof fetch, url: string, site: SiteId, tabId?: number): Promise<unknown> {
    const current = await session(ext);
    if (!current) return { state: "signed-out" };
    const existing = (await recent(ext)).find((r) => r.url === url && r.status === "saving");
    if (existing) return { state: "saving", url };
    const created = await createSave(fetchImpl, current.key, url);
    if (created.kind === "signed-out") {
        await ext.storage.local.remove(SESSION);
        return { state: "signed-out" };
    }
    if (created.kind === "offline") {
        offline = true;
        return { state: "offline" };
    }
    if (created.kind === "error") return { state: "error", message: created.message };
    const job: Job = { id: created.id, url, studioUrl: created.studioUrl, site, ...(tabId !== undefined ? { tabId } : {}) };
    await remember(ext, { url, status: "saving", at: Date.now(), studioUrl: created.studioUrl });
    void follow(ext, fetchImpl, current.key, job);
    ext.alarms?.create("capystore-saves", { periodInMinutes: 1 });
    return { state: "saving", url, studioUrl: created.studioUrl };
}

async function follow(ext: Ext, fetchImpl: typeof fetch, key: string, job: Job): Promise<void> {
    if (loops.has(job.id)) return;
    loops.add(job.id);
    try {
        const outcome = await followSave({ fetch: fetchImpl, key, id: job.id, studioUrl: job.studioUrl, waitSeconds: 20 });
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
    await remember(ext, {
        url: job.url,
        status,
        at: Date.now(),
        studioUrl: job.studioUrl,
        ...(outcome.kind === "error" ? { error: outcome.message } : {}),
    });
    tell(ext, job, status);
}

function tell(ext: Ext, job: Job, state: string) {
    if (job.tabId === undefined) return;
    void ext.tabs.sendMessage(job.tabId, { type: "save-update", url: job.url, state }).catch(() => {});
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
    return { state: row.status, url, ...auth };
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

function isSite(v: unknown): v is SiteId {
    return v === "x" || v === "youtube" || v === "twitch" || v === "instagram";
}

const ext = getExt();
if (ext) wire(ext);

export { DEFAULT_SITES };
