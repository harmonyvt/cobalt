// Workbench ops (APP-API-CONTRACT.md 33.11): the chat AI's Linux box, for sites and files the normal tools cannot read.
// AI only (no route), tier free, offered only while the box is on (the WORKBENCH binding and a daily cap above zero).
// The box runs in the Workbench Durable Object (src/workbench.ts); these ops reach it over Workers RPC. A saved file
// goes through the normal upload path (PUT /studio/upload's own code), typed by its bytes, as the chat's key id.
import * as z from "zod";
import { MAX_UPLOAD_BYTES, studioUpload } from "../../app-routes";
import { ITEM_ID_REGEX } from "../../gate";
import type { BoxError, BoxRun, BoxStat, BoxWrite } from "../../workbench-core";
import { BOX_NAME_REGEX, RUN_DEFAULT_S, RUN_MAX_S } from "../../workbench-core";
import { sniffSave } from "../../workbench-rules";
import { defineOp, ok, OpError, type OpContext } from "../op";
import { FILE_SELECT, isSource, type FileRow } from "./make";

// The Workbench object as the ops see it (its RPC methods).
export type WorkbenchPort = {
    run(thread: string, cmd: string, timeoutS?: number): Promise<BoxRun | BoxError>;
    stat(thread: string, path: string): Promise<BoxStat | BoxError>;
    read(thread: string, path: string): Promise<ReadableStream<Uint8Array> | BoxError>;
    write(thread: string, name: string, body: ReadableStream<Uint8Array>): Promise<BoxWrite | BoxError>;
};

export function workbenchPort(ctx: OpContext): WorkbenchPort {
    const ns = ctx.env.WORKBENCH;
    if (!ns) throw new OpError(404, "error.workbench.off", "the workbench is off on this server");
    return ns.get(ns.idFromName("main")) as unknown as WorkbenchPort;
}

const threadOf = (ctx: OpContext) => {
    if (!ctx.chat) throw new OpError(404, "error.chat.off", "only the chat can call this");
    return ctx.chat.threadId;
};

const isError = (v: unknown): v is BoxError => !!v && typeof v === "object" && typeof (v as BoxError).error === "string";

// A stream R2 can store: the Workers runtime needs a known length (FixedLengthStream); elsewhere (the tests) the stream
// goes as it is. Copied chunk by chunk: pipeTo between streams is not implemented in the Workers runtime.
function withLength(stream: ReadableStream<Uint8Array>, size: number): ReadableStream<Uint8Array> {
    const FLS = (globalThis as { FixedLengthStream?: new (n: number) => TransformStream<Uint8Array, Uint8Array> }).FixedLengthStream;
    if (!FLS) return stream;
    const fls = new FLS(size);
    void (async () => {
        const reader = stream.getReader();
        const writer = fls.writable.getWriter();
        try {
            for (;;) {
                const { done, value } = await reader.read();
                if (done) break;
                await writer.write(value);
            }
            await writer.close();
        } catch (e) {
            await writer.abort(e).catch(() => {});
            await reader.cancel(e).catch(() => {});
        }
    })();
    return fls.readable;
}

const baseName = (path: string) => path.split("/").filter(Boolean).pop() ?? "box";

export const boxRunOp = defineOp({
    name: "box.run",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        cmd: z.string().min(1).max(8000),
        timeoutS: z.number().int().min(1).max(RUN_MAX_S).optional().describe(`default ${RUN_DEFAULT_S}, max ${RUN_MAX_S}`),
    }),
    output: z.object({ code: z.number(), stdout: z.string(), stderr: z.string(), timed_out: z.boolean() }),
    ai: {
        tier: "free",
        only: true,
        summary:
            "A bash command in a Linux box with ffmpeg, ffprobe, yt-dlp, curl and python3 (cwd /workspace, public internet over\nhttp/https only). Two uses: full ffmpeg editing of library files (box.pull them in, run any ffmpeg command, box.save the\nresult) when the make/edits ops can't do it, and as the LAST RESORT for a site or file the normal tools can't save. It\nwakes in ~10 s, keeps this thread's files while awake, and is wiped when it sleeps (2 min idle). stdout and stderr come\nback cut to 8 KB each (use ffmpeg -hide_banner -loglevel error -y).",
        params: ["cmd"],
        options: true,
        when: (f) => f.box === true,
    },
    handler: async (ctx, input) => {
        const r = await workbenchPort(ctx).run(threadOf(ctx), input.cmd, input.timeoutS);
        if (isError(r)) throw new OpError(503, "error.workbench", `cobalt.box.run: ${r.error}`);
        return ok({ code: r.code, stdout: r.stdout, stderr: r.stderr, timed_out: r.timed_out });
    },
});

export const boxSaveOp = defineOp({
    name: "box.save",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        path: z.string().min(1).max(1024).describe("relative to /workspace, or absolute"),
        title: z.string().max(200).optional(),
        public: z.boolean().optional().describe("host it publicly too (default false)"),
    }),
    output: z.object({
        post_id: z.string().describe("the new post (use it with library.post, show, look)"),
        kind: z.enum(["video", "image"]),
        bytes: z.number(),
        processing: z.boolean().describe("a video gets its posters and copies made over the next minute"),
        public_url: z.string().nullable(),
    }),
    ai: {
        tier: "free",
        only: true,
        summary: `Put a file from the box into Harmony's library like an upload (jpg png webp gif heic mp4 mov, typed by its bytes, max ${MAX_UPLOAD_BYTES / 1_000_000} MB). Convert anything else with ffmpeg first.`,
        params: ["path"],
        options: true,
        when: (f) => f.box === true,
    },
    handler: async (ctx, input) => {
        const thread = threadOf(ctx);
        const box = workbenchPort(ctx);
        const st = await box.stat(thread, input.path);
        if (isError(st)) throw new OpError(404, "error.workbench", `cobalt.box.save: ${st.error}`);
        if (st.size === 0) throw new OpError(400, "error.library.empty", "cobalt.box.save: the file is empty");
        if (st.size > MAX_UPLOAD_BYTES) {
            throw new OpError(413, "error.library.too_large", `cobalt.box.save: ${Math.ceil(st.size / 1_000_000)} MB is over the ${MAX_UPLOAD_BYTES / 1_000_000} MB cap; make it smaller with ffmpeg`);
        }
        const type = sniffSave(new Uint8Array(st.head));
        if (!type) {
            throw new OpError(415, "error.library.unsupported", "cobalt.box.save: not a jpg, png, webp, gif, heic, mp4 or mov by its bytes; convert it with ffmpeg (e.g. ffmpeg -i in.webm -c:v libx264 -c:a aac out.mp4)");
        }
        const body = await box.read(thread, input.path);
        if (isError(body)) throw new OpError(404, "error.workbench", `cobalt.box.save: ${body.error}`);
        const name = baseName(input.path).replace(/\.[^.]*$/, "") + `.${type.ext}`;
        const q = new URLSearchParams({ name, queue: "1" });
        if (input.title) q.set("title", input.title);
        if (input.public) q.set("public", "1");
        const request = new Request("https://do.internal/studio/upload", {
            method: "PUT",
            headers: { "content-type": type.contentType, "content-length": String(st.size) },
            body: withLength(body, st.size),
            duplex: "half",
        } as RequestInit);
        const r = await studioUpload(ctx.app(), request, ctx.keyId!, q);
        const b = r.body as {
            item?: { id: string; bytes: number | null } | null;
            id?: string | null;
            public_url?: string | null;
            error?: { code?: string };
        };
        if (r.status !== 201 || !b.item) {
            const code = b.error?.code ?? "error.api.generic";
            throw new OpError(r.status, code, `cobalt.box.save failed: ${code}`);
        }
        return ok({
            post_id: b.item.id,
            kind: type.contentType.startsWith("video/") ? "video" : "image",
            bytes: b.item.bytes ?? st.size,
            processing: typeof b.id === "string",
            public_url: b.public_url ?? null,
        });
    },
});

// ---- box.pull: library files into the box (33.11.1) ------------------------------------------------------------------

// What one pull may copy in (the box has 4 GB of disk, and it is wiped on sleep anyway).
export const PULL_MAX_BYTES = 1_000_000_000;
export const PULL_MAX_FILES = 10;

const EXT_BY_TYPE: Record<string, string> = {
    "video/mp4": "mp4",
    "video/quicktime": "mov",
    "video/webm": "webm",
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
    "image/gif": "gif",
    "image/heic": "heic",
    "audio/mpeg": "mp3",
    "audio/mp4": "m4a",
};

function extOf(f: Pick<FileRow, "content_type" | "r2_key">): string {
    const t = (f.content_type ?? "").split(";")[0]!.trim().toLowerCase();
    if (EXT_BY_TYPE[t]) return EXT_BY_TYPE[t]!;
    const m = /\.([A-Za-z0-9]{1,5})$/.exec(f.r2_key);
    return m ? m[1]!.toLowerCase() : "bin";
}

type ReadBucket = { get(key: string): Promise<{ body: ReadableStream<Uint8Array>; size: number } | null> };

function bucketOf(ctx: OpContext, f: FileRow): ReadBucket {
    if (f.bucket === "originals") return ctx.env.ORIGINALS as unknown as ReadBucket;
    if (f.bucket === "media") return ctx.env.MEDIA as unknown as ReadBucket;
    throw new OpError(404, "error.library.not_found", `cobalt.box.pull: file ${f.id} has no stored bytes`);
}

// A post id -> the files it was saved as (every item of a gallery), else every file of the post; a file id -> that file.
async function pullFiles(ctx: OpContext, id: string): Promise<FileRow[]> {
    if (ITEM_ID_REGEX.test(id)) {
        const f = await ctx.db.prepare(`${FILE_SELECT} WHERE id = ?1`).bind(id).first<FileRow>();
        if (f && f.post_key !== id) return [f];
    }
    const { results } = await ctx.db.prepare(`${FILE_SELECT} WHERE post_key = ?1 ORDER BY item_index, created_at, id`).bind(id).all<FileRow>();
    if (results.length === 0) throw new OpError(404, "error.library.not_found", `cobalt.box.pull: no post or file with id ${id}`);
    const sources = results.filter(isSource);
    return (sources.length > 0 ? sources : results).slice(0, PULL_MAX_FILES);
}

const PulledSchema = z.object({
    path: z.string().describe("its name in /workspace"),
    file_id: z.string(),
    content_type: z.string().nullable(),
    bytes: z.number(),
    seconds: z.number().nullable(),
    width: z.number().nullable(),
    height: z.number().nullable(),
});

export const boxPullOp = defineOp({
    name: "box.pull",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        id: z.string().min(1).max(64).describe("a post id (every file it was saved as, up to 10) or one file id"),
        as: z.string().regex(BOX_NAME_REGEX).optional().describe("a file name for a single file (default <file id>.<ext>)"),
    }),
    output: z.object({ files: z.array(PulledSchema) }),
    ai: {
        tier: "free",
        only: true,
        summary: `Copy a library post's files (or one file) into the box's /workspace, to edit with ffmpeg/ffprobe there and put the result back with box.save. Private files too: the box can't send a request body over 64 KB, so they leave it only through box.save. Up to ${PULL_MAX_BYTES / 1_000_000_000} GB a call.`,
        params: ["id"],
        options: true,
        when: (f) => f.box === true,
    },
    handler: async (ctx, input) => {
        const thread = threadOf(ctx);
        const files = await pullFiles(ctx, input.id);
        if (input.as && files.length > 1) throw new OpError(400, "error.make.refused", `cobalt.box.pull: "as" names one file, and post ${input.id} has ${files.length}; pull a file id`);
        const box = workbenchPort(ctx);
        const out: z.infer<typeof PulledSchema>[] = [];
        let total = 0;
        for (const f of files) {
            const obj = await bucketOf(ctx, f).get(f.r2_key);
            if (!obj) throw new OpError(404, "error.library.not_found", `cobalt.box.pull: the bytes of file ${f.id} are missing`);
            total += obj.size;
            if (total > PULL_MAX_BYTES) {
                await obj.body.cancel().catch(() => {});
                throw new OpError(413, "error.library.too_large", `cobalt.box.pull: over ${PULL_MAX_BYTES / 1_000_000_000} GB in one call; pull fewer files`);
            }
            const name = input.as ?? `${f.id}.${extOf(f)}`;
            const w = await box.write(thread, name, obj.body);
            if (isError(w)) throw new OpError(503, "error.workbench", `cobalt.box.pull: ${w.error}`);
            if (w.size !== obj.size) throw new OpError(503, "error.workbench", `cobalt.box.pull: ${name} arrived cut (${w.size} of ${obj.size} bytes); try again`);
            out.push({ path: name, file_id: f.id, content_type: f.content_type, bytes: w.size, seconds: f.duration, width: f.width, height: f.height });
        }
        return ok({ files: out });
    },
});

export const BOX_OPS = [boxRunOp, boxPullOp, boxSaveOp];
