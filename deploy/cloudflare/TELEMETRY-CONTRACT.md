# cobalt telemetry: contract as built (server half)

Self-hosted crash and log telemetry for the native app. The app uploads batches of log events and
crash/diagnostic reports to `POST /telemetry` on the API Worker; the owner reads them on the web
origin at `/logs`. Nothing leaves this deployment. This file is the server side as built; the app
lane's client is written against the pinned request/response below.

Everything here is additive: no existing route, table, binding or response changes (the only edits to
existing behaviour are `features.telemetry: true` in `GET /capabilities` and one extra link in the
library page's header).

## 1. `POST /telemetry` (API Worker)

Auth: `Authorization: Api-Key <key>`, the same per-owner client keys as every other keyed route
(the gate's `lookupThen` plus the D1 `lookupKey`; `last_used_at` is updated like any other call).
Answered by the Worker from D1 and R2 only: **the container and the Durable Object are never
involved**, so a flood of telemetry cannot wake or bill the container. No CORS (the app sends no
`Origin`); `OPTIONS`, any other method, any other path under it (`/telemetry/`, `/telemetry/x`) and the
web Worker's library service credential are all a plain `404`. The body never reaches `request_log`.

Request body, JSON (`content-encoding: gzip` is accepted, `identity` or none otherwise):

```json
{"app":{"version":"1.3","build":"4","platform":"ios|macos","os":"26.5","device":"iPhone18,1","process":"app|share|widgets"},
 "install":"<uuid, stable per install>",
 "events":[{"ts":1800000000000,"level":"debug|info|warn|error",
            "cat":"app|pipeline|upload|share|photos|sync|net|store|ui|live",
            "msg":"<=300 chars","data":{"flat":"string/number/bool map, <=20 keys"}}],
 "crashes":[{"ts":1800000000000,"kind":"crash|hang|cpu|disk|launch|unclean_exit",
             "summary":"<=300 chars","payload":{"MetricKit diagnostic JSON":"object, or null"},
             "events":[{"same event shape: the last events before it"}]}]}
```

Limits and answers, checked in this order:

| check | answer |
|---|---|
| key missing / malformed / unknown / revoked | `401` `error.api.auth.key.*` (cobalt's own codes), D1 down `503 error.api.generic` |
| more than 60 batches per minute for this key | `429 error.telemetry.rate_limited` + `retry-after` (seconds) |
| body over 256 KB (declared `content-length`, or counted while streaming; for gzip BOTH the wire size and the inflated size) | `413 error.telemetry.too_large` |
| unsupported `content-encoding`, bad gzip, not UTF-8, not JSON, wrong shape, more than 500 events, more than 10 crashes, more than 500 events inside one crash | `400 error.telemetry.invalid` |
| D1 or R2 write failed | `503 error.telemetry.unavailable` (retry; nothing from the batch is acknowledged) |
| accepted | `202 {"status":"success","accepted":{"events":n,"crashes":m}}` |

Errors are always `{"status":"error","error":{"code":"..."}}`; every answer carries `cache-control: no-store`.

What counts as "wrong shape" (strict, because the filters depend on them): `app` must be an object with
non-empty string `version` and `build` (a number `build` is accepted and stored as text), `platform` in
`ios|macos`, `process` in `app|share|widgets` (`os` and `device` are optional strings); `install` must be a
UUID (stored lowercase); every event needs a finite `ts` (>= 0, ms), a `level` and `cat` from the lists above and a
string `msg`; every crash a finite `ts`, a `kind` from the list, a string `summary`, and a `payload` that is an
object or null/absent. `events` and `crashes` may be absent (empty). An empty batch is `202` with `0` and `0`.

Leniency, deliberately: things a client can get slightly wrong never cost a whole batch. `msg`, `summary` and string
values in `data` over 300 characters are **truncated, not rejected**; `data` keeps at most 20 keys (first 20), drops
values that are not string/number/bool (nested objects, arrays, null, non-finite numbers) and keys over 64
characters are cut; `data` that is not an object at all is a `400`.

Scrubbing: an `Api-Key <token>` or `Bearer <token>` that slips into a `msg`, `summary` or a `data` string is
replaced with `Api-Key [redacted]` / `Bearer [redacted]` before anything is stored. The MetricKit `payload` is stored as
sent.

Idempotency: ids are deterministic (SHA-256 of install, ts, level, cat, msg, data for an event; install, ts, kind,
summary for a crash), inserts are `INSERT OR IGNORE`, and the crash object name is derived from the id. A batch the
client retries after a lost response therefore does not duplicate anything. (Two identical events from one install
in the same millisecond collapse into one row.) The response's `accepted` counts what the batch contained, not what
was newly inserted.

Rate limit, exactly what it is: a fixed one-minute window per key id held **in the Worker isolate's memory**, not in
D1. It is a brake on a runaway client, not an exact quota: a second isolate has its own counters, so the real ceiling
per key is 60 per minute per isolate (one owner, one app: effectively 60). Unauthenticated requests never reach it
(the key lookup comes first), invalid and oversized batches do count. D1 was not used because the point is to cost no
extra write.

## 2. Storage

D1 migration `d1/migrations/0005_telemetry.sql` (additive: two tables, six indexes). Timestamps are ms.

- `telemetry_events(id PK, key_id, install, ts, level, cat, msg, data, version, build, platform, device, process,
  received_at)`; `data` is the flat map as a JSON string or NULL. Indexes: `(ts DESC, id DESC)`, `(received_at)`,
  `(level, ts DESC)`.
- `telemetry_crashes(id PK, key_id, install, ts, kind, summary, r2_key, version, build, platform, device, process,
  received_at)`. Indexes: `(ts DESC, id DESC)`, `(received_at)`, `(kind, ts DESC)`.
- `key_id` is `api_keys.id` of the key that sent the batch (never the key). `ts` is the device's clock;
  `received_at` the Worker's, and retention runs on `received_at` so a skewed device clock cannot keep rows forever.
- A crash's payload and the events leading up to it go to the existing PRIVATE R2 bucket `cobalt-originals` at
  `telemetry/crashes/<yyyy-mm-dd>/<id>.json` (UTC day of the crash's `ts`; no new bucket), as
  `{id, install, ts, kind, summary, app, received_at, payload, events}`. The object is written BEFORE its row, so a row
  never names a missing object. A crash's own `events` are kept only in that object; they are not copied into the
  event stream (the app sends them in `events` too if it wants them there).
- Writes use `db.batch()` with 7-row multi-row inserts (14 bound parameters each; D1 allows 100), at most 50
  statements per batch call.

## 3. Retention: 30 days

No scheduled path existed (the Durable Object's sweep only runs while a job is pending), so **a daily cron trigger was
added** in `api/cloudflare.config.ts`: `triggers: [triggers.scheduled({ schedule: "23 3 * * *" })]` (03:23 UTC), and
the Worker's `scheduled` handler (`api/src/index.ts`) calls `runTelemetryRetention` (`api/src/telemetry.ts`). It touches D1
and R2 only. Per run: crashes with `received_at` older than 30 days are processed 50 at a time (up to 2000): the R2
object is deleted first and the row only after the object is gone, so a failed R2 delete leaves the row for tomorrow's
run (and the loop stops rather than spin if nothing could be deleted); then events older than 30 days are deleted
1000 at a time (up to 50000). The result is logged (`[telemetry] retention {"events":n,"crashes":m,"failed":k}`).
Anything beyond the per-run bound is picked up by the next run.

Accepted gap: if an R2 `put` succeeds but the D1 insert then fails (the batch answers 503 and the client retries with
the same deterministic id, which overwrites the same object), only a client that never retries leaves an object with no
row, and nothing sweeps those. No R2 lifecycle rule exists on `cobalt-originals`.

## 4. Capability

`GET /capabilities` -> `features.telemetry: true`. The app should upload only when it is true (an older deployment
without it answers `404` to `POST /telemetry`).

## 5. Read side: web Worker (behind Cloudflare Access)

All routes verify the `Cf-Access-Jwt-Assertion` JWT exactly like `/api/keys` and `/api/library` (RS256 against the
team's JWKS, `aud`, `iss`, `exp`/`nbf` with 60 s skew, `email` = `OWNER_EMAIL`); anything else is
`401 {"status":"error","error":{"code":"unauthorized"}}` before D1 or R2 is touched. Read-only, so no `Origin` check.
They read the same D1 database (`DB`) the API Worker writes and the private bucket (`ORIGINALS`; **the binding already
existed** in `web/cloudflare.config.ts`, nothing was added). `runWorkerFirst` gained `/logs`, `/api/logs`, `/api/logs/*`.
Everything is `cache-control: no-store`. Wrong method `405 error.logs.method` (+ `allow`), unknown path `404
error.logs.not_found`, bad query `400 error.logs.bad_request`, D1/R2 failure `500 error.logs.server`.

- `GET /api/logs?level=&cat=&before=&limit=` -> `{"status":"success","events":[{id, install, ts, level, cat, msg, data
  (object or null), version, build, platform, device, process, received_at}],"next_before":"<ts>_<id>"|null}`, newest
  first (`ts DESC, id DESC`). `level` and `cat` take one value or a comma list (`level=warn,error`); unknown values are a
  400. `limit` 1..200 (default 100). `before` is the previous page's `next_before` (`<ts>_<id>`, so rows that share a
  millisecond are neither skipped nor repeated), or a bare ms timestamp for "strictly older than".
- `GET /api/logs/crashes?kind=&before=&limit=` -> `{"status":"success","crashes":[{id, install, ts, kind, summary,
  version, build, platform, device, process, received_at}],"next_before":...}`, same ordering and cursor; `kind` takes a
  comma list; `limit` 1..100 (default 50).
- `GET /api/logs/crashes/<id>` -> `{"status":"success","crash":{...the list fields, "app": {...}|null, "payload":
  {...}|null, "events":[...], "payload_missing": bool}}`. `payload_missing` is true when the row exists but its R2
  object is gone, unreadable or over 1 MB (the summary is still returned). The object key comes from the D1 row, never
  from the URL; ids not matching `[0-9A-Za-z_-]{8,64}` are a 404 before any lookup. Unknown id `404`.
- Never returned: API keys, `key_id`, `r2_key`.
- `GET /logs` (and `HEAD`) -> the page below, with the CSP `default-src 'self'; base-uri 'none'; connect-src 'self';
  img-src 'self' data:; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com;
  script-src 'self' 'unsafe-inline'; frame-ancestors 'none'`.

### The `/logs` page

Self-contained HTML embedded in the Worker (`web/src/logs/page.html` -> `page.generated.ts` via `npm run logs:build`;
a test fails when the embed is stale), same visual language as `/library` (cobalt's tokens, IBM Plex Mono, lowercase,
light and dark by `prefers-color-scheme`, safe-area insets, 44 px touch targets, works at phone width).

- Crashes on top: kind badge, summary, age, `build 1.3 (4)`, platform, device, process. Tap one: detail replaces the
  list (`#crash=<id>` in the address bar, so a reload or a shared link reopens it) with the metadata, the MetricKit
  diagnostic metadata (`signal`, `terminationReason`, `hangDuration`, ...), every **call stack tree found anywhere in
  the payload** (a whole `MXDiagnosticPayload`, one diagnostic, or just the tree) rendered as numbered frames
  `#n binaryName +offset 0xaddress` (the attributed thread is open and marked "crashed here"; a plain call chain stays
  at one indent, a sampled hang tree indents per branch; the binary UUID is on each frame's tooltip), a "copy frames"
  button (`n  binary  0xaddress  +offset  uuid`, kept for later symbolication), the raw payload JSON with "copy json",
  and "last events before it" oldest-first with offsets relative to the crash (`-1.0 s`) ending in a crash marker.
- Below, the event stream: level and category chips (multi-select, none selected = all), newest first, day separators,
  "load older" (100 per page), tap a row for its `data` and build/device. Every string from the app is written with
  `textContent` (a test asserts the script contains no `innerHTML`-style sink and executes the page's script against
  a DOM stub backed by the real handler).
- The library page's header gained a "logs" link and the logs page links back to "library" and cobalt. The sidebar
  (upstream Svelte) is NOT touched: CLAUDE.md allows only the library tab there.
