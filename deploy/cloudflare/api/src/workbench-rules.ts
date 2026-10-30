// The chat's workbench (APP-API-CONTRACT.md section 33.11): the pure parts, free of Cloudflare imports so the tests run them
// under node. The outbound rule every request from the box passes (the section 19.2 rule, plus our own hosts), the type
// of a file the box hands to the library (by its bytes), the 8 KB output clip, and the daily ledger of awake minutes.

// ---- switches ---------------------------------------------------------------------------------------------------------

export type WorkbenchSwitches = { WORKBENCH?: unknown; WORKBENCH_DAILY_MINUTES?: string };

export const DEFAULT_DAILY_MINUTES = 60;

// Awake minutes a day (WORKBENCH_DAILY_MINUTES, default 60). "0" turns the box off.
export function dailyMinutes(env: WorkbenchSwitches): number {
    const raw = (env.WORKBENCH_DAILY_MINUTES ?? "").trim();
    if (raw === "") return DEFAULT_DAILY_MINUTES;
    const n = Number(raw);
    return Number.isFinite(n) && n >= 0 ? Math.floor(n) : DEFAULT_DAILY_MINUTES;
}

// The model is offered cobalt.box.* only while the binding is there and the cap is above zero.
export const workbenchOn = (env: WorkbenchSwitches): boolean => !!env.WORKBENCH && dailyMinutes(env) > 0;

// ---- the outbound rule ------------------------------------------------------------------------------------------------

function v4Parts(s: string): number[] | null {
    const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s);
    if (!m) return null;
    const p = m.slice(1).map(Number);
    return p.every((n) => n <= 255) ? p : null;
}

// helper/lib.js publicV4, copied (the helper is node code; this runs in the Worker)
function publicV4([a, b, c]: number[]): boolean {
    if (a === 0 || a === 10 || a === 127) return false;
    if (a === 100 && b! >= 64 && b! <= 127) return false;
    if (a === 169 && b === 254) return false;
    if (a === 172 && b! >= 16 && b! <= 31) return false;
    if (a === 192 && b === 0 && c === 0) return false;
    if (a === 192 && b === 0 && c === 2) return false;
    if (a === 192 && b === 88 && c === 99) return false;
    if (a === 192 && b === 168) return false;
    if (a === 198 && (b === 18 || b === 19)) return false;
    if (a === 198 && b === 51 && c === 100) return false;
    if (a === 203 && b === 0 && c === 113) return false;
    if (a! >= 224) return false;
    return true;
}

function v6Groups(ip: string): number[] | null {
    let s = ip;
    const tail = /(\d{1,3}(?:\.\d{1,3}){3})$/.exec(s);
    if (tail) {
        const q = v4Parts(tail[1]!);
        if (!q) return null;
        s = s.slice(0, s.length - tail[1]!.length) + ((q[0]! << 8) | q[1]!).toString(16) + ":" + ((q[2]! << 8) | q[3]!).toString(16);
    }
    const halves = s.split("::");
    if (halves.length > 2) return null;
    const head = halves[0] ? halves[0].split(":") : [];
    const rest = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
    const missing = 8 - head.length - rest.length;
    if (halves.length === 1 ? missing !== 0 : missing < 1) return null;
    const all = [...head, ...(halves.length === 2 ? Array(missing).fill("0") : []), ...rest];
    if (all.length !== 8) return null;
    const g = all.map((h) => (/^[0-9a-f]{1,4}$/.test(h) ? parseInt(h, 16) : NaN));
    return g.some(Number.isNaN) ? null : g;
}

const quad = (hi: number, lo: number) => [hi >> 8, hi & 255, lo >> 8, lo & 255];

const isV6Literal = (s: string) => s.includes(":");

// Whether an IP literal is a public, globally routable unicast address (helper/lib.js isPublicIp, the same tables).
export function isPublicIp(ip: string): boolean {
    let s = String(ip).trim().toLowerCase();
    if (s.startsWith("[") && s.endsWith("]")) s = s.slice(1, -1);
    s = s.replace(/%.*$/, "");
    const v4 = v4Parts(s);
    if (v4) return publicV4(v4);
    if (!isV6Literal(s)) return false;
    const g = v6Groups(s);
    if (!g) return false;
    const [g0, g1, g2, g3, g4, g5, g6, g7] = g as [number, number, number, number, number, number, number, number];
    if (g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0 && (g5 === 0xffff || g5 === 0)) return publicV4(quad(g6, g7));
    if (g0 === 0x64 && g1 === 0xff9b && g2 === 0 && g3 === 0 && g4 === 0 && g5 === 0) return publicV4(quad(g6, g7));
    if (g0 === 0x2002) return publicV4(quad(g1, g2));
    if ((g0 & 0xe000) !== 0x2000) return false;
    if (g0 === 0x2001 && g1 === 0) return false;
    if (g0 === 0x2001 && g1 === 0xdb8) return false;
    if (g0 === 0x2001 && (g1 & 0xfff0) === 0x10) return false;
    if (g0 === 0x3fff && g1 <= 0x0fff) return false;
    return true;
}

const PRIVATE_HOST = /(^|\.)(localhost|local|internal|localdomain|home\.arpa|intranet|lan|corp)$/i;

// Our own hosts: the API Worker (api, share, studio), the web app, anything else on the zone. The public media host is
// the one exception: its files are public anyway, and the box may want to work on one of Harmony's own public files.
const OWN_ZONE = "capybaraharmony.com";
const OWN_ZONE_ALLOWED = new Set(["media.capybaraharmony.com"]);
// Other people's Workers and Pages are fine in principle, but nothing the box needs lives there, and they are the easy
// way back into Cloudflare's own network: refused.
const WORKER_HOSTS = /(^|\.)(workers\.dev|pages\.dev)$/i;

export type OutboundDecision = { ok: true; url: URL } | { ok: false; reason: string };

// The rule for every request the box makes (the Worker sees each one through the platform's outbound interception).
// http or https, no credentials, port 80 or 443, a public IP literal or a dotted name that is not a private spelling,
// not our own zone and not a Workers host. Names are resolved by the Worker's own fetch on Cloudflare's network, which
// cannot reach private addresses; the address check here covers literals.
export function checkOutbound(raw: string): OutboundDecision {
    let u: URL;
    try {
        u = new URL(raw);
    } catch {
        return { ok: false, reason: "not a url" };
    }
    if (u.protocol !== "http:" && u.protocol !== "https:") return { ok: false, reason: `${u.protocol} is not allowed` };
    if (u.username || u.password) return { ok: false, reason: "credentials in the url" };
    const port = u.port ? Number(u.port) : u.protocol === "https:" ? 443 : 80;
    if (port !== 80 && port !== 443) return { ok: false, reason: `port ${port} is not allowed` };
    const host = u.hostname.replace(/\.$/, "").toLowerCase();
    if (!host) return { ok: false, reason: "no host" };
    const bare = host.startsWith("[") ? host.slice(1, -1) : host;
    if (v4Parts(bare) || isV6Literal(bare)) {
        return isPublicIp(bare) ? { ok: true, url: u } : { ok: false, reason: `${bare} is not a public address` };
    }
    if (!host.includes(".") || PRIVATE_HOST.test(host)) return { ok: false, reason: `${host} is a private name` };
    if ((host === OWN_ZONE || host.endsWith(`.${OWN_ZONE}`)) && !OWN_ZONE_ALLOWED.has(host)) {
        return { ok: false, reason: `${host} is capystore's own server` };
    }
    if (WORKER_HOSTS.test(host)) return { ok: false, reason: `${host} is a Workers host` };
    return { ok: true, url: u };
}

// The outbound handler's answer: the request goes out with redirects left to the box (so every hop comes back through
// this rule), or a 403 the tool in the box prints.
// A request body the box may send out (33.11.1): enough for a site's own API calls (a login form, a GraphQL query), never
// a library file box.pull copied in.
export const OUTBOUND_BODY_MAX = 64 * 1024;

const blocked = (reason: string) =>
    new Response(`workbench: blocked (${reason})\n`, { status: 403, headers: { "content-type": "text/plain", "x-workbench-blocked": "1" } });

// The body, read up to the cap: null when it is over (the rest is not read).
async function boundedBody(request: Request): Promise<Uint8Array | null> {
    const declared = Number(request.headers.get("content-length") ?? "");
    if (Number.isFinite(declared) && declared > OUTBOUND_BODY_MAX) {
        await request.body?.cancel().catch(() => {});
        return null;
    }
    const reader = request.body!.getReader();
    const chunks: Uint8Array[] = [];
    let n = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        n += value.length;
        if (n > OUTBOUND_BODY_MAX) {
            await reader.cancel().catch(() => {});
            return null;
        }
        chunks.push(value);
    }
    const out = new Uint8Array(n);
    let off = 0;
    for (const c of chunks) {
        out.set(c, off);
        off += c.length;
    }
    return out;
}

export async function forwardOutbound(request: Request, doFetch: (r: Request) => Promise<Response>): Promise<Response> {
    const d = checkOutbound(request.url);
    if (!d.ok) return blocked(d.reason);
    if (!request.body) return doFetch(new Request(request, { redirect: "manual" }));
    const body = await boundedBody(request);
    if (!body) return blocked(`a request body over ${OUTBOUND_BODY_MAX / 1024} KB`);
    return doFetch(new Request(request.url, { method: request.method, headers: request.headers, body, redirect: "manual" }));
}

// ---- what box.save hands to the library -------------------------------------------------------------------------------

// The upload path's types (app-routes.ts UPLOAD_TYPES), read from the file's first bytes (the helper's sniffType and
// sniffVideo, section 19.1.3). A webm or mkv, audio, html, anything else: null.
const HEIF_BRANDS = new Set(["heic", "heix", "hevc", "mif1", "msf1"]);
const MP4_BRANDS = new Set([
    "isom", "iso2", "iso3", "iso4", "iso5", "iso6", "mp41", "mp42", "mp71", "avc1", "dash", "MSNV", "mmp4",
    "3gp4", "3gp5", "3gp6", "3gp7", "3ge6", "3ge7", "3gg6", "3g2a", "3g2b", "3g2c", "XAVC", "f4v ", "cmfc",
    "M4V ", "M4VH", "M4VP",
]);

export type SniffedSave = { contentType: string; ext: string };

export function sniffSave(head: Uint8Array): SniffedSave | null {
    const n = head.length;
    const ascii = (a: number, b: number) => String.fromCharCode(...head.subarray(a, Math.min(b, n)));
    if (n >= 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) return { contentType: "image/jpeg", ext: "jpg" };
    if (n >= 8 && [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].every((v, i) => head[i] === v)) return { contentType: "image/png", ext: "png" };
    if (n >= 12 && ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP") return { contentType: "image/webp", ext: "webp" };
    if (n >= 6 && (ascii(0, 6) === "GIF87a" || ascii(0, 6) === "GIF89a")) return { contentType: "image/gif", ext: "gif" };
    if (n >= 12 && ascii(4, 8) === "ftyp") {
        const brand = ascii(8, 12);
        if (HEIF_BRANDS.has(brand)) return { contentType: "image/heic", ext: "heic" };
        if (brand === "qt  ") return { contentType: "video/quicktime", ext: "mov" };
        if (MP4_BRANDS.has(brand)) return { contentType: "video/mp4", ext: "mp4" };
    }
    return null;
}

// ---- the 8 KB clip of a command's output ------------------------------------------------------------------------------

export const OUTPUT_MAX = 8192;
const CLIP_HEAD = 2048;

// Keeps the first 2 KB and the last 6 KB of a stream (the start says what ran, the end says how it ended), counting the
// rest. `text()` is what the model reads.
export class Clip {
    #head: number[] = [];
    #tail: Uint8Array = new Uint8Array(0);
    total = 0;

    push(chunk: Uint8Array): void {
        this.total += chunk.byteLength;
        let rest = chunk;
        if (this.#head.length < CLIP_HEAD) {
            const take = Math.min(CLIP_HEAD - this.#head.length, rest.byteLength);
            for (let i = 0; i < take; i++) this.#head.push(rest[i]!);
            rest = rest.subarray(take);
        }
        if (rest.byteLength === 0) return;
        const keep = OUTPUT_MAX - CLIP_HEAD;
        const joined = new Uint8Array(Math.min(keep, this.#tail.byteLength + rest.byteLength));
        const fromTail = joined.byteLength - Math.min(rest.byteLength, joined.byteLength);
        joined.set(this.#tail.subarray(this.#tail.byteLength - fromTail), 0);
        joined.set(rest.subarray(rest.byteLength - (joined.byteLength - fromTail)), fromTail);
        this.#tail = joined;
    }

    text(): string {
        const dec = new TextDecoder();
        const head = dec.decode(new Uint8Array(this.#head));
        const kept = this.#head.length + this.#tail.byteLength;
        if (kept >= this.total) return head + dec.decode(this.#tail);
        return `${head}\n… (${this.total - kept} bytes cut) …\n${dec.decode(this.#tail)}`;
    }
}

// ---- the daily ledger of awake time -----------------------------------------------------------------------------------

// Kept in the Workbench Durable Object's storage. One box, so one ledger: `used_ms` is today's closed awake time,
// `awake_since` is set while a container runs, `last_active` is the last call's end (the box sleeps SLEEP_MS after it).
export type Ledger = { day: string; used_ms: number; awake_since: number | null; last_active: number | null; owner: string | null };

export const SLEEP_MS = 2 * 60_000;

export const dayOf = (ms: number) => new Date(ms).toISOString().slice(0, 10);
const dayStart = (day: string) => Date.parse(`${day}T00:00:00.000Z`);

export const emptyLedger = (now: number): Ledger => ({ day: dayOf(now), used_ms: 0, awake_since: null, last_active: null, owner: null });

// A new UTC day starts from zero (an awake stretch that crosses midnight counts from midnight).
export function rollDay(l: Ledger, now: number): Ledger {
    const day = dayOf(now);
    if (l.day === day) return l;
    return { ...l, day, used_ms: 0, awake_since: l.awake_since === null ? null : Math.max(l.awake_since, dayStart(day)) };
}

// Awake time so far today, the running stretch included.
export function usedMs(l: Ledger, now: number): number {
    const r = rollDay(l, now);
    return r.used_ms + (r.awake_since === null ? 0 : Math.max(0, now - r.awake_since));
}

// The container started.
export function markAwake(l: Ledger, now: number, owner: string): Ledger {
    const r = rollDay(l, now);
    return { ...r, awake_since: r.awake_since ?? now, last_active: now, owner };
}

export function markActive(l: Ledger, now: number): Ledger {
    return { ...rollDay(l, now), last_active: now };
}

// The container stopped (slept, was wiped or crashed). A stop the object only learns about later is charged up to
// last_active plus the sleep time, never past `now`.
export function markAsleep(l: Ledger, now: number): Ledger {
    const r = rollDay(l, now);
    if (r.awake_since === null) return { ...r, owner: null };
    const end = Math.min(now, (r.last_active ?? now) + SLEEP_MS);
    return { ...r, used_ms: r.used_ms + Math.max(0, end - r.awake_since), awake_since: null, owner: null };
}
