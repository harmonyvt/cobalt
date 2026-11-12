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
    cleanDevice,
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
const KEY_NAME_INVALID = "error.api.auth.key.name_invalid";
const KEY_TOO_MANY = "error.api.auth.key.too_many";
const SESSION_REQUIRED = "error.api.auth.session_required";

// Keys for tools (section 50): the same cap and name length as the web Worker's /api/keys (web/src/keys.ts).
export const MAX_KEYS = 50;

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

// Making and renaming keys needs a signed-in device (a session): a key for tools never mints or renames keys, so a leaked
// one can't make itself a spare.
async function requireSession(ctx: OpContext): Promise<void> {
    const row = await callerRow(ctx);
    if (row?.kind !== "session") throw new OpError(403, SESSION_REQUIRED);
}

// A key name: 1..40 printable characters after trimming (the same rule as a device name), else null.
const cleanKeyName = (raw: unknown): string | null => cleanDevice(raw);

const KeyNameInput = z.object({ name: z.string().max(400) });

const route = <I>(o: {
    name: string;
    method: "GET" | "POST" | "PATCH" | "DELETE";
    path: string;
    input?: z.ZodType<I>;
    badRequest?: string;
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
        ...(o.badRequest ? { badRequest: o.badRequest } : {}),
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
        name: "auth.keys.create",
        method: "POST",
        path: "/auth/keys",
        input: KeyNameInput,
        badRequest: KEY_NAME_INVALID,
        output: z.object({
            status: z.literal("success"),
            key: z.string().describe("the new key, shown this once: only its SHA-256 is stored"),
            item: KeyShape,
        }),
        summary: "Make a key for tools; the key is in this answer only (POST /auth/keys, signed-in devices only).",
        run: async (ctx, input) => {
            await requireSession(ctx);
            const name = cleanKeyName(input.name);
            if (name === null) throw new OpError(400, KEY_NAME_INVALID);
            const now = ctx.now();
            const key = crypto.randomUUID();
            const id = crypto.randomUUID();
            const prefix = key.slice(0, 8);
            // The cap is checked inside the INSERT, so two racing creates can't pass it.
            const made = await ctx.db
                .prepare(
                    `INSERT INTO api_keys (id, name, key_hash, prefix, created_at)
                     SELECT ?1, ?2, ?3, ?4, ?5
                     WHERE (SELECT COUNT(*) FROM api_keys WHERE ${ACTIVE_KEY_SQL}) < ?6
                     RETURNING id`,
                )
                .bind(id, name, await hashKey(key), prefix, now, MAX_KEYS)
                .first<{ id: string }>();
            if (!made) throw new OpError(409, KEY_TOO_MANY);
            return ok(
                { status: "success", key, item: { id, name, prefix, created_at: now, last_used_at: null, old_paste: false } },
                201,
            );
        },
    }),
    route({
        name: "auth.keys.update",
        method: "PATCH",
        path: "/auth/keys/:id",
        input: z.object({ id: z.string(), name: z.string().max(400) }),
        badRequest: KEY_NAME_INVALID,
        output: z.object({ status: z.literal("success"), item: KeyShape }),
        summary: "Rename a key for tools (PATCH /auth/keys/<id> {name}, signed-in devices only).",
        run: async (ctx, input) => {
            await requireSession(ctx);
            if (!UUID_REGEX.test(input.id)) throw new OpError(404, KEY_NOT_FOUND);
            const name = cleanKeyName(input.name);
            if (name === null) throw new OpError(400, KEY_NAME_INVALID);
            const r = await ctx.db
                .prepare(
                    `UPDATE api_keys SET name = ?1 WHERE id = ?2 AND ${ACTIVE_KEY_SQL}
                     RETURNING id, name, prefix, created_at, last_used_at, replaced_by`,
                )
                .bind(name, input.id)
                .first<{ id: string; name: string; prefix: string; created_at: number; last_used_at: number | null; replaced_by: string | null }>();
            if (!r) throw new OpError(404, KEY_NOT_FOUND);
            return ok({
                status: "success",
                item: { id: r.id, name: r.name, prefix: r.prefix, created_at: r.created_at, last_used_at: r.last_used_at, old_paste: r.replaced_by !== null },
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

// ---- extension pairing (55) ------------------------------------------------------------------------------------------
// Safari cannot finish chrome.identity.launchWebAuthFlow, so it polls. Chrome's redirect sign-in does not use this
// table: the approve page writes an auth_handoffs row and the existing POST /auth/exchange mints the session.
// Codes are 32 random bytes, base64url (43 characters), the same shape as an app handoff code. Only the hash is stored.

export const PAIRING_TTL_MS = 5 * 60 * 1000;
export const PAIRING_INTERVAL_S = 2;
const MAX_PAIRINGS = 30;
const STATE_REGEX = /^[A-Za-z0-9_-]{16,128}$/;

const newSecret = () => b64url(crypto.getRandomValues(new Uint8Array(32)).buffer);

const Pending = z.object({
    status: z.literal("pending"),
    interval: z.number().int().describe("seconds the extension should wait before polling again"),
});

export const extensionBeginOp = defineOp({
    name: "auth.extension.begin",
    route: { method: "POST", path: "/auth/extension/begin" },
    auth: "open",
    runs: "worker",
    cors: false,
    noStore: true,
    input: z.object({
        challenge: z.string().max(64).describe("base64url(SHA-256(verifier)), PKCE S256"),
        state: z.string().max(160),
    }),
    badRequest: CODE_INVALID,
    output: z.object({
        status: z.literal("pending"),
        device_code: z.string().describe("the extension's secret for POST /auth/extension/poll; shown once"),
        user_code: z.string().describe("goes in the approve page URL; useless without the device code and the verifier"),
        expires_at: z.number().int(),
        interval: z.number().int(),
    }),
    ai: { tier: "hidden", summary: "Start a browser-extension sign-in (POST /auth/extension/begin). The owner approves it on the web app." },
    handler: async (ctx, input) => {
        if (!CODE_REGEX.test(input.challenge) || !STATE_REGEX.test(input.state)) throw new OpError(400, CODE_INVALID);
        const now = ctx.now();
        // Expired and already-traded rows are dead weight. Then a soft cap, so a flood of begins can't grow the table.
        await ctx.db.prepare("DELETE FROM extension_pairings WHERE expires_at < ?1 OR used_at IS NOT NULL").bind(now).run();
        const count = await ctx.db.prepare("SELECT COUNT(*) AS n FROM extension_pairings").first<{ n: number }>();
        const extra = Number(count?.n ?? 0) - (MAX_PAIRINGS - 1);
        if (extra > 0) {
            await ctx.db
                .prepare("DELETE FROM extension_pairings WHERE device_hash IN (SELECT device_hash FROM extension_pairings ORDER BY created_at ASC, device_hash ASC LIMIT ?1)")
                .bind(extra)
                .run();
        }
        const deviceCode = newSecret();
        const userCode = newSecret();
        const expiresAt = now + PAIRING_TTL_MS;
        await ctx.db
            .prepare(
                "INSERT INTO extension_pairings (device_hash, user_hash, challenge, state, device, email, created_at, expires_at) VALUES (?1, ?2, ?3, ?4, 'Browser extension', NULL, ?5, ?6)",
            )
            .bind(await hashKey(deviceCode), await hashKey(userCode), input.challenge, input.state, now, expiresAt)
            .run();
        return ok({ status: "pending", device_code: deviceCode, user_code: userCode, expires_at: expiresAt, interval: PAIRING_INTERVAL_S }, 201);
    },
});

export const extensionPollOp = defineOp({
    name: "auth.extension.poll",
    route: { method: "POST", path: "/auth/extension/poll" },
    auth: "open",
    runs: "worker",
    cors: false,
    noStore: true,
    input: z.object({
        device_code: z.string().max(64),
        verifier: z.string().max(160),
        state: z.string().max(160),
    }),
    badRequest: CODE_INVALID,
    output: z.union([
        Pending,
        z.object({ status: z.literal("success"), key: z.string().describe("the session token: send it as Api-Key"), session: SessionShape }),
    ]),
    ai: { tier: "hidden", summary: "Poll a browser-extension sign-in (POST /auth/extension/poll). Pending until the owner approves, then a device session." },
    handler: async (ctx, input) => {
        if (!CODE_REGEX.test(input.device_code) || !VERIFIER_REGEX.test(input.verifier) || !STATE_REGEX.test(input.state)) {
            throw new OpError(400, CODE_INVALID);
        }
        const now = ctx.now();
        const row = await ctx.db
            .prepare("SELECT challenge, state, device, email, approved_at, used_at, expires_at FROM extension_pairings WHERE device_hash = ?1")
            .bind(await hashKey(input.device_code))
            .first<{ challenge: string; state: string; device: string; email: string | null; approved_at: number | null; used_at: number | null; expires_at: number }>();
        // One answer for unknown, expired, used, or a verifier/state that does not match, so a guess learns nothing.
        if (!row || row.used_at || row.expires_at <= now) throw new OpError(400, CODE_INVALID);
        if (row.challenge !== (await challengeOf(input.verifier)) || row.state !== input.state) throw new OpError(400, CODE_INVALID);
        if (!row.approved_at || !row.email) return ok({ status: "pending", interval: PAIRING_INTERVAL_S }, 202);
        const claimed = await ctx.db
            .prepare(
                `UPDATE extension_pairings SET used_at = ?1
                 WHERE device_hash = ?2 AND used_at IS NULL AND approved_at IS NOT NULL AND expires_at > ?1
                 RETURNING device, email`,
            )
            .bind(now, await hashKey(input.device_code))
            .first<{ device: string; email: string }>();
        if (!claimed?.email) throw new OpError(400, CODE_INVALID);
        const minted = await mintSession(
            ctx.db,
            {
                device: cleanDevice(claimed.device) ?? "Browser extension",
                platform: "extension",
                email: claimed.email,
                country: ctx.country ?? countryOf(ctx.request),
            },
            now,
        );
        return ok({ status: "success", key: minted.key, session: minted.session });
    },
});

export const AUTH_OPS = [exchangeOp, extensionBeginOp, extensionPollOp, ...ROUTES];
