// Injects one Save button per post. Re-scans on DOM changes so a feed that scrolls in more posts,
// and a site that redraws itself without a navigation, both get buttons. A button that was mounted
// before its real anchor existed is moved there on the next scan.

import { getExt, type Ext } from "./lib/browser";
import { deepAll, mountedHost, relocateHost, type FoundPost, type Scan } from "./lib/find";
import { describeSave, EMPTY_PROGRESS, type SaveFace, type SaveProgress } from "./lib/progress";
import { spriteCss, type SiteId, type SpriteState } from "./lib/view";

const HOST = "capystore-save";

function buttonCss(fit?: FoundPost["fit"]): string {
    // X's action icons are about 34px; the reels rail's hit targets are about 40px.
    const size = fit === "rail" ? 40 : fit === "row" ? 34 : 36;
    const sprite = fit ? spriteCss(20, 14) : spriteCss();
    return `
:host { all: initial; position: relative; }
button {
  display: inline-flex; align-items: center; justify-content: center; gap: 4px;
  margin: 0; padding: 0; border: 0; background: transparent; color: inherit;
  font: 13px/1 -apple-system, system-ui, sans-serif; cursor: pointer; border-radius: 999px;
}
button.icon { width: ${size}px; height: auto; min-height: ${size}px; flex-direction: column; gap: 1px; }
button.pill { height: 36px; padding: 0 10px 0 4px; flex-direction: row; }
button:hover, button:focus-visible { background: color-mix(in srgb, currentColor 12%, transparent); outline: none; }
.ring { width: ${size}px; height: ${size}px; border-radius: 999px; display: grid; place-items: center; background: transparent; box-shadow: inset 0 0 0 2px color-mix(in srgb, currentColor 35%, transparent); }
.ring.on { background: conic-gradient(#f4f1ea calc(var(--p) * 1%), transparent 0); }
.ring.spin { background: conic-gradient(transparent 0 70%, #f4f1ea 0 100%); animation: capy-spin 0.9s linear infinite; }
@keyframes capy-spin { to { transform: rotate(1turn); } }
.label { font: 10px/1 -apple-system, system-ui, sans-serif; color: inherit; }
.label:empty { display: none; }
.toast {
  position: absolute; top: calc(100% + 6px); left: 0; z-index: 2147483646;
  width: max-content; max-width: 280px; box-sizing: border-box;
  background: #141414; color: #f4f1ea; border-radius: 12px; padding: 8px 10px;
  font: 12px/1.35 -apple-system, system-ui, sans-serif; box-shadow: 0 10px 28px rgba(0,0,0,.45);
}
.toast[hidden] { display: none; }
.toast .row { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.toast button { width: auto; height: auto; min-height: 0; padding: 2px 8px; border-radius: 999px; background: #2a2622; color: inherit; font: inherit; }
.toast .code { display: block; margin-top: 4px; color: #b7b0a4; font-family: ui-monospace, monospace; font-size: 11px; }
${sprite}
`;
}

const LABEL: Record<SpriteState, string> = {
    idle: "Save to Capystore",
    saving: "Saving to Capystore",
    saved: "Saved to Capystore",
    error: "Couldn't save to Capystore",
    sleeping: "Sign in to Capystore",
};

type Button = {
    url: string;
    button: HTMLButtonElement;
    capy: HTMLElement;
    ring: HTMLElement;
    label: HTMLElement;
    toast: HTMLElement;
    toastText: HTMLElement;
    state: SpriteState;
    hideToast: number;
};

export function start(site: SiteId, scan: Scan): void {
    const ext = getExt();
    if (!ext || (globalThis as { __capystoreStarted?: Set<string> }).__capystoreStarted?.has(site)) return;
    const flag = ((globalThis as { __capystoreStarted?: Set<string> }).__capystoreStarted ??= new Set());
    flag.add(site);
    const buttons = new Set<Button>();
    let enabled = true;
    let signedIn = true;
    let observer: MutationObserver | undefined;
    let tick = 0;
    let hrefTimer = 0;
    let retired = false;

    // After the extension is reloaded or updated, this script keeps running on the open page but can no
    // longer reach the background ("Extension context invalidated"). Stop quietly and tell the user.
    const retire = () => {
        if (retired) return;
        retired = true;
        observer?.disconnect();
        window.clearInterval(tick);
        window.clearInterval(hrefTimer);
        for (const b of buttons) {
            paint(b, "sleeping");
            b.button.title = "Capystore was updated: reload this page";
            b.button.setAttribute("aria-label", b.button.title);
        }
    };
    const send = async (message: unknown): Promise<unknown> => {
        if (retired) return undefined;
        try {
            if (!ext.runtime.id) throw new Error("Extension context invalidated.");
            return await ext.runtime.sendMessage(message);
        } catch (e) {
            if (!ext.runtime.id || /context invalidated/i.test(String(e))) retire();
            return undefined;
        }
    };

    const sheet = document.createElement("style");
    // Shrink to the button. A flex or grid parent (a card, <main>, a results row) would otherwise stretch this into a full-width bar.
    // `row` takes an equal share of an X action bar so the row does not wrap. `rail` is one reels slot.
    sheet.textContent = `.${HOST}{display:inline-flex;align-items:center;vertical-align:middle;position:relative;width:max-content;max-width:max-content;flex:0 0 auto;align-self:center;box-sizing:border-box}.${HOST}.row{display:flex;flex:1 1 0%;width:auto;max-width:none;min-width:0;justify-content:flex-start}.${HOST}.rail{display:flex;flex:0 0 auto;width:auto;max-width:none;min-width:0;justify-content:center}`;
    document.documentElement.appendChild(sheet);

    const paint = (b: Button, state: SpriteState) => {
        b.state = state;
        b.capy.className = `capy ${state}`;
        const label = state === "sleeping" && signedIn ? "Capystore is offline" : LABEL[state];
        b.button.setAttribute("aria-label", label);
        b.button.title = label;
    };

    const findHost = (url: string): HTMLElement | null => {
        for (const el of deepAll(document, `.${HOST}`)) {
            if ((el as HTMLElement).dataset.url === url) return el as HTMLElement;
        }
        return null;
    };

    const mark = (host: HTMLElement, found: FoundPost) => {
        host.className = found.fit ? `${HOST} ${found.fit}` : HOST;
        host.dataset.url = found.url;
    };

    const ensure = (found: FoundPost) => {
        // Same rail, new reel: the page URL changed and the button is already in this mount.
        const prev = findHost(found.url) ?? mountedHost(found.mount, HOST);
        if (prev) {
            const previousUrl = prev.dataset.url ?? "";
            if (previousUrl && previousUrl !== found.url) {
                for (const b of buttons) if (b.url === previousUrl) b.url = found.url;
            }
            mark(prev, found);
            relocateHost(prev, found.mount, found.after, found.before);
            return;
        }
        const host = document.createElement("span");
        mark(host, found);
        const root = host.attachShadow({ mode: "open" });
        const style = document.createElement("style");
        style.textContent = buttonCss(found.fit);
        const button = document.createElement("button");
        button.type = "button";
        button.className = found.variant;
        const ring = document.createElement("span");
        ring.className = "ring";
        const capy = document.createElement("span");
        capy.className = "capy idle";
        capy.setAttribute("aria-hidden", "true");
        capy.style.backgroundImage = `url("${ext.runtime.getURL("assets/capy-sprites.png")}")`;
        ring.append(capy);
        const label = document.createElement("span");
        label.className = "label";
        button.append(ring, label);
        if (found.variant === "pill") label.textContent = "Save";
        const toast = document.createElement("div");
        toast.className = "toast";
        toast.hidden = true;
        const toastText = document.createElement("span");
        toastText.className = "text";
        toast.append(toastText);
        root.append(style, button, toast);
        const record: Button = { url: found.url, button, capy, ring, label, toast, toastText, state: signedIn ? "idle" : "sleeping", hideToast: 0 };
        paint(record, record.state);
        button.addEventListener("mousedown", (e) => e.stopPropagation());
        button.addEventListener("click", (e) => {
            e.preventDefault();
            e.stopPropagation();
            void onClick(record);
        });
        relocateHost(host, found.mount, found.after, found.before);
        buttons.add(record);
    };

    const onClick = async (record: Button) => {
        if (record.state === "saving") return;
        if (!signedIn) {
            // Ask the background first: the popup may have signed in since this page loaded.
            const before = (await send({ type: "auth-state" })) as { signedIn?: boolean } | undefined;
            signedIn = before?.signedIn === true;
        }
        if (!signedIn) {
            // Visible while the approve tab is open, so a click never looks like nothing happened.
            paint(record, "saving");
            record.button.title = "Signing in to Capystore: approve it in the tab that opened";
            record.button.setAttribute("aria-label", record.button.title);
            const res = (await send({ type: "sign-in" })) as { ok?: boolean; message?: string } | undefined;
            const auth = (await send({ type: "auth-state" })) as { signedIn?: boolean } | undefined;
            signedIn = auth?.signedIn === true;
            if (!signedIn) {
                paint(record, "error");
                const why = res?.message ?? "Sign-in did not finish.";
                record.button.title = `${why} Click to try again.`;
                record.button.setAttribute("aria-label", record.button.title);
                return;
            }
        }
        paint(record, "saving");
        showFace(record, describeSave("saving", { ...EMPTY_PROGRESS, step: "fetching", waking: true }), null, null, null);
        const res = (await send({ type: "save", url: record.url, site })) as { state?: string; studioUrl?: string; message?: string } | undefined;
        if (res?.state === "signed-out") {
            signedIn = false;
            paint(record, "sleeping");
            return;
        }
        if (res?.state === "offline") {
            paint(record, "sleeping");
            return;
        }
        if (res?.state === "error") paint(record, "error");
    };

    const scanNow = async () => {
        const sites = (await send({ type: "get-sites" })) as Record<string, boolean> | undefined;
        enabled = !sites || sites[site] !== false;
        if (!enabled) {
            for (const b of buttons) b.button.getRootNode() instanceof ShadowRoot && (b.button.getRootNode() as ShadowRoot).host.remove();
            buttons.clear();
            return;
        }
        for (const b of buttons) {
            const root = b.button.getRootNode();
            if (root instanceof ShadowRoot && !root.host.isConnected) buttons.delete(b);
        }
        for (const found of scan(document, location.href)) {
            try {
                ensure(found);
            } catch {
                // A node the site detached between the scan and the insert.
            }
        }
    };

    let timer = 0;
    const schedule = () => {
        window.clearTimeout(timer);
        timer = window.setTimeout(() => void scanNow(), 150);
    };
    observer = new MutationObserver((records) => {
        if (records.every((r) => r.target instanceof Element && r.target.closest(`.${HOST}`))) return;
        schedule();
    });
    observer.observe(document.documentElement, { childList: true, subtree: true });
    document.addEventListener("yt-navigate-finish", schedule);
    window.addEventListener("popstate", schedule);
    // A content script's history.pushState wrapper does not see the page's own calls. Reels
    // change the URL with the up/down arrows and often keep the same rail, so watch the href.
    let href = location.href;
    hrefTimer = window.setInterval(() => {
        if (retired || location.href === href) return;
        href = location.href;
        schedule();
    }, 250);

    const copyText = async (text: string) => {
        try {
            await navigator.clipboard.writeText(text);
        } catch {
            const area = document.createElement("textarea");
            area.value = text;
            document.documentElement.append(area);
            area.select();
            document.execCommand("copy");
            area.remove();
        }
    };

    const showFace = (b: Button, face: SaveFace, studioUrl: string | null, shareUrl: string | null, code: string | null) => {
        b.label.textContent = face.label;
        b.button.setAttribute("aria-label", face.toast);
        b.button.title = face.toast;
        b.ring.classList.toggle("spin", face.ring === "spin");
        b.ring.classList.toggle("on", typeof face.ring === "number");
        b.ring.style.setProperty("--p", typeof face.ring === "number" ? String(Math.round(face.ring * 100)) : "0");
        b.toastText.textContent = face.toast;
        b.toast.querySelectorAll("button, .code").forEach((n) => n.remove());
        const add = (text: string, run: () => void) => {
            const btn = document.createElement("button");
            btn.type = "button";
            btn.textContent = text;
            btn.addEventListener("click", (e) => {
                e.preventDefault();
                e.stopPropagation();
                run();
            });
            b.toast.append(btn);
        };
        if (face.open && studioUrl) add("Open", () => void send({ type: "open", url: studioUrl }));
        if (face.copy) add("Copy link", () => void copyText(shareUrl || studioUrl || b.url));
        if (face.retry) add("Retry", () => void onClick(b));
        if (face.details && code) {
            add("Details", () => {
                let codeEl = b.toast.querySelector(".code");
                if (codeEl) {
                    codeEl.remove();
                    return;
                }
                codeEl = document.createElement("span");
                codeEl.className = "code";
                codeEl.textContent = code;
                b.toast.append(codeEl);
            });
        }
        b.toast.hidden = false;
        window.clearTimeout(b.hideToast);
        b.hideToast = window.setTimeout(() => {
            b.toast.hidden = true;
        }, 4000);
    };

    const applyUpdate = (b: Button, state: string, progress: SaveProgress | null, studioUrl: string | null, shareUrl: string | null) => {
        if (state === "sleeping" || state === "idle" || state === "signed-out") {
            paint(b, state === "idle" ? "idle" : "sleeping");
            b.label.textContent = "";
            b.ring.className = "ring";
            return;
        }
        if (state === "saving" || state === "saved" || state === "error") {
            paint(b, state === "saving" ? "saving" : state);
            const face = describeSave(state, progress ?? EMPTY_PROGRESS);
            showFace(b, face, studioUrl, shareUrl, progress?.code ?? null);
        }
    };

    ext.runtime.onMessage.addListener((message) => {
        const msg = message as { type?: string; url?: string; state?: string; progress?: SaveProgress | null; studioUrl?: string | null; shareUrl?: string | null };
        if (msg?.type !== "save-update" || !msg.url || !msg.state) return;
        for (const b of buttons) if (b.url === msg.url) applyUpdate(b, msg.state, msg.progress ?? null, msg.studioUrl ?? null, msg.shareUrl ?? null);
    });
    ext.storage.onChanged.addListener((changes, area) => {
        if (area !== "local") return;
        if ("session" in changes) {
            // Signed in or out from the popup (or another tab): wake or put every button to sleep.
            signedIn = changes.session?.newValue != null;
            for (const b of buttons) {
                if (signedIn && b.state === "sleeping") paint(b, "idle");
                else if (!signedIn && b.state === "idle") paint(b, "sleeping");
            }
        }
        schedule();
    });

    void (async () => {
        const auth = (await send({ type: "auth-state" })) as { signedIn?: boolean } | undefined;
        signedIn = auth?.signedIn === true;
        for (const b of buttons) if (!signedIn && b.state === "idle") paint(b, "sleeping");
        await scanNow();
    })();

    tick = window.setInterval(() => {
        for (const b of buttons) {
            if (b.state !== "saving" && b.state !== "sleeping") continue;
            void send({ type: "status", url: b.url }).then((res) => {
                const body = res as { state?: string; signedIn?: boolean; progress?: SaveProgress | null; studioUrl?: string | null; shareUrl?: string | null } | undefined;
                if (typeof body?.signedIn === "boolean") signedIn = body.signedIn;
                if (body?.state === "signed-out") signedIn = false;
                const state = body?.state === "offline" || body?.state === "signed-out" ? "sleeping" : body?.state;
                if (state === "saving" || state === "saved" || state === "error") applyUpdate(b, state, body?.progress ?? null, body?.studioUrl ?? null, body?.shareUrl ?? null);
                else if (state === "idle" || state === "sleeping") applyUpdate(b, state, null, null, null);
            });
        }
    }, 2000);
}
