// Stage (APP-API-CONTRACT.md section 29): a 1080p canvas OBS loads as a Browser Source that scatters the
// owner's public library files, a public viewer store, and Twitch channel-point redemptions that act on
// the canvas. This file is the D1 + route logic: settings, the pool, codes, the keyed owner routes
// (29.10), the stage host's pages and APIs (29.4), the Twitch connection (29.8) and the EventSub
// webhook (29.9). The Twitch client is stage-twitch.ts, the canvas WebSockets are the StageRoom Durable
// Object (stage-room.ts), the HTML is stage-pages.ts. Free of Cloudflare imports so it runs under plain
// node in the tests (real SQL on node:sqlite, fake Twitch, fake room).
//
// "studio" already means the save/trim session everywhere else, so this is `stage` in code, routes and
// tables; only the host (studio.capybaraharmony.com) and the app's tab say "studio".

import { POST_KEY_SQL } from "./app-routes";
import { searchPosts, type EmbedClient } from "./embed";
import { randomBase62 } from "./ids";
import { publicUrlOf } from "./share-sets";
import type { StudioReply } from "./studio";
import { ITEM_COLUMNS, extOf, visSql, type MediaRow } from "./visibility";
import { livePage, storeLockedPage, storePage } from "./stage-pages";
import {
    REWARD_SCOPE,
    TwitchError,
    decryptToken,
    encryptToken,
    twitchClient,
    twitchConfigFrom,
    verifyEventSub,
    type RewardBody,
    type TwitchClient,
    type TwitchConfig,
    type TwitchFetch,
} from "./stage-twitch";

// ---- constants (29.2, 29.3, 29.9) ---------------------------------------------------------------------

export const STAGE_ACTIONS = ["summon", "chaos", "shuffle", "pin"] as const;
export type StageAction = (typeof STAGE_ACTIONS)[number];
export const POOL_MAX = 2000;
export const POOL_TTL_MS = 10 * 60 * 1000;
export const SEARCH_POOL_POSTS = 200;
export const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
// 3-char codes until more than half of the 32^3 are used
export const CODES_SHORT_HALF = (32 * 32 * 32) / 2;
export const OAUTH_STATE_TTL_MS = 10 * 60 * 1000;
export const SEEN_TTL_MS = 10 * 60 * 1000;
export const REDEMPTION_KEEP_MS = 30 * 24 * 60 * 60 * 1000;
export const CHAOS_MS = 30_000;
export const CHAOS_MAX_MS = 60_000;
export const PIN_MS = 120_000;
export const INPUT_MAX = 200;
export const STORE_QUERY_MAX = 60;
// Every post gets a meaning-search score (section 21), so "best first" alone would always find something.
// Under this (cosine-like scale; tune against the real Space) a post is not a hit: a search pool leaves it
// out and a summon that finds nothing else is refunded. A plain title match still counts through the
// substring step.
export const SEARCH_MIN_SCORE = 0.2;
export const TWITCH_RETRY_MS = 10 * 60 * 1000;
// cap on an EventSub body (a notification is ~1 KB)
const WEBHOOK_BODY_MAX = 64 * 1024;

const REWARD_DEFAULTS: Record<StageAction, { cost: number; cooldown: number; enabled: number; prompt: string }> = {
    summon: { cost: 500, cooldown: 30, enabled: 1, prompt: "a code from the store, or a few words" },
    chaos: { cost: 2000, cooldown: 300, enabled: 1, prompt: "the canvas fills up for 30 seconds" },
    shuffle: { cost: 1000, cooldown: 120, enabled: 1, prompt: "wipe the canvas and refill it" },
    pin: { cost: 300, cooldown: 60, enabled: 0, prompt: "keep the spotlight up for 2 minutes" },
};

// ---- deps ---------------------------------------------------------------------------------------------

export type CanvasEvent =
    | { type: "settings"; stage: CanvasSettings }
    | { type: "pool" }
    | { type: "summon"; spotlight: Spotlight; toast: Toast | null }
    | { type: "chaos"; until: number; toast: Toast | null }
    | { type: "shuffle"; toast: Toast | null }
    | { type: "pin"; pinned_until: number; toast: Toast | null }
    | { type: "unpin" }
    | { type: "skip" }
    | { type: "rotated" }
    // not in 29.6: a refunded summon's toast (29.9 asks for one but defines no event for it)
    | { type: "toast"; toast: Toast & { refunded: true } };

export type Toast = { by: string; action: StageAction; cost: number; detail: string };

// What the room keeps between events (29.6: "the last spotlight and chaos until").
export type RoomState = { spotlight: Spotlight | null; pinned_until: number; chaos_until: number; chaos_by: string | null };
export const emptyRoom = (): RoomState => ({ spotlight: null, pinned_until: 0, chaos_until: 0, chaos_by: null });

export function reduceRoom(s: RoomState, e: CanvasEvent): RoomState {
    switch (e.type) {
        case "summon":
            // a new pick replaces whatever was up, pinned or not
            return { ...s, spotlight: e.spotlight, pinned_until: 0 };
        case "chaos":
            return { ...s, chaos_until: e.until, chaos_by: e.toast?.by ?? null };
        case "pin":
            return { ...s, pinned_until: e.pinned_until };
        case "unpin":
            return { ...s, pinned_until: 0 };
        case "skip":
            return { ...s, spotlight: null, pinned_until: 0 };
        default:
            return s;
    }
}

// The spotlight a new canvas should draw: newer than `seconds`, or pinned.
export function spotlightView(s: RoomState, now: number, seconds: number): Spotlight | null {
    const sp = s.spotlight;
    if (!sp) return null;
    const pinned = s.pinned_until > now;
    if (!pinned && sp.at + seconds * 1000 <= now) return null;
    return { ...sp, pinned_until: pinned ? s.pinned_until : null };
}

// The StageRoom Durable Object as the Worker uses it (index.ts wires the real one; tests a fake).
export interface RoomPort {
    send(event: CanvasEvent): Promise<void>;
    state(): Promise<RoomState>;
    // the /live/<token>/ws upgrade request, already token-checked
    connect(request: Request): Promise<Response>;
}

export type RoomNamespace = {
    idFromName(name: string): unknown;
    get(id: any): { fetch(request: Request): Promise<Response> };
};

export const ROOM_NAME = "main";

export function roomPort(ns: RoomNamespace): RoomPort {
    const stub = () => ns.get(ns.idFromName(ROOM_NAME));
    return {
        async send(event) {
            await stub().fetch(new Request("https://stage-room.internal/event", { method: "POST", body: JSON.stringify(event) }));
        },
        async state() {
            const res = await stub().fetch(new Request("https://stage-room.internal/state"));
            return { ...emptyRoom(), ...((await res.json()) as Partial<RoomState>) };
        },
        connect: (request) => stub().fetch(new Request("https://stage-room.internal/ws", request)),
    };
}

// No STAGE_ROOM binding: the routes still work, nothing is pushed and no canvas can connect.
export const noRoom: RoomPort = {
    async send() {},
    async state() {
        return emptyRoom();
    },
    async connect() {
        return new Response("no room\n", { status: 503, headers: { "content-type": "text/plain" } });
    },
};

export type StageDeps = {
    db: D1Database;
    mediaBaseUrl: string;
    // https://<stage host>/ with the trailing slash
    stageBaseUrl: string;
    // the three Twitch secrets, or null (canvas and store still work)
    twitch: TwitchConfig | null;
    twitchFetch?: TwitchFetch;
    embed: EmbedClient | null;
    room: RoomPort;
    now: () => number;
    waitUntil?: (p: Promise<unknown>) => void;
    randomBytes?: (n: number) => Uint8Array;
};

// ---- config from the environment ------------------------------------------------------------------------

type StageEnv = {
    STAGE_BASE_URL?: string;
    TWITCH_CLIENT_ID?: string;
    TWITCH_CLIENT_SECRET?: string;
    TWITCH_EVENTSUB_SECRET?: string;
};

// STAGE_BASE_URL as "https://host/" or null while it is unset or not an https URL.
export function stageBaseFrom(env: Pick<StageEnv, "STAGE_BASE_URL">): string | null {
    if (!env.STAGE_BASE_URL) return null;
    try {
        const u = new URL(env.STAGE_BASE_URL);
        return u.protocol === "https:" ? withSlash(u.toString()) : null;
    } catch {
        return null;
    }
}
export const stageHostFrom = (env: Pick<StageEnv, "STAGE_BASE_URL">): string | null => {
    const b = stageBaseFrom(env);
    return b ? new URL(b).hostname : null;
};
export { twitchConfigFrom };

// ---- small helpers ----------------------------------------------------------------------------------------

const withSlash = (u: string) => (u.endsWith("/") ? u : `${u}/`);
const err = (status: number, code: string): StudioReply => ({ status, body: { status: "error", error: { code } } });
const ok = (body: Record<string, unknown> = {}): StudioReply => ({ status: 200, body: { status: "success", ...body } });
const clamp = (n: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, n));
const log = (what: string, e?: unknown) => console.error(`[stage] ${what}`, e === undefined ? "" : e instanceof Error ? `${e.name}: ${e.message}` : String(e));

function background(d: Pick<StageDeps, "waitUntil">, p: Promise<unknown>): Promise<unknown> | undefined {
    const safe = p.catch((e) => log("background work failed", e));
    if (d.waitUntil) {
        d.waitUntil(safe);
        return undefined;
    }
    return safe;
}

// Same length and same bytes, without an early exit.
export function sameSecret(a: string, b: string): boolean {
    if (a.length !== b.length) return false;
    let diff = 0;
    for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return diff === 0;
}

const rbytes = (d: Pick<StageDeps, "randomBytes">) => d.randomBytes ?? ((n: number) => crypto.getRandomValues(new Uint8Array(n)));

async function readBody(request: Request): Promise<Record<string, unknown> | null> {
    try {
        const b = await request.json();
        return b && typeof b === "object" && !Array.isArray(b) ? (b as Record<string, unknown>) : null;
    } catch {
        return null;
    }
}

// ---- settings (29.2) -------------------------------------------------------------------------------------------

type PoolKind = "library" | "collection" | "group" | "search";
const POOL_KINDS: PoolKind[] = ["library", "collection", "group", "search"];

type SettingsRow = {
    on_air: number;
    pool_kind: PoolKind;
    pool_ref: string | null;
    pool_ids: string;
    pool_at: number;
    density: number;
    tile_seconds: number;
    tile_scale: number;
    spotlight_auto: number;
    spotlight_seconds: number;
    sound: number;
    video_max: number;
    store_open: number;
    store_hint: number;
    live_token: string;
    oauth_state: string | null;
    oauth_state_at: number | null;
    updated_at: number;
};

// The single settings row, created with its defaults (and the four rewards) on first read.
export async function readSettings(d: StageDeps): Promise<SettingsRow> {
    const have = await d.db.prepare("SELECT * FROM stage_settings WHERE id = 'main'").first<SettingsRow>();
    if (have) return have;
    const now = d.now();
    await d.db.batch([
        d.db.prepare("INSERT OR IGNORE INTO stage_settings (id, live_token, updated_at) VALUES ('main', ?1, ?2)").bind(randomBase62(32, rbytes(d)), now),
        ...STAGE_ACTIONS.map((a) =>
            d.db
                .prepare(
                    "INSERT OR IGNORE INTO stage_rewards (action, title, prompt, cost, cooldown_seconds, enabled, synced, updated_at) VALUES (?1, ?1, ?2, ?3, ?4, ?5, 0, ?6)",
                )
                .bind(a, REWARD_DEFAULTS[a].prompt, REWARD_DEFAULTS[a].cost, REWARD_DEFAULTS[a].cooldown, REWARD_DEFAULTS[a].enabled, now),
        ),
    ]);
    return (await d.db.prepare("SELECT * FROM stage_settings WHERE id = 'main'").first<SettingsRow>())!;
}

const SETTING_COLUMNS = new Set([
    "on_air",
    "pool_kind",
    "pool_ref",
    "pool_ids",
    "pool_at",
    "density",
    "tile_seconds",
    "tile_scale",
    "spotlight_auto",
    "spotlight_seconds",
    "sound",
    "video_max",
    "store_open",
    "store_hint",
    "live_token",
    "oauth_state",
    "oauth_state_at",
]);

async function writeSettings(d: StageDeps, fields: Record<string, number | string | null>): Promise<void> {
    const keys = Object.keys(fields).filter((k) => SETTING_COLUMNS.has(k));
    if (keys.length === 0) return;
    const sets = keys.map((k, i) => `${k} = ?${i + 1}`);
    await d.db
        .prepare(`UPDATE stage_settings SET ${sets.join(", ")}, updated_at = ?${keys.length + 1} WHERE id = 'main'`)
        .bind(...keys.map((k) => fields[k]!), d.now())
        .run();
}

export type CanvasSettings = {
    on_air: boolean;
    density: number;
    tile_seconds: number;
    tile_scale: number;
    spotlight_auto: boolean;
    spotlight_seconds: number;
    sound: boolean;
    video_max: number;
    store_hint: boolean;
    store_url: string | null;
};

const storeUrlOf = (d: Pick<StageDeps, "stageBaseUrl">) => `${d.stageBaseUrl}store`;
const liveUrlOf = (d: Pick<StageDeps, "stageBaseUrl">, s: Pick<SettingsRow, "live_token">) => `${d.stageBaseUrl}live/${s.live_token}`;

export function canvasSettings(d: Pick<StageDeps, "stageBaseUrl">, s: SettingsRow): CanvasSettings {
    return {
        on_air: s.on_air === 1,
        density: s.density,
        tile_seconds: s.tile_seconds,
        tile_scale: s.tile_scale,
        spotlight_auto: s.spotlight_auto === 1,
        spotlight_seconds: s.spotlight_seconds,
        sound: s.sound === 1,
        video_max: s.video_max,
        store_hint: s.store_hint === 1,
        // null while the store is locked, so the hint hides
        store_url: s.store_open === 1 ? storeUrlOf(d) : null,
    };
}

// ---- items (29.3) -----------------------------------------------------------------------------------------------

export type Item = {
    id: string;
    code: string;
    title: string;
    kind: "image" | "video";
    url: string;
    poster_url: string | null;
    width: number | null;
    height: number | null;
    duration: number | null;
};

export type StoreItem = {
    id: string;
    code: string;
    title: string;
    kind: "image" | "video";
    thumb_url: string;
    poster_url: string | null;
    width: number | null;
    height: number | null;
};

export const storeItem = (i: Item): StoreItem => ({
    id: i.id,
    code: i.code,
    title: i.title,
    kind: i.kind,
    thumb_url: i.kind === "video" ? (i.poster_url ?? i.url) : i.url,
    poster_url: i.poster_url,
    width: i.width,
    height: i.height,
});

const VIDEO_EXT = new Set(["mp4", "m4v", "mov", "webm"]);
const IMAGE_EXT = new Set(["webp", "gif", "jpg", "jpeg", "png", "avif"]);

// image (GIF and WebP included) or video; null for anything the canvas cannot draw (heic, pdf, ...)
export function mediaKind(r: Pick<MediaRow, "content_type" | "r2_key" | "public_key" | "bucket">): "image" | "video" | null {
    const ct = (r.content_type ?? "").split(";")[0]!.trim().toLowerCase();
    if (ct.startsWith("video/")) return "video";
    if (ct.startsWith("image/")) return ct === "image/heic" || ct === "image/heif" ? null : "image";
    const key = r.bucket === "media" ? r.r2_key : r.public_key;
    const ext = key ? extOf(key) : "";
    return VIDEO_EXT.has(ext) ? "video" : IMAGE_EXT.has(ext) ? "image" : null;
}

const MEDIA_COLS = ITEM_COLUMNS.split(", ")
    .map((c) => `m.${c}`)
    .join(", ");

type FileHit = { row: MediaRow; kind: "image" | "video" };

// The rows behind `ids` that are public right now (section 16: effective visibility public and a public
// URL), in `ids` order. A file made private or deleted since the pool was resolved drops out here.
async function publicFiles(d: StageDeps, ids: string[]): Promise<FileHit[]> {
    if (ids.length === 0) return [];
    const { results } = await d.db
        .prepare(`SELECT ${MEDIA_COLS} FROM json_each(?1) j JOIN media_items m ON m.id = j.value WHERE m.deleted_at IS NULL ORDER BY j.key`)
        .bind(JSON.stringify(ids))
        .all<MediaRow>();
    return keepPublic(d, results);
}

function keepPublic(d: Pick<StageDeps, "mediaBaseUrl">, rows: MediaRow[]): FileHit[] {
    const out: FileHit[] = [];
    for (const row of rows) {
        const kind = mediaKind(row);
        if (kind && publicUrlOf(row, d.mediaBaseUrl)) out.push({ row, kind });
    }
    return out;
}

type DecoratedRow = MediaRow & { custom_title: string | null; caption: string | null; code: string | null };

const fileTitle = (r: DecoratedRow): string => {
    const t = (r.custom_title ?? "").trim() || (r.caption ?? "").trim() || (r.name ?? "").trim().replace(/\.[A-Za-z0-9]{1,8}$/, "");
    return (t || "untitled").slice(0, 200);
};

// The canvas items for `ids`, in order, public ones only: title = the post's title, else the roast
// caption (section 25), else the file name; code = the pool code (minted here if it somehow has none).
export async function canvasItems(d: StageDeps, ids: string[]): Promise<Item[]> {
    if (ids.length === 0) return [];
    const { results } = await d.db
        .prepare(
            `SELECT ${MEDIA_COLS},
                    (SELECT t.title FROM media_titles t WHERE t.post_key = ${POST_KEY_SQL}) AS custom_title,
                    (SELECT c.title FROM media_captions c WHERE c.subject = 'item:' || m.id) AS caption,
                    (SELECT k.code FROM stage_codes k WHERE k.item_id = m.id) AS code
               FROM json_each(?1) j JOIN media_items m ON m.id = j.value
              WHERE m.deleted_at IS NULL ORDER BY j.key`,
        )
        .bind(JSON.stringify(ids))
        .all<DecoratedRow>();
    const posterBase = withSlash(d.mediaBaseUrl);
    const picked: { r: DecoratedRow; kind: "image" | "video"; url: string }[] = [];
    for (const r of results) {
        const kind = mediaKind(r);
        const url = kind ? publicUrlOf(r, d.mediaBaseUrl) : null;
        if (kind && url) picked.push({ r, kind, url });
    }
    const lacking = picked.filter((p) => !p.r.code).map((p) => p.r.id);
    const minted = lacking.length > 0 ? await ensureCodes(d, lacking) : new Map<string, string>();
    return picked.map(({ r, kind, url }) => ({
        id: r.id,
        code: r.code ?? minted.get(r.id) ?? "",
        title: fileTitle(r),
        kind,
        url,
        poster_url: kind === "video" && r.poster && r.poster.startsWith(posterBase) ? r.poster : null,
        width: r.width && r.width > 0 ? Math.round(r.width) : null,
        height: r.height && r.height > 0 ? Math.round(r.height) : null,
        duration: kind === "video" && r.duration && r.duration > 0 ? r.duration : null,
    }));
}

// ---- codes (29.2 stage_codes) ----------------------------------------------------------------------------------

// A code for every id that has none: 3 chars from the alphabet, 4 once more than half of the 3-char
// space is used. Codes never change. Returns code by item id for all `ids`.
export async function ensureCodes(d: StageDeps, ids: string[]): Promise<Map<string, string>> {
    const out = new Map<string, string>();
    const want = [...new Set(ids)];
    for (let attempt = 0; attempt < 3; attempt++) {
        const left = want.filter((i) => !out.has(i));
        if (left.length === 0) break;
        const { results } = await d.db
            .prepare("SELECT k.item_id, k.code FROM json_each(?1) j JOIN stage_codes k ON k.item_id = j.value")
            .bind(JSON.stringify(left))
            .all<{ item_id: string; code: string }>();
        for (const r of results) out.set(r.item_id, r.code);
        const missing = left.filter((i) => !out.has(i));
        if (missing.length === 0) break;
        const { results: used } = await d.db.prepare("SELECT code FROM stage_codes").all<{ code: string }>();
        const taken = new Set(used.map((u) => u.code));
        const now = d.now();
        const stmts: D1PreparedStatement[] = [];
        for (const id of missing) {
            const len = taken.size >= CODES_SHORT_HALF ? 4 : 3;
            let code = "";
            do {
                code = "";
                for (const b of rbytes(d)(len)) code += CODE_ALPHABET[b & 31];
            } while (taken.has(code));
            taken.add(code);
            stmts.push(d.db.prepare("INSERT OR IGNORE INTO stage_codes (code, item_id, created_at) VALUES (?1, ?2, ?3)").bind(code, id, now));
        }
        for (let i = 0; i < stmts.length; i += 50) await d.db.batch(stmts.slice(i, i + 50));
    }
    return out;
}

// ---- the pool (29.3) ----------------------------------------------------------------------------------------------

type PoolSpec = { kind: PoolKind; ref: string | null };
type Resolved = { ids: string[] } | { unavailable: true };

const cap = (ids: string[]) => [...new Set(ids)].slice(0, POOL_MAX);
const idsOfSets = (rows: { items: string }[]): string[] =>
    rows.flatMap((r) => {
        try {
            const v = JSON.parse(r.items);
            return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
        } catch {
            return [];
        }
    });

export async function resolvePool(d: StageDeps, spec: PoolSpec): Promise<Resolved> {
    if (spec.kind === "library") {
        const { results } = await d.db
            .prepare(
                `SELECT ${MEDIA_COLS} FROM media_items m
                  WHERE m.deleted_at IS NULL AND ${visSql("m.")} = 'public'
                    AND (m.content_type IS NULL OR m.content_type LIKE 'image/%' OR m.content_type LIKE 'video/%')
                  ORDER BY m.created_at DESC, m.id DESC LIMIT ${POOL_MAX * 2}`,
            )
            .all<MediaRow>();
        return { ids: keepPublic(d, results).slice(0, POOL_MAX).map((f) => f.row.id) };
    }
    if (spec.kind === "collection") {
        // every file of every live gallery link in it, in the collection's order (section 26)
        const { results } = await d.db
            .prepare(
                `SELECT s.items FROM share_collection_items i JOIN share_sets s ON s.id = i.set_id
                  WHERE i.collection_id = ?1 AND s.revoked_at IS NULL ORDER BY i.added_at DESC, i.set_id DESC`,
            )
            .bind(spec.ref)
            .all<{ items: string }>();
        return { ids: (await publicFiles(d, cap(idsOfSets(results)))).map((f) => f.row.id) };
    }
    if (spec.kind === "group") {
        // every file of every collection in it (section 28)
        const { results } = await d.db
            .prepare(
                `SELECT s.items FROM collection_group_items g
                   JOIN share_collections c ON c.id = g.collection_id
                   JOIN share_collection_items i ON i.collection_id = g.collection_id
                   JOIN share_sets s ON s.id = i.set_id
                  WHERE g.group_id = ?1 AND s.revoked_at IS NULL
                  ORDER BY g.added_at DESC, g.collection_id DESC, i.added_at DESC, i.set_id DESC`,
            )
            .bind(spec.ref)
            .all<{ items: string }>();
        return { ids: (await publicFiles(d, cap(idsOfSets(results)))).map((f) => f.row.id) };
    }
    // search: the meaning search over posts (section 21), best first, then each post's public files
    const found = await searchPosts({ db: d.db, client: d.embed, mediaBaseUrl: d.mediaBaseUrl }, spec.ref ?? "", SEARCH_POOL_POSTS);
    if (!found.ok) return { unavailable: true };
    const hits = found.hits.filter((h) => h.score >= SEARCH_MIN_SCORE);
    if (hits.length === 0) return { ids: [] };
    const { results } = await d.db
        .prepare(
            `SELECT * FROM (SELECT ${MEDIA_COLS}, m.item_index AS item_index, ${POST_KEY_SQL} AS post_key FROM media_items m WHERE m.deleted_at IS NULL)
              WHERE post_key IN (SELECT value FROM json_each(?1))`,
        )
        .bind(JSON.stringify(hits.map((h) => h.post_key)))
        .all<MediaRow & { item_index: number | null; post_key: string }>();
    const byPost = new Map<string, (MediaRow & { item_index: number | null })[]>();
    for (const r of results) byPost.set(r.post_key, [...(byPost.get(r.post_key) ?? []), r]);
    const ids: string[] = [];
    for (const h of hits) {
        const files = (byPost.get(h.post_key) ?? []).sort(
            (a, b) => (a.item_index ?? 0) - (b.item_index ?? 0) || a.created_at - b.created_at || (a.id < b.id ? -1 : 1),
        );
        for (const f of keepPublic(d, files)) ids.push(f.row.id);
    }
    return { ids: cap(ids) };
}

// The pool's display name, or null with `missing` when its collection or set was deleted.
export async function poolMeta(d: StageDeps, spec: PoolSpec): Promise<{ name: string | null; missing: boolean }> {
    if (spec.kind === "library") return { name: "whole library", missing: false };
    if (spec.kind === "search") return { name: spec.ref, missing: false };
    const table = spec.kind === "collection" ? "share_collections" : "collection_groups";
    const row = await d.db.prepare(`SELECT name FROM ${table} WHERE id = ?1`).bind(spec.ref).first<{ name: string }>();
    return row ? { name: row.name, missing: false } : { name: null, missing: true };
}

const parseIds = (raw: string): string[] => {
    try {
        const v = JSON.parse(raw);
        return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
    } catch {
        return [];
    }
};

// Resolves the pool again when it is older than 10 minutes (so new saves join) and stores it. A search
// pool that cannot be resolved right now (search off or asleep) keeps its old ids and is tried again in a minute.
export async function freshSettings(d: StageDeps): Promise<SettingsRow> {
    const s = await readSettings(d);
    if (d.now() - s.pool_at <= POOL_TTL_MS) return s;
    try {
        const r = await resolvePool(d, { kind: s.pool_kind, ref: s.pool_ref });
        if ("unavailable" in r) {
            await writeSettings(d, { pool_at: d.now() - POOL_TTL_MS + 60_000 });
            return { ...s, pool_at: d.now() - POOL_TTL_MS + 60_000 };
        }
        await ensureCodes(d, r.ids);
        await writeSettings(d, { pool_ids: JSON.stringify(r.ids), pool_at: d.now() });
        return { ...s, pool_ids: JSON.stringify(r.ids), pool_at: d.now() };
    } catch (e) {
        log("pool refresh failed", e);
        return s;
    }
}

// ---- twitch rows and tokens (29.2, 29.8) ----------------------------------------------------------------------------

type TwitchRow = {
    broadcaster_id: string;
    login: string;
    display_name: string;
    access_token: string;
    refresh_token: string;
    expires_at: number;
    scopes: string;
    eventsub_id: string | null;
    connected_at: number;
    last_event_at: number | null;
    status: "setting_up" | "ok" | "reconnect" | "not_affiliate";
    status_at: number;
};

type RewardRow = {
    action: StageAction;
    twitch_reward_id: string | null;
    title: string;
    prompt: string;
    cost: number;
    cooldown_seconds: number;
    enabled: number;
    synced: number;
    updated_at: number;
};

const readTwitch = (d: StageDeps) => d.db.prepare("SELECT * FROM stage_twitch WHERE id = 'main'").first<TwitchRow>();

async function readRewards(d: StageDeps): Promise<RewardRow[]> {
    const { results } = await d.db.prepare("SELECT * FROM stage_rewards").all<RewardRow>();
    return STAGE_ACTIONS.map((a) => results.find((r) => r.action === a)).filter((r): r is RewardRow => !!r);
}

const clientOf = (d: StageDeps): TwitchClient | null =>
    d.twitch ? twitchClient(d.twitch, d.twitchFetch ?? ((u, i) => fetch(u, i)), d.now) : null;

async function setStatus(d: StageDeps, status: TwitchRow["status"]): Promise<void> {
    await d.db.prepare("UPDATE stage_twitch SET status = ?1, status_at = ?2 WHERE id = 'main' AND status <> ?1").bind(status, d.now()).run();
}

// The broadcaster's access token, refreshed when it expires within 5 minutes (or `force`: Helix said
// 401). A failed refresh, or tokens this key cannot open any more, sets status "reconnect".
async function accessToken(d: StageDeps, tw: TwitchClient, force: boolean): Promise<string> {
    const row = await readTwitch(d);
    if (!row || !d.twitch) throw new TwitchError(404, "not connected");
    try {
        if (!force && row.expires_at - d.now() > 5 * 60_000) return await decryptToken(d.twitch.clientSecret, row.access_token);
        const t = await tw.refresh(await decryptToken(d.twitch.clientSecret, row.refresh_token));
        await d.db
            .prepare("UPDATE stage_twitch SET access_token = ?1, refresh_token = ?2, expires_at = ?3, scopes = ?4 WHERE id = 'main'")
            .bind(
                await encryptToken(d.twitch.clientSecret, t.access_token),
                await encryptToken(d.twitch.clientSecret, t.refresh_token || (await decryptToken(d.twitch.clientSecret, row.refresh_token))),
                d.now() + t.expires_in * 1000,
                t.scope.length > 0 ? t.scope.join(" ") : row.scopes,
            )
            .run();
        return t.access_token;
    } catch (e) {
        // an invalid refresh token (400/401), or unreadable stored tokens: the owner has to connect again
        if (!(e instanceof TwitchError) || e.status === 400 || e.status === 401) {
            await setStatus(d, "reconnect").catch(() => undefined);
            throw new TwitchError(401, "reconnect");
        }
        throw e;
    }
}

// Runs a Helix call as the broadcaster; a 401 refreshes the token once and tries again.
async function asBroadcaster<T>(d: StageDeps, tw: TwitchClient, call: (token: string, broadcasterId: string) => Promise<T>): Promise<T> {
    const row = await readTwitch(d);
    if (!row) throw new TwitchError(404, "not connected");
    let token = await accessToken(d, tw, false);
    try {
        return await call(token, row.broadcaster_id);
    } catch (e) {
        if (!(e instanceof TwitchError) || e.status !== 401) throw e;
        token = await accessToken(d, tw, true);
        return await call(token, row.broadcaster_id);
    }
}

// ---- twitch setup: rewards and the EventSub subscription (29.8) ------------------------------------------------------

const rewardBody = (r: RewardRow): RewardBody => ({
    cost: r.cost,
    prompt: r.prompt,
    is_enabled: r.enabled === 1,
    is_user_input_required: r.action === "summon",
    is_global_cooldown_enabled: r.cooldown_seconds > 0,
    ...(r.cooldown_seconds > 0 ? { global_cooldown_seconds: r.cooldown_seconds } : {}),
    should_redemptions_skip_request_queue: false,
});

// Brings one reward on Twitch to the row's values (creating it first when it has no id), then marks it synced.
// Twitch reward titles are unique per channel: the bare word, else "capystore <word>". Throws Twitch's refusal.
async function syncReward(d: StageDeps, tw: TwitchClient, r: RewardRow, mine: Map<string, string>): Promise<void> {
    const store = (id: string, title: string) =>
        d.db
            .prepare("UPDATE stage_rewards SET twitch_reward_id = ?2, title = ?3, synced = 1 WHERE action = ?1 AND updated_at = ?4")
            .bind(r.action, id, title, r.updated_at)
            .run();
    let id = r.twitch_reward_id;
    let title = r.title;
    if (!id) {
        const adopt = [r.action, `capystore ${r.action}`].find((t) => mine.has(t));
        if (adopt) {
            id = mine.get(adopt)!;
            title = adopt;
        }
    }
    if (id) {
        try {
            await asBroadcaster(d, tw, (t, b) => tw.updateReward(t, b, id!, rewardBody(r)));
            await store(id, title);
            return;
        } catch (e) {
            // deleted on Twitch by hand: make it again below
            if (!(e instanceof TwitchError) || e.status !== 404) throw e;
        }
    }
    const create = (t: string) => asBroadcaster(d, tw, (tok, b) => tw.createReward(tok, b, { ...rewardBody(r), title: t }));
    try {
        const made = await create(r.action);
        await store(made.id, made.title || r.action);
    } catch (e) {
        if (!(e instanceof TwitchError) || e.status !== 400 || !/duplicate/i.test(e.detail)) throw e;
        const prefixed = `capystore ${r.action}`;
        const made = await create(prefixed);
        await store(made.id, made.title || prefixed);
    }
}

let syncing = false;

// Creates or updates the four rewards and the EventSub subscription; each step is logged and a failure
// leaves the connection stored for the next GET /stage to retry (29.8). Never throws.
export async function syncTwitch(d: StageDeps): Promise<void> {
    const tw = clientOf(d);
    if (!tw || syncing) return;
    syncing = true;
    try {
        let row = await readTwitch(d);
        if (!row) return;
        let forbidden = false;
        const rewards = await readRewards(d);
        // rewards this app already made on the channel (a reconnect, a half-finished setup): adopted, not duplicated
        let mine = new Map<string, string>();
        if (rewards.some((r) => !r.twitch_reward_id)) {
            try {
                const list = await asBroadcaster(d, tw, (t, b) => tw.listManageableRewards(t, b));
                mine = new Map(list.map((x) => [x.title, x.id]));
            } catch (e) {
                if (e instanceof TwitchError && e.status === 403) forbidden = true;
                else log("listing rewards failed", e);
            }
        }
        for (const r of rewards) {
            if (forbidden) break;
            if (r.synced === 1 && r.twitch_reward_id) continue;
            try {
                await syncReward(d, tw, r, mine);
            } catch (e) {
                if (e instanceof TwitchError && e.status === 403) {
                    // channel points need an Affiliate or Partner channel
                    forbidden = true;
                } else log(`reward ${r.action} failed`, e);
            }
        }
        row = (await readTwitch(d)) ?? row;
        if (!forbidden && !row.eventsub_id && row.status !== "reconnect") {
            try {
                const app = await tw.appToken();
                const id = await tw.createSubscription(app, row.broadcaster_id, `${d.stageBaseUrl}twitch/eventsub`);
                await d.db.prepare("UPDATE stage_twitch SET eventsub_id = ?1 WHERE id = 'main'").bind(id).run();
            } catch (e) {
                log("eventsub subscription failed", e);
            }
        }
        row = (await readTwitch(d)) ?? row;
        if (row.status === "reconnect") return;
        const after = await readRewards(d);
        if (forbidden) await setStatus(d, "not_affiliate");
        else if (row.eventsub_id && after.every((r) => r.synced === 1 && r.twitch_reward_id)) await setStatus(d, "ok");
        else await setStatus(d, "setting_up");
    } catch (e) {
        log("twitch sync failed", e);
    } finally {
        syncing = false;
    }
}

// Does GET /stage have setup left to retry? A reconnect needs the owner; not_affiliate is tried every 10 minutes.
function needsSync(d: StageDeps, row: TwitchRow | null, rewards: RewardRow[]): boolean {
    if (!row || !d.twitch || row.status === "reconnect") return false;
    if (row.status === "not_affiliate" && d.now() - row.status_at < TWITCH_RETRY_MS) return false;
    return row.status === "setting_up" || row.status === "not_affiliate" || !row.eventsub_id || rewards.some((r) => !r.synced || !r.twitch_reward_id);
}

// ---- the owner's stage shape (29.10) ----------------------------------------------------------------------------------------

const rewardShape = (r: RewardRow, connected: boolean) => ({
    action: r.action,
    title: r.title,
    cost: r.cost,
    cooldown_seconds: r.cooldown_seconds,
    enabled: r.enabled === 1,
    synced: connected && r.synced === 1 && !!r.twitch_reward_id,
});

async function stageShape(d: StageDeps, s: SettingsRow, tw: TwitchRow | null, room: RoomState, count?: number) {
    const spec: PoolSpec = { kind: s.pool_kind, ref: s.pool_ref };
    const meta = await poolMeta(d, spec);
    return {
        on_air: s.on_air === 1,
        pool: {
            kind: s.pool_kind,
            ref: s.pool_kind === "library" ? null : s.pool_ref,
            name: meta.name,
            count: meta.missing ? 0 : (count ?? (await publicFiles(d, parseIds(s.pool_ids))).length),
            missing: meta.missing,
        },
        density: s.density,
        tile_seconds: s.tile_seconds,
        tile_scale: s.tile_scale,
        spotlight_auto: s.spotlight_auto === 1,
        spotlight_seconds: s.spotlight_seconds,
        sound: s.sound === 1,
        video_max: s.video_max,
        store_open: s.store_open === 1,
        store_hint: s.store_hint === 1,
        live_url: liveUrlOf(d, s),
        store_url: storeUrlOf(d),
        twitch: tw
            ? { login: tw.login, display_name: tw.display_name, connected_at: tw.connected_at, status: tw.status, last_event_at: tw.last_event_at }
            : null,
        spotlight: spotlightView(room, d.now(), s.spotlight_seconds),
        updated_at: s.updated_at,
    };
}

async function roomState(d: StageDeps): Promise<RoomState> {
    try {
        return await d.room.state();
    } catch (e) {
        log("room state failed", e);
        return emptyRoom();
    }
}

async function broadcast(d: StageDeps, e: CanvasEvent): Promise<void> {
    try {
        await d.room.send(e);
    } catch (err) {
        log(`broadcast ${e.type} failed`, err);
    }
}

// the live pool of a settings row, as canvas items (a pool whose collection was deleted is empty)
async function poolItems(d: StageDeps, s: SettingsRow): Promise<Item[]> {
    const meta = await poolMeta(d, { kind: s.pool_kind, ref: s.pool_ref });
    return meta.missing ? [] : canvasItems(d, parseIds(s.pool_ids));
}

// ---- owner routes (29.10) ---------------------------------------------------------------------------------------------------

export type StageOp = "get" | "patch" | "rotate" | "action" | "pool" | "redemptions" | "reward" | "twitch_connect" | "twitch_delete";

export async function stageKeyed(d: StageDeps, op: StageOp, request: Request, params: Record<string, string>, q: URLSearchParams): Promise<StudioReply> {
    try {
        if ((op === "twitch_connect" || op === "twitch_delete") && !d.twitch) return err(404, "error.stage.twitch_off");
        switch (op) {
            case "get":
                return await ownerGet(d);
            case "patch":
                return await ownerPatch(d, request);
            case "rotate":
                return await ownerRotate(d);
            case "action":
                return await ownerAction(d, request);
            case "pool":
                return await ownerPool(d, q);
            case "redemptions":
                return await ownerRedemptions(d, q);
            case "reward":
                return await ownerReward(d, request, params.action ?? "");
            case "twitch_connect":
                return await ownerTwitchConnect(d);
            case "twitch_delete":
                return await ownerTwitchDelete(d);
        }
    } catch (e) {
        log(`${op} failed`, e);
        return err(503, "error.api.generic");
    }
}

async function ownerGet(d: StageDeps): Promise<StudioReply> {
    const s = await freshSettings(d);
    const tw = await readTwitch(d);
    const rewards = await readRewards(d);
    // setup left over from a connect that did not finish, or a reward Twitch refused: tried again now
    if (needsSync(d, tw, rewards)) void background(d, syncTwitch(d));
    return ok({
        stage: await stageShape(d, s, tw, await roomState(d)),
        rewards: rewards.map((r) => rewardShape(r, !!tw)),
    });
}

type Num = { key: string; lo: number; hi: number; int: boolean };
const NUMBERS: Num[] = [
    { key: "density", lo: 5, hi: 100, int: true },
    { key: "tile_seconds", lo: 3, hi: 30, int: true },
    { key: "tile_scale", lo: 0.5, hi: 1.6, int: false },
    { key: "spotlight_seconds", lo: 10, hi: 120, int: true },
    { key: "video_max", lo: 0, hi: 24, int: true },
];
const BOOLS = ["on_air", "spotlight_auto", "sound", "store_open", "store_hint"] as const;

async function ownerPatch(d: StageDeps, request: Request): Promise<StudioReply> {
    const bad = () => err(400, "error.stage.bad_request");
    const b = await readBody(request);
    if (!b) return bad();
    await readSettings(d);
    const set: Record<string, number | string | null> = {};
    for (const k of BOOLS) {
        if (b[k] === undefined) continue;
        if (typeof b[k] !== "boolean") return bad();
        set[k] = b[k] ? 1 : 0;
    }
    for (const n of NUMBERS) {
        const v = b[n.key];
        if (v === undefined) continue;
        if (typeof v !== "number" || !Number.isFinite(v)) return bad();
        // out of range is clamped, not refused
        set[n.key] = n.int ? clamp(Math.round(v), n.lo, n.hi) : Math.round(clamp(v, n.lo, n.hi) * 100) / 100;
    }

    let spec: PoolSpec | null = null;
    if (b.pool !== undefined) {
        const p = b.pool;
        if (!p || typeof p !== "object" || Array.isArray(p)) return bad();
        const kind = (p as { kind?: unknown }).kind;
        const ref = (p as { ref?: unknown }).ref;
        if (typeof kind !== "string" || !POOL_KINDS.includes(kind as PoolKind)) return bad();
        if (kind === "library") spec = { kind, ref: null };
        else if (kind === "search") {
            const words = typeof ref === "string" ? ref.replace(/\s+/g, " ").trim() : "";
            if (words === "" || words.length > 200) return bad();
            spec = { kind, ref: words };
        } else {
            if (typeof ref !== "string" || !/^[A-Za-z0-9]{16}$/.test(ref)) return bad();
            const meta = await poolMeta(d, { kind: kind as PoolKind, ref });
            if (meta.missing) return bad();
            spec = { kind: kind as PoolKind, ref };
        }
    }

    let resolved: string[] | null = null;
    if (spec) {
        if (spec.kind === "search" && !d.embed) return err(503, "error.stage.search_unavailable");
        const r = await resolvePool(d, spec);
        // search off or asleep: nothing changes
        if ("unavailable" in r) return err(503, "error.stage.search_unavailable");
        resolved = r.ids;
        await ensureCodes(d, resolved);
        set.pool_kind = spec.kind;
        set.pool_ref = spec.ref;
        set.pool_ids = JSON.stringify(resolved);
        set.pool_at = d.now();
    }

    await writeSettings(d, set);
    const s = await readSettings(d);
    await broadcast(d, { type: "settings", stage: canvasSettings(d, s) });
    if (spec) await broadcast(d, { type: "pool" });
    return ok({ stage: await stageShape(d, s, await readTwitch(d), await roomState(d), resolved?.length) });
}

async function ownerRotate(d: StageDeps): Promise<StudioReply> {
    await readSettings(d);
    await writeSettings(d, { live_token: randomBase62(32, rbytes(d)) });
    // the old token's sockets are told, then closed (29.6)
    await broadcast(d, { type: "rotated" });
    const s = await readSettings(d);
    return ok({ stage: await stageShape(d, s, await readTwitch(d), await roomState(d)) });
}

const ACTION_TYPES = ["skip", "pin", "unpin", "shuffle", "chaos", "spotlight"] as const;

// chaos lasts 30 s; another one extends it to at most 60 s from now (29.9)
export function nextChaosUntil(now: number, current: number): number {
    return current > now ? Math.min(current + CHAOS_MS, now + CHAOS_MAX_MS) : now + CHAOS_MS;
}

async function ownerAction(d: StageDeps, request: Request): Promise<StudioReply> {
    const b = await readBody(request);
    const type = b?.type;
    if (!b || typeof type !== "string" || !(ACTION_TYPES as readonly string[]).includes(type)) return err(400, "error.stage.bad_request");
    if (b.item_id !== undefined && typeof b.item_id !== "string") return err(400, "error.stage.bad_request");
    const s = await freshSettings(d);
    if (s.on_air !== 1) return err(409, "error.stage.off_air");
    const now = d.now();
    const room = await roomState(d);
    let itemId: string | null = null;
    if (type === "spotlight") {
        if (typeof b.item_id !== "string" || !parseIds(s.pool_ids).includes(b.item_id)) return err(404, "error.stage.not_found");
        const [item] = await canvasItems(d, [b.item_id]);
        if (!item) return err(404, "error.stage.not_found");
        itemId = item.id;
        await broadcast(d, { type: "summon", spotlight: { item, by: null, action: "owner", pinned_until: null, at: now }, toast: null });
    } else if (type === "skip") await broadcast(d, { type: "skip" });
    else if (type === "unpin") await broadcast(d, { type: "unpin" });
    else if (type === "shuffle") await broadcast(d, { type: "shuffle", toast: null });
    else if (type === "chaos") await broadcast(d, { type: "chaos", until: nextChaosUntil(now, room.chaos_until), toast: null });
    else await broadcast(d, { type: "pin", pinned_until: now + PIN_MS, toast: null });
    await d.db
        .prepare(
            "INSERT INTO stage_redemptions (id, action, user_id, user_login, user_name, input, item_id, status, reason, created_at) VALUES (?1, ?2, 'owner', 'owner', 'you', '', ?3, 'done', NULL, ?4)",
        )
        .bind(`owner:${randomBase62(16, rbytes(d))}`, type, itemId, now)
        .run();
    return ok({ stage: await stageShape(d, s, await readTwitch(d), await roomState(d)) });
}

const pageParams = (q: URLSearchParams, max: number, def: number): { offset: number; limit: number } | null => {
    let offset = 0;
    let limit = def;
    if (q.has("offset")) {
        const raw = q.get("offset") ?? "";
        if (!/^\d{1,7}$/.test(raw)) return null;
        offset = Number(raw);
    }
    if (q.has("limit")) {
        const raw = q.get("limit") ?? "";
        if (!/^\d{1,4}$/.test(raw)) return null;
        limit = Number(raw);
        if (limit < 1 || limit > max) return null;
    }
    return { offset, limit };
};

async function ownerPool(d: StageDeps, q: URLSearchParams): Promise<StudioReply> {
    const p = pageParams(q, 100, 60);
    if (!p) return err(400, "error.stage.bad_request");
    const s = await freshSettings(d);
    const all = await poolItems(d, s);
    const items = all.slice(p.offset, p.offset + p.limit);
    return ok({ total: all.length, offset: p.offset, next: p.offset + p.limit < all.length ? p.offset + p.limit : null, items });
}

type RedemptionRow = {
    id: string;
    action: string;
    user_name: string;
    input: string;
    item_id: string | null;
    status: string;
    reason: string | null;
    created_at: number;
};

async function ownerRedemptions(d: StageDeps, q: URLSearchParams): Promise<StudioReply> {
    let limit = 30;
    if (q.has("limit")) {
        const raw = q.get("limit") ?? "";
        if (!/^\d{1,4}$/.test(raw) || Number(raw) < 1 || Number(raw) > 100) return err(400, "error.stage.bad_request");
        limit = Number(raw);
    }
    let before = Number.MAX_SAFE_INTEGER;
    if (q.has("before")) {
        const raw = q.get("before") ?? "";
        if (!/^\d{1,16}$/.test(raw)) return err(400, "error.stage.bad_request");
        before = Number(raw);
    }
    const { results } = await d.db
        .prepare(
            "SELECT id, action, user_name, input, item_id, status, reason, created_at FROM stage_redemptions WHERE created_at < ?1 ORDER BY created_at DESC, id DESC LIMIT ?2",
        )
        .bind(before, limit)
        .all<RedemptionRow>();
    const ids = [...new Set(results.map((r) => r.item_id).filter((x): x is string => !!x))];
    const items = new Map((await canvasItems(d, ids)).map((i) => [i.id, i]));
    return ok({
        redemptions: results.map((r) => ({
            id: r.id,
            action: r.action,
            user_name: r.user_name,
            input: r.input,
            item: r.item_id ? (items.get(r.item_id) ?? null) : null,
            status: r.status,
            reason: r.reason,
            created_at: r.created_at,
        })),
    });
}

async function ownerReward(d: StageDeps, request: Request, action: string): Promise<StudioReply> {
    if (!(STAGE_ACTIONS as readonly string[]).includes(action)) return err(404, "error.stage.not_found");
    const bad = () => err(400, "error.stage.bad_request");
    const b = await readBody(request);
    if (!b) return bad();
    const int = (v: unknown, lo: number, hi: number): number | null | undefined =>
        v === undefined ? undefined : typeof v === "number" && Number.isInteger(v) && v >= lo && v <= hi ? v : null;
    const cost = int(b.cost, 1, 1_000_000);
    const cooldown = int(b.cooldown_seconds, 0, 604_800);
    if (cost === null || cooldown === null) return bad();
    if (b.enabled !== undefined && typeof b.enabled !== "boolean") return bad();
    if (cost === undefined && cooldown === undefined && b.enabled === undefined) return bad();
    await readSettings(d);
    await d.db
        .prepare(
            "UPDATE stage_rewards SET cost = COALESCE(?2, cost), cooldown_seconds = COALESCE(?3, cooldown_seconds), enabled = COALESCE(?4, enabled), synced = 0, updated_at = ?5 WHERE action = ?1",
        )
        .bind(action, cost ?? null, cooldown ?? null, b.enabled === undefined ? null : b.enabled ? 1 : 0, d.now())
        .run();
    const tw = await readTwitch(d);
    const tc = clientOf(d);
    if (tw && tc) {
        // the next GET /stage retries what Twitch refuses (synced stays false)
        const row = (await readRewards(d)).find((r) => r.action === action)!;
        try {
            await syncReward(d, tc, row, new Map());
        } catch (e) {
            if (e instanceof TwitchError && e.status === 403) await setStatus(d, "not_affiliate").catch(() => undefined);
            log(`reward ${action} not synced`, e);
        }
    }
    const row = (await readRewards(d)).find((r) => r.action === action)!;
    return ok({ reward: rewardShape(row, !!tw) });
}

async function ownerTwitchConnect(d: StageDeps): Promise<StudioReply> {
    const tc = clientOf(d)!;
    await readSettings(d);
    const state = randomBase62(32, rbytes(d));
    await writeSettings(d, { oauth_state: state, oauth_state_at: d.now() });
    return ok({ authorize_url: tc.authorizeUrl(`${d.stageBaseUrl}twitch/callback`, state) });
}

async function ownerTwitchDelete(d: StageDeps): Promise<StudioReply> {
    const tw = await readTwitch(d);
    if (tw) await disconnect(d, tw);
    const s = await readSettings(d);
    return ok({ stage: await stageShape(d, s, null, await roomState(d)) });
}

// Best effort on Twitch (the subscription, the four rewards, the tokens), then the row and the reward ids are gone.
async function disconnect(d: StageDeps, tw: TwitchRow): Promise<void> {
    const tc = clientOf(d);
    if (tc) {
        if (tw.eventsub_id) {
            try {
                await tc.deleteSubscription(await tc.appToken(), tw.eventsub_id);
            } catch (e) {
                log("deleting the subscription failed", e);
            }
        }
        for (const r of await readRewards(d)) {
            if (!r.twitch_reward_id) continue;
            try {
                await asBroadcaster(d, tc, (t, b) => tc.deleteReward(t, b, r.twitch_reward_id!));
            } catch (e) {
                log(`deleting reward ${r.action} failed`, e);
            }
        }
        try {
            await tc.revoke(await accessToken(d, tc, false));
        } catch {
            /* the tokens are dropped below either way */
        }
    }
    await d.db.batch([
        d.db.prepare("DELETE FROM stage_twitch WHERE id = 'main'"),
        d.db.prepare("UPDATE stage_rewards SET twitch_reward_id = NULL, title = action, synced = 0"),
    ]);
}

// ---- the stage host (29.4) -------------------------------------------------------------------------------------------------------

const HTML_HEADERS = { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "x-robots-tag": "noindex", "referrer-policy": "no-referrer" };

const jsonRes = (r: StudioReply) =>
    new Response(JSON.stringify(r.body), { status: r.status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
const notFound = () =>
    new Response("not found\n", { status: 404, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });

export async function stageSite(d: StageDeps, request: Request): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    try {
        if (path === "/twitch/eventsub") return request.method === "POST" ? await eventSub(d, request) : notFound();
        if (request.method !== "GET" && request.method !== "HEAD") return notFound();

        if (path.startsWith("/live/")) {
            const [token, sub, ...rest] = path.slice("/live/".length).split("/");
            if (rest.length > 0 || !token) return notFound();
            const s = await readSettings(d);
            // a wrong (or rotated) token says nothing
            if (!sameSecret(token, s.live_token)) {
                return sub === "state" ? jsonRes(err(404, "error.stage.not_found")) : notFound();
            }
            if (sub === undefined) {
                return new Response(livePage({ stageBaseUrl: d.stageBaseUrl, preview: url.searchParams.get("preview") === "1" }), { headers: HTML_HEADERS });
            }
            if (sub === "state") return jsonRes(await liveState(d));
            if (sub === "ws") {
                if ((request.headers.get("upgrade") ?? "").toLowerCase() !== "websocket") {
                    return new Response("expected a websocket\n", { status: 426, headers: { "content-type": "text/plain" } });
                }
                return await d.room.connect(request);
            }
            return notFound();
        }

        if (path === "/store") {
            const s = await readSettings(d);
            if (s.store_open !== 1) return new Response(storeLockedPage(), { status: 404, headers: HTML_HEADERS });
            return new Response(storePage({ stageBaseUrl: d.stageBaseUrl, twitchClientId: d.twitch ? d.twitch.clientId : null }), { headers: HTML_HEADERS });
        }
        if (path.startsWith("/store/api/")) {
            const s = await readSettings(d);
            if (s.store_open !== 1) return jsonRes(err(404, "error.stage.store_locked"));
            const which = path.slice("/store/api/".length);
            if (which === "pool") return jsonRes(await storePool(d, url.searchParams));
            if (which === "rewards") return jsonRes(await storeRewards(d));
            if (which === "me") return jsonRes(await storeMe(d, request));
            return jsonRes(err(404, "error.stage.not_found"));
        }
        if (path === "/twitch/callback") return await twitchCallback(d, url);
        return notFound();
    } catch (e) {
        log(`${request.method} ${path} failed`, e);
        return new Response("try again\n", { status: 503, headers: { "content-type": "text/plain", "retry-after": "5", "cache-control": "no-store" } });
    }
}

async function liveState(d: StageDeps): Promise<StudioReply> {
    const s = await freshSettings(d);
    const room = await roomState(d);
    const now = d.now();
    return ok({
        stage: canvasSettings(d, s),
        pool: await poolItems(d, s),
        spotlight: spotlightView(room, now, s.spotlight_seconds),
        // not in 29.4: a page that connects mid-chaos catches up from here (29.6)
        chaos_until: room.chaos_until > now ? room.chaos_until : null,
        chaos_by: room.chaos_until > now ? room.chaos_by : null,
        now,
    });
}

async function storePool(d: StageDeps, q: URLSearchParams): Promise<StudioReply> {
    const raw = q.get("q") ?? "";
    if (raw.length > STORE_QUERY_MAX) return err(400, "error.stage.bad_request");
    const p = pageParams(q, 60, 40);
    if (!p) return err(400, "error.stage.bad_request");
    const s = await freshSettings(d);
    const needle = raw.trim().toLowerCase();
    let items = await poolItems(d, s);
    // a case-insensitive substring of the title, or an exact code
    if (needle) items = items.filter((i) => i.title.toLowerCase().includes(needle) || i.code.toLowerCase() === needle);
    const meta = await poolMeta(d, { kind: s.pool_kind, ref: s.pool_ref });
    const page = items.slice(p.offset, p.offset + p.limit);
    return ok({
        on_air: s.on_air === 1,
        pool_name: s.pool_kind === "library" ? "everything" : (meta.name ?? "nothing"),
        total: items.length,
        offset: p.offset,
        next: p.offset + p.limit < items.length ? p.offset + p.limit : null,
        items: page.map(storeItem),
    });
}

async function storeRewards(d: StageDeps): Promise<StudioReply> {
    const tw = d.twitch ? await readTwitch(d) : null;
    if (!tw) return ok({ channel: null, rewards: [] });
    const rewards = (await readRewards(d)).filter((r) => r.enabled === 1);
    return ok({
        channel: tw.login,
        rewards: rewards.map((r) => ({ action: r.action, title: r.title, cost: r.cost, cooldown_seconds: r.cooldown_seconds, prompt: r.prompt })),
    });
}

// The viewer's own token, checked with Twitch; nothing about the viewer is kept beyond the redemptions.
async function storeMe(d: StageDeps, request: Request): Promise<StudioReply> {
    if (!d.twitch) return err(404, "error.stage.off");
    const m = /^Bearer ([A-Za-z0-9]{10,200})$/.exec(request.headers.get("authorization") ?? "");
    if (!m) return err(401, "error.stage.twitch_auth");
    let who: { user_id: string; login: string; client_id: string };
    try {
        who = await clientOf(d)!.validate(m[1]!);
    } catch (e) {
        if (e instanceof TwitchError && (e.status === 401 || e.status === 400)) return err(401, "error.stage.twitch_auth");
        log("validating a viewer token failed", e);
        return err(503, "error.api.generic");
    }
    // a token for another app is not ours to read
    if (who.client_id !== d.twitch.clientId) return err(401, "error.stage.twitch_auth");
    const { results } = await d.db
        .prepare(
            "SELECT input, item_id, status, reason, created_at FROM stage_redemptions WHERE user_id = ?1 AND action = 'summon' ORDER BY created_at DESC, id DESC LIMIT 10",
        )
        .bind(who.user_id)
        .all<{ input: string; item_id: string | null; status: string; reason: string | null; created_at: number }>();
    const items = new Map((await canvasItems(d, [...new Set(results.map((r) => r.item_id).filter((x): x is string => !!x))])).map((i) => [i.id, i]));
    return ok({
        user: { id: who.user_id, login: who.login },
        summons: results.map((r) => ({
            item: r.item_id && items.has(r.item_id) ? storeItem(items.get(r.item_id)!) : null,
            input: r.input,
            status: r.status,
            reason: r.reason,
            created_at: r.created_at,
        })),
    });
}

// ---- Twitch OAuth return (29.8) ----------------------------------------------------------------------------------------------------

function callbackPage(ok: boolean, reason?: string): Response {
    const target = ok ? "cobalt-apple://stage?twitch=connected" : `cobalt-apple://stage?twitch=failed&reason=${encodeURIComponent(reason ?? "error")}`;
    const text = ok ? "twitch is connected. you can close this." : "twitch did not connect. you can close this.";
    const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>twitch</title>
<style>body{background:#000;color:#fff;font:16px/1.5 ui-monospace,Menlo,monospace;display:grid;place-items:center;min-height:100vh;margin:0;text-align:center}a{color:#2f8af9}</style>
</head><body><main><p>${text}</p><p><a href="${target}">back to the app</a></p></main>
<script>location.replace(${JSON.stringify(target)})</script></body></html>`;
    return new Response(html, { status: ok ? 200 : 400, headers: HTML_HEADERS });
}

async function twitchCallback(d: StageDeps, url: URL): Promise<Response> {
    const tc = clientOf(d);
    if (!tc || !d.twitch) return callbackPage(false, "off");
    const s = await readSettings(d);
    const state = url.searchParams.get("state") ?? "";
    const valid = !!s.oauth_state && !!state && sameSecret(state, s.oauth_state) && d.now() - (s.oauth_state_at ?? 0) <= OAUTH_STATE_TTL_MS;
    // single use: gone whatever happens next
    if (s.oauth_state) await writeSettings(d, { oauth_state: null, oauth_state_at: null });
    if (!valid) return callbackPage(false, "state");
    const code = url.searchParams.get("code");
    if (url.searchParams.has("error") || !code) return callbackPage(false, "denied");
    try {
        const t = await tc.exchangeCode(code, `${d.stageBaseUrl}twitch/callback`);
        if (!t.scope.includes(REWARD_SCOPE)) return callbackPage(false, "scope");
        const user = await tc.user(t.access_token);
        const before = await readTwitch(d);
        const secret = d.twitch.clientSecret;
        const now = d.now();
        // another channel than before: the old channel's subscription and rewards are not ours to keep
        if (before && before.broadcaster_id !== user.id) await disconnect(d, before).catch((e) => log("dropping the old channel failed", e));
        await d.db
            .prepare(
                `INSERT INTO stage_twitch (id, broadcaster_id, login, display_name, access_token, refresh_token, expires_at, scopes, eventsub_id, connected_at, last_event_at, status, status_at)
                 VALUES ('main', ?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, ?8, NULL, 'setting_up', ?8)
                 ON CONFLICT (id) DO UPDATE SET broadcaster_id = ?1, login = ?2, display_name = ?3, access_token = ?4, refresh_token = ?5,
                    expires_at = ?6, scopes = ?7, connected_at = ?8, status = 'setting_up', status_at = ?8`,
            )
            .bind(
                user.id,
                user.login,
                user.display_name,
                await encryptToken(secret, t.access_token),
                await encryptToken(secret, t.refresh_token),
                now + t.expires_in * 1000,
                t.scope.join(" "),
                now,
            )
            .run();
    } catch (e) {
        log("twitch connect failed", e);
        return callbackPage(false, e instanceof TwitchError && e.status !== 0 ? "exchange" : "error");
    }
    // rewards and the subscription are made after the answer; a failure is retried by the next GET /stage
    const work = background(d, syncTwitch(d));
    if (work) await work;
    return callbackPage(true);
}

// ---- EventSub webhook (29.9) ----------------------------------------------------------------------------------------------------------

type RedemptionEvent = {
    id: string;
    user_id: string;
    user_login: string;
    user_name: string;
    user_input?: string;
    reward: { id: string; title?: string; cost?: number };
    redeemed_at?: string;
};

async function eventSub(d: StageDeps, request: Request): Promise<Response> {
    if (!d.twitch) return notFound();
    const declared = request.headers.get("content-length");
    if (declared !== null && /^\d+$/.test(declared) && Number(declared) > WEBHOOK_BODY_MAX) return new Response(null, { status: 413 });
    const raw = await request.text();
    if (raw.length > WEBHOOK_BODY_MAX) return new Response(null, { status: 413 });
    const id = request.headers.get("twitch-eventsub-message-id");
    const ts = request.headers.get("twitch-eventsub-message-timestamp");
    const good = await verifyEventSub(d.twitch.eventsubSecret, id, ts, raw, request.headers.get("twitch-eventsub-message-signature"));
    if (!good) return new Response(null, { status: 403 });
    const sent = Date.parse(ts!);
    // older (or newer) than 10 minutes: a replay
    if (!Number.isFinite(sent) || Math.abs(d.now() - sent) > SEEN_TTL_MS) return new Response(null, { status: 403 });

    let body: { challenge?: unknown; event?: RedemptionEvent } | null = null;
    try {
        body = JSON.parse(raw);
    } catch {
        body = null;
    }
    const type = request.headers.get("twitch-eventsub-message-type");
    if (type === "webhook_callback_verification") {
        return typeof body?.challenge === "string"
            ? new Response(body.challenge, { status: 200, headers: { "content-type": "text/plain" } })
            : new Response(null, { status: 400 });
    }
    // Twitch redelivers: a message id seen in the last 10 minutes is answered and ignored
    await d.db.prepare("DELETE FROM stage_seen WHERE seen_at < ?1").bind(d.now() - SEEN_TTL_MS).run();
    const first = await d.db.prepare("INSERT OR IGNORE INTO stage_seen (id, seen_at) VALUES (?1, ?2)").bind(id, d.now()).run();
    if (Number(first.meta?.changes ?? 0) === 0) return new Response(null, { status: 204 });

    if (type === "revocation") {
        await d.db.prepare("UPDATE stage_twitch SET eventsub_id = NULL WHERE id = 'main'").run();
        log("eventsub subscription revoked");
        return new Response(null, { status: 204 });
    }
    if (type !== "notification" || !body?.event || typeof body.event.id !== "string" || typeof body.event.reward?.id !== "string") {
        return new Response(null, { status: 204 });
    }
    const reward = await d.db.prepare("SELECT * FROM stage_rewards WHERE twitch_reward_id = ?1").bind(body.event.reward.id).first<RewardRow>();
    // some other reward on the channel
    if (!reward) return new Response(null, { status: 204 });
    // Twitch wants an answer within a few seconds: 204 now, the rest after
    const work = background(d, redeem(d, body.event, reward));
    if (work) await work;
    return new Response(null, { status: 204 });
}

// ---- redemptions (29.9) ------------------------------------------------------------------------------------------------------------------

const wordsOf = (s: string) => s.replace(/\s+/g, " ").trim();

// A summon's input to one pool item: a 3-4 char code, else the meaning search over the pool (the best pool
// post, then its first public file), else a title substring. null = nothing matched.
export async function findSummon(d: StageDeps, s: SettingsRow, input: string): Promise<Item | null> {
    const words = wordsOf(input).slice(0, INPUT_MAX);
    if (!words) return null;
    const pool = await poolItems(d, s);
    if (pool.length === 0) return null;
    const byId = new Map(pool.map((i) => [i.id, i]));

    if (/^[A-Za-z0-9]{3,4}$/.test(words)) {
        const k = await d.db.prepare("SELECT item_id FROM stage_codes WHERE code = ?1").bind(words.toUpperCase()).first<{ item_id: string }>();
        const hit = k ? byId.get(k.item_id) : undefined;
        if (hit) return hit;
    }

    if (d.embed) {
        const found = await searchPosts({ db: d.db, client: d.embed, mediaBaseUrl: d.mediaBaseUrl }, words, SEARCH_POOL_POSTS);
        if (found.ok && found.hits.length > 0) {
            const { results } = await d.db
                .prepare(
                    `SELECT m.id AS id, m.item_index AS item_index, m.created_at AS created_at, ${POST_KEY_SQL} AS post_key
                       FROM json_each(?1) j JOIN media_items m ON m.id = j.value`,
                )
                .bind(JSON.stringify(pool.map((i) => i.id)))
                .all<{ id: string; item_index: number | null; created_at: number; post_key: string }>();
            const byPost = new Map<string, typeof results>();
            for (const r of results) byPost.set(r.post_key, [...(byPost.get(r.post_key) ?? []), r]);
            for (const h of found.hits) {
                if (h.score < SEARCH_MIN_SCORE) break;
                const files = (byPost.get(h.post_key) ?? []).sort(
                    (a, b) => (a.item_index ?? 0) - (b.item_index ?? 0) || a.created_at - b.created_at || (a.id < b.id ? -1 : 1),
                );
                const first = files.find((f) => byId.has(f.id));
                if (first) return byId.get(first.id)!;
            }
        }
    }

    const needle = words.toLowerCase();
    return pool.find((i) => i.title.toLowerCase().includes(needle)) ?? null;
}

async function redeem(d: StageDeps, ev: RedemptionEvent, reward: RewardRow): Promise<void> {
    const tc = clientOf(d);
    const known = await d.db.prepare("SELECT 1 AS x FROM stage_redemptions WHERE id = ?1").bind(ev.id).first();
    if (known) return;
    const now = d.now();
    const by = (ev.user_name || ev.user_login || "someone").slice(0, 60);
    const input = wordsOf(ev.user_input ?? "").slice(0, INPUT_MAX);
    const cost = typeof ev.reward.cost === "number" ? ev.reward.cost : reward.cost;
    await d.db.prepare("UPDATE stage_twitch SET last_event_at = ?1 WHERE id = 'main'").bind(now).run().catch(() => undefined);

    let status: "done" | "refunded" | "failed" = "done";
    let reason: string | null = null;
    let itemId: string | null = null;
    try {
        const s = await freshSettings(d);
        if (s.on_air !== 1) {
            status = "refunded";
            reason = "off_air";
        } else if (reward.enabled !== 1) {
            status = "refunded";
            reason = "disabled";
        } else if (reward.action === "summon") {
            const item = await findSummon(d, s, input);
            if (!item) {
                status = "refunded";
                reason = "no_match";
                await broadcast(d, {
                    type: "toast",
                    toast: { by, action: "summon", cost: 0, detail: `nothing matched "${input}", points refunded`, refunded: true },
                });
            } else {
                itemId = item.id;
                await broadcast(d, {
                    type: "summon",
                    spotlight: { item, by, action: "summon", pinned_until: null, at: now },
                    toast: { by, action: "summon", cost, detail: `"${input}" → ${item.title}` },
                });
            }
        } else if (reward.action === "chaos") {
            const until = nextChaosUntil(now, (await roomState(d)).chaos_until);
            const secs = Math.round((until - now) / 1000);
            await broadcast(d, { type: "chaos", until, toast: { by, action: "chaos", cost, detail: `100 things on screen for ${secs} seconds` } });
        } else if (reward.action === "shuffle") {
            await broadcast(d, { type: "shuffle", toast: { by, action: "shuffle", cost, detail: "wiped the canvas and refilled it" } });
        } else {
            await broadcast(d, {
                type: "pin",
                pinned_until: now + PIN_MS,
                toast: { by, action: "pin", cost, detail: "the spotlight stays up for 2 more minutes" },
            });
        }
    } catch (e) {
        log("redemption failed", e);
        status = "failed";
        reason = "error";
    }

    // fulfil or refund on Twitch; a Helix failure leaves it in Twitch's queue (the owner can refund there)
    let settled = false;
    if (tc) {
        try {
            await asBroadcaster(d, tc, (t, b) => tc.setRedemption(t, b, reward.twitch_reward_id!, ev.id, status === "done" ? "FULFILLED" : "CANCELED"));
            settled = true;
        } catch (e) {
            log("settling the redemption failed", e);
        }
    }
    if (!settled) {
        status = "failed";
        reason = "error";
    }
    await d.db
        .prepare(
            "INSERT OR IGNORE INTO stage_redemptions (id, action, user_id, user_login, user_name, input, item_id, status, reason, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        )
        .bind(ev.id, reward.action, ev.user_id ?? "", ev.user_login ?? "", by, input, itemId, status, reason, now)
        .run();
}

// ---- retention -------------------------------------------------------------------------------------------------------------------------------

// The daily cron: redemptions older than 30 days, and EventSub message ids past their 10 minutes.
export async function stageRetention(db: D1Database, now: number): Promise<{ redemptions: number; seen: number }> {
    const a = await db.prepare("DELETE FROM stage_redemptions WHERE created_at < ?1").bind(now - REDEMPTION_KEEP_MS).run();
    const b = await db.prepare("DELETE FROM stage_seen WHERE seen_at < ?1").bind(now - SEEN_TTL_MS).run();
    return { redemptions: Number(a.meta?.changes ?? 0), seen: Number(b.meta?.changes ?? 0) };
}

// ---- types the room and the pages share ------------------------------------------------------------------------------------------------------

export type Spotlight = { item: Item; by: string | null; action: "summon" | "owner"; pinned_until: number | null; at: number };
