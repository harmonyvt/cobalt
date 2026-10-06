// The server's line (APP-API-CONTRACT.md section 17): what waits for the helper, in order.
// Free of Cloudflare imports so it runs under plain node in the tests.
//
// The helper does one save, probe, encode or poster at a time and there is exactly one Durable
// Object, so that one object can hold one honest line for every client. The line lives in the
// Durable Object's storage under `line:<class>:<seq>`; the rows a queued job creates are the
// ordinary `studio_sessions` / `studio_renders` rows. Durable Object `list()` returns keys in
// ascending UTF-8 order, so `list({prefix: "line:"})` IS the order: class `0` (a render the owner
// asked for from the screen, `priority: "focused"`) first, then everything else, each in first in
// first out by the zero-padded sequence number kept under `lineseq` (not under the prefix).

import type { KV, WebpParams } from "./webp";

export const LINE_MAX = 50;
// An entry waits at most this long (20 links at about 45 s each, twice over), then it ends with
// the usual busy failure.
export const LINE_WAIT_MS = 30 * 60 * 1000;
// A started save whose helper start keeps meeting a foreign 429 keeps trying this long (a save that
// never waited keeps BUSY_WAIT_MS).
export const LINE_BUSY_WAIT_MS = 10 * 60 * 1000;
// A render entry whose upload into the helper began this long ago and has no live call behind it
// (the Durable Object was evicted mid-upload) is started again. = SWEEP_RENDER_MS (studio.ts).
export const LINE_START_STALE_MS = 6 * 60 * 1000;

const PREFIX = "line:";
const SEQ_KEY = "lineseq";
const SEQ_DIGITS = 12;

// What a queued slideshow job (APP-API-CONTRACT.md section 18.5) carries: the validated plan with its
// inputs resolved (the stored originals) and the frame the Durable Object decided.
export type SlideshowInput = {
    // the input slot in the helper (`PUT /slideshow/<job>/inputs/<n>`), 0-19
    n: number;
    // media_items.item_index of the chosen item
    index: number;
    itemId: string;
    r2Key: string;
    type: "photo" | "video" | "gif";
    // a still's seconds; null = the item's own length (a video or a gif)
    seconds: number | null;
};
export type SlideshowRun = {
    width: number;
    height: number;
    fade: boolean;
    sound: "none" | "own";
    inputs: SlideshowInput[];
    // 18.10: the webp slideshow (absent = mp4); `quality` only with it, the frame's `width` is the webp's
    format?: "mp4" | "webp";
    quality?: "low" | "med" | "high";
};

// What a queued gallery image (18.11) carries: the layout and the chosen photos in the order they are drawn
// (`seconds` is always null: a photo has none).
export type GalleryRun = {
    layout: "strip" | "grid2" | "grid3" | "row";
    inputs: SlideshowInput[];
};

export type LineEntry = {
    // "slideshow" (section 18.5) and "gallery_image" (18.11) behave as a render everywhere they are observed from
    // outside (`GET /studio/line` reports them as one): only the Durable Object tells them apart
    kind: "save" | "render" | "slideshow" | "gallery_image";
    // the studio session (a queued save's row exists, status 'saving')
    sid: string;
    // render: the job id, minted at enqueue (webp.ts `mintId`, 20 base62)
    job: string | null;
    // who asked: api_keys.id of the key that created the session
    keyId: string;
    // enqueued, ms
    at: number;
    origin: "share" | null;
    // a save that is an adopted upload: it starts in phase "probing"
    adopt: boolean;
    // `r2Key` / `itemId`: a render of one item of a gallery (18.13) reads that item, not the session's lead
    render: { params: WebpParams; effectiveWidth: number; quality: string; start: number; length: number; r2Key?: string; itemId?: string } | null;
    // slideshow: what to run
    slideshow?: SlideshowRun | null;
    // gallery image: what to run
    gallery?: GalleryRun | null;
    // a save of a post's items (section 18.2): which, and how many the client saw; `retry` = the session
    // is ready already and only these indices are fetched again (18.2 `items/retry`)
    items?: ItemsChoice;
    itemCount?: number;
    retry?: boolean;
    // a render whose upload into the helper began at this time
    starting: number | null;
    // starts that met a foreign 429
    attempts: number;
};

// `items` of POST /studio (section 18.2)
export type ItemsChoice = "all" | "first-video" | number[];

export const classOf = (focused: boolean): "0" | "1" => (focused ? "0" : "1");

// `line:<class>:<seq>`; the class is the first character after the prefix.
export const lineKey = (cls: "0" | "1", seq: number): string => `${PREFIX}${cls}:${String(seq).padStart(SEQ_DIGITS, "0")}`;
export const isFocusedKey = (key: string): boolean => key.startsWith(`${PREFIX}0:`);

// Whether an entry's upload into the helper is (presumably) still going on.
export const startingFresh = (e: LineEntry, now: number): boolean =>
    e.starting !== null && now - e.starting < LINE_START_STALE_MS;

// Boolean flag from a body field: absent, null and false are "no", true is "yes", anything else
// is not a boolean (null result = invalid).
export function parseFlag(v: unknown): boolean | null {
    if (v === undefined || v === null) return false;
    return typeof v === "boolean" ? v : null;
}

// Boolean flag from a query value (`?queue=1`): absent or empty is "no", 1/true "yes", 0/false "no".
export function parseQueryFlag(raw: string | null): boolean | null {
    if (raw === null || raw === "") return false;
    if (raw === "1" || raw === "true") return true;
    if (raw === "0" || raw === "false") return false;
    return null;
}

export class LineStore {
    // enqueue() is read-count-then-write: two of them must never interleave.
    private chain: Promise<unknown> = Promise.resolve();

    constructor(
        private storage: KV,
        private now: () => number,
    ) {}

    // Every entry, in line order. (The Durable Object already lists in key order; sorting here is
    // a no-op there and keeps a map that lists in insertion order honest.)
    async list(): Promise<Array<{ key: string; entry: LineEntry }>> {
        const all = await this.storage.list<LineEntry>({ prefix: PREFIX });
        return [...all]
            .filter(([, e]) => !!e)
            .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
            .map(([key, entry]) => ({ key, entry }));
    }

    async size(): Promise<number> {
        return (await this.storage.list<LineEntry>({ prefix: PREFIX })).size;
    }

    // Adds an entry at the end of its class. Full (LINE_MAX entries, all keys): `{full: true}` and
    // nothing is written.
    enqueue(e: Omit<LineEntry, "starting" | "attempts">, focused: boolean): Promise<{ key: string } | { full: true }> {
        const run = async (): Promise<{ key: string } | { full: true }> => {
            if ((await this.size()) >= LINE_MAX) return { full: true };
            const last = await this.storage.get<number>(SEQ_KEY);
            const seq = (typeof last === "number" ? last : 0) + 1;
            await this.storage.put(SEQ_KEY, seq);
            const key = lineKey(classOf(focused), seq);
            await this.storage.put(key, { ...e, starting: null, attempts: 0 } satisfies LineEntry);
            return { key };
        };
        const p = this.chain.then(run, run);
        this.chain = p.catch(() => {});
        return p;
    }

    // The first entry of a session's save (job omitted or null) or of one render job.
    async find(sid: string, job?: string | null): Promise<{ key: string; entry: LineEntry; index: number } | null> {
        const all = await this.list();
        for (let index = 0; index < all.length; index++) {
            const { key, entry } = all[index]!;
            if (entry.sid !== sid) continue;
            if (job ? entry.kind !== "save" && entry.job === job : entry.kind === "save") return { key, entry, index };
        }
        return null;
    }

    async remove(key: string): Promise<void> {
        await this.storage.delete(key);
    }

    async put(key: string, e: LineEntry): Promise<void> {
        await this.storage.put(key, e);
    }
}
