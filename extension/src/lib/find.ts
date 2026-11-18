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
    // When set, the host is inserted immediately before this child of `mount` (above Save on a reels rail).
    before?: Element;
    // `row` shares an X action bar. `rail` is one slot in Instagram's vertical reels rail.
    fit?: "row" | "rail";
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

// Reply, repost, like, bookmark. The first role=group in a post is often only the like control,
// a column under the heart, so mounting there puts the button on its own row.
const X_ACTION = '[data-testid="reply"], [data-testid="retweet"], [data-testid="unretweet"], [data-testid="like"], [data-testid="unlike"], [data-testid="bookmark"], [data-testid="removeBookmark"]';

function actionsIn(scope: Element, article: Element): Element[] {
    return [...scope.querySelectorAll(X_ACTION)].filter((el) => el.closest("article") === article);
}

function xMount(article: Element): Pick<FoundPost, "mount" | "after" | "fit"> {
    const actions = actionsIn(article, article);
    if (actions.length < 2) {
        const group = [...article.querySelectorAll('[role="group"]')].find((el) => el.closest("article") === article);
        return { mount: group ?? article };
    }
    let node: Element | null = actions[0]!.parentElement;
    let bar: Element | null = null;
    while (node && node !== article) {
        if (actionsIn(node, article).length >= 2) {
            bar = node;
            break;
        }
        node = node.parentElement;
    }
    if (!bar) return { mount: actions[0]!.parentElement ?? article };
    const cells = [...bar.children];
    const cellOf = (el: Element | null | undefined) => (el ? cells.find((c) => c === el || c.contains(el)) : undefined);
    const bookmark = [...bar.querySelectorAll('[data-testid="bookmark"], [data-testid="removeBookmark"]')].find((el) => el.closest("article") === article);
    const share = [...bar.querySelectorAll("button, [role='button'], a")].find((el) => {
        if (el.closest("article") !== article) return false;
        return el.getAttribute("data-testid") === "share" || /^share\b/i.test((el.getAttribute("aria-label") ?? "").trim());
    });
    const bookmarkCell = cellOf(bookmark);
    const shareCell = cellOf(share);
    const idx = Math.max(bookmarkCell ? cells.indexOf(bookmarkCell) : -1, shareCell ? cells.indexOf(shareCell) : -1);
    const after = idx >= 0 ? cells[idx] : undefined;
    return { mount: bar, fit: "row", ...(after ? { after } : {}) };
}

export function scanX(doc: ParentNode, pageUrl: string): FoundPost[] {
    const marked = [...(doc.querySelectorAll?.('article[data-testid="tweet"]') ?? [])];
    const articles = marked.length ? marked : [...(doc.querySelectorAll?.("article") ?? [])];
    const out: FoundPost[] = [];
    for (const article of articles) {
        const url = xUrl(article, pageUrl);
        if (!url) continue;
        const place = xMount(article);
        out.push({ url, variant: "icon", ...place });
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
        // A sponsored result carries Watch/Download in ad-button-view-model. It is an ad, not a post.
        if (lockup && containsAdCta(card)) continue;
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

// The live clip page wraps Share in extra Layout divs. The row is the nearest ancestor that also
// holds the other actions (Edit, Like, …): three or more buttons. The pill goes after that row's
// child which contains Share, so it sits beside the chip instead of inside it.
function shareRow(share: Element): { mount: Element; after?: Element } | null {
    let node: Element | null = share.parentElement;
    while (node && node.tagName !== "MAIN" && node.tagName !== "BODY" && node.tagName !== "HTML") {
        if (node.querySelectorAll("button").length >= 3) {
            const child = [...node.children].find((c) => c === share || c.contains(share));
            return { mount: node, ...(child ? { after: child } : {}) };
        }
        node = node.parentElement;
    }
    return share.parentElement ? { mount: share.parentElement } : null;
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
export function relocateHost(host: HTMLElement, mount: Element, after?: Element | null, before?: Element | null): boolean {
    if (before && before.parentElement === mount) {
        if (host.parentElement === mount && host.nextElementSibling === before) return false;
        mount.insertBefore(host, before);
        return true;
    }
    if (after && after.parentElement === mount) {
        if (host.parentElement === mount && host.previousElementSibling === after) return false;
        mount.insertBefore(host, after.nextSibling);
        return true;
    }
    if (host.parentElement === mount) return false;
    mount.appendChild(host);
    return true;
}

// A button already sitting in this row or rail. The caller retargets its URL when the reel changes.
export function mountedHost(mount: Element, hostClass: string): HTMLElement | null {
    for (const el of mount.children) {
        const host = el as HTMLElement;
        if (host.classList?.contains(hostClass)) return host;
    }
    return null;
}

const IG_LINK = 'a[href*="/p/"], a[href*="/reel"], a[href*="/tv/"]';
const IG_LIKE = 'svg[aria-label="Like"], svg[aria-label="Unlike"], svg[aria-label="Comment"]';

function igLabel(el: Element): string {
    const own = (el.getAttribute("aria-label") ?? "").trim();
    if (own) return own;
    return (el.querySelector("svg[aria-label]")?.getAttribute("aria-label") ?? "").trim();
}

function insideCapystore(el: Element): boolean {
    const root = el.getRootNode();
    if (typeof ShadowRoot !== "undefined" && root instanceof ShadowRoot && (root.host as HTMLElement).classList?.contains("capystore-save")) return true;
    return !!el.closest(".capystore-save");
}

// Reels put the words on the button. The svg is aria-hidden, so the like-svg scan never sees the rail.
function isIgAction(label: string): boolean {
    if (/capystore/i.test(label)) return false;
    return /^(like|unlike|comment|comments|repost|share|send|save|saved|remove|bookmark)\b/i.test(label);
}

function igControls(root: ParentNode): Element[] {
    const out: Element[] = [];
    for (const el of deepAll(root, "button, [role='button']")) {
        if (insideCapystore(el)) continue;
        if (!isIgAction(igLabel(el))) continue;
        out.push(el);
    }
    return out;
}

function instagramRails(doc: ParentNode): Element[] {
    const controls = igControls(doc);
    const rails: Element[] = [];
    const claimed = new Set<Element>();
    for (const seed of controls) {
        if (claimed.has(seed)) continue;
        let node: Element | null = seed.parentElement;
        let rail: Element | null = null;
        while (node && node.tagName !== "BODY" && node.tagName !== "HTML") {
            const n = controls.filter((c) => node!.contains(c) && !claimed.has(c)).length;
            if (n >= 3) {
                rail = node;
                break;
            }
            node = node.parentElement;
        }
        if (!rail) continue;
        for (const c of controls) if (rail.contains(c)) claimed.add(c);
        rails.push(rail);
    }
    return rails;
}

function directChild(rail: Element, el: Element): Element | undefined {
    return [...rail.children].find((c) => c === el || c.contains(el));
}

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
    for (const rail of instagramRails(doc)) {
        // A feed post already got its button from the article above. The rail is the reels viewer.
        if (rail.closest("article")) continue;
        const link = deepQuery(rail, IG_LINK);
        const fromLink = link ? canonicalInstagram(link.getAttribute("href") ?? "", pageUrl) : null;
        const url = fromLink ?? page;
        if (!url || seen.has(url)) continue;
        const save = igControls(rail).find((c) => /^(save|saved|remove|bookmark)\b/i.test(igLabel(c)));
        const before = save ? directChild(rail, save) : undefined;
        seen.add(url);
        out.push({ url, mount: rail, variant: "icon", fit: "rail", ...(before ? { before } : {}) });
    }
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
