// The local MCP dev server (widgets-dev/mcp-dev.mjs bundles this file). It runs the REAL MCP code path
// (serveMcpRequest with the real app tools, widgets and op registry) over an in-memory seeded database, so a person can
// point a host at it (through a tunnel) and try the app without a deploy. Demo data only; it never touches the cloud.
//
// What is real: the registry, the zod checks, the chat read ops (library, post, links, collections), the share-link and
// collection writes, upload.begin and PUT /mcp/upload/<token> (the Worker's own handler on in-memory R2 fakes).
// What is faked (ops that need a container or a Durable Object): make.webp and jobs.wait (a job that runs, then makes a
// post), library.save (a save that takes a few seconds), edits.list and edits.get (two canned projects).
import { createReadStream, existsSync, readFileSync, statSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { Readable } from "node:stream";
import { createFakeD1 } from "../../test-support/d1-sqlite";
import { hashKey } from "../src/keys";
import type { McpCaller } from "../src/mcp";
import { claudeUiDomain, serveMcpRequest } from "../src/mcp-app/server";
import { forCall, opBase } from "../src/registry/context";
import { REGISTRY } from "../src/registry/index";
import { ok, OpError, type Op } from "../src/registry/op";
import { Registry } from "../src/registry/registry";
import { getSession, sessionBody } from "../src/studio";
import { handleRequest, type WorkerEnv } from "../src/worker";
import { withBatch } from "../test/d1-batch";
import { fixedLengthPair, MemoryMedia, MemoryOriginals } from "../test/studio-fakes";
import { placeholderSvg, randomId, seedDemo } from "./mcp-dev-seed";

export type DevOptions = {
    port?: number;
    host?: string;
    // the origin hosts reach this server at (a tunnel URL); default http://localhost:<port>
    publicUrl?: string;
    // how long the fake webp encode and save take
    webpMs?: number;
    saveMs?: number;
    // a single call waits at most this long, so a widget sees a job running (the real ops wait up to 8 s or more)
    waitCapMs?: number;
    // a small mp4 served for every demo video (the CLI makes one with ffmpeg when it can)
    sampleVideo?: string | null;
    log?: (line: string) => void;
};

export type DevServer = {
    server: Server;
    port: number;
    // the origin hosts connect to, and the MCP URL
    publicOrigin: string;
    mcpUrl: string;
    mediaBase: string;
    claudeDomain: string;
    close(): Promise<void>;
};

const API_KEY_ID = "dev-key-1";
const INTERNAL_KEY = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export async function startDevServer(o: DevOptions = {}): Promise<DevServer> {
    const log = o.log ?? (() => {});
    const webpMs = o.webpMs ?? 7000;
    const saveMs = o.saveMs ?? 5000;
    const waitCap = o.waitCapMs ?? 2000;

    // the port is known after listen(); the URLs are built from it unless a public URL was given
    const server = createServer();
    await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(o.port ?? 8788, o.host, resolve);
    });
    const port = (server.address() as { port: number }).port;
    const publicUrl = (o.publicUrl ?? `http://localhost:${port}`).replace(/\/+$/, "");
    const origin = new URL(publicUrl).origin;
    const MEDIA = `${origin}/media/`;
    const SHARE = `${origin}/s/`;
    const mcpUrl = `${origin}/mcp`;

    // ---- the database and the fakes
    const db = withBatch(createFakeD1());
    const now = () => Date.now();
    db.raw.prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)").run(API_KEY_ID, "dev demo", await hashKey("0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11"), "0b5f2c3e", now());
    const seeded = seedDemo(db, { mediaBase: MEDIA, shareBase: SHARE, now: now(), keyId: API_KEY_ID });
    const media = new MemoryMedia();
    const originals = new MemoryOriginals();
    // private demo files for the signed previews (/mcp/media/<token>): a one-pixel JPEG for a picture, the sample for a video
    const JPEG = Buffer.from("/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=", "base64");
    for (const r of db.raw.prepare("SELECT r2_key, content_type FROM media_items WHERE bucket = 'originals'").all() as { r2_key: string; content_type: string }[]) {
        const bytes = r.content_type.startsWith("video/") && o.sampleVideo && existsSync(o.sampleVideo) ? readFileSync(o.sampleVideo) : JPEG;
        originals.objects.set(r.r2_key, { bytes: new Uint8Array(bytes), contentType: r.content_type, meta: {} });
    }
    const env = {
        API_URL: `${origin}/`,
        CORS_URL: origin,
        COBALT_API_KEY: INTERNAL_KEY,
        DB: db as unknown as D1Database,
        ORIGINALS: originals,
        MEDIA: media,
        MEDIA_BASE_URL: MEDIA,
        SHARE_BASE_URL: SHARE,
    } as unknown as WorkerEnv;

    // ---- jobs the fake ops run
    type Job = { id: string; startedAt: number; ms: number; done: boolean; result: Record<string, unknown> | null; error: string | null };
    const jobs = new Map<string, Job>();
    const insertMedia = (f: { id: string; key: string; ext: string; type: string; title: string; secs?: number | null; w: number; h: number; pub: boolean; source: string; link?: string | null; session?: string | null; post?: string }) => {
        const name = `${f.key}.${f.ext}`;
        db.raw
            .prepare(
                `INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at, poster, visibility, post_key)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)`,
            )
            .run(f.id, f.pub ? "public" : "private", f.source, f.pub ? "media" : "originals", f.pub ? name : `originals/${f.id}.${f.ext}`, f.pub ? `${MEDIA}${name}` : null, name, f.type, 90_000, f.w, f.h, f.secs ?? null, f.link ?? null, f.session ?? null, API_KEY_ID, now(), f.pub ? "public" : "private", f.post ?? f.id);
        db.raw.prepare("INSERT OR REPLACE INTO media_titles (post_key, title, key_id, updated_at) VALUES (?, ?, ?, ?)").run(f.post ?? f.id, f.title, API_KEY_ID, now());
    };
    const titleOf = (id: string) => (db.raw.prepare("SELECT t.title FROM media_titles t WHERE t.post_key = ?1 OR t.post_key = (SELECT post_key FROM media_items WHERE id = ?1)").get(id) as { title?: string } | undefined)?.title ?? "Demo clip";

    const waitFor = async (job: Job, seconds: number) => {
        const until = now() + Math.min(seconds * 1000, waitCap);
        while (!job.done && now() < until) await sleep(100);
    };
    const jobBody = (job: Job) => {
        if (job.error) return { job: job.id, status: "error", error: job.error };
        if (job.done) return { job: job.id, status: "done", ...job.result };
        return { job: job.id, status: "running", progress: Math.min(0.95, Math.round(((now() - job.startedAt) / job.ms) * 100) / 100), queue_ahead: null };
    };

    // ---- the faked ops: same names, schemas and tiers as the real ones, a handler that needs no container
    const fake = (name: string, handler: NonNullable<Op["handler"]>): Op => {
        const real = REGISTRY.op(name);
        if (!real) throw new Error(`no op ${name}`);
        return { ...real, runs: "worker", handler };
    };
    const faked: Op[] = [
        fake("make.webp", async (_ctx, input: { id: string; start: number; end: number; width?: number }) => {
            const srcTitle = titleOf(input.id);
            const id = `studio:${randomId(22)}:${randomId(20)}`;
            const job: Job = { id, startedAt: now(), ms: webpMs, done: false, result: null, error: null };
            jobs.set(id, job);
            setTimeout(() => {
                const fid = randomId(16);
                const key = `Webp${randomId(8)}`;
                const w = input.width ?? 480;
                insertMedia({ id: fid, key, ext: "webp", type: "image/webp", title: `${srcTitle} (webp)`, w, h: Math.round(w * 1.78), pub: true, source: "webp" });
                job.result = { file_id: fid, post_id: fid, kind: "image", public: true, bytes: 84_000, width: w, height: Math.round(w * 1.78), seconds: Math.round((input.end - input.start) * 10) / 10, share_url: `${SHARE}${key}` };
                job.done = true;
                log(`webp job ${id} done`);
            }, webpMs).unref();
            return ok({ job: id, status: "running", queue_ahead: null });
        }),
        fake("jobs.wait", async (_ctx, input: { job: string; seconds?: number }) => {
            const job = jobs.get(input.job);
            if (!job) throw new OpError(404, "error.studio.not_found", `no job ${input.job}`);
            await waitFor(job, input.seconds ?? 15);
            return ok(jobBody(job));
        }),
        fake("library.save", async (_ctx, input: { url: string; wait?: number }) => {
            const sid = randomId(22);
            const host = (() => {
                try {
                    return new URL(input.url).hostname.replace(/^www\./, "");
                } catch {
                    return "link";
                }
            })();
            const fails = /fail|broken/i.test(input.url);
            db.raw
                .prepare("INSERT INTO studio_sessions (id, key_id, link, service, title, status, created_at, expires_at) VALUES (?, ?, ?, ?, ?, 'saving', ?, ?)")
                .run(sid, API_KEY_ID, input.url, host.split(".")[0]!, null, now(), now() + 7 * 86_400_000);
            const job: Job = { id: sid, startedAt: now(), ms: saveMs, done: false, result: null, error: null };
            jobs.set(`save:${sid}`, job);
            setTimeout(() => {
                if (fails) {
                    db.raw.prepare("UPDATE studio_sessions SET status = 'error', error_code = 'error.api.fetch.fail' WHERE id = ?").run(sid);
                    job.error = "error.api.fetch.fail";
                } else {
                    const title = `Saved from ${host}`;
                    const fid = randomId(16);
                    insertMedia({ id: fid, key: `Save${randomId(8)}`, ext: "mp4", type: "video/mp4", title, secs: 12, w: 720, h: 1280, pub: false, source: "saved", link: input.url, session: sid, post: sid });
                    db.raw.prepare("UPDATE studio_sessions SET status = 'ready', title = ?, r2_key = ?, content_type = 'video/mp4', bytes = 2400000, duration = 12, width = 720, height = 1280 WHERE id = ?").run(title, `originals/${fid}.mp4`, sid);
                    job.result = { title };
                }
                job.done = true;
                log(`save ${sid} ${fails ? "failed" : "ready"}`);
            }, saveMs).unref();
            await waitFor(job, input.wait ?? 8);
            const base = { save_id: sid, public: null, saves_left_today: 9 };
            if (job.error) return ok({ ...base, status: "error", post_id: null, title: null, kind: null, files: null, error: job.error });
            if (job.done) return ok({ ...base, status: "ready", post_id: sid, title: String(job.result!.title), kind: "video", files: 1, public: false, error: null });
            return ok({ ...base, status: "saving", post_id: null, title: null, kind: null, files: null, error: null });
        }),
        fake("edits.list", async () => ok(seeded.editProjects.map(({ id, title, revision, duration, render }) => ({ id, title, revision, duration, render })))),
        fake("edits.get", async (_ctx, input: { id: string }) => {
            const p = seeded.editProjects.find((x) => x.id === input.id);
            if (!p) throw new OpError(404, "error.edit.not_found", `no edit project ${input.id}`);
            return ok(p);
        }),
    ];
    const byName = new Map(faked.map((op) => [op.name, op]));
    const registry = new Registry(REGISTRY.ops.map((op) => byName.get(op.name) ?? op));

    // the studio Durable Object of the real Worker advances a save when asked; this one answers from the fake save
    const container = {
        async fetch(req: Request) {
            const url = new URL(req.url);
            const m = /^\/studio\/([A-Za-z0-9]{22})\/advance$/.exec(url.pathname);
            if (!m) return Response.json({ status: "error", error: { code: "error.dev.no_container" } }, { status: 503 });
            const job = jobs.get(`save:${m[1]}`);
            if (job) await waitFor(job, Number(url.searchParams.get("wait") ?? 0));
            const row = await getSession(db, m[1]!);
            if (!row) return Response.json({ status: "error", error: { code: "error.studio.not_found" } }, { status: 404 });
            return Response.json(sessionBody(row, [], null, null));
        },
    };
    const edge = { now, sleep, fixedLength: fixedLengthPair } as never;
    const base = { ...opBase(env, container, edge, registry), shareBaseUrl: SHARE };
    const callerFor = (): McpCaller => ({ ctx: forCall(base, { keyId: API_KEY_ID, caller: "key" }), clientKeyId: API_KEY_ID, origin });

    // ---- http
    const cors = (res: ServerResponse) => {
        res.setHeader("access-control-allow-origin", "*");
        res.setHeader("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS");
        res.setHeader("access-control-allow-headers", "content-type, accept, authorization, mcp-protocol-version, mcp-session-id");
    };
    const send = async (res: ServerResponse, r: Response) => {
        const headers: Record<string, string> = {};
        r.headers.forEach((v, k) => (headers[k] = v));
        if (!res.hasHeader("access-control-allow-origin")) cors(res);
        res.writeHead(r.status, headers);
        if (!r.body) return void res.end();
        const reader = r.body.getReader();
        for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            res.write(value);
        }
        res.end();
    };
    const text = (res: ServerResponse, status: number, body: string, type = "text/plain") => {
        cors(res);
        res.writeHead(status, { "content-type": `${type}; charset=utf-8` }).end(body);
    };
    const readBody = (req: IncomingMessage) =>
        new Promise<string>((resolve, reject) => {
            const chunks: Buffer[] = [];
            req.on("data", (c) => chunks.push(c));
            req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
            req.on("error", reject);
        });
    const headersOf = (req: IncomingMessage) => {
        const h = new Headers();
        for (const [k, v] of Object.entries(req.headers)) if (v !== undefined) h.set(k, Array.isArray(v) ? v.join(", ") : v);
        return h;
    };

    // POST /mcp: one message or a batch, answered by the real server code (no auth: the demo key is the caller)
    async function mcp(req: IncomingMessage, res: ServerResponse, path: string) {
        const raw = await readBody(req);
        let body: unknown;
        try {
            body = JSON.parse(raw);
        } catch {
            return text(res, 400, JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } }), "application/json");
        }
        const headers = headersOf(req);
        headers.delete("content-length");
        const one = (m: unknown) => serveMcpRequest(registry, callerFor(), new Request(`${origin}${path}`, { method: "POST", headers, body: JSON.stringify(m) }), m);
        if (!Array.isArray(body)) return send(res, await one(body));
        const replies: unknown[] = [];
        for (const m of body.slice(0, 20)) {
            const r = await one(m);
            if (r.status !== 202) replies.push(await r.json());
        }
        return replies.length ? text(res, 200, JSON.stringify(replies), "application/json") : void (cors(res), res.writeHead(202).end());
    }

    // PUT /mcp/upload/<token> and its preflight: the Worker's own handler, on a stand-in host
    async function upload(req: IncomingMessage, res: ServerResponse, pathAndQuery: string) {
        const hasBody = req.method !== "GET" && req.method !== "HEAD";
        const request = new Request(`http://dev-api.local${pathAndQuery}`, {
            method: req.method,
            headers: headersOf(req),
            ...(hasBody ? { body: Readable.toWeb(req) as ReadableStream, duplex: "half" } : {}),
        } as RequestInit);
        const r = await handleRequest(request, env, container, { now, sleep, fixedLength: fixedLengthPair, registry });
        log(`${req.method} ${pathAndQuery.split("?")[0]!.replace(/\/upload\/.*/, "/upload/…")} -> ${r.status}`);
        await send(res, r);
    }

    // GET /media/<name>: uploaded files as they were stored, demo pictures drawn on the fly, demo videos from one sample
    function mediaFile(req: IncomingMessage, res: ServerResponse, name: string) {
        const stored = media.objects.get(name);
        if (stored) {
            cors(res);
            return void res.writeHead(200, { "content-type": stored.contentType ?? "application/octet-stream", "cache-control": "no-store" }).end(Buffer.from(stored.data));
        }
        if (name.endsWith(".mp4")) {
            if (!o.sampleVideo || !existsSync(o.sampleVideo)) return text(res, 404, "no sample video (install ffmpeg)");
            const size = statSync(o.sampleVideo).size;
            const m = /^bytes=(\d*)-(\d*)$/.exec(String(req.headers.range ?? ""));
            const start = m && m[1] ? Number(m[1]) : 0;
            const end = m && m[2] ? Math.min(Number(m[2]), size - 1) : size - 1;
            cors(res);
            res.writeHead(m ? 206 : 200, { "content-type": "video/mp4", "accept-ranges": "bytes", "content-length": end - start + 1, ...(m ? { "content-range": `bytes ${start}-${end}/${size}` } : {}) });
            return void createReadStream(o.sampleVideo, { start, end }).pipe(res);
        }
        const key = name.startsWith("Poster") ? name.slice(6).replace(/\.[a-z0-9]+$/, "") : name.replace(/\.[a-z0-9]+$/, "");
        const row = db.raw.prepare("SELECT id, post_key, content_type, duration FROM media_items WHERE r2_key LIKE ?1 || '.%' AND deleted_at IS NULL").get(key) as { id: string; post_key: string; content_type: string; duration: number | null } | undefined;
        if (!row) return text(res, 404, "not found");
        const kind = row.content_type?.startsWith("video/") ? "video" : row.content_type === "image/webp" ? "webp" : "image";
        const svg = placeholderSvg({ name: key, title: titleOf(row.post_key), kind, secs: row.duration });
        cors(res);
        res.writeHead(200, { "content-type": "image/svg+xml", "cache-control": "no-store" }).end(svg);
    }

    function sharePage(res: ServerResponse, pathname: string) {
        const key = pathname.slice(3).replace(/\.[a-z0-9]+$/, "");
        const row = db.raw.prepare("SELECT id, post_key, name, r2_key FROM media_items WHERE r2_key LIKE ?1 || '.%' AND deleted_at IS NULL").get(key) as { post_key: string; r2_key: string } | undefined;
        const title = row ? titleOf(row.post_key) : "capystore demo share page";
        const image = row ? `${MEDIA}${row.r2_key}` : "";
        text(res, 200, `<!doctype html><meta charset="utf-8"><title>${title}</title><meta property="og:title" content="${title}">${image ? `<meta property="og:image" content="${image}">` : ""}<body style="font:16px system-ui;margin:2rem"><h1>${title}</h1><p>Demo share page (dev server, demo data only).</p>${image ? `<img src="${image}" style="max-width:360px">` : ""}`, "text/html");
    }

    server.on("request", (req, res) => {
        const url = new URL(req.url ?? "/", "http://x");
        const path = url.pathname;
        void (async () => {
            try {
                if (req.method === "OPTIONS" && !path.startsWith("/mcp/upload/") && !path.startsWith("/mcp/media/")) return void (cors(res), res.writeHead(204, { "access-control-max-age": "600" }).end());
                if (path === "/mcp" || path.startsWith("/mcp/k/")) {
                    if (req.method === "POST") return await mcp(req, res, path + url.search);
                    return void (cors(res), res.writeHead(405, { allow: "POST" }).end());
                }
                if (path.startsWith("/mcp/upload/") || path.startsWith("/mcp/media/")) return await upload(req, res, path + url.search);
                if (path.startsWith("/media/") && (req.method === "GET" || req.method === "HEAD")) return mediaFile(req, res, decodeURIComponent(path.slice(7)));
                if (path.startsWith("/s/")) return sharePage(res, path);
                if (path === "/") return text(res, 200, `capystore MCP dev server (demo data only)\nMCP URL: ${mcpUrl}\n`);
                return text(res, 404, "not found");
            } catch (e) {
                log(`error ${req.method} ${path}: ${e instanceof Error ? e.stack : String(e)}`);
                if (!res.headersSent) text(res, 500, "dev server error");
                else res.end();
            }
        })();
    });

    return {
        server,
        port,
        publicOrigin: origin,
        mcpUrl,
        mediaBase: MEDIA,
        claudeDomain: await claudeUiDomain(mcpUrl),
        close: () => new Promise<void>((r) => (server.closeAllConnections?.(), server.close(() => r()))),
    };
}
