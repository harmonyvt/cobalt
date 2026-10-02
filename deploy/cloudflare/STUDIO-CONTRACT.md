# cobalt studio: shared contract (pinned 2026-09-30)

Three pieces are built in parallel against this file. Do not deviate; if
something here is impossible, stop and report instead of improvising.

## Flow
1. "cobalt studio" Shortcut sends `POST https://api.capybaraharmony.com/studio`
   with the owner's API key and `{ "url": <free text> }` (share input + clipboard;
   the API Worker already extracts the first http(s) link via normalizeUrlField).
2. The API answers at once with the studio page URL; the Shortcut opens it and
   shows a notification. In the background the API fetches the video once via
   cobalt and stores it privately in R2 bucket `cobalt-originals`.
3. The studio page (`https://cobalt.capybaraharmony.com/studio/<id>`, behind
   Cloudflare Access like the rest of that host) polls the session, streams the
   stored video, lets the owner pick up to 10 s, renders animated WebPs from the
   stored copy (never re-fetching the source), and shows the public link.

## Identifiers and limits
- Session id: 22 chars base62 from crypto.getRandomValues (>=128 bits). It is a
  capability: the /studio/<id>* API routes need no API key, only the id.
- Render job id: 20 chars base62.
- Session lifetime: 7 days from creation (`expires_at`). Expired -> 410.
- Stored source: R2 `cobalt-originals`, key `originals/<session id>.<ext>`
  (mp4 normally). Kept after expiry (the gallery will use it). Max 200 MB.
- Render: length 0.5-10 s (the server limit is WEBP_MAX_SECONDS = 10), start >= 0,
  start + length <= duration + 0.05. width 320 | 480 (default 480, never above the
  source width). quality low | med | high (default med). One encode at a time.

## API (base https://api.capybaraharmony.com). JSON unless noted.
All /studio responses carry `access-control-allow-origin: https://cobalt.capybaraharmony.com`,
and OPTIONS preflights for /studio* from that origin get 204 with
`access-control-allow-methods: GET, POST, OPTIONS`,
`access-control-allow-headers: content-type, range`, `access-control-max-age: 600`.
Media responses also expose `content-range, content-length, accept-ranges`.
Errors are always `{ "status": "error", "error": { "code": "<code>" } }`.

1. `POST /studio` (Authorization: Api-Key <key>; body `{ url }`)
   -> 201 `{ "status": "success", "id": "<sid>", "url": "https://cobalt.capybaraharmony.com/studio/<sid>" }`
   Starts the background save. Errors: auth codes as today, `error.studio.no_link`
   (no http(s) link found), `error.studio.busy` (a save or encode is running).
2. `GET /studio/<sid>[?wait=N]` (no key; N <= 25 long-polls while status is "saving")
   -> 200 `{ "status": "saving" | "ready" | "error", "id", "link", "service",
   "title": string|null, "duration": number|null, "width": number|null,
   "height": number|null, "bytes": number|null, "created_at": ms, "expires_at": ms,
   "error": {code}|null, "renders": [ { "id", "url", "start", "length", "width",
   "quality", "bytes", "created_at" } ] }` (renders newest first, successful only).
   Unknown -> 404 `error.studio.not_found`; expired -> 410 `error.studio.expired`.
   Save failures set status "error" with cobalt's code passed through
   (e.g. `error.api.fetch.fail`) or `error.studio.too_large`.
3. `GET /studio/<sid>/source` (no key) -> the stored video from R2, `content-type`
   from the object, `accept-ranges: bytes`, Range -> 206 with `content-range`,
   `cache-control: private, max-age=3600`. Served by the Worker straight from R2
   (the container is not involved). Not ready -> 409 `error.studio.not_ready`.
4. `POST /studio/<sid>/render` (no key; body `{ start, length, width?, quality? }`)
   -> 202 `{ "status": "pending", "job": "<jobid>" }`. Errors: `error.webp.invalid_params`,
   `error.webp.too_long`, `error.webp.busy` (429), `error.studio.not_ready` (409),
   expired/not_found as above.
5. `GET /studio/<sid>/render/<jobid>[?wait=N]` (no key, N <= 25)
   -> `{ "status": "pending", "job" }` | `{ "status": "success", "job", "url",
   "bytes", "width", "height", "seconds" }` | `{ "status": "error", "error": {code} }`.
   `url` is `https://media.capybaraharmony.com/<10 chars>.webp` (public, as today).

## Web (cobalt.capybaraharmony.com)
- The web Worker serves the studio page for `/studio/<sid>` (add `/studio` and
  `/studio/*` to `assets.runWorkerFirst`). Everything else stays cobalt's assets.
- The page's own response headers (not cobalt's `_headers`):
  `content-security-policy: default-src 'self'; connect-src https://api.capybaraharmony.com; media-src https://api.capybaraharmony.com blob:; img-src 'self' data: blob: https://media.capybaraharmony.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'`,
  `referrer-policy: no-referrer`, `cache-control: no-store`, `x-content-type-options: nosniff`.
  No COEP/COOP (the video is cross-origin).
- The page loads the video with `<video crossorigin="anonymous" playsinline>` from
  route 3 so it can draw filmstrip thumbnails to a canvas.
