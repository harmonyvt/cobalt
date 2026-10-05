// The world of the poster / public-by-default tests (APP-API-CONTRACT.md section 13): the
// Worker, the Durable Object's services with the PUBLIC bucket wired in (so posters and
// `public: true` hosting are on, as in production) and the real SQL on node:sqlite over every
// migration. The helper and both R2 buckets are the fakes from studio-fakes.ts.
import { handleRequest, type WorkerEnv } from "../src/worker";
import { hashKey } from "../src/keys";
import { SERVICE_HEADER } from "../src/headers";
import { SESSION_TTL_MS, StudioService, handleStudioRoute, isStudioRoute } from "../src/studio";
import { WebpService, handleWebpRoute, isWebpRoute } from "../src/webp";
import { type FakeD1 } from "../../test-support/d1-sqlite";
import { createBatchD1 } from "./d1-batch";
import { Clock, FakeHelper, MemoryKV, MemoryMedia, MemoryOriginals, fixedLength, fixedLengthPair } from "./studio-fakes";

export const ORIGIN = "https://cobalt.capybaraharmony.com";
export const MEDIA_BASE = "https://media.capybaraharmony.com/";
export const INTERNAL = "9d3a1c6e-2f4b-4c8d-8e7a-5b1f0a2c3d4e";
export const CLIENT = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
export const KEY_ID = "key-row-1";
export const SID = "aB3dE6gH9jK2mN5pQ8sTuV";
export const LINK = "https://x.com/maria_rcks/status/2105237035271258436";
export const POSTER_URL = /^https:\/\/media\.capybaraharmony\.com\/[A-Za-z0-9]{10}\.jpg$/;
export const HOST_URL = /^https:\/\/media\.capybaraharmony\.com\/[A-Za-z0-9]{10}\.mp4$/;

export const auth = { authorization: `Api-Key ${CLIENT}` };
export const svc = { [SERVICE_HEADER]: INTERNAL };
export const json = (o: unknown) => JSON.stringify(o);
export const asBody = (r: { body: unknown }) => r.body as any;

export function world(opts: { media?: boolean } = {}) {
    const withMedia = opts.media !== false;
    const db: FakeD1 = createBatchD1();
    const clock = new Clock();
    const kv = new MemoryKV();
    const originals = new MemoryOriginals();
    const media = new MemoryMedia();
    const helper = new FakeHelper();
    let sweepsArmed = 0;
    const webp = new WebpService({
        storage: kv,
        bucket: media,
        mediaBaseUrl: MEDIA_BASE,
        now: clock.now,
        sleep: clock.sleep,
        ensureRunning: async () => {},
        helper: helper.helper,
        db,
    });
    const make = (over: Partial<ConstructorParameters<typeof StudioService>[0]> = {}) =>
        new StudioService({
            db,
            storage: kv,
            originals,
            webp,
            webBaseUrl: ORIGIN,
            now: clock.now,
            sleep: clock.sleep,
            ensureRunning: async () => {},
            helper: helper.helper,
            fixedLength,
            scheduleSweep: () => {
                sweepsArmed++;
            },
            ...(withMedia ? { media, mediaBaseUrl: MEDIA_BASE } : {}),
            ...over,
        });
    const studio = make();

    const seen: Request[] = [];
    const container = {
        async fetch(r: Request) {
            seen.push(r);
            const p = new URL(r.url).pathname;
            if (isStudioRoute(p)) return handleStudioRoute(studio, r);
            if (isWebpRoute(p)) return handleWebpRoute(webp, r);
            return new Response('{"status":"ok"}', { headers: { "content-type": "application/json" } });
        },
    };
    const env: WorkerEnv = {
        API_URL: "https://api.capybaraharmony.com/",
        CORS_URL: ORIGIN,
        COBALT_API_KEY: INTERNAL,
        DB: db,
        ORIGINALS: originals,
        MEDIA: media,
        MEDIA_BASE_URL: MEDIA_BASE,
    };
    const call = (url: string, init: RequestInit = {}) =>
        handleRequest(new Request(`https://api.capybaraharmony.com${url}`, init), env, container, {
            now: clock.now,
            sleep: clock.sleep,
            fixedLength: fixedLengthPair,
        });

    const items = () => db.raw.prepare("SELECT * FROM media_items ORDER BY created_at, id").all() as any[];
    const item = (id: string) => db.raw.prepare("SELECT * FROM media_items WHERE id = ?").get(id) as any;
    const session = (sid: string) => db.raw.prepare("SELECT * FROM studio_sessions WHERE id = ?").get(sid) as any;
    const posters = () => [...media.objects.keys()].filter((k) => k.endsWith(".jpg"));

    // A ready session + its saved original + the original's object (a save that finished before
    // posters existed, or one whose poster is still to come).
    let n = 0;
    const seed = (over: Record<string, unknown> = {}, o: { row?: boolean; object?: boolean } = {}) => {
        n++;
        const sid = (over.id as string) ?? `${SID.slice(0, 20)}${String(n).padStart(2, "0")}`;
        const r2 = (over.r2_key as string) ?? `originals/${sid}.mp4`;
        const s = {
            id: sid,
            key_id: KEY_ID,
            link: LINK,
            service: "x",
            title: "x_2105237035271258436",
            status: "ready",
            error_code: null,
            r2_key: r2,
            content_type: "video/mp4",
            bytes: 4096,
            duration: 9.6,
            width: 480,
            height: 560,
            created_at: clock.t,
            expires_at: clock.t + SESSION_TTL_MS,
            ...over,
        };
        db.raw
            .prepare(
                "INSERT INTO studio_sessions (id, key_id, link, service, title, status, error_code, r2_key, content_type, bytes, duration, width, height, created_at, expires_at) VALUES (@id,@key_id,@link,@service,@title,@status,@error_code,@r2_key,@content_type,@bytes,@duration,@width,@height,@created_at,@expires_at)",
            )
            .run(s as any);
        if (o.object !== false && r2) {
            originals.objects.set(r2, {
                bytes: new Uint8Array((s.bytes as number) ?? 0).fill(7),
                contentType: (s.content_type as string) ?? "video/mp4",
                meta: {},
            });
        }
        let itemId: string | null = null;
        if (o.row !== false) {
            itemId = `Saved${String(n).padStart(11, "0")}`;
            db.raw
                .prepare(
                    "INSERT INTO media_items (id, kind, source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link, session_id, key_id, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                )
                .run(itemId, "private", "saved", "originals", r2, null, "x_2105237035271258436", s.content_type, s.bytes, s.width, s.height, s.duration, LINK, sid, KEY_ID, clock.t);
        }
        return { sid, r2, itemId: itemId as string };
    };

    const addKey = async () =>
        db.raw
            .prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)")
            .run(KEY_ID, "test", await hashKey(CLIENT), "0b5f2c3e", 1);

    // Polls a session (the Durable Object's advance) until it is no longer saving.
    const settle = async (sid: string, tries = 20) => {
        for (let i = 0; i < tries; i++) {
            const r = await studio.advance(sid, 0);
            if ((r.body as any).status !== "saving") return r;
        }
        throw new Error("the save never finished");
    };

    return {
        db, clock, kv, originals, media, helper, webp, studio, make, seen, container, env, call,
        items, item, session, posters, seed, addKey, settle,
        sweepsArmed: () => sweepsArmed,
    };
}
export type World = ReturnType<typeof world>;
