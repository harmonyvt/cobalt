// The Worker's other hosts as ops (APP-API-CONTRACT.md 33.12, plan thread T7): the share host's link pages (section 22),
// the stage host's canvas, store and Twitch webhooks (section 30.4), and a 404 page for any other studio.* host. Each is
// one raw catch-all: the host's own router answers every path and method, with no key, no container and no CORS. They
// run before the API's checks (the internal key, the header strip), exactly as before.
import * as z from "zod";
import { stageDepsFrom } from "../../deps";
import { captionerFrom } from "../../roast";
import { sharePage } from "../../share";
import { stageSite } from "../../stage";
import { defineOp } from "../op";

const NoInput = z.object({});
const none = () => ({});
const notFoundPage = () =>
    new Response("not found\n", { status: 404, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });

export const sharePagesOp = defineOp({
    name: "host.share",
    route: { host: "share", method: "ANY", path: "/*" },
    auth: "open",
    runs: "worker",
    cors: false,
    input: NoInput,
    http: none,
    raw: true,
    ai: { tier: "hidden", summary: "The share host's link pages." },
    handler: async (ctx) =>
        sharePage(
            {
                db: ctx.db,
                mediaBaseUrl: ctx.mediaBaseUrl,
                shareBaseUrl: ctx.env.SHARE_BASE_URL!,
                captioner: ctx.edge.captioner === undefined ? captionerFrom(ctx.env, ctx.edge.modelFetch) : ctx.edge.captioner,
                waitUntil: ctx.edge.waitUntil,
                loops: ctx.env.GALLERY_LOOPS === "1",
                // private links' files (section 36)
                originals: ctx.env.ORIGINALS,
                media: ctx.env.MEDIA,
                now: ctx.now,
            },
            ctx.request!,
        ),
});

// Its own gate is the canvas token, the store lock and the EventSub signature.
export const stageSiteOp = defineOp({
    name: "host.stage",
    route: { host: "stage", method: "ANY", path: "/*" },
    auth: "open",
    runs: "worker",
    cors: false,
    input: NoInput,
    http: none,
    raw: true,
    ai: { tier: "hidden", summary: "The stage host's canvas, store and webhooks." },
    handler: async (ctx) => {
        const d = stageDepsFrom(ctx.env, ctx.edge, ctx.stageEdge);
        return d ? stageSite(d, ctx.request!) : notFoundPage();
    },
});

// The studio host is routed to this Worker whether or not the stage is on: with it off (or on another host) it must
// not reach the API's routes.
export const studioHostOp = defineOp({
    name: "host.studio",
    route: { host: "studio", method: "ANY", path: "/*" },
    auth: "open",
    runs: "worker",
    cors: false,
    input: NoInput,
    http: none,
    raw: true,
    ai: { tier: "hidden", summary: "Any other studio.* host: a 404 page." },
    handler: async () => notFoundPage(),
});

export const HOST_OPS = [sharePagesOp, stageSiteOp, studioHostOp];
