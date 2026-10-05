// A database shaped like production on 2026-10-05 (apple/CONTRACT-VISIBILITY.md section 0.4), for the
// visibility tests: 57 originals (53 saved + 4 uploads; every one with a poster), 6 host copies
// matched to exactly one original each (5 saved links, 1 upload through its `upload:<id>` session),
// 29 webps (27 studio renders + 2 /webp jobs), so 92 live rows, 59 posts' worth of grouping, and the
// objects behind every row in the fake buckets. Nothing is migrated: `visibility` and the other 0008
// columns are NULL, which is what the data step finds.
import { SESSION_TTL_MS } from "../src/studio";
import { KEY_ID, LINK, MEDIA_BASE, type World } from "./poster-world";

export type Pair = {
    host: string; // the old host row id
    orig: string; // the original's row id
    key: string; // the public object key
    url: string;
    sid: string;
    source: "saved" | "upload";
    bytes: number;
};

const mk = (prefix: string, k: number) => `${prefix}${String(k).padStart(16 - prefix.length, "0")}`;
const POSTER = (n: number) => `${MEDIA_BASE}Poster${String(n).padStart(4, "0")}.jpg`;

export function seedProduction(w: World) {
    const T = w.clock.t - 90 * 24 * 3_600_000; // saved long ago: sessions expired, rows live on
    const exec = (sql: string, ...p: any[]) => w.db.raw.prepare(sql).run(...p);
    const insertRow = (r: Record<string, unknown>) =>
        exec(
            "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, deleted_at, poster) VALUES (@id,@kind,@source,@bucket,@r2_key,@url,@name,@content_type,@bytes,@width,@height,@duration,@link,@session_id,@key_id,@created_at,@deleted_at,@poster)",
            {
                url: null,
                content_type: "video/mp4",
                width: 720,
                height: 1280,
                duration: 9.5,
                link: null,
                session_id: null,
                key_id: KEY_ID,
                deleted_at: null,
                poster: null,
                ...r,
            },
        );
    const poster = (n: number) => {
        w.media.objects.set(`Poster${String(n).padStart(4, "0")}.jpg`, { bytes: 3, meta: { poster: "1" }, data: new Uint8Array(3), viaStream: false });
        return POSTER(n);
    };
    const obj = (key: string, bytes: number, bucket: "media" | "originals") => {
        const data = new Uint8Array(bytes).fill(bytes % 251);
        if (bucket === "originals") w.originals.objects.set(key, { bytes: data, contentType: "video/mp4", meta: {} });
        else w.media.objects.set(key, { bytes, meta: {}, data, viaStream: true });
    };

    const pairs: Pair[] = [];
    const privates: string[] = [];
    const webps: string[] = [];
    let n = 0;
    let posterN = 0;

    // 6 pairs: 5 saved links, 1 upload (the session of an upload links `upload:<item id>`)
    for (let k = 0; k < 6; k++) {
        n++;
        const upload = k === 3;
        const sid = `Sess${String(k).padStart(2, "0")}`.padEnd(22, "S");
        const orig = mk("Orig", k);
        const host = mk("Host", k);
        const bytes = 1000 + k * 111;
        const r2 = upload ? `uploads/${orig}.mp4` : `originals/${sid}.mp4`;
        const key = `Pub${k}Mirror`.padEnd(10, "x").slice(0, 10) + ".mp4";
        const url = `${MEDIA_BASE}${key}`;
        const p = poster(++posterN);
        const title = `Clip number ${k}`;
        exec(
            "INSERT INTO studio_sessions (id, key_id, link, service, title, status, r2_key, content_type, bytes, duration, width, height, created_at, expires_at, poster) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            sid, KEY_ID, upload ? `upload:${orig}` : `${LINK}${k}`, upload ? "upload" : "x", title, "ready", r2, "video/mp4", bytes, 9.5, 720, 1280, T + n * 1000, T + n * 1000 + SESSION_TTL_MS, p,
        );
        insertRow({
            id: orig, kind: "private", source: upload ? "upload" : "saved", bucket: "originals", r2_key: r2,
            name: upload ? "holiday.mp4" : title, bytes, link: upload ? null : `${LINK}${k}`, session_id: upload ? null : sid,
            created_at: T + n * 1000, poster: p,
        });
        insertRow({
            id: host, kind: "public", source: "host", bucket: "media", r2_key: key, url,
            name: upload ? "holiday.mp4" : `${title}.mp4`, bytes, link: upload ? null : `${LINK}${k}`, session_id: sid,
            created_at: T + n * 1000 + 500, poster: p,
        });
        obj(r2, bytes, "originals");
        obj(key, bytes, "media");
        pairs.push({ host, orig, key, url, sid, source: upload ? "upload" : "saved", bytes });
    }

    // 51 private-only originals (saved links and uploads), each with a poster
    for (let k = 0; k < 51; k++) {
        n++;
        const orig = mk("Priv", k);
        const upload = k % 13 === 0;
        const r2 = upload ? `uploads/${orig}.mp4` : `originals/${`PrivSess${k}`.padEnd(22, "P")}.mp4`;
        const bytes = 500 + k;
        insertRow({
            id: orig, kind: "private", source: upload ? "upload" : "saved", bucket: "originals", r2_key: r2,
            name: `private ${k}`, bytes, link: upload ? null : `${LINK}p${k}`, session_id: upload ? null : `PrivSess${k}`.padEnd(22, "P"),
            created_at: T + n * 1000, poster: poster(++posterN),
        });
        obj(r2, bytes, "originals");
        privates.push(orig);
    }

    // 29 webps: 27 studio renders and 2 /webp jobs (public objects, no private copy)
    for (let k = 0; k < 29; k++) {
        n++;
        const id = mk("Webp", k);
        const key = `Webp${String(k).padStart(2, "0")}Name`.slice(0, 10) + ".webp";
        const bytes = 200 + k;
        insertRow({
            id, kind: "public", source: k < 27 ? "studio" : "webp", bucket: "media", r2_key: key, url: `${MEDIA_BASE}${key}`,
            name: `render ${k}.webp`, content_type: "image/webp", bytes, width: 480, height: 854, duration: 5,
            link: `${LINK}w${k}`, session_id: null, created_at: T + n * 1000,
        });
        obj(key, bytes, "media");
        webps.push(id);
    }
    return { pairs, privates, webps, T };
}

// Every live row, as a plain object (to compare before and after).
export const liveRows = (w: World) => w.db.raw.prepare("SELECT * FROM media_items WHERE deleted_at IS NULL ORDER BY created_at, id").all() as any[];
export const allRows = (w: World) => w.db.raw.prepare("SELECT * FROM media_items ORDER BY created_at, id").all() as any[];

// ---- helpers shared by the visibility tests -------------------------------------------------------

import { vi } from "vitest";
import { expect } from "vitest";
import { auth } from "./poster-world";

export const migrate = async (w: World, q = "dry_run=1&limit=100", headers: Record<string, string> = auth) => {
    const res = await w.call(`/library/visibility/migrate?${q}`, { method: "POST", headers });
    return { status: res.status, body: (await res.json()) as any };
};

export const listAll = async (w: World, q = "") => {
    const posts: any[] = [];
    let cursor: string | null = null;
    let last: any = null;
    for (let i = 0; i < 20; i++) {
        const res: Response = await w.call(`/library?limit=50${q ? `&${q}` : ""}${cursor ? `&cursor=${cursor}` : ""}`, { headers: auth });
        expect(res.status).toBe(200);
        last = (await res.json()) as any;
        posts.push(...last.posts);
        cursor = last.next;
        if (!cursor) break;
    }
    return { posts, counts: last.counts, usage: last.usage, files: posts.flatMap((p) => p.files) as any[] };
};

export const patchVisibility = async (w: World, id: string, body: unknown, headers: Record<string, string> = auth) => {
    const res = await w.call(`/library/items/${id}/visibility`, {
        method: "PATCH",
        headers: { ...headers, "content-type": "application/json" },
        body: typeof body === "string" ? body : JSON.stringify(body),
    });
    return { status: res.status, body: (await res.json()) as any };
};

// The purge API, faked: every call is recorded; `fail` answers success:false, `down` throws.
export function stubPurge(w: World) {
    const calls: { zone: string; urls: string[]; authorization: string }[] = [];
    const state = { fail: false, down: false };
    w.env.MEDIA_ZONE_ID = "560c4ad4961a65fa19899b4dfa8b5702";
    w.env.MEDIA_PURGE_TOKEN = "test-token-not-a-secret";
    vi.stubGlobal("fetch", async (input: any, init: any) => {
        if (state.down) throw new Error("network down");
        const u = String(input);
        const m = /\/zones\/([0-9a-f]{32})\/purge_cache$/.exec(u);
        if (!m) throw new Error(`unexpected fetch ${u}`);
        calls.push({ zone: m[1]!, urls: JSON.parse(init.body).files, authorization: init.headers.authorization });
        return new Response(JSON.stringify({ success: !state.fail, errors: [], result: { id: "x" } }), {
            status: state.fail ? 400 : 200,
            headers: { "content-type": "application/json" },
        });
    });
    return { calls, state, restore: () => vi.unstubAllGlobals() };
}

// I1-I5 of the contract (section 2), over the whole database and both buckets, for a migrated database.
export function assertInvariants(w: World) {
    const rows = liveRows(w);
    const sessions = w.db.raw.prepare("SELECT * FROM studio_sessions").all() as any[];
    for (const r of rows) {
        // I1
        expect(r.visibility === "public", `I1 ${r.id}`).toBe(r.url !== null);
        // I3
        if (r.bucket === "media") expect(r.visibility, `I3 ${r.id}`).toBe("public");
        if (r.bucket === "originals" && r.public_key) {
            // I2
            const has = w.media.objects.has(r.public_key);
            expect(has, `I2 ${r.id} (${r.visibility})`).toBe(r.visibility === "public");
            if (r.visibility === "public") {
                expect(r.url, `I2 url ${r.id}`).toBe(`https://media.capybaraharmony.com/${r.public_key}`);
                if (r.source === "saved" || r.source === "upload") expect(r.public_id, `I2 public_id ${r.id}`).toMatch(/^[A-Za-z0-9]{16}$/);
            }
        }
        if (r.bucket === "originals") expect(w.originals.objects.has(r.r2_key), `canonical object ${r.id}`).toBe(true);
    }
    // I4
    const keys = rows.map((r) => r.public_key).filter(Boolean);
    expect(new Set(keys).size).toBe(keys.length);
    for (const r of rows.filter((r) => r.bucket === "media")) expect(keys, `I4 ${r.r2_key}`).not.toContain(r.r2_key);
    // I5
    for (const s of sessions) {
        const o = rows.find((r) => r.bucket === "originals" && r.r2_key === s.r2_key);
        if (!o) continue;
        expect(s.public_url, `I5 url ${s.id}`).toBe(o.url);
        if (o.visibility === "public") expect(s.public_state, `I5 state ${s.id}`).toBe("ready");
        else expect(s.public_state === null || s.public_state === "failed" || s.public_state === "pending", `I5 state ${s.id}`).toBe(true);
    }
}
