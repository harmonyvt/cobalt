// Audio Loudness Leveling ops (v10.1):
//   GET    /audio/settings                  current mode, target LUFS, default link + library audio counts
//   PUT    /audio/settings                  update mode (off | measure | auto), target (-14 | -16), default_link (orig | normal)
//   POST   /library/items/:id/audio/level   trigger manual leveling / re-leveling of a video (202 queued)
//   DELETE /library/items/:id/audio/level   remove the leveled alt copy of a video (preserves original)
//   POST   /audio/backfill                  queue background measurement & leveling sweep for existing videos
import * as z from "zod";
import {
    AUDIO_KICK_MAX,
    AUDIO_LEVEL_TARGETS,
    AUDIO_MODES,
    AUDIO_DEFAULT_LINKS,
    parseAudioTarget,
    readAudioSettings,
    removeAudioAlt,
    writeAudioSettings,
    type AudioDefaultLink,
    type AudioMode,
    type AudioTargetLufs,
} from "../../audio-loudness";
import { ITEM_ID_REGEX } from "../../gate";
import { isMissingTable } from "../../private-links";
import { getRow } from "../../visibility";
import { defineOp, ok, type OpContext, type OpReply } from "../op";

const Status = z.literal("success");
const AudioModeSchema = z.enum(AUDIO_MODES as unknown as ["off", "measure", "auto"]);
const AudioTargetSchema = z.union([z.literal(-14), z.literal(-16)]);
const AudioDefaultLinkSchema = z.enum(AUDIO_DEFAULT_LINKS as unknown as ["orig", "normal"]);

const CountsSchema = z.object({
    total_videos: z.number().int(),
    measured: z.number().int(),
    leveled: z.number().int(),
    needs_level: z.number().int(),
    rendering: z.number().int(),
    failed: z.number().int(),
});

const SettingsOutput = z.object({
    status: Status,
    mode: AudioModeSchema,
    target_lufs: AudioTargetSchema,
    default_link: AudioDefaultLinkSchema,
    updated_at: z.number().int(),
    counts: CountsSchema,
});

const SettingsPatchInput = z.object({
    mode: AudioModeSchema.optional(),
    target_lufs: AudioTargetSchema.optional(),
    default_link: AudioDefaultLinkSchema.optional(),
});

const LevelInput = z.object({
    target_lufs: AudioTargetSchema.optional(),
});

const BackfillInput = z.object({
    limit: z.coerce.number().int().min(1).max(AUDIO_KICK_MAX).optional(),
});

const fail = (status: number, code: string): OpReply => ({
    status,
    body: { status: "error", error: { code } },
});

async function readAudioCounts(db: D1Database): Promise<z.infer<typeof CountsSchema>> {
    const empty = { total_videos: 0, measured: 0, leveled: 0, needs_level: 0, rendering: 0, failed: 0 };
    try {
        const totalRow = await db
            .prepare(
                `SELECT COUNT(*) AS n FROM media_items
                  WHERE deleted_at IS NULL
                    AND lower(coalesce(content_type, '')) LIKE 'video/%'
                    AND (role IS NULL OR role != 'alt')`,
            )
            .first<{ n: number }>();
        const stats = await db
            .prepare(
                `SELECT
                    SUM(CASE WHEN a.integrated_lufs IS NOT NULL THEN 1 ELSE 0 END) AS measured,
                    SUM(CASE WHEN a.state = 'ready' AND a.alt_item_id IS NOT NULL THEN 1 ELSE 0 END) AS leveled,
                    SUM(CASE WHEN a.state = 'measured' AND a.zone IN ('loud', 'quiet') THEN 1 ELSE 0 END) AS needs_level,
                    SUM(CASE WHEN a.state = 'rendering' THEN 1 ELSE 0 END) AS rendering,
                    SUM(CASE WHEN a.state = 'failed' THEN 1 ELSE 0 END) AS failed
                   FROM media_audio a
                   JOIN media_items m ON m.id = a.item_id
                  WHERE m.deleted_at IS NULL AND (m.role IS NULL OR m.role != 'alt')`,
            )
            .first<{
                measured: number | null;
                leveled: number | null;
                needs_level: number | null;
                rendering: number | null;
                failed: number | null;
            }>();
        return {
            total_videos: Number(totalRow?.n ?? 0),
            measured: Number(stats?.measured ?? 0),
            leveled: Number(stats?.leveled ?? 0),
            needs_level: Number(stats?.needs_level ?? 0),
            rendering: Number(stats?.rendering ?? 0),
            failed: Number(stats?.failed ?? 0),
        };
    } catch (e) {
        if (isMissingTable(e)) return empty;
        console.error("[audio] count query failed", String(e));
        return empty;
    }
}

async function readOptionalJsonBody(ctx: OpContext): Promise<Record<string, unknown>> {
    if (!ctx.request) return {};
    const text = await ctx.request.text();
    if (!text.trim()) return {};
    let parsed: unknown;
    try {
        parsed = JSON.parse(text);
    } catch {
        throw new Error("invalid json");
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error("expected object");
    }
    return parsed as Record<string, unknown>;
}

async function forwardJson(res: Response): Promise<OpReply> {
    const body = await res.json().catch(() => ({ status: "error", error: { code: "error.api.generic" } }));
    return { status: res.status, body };
}

const base = {
    auth: "key_or_service" as const,
    runs: "worker" as const,
    cors: true,
    noStore: true,
    badRequest: "error.audio.bad_request",
};

export const AUDIO_OPS = [
    defineOp({
        ...base,
        name: "audio.settings.get",
        route: { method: "GET", path: "/audio/settings" },
        input: z.object({}),
        http: () => ({}),
        output: SettingsOutput,
        ai: { tier: "hidden", summary: "Read audio loudness leveling settings and library counts (GET /audio/settings)." },
        handler: async (ctx) => {
            try {
                const [settings, counts] = await Promise.all([readAudioSettings(ctx.db), readAudioCounts(ctx.db)]);
                return ok({ status: "success", ...settings, counts });
            } catch (e) {
                console.error("[audio] settings get failed", String(e));
                return fail(503, "error.api.generic");
            }
        },
    }),
    defineOp({
        ...base,
        name: "audio.settings.set",
        route: { method: "PUT", path: "/audio/settings" },
        input: SettingsPatchInput,
        http: async (ctx) => readOptionalJsonBody(ctx),
        output: SettingsOutput,
        ai: { tier: "hidden", summary: "Update audio loudness leveling settings (PUT /audio/settings)." },
        handler: async (ctx, input) => {
            try {
                const patch: { mode?: AudioMode; target_lufs?: AudioTargetLufs; default_link?: AudioDefaultLink } = {};
                if (input.mode !== undefined) patch.mode = input.mode;
                if (input.target_lufs !== undefined) patch.target_lufs = input.target_lufs;
                if (input.default_link !== undefined) patch.default_link = input.default_link;
                const settings = await writeAudioSettings(ctx.db, patch, ctx.now());
                const counts = await readAudioCounts(ctx.db);
                return ok({ status: "success", ...settings, counts });
            } catch (e) {
                if (isMissingTable(e)) return fail(503, "error.api.generic");
                console.error("[audio] settings set failed", String(e));
                return fail(503, "error.api.generic");
            }
        },
    }),
    defineOp({
        ...base,
        name: "library.item.audio.level",
        route: { method: "POST", path: "/library/items/:id/audio/level", params: { id: ITEM_ID_REGEX } },
        input: LevelInput,
        http: async (ctx) => {
            const body = await readOptionalJsonBody(ctx);
            const qTarget = ctx.query.get("target");
            if (body.target_lufs === undefined && qTarget !== null) {
                const parsed = parseAudioTarget(qTarget);
                return { target_lufs: parsed ?? qTarget };
            }
            return body;
        },
        output: z.object({
            status: Status,
            state: z.string(),
            target_lufs: AudioTargetSchema,
            queued: z.boolean(),
        }),
        ai: { tier: "hidden", summary: "Queue EBU R128 loudness leveling for a library video (POST /library/items/:id/audio/level)." },
        handler: async (ctx, input) => {
            const id = ctx.params.id!;
            const q = input.target_lufs !== undefined ? `?target=${input.target_lufs}` : "";
            try {
                const res = await ctx.durableObject(`/audio/level/${encodeURIComponent(id)}${q}`, { method: "POST" });
                return await forwardJson(res);
            } catch (e) {
                console.error("[audio] level forward failed", id, String(e));
                return fail(503, "error.api.generic");
            }
        },
    }),
    defineOp({
        ...base,
        name: "library.item.audio.remove",
        route: { method: "DELETE", path: "/library/items/:id/audio/level", params: { id: ITEM_ID_REGEX } },
        input: z.object({}),
        http: () => ({}),
        output: z.object({
            status: Status,
            removed: z.boolean(),
            alt_id: z.string().nullable(),
            bytes: z.number().int(),
        }),
        ai: { tier: "hidden", summary: "Delete the leveled audio alternate for a library video (DELETE /library/items/:id/audio/level)." },
        handler: async (ctx) => {
            const id = ctx.params.id!;
            let row;
            try {
                row = await getRow(ctx.db, id);
            } catch {
                return fail(503, "error.api.generic");
            }
            if (!row) return fail(404, "error.library.not_found");
            try {
                const app = ctx.app();
                const res = await removeAudioAlt(
                    {
                        db: ctx.db,
                        originals: app.originals,
                        media: app.media,
                        mediaBaseUrl: app.mediaBaseUrl,
                        now: ctx.now,
                        purge: app.purge,
                    },
                    row.id,
                );
                return ok({ status: "success", removed: res.removed, alt_id: res.altId, bytes: res.bytes });
            } catch (e) {
                console.error("[audio] remove alt failed", id, String(e));
                return fail(503, "error.api.generic");
            }
        },
    }),
    defineOp({
        ...base,
        name: "audio.backfill",
        route: { method: "POST", path: "/audio/backfill" },
        input: BackfillInput,
        http: async (ctx) => {
            const body = await readOptionalJsonBody(ctx);
            const qLimit = ctx.query.get("limit");
            if (body.limit === undefined && qLimit !== null) return { limit: qLimit };
            return body;
        },
        output: z.object({
            status: Status,
            queued_measure: z.number().int(),
            queued_level: z.number().int(),
            eligible: z.number().int(),
            mode: AudioModeSchema,
            target_lufs: AudioTargetSchema,
        }),
        ai: { tier: "hidden", summary: "Queue a background backfill sweep of unmeasured/unleveled videos (POST /audio/backfill)." },
        handler: async (ctx, input) => {
            const limit = input.limit ?? AUDIO_KICK_MAX;
            try {
                const res = await ctx.durableObject(`/audio/kick?backfill=1&limit=${limit}`, { method: "POST" });
                return await forwardJson(res);
            } catch (e) {
                console.error("[audio] backfill forward failed", String(e));
                return fail(503, "error.api.generic");
            }
        },
    }),
];

export { AUDIO_LEVEL_TARGETS };
