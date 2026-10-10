// Fakes shared by the studio tests: an R2 bucket that consumes streams, a DO
// storage map, a scriptable container helper and a manual clock.
import type { KV, MediaBucket } from "../src/webp";
import type { OriginalsBucket } from "../src/studio";
import type { PublishBucket } from "../src/publish";

export class MemoryKV implements KV {
    m = new Map<string, unknown>();
    async get<T>(k: string) {
        return this.m.get(k) as T | undefined;
    }
    async put(k: string, v: unknown) {
        this.m.set(k, v);
    }
    async delete(k: string) {
        return this.m.delete(k);
    }
    async list<T>(o: { prefix: string }) {
        return new Map([...this.m].filter(([k]) => k.startsWith(o.prefix))) as Map<string, T>;
    }
}

const collect = async (s: ReadableStream): Promise<Uint8Array> =>
    new Uint8Array(await new Response(s).arrayBuffer());

// R2 `cobalt-originals`: put() only accepts a stream (never a buffer), like the
// production code path.
export const UPLOADED = new Date(Date.UTC(2026, 0, 2, 3, 4, 5));
export const etagOf = (key: string, n: number) => `"${key}:${n}"`;

export class MemoryOriginals implements OriginalsBucket {
    objects = new Map<string, { bytes: Uint8Array; contentType: string; meta: Record<string, string> }>();
    putValueTypes: string[] = [];
    failPut = false;
    // Hand out bodies whose pipeTo / pipeThrough / tee throw, like this
    // runtime's inter-stream pipeTo (unimplemented): code that copies a body
    // must pass it on or read it chunk by chunk.
    hostileStreams = false;
    failGet = false;
    gets: { key: string; range?: { offset: number; length?: number } }[] = [];

    async put(
        key: string,
        value: ReadableStream,
        o: { httpMetadata: { contentType: string }; customMetadata: Record<string, string> },
    ) {
        this.putValueTypes.push(value instanceof ReadableStream ? "ReadableStream" : typeof value);
        if (this.failPut) throw new Error("R2 down");
        const bytes = await collect(value);
        this.objects.set(key, { bytes, contentType: o.httpMetadata.contentType, meta: o.customMetadata });
        return { size: bytes.length };
    }
    async get(key: string, options?: { range?: { offset: number; length?: number } }) {
        this.gets.push({ key, range: options?.range });
        if (this.failGet) throw new Error("R2 get down");
        const o = this.objects.get(key);
        if (!o) return null;
        const r = options?.range;
        const slice = r ? o.bytes.slice(r.offset, r.length === undefined ? undefined : r.offset + r.length) : o.bytes;
        const body = new Blob([slice]).stream() as ReadableStream;
        if (this.hostileStreams) {
            const nope = () => {
                throw new Error("pipeTo/pipeThrough/tee is not implemented in this runtime");
            };
            Object.assign(body, { pipeTo: nope, pipeThrough: nope, tee: nope });
        }
        return {
            body,
            size: o.bytes.length,
            httpMetadata: { contentType: o.contentType },
            httpEtag: etagOf(key, o.bytes.length),
            uploaded: UPLOADED,
        };
    }
    heads: string[] = [];
    failHead = false;
    async head(key: string) {
        this.heads.push(key);
        if (this.failHead) throw new Error("R2 head down");
        const o = this.objects.get(key);
        return o
            ? { size: o.bytes.length, httpMetadata: { contentType: o.contentType }, httpEtag: etagOf(key, o.bytes.length), uploaded: UPLOADED }
            : null;
    }
    async delete(key: string) {
        this.objects.delete(key);
    }
}

// R2 `cobalt-media`: put() takes the WebP bytes (the encode path) or a stream
// (publish), read chunk by chunk like R2 would.
export class MemoryMedia implements MediaBucket, PublishBucket {
    objects = new Map<
        string,
        {
            bytes: number;
            meta: Record<string, string>;
            contentType?: string;
            cacheControl?: string;
            data: Uint8Array;
            viaStream: boolean;
        }
    >();
    failPut = false;
    puts: { key: string; value: unknown }[] = [];
    async put(
        key: string,
        value: ArrayBuffer | ReadableStream,
        o: {
            httpMetadata: { contentType: string; cacheControl: string };
            customMetadata: Record<string, string>;
        },
    ) {
        this.puts.push({ key, value });
        if (this.failPut) throw new Error("R2 down");
        const viaStream = value instanceof ReadableStream;
        let data: Uint8Array;
        if (value instanceof ReadableStream) {
            const chunks: Uint8Array[] = [];
            const reader = (value as ReadableStream<Uint8Array>).getReader();
            for (;;) {
                const { done, value: v } = await reader.read();
                if (done) break;
                chunks.push(v);
            }
            data = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
            let off = 0;
            for (const c of chunks) {
                data.set(c, off);
                off += c.length;
            }
        } else {
            data = new Uint8Array(value);
        }
        this.objects.set(key, {
            bytes: data.length,
            meta: o.customMetadata,
            contentType: o.httpMetadata.contentType,
            cacheControl: o.httpMetadata.cacheControl,
            data,
            viaStream,
        });
        return { size: data.length };
    }
    failDelete = false;
    deletes: string[] = [];
    async delete(key: string) {
        this.deletes.push(key);
        if (this.failDelete) throw new Error("R2 delete down");
        this.objects.delete(key);
    }
    heads: string[] = [];
    async head(key: string) {
        this.heads.push(key);
        const o = this.objects.get(key);
        return o ? { size: o.data.length } : null;
    }
    // A fresh body per call, like R2's get()
    async get(key: string) {
        const o = this.objects.get(key);
        if (!o) return null;
        return {
            body: new Blob([o.data]).stream() as ReadableStream,
            size: o.data.length,
            httpMetadata: { contentType: o.contentType },
        };
    }
}

// R2 stream wrapper for tests: checks the byte count like FixedLengthStream does.
// `onChunk` sees each chunk's size as it passes (the "storing" progress).
export const fixedLength = (
    stream: ReadableStream,
    length: number,
    onChunk?: (n: number) => void,
): ReadableStream => {
    let n = 0;
    return stream.pipeThrough(
        new TransformStream({
            transform(chunk, c) {
                n += chunk.length;
                onChunk?.(chunk.length);
                c.enqueue(chunk);
            },
            flush() {
                if (n !== length) throw new Error(`FixedLengthStream: expected ${length}, got ${n}`);
            },
        }),
    );
};

// The Worker's FixedLengthStream, for the library publish copy (Node has none):
// a pass-through pair that fails the stream when the bytes written do not add
// up to `n`, like the real one.
export const fixedLengthPair = (n: number) => {
    let seen = 0;
    const ts = new TransformStream<Uint8Array, Uint8Array>({
        transform(chunk, c) {
            seen += chunk.length;
            c.enqueue(chunk);
        },
        flush() {
            if (seen !== n) throw new Error(`FixedLengthStream: expected ${n}, got ${seen}`);
        },
    });
    return { readable: ts.readable, writable: ts.writable };
};

export class Clock {
    t = 1_800_000_000_000;
    now = () => this.t;
    sleep = async (ms: number) => {
        this.t += ms;
    };
}

const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

// A scriptable container helper. Default: /fetch is accepted, finishes on the
// first poll, and serves `videoBytes`; uploads are accepted and their bodies
// consumed (length recorded); jobs finish on the first poll.
// One item of a post as the fake helper's cobalt "resolves" it (APP-API-CONTRACT.md 18.7)
export type GalleryItemSpec = {
    type: "photo" | "video" | "gif";
    // answers this code instead of the item (an expired signed link)
    fail?: string;
    bytes?: Uint8Array;
    width?: number;
    height?: number;
    duration?: number | null;
    // a photo with no thumb (the helper could not make one)
    noThumb?: boolean;
};
export const JPEG_HEAD = [0xff, 0xd8, 0xff, 0xe0];
export const fakeJpeg = (n: number, fill = 3) => Uint8Array.from([...JPEG_HEAD, ...new Array(n).fill(fill), 0xff, 0xd9]);

export class FakeHelper {
    calls: string[] = []; // "METHOD /path"
    // photos and galleries (18.7): the post a link resolves to, and what is asked of it
    gallery: GalleryItemSpec[] | null = null;
    fetchRequests = new Map<string, Record<string, any>>();
    fileQueries: string[] = []; // the `?i=` of every GET /fetch/:id/file (null = none)
    thumbQueries: string[] = [];
    singleThumb: Uint8Array | null = null; // GET /fetch/:id/thumb (no i) for a single file
    thumbFails = false;
    // the slideshow (18.7)
    slideBusy = false; // PUT inputs answer 429
    slideInputStatus: number | null = null; // PUT inputs answer this (413, 400)
    slideInputs = new Map<string, Map<number, number>>(); // job -> n -> bytes
    slideStarts: { job: string; body: any }[] = [];
    slideStartStatus: number | null = null; // POST start answers this (409, 400, ...)
    slidePolls = 0; // GET /slideshow/:id answers pending this many times first
    slidePendingFields: Record<string, unknown> = { phase: "composing", done: 1, total: 3 };
    slideError: string | null = null;
    slideGone = false;
    slideResult: Record<string, unknown> = { bytes: 5000, duration: 12.3, width: 1080, height: 1350 };
    slideFile = new Uint8Array(5000).fill(4);
    slideDeletes: string[] = [];
    slideGate: Promise<void> | null = null; // holds PUT inputs (an upload "in progress")
    // the webp slideshow (18.10): what the start body asked for decides the format the answers carry
    slideFormats = new Map<string, "mp4" | "webp">();
    slideWebpResult: Record<string, unknown> = { bytes: 3000, duration: 6, width: 480, height: 600 };
    slideWebpFile = new Uint8Array(3000).fill(8);
    slidePosterStatus = 200; // GET /slideshow/:id/poster
    // the gallery image (18.11), as the slideshow above
    galleryBusy = false;
    galleryInputStatus: number | null = null;
    galleryInputs = new Map<string, Map<number, number>>();
    galleryStarts: { job: string; body: any }[] = [];
    galleryStartStatus: number | null = null;
    galleryPolls = 0;
    galleryPendingFields: Record<string, unknown> = { phase: "composing", done: 1, total: 3 };
    galleryError: string | null = null;
    galleryGone = false;
    galleryResult: Record<string, unknown> = { bytes: 4000, width: 2160, height: 4500, cropped: [], upscaled: [] };
    galleryFile = new Uint8Array(4000).fill(6);
    galleryDeletes: string[] = [];
    videoBytes = new Uint8Array(4096).fill(7);
    busyFetchStarts = 0; // this many POST /fetch answer 429 first
    fetchPolls = 0; // this many GET /fetch/:id answer pending first
    fetchPendingFields: Record<string, unknown> = {}; // merged into those pending answers (stage, bytes, total)
    jobPendingFields: Record<string, unknown> = {}; // the same for GET /jobs/:id (phase, frames_done, frames_total)
    fetchDone: Record<string, unknown> | null = null; // overrides the done body
    fetchError: string | null = null;
    fetchFileLength: number | null = null; // content-length to lie with
    fetchGone = false; // GET /fetch/:id -> 404 for good
    fetchLosses = 0; // the next this many GET /fetch/:id -> 404 (container restarts): the fetch is forgotten
    fetchStarted = new Set<string>(); // ids the helper accepted and still knows
    fetchBodies: Record<string, unknown>[] = [];
    uploadBusy = false;
    uploadedBytes: number[] = [];
    uploadQueries: URLSearchParams[] = [];
    // POST /probe (adopted uploads): this many answer 429 first, then the
    // result (or probeError); probedBytes records the streamed body lengths.
    probeBusy = 0;
    probeResult: Record<string, unknown> = { duration: 4.2, width: 640, height: 360 };
    probeError: { status: number; code: string } | null = null;
    probeHang = false; // never answers (a hung helper call)
    probedBytes: number[] = [];
    // POST /poster?id= (server-made posters, APP-API-CONTRACT.md section 13): this many answer 429
    // first, then the JPEG (or posterError); posterBytes records the streamed video lengths,
    // posterIds the ids asked for. posterGate holds the call until it resolves (a poster "in progress").
    posterBusy = 0;
    posterFailures = 0; // this many answer 500 first
    posterError: { status: number; code: string } | null = null;
    posterJpeg: Uint8Array = Uint8Array.from([0xff, 0xd8, ...new Array(300).fill(5), 0xff, 0xd9]);
    posterBytes: number[] = [];
    posterIds: string[] = [];
    posterGate: Promise<void> | null = null;
    jobPolls = 0;
    jobsGone = false; // GET /jobs/:id -> 404 (the container restarted and forgot every job)
    // DELETE /jobs/:id really drops the job (like the real helper): a later GET
    // /jobs/:id and /jobs/:id/file answer 404.
    dropJobsOnDelete = false;
    droppedJobs = new Set<string>();
    jobError: string | null = null;
    webp = new Uint8Array(1500).fill(9);
    unreachable = false;

    itemBytes(i: number, spec: GalleryItemSpec): Uint8Array {
        if (spec.bytes) return spec.bytes;
        return spec.type === "photo" ? fakeJpeg(120 + i, i + 1) : new Uint8Array(600 + i).fill(i + 1);
    }

    // the done answer of a save of several items (18.7)
    galleryDone(choice: "all" | number[]): Record<string, unknown> {
        const g = this.gallery!;
        const chosen = choice === "all" ? g.map((_, i) => i) : choice;
        const items = chosen.map((i) => {
            const spec = g[i];
            if (!spec) return { i, status: "error", code: "error.studio.unavailable" };
            if (spec.fail) return { i, status: "error", code: spec.fail };
            const bytes = this.itemBytes(i, spec).length;
            return {
                i,
                status: "done",
                bytes,
                contentType: spec.type === "photo" ? "image/jpeg" : spec.type === "gif" ? "image/gif" : "video/mp4",
                ext: spec.type === "photo" ? "jpg" : spec.type === "gif" ? "gif" : "mp4",
                duration: spec.type === "photo" ? null : (spec.duration ?? 4.5),
                width: spec.width ?? 1080,
                height: spec.height ?? 1350,
                thumb: spec.type === "photo" && !spec.noThumb,
            };
        });
        const done = items.filter((x: any) => x.status === "done") as any[];
        const lead = done.find((x) => x.contentType.startsWith("video/")) ?? done[0];
        return {
            status: "done",
            ...(lead ?? { bytes: 0 }),
            title: "ig_Ddy0-gpGg5U",
            service: "instagram",
            picker_count: g.length,
            items,
        };
    }

    // every answer says what this helper can do, like the real one (helper/server.js HELPER_CAPS_HEADER); an
    // "older helper image" is `advertise = false`
    advertise = true;
    makes = true;
    // `direct=1`: a link to a media file that cobalt has no service for is saved as that file (APP-API-CONTRACT.md 19)
    directs = true;
    helper = async (path: string, init?: RequestInit): Promise<Response> => {
        const res = await this.answer(path, init);
        if (this.advertise) {
            res.headers.set("x-cobalt-helper", [this.makes ? "gallery=1,make=1" : "gallery=1", this.directs ? "direct=1" : ""].filter(Boolean).join(","));
        }
        return res;
    };

    private answer = async (path: string, init?: RequestInit): Promise<Response> => {
        if (this.unreachable) throw new Error("container down");
        const method = init?.method ?? "GET";
        this.calls.push(`${method} ${path.split("?")[0]}`);
        const u = new URL(`http://helper${path}`);
        const p = u.pathname;

        if (method === "POST" && p === "/fetch") {
            if (this.busyFetchStarts > 0) {
                this.busyFetchStarts--;
                return json(429, { status: "error", error: { code: "error.webp.busy" } });
            }
            const b = JSON.parse(String(init?.body));
            this.fetchBodies.push(b);
            this.fetchRequests.set(b.id, b);
            this.fetchStarted.add(b.id);
            return json(202, { status: "pending", id: b.id });
        }
        if (method === "GET" && /^\/fetch\/[A-Za-z0-9]+$/.test(p)) {
            const id = p.slice("/fetch/".length);
            if (this.fetchLosses > 0) {
                this.fetchLosses--;
                this.fetchStarted.delete(id);
            }
            if (this.fetchGone || !this.fetchStarted.has(id)) {
                return json(404, { status: "error", error: { code: "error.webp.not_found" } });
            }
            if (this.fetchPolls > 0) {
                this.fetchPolls--;
                return json(200, { status: "pending", ...this.fetchPendingFields });
            }
            if (this.fetchError) return json(200, { status: "error", error: { code: this.fetchError } });
            const asked = this.fetchRequests.get(id);
            if (this.gallery && asked && asked.items !== undefined && asked.items !== "first-video") {
                if (asked.item_count !== undefined && asked.item_count !== this.gallery.length) {
                    return json(200, { status: "error", error: { code: "error.studio.gallery_changed" } });
                }
                return json(200, this.galleryDone(asked.items));
            }
            return json(200, {
                status: "done",
                bytes: this.videoBytes.length,
                contentType: "video/mp4",
                ext: "mp4",
                duration: 9.6,
                width: 480,
                height: 560,
                title: "x_2105237035271258436",
                service: "x",
                ...this.fetchDone,
            });
        }
        if (method === "GET" && /^\/fetch\/[A-Za-z0-9]+\/file$/.test(p)) {
            const i = u.searchParams.get("i");
            this.fileQueries.push(String(i));
            const spec = this.gallery && i !== null ? this.gallery[Number(i)] : undefined;
            if (i !== null && this.gallery && (!spec || spec.fail)) return json(404, { status: "error", error: { code: "error.webp.not_found" } });
            const bytes = spec ? this.itemBytes(Number(i), spec) : this.videoBytes;
            return new Response(bytes, {
                headers: { "content-length": String(this.fetchFileLength ?? bytes.length) },
            });
        }
        if (method === "GET" && /^\/fetch\/[A-Za-z0-9]+\/thumb$/.test(p)) {
            const i = u.searchParams.get("i");
            this.thumbQueries.push(String(i));
            if (this.thumbFails) return json(404, { status: "error", error: { code: "error.webp.not_found" } });
            if (i === null) {
                return this.singleThumb ? new Response(this.singleThumb, { headers: { "content-type": "image/jpeg" } }) : json(404, { status: "error", error: { code: "error.webp.not_found" } });
            }
            const spec = this.gallery?.[Number(i)];
            if (!spec || spec.fail || spec.type !== "photo" || spec.noThumb) return json(404, { status: "error", error: { code: "error.webp.not_found" } });
            return new Response(fakeJpeg(40, Number(i) + 1), { headers: { "content-type": "image/jpeg" } });
        }

        // the slideshow
        if (p.startsWith("/slideshow/")) {
            const [, , job, sub, n] = p.split("/");
            if (method === "PUT" && sub === "inputs") {
                if (this.slideGate) await this.slideGate;
                if (this.slideBusy) return json(429, { status: "error", error: { code: "error.webp.busy" } });
                const len = (await collect(init?.body as ReadableStream)).length;
                if (this.slideInputStatus) return json(this.slideInputStatus, { status: "error", error: { code: "error.studio.too_large" } });
                const m = this.slideInputs.get(job!) ?? new Map<number, number>();
                m.set(Number(n), len);
                this.slideInputs.set(job!, m);
                return new Response(null, { status: 204 });
            }
            if (method === "POST" && sub === "start") {
                const body = JSON.parse(String(init?.body));
                if (this.slideStartStatus) return json(this.slideStartStatus, { status: "error", error: { code: "error.webp.invalid_params" } });
                const have = this.slideInputs.get(job!);
                if (!have || body.slides.some((sl: any) => !have.has(sl.n))) return json(409, { status: "error", error: { code: "error.studio.missing" } });
                this.slideStarts.push({ job: job!, body });
                this.slideFormats.set(job!, body.format === "webp" ? "webp" : "mp4");
                return json(202, { status: "pending" });
            }
            if (method === "GET" && sub === undefined) {
                if (this.slideGone || !this.slideStarts.some((x) => x.job === job)) return json(404, { status: "error", error: { code: "error.webp.not_found" } });
                if (this.slidePolls > 0) {
                    this.slidePolls--;
                    return json(200, { status: "pending", ...this.slidePendingFields });
                }
                if (this.slideError) return json(200, { status: "error", error: { code: this.slideError } });
                const webp = this.slideFormats.get(job!) === "webp";
                return json(200, { status: "done", ...(webp ? this.slideWebpResult : this.slideResult), format: webp ? "webp" : "mp4" });
            }
            if (method === "GET" && sub === "file") {
                const f = this.slideFormats.get(job!) === "webp" ? this.slideWebpFile : this.slideFile;
                return new Response(f, { headers: { "content-length": String(f.length) } });
            }
            if (method === "GET" && sub === "poster") {
                if (this.slidePosterStatus !== 200) return json(this.slidePosterStatus, { status: "error", error: { code: "error.webp.not_found" } });
                return new Response(this.posterJpeg, { headers: { "content-type": "image/jpeg", "content-length": String(this.posterJpeg.length) } });
            }
            if (method === "DELETE") {
                this.slideDeletes.push(job!);
                this.slideInputs.delete(job!);
                return new Response(null, { status: 204 });
            }
        }
        // the gallery image (a helper from before the makes has no such route)
        if (p.startsWith("/gallery/") && !this.makes) return json(404, { status: "error", error: { code: "error.webp.not_found" } });
        if (p.startsWith("/gallery/")) {
            const [, , job, sub, n] = p.split("/");
            if (method === "PUT" && sub === "inputs") {
                if (this.galleryBusy) return json(429, { status: "error", error: { code: "error.webp.busy" } });
                const len = (await collect(init?.body as ReadableStream)).length;
                if (this.galleryInputStatus) return json(this.galleryInputStatus, { status: "error", error: { code: "error.studio.too_large" } });
                const m = this.galleryInputs.get(job!) ?? new Map<number, number>();
                m.set(Number(n), len);
                this.galleryInputs.set(job!, m);
                return new Response(null, { status: 204 });
            }
            if (method === "POST" && sub === "start") {
                const body = JSON.parse(String(init?.body));
                if (this.galleryStartStatus) return json(this.galleryStartStatus, { status: "error", error: { code: "error.webp.invalid_params" } });
                const have = this.galleryInputs.get(job!);
                if (!have || body.slides.some((sl: any) => !have.has(sl.n))) return json(409, { status: "error", error: { code: "error.studio.missing" } });
                this.galleryStarts.push({ job: job!, body });
                return json(202, { status: "pending" });
            }
            if (method === "GET" && sub === undefined) {
                if (this.galleryGone || !this.galleryStarts.some((x) => x.job === job)) return json(404, { status: "error", error: { code: "error.webp.not_found" } });
                if (this.galleryPolls > 0) {
                    this.galleryPolls--;
                    return json(200, { status: "pending", ...this.galleryPendingFields });
                }
                if (this.galleryError) return json(200, { status: "error", error: { code: this.galleryError } });
                return json(200, { status: "done", ...this.galleryResult });
            }
            if (method === "GET" && sub === "file") {
                return new Response(this.galleryFile, { headers: { "content-length": String(this.galleryFile.length) } });
            }
            if (method === "DELETE") {
                this.galleryDeletes.push(job!);
                this.galleryInputs.delete(job!);
                return new Response(null, { status: 204 });
            }
        }
        if (method === "DELETE") {
            if (p.startsWith("/jobs/")) {
                if (this.dropJobsOnDelete) this.droppedJobs.add(p.slice("/jobs/".length));
                return json(200, { status: "success" });
            }
            this.fetchStarted.delete(p.slice("/fetch/".length));
            return json(200, { status: "success" });
        }
        if (method === "GET" && /^\/jobs\/[A-Za-z0-9]+(\/file)?$/.test(p) && this.droppedJobs.has(p.split("/")[2]!)) {
            return json(404, { status: "error", error: { code: "error.webp.not_found" } });
        }

        if (method === "POST" && p === "/probe") {
            if (this.probeHang) return new Promise<Response>(() => {});
            if (this.probeBusy > 0) {
                this.probeBusy--;
                return json(429, { status: "error", error: { code: "error.webp.busy" } });
            }
            this.probedBytes.push((await collect(init?.body as ReadableStream)).length);
            if (this.probeError) {
                return json(this.probeError.status, { status: "error", error: { code: this.probeError.code } });
            }
            return json(200, this.probeResult);
        }

        if (method === "POST" && p === "/poster") {
            this.posterIds.push(u.searchParams.get("id") ?? "");
            if (this.posterGate) await this.posterGate;
            if (this.posterBusy > 0) {
                this.posterBusy--;
                return json(429, { status: "error", error: { code: "error.webp.busy" } });
            }
            this.posterBytes.push((await collect(init?.body as ReadableStream)).length);
            if (this.posterFailures > 0) {
                this.posterFailures--;
                return json(500, { status: "error", error: { code: "error.studio.upload_failed" } });
            }
            if (this.posterError) {
                return json(this.posterError.status, { status: "error", error: { code: this.posterError.code } });
            }
            return new Response(this.posterJpeg, {
                headers: { "content-type": "image/jpeg", "content-length": String(this.posterJpeg.length) },
            });
        }

        if (method === "POST" && p === "/jobs/upload") {
            this.uploadQueries.push(u.searchParams);
            if (this.uploadBusy) return json(429, { status: "error", error: { code: "error.webp.busy" } });
            const body = init?.body as ReadableStream;
            this.uploadedBytes.push((await collect(body)).length);
            return json(202, { status: "pending", id: u.searchParams.get("id") });
        }
        if (method === "GET" && /^\/jobs\/[A-Za-z0-9]+$/.test(p)) {
            if (this.jobsGone) return json(404, { status: "error", error: { code: "error.webp.not_found" } });
            if (this.jobPolls > 0) {
                this.jobPolls--;
                return json(200, { status: "pending", ...this.jobPendingFields });
            }
            if (this.jobError) return json(200, { status: "error", error: { code: this.jobError } });
            return json(200, { status: "done", bytes: this.webp.length, width: 480, height: 560, seconds: 5, service: "studio" });
        }
        if (method === "GET" && /^\/jobs\/[A-Za-z0-9]+\/file$/.test(p)) {
            return new Response(this.webp, { headers: { "content-length": String(this.webp.length) } });
        }
        return json(404, { status: "error", error: { code: "error.webp.not_found" } });
    };
}
