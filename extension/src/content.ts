// Injects one Save button per post. Re-scans on DOM changes so a feed that scrolls in more posts,
// and a site that redraws itself without a navigation, both get buttons. A button that was mounted
// before its real anchor existed is moved there on the next scan.

import { getExt, type Ext } from "./lib/browser";
import { deepAll, relocateHost, type FoundPost, type Scan } from "./lib/find";
import { spriteCss, type SiteId, type SpriteState } from "./lib/view";

const HOST = "capystore-save";
const CSS = `
:host { all: initial; }
button {
  display: inline-flex; align-items: center; justify-content: center; gap: 4px;
  margin: 0; padding: 0; border: 0; background: transparent; color: inherit;
  font: 13px/1 -apple-system, system-ui, sans-serif; cursor: pointer; border-radius: 999px;
}
button.icon { width: 36px; height: 36px; }
button.pill { height: 36px; padding: 0 10px 0 4px; }
button:hover, button:focus-visible { background: color-mix(in srgb, currentColor 12%, transparent); outline: none; }
${spriteCss()}
`;

const LABEL: Record<SpriteState, string> = {
    idle: "Save to Capystore",
    saving: "Saving to Capystore",
    saved: "Saved to Capystore",
    error: "Couldn't save to Capystore",
    sleeping: "Sign in to Capystore",
};

type Button = { url: string; button: HTMLButtonElement; capy: HTMLElement; state: SpriteState };

export function start(site: SiteId, scan: Scan): void {
    const ext = getExt();
    if (!ext || (globalThis as { __capystoreStarted?: Set<string> }).__capystoreStarted?.has(site)) return;
    const flag = ((globalThis as { __capystoreStarted?: Set<string> }).__capystoreStarted ??= new Set());
    flag.add(site);
    const buttons = new Set<Button>();
    let enabled = true;
    let signedIn = true;

    const sheet = document.createElement("style");
    // Shrink to the button. A flex or grid parent (a card, <main>, a results row) would otherwise stretch this into a full-width bar.
    sheet.textContent = `.${HOST}{display:inline-flex;align-items:center;vertical-align:middle;width:max-content;max-width:max-content;flex:0 0 auto;align-self:center;box-sizing:border-box;}`;
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

    const ensure = (found: FoundPost) => {
        const prev = findHost(found.url);
        if (prev) {
            relocateHost(prev, found.mount, found.after);
            return;
        }
        const host = document.createElement("span");
        host.className = HOST;
        host.dataset.url = found.url;
        const root = host.attachShadow({ mode: "open" });
        const style = document.createElement("style");
        style.textContent = CSS;
        const button = document.createElement("button");
        button.type = "button";
        button.className = found.variant;
        const capy = document.createElement("span");
        capy.className = "capy idle";
        capy.setAttribute("aria-hidden", "true");
        capy.style.backgroundImage = `url("${ext.runtime.getURL("assets/capy-sprites.png")}")`;
        button.append(capy);
        if (found.variant === "pill") {
            const label = document.createElement("span");
            label.textContent = "Save";
            button.append(label);
        }
        root.append(style, button);
        const record: Button = { url: found.url, button, capy, state: signedIn ? "idle" : "sleeping" };
        paint(record, record.state);
        const stop = (e: Event) => {
            e.preventDefault();
            e.stopPropagation();
        };
        button.addEventListener("mousedown", stop);
        button.addEventListener("click", (e) => {
            stop(e);
            void onClick(record);
        });
        relocateHost(host, found.mount, found.after);
        buttons.add(record);
    };

    const onClick = async (record: Button) => {
        if (record.state === "saving") return;
        if (!signedIn) {
            paint(record, "sleeping");
            await ext.runtime.sendMessage({ type: "sign-in" });
            const auth = (await ext.runtime.sendMessage({ type: "auth-state" })) as { signedIn?: boolean } | undefined;
            signedIn = auth?.signedIn === true;
            if (!signedIn) return;
        }
        paint(record, "saving");
        const res = (await ext.runtime.sendMessage({ type: "save", url: record.url, site })) as { state?: string } | undefined;
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
        const sites = (await ext.runtime.sendMessage({ type: "get-sites" })) as Record<string, boolean> | undefined;
        enabled = !sites || sites[site] !== false;
        if (!enabled) {
            for (const b of buttons) b.button.getRootNode() instanceof ShadowRoot && (b.button.getRootNode() as ShadowRoot).host.remove();
            buttons.clear();
            return;
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
    new MutationObserver((records) => {
        if (records.every((r) => r.target instanceof Element && r.target.closest(`.${HOST}`))) return;
        schedule();
    }).observe(document.documentElement, { childList: true, subtree: true });
    document.addEventListener("yt-navigate-finish", schedule);
    window.addEventListener("popstate", schedule);

    ext.runtime.onMessage.addListener((message) => {
        const msg = message as { type?: string; url?: string; state?: SpriteState };
        if (msg?.type !== "save-update" || !msg.url || !msg.state) return;
        for (const b of buttons) if (b.url === msg.url) paint(b, msg.state);
    });
    ext.storage.onChanged.addListener((_changes, area) => {
        if (area === "local") schedule();
    });

    void (async () => {
        const auth = (await ext.runtime.sendMessage({ type: "auth-state" })) as { signedIn?: boolean } | undefined;
        signedIn = auth?.signedIn === true;
        for (const b of buttons) if (!signedIn && b.state === "idle") paint(b, "sleeping");
        await scanNow();
    })();

    window.setInterval(() => {
        for (const b of buttons) {
            if (b.state !== "saving" && b.state !== "sleeping") continue;
            void ext.runtime.sendMessage({ type: "status", url: b.url }).then((res) => {
                const raw = (res as { state?: string } | undefined)?.state;
                if (raw === "signed-out") signedIn = false;
                const state = raw === "offline" || raw === "signed-out" ? "sleeping" : raw;
                if (state === "idle" || state === "saving" || state === "saved" || state === "error" || state === "sleeping") paint(b, state);
            });
        }
    }, 2000);
}
