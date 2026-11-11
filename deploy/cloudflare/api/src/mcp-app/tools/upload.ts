// upload_files: short-lived links to PUT local files to (MCP-APP-CONTRACT.md section 4); the widget sends the files
// itself, a host with no widget gets a ready curl line for each.
import * as z from "zod";
import { MAX_UPLOAD_BYTES, UPLOAD_TYPES } from "../../app-routes";
import { UploadOut } from "../shapes";
import type { AppTool } from "../types";
import { arr, int, plural, rec, str } from "./common";

const Input = z.object({
    files: z
        .array(z.object({ name: z.string().min(1).max(200), title: z.string().min(1).max(200).optional() }))
        .min(1)
        .max(10)
        .optional(),
    public: z.boolean().optional(),
});

// 'image/jpeg' -> '.jpg'
const extensions = (types: unknown): string[] => {
    const list = arr(types).filter((t): t is string => typeof t === "string");
    const exts = (list.length > 0 ? list.map((t) => UPLOAD_TYPES[t]) : Object.values(UPLOAD_TYPES)).filter((e): e is string => !!e);
    const out = [...new Set(exts)].map((e) => `.${e}`);
    // a jpeg file is as often .jpeg as .jpg
    return out.includes(".jpg") && !out.includes(".jpeg") ? [...out, ".jpeg"] : out;
};

// a file name inside single quotes for a shell
const shellQuote = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

export const uploadFiles: AppTool<z.infer<typeof Input>> = {
    name: "upload_files",
    title: "Upload files",
    description:
        "Get upload links (15 minutes) for up to 10 local videos or images to add to the capystore library. Each link takes the file's bytes with an HTTP PUT; the answer includes a ready curl command per file.",
    input: Input,
    output: UploadOut,
    readOnly: false,
    annotations: { destructiveHint: false, openWorldHint: false },
    view: "upload",
    async run(ctx, input) {
        const wanted = input.files ?? [{ name: "", title: undefined as string | undefined }];
        const isPublic = input.public === true;
        const made = await Promise.all(
            wanted.map(async (f) => {
                const r = rec(
                    await ctx.call("upload.begin", {
                        ...(f.name ? { name: f.name } : {}),
                        ...(f.title ? { title: f.title } : {}),
                        ...(isPublic ? { public: true } : {}),
                    }),
                );
                return { name: f.name, r };
            }),
        );
        const first = made[0]!.r;
        const uploads = made.map(({ name, r }) => {
            const url = str(r.upload_url) ?? "";
            return {
                name: name || "file",
                upload_url: url,
                expires_at: str(r.expires_at) ?? new Date(ctx.op.now()).toISOString(),
                // the op's own line has a FILE placeholder; the file's name stands there when there is one
                curl: `curl -sS -T ${name ? shellQuote(name) : "FILE"} '${url}'`,
            };
        });
        const maxBytes = int(first.max_bytes, MAX_UPLOAD_BYTES);
        const accept = extensions(first.types);
        const mb = Math.round(maxBytes / 1_000_000);
        const text = [
            `${plural(uploads.length, "upload link")} ready (valid for 15 minutes, up to ${mb} MB each; ${accept.map((a) => a.slice(1)).join(", ")}${isPublic ? "; the files will be public" : ""}).`,
            ...uploads.map((u, i) => `${i + 1}. ${u.name}: ${u.curl}`),
            "Each file is added to the library when its upload finishes.",
        ].join("\n");
        return { text, structured: { view: "upload", uploads, max_bytes: maxBytes, accept, public: isPublic } satisfies z.infer<typeof UploadOut> };
    },
};
