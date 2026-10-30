// Hidden posts and auto-hide rules (APP-API-CONTRACT.md section 37): the bulk status route and the rules under /hidden,
// and the chat AI's calls (37.6, which the MCP serves as tools like every chat op). The work is in src/hidden.ts.
//  - The routes take the app's client key or the web Worker's library service credential (the web library is the
//    owner's, behind Cloudflare Access), CORS for the web app, no-store. Until migration 0025 they answer 503.
//  - Chat and MCP: library.status (free for hidden/off, asks for public/private and whenever it would unhide),
//    library.hidden (free), hidden.rules.list / .preview (free), .add (asks with apply), .update / .delete (ask).
import * as z from "zod";
import { loadPosts } from "../../chat-tools";
import {
    addRule,
    CHAT_STATUS_IDS_MAX,
    deleteRule,
    hiddenList,
    hiddenTargets,
    HIDDEN_RULES_MAX,
    listRules,
    postKeysOf,
    previewRule,
    RULE_KINDS,
    setStatus,
    STATUSES,
    STATUS_IDS_MAX,
    updateRule,
    type HiddenDeps,
    type Status as StatusName,
} from "../../hidden";
import { HIDDEN_RULE_ID_REGEX } from "../../hidden-store";
import type { StudioReply } from "../../studio";
import { defineOp, ok, OpError, type OpContext, type OpReply } from "../op";
import { PostSchema } from "./library";
import { unwrap } from "./share";

export function hiddenDeps(ctx: OpContext): HiddenDeps {
    return { db: ctx.db, vis: ctx.app(), shareBaseUrl: ctx.shareBaseUrl, now: ctx.now, keyId: ctx.keyId ?? "service:library" };
}
const byOf = (ctx: OpContext) => (ctx.caller === "chat" ? ("chat" as const) : ("you" as const));
const reply = (r: StudioReply): OpReply => ({ status: r.status, body: r.body });

// ---- shapes -----------------------------------------------------------------------------------------------------------

const Status = z.literal("success");
const StatusEnum = z.enum(STATUSES as [StatusName, ...StatusName[]]);
const KindEnum = z.enum(RULE_KINDS as ["site", "words", "about", "upload"]);

export const HiddenRuleShape = z
    .object({
        id: z.string(),
        kind: KindEnum,
        value: z.string().describe("normalized: lower case, trimmed; '' for upload"),
        enabled: z.boolean(),
        hits: z.number().int().describe("posts this rule has hidden"),
        created_at: z.number().int(),
        updated_at: z.number().int(),
    })
    .meta({ id: "HiddenRule" });

const Failed = z.array(z.object({ id: z.string(), error: z.string().describe("an error code") })).describe("ids (or files) that did not get the status");
const StatusReply = z.object({
    status: Status,
    posts: z.array(
        z.object({
            id: z.string().describe("the id sent"),
            post_key: z.string(),
            status: StatusEnum,
            files: z.array(z.looseObject({ id: z.string(), visibility: z.string(), private_url: z.string().nullable() })),
        }),
    ),
    failed: Failed,
});
const RuleReply = z.object({ status: Status, rule: HiddenRuleShape, applied: z.number().int() });

const RuleValue = z.string().max(400);

// ---- the routes (37.4) --------------------------------------------------------------------------------------------------

const route = <I>(o: {
    name: string;
    method: "GET" | "POST" | "PATCH" | "DELETE";
    path: string;
    params?: Record<string, RegExp>;
    input?: z.ZodType<I>;
    badRequest?: string;
    output?: z.ZodType;
    summary: string;
    run: (ctx: OpContext, input: I) => Promise<StudioReply>;
}) =>
    defineOp<I>({
        name: o.name,
        route: { method: o.method, path: o.path, ...(o.params ? { params: o.params } : {}) },
        auth: "key_or_service",
        runs: "worker",
        cors: true,
        noStore: true,
        input: (o.input ?? z.object({})) as z.ZodType<I>,
        ...(o.input ? {} : { http: () => ({}) }),
        ...(o.badRequest ? { badRequest: o.badRequest } : {}),
        ...(o.output ? { output: o.output } : {}),
        ai: { tier: "hidden", summary: o.summary },
        handler: async (ctx, input) => reply(await o.run(ctx, input)),
    });

const RuleParams = { id: HIDDEN_RULE_ID_REGEX };

const ROUTE_OPS = [
    route({
        name: "library.status.route",
        method: "POST",
        path: "/library/status",
        input: z.object({ ids: z.array(z.string().min(1).max(2048)).min(1).max(STATUS_IDS_MAX), status: StatusEnum }),
        badRequest: "error.library.bad_request",
        output: StatusReply,
        summary: "Many posts (file or post ids) to one status at once: off, public, private (each file's own private link) or hidden (POST /library/status).",
        run: (ctx, input) => setStatus(hiddenDeps(ctx), input.ids, input.status, byOf(ctx)),
    }),
    route({
        name: "hidden_rules.list",
        method: "GET",
        path: "/hidden/rules",
        output: z.object({ status: Status, rules: z.array(HiddenRuleShape), hidden: z.number().int(), held: z.number().int() }),
        summary: "The auto-hide rules, oldest first, and how many posts are hidden and held (GET /hidden/rules).",
        run: (ctx) => listRules(ctx),
    }),
    route({
        name: "hidden_rules.create",
        method: "POST",
        path: "/hidden/rules",
        input: z.object({ kind: KindEnum, value: RuleValue.optional(), enabled: z.boolean().optional(), apply: z.boolean().optional() }),
        badRequest: "error.hidden.bad_rule",
        output: RuleReply,
        summary: `A new auto-hide rule (at most ${HIDDEN_RULES_MAX}); apply also hides what is saved now (POST /hidden/rules).`,
        run: (ctx, input) => addRule(hiddenDeps(ctx), input),
    }),
    route({
        name: "hidden_rules.preview",
        method: "POST",
        path: "/hidden/rules/preview",
        input: z.object({ kind: KindEnum, value: RuleValue.optional() }),
        badRequest: "error.hidden.bad_rule",
        output: z.object({ status: Status, matches: z.number().int(), sample: z.array(z.string()).describe("up to 6 post keys, newest first") }),
        summary: "What a rule would hide now, changing nothing (POST /hidden/rules/preview).",
        run: (ctx, input) => previewRule(ctx, input),
    }),
    route({
        name: "hidden_rules.update",
        method: "PATCH",
        path: "/hidden/rules/:id",
        params: RuleParams,
        input: z.object({ id: z.string(), enabled: z.boolean().optional(), value: RuleValue.optional(), apply: z.boolean().optional() }),
        badRequest: "error.hidden.bad_rule",
        output: RuleReply,
        summary: "Turn a rule on or off, change its value, or apply it now (PATCH /hidden/rules/<id>).",
        run: (ctx, input) => updateRule(hiddenDeps(ctx), ctx.params.id!, input),
    }),
    route({
        name: "hidden_rules.delete",
        method: "DELETE",
        path: "/hidden/rules/:id",
        params: RuleParams,
        summary: "Delete a rule; the posts it hid stay hidden (DELETE /hidden/rules/<id>).",
        run: (ctx) => deleteRule(ctx, ctx.params.id!),
    }),
];

// ---- the chat AI's calls (37.6) ---------------------------------------------------------------------------------------


const MESSAGES: Record<string, string> = {
    "error.hidden.bad_rule":
        "a rule is { kind: site | words | about | upload, value }: site is a host or host/path (x.com/name), words 1 to 60 characters, about 1 to 40",
    "error.hidden.too_many": `there are already ${HIDDEN_RULES_MAX} rules`,
    "error.hidden.not_found": "no such rule (cobalt.hidden.rules.list() lists them)",
    "error.api.generic": "hidden posts are not set up on this server yet",
};

const ChatIds = z.preprocess(
    (v) => [...new Set(Array.isArray(v) ? v : [v])],
    z.array(z.string().min(1).max(2048)).min(1).max(CHAT_STATUS_IDS_MAX),
);


export const libraryStatusOp = defineOp({
    name: "library.status",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        ids: ChatIds.describe(`post ids (or file ids from post()), 1 to ${CHAT_STATUS_IDS_MAX}`),
        status: StatusEnum.describe(
            "hidden: out of the library and never shareable (every link stops working); off: no link; public: public links; private: each file's own private link (share.../p/<key>)",
        ),
    }),
    output: z.object({
        status: StatusEnum,
        posts: z.array(z.object({ id: z.string(), files: z.number(), links: z.array(z.string()).describe("the links that work now") })),
        failed: Failed,
    }),
    ai: {
        tier: "ask",
        only: true,
        summary:
            "Give posts one status: hidden (out of the library, never shareable), off, public or private. hidden and off just run; public, private, and\nanything that unhides a hidden post ask Harmony first. Hidden posts are left out of library.list/search; library.hidden lists them.",
        params: ["ids", "status"],
        asks: async (input, ctx) =>
            input.status === "public" || input.status === "private" || (input.status === "off" && (await hiddenTargets(ctx.db, input.ids)).length > 0),
        preview: async (ctx, input) => {
            const keys = await postKeysOf(ctx.db, input.ids);
            const unknown = input.ids.filter((i) => !keys.get(i));
            if (unknown.length > 0) throw new OpError(404, "error.library.not_found", `no post or file ${unknown.join(", ")} in the library`);
            const unhides = await hiddenTargets(ctx.db, input.ids);
            const posts = await loadPosts(ctx, [...new Set([...keys.values()].filter((k): k is string => !!k))]);
            const n = posts.length;
            const what = n === 1 ? (posts[0]!.record.title ? `“${posts[0]!.record.title.slice(0, 60)}”` : "this post") : `${n} posts`;
            return {
                summary: `${input.status === "off" ? "turn off" : `make ${input.status}`} ${what}${unhides.length > 0 ? ` (unhides ${unhides.length})` : ""}`,
                effect: { status: input.status, posts: n, titles: posts.slice(0, 5).map((p) => p.record.title ?? "untitled"), unhides: unhides.length },
            };
        },
    },
    handler: async (ctx, input) => {
        const body = unwrap<{ posts: { id: string; files: { visibility: string; url: string | null; private_url: string | null }[] }[]; failed: { id: string; error: string }[] }>(
            await setStatus(hiddenDeps(ctx), input.ids, input.status, "chat"),
            MESSAGES,
        );
        return ok({
            status: input.status,
            posts: body.posts.map((p) => ({
                id: p.id,
                files: p.files.length,
                links: p.files.flatMap((f) => (f.private_url ? [f.private_url] : f.visibility === "public" && f.url ? [f.url] : [])),
            })),
            failed: body.failed,
        });
    },
});

const HiddenPost = z.intersection(
    PostSchema,
    z.object({
        hidden_by: z.enum(["you", "rule", "chat"]),
        hidden_rule: z.string().nullable().describe("the rule that hid it"),
        hidden_at: z.string().describe("ISO date it was hidden"),
    }),
);

export const libraryHiddenOp = defineOp({
    name: "library.hidden",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        limit: z.number().int().min(1).max(50).optional().describe("default 50"),
        cursor: z.string().max(4096).optional().describe("the next of the page before"),
    }),
    output: z.object({ posts: z.array(HiddenPost), next: z.string().nullable() }),
    ai: {
        tier: "free",
        only: true,
        summary: "The hidden posts, most recently hidden first (they are left out of everything else). library.status(ids, \"off\") unhides.",
        options: true,
    },
    handler: async (ctx, input) => {
        const rows = await hiddenList(ctx.db);
        const start = input.cursor ? rows.findIndex((r) => r.post_key === input.cursor) + 1 : 0;
        const limit = input.limit ?? 50;
        const page = rows.slice(start, start + limit);
        const posts = new Map((await loadPosts(ctx, page.map((r) => r.post_key))).map((p) => [p.record.id, p.record]));
        const out = page.flatMap((r) => {
            const rec = posts.get(r.post_key);
            return rec ? [{ ...rec, hidden_by: r.by, hidden_rule: r.rule_id, hidden_at: new Date(r.at).toISOString() }] : [];
        });
        const more = start + limit < rows.length;
        return ok({ posts: out, next: more && page.length > 0 ? page[page.length - 1]!.post_key : null });
    },
});

const run = async (r: Promise<StudioReply>) => unwrap(await r, MESSAGES);

export const hiddenRulesOp = defineOp({
    name: "hidden.rules.list",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({}),
    output: z.object({ rules: z.array(HiddenRuleShape), hidden: z.number(), held: z.number() }),
    ai: {
        tier: "free",
        only: true,
        aliases: ["hidden.rules"],
        summary:
            "The auto-hide rules: site (a host, or host/path like x.com/name), words (in a title, file name, caption or link), about (a tag or word of\nwhat it's about) and upload (every upload). New saves that match are hidden. Also how many posts are hidden.",
    },
    handler: async (ctx) => {
        const { status: _s, ...rest } = await run(listRules(ctx));
        return ok(rest);
    },
});

const RuleInput = { kind: KindEnum, value: RuleValue.optional().describe("site: host or host/path; words: 1-60 chars; about: 1-40 chars; upload: none") };

export const hiddenRulesAddOp = defineOp({
    name: "hidden.rules.add",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ ...RuleInput, apply: z.boolean().optional().describe("also hide what is saved now (asks Harmony first)") }),
    output: z.object({ rule: HiddenRuleShape, applied: z.number() }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Add an auto-hide rule: new saves that match are hidden. With apply: true it also hides what is saved now, and asks Harmony first.",
        params: ["kind", "value"],
        options: true,
        asks: (input) => input.apply === true,
        preview: async (ctx, input) => {
            const p = await run(previewRule(ctx, input));
            const m = (p as { matches: number }).matches;
            return { summary: `add a ${input.kind} rule${input.value ? ` “${input.value}”` : ""} and hide ${m} saved ${m === 1 ? "post" : "posts"}`, effect: { kind: input.kind, value: input.value ?? "", hides: m } };
        },
    },
    handler: async (ctx, input) => {
        const { rule, applied } = await run(addRule(hiddenDeps(ctx), input));
        return ok({ rule, applied });
    },
});

const ruleLabel = async (ctx: OpContext, id: string) => {
    const r = await ctx.db.prepare("SELECT kind, value FROM hidden_rules WHERE id = ?1").bind(id).first<{ kind: string; value: string }>().catch(() => null);
    if (!r) throw new OpError(404, "error.hidden.not_found", MESSAGES["error.hidden.not_found"]);
    return `the ${r.kind} rule${r.value ? ` “${r.value}”` : ""}`;
};

export const hiddenRulesUpdateOp = defineOp({
    name: "hidden.rules.update",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({
        id: z.string().regex(HIDDEN_RULE_ID_REGEX, "a rule id from hidden.rules.list()"),
        enabled: z.boolean().optional(),
        value: RuleValue.optional(),
        apply: z.boolean().optional().describe("also hide what is saved now"),
    }),
    output: z.object({ rule: HiddenRuleShape, applied: z.number() }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Change an auto-hide rule: turn it on or off, change its value, or apply it to what is saved now.",
        params: ["id"],
        options: true,
        preview: async (ctx, input) => ({
            summary: `change ${await ruleLabel(ctx, input.id)}`,
            effect: { ...(input.enabled !== undefined ? { enabled: input.enabled } : {}), ...(input.value !== undefined ? { value: input.value } : {}), apply: input.apply === true },
        }),
    },
    handler: async (ctx, input) => {
        const { id, ...rest } = input;
        const { rule, applied } = await run(updateRule(hiddenDeps(ctx), id, rest));
        return ok({ rule, applied });
    },
});

export const hiddenRulesDeleteOp = defineOp({
    name: "hidden.rules.delete",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object({ id: z.string().regex(HIDDEN_RULE_ID_REGEX, "a rule id from hidden.rules.list()") }),
    output: z.object({ deleted: z.string() }),
    ai: {
        tier: "ask",
        only: true,
        summary: "Delete an auto-hide rule. The posts it hid stay hidden.",
        params: ["id"],
        preview: async (ctx, input) => ({ summary: `delete ${await ruleLabel(ctx, input.id)}`, effect: { posts_stay_hidden: true } }),
    },
    handler: async (ctx, input) => {
        await run(deleteRule(ctx, input.id));
        return ok({ deleted: input.id });
    },
});

export const hiddenRulesPreviewOp = defineOp({
    name: "hidden.rules.preview",
    auth: "key",
    runs: "worker",
    cors: false,
    input: z.object(RuleInput),
    output: z.object({ matches: z.number(), sample: z.array(z.string()).describe("up to 6 post ids") }),
    ai: {
        tier: "free",
        only: true,
        summary: "How many saved posts a rule would hide now (and up to 6 of their ids); nothing changes.",
        params: ["kind", "value"],
    },
    handler: async (ctx, input) => {
        const { status: _s, ...rest } = await run(previewRule(ctx, input));
        return ok(rest);
    },
});

export const HIDDEN_OPS = [
    ...ROUTE_OPS,
    libraryStatusOp,
    libraryHiddenOp,
    hiddenRulesOp,
    hiddenRulesAddOp,
    hiddenRulesUpdateOp,
    hiddenRulesDeleteOp,
    hiddenRulesPreviewOp,
];
