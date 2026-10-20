// Shared fixtures for the editor tests (APP-API-CONTRACT.md section 31): the Worker with real SQL on node:sqlite over every
// migration (0021 included), a fake EditRenderer namespace that records the kicks, and, for the step machine, a fake render
// container that speaks the helper's HTTP contract (31.9). No network, no Cloudflare runtime.
import { readdirSync, readFileSync } from "node:fs";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { EditRenderCore, type EditCoreDeps } from "../src/edit-render-core";
import { createBatchD1, withBatch } from "./d1-batch";
import { Clock, MemoryKV, MemoryMedia, MemoryOriginals, fakeJpeg, fixedLength } from "./studio-fakes";

export const ORIGIN = "https://cobalt.capybaraharmony.com";
export const MEDIA_BASE = "https://media.capybaraharmony.com/";
export const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
export const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
export const KEY_ID = "key-row-1";
export const AUTH = { authorization: `Api-Key ${CLIENT}` };
export const JSON_HEADERS = { ...AUTH, "content-type": "application/json" };
export const HARK = "https://hark.example/hook/abc";

// 16-character library ids
export const ids = {
    a: "VidAAAAAAAAAAAAA",
    b: "VidBBBBBBBBBBBBB",
    c: "VidCCCCCCCCCCCCC",
    gif: "GifAAAAAAAAAAAAA",
    photo: "PhotoAAAAAAAAAAA",
    webm: "WebmAAAAAAAAAAAA",
};
for (const [k, v] of Object.entries(ids)) if (v.length !== 16) throw new Error(`id ${k} is ${v.length} long`);

export type ItemSpec = {
    id: string;
    contentType?: string;
    bytes?: number;
    width?: number;
    height?: number;
    duration?: number | null;
    bucket?: "originals" | "media";
    deleted?: boolean;
    poster?: string | null;
    object?: boolean;
};

// ---- the fake EditRenderer namespace --------------------------------------------------------------------------------

export class FakeRenderers {
    kicks: { name: string; instance: string | null; path: string; method: string }[] = [];
    // an instance that does not answer
    down = new Set<string>();
    // never answers (a stuck Durable Object)
    hang = new Set<string>();
    idFromName(name: string) {
        return name;
    }
    get(id: string) {
        return {
            fetch: async (request: Request) => {
                if (this.hang.has(id)) await new Promise<never>(() => {});
                if (this.down.has(id)) throw new Error("renderer down");
                this.kicks.push({ name: id, instance: request.headers.get("x-edit-instance"), path: new URL(request.url).pathname, method: request.method });
                return new Response(null, { status: 202 });
            },
        };
    }
}

// ---- the Worker -------------------------------------------------------------------------------------------------------

export function world(opts: { binding?: boolean; migrate?: boolean } = {}) {
    const db = opts.migrate === false ? withBatch(createFakeD1(onlyBefore0021())) : createBatchD1();
    const clock = new Clock();
    const originals = new MemoryOriginals();
    const media = new MemoryMedia();
    const renderers = new FakeRenderers();
    const env: WorkerEnv = {
        API_URL: "https://api.capybaraharmony.com/",
        CORS_URL: ORIGIN,
        COBALT_API_KEY: INTERNAL,
        DB: db,
        ORIGINALS: originals,
        MEDIA: media,
        MEDIA_BASE_URL: MEDIA_BASE,
        ...(opts.binding === false ? {} : { EDIT_RENDERER: renderers as unknown as DurableObjectNamespace }),
    };
    const container = {
        async fetch(_r: Request) {
            return new Response('{"status":"ok"}', { headers: { "content-type": "application/json" } });
        },
    };
    const call = (url: string, init: RequestInit = {}) =>
        handleRequest(new Request(`https://api.capybaraharmony.com${url}`, init), env, container, { now: clock.now, sleep: clock.sleep });
    const api = async (method: string, url: string, body?: unknown, headers: Record<string, string> = JSON_HEADERS) => {
        const res = await call(url, { method, headers, ...(body === undefined ? {} : { body: typeof body === "string" ? body : JSON.stringify(body) }) });
        const text = await res.text();
        let json: any = null;
        try {
            json = JSON.parse(text);
        } catch {
            // not JSON
        }
        return { res, status: res.status, json, text };
    };
    const addKey = async () =>
        db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run(KEY_ID, "test", await hashKey(CLIENT), "0b5f2c3e", 1);

    // library rows (and the objects behind them)
    const addItem = (s: ItemSpec) => {
        const ct = s.contentType ?? "video/mp4";
        const bytes = s.bytes ?? 1000;
        const bucket = s.bucket ?? "originals";
        const key = `${bucket === "originals" ? "originals/" : ""}${s.id}.bin`;
        db.raw
            .prepare(
                "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, key_id, created_at, deleted_at, poster) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            )
            .run(
                s.id,
                bucket === "originals" ? "private" : "public",
                "saved",
                bucket,
                key,
                null,
                `${s.id}.mp4`,
                ct,
                bytes,
                s.width ?? 1080,
                s.height ?? 1920,
                s.duration === undefined ? 12 : s.duration,
                KEY_ID,
                clock.t,
                s.deleted ? clock.t : null,
                s.poster ?? null,
            );
        if (s.object !== false) {
            const store = bucket === "originals" ? originals : media;
            if (bucket === "originals") originals.objects.set(key, { bytes: new Uint8Array(bytes).fill(9), contentType: ct, meta: {} });
            else media.objects.set(key, { bytes, meta: {}, contentType: ct, data: new Uint8Array(bytes).fill(9), viaStream: false });
            void store;
        }
        return key;
    };
    const seedLibrary = () => {
        addItem({ id: ids.a, bytes: 1500, duration: 12, poster: `${MEDIA_BASE}CoverAAAAA.jpg` });
        addItem({ id: ids.b, bytes: 2500, duration: 6, width: 1920, height: 1080 });
        addItem({ id: ids.c, bytes: 500, duration: 30 });
        addItem({ id: ids.gif, contentType: "image/gif", bytes: 300, width: 480, height: 480, duration: null });
        addItem({ id: ids.photo, contentType: "image/jpeg", bytes: 800, width: 3024, height: 4032, duration: null });
        addItem({ id: ids.webm, contentType: "video/webm", bytes: 700, duration: 5 });
    };

    return { db, clock, originals, media, renderers, env, call, api, addKey, addItem, seedLibrary };
}
export type World = ReturnType<typeof world>;

// migrations 0001..0020 only (a database the owner has not migrated yet)
function onlyBefore0021(): string {
    const dir = new URL("../../d1/migrations/", import.meta.url);
    return readdirSync(dir)
        .filter((f) => f.endsWith(".sql") && f < "0021")
        .sort()
        .map((f) => readFileSync(new URL(f, dir), "utf8"))
        .join("\n");
}

// ---- timelines -----------------------------------------------------------------------------------------------------------

export const mainClip = (item: string, over: Record<string, unknown> = {}) => ({
    id: `c${item.slice(0, 8)}`,
    item,
    in: 0,
    out: 4,
    speed: 1,
    fit: "fill",
    volume: 1,
    muted: false,
    ...over,
});
export const overlayClip = (item: string, over: Record<string, unknown> = {}) => ({
    id: `o${item.slice(0, 8)}`,
    item,
    at: 1,
    in: 0,
    out: 2,
    frame: { x: 0.6, y: 0.05, w: 0.35 },
    opacity: 1,
    volume: 1,
    muted: true,
    ...over,
});
// two main clips (150 + 120 frames = 9 s at 30 fps), no overlay unless asked
export function timeline(over: { main?: unknown[]; overlay?: unknown[]; canvas?: Record<string, unknown> } = {}) {
    return {
        version: 1,
        canvas: { w: 1080, h: 1920, fps: 30, ...(over.canvas ?? {}) },
        main: over.main ?? [mainClip(ids.a, { id: "cA1b2C3d4", in: 2, out: 9.5, speed: 1.5, volume: 1 }), mainClip(ids.b, { id: "cE5f6G7h8", volume: 0.7 })],
        overlay: over.overlay ?? [],
    };
}

// ---- the fake render container (31.9) --------------------------------------------------------------------------------------

type RenderState = {
    inputs: Map<number, number>;
    started: any | null;
    polls: number;
    deleted: boolean;
};

export class FakeEditContainer {
    renders = new Map<string, RenderState>();
    // "METHOD /path"
    calls: string[] = [];
    // hook run on every call before it is answered (statuses seen from D1, cancel requests, ...)
    onCall: ((method: string, path: string) => void | Promise<void>) | null = null;
    // polls that answer "encoding" before the render is done
    encodingPolls = 2;
    secondsDone = (poll: number) => poll * 3;
    // the done answer
    result = { bytes: 4096, width: 1080, height: 1920, duration: 9 };
    file = new Uint8Array(4096).fill(5);
    poster: Uint8Array | null = fakeJpeg(64);
    posterStatus = 200;
    // status overrides
    inputStatus: ((n: number, tries: number) => number) | null = null;
    startStatus: { status: number; body?: unknown } | null = null;
    // the render's status answer is this error once (helper-side failure)
    helperError: string | null = null;
    // forever "encoding"
    stuck = false;
    // answer 404 to everything about a rid (a restarted container)
    forget = false;
    // tell how many times the container was "restarted": clears state
    reboot() {
        this.renders.clear();
    }
    // the file endpoint's declared length (default: the bytes)
    fileLength: number | null = null;
    inputTries = new Map<number, number>();

    private res(status: number, body?: unknown, headers: Record<string, string> = {}) {
        return new Response(body === undefined ? null : typeof body === "string" || body instanceof Uint8Array ? (body as any) : JSON.stringify(body), {
            status,
            headers: { ...(typeof body === "object" && !(body instanceof Uint8Array) ? { "content-type": "application/json" } : {}), ...headers },
        });
    }

    handle = async (path: string, init: RequestInit = {}): Promise<Response> => {
        const method = (init.method ?? "GET").toUpperCase();
        this.calls.push(`${method} ${path.replace(/^\/renders\/[A-Za-z0-9]{20}/, "/renders/<rid>")}`);
        await this.onCall?.(method, path);
        const m = /^\/renders\/([A-Za-z0-9]{20})(?:\/(.*))?$/.exec(path);
        if (!m) return this.res(404);
        const [, rid, rest] = m;
        if (this.forget && method !== "DELETE") {
            // a body sent to a restarted container is still consumed
            await consume(init.body);
            return this.res(404, { status: "error", error: { code: "error.edit.not_found" } });
        }
        if (method === "PUT" && rest?.startsWith("inputs/")) {
            const n = Number(rest.slice("inputs/".length));
            const len = await consume(init.body);
            const declared = Number((init.headers as Record<string, string>)?.["content-length"]);
            if (declared !== len) return this.res(400);
            const tries = (this.inputTries.get(n) ?? 0) + 1;
            this.inputTries.set(n, tries);
            const forced = this.inputStatus?.(n, tries);
            if (forced && forced !== 204) return this.res(forced, { status: "error", error: { code: "error.edit.busy" } });
            const st = this.renders.get(rid!) ?? { inputs: new Map(), started: null, polls: 0, deleted: false };
            st.inputs.set(n, len);
            this.renders.set(rid!, st);
            return this.res(204);
        }
        const st = this.renders.get(rid!);
        if (method === "POST" && rest === "start") {
            if (this.startStatus) return this.res(this.startStatus.status, this.startStatus.body ?? {});
            if (!st) return this.res(409, { status: "error", error: { code: "error.edit.input_missing" } });
            st.started = JSON.parse(String(init.body));
            return this.res(202);
        }
        if (method === "DELETE") {
            if (st) st.deleted = true;
            this.renders.delete(rid!);
            return this.res(204);
        }
        if (!st) return this.res(404, { status: "error", error: { code: "error.edit.not_found" } });
        if (method === "GET" && rest === undefined) {
            st.polls++;
            if (this.helperError) return this.res(200, { status: "error", seconds_done: null, seconds_total: 9, error: { code: this.helperError } });
            if (this.stuck || st.polls <= this.encodingPolls) {
                return this.res(200, { status: "encoding", seconds_done: this.secondsDone(st.polls), seconds_total: 9, speed: 2, bytes: null, error: null });
            }
            return this.res(200, { status: "done", seconds_done: 9, seconds_total: 9, speed: 2, error: null, ...this.result });
        }
        if (method === "GET" && rest === "file") {
            return this.res(200, this.file, { "content-type": "video/mp4", "content-length": String(this.fileLength ?? this.file.length) });
        }
        if (method === "GET" && rest === "poster") {
            if (this.posterStatus !== 200) return this.res(this.posterStatus, { status: "error", error: { code: "error.edit.render_failed" } });
            return this.poster ? this.res(200, this.poster, { "content-type": "image/jpeg" }) : this.res(500);
        }
        return this.res(404);
    };
}

async function consume(body: unknown): Promise<number> {
    if (!(body instanceof ReadableStream)) return body == null ? 0 : String(body).length;
    const reader = (body as ReadableStream<Uint8Array>).getReader();
    let n = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        n += value.length;
    }
    return n;
}

// ---- the step machine -----------------------------------------------------------------------------------------------------------

export function coreWorld() {
    const w = world();
    const db = w.db;
    const clock = w.clock;
    const container = new FakeEditContainer();
    const harkCalls: { url: string; body: any }[] = [];
    let harkStatus = 200;
    let harkThrows = false;
    const harkQueue: number[] = [];
    const cores: Record<string, EditRenderCore & { pending: number | null; storage: MemoryKV; scheduled: number[]; ensured: number; up: boolean; envChecks: number }> = {};

    const makeCore = (instance: string, over: Partial<EditCoreDeps> = {}) => {
        const storage = new MemoryKV();
        const state = { pending: null as number | null, scheduled: [] as number[], ensured: 0, running: true, envChecks: 0 };
        const core = new EditRenderCore({
            instance,
            db,
            storage,
            originals: w.originals,
            media: w.media,
            mediaBaseUrl: MEDIA_BASE,
            now: clock.now,
            fixedLength,
            ensureRunning: async () => {
                state.ensured++;
            },
            isRunning: () => state.running,
            container: container.handle,
            schedule: async (s) => {
                state.pending = s;
                state.scheduled.push(s);
            },
            beforeClaim: async () => {
                state.envChecks++;
            },
            hark: HARK,
            harkFetch: async (url, init) => {
                if (harkThrows) throw new Error("network down");
                harkCalls.push({ url, body: JSON.parse(String(init.body)) });
                return new Response(null, { status: harkQueue.length ? harkQueue.shift()! : harkStatus });
            },
            log: () => {},
            ...over,
        }) as any;
        Object.defineProperty(core, "pending", { get: () => state.pending, set: (v) => (state.pending = v) });
        core.storage = storage;
        core.scheduled = state.scheduled;
        Object.defineProperty(core, "ensured", { get: () => state.ensured });
        Object.defineProperty(core, "up", { get: () => state.running, set: (v) => (state.running = v) });
        Object.defineProperty(core, "envChecks", { get: () => state.envChecks });
        cores[instance] = core;
        return core as typeof cores[string];
    };

    // The alarm loop: kick, then run every scheduled tick (the clock moves by each delay) until nothing is armed.
    const run = async (core: ReturnType<typeof makeCore>, max = 400) => {
        await core.kick();
        let n = 0;
        while (core.pending !== null && n++ < max) {
            const delay = core.pending;
            core.pending = null;
            clock.t += delay * 1000;
            await core.tick();
        }
        if (n >= max) throw new Error("the render never settled");
        return n;
    };

    // a queued render, as POST /edits/<id>/render would insert it
    let seq = 0;
    const queueRender = (over: Record<string, unknown> = {}) => {
        seq++;
        const id = String(over.id ?? `Rnd${String(seq).padStart(17, "0")}`);
        const tl = JSON.stringify(over.timeline ?? timeline());
        const row = {
            id,
            project_id: "ProjectAAAAAAAAA".slice(0, 16),
            revision: 3,
            title: "My edit",
            timeline: tl,
            status: "queued",
            cancel_requested: 0,
            attempts: 0,
            input_bytes: 4000,
            seconds_total: 9,
            notify: 0,
            key_id: KEY_ID,
            created_at: clock.t + seq,
            updated_at: clock.t + seq,
            ...over,
        } as Record<string, any>;
        row.id = id;
        row.timeline = tl;
        const cols = Object.keys(row);
        db.raw.prepare(`INSERT INTO edit_renders (${cols.join(", ")}) VALUES (${cols.map(() => "?").join(", ")})`).run(...cols.map((c) => row[c]));
        return id;
    };
    const row = (id: string) => db.raw.prepare("SELECT * FROM edit_renders WHERE id = ?").get(id) as any;

    return {
        ...w,
        db,
        clock,
        container,
        harkCalls,
        setHark: (status: number, throws = false) => {
            harkStatus = status;
            harkThrows = throws;
        },
        // the statuses the next Hark calls answer, then `setHark`'s
        harkScript: (...statuses: number[]) => void harkQueue.push(...statuses),
        makeCore,
        run,
        queueRender,
        row,
    };
}
export type CoreWorld = ReturnType<typeof coreWorld>;
