// Container entrypoint: runs cobalt's API (`node src/cobalt`) as a child and, in
// the same container, serves the helper API (animated WebPs, and cobalt
// studio's fetch / upload endpoints; see ./server.js for the routes) on
// [::]:9100 (dual-stack).
//
// Port 9100 is reachable only through the Durable Object (which sends
// x-internal-key, the Worker's COBALT_API_KEY secret); every request without it
// gets 403. One job runs at a time. Plain Node ESM, no dependencies.

import { spawn } from "node:child_process";
import { createHelper } from "./server.js";

const APP_DIR = process.env.COBALT_APP_DIR || "/app";
const INTERNAL_KEY = process.env.COBALT_INTERNAL_KEY || "";
const PORT = Number(process.env.WEBP_HELPER_PORT || 9100);
const COBALT = process.env.WEBP_COBALT_ORIGIN || undefined;
const WORK_DIR = process.env.WEBP_WORK_DIR || "/tmp/webp";
const FETCH_DIR = process.env.STUDIO_FETCH_DIR || "/tmp/fetch";
const FFMPEG_TIMEOUT_MS = Number(process.env.WEBP_FFMPEG_TIMEOUT_MS || 240_000);

let apiOrigin;
try {
    // cobalt's tunnel URLs are built from API_URL (the public api host in
    // production); resolveSource rewrites those to the local origin.
    apiOrigin = process.env.API_URL ? new URL(process.env.API_URL).origin : undefined;
} catch {}

if (!INTERNAL_KEY) {
    console.error("[webp-helper] COBALT_INTERNAL_KEY is not set: every request will be refused");
}

// --- cobalt child ------------------------------------------------------------

const cobalt = spawn(process.execPath, ["src/cobalt"], {
    cwd: APP_DIR,
    stdio: "inherit",
});

const helper = createHelper({
    appDir: APP_DIR,
    internalKey: INTERNAL_KEY,
    workDir: WORK_DIR,
    fetchDir: FETCH_DIR,
    cobaltOrigin: COBALT,
    apiOrigin,
    ffmpegTimeoutMs: FFMPEG_TIMEOUT_MS,
});

// set when WE forwarded a stop signal, so cobalt dying from it is a clean exit
let stopping = false;
for (const sig of ["SIGTERM", "SIGINT"]) {
    process.on(sig, () => {
        stopping = true;
        if (cobalt.exitCode === null && cobalt.signalCode === null) cobalt.kill(sig);
        else process.exit(0);
    });
}

cobalt.on("error", (e) => {
    console.error("[webp-helper] cannot start cobalt:", e);
    process.exit(1);
});
cobalt.on("exit", (code, signal) => {
    console.error(`[webp-helper] cobalt exited (code=${code}, signal=${signal})`);
    helper.killAll();
    process.exit(code ?? (stopping ? 0 : 1));
});

helper.server.on("error", (e) => {
    console.error("[webp-helper] cannot listen:", e);
    cobalt.kill("SIGTERM");
    process.exit(1);
});
// "::" is dual-stack (IPv4 + IPv6), like cobalt's own listener. Cloudflare
// Containers are provisioned with `assign_ipv4: none`, and a 0.0.0.0-only bind
// never became reachable there: every POST /webp failed after the library's
// 20 s port wait with error.webp.unavailable (2026-09-30).
helper.server.listen(PORT, "::", () => {
    console.error(`[webp-helper] listening on [::]:${PORT}`);
});
