import { getExt } from "./lib/browser";
import { LIBRARY_URL } from "./lib/save";
import { currentCard, popupView, spriteCss, type RecentSave, type SpriteState } from "./lib/view";

const ext = getExt();
if (ext) void init(ext);

async function init(api: NonNullable<ReturnType<typeof getExt>>) {
    const style = document.createElement("style");
    style.textContent = spriteCss(48, 34);
    document.head.appendChild(style);
    const capy = document.querySelector<HTMLElement>("#capy")!;
    capy.style.backgroundImage = `url("${api.runtime.getURL("assets/capy-sprites.png")}")`;
    const heading = document.querySelector("#heading")!;
    const detail = document.querySelector("#detail")!;
    const signIn = document.querySelector<HTMLButtonElement>("#sign-in")!;
    const signOut = document.querySelector<HTMLButtonElement>("#sign-out")!;
    const recent = document.querySelector("#recent")!;
    const card = document.querySelector<HTMLElement>("#card")!;
    const cardHeadline = document.querySelector("#card-headline")!;
    const cardFill = document.querySelector<HTMLElement>("#card-fill")!;
    const cardLabel = document.querySelector("#card-label")!;
    const cardOpen = document.querySelector<HTMLButtonElement>("#card-open")!;
    const cardCopy = document.querySelector<HTMLButtonElement>("#card-copy")!;
    const cardRetry = document.querySelector<HTMLButtonElement>("#card-retry")!;
    const cardDetails = document.querySelector<HTMLButtonElement>("#card-details")!;
    const cardCode = document.querySelector<HTMLElement>("#card-code")!;
    const phone = document.querySelector<HTMLInputElement>("#phone")!;
    signIn.classList.add("primary");

    const draw = (input: { signedIn: boolean; offline: boolean; device: string | null; saving: boolean; recent: RecentSave[] }) => {
        const view = popupView(input);
        capy.className = `capy ${view.sprite}`;
        heading.textContent = view.heading;
        detail.textContent = view.detail;
        signIn.hidden = !view.showSignIn;
        signOut.hidden = !view.showSignOut;
        const current = currentCard(input.recent);
        card.hidden = !current;
        if (current) {
            cardHeadline.textContent = current.headline;
            cardLabel.textContent = current.label;
            const working = current.fraction === null && !current.retry && !current.open;
            const bar = cardFill.parentElement as HTMLElement;
            bar.hidden = current.retry;
            bar.classList.toggle("indeterminate", working);
            card.dataset.tone = current.retry ? "error" : current.open ? "saved" : "saving";
            cardFill.style.width = current.fraction === null ? "" : `${Math.round(current.fraction * 100)}%`;
            cardOpen.hidden = !current.open;
            cardCopy.hidden = !current.copy;
            cardRetry.hidden = !current.retry;
            cardDetails.hidden = !current.details;
            cardCode.hidden = true;
            cardCode.textContent = current.code ?? "";
            cardOpen.onclick = () => void api.runtime.sendMessage({ type: "open", url: current.studioUrl || "library" });
            cardCopy.onclick = () => void navigator.clipboard?.writeText(current.shareUrl || current.studioUrl || current.url);
            cardRetry.onclick = () => void api.runtime.sendMessage({ type: "save", url: current.url });
            cardDetails.onclick = () => {
                cardCode.hidden = !cardCode.hidden;
            };
        }
        recent.replaceChildren();
        if (input.recent.length === 0) {
            const li = document.createElement("li");
            li.className = "empty";
            li.textContent = "Nothing saved from this browser yet.";
            recent.append(li);
            return;
        }
        for (const row of input.recent.slice(0, 8)) {
            const li = document.createElement("li");
            const a = document.createElement("a");
            a.href = row.studioUrl || LIBRARY_URL;
            a.textContent = shortUrl(row.url);
            a.addEventListener("click", (e) => {
                e.preventDefault();
                void api.runtime.sendMessage({ type: "open", url: row.studioUrl || "library" });
            });
            const status = document.createElement("span");
            status.className = "status";
            status.dataset.state = row.status;
            status.textContent = row.status === "error" ? "failed" : row.status;
            li.append(a, status);
            recent.append(li);
        }
    };

    const refresh = async () => {
        const bag = (await api.runtime.sendMessage({ type: "recent" })) as {
            signedIn?: boolean;
            offline?: boolean;
            device?: string | null;
            saving?: boolean;
            recent?: RecentSave[];
            pairing?: string | null;
            phone?: boolean;
        };
        draw({
            signedIn: bag?.signedIn === true,
            offline: bag?.offline === true,
            device: bag?.device ?? null,
            saving: bag?.saving === true,
            recent: Array.isArray(bag?.recent) ? bag.recent : [],
        });
        phone.checked = bag?.phone !== false;
        if (typeof bag?.pairing === "string") {
            heading.textContent = "Waiting for approval";
            detail.textContent = `Approve only if the Capystore page shows ${bag.pairing}.`;
            capy.className = "capy saving";
            signIn.hidden = true;
            setTimeout(() => void refresh(), 2000);
        }
    };

    signIn.addEventListener("click", () => {
        heading.textContent = "Waiting for approval";
        capy.className = "capy saving";
        void api.runtime.sendMessage({ type: "sign-in" }).then(() => refresh());
    });
    signOut.addEventListener("click", () => {
        void api.runtime.sendMessage({ type: "sign-out" }).then(() => refresh());
    });
    document.querySelector("#library")!.addEventListener("click", () => {
        void api.runtime.sendMessage({ type: "open", url: "library" });
    });
    phone.addEventListener("change", () => {
        void api.runtime.sendMessage({ type: "set-phone", on: phone.checked });
    });
    document.querySelector("#options")!.addEventListener("click", () => {
        if (api.runtime.openOptionsPage) void api.runtime.openOptionsPage();
        else location.href = api.runtime.getURL("options.html");
    });
    await refresh();
}

function shortUrl(url: string): string {
    try {
        const u = new URL(url);
        const path = u.pathname.length > 28 ? `${u.pathname.slice(0, 26)}…` : u.pathname;
        return `${u.hostname.replace(/^www\./, "")}${path}`;
    } catch {
        return url;
    }
}

export type { SpriteState };
