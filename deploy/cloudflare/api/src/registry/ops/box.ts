// Workbench ops (APP-API-CONTRACT.md 33.7): the chat AI's Linux box, for sites and files the normal tools cannot read.
// AI only (no route), tier free, offered only while the box is on (the WORKBENCH binding and a daily cap above zero).
// The box runs in the Workbench Durable Object (src/workbench.ts); these ops reach it over Workers RPC. A saved file
// goes through the normal upload path (PUT /studio/upload's own code), typed by its bytes, as the chat's key id.
import * as z from "zod";
import { MAX_UPLOAD_BYTES, studioUpload } from "../../app-routes";
import type { BoxError, BoxRun, BoxStat } from "../../workbench-core";
import { RUN_DEFAULT_S, RUN_MAX_S } from "../../workbench-core";
import { sniffSave } from "../../workbench-rules";
import { defineOp, ok, OpError, type OpContext } from "../op";

// The Workbench object as the ops see it (its RPC methods).
export type WorkbenchPort = {
    run(thread: string, cmd: string, timeoutS?: number): Promise<BoxRun | BoxError>;
    stat(thread: string, path: string): Promise<BoxStat | BoxError>;
    read(thread: string, path: string): Promise<ReadableStream<Uint8Array> | BoxError>;
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
            "LAST RESORT. A bash command in a Linux box with yt-dlp, curl, ffmpeg and python3 (cwd /workspace, public internet over\nhttp/https only). For a site or file the normal tools can't save. It wakes in ~10 s, keeps this thread's files while\nawake, and is wiped when it sleeps (2 min idle). stdout and stderr come back cut to 8 KB each.",
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

export const BOX_OPS = [boxRunOp, boxSaveOp];
