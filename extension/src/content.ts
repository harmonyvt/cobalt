// Injects one Save button per post. Re-scans on DOM changes so a feed that scrolls in more posts,
// and a site that redraws itself without a navigation, both get buttons. A button that was mounted
// before its real anchor existed is moved there on the next scan.
//
// The button is a shadow root. The host is also pinned inline, because X and Instagram style every
// span and button on the page and that styling was painting a disc around the capybara.

import { getExt, type Ext } from "./lib/browser";
import { deepAll, mountedHost, relocateHost, type FoundPost, type Scan } from "./lib/find";
import { describeSave, EMPTY_PROGRESS, type SaveFace, type SaveProgress } from "./lib/progress";
import { buttonCss, hostCss, pageTheme, shieldHost, type SurfaceKind } from "./lib/surface";
import { type SiteId, type SpriteState } from "./lib/view";

const HOST = "capystore-save";

const LABEL: Record<SpriteState, string> = {
    idle: "Save to Capystore",
    saving: "Saving to Capystore",
    saved: "Saved to Capystore",
    error: "Couldn't save to Capystore",
    sleeping: "Sign in to Capystore",
};

type Button = {
    url: string;
    root: HTMLElement;
    button: HTMLButtonElement;
    capy: HTMLElement;
    tip: HTMLElement;
    toast: HTMLElement;
    toastText: HTMLElement;
    toastBar: HTMLElement;
    toastFill: HTMLElement;
    markWork: SVGElement;
    markOk: SVGElement;
    markBad: SVGElement;
    actions: HTMLElement;
    state: SpriteState;
    hideToast: number;
    hovering: boolean;
    toastGen: number;
    arm: () => void;
    untrack: () => void;
};

function kindOf(found: FoundPost): SurfaceKind {
    if (found.fit === "rail") return "rail";
    return found.variant === "pill" ? "pill" : "icon";
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, className: string): HTMLElementTagNameMap[K] {
    const node = document.createElement(tag);
    node.className = className;
    return node;
}

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
            say(b, "Capystore was updated: reload this page");
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
    sheet.textContent = hostCss();
    document.documentElement.appendChild(sheet);

    const say = (b: Button, text: string) => {
        b.button.setAttribute("aria-label", text);
        b.tip.textContent = text;
    };

    const syncTheme = (b: Button) => {
        b.root.dataset.theme = pageTheme(document);
    };

    const paint = (b: Button, state: SpriteState) => {
        b.state = state;
        b.capy.className = `cs-glyph capy ${state}`;
        b.root.classList.toggle("busy", state === "saving");
        b.root.classList.toggle("saved", state === "saved");
        b.root.classList.toggle("error", state === "error");
        if (state !== "saving") b.root.classList.remove("spin");
        const label = state === "sleeping" && signedIn ? "Capystore is offline" : LABEL[state];
        say(b, label);
    };

    const findHost = (url: string): HTMLElement | null => {
        for (const node of deepAll(document, `.${HOST}`)) {
            if ((node as HTMLElement).dataset.url === url) return node as HTMLElement;
        }
        return null;
    };

    const stamp = (host: HTMLElement, found: FoundPost) => {
        host.className = found.fit ? `${HOST} ${found.fit}` : HOST;
        host.dataset.url = found.url;
        shieldHost(host, found.fit);
    };

    const ensure = (found: FoundPost) => {
        // Same rail, new reel: the page URL changed and the button is already in this mount.
        const prev = findHost(found.url) ?? mountedHost(found.mount, HOST);
        if (prev) {
            const previousUrl = prev.dataset.url ?? "";
            if (previousUrl && previousUrl !== found.url) {
                for (const b of buttons) if (b.url === previousUrl) b.url = found.url;
            }
            stamp(prev, found);
            relocateHost(prev, found.mount, found.after, found.before);
            const existing = [...buttons].find((b) => b.button.getRootNode() instanceof ShadowRoot && (b.button.getRootNode() as ShadowRoot).host === prev);
            if (existing) syncTheme(existing);
            return;
        }
        const kind = kindOf(found);
        const host = document.createElement("span");
        stamp(host, found);
        const root = host.attachShadow({ mode: "open" });
        const style = document.createElement("style");
        style.textContent = buttonCss(kind);
        const wrap = el("span", `cs-root ${kind}`);
        wrap.dataset.theme = pageTheme(document);
        const button = el("button", found.variant === "pill" ? "cs-btn pill" : "cs-btn");
        button.type = "button";
        const hit = el("span", "cs-hit");
        hit.innerHTML = `<svg class="cs-arc" viewBox="0 0 36 36" aria-hidden="true">
            <circle class="cs-track" cx="18" cy="18" r="15.5"></circle>
            <circle class="cs-value" cx="18" cy="18" r="15.5"></circle>
        </svg>
        <svg class="cs-check" viewBox="0 0 16 16" aria-hidden="true"><path d="M3.4 8.3 6.5 11.2 12.6 4.8"/></svg>`;
        const capy = el("span", "cs-glyph capy idle");
        capy.setAttribute("aria-hidden", "true");
        capy.style.backgroundImage = `url("${ext.runtime.getURL("assets/capy-sprites.png")}")`;
        hit.append(capy);
        button.append(hit);
        if (found.variant === "pill") {
            const word = el("span", "cs-word");
            word.textContent = "Save";
            button.append(word);
        }
        const tip = el("span", "cs-tip");
        tip.setAttribute("role", "tooltip");
        const toast = el("div", "cs-toast");
        toast.setAttribute("role", "status");
        toast.hidden = true;
        const markWork = document.createElementNS("http://www.w3.org/2000/svg", "svg");
        markWork.setAttribute("viewBox", "0 0 16 16");
        markWork.setAttribute("class", "cs-mark-work");
        markWork.innerHTML = `<circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-dasharray="11 27"/>`;
        const markOk = document.createElementNS("http://www.w3.org/2000/svg", "svg");
        markOk.setAttribute("viewBox", "0 0 16 16");
        markOk.setAttribute("class", "cs-mark-ok");
        markOk.innerHTML = `<circle cx="8" cy="8" r="8" fill="var(--cs-ok)"/><path d="M4.2 8.2 6.8 10.7 11.8 5.4" fill="none" stroke="#fff" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/>`;
        const markBad = document.createElementNS("http://www.w3.org/2000/svg", "svg");
        markBad.setAttribute("viewBox", "0 0 16 16");
        markBad.setAttribute("class", "cs-mark-bad");
        markBad.innerHTML = `<circle cx="8" cy="8" r="8" fill="var(--cs-bad)"/><path d="M8 4.1v4.6" stroke="#fff" stroke-width="1.7" stroke-linecap="round"/><circle cx="8" cy="11.5" r="0.9" fill="#fff"/>`;
        const markEl = el("span", "cs-mark");
        markEl.setAttribute("aria-hidden", "true");
        markEl.append(markWork, markOk, markBad);
        const toastText = el("span", "cs-line");
        const toastBar = el("span", "cs-bar");
        toastBar.setAttribute("role", "progressbar");
        toastBar.setAttribute("aria-valuemin", "0");
        toastBar.setAttribute("aria-valuemax", "100");
        const toastFill = document.createElement("i");
        toastBar.append(toastFill);
        toastBar.hidden = true;
        const actions = el("span", "cs-actions");
        toast.append(markEl, toastText, toastBar, actions);
        wrap.append(button, tip, toast);
        root.append(style, wrap);
        const record: Button = {
            url: found.url,
            root: wrap,
            button,
            capy,
            tip,
            toast,
            toastText,
            toastBar,
            toastFill,
            markWork,
            markOk,
            markBad,
            actions,
            state: signedIn ? "idle" : "sleeping",
            hideToast: 0,
            hovering: false,
            toastGen: 0,
            arm: () => {},
            untrack: () => {},
        };
        paint(record, record.state);
        const placeTip = () => {
            const box = button.getBoundingClientRect();
            const rail = kind === "rail";
            if (rail) {
                record.tip.style.left = `${Math.max(8, box.left - record.tip.offsetWidth - 8)}px`;
                record.tip.style.top = `${box.top + box.height / 2 - record.tip.offsetHeight / 2}px`;
            } else {
                const width = record.tip.offsetWidth;
                let left = box.left + box.width / 2 - width / 2;
                left = Math.min(Math.max(8, left), window.innerWidth - width - 8);
                record.tip.style.left = `${left}px`;
                record.tip.style.top = `${box.bottom + 6}px`;
            }
        };
        button.addEventListener("mouseenter", () => {
            if (record.root.classList.contains("toast-open")) return;
            record.root.classList.add("show-tip");
            placeTip();
        });
        button.addEventListener("mouseleave", () => record.root.classList.remove("show-tip"));
        button.addEventListener("focus", () => {
            if (record.root.classList.contains("toast-open")) return;
            record.root.classList.add("show-tip");
            placeTip();
        });
        button.addEventListener("blur", () => record.root.classList.remove("show-tip"));
        toast.addEventListener("mouseenter", () => {
            record.hovering = true;
            window.clearTimeout(record.hideToast);
        });
        toast.addEventListener("mouseleave", () => {
            record.hovering = false;
            record.arm();
        });
        toast.addEventListener("mousedown", (e) => e.stopPropagation());
        toast.addEventListener("click", (e) => e.stopPropagation());
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
            record.root.classList.add("spin");
            say(record, "Signing in to Capystore: approve it in the tab that opened");
            const res = (await send({ type: "sign-in" })) as { ok?: boolean; message?: string } | undefined;
            const auth = (await send({ type: "auth-state" })) as { signedIn?: boolean } | undefined;
            signedIn = auth?.signedIn === true;
            if (!signedIn) {
                paint(record, "error");
                say(record, `${res?.message ?? "Sign-in did not finish."} Click to try again.`);
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
            for (const b of buttons) {
                const node = b.button.getRootNode();
                if (node instanceof ShadowRoot) node.host.remove();
            }
            buttons.clear();
            return;
        }
        for (const b of buttons) {
            const node = b.button.getRootNode();
            if (node instanceof ShadowRoot && !node.host.isConnected) buttons.delete(b);
        }
        for (const found of scan(document, location.href)) {
            try {
                ensure(found);
            } catch {
                // A node the site detached between the scan and the insert.
            }
        }
        for (const b of buttons) syncTheme(b);
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
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener?.("change", () => {
        for (const b of buttons) syncTheme(b);
    });
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

    const dismiss = (b: Button) => {
        b.toast.classList.remove("cs-in");
        b.root.classList.remove("toast-open");
        const gen = b.toastGen;
        window.setTimeout(() => {
            if (gen === b.toastGen && !b.toast.classList.contains("cs-in")) b.toast.hidden = true;
        }, 200);
    };

    const placeToast = (b: Button) => {
        const box = b.button.getBoundingClientRect();
        const width = b.toast.offsetWidth;
        const height = b.toast.offsetHeight;
        const vw = window.innerWidth;
        const vh = window.innerHeight;
        const rail = b.root.classList.contains("rail");
        let left = box.left + box.width / 2 - width / 2;
        let top = box.bottom + 8;
        let place: "below" | "above" | "left" = "below";
        const overflowsRight = left + width > vw - 8;
        if (rail || overflowsRight) {
            place = "left";
            left = box.left - width - 10;
            top = box.top + box.height / 2 - height / 2;
        } else if (top + height > vh - 8) {
            place = "above";
            top = box.top - height - 8;
        }
        if (left < 8) left = 8;
        if (left + width > vw - 8) left = Math.max(8, vw - width - 8);
        if (top < 8) top = 8;
        if (top + height > vh - 8) top = Math.max(8, vh - height - 8);
        b.root.classList.toggle("place-left", place === "left");
        b.root.classList.toggle("place-above", place === "above");
        b.toast.style.left = `${Math.round(left)}px`;
        b.toast.style.top = `${Math.round(top)}px`;
    };

    const reveal = (b: Button) => {
        b.untrack();
        const gen = ++b.toastGen;
        b.toast.hidden = false;
        b.root.classList.add("toast-open");
        b.root.classList.remove("show-tip");
        placeToast(b);
        void b.toast.offsetWidth;
        b.toast.classList.add("cs-in");
        placeToast(b);
        const track = () => {
            if (gen !== b.toastGen || b.toast.hidden) return;
            placeToast(b);
        };
        window.addEventListener("scroll", track, true);
        window.addEventListener("resize", track);
        b.untrack = () => {
            window.removeEventListener("scroll", track, true);
            window.removeEventListener("resize", track);
        };
        b.arm = () => {
            window.clearTimeout(b.hideToast);
            if (b.hovering || gen !== b.toastGen) return;
            b.hideToast = window.setTimeout(() => {
                b.untrack();
                dismiss(b);
            }, 4000);
        };
        b.arm();
    };

    const showFace = (b: Button, face: SaveFace, studioUrl: string | null, shareUrl: string | null, code: string | null) => {
        say(b, face.toast);
        const saving = b.state === "saving";
        const determinate = typeof face.ring === "number";
        const wasSpin = b.root.classList.contains("spin");
        b.root.classList.toggle("busy", saving);
        b.root.classList.toggle("spin", face.ring === "spin");
        b.root.classList.toggle("saved", b.state === "saved");
        b.root.classList.toggle("error", b.state === "error");
        const pct = determinate ? String(Math.round((face.ring as number) * 100)) : b.state === "saved" ? "100" : "0";
        if (wasSpin && face.ring !== "spin") b.root.classList.add("no-ease");
        b.root.style.setProperty("--p", pct);
        if (wasSpin && face.ring !== "spin") {
            requestAnimationFrame(() => requestAnimationFrame(() => b.root.classList.remove("no-ease")));
        }
        const showIcon = (node: SVGElement, on: boolean) => (on ? node.removeAttribute("hidden") : node.setAttribute("hidden", ""));
        showIcon(b.markWork, b.state === "saving");
        showIcon(b.markOk, b.state === "saved");
        showIcon(b.markBad, b.state === "error");
        // The saved copy names the buttons. They are real controls, so the line stays the headline.
        b.toastText.textContent = face.open ? face.headline : face.toast;
        const working = saving && face.ring !== null;
        b.toastBar.hidden = !working;
        b.toastBar.classList.toggle("indet", face.ring === "spin");
        if (determinate) {
            const pct = Math.round((face.ring as number) * 100);
            b.toastFill.style.width = `${pct}%`;
            b.toastBar.setAttribute("aria-valuenow", String(pct));
            b.toastBar.removeAttribute("aria-valuetext");
        } else {
            b.toastFill.style.width = "";
            b.toastBar.removeAttribute("aria-valuenow");
            if (face.ring === "spin") b.toastBar.setAttribute("aria-valuetext", face.headline);
        }
        b.actions.replaceChildren();
        b.toast.querySelector(".cs-code")?.remove();
        b.toast.classList.remove("has-code");
        const add = (text: string, run: () => void) => {
            const btn = document.createElement("button");
            btn.type = "button";
            btn.textContent = text;
            btn.addEventListener("click", (e) => {
                e.preventDefault();
                e.stopPropagation();
                run();
            });
            b.actions.append(btn);
        };
        if (face.open && studioUrl) add("Open", () => void send({ type: "open", url: studioUrl }));
        if (face.copy) add("Copy link", () => void copyText(shareUrl || studioUrl || b.url));
        if (face.retry) add("Retry", () => void onClick(b));
        if (face.details && code) {
            add("Details", () => {
                let codeEl = b.toast.querySelector(".cs-code");
                if (codeEl) {
                    codeEl.remove();
                    b.toast.classList.remove("has-code");
                    placeToast(b);
                    return;
                }
                codeEl = document.createElement("span");
                codeEl.className = "cs-code";
                codeEl.textContent = code;
                b.toast.append(codeEl);
                b.toast.classList.add("has-code");
                placeToast(b);
            });
        }
        reveal(b);
    };

    const applyUpdate = (b: Button, state: string, progress: SaveProgress | null, studioUrl: string | null, shareUrl: string | null) => {
        if (state === "sleeping" || state === "idle" || state === "signed-out") {
            paint(b, state === "idle" ? "idle" : "sleeping");
            b.root.classList.remove("spin", "busy", "saved");
            b.root.style.setProperty("--p", "0");
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
