# cobalt for apple: API contract (pinned 2026-10-02)

The backend half of the native app (`apple/CONTRACT.md` is the app half). Lane API builds
this; Lane CORE codes the Swift client against it at the same time. Do not deviate; if
something here is impossible, stop and report instead of improvising.

Design source: `apple/mockup/` (the approved boards, published artifact
https://claude.ai/artifact/XaMAQRWSyFnBGRpXwywuvF, version 8). `canvas.json` notes "api"
and "caveats" list what the boards assume from the server; this file turns that into shapes.

## Ground rules

- **Nothing under `api/`, `web/`, `packages/` or the root `Dockerfile` changes.** Every change
  lives in `deploy/cloudflare/**` (Worker, Durable Object, helper, tests, README). Upstream
  cobalt's `POST /`, `GET /tunnel` and their responses are untouched.
- **Additive only.** Every existing route keeps its request and response exactly; new fields
  are added, none renamed or removed. `STUDIO-CONTRACT.md` and `LIBRARY-CONTRACT.md` stay
  true (the web studio page and library page keep working unchanged).
- **Field names are snake_case**, like the existing API (`created_at`, `expires_at`). Times
  are ms since epoch. Errors are always `{"status":"error","error":{"code":"<code>"}}`.
- **No D1 migration.** Everything fits the existing tables (`0001`-`0004`). If you find you
  need one, stop and report: the owner applies migrations by hand.
- **The native app sends no `Origin`.** New routes need no CORS. Routes under `/studio*` keep
  getting the studio CORS header from `handleRequest` (harmless).
- **Auth** is `Authorization: Api-Key <lowercase uuid>` checked with the existing D1 lookup
  (`gate.ts` `lookupThen` + `keys.ts` `lookupKey`), or the library service header, exactly as
  today. "keyed" below means that.
- Gates: `npm test && npm run typecheck` green in `deploy/cloudflare/api` AND
  `deploy/cloudflare/web` after every change (web has no code changes here, but it shares the
  migrations and test support).

## Summary of changes

| # | route / behaviour | auth | where |
|---|---|---|---|
| 1 | `GET /capabilities` (new) | none; optional key check | gate + Worker (`src/app-routes.ts`, new) |
| 2 | `GET /studio/<sid>` gains `step`, `step_bytes`, `step_total`, `waking` | none (unchanged) | `studio.ts`, `index.ts`, `helper/server.js`, `helper/lib.js` |
| 3 | `PUT /studio/upload?name=` (new) | keyed | gate + Worker (`app-routes.ts`) + DO internal adopt path |
| 4 | `GET /studio/<sid>/render/<job>` (and `GET /webp/<id>`) pending gains `phase`, `frames_done`, `frames_total` | unchanged | `webp.ts`, `studio.ts`, `helper/server.js`, `helper/lib.js` |
| 5 | `GET /library` (new), `GET /library/items/<id>/file`, `POST /library/items/<id>/publish`, `POST /library/items/<id>/studio` (new) | keyed | gate + Worker (`app-routes.ts`) |
| 6 | jobs and saves finish with nobody polling (job sweep) | n/a | `index.ts` (`schedule`), `studio.ts` / `webp.ts` (`sweep`) |
| 7 | `GET /studio/<sid>/source`: no change, confirmed | none | `studio-edge.ts` |

New Worker-side code goes in `deploy/cloudflare/api/src/app-routes.ts` (no Cloudflare
imports, like `studio-edge.ts` and `publish.ts`, so it runs under plain node in the tests).
The gate gains decisions for the new routes; `worker.ts` dispatches them **right after the key
lookup, next to `studio_publish`** (before `normalizeUrlField` / `describeBody`, which must
never read an upload body).

---

## 1. Capability discovery: `GET /capabilities`

The app calls this first, on launch and whenever the server URL or key changes.

Request: `GET /capabilities`, optional `Authorization: Api-Key <key>`. Never wakes the
container (D1 at most). `cache-control: no-store`.

Response `200`:

```json
{
  "status": "success",
  "server": "cobalt-cloudflare",
  "cobalt": { "version": "11.7.1" },
  "features": {
    "studio": true,
    "upload": true,
    "library": true,
    "save_progress": true,
    "render_progress": true,
    "finishes_unpolled": true
  },
  "limits": {
    "max_webp_seconds": 10,
    "min_webp_seconds": 0.5,
    "webp_widths": [320, 480],
    "webp_qualities": ["low", "med", "high"],
    "render_fps": 15,
    "max_upload_bytes": 100000000,
    "max_source_bytes": 209715200,
    "session_ttl_ms": 604800000
  },
  "media_base_url": "https://media.capybaraharmony.com/",
  "key": "valid",
  "key_name": "iphone"
}
```

- Later additions to `features` (a missing key = `false`): `live_activity_push` (section 8.5),
  `notify_bridge` (section 9.1), `crop` (section 10; `true` on any server that has it).
- `server` is the fork marker. The app treats any 200 JSON with `server == "cobalt-cloudflare"`
  as this fork and reads `features` / `limits` from it (missing feature keys = `false`, missing
  limits = the values above).
- `cobalt.version` is the upstream version read at bundle time from the repo's
  `api/package.json` (a JSON import from the fork's Worker; reading an upstream file is fine,
  editing it is not). If the bundler cannot reach it, send `"cobalt": null`; the app then
  shows "cobalt + studio, library" without a number.
- `key`: `"missing"` (no header), `"invalid"` (malformed, unknown or revoked; for a
  well-formed key this is the existing `lookupKey`, which also stamps `last_used_at`),
  `"valid"`, or `"unknown"` (D1 failed). Never a 401: the app needs the answer to render
  Settings ("this key was revoked"). `key_name` is `api_keys.name` for a valid key, else
  `null` (one extra `SELECT name FROM api_keys WHERE id = ?1`; the service header gives
  `"key_name": "service"`).
- `limits` constants come from the code that enforces them (`MAX_RENDER_SECONDS`,
  `MIN_RENDER_SECONDS`, `RENDER_WIDTHS`, `RENDER_FPS`, `MAX_SOURCE_BYTES`, `SESSION_TTL_MS`
  in `studio.ts`, the new `MAX_UPLOAD_BYTES = 100_000_000` in `app-routes.ts`). Import them,
  do not retype them.

### How the app recognises the other kinds of server (Lane CORE implements, pinned here)

1. `GET {base}/capabilities` **without following redirects**.
   - 200 JSON with `server == "cobalt-cloudflare"` → **this fork**.
   - Plain upstream cobalt answers `GET /*` with a **302 to `/`** (`api/src/core/api.js:328`,
     `app.get('/*', ... res.redirect('/'))`); the current fork (before this lane deploys)
     answers **404 with no body** (gate default). Both → step 2.
2. `GET {base}/` with `Accept: application/json`.
   - 200 JSON with `cobalt.version` (string) → **plain cobalt**: no studio, upload, library
     or progress; the paste circle saves through `POST /` only.
   - 404 (this fork hides `GET /` from anyone but the web origin, `gate.ts:176`) → step 3.
3. `GET {base}/studio/0000000000000000000000` (22 chars, no key).
   - 404 JSON `error.studio.not_found` → **legacy fork** (studio routes exist, nothing from
     this contract yet): `studio = true`, everything else `false`. D1 read only.
   - anything else → **not cobalt**.
   Network failure at step 1 → **unreachable** (the app keeps its last known capabilities).

---

## 2. Save progress on `GET /studio/<sid>`

Four fields are added to the session body (`sessionBody`, `studio.ts:136`), always present,
on every route that returns a session (`GET /studio/<sid>`, the DO's advance reply, the
Worker's D1 answers and its fallback):

| field | type | meaning |
|---|---|---|
| `step` | `"fetching" \| "reading" \| "storing" \| null` | what the save is doing now; `null` unless `status == "saving"` and the DO knows |
| `step_bytes` | number \| null | bytes so far in this step (`fetching`: downloaded by the helper; `storing`: copied into R2); `null` when unknown |
| `step_total` | number \| null | total bytes when known (`storing`: always the helper's file size; `fetching`: the download's `content-length` when it sent one) |
| `waking` | boolean | `true` while this save is waiting for the container to start; else `false` |

The existing `bytes` field keeps its meaning (the stored size, `null` while saving). That is
why progress uses new names instead of reusing it.

Order for a link save: `fetching` → `reading` (helper's ffmpeg probe, about a second) →
`storing` → `status: "ready"`. For an adopted upload (route 3): `reading` → `ready`.

### Where the DO knows each value (read against the branch on 2026-10-02)

Progress lives in memory on `StudioService` (`private progress = new Map<string, SaveProgress>()`,
`SaveProgress = { step, bytes: number|null, total: number|null, waking: boolean }`). It is not
persisted: after a DO eviction the next step repopulates it, and until then the fields are
`null` / `false` (the app degrades, see `apple/CONTRACT.md`). Cleared in `fail()` and at the
end of `finalize()` / `probeStep()`.

- **`fetching`**, `waking`: `step()` (`studio.ts:597`) dispatches on `SaveRecord.phase`.
  Phase `starting` → `startFetch()` (`studio.ts:654`) calls `d.ensureRunning()` first: set
  `{step: "fetching", waking: !d.isRunning()}` before that call, `waking: false` after it
  returns. Add `isRunning?: () => boolean` to `StudioDeps` (`index.ts`:
  `() => this.ctx.container?.running ?? false`). Phase `fetching` → `pollFetch()`
  (`studio.ts:703`) reads helper `GET /fetch/<sid>`; today a pending answer is just
  `{status:"pending"}` (`helper/server.js:566`). The helper adds
  `{status:"pending", stage:"downloading"|"probing", bytes, total}`:
  - `helper/lib.js:553` `downloadToFile` takes an optional `onProgress(bytes, total|null)`,
    called from its counting `Transform` (`lib.js:576`, throttled to once per 256 KB or
    250 ms); `total` is the response `content-length` when present.
  - `helper/server.js:296` `runFetch` stores it on the job (`job.progress = {stage, bytes, total}`),
    and sets `stage: "probing"` right before `probe(input)` (`server.js:322`).
  - `pollFetch` maps `downloading` → `{step: "fetching", bytes, total}` and `probing` →
    `{step: "reading", bytes: <last downloaded>, total: null}`. An old helper without the
    fields keeps `{step: "fetching", bytes: null}`.
- **`reading`** for uploads: phase `probing` → `probeStep()` (`studio.ts:894`): set
  `{step: "reading"}` on entry.
- **`storing`**: `finalize()` (`studio.ts:736`), between `callHelper("/fetch/<sid>/file")`
  and `originals.put()` resolving. Set `{step: "storing", bytes: 0, total: bytes}`, and count
  chunks through the copy: `StudioDeps.fixedLength` becomes
  `(stream, length, onChunk?: (n: number) => void) => ReadableStream`, and the existing
  reader/writer loop in `index.ts:117-142` calls `onChunk(value.byteLength)` per chunk (still
  no `pipeTo`). The fake in `test/studio-fakes.ts:136` gets the same parameter.
- The reply: `advance()` (`studio.ts:563`) answers through `sessionReply(row)`
  (`studio.ts:550`); pass `this.progress.get(sid)` into `sessionBody` when
  `row.status === "saving"`. The Worker's own answers (`studio-edge.ts:108,115`) pass nothing
  (nulls, `waking: false`).

Polling: the app polls `GET /studio/<sid>?wait=1` about once a second while saving, so the
fields update at that rate. `wait` semantics are unchanged (0..25).

---

## 3. Upload into the same pipeline: `PUT /studio/upload?name=<filename>`

Today only the web login can upload (`/api/library/upload` on the web Worker). This is the
same thing with an API key, and it continues straight into a studio session through the
existing adopt path, so an upload and a pasted link end up in the same `saving → ready`
session.

Request:

```
PUT /studio/upload?name=<url-encoded file name>
Authorization: Api-Key <key>
Content-Type: <one of the types below>
Content-Length: <bytes>          (required; <= 100000000)
<raw file bytes>
```

Allowed types and stored extension (same table as `web/src/library.ts:45` `UPLOAD_TYPES`; copy
it, do not import across Workers): `image/gif` gif, `image/webp` webp, `image/png` png,
`image/jpeg` jpg, `video/mp4` mp4, `video/quicktime` mov, `image/heic` heic.

Gate: `decideStudio` (`gate.ts:195`) checks `pathname === "/studio/upload"` **before** the
session-id regex (today "upload" fails the 22-char sid check and is a 404): `PUT` →
`lookupThen(req, "studio_upload")`, any other method → 404.

Handling (Worker, after the key lookup; never forwarded raw to the DO or container):

1. Validate type (415), `content-length` present and numeric (411), `<= 100_000_000` (413),
   non-zero with a body (400). Reject before reading the body; cancel it.
2. `id` = 16 base62 (`mintItemId`), key `uploads/<id>.<ext>`, name cleaned exactly like the
   web's `cleanName` (`web/src/library.ts:440`). `ORIGINALS.put(key, request.body, {httpMetadata:
   {contentType}})` straight from the request (known length, nothing buffered). Size mismatch →
   delete the object, 400 `error.library.incomplete`.
3. Insert the `media_items` row: `kind 'private'`, `source 'upload'`, `bucket 'originals'`,
   `key_id` = the caller's key id (the web lane leaves it null; here it is known).
4. If the type is `video/*` or `image/gif`: call the DO on an **internal** path
   `POST /studio/upload/adopt` with `x-cobalt-key-id: <caller key id>` and the JSON body
   `{r2_key, name, content_type, bytes, item_id}`; the DO answers with
   `StudioService.adopt(keyId, body)` (`studio.ts:829`, unchanged logic) from a new branch in
   `handleStudioRoute` (`studio.ts:1169`) that requires the key id header. The gate answers 404
   for `/studio/upload/adopt` from outside (only `PUT /studio/upload` is public), and
   `headers.ts` strips `x-cobalt-key-id` from every client request. `/library/adopt` stays
   service-only.
5. Request log: one `request_log` row with route `PUT /studio/upload`; **never read the body
   for it** (`describeBody` must not run): `body_bytes` = content-length, `body_keys` `""`,
   `url_type` `"upload"`.

Response `201`:

```json
{
  "status": "success",
  "id": "<sid>",
  "url": "https://cobalt.capybaraharmony.com/studio/<sid>",
  "item": { "id": "...", "kind": "private", "source": "upload", "name": "IMG_0412.mov",
            "url": null, "content_type": "video/quicktime", "bytes": 18234112, "width": null,
            "height": null, "duration": null, "link": null, "session_id": null,
            "created_at": 1790000000000 },
  "studio_error": null
}
```

- `id` / `url` are exactly what `POST /studio` returns (`{status, id, url}`), so the app polls
  `GET /studio/<id>` the same way. `item` is the web's `itemShape` (`web/src/library.ts:84`).
- Images (`png`, `jpeg`, `webp`, `heic`): `id: null`, `url: null`, `studio_error: null`. The
  app offers "host as-is" (route 5c).
- A video whose adopt was refused (429 `error.studio.busy`, 400 `error.studio.not_video`, 413):
  still **201** (the file IS stored), `id: null`, `studio_error: {"code": ...}`. The app retries
  with `POST /library/items/<item.id>/studio` (route 5d).

Errors (nothing stored): 401 auth codes as today, 411 `error.library.length_required`, 413
`error.library.too_large`, 415 `error.library.unsupported`, 400 `error.library.empty` /
`error.library.incomplete`, 502 `error.library.storage` (R2 put threw), 503 `error.api.generic`
(D1).

Limit note: 100 MB is Cloudflare's request body limit on this plan, not a choice. The app
refuses bigger files before uploading ("that file is over the 100 MB limit.").

---

## 4. Render progress

`GET /studio/<sid>/render/<job>` pending today: `{"status":"pending","job"}`. It becomes:

```json
{ "status": "pending", "job": "<job>", "phase": "decode", "frames_done": 42, "frames_total": 150 }
```

| field | values |
|---|---|
| `phase` | `"fetching"` (only `/webp` jobs: cobalt + download), `"decode"` (ffmpeg writing PNG frames; includes the ~1 s probe), `"pack"` (img2webp; no count exists), or `null` (unknown: old helper, or the DO lost its in-memory copy) |
| `frames_done` | integer \| null. `decode`: PNG frames on disk; `pack`: equals `frames_total` |
| `frames_total` | integer \| null. `decode`: `max(1, round(clip_seconds * fps))` from `planClip`; corrected to the real count when decode ends |

`GET /webp/<id>` pending gets the same three fields (`{"status":"pending","id",...}`); free,
since it is the same `WebpService.status`.

How the helper counts (honest by construction):

- `helper/lib.js:380` `encodeAnimatedWebp` takes `onPhase?(phase, info)`: call
  `onPhase("decode", {total})` before the ffmpeg `runProcess`, and
  `onPhase("pack", {frames: frames.length})` after the frames are listed (`lib.js:397`),
  before img2webp.
- `helper/server.js:203` `encodeJob` keeps `job.progress = {phase, total, framesDir}`.
  `GET /jobs/:id` (`server.js:635`) for a pending job answers
  `{status:"pending", phase, frames_done, frames_total}` where, during `decode`,
  `frames_done = max(0, count(readdir(framesDir) matching FRAME_RE) - 1)` (the newest file may
  still be being written), capped at `frames_total`. 10 s x 15 fps is 150 directory entries:
  cheap. During `pack`, `frames_done = frames_total = frames.length`. `runJob` (link jobs)
  reports `phase: "fetching"` until the download ends.
- `WebpService.pollOnce` (`webp.ts:367`) currently returns `null` on pending and drops the
  body; keep the last pending body per id in memory (`private progress = new Map()`), and
  `status()` (`webp.ts:345`) puts it into the pending reply. `StudioService.renderStatus`
  (`studio.ts:1131`) passes the three fields through into its own pending reply.

Polling: the app polls with `?wait=1` (one helper poll, then the deadline answers with the
latest progress); completion still returns at once.

---

## 5. Library with an API key

The web library (`/api/library` on the web origin) needs the Access login; the app needs the
same data with its key, grouped into posts the way the mockup shows ("15 posts · 24 files").
All four routes are answered by the Worker from D1 and R2; the container is never woken.
Item ids are 16 base62 (`mintItemId`; the web's `base62(16)` and the backfill's `newId` are
16 too): the gate checks `^[A-Za-z0-9]{16}$`, anything else is a 404. The gate keeps
`/library/adopt` (service only) first, then `GET /library`, then `/library/items/<id>/<sub>`.

### 5a. `GET /library?limit=<1..50>&cursor=<opaque>` (keyed)

Default `limit` 20. Posts newest first. `media_items` columns (migration 0004): `id, kind,
source, bucket, r2_key, url, name, content_type, bytes, width, height, duration, link,
session_id, key_id, created_at, deleted_at`. Only rows with `deleted_at IS NULL`.

**Post key** (one card per post): the owner's rule `COALESCE(session_id, link, id)`, with one
refinement so an upload and the webps made from it land in one card (a render of an adopted
upload has `session_id` = the adopted session, whose `link` is `upload:<item id>`; when a
**saved** original is reopened via 5d its new session's link is `upload:<that row's session_id>`
instead, so its renders stay in the original post's card — review fix, 2026-10-02):

```sql
COALESCE(
  (SELECT substr(s.link, 8) FROM studio_sessions s
     WHERE s.id = m.session_id AND s.link LIKE 'upload:%'),
  m.session_id, m.link, m.id) AS post_key
```

Post order and cursor: by `MAX(created_at)` of the post's files, then `post_key` descending.
`cursor` is opaque to the app (base64url of `"<ms>.<post_key>"` is fine); `next` is `null` on
the last page. Two queries: the page of post keys (`GROUP BY post_key ... HAVING (max, key) <
cursor ... LIMIT limit+1`), then all live files of those keys. Bad `limit` or `cursor` → 400
`error.library.bad_request`.

Response `200`:

```json
{
  "status": "success",
  "posts": [
    {
      "id": "<post_key>",
      "service": "instagram",
      "link": "https://www.instagram.com/reel/Dd7P496wolG/",
      "title": "instagram_Dd7P496wolG",
      "duration": 14.77, "width": 720, "height": 1280,
      "created_at": 1790000000000,
      "session": { "id": "<sid>", "status": "ready", "expires_at": 1790600000000,
                   "source_url": "https://api.capybaraharmony.com/studio/<sid>/source" },
      "files": [
        { "id": "<item id>", "kind": "public", "source": "studio",
          "name": "instagram_Dd7P496wolG.webp",
          "url": "https://media.capybaraharmony.com/AbCdEfGhIj.webp",
          "content_type": "image/webp", "bytes": 4500000, "width": 480, "height": 854,
          "duration": 10.1, "created_at": 1790000000000,
          "media_name": "AbCdEfGhIj.webp", "deletable": true },
        { "id": "<item id>", "kind": "private", "source": "saved",
          "name": "instagram_Dd7P496wolG", "url": null,
          "content_type": "video/mp4", "bytes": 4331778, "width": 720, "height": 1280,
          "duration": 14.77, "created_at": 1789999990000,
          "media_name": null, "deletable": false }
      ]
    }
  ],
  "counts": { "posts": 15, "files": 24 },
  "usage": { "public_bytes": 0, "private_bytes": 0 },
  "next": "<cursor>"
}
```

- `service`: from the post's newest session (`studio_sessions.service`; `"upload"` for
  uploads) else `serviceFromUrl(link)` (`webp.ts:141`), else `null`.
- `title`, `duration`, `width`, `height`: from the post's private original (`saved` or
  `upload` row) when there is one, else from its newest video-ish file, else `null`.
- `session`: the post's newest session with `expires_at > now` and `status IN
  ('saving','ready')`, else `null`. `source_url` is the API's own `/studio/<sid>/source`
  (built from `API_URL`).
- `files`: newest first. `media_name` = `r2_key` for `bucket = 'media'`, else `null`.
  `deletable` = `bucket = 'media'` AND `r2_key` matches `MEDIA_NAME_REGEX`
  (`^[A-Za-z0-9]{10}\.webp$`, `gate.ts:75`), i.e. exactly what `DELETE /media/<name>` accepts.
  Hosted `.mp4` files and private copies are `false` (the app says "delete on web").
- `counts`: totals over the whole library (two `COUNT`s), not the page.
- `usage`: same query as the web's (`web/src/library.ts:321`).

Known gap (accepted, no migration): an **image** hosted from an upload (route 5c) gets its own
`host` row with no session and no link, so it shows as a second post next to its private
upload. Videos do not have this gap (their host rows carry `session_id`).

### 5b. `GET|HEAD /library/items/<id>/file` (keyed)

A private file's bytes (for "save" on a private copy when the device has no local copy, e.g. a
new Mac; `/studio/<sid>/source` stops at the session's 7-day expiry, this one does not). Only
`bucket = 'originals'` rows; a public row → 409 `error.library.public` (use its `url`). Same
Range handling as `studioSource` (`studio-edge.ts:121`, reuse `parseRange`):
`accept-ranges: bytes`, `206` + `content-range` for a single range, `416
error.studio.bad_range`, `cache-control: private, max-age=3600`, `content-type` from the row.
Unknown or deleted → 404 `error.library.not_found`; missing object → 404 `error.library.missing`.

### 5c. `POST /library/items/<id>/publish` (keyed)

Hosts a private file publicly (the app's "host as-is" for an uploaded image, and "host it" on
any private copy). Port of the web's `itemPublish` (`web/src/library.ts:532`), including its
chunk-loop `copyToMedia` (`library.ts:499`, `FixedLengthStream` injected for tests, no
`pipeTo`). The new `host` row copies `session_id`, `link`, `width`, `height`, `duration` from
the source row and sets `key_id` to the caller.

`201 {"status":"success","url","bytes","content_type","item_id"}` (the same shape as
`POST /studio/<sid>/publish`). Errors: 404 `error.library.not_found`, 409
`error.library.already_public`, 404 `error.library.missing`, 502 `error.library.storage`.

### 5d. `POST /library/items/<id>/studio` (keyed)

Opens a studio session for a private video/gif (the library's "trim a new webp" after the
original's session expired, and the retry for an upload whose adopt was busy). Port of the
web's `itemStudio` (`web/src/library.ts:567`): reopen the row's own session if it is `ready`
and unexpired with the same `r2_key` (200), else adopt through the DO's internal
`POST /studio/upload/adopt` (route 3, step 4) (201).

`{"status":"success","id":"<sid>","url":"<web studio url>"}`. Errors: 404
`error.library.not_found`, 409 `error.library.not_private`, 400 `error.studio.not_video`,
429 `error.studio.busy`, plus the adopt errors.

### Delete

Unchanged: `DELETE /media/<name>.webp` (keyed) for files with `deletable: true`. Nothing new
deletes private copies or hosted `.mp4` files with a key; that stays on the web (Access login).

---

## 6. Jobs finish without polls

**Problem** (README "Limits and caveats", canvas caveat): a render's result is collected into
R2 only when someone polls, and the container sleeps 45 s after its last activity
(`index.ts:31`, `sleepAfter = "45s"`). An app backgrounded mid-render for ~45 s, or a share
sheet closed mid-render, loses the webp (`error.webp.job_lost`). A save stops moving without
polls too (`SAVING_STUCK_MS` 10 min, then `error.studio.save_lost`).

**Fix (chosen): a DO-side sweep driven by the Containers library's own scheduler.**

- `@cloudflare/containers` 0.3.7 owns `alarm()` and says to use `schedule()` instead
  (`node_modules/@cloudflare/containers/dist/lib/container.d.ts:252`: "We strongly recommend
  using this instead of the `alarm` handler"); its alarm loop runs due schedules while the
  container is idle (`container.js:1502-1590`, read 2026-10-02).
- When a render job is accepted (`WebpService.create`, `createFromUpload`), a save is created
  (`StudioService.create`) or an adopt is created, the service calls a new optional dep
  `scheduleSweep?: () => void` (on `WebpDeps` and `StudioDeps`). `index.ts` implements it as
  `this.schedule(5, "sweepJobs")`, de-duplicated with a DO storage key `sweep:at` (skip when a
  sweep is already due within 10 s).
- `CobaltContainer.sweepJobs()` (public method; the name is the schedule's callback) calls
  `this.studio.sweep()` and, if it reports anything still pending, schedules itself again in
  5 s. `sweep()` lives in `studio.ts` (pure, testable with the fakes) and does one
  non-waiting pass:
  1. every `job:<id>` record in DO storage without a `result:<id>`, created within
     `SWEEP_RENDER_MS` (6 min: the helper's 240 s budget plus upload time): owner
     `studio:<sid>` → `this.renderStatus(sid, id, 0)` (records D1 `studio_renders`, the
     `media_items` `studio` row and the R2 upload exactly as a client poll would); any other
     owner → `this.d.webp.status(owner, id, 0)` (records the `webp` row);
  2. every `save:<sid>` record not currently locked, last advanced within `SAVE_BUDGET_MS`
     plus 60 s → `this.advance(sid, 0)` (one step);
  3. returns `{ pending: number }`.
- Each pass makes helper calls through `containerFetch`, which renews the activity timer, so
  the container stays awake **exactly while something is pending**, capped by the budgets
  above. When nothing is pending the 45 s sleep applies as today (the owner cut it for cost).

Why not the alternatives: raising `sleepAfter` costs memory-seconds for every request and
still never collects a finished result; overriding `alarm()` fights the library ("container
DOs ALWAYS need an alarm right now", `container.js:1513`); `onActivityExpired()` only fires
once per 45 s idle window, so results would land up to 45 s late; `ctx.waitUntil` work does not
survive the response (measured 2026-09-30, README "How a save works").

Result for the app: a render nobody polls is in R2 and D1 within ~5 s of finishing; the next
`GET .../render/<job>` (or `GET /library`) returns it. `error.webp.job_lost` remains possible
only for a container crash or a job past its budget.

Unverified until deployed (say so in the README): that `schedule()` callbacks fire on the
deployed runtime while no request is in flight. The tests prove the sweep logic with fakes and
that `scheduleSweep` is called; a live check is a render started, the client gone, and
`studio_renders.status = 'success'` a minute later.

---

## 7. `GET /studio/<sid>/source` (confirmed, unchanged)

`studio-edge.ts:121-182`: `GET` and `HEAD`, no key, served by the Worker from R2 (container
never woken). Single `bytes=` ranges → `206` with `content-range`; `bytes=-N` suffix ranges;
multi-range → full `200`; bad or unsatisfiable → `416 error.studio.bad_range` with
`content-range: bytes */<size>`. Headers: `content-type` from the row (default `video/mp4`),
`accept-ranges: bytes`, `content-length`, `cache-control: private, max-age=3600`. `409
error.studio.not_ready` while saving, `404` unknown, **`410 error.studio.expired` after 7 days**
(the R2 object is kept; route 5b reads it after that). The app downloads the original right
after `ready` (keep on device), and AVFoundation reads it with ranges for the filmstrip.

---

## Tests to extend (all in `deploy/cloudflare/api/test/`)

- `gate.test.ts`, `studio-gate.test.ts`: `GET /capabilities` (no key, bad key, key),
  `PUT /studio/upload` (keyed; GET/POST → 404), `/studio/upload/adopt` from outside → 404,
  `GET /library`, `/library/items/<16>/file|publish|studio` (keyed; 15 or 17 chars → 404;
  wrong methods → 404), `/library/adopt` still service-only.
- `worker.test.ts`, `studio-worker.test.ts`: capabilities shapes and `key` states (D1 throws →
  `unknown`); upload end to end with fakes (stream reaches R2 unbuffered, row inserted with
  `key_id`, video → session via the internal adopt path, image → `id: null`, busy adopt → 201
  with `studio_error`, the body is never read for the log, 411/413/415 before the body is
  read); item file Range cases; item publish (chunk copy, hostile `pipeTo` streams);
  item studio (reopen vs adopt).
- `library.test.ts` (real SQL on `node:sqlite`): post grouping (saved + render + host of one
  session = 1 post; a `/webp` job = its own post by link; upload + its adopted renders = 1
  post; deleted rows excluded), cursor paging with ties, `counts`, `deletable`.
- `studio.test.ts`: `step`/`step_bytes`/`step_total`/`waking` through starting → fetching
  (helper bytes) → probing (`reading`) → storing (chunk counting) → ready, and on an adopt;
  nulls with an old helper; `sweep()` collects a render nobody polled (D1 success,
  `media_items` row, R2 object), advances a save nobody polled, stops at the budgets, returns
  the pending count; `scheduleSweep` called on render/save/adopt creation.
- `webp.test.ts`: pending replies carry `phase`/`frames_done`/`frames_total`; sweep of a
  `/webp` job.
- `helper-server.test.ts`: `GET /fetch/:id` pending has `stage`/`bytes`/`total`; `GET /jobs/:id`
  pending has `phase`/`frames_done`/`frames_total` (stub encoder writing frame files).
- `helper.test.ts`: `downloadToFile` `onProgress`; `encodeAnimatedWebp` `onPhase` order
  (decode before ffmpeg, pack with the real count before img2webp).

Docs: add an "App routes" section to `deploy/cloudflare/README.md` (routes, the sweep, what is
unverified) and update its "Gate rules" paragraph. `STUDIO-CONTRACT.md` and
`LIBRARY-CONTRACT.md` are not edited (they stay true).

Deploy note for the owner (not run by the lane): API only (`prepare-git-info.sh`, then
`cf deploy --secrets-file ...`); the helper changes ship in the image, and the deploy id in the
container env restarts it once. No migration, no web deploy.

## Out of scope for this pass

Push notifications (APNs) for "your webp is ready"; deleting private copies or hosted mp4s with
a key; per-key rate limits; a `parent_id` column to join image hosts to their uploads; any
change to `/webp` beyond the progress fields; YouTube.

---

## 8. Live Activity push (addendum, pinned 2026-10-02)

The server half of `apple/CONTRACT-LIVE.md` (read its sections 2 and 3 first: the writer table,
the content-state shape and the parity fixture are pinned there). This section supersedes the
"Push notifications (APNs)" line of "Out of scope" above, for Live Activities only (no ordinary
alert pushes). Lane API, wave L0, starts after the HIG/review-fix wave has landed. Ground rules
above still hold: everything in `deploy/cloudflare/**`, additive only, **no D1 migration**
(tokens and runs live in Durable Object storage).

### 8.1 Decisions

- **Sender: the Durable Object, with `fetch()`** to `https://api.push.apple.com` /
  `https://api.sandbox.push.apple.com` (HTTP/2 negotiated by the Workers runtime in production;
  evidence and confidence in `apple/CONTRACT-LIVE.md` 3.1). Fallback built in the same wave: a
  relay route in the helper using `node:http2`, chosen by the text binding `APNS_VIA`
  (`"worker"` default, `"helper"`). The DO signs and builds every request either way; the helper
  only relays bytes to those two hosts, so no APNs secret ever enters the container.
- **Storage: DO storage** (the one `main` instance), next to `job:`, `save:` and `sweep:at`.
- **Triggers are the existing transitions**, reached by a client poll or by the sweep; no new
  timers (work after a DO response does not survive, CLAUDE.md runtime lessons). The latest
  counter value is always re-sent by the next poll or sweep, so nothing needs a trailing flush.
- **Live routes never wake the container** and are never written to `request_log` (a relay can
  arrive once a second).

### 8.2 Routes (all keyed; `Authorization: Api-Key`; a service-header caller gets 404)

The gate answers everything else under `/live` with 404. `<run>` is a lowercase UUID
(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`), else 404. The Worker handles
them **right after the key lookup, next to the library routes** (before `describeBody` and
`logRequest`), deletes `Authorization`, sets `x-cobalt-key-id`, and forwards to the DO at the same
path; the DO's `handle()` answers `/live/*` before the studio and webp routes (and never calls
`super.fetch`), refusing a request without the key id header with 403. Bodies are JSON, at most
4096 bytes (else 400). Errors use the usual shape with the codes below.

| route | body | answer |
|---|---|---|
| `PUT /live/start-token` | `{"token":"<hex>","environment":"sandbox"\|"production"}` | `204`. Stored as `live:start:<key id>` = `{token, env, updatedAt}` (one per key: one key per device) |
| `DELETE /live/start-token` | none | `204` |
| `PUT /live/runs/<run>` | see below | `200 {"status":"success","pushing":bool,"started":bool,"reason"?:"no_start_token"\|"not_configured"\|"start_unconfirmed"\|"start_rate_limited"}`; `429 error.live.too_many_runs` (caps below) |
| `POST /live/runs/<run>/state` | `{"state":{...}}` | `202 {"status":"success"}`; `404 error.live.not_found` (unknown run or another key's); `409 error.live.server_stage` (stage not `uploading`/`reading`/`ready`/`failed`) |
| `DELETE /live/runs/<run>` | none | `204` (idempotent). With an update token and not yet ended: one `end` push with the stored state, `dismissal-date` = now, no alert. Then the record and its `live:sid:` entry go |
| `GET /live/selftest` | none | 8.6 |

`PUT /live/runs/<run>` body (snake_case outside; `attributes` and `state` are passed through to
APNs verbatim, so their keys are the Swift property names):

```json
{
  "environment": "sandbox",
  "update_token": "<lowercase hex>",
  "session": "<sid>",
  "start": false,
  "attributes": { "run": "<run>", "input": "link", "service": "instagram", "ref": "Dd7P496wolG", "origin": "app" },
  "state": { "stage": "fetching", "rail": 0, "since": 1790000000, "waking": false, "packing": false }
}
```

Validation (400 `error.live.bad_request` unless noted): token `^[0-9a-f]{64,200}$` or null;
`environment` one of the two; `session` null or a valid sid whose `studio_sessions.key_id` is the
caller's (else 404 `error.live.not_found`); `attributes.run` equals `<run>`, `input` in
`link|file`, `origin` in `app|share`, `service`/`ref` strings of at most 120 characters; `state`
reduced to the allow-listed keys of `LiveContentState` with their types (`stage` in the enum,
`rail` 0..3, finite numbers, strings of at most 300 characters, unknown keys dropped, `waking` and
`packing` required). Upsert semantics: later PUTs fill in `update_token` and `session`; the stored
`state` is replaced only when the incoming one is from a device-owned stage or the run has no state.

Run record `live:run:<run>`: `{run, keyId, sid, job, env, updateToken, attributes, state, sent,
lastPushAt, startedAt, endedAt, createdAt, startAttemptedAt?, endTries?, endRetryAt?}` (`sent` =
the last content state APNs accepted); index `live:sid:<sid>` = run ids (at most 16 per session);
a small per-run index entry `live:idx:<key id>:<run>` = `{run, keyId, sid, createdAt, endedAt,
active, retryAt}` that the caps, the cleanup, `hasActiveRuns()` and the end retries read instead of
the run records. Effects of a PUT:

- `start: true`, no update token, `startedAt` unset, run not ended: one **push-to-start** (8.4) to
  `live:start:<key id>`; `started: true` when APNs said 200; no start token → `started: false,
  reason: "no_start_token"`. Honoured once per run, and never re-sent when its outcome is unknown
  (review fix 2026-10-02): `startAttemptedAt` is written BEFORE the push leaves and kept when the
  request was sent but no answer was seen (a transport error or timeout: Apple may have started the
  activity), and then every later `start: true` answers `started: false, reason:
  "start_unconfirmed"` and sends nothing. The conservative choice: at worst the activity of that
  run never appears; the alternative is two activities. A start that provably never left (a jwt
  failure, a transport that could not be made ready, an answered refusal, a 429) clears the marker,
  so a later PUT may try again.
- At most one push-to-start per key per 10 s (`LIVE_START_MIN_GAP_MS`; a failed one uses the
  window too): another PUT inside it answers `started: false, reason: "start_rate_limited"` and
  sends nothing (a later PUT may start).
- A new `update_token` while `state` differs from `sent`: one update push (priority 10) at once,
  so a push-started activity catches up as soon as the app reports its token. Nothing is ever pushed
  to a run that has `endedAt` (a late token on a finished run is stored and nothing else).
- `pushing` is false when APNs is not configured (`reason: "not_configured"`) or the last APNs
  attempt for this key failed for a non-token reason within 10 minutes (`live:health:<key id>`).
- Caps (`429 error.live.too_many_runs`, nothing stored): a key may hold at most 16 runs that have
  not ended (`LIVE_MAX_OPEN_RUNS_PER_KEY`) and 64 in all (ended runs are kept for an hour,
  `LIVE_MAX_RUNS_PER_KEY`); a session at most 16 (`LIVE_MAX_RUNS_PER_SID`), also when an existing
  run is moved to it. A PUT for a run that already exists is never counted again. Each run is an
  alert-bearing push with caller-supplied text, so unbounded runs would be unbounded pushes and
  unbounded work in the one Durable Object. The app should treat the 429 as "no activity for this
  run" (not retry hot).

### 8.3 Triggers (`src/live.ts` `LiveService`, called from `studio.ts`)

`StudioDeps` gains `live?: LiveHooks`:

```ts
export type LiveSaveEvent =
    | { kind: "progress"; progress: SaveProgress; title?: string | null; duration?: number | null }
    | { kind: "failed"; code: string };
export type LiveRenderEvent =
    | { kind: "accepted"; title?: string | null; duration?: number | null }
    | { kind: "pending"; phase: "fetching" | "decode" | "pack" | null; framesDone: number | null; framesTotal: number | null }
    | { kind: "success"; url: string; bytes: number | null; width: number | null; height: number | null; seconds: number | null }
    | { kind: "failed"; code: string };
export type LiveHooks = {
    onSave(sid: string, e: LiveSaveEvent): Promise<void>;
    onRender(sid: string, job: string, e: LiveRenderEvent): Promise<void>;
    // any run with an update token waiting on a server step (the sweep's 2 s cadence)
    hasActiveRuns(): Promise<boolean>;
};
```

Every call is awaited, raced against `LIVE_PUSH_MS = 3000` with `raceCeiling`, and can never fail
or delay the poll beyond that (errors logged). Pushes for several runs go out in parallel.

| server transition (file) | event | stage pushed |
|---|---|---|
| every `this.progress.set(sid, p)` (route them through one `setProgress`) in `startFetch`, `pollFetch`, `finalize` | `progress` | `p.step == "fetching"` → `fetching` (`waking`); `"reading"`/`"storing"` → `saving` (`bytes`, `total`). **Not** from `probeStep` (an upload's server read is not shown: the device is reading frames then) |
| `fail(sid, code)` | `failed` | `failed`, `failure` from `failureKey(code, "saving")`, `end` |
| session becomes `ready` | none | nothing (the device reads, `CONTRACT-LIVE.md` 2.1) |
| `render()` accepted (202), job id known | `accepted` | `rendering`; the run's `job` is set |
| `renderStatus()` pending | `pending` | `rendering`: `decode` → `framesDone`/`framesTotal`; `pack` → `packing: true`, frames = total; `fetching`/null → neither |
| `renderStatus()` success (first or repeated) | `success` | `done` with the result fields, `end` |
| `renderStatus()` recorded error, or a lost job | `failed` | `failed`, `failureKey(code, "rendering")`, `end` |

`failureKey(code, phase)` is a port of `apple/CobaltKit/Sources/CobaltKit/API/ErrorMap.swift`
`mapFailure` returning the case name (`fetchFailed`, `renderLost`, …; unknown → `server`).
Runs for a sid are found through `live:sid:<sid>`; a render event also matches runs whose `job`
equals the job id. Events for a run that has `endedAt` are ignored.

**Merge and coalesce** (per run, pure function in `live.ts`, same rule as the app's builder):
on a stage change reset `bytes`, `total`, `framesDone`, `framesTotal`, `packing` and set `since`
= now (`fetching` keeps the registered `since`); carry `title`/`duration`. Then:

- next state deep-equals `sent` → nothing;
- stage changed, or terminal → push now, `apns-priority: 10`;
- else if `now - lastPushAt < 1000` → store `state`, no push (the next poll or sweep sends the latest);
- else push, `apns-priority: 5`.

Without an update token the state is stored (sent later by the catch-up push in 8.2).

**Sweep cadence** (`sweep.ts`): `scheduleSweepSoon(d, delayS = SWEEP_DELAY_S)`; `runSweep`
re-arms after a pass with `LIVE_SWEEP_DELAY_S = 2` when something is pending **and**
`hasActiveRuns()`, else 5 as today. The same pass runs `live.cleanup(now)`: runs older than
`LIVE_RUN_TTL_MS` (8 h, Apple's active limit) or ended more than 1 h ago, `live:sid:` entries
without runs, start tokens not refreshed for 60 days. `PUT /live/runs` runs the same cleanup.
Cleanup and `hasActiveRuns()` read the per-run index entries (bounded by the caps in 8.2), never
the run records.

**End retries** (review fix 2026-10-02): a terminal state whose `end` push failed (5xx, a network
error, 429, the ceiling) stays "pending end" on the run record (`endTries`, `endRetryAt`), because
once the sweep has collected a result it never looks at that job again, so nothing else would
re-send it with nobody polling. The pass also runs `live.retryEnds(now)`, which re-sends due ends
(backoff `LIVE_END_RETRY_DELAYS_MS` = 5 s, 15 s, 40 s after each failure: the first try plus 3
retries over about a minute, then only a client poll retries) and tells the sweep when the next one
is due, so `runSweep` re-arms for it even with nothing else pending; the failing push itself arms
the sweep (`LiveDeps.scheduleSweep`). A poll inside the backoff does not re-send either. This is
DO-only work: with the `worker` transport the container is not touched; with the `helper`
transport an `end` wakes it first, as it always does (8.4).

### 8.4 APNs requests (`src/apns.ts`, pure: `fetch`, `crypto.subtle`, `now` injected)

JWT: header `{"alg":"ES256","kid":APNS_KEY_ID}`, claims `{"iss":APNS_TEAM_ID,"iat":<unix s>}`,
signed with the PKCS#8 key from `APNS_KEY_P8` (PEM; strip the armour, base64-decode,
`importKey("pkcs8", …, {name:"ECDSA", namedCurve:"P-256"}, false, ["sign"])`; WebCrypto's
signature is already the raw 64-byte `r‖s` ES256 wants), base64url without padding. Reused for 50
minutes; never re-signed within 20 minutes (APNs refuses frequent provider-token refreshes) except
once after a `403 ExpiredProviderToken`. The token is **persisted in DO storage** (`live:jwt` =
`{token, at, forced, kid, iss}`, loaded on the first use after a start or eviction; a token for
another key id or team id is ignored), so a Durable Object eviction does not re-sign it: a
memory-only cache re-signed on every eviction, which breaks the 20-minute rule and made Apple
answer `429 TooManyProviderTokenUpdates`.

```
POST https://api.push.apple.com/3/device/<token>          (production)
POST https://api.sandbox.push.apple.com/3/device/<token>  (sandbox)
authorization: bearer <jwt>
apns-topic: <APNS_BUNDLE_ID>.push-type.liveactivity       (com.capybaraharmony.cobalt.push-type.liveactivity)
apns-push-type: liveactivity
apns-priority: 10 | 5
apns-expiration: <unix s>     (counters: now + 60; stage changes, start and end: now + 3600)
content-type: application/json
```

Payloads (`timestamp`, `stale-date`, `dismissal-date` are integer unix seconds; `content-state`
is the run's state exactly as stored):

```json
{"aps":{"timestamp":1790000020,"event":"update","content-state":{…},"stale-date":1790000140}}

{"aps":{"timestamp":1790000000,"event":"start","attributes-type":"CobaltActivityAttributes",
        "attributes":{"run":"…","input":"link","service":"x","ref":"2105435404002562056","origin":"share"},
        "content-state":{…},"stale-date":1790000120,"input-push-token":1,
        "alert":{"title":"cobalt","body":"fetching from x"}}}

{"aps":{"timestamp":1790000043,"event":"end","content-state":{…},"dismissal-date":1790000943,
        "alert":{"title":"webp ready","body":"x · 841 KB"}}}
```

- `stale-date`: now + 120 s; for a relayed `ready` state now + 30 min (the owner is trimming).
- `end` on `done`: `dismissal-date` now + 900, alert `{"title":"webp ready","body":"<service> ·
  <size>"}` (size formatted like the app's `Format.bytes`); on `failed`: now + 300, alert
  `{"title":"cobalt couldn't finish","body":"open cobalt to see what happened."}`. Start alert body:
  `"fetching from <service>"`, or `"uploading <ref>"` for a file. No `sound` anywhere. All copy
  lowercase and lives in `live.ts`.
- `input-push-token` only on `start` (Apple: it has no effect elsewhere).

Answers:

| APNs answer | action |
|---|---|
| 200 | `sent`/`lastPushAt` updated; health ok |
| 400 `BadDeviceToken` | retry once on the other host; on 200 store that environment for the token; else drop the token |
| 410 (any), 400 `ExpiredToken` | drop the token (run's `updateToken` = null, or the start token) |
| 403 `ExpiredProviderToken` | re-sign once, retry once |
| 403 other (`InvalidProviderToken`, `TopicDisallowed`, …), 5xx, network error, transport ceiling | health bad for 10 min (`pushing: false`), logged |
| 429 `TooManyProviderTokenUpdates` | health bad for 10 min (`pushing: false`), logged with the reason (never silent: it used to count as the 429 below and lost the push without a trace) |
| other 429 | nothing (the next event retries) |

A counter (priority 5) is also skipped while the key is unhealthy (during an outage every poll and
every 2 s sweep would otherwise wait out a failing push); stage changes, `end` and a catch-up still
go. With `APNS_VIA=helper` a counter is skipped outside the server stages (`fetching`, `saving`,
`rendering`) too: a relay goes through `containerFetch`, which renews the container's `sleepAfter`,
and device-stage relays (about one a second while uploading or reading) would keep it awake.

`unhealthy` deliveries also say whether the request may have been delivered (`maybeDelivered`: it
was sent and no answer came back) or provably was not (an answered refusal, a jwt or wake failure);
only the start push (8.2) acts on it.

**Logs**: one line per push, `[live] apns <status> <reason|-> event=<start|update|end> pri=<5|10>
run=<first 8> token=<first 8> apns-id=<apns-id header>`. Never the key, the JWT, a full token, or
the content state. A test spies on `console` to prove it.

**Fallback transport** (`APNS_VIA = "helper"`): `helper/server.js` gains `POST /apns` (behind
`x-internal-key` like every helper route): body `{"host","path","headers","body"}`; refuses any
host but the two above (400); one `node:http2` session per host, reconnected on `goaway`/error;
one 2 s budget for the whole relay, a retry on a fresh session after a dead one included
(`APNS_DEFAULT_TIMEOUT_MS`; a larger configured value is capped), so the helper always answers
before the DO gives up on it at `APNS_CALL_MS` = 2500; answers
`{"status":<int>,"reason":<string|null>,"apns_id":<string|null>}`. The DO uses it through
`d.helper` only when the container is running, except for `start` and `end` events and the
self-test, which call `ensureRunning()` first; a counter while the container sleeps is skipped
(the next event sends the latest).

`ensureRunning()` runs **before and outside** the per-attempt ceiling, under its own budget
(`APNS_WAKE_MS` = 30 s; the transport's `prepare` step). A cold start inside the 2.5 s ceiling used
to time the push out, mark the key unhealthy for 10 minutes and answer `started: false`, while the
waking container went on to deliver it (the helper's old 10 s timeout), so a retried
`PUT start: true` sent a second start and made two activities. A wake that fails or outlasts its
budget is `unhealthy` (`wake: …`) and provably sent nothing. Consequence: a `PUT` with
`start: true` can take up to about 30 s on a cold container (the app's call should tolerate that or
accept a lost answer; the `start_unconfirmed` rule covers the retry).

### 8.5 Secrets, config, capability

`cloudflare.config.ts` (api): `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID` as
`bindings.secret()`; `APNS_BUNDLE_ID: bindings.text("com.capybaraharmony.cobalt")`;
`APNS_VIA: bindings.text("worker")`. They are read by the Worker (capabilities) and the DO
(sending); **none** goes into `envVars` (the container never sees them, the env fingerprint does
not change). They come from `~/.config/cobalt/secrets.json` through `--secrets-file` like
`COBALT_API_KEY` (the PEM as one JSON string with `\n` escapes). Check with `cf deploy --dry-run`
whether `cf` 1.0.0-beta.5 refuses a declared secret missing from the file, and say so in the
README.

`GET /capabilities` gains `features.live_activity_push`: true when all three secrets are
non-empty strings (`capabilities()` takes a `livePush: boolean`). Missing key in older servers =
false, so the app degrades to local updates.

### 8.6 `GET /live/selftest` (keyed): the live check of the transport

Signs a JWT and sends one update to the **sandbox** host for the device token of 64 zeros, through
the configured transport, with the real topic. Answers `200`:

```json
{"status":"success","configured":true,"transport":"worker","host":"api.sandbox.push.apple.com",
 "jwt":"ok","apns_status":400,"apns_reason":"BadDeviceToken"}
```

`BadDeviceToken` means HTTP/2, the JWT and the topic all work. `InvalidProviderToken`: wrong key
id, team id or key. `TopicDisallowed`: the key is not allowed for this bundle id. No JSON
`reason`, or a network error in `apns_reason` (`"transport: <message>"`): the transport failed,
switch `APNS_VIA` to `helper` and redeploy. Not configured: `{"configured":false}`. Never returns
the JWT or the key.

### 8.7 Files

New: `src/apns.ts`, `src/live.ts`, `test/apns.test.ts`, `test/live.test.ts`,
`test/fixtures/live-states.json` (byte-identical copy of the app's fixture). Edited:
`src/gate.ts` (decisions `live_start_token`, `live_run`, `live_state`, `live_selftest`),
`src/worker.ts` (dispatch, `WorkerEnv` APNs fields, capabilities flag), `src/app-routes.ts`
(`features.live_activity_push`), `src/index.ts` (construct `LiveService` with `this.ctx.storage`,
the env, `fetch`, the helper transport; route `/live/*` in `handle()`; pass `live` to
`StudioService`; `hasActiveRuns` into the sweep), `src/studio.ts` (hooks per 8.3),
`src/sweep.ts` (cadence), `helper/server.js` (`POST /apns`), `cloudflare.config.ts`, `README.md`
("Live Activities": routes, secrets, the self-test and how to read it, the transport switch, what
is unverified).

### 8.8 Tests

- `gate.test.ts`: every `/live` route keyed (missing/invalid key → 401), wrong methods and bad run
  ids → 404, service header → 404, unknown `/live/*` → 404.
- `worker.test.ts`: live routes forwarded with the key id and without `Authorization`, not logged
  to `request_log`, `describeBody` never called; `features.live_activity_push` true only with all
  three secrets.
- `apns.test.ts` (node WebCrypto, a generated P-256 key): the JWT verifies with the public key and
  has the pinned header and claims; reuse within 50 min, no re-sign within 20 min, re-sign once on
  `ExpiredProviderToken`; exact headers and host per environment; `BadDeviceToken` retries on the
  other host and remembers it; 410 drops the token; health bad on 403/5xx/ceiling; no log line
  contains the token, the JWT or the PEM; the helper transport refuses other hosts.
- `live.test.ts`: registration validation (each 400/404/409 case); session of another key → 404;
  push-to-start payload exactly as 8.4, once per run, `no_start_token`; catch-up push when the
  update token arrives; the merge rule; coalescing (counters at most one per second, stage changes
  and terminal at once, equal states never re-sent); priorities 5/10; `end` payloads with their
  dismissal dates and alerts; relay accepts only device stages; `DELETE` sends `end` now; cleanup
  TTLs; `failureKey` against every row of the app's error map; **parity**: from the matching
  events the builder produces each entry of `fixtures/live-states.json`.
- `studio.test.ts`: hooks called at each transition of 8.3 (starting → fetching → storing → ready
  makes fetching, saving, nothing; an adopt makes nothing until render; render accept, pending
  decode/pack, success, error, lost; the sweep's own collection fires them too); a hook that throws
  or hangs never fails or stalls the poll beyond `LIVE_PUSH_MS`.
- `sweep.test.ts`: 2 s re-arm while live runs are active and something is pending, 5 s otherwise.
- `helper-server.test.ts`: `POST /apns` needs the internal key, refuses other hosts (the HTTP/2 call
  itself is stubbed).

### 8.9 Deploy note (owner; not run by the lane)

Add the three APNs secrets to `~/.config/cobalt/secrets.json`, then the API deploy only
(`prepare-git-info.sh`, `cf deploy --secrets-file …`). No D1 migration, no web deploy. The helper
change ships in the image (the deploy id restarts the container once). Then
`GET /live/selftest` with the device's key and read the answer as in 8.6.

Unverified until deployed: HTTP/2 from the DO to Apple (8.6 is the check); APNs throttling of
priority-5 updates at one per second; that a push-started activity's update token reaches the app
(`apple/CONTRACT-LIVE.md` section 6, Plan B: broadcast channels).

---

## 9. Hark notification bridge (addendum, pinned 2026-10-04)

APNs is not available yet (no push key), so a job the owner walked away from (typically a share-sheet
run) is announced through the owner's **Hark** webhook instead: the Worker's Durable Object POSTs
`{"title": "<=80 chars", "body": "<=2000 chars"}` (`content-type: application/json`) to
`HARK_WEBHOOK_URL`. Nothing under `api/` changes; nothing wakes the container.

### 9.1 Config and capability

- `cloudflare.config.ts` (api): `HARK_WEBHOOK_URL: bindings.secret()`, from
  `~/.config/cobalt/secrets.json` through `--secrets-file` like `COBALT_API_KEY`. Read by the Worker
  (the capability flag) and the Durable Object (sending). It is a SECRET: never in `envVars` (the
  container never sees it), never logged, never stored, never returned.
- Missing, empty, blank, not a URL or not `https:` = **bridge off**: nothing is stored or sent.
- `GET /capabilities` gains `features.notify_bridge: boolean` (true = a usable webhook URL is
  configured). A missing key in an older server = false. The app only offers/uses the opt-in when
  it is true (the routes still answer when it is false, see 9.2).

### 9.2 Opt-in: `PUT|DELETE /studio/<sid>/notify` (keyed)

So that only jobs the owner walked away from notify, nothing fires without an opt-in. The app
sends `PUT` when it is about to be backgrounded or closed with a job in flight (the share
extension: right after creating the session) and `DELETE` when it is back in the foreground and
has the result (otherwise a foreground poll that sees the result also notifies).

`Authorization: Api-Key <key>`; a library-service caller gets 404; no CORS (the app sends no
`Origin`); wrong methods and bad session ids are 404. The key must be the one that created the
session; any other key, and an unknown session, get the same `404 error.studio.not_found`.

`PUT /studio/<sid>/notify`, body (at most 1024 bytes):

```json
{ "on": ["saved", "rendered", "failed"], "label": "x · 2105435404002562056" }
```

- `on`: 1 to 3 of `"saved"` (the save became ready), `"rendered"` (a render finished),
  `"failed"` (the save or a render failed). Repeats are folded; anything else is a 400.
- `label`: optional, at most 60 characters (counted as characters), no control characters; empty or
  `null` = none. It names the job in the "saved" and save-failure messages; without it the server
  uses `"<service> · <ref>"` (ref = the link's last path segment) or the clip's title.
- Invalid: `400 {"status":"error","error":{"code":"error.notify.invalid"}}`. D1 down: 503.
- Answer `200`:

```json
{ "status": "success", "bridge": true, "on": ["saved", "rendered", "failed"],
  "label": "x · 2105435404002562056", "expires_at": 1790086400000 }
```

  `expires_at` is unix ms, **24 hours** after this call. Idempotent: a repeat replaces the opt-in
  and restarts the 24 h; it never resets what was already sent. With the bridge off the answer is
  `{"status":"success","bridge":false,"on":[...],"label":...,"expires_at":null}` and nothing is
  stored.

`DELETE /studio/<sid>/notify` -> `204`, idempotent. Removes the opt-in and the render-only ones
(9.3) and cancels notifications still waiting for a retry. Another key: 404.

### 9.3 Render-only opt-in: `"notify": true` on `POST /studio/<sid>/render`

Optional boolean in the render body (`false` or absent = none; any other type is
`400 error.webp.invalid_params`). Notifies about THAT render's result only (`rendered` or
`failed`), for 24 hours, whether or not the session has an opt-in. The route stays a capability
URL (no key), so there is no owner check.

### 9.4 What fires, and the copy

Fired from the server-side transitions that also run unpolled, so a closed app is still told: the
poll that sees them, or the job sweep (section 6), whichever comes first.

| event | when | title | body |
|---|---|---|---|
| `saved` | the save became `ready` (a link save; not an upload adoption) | `cobalt` | `<label or service · ref> is saved · <duration> s — open cobalt to make a webp` (`· <duration> s` left out when unknown) |
| `rendered` | a render job finished | `cobalt` | `webp ready · <w>×<h> · <size>` + `\n` + the webp URL (parts left out when unknown; size as `Format.bytes`: `841 KB`, `4.5 MB`) |
| `failed` | the save failed / a render failed | `cobalt couldn't finish` | `couldn't save <label or service · ref> — <reason>` / `couldn't make the webp — <reason>` |

`<reason>` is a short plain phrase from the error code (`the link could not be fetched`, `the
server was busy`, `the server lost track of the job`, `the video is too large`, `that kind of
video is not supported`, `the session expired`, `storing the file failed`, `the server was not
available`, `the clip is too long`, else `something went wrong on the server`). Copy is lowercase;
the title is cut to 80 characters and the body to 2000 (by code points, with `…`).

### 9.5 Exactly once, retries, timeouts

- Every event has a record in DO storage (`notify:ev:<sid>:<event>`; a render's is per job, so a
  job gives one notification whether it succeeds or fails). A record exists before the first
  send and outlives it (7 days), so a client poll racing the sweep, a repeated poll of a finished
  job, or a re-sent opt-in never produces a second message. Per event the work is serialised.
- The send is a plain `fetch` from the Durable Object, raced against our own **3 s** ceiling
  (AbortSignal timeouts are not honoured inside the DO). `2xx` = sent. `5xx`, a network error and a
  timeout are retried by the sweep (which the failure arms): **at most twice**, after 5 s and 20 s
  (three sends in all, then it gives up). Any other status (`4xx` including 429, redirects: not
  followed) is final and never retried. A timeout is ambiguous (the webhook may have received
  it), so a timed-out send that is then retried can, rarely, arrive twice; Hark has no idempotency
  key. The try counter is written before each send, so a Durable Object that dies mid-send
  keeps the retries bounded.
- A poll inside a backoff does not re-send. The poll or sweep that sees a transition awaits the
  send (at most 3 s plus storage; 5 s as an outer ceiling), so a slow Hark delays that one poll
  slightly and never fails it.
- Logs carry only `[notify] hark sent <status> sid=<first 8>` / `hark failed <status|network|timeout>
  sid=<first 8>`: never the URL, a key, a message or an error text.

### 9.6 Files

New: `src/notify.ts`, `test/notify.test.ts`. Edited: `src/gate.ts` (`studio_notify`), `src/worker.ts`
(dispatch, `WorkerEnv.HARK_WEBHOOK_URL`, capability flag), `src/app-routes.ts`
(`features.notify_bridge`), `src/index.ts` (construct `NotifyService`, route before the container
checks), `src/studio.ts` (hooks at save ready / save failed / render result, the `notify` flag),
`src/sweep.ts` (retries re-arm the sweep), `cloudflare.config.ts`, `README.md`.

### 9.7 Deploy note (owner)

`HARK_WEBHOOK_URL` is already in `~/.config/cobalt/secrets.json`. API deploy only
(`prepare-git-info.sh`, then `cf deploy --secrets-file …`); no D1 migration, no web deploy.
`cf deploy --dry-run --secrets-file` accepts the new secret (checked 2026-10-04). Unverified until
deployed: the real Hark endpoint's answers (only 2xx/4xx/5xx classes are assumed), and that a
`fetch` from the Durable Object reaches it.

---

## 10. Crop (addendum, pinned 2026-10-04; `apple/CONTRACT-ORBIT.md` section 2d)

An optional spatial crop in addition to the time trim.

### 10.1 Wire

`crop` on `POST /studio/<sid>/render` and on `POST /webp`:

```json
{ "start": 2, "length": 5, "width": 480, "crop": { "x": 0.25, "y": 0.1, "w": 0.5, "h": 0.5 } }
```

- Normalized `x, y, w, h`, all finite numbers (numbers only, not strings), `x, y >= 0`, `w, h > 0`,
  `x + w <= 1` and `y + h <= 1` (plus a slack of 0.001 for a client's float rounding, clamped
  away below). In the source's **display orientation** (after rotation metadata).
  Anything else: `400 error.webp.invalid_params`. Absent or `null` = no crop, exactly the
  behaviour before this section (no `crop` key in any record, query or ffmpeg argument).
- Server conversion (`helper/crop.js` `cropToPixels`, shared by the Durable Object and the
  helper): multiply by the displayed size, round each of x, y, w, h to the nearest **even**
  number, clamp the size to the (even) frame and the position so the rectangle stays inside it,
  and reject a cropped width or height **under 64 px** with `error.webp.invalid_params`.
- The displayed size is what the helper probes (rotation applied: a 1920x1080 clip with a
  -90 degree rotation is 1080x1920) and what ffmpeg's filter graph sees (it autorotates before
  filtering), so the crop is read against the picture the owner saw.

### 10.2 Where it is checked

- Studio render: the Durable Object already has the session's probed size (`width`/`height`), so
  the whole check is a synchronous `400` before anything is uploaded. A session saved without a
  known size passes the crop on unconverted (the helper converts it).
- `POST /webp` (a URL source): the size is only known once the helper has downloaded and probed
  it, so a crop under 64 px there fails the JOB (`status: "error"`,
  `error.webp.invalid_params`) instead of the POST; a malformed crop is still a `400`.
- The helper (`POST /jobs`, `POST /jobs/upload?...&crop=x,y,w,h`) validates again and converts with
  its own probe. A source whose size it cannot read cannot be cropped
  (`error.webp.encode_failed`).

### 10.3 Encoding and result

ffmpeg filter: `fps=<fps>,crop=<w>:<h>:<x>:<y>,scale='min(<width>,iw)':-2:flags=lanczos`, i.e. the
crop is applied BEFORE the scale. Output width = `min(requested width, cropped width)`; the height
keeps the crop's aspect (`-2`); the clip window and `fps` are untouched, so `frames_total` is the
same as without a crop. The render's recorded width (`studio_renders.width`) is that
min-width; the result's `width`/`height` are the real WebP's. The crop is kept in the DO's job record
(`job:<id>.params.crop`); no D1 column holds it (no migration).

`GET /capabilities` gains `features.crop: true` (missing = false: an older server ignores the field
and renders the whole frame, so the app hides the crop button).

### 10.4 Files and tests

New: `helper/crop.js`, `test/crop.test.ts`. Edited: `helper/lib.js` (`validateEncodeFields`,
`buildFrameArgs`), `helper/server.js` (the conversion at encode time, `crop` in the upload query),
`src/webp.ts`, `src/studio.ts`, `src/app-routes.ts`. `test/crop.test.ts`: validation matrix, even
rounding and clamping, the 64 px floor, the rotation case (the probe of a rotated clip), ffmpeg
args with crop before scale and unchanged without, the helper's API (upload and `/jobs`), the DO
paths (studio and `/webp`), and absent-crop-unchanged.

## 11. Hold the video until the save finishes: `GET /studio/<sid>/source?wait=<0..90>` (addendum, pinned 2026-10-04; `apple/CONTRACT-SYNC.md` section 5)

Why: a background download (`nsurlsessiond`) started right after the share cannot poll. It asks for
the video once and the server holds the request until the save is done.

`GET /studio/<sid>/source?wait=N`. `N` is clamped to `0..90` (seconds, fractions allowed); absent,
empty or junk is `0`, which is today's behaviour exactly. Same route, same rules: no key (the
session id is the credential), unknown id `404`, `410 error.studio.expired`, ranges, headers, CORS.

| state when asked / during the hold | answer |
|---|---|
| `ready` | today's `200`, or `206` / `416` for a `Range` (the range is applied after the hold) |
| `saving`, ready before the deadline | the same `200` / `206` |
| `saving` at the deadline | `409 error.studio.not_ready` (today's) |
| `error` (already, or during the hold) | `422 {"status":"error","error":{"code":"<the session's error_code>"}}`; `error.api.generic` if the row has none |
| session expires during the hold | `410 error.studio.expired` |
| D1 fails | `503 error.api.generic` |

- `wait` absent or `0`: unchanged, including `409` (not 422) for a failed session.
- `HEAD` ignores `wait`: it answers from the row as it is.
- While the row is `saving` the Worker repeats the same Durable Object call the status route uses,
  `GET /studio/<sid>/advance?wait=min(25, seconds left)` (a save only moves while the DO is
  polled), then re-reads the session row from D1, until the row leaves `saving` or the deadline
  passes. A DO that answers at once, or throws, costs a 500 ms pause (injected `sleep`), so the hold
  never spins; the loop is also capped at 400 advances. No CPU while waiting beyond one D1 read per
  advance. The container is already awake while a save is running; a `ready` session with `wait`
  never touches it (no DO call, no sleep).
- `GET /capabilities` gains `features.source_wait: true`. Missing = an older server: it answers
  `409` at once, which the app treats as "try again on foreground".
- Range requests: a `ready` session row is cached in the Worker isolate (per D1 binding, 60 s TTL,
  64 entries, never for `saving` / `error`), so the many range reads of the filmstrip skip the D1
  lookup. Safe because the only writers of a session row are `WHERE status = 'saving'`; expiry is
  checked on every hit; a swept session shows up as the R2 `404` at worst.
- Unverified until deployed: a 90 s hold through the Cloudflare edge to the client. The measured
  per-range latency (about 0.4 s) was not re-measured; the cache removes one D1 round trip only.

Code: `src/studio-edge.ts` (`studioSource`, `loadSourceSession`), `src/studio.ts`
(`parseSourceWait`), `src/worker.ts` (the route), `src/app-routes.ts` (the flag).
Tests: `test/studio-worker.test.ts` ("GET /studio/<sid>/source?wait=N"), `test/worker.test.ts`
(the flag).

## 12. Delete a whole post: `DELETE /library/items/<id>/post` (addendum, pinned 2026-10-05; `apple/CONTRACT-MEDIA.md` section 6.1)

- **Gate** (`gate.ts`, in the existing `/library/items/<id>/<sub>` block): sub `post`, method
  `DELETE` → `lookupThen(req, "library_post_delete", { id })`; any other method on `post` → 404.
  `<id>` is checked by the existing `^[A-Za-z0-9]{16}$` (else 404). Auth exactly like the other
  library routes: `Authorization: Api-Key <key>` (D1 lookup) or the web Worker's
  `x-cobalt-service` (key id `service:library`); missing/invalid key → the existing 401 codes.
  Answered by the Worker from D1 + R2 (`MEDIA`, `ORIGINALS`); the container and the DOs are never
  woken. No CORS (the web page does not call it; a later web change may, through the service
  binding).
- **Which post**: the anchor row is read **including soft-deleted rows**
  (`SELECT … FROM media_items WHERE id = ?1`; unknown → 404 `error.library.not_found`), and its post
  key is computed with the same `POST_KEY_SQL` as `GET /library`. The post's sessions are the
  `studio_sessions` whose list key (`CASE WHEN s.link LIKE 'upload:%' THEN substr(s.link, 8) ELSE
  s.id END`, `app-routes.ts:448`) equals that key.
- **Busy** → `409 {"status":"error","error":{"code":"error.library.busy"}}`, nothing changed: any of
  those sessions has `status = 'saving'` and `created_at > now − 15 min`, or a `studio_renders` row
  with `status = 'pending'` and `created_at > now − 15 min` (older pending rows are lost jobs and do
  not block).
- **Order** (each step idempotent):
  1. expire the post's sessions: `UPDATE studio_sessions SET expires_at = now WHERE id IN (…) AND
     expires_at > now` (no new render or source read can start: they answer 410, as today);
  2. for every live row of the post (`deleted_at IS NULL`), oldest first: `R2.delete(r2_key)` in its
     bucket (`media` → `MEDIA`, `originals` → `ORIGINALS`; deleting a missing object succeeds), then
     `UPDATE media_items SET deleted_at = now WHERE id = ? AND deleted_at IS NULL`. A row whose R2
     delete throws stays live and is reported in `remaining`;
  3. for each of the post's sessions, `ORIGINALS.delete(session.r2_key)` when set (covers an
     original with no row; failure is logged, not reported: its session is already expired, so it
     can no longer be read through any route).
- **Responses** (`cache-control: no-store`, JSON):
  - `200 {"status":"success","post":"<post key>","deleted":{"files":4,"bytes":12471210},"remaining":[]}`;
    a second call for the same post (or any anchor of it, deleted or not) → `200` with
    `"deleted":{"files":0,"bytes":0}`: **idempotent**, so the app's retry is always safe.
  - `502 {"status":"error","error":{"code":"error.library.partial"},"post":"…","deleted":{…},"remaining":["<item id>",…]}`
    when at least one row could not be deleted. Extra keys on an error body are additive; old
    clients never call this route.
  - `404 error.library.not_found`, `409 error.library.busy`, `400`-class gate rejections as today,
    `503 error.api.generic` when D1 itself fails before anything changed.
- **Capability**: `GET /capabilities` gains `features.delete_post: true` (`app-routes.ts:185`).
  Absent = false: the app uses fallback (a).
- **Accepted race**: a render POSTed in the instant between the busy check and step 1 can still
  finish and add one webp row; it shows as a one-webp post the owner can delete again.
- **Backward compatibility**: no existing route, gate decision, response shape, row shape or
  migration changes. Rows are soft-deleted exactly as the web's `itemDelete` does
  (`web/src/library.ts:596-615`), so the web library, `GET /library`, old app builds (1.0/1.1, which
  only list and per-webp delete) and plain cobalt clients (`POST /`) see nothing new except that
  deleted things are gone. `OriginalsBucket`/`PublishBucket` interfaces gain `delete(key)` (the real
  R2 binding has it; the test fakes add it).
- **Tests** (`test/library.test.ts`, real SQL on `node:sqlite`; `test/gate.test.ts`;
  `test/worker.test.ts`): a post of saved original + 2 studio webps + host mp4 → all rows soft-deleted,
  all four R2 keys deleted, sessions expired, `200` with the counts; second call → `200` zeros;
  anchored on an already-deleted row → same post; an upload post (`upload:<id>` session link) and a
  reopened saved session (renders stay in the original post) → whole post; a `/webp`-job post keyed
  by link → only its rows, another post with a different link untouched; a pending render < 15 min →
  `409`, nothing changed; a pending render > 15 min → proceeds; R2 delete throwing for one key →
  `502 error.library.partial`, that row live, the others deleted, retry → `200`; gate: 15/17-char id
  → 404, `GET/POST …/post` → 404, no key → 401, service header → allowed; `GET /library` after the
  delete no longer lists the post and `counts` drop; `/capabilities` has `delete_post: true`; the
  existing suites stay green (old routes unchanged).

Code: `src/gate.ts` (the `post` sub-route), `src/app-routes.ts` (`libraryPostDelete`, the flag), `src/worker.ts` (the
dispatch). Tests: `test/library.test.ts` ("DELETE /library/items/<id>/post"), `test/gate.test.ts`, `test/worker.test.ts`
(the flag). `OriginalsBucket` (`src/studio.ts`) and `PublishBucket` (`src/publish.ts`) already declared `delete(key)`, and
the test fakes already implemented it, so no interface change was needed. Deploying is the owner's.
