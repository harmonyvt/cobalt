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

export function scanYouTube(doc: ParentNode, pageUrl: string): FoundPost[] {
    const out: FoundPost[] = [];
    for (const card of doc.querySelectorAll?.(YT_CARDS) ?? []) {
        const href = deepQuery(card, 'a[href*="/watch"], a[href*="/shorts/"], a[href*="youtu.be"]')?.getAttribute("href");
        const url = href ? canonicalYouTube(href, pageUrl) : null;
        if (!url) continue;
        const mount = deepQuery(card, "#metadata, #meta, h3") ?? card;
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

export function scanTwitch(doc: ParentNode, pageUrl: string): FoundPost[] {
    const out: FoundPost[] = [];
    const seen = new Set<string>();
    for (const a of deepAll(doc, 'a[href*="/clip/"]')) {
        const url = canonicalTwitch(a.getAttribute("href") ?? "", pageUrl);
        if (!url || seen.has(url)) continue;
        seen.add(url);
        const mount = a.closest("[data-a-target='preview-card-image-link'], article") ?? a.parentElement ?? a;
        out.push({ url, mount, variant: "icon" });
    }
    const page = canonicalTwitch(pageUrl, pageUrl);
    if (page && !seen.has(page)) {
        const share = deepQuery(doc, "[data-a-target='share-button']");
        const mount = share?.parentElement ?? deepQuery(doc, "[data-a-target='player-clip-title'], main");
        if (mount) out.push({ url: page, mount, variant: "pill" });
    }
    return out;
}

export function scanInstagram(doc: ParentNode, pageUrl: string): FoundPost[] {
    const out: FoundPost[] = [];
    const seen = new Set<string>();
    for (const article of doc.querySelectorAll?.("article") ?? []) {
        const href = deepQuery(article, 'a[href*="/p/"], a[href*="/reel"], a[href*="/tv/"]')?.getAttribute("href");
        const url = (href ? canonicalInstagram(href, pageUrl) : null) ?? canonicalInstagram(pageUrl, pageUrl);
        if (!url || seen.has(url)) continue;
        seen.add(url);
        const like = deepQuery(article, 'svg[aria-label="Like"], svg[aria-label="Unlike"], svg[aria-label="Comment"]');
        const mount = like?.parentElement ?? deepQuery(article, "section") ?? article;
        out.push({ url, mount, variant: "icon" });
    }
    const page = canonicalInstagram(pageUrl, pageUrl);
    if (page && !seen.has(page)) {
        const like = deepQuery(doc, 'svg[aria-label="Like"], svg[aria-label="Unlike"]');
        const mount = like?.parentElement ?? deepQuery(doc, "section, main");
        if (mount) out.push({ url: page, mount, variant: "icon" });
    }
    return out;
}
