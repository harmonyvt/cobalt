// Gallery share links (APP-API-CONTRACT.md section 24): 2..10 public files under one link,
// https://share.../g/<id>. The keyed routes (create, list, revoke) and the share host's pages for a set:
// the Open Graph page, and the Mastodon-shaped status Discord reads to draw every file as attachments.
// D1 only, the container is never involved. Free of Cloudflare imports so it runs under plain node.

import { captionOf, fileOf, setSubject, writeCaption, type Caption, type Captioner, type RoastInput } from "./roast";
import { ITEM_COLUMNS, effectiveVisibility, type MediaRow } from "./visibility";
import { escapeHtml, pageHeaders } from "./share";
import { loopUrls } from "./loops";
import {
    linkInsert,
    linkShape,
    liveLinksFor,
    newLinksSetting,
    revokeLinkQuietly,
    setIsPrivate,
    type PrivateLinkRow,
} from "./private-links";
import { privateFileUrl, privatePosterUrl } from "./share-private";
import { hiddenFileIds, notHiddenClause, shareGate } from "./hidden-store";
import type { StudioReply } from "./studio";

// 10 is the most a Discord media gallery shows (section 29; it was 4, the Open Graph image grid's limit).
export const SHARE_SET_MAX = 10;
// Discord's limit on a component embed payload (https://docs.discord.com/developers/link-previews/component-embeds).
export const COMPONENT_EMBED_MAX_BYTES = 3000;
export const SHARE_SET_MIN = 2;
export const SHARE_TITLE_MAX = 80;
export const SHARE_LIST_MAX = 200;
export const SET_ID_REGEX = /^[0-9]{19}$/;

export type ShareSetDeps = {
    db: D1Database;
    mediaBaseUrl: string;
    shareBaseUrl: string;
    now: () => number;
    randomBytes?: (n: number) => Uint8Array;
    // roast captions (section 25): written at creation, waiting at most captionWaitMs (the cron fills misses)
    captioner?: Captioner | null;
    captionWaitMs?: number;
    // Queues the moving previews of a new link's videos in the Durable Object (section 29). Never awaited
    // for long: the Worker hands it to waitUntil.
    kickLoops?: () => Promise<void>;
    // Whether Discord's gallery shows a video's moving preview in its place (section 29.1). Absent = on
    // (tests); the Worker passes GALLERY_LOOPS === "1", off by default since 2026-10-20.
    loops?: boolean;
    // the random bytes of a private link's key (section 36); absent = crypto
    keyBytes?: (n: number) => Uint8Array;
};

export const CAPTION_WAIT_MS = 6000;

export type SetRow = { id: string; items: string; title: string | null; created_at: number; revoked_at: number | null };

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);
const err = (status: number, code: string, extra: Record<string, unknown> = {}): StudioReply => ({
    status,
    body: { status: "error", error: { code }, ...extra },
});
const PUBLIC_NAME = /^[A-Za-z0-9]{6,40}\.[A-Za-z0-9]{1,8}$/;

// 19 random digits, first one 1..9 (a Mastodon-style numeric id, ~63 bits).
export function mintSetId(rb: (n: number) => Uint8Array = (n) => crypto.getRandomValues(new Uint8Array(n))): string {
    let out = "";
    while (out.length < 19) {
        for (const b of rb(32)) {
            if (b >= 250) continue; // keep the digits uniform
            const d = b % 10;
            if (out.length === 0 && d === 0) continue;
            out += String(d);
            if (out.length === 19) break;
        }
    }
    return out;
}

// The public file URL of a row, or null when it is not public right now.
export function publicUrlOf(r: MediaRow, mediaBaseUrl: string): string | null {
    if (r.deleted_at || effectiveVisibility(r) !== "public") return null;
    const key = r.bucket === "media" ? r.r2_key : r.public_key;
    return key && PUBLIC_NAME.test(key) ? `${withSlash(mediaBaseUrl)}${key}` : null;
}

// The live rows of these files. A file of a hidden post (section 37.2) is left out, so everything that reads a gallery
// link treats it like a deleted file.
export async function rowsById(db: D1Database, ids: string[]): Promise<Map<string, MediaRow>> {
    if (ids.length === 0) return new Map();
    const marks = ids.map((_, i) => `?${i + 1}`).join(", ");
    const cols = ITEM_COLUMNS.split(", ").map((c) => `m.${c}`).join(", ");
    const { results } = await db
        .prepare(`SELECT ${cols} FROM media_items m WHERE m.id IN (${marks}) AND m.deleted_at IS NULL${await notHiddenClause(db)}`)
        .bind(...ids)
        .all<MediaRow>();
    return new Map(results.map((r) => [r.id, r]));
}

export type SetItem = {
    id: string;
    url: string | null;
    content_type: string | null;
    poster_url: string | null;
    width: number | null;
    height: number | null;
    duration: number | null;
};

export const parseItems = (s: string): string[] => {
    try {
        const v = JSON.parse(s);
        return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
    } catch {
        return [];
    }
};

function itemsOf(ids: string[], rows: Map<string, MediaRow>, mediaBaseUrl: string): SetItem[] {
    return ids.map((id) => {
        const r = rows.get(id);
        const url = r ? publicUrlOf(r, mediaBaseUrl) : null;
        return {
            id,
            url,
            content_type: r?.content_type ?? null,
            poster_url: url && r?.poster && r.poster.startsWith(withSlash(mediaBaseUrl)) ? r.poster : null,
            width: r?.width ?? null,
            height: r?.height ?? null,
            duration: r?.duration ?? null,
        };
    });
}

// A private gallery link's files (section 36), as its owner sees them: every live file at its address under
// share.../p/<key>/, whatever its own state (a deleted one is null, as in a public link).
function privateItemsOf(d: Pick<ShareSetDeps, "mediaBaseUrl" | "shareBaseUrl">, ids: string[], rows: Map<string, MediaRow>, key: string): SetItem[] {
    return ids.map((id, i) => {
        const r = rows.get(id);
        const url = r ? privateFileUrl(d.shareBaseUrl, key, i + 1, r) : null;
        return {
            id,
            url,
            content_type: r?.content_type ?? null,
            poster_url: r && r.poster && r.poster.startsWith(withSlash(d.mediaBaseUrl)) ? privatePosterUrl(d.shareBaseUrl, key, i + 1) : null,
            width: r?.width ?? null,
            height: r?.height ?? null,
            duration: r?.duration ?? null,
        };
    });
}

// The set as every client sees it. Section 36: `url` is the link that works now (the private one while private),
// `public_url` its share.../g/<id>, `link` its live private link or null.
const setShape = (d: ShareSetDeps, s: SetRow, items: SetItem[], link: PrivateLinkRow | null = null) => {
    const publicUrl = `${withSlash(d.shareBaseUrl)}g/${s.id}`;
    const shaped = link ? linkShape(link, d.shareBaseUrl) : null;
    return {
        id: s.id,
        url: shaped ? shaped.url : publicUrl,
        title: s.title,
        created_at: s.created_at,
        items,
        private: link !== null,
        public_url: publicUrl,
        link: shaped,
    };
};

// The set's items: through its private link while it has one, else its public files.
const itemsFor = (d: ShareSetDeps, ids: string[], rows: Map<string, MediaRow>, link: PrivateLinkRow | null | undefined): SetItem[] =>
    link ? privateItemsOf(d, ids, rows, link.key) : itemsOf(ids, rows, d.mediaBaseUrl);

// Trimmed, no control characters, 1..80 code points; "" / absent = no title; null = invalid.
function cleanTitle(v: unknown): string | null | undefined {
    if (v === undefined || v === null) return undefined;
    if (typeof v !== "string") return null;
    // eslint-disable-next-line no-control-regex
    const t = v.replace(/[\u0000-\u001f\u007f]/g, "").trim();
    if (t === "") return undefined;
    return Array.from(t).length > SHARE_TITLE_MAX ? null : t;
}

// ---- keyed routes ---------------------------------------------------------------------------------

export async function createShareSet(d: ShareSetDeps, request: Request, keyId: string): Promise<StudioReply> {
    let body: unknown;
    try {
        body = await request.json();
    } catch {
        return err(400, "error.share.bad_request");
    }
    const b = body as { items?: unknown; title?: unknown; private?: unknown } | null;
    const items = b?.items;
    if (
        !Array.isArray(items) ||
        items.length < SHARE_SET_MIN ||
        items.length > SHARE_SET_MAX ||
        !items.every((x) => typeof x === "string" && /^[A-Za-z0-9]{16}$/.test(x)) ||
        new Set(items).size !== items.length
    ) {
        return err(400, "error.share.bad_request");
    }
    const title = cleanTitle(b?.title);
    if (title === null) return err(400, "error.share.bad_request");
    if (b?.private !== undefined && typeof b.private !== "boolean") return err(400, "error.share.bad_request");
    const ids = items as string[];
    try {
        // a hidden post's files are never shared (section 37.2); a held one's wait ends here (the owner decided, 37.3)
        const hidden = await shareGate(d.db, ids);
        if (hidden.length > 0) return err(409, "error.hidden", { ids: hidden });
        // section 36: absent = the owner's `new_links` setting
        const makePrivate = typeof b?.private === "boolean" ? b.private : (await newLinksSetting(d.db)) === "private";
        const rows = await rowsById(d.db, ids);
        const publicItems = itemsOf(ids, rows, d.mediaBaseUrl);
        // a private link may hold files that are not public: only missing or deleted ones are refused
        const bad = makePrivate ? ids.filter((id) => !rows.has(id)) : publicItems.filter((i) => i.url === null).map((i) => i.id);
        if (bad.length > 0) return err(409, "error.share.not_public", { items: bad });
        const row: SetRow = {
            id: mintSetId(d.randomBytes),
            items: JSON.stringify(ids),
            title: title ?? null,
            created_at: d.now(),
            revoked_at: null,
        };
        const insert = d.db
            .prepare("INSERT INTO share_sets (id, items, title, key_id, created_at) VALUES (?1, ?2, ?3, ?4, ?5)")
            .bind(row.id, row.items, row.title, keyId, row.created_at);
        let link: PrivateLinkRow | null = null;
        if (makePrivate) {
            // the set and its private link in one batch: never a moment where the new set is public
            const made = linkInsert(d.db, "set", row.id, row.created_at, d.keyBytes);
            await d.db.batch([insert, made.stmt]);
            link = made.row;
        } else {
            await insert.run();
        }
        const shaped = itemsFor(d, ids, rows, link);
        if (d.captioner) {
            const input: RoastInput = { files: ids.map((id) => rows.get(id)!).map((r, i) => fileOf(r, publicItems[i]!.url)), userTitle: row.title };
            const wait = d.captionWaitMs ?? CAPTION_WAIT_MS;
            // our own timeout: a slow model must not hold the link (the row is recorded either way)
            await Promise.race([
                writeCaption({ db: d.db, captioner: d.captioner, now: d.now }, setSubject(row.id), input),
                new Promise((r) => setTimeout(r, wait)),
            ]);
        }
        if (d.kickLoops && shaped.some((i) => (i.content_type ?? "").startsWith("video/"))) {
            await d.kickLoops().catch(() => {});
        }
        return { status: 201, body: { status: "success", set: setShape(d, row, shaped, link) } };
    } catch {
        return err(503, "error.api.generic");
    }
}

export async function listShareSets(d: ShareSetDeps): Promise<StudioReply> {
    try {
        const { results } = await d.db
            .prepare(
                `SELECT id, items, title, created_at, revoked_at FROM share_sets WHERE revoked_at IS NULL ORDER BY created_at DESC, id DESC LIMIT ${SHARE_LIST_MAX}`,
            )
            .all<SetRow>();
        const all = [...new Set(results.flatMap((s) => parseItems(s.items)))];
        const rows = new Map<string, MediaRow>();
        for (let i = 0; i < all.length; i += 90) {
            for (const [k, v] of await rowsById(d.db, all.slice(i, i + 90))) rows.set(k, v);
        }
        const links = await liveLinksFor(d.db, "set", results.map((s) => s.id));
        // a hidden file is listed like a deleted one (url null), and says so (section 37.2)
        const hidden = new Set(await hiddenFileIds(d.db, all));
        const mark = (items: SetItem[]) => (hidden.size === 0 ? items : items.map((i) => (hidden.has(i.id) ? { ...i, hidden: true } : i)));
        return {
            status: 200,
            body: {
                status: "success",
                sets: results.map((s) => setShape(d, s, mark(itemsFor(d, parseItems(s.items), rows, links.get(s.id))), links.get(s.id) ?? null)),
            },
        };
    } catch {
        return err(503, "error.api.generic");
    }
}

export async function revokeShareSet(d: ShareSetDeps, id: string): Promise<StudioReply> {
    try {
        const row = await d.db.prepare("SELECT id, revoked_at FROM share_sets WHERE id = ?1").bind(id).first<{ id: string; revoked_at: number | null }>();
        if (!row) return err(404, "error.share.not_found");
        if (row.revoked_at === null) {
            await d.db.prepare("UPDATE share_sets SET revoked_at = ?2 WHERE id = ?1 AND revoked_at IS NULL").bind(id, d.now()).run();
        }
        // its private link goes with it (section 36); a repeat cleans up one left by a failed call
        await revokeLinkQuietly(d.db, "set", id, d.now());
        return { status: 200, body: { status: "success" } };
    } catch {
        return err(503, "error.api.generic");
    }
}

// ---- the share host --------------------------------------------------------------------------------

// `loop_url`: a video's moving preview (section 29), when it has one
export type LiveSet = { set: SetRow; files: (SetItem & { url: string; loop_url?: string | null })[]; caption?: Caption | null };

export async function liveSetRow(db: D1Database, id: string): Promise<SetRow | null> {
    if (!SET_ID_REGEX.test(id)) return null;
    return (
        (await db
            .prepare("SELECT id, items, title, created_at, revoked_at FROM share_sets WHERE id = ?1 AND revoked_at IS NULL")
            .bind(id)
            .first<SetRow>()) ?? null
    );
}

// A public gallery link's page data: its public files. A link with a live private link (section 36) has none here.
async function liveSet(d: Pick<ShareSetDeps, "db" | "mediaBaseUrl" | "loops">, id: string): Promise<LiveSet | null> {
    const set = await liveSetRow(d.db, id);
    if (!set) return null;
    if (await setIsPrivate(d.db, id)) return null;
    const ids = parseItems(set.items);
    const files = itemsOf(ids, await rowsById(d.db, ids), d.mediaBaseUrl).filter((i): i is SetItem & { url: string } => i.url !== null);
    if (files.length === 0) return null;
    // with moving previews off, every video is the real file (full quality, sound, tap to play)
    const loops =
        d.loops === false
            ? new Map<string, string>()
            : await loopUrls(
                  d.db,
                  files.filter((f) => kindOf(f.content_type) === "video").map((f) => f.id),
              );
    return {
        set,
        files: files.map((f) => ({ ...f, loop_url: loops.get(f.id) ?? null })),
        caption: await captionOf(d.db, setSubject(set.id)),
    };
}

// A private gallery link's page data (section 36): every live file, whatever its own state, at its address under
// share.../p/<key>/ (files keep their place in the link, so file <n> never changes). No moving previews: they live on
// the media domain. Null when no file is left.
export async function privateLiveSet(d: Pick<ShareSetDeps, "db" | "mediaBaseUrl" | "shareBaseUrl">, set: SetRow, key: string): Promise<LiveSet | null> {
    const ids = parseItems(set.items);
    const files = privateItemsOf(d, ids, await rowsById(d.db, ids), key).filter((i): i is SetItem & { url: string } => i.url !== null);
    if (files.length === 0) return null;
    return { set, files: files.map((f) => ({ ...f, loop_url: null })), caption: await captionOf(d.db, setSubject(set.id)) };
}

// The roast model input for a live gallery link, or null when none of its files is public any more.
export async function setRoastInput(d: Pick<ShareSetDeps, "db" | "mediaBaseUrl">, id: string): Promise<RoastInput | null> {
    const set = await d.db
        .prepare("SELECT id, items, title, created_at, revoked_at FROM share_sets WHERE id = ?1 AND revoked_at IS NULL")
        .bind(id)
        .first<SetRow>();
    if (!set) return null;
    const ids = parseItems(set.items);
    const rows = await rowsById(d.db, ids);
    const files = ids
        .map((i) => rows.get(i))
        .filter((r): r is MediaRow => !!r)
        .map((r) => ({ r, url: publicUrlOf(r, d.mediaBaseUrl) }))
        .filter((x) => x.url !== null)
        .map((x) => fileOf(x.r, x.url));
    return files.length > 0 ? { files, userTitle: set.title } : null;
}

const NOT_FOUND = () =>
    new Response("not found\n", {
        status: 404,
        headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "public, max-age=60" },
    });

const jsonRes = (body: unknown) =>
    new Response(JSON.stringify(body), {
        headers: { "content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=60", "access-control-allow-origin": "*" },
    });

const kindOf = (t: string | null): "video" | "gif" | "image" => {
    const ty = (t ?? "").toLowerCase();
    if (ty.startsWith("video/")) return "video";
    if (ty === "image/gif" || ty === "image/webp") return "gif";
    return "image";
};

// A title Harmony typed wins; then the roast caption; then "N files".
const titleText = (s: LiveSet) => s.set.title ?? s.caption?.title ?? `${s.files.length} files`;
const descText = (s: LiveSet) => s.caption?.description || "";
const mdEscape = (t: string) => t.replace(/[\\*_~`|>#\[\]<@]/g, (c) => `\\${c}`);

// Discord refuses a video over 1920 px on a side: report half (the player scales).
function videoSize(w: number | null, h: number | null): { width: number; height: number } | null {
    if (!w || !h) return null;
    return w > 1920 || h > 1920 ? { width: Math.round(w / 2), height: Math.round(h / 2) } : { width: w, height: h };
}

function statusJson(d: ShareSetDeps, s: LiveSet) {
    const share = withSlash(d.shareBaseUrl);
    const pageUrl = `${share}g/${s.set.id}`;
    const created = new Date(s.set.created_at).toISOString();
    const account = {
        id: "1",
        username: "cobalt",
        acct: "cobalt",
        display_name: "capystore",
        locked: false,
        bot: false,
        discoverable: false,
        group: false,
        created_at: created,
        note: "",
        url: share,
        uri: share,
        avatar: "",
        avatar_static: "",
        header: "",
        header_static: "",
        followers_count: 0,
        following_count: 0,
        statuses_count: 0,
        last_status_at: null,
        emojis: [],
        fields: [],
    };
    const media_attachments = s.files.map((f, i) => {
        const k = kindOf(f.content_type);
        const size = k === "video" ? videoSize(f.width, f.height) : f.width && f.height ? { width: f.width, height: f.height } : null;
        const original = size ? { width: size.width, height: size.height, size: `${size.width}x${size.height}`, aspect: size.width / size.height } : {};
        return {
            id: String(i + 1),
            type: k === "video" ? "video" : k === "gif" && f.content_type?.toLowerCase() === "image/gif" ? "gifv" : "image",
            url: f.url,
            preview_url: k === "video" ? (f.poster_url ?? f.url) : f.url,
            remote_url: null,
            preview_remote_url: null,
            text_url: null,
            description: null,
            blurhash: null,
            meta: { original, ...(size ? { small: original } : {}) },
        };
    });
    return {
        id: s.set.id,
        created_at: created,
        in_reply_to_id: null,
        in_reply_to_account_id: null,
        sensitive: false,
        spoiler_text: "",
        visibility: "public",
        language: null,
        uri: pageUrl,
        url: pageUrl,
        replies_count: 0,
        reblogs_count: 0,
        favourites_count: 0,
        edited_at: null,
        content: s.set.title ? `<p>${escapeHtml(s.set.title)}</p>` : "",
        reblog: null,
        application: null,
        account,
        media_attachments,
        mentions: [],
        tags: [],
        emojis: [],
        card: null,
        poll: null,
    };
}

// https://docs.discord.com/developers/link-previews/component-embeds: one Container (17) holding a Text
// Display (10) and a Media Gallery (12) of every file. A video with a moving preview (section 29) is shown
// as that animated WebP, which Discord plays by itself, and the link then ends with an Action Row (1)
// holding one link Button (2, style 5) to the page, where the videos play with sound. At most 3,000
// bytes: over it the description goes, then the button; still over, null (Open Graph alone). `<` is
// escaped so the JSON cannot end the script.
export function componentEmbed(s: LiveSet, pageUrl: string): string | null {
    const looped = s.files.some((f) => kindOf(f.content_type) === "video" && f.loop_url);
    const build = (withDesc: boolean, withButton: boolean) =>
        JSON.stringify({
            component: {
                type: 17,
                components: [
                    {
                        type: 10,
                        content: [`**${mdEscape(titleText(s))}**`, withDesc && descText(s) ? mdEscape(descText(s)) : ""].filter(Boolean).join("\n"),
                    },
                    {
                        type: 12,
                        items: s.files.map((f) => ({ media: { url: kindOf(f.content_type) === "video" && f.loop_url ? f.loop_url : f.url } })),
                    },
                    ...(withButton ? [{ type: 1, components: [{ type: 2, style: 5, url: pageUrl, label: "watch with sound" }] }] : []),
                ],
            },
        }).replace(/</g, "\\u003c");
    for (const [desc, button] of [
        [true, looped],
        [false, looped],
        [false, false],
    ] as const) {
        const json = build(desc, button);
        if (new TextEncoder().encode(json).byteLength <= COMPONENT_EMBED_MAX_BYTES) return json;
    }
    return null;
}

export function pageHtml(d: Pick<ShareSetDeps, "shareBaseUrl">, s: LiveSet, discord: boolean, pageUrl = `${withSlash(d.shareBaseUrl)}g/${s.set.id}`): string {
    const e = escapeHtml;
    const title = titleText(s);
    const meta: string[] = [
        `<meta property="og:site_name" content="capystore">`,
        `<meta property="og:title" content="${e(title)}">`,
        `<meta property="og:url" content="${e(pageUrl)}">`,
        `<meta name="twitter:title" content="${e(title)}">`,
        `<meta name="theme-color" content="#000000">`,
        ...(descText(s) ? [`<meta property="og:description" content="${e(descText(s))}">`, `<meta name="twitter:description" content="${e(descText(s))}">`] : []),
    ];
    const video = s.files.find((f) => kindOf(f.content_type) === "video");
    if (video) {
        const size = videoSize(video.width, video.height);
        meta.push(
            `<meta property="og:type" content="video.other">`,
            `<meta property="og:video" content="${e(video.url)}">`,
            `<meta property="og:video:secure_url" content="${e(video.url)}">`,
            `<meta property="og:video:type" content="${e((video.content_type ?? "video/mp4").split(";")[0])}">`,
            ...(size ? [`<meta property="og:video:width" content="${size.width}">`, `<meta property="og:video:height" content="${size.height}">`] : []),
        );
    } else {
        meta.push(`<meta property="og:type" content="website">`);
    }
    // every picture (an image, a webp, a video's poster) is an og:image; Discord draws several as a grid
    const pictures = s.files.map((f) => (kindOf(f.content_type) === "video" ? f.poster_url : f.url)).filter((u): u is string => !!u);
    for (const p of pictures) meta.push(`<meta property="og:image" content="${e(p)}">`, `<meta name="twitter:image" content="${e(p)}">`);
    meta.push(`<meta name="twitter:card" content="summary_large_image">`);
    // Discord's component embed: every file in one Media Gallery, videos playable, animated images moving.
    // Open Graph above stays as the fallback. The Mastodon status routes remain but are no longer linked.
    const embed = discord ? componentEmbed(s, pageUrl) : null;
    if (embed) meta.push(`<script id="discord:component-embed" type="application/json">${embed}</script>`);
    const body = s.files
        .map((f) =>
            kindOf(f.content_type) === "video"
                ? `<video src="${e(f.url)}"${f.poster_url ? ` poster="${e(f.poster_url)}"` : ""} controls muted loop playsinline preload="metadata"></video>`
                : `<img src="${e(f.url)}" alt="" loading="lazy">`,
        )
        .join("\n");
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${e(title)}</title>
<link rel="canonical" href="${e(pageUrl)}">
${meta.join("\n")}
<style>
html,body{margin:0;background:#000;color:#ddd;font:15px -apple-system,system-ui,sans-serif}
main{display:grid;gap:8px;padding:8px;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));align-items:center}
video,img{width:100%;max-height:90vh;object-fit:contain;display:block;background:#111}
</style>
</head>
<body><main>
${body}
</main></body>
</html>
`;
}

// The share host's set routes; null when the path is not one of them (share.ts handles the rest).
export async function shareSetRoute(d: ShareSetDeps, request: Request): Promise<Response | null> {
    const url = new URL(request.url);
    const p = url.pathname;
    let id: string | null = null;
    let kind: "page" | "status" | "oembed";
    let m: RegExpExecArray | null;
    if ((m = /^\/g\/([^/]+)\/?$/.exec(p))) {
        id = m[1]!;
        kind = "page";
    } else if ((m = /^\/(?:api\/v1\/statuses|users\/cobalt\/statuses)\/([^/]+)$/.exec(p))) {
        id = m[1]!;
        kind = "status";
    } else if (p === "/owoembed") {
        id = url.searchParams.get("id");
        kind = "oembed";
    } else {
        return null;
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
        return new Response(null, { status: 405, headers: { allow: "GET, HEAD" } });
    }
    let s: LiveSet | null;
    try {
        s = id ? await liveSet(d, id) : null;
    } catch {
        return new Response("try again\n", { status: 503, headers: { "content-type": "text/plain", "retry-after": "5" } });
    }
    if (!s) return NOT_FOUND();
    if (kind === "status") return jsonRes(statusJson(d, s));
    if (kind === "oembed") {
        return jsonRes({
            version: "1.0",
            type: "rich",
            title: "Embed",
            provider_name: "capystore",
            provider_url: withSlash(d.shareBaseUrl),
            author_name: titleText(s),
        });
    }
    const discord = /discordbot/i.test(request.headers.get("user-agent") ?? "");
    const html = pageHtml(d, s, discord);
    const mediaOrigin = new URL(withSlash(d.mediaBaseUrl)).origin;
    return new Response(request.method === "HEAD" ? null : html, {
        headers: pageHeaders(mediaOrigin, "public, max-age=60", { vary: "user-agent" }),
    });
}
