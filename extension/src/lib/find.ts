// Find every post in a document and the element the button should sit on.
// Selectors are the stable ones (test ids, aria labels, URL shapes) with a walk into open shadow roots,
// because YouTube keeps anchors inside them. Closed shadow roots are skipped; the host element is the fallback.

import { canonicalInstagram, canonicalTwitch, canonicalX, canonicalYouTube } from "./urls";

export type Variant = "icon" | "pill";

export type FoundPost = {
    url: string;
    mount: Element;
    variant: Variant;
    // When set, the host is inserted immediately after this child of `mount` (the Share chip, not the end of the row).
    after?: Element;
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

// A lockup card has no #metadata. Search results use the wiz metadata row, or just the title link's parent.
const YT_META = [
    "#metadata",
    "#meta",
    "h3",
    "yt-lockup-metadata-view-model",
    ".yt-lockup-metadata-view-model",
    ".yt-lockup-metadata-view-model-wiz",
    ".ytLockupViewModelMeta",
    ".yt-lockup-metadata-view-model-wiz__title",
    "a.yt-lockup-metadata-view-model-wiz__title",
].join(", ");
const YT_LINK = 'a[href*="/watch"], a[href*="/shorts/"], a[href*="youtu.be"]';

function isThumbLink(a: Element): boolean {
    const cls = `${a.id} ${a.getAttribute("class") ?? ""}`.toLowerCase();
    if (/thumb|image|contentimage/.test(cls)) return true;
    return !!a.querySelector("img, yt-image, yt-thumbnail-view-model");
}

const AD_CTA = "ad-button-view-model, .ytAdButtonViewModelHost";

function insideAdCta(el: Element): boolean {
    return !!el.closest(AD_CTA);
}

function containsAdCta(el: Element): boolean {
    return !!el.querySelector(AD_CTA);
}

// The title row of a lockup. Ad Watch/Download buttons also link to the video; they are not the title.
function lockupRow(card: Element): Element | null {
    const meta = deepAll(card, YT_META).find((el) => el !== card && !insideAdCta(el) && !containsAdCta(el));
    if (meta) return meta;
    const title = deepAll(card, YT_LINK).find((a) => !isThumbLink(a) && !insideAdCta(a));
    const parent = title?.parentElement;
    if (!title || !parent || parent === card) return null;
    // The metadata block also holds Watch/Download. The title link is the row; the CTA container is not.
    if (!insideAdCta(parent) && !containsAdCta(parent)) return parent;
    return title;
}

export function scanYouTube(doc: ParentNode, pageUrl: string): FoundPost[] {
    const out: FoundPost[] = [];
    for (const card of doc.querySelectorAll?.(YT_CARDS) ?? []) {
        const href = deepQuery(card, YT_LINK)?.getAttribute("href");
        const url = href ? canonicalYouTube(href, pageUrl) : null;
        // An ad or sponsored card with no /watch or /shorts link is not a post.
        if (!url) continue;
        const lockup = card.tagName.toLowerCase() === "yt-lockup-view-model";
        const mount = lockup ? lockupRow(card) : (deepQuery(card, YT_META) ?? deepQuery(card, YT_LINK));
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

// Live Share is <button aria-label="Share Clip: …"> with no data-a-target. The top nav also has Share buttons.
const TWITCH_CHROME = "nav, header, [role='navigation'], [data-a-target='top-nav-container'], [data-a-target='navigation-bar']";

function isTwitchShare(el: Element): boolean {
    const target = el.getAttribute("data-a-target");
    if (target === "share-button" || target === "clip-share-button") return true;
    if (el.tagName !== "BUTTON") return false;
    return /^share\b/i.test((el.getAttribute("aria-label") ?? "").trim());
}

// A one-button wrapper is the Share chip. Its parent, when that parent holds the other actions, is the row.
function shareRow(share: Element): { mount: Element; after?: Element } | null {
    const chip = share.parentElement;
    if (!chip) return null;
    const row = chip.parentElement;
    const pageLevel = !row || row.tagName === "MAIN" || row.tagName === "BODY" || row.tagName === "HTML";
    const chipButtons = chip.querySelectorAll("button").length;
    const rowButtons = row?.querySelectorAll("button").length ?? 0;
    if (!pageLevel && chipButtons <= 1 && rowButtons > chipButtons) return { mount: row, after: chip };
    return { mount: chip };
}

function clipShareButton(doc: ParentNode): Element | null {
    for (const el of deepAll(doc, "button, [data-a-target='share-button'], [data-a-target='clip-share-button']")) {
        if (!isTwitchShare(el)) continue;
        if (el.closest(TWITCH_CHROME)) continue;
        return el;
    }
    return null;
}

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
        // The Share control sits in its own chip. The pill is a sibling of that chip, on the Edit/Share/like row.
        const share = clipShareButton(doc);
        const placed = share ? shareRow(share) : null;
        if (placed) out.push({ url: page, mount: placed.mount, variant: "pill", ...(placed.after ? { after: placed.after } : {}) });
    }
    return out;
}

// Move a button that landed on a weak mount (the page, a card) once a tighter anchor exists.
export function relocateHost(host: HTMLElement, mount: Element, after?: Element | null): boolean {
    if (after && after.parentElement === mount) {
        if (host.parentElement === mount && host.previousElementSibling === after) return false;
        mount.insertBefore(host, after.nextSibling);
        return true;
    }
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
