// Private share links (APP-API-CONTRACT.md section 36): the owner's routes under /share/private, a collection's privacy
// switch, and the chat AI's links.private / links.rotate. The work is in src/private-actions.ts; the share host's /p/
// pages are in src/share-private.ts.
//  - The /share/private routes take the app's client key or the web Worker's library service credential (the web library
//    is the owner's, behind Cloudflare Access), CORS for the web app, no-store. The collection switch is keyed only, like
//    the rest of section 26. While the share host is off they answer 404 error.share.off.
//  - Chat and MCP (36.5): links.private (asks first when turning one off: a gallery link's public URL comes back) and
//    links.rotate (asks). Rotating every key and the new-links setting are the owner's: routes only.
import * as z from "zod";
import { ITEM_ID_REGEX } from "../../gate";
import { linkByKey, PRIVATE_KEY_REGEX, type PrivateKind } from "../../private-links";
import {
    collectionPrivacy,
    currentLink,
    itemOn,
    linkOff,
    linkRotate,
    listPrivate,
    rotateEvery,
    setNewLinksSetting,
    setOn,
    type PrivateDeps,
} from "../../private-actions";
import { COLLECTION_ID_REGEX } from "../../share-collections";
import { HIDDEN_HINT } from "../../hidden";
import { privateFileUrls } from "../../share-private";
import { listShareSets, liveSetRow, SET_ID_REGEX } from "../../share-sets";
import type { StudioReply } from "../../studio";
import { defineOp, ok, OpError, type OpContext, type OpReply } from "../op";
import { linkFiles, shareSetDeps, unwrap } from "./share";

const shareOff = () => new OpError(404, "error.share.off", "share links are off on this server");

export function privateDeps(ctx: OpContext): PrivateDeps | null {
    if (!ctx.shareBaseUrl) return null;
    return { db: ctx.db, vis: ctx.app(), shareBaseUrl: ctx.shareBaseUrl, now: ctx.now, keyId: ctx.keyId ?? "service:library" };
}

const needDeps = (ctx: OpContext): PrivateDeps => {
    const d = privateDeps(ctx);
    if (!d) throw shareOff();
    return d;
};
const reply = (r: StudioReply): OpReply => ({ status: r.status, body: r.body });

// ---- shapes -----------------------------------------------------------------------------------------------------------

const LinkShape = z.object({
    kind: z.enum(["item", "set"]).describe("item: one file; set: a gallery link"),
    target_id: z.string().describe("the file's id or the gallery link's id"),
    url: z.string().describe("share.../p/<key>: the only way in while it is live"),
    created_at: z.number().describe("ms; when this key was made"),
    opened: z.number().describe("page opens (GET)"),
    last_opened_at: z.number().nullable(),
});
const Status = z.literal("success");
const NewLinks = z.enum(["public", "private"]);

// ---- the routes -------------------------------------------------------------------------------------------------------

const NoInput = z.object({});
const none = () => ({});

const route = <I>(o: {
    name: string;
    method: "GET" | "PUT" | "POST" | "PATCH" | "DELETE";
    path: string;
    params?: Record<string, RegExp>;
    input?: z.ZodType<I>;
    badRequest?: string;
    output?: z.ZodType;
    summary: string;
    auth?: "key" | "key_or_service";
    run: (ctx: OpContext, d: PrivateDeps, input: I) => Promise<StudioReply>;
}) =>
    defineOp<I>({
        name: o.name,
        route: { method: o.method, path: o.path, ...(o.params ? { params: o.params } : {}) },
        auth: o.auth ?? "key_or_service",
        runs: "worker",
        cors: true,
        noStore: true,
        input: (o.input ?? NoInput) as z.ZodType<I>,
        ...(o.input ? {} : { http: none }),
        ...(o.badRequest ? { badRequest: o.badRequest } : {}),
        ...(o.output ? { output: o.output } : {}),
        ai: { tier: "hidden", summary: o.summary },
        handler: async (ctx, input) => reply(await o.run(ctx, needDeps(ctx), input)),
    });

const ItemParams = { id: ITEM_ID_REGEX };
const SetParams = { id: SET_ID_REGEX };
const LinkReply = z.object({ status: Status, link: LinkShape });

const ROUTE_OPS = [
    route({
        name: "share_private.list",
        method: "GET",
        path: "/share/private",
        output: z.object({ status: Status, links: z.array(LinkShape), new_links: NewLinks, sets: z.array(z.unknown()) }),
        summary:
            "Every live private link, newest first, whether new gallery links start private, and the gallery links themselves (the section 24 list, for the web Worker, which GET /share/sets refuses) (GET /share/private).",
        run: async (ctx, d) => {
            const r = await listPrivate(d);
            if (r.status !== 200) return r;
            const sd = shareSetDeps(ctx);
            const sets = sd ? await listShareSets(sd) : null;
            const list = sets && sets.status === 200 ? ((sets.body as { sets?: unknown[] }).sets ?? []) : [];
            return { status: 200, body: { ...(r.body as Record<string, unknown>), sets: list } };
        },
    }),
    route({
        name: "share_private.item_on",
        method: "PUT",
        path: "/share/private/items/:id",
        params: ItemParams,
        output: LinkReply,
        summary: "Turn a file's private link on; a public file is made not public first (PUT /share/private/items/<id>).",
        run: (ctx, d) => itemOn(d, ctx.params.id!),
    }),
    route({
        name: "share_private.item_off",
        method: "DELETE",
        path: "/share/private/items/:id",
        params: ItemParams,
        summary: "Revoke a file's private link; the file stays not public (DELETE /share/private/items/<id>).",
        run: (ctx, d) => linkOff(d, "item", ctx.params.id!),
    }),
    route({
        name: "share_private.item_rotate",
        method: "POST",
        path: "/share/private/items/:id/rotate",
        params: ItemParams,
        output: LinkReply,
        summary: "A new key for a file's private link; the old one is a 404 at once.",
        run: (ctx, d) => linkRotate(d, "item", ctx.params.id!),
    }),
    route({
        name: "share_private.set_on",
        method: "PUT",
        path: "/share/private/sets/:id",
        params: SetParams,
        output: LinkReply,
        summary: "Turn a gallery link's private link on; its /g/<id> is a 404 while it is live (PUT /share/private/sets/<id>).",
        run: (ctx, d) => setOn(d, ctx.params.id!),
    }),
    route({
        name: "share_private.set_off",
        method: "DELETE",
        path: "/share/private/sets/:id",
        params: SetParams,
        summary: "Revoke a gallery link's private link; it is public again (DELETE /share/private/sets/<id>).",
        run: (ctx, d) => linkOff(d, "set", ctx.params.id!),
    }),
    route({
        name: "share_private.set_rotate",
        method: "POST",
        path: "/share/private/sets/:id/rotate",
        params: SetParams,
        output: LinkReply,
        summary: "A new key for a gallery link's private link; the old one is a 404 at once.",
        run: (ctx, d) => linkRotate(d, "set", ctx.params.id!),
    }),
    route({
        name: "share_private.rotate_all",
        method: "POST",
        path: "/share/private/rotate-all",
        output: z.object({ status: Status, links: z.array(LinkShape), rotated: z.number() }),
        summary: "Every live private key rotated at once (POST /share/private/rotate-all).",
        run: (_ctx, d) => rotateEvery(d),
    }),
    route({
        name: "share_private.settings",
        method: "PATCH",
        path: "/share/private/settings",
        input: z.object({ new_links: NewLinks }),
        badRequest: "error.private.bad_request",
        output: z.object({ status: Status, new_links: NewLinks }),
        summary: "Whether new gallery links start public or private (PATCH /share/private/settings).",
        run: (_ctx, d, input) => setNewLinksSetting(d, input.new_links),
    }),
    route({
        name: "share_collections.privacy",
        auth: "key",
        method: "POST",
        path: "/share/collections/:id/privacy",
        params: { id: COLLECTION_ID_REGEX },
        input: z
            .object({ private: z.boolean().optional(), rotate: z.literal(true).optional() })
            .refine((b) => (b.private === undefined) !== (b.rotate === undefined), "private or rotate"),
        badRequest: "error.collection.bad_request",
        output: z.object({ status: Status, links: z.array(LinkShape) }),
        summary: "Every gallery link in a collection made private, public again, or rotated (POST /share/collections/<id>/privacy).",
        run: (ctx, d, input) => collectionPrivacy(d, ctx.params.id!, input.rotate ? { rotate: true } : { private: input.private! }),
    }),
];

// ---- the chat AI's calls (36.5) ---------------------------------------------------------------------------------------

type Target = { kind: PrivateKind; id: string; label: string };

// What `link` names: a private link (share.../p/<key>, or the key), a gallery link (its id or share.../g/<id>), or one
// file (a file id, or a post with one file).
async function targetOf(ctx: OpContext, ref: string): Promise<Target> {
    const v = ref.trim();
    const key = /\/p\/([A-Za-z0-9]{22})\/?$/.exec(v)?.[1] ?? (PRIVATE_KEY_REGEX.test(v) ? v : null);
    if (key) {
        const l = await linkByKey(ctx.db, key);
        if (!l) throw new OpError(404, "error.private.not_found", "that private link is not live (rotated or revoked)");
        return { kind: l.kind, id: l.target_id, label: l.kind === "set" ? `gallery link ${l.target_id}` : `file ${l.target_id}` };
    }
    const setId = /\/g\/([0-9]{19})\/?$/.exec(v)?.[1] ?? (SET_ID_REGEX.test(v) ? v : null);
    if (setId) {
        if (!(await liveSetRow(ctx.db, setId))) throw new OpError(404, "error.private.not_found", `no live gallery link ${setId} (cobalt.links.list() lists them)`);
        return { kind: "set", id: setId, label: `gallery link ${setId}` };
    }
    const found = await linkFiles(ctx, [v], { anyState: true });
    if (found.unknown.length > 0 || found.files.length === 0) throw new OpError(404, "error.private.not_found", `no gallery link, post or file ${JSON.stringify(v)}`);
    if (found.files.length > 1) {
        throw new OpError(400, "error.private.bad_request", `that post has ${found.files.length} files: make one gallery link of them with links.create(ids, { private: true })`);
    }
    return { kind: "item", id: found.files[0]!.id, label: `file ${found.files[0]!.id}` };
}

const FileUrls = z
    .array(z.string().nullable())
    .describe("while private: each file's direct link (share.../p/<key>/<n>.<ext>, the bytes, for a download or an import), in the link's order; null for a file that is gone. Anyone holding one can download that file");

// The direct file links of the private link at `url` (share.../p/<key>).
async function fileUrlsOf(ctx: OpContext, d: PrivateDeps, t: Target, url: string): Promise<(string | null)[]> {
    const key = /\/p\/([A-Za-z0-9]{22})$/.exec(url)?.[1];
    return key ? privateFileUrls(ctx.db, d.shareBaseUrl, { kind: t.kind, target_id: t.id, key }) : [];
}

const PrivateOut = z.object({
    link: z.string().describe("what was changed: a gallery link id or a file id"),
    kind: z.enum(["item", "set"]),
    private: z.boolean(),
    url: z.string().nullable().describe("the link that works now: the private one, the gallery link's public one, or null for a file with no link"),
    file_urls: FileUrls.optional(),
});

const PRIVATE_MESSAGES: Record<string, string> = {
    "error.private.not_toggleable": "that file cannot have a private link (only originals and webps can)",
    "error.private.not_found": "no such live file or gallery link",
    "error.hidden": HIDDEN_HINT,
};

export const linksPrivateOp = defineOp({
    name: "links.private",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        link: z.string().min(1).max(2048).describe("a gallery link id or URL, a private link URL, a file id, or a post with one file"),
        private: z.boolean().describe("true: only a secret share.../p/<key> URL works; false: the private link is revoked"),
    }),
    output: PrivateOut,
    ai: {
        tier: "ask",
        asks: (input) => input.private === false,
        only: true,
        summary:
            "Make a gallery link or a file private (only a secret share.../p/<key> URL opens it; the public URL becomes a 404; a public file stops being public) or revoke that private link (a gallery link is public again, a file stays not public). Returns the URL that works now, and while private each file's direct link (file_urls).",
        params: ["link", "private"],
        preview: async (ctx, input) => {
            const t = await targetOf(ctx, input.link);
            return {
                summary: `revoke the private link of ${t.label}`,
                effect: { link: t.id, kind: t.kind, private_link_stops_working: true, public_again: t.kind === "set" },
            };
        },
    },
    handler: async (ctx, input) => {
        const d = needDeps(ctx);
        const t = await targetOf(ctx, input.link);
        const publicUrl = t.kind === "set" ? `${d.shareBaseUrl.replace(/\/?$/, "/")}g/${t.id}` : null;
        if (input.private) {
            const body = unwrap<{ link: { url: string } }>(t.kind === "item" ? await itemOn(d, t.id) : await setOn(d, t.id), PRIVATE_MESSAGES);
            return ok({ link: t.id, kind: t.kind, private: true, url: body.link.url, file_urls: await fileUrlsOf(ctx, d, t, body.link.url) });
        }
        unwrap(await linkOff(d, t.kind, t.id), PRIVATE_MESSAGES);
        return ok({ link: t.id, kind: t.kind, private: false, url: publicUrl });
    },
});

export const linksRotateOp = defineOp({
    name: "links.rotate",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ link: z.string().min(1).max(2048).describe("a private link URL, or its gallery link id or file id") }),
    output: z.object({ link: z.string(), kind: z.enum(["item", "set"]), url: z.string().describe("the new private URL"), file_urls: FileUrls }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Give a private link a new key: the old share.../p/<key> URL stops working at once.",
        params: ["link"],
        preview: async (ctx, input) => {
            const t = await targetOf(ctx, input.link);
            const d = needDeps(ctx);
            const now = await currentLink(d, t.kind, t.id);
            if (!now) throw new OpError(404, "error.private.not_found", `${t.label} has no private link to rotate`);
            return { summary: `rotate the private link of ${t.label}`, effect: { link: now.url, opened: now.opened, old_link_stops_working: true } };
        },
    },
    handler: async (ctx, input) => {
        const d = needDeps(ctx);
        const t = await targetOf(ctx, input.link);
        const body = unwrap<{ link: { url: string } }>(await linkRotate(d, t.kind, t.id), {
            ...PRIVATE_MESSAGES,
            "error.private.not_found": `${t.label} has no private link to rotate`,
        });
        return ok({ link: t.id, kind: t.kind, url: body.link.url, file_urls: await fileUrlsOf(ctx, d, t, body.link.url) });
    },
});

export const PRIVATE_OPS = [...ROUTE_OPS, linksPrivateOp, linksRotateOp];
