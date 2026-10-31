// System routes as ops (APP-API-CONTRACT.md 33.12, plan thread T7): app discovery, telemetry, the upstream cobalt API
// (POST /, GET /, GET /tunnel) and the webp service (POST /webp, GET /webp/<id>, DELETE /media/<name>). All tier hidden:
// owner and system plumbing the chat AI never sees. Each wraps the code worker.ts ran for it, unchanged.
import * as z from "zod";
import { capabilities } from "../../app-routes";
import { livePushConfigured } from "../../apns";
import { chatModelFrom } from "../../chat";
import { embedFrom } from "../../deps";
import { editTablesPresent } from "../../edits";
import { MEDIA_NAME_REGEX, parseAuthorization, TUNNEL_PARAMS, WEBP_ID_REGEX } from "../../gate";
import { KEY_ID_HEADER } from "../../headers";
import { harkConfigured } from "../../notify";
import { describeBody, logRequest, normalizeUrlField, type BodyInfo } from "../../request-log";
import { stageBaseFrom, twitchConfigFrom } from "../../stage";
import { ingestTelemetry } from "../../telemetry";
import { deleteSwitchedWebp } from "../../visibility";
import type { ContainerStub } from "../../deps";
import { defineOp, type OpContext } from "../op";

// The handlers read their own request (query, body, headers): no schema input.
const NoInput = z.object({});
const none = () => ({});
const notFound = () => new Response(null, { status: 404 });

// What the container's helper has said it can do (the Durable Object keeps what it last answered; it never wakes the
// container for this): the slideshow routes (`gallery`), the webp slideshow, the gallery image and `item` renders
// (`make`), a pasted link straight to a media file (`direct`, section 19), a webp of one photo (`still`, 18.14) and old
// Discord links (`discord`, 19.6). Any failure is "not yet": the capability is simply not offered.
export async function helperHas(container: ContainerStub): Promise<[boolean, boolean, boolean, boolean, boolean]> {
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

// Chat is on with a model (the Anthropic key) and a code runner (the LOADER binding, index.ts).
const chatOn = (ctx: OpContext): boolean =>
    (ctx.edge.chatModel === undefined ? chatModelFrom(ctx.env, ctx.edge.modelFetch) : ctx.edge.chatModel) !== null && !!ctx.edge.codeRunner;

// What a /capabilities request carried: the service, no header, a bad header or a well-formed key (D1 decides later
// whether it is registered). Never a refusal.
export function capabilitiesAuth(service: boolean, header: string | null): { auth: "service" | "missing" | "invalid" | "key"; key?: string } {
    if (service) return { auth: "service" };
    if (header === null) return { auth: "missing" };
    const parsed = parseAuthorization(header);
    return "key" in parsed ? { auth: "key", key: parsed.key } : { auth: "invalid" };
}

// GET /: only the web app's origin.
export const infoAllowed = (origin: string | null, corsUrl: string): boolean => origin !== null && origin === corsUrl;

// GET /tunnel: every tunnel parameter present and `exp` (Unix ms) still ahead.
export function tunnelOpen(query: URLSearchParams, now: number): boolean {
    for (const p of TUNNEL_PARAMS) if (!query.get(p)) return false;
    const exp = Number(query.get("exp"));
    return Number.isFinite(exp) && exp > now;
}

// GET /capabilities (section 1): open to everyone, never a 401. The key (if any) only changes the answer.
export const capabilitiesOp = defineOp({
    name: "capabilities",
    route: { method: "GET", path: "/capabilities" },
    auth: "open",
    runs: "worker",
    cors: false,
    noStore: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "What this server can do (GET /capabilities)." },
    handler: async (ctx) => {
        const { auth, key } = capabilitiesAuth(ctx.caller === "service", ctx.request!.headers.get("Authorization"));
        const env = ctx.env;
        const helper = await helperHas(ctx.container);
        const r = await capabilities(
            ctx.app(),
            auth,
            key,
            livePushConfigured(env),
            harkConfigured(env),
            helper[0],
            helper[1],
            helper[2],
            helper[3],
            embedFrom(env) !== null,
            chatOn(ctx),
            stageBaseFrom(env) !== null,
            twitchConfigFrom(env) !== null,
            // the editor is on exactly while the renderer binding is there and migration 0021 is applied (section 31.13)
            !!env.EDIT_RENDERER && (await editTablesPresent(ctx.db, ctx.now())),
            helper[4],
            // section 34: the words need the Anthropic key, the sound Workers AI
            !!env.ANTHROPIC_API_KEY?.trim(),
            !!env.AI,
            // section 39.5: cutouts by the server (auto lifts the subject) need the Cloudflare Images binding
            !!env.IMAGES,
        );
        return { status: r.status, body: r.body };
    },
});

// POST /telemetry (TELEMETRY-CONTRACT.md): client keys only (one key per device; the service gets 404), D1 + R2, no CORS.
// A batch never reaches request_log.
export const telemetryOp = defineOp({
    name: "telemetry",
    route: { method: "POST", path: "/telemetry" },
    auth: "key",
    runs: "worker",
    cors: false,
    noStore: true,
    input: NoInput,
    http: none,
    ai: { tier: "hidden", summary: "Crash and log telemetry (POST /telemetry)." },
    handler: async (ctx) => {
        const r = await ingestTelemetry({ db: ctx.db, originals: ctx.env.ORIGINALS, now: ctx.now }, ctx.request!, ctx.keyId!);
        return { status: r.status, body: r.body, headers: r.headers };
    },
});

// A keyed POST's log row. Clients (the macOS Shortcut) may send free text as `url`: the first http(s) link is taken
// from it first, and the row is written after that, so clipboard text is never stored (scrubbed 2026-09-30). When no
// link is found only the length is kept.
export async function loggedPost(request: Request): Promise<{ request: Request; log: BodyInfo }> {
    const normal = await normalizeUrlField(request);
    const log = await describeBody(normal);
    if (log.urlPrefix !== null && !/^https?:\/\//i.test(log.urlPrefix)) log.urlPrefix = null;
    return { request: normal, log };
}

// The request on to the main Durable Object with this call's key id, never the client's key.
export function toDurableObject(request: Request, keyId: string): Request {
    const headers = new Headers(request.headers);
    headers.delete("Authorization");
    headers.set(KEY_ID_HEADER, keyId);
    return new Request(request, { headers });
}

// POST / (upstream cobalt): a client key or the library service, forwarded to the container with the INTERNAL key
// swapped in (the container knows no other). Logged in request_log. No CORS header is added: the container's own.
export const cobaltOp = defineOp({
    name: "cobalt",
    route: { method: "POST", path: "/" },
    auth: "key_or_service",
    runs: "worker",
    cors: false,
    input: NoInput,
    http: none,
    raw: true,
    ai: { tier: "hidden", summary: "Upstream cobalt (POST /)." },
    handler: async (ctx) => {
        const { request, log } = await loggedPost(ctx.request!);
        const headers = new Headers(request.headers);
        headers.set("Authorization", `Api-Key ${ctx.env.COBALT_API_KEY}`);
        const res = await ctx.container.fetch(new Request(request, { headers }));
        await logRequest(ctx.db, "POST /", ctx.keyId!, request, log, res);
        return res;
    },
});

// GET / (upstream cobalt's instance info): only for the web app's origin; anyone else gets a bodyless 404.
export const cobaltInfoOp = defineOp({
    name: "cobalt.info",
    route: { method: "GET", path: "/" },
    auth: "open",
    runs: "worker",
    cors: false,
    input: NoInput,
    http: none,
    raw: true,
    ai: { tier: "hidden", summary: "Upstream cobalt's instance info (GET /)." },
    handler: async (ctx) => {
        return infoAllowed(ctx.request!.headers.get("Origin"), ctx.env.CORS_URL) ? ctx.container.fetch(ctx.request!) : notFound();
    },
});

// GET /tunnel (upstream cobalt's streams): every tunnel parameter present and `exp` (Unix ms) still ahead; else a
// bodyless 404 without waking the container. One named instance serves them all: tunnels live in its memory.
export const tunnelOp = defineOp({
    name: "cobalt.tunnel",
    route: { method: "GET", path: "/tunnel" },
    auth: "open",
    runs: "worker",
    cors: false,
    input: NoInput,
    http: none,
    raw: true,
    ai: { tier: "hidden", summary: "Upstream cobalt's streams (GET /tunnel)." },
    handler: async (ctx) => {
        return tunnelOpen(ctx.query, ctx.now()) ? ctx.container.fetch(ctx.request!) : notFound();
    },
});

// POST /webp (the webp service, deploy/cloudflare/README.md): the Durable Object with the key id; logged.
export const webpCreateOp = defineOp({
    name: "webp.create",
    route: { method: "POST", path: "/webp" },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    input: NoInput,
    http: none,
    raw: true,
    ai: { tier: "hidden", summary: "Start a webp encode (POST /webp)." },
    handler: async (ctx) => {
        const { request, log } = await loggedPost(ctx.request!);
        const res = await ctx.container.fetch(toDurableObject(request, ctx.keyId!));
        await logRequest(ctx.db, "POST /webp", ctx.keyId!, request, log, res);
        return res;
    },
});

// GET /webp/<id>: the encode's status, from the Durable Object.
export const webpStatusOp = defineOp({
    name: "webp.status",
    route: { method: "GET", path: "/webp/:id", params: { id: WEBP_ID_REGEX } },
    auth: "key_or_service",
    runs: "durable_object",
    cors: true,
    input: NoInput,
    raw: true,
    ai: { tier: "hidden", summary: "A webp encode's status (GET /webp/<id>)." },
});

// DELETE /media/<name>.webp: a webp that was switched private once has its bytes in the private bucket, so both copies
// go here (section 16); any other name is the webp service's, in the Durable Object.
export const mediaDeleteOp = defineOp({
    name: "media.delete",
    route: { method: "DELETE", path: "/media/:name", params: { name: MEDIA_NAME_REGEX } },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    input: NoInput,
    http: none,
    raw: true,
    ai: { tier: "hidden", summary: "Delete a hosted webp (DELETE /media/<name>)." },
    handler: async (ctx) => {
        const r = await deleteSwitchedWebp(ctx.app(), ctx.params.name!);
        if (r) return { status: r.status, body: r.body };
        return ctx.container.fetch(toDurableObject(ctx.request!, ctx.keyId!));
    },
});

export const SYSTEM_OPS = [capabilitiesOp, telemetryOp, cobaltOp, cobaltInfoOp, tunnelOp, webpCreateOp, webpStatusOp, mediaDeleteOp];
