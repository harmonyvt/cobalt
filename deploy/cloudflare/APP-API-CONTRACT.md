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
  `notify_bridge` (section 9.1), `crop` (section 10; `true` on any server that has it), `delete_post` (section 12), `source_wait`
  (section 11), `poster` and `public_default` (section 13), `line` (section 17, with `limits.line_max` and `limits.line_wait_ms`).
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

Every message carries `url: cobalt-apple://session/<sid>` (the studio session id, never the webhook URL or a
key), so a tap opens cobalt on that run instead of Hark; the app routes it in `AppModel.openRunLink`. A
retried send carries it too.

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

## 13. Server-made posters and "public by default" (addendum, built 2026-10-05; owner: "by default videos are public and they should have a thumbnail by the server")

Two additive features, built as one change. **Backward compatible**: no existing route, gate decision, status code, error code or
row meaning changes; old apps (1.0 to 1.3), the web library, the studio page and upstream-style clients (`POST /`) see only extra JSON
fields. Both are announced by capability flags: `GET /capabilities` gains `features.poster: true` and `features.public_default: true`
(missing = `false`: an older server ignores `public` and makes no posters, so the app keeps its own thumbnails and hosts by hand).

### 13.1 Migration `d1/migrations/0006_posters_public.sql` (additive: nullable columns and one index)

| table | new column | meaning |
|---|---|---|
| `media_items` | `poster TEXT` | public URL of the row's poster JPEG (`https://media.capybaraharmony.com/<10 base62>.jpg`) |
| `media_items` | `poster_at INTEGER` | ms; when a poster was made, or when the last attempt ended without one (a row without a poster is not tried again for 24 h) |
| `studio_sessions` | `poster TEXT` | the same URL, mirrored from the session's original (so `GET /studio/<sid>` needs no join) |
| `studio_sessions` | `public_state TEXT` | `NULL` (never asked), `'pending'`, `'ready'`, `'failed'` |
| `studio_sessions` | `public_url TEXT` | the hosted original's public URL when `public_state = 'ready'` |

Plus `idx_media_items_object ON media_items (bucket, r2_key)`. Nothing existing is rewritten. Statements that name their columns (every
one the code before this change ran) keep working on the migrated database, so **apply the migration first, deploy after**.
`test/migration-0006.test.ts` applies it on top of 0005 with data in every table and asserts the rows survive untouched, the new columns
read NULL, the old statements still run, and the file contains nothing but `ALTER TABLE ... ADD COLUMN` and `CREATE INDEX`.

### 13.2 `public: true`: host the original publicly when the save is ready

- **`POST /studio`**: optional `"public": true` next to `url`. `true` asks for it; absent, `null` and `false` are exactly today's
  behaviour. Any other type (`"yes"`, `1`, an object) is `400 error.studio.invalid_params` and nothing is created. The response is
  unchanged (`201 {status, id, url}`). The flag survives the Worker's link extraction from free text.
- **`PUT /studio/upload?name=...&public=1`** (the upload contract's own style: options travel in the query). `1` and `true` ask for it;
  absent, empty, `0` and `false` are today's behaviour; any other value is `400 error.library.bad_request`, refused before the body is
  read. (There is no header form.)
- **What happens.** The session row records `public_state = 'pending'` at creation (an errored save resets it to `NULL`: nothing to
  host). When the save becomes `ready` (the very `UPDATE ... SET status = 'ready'` is untouched and happens first), the Durable Object
  hosts the stored original with **the same code as `POST /studio/<sid>/publish`** (`publishStudio`): the same unguessable
  `<10 base62>.<ext>` name, the same chunk-free R2 to R2 stream copy, the same `host` row (same columns, `session_id = <sid>`,
  `key_id` = the session's key, `link`, size, duration) and the same object metadata (`published: "1"`, `sessionId`, ...). Then
  `public_state = 'ready'` and `public_url` = the file. The poll that reports `ready` normally already carries `public_url` (the copy
  ran before that response was sent); if the copy is slow the poll just takes longer, and `status` was `ready` in D1 the whole time
  (`/studio/<sid>/source?wait=` is not held back). The helper copy and the `save:` record are released **before** the copy starts, so it
  cannot hold up the next save.
- **Failure never fails the save.** A `public:<sid>` record in the Durable Object's storage is written before the first attempt; if the
  attempt does not finish (R2 hiccup, eviction) the job sweep retries it every pass. 4 attempts in all (counted when one starts), then
  `public_state = 'failed'`: the original stays private and the owner can still host it by hand (`POST /library/items/<id>/publish`).
  A session that expired or vanished is `'failed'` at once. A save whose hosting already exists (an earlier attempt copied the file but
  died before recording it) just records the existing copy: nothing is copied twice. Without the public bucket wired, `'failed'`.
- **An upload that gets no session** (an image: `png`, `jpeg`, `webp`, `heic`; or a video whose adopt was refused, e.g. `busy`) is hosted
  by the same call, inline, with `POST /library/items/<id>/publish`'s own code (`libraryPublish`): `public_state` `'ready'` with
  `public_url`, or `'failed'` (the private upload stays; still `201`). Known gap, as for route 5c: such a copy has no session, so it is
  listed as a second post next to its private upload.
- **Responses (all additive).**
  - `GET /studio/<sid>` (and the Durable Object's advance reply, the Worker's D1 answers and its fallback): `public_state`
    (`null | "pending" | "ready" | "failed"`) and `public_url` (`string | null`), always present, `null` when never asked.
  - `PUT /studio/upload` `201`: the same two keys.
  - `GET /library`: each post gains `public_url` (the newest `host` file's URL, else `null`); the hosted copy is also a normal file
    (`kind "public"`, `source "host"`, `url`) in `files`, as it always was for a published original.
- **Unchanged**: a session's lifetime (7 days), `POST /studio/<sid>/publish`, the web studio page, the web library.

### 13.3 Posters

- **What gets one**: the private ORIGINAL of a video or gif (`content_type` `video/*` or `image/gif`): a saved link, an upload. The
  public copy hosted from it shares the original's poster object. **Webps get none** (decision): ffmpeg here cannot decode animated
  WebP (LIBRARY-CONTRACT conversion rules), and a webp is its own picture. Images need none.
- **Picture**: one JPEG, `-q:v 4`, frame at **10 % of the duration, at most 3 s in** (0 when the duration is unknown), longer side at
  most **720 px** (never upscaled, rotation metadata applied so a phone clip is upright, square pixels, 4:2:0). Tens of KB (14 to 17 KB for the test clips).
  A frame past the end of a clip whose container over-reports its duration is retried at the very start.
- **Where**: the PUBLIC bucket `cobalt-media`, name `<10 base62>.jpg` (unguessable; never matches `DELETE /media/<name>`'s
  `.webp` pattern), `content-type: image/jpeg`, `cache-control: public, max-age=31536000, immutable`, custom metadata
  `poster: "1"`, `itemId`, `createdAt`. The URL is recorded in `media_items.poster` (the original's row) and mirrored on every session
  of that original (`studio_sessions.poster`, matched by `r2_key`) and on the `host` rows hosted from those sessions. **The poster of a
  private video is therefore public** (an unguessable URL), by the owner's decision.
- **Helper** (`helper/server.js`, `helper/lib.js`): `POST /poster?id=<16..32 alnum>`, body = the video bytes (streamed to
  `/tmp/poster/<id>/in`, at most 200 MB), `x-internal-key`. It probes (no video stream: `400 error.studio.not_video`), runs ffmpeg
  once (30 s budget), deletes the directory, and answers `200 image/jpeg` with `content-length`. Errors: `413 error.studio.too_large`,
  `422 error.poster.failed` (no frame, a hung or failing ffmpeg, an empty or over-2 MB file), `429 error.webp.busy` (**one job at a
  time**, the same rule as `/probe`: a poster holds the helper like a job does), `502 error.studio.upload_failed`.
- **When (never delays `ready`)**: `ready` only writes a `poster:<item id>` record into the Durable Object's storage and arms the job
  sweep. The sweep makes **one poster per pass**, oldest first, and only while the helper is free (no save in flight, no encode; a
  `429` from the helper also counts as "not now" and is not an attempt, up to 10 minutes). A render, save or upload that arrives while
  a poster is being made **waits for it** (at most 20 s) instead of finding the helper busy. Typical delay from `ready` to a poster:
  the sweep cadence (5 s) plus a second or two of ffmpeg.
- **Retries**: 3 helper attempts per job (counted when one starts, so a poison file cannot loop), then `poster_at = now` and the job
  is dropped; a refusal for good (4xx from the helper: not a video, no frame) gives up at once. The lazy backfill skips a row for 24 h
  after `poster_at`.
- **Existing saves, lazily or in one go** (no migration data step):
  - **a library read** (`GET /library`, and the web's `GET /api/library`) that shows an original with no poster (and not tried in the
    last 24 h) asks the Durable Object to queue it: one internal call (`POST /posters/kick`, 1.5 s cap, errors swallowed), which only
    writes records (up to 25 newest first). The container is not woken by the call, only by the sweep that follows;
  - **`POST /library/posters/backfill[?limit=1..100]`** (keyed, or the service header): the same kick, default 25, answers
    `200 {"status":"success","queued":<new>,"eligible":<all rows still without a poster and out of cooldown>}`. Call it until
    `eligible` is 0 (the sweep drains the queue meanwhile). No CORS, `cache-control: no-store`;
  - **the daily cron** (03:23 UTC, the telemetry retention's trigger) kicks up to 100.
- **Responses (all additive)**:
  - `GET /studio/<sid>` (and the other session answers): `poster_url` (`string | null`).
  - `GET /library`: each post gains `poster_url` (the original's, else any file's), each file gains `poster_url`; the item shape
    returned by `PUT /studio/upload` and the web's `itemShape` gain `poster_url`. `null` until made, always `null` for webps.
  - web `GET /api/library`: items and studios gain `poster_url`; the page uses it as the tile picture (a small `<img>` instead of a
    `<video>` or a lock icon), falling back to what it showed before if the image does not load.
- **Not done**: no re-encode of an existing poster, no poster for webp/png/jpeg/heic, no poster from the helper's held copy of a
  fresh link save (the video is streamed from R2 again: one more R2 read and one container upload per save; fine at this size, a
  possible later optimisation).

### 13.4 Deleting

- **`DELETE /library/items/<id>/post`** (section 12) deletes the posters of the rows it deletes: after every row of the post is
  soft-deleted, each distinct `poster` URL among them is released. **A poster object is deleted only when no live row still names it**
  (the original and its public copy share one: deleting the last of them removes it); a row that stayed live in `remaining` keeps its
  poster until the retry. Only objects named like a poster (`<10 base62>.jpg`) are ever deleted through the column. A failed poster delete
  is logged, not reported (`200` / `502 partial` keep their meaning); the object is then an orphan nothing lists (tens of KB).
- **The web library's `DELETE /api/library/items/<id>`** does the same for its one row (and the host copy keeps the shared poster until
  it is deleted too). The web's `POST /api/library/items/<id>/publish` copies the poster URL to the new `host` row.
- **Per-file deletes**: `DELETE /media/<name>.webp` (webps have no poster) is unchanged and a poster name is a `404` at the gate.
- **Lifetime paths**: nothing that expires or sweeps ever deletes media. The 7-day session expiry keeps the original (the library's
  gallery), so its poster stays; the job sweep deletes no object; the 30-day retention (`runTelemetryRetention`) only touches telemetry
  rows and `telemetry/...` crash objects. `test/poster-delete.test.ts` pins every `.delete(` on a bucket in `src/` so a new deletion
  path cannot appear without a review against posters.
- **`scripts/backfill-library.mjs`** (the one-off library backfill) skips objects whose custom metadata says `poster: "1"`: they are
  not library files. (A hosted `.jpg` image has the same name shape, so the metadata, not the name, decides.)

### 13.5 Files and tests

New: `d1/migrations/0006_posters_public.sql`, `api/src/poster.ts` (`PosterService`: queue, sweep, job, kick, `idle`),
`api/test/{poster,public-default,poster-delete,poster-helper,migration-0006}.test.ts`, `api/test/poster-world.ts`,
`api/test/fixtures/clip-*.mp4|gif` (six small clips, 140 KB in all). Edited: `api/helper/{lib,server}.js` (`posterTime`,
`buildPosterArgs`, `POST /poster`), `api/src/{studio,publish,library,app-routes,gate,worker,index}.ts`, `api/test/{studio-fakes,
library,gate,backfill}.test.ts` (the fake helper answers `/poster`; the expected shapes gain the new keys), `scripts/backfill-library.mjs`,
`web/src/library.ts`, `web/src/library/page.html` (+ the generated embed), `web/test/library.test.ts`, `README.md`.

Code map: `studio.ts` (`create`/`adopt` parse `public`; `afterReady`, `hostPublic`, `kickPosters`; `sweep` runs the public retries and one
poster; `sessionBody` adds the three keys; `/posters/kick` in `handleStudioRoute`), `poster.ts`, `publish.ts` (the host row copies the
session's poster), `library.ts` (`releasePoster`, `poster` in `insertMediaItem`), `app-routes.ts` (the flag on upload, `poster_url` and
`public_url` in `GET /library`, the lazy kick, `libraryPostersBackfill`, poster release in `libraryPostDelete`), `gate.ts` and `worker.ts`
(`library_posters_backfill`), `index.ts` (the public bucket into `StudioService`, `/poster` in the helper call budget, the cron kick).

Tests (real SQL on `node:sqlite` over every migration; the helper's HTTP API against the REAL ffmpeg on the fixture clips and against a
scripted stand-in): poster generated and recorded (original row, session mirror, public copies), never inside the save, one job per
pass, busy/retry/give-up/cooldown, deleted-meanwhile guard, render/save waiting for a poster, the lazy kick and the backfill route (gate,
auth, limits), `poster_url` in every response, `public` on link and upload (video, image, refused adopt), absent flag = today's, failure
and retry and recovery of the public copy, shared poster refcount on delete, lifetime paths, the migration on top of 0005. The real-ffmpeg
half skips itself when no ffmpeg is found (`FFMPEG_PATH` or `ffmpeg` on the PATH).

### 13.6 Deploy (owner; not run by the lane)

1. **Migration first**: `cd deploy/cloudflare/web && cf d1 migrations apply 42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir ../d1/migrations`
   (the GLOBAL `cf`). Additive; the running Workers keep working on it.
2. **API**: `deploy/cloudflare/api/prepare-git-info.sh`, then `cd deploy/cloudflare/api && cf deploy --secrets-file ~/.config/cobalt/secrets.json`.
   The helper changed, so the deploy restarts the container once.
3. **Web**: `deploy/cloudflare/build-web.sh`, then `cd deploy/cloudflare/web && cf deploy --secrets-file ~/.config/cobalt/secrets.json`.
4. **Backfill** (optional, the library read and the cron do it lazily): `curl -X POST -H "Authorization: Api-Key <key>"
   https://api.capybaraharmony.com/library/posters/backfill?limit=100` until `eligible` is 0.
5. **Verified on the image**: the container image the dry run built (linux/amd64 under emulation, ffmpeg-static) ran the real helper's
   `POST /poster` on the six fixture clips: 200 `image/jpeg`, 720x405 (1080p), 640x360, 360x640 (portrait and the rotation-tagged clip),
   200x120 (gif), 64x64, 5 to 17 KB each, 0.3 to 1.6 s each (emulated, on a heavily loaded machine).
   **Unverified until deployed**: a poster write and the R2 to R2 copy from inside the Durable Object (the same R2 calls the Worker
   already makes), and the real timings (poster delay after `ready`, hosting time for a large file).

## 14. Instant share: `notify` and `origin: "share"` on `POST /studio`, and `GET /studio/recent` (addendum, built 2026-10-05; `apple/CONTRACT-SHARE-QUICK.md` section 9)

Why: the share extension shows nothing that waits (owner: "maybe we remove the share screen entirely with a notification"). It
queues ONE background `POST /studio` and goes. The server has to do on that single call what the sheet used to do in three
(create, `PUT .../notify`, hand the original off), and the app has to be able to find what the extension created without sharing a
file with it (a build re-signed without the app group has no shared container). All of it is **additive and backward compatible**:
no existing route, status code, error code or response key changes; an older client sees nothing new, an older server ignores the
new fields (and the app then learns it from the missing capability flag). `GET /capabilities` gains `features.create_notify: true`
(missing = `false`) for all three pieces below.

### 14.1 `POST /studio` takes `notify` and `origin`

```json
{ "url": "https://www.instagram.com/p/Dc2QA4ng-US/", "public": true, "origin": "share",
  "notify": { "on": ["saved", "failed"], "label": "instagram · Dc2QA4ng-US" } }
```

- **`notify`** (optional; absent and `null` = today's behaviour): the body of `PUT /studio/<sid>/notify` (section 9.2), validated by the
  SAME parser (`parseOptIn`): an object, `on` = 1 to 8 entries from `saved` / `rendered` / `failed` (repeats folded), `label` optional (at
  most 60 characters, no control characters), at most 1024 bytes once serialised. Anything else is
  `400 {"status":"error","error":{"code":"error.notify.invalid"}}` and **nothing is created** (no row, no record, no helper call). The
  opt-in is registered **after the session row exists and before the save can move**, through the same service call as the PUT route
  (so the stored record, its 24 h life and its owner check are identical), which means an instant save is already announced when it
  finishes. It is validated even when the bridge is off; with the bridge off (`features.notify_bridge: false`) it is then ignored:
  nothing stored, nothing sent. A failure to store it never fails the save (the app's own poll still tells the owner).
- **`origin`** (optional): only `"share"` (a share sheet's save) is accepted; any other value, any other type is
  `400 error.studio.invalid_params`, nothing created. It does three things:
  1. the session is remembered for `GET /studio/recent` (14.2) for 24 hours;
  2. it is **never refused as busy**: a share has no one to retry a `429`, so its save queues behind the running one (a save already
     waits for the helper for up to 2 minutes and then fails with `error.studio.busy`, which the opt-in announces). A save without
     `origin` still gets `429 error.studio.busy` while another is running, exactly as before;
  3. the `201` is answered within `SHARE_KICK_MS` (1.2 s) instead of `KICK_MS` (4 s): the container's cold start (6 s measured) is left
     to the sweep, which is already scheduled by the create. The extension's request must be answered before the extension is torn down.
- **Response** `201`: `{status, id, url}` as before, plus `notify: {bridge, on, label, expires_at}` (the opt-in's answer) when `notify`
  was sent and the server has the Hark service. `bridge: false` means nothing was stored.

### 14.2 `GET /studio/recent?since=<ms>&limit=<1..25>` (keyed)

The sessions this key created with `origin: "share"` in the last 24 hours, newest first:

```json
{ "status": "success", "now": 1790000000000, "sessions": [ { "status": "saving", "id": "<sid>", "link": "...", ...the body of GET /studio/<sid> } ] }
```

- `Authorization: Api-Key <key>`; no key or a wrong one is the gate's usual `401`; the library-service credential and any method but
  `GET` are `404`; no CORS (the app sends no `Origin`); `cache-control: no-store`.
- `since`: unix milliseconds, clamped to the last 24 hours (absent or junk = 24 hours). `limit`: default and maximum 25 (junk = 25, 0 = 1).
- Only the caller's own sessions, only share-origin ones, never an expired one or a deleted row. Each element is exactly what
  `GET /studio/<sid>` answers for the session (status, link, service, title, duration, size, `public_url`, `error`, ...). Failed
  saves are listed (`status: "error"`); the client skips them.
- Why it exists: a build re-signed without the app group cannot read what the extension left, and a force-quit app is never woken for
  the extension's background request. On every foreground the app asks this route and keeps the original of what it does not have yet
  (`apple/CONTRACT-SHARE-QUICK.md` section 9). A server without the route answers `404`; the app then relies on the system's wake.
- Storage: DO storage `share:<sid>` = `{keyId, at}`, written by the create, pruned at the next share-origin create after 24 hours. No
  D1 change, no migration.

### 14.3 Files and tests

Edited: `src/studio.ts` (`create` parses and validates `notify` and `origin`, registers the opt-in through `NotifyService.put`, records the
share, `recent`, `kick` takes a cap, the route in `handleStudioRoute`), `src/gate.ts` (`/studio/recent`, `studio_recent`), `src/worker.ts`
(the DO forward next to `studio_notify`), `src/app-routes.ts` (the flag). **Not edited:** `src/notify.ts` (another lane's `url` field in
the Hark payload; `NotifyService.put` is called structurally, see `scratchpad/instant-share/requests.md`), `src/index.ts`, no migration.
Tests: `test/instant-share.test.ts` (the opt-in registered and identical to the PUT's; announced when the save finishes or fails;
every invalid shape is a 400 with nothing created; bridge off ignored; a Durable Object with no Hark service; the flag; `origin`
validated, remembered, never busy, answered within the cap; `GET /studio/recent`: ownership, order, `since`, `limit`, 24 h, gate, no
service credential, forged key-id header, expired and deleted rows), `test/library.test.ts` (the capability object).

### 14.4 Deploy (owner; not run by the lane)

API deploy only: `deploy/cloudflare/api/prepare-git-info.sh`, then `cd deploy/cloudflare/api && cf deploy --secrets-file ~/.config/cobalt/secrets.json`.
No D1 migration, no web deploy, no new secret. **Unverified until deployed:** the real timing of a share-origin `POST /studio` through the
edge on a cold container (the cap is 1.2 s; the rest is Worker and D1), and `GET /studio/recent` against the real Durable Object storage.

## 15. Custom titles: `PATCH /library/items/<id>/post`, `custom_title`, `features.titles` (addendum, built 2026-10-05; `apple/CONTRACT-LIBRARY2.md` section 6)

Why: an uploaded file is listed as `service: "upload"` with its cleaned file name, and nothing could rename a post. The app now names
a post (right after picking a file, and later from the library); the name has to live on the server so every device and the web
library show it. All of it is **additive and backward compatible**: no existing route, status code, error code or response key changes
(`GET /library` gains one key per post), no row of an existing table changes, and `title` (the file name) keeps its meaning; an
older client ignores `custom_title`, an older server simply never sends it (the app then knows from the missing capability flag).

### 15.1 Migration `d1/migrations/0007_titles.sql` (additive: one new table)

```sql
CREATE TABLE media_titles (
    post_key   TEXT PRIMARY KEY,
    title      TEXT NOT NULL,      -- 1..80 code points, trimmed, no control characters
    key_id     TEXT,               -- api_keys.id (or service:library) that set it
    updated_at INTEGER NOT NULL    -- ms
);
```

One row per **post**, keyed by the post key `GET /library` groups by (`POST_KEY_SQL`, section 5a), so the title is the same for every
file of the post (original, renders, hosted copy) and survives the deletion of any one file. No row = no custom title. Why a table
and not `media_items.name` (lane decision): a custom title must be (a) distinguishable from the default so it can be cleared, (b)
independent of whichever file row would carry it, and (c) possible for every post kind, including webp-only `/webp` posts with no
original; overwriting `name` fails all three and changes download names. **Apply it BEFORE deploying the API and web Workers** (old
code never touches it; the web library tolerates its absence, the API's `GET /library` does not).

### 15.2 `PATCH /library/items/<id>/post` (keyed)

- **Gate** (`gate.ts`, in the existing `/library/items/<id>/post` block): `PATCH` → `lookupThen(req, "library_post_title", { id })`;
  `DELETE` is still section 12; every other method on `post` is 404. `<id>` is the usual `^[A-Za-z0-9]{16}$` (else 404). Auth like the
  other library routes: `Authorization: Api-Key <key>` (D1 lookup) or the web Worker's `x-cobalt-service` (key id `service:library`);
  missing/invalid key → the existing 401 codes. Answered by the Worker from D1 alone: the container and the Durable Objects are never
  woken. No CORS (the web page does not call it).
- **Body**: JSON, at most 1024 bytes (counted as read: a streamed body is cut off at the cap), UTF-8, an object with a `title` key that
  is a string or `null`. Extra keys are ignored. Bad JSON, a non-object, a missing `title`, any other type, a body over 1024 bytes, or
  a title that fails the rules below → `400 {"status":"error","error":{"code":"error.library.bad_title"}}`, nothing stored. The body is
  judged **before** the id is looked up.
- **Rules** (identical in the app, `apple/CONTRACT-LIBRARY2.md` decision 6; the server never sees an invalid title from the app, so the
  `400` is for other callers): trim leading and trailing whitespace and line breaks (JS `trim()`); then reject any control character
  `U+0000-U+001F`, `U+007F-U+009F`, `U+2028`, `U+2029` (inside the title: a line break in the middle is a `400`, at the ends it is
  trimmed) and unpaired surrogates; at most **80 Unicode code points** (`Array.from(t).length`: an emoji is one, a combining mark is
  one). `null`, `""` and whitespace only **clear** the title.
- **Which post**: the anchor must be a **live** row (`deleted_at IS NULL`), else `404 {"error":{"code":"error.library.not_found"}}`; any
  file of the post works (saved original, webp, upload, hosted copy, a render of a reopened session). The post key is `POST_KEY_SQL`
  on the anchor, the same as `GET /library`'s `id`.
- **Effect**: non-empty → `INSERT … ON CONFLICT(post_key) DO UPDATE SET title, key_id, updated_at` (the caller's key id, or
  `service:library`; `updated_at` = now); clear → `DELETE FROM media_titles WHERE post_key = ?`.
- **Response** `200 {"status":"success","post":"<post key>","title":"<title>"|null}`, `content-type: application/json`,
  `cache-control: no-store`. **Idempotent**: the same body again gives the same answer, and clearing a post with no title is a `200`.
  `title` in the answer is the cleaned one (trimmed). D1 failure → `503 error.api.generic`.

### 15.3 `GET /library`: `custom_title`

Each post gains `"custom_title": string | null`, next to `title`; `title` is **unchanged** (the file name, which downloads and the old
clients use). One more query per page (`SELECT post_key, title FROM media_titles WHERE post_key IN (…)`); a D1 failure on it is the
same `503` as any other failure of the list (never a list that silently drops titles). A title row whose post has no live file shows
nowhere.

### 15.4 Delete and publish

- **`DELETE /library/items/<id>/post`** (section 12) also deletes the post's `media_titles` row, as a last step (4) after the files and
  the sessions' originals. **Only when every file went** (`remaining: []`): a partly deleted post (`502 error.library.partial`) keeps
  its title until the retry finishes it (a deviation from "always", chosen so a retry never leaves a live post that lost its name). A
  failure of this step is logged, not reported. Deleting one webp (`DELETE /media/<name>`) leaves the post's title.
- **`POST /library/items/<id>/publish`** (5c): when the new `host` row's post key differs from the source's (an **image** hosted from an
  upload: the copy has no session, so it is its own post, section 5a "known gap"), the source post's custom title is copied to the new
  key (`INSERT OR IGNORE`, so a title already on the copy stays). A video's host copy shares the source's post: nothing to copy. A
  failure is logged and never fails the publish. **Known gap (accepted):** a title set *after* an image was hosted does not reach the
  copy (it is a separate post); and an image hosted at upload time by `public: true` (section 13.2) is hosted before any title exists.
  The app titles the post it sees in the library; the web library shows each file's own post title.

### 15.5 Capability

`GET /capabilities` gains `features.titles: true` (`app-routes.ts` `capabilities()`, next to `delete_post`). Absent = false: the app
shows no title sheet and renames on the device only.

### 15.6 Web library (lane W, optional, done)

`GET /api/library` (the web Worker's own list, `web/src/library.ts`) gives each **item** `custom_title` (the title of the item's post,
same post key SQL; `name` unchanged), and the page shows it in place of the file name on the tile. The lookup is a separate, best
effort query: without the table (`0007` not applied yet) or on a D1 error the page shows file names and the list is still a `200`.

### 15.7 Files and tests

Edited: `src/gate.ts` (`library_post_title`), `src/app-routes.ts` (`libraryPostTitle`, `parseTitle`, `custom_title` in `libraryList`,
the delete step, `copyTitle` in `libraryPublish`, the flag), `src/worker.ts` (the dispatch, answered like the delete: no CORS, no log
row). New: `d1/migrations/0007_titles.sql`. Web: `web/src/library.ts`, `web/src/library/page.html` (+ regenerated
`page.generated.ts`). Not edited: `studio.ts`, `notify.ts`, `PUT /studio/upload` (the title is sent after the upload answers, with its
item id), `POST /studio`.
Tests: `api/test/titles.test.ts` (migration additive and applying over data; the validation table; PATCH: set, replace, clear with
`null` and whitespace, idempotent, trim, exactly 80 code points with emoji, 81, control characters, bad JSON / number / missing key /
array / too large / not UTF-8, the 1024-byte boundary and a streamed body, anchors on every file of every post kind, unknown and
soft-deleted anchors, D1 down, key / service / ids / methods / no CORS; `GET /library` titles on the right post only, across pages,
one query, orphan rows, D1 down; delete-post removes it, partial keeps it, a failing delete is quiet; publish copies to an image host,
leaves a video alone, never fails the publish; the flag), `api/test/gate.test.ts` (the PATCH decision), `api/test/library.test.ts` (the
capability object), `api/test/migration-0006.test.ts` (no longer pins 0006 as the last migration), `web/test/library.test.ts` (item
shape, titles by post, no table, the page).

### 15.8 Deploy (owner; not run by the lane)

1. Migration first (from `deploy/cloudflare/web`, with the global `cf`): `cf d1 migrations apply 42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir ../d1/migrations`.
2. API: `deploy/cloudflare/api/prepare-git-info.sh`, then `cd deploy/cloudflare/api && cf deploy --secrets-file ~/.config/cobalt/secrets.json`.
3. Web (only for the library page's titles): `cd deploy/cloudflare/web && cf deploy`.

No new secret. **Unverified until deployed:** the real D1 (the tests run the same SQL on `node:sqlite`), and the web page's tile in a
browser (the page's one-line change is only asserted as text, not rendered).


## 16. One file per rendition, public or private (addendum, built 2026-10-05; `apple/CONTRACT-VISIBILITY.md`)

Owner: "there shouldnt be seperate private and public of the same media it should just be a toggle". A library row is now the media
file; "public" is a mirror object in `cobalt-media` at the row's stable `public_key`, owned by the same row. Everything below is
additive for clients (old apps keep working, section 16.6).

### 16.1 Migration `d1/migrations/0008_visibility.sql` (additive: four nullable columns, two indexes)

`media_items.visibility` (`'public'|'private'`, NULL = not migrated: read as `bucket = 'media'` -> public, else private),
`public_key` (the key of the public mirror in `cobalt-media`, kept after the row turns private so the same link comes back),
`public_id` (the 16-base62 id old clients know the public file by: the retired host row's id after the merge, minted at the first
publish otherwise; NULL for webps), `merged_into` (on a retired host row: the original it became). Indexes on `public_id`, `public_key`.
Apply BEFORE deploying the Workers (old code names its columns). `kind`, `bucket`, `r2_key` keep their meaning (where the canonical
bytes live); `url` is set exactly while the row is public.

### 16.2 `PATCH /library/items/<id>/visibility` (keyed or service)

Body `{"public": true|false}` (JSON, at most 256 bytes, extra keys ignored; anything else `400 error.library.bad_request`, judged
before the lookup). `<id>` is an item id OR a `public_id`. Answered by the Worker (D1 + R2); `no-store`, no CORS.

- Unknown or deleted -> `404 error.library.not_found`. A legacy `host` row (unmerged) -> `409 error.library.not_toggleable`. Toggleable:
  every `bucket 'originals'` row and a webp (`source webp|studio`) in the public bucket.
- A not-yet-merged pair is merged first (the data step's rule, 16.4), so the window between deploy and migration never mints a second mirror.
- **ON**: `key = public_key ?? <10 base62>.<ext>`; if the object at `key` is missing or its size differs, copy the original there
  (`cache-control: public, max-age=3600`, custom metadata `mirror: "1"`; a copy of the wrong length is deleted, `502`); original missing
  `404 error.library.missing`, R2 failure `502 error.library.storage`, row unchanged in both. Only then `UPDATE ... visibility='public',
  public_key, public_id, url`, sync `studio_sessions.public_state/public_url`, purge the URL (clears a cached 404).
- **OFF**: delete the object at `public_key` FIRST (a failure is `502`, the row stays truthfully public), then `visibility='private', url=NULL`
  (`public_key` and `public_id` kept), clear the sessions' `public_state/public_url`, purge the old URL.
- One reconcile pass at the end (re-read; public with no object -> copy once; private with an object -> delete once) so racing calls converge.
- **Response** `200 {"status":"success","item":<v2 file 16.5>,"cache_cleared":true|false|null}`. `cache_cleared` reports an OFF's purge
  (`null`: nothing to purge or purge not configured; `false`: the API call failed). Idempotent: on when on, off when off do no copy or delete.
- **Purge** (`MEDIA_PURGE_TOKEN` secret + `MEDIA_ZONE_ID` var, `api/cloudflare.config.ts`): `POST https://api.cloudflare.com/client/v4/zones/<zone>/purge_cache`
  `{"files":[url,...]}` (30 per call), bearer token, 3 s cap. Never fails a toggle; unconfigured it is `null`.
- **Webps (owner)**: a webp's bytes live only in the public bucket, so its first OFF copies them to `cobalt-originals/webps/<name>` (verified with
  `head`), converts the row to `bucket 'originals'` with `public_key = <its public name>`, and then deletes the public object. ON copies back
  to the SAME name; the private copy is KEPT (later toggles never copy to the private side again; delete removes both). New renders stay public.

### 16.3 Capability and the other routes

- `features.visibility: true`.
- `POST /library/items/<id>/publish` and `POST /studio/<sid>/publish` are the legacy spelling of ON on the original's row: same `201 {status,url,bytes,content_type,item_id}`
  (`item_id` = the `public_id`), a repeat returns the same link and copies nothing; a `bucket 'media'` row is `409 error.library.already_public`.
  A ready session whose library row was never written (the insert is bookkeeping) gets its row written first. The 7-day session expiry no longer refuses it.
- `public: true` on `POST /studio` and `PUT /studio/upload?public=1` run the same ON (a hosted image is now one row, one post).
- `GET|HEAD .../file`, `POST .../studio`, `PATCH|DELETE .../post` resolve a `public_id`.
- `DELETE /library/items/<id>/post` also deletes each row's mirror (`public_key`) and purges the public URLs (best effort).
- `DELETE /media/<name>.webp` of a webp switched private once deletes both copies (Worker-side), otherwise the webp service as before.
- Session bodies (`GET /studio/<sid>`, `/studio/recent`) gain `item_id` and `visibility` (the original's row, else null).

### 16.4 `POST /library/visibility/migrate?dry_run=1|0&limit=1..100&undo=0|1` (keyed or service)

The data step: dry run unless `dry_run=0`; `limit` (default 25) pairs per call; D1 writes only, R2 is only read (`head`), no object is ever
written or deleted. Candidates = live `host` rows joined to their session's `r2_key` -> the one live original. One D1 `batch` per pair:
the original takes the host's `public_key/public_id/url` (and its poster when it has none), the host row is retired (`deleted_at`,
`merged_into`; the tombstone is the rollback record), the session says `ready`. Skips (reported, never guessed): `no_original`,
`several_originals`, `several_hosts` (the newest is NOT picked), `object_missing`, `size_mismatch`, `storage_error`. After the last page
every row with `visibility IS NULL` gets `public` (bucket media) or `private`. Idempotent (`already_merged` counts the tombstones).
Response `{status,dry_run,undo,report{rows_live,originals,hosts_live,webps,merge{pairs,saved,upload,already_merged},skipped{...},
after{rows_live,public,private,tombstones},visibility_unset,posters_missing,r2_writes:0,r2_deletes:0[,processed,backfilled]},items[],remaining}`.
**`undo=1`** (also dry-run by default): restores each tombstone and clears the original's four columns, inserts the host row old code expects
for an original the new code made public, then (last page) sets `visibility` back to NULL; byte-for-byte for the rows (replay test). A webp
that was switched private has no pre-0008 shape: undo leaves it and reports `webps_switched` (make them public before a code rollback).
Rollback order: `undo` until `remaining: 0`, THEN redeploy the old Workers.

### 16.5 `GET /library`: `v=2`, `visibility`, legacy synthesis

- Every real file gains `visibility` and `visibility_toggle` (both shapes, additive). `?v=2`: one entry per live row, `url` is the public URL while
  public else null, posts gain `visibility` (the original's, else public if any file is). `media_name`/`deletable` for webps are the public name
  (also when switched), an original's stay null/false.
- Without `v` (old apps): the original is `url: null` as before and each public original is followed by a synthesized `host` file (id = `public_id`,
  `kind 'public'`, `source 'host'`; for a merged pair every field, including name, size and time, comes from the retired host row, so the
  list is the one they always saw). A private webp is left out (old apps have no word for it; a webp-only post vanishes).
- `counts.files` counts what the shape lists (86 after the merge in the v2 shape; legacy counts the live rows); `usage.public_bytes` = live
  effective-public rows, `usage.private_bytes` = live `bucket 'originals'` rows (a public original counts in both).

### 16.6 Deploy (owner; not run by the lane)

1. `cd deploy/cloudflare/web && cf d1 migrations apply 42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir ../d1/migrations`
2. `MEDIA_PURGE_TOKEN` is in `~/.config/cobalt/secrets.json`; `MEDIA_ZONE_ID` is in `api/cloudflare.config.ts`.
3. API: `deploy/cloudflare/api/prepare-git-info.sh`, `cd deploy/cloudflare/api && cf deploy --secrets-file ~/.config/cobalt/secrets.json`; then web: `deploy/cloudflare/build-web.sh`, `cd deploy/cloudflare/web && cf deploy --secrets-file ~/.config/cobalt/secrets.json`.
4. Dry run: `curl -X POST -H "Authorization: Api-Key <key>" 'https://api.capybaraharmony.com/library/visibility/migrate?dry_run=1&limit=100'` -> 6 pairs (5 saved, 1 upload), 0 skipped, after 86 / 35 / 51 / 6 (replayed on a copy of the real database).
5. Apply: the same with `dry_run=0`, until `remaining: 0`; a second `dry_run=0` reports `already_merged: 6`.
Tests: `api/test/{visibility,visibility-migrate,migration-0008}.test.ts` (+ `visibility-fixture.ts`, `d1-batch.ts`), `replay-prod.test.ts` (skipped
unless `VIS_REPLAY_DIR` holds a D1 export and two bucket listings). **Unverified until deployed:** real R2-to-R2 copy time for a large file
inside a Worker request, that a zone purge by URL clears R2 custom-domain cache for mp4s, the real D1 `batch`.

## 17. The server's line: queued saves and renders that finish with every client gone (addendum, pinned 2026-10-06; `apple/CONTRACT-PARALLEL.md` section 7)

Owner (2026-10-06): the links waiting when he leaves cobalt must finish with the app closed, and "2nd in line" must count every
client. The helper does one save, probe, encode or poster at a time (`helper/server.js:178` `busy()`), and there is exactly one
Durable Object for everything (`src/index.ts:331`, `getContainer(env.COBALT, "main")`), so that one object can hold one honest line
for the share sheet, the app on every device, the app's Shortcuts actions and the web studio page. Design lane; **built 2026-10-06
(lane S1, not yet deployed; where the build differs from this text, `README.md` "The server's line" says so)**. Code read on 2026-10-06 (`studio.ts`, `webp.ts`, `studio-edge.ts`, `sweep.ts`, `notify.ts`, `gate.ts`, `worker.ts`,
`app-routes.ts`, `helper/server.js`, `helper/lib.js`); line numbers are from that read.

All of it is **additive and backward compatible**: a client that sends nothing new sees what it saw before (one exception, the share
sheet, which is better off: 17.3). No D1 migration: the line lives in Durable Object storage, the rows it creates are ordinary
`studio_sessions` / `studio_renders` rows.

### 17.1 What changes, per caller

| caller | today | with the line |
|---|---|---|
| app with `features.line` (`"queue": true`) | `429 error.studio.busy`, retries every 3 s for 60 s (`PipelineFlows.swift:69-84`) | `201` at once with `queued: true` and its place; the save starts when its turn comes, polled or not |
| share sheet (`origin: "share"`) | never refused; its `save:` record retries the helper every 2 s for up to 120 s, first to retry wins (`studio.ts:761-766`, `:1102-1115`), then `error.studio.busy` | implicitly queued: the same `201` (plus `queued`, `queue_ahead`), first in first out, 30 min ceiling (17.6) |
| app render with `"queue": true` | `429 error.webp.busy` while a save runs (`studio.ts:1617`); the app fails `renderBusy` at once | `202` with the job id at once, `phase: "queued"` until it starts |
| old app, web studio page, the macOS Shortcuts in `shortcuts/` (no `queue`) | `429` while a save or encode runs | `429` while the helper is held **or anything waits in the line** (fairness: they never jump it). Same codes, same shapes |
| `PUT /studio/upload` / `POST /library/items/<id>/studio` | busy adopt → `201` with `studio_error` / `429` | with `?queue=1`: the adopted session joins the line instead |
| `/library/adopt` (web Worker, service) | unchanged | unchanged (never queues) |
| `POST /webp` (URL jobs) | unchanged | unchanged (not in the line; its `job:` record still counts as the helper being held, 17.2) |

### 17.2 Storage, order, and "held"

- **Entries**: DO storage key `line:<class>:<seq>` → `LineEntry`. `<class>` is `0` for a render asked with `"priority": "focused"`,
  `1` for everything else; `<seq>` is a 12-digit zero-padded counter kept under `lineseq` (not under the `line:` prefix). Durable
  Object `list()` returns keys "in ascending sorted order based on the keys' UTF-8 encodings" (Cloudflare storage API docs, read
  2026-10-06), so `list({prefix: "line:"})` IS the order: focused renders first, then everything else first in first out. No index:
  every lookup lists and scans (at most `LINE_MAX` = 50 entries).

```ts
// src/line.ts (new, no Cloudflare imports: runs under plain node in the tests)
export type LineEntry = {
    kind: "save" | "render";
    sid: string;                       // the studio session (a queued save's row exists, status 'saving')
    job: string | null;                // render: the job id, minted at enqueue (webp.ts `mintId`, 20 base62)
    keyId: string;                     // who asked (api_keys.id; the share sheet's key)
    at: number;                        // enqueued, ms
    origin: "share" | null;
    adopt: boolean;                    // a save that is an adopted upload: it starts in phase "probing"
    render: { params: WebpParams; effectiveWidth: number; quality: string; start: number; length: number } | null;
    starting: number | null;           // a render whose upload into the helper began at this time (17.5)
    attempts: number;                  // starts that met a foreign 429
};
export const LINE_MAX = 50;
export const LINE_WAIT_MS = 30 * 60 * 1000;
export const LINE_BUSY_WAIT_MS = 10 * 60 * 1000;
export const LINE_START_STALE_MS = 6 * 60 * 1000;   // = SWEEP_RENDER_MS
export class LineStore {               // over the DO's KV (`StudioDeps.storage`)
    constructor(storage: KV, now: () => number);
    list(): Promise<Array<{ key: string; entry: LineEntry }>>;
    enqueue(e: Omit<LineEntry, "starting" | "attempts">, focused: boolean): Promise<{ key: string } | { full: true }>;
    find(sid: string, job?: string | null): Promise<{ key: string; entry: LineEntry; index: number } | null>;
    remove(key: string): Promise<void>;
    put(key: string, e: LineEntry): Promise<void>;
}
```

- **Held** (`StudioService.held()`, replacing the `saveActive() || encoding()` pair at `studio.ts:764`, `:1460`, `:1617` for the
  free/not-free decision): any `save:<sid>` record; any `job:<id>` record without `result:<id>` accepted within `SWEEP_RENDER_MS`
  (durable, so it survives an eviction, unlike the in-memory `encodes` map, which is still consulted); a poster in flight (the
  `PosterService` reports it); a render entry with `starting` younger than `LINE_START_STALE_MS`. Returns what holds it:
  `{kind: "save"|"render"|"webp"|"poster", sid?, job?} | null`.
- **Free for a request** = not held AND no entry that would go before it: for a save or an unprioritised render, an empty line; for a
  focused render, no class-`0` entry. Only then does a request take today's immediate path. A share-origin save that finds the
  helper free still takes today's path (a `save:` record and the 1.2 s kick).
- Since every non-free create now waits in the line instead of writing a `save:` record, there is at most one `save:` record at a time
  (the busy retry in `startFetch` stays for a race with a `/webp` job or a poster, 17.5).
- **Posters yield**: the poster service's `helperBusy` (`studio.ts:571`) also answers true while the line is not empty, so a poster is
  never cut while somebody waits.

### 17.3 Joining the line

**`POST /studio`** gains three optional fields (validated before anything is created; anything invalid creates nothing):

```json
{ "url": "https://www.instagram.com/reel/Dd7P496wolG/", "public": true, "queue": true,
  "title": "the good part", "notify": { "on": ["saved", "failed"] } }
```

- `queue`: boolean (absent, `null`, `false` = today). Any other type: `400 error.studio.invalid_params`. `origin: "share"` implies it.
- `title`: optional string or `null`, the rules of section 15.2 (trimmed, no control characters, at most 80 code points; empty or
  whitespace = none). Invalid: `400 error.library.bad_title`. Stored at create as the post's custom title (`media_titles`, post key =
  the new session id, which is the post key of a saved link's original, `POST_KEY_SQL`): a title row with no live file shows nowhere
  (15.3), so the row is written at once and deleted when the save fails or is cancelled. Exists for the Shortcuts actions, which may
  not live long enough to send `PATCH .../post` after the save.
- Not free and queued: the `studio_sessions` row is inserted (`status 'saving'`, as today), the opt-in of `notify` is registered as
  today (14.1), a line entry is written, **no** `save:` record, **no** kick, `scheduleSweep()`. Answer `201`:
  `{status, id, url, queued: true, queue_ahead: <n>, notify?}`. Free: today's path and `{..., queued: false, queue_ahead: null}`.
- Line full (`LINE_MAX` entries, all keys): `429 error.studio.line_full`, nothing created (also for a share; the extension already
  shows a failed share, `CobaltShare/InstantFailure.swift`).
- Not free, not queued: `429 error.studio.busy` (today's code).

**`POST /studio/<sid>/render`** gains `queue` (boolean, same rule) and `priority` (`"focused"` or absent/`null`; anything else, or
`priority` without `queue`, is `400 error.webp.invalid_params`). Validation is today's (`validateRender`, crop included) and happens
first. Not free and queued: the job id is minted here, the `studio_renders` row is inserted `pending` (as today at `studio.ts:1647`),
`"notify": true` registers the job's opt-in now (`optInJob`, the job id is known), and the entry carries the validated params. Answer
`202 {status: "pending", job, queued: true, queue_ahead}`. Free: today's path plus `queued: false, queue_ahead: null`. Not free, not
queued: `429 error.webp.busy`. `WebpService.createFromUpload` (`webp.ts:362`) takes an optional pre-minted `id` (else `mintId` as
today, `webp.ts:375`). With `queue`, a `429` from the helper on the free path (a race with a `/webp` job or a poster that `held()`
did not see) does not reach the client: the request is enqueued instead (`202`, `queued: true`), in its class's order. A queued save
needs no such rule (its started save retries the helper inside `startFetch`).

The focused rule: **a render the owner asked for from the screen goes ahead of every waiting save** (and behind earlier focused
renders); it never interrupts what runs. The app sends `priority: "focused"` for every render it starts from a planet (renders exist
only for the focused job, `apple/CONTRACT-PARALLEL.md` 5.3); its Shortcuts action does not.

**Uploads**: `PUT /studio/upload?...&queue=1` and `POST /library/items/<id>/studio?queue=1` pass `queue: true` into the internal adopt
body (`/studio/upload/adopt`; the public gate still answers 404 for it). `adopt()` (`studio.ts:1423`): free → today; not free and
queued → the session row (`service 'upload'`) and an entry with `adopt: true`; the upload answer is `201` with `id` = that session,
`studio_error: null`, plus `queued: true, queue_ahead`; the item route answers `201 {status, id, url, queued, queue_ahead}`. Without
`queue=1` both behave as today. `PUT /studio/upload` also takes `title=<url-encoded>` (15.2 rules, judged with the other query checks
before the body is read: `400 error.library.bad_title`); it is written for the post key of the new upload row (its item id) right
after the row insert, best effort (logged, never fails the upload).

### 17.4 Reading the line

- **`GET /studio/<sid>`** (and every session body: the DO's advance reply, `/studio/recent`) gains `queue_ahead: number | null`;
  `step` gains the value `"queued"`. For a session whose save waits in the line: `status: "saving"`, `step: "queued"`, `step_bytes` /
  `step_total` null, `waking: false`, `queue_ahead` = the jobs that will run before it, **the one running now included** (`1` = it is
  next; the app shows "2nd in line"). Otherwise `queue_ahead: null`. Old apps decode an unknown `step` as "not said"
  (`apple/CobaltKit/.../Models/Wire.swift:127`).
- **Render pending** (`GET /studio/<sid>/render/<job>`): `{status: "pending", job, phase: "queued", frames_done: null, frames_total:
  null, queue_ahead}`; `queue_ahead` is null on every other pending answer. Old apps map an unknown `phase` to nil
  (`HTTPCobaltClient.swift:371`).
- **`GET /studio/recent`** (14.2): unchanged rules (share-origin sessions of this key); a queued one shows `step: "queued"` and its
  `queue_ahead`. App-queued sessions are not listed: the app knows its own session ids.
- **`GET /studio/line`** (new, keyed; the library-service credential and other methods: 404; `cache-control: no-store`; never wakes the
  container):

```json
{ "status": "success", "now": 1790000000000,
  "running": { "kind": "save", "mine": false, "sid": null, "job": null, "origin": "share", "key_name": "iphone" },
  "entries": [
    { "position": 2, "kind": "save", "mine": true, "sid": "<sid>", "job": null, "at": 1789999990000,
      "origin": null, "priority": null, "key_name": "mac", "link": "https://www.instagram.com/reel/Dd7P496wolG/" },
    { "position": 3, "kind": "render", "mine": false, "sid": null, "job": null, "at": 1789999995000,
      "origin": null, "priority": null, "key_name": "iphone", "link": null }
  ],
  "max": 50, "wait_ms": 1800000 }
```

  `running` is `held()` (null when free; `kind` `"save" | "render" | "webp" | "poster"`). `position` counts the running job as 1st.
  `sid`, `job` and `link` only for the caller's own work (`mine`, by key id); `key_name` is `api_keys.name` (one `SELECT id, name FROM
  api_keys WHERE id IN (...)`), `null` for the service key or an unknown key. D1 failure: the answer still comes, with `key_name: null`.

### 17.5 Starting the next one (the pump)

`StudioService.pumpLine()`: if `held()` → nothing. Else take the first entry:

1. **Stale**: older than `LINE_WAIT_MS` → expire it (17.6) and look at the next. Its session row gone, expired or no longer `saving`
   (a save) / its render row not `pending` → drop the entry silently and look at the next.
2. **Save**: write `save:<sid>` = `{phase: adopt ? "probing" : "starting", startedAt: now, attempts: 0, lastAdvance: now, lined: true,
   queuedAt: entry.at}`, THEN remove the entry (a crash in between leaves a started save and an entry the next pump drops because the
   row's `save:` record exists), then `kick(sid)` (capped at `KICK_MS`). From here it is an ordinary save: the sweep advances it, a poll
   advances it, every existing rule applies. One difference: a `lined` record that meets a foreign `429` at `startFetch`
   (`studio.ts:1110-1114`) or `probeStep` (`:1541-1548`) keeps retrying for `LINE_BUSY_WAIT_MS` (10 min) instead of `BUSY_WAIT_MS`.
3. **Render**: persist `starting: now` on the entry (and remember it in memory), then `createFromUpload("studio:<sid>", params, getUpload,
   {id: job})` exactly as `render()` does (keep-awake renew included). `202` → `encodes.set(job)`, remove the entry, `liveRender accepted`.
   `429` → clear `starting`, `attempts + 1`, leave it at the head (the next pass retries; the 30 min ceiling bounds it). Any other
   failure → `UPDATE studio_renders SET status 'error', error_code` (the code from the reply, else `error.webp.unavailable`), the
   render's notify/live failed hooks, remove the entry, continue with the next.
   A `starting` entry older than `LINE_START_STALE_MS` with no in-memory mark (the DO was evicted mid-upload) is started again.
4. At most **one start per pump call**; one call per place below.

Where it runs: **at the end of every sweep pass** (`StudioService.sweep()`, `studio.ts:1800`, before the posters), and a non-empty line
counts as pending, so the sweep keeps re-arming every `SWEEP_DELAY_S` (5 s, `sweep.ts`) while anything waits. Every transition that
frees the helper (save ready or failed, render result recorded, cancel) calls `scheduleSweep()`, which it already does or can do
cheaply; the gap between two jobs is therefore at most about one sweep interval when nobody polls. No pump runs inside a client's
request except the free-path start that create/render already do today.

**Guards** (these would silently jump the line or lose a job):
- `advance()` (`studio.ts:983`) and `step()` (`:1017`): a session with a save entry in the line is answered (`step: "queued"`), never
  stepped. Without this, the first poll of a queued session would start it (`step()` builds a missing record from the row, `:1039-1052`).
- `renderStatusInner()` (`:1669`): a pending render row whose job is in the line is answered `phase: "queued"` **before**
  `this.d.webp.status(...)`, which would answer 404 for a job with no `job:` record, i.e. `error.webp.job_lost` (`:1740-1742`).

### 17.6 Ceiling and expiry

- `LINE_MAX` = 50 entries in all (the app's paste takes at most 20 links). Over it: `429 error.studio.line_full`.
- `LINE_WAIT_MS` = 30 minutes from `at` (20 links at about 45 s each, twice over). An entry past it is ended by the pump or the sweep:
  a save → `markError(sid, "error.studio.busy")`, the title row deleted, the `failed` notification (per-session opt-in) and the live
  `failed` hook, i.e. exactly what `fail()` does today for a busy save; a render → its row `error` with `error.webp.busy` and its
  failed hooks. Old and new clients already have words for both codes; `plainReason` says "the server was busy".
- Nothing else expires an entry: the session's 7-day life is far longer than the ceiling.

### 17.7 Cancel what has not started (new routes, keyed)

- `DELETE /studio/<sid>/line`: cancels the session's queued save. `DELETE /studio/<sid>/render/<job>`: cancels a queued render.
  `Authorization: Api-Key`; the key must be the one that created the session (`row.key_id`), else, like an unknown session or job,
  `404 error.studio.not_found`; the service credential: 404. No CORS (the web page does not cancel).
- In the line → remove the entry; a save: `UPDATE studio_sessions SET status 'error', error_code 'error.studio.cancelled'` (and its
  title row deleted); a render: its row `error`, `error.webp.cancelled`. The live hooks get `failed` with that code (a registered run
  ends); **no Hark message** for a cancel (the owner did it); the line summary (17.8) drops the member. `200 {"status":"success",
  "cancelled": true}`.
- Already cancelled: the same `200` (idempotent). Already started, finished or failed: `409 error.studio.started` (the client says
  "stopped following": a running save or encode cannot be stopped; `DELETE /fetch/<id>` on the helper only forgets the job while its
  download keeps going, `helper/server.js:733-736`, so v1 does not pretend).

### 17.8 Notifications

- Per-session opt-ins (sections 9 and 14) are unchanged and fire when a queued job finishes, through the same hooks, so a share-sheet save
  that waited in the line is announced exactly as today.
- **One message for everything left behind**: `PUT /studio/line/notify` (keyed; body empty or `{}`; anything else `400
  error.notify.invalid`). The server takes a snapshot of the caller's work in flight: its line entries, its sessions with a `save:` record,
  and the unfinished `job:` records of its sessions, **minus** any session or job with its own opt-in (those announce themselves). Stored as
  `notify:line:<keyId>` = `{members: {"<sid>" | "<sid>:<job>": "pending" | "saved" | "rendered" | "failed:<code>"}, at, expires_at}` (24 h).
  A repeat PUT adds the work in flight now to the members still pending and keeps the outcomes already in. Answer `200 {status, bridge,
  watching: <members>, expires_at}`; nothing in flight → `watching: 0`, nothing stored, `expires_at: null`; bridge off → `bridge: false`,
  nothing stored. `DELETE /studio/line/notify` → `204`, idempotent (removes the record and cancels its pending retries).
- A new hook `NotifyHooks.onLineSettle(sid, job | null, outcome)` is called at every settle: save ready (link and adopted upload), save
  failed, cancelled, render success, render failed. It updates the member; a cancelled member is removed. When no member is pending, one
  message is sent (exactly once, `notify:ev:line:<keyId>:<at>`; retries and logs as 9.5); all members cancelled → nothing, record deleted.
- Copy: **one member** → exactly 9.4's message for that event (url `cobalt-apple://session/<sid>`). **Several** → title `cobalt`, body
  `done · 4 saved · 1 webp ready · 1 couldn't finish` (zero counts left out; `webps` for more than one), then for up to 3 failures a line
  each with 9.4's failure wording (`couldn't save <service · ref> — <reason>` / `couldn't make the webp — <reason>`), then, when exactly one
  webp was made, its URL on the last line. url: `cobalt-apple://jobs` (new: the app opens its job list). Lowercase, 80/2000 caps as 9.4.

### 17.9 Capability

`GET /capabilities`: `features.line: true` (absent = false: the app keeps its own line on the device and sends no `queue`), and
`limits.line_max: 50`, `limits.line_wait_ms: 1800000` (imported from `line.ts`, not retyped).

### 17.10 Gate and Worker

- `gate.ts` `decideStudio`, next to `/studio/recent` (`gate.ts:321`; neither path segment is a 22-char session id):
  `/studio/line` `GET` → `lookupThen(req, "studio_line")`; `/studio/line/notify` `PUT|DELETE` → `lookupThen(req, "studio_line_notify")`;
  other methods 404. In the session block: `/studio/<sid>/line` `DELETE` → `lookupThen(req, "studio_cancel", {sid})`;
  `/studio/<sid>/render/<job>` `DELETE` → `lookupThen(req, "studio_cancel", {sid, job})` (its `GET` stays unkeyed, `render_status`).
- `worker.ts`: the three new decisions are forwarded to the Durable Object like `studio_recent` (`worker.ts:356-366`: no body read, no
  `request_log` row, `Authorization` dropped, the key id header set). The DO routes them in `handleStudioRoute` (`studio.ts:1925`),
  requiring the key id header (403 without it), and refuses the service key id with 404.
- `POST /studio` and `POST .../render` keep their current Worker path (the body reaches the DO unchanged; `normalizeUrlField` only
  touches `url`).

### 17.11 Files and tests

New: `src/line.ts`, `test/line.test.ts`, `test/line-notify.test.ts`. Edited: `src/studio.ts` (create, render, adopt, `held`, `pumpLine`,
the two guards, sweep, cancel, `line` route, session body), `src/webp.ts` (`createFromUpload` optional id; export `mintId` if needed),
`src/notify.ts` (`onLineSettle`, the line opt-in, the summary copy), `src/gate.ts`, `src/worker.ts`, `src/app-routes.ts` (capability,
`queue` and `title` on upload and the item studio route), `README.md` (App routes: the line).
Tests (fakes from `test/studio-fakes.ts`, fake clock):
- order: three saves queued in order run in order; a focused render queued after them runs before the 2nd; two focused renders keep
  their order; nothing running is ever interrupted;
- free path unchanged: an empty line and a free helper give exactly today's replies (`queued: false`), byte-for-byte for the old keys;
- not queued while waiting: an old client's `POST /studio` gets `429 error.studio.busy` while the helper is free but the line is not
  empty; the web page path likewise;
- share: `origin: "share"` while busy is queued (no `save:` record, no 2 s busy retry), announced on finish through its opt-in, listed by
  `/studio/recent` with `step: "queued"`;
- polls never start: `GET /studio/<sid>` of a queued save answers `queued` and does not create a `save:` record; a queued render's
  status is `phase: "queued"`, never `job_lost`;
- the pump: starts the head when the running save ends (sweep only, no client polling); a render start that meets `429` stays at the
  head; a render start that fails ends that render and starts the next; an evicted `starting` render is restarted after
  `LINE_START_STALE_MS`; at most one start per call; posters never cut while the line has entries;
- `queue_ahead` and `GET /studio/line` (positions, `mine`, `key_name`, `running` kinds, other keys' links never shown);
- ceiling: `line_full` creates nothing; an entry past 30 min ends with `error.studio.busy` / `error.webp.busy` and the failed hooks;
- cancel: in line → cancelled codes, no Hark, idempotent; started → 409; another key / service → 404; gate methods;
- `title` and `queue` validation on all three create paths (400 creates nothing); the title row of a failed or cancelled save is gone;
- line notify: snapshot excludes sessions with their own opt-in; one message after the last member settles; single member uses 9.4
  copy; repeat PUT merges; DELETE cancels; bridge off stores nothing; exactly once under a poll racing the sweep;
- capability object (`test/library.test.ts`).

### 17.12 Deploy (owner; not run by the lane) and what stays unverified

API deploy only: `deploy/cloudflare/api/prepare-git-info.sh`, then `cd deploy/cloudflare/api && cf deploy --secrets-file
~/.config/cobalt/secrets.json`. No migration, no web deploy, no new secret, no helper change (the image is unchanged).
**Unverified until deployed:** that `schedule()` fires the sweep while no request is in flight (already section 6's caveat; the line
depends on it to drain with every client gone); that a render start begun inside a sweep pass with a large original (the stream into
the helper, up to 200 MB) completes when it outlasts the pass's 30 s item ceiling (abandoned, not cancelled; the stale-start rule
re-runs it if the object was evicted); real gaps between jobs on the deployed alarm cadence.

## 18. Photos and galleries: several items per save, photos stored as photos, made files, and a slideshow job (addendum, pinned 2026-10-06, owner decisions the same day; `apple/CONTRACT-GALLERY.md`)

Owner (2026-10-06): an Instagram carousel (`/p/Ddy0-gpGg5U`, 10 photos) and an X post (4 photos) cannot be saved; photos should be
first-class; a gallery saves whole, in part, or as one video; v1 also stores **crops** and **exports** (long image, PDF) made on the
device. **Pinned; 18.1-18.8 built by lanes GS1 (helper) and GS2 (API) at `a43d88d4b` (their briefs are in that commit's
`apple/CONTRACT-GALLERY.md` 8.1-8.2). Owner interview 2026-10-07: 18.9 (interim fix, lane S0) and 18.10-18.13 (makes, lane S1) added; their
briefs are the reworked `apple/CONTRACT-GALLERY.md` 8.1-8.2.** Code read on
2026-10-06 (`helper/lib.js`, `helper/server.js`, `studio.ts`, `app-routes.ts`, `poster.ts`, migrations 0003-0008). Everything is
**additive**: a client that sends nothing new gets today's behaviour, with two deliberate fixes (18.2): a single photo is stored as a
photo instead of a 0.04 s `video/mp4`, and an image gets a poster.

### 18.1 Migration `d1/migrations/0009_gallery.sql` (additive: nullable columns, two indexes)

```sql
-- Photos and galleries (APP-API-CONTRACT.md section 18, apple/CONTRACT-GALLERY.md). Additive only. Apply BEFORE deploying.
-- A gallery is one studio session whose items are N media_items rows sharing its session_id (one post).
ALTER TABLE media_items ADD COLUMN item_index INTEGER;   -- 0-based position in the source post; NULL = not a gallery item
ALTER TABLE media_items ADD COLUMN role TEXT;            -- 'item' | 'slideshow' | 'crop' | 'export'; NULL = legacy meaning (by source)
ALTER TABLE media_items ADD COLUMN made_from TEXT;       -- slideshow/crop/export: JSON array of the media_items ids it was made from
ALTER TABLE media_items ADD COLUMN made_spec TEXT;       -- crop/export/slideshow: the JSON spec it was made with (<= 512 bytes)
ALTER TABLE media_items ADD COLUMN post_key TEXT;        -- set on made rows (and gallery items): the post they belong to
ALTER TABLE studio_sessions ADD COLUMN item_count INTEGER;   -- picker items when it was resolved (NULL = single)
ALTER TABLE studio_sessions ADD COLUMN items TEXT;           -- JSON [{"i":0,"type":"photo","status":"ready"|"error","code":null}]
ALTER TABLE studio_renders ADD COLUMN kind TEXT;             -- NULL = 'webp' (today); 'slideshow'
ALTER TABLE studio_renders ADD COLUMN plan TEXT;             -- slideshow: the validated plan (18.5) as JSON
CREATE INDEX idx_media_items_session_item ON media_items (session_id, item_index);
CREATE INDEX idx_media_items_post_key ON media_items (post_key);
```

- **Post key**: every copy of the post-key expression gains a first branch: `COALESCE(m.post_key, <today's expression>)` —
  `POST_KEY_SQL` (`api/src/app-routes.ts:440`) and the web Worker's copy (`web/src/library.ts:101`). A made row of an image upload
  (whose post key is its own row id, no session) therefore joins that post. Rows written before 0009 have `post_key NULL`: nothing
  regroups.
- **Lead item**: `studio_sessions.r2_key` of a gallery names the first saved video item, else the first saved item, so every
  reader of "the session's original" (renders, reopen, `GET /studio/<sid>/source`, posters) keeps working on one file.

### 18.2 Saving: `POST /studio` takes `items` and `item_count`; photos are photos

- **`items`** (optional): `"all"` | `"first-video"` | an array of 1-20 unique ascending integers (picker indices). Absent = today
  (a picker gives its first video, else gif, else `error.webp.no_video`), **except** a 1-item picker, which saves that item whatever
  its type. Anything else → `400 error.studio.invalid_params`. **`item_count`** (optional integer 1-50, what the client saw): when
  the server's own resolve finds another count the session fails with `error.studio.gallery_changed` before anything is stored.
- **`slideshow`** (optional, only with `items`): a plan as 18.5 without `queue`/`priority`; when the save is ready a `slideshow`
  job joins the line (class `1`): the share sheet's and Shortcuts' "make a video".
- **Helper** (internal wire 18.7): one fetch job saves the chosen items one after another, each typed **by its bytes** and probed;
  a photo gets a 480 px JPEG thumb; a failed item is recorded and the job goes on (the job fails only when every item failed, with
  the first item's code).
- **Durable Object finalize** (`studio.ts:1983`): each saved item goes to `originals/<sid>-<nn>.<ext>` (`nn` = two-digit index)
  with one row: `kind 'private'`, `source 'saved'`, `role 'item'`, `item_index`, `post_key` = `<sid>`, `poster` = the thumb stored
  as a public unguessable JPEG (13.3's naming) for a photo, the usual poster job for a video; `public: true` applies 16.2's "on" per
  row. The session gets `item_count`, `items`, and `r2_key` = the lead. The adopt key regex (`studio.ts:2256`) widens to
  `originals/[A-Za-z0-9]{22}(-[0-9]{2})?\.[a-z0-9]{1,8}`.
- **Single files** (no `items`): the content type check at `studio.ts:1989-1993` keeps a helper-reported `image/jpeg|png|webp|heic`
  (instead of coercing to `video/mp4`) and stores `originals/<sid>.<ext>` with `role NULL`, `duration NULL`, a thumb as poster.
- **`POST /studio/<sid>/items/retry`** (keyed) `{"items":[6], "queue": true}`: re-resolves the session's link and fetches only those
  indices (a save job in the line, 17.3 rules); `202 {status, id, queued, queue_ahead}`; `409 error.studio.gallery_changed` when the
  count differs; `404 error.studio.not_found`; indices already `ready` are ignored; `400 error.studio.invalid_params` otherwise.
- **`GET /studio/<sid>`** gains `item_count` and `items` (parsed); the old fields describe the lead item.
- **Posters of images**: `isPosterType` (`poster.ts:45`) takes `image/jpeg|png|webp|heic`; the helper's `/poster` answers an image
  with its frame 0 (18.7). An image upload (`PUT /studio/upload`) therefore gets a poster too.

### 18.3 What a gallery post looks like: `GET /library?v=3`

- **`v=3`** (sent by builds with `features.gallery`): `v=2` (16.5) plus, on every file, `role`, `item_index`, `made_from` (array),
  `made_spec` (object); on every post `kind` (`"video" | "photo" | "gallery" | "webp"`: gallery = 2+ live `item` rows), `item_count`
  (live items), `items_failed` (indices from the session's `items`). Files ordered: items by `item_index`, then slideshows, crops,
  exports, webps, each by `created_at`.
- **Without `v=3`** (old apps 1.0-1.7, the old web page): a gallery post is emitted as its lead item (16.5's shape, legacy host
  synthesis when public) and its webps; other items and made rows are omitted. Single photos, crops and exports of a single photo:
  the photo only. `counts` unchanged.

### 18.4 Deleting and visibility

- **`DELETE /library/items/<id>`** (keyed; `DELETE` on the bare item path, which `gate.ts:215-240` answers 404 today since `sub` is undefined): a live row with `role`
  `item`, `slideshow`, `crop` or `export`. Deletes its R2 object, its mirror (`public_key`), an unshared poster (refcount, 13.4),
  soft-deletes the row, purges its public URL (best effort). The **last live item** of a post → `409 error.library.last_item` (use
  section 12). Any other row → `409 error.library.not_deletable` (webps keep `DELETE /media/<name>`). `200 {"status":"success",
  "deleted":{"files":1,"bytes":…}}`; a deleted or unknown id → `404 error.library.not_found`. Made rows keep working when the
  item they were made from is deleted.
- **`DELETE /library/items/<id>/post`** (12): covers every row of the post (same post key, `post_key` included); unchanged otherwise.
- **`PATCH /library/items/<id>/visibility`** (16.2) takes `"scope": "post"` (absent = `"row"`): applies on/off to every live
  `bucket 'originals'` row of the post that is not a switched webp, in `item_index` then `created_at` order, each step as 16.2;
  `200 {status, items: [<v3 file>…], cache_cleared}`; rows that fail are listed in `remaining` with `502 error.library.partial`
  (retry is idempotent).

### 18.5 The slideshow job: `POST /studio/<sid>/slideshow` (keyed)

- **Body** (≤ 4 KB): `{"items":[0,1,…], "seconds":[3,5.6,…,null], "fade":true, "frame":"keep"|"9:16"|"1:1", "sound":"none"|"own",
  "queue":true, "priority":"focused"|null, "notify":true|false}`. `items`: 2-20 `item_index` values of live `item` rows of the
  session's post, any order (the play order), no repeats; `seconds`: same length, a number 1-15 (one decimal) for a photo, `null`
  for a video or gif (own length; a gif plays once); total ≤ 180 s → else `400 error.webp.too_long`; `sound: "own"` without a video
  item, or anything else malformed → `400 error.webp.invalid_params`; `priority` without `queue` → `400`. Fewer than 2 live items in
  the post → `409 error.studio.not_gallery`; an expired session → `410` as renders.
- **Frame** (decided by the DO from the rows): `keep` = the most common `width×height` among the chosen items (ties: the first),
  scaled to 1080 on the short side; `9:16` = 1080×1920; `1:1` = 1080×1080; both sides rounded down to even.
- **Line**: a `LineEntry` (17.2) of `kind: "slideshow"` carrying the validated plan; class `0` with `priority: "focused"`, else `1`;
  a `studio_renders` row `kind 'slideshow'`, `plan`, `status 'pending'`. Answer as a render: `202 {status: "pending", job, queued,
  queue_ahead}`. Progress on `GET /studio/<sid>/render/<job>` (section 4) with `phase` `"queued"`, `"uploading"` (inputs into the
  helper), `"composing"` (`frames_done` = stills done, `frames_total` = stills), `"encoding"` (`frames_done` = seconds encoded,
  `frames_total` = total seconds); on done `{status:"success", url?, item_id, bytes, width, height, seconds}`.
- **Start**: the DO streams each chosen original from R2 into the helper (`PUT /slideshow/<job>/inputs/<n>`, 18.7), then `POST
  /slideshow/<job>/start`; when done it stores `GET /slideshow/<job>/file` at `originals/<sid>-s<job>.mp4` as a row (`kind
  'private'`, `source 'studio'`, `role 'slideshow'`, `made_from` = the item ids, `made_spec` = the plan, `post_key`), applies the post's
  visibility (its lead item's), queues a poster, writes `result:<job>`, `DELETE`s the helper job; `notify` as 9.3.
- **Failures**: helper error → the render row `error` with its code (`error.webp.encode_failed`, `error.webp.timeout`); an input
  missing in R2 → `error.studio.missing`; the line's ceilings (17.6) apply. The items are never touched.

### 18.6 Made on the device: `PUT /library/items/<id>/made` (keyed)

- **Query**: `role=crop|export`, `name=<url-encoded, cleanName rules, ≤ 120>`, `spec=<url-encoded JSON object, ≤ 512 bytes>`.
  Headers: `content-type` `image/jpeg` (crop; export with `spec.kind = "long"`) or `application/pdf` (export with `spec.kind =
  "pdf"`); `content-length` required, ≤ 50 MB (`413 error.studio.too_large`). Judged before the body is read; any mismatch → `400
  error.library.bad_request`. Body streamed to R2 by the Worker (no container).
- **Anchor `<id>`** (id or `public_id`, live): for `crop` a live `item` row (or a single photo, `role NULL`) whose `content_type` is
  an image (else `409 error.library.not_photo`); for `export` any live row of the post. Unknown → `404 error.library.not_found`.
- **Row**: id 16 base62; `kind 'private'`, `source 'made'`, `bucket 'originals'`, `r2_key made/<row id>.<jpg|pdf>`, `role`,
  `made_from` (crop: `[anchor id]`; export: the ids of the post's live image items at that moment), `made_spec` = `spec`, `post_key`
  = the anchor's post key, `session_id` = the anchor's, `link` = the anchor's, `width`/`height` from the JPEG header (null for a PDF),
  `name`. Visibility = the post's (its lead item's): when public, 16.2's "on" runs for the new row. A poster job is queued for a JPEG
  (none for a PDF).
- **Replace**: for `export`, any other live `export` row of the post with the same `spec.kind` is deleted (as 18.4) **after** the
  new row is stored. Crops accumulate.
- **Answer**: `201 {"status":"success","item":<v3 file>,"replaced":["<id>"]}`; `503 error.api.generic` when D1/R2 fail before the
  row exists (the object, if written, is deleted).

### 18.7 Helper internal wire (port 9100, `x-internal-key`; pinned so GS1 and GS2 build in parallel)

- **`POST /fetch {id, url, items?, item_count?}`**: `items` and `item_count` as 18.2 (else `400 {error:{code:"error.studio.
  invalid_params"}}`). Without `items`: today's job, plus type by bytes (below) and the 1-item-picker rule.
- **`GET /fetch/:id`**: pending `{status:"pending", stage:"downloading"|"probing", bytes, total, item: <index>|null, items_done,
  items_total}`; done: today's fields describing the **lead**, plus `picker_count` (null when not a picker), and with `items`:
  `items: [{i, status:"done"|"error", code?, bytes?, contentType?, ext?, duration?, width?, height?, thumb: boolean}]`; error
  `{status:"error", error:{code}}` (`error.studio.gallery_changed` when `item_count` differs from the picker's length).
- **`GET /fetch/:id/file?i=<n>`** (no `i` = the lead): the bytes with content-length; unknown or failed `i` → 404.
  **`GET /fetch/:id/thumb?i=<n>`** (no `i` = the single file): `image/jpeg`, longer side ≤ 480 px; none → 404.
- **Type by bytes** (`lib.js`, new `sniffType(head)`): JPEG `FF D8 FF`; PNG `89 50 4E 47 0D 0A 1A 0A`; WebP `RIFF????WEBP`; HEIC/HEIF
  `????ftyp` + `heic|heix|hevc|mif1|msf1`; GIF as today; anything else → the video path as today (`videoExt`). An image gets
  `contentType` `image/jpeg|png|webp|heic`, `ext` `jpg|png|webp|heic`, `duration: null`, width/height from the probe. An animated
  WebP or GIF stays what it is (a GIF keeps today's `image/gif` meaning: animated).
- **`POST /poster?id=`**: an image body (sniffed) is answered from frame 0 (no `-ss`; today `posterTime(0.04)` = 0.004 s seeks past
  the only frame and ffmpeg writes nothing: checked locally with ffmpeg 9.0.1, so an image gets `422 error.poster.failed` today).
- **Slideshow** (holds the helper like an upload from the first input until `DELETE` or a 5 min idle reap):
  - `PUT /slideshow/:id/inputs/:n` (n 0-19) body = the file (≤ 200 MB each, ≤ 500 MB per job) → `204` | `413` | `429 busy`
    (another job holds the helper) | `400` (bad n).
  - `POST /slideshow/:id/start {width, height, fade, sound, slides:[{n, seconds|null}]}` (`width`/`height` even, ≤ 1920; `seconds`
    1-15 for a still, `null` for a video/gif input; total ≤ 180) → `202` | `400 error.webp.invalid_params` | `409` (an input missing).
  - `GET /slideshow/:id` → `{status:"pending", phase:"composing"|"encoding", done, total}` | `{status:"done", bytes, duration, width,
    height}` | `{status:"error", error:{code}}`; `GET /slideshow/:id/file` → `video/mp4`; `DELETE /slideshow/:id` → `204`.
  - The recipe is `apple/CONTRACT-GALLERY.md` section 6 (compose each still once with the blurred fill, `xfade` 0.3 s or `concat`,
    `mpdecimate=…:max=15`, `-fps_mode vfr`, `libx264 veryfast stillimage crf 20`, `+faststart`); video inputs are scaled/padded
    with the same fill, their audio kept with `sound: "own"` (`anullsrc` under stills), else `-an`. Job timeout 10 min →
    `error.webp.timeout`; ffmpeg failure → `error.webp.encode_failed`.

### 18.8 Capability, errors, deploy

- `GET /capabilities`: `features.gallery: true` (needs `features.line`). Absent: the app keeps today's picker; the share extension
  shows its one-line card; batches and Shortcuts keep first-video (CONTRACT-GALLERY owner decision 5, interim).
- New codes: `error.studio.gallery_changed`, `error.studio.not_gallery`, `error.studio.missing`, `error.library.last_item`,
  `error.library.not_deletable`, `error.library.not_photo`. Reused: `error.webp.too_long`, `error.webp.encode_failed`,
  `error.webp.timeout`, `error.webp.invalid_params`, `error.studio.invalid_params`, `error.studio.too_large`,
  `error.library.bad_request`, `error.library.partial`, `error.library.not_found`.
- Deploy (owner): remote migration 0009 first, then the API (`prepare-git-info.sh`, `cf deploy`; the container image changes with
  the helper), then the web Worker (its `POST_KEY_SQL` line). No new secret.
- Tests and files: the GS1/GS2 briefs in `a43d88d4b`'s `apple/CONTRACT-GALLERY.md` 8.1-8.2 were the list for 18.1-18.8; the S0/S1
  briefs in today's 8.1-8.2 are the list for 18.9-18.13.

### 18.9 Interim: a photo-only gallery from a client that sends no `items` saves whole (lane S0; owner interview 2026-10-07)

Why: the 1.13 app sends no `items` from its share sheet, a batch paste or a Shortcut, so 18.2's "absent = today" answers a photo-only
carousel with `error.webp.no_video` (`helper/lib.js:188-202`, `server.js:582`). The owner hit it sharing an X 4-photo post.

- **Rule (exact):** when `POST /studio` (and the helper's `POST /fetch`) has **no `items`** and cobalt answers a **picker of 2 or
  more entries none of which is `video` or `gif`**, the save behaves as `items: "all"`: every entry up to 20, one after another, a
  failed item recorded (18.2), stored as a gallery (N `role 'item'` rows, `item_count` = the picker's length, lead = item 0). In
  every other case "absent" keeps 18.2's meaning: a 1-item picker saves that item; a picker with a video or gif saves the first video,
  else the first gif; a plain answer saves the file. An explicit `"first-video"` is unchanged (a photo-only post still fails
  `no_video`: that client asked for a video). `item_count` absent: no `gallery_changed` check.
- **Where:** `helper/lib.js` gains `effectiveItems(entries, items)` (returns `items` when given; `"all"` for the case above; else
  `undefined`); the fetch job uses it before `selectPickerItems` and before choosing the one-file branch, so the answer carries
  `items` and `picker_count` and the Durable Object's existing `finalizeItems` path (`studio.ts:2379`) stores the rows. No API
  change outside the helper.
- **What old clients see:** `GET /library` without `v=3` lists the post as its first photo (18.3's legacy shape); `GET
  /studio/<sid>` answers the lead (a photo: `image/jpeg`, `duration: null`) plus `item_count`/`items`. A notification opted in for
  `saved` fires once. What the 1.13 app draws for an image session is not verified (V checks it).
- **Tests:** `apple/CONTRACT-GALLERY.md` 8.1. **Deploy:** the helper changes, so the container image changes (owner).

### 18.10 The slideshow webp, and 0.5 s photos (lane S1)

- **`POST /studio/<sid>/slideshow`** body gains `"format": "mp4" | "webp"` (absent = `"mp4"`), and for `webp` only `"quality":
  "low" | "med" | "high"` (absent = `"med"`) and `"width": 320 | 480` (absent = 480); `quality`/`width` with `mp4` → `400
  error.webp.invalid_params`. `seconds` of a photo: **0.5 to 15**, one decimal (was 1 to 15). `sound` must be `"none"` with `webp`
  (else 400). Totals: `webp` ≤ **60 s** (`400 error.webp.too_long` when the photos alone exceed it; with videos the helper decides
  after probing), `mp4` ≤ 180 s as before; videos and gifs ≤ 60 s together in both (helper, `error.webp.too_long`).
- **Frame**: `mp4` as 18.5. `webp`: width = `width`, height = even(width / aspect) with the aspect of `keep` (18.5's most common size),
  `9:16` or `1:1` (480 → 480×600 for 4:5, 480×854, 480×480).
- **Helper**: `POST /slideshow/:id/start` gains `format`, `quality`, `fps` (15; webp only); `seconds` 0.5-15. The webp recipe is
  `apple/CONTRACT-GALLERY.md` 6.2 (a frame list encoded by one `img2webp` run with today's `-kmin 3 -kmax 5`). `GET /slideshow/:id`
  done answers `{bytes, duration, width, height, format}`; `GET /slideshow/:id/file` → `image/webp` or `video/mp4`; new `GET
  /slideshow/:id/poster` → `image/jpeg` (the first frame; webp and mp4). Output ≤ 25 MB for webp (`error.webp.too_large`).
- **Result row**: as 18.5 with `r2_key originals/<sid>-s<job>.webp`, `content_type image/webp`, `made_spec` = the plan including
  `format`, `quality`, `width`; its poster is the helper's poster JPEG stored as 13.3's public unguessable JPEG (no poster job).
- **Replace (owner-approved 2026-10-07, `apple/CONTRACT-GALLERY.md` R8)**: a post holds one slideshow per `format`. When the new row
  is stored, any other live `role 'slideshow'` row of the post with the same `made_spec.format` (absent = `"mp4"`, so rows made
  before 18.10 count as mp4) is deleted as 18.4 (R2 object, mirror, unshared poster, purge). The render's done answer lists it in
  `replaced: ["<id>"]`. This also changes 18.5's mp4 slideshows, which accumulated.
  `GET /studio/<sid>/render/<job>` done adds `format`. Library `v=3` lists it with `role 'slideshow'` and its `content_type`.

### 18.11 The gallery image: `POST /studio/<sid>/gallery-image` (keyed; lane S1)

- **Body** (≤ 2 KB): `{"items":[…], "layout":"strip"|"grid2"|"grid3"|"row", "queue":true, "priority":"focused"|null,
  "notify":true|false}`. `items`: 2-20 unique `item_index` values of live `item` rows of the post, in the order to draw, every one a
  photo (`image/*` other than `image/gif`; a video or gif → `400 error.webp.invalid_params`); fewer than 2 live photo items in the
  post → `409 error.studio.too_few_photos`; malformed → `400 error.webp.invalid_params`; `priority` without `queue` → 400; an
  expired session → 410.
- **Line**: a `LineEntry` (17.2) of `kind: "gallery_image"`, class 0 with `priority: "focused"`, else 1; a `studio_renders` row
  `kind 'gallery_image'`, `plan` = the body's items and layout, `status 'pending'`. Answer `202 {status:"pending", job, queued,
  queue_ahead}`; progress on `GET /studio/<sid>/render/<job>` with `phase` `queued` | `uploading` | `composing`; done
  `{status:"success", url?, item_id, bytes, width, height, cropped:[index…], upscaled:[index…]}`.
- **Helper**: `PUT /gallery/:id/inputs/:n` (n 0-19; ≤ 200 MB each, ≤ 500 MB a job; holds the helper like `/slideshow`, 5 min idle
  reap, 429 busy), `POST /gallery/:id/start {layout, slides:[{n}]}` (the helper probes the sizes and runs
  `apple/CONTRACT-GALLERY.md` 6.3-6.4) → 202 | 400 | 409 (an input missing); `GET /gallery/:id` → pending `{phase:"composing"}` |
  done `{bytes, width, height, cropped:[n…], upscaled:[n…]}` | error; `GET /gallery/:id/file` → `image/jpeg`; `DELETE` → 204.
  Errors: `error.webp.invalid_params` (an input that is not a still), `error.webp.encode_failed`, `error.webp.too_large` (> 50 MB),
  `error.webp.timeout` (10 min).
- **Result row**: `originals/<sid>-g<job>.jpg`, `kind 'private'`, `source 'studio'`, `role 'export'`, `made_from` = the item ids,
  `made_spec` = `{"kind":"gallery","layout":"grid3","items":[…]}` (≤ 512 bytes), `post_key`, width/height, the post's visibility
  (its lead's), a poster job (image). **Replace** (R8): another live `export` row of the post with `made_spec.kind "gallery"` and the
  same `layout` is deleted (as 18.4) after the new row is stored, listed in the done answer's `replaced`; other layouts stay. `notify` as 9.3 (`rendered` copy:
  `gallery image ready · <w>×<h> · <size>`).

### 18.12 The share sheet's one request: `slideshow.format` and `gallery_image` on `POST /studio` (lane S1)

- `POST /studio` (with `items`) takes `slideshow` as 18.2 plus 18.10's `format`/`quality`/`width`, **or** `gallery_image: {items,
  layout}` (18.11's fields), not both (400). `slideshow.seconds` carries `null` for every video and gif item (its own length) and the
  photo time for every photo, in the plan's order (the approved boards' shape); a number for a video or `null` for a photo → 400. The make's render row is created with the session (its job id is in the answer as
  `make: {job, kind}`) and joins the line (class 1) when the save is ready, over the asked items **that were saved** (a failed item is
  dropped from the plan; for a gallery image, fewer than 2 photos left → the render ends `error.studio.too_few_photos`, the save
  stays; for a slideshow, fewer than 2 items left → `error.studio.not_gallery`).
- **One message.** With a make, the client sends `notify: {on: ["rendered", "failed"], label}`: exactly one Hark message when the
  make ends (`<label> · slideshow webp ready` / `<label> · slideshow ready` / `<label> · gallery image ready`, with the 9.4 size and
  URL line), or when the save fails (9.4's save failure), or when the save succeeds and the make fails (`<label> · saved <n> items.
  <what> couldn't be made — <reason>`; for a webp over 60 s: `<label> · saved <n> items. the slideshow webp would be <m:ss> and
  webps stop at 60 s. open cobalt to make the mp4.`). `saved` is not sent unless asked. The message's URL opens the session.
- Bodies the share sheet sends (pinned for lane A4; `public` and `label` as today's instant share):
  `{"url", "items":"all", "item_count":10, "public":true, "origin":"share", "queue":true, "notify":{"on":["saved","failed"],"label"}}`
  (save all); the same plus `"slideshow":{"items":[0,…,9], "seconds":[2,…,null], "fade":true, "frame":"keep", "sound":"none",
  "format":"webp", "quality":"med", "width":480}` and `notify.on: ["rendered","failed"]`; or plus `"gallery_image":{"items":[photo
  indices], "layout":"grid3"}` and `notify.on: ["rendered","failed"]`.

### 18.13 Renders of one item: `item` on `POST /studio/<sid>/render` (lane S1)

- Optional integer `item`: the `item_index` of a live `item` row of the session whose type is a video or gif; the render reads that
  row's `r2_key` instead of the session's lead. A photo item → `409 error.studio.not_video`; an unknown or deleted index → `404
  error.studio.not_found`; on a session without items → 400 `error.webp.invalid_params`. Absent = the lead (today). The webp is
  stored as today (public `media` bucket) and listed in `v=3` with `made_from` = that item's id.

**Capability (18.10-18.13):** `features.gallery_make: true` when the running helper answers `x-cobalt-helper: gallery=1,make=1`
(checked as `gallery=1` is, `studio.ts:812-836`); without it the app hides the three makes and the share sheet draws only `save all`.
New code: `error.studio.too_few_photos`. Reused: `error.studio.not_video`, `error.studio.not_gallery`, `error.webp.*` as above.
