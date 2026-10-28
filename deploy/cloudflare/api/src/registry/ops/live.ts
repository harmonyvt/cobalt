// Live Activity and Hark routes as ops (APP-API-CONTRACT.md 33.12, plan thread T7): sections 8, 9, 17.6, 27.9 and 32.
// All go to the main Durable Object (token and run store, APNs, the Hark opt-ins) with the verified key id and never
// the client's key; none wakes the container, reads a body here or writes request_log (a relay arrives about once a
// second). Client keys only: the library service gets 404 (one key per device). No CORS: the app sends no Origin.
//
// The Worker's own paths under these prefixes (/live/chats/<thread>/state, /live/edits/<rid>/push) are not ops, so the
// internet gets 404 for them.
import * as z from "zod";
import { EDIT_RENDER_ID_REGEX, STUDIO_SID_REGEX, THREAD_ID_REGEX } from "../../gate";
import { defineOp, type HttpMethod } from "../op";

export const LIVE_RUN_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const toDurableObject = (name: string, method: HttpMethod, path: string, summary: string, params?: Record<string, RegExp>) =>
    defineOp({
        name,
        route: { method, path, ...(params ? { params } : {}) },
        auth: "key",
        runs: "durable_object",
        cors: false,
        input: z.object({}),
        ai: { tier: "hidden", summary },
    });

const both = (name: string, path: string, summary: string, params?: Record<string, RegExp>) => [
    toDurableObject(`${name}.put`, "PUT", path, summary, params),
    toDurableObject(`${name}.delete`, "DELETE", path, summary, params),
];

export const LIVE_OPS = [
    // section 8: the push-to-start token, one save's activity token, the activity's state relay, the self test
    ...both("live.start_token", "/live/start-token", "A device's push-to-start token."),
    ...both("live.run", "/live/runs/:run", "A save's Live Activity token.", { run: LIVE_RUN_REGEX }),
    toDurableObject("live.run.state", "POST", "/live/runs/:run/state", "A save activity's state.", { run: LIVE_RUN_REGEX }),
    toDurableObject("live.selftest", "GET", "/live/selftest", "Test the APNs setup."),
    // section 27.9: chat reply activities
    ...both("live.chat_start_token", "/live/chat-start-token", "A device's push-to-start token for chat replies."),
    toDurableObject("live.chat", "PUT", "/live/chats/:thread", "A push-started chat activity's token.", { thread: THREAD_ID_REGEX }),
    // section 32: editor render activities
    ...both("live.edit", "/live/edits/:rid", "An editor render's activity token.", { rid: EDIT_RENDER_ID_REGEX }),
    // section 9: the Hark opt-in for one save (the Durable Object checks the owner), and 17.6: the line's summary
    ...both("studio.notify", "/studio/:sid/notify", "Hark when this save is done.", { sid: STUDIO_SID_REGEX }),
    ...both("studio.line.notify", "/studio/line/notify", "Hark when the line is done."),
];
