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
        };
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
    async delete(key: string) {
        this.objects.delete(key);
    }
}

// R2 stream wrapper for tests: checks the byte count like FixedLengthStream does.
export const fixedLength = (stream: ReadableStream, length: number): ReadableStream => {
    let n = 0;
    return stream.pipeThrough(
        new TransformStream({
            transform(chunk, c) {
                n += chunk.length;
                c.enqueue(chunk);
            },
            flush() {
                if (n !== length) throw new Error(`FixedLengthStream: expected ${length}, got ${n}`);
            },
        }),
    );
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
export class FakeHelper {
    calls: string[] = []; // "METHOD /path"
    videoBytes = new Uint8Array(4096).fill(7);
    busyFetchStarts = 0; // this many POST /fetch answer 429 first
    fetchPolls = 0; // this many GET /fetch/:id answer pending first
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
    jobPolls = 0;
    jobError: string | null = null;
    webp = new Uint8Array(1500).fill(9);
    unreachable = false;

    helper = async (path: string, init?: RequestInit): Promise<Response> => {
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
                return json(200, { status: "pending" });
            }
            if (this.fetchError) return json(200, { status: "error", error: { code: this.fetchError } });
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
            return new Response(this.videoBytes, {
                headers: { "content-length": String(this.fetchFileLength ?? this.videoBytes.length) },
            });
        }
        if (method === "DELETE") {
            this.fetchStarted.delete(p.slice("/fetch/".length));
            return json(200, { status: "success" });
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

        if (method === "POST" && p === "/jobs/upload") {
            this.uploadQueries.push(u.searchParams);
            if (this.uploadBusy) return json(429, { status: "error", error: { code: "error.webp.busy" } });
            const body = init?.body as ReadableStream;
            this.uploadedBytes.push((await collect(body)).length);
            return json(202, { status: "pending", id: u.searchParams.get("id") });
        }
        if (method === "GET" && /^\/jobs\/[A-Za-z0-9]+$/.test(p)) {
            if (this.jobPolls > 0) {
                this.jobPolls--;
                return json(200, { status: "pending" });
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
