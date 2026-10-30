// The MCP's private link (APP-API-CONTRACT.md section 35.5): a URL with the key inside it, POST /mcp/k/<secret>, for
// clients that cannot send a header (claude.ai's custom connectors). One mode decides which URL answers:
//  - "public":  POST /mcp with a client key in the header (the default, also while migration 0023 is not applied)
//  - "private": only the live private link; /mcp answers 404
//  - "off":     neither
// Only the secret's SHA-256 is stored (D1 mcp_links); the link is shown once, when it is made or rotated.
// Free of Cloudflare imports: the tests run it under node.
import { hashKey } from "./keys";

export type McpMode = "off" | "public" | "private";
export const MCP_MODES = ["off", "public", "private"] as const;

export const MCP_LINK_PATH = "/mcp/k/";
export const MCP_LINK_SECRET_LENGTH = 32;
export const MCP_LINK_SECRET_REGEX = /^[A-Za-z0-9]{32}$/;

// Every private link runs as one MCP thread, so its caps and box files carry over when the link is rotated.
export const MCP_LINK_THREAD_KEY = "private-link";
// The client key id an MCP call through a link carries (upload links name it, and are checked against it).
export const linkClientId = (linkId: string) => `link:${linkId}`;

const MAX_CLIENT_NAME = 60;
const BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

// 32 base62 characters (~190 bits), without modulo bias.
export function newLinkSecret(): string {
    let out = "";
    while (out.length < MCP_LINK_SECRET_LENGTH) {
        const bytes = crypto.getRandomValues(new Uint8Array(48));
        for (const b of bytes) {
            if (b < 248 && out.length < MCP_LINK_SECRET_LENGTH) out += BASE62[b % 62];
        }
    }
    return out;
}

const utcDay = (now: number) => new Date(now).toISOString().slice(0, 10);

// The mode. A missing row or table (migration 0023 not applied yet) is "public", so the server behaves as before.
export async function mcpMode(db: D1Database): Promise<McpMode> {
    try {
        const row = await db.prepare("SELECT mode FROM mcp_settings WHERE id = 1").first<{ mode: string }>();
        const mode = row?.mode;
        return mode === "off" || mode === "private" ? mode : "public";
    } catch {
        return "public";
    }
}

// The live link a secret belongs to, recording the use (one statement). Null: unknown or revoked.
export async function lookupLink(db: D1Database, secret: string, now: number): Promise<string | null> {
    if (!MCP_LINK_SECRET_REGEX.test(secret)) return null;
    const day = utcDay(now);
    const res = await db
        .prepare(
            `UPDATE mcp_links SET last_used_at = ?1,
                 calls = CASE WHEN calls_day = ?2 THEN calls + 1 ELSE 1 END,
                 calls_day = ?2
             WHERE link_hash = ?3 AND revoked_at IS NULL RETURNING id`,
        )
        .bind(now, day, await hashKey(secret))
        .all<{ id: string }>();
    return res.results[0]?.id ?? null;
}

// The client's own name from its initialize (shown as "used by" in settings).
export async function noteLinkClient(db: D1Database, linkId: string, name: string): Promise<void> {
    const clean = name.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, MAX_CLIENT_NAME);
    if (!clean) return;
    await db.prepare("UPDATE mcp_links SET used_by = ?1 WHERE id = ?2").bind(clean, linkId).run();
}

export async function linkLive(db: D1Database, linkId: string): Promise<boolean> {
    const row = await db.prepare("SELECT id FROM mcp_links WHERE id = ?1 AND revoked_at IS NULL").bind(linkId).first<{ id: string }>();
    return row !== null;
}

type LinkRow = { id: string; tail: string; made_at: number; last_used_at: number | null; used_by: string | null; calls_day: string | null; calls: number };

export type McpSettingsView = {
    mode: McpMode;
    public_url: string;
    link: null | {
        hint: string;
        tail: string;
        made_at: number;
        last_used_at: number | null;
        used_by: string | null;
        calls_today: number;
    };
};

// What settings show. The secret is never part of it.
export async function mcpSettings(db: D1Database, origin: string, now: number): Promise<McpSettingsView> {
    const mode = await mcpMode(db);
    let row: LinkRow | null = null;
    try {
        row = await db
            .prepare("SELECT id, tail, made_at, last_used_at, used_by, calls_day, calls FROM mcp_links WHERE revoked_at IS NULL")
            .first<LinkRow>();
    } catch {
        row = null;
    }
    return {
        mode,
        public_url: `${origin}/mcp`,
        link:
            mode === "private" && row
                ? {
                      hint: `${origin}${MCP_LINK_PATH}…${row.tail}`,
                      tail: row.tail,
                      made_at: row.made_at,
                      last_used_at: row.last_used_at,
                      used_by: row.used_by,
                      calls_today: row.calls_day === utcDay(now) ? row.calls : 0,
                  }
                : null,
    };
}

const upsertMode = (db: D1Database, mode: McpMode, now: number) =>
    db
        .prepare("INSERT INTO mcp_settings (id, mode, updated_at) VALUES (1, ?1, ?2) ON CONFLICT (id) DO UPDATE SET mode = ?1, updated_at = ?2")
        .bind(mode, now);
const revokeLive = (db: D1Database, now: number) => db.prepare("UPDATE mcp_links SET revoked_at = ?1 WHERE revoked_at IS NULL").bind(now);

async function insertLink(db: D1Database, now: number): Promise<{ secret: string; stmt: D1PreparedStatement }> {
    const secret = newLinkSecret();
    const stmt = db
        .prepare("INSERT INTO mcp_links (id, link_hash, tail, made_at) VALUES (?1, ?2, ?3, ?4)")
        .bind(crypto.randomUUID(), await hashKey(secret), secret.slice(-4), now);
    return { secret, stmt };
}

export type McpChange = { settings: McpSettingsView; link_url?: string };

// Switch the mode. Turning "private" on makes a new link (answered once as link_url); leaving it revokes the link for
// good. The same mode again changes nothing.
export async function setMcpMode(db: D1Database, mode: McpMode, origin: string, now: number): Promise<McpChange> {
    const current = await mcpMode(db);
    if (mode === current) return { settings: await mcpSettings(db, origin, now) };
    if (mode === "private") {
        const { secret, stmt } = await insertLink(db, now);
        await db.batch([upsertMode(db, mode, now), revokeLive(db, now), stmt]);
        return { settings: await mcpSettings(db, origin, now), link_url: `${origin}${MCP_LINK_PATH}${secret}` };
    }
    await db.batch([upsertMode(db, mode, now), revokeLive(db, now)]);
    return { settings: await mcpSettings(db, origin, now) };
}

// A new private link; the old one stops at once. Null when the mode is not "private".
export async function rotateMcpLink(db: D1Database, origin: string, now: number): Promise<McpChange | null> {
    if ((await mcpMode(db)) !== "private") return null;
    const { secret, stmt } = await insertLink(db, now);
    await db.batch([revokeLive(db, now), stmt]);
    return { settings: await mcpSettings(db, origin, now), link_url: `${origin}${MCP_LINK_PATH}${secret}` };
}
