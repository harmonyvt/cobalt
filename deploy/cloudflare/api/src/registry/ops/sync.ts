// GET /sync (the Capystore sync engine, slice 1). Keyed the same way as GET /library. The page is the contract the
// app already speaks: seq, more, the library post object, the other synced things, and gone. Hidden from the chat.
import * as z from "zod";
import { syncPage } from "../../sync";
import { defineOp } from "../op";

const AnyQuery = z.record(z.string(), z.string());

export const syncOp = defineOp({
    name: "sync",
    route: { method: "GET", path: "/sync" },
    auth: "key_or_service",
    runs: "worker",
    cors: true,
    noStore: true,
    input: AnyQuery,
    badRequest: "error.sync.bad_request",
    http: (ctx) => Object.fromEntries(ctx.query),
    ai: { tier: "hidden", summary: "What changed in the library since a change number (GET /sync)." },
    handler: async (ctx) => syncPage({ db: ctx.db, now: ctx.now, apiUrl: ctx.env.API_URL, shareBaseUrl: ctx.shareBaseUrl }, ctx.query),
});

export const SYNC_OPS = [syncOp];
