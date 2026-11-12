import { getExt } from "./lib/browser";
import { LIBRARY_URL } from "./lib/save";
import { popupView, spriteCss, type RecentSave, type SpriteState } from "./lib/view";

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
    signIn.classList.add("primary");

    const draw = (input: { signedIn: boolean; offline: boolean; device: string | null; saving: boolean; recent: RecentSave[] }) => {
        const view = popupView(input);
        capy.className = `capy ${view.sprite}`;
        heading.textContent = view.heading;
        detail.textContent = view.detail;
        signIn.hidden = !view.showSignIn;
        signOut.hidden = !view.showSignOut;
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
        };
        draw({
            signedIn: bag?.signedIn === true,
            offline: bag?.offline === true,
            device: bag?.device ?? null,
            saving: bag?.saving === true,
            recent: Array.isArray(bag?.recent) ? bag.recent : [],
        });
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
