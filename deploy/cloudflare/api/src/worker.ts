// The Worker's request handling, separated from index.ts (which imports the
// Containers library and so cannot load under plain node) so the whole flow,
// gate -> D1 lookup -> Durable Object / container, is testable with fakes.
import { type EmbedClient, librarySearchIndex, librarySearchPost } from "./embed";
import { appDeps, embedFrom, shareHost, type ContainerStub } from "./deps";
import {
    capabilities,
    libraryFile,
    libraryPostersBackfill,
    libraryVisibilityMigrate,
    type AppDeps,
} from "./app-routes";
import { livePushConfigured } from "./apns";
import { ChatLivePusher } from "./chat-live";
import { harkConfigured } from "./notify";
import { saveEmote, searchEmotes } from "./emotes";
import { decide, isStudioPath } from "./gate";
import { KEY_ID_HEADER, SERVICE_HEADER, stripInternalHeaders } from "./headers";
import { lookupKey } from "./keys";
import { SERVICE_KEY_ID } from "./library";
import type { PublishBucket } from "./publish";
import { serviceAuthorized } from "./service-auth";
import { sharePage } from "./share";
import {
    noRoom,
    stageBaseFrom,
    stageKeyed,
    stageSite,
    twitchConfigFrom,
    type RoomPort,
    type StageDeps,
    type StageOp,
} from "./stage";
import type { TwitchFetch } from "./stage-twitch";
import { createShareSet, listShareSets, revokeShareSet } from "./share-sets";
import { deleteSwitchedWebp } from "./visibility";
import { captionerFrom } from "./roast";
import { createCollection, deleteCollection, listCollections, rerollCollection, updateCollection } from "./share-collections";
import { createGroup, deleteGroup, listGroups, updateGroup } from "./collection-groups";
import { editTablesPresent } from "./edits";
import { chatModelFrom, createThread, deleteThread, getCollage, getThread, listThreads, renameThread, sendMessage } from "./chat";
import { ingestTelemetry } from "./telemetry";
import { describeBody, logRequest, normalizeUrlField } from "./request-log";
import { handleOp, opBase, REGISTRY, type Registry } from "./registry/index";
import { chatDepsFrom } from "./registry/ops/chat";
import {
    parseSourceWait,
    parseStudioWait,
    type OriginalsBucket,
} from "./studio";
import {
    preflight,
    studioSource,
    studioStatus,
    withStudioCors,
    type EdgeDeps,
} from "./studio-edge";

export interface WorkerEnv {
    API_URL: string;
    CORS_URL: string;
    // Secret UUIDv4 used ONLY between this Worker and the container.
    COBALT_API_KEY: string;
    // D1 database `cobalt-keys`, table api_keys (d1/migrations/0001_api_keys.sql)
    DB: D1Database;
    // R2 bucket `cobalt-originals` (private): stored source videos of cobalt
    // studio sessions, read only by this Worker and the Durable Object.
    ORIGINALS: OriginalsBucket;
    // R2 bucket `cobalt-media` (public) and its base URL: studio publish copies
    // an original here from the Worker itself.
    MEDIA: PublishBucket;
    MEDIA_BASE_URL: string;
    // Live Activity push (section 8). Secrets: absent or empty means no pushes and
    // `features.live_activity_push` false. The bundle id and transport have defaults.
    APNS_KEY_P8?: string;
    APNS_KEY_ID?: string;
    APNS_TEAM_ID?: string;
    APNS_BUNDLE_ID?: string;
    APNS_VIA?: string;
    // Hark notification bridge (section 9): the webhook URL, a secret. Absent, empty or not
    // an https URL means the bridge is off and `features.notify_bridge` false.
    HARK_WEBHOOK_URL?: string;
    // "1" turns the Hark bridge on; anything else (the config's "0") keeps it off.
    HARK_NOTIFY?: string;
    // Edge-cache purge for the public bucket (section 16): the zone id (a plain var) and a Cache Purge
    // token (a secret). Absent or empty: no purge, `cache_cleared: null`.
    MEDIA_ZONE_ID?: string;
    MEDIA_PURGE_TOKEN?: string;
    // Old Discord attachment links (section 19.6): a Discord bot token, a secret. Handed to the container's helper
    // only; absent or empty means Discord links save exactly as before and `features.discord_refresh` is false.
    DISCORD_BOT_TOKEN?: string;
    // Library search (section 21): the private Hugging Face Space's URL (a plain var), the Hugging Face
    // token that may call it and the Space's own EMBED_KEY (secrets). No URL or token: search is off.
    EMBED_URL?: string;
    // The Space's Hub id (owner/name, a plain var): a sleeping Space that refuses a wake-up is restarted.
    EMBED_SPACE?: string;
    EMBED_TOKEN?: string;
    EMBED_KEY?: string;
    // Rich link pages (section 22): https://<share host>/ (a plain var). The Worker answers that host
    // itself, before the gate. Absent or empty: no pages, `share_base_url: null`.
    SHARE_BASE_URL?: string;
    // Gallery links' moving previews (section 29.1): "1" shows each video in Discord's gallery as a 4 s
    // silent WebP that plays by itself; anything else (the default) shows the real video.
    GALLERY_LOOPS?: string;
    // Roast captions (section 25): the Anthropic key and optional AI Gateway URL (secrets), the model.
    ANTHROPIC_API_KEY?: string;
    ROAST_BASE_URL?: string;
    ROAST_MODEL?: string;
    // Chat (section 27): the model (a plain var; the key is ANTHROPIC_API_KEY) and the Worker Loader
    // binding the model's code runs in. The runner itself comes in through EdgeDeps (index.ts).
    CHAT_MODEL?: string;
    LOADER?: unknown;
    // Stage (section 30): https://<stage host>/ (a plain var; the Worker answers that host itself, before the gate) and
    // the three Twitch secrets. Absent or not https: no stage. Missing secrets: canvas and store only.
    STAGE_BASE_URL?: string;
    TWITCH_CLIENT_ID?: string;
    TWITCH_CLIENT_SECRET?: string;
    TWITCH_EVENTSUB_SECRET?: string;
    // Editor (section 31): the EditRenderer Durable Object namespace (two instances, "r0" and "r1"). Absent: no editor,
    // every /edits route answers 404 error.edit.off and `features.editor` is false. With it, the flag also needs migration 0021.
    EDIT_RENDERER?: DurableObjectNamespace;
    // Chat saves (section 33.7): how many links one chat thread may save in any 24 hours (a plain var, default 20; "0"
    // turns the chat's saves off).
    CHAT_DAILY_SAVES?: string;
    // The chat AI's daily cap on files it starts making per thread (section 33.8, a plain var; default 10).
    CHAT_DAILY_RENDERS?: string;
}

// What the stage needs that is not in the env: the StageRoom Durable Object (index.ts passes the real one) and
// the fetch the Twitch client uses (tests pass a fake).
export type StageEdge = { stageRoom?: RoomPort; twitchFetch?: TwitchFetch; stageEmbed?: EmbedClient | null; stageLimits?: StageDeps["limits"] };

// The op registry the Worker routes through (section 33); tests pass their own.
export type RegistryEdge = { registry?: Registry };

// The stage's deps, or null while STAGE_BASE_URL is not an https URL (every /stage* route is then 404).
function stageDepsFrom(env: WorkerEnv, edge: Pick<EdgeDeps, "now" | "waitUntil">, se: StageEdge): StageDeps | null {
    const stageBaseUrl = stageBaseFrom(env);
    if (!stageBaseUrl) return null;
    return {
        db: env.DB,
        mediaBaseUrl: env.MEDIA_BASE_URL,
        stageBaseUrl,
        twitch: twitchConfigFrom(env),
        twitchFetch: se.twitchFetch,
        embed: se.stageEmbed === undefined ? embedFrom(env) : se.stageEmbed,
        room: se.stageRoom ?? noRoom,
        now: edge.now,
        waitUntil: edge.waitUntil,
        limits: se.stageLimits,
    };
}

// Chat is on with a model (the Anthropic key) and a code runner (the LOADER binding, index.ts).
const chatOn = (env: WorkerEnv, edge: EdgeDeps): boolean =>
    (edge.chatModel === undefined ? chatModelFrom(env, edge.modelFetch) : edge.chatModel) !== null && !!edge.codeRunner;

export { embedFrom, type ContainerStub } from "./deps";
export { bodyLink, describeBody, extractFirstUrl, logRequest, normalizeUrlField, type BodyInfo } from "./request-log";

// Lowercase only: the API rejects a key file with any other spelling.
const UUID_REGEX =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// Rejections from the Worker carry the same CORS header cobalt would send, so
// the web app can read the error code instead of seeing a network failure.
const json = (status: number, body: unknown, allowOrigin?: string) =>
    new Response(JSON.stringify(body), {
        status,
        headers: {
            "content-type": "application/json",
            ...(allowOrigin ? { "access-control-allow-origin": allowOrigin } : {}),
        },
    });

function withCors(res: Response, allowOrigin?: string): Response {
    if (!allowOrigin) return res;
    const out = new Response(res.body, res);
    out.headers.set("access-control-allow-origin", allowOrigin);
    return out;
}

export async function handleRequest(
    incoming: Request,
    env: WorkerEnv,
    container: ContainerStub,
    deps: Partial<EdgeDeps> & StageEdge & RegistryEdge = {},
): Promise<Response> {
    // The share host serves the public link pages and nothing else: no key, no container, no CORS.
    const share = shareHost(env);
    if (share && new URL(incoming.url).hostname === share) {
        return sharePage(
            {
                db: env.DB,
                mediaBaseUrl: env.MEDIA_BASE_URL,
                shareBaseUrl: env.SHARE_BASE_URL!,
                captioner: deps.captioner === undefined ? captionerFrom(env, deps.modelFetch) : deps.captioner,
                waitUntil: deps.waitUntil,
                loops: env.GALLERY_LOOPS === "1",
            },
            incoming,
        );
    }
    // The stage host serves the canvas, the store and the Twitch webhooks (section 30.4): no key, no container, no CORS.
    // Its own gate is the canvas token, the store lock and the EventSub signature.
    const stageNow = deps.now ?? (() => Date.now());
    const stage = stageDepsFrom(env, { now: stageNow, waitUntil: deps.waitUntil }, deps);
    const host = new URL(incoming.url).hostname;
    if (stage && host === new URL(stage.stageBaseUrl).hostname) return stageSite(stage, incoming);
    // The studio host is routed to this Worker whether or not the stage is on: with it off (or on another host) it
    // must not fall through to the API's gate and routes.
    if (host.startsWith("studio.")) {
        return new Response("not found\n", { status: 404, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
    }
    const res = await handleInner(incoming, env, container, {
        now: deps.now ?? (() => Date.now()),
        sleep: deps.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))),
        fixedLength: deps.fixedLength,
        captioner: deps.captioner,
        chatModel: deps.chatModel,
        codeRunner: deps.codeRunner,
        waitUntil: deps.waitUntil,
        // the Anthropic relay (src/model-fetch.ts): without it, chat and captions call from the local colo
        modelFetch: deps.modelFetch,
    }, deps);
    // Every /studio* response, rejections included, carries the studio page's
    // origin (STUDIO-CONTRACT.md); the page is the only intended caller.
    return isStudioPath(new URL(incoming.url).pathname)
        ? withStudioCors(res, env.CORS_URL)
        : res;
}

async function handleInner(
    incoming: Request,
    env: WorkerEnv,
    container: ContainerStub,
    edge: EdgeDeps,
    stageEdge: StageEdge & RegistryEdge = {},
): Promise<Response> {
    // Misconfiguration must not wake (and crash-loop) the container: the
    // API refuses to load a key file that has a non-UUID key.
    if (!env.COBALT_API_KEY || !UUID_REGEX.test(env.COBALT_API_KEY)) {
        return json(503, {
            status: "error",
            error: { code: "error.api.generic" },
        });
    }

    // The library service credential is read before the headers are stripped;
    // a wrong or empty value is simply "not the service".
    const isService = await serviceAuthorized(
        incoming.headers.get(SERVICE_HEADER),
        env.COBALT_API_KEY,
    );

    // Security: drop headers only this Worker may set, from EVERY request,
    // before anything can forward it (see headers.ts).
    let request = new Request(incoming, {
        headers: stripInternalHeaders(incoming.headers),
    });

    const url = new URL(request.url);
    const origin = request.headers.get("Origin");
    const allowOrigin = origin === env.CORS_URL ? origin : undefined;

    // The op registry answers the routes it knows (section 33); everything else goes on to the gate below.
    const registry = stageEdge.registry ?? REGISTRY;
    const byOp = await handleOp(registry, opBase(env, container, edge, registry), { request, url, service: isService, allowOrigin });
    if (byOp) return byOp;

    const decision = decide(
        {
            method: request.method,
            pathname: url.pathname,
            searchParams: url.searchParams,
            origin: request.headers.get("Origin"),
            authorization: request.headers.get("Authorization"),
            service: isService,
        },
        {
            corsUrl: env.CORS_URL,
            now: edge.now(),
        },
    );

    if (decision.action === "reject") {
        if (decision.errorCode) {
            return json(
                decision.status,
                { status: "error", error: { code: decision.errorCode } },
                allowOrigin,
            );
        }
        return new Response(null, { status: decision.status });
    }

    if (decision.action === "studio") {
        const { sid } = decision;
        switch (decision.op) {
            case "preflight":
                return preflight(env.CORS_URL);
            case "status":
                return studioStatus(
                    env.DB,
                    container,
                    sid!,
                    parseStudioWait(url.searchParams.get("wait")),
                    edge,
                );
            case "source":
                return studioSource(env.DB, env.ORIGINALS, sid!, request, edge, {
                    container,
                    seconds: parseSourceWait(url.searchParams.get("wait")),
                });
        }
    }

    // GET /capabilities: the key's state is reported, never refused.
    if (decision.action === "capabilities") {
        const helper = await helperHas(container);
        const r = await capabilities(
            appDeps(env, container, edge),
            decision.auth,
            decision.key,
            livePushConfigured(env),
            harkConfigured(env),
            helper[0],
            helper[1],
            helper[2],
            helper[3],
            embedFrom(env) !== null,
            chatOn(env, edge),
            stageBaseFrom(env) !== null,
            twitchConfigFrom(env) !== null,
            // the editor is on exactly while the renderer binding is there and migration 0021 is applied (section 31.13)
            !!env.EDIT_RENDERER && (await editTablesPresent(env.DB, edge.now())),
            helper[4],
        );
        return new Response(JSON.stringify(r.body), {
            status: r.status,
            headers: { "content-type": "application/json", "cache-control": "no-store" },
        });
    }

    if (decision.action === "lookup" || decision.action === "service") {
        let keyId: string | null;
        if (decision.action === "service") {
            // Already authenticated by the gate (constant-time header check).
            keyId = SERVICE_KEY_ID;
        } else {
            try {
                keyId = await lookupKey(env.DB, decision.key, Date.now());
            } catch {
                // Fail closed: never forward when D1 cannot vouch for the key.
                return json(
                    503,
                    { status: "error", error: { code: "error.api.generic" } },
                    allowOrigin,
                );
            }
            if (keyId === null) {
                return json(
                    401,
                    {
                        status: "error",
                        error: { code: "error.api.auth.key.invalid" },
                    },
                    allowOrigin,
                );
            }
        }

        // POST /telemetry: D1 + R2 only, no CORS. Dispatched here, before anything that
        // reads a body or writes the request log: a batch never reaches `request_log`.
        if (decision.then === "telemetry_ingest") {
            const r = await ingestTelemetry({ db: env.DB, originals: env.ORIGINALS, now: edge.now }, request, keyId);
            return new Response(JSON.stringify(r.body), {
                status: r.status,
                headers: { "content-type": "application/json", "cache-control": "no-store", ...r.headers },
            });
        }

        if (decision.then === "library_search_index") {
            const deps = { ...appDeps(env, container, edge), embed: embedFrom(env) };
            const r = await librarySearchIndex(deps, url.searchParams);
            return new Response(JSON.stringify(r.body), {
                status: r.status,
                headers: { "content-type": "application/json", "cache-control": "no-store" },
            });
        }
        if (decision.then === "library_search_post") {
            const deps = { db: env.DB, mediaBaseUrl: env.MEDIA_BASE_URL, searchEnabled: embedFrom(env) !== null };
            const r = await librarySearchPost(deps, url.searchParams);
            return new Response(JSON.stringify(r.body), {
                status: r.status,
                headers: { "content-type": "application/json", "cache-control": "no-store" },
            });
        }
        // Gallery share links (section 24): D1 only.
        if (decision.then === "share_sets_create" || decision.then === "share_sets_list" || decision.then === "share_sets_revoke") {
            const shareBaseUrl = shareHost(env) ? env.SHARE_BASE_URL : undefined;
            if (!shareBaseUrl) return json(404, { status: "error", error: { code: "error.share.off" } }, allowOrigin);
            const sd = {
                db: env.DB,
                mediaBaseUrl: env.MEDIA_BASE_URL,
                shareBaseUrl,
                now: edge.now,
                captioner: edge.captioner ?? captionerFrom(env, edge.modelFetch),
                // a new link's videos get moving previews (section 29): the Durable Object only writes records
                kickLoops: env.GALLERY_LOOPS !== "1" ? undefined : async () => {
                    const p = container
                        .fetch(
                            new Request("https://do.internal/loops/kick", {
                                method: "POST",
                                headers: { [KEY_ID_HEADER]: "worker:loops" },
                            }),
                        )
                        .then(
                            (res) => void res.body?.cancel().catch(() => {}),
                            (e) => console.error("[loops] kick failed", e instanceof Error ? e.name : "error"),
                        );
                    if (edge.waitUntil) edge.waitUntil(p);
                    else await p;
                },
            };
            const r =
                decision.then === "share_sets_create"
                    ? await createShareSet(sd, request, keyId)
                    : decision.then === "share_sets_list"
                      ? await listShareSets(sd)
                      : await revokeShareSet(sd, decision.params!.id);
            const res = json(r.status, r.body, allowOrigin);
            res.headers.set("cache-control", "no-store");
            return res;
        }
        // Chat (section 27): D1, the model, and the code sandbox.
        if (
            decision.then === "chat_list" ||
            decision.then === "chat_create" ||
            decision.then === "chat_get" ||
            decision.then === "chat_rename" ||
            decision.then === "chat_delete" ||
            decision.then === "chat_send" ||
            decision.then === "chat_collage"
        ) {
            const noStore = (r: { status: number; body: unknown }) => {
                const res = json(r.status, r.body, allowOrigin);
                res.headers.set("cache-control", "no-store");
                return res;
            };
            const base = chatDepsFrom(opBase(env, container, edge, registry));
            if (!base) return noStore({ status: 404, body: { status: "error", error: { code: "error.chat.off" } } });
            const cd = {
                ...base,
                // section 27.9: the reply's Live Activity on the owner's other iPhones, through the Durable Object
                liveFor: livePushConfigured(env)
                    ? (thread: string, prompt: string) =>
                          new ChatLivePusher({
                              thread,
                              keyId,
                              prompt,
                              now: edge.now,
                              post: async (body) => {
                                  const res = await container.fetch(
                                      new Request(`https://do.internal/live/chats/${thread}/state`, {
                                          method: "POST",
                                          headers: { "content-type": "application/json", "x-internal-key": env.COBALT_API_KEY },
                                          body: JSON.stringify(body),
                                      }),
                                  );
                                  if (!res.ok) {
                                      await res.body?.cancel();
                                      return null;
                                  }
                                  const j = (await res.json()) as { targets?: number };
                                  return typeof j.targets === "number" ? { targets: j.targets } : null;
                              },
                          })
                    : undefined,
            };
            const id = decision.params?.id ?? "";
            if (decision.then === "chat_send") {
                const r = await sendMessage(cd, request, id);
                if (r instanceof Response) {
                    if (allowOrigin) r.headers.set("access-control-allow-origin", allowOrigin);
                    return r;
                }
                return noStore(r);
            }
            const r =
                decision.then === "chat_list"
                    ? await listThreads(cd)
                    : decision.then === "chat_collage"
                      ? await getCollage(cd, id, decision.params?.message ?? "", url.searchParams)
                    : decision.then === "chat_create"
                      ? await createThread(cd, request, keyId)
                      : decision.then === "chat_get"
                        ? await getThread(cd, id)
                        : decision.then === "chat_rename"
                          ? await renameThread(cd, request, id)
                          : await deleteThread(cd, id);
            return noStore(r);
        }
        // Share link collections (section 26): D1 only.
        if (
            decision.then === "collections_list" ||
            decision.then === "collections_create" ||
            decision.then === "collections_update" ||
            decision.then === "collections_delete" ||
            decision.then === "collections_reroll"
        ) {
            if (!shareHost(env)) return json(404, { status: "error", error: { code: "error.share.off" } }, allowOrigin);
            const cd = {
                db: env.DB,
                now: edge.now,
                mediaBaseUrl: env.MEDIA_BASE_URL,
                shareBaseUrl: env.SHARE_BASE_URL,
                captioner: edge.captioner === undefined ? captionerFrom(env, edge.modelFetch) : edge.captioner,
            };
            const r =
                decision.then === "collections_list"
                    ? await listCollections(cd)
                    : decision.then === "collections_create"
                      ? await createCollection(cd, request, keyId)
                      : decision.then === "collections_update"
                        ? await updateCollection(cd, request, decision.params!.id)
                        : decision.then === "collections_delete"
                          ? await deleteCollection(cd, decision.params!.id)
                          : await rerollCollection(cd, decision.params!.id, keyId);
            const res = json(r.status, r.body, allowOrigin);
            res.headers.set("cache-control", "no-store");
            return res;
        }
        // Collection sets (section 28): D1 only.
        if (
            decision.then === "groups_list" ||
            decision.then === "groups_create" ||
            decision.then === "groups_update" ||
            decision.then === "groups_delete"
        ) {
            if (!shareHost(env)) return json(404, { status: "error", error: { code: "error.share.off" } }, allowOrigin);
            const gd = { db: env.DB, now: edge.now };
            const r =
                decision.then === "groups_list"
                    ? await listGroups(gd)
                    : decision.then === "groups_create"
                      ? await createGroup(gd, request, keyId)
                      : decision.then === "groups_update"
                        ? await updateGroup(gd, request, decision.params!.id)
                        : await deleteGroup(gd, decision.params!.id);
            const res = json(r.status, r.body, allowOrigin);
            res.headers.set("cache-control", "no-store");
            return res;
        }
        // Editor routes (section 31.12) are ops in the registry (src/registry/ops/make.ts, section 33.8).
        // Stage owner routes (section 30.10): D1, the StageRoom Durable Object and Twitch; never the container.
        if (decision.then?.startsWith("stage_")) {
            const sd = stageDepsFrom(env, edge, stageEdge);
            const reply = sd
                ? await stageKeyed(sd, decision.then.slice("stage_".length) as StageOp, request, decision.params ?? {}, url.searchParams)
                : { status: 404, body: { status: "error", error: { code: "error.stage.off" } } };
            const res = json(reply.status, reply.body, allowOrigin);
            res.headers.set("cache-control", "no-store");
            return res;
        }
        if (decision.then === "emotes_search" || decision.then === "emotes_save") {
            const deps = appDeps(env, container, edge);
            const r =
                decision.then === "emotes_search"
                    ? await searchEmotes(deps, url.searchParams)
                    : await saveEmote(deps, request, keyId);
            return json(r.status, r.body, allowOrigin);
        }
        if (decision.then === "library_file") {
            return libraryFile(appDeps(env, container, edge), decision.params!.id, request);
        }
        // POST /library/visibility/migrate (section 16.4): D1 + R2 only, no CORS. (The toggle itself is an op,
        // src/registry/ops/library-writes.ts.)
        if (decision.then === "library_visibility_migrate") {
            const r = await libraryVisibilityMigrate(appDeps(env, container, edge), url.searchParams);
            return new Response(JSON.stringify(r.body), {
                status: r.status,
                headers: { "content-type": "application/json", "cache-control": "no-store" },
            });
        }
        // DELETE /media/<name>.webp of a webp that was switched private once: its bytes live in the
        // private bucket now, so both copies go here; any other name is the webp service's as before.
        if (decision.then === "media_delete") {
            const r = await deleteSwitchedWebp(appDeps(env, container, edge), decision.params!.name);
            if (r) return json(r.status, r.body, allowOrigin);
        }
        // POST /library/posters/backfill: queues the posters still missing (section 13). The
        // Durable Object only writes records; no CORS (the page does not call it).
        if (decision.then === "library_posters_backfill") {
            const raw = url.searchParams.get("limit");
            const limit = raw !== null && /^\d{1,4}$/.test(raw) ? Number(raw) : undefined;
            const r = await libraryPostersBackfill(appDeps(env, container, edge), limit);
            return new Response(JSON.stringify(r.body), {
                status: r.status,
                headers: { "content-type": "application/json", "cache-control": "no-store" },
            });
        }

        // Live Activity push: handled by the Durable Object (token and run store, APNs),
        // which never wakes the container. Dispatched here, before anything that
        // reads a body or writes the request log: a relay arrives about once a
        // second and must never reach `request_log`. The caller's key is not
        // passed on; only its id, which the Worker just verified.
        if (
            decision.then === "live_start_token" ||
            decision.then === "live_run" ||
            decision.then === "live_state" ||
            decision.then === "live_selftest" ||
            decision.then === "live_edit" ||
            decision.then === "live_chat" ||
            // the Hark opt-in (also DO-only: D1 ownership check and DO storage)
            decision.then === "studio_notify" ||
            // the server's line's Hark summary (section 17): DO storage and D1; never wakes the container. (The line,
            // the cancels, the recent saves and the items retry are ops: src/registry/ops/library-writes.ts; the slideshow and
            // the gallery image: ops/make.ts.)
            decision.then === "studio_line_notify"
        ) {
            const headers = new Headers(request.headers);
            headers.delete("Authorization");
            headers.set(KEY_ID_HEADER, keyId);
            return container.fetch(new Request(request, { headers }));
        }

        // Clients (the macOS Shortcut) may send free text as `url`; take the
        // first http(s) link from it. The Shortcut's own "Get URLs from Input"
        // step produced an empty string on macOS 27 (2026-09-30), so link
        // extraction lives here instead.
        // Log AFTER extraction: the Shortcut sends its share input plus the
        // whole clipboard as `url`, and clipboard text must never be stored.
        // (Logging before extraction captured clipboard snippets; scrubbed
        // 2026-09-30.) When no link is found, only the length is kept.
        if (request.method === "POST") request = await normalizeUrlField(request);
        const logEntry =
            request.method === "POST" ? await describeBody(request) : null;
        if (logEntry && logEntry.urlPrefix !== null && !/^https?:\/\//i.test(logEntry.urlPrefix)) {
            logEntry.urlPrefix = null;
        }

        const headers = new Headers(request.headers);
        if (decision.then) {
            // /webp and /media: same Durable Object, with the caller's key id
            // (trusted only because it was set here, after the D1 lookup). The
            // client's own key is not passed on.
            headers.delete("Authorization");
            headers.set(KEY_ID_HEADER, keyId);
            const res = await container.fetch(new Request(request, { headers }));
            if (logEntry) await logRequest(env.DB, `POST ${url.pathname}`, keyId, request, logEntry, res);
            return withCors(res, allowOrigin);
        }
        // The container only knows the internal key.
        headers.set("Authorization", `Api-Key ${env.COBALT_API_KEY}`);
        const res = await container.fetch(new Request(request, { headers }));
        if (logEntry) await logRequest(env.DB, "POST /", keyId, request, logEntry, res);
        return res;
    }

    // One named instance for everything: tunnels created by POST / live in
    // that process's memory and must be served by the same one.
    return container.fetch(request);
}

// What the container's helper has said it can do (the Durable Object keeps what it last answered; it never wakes the
// container for this): the slideshow routes (`gallery`), and the webp slideshow, the gallery image and `item` renders
// (`make`), a pasted link straight to a media file (`direct`, section 19), and a webp of one photo (`still`, 18.14). Any failure is "not yet": the capability is simply not offered.
async function helperHas(container: ContainerStub): Promise<[boolean, boolean, boolean, boolean, boolean]> {
    const none: [boolean, boolean, boolean, boolean, boolean] = [false, false, false, false, false];
    try {
        const res = await container.fetch(new Request("https://do.internal/helper/caps", { headers: { [KEY_ID_HEADER]: "worker:capabilities" } }));
        if (res.status !== 200) return none;
        const body = (await res.json()) as { gallery?: unknown; make?: unknown; direct?: unknown; still?: unknown; discord?: unknown };
        return [body?.gallery === true, body?.make === true, body?.direct === true, body?.still === true, body?.discord === true];
    } catch {
        return none;
    }
}
