// Find every post in a document and the element the button should sit on.
// Selectors are the stable ones (test ids, aria labels, URL shapes) with a walk into open shadow roots,
// because YouTube keeps anchors inside them. Closed shadow roots are skipped; the host element is the fallback.

import { canonicalInstagram, canonicalTwitch, canonicalX, canonicalYouTube } from "./urls";

export type Variant = "icon" | "pill";

export type FoundPost = {
    url: string;
    mount: Element;
    variant: Variant;
};

export type Scan = (doc: ParentNode, pageUrl: string) => FoundPost[];

function shadowOf(node: ParentNode): ParentNode | null {
    const shadow = (node as Element & { shadowRoot?: ParentNode | null }).shadowRoot;
    return shadow && shadow !== node ? shadow : null;
}

export function deepQuery(root: ParentNode, selector: string): Element | null {
    const direct = root.querySelector?.(selector);
    if (direct) return direct;
    // The node we were handed may itself be the shadow host (a YouTube card).
    const own = shadowOf(root);
    if (own) {
        const found = deepQuery(own, selector);
        if (found) return found;
    }
    for (const el of root.querySelectorAll?.("*") ?? []) {
        const shadow = shadowOf(el);
        if (!shadow) continue;
        const found = deepQuery(shadow, selector);
        if (found) return found;
    }
    return null;
}

export function deepAll(root: ParentNode, selector: string): Element[] {
    const out: Element[] = [];
    const walk = (node: ParentNode) => {
        if (node.querySelectorAll) out.push(...node.querySelectorAll(selector));
        const own = shadowOf(node);
        if (own) walk(own);
        for (const el of node.querySelectorAll?.("*") ?? []) {
            const shadow = shadowOf(el);
            if (shadow) walk(shadow);
        }
    };
    walk(root);
    return out;
}

export function scanX(doc: ParentNode, pageUrl: string): FoundPost[] {
    const marked = [...(doc.querySelectorAll?.('article[data-testid="tweet"]') ?? [])];
    const articles = marked.length ? marked : [...(doc.querySelectorAll?.("article") ?? [])];
    const out: FoundPost[] = [];
    for (const article of articles) {
        const url = xUrl(article, pageUrl);
        if (!url) continue;
        const mount = article.querySelector('[role="group"]') ?? article;
        out.push({ url, mount, variant: "icon" });
    }
    return out;
}

function xUrl(article: Element, pageUrl: string): string | null {
    const time = article.querySelector("time");
    const fromTime = time?.closest("a")?.getAttribute("href");
    const href = (fromTime && fromTime.includes("/status/") ? fromTime : null) ?? article.querySelector('a[href*="/status/"]')?.getAttribute("href");
    return href ? canonicalX(href, pageUrl) : null;
}

const YT_CARDS = [
    "ytd-rich-item-renderer",
    "ytd-video-renderer",
    "ytd-grid-video-renderer",
    "ytd-compact-video-renderer",
    "ytd-reel-item-renderer",
    "ytd-playlist-video-renderer",
    "yt-lockup-view-model",
].join(", ");

// A lockup card has no #metadata. These are the title row YouTube actually renders there.
const YT_META = [
    "#metadata",
    "#meta",
    "h3",
    "yt-lockup-metadata-view-model",
    ".yt-lockup-metadata-view-model",
    ".ytLockupViewModelMeta",
    ".yt-lockup-metadata-view-model-wiz__title",
    "a.yt-lockup-metadata-view-model-wiz__title",
].join(", ");

export function scanYouTube(doc: ParentNode, pageUrl: string): FoundPost[] {
    const out: FoundPost[] = [];
    for (const card of doc.querySelectorAll?.(YT_CARDS) ?? []) {
        const href = deepQuery(card, 'a[href*="/watch"], a[href*="/shorts/"], a[href*="youtu.be"]')?.getAttribute("href");
        const url = href ? canonicalYouTube(href, pageUrl) : null;
        if (!url) continue;
        const meta = deepQuery(card, YT_META);
        const lockup = card.tagName.toLowerCase() === "yt-lockup-view-model";
        // A lockup with no title row would put the button on the whole card, in the gap between results.
        if (lockup && !meta) continue;
        const link = deepQuery(card, 'a[href*="/watch"], a[href*="/shorts/"], a[href*="youtu.be"]');
        const mount = meta ?? link;
        if (!mount || mount === card) continue;
        out.push({ url, mount, variant: "icon" });
    }
    let page: URL | null = null;
    try {
        page = new URL(pageUrl);
    } catch {
        page = null;
    }
    const canonical = canonicalYouTube(pageUrl, pageUrl);
    if (page && canonical && (page.pathname === "/watch" || page.pathname.startsWith("/shorts/"))) {
        const mount =
            deepQuery(doc, "#top-level-buttons-computed") ??
            deepQuery(doc, "ytd-reel-player-overlay-renderer") ??
            deepQuery(doc, "#actions");
        if (mount) out.push({ url: canonical, mount, variant: page.pathname.startsWith("/shorts/") ? "icon" : "pill" });
    }
    return out;
}

const TWITCH_SHARE = "[data-a-target='share-button'], [data-a-target='clip-share-button'], button[aria-label='Share']";

function isPreviewLink(a: Element): boolean {
    return a.getAttribute("data-a-target") === "preview-card-image-link" || a.closest("[data-a-target='preview-card-image-link']") === a;
}

export function scanTwitch(doc: ParentNode, pageUrl: string): FoundPost[] {
    const out: FoundPost[] = [];
    const chosen = new Map<string, Element>();
    for (const a of deepAll(doc, 'a[href*="/clip/"]')) {
        const url = canonicalTwitch(a.getAttribute("href") ?? "", pageUrl);
        if (!url) continue;
        const prev = chosen.get(url);
        // The preview image is a big link. A later title link for the same clip is the compact one.
        if (!prev || (isPreviewLink(prev) && !isPreviewLink(a))) chosen.set(url, a);
    }
    for (const [url, a] of chosen) out.push({ url, mount: a, variant: "icon" });
    const page = canonicalTwitch(pageUrl, pageUrl);
    if (page && !chosen.has(page)) {
        // Wait for Share. Mounting on <main> before it exists leaves a full-width bar above the signup banner.
        const share = deepQuery(doc, TWITCH_SHARE);
        const mount = share?.parentElement;
        if (share && mount) out.push({ url: page, mount, variant: "pill" });
    }
    return out;
}

// Move a button that landed on a weak mount (the page, a card) once a tighter anchor exists.
export function relocateHost(host: HTMLElement, mount: Element): boolean {
    if (host.parentElement === mount) return false;
    mount.appendChild(host);
    return true;
}

const IG_LINK = 'a[href*="/p/"], a[href*="/reel"], a[href*="/tv/"]';
const IG_LIKE = 'svg[aria-label="Like"], svg[aria-label="Unlike"], svg[aria-label="Comment"]';

export function scanInstagram(doc: ParentNode, pageUrl: string): FoundPost[] {
    const out: FoundPost[] = [];
    const seen = new Set<string>();
    for (const article of doc.querySelectorAll?.("article") ?? []) {
        const link = deepQuery(article, IG_LINK);
        const like = deepQuery(article, IG_LIKE);
        const url = (link ? canonicalInstagram(link.getAttribute("href") ?? "", pageUrl) : null) ?? (like ? canonicalInstagram(pageUrl, pageUrl) : null);
        if (!url || seen.has(url)) continue;
        const mount = like?.parentElement ?? link;
        if (!mount) continue;
        seen.add(url);
        out.push({ url, mount, variant: "icon" });
    }
    const page = canonicalInstagram(pageUrl, pageUrl);
    if (page && !seen.has(page)) {
        // A removed post still has a permalink and a <main>. Only a like control or a post link is a real anchor.
        const like = deepQuery(doc, IG_LIKE);
        const link = deepQuery(doc, IG_LINK);
        const mount = like?.parentElement ?? link;
        const url = (link ? canonicalInstagram(link.getAttribute("href") ?? "", pageUrl) : null) ?? (like ? page : null);
        if (url && mount) out.push({ url, mount, variant: "icon" });
    }
    return out;
}
