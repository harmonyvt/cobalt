// Accounts (APP-API-CONTRACT.md section 42): device sessions minted after a Cloudflare Access sign-in, and the owner's
// view of sessions and keys. Tier hidden: never chat or MCP tools.
//  - POST /auth/exchange: open, no CORS. Trades the one-time code the web Worker's /api/auth/app handed the app (PKCE
//    S256) for a new session. Every failure is the same 400 error.api.auth.code.invalid, so nobody learns whether a code
//    existed or the verifier was wrong.
//  - The rest: a client key or a session (auth key), CORS for the web app, no-store.
// Tokens and codes are never logged and never stored in plaintext (only their SHA-256).
import * as z from "zod";
import { countryOf, hashKey } from "../../keys";
import {
    ACTIVE_SESSION_SQL,
    mintSession,
    PLATFORMS,
    SESSION_COLUMNS,
    sessionBody,
    type Platform,
    type SessionRow,
} from "../../sessions";
import { defineOp, ok, OpError, type OpContext } from "../op";

const CODE_INVALID = "error.api.auth.code.invalid";
const SESSION_NOT_FOUND = "error.api.auth.session.not_found";
const KEY_NOT_FOUND = "error.api.auth.key.not_found";

// 32 random bytes, base64url without padding: 43 characters.
const CODE_REGEX = /^[A-Za-z0-9_-]{43}$/;
// RFC 7636: 43..128 unreserved characters (the apps send 32 bytes base64url, 43 characters).
const VERIFIER_REGEX = /^[A-Za-z0-9._~-]{43,128}$/;
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const ACTIVE_KEY_SQL = "kind = 'key' AND revoked_at IS NULL";

const b64url = (buf: ArrayBuffer) => {
    let s = "";
    for (const b of new Uint8Array(buf)) s += String.fromCharCode(b);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

// PKCE S256: base64url(SHA-256(verifier)).
export async function challengeOf(verifier: string): Promise<string> {
    return b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
}

// ---- shapes -----------------------------------------------------------------------------------------------------------

export const SessionShape = z
    .object({
        id: z.string(),
        device: z.string(),
        platform: z.enum(PLATFORMS as unknown as [Platform, ...Platform[]]),
        created_at: z.number().int(),
        last_used_at: z.number().int(),
        expires_at: z.number().int().describe("ms; slides 90 days on each use"),
        country: z.string().nullable().describe("cf.country of the last use"),
        current: z.boolean().describe("this is the caller's own session"),
    })
    .meta({ id: "AuthSessionRow" });

export const KeyShape = z
    .object({
        id: z.string(),
        name: z.string(),
        prefix: z.string().describe("the key's first 8 characters"),
        created_at: z.number().int(),
        last_used_at: z.number().int().nullable(),
        old_paste: z.boolean().describe("a device that used this pasted key has signed in since (replaced_by set)"),
    })
    .meta({ id: "AuthKeyRow" });

const Success = z.object({ status: z.literal("success") });
const NoInput = z.object({});
const none = () => ({});
const IdInput = z.object({ id: z.string() });

// ---- helpers ------------------------------------------------------------------------------------------------------------

type CallerRow = { id: string; kind: string; device: string | null; platform: string | null; email: string | null; expires_at: number | null };

async function callerRow(ctx: OpContext): Promise<CallerRow | null> {
    return ctx.db
        .prepare("SELECT id, kind, device, platform, email, expires_at FROM api_keys WHERE id = ?1")
        .bind(ctx.keyId)
        .first<CallerRow>();
}

const route = <I>(o: {
    name: string;
    method: "GET" | "POST" | "DELETE";
    path: string;
    input?: z.ZodType<I>;
    output: z.ZodType;
    summary: string;
    run: (ctx: OpContext, input: I) => Promise<{ status: number; body: unknown }>;
}) =>
    defineOp<I>({
        name: o.name,
        route: { method: o.method, path: o.path },
        auth: "key",
        runs: "worker",
        cors: true,
        noStore: true,
        input: (o.input ?? NoInput) as z.ZodType<I>,
        ...(o.input ? {} : { http: none }),
        output: o.output,
        ai: { tier: "hidden", summary: o.summary },
        handler: (ctx, input) => o.run(ctx, input),
    });

// ---- POST /auth/exchange (42.3) -------------------------------------------------------------------------------------------

export const exchangeOp = defineOp({
    name: "auth.exchange",
    route: { method: "POST", path: "/auth/exchange" },
    auth: "open",
    runs: "worker",
    cors: false,
    noStore: true,
    input: z.object({
        code: z.string().max(256),
        verifier: z.string().max(256),
        old_key: z.string().max(256).nullish(),
    }),
    badRequest: CODE_INVALID,
    output: z.object({ status: z.literal("success"), key: z.string().describe("the session token: send it as Api-Key"), session: SessionShape }),
    ai: { tier: "hidden", summary: "Trade a sign-in code for a device session (POST /auth/exchange)." },
    handler: async (ctx, input) => {
        if (!CODE_REGEX.test(input.code) || !VERIFIER_REGEX.test(input.verifier)) throw new OpError(400, CODE_INVALID);
        const now = ctx.now();
        // One statement: the code exists, is unused, unexpired and matches the verifier, and is marked used. A second try
        // with the same code (or a racing one) finds used_at set and gets the same 400.
        const handoff = await ctx.db
            .prepare(
                `UPDATE auth_handoffs SET used_at = ?1
                 WHERE code_hash = ?2 AND challenge = ?3 AND used_at IS NULL AND expires_at > ?1
                 RETURNING device, platform, email`,
            )
            .bind(now, await hashKey(input.code), await challengeOf(input.verifier))
            .first<{ device: string; platform: string; email: string }>();
        if (!handoff || !(PLATFORMS as readonly string[]).includes(handoff.platform)) throw new OpError(400, CODE_INVALID);
        const minted = await mintSession(
            ctx.db,
            { device: handoff.device, platform: handoff.platform as Platform, email: handoff.email, country: ctx.country ?? countryOf(ctx.request) },
            now,
        );
        // The pasted key this device used before: marked as taken over (it keeps working until revoked).
        if (input.old_key && UUID_REGEX.test(input.old_key)) {
            await ctx.db
                .prepare(`UPDATE api_keys SET replaced_by = ?1 WHERE key_hash = ?2 AND ${ACTIVE_KEY_SQL}`)
                .bind(minted.session.id, await hashKey(input.old_key))
                .run();
        }
        return ok({ status: "success", key: minted.key, session: minted.session });
    },
});

// ---- the keyed routes (42.5) ------------------------------------------------------------------------------------------------

const ROUTES = [
    route({
        name: "auth.me",
        method: "GET",
        path: "/auth/me",
        output: z.object({
            caller: z.object({
                kind: z.enum(["key", "session"]),
                id: z.string(),
                device: z.string().optional(),
                platform: z.string().optional(),
                email: z.string().optional(),
                expires_at: z.number().int().optional(),
            }),
            sessions: z.number().int().describe("active sessions"),
            keys: z.number().int().describe("active keys"),
        }),
        summary: "Who is calling (a key or a device session) and how many sessions and keys are active (GET /auth/me).",
        run: async (ctx) => {
            const now = ctx.now();
            const row = await callerRow(ctx);
            const counts = await ctx.db
                .prepare(`SELECT (SELECT COUNT(*) FROM api_keys WHERE ${ACTIVE_SESSION_SQL}) AS sessions, (SELECT COUNT(*) FROM api_keys WHERE ${ACTIVE_KEY_SQL}) AS keys`)
                .bind(now)
                .first<{ sessions: number; keys: number }>();
            const caller =
                row?.kind === "session"
                    ? {
                          kind: "session" as const,
                          id: row.id,
                          device: row.device ?? "",
                          platform: row.platform ?? "",
                          email: row.email ?? "",
                          expires_at: row.expires_at ?? 0,
                      }
                    : { kind: "key" as const, id: ctx.keyId! };
            return ok({ caller, sessions: Number(counts?.sessions ?? 0), keys: Number(counts?.keys ?? 0) });
        },
    }),
    route({
        name: "auth.sessions.list",
        method: "GET",
        path: "/auth/sessions",
        output: z.object({ sessions: z.array(SessionShape) }),
        summary: "The active device sessions, most recently used first (GET /auth/sessions).",
        run: async (ctx) => {
            const { results } = await ctx.db
                .prepare(`SELECT ${SESSION_COLUMNS} FROM api_keys WHERE ${ACTIVE_SESSION_SQL} ORDER BY last_used_at DESC, created_at DESC, id DESC`)
                .bind(ctx.now())
                .all<SessionRow>();
            return ok({ sessions: results.map((r) => sessionBody(r, ctx.keyId)) });
        },
    }),
    route({
        name: "auth.sessions.delete",
        method: "DELETE",
        path: "/auth/sessions/:id",
        input: IdInput,
        output: Success,
        summary: "Sign a device out (DELETE /auth/sessions/<id>); the caller's own session too.",
        run: async (ctx, { id }) => {
            if (!UUID_REGEX.test(id)) throw new OpError(404, SESSION_NOT_FOUND);
            const now = ctx.now();
            const r = await ctx.db
                .prepare(`UPDATE api_keys SET revoked_at = ?1 WHERE id = ?2 AND ${ACTIVE_SESSION_SQL} RETURNING id`)
                .bind(now, id)
                .first<{ id: string }>();
            if (!r) throw new OpError(404, SESSION_NOT_FOUND);
            return ok({ status: "success" });
        },
    }),
    route({
        name: "auth.signout",
        method: "POST",
        path: "/auth/signout",
        output: z.object({ signed_out: z.boolean().describe("false: the caller is a key, which is never revoked here") }),
        summary: "Sign the calling device out; a key is left alone (POST /auth/signout).",
        run: async (ctx) => {
            const now = ctx.now();
            const r = await ctx.db
                .prepare(`UPDATE api_keys SET revoked_at = ?1 WHERE id = ?2 AND ${ACTIVE_SESSION_SQL} RETURNING id`)
                .bind(now, ctx.keyId)
                .first<{ id: string }>();
            return ok({ signed_out: !!r });
        },
    }),
    route({
        name: "auth.signout_others",
        method: "POST",
        path: "/auth/signout-others",
        output: z.object({ count: z.number().int().describe("sessions signed out") }),
        summary: "Sign out every other device (POST /auth/signout-others).",
        run: async (ctx) => {
            const now = ctx.now();
            const { results } = await ctx.db
                .prepare(`UPDATE api_keys SET revoked_at = ?1 WHERE id != ?2 AND ${ACTIVE_SESSION_SQL} RETURNING id`)
                .bind(now, ctx.keyId)
                .all<{ id: string }>();
            return ok({ count: results.length });
        },
    }),
    route({
        name: "auth.keys.list",
        method: "GET",
        path: "/auth/keys",
        output: z.object({ keys: z.array(KeyShape) }),
        summary: "The active keys for tools, newest first (GET /auth/keys).",
        run: async (ctx) => {
            const { results } = await ctx.db
                .prepare(
                    `SELECT id, name, prefix, created_at, last_used_at, replaced_by FROM api_keys WHERE ${ACTIVE_KEY_SQL} ORDER BY created_at DESC, id DESC`,
                )
                .all<{ id: string; name: string; prefix: string; created_at: number; last_used_at: number | null; replaced_by: string | null }>();
            return ok({
                keys: results.map((r) => ({
                    id: r.id,
                    name: r.name,
                    prefix: r.prefix,
                    created_at: r.created_at,
                    last_used_at: r.last_used_at,
                    old_paste: r.replaced_by !== null,
                })),
            });
        },
    }),
    route({
        name: "auth.keys.delete",
        method: "DELETE",
        path: "/auth/keys/:id",
        input: IdInput,
        output: Success,
        summary: "Revoke a key for tools, never a session (DELETE /auth/keys/<id>).",
        run: async (ctx, { id }) => {
            if (!UUID_REGEX.test(id)) throw new OpError(404, KEY_NOT_FOUND);
            const r = await ctx.db
                .prepare(`UPDATE api_keys SET revoked_at = ?1 WHERE id = ?2 AND ${ACTIVE_KEY_SQL} RETURNING id`)
                .bind(ctx.now(), id)
                .first<{ id: string }>();
            if (!r) throw new OpError(404, KEY_NOT_FOUND);
            return ok({ status: "success" });
        },
    }),
];

export const AUTH_OPS = [exchangeOp, ...ROUTES];
