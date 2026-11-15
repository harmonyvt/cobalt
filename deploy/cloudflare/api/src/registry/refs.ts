// The op inputs that name posts, given as links (APP-API-CONTRACT.md section 60): before an op's input is checked, every
// field its `ai.refs` lists that holds a link or file name (src/refs.ts) is swapped for the post or file it names, hidden and
// private posts included. Ids pass through untouched (no lookup). A ref that names nothing fails the call with a one-line
// reason, before anything runs or is asked.
import { looksLikeRef, resolveRefs, unresolvedText } from "../refs";
import { OpError, type Op, type OpContext } from "./op";

type Json = Record<string, unknown>;

export async function withRefs(op: Op, ctx: Pick<OpContext, "db" | "mediaBaseUrl" | "shareBaseUrl">, input: unknown): Promise<unknown> {
    const spec = op.ai.refs;
    if (!spec || !input || typeof input !== "object" || Array.isArray(input)) return input;
    const obj = input as Json;
    const wanted: string[] = [];
    for (const field of Object.keys(spec)) {
        const v = obj[field];
        for (const x of Array.isArray(v) ? v : [v]) if (typeof x === "string" && looksLikeRef(x)) wanted.push(x);
    }
    if (wanted.length === 0) return input;
    const found = await resolveRefs(ctx.db, wanted, { mediaBaseUrl: ctx.mediaBaseUrl, shareBaseUrl: ctx.shareBaseUrl });
    const missing = [...new Set(wanted)].filter((r) => !found.get(r) || found.get(r)!.posts.length === 0);
    if (missing.length > 0) throw new OpError(404, "error.library.not_found", missing.map((r) => unresolvedText(r, found.get(r) ?? null)).join("; "));
    const out: Json = { ...obj };
    for (const [field, mode] of Object.entries(spec)) {
        const v = obj[field];
        const one = (x: unknown): unknown[] => {
            if (typeof x !== "string" || !found.has(x)) return [x];
            const r = found.get(x)!;
            return (mode === "file" || mode === "files") && r.file ? [r.file] : r.posts;
        };
        if (mode === "posts" || mode === "files") {
            if (v === undefined || v === null) continue;
            out[field] = [...new Set((Array.isArray(v) ? v : [v]).flatMap(one))];
        } else if (typeof v === "string" && found.has(v)) {
            const list = one(v);
            if (list.length > 1) {
                throw new OpError(
                    400,
                    "error.library.many_posts",
                    `${v} is a gallery link of ${list.length} posts (${list.join(", ")}): pass one of them`,
                );
            }
            out[field] = list[0];
        }
    }
    return out;
}
