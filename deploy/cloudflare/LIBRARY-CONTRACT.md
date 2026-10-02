# cobalt library: shared contract (pinned 2026-10-02)

Two lanes build against this file in parallel: the API lane (deploy/cloudflare/api/**,
d1 migration 0004) and the web lane (deploy/cloudflare/web/** + the sidebar tab in
upstream web/). Do not deviate; if something is impossible, stop and report.
Approved mockup: scratchpad/cobalt-library-mockup.html (owner approved "build it as shown").

## Decisions (owner, 2026-10-02)
- New "library" tab in cobalt's sidebar (small upstream edit) → full-page link to /library.
- Upload limit 100 MB per file (enforce `bytes <= 100_000_000`; Cloudflare's request body limit on this plan is 100 MB, so this fits).
- Library actions authenticate with the Cloudflare Access login only (no API key in the browser).

## Storage and records
- Public files: R2 `cobalt-media` (MEDIA), served at https://media.capybaraharmony.com/<name>,
  name = 10 base62 chars + "." + ext. Private files: R2 `cobalt-originals` (ORIGINALS):
  studio saves at `originals/<sid>.<ext>` (exists), uploads at `uploads/<id>.<ext>` (new).
- D1 migration `0004_library.sql` (API lane writes it; both lanes use it):
  `media_items(id TEXT PRIMARY KEY, kind TEXT NOT NULL /* 'public' | 'private' */,
  source TEXT NOT NULL /* 'webp' | 'studio' | 'host' | 'upload' | 'saved' */,
  bucket TEXT NOT NULL /* 'media' | 'originals' */, r2_key TEXT NOT NULL, url TEXT /* public only */,
  name TEXT NOT NULL /* display name */, content_type TEXT, bytes INTEGER, width INTEGER,
  height INTEGER, duration REAL, link TEXT /* source page link */, session_id TEXT,
  key_id TEXT, created_at INTEGER NOT NULL, deleted_at INTEGER)` + index on
  (deleted_at, created_at DESC) and on session_id. id = 16 base62 chars.
- Who inserts rows:
  - API lane: `webp` (every successful POST /webp job), `studio` (every successful studio
    render), `host` (studio publish, below), `saved` (when a studio save becomes ready: the
    private original). Backfill script for what already exists (studio_sessions ready →
    'saved'; studio_renders success → 'studio'; R2 MEDIA objects not covered → 'webp' with
    customMetadata when present) — run by the main thread.
  - Web lane: `upload` (private, bucket originals) and `host` when publishing an upload.
- Soft delete: set deleted_at, and delete the R2 object. Lists exclude deleted rows.

## Internal service auth (web Worker → API Worker)
- The web Worker gets a service binding `API` → Worker `cobalt-api` (cf/config
  `bindings.worker({ worker: "cobalt-api" })`) and the secret `COBALT_API_KEY` (same
  ~/.config/cobalt/secrets.json, uploaded with `cf deploy --secrets-file` for web too).
- It calls the API with header `x-cobalt-service: <COBALT_API_KEY>` (and NO Authorization).
  The API Worker: if that header is present and constant-time-equals env.COBALT_API_KEY,
  the request is authenticated as key id `service:library` (same as a valid Api-Key);
  otherwise ignore it as if absent. Always strip it before anything reaches the container
  or the DO. Requests via the binding use the URL https://api.capybaraharmony.com/<path>.

## API routes (API lane) — existing ones unchanged, plus:
1. `POST /studio/<sid>/publish` (Api-Key OR service auth; studio must be "ready") →
   copies the stored original from ORIGINALS to MEDIA under a new public name (stream
   copy, no buffering; chunk loop, NOT pipeTo — pipeTo between streams is unimplemented
   in this runtime) → inserts a `host` media_items row → 201
   `{ "status": "success", "url", "bytes", "content_type", "item_id" }`.
   Errors: not_ready 409, not_found 404, expired 410, `error.studio.storage` 502.
2. `POST /library/adopt` (service auth ONLY) body `{ "r2_key": "uploads/<id>.<ext>",
   "name": string, "content_type": string, "bytes": number, "item_id": string }` →
   creates a studio session that points at that existing ORIGINALS object (no cobalt
   fetch) and probes it for duration/width/height by streaming the object to a new helper
   endpoint `POST /probe?id=` (helper writes it to /tmp, runs the ffmpeg probe, deletes it,
   answers `{duration,width,height}`); poll-driven like the studio save (the probe advances
   while GET /studio/<sid> is polled). → 201 `{ "status": "success", "id", "url" }`.
   Only video/gif content types (`video/*`, `image/gif`); others → 400 `error.studio.not_video`.
   The adopted session's original is NOT a new 'saved' item (it is the upload's item).
3. Everything else about studios (GET status long-poll, source, render) works for adopted
   sessions exactly as for saved ones.

## Web routes (web lane), all on https://cobalt.capybaraharmony.com, Access JWT verified
exactly like /api/keys (same verifier), POST/PUT/DELETE also require Origin = web origin.
JSON responses, `cache-control: no-store`.
- `GET /library` → the library page (self-contained HTML like the studio page; same CSP
  approach: connect-src 'self' https://api.capybaraharmony.com; img-src/media-src also allow
  https://media.capybaraharmony.com and blob:/data:). Add "/library", "/library/*",
  "/api/library", "/api/library/*" to runWorkerFirst.
- `GET /api/library?filter=all|public|private|studio&before=<ms>&limit=<=100` →
  `{ "items": [ { "id", "kind", "source", "name", "url", "content_type", "bytes", "width",
  "height", "duration", "link", "session_id", "created_at" } ], "studios": [ { "id", "url",
  "status", "link", "title", "duration", "renders": <count>, "created_at", "expires_at" } ],
  "usage": { "public_bytes", "private_bytes" }, "next_before": ms|null }`.
- `POST /api/library/link` `{ "url": string, "action": "webp" | "studio" | "host" | "keep" }` →
  webp → API POST /webp → `{ "status": "pending", "job" }`; studio|host|keep → API POST
  /studio → `{ "status": "success", "studio": "<sid>", "url" }` (the page then polls and,
  for host, calls publish once ready; for keep it just waits for "ready").
- `GET /api/library/webp/<job>?wait=N` → proxies API GET /webp/<job>.
- `GET /api/library/studio/<sid>?wait=N` → proxies API GET /studio/<sid>.
- `POST /api/library/studio/<sid>/publish` → proxies API route 1.
- `PUT /api/library/upload?name=<filename>` body = raw file bytes, `content-type` = the
  file's type, `content-length` required, <= 100_000_000 → R2 ORIGINALS `uploads/<id>.<ext>`
  (stream straight from request.body; it has a known length) → inserts a private
  `upload` item → 201 `{ "status": "success", "item": {…item shape…} }`.
  Allowed types: image/gif, image/webp, image/png, image/jpeg, video/mp4,
  video/quicktime, image/heic (ext from type). Others → 415 `error.library.unsupported`;
  too big → 413 `error.library.too_large`.
- `POST /api/library/items/<id>/publish` → copies an upload (or any private item) from
  ORIGINALS to MEDIA (chunk-loop copy) → inserts a public `host` item → 201 `{ "status": "success", "item" }`.
- `POST /api/library/items/<id>/studio` → API POST /library/adopt → `{ "status": "success", "studio", "url" }`.
  "convert to webp" in the UI = this, then poll the studio until ready, then (if duration
  <= 10) POST https://api.capybaraharmony.com/studio/<sid>/render `{start:0,length:duration}`
  (public route) and poll it; if > 10 s the UI offers "trim in studio" instead.
- `DELETE /api/library/items/<id>` → delete the R2 object, set deleted_at → 200 `{status:"success"}`.
  Deleting a private original also expires (expires_at = now) studios whose session's
  r2_key matches it.
- `DELETE /api/library/studios/<sid>` → set expires_at = now → 200.
Errors: `{ "status": "error", "error": { "code" } }`; auth 401 `unauthorized`, origin 403 `forbidden`.

## Conversion rules (UI and server agree)
- convert to webp: gif, mp4, mov only (webp uploads: host only — ffmpeg here can't decode
  animated WebP; heic: host only). Length <= 10 s → whole clip; longer → studio trim.
- host as-is: every allowed type.
