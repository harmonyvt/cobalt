# Private Cloudflare deployment

- `web/`  -> Worker with static assets at https://cobalt.capybaraharmony.com (behind Cloudflare Access); its Worker
  also serves `/api/keys` (owner-only API key management)
- `api/`  -> Worker + Container at https://api.capybaraharmony.com (locked by per-owner API keys, NOT by Access);
  also hosts animated WebPs (`/webp`, `/media`, see "Animated WebP hosting") in the R2 bucket `cobalt-media`,
  served from https://media.capybaraharmony.com/; also hosts cobalt studio (`/studio*`, see "cobalt studio"), which keeps
  private copies of saved videos in the R2 bucket `cobalt-originals`
- `d1/`   -> migrations for the `cobalt-keys` D1 database shared by both Workers

Everything here is fork-only; nothing under `api/`, `web/` or the root `Dockerfile` is modified.
The deploy tool is the Cloudflare `cf` CLI (v1.0.0-beta.5), not Wrangler. Each of `api/` and `web/` has a
`cloudflare.config.ts` (the cf config) and a `wrangler.config.ts` (bundler settings; cf delegates the build to the
local Wrangler, so Wrangler stays a devDependency but is never invoked directly and never needs `wrangler login`).

Prerequisites: Node, Docker running (the container image is built locally, linux/amd64), `cf` authenticated
(`cf auth login`, or `CLOUDFLARE_API_TOKEN`), and `npm install` in `api/` and `web/` (installs the pinned `cf`
that `cloudflare.config.ts` imports `cf/config` from).

## Secrets file (once)

The main secret is `COBALT_API_KEY`, a UUID (the API rejects anything else; the three optional APNs secrets of "Live Activities" below live in the same file). Since API keys became per-owner it is an
INTERNAL key: the API Worker swaps it into every forwarded request and writes it into the container's key file. Clients
never send or see it (their keys live, hashed, in D1). It lives in a JSON file outside the repo and is uploaded by
`cf deploy --secrets-file`. It is declared in `api/cloudflare.config.ts` as `bindings.secret()`; it is never in the repo.

    mkdir -p ~/.config/cobalt && chmod 700 ~/.config/cobalt
    node -e "console.log(JSON.stringify({COBALT_API_KEY: crypto.randomUUID()}, null, 2))" > ~/.config/cobalt/secrets.json
    chmod 600 ~/.config/cobalt/secrets.json

Format: a flat JSON object `{"NAME": "value"}` (a `.env` file, `NAME=value` per line, is also accepted). You never paste
this value anywhere. Client keys are created in the web UI (Settings -> Instances, "API keys").

## 0. D1 database and migration (once, before deploying this version)

The database `cobalt-keys` (id `42f18bb0-837a-47f7-b1e2-606eb705ab6c`, primary in OC) already exists and both Workers
bind it as `DB`. Create the table (this touches the remote database; run it yourself):

    cd deploy/cloudflare/web
    cf d1 migrations list  42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir ../d1/migrations   # shows what is unapplied
    cf d1 migrations apply 42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir ../d1/migrations

Use the globally installed `cf`, not `npx cf`: on 2026-09-29 the project-pinned copy failed the remote apply with
`[7403] account is not valid or is not authorized`, while the global one applied `0001` fine with the same login.
(`cf d1 migrations` takes the database ID, not its name; `--dir` defaults to `./migrations`. Applied files are recorded
in the `d1_migrations` table, so re-running only applies new ones. Add future schema changes as new numbered files (`0001` api_keys, `0002` request_log, `0003` studio, `0004` library); never edit an applied one.) Deploy the web and API Workers after the table exists; until then `/api/keys` answers 500 and `POST /` answers
503, and nothing is forwarded to the container.

## 1. Deploy the API

Before the first deploy of the WebP feature the R2 bucket and its public domain must exist (the deploy binds
`MEDIA` to `cobalt-media`; a missing bucket fails the deploy). Owner steps, once (R2 must be enabled on the account):

    cf r2 buckets create-by-name cobalt-media          # or: dashboard -> R2 -> Create bucket "cobalt-media"
    # then: dashboard -> R2 -> cobalt-media -> Settings -> Custom Domains -> media.capybaraharmony.com
    # (do NOT enable the r2.dev public URL). The cf command name is unverified against a live account.

The public URL base is the `MEDIA_BASE_URL` text var in `api/cloudflare.config.ts`.

    deploy/cloudflare/api/prepare-git-info.sh          # from the repo root; writes api/.gitinfo (see below)
    cd deploy/cloudflare/api
    npm install && npm test && npm run typecheck
    cf deploy --dry-run --secrets-file ~/.config/cobalt/secrets.json   # optional: builds the image, uploads nothing
    cf deploy --secrets-file ~/.config/cobalt/secrets.json             # builds, pushes the image, uploads the Worker + secret

(`npm run dry-run` / `npm run deploy` do the same and also run `prepare-git-info.sh`; the secrets path can be
overridden with `COBALT_SECRETS_FILE`.) The first deploy provisions the container; allow a few minutes before
requests succeed. Until the secret exists the Worker answers 503 and never wakes the container.

Rotating the internal key: a container rollout restarts the running instance with the env it was *last started with*,
so after the 2026-09-29 rotation every request failed with `error.api.auth.key.not_found` (Worker had the new key,
container the old one). `CobaltContainer` now stores a fingerprint of its env when it starts and destroys and restarts
the container on the next request if the env changed, so rotation just needs a deploy. The first request afterwards
takes ~10 s. When only Worker code changed, `--containers-rollout none` skips the image rollout.

`prepare-git-info.sh` is required before every build: the API reads `.git/HEAD`, `.git/config` and `.git/logs/HEAD`
at startup (`packages/version-info`), and in a git worktree `.git` is a file. The script writes a minimal synthetic
git dir to `api/.gitinfo/` (gitignored) from `git rev-parse HEAD`, the current branch and the `origin` URL, and the
Dockerfile copies it to `/app/.git` instead of the build stage's `.git`. It works from any checkout.

## 2. Build and deploy the web app

    deploy/cloudflare/build-web.sh                     # from the repo root; writes web/build
    cd deploy/cloudflare/web && npm install
    cf deploy --dry-run                                # optional
    cf deploy

The web `cloudflare.config.ts` declares an entrypoint (`web/src/index.ts`), the `DB` and `ASSETS` bindings, the
`ACCESS_TEAM_DOMAIN`, `ACCESS_AUD`, `OWNER_EMAIL` and `WEB_ORIGIN` text vars, and
`assets.runWorkerFirst: ["/api/keys", "/api/keys/*"]`: only those paths run the Worker, everything else is served
straight from the static assets. Checks (in `web/` and in `api/`): `npm test && npm run typecheck`.

`build-web.sh` runs `pnpm install --frozen-lockfile` and the web build with `WEB_DEFAULT_API=https://api.capybaraharmony.com/`
and `WEB_HOST=cobalt.capybaraharmony.com` (override via env; `PNPM` overrides the pnpm command, default
`npx pnpm@9.6.0`). It builds in a temporary copy that has a synthetic `.git`, because the build prerenders
`/version.json` from git metadata and fails with ENOTDIR in a worktree. `web/build/_headers` carries the COOP/COEP
headers needed for in-browser remuxing.

## 3. Access (dashboard, Zero Trust) for cobalt.capybaraharmony.com only

Add a self-hosted application for `cobalt.capybaraharmony.com`, policy Allow -> Emails -> owner address,
login method One-time PIN. Do NOT put Access on `api.capybaraharmony.com`: the web app's cross-origin
fetches carry no Access cookie, so they would all be redirected to the login page.

The web Worker's `/api/keys` does not assume Access is in front of it: it verifies the `Cf-Access-Jwt-Assertion`
header itself (RS256 signature against `https://harmonyvt.cloudflareaccess.com/cdn-cgi/access/certs`, `aud` = the
application's AUD tag, `iss`, `exp`/`nbf` with 60 s skew, and `email` equal to `OWNER_EMAIL`). If the team domain,
AUD tag or owner email change, edit the vars in `web/cloudflare.config.ts` and redeploy the web Worker.
UNTESTED against production: that Access injects `Cf-Access-Jwt-Assertion` on a Worker custom domain. If
`/api/keys` answers 401 while signed in, check that header first (browser devtools, request headers).

## API keys

The owner creates and revokes named keys in the web app; the API Worker gates every `POST /` on them.

- `GET /api/keys`, `POST /api/keys` `{"name"}`, `DELETE /api/keys/:id` on the web origin (Access JWT required; POST and
  DELETE also require `Origin: https://cobalt.capybaraharmony.com`). At most 50 active keys.
- Only the lowercase hex SHA-256 of a key is stored (`api_keys.key_hash`). The plaintext UUID is shown once, at creation.
- On `POST /` the API Worker runs one statement, `UPDATE api_keys SET last_used_at=? WHERE key_hash=? AND revoked_at
  IS NULL RETURNING id`. No row: 401 `error.api.auth.key.invalid`. D1 error: 503, never forwarded. A row: the request is
  forwarded to the container with `Authorization` replaced by the internal `COBALT_API_KEY`.

### Using a key from scripts or iOS Shortcuts

    curl -sS https://api.capybaraharmony.com/ \
      -H 'Authorization: Api-Key <your key>' \
      -H 'Accept: application/json' -H 'Content-Type: application/json' \
      -d '{"url":"https://example.com/video"}'

In Shortcuts: "Get Contents of URL", method POST, URL `https://api.capybaraharmony.com/`, headers
`Authorization: Api-Key <key>`, `Accept: application/json`, request body JSON `{"url": <shared URL>}`. The response is
cobalt's usual JSON (`status`, `url`, ...); tunnel links it returns are fetched with a plain GET (no key).

### Rotating the internal key

    node -e "console.log(JSON.stringify({COBALT_API_KEY: crypto.randomUUID()}, null, 2))" > ~/.config/cobalt/secrets.json
    chmod 600 ~/.config/cobalt/secrets.json
    deploy/cloudflare/api/prepare-git-info.sh
    cd deploy/cloudflare/api && cf deploy --secrets-file ~/.config/cobalt/secrets.json

Nothing else changes: client keys keep working and no client is told. The container reads its key file at start, and
the single `main` instance keeps the old internal key until it stops (it sleeps after 2 minutes idle; unverified whether
a secret change or redeploy restarts it sooner). Until then requests can fail upstream (the Worker sends the new key,
the container still holds the old one); wait for the instance to sleep, or redeploy again.

### Accepted trade-offs

- Hosted WebPs are PUBLIC to anyone with the URL; the only protection is the unguessable 10-character base62 name
  (about 60 bits). Any valid client key can delete any object (there is one owner; the object's `keyId` metadata records
  who made it but delete does not check it).
- All client keys share the one container-side key, so the 60 requests/min limit is shared by every client key together,
  not per key.
- Revoking a key stops new `POST /` calls immediately, but tunnel links it already obtained keep working until they
  expire (about 90 s): `GET /tunnel` is authenticated by its signed query, not by a key.
- The web app's settings export includes the browser's stored key, so treat an export file like the key itself.
- Every accepted API request costs one D1 write (`last_used_at`); at this scale that is far inside D1's limits.

## After pulling upstream

`git pull --ff-only upstream main`, then diff the root `Dockerfile` against
`deploy/cloudflare/api/Dockerfile`; they must match except for the final `CMD`, the `/app/.git` copy and the
`/app/webp-helper` copy + `EXPOSE 9100`, and the final-stage `apk add libwebp-tools` (the four documented deviations). If upstream changes how the API starts
(`node src/cobalt`) or where `ffmpeg-static` lives, update `api/helper/supervisor.js` too. Rebuild web and redeploy both. If upstream changes the tunnel query parameters
(`api/src/stream/manage.js`) or auth error codes (`api/src/security/api-keys.js`), update `api/src/gate.ts`.

## Gate rules (api/src/gate.ts)

OPTIONS: forwarded only from the web origin, else 403. POST /: needs `Authorization: Api-Key <key>` with a lowercase-UUID
key (401 with cobalt's JSON error otherwise); a well-formed key is then checked against D1 (see "API keys"). GET /: forwarded only from the web origin, else 404. GET /tunnel: needs
id, exp, sig, sec, iv and an unexpired `exp` (ms), else 404. POST /webp, GET /webp/:id (id = 16-32 alphanumerics) and
DELETE /media/:name (name = 10 alphanumerics + `.webp`) need the same well-formed key and D1 lookup; a malformed id or
name is a 404. `/studio*` (no key except `POST /studio`, which needs a well-formed key plus the D1 lookup like `POST /webp`):
`OPTIONS` from the web origin is answered by the Worker (else 403); `GET /studio/<22 alnum>`, `GET|HEAD .../source`,
`POST .../render` and `GET .../render/<20 alnum>` are the id-as-credential routes; a malformed id or any other path or
method is a 404 (see "cobalt studio"). `POST /studio/<sid>/publish` needs a key like `POST /studio`; `POST /library/adopt`
needs the library service credential and nothing else (see "cobalt library"). The native app's routes (see "App routes"):
`GET /capabilities` needs nothing (a missing, malformed or unknown key is reported in the body, never a 401);
`PUT /studio/upload`, `GET /library`, `GET|HEAD /library/items/<16 alnum>/file`, `POST /library/items/<16 alnum>/publish|studio` and
`DELETE /library/items/<16 alnum>/post` (deletes the whole post of any one of its files, D1 + R2 only; `APP-API-CONTRACT.md` section 12)
need a well-formed key plus the D1 lookup, and are checked before the studio session-id rule (`/studio/upload` is the one
`/studio/<x>` path whose second segment is not a session id); `/studio/upload/adopt` is internal to the Worker and a 404 from
outside. A caller that sends the right
`x-cobalt-service` header counts as a valid key (id `service:library`) on every keyed route. Everything else 404.
None of the rejections wake the container. The container is single-instance because tunnel state is in memory.

The Worker strips `cf-container-target-port` (any case), `x-cobalt-key-id` and `x-cobalt-service` from EVERY incoming
request before it can be forwarded (`api/src/headers.ts`), and the Durable Object strips them again. The Containers library honours
`cf-container-target-port` in `Container.fetch()`, so without this a client could pick any container port (such as the
internal helper's 9100) and bypass the gate. `x-cobalt-key-id` is how the Worker tells the Durable Object which key
(D1 `api_keys.id`) passed the lookup; a client-sent copy would be an identity spoof.

## Animated WebP hosting

Turns a video link into a looping animated WebP (the whole video by default, up to 60 s), hosted in R2, for pasting where an image is wanted (built for an
iOS Shortcut). Same auth as `POST /`: `Authorization: Api-Key <key>` (a client key from the web UI). Clients branch on
the JSON `status` field only.

    # 1. start a job
    POST https://api.capybaraharmony.com/webp
      body {"url":"https://twitter.com/X/status/1697304622749086011"}
      -> {"status":"pending","id":"<20 chars>"}   |   {"status":"error","error":{"code":"..."}}

    # 2. poll (long-poll: the request holds up to `wait` seconds, default 20, max 25)
    GET https://api.capybaraharmony.com/webp/<id>?wait=20
      -> {"status":"pending","id":"<id>"}
       | {"status":"success","id":"<id>","url":"https://media.capybaraharmony.com/<name>.webp",
          "bytes":..,"width":..,"height":..,"seconds":..}
       | {"status":"error","error":{"code":"..."}}

    # 3. delete (idempotent: deleting a missing name also succeeds)
    DELETE https://api.capybaraharmony.com/media/<name>.webp   -> {"status":"success"}

All three take `Authorization: Api-Key <key>` and `Accept: application/json` (POST also `Content-Type: application/json`).

`POST /webp` body (all but `url` optional; numbers may be sent as strings):

| field     | values                              | default |
|-----------|-------------------------------------|---------|
| `url`     | http(s) link, at most 2048 chars    | required |
| `start`   | seconds into the video, 0 to 3600   | 0 |
| `length`  | seconds, 1 to 600 (sanity bound)    | none: from `start` to the end of the video |
| `width`   | 320, 480 or 640 (height follows)    | 480 |
| `fps`     | integer 10 to 25                    | 15 |
| `quality` | `low`, `med`, `high` (q 65/75/85)   | `med` |

There is no default length: the whole video is converted, and the helper (not the request) gates how long that may be:
after downloading it reads the video's duration, and a clip (`length`, capped at what remains after `start`) over
`WEBP_MAX_SECONDS` (default 60) is refused with `error.webp.too_long` without encoding. A `start` at or past the end of
the video is `error.webp.invalid_params`. `seconds` in the success body is the length actually encoded. Trim a long
video with `start` and `length`.

Anything else: 400 `error.webp.invalid_params`. The HTTP status is informational (202 pending, 200 for a finished job
whether it succeeded or failed, 400/404/429/5xx for request-level problems); branch on `status`. Error codes: cobalt's
own `error.api.*` codes pass through unchanged (unsupported link, unavailable video, ...), plus `error.webp.busy` (429:
an encode is already running), `error.webp.not_found` (unknown id, or one made by another key), `error.webp.no_video`
(picker with no video), `error.webp.unsupported` (cobalt asked for local processing), `error.webp.bad_source`,
`error.webp.download_failed`, `error.webp.too_large` (source over 300 MB or output over 25 MB), `error.webp.too_long` (the clip to encode is over
`WEBP_MAX_SECONDS`, default 60; nothing is encoded), `error.webp.timeout`
(download over 120 s or encode, both steps together, over 240 s), `error.webp.encode_failed`, `error.webp.job_lost` (the container restarted
mid-job), and the retryable infrastructure codes `error.webp.storage`, `error.webp.upstream`, `error.webp.unavailable`.

### How it works

- The Worker gates `/webp*` and `/media*` with the same D1 key lookup as `POST /`, then forwards to the same `main`
  Durable Object with the key's id in `x-cobalt-key-id`.
- The container entrypoint (`api/helper/supervisor.js`, plain Node, no dependencies) runs `node src/cobalt` as a child
  (exiting with its code, forwarding SIGTERM/SIGINT) and serves a helper API on port 9100. Every request needs
  `x-internal-key` = the Worker's `COBALT_API_KEY` (passed in as `COBALT_INTERNAL_KEY`), else 403. Port 9100 is
  reachable only through the Durable Object (the Worker strips `cf-container-target-port`).
- A job: ask the local cobalt (`POST http://127.0.0.1:9000/`, internal key, `alwaysProxy`, 720p) for the source, rewrite
  its tunnel URL to the local origin (an unexpected host is refused), DOWNLOAD it to `/tmp/webp/<id>/in` (a local file:
  moov-at-end mp4s need seeking), read its duration from `ffmpeg -i in` (no ffprobe in the image; `Duration: N/A` counts as unknown), work out the clip
(`min(length, duration - start)`, refused when over `WEBP_MAX_SECONDS`, with 0.5 s of slack for "60 s" videos that
report 60.03), then encode in two steps. (1) the image's ffmpeg-static decodes the clip window to PNG frames in
  `/tmp/webp/<id>/frames/` (`-ss start -t clip -i in -vf fps=N,scale='min(W,iw)':-2:flags=lanczos`, never upscaled). (2) Google's
  `img2webp` (Alpine `libwebp-tools`, installed in the image's final stage) encodes them, run with the frames dir as cwd so
  argv holds short relative names: `-loop 0 -d round(1000/N) -lossy -q Q -m 4 -kmin 3 -kmax 5 f00001.png ... -o out.webp`
  (Q = 65/75/85 for low/med/high). The frames dir is deleted afterwards, success or failure. Why not ffmpeg's
  `libwebp_anim`: WebPAnimEncoder only re-encodes changed sub-rectangles and ffmpeg exposes no keyframe interval, so stale
  blocks from earlier scenes stayed visible ("ghosting"), and raising quality only hid them (q85 = 2.06 MB, still faint
  blocks). Forced keyframes every 3 to 5 frames fixed it (on the owner's 9.6 s 480x560 clip: 1.27 MB at q75, clean;
  `-kmax 15` brought the blocks back, so do not raise it). Size, frame
  count, duration and canvas dimensions are read from the output's RIFF chunks (no ffprobe in the image).
  A non-zero exit from either step is `error.webp.encode_failed`; the 240 s budget covers both steps together.
- `GET /webp/:id` polls the helper about once a second. Every poll goes through `containerFetch`, which renews the
  `sleepAfter` timer, so a job someone is polling keeps the container awake. When the encode is done the Durable Object
  copies the file into R2 as `<10 random base62>.webp` (`Cache-Control: public, max-age=31536000, immutable`, custom
  metadata `keyId`, `source`, `service`, `createdAt`), stores the result under the id and deletes the helper's copy;
  polling again returns the same result. Job and result records live in the DO's storage and are pruned after 24 h.
- One encode at a time (0.25 vCPU): a second `POST /webp` while one runs gets 429 `error.webp.busy`. The helper keeps
  the last 20 jobs in memory and expires finished ones after 30 min.

### Limits and caveats

- Source download at most 300 MB, output at most 25 MB (`WEBP_MAX_BYTES`), clip at most 60 s (`WEBP_MAX_SECONDS`), at
  most 640 px wide and 25 fps, ffmpeg plus img2webp killed after 240 s in total (`WEBP_FFMPEG_TIMEOUT_MS`). These are container env vars read
  by the helper; the deploy does not set them, so the defaults apply (add them to `envVars` in `src/index.ts` to
  change them, which restarts the container once). Measured locally with the img2webp pipeline (`--cpus 0.25`, linux/amd64 image
  emulated on an arm64 Mac, so real Cloudflare timings will differ; single runs): the owner's 9.6 s 480x560 clip end to end
  (resolve, download, probe, frames, encode) took 71 s and produced 1.27 MB; the 6 s 480x480 sample took 20 s and 214 KB.
  Native arm64 encode of the 9.6 s clip alone was 3.9 s at full CPU. The earlier libwebp_anim figures (6 s clip in 7 s,
  a synthetic 60 s 720p video in 64 s) no longer apply and the 60 s case has NOT been re-measured with img2webp, so the
  240 s headroom for a 60 s clip is unproven.
- The PNG frames live in the container's `/tmp` until the encode ends: 144 frames of the 9.6 s clip took 58 MB
  (about 400 KB each at 480x560). Scale that by frames and size (60 s x 25 fps x 640 px is 1500 frames, on the order of
  1 GB) and check it against the instance disk before allowing long, wide, high-fps jobs. If the duration cannot be read the encode is
  capped at `WEBP_MAX_SECONDS` instead of being refused (a longer video is cut short), and the helper logs it.
- The output is buffered in the Durable Object (128 MB memory) on its way to R2, so `WEBP_MAX_BYTES` should stay well
  under about 60 MB. Helper calls from the DO time out after 15 s (60 s for the result download); jobs are async, so a
  long encode does not hold any call open.
- The result is collected when someone polls, and (since the job sweep, see "App routes") also by the Durable Object
  itself every 5 s while a job is pending, so a client that goes away no longer loses the job to `sleepAfter` (now 45 s).
  The sweep is verified by fakes only until deployed; until you have seen it work live, treat "poll until `success` or
  `error`" as the safe habit. Download (up to 120 s) plus encode (up to 240 s) fits the sweep's 6-minute budget; a job
  older than that, or one whose container died, ends as `error.webp.job_lost`.
- Media is PUBLIC by name (see accepted trade-offs). To delete: `DELETE /media/<name>.webp` with any client key, or
  remove the object in the R2 dashboard. There is no automatic expiry; add an R2 lifecycle rule on `cobalt-media` for one.
- The first deploy after this change restarts the container once: its env gained `COBALT_INTERNAL_KEY`, which changes
  the env fingerprint (allow about 10 s on the next request).
- YouTube is not a goal here (see CLAUDE.md); whatever cobalt itself can fetch works.

## cobalt studio (`/studio*`, API half)

Contract: `STUDIO-CONTRACT.md` (pinned; the web page and the Shortcut are built against it). Turns a shared link into a
private saved copy of the video, then lets the owner's studio page render animated WebPs from that copy without asking
cobalt again. This section covers the API Worker, Durable Object and container helper; the page itself is under `web/`.

Prerequisites (owner steps): apply migration `0003_studio.sql` (below) and make sure the R2 bucket `cobalt-originals`
exists (private, OC; it does; the deploy binds it as `ORIGINALS` and fails if it is missing). Do NOT give it a public domain.

    cd deploy/cloudflare/web
    cf d1 migrations apply 42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir ../d1/migrations

(the global `cf`, not `npx cf`; see section 0). Until it is applied `/studio*` answers 503. Deploy the API afterwards.

### Routes

| route | who answers | key | notes |
|-------|-------------|-----|-------|
| `POST /studio` `{url}` | Worker (D1 key lookup) -> DO | yes | 201 `{status,id,url}` right away (the DO tries once to start the download first, at most 4 s) |
| `GET /studio/<sid>[?wait=N]` | Worker reads D1; while `saving` it forwards to the DO | no | N <= 25. `ready` / `error` / expired come from D1; a `saving` session is advanced by the DO (below) and the DO holds the request for up to N s |
| `GET`/`HEAD /studio/<sid>/source` | Worker, R2 only | no | `Range` -> 206; never wakes the container; `?wait=0..90` holds it while the save runs (APP-API-CONTRACT section 11) |
| `POST /studio/<sid>/render` `{start,length,width?,quality?}` | Worker -> DO | no | 202 `{status:"pending",job}` |
| `GET /studio/<sid>/render/<job>[?wait=N]` | Worker -> DO | no | pending, success (public WebP URL) or error |
| `OPTIONS /studio*` | Worker | web origin only | 204; anyone else 403 |

Internally the Worker forwards a `saving` session's poll to `GET /studio/<sid>/advance?wait=N` on the DO. That path is not
public: the gate answers 404 for `/studio/<sid>/advance`, so only the Worker's own forward reaches it.

Ids are validated by regex before any lookup (`sid` 22 base62, `job` 20 base62; anything else is a 404). The session id is
a capability (>= 128 bits): the routes that take it need no API key. Every `/studio*` response carries
`access-control-allow-origin: https://cobalt.capybaraharmony.com`. `POST /studio` goes through the same free-text link
extraction as `POST /` and is logged to `request_log` as `POST /studio` after extraction (never the raw text). A body with
no http(s) link is `400 error.studio.no_link` before the container is involved. Errors are always
`{"status":"error","error":{"code":...}}`.

### Storage and lifetimes

- D1 (`0003_studio.sql`): `studio_sessions` (one saved video: link, service, title, status `saving|ready|error`, R2 key,
  content type, bytes, duration, width, height, `created_at`, `expires_at`) and `studio_renders` (one per render request,
  with the requested params and, once done, the public URL and output size). Timestamps are ms.
- R2 `cobalt-originals`, key `originals/<sid>.<ext>` (`mp4` normally; `webm`, `mov`, `mkv`, `m4v` when the download says
  so), at most 200 MB. Sessions live 7 days (`expires_at`; past it every route answers 410) but the object is KEPT after
  expiry (the future gallery will use it); there is no cleanup job and no lifecycle rule on this bucket.
- Rendered WebPs go to the public `cobalt-media` bucket exactly like `/webp` (same `MEDIA` upload code, unguessable name).
  `DELETE /media/<name>.webp` does not touch the `studio_renders` row, which would keep listing that URL.
- Render job records live in the DO's storage for 24 h (same as `/webp`); the session's render list comes from D1.

### Limits

- Render: length 0.5 to 10 s (over is `error.webp.too_long`, under or junk `error.webp.invalid_params`), `start >= 0`,
  `start + length <= duration + 0.05` (checked only when the duration is known), `width` 320 or 480 (default 480),
  `quality` low, med or high (default med), 15 fps. The stored and reported `width` is `min(requested, source width)`; the
  helper is asked for the requested width and its `scale='min(W,iw)'` never upscales. `start` and `length` are required.
- Save: source at most 200 MB (`error.studio.too_large`), download at most 240 s (helper) and 8 min per helper fetch
  (`error.webp.timeout`). One helper job at a time: a save waits up to 2 minutes for a running encode before failing
  `error.studio.busy`; `POST /studio` answers 429 `error.studio.busy` at once when this DO already has a save in flight or an
  encode it started in the last 5 minutes; a render answers 429 `error.webp.busy` when the helper (or a save) is busy.
- The save only moves while the studio page is open: the page polls `GET /studio/<sid>?wait=...` while `saving`, and those
  polls are what run the save. A session nobody has polled for 10 minutes (measured from the last advance attempt, not from
  creation) becomes `error.studio.save_lost` on the next look (or when the next `POST /studio` or render sweeps it), and its
  helper copy is dropped. The page always polls while saving, so a live page never hits this; a shortcut that saves a link
  and is never opened does.
- Extra codes beyond the contract's examples: `error.studio.storage` (R2 write failed or the file length did not match),
  `error.studio.unavailable` (container would not start or stopped answering for 30 s), `error.studio.save_lost` (no poll for
  10 min, or the container lost the download 3 times), `error.studio.busy` (helper busy for 2 min),
  `error.studio.bad_range` (416), plus the existing `error.webp.*` and cobalt `error.api.*` codes.

### How a save works

A background task started from the POST does NOT survive: Cloudflare stops a Durable Object's `waitUntil` work once the
request that started it has answered (measured 2026-09-30: the row stayed `saving` for over 10 minutes and nothing reached R2).
So the save is poll-driven, exactly like a WebP job: every client poll goes through the DO and moves it one step. The DO keeps
`save:<sid>` in its storage, `{phase: "starting" | "fetching", startedAt, attempts, lastAdvance, ...}`.

1. `POST /studio` (after the key lookup and the link check) reaches the DO, which inserts the row as `saving`, writes the
   `save:<sid>` record, tries one step (start the helper fetch, at most 4 s) and answers 201 whatever came of it.
2. The studio page polls `GET /studio/<sid>?wait=N`. The Worker reads D1; if the row is `saving` and not expired it forwards to
   the DO's `GET /studio/<sid>/advance?wait=N`, which loops until the deadline, one step at a time, one second apart:
   - `starting`: helper `POST /fetch {id: <sid>, url}` (the helper resolves through cobalt at `127.0.0.1:9000` with the internal
     key, downloads to `/tmp/fetch/<id>/in` with the 200 MB cap, reads duration, width, height and the content type, takes a
     title from cobalt's filename). 202 moves the record to `fetching`. 429 (helper busy) keeps the session `saving` and is
     retried every 2 s; a 429 for a fetch the helper already has (our accept got lost) is recognised and is not busy; after 2
     minutes of busy the save fails `error.studio.busy`.
   - `fetching`: `GET /fetch/<id>`. `pending` keeps waiting (this also keeps the container awake). 404 means the container
     restarted and forgot the fetch: it is started again (3 attempts in all, then `error.studio.save_lost`). `error` fails the
     session with that code. `done`: the same request streams `GET /fetch/<id>/file` into R2 with a `FixedLengthStream` of the
     known length (never buffered in the DO, 128 MB), sets the row `ready` with the metadata, deletes the helper copy and the
     record, and answers with the finished session.
   The answer is always the session JSON of `GET /studio/<sid>`.
3. Two polls of the same session never advance it at once (an in-memory lock in the DO): the second waits for the first and
   answers from D1. If a client aborts a poll during the R2 copy, the next poll finds the helper's finished file and copies
   it again (the R2 write is idempotent).
4. Failure at any step sets `error` with the code (cobalt's `error.api.*` passed through) and drops the helper copy. If the
   Worker cannot reach the DO, or it answers 5xx, the page gets the D1 row (`saving`) and simply polls again.

### How a render works

`POST /studio/<sid>/render` checks the session (404, 410, 409 `error.studio.not_ready`), validates the params, then streams
the R2 original into the helper: `POST /jobs/upload?id=&start=&length=&width=&fps=15&quality=` with the video as the request
body. The helper writes it to `/tmp/webp/<id>/in` (at most 200 MB) and runs the same encode as `/webp` (ffmpeg frames, then
img2webp), skipping cobalt and the download. Polling `GET .../render/<job>` goes through `WebpService.status`, which
uploads the finished WebP to `cobalt-media` when it is done; the DO records the result (or the error) in `studio_renders`.

### Helper endpoints (port 9100, `x-internal-key`, one job at a time)

`POST /fetch`, `GET /fetch/<id>`, `GET /fetch/<id>/file`, `DELETE /fetch/<id>`, `POST /jobs/upload`; the older `/jobs`
routes are unchanged. Its HTTP server lives in `api/helper/server.js` (testable with stubs); `supervisor.js` only starts cobalt
and the server.

### Verified and unverified

Verified locally (2026-09-30): unit tests against the real SQL (`npm test`), and a real container (`linux/amd64`,
`--cpus 0.25`, `--memory 1g`) running the helper: `POST /fetch` on
`https://x.com/maria_rcks/status/2105237035271258436` finished in about 9 s (duration 9.6 s, 480x560, 482,592 bytes, mp4) and
`POST /jobs/upload` of that file (start 2, length 5) produced a valid animated WebP (RIFF/WEBP, ANIM, 72 frames, 592 KB)
in about 34 s; the temp files were removed by `DELETE`. NOT verifiable before deploy: the Worker + DO + R2 paths (streaming the
helper response into R2 with `FixedLengthStream`, streaming an R2 object as the helper's request body, D1 writes from the DO,
the Worker -> DO advance forward) run only on Cloudflare; the tests use fakes for them. The `waitUntil` background save
originally shipped here did NOT work on the deployed Workers (see "How a save works"); the poll-driven save replacing it is
covered by fakes only until it has been deployed and a real save has reached `ready`.

## cobalt library (API half)

Contract: `LIBRARY-CONTRACT.md` (pinned; the web lane builds against it). The library is the owner's list of every file the
deployment holds: public (R2 `cobalt-media`) and private (R2 `cobalt-originals`). This section is the API Worker, Durable
Object, helper and D1 side; the page and `/api/library*` routes are under `web/`.

Prerequisites (owner steps, nothing here was run remotely): apply migration `0004_library.sql` (global `cf`, as in section 0),
deploy the API, then run the backfill once for what existed before the library.

### Service auth (web Worker -> API Worker)

The web Worker calls the API with `x-cobalt-service: <COBALT_API_KEY>` (the same internal secret, constant-time compared in
`api/src/service-auth.ts` by hashing both sides). A match is authenticated as key id `service:library` and works wherever an
`Api-Key` does (`POST /`, `POST /webp`, `GET /webp/<id>`, `DELETE /media/<name>`, `POST /studio`, publish); a wrong or empty
value is ignored as if absent. The header is read from the incoming request before the strip and is never forwarded (Worker,
DO and the tests all enforce it). `POST /library/adopt` accepts the service credential ONLY.

### Routes

| route | who answers | auth | notes |
|-------|-------------|------|-------|
| `POST /studio/<sid>/publish` | Worker, D1 + R2 only | Api-Key or service | 201 `{status,url,bytes,content_type,item_id}`; 409 `error.studio.not_ready`, 404, 410 expired, 502 `error.studio.storage` |
| `POST /library/adopt` `{r2_key,name,content_type,bytes,item_id}` | Worker -> DO | service only | 201 `{status,id,url}`; 400 `error.studio.not_video` (only `video/*` and `image/gif`), 400 `error.studio.invalid_params`, 413 `error.studio.too_large`, 429 `error.studio.busy` |

Publish copies the session's stored original (`originals/<sid>.<ext>` or an adopted `uploads/<id>.<ext>`) to the public
bucket under a new 10-character name keeping the extension, with the session's content type and
`cache-control: public, max-age=31536000, immutable`, and inserts a `host` item. The R2 object's own body is handed to
`MEDIA.put()`: no buffering, no `FixedLengthStream`, and no `ReadableStream.pipeTo()` (unimplemented between streams in this
runtime; the tests make `pipeTo`/`pipeThrough`/`tee` throw on the body to prove it). Publishing twice makes two public copies.

Adopt makes a studio session (`status saving`, `service "upload"`, `link "upload:<item_id>"`, `title` = the file name,
`r2_key` as given, 7-day lifetime) out of an upload that is already in `cobalt-originals`, with no cobalt fetch. The probe is
poll-driven like the save: nothing runs after the 201, and the first `GET /studio/<sid>` poll (record phase `probing`) streams
the object into the helper's `POST /probe?id=<sid>` with a known `content-length`, then sets the row `ready` with
`duration`, `width`, `height` and the object's size. A busy helper (429) is retried every 2 s for up to 2 minutes
(`error.studio.busy`), an unreachable one for 30 s (`error.studio.unavailable`), a hung call is cut at 50 s by the DO's own
race (`probeTimeoutMs`), and a refused file ends the session with the helper's code (`error.studio.not_video`,
`error.studio.too_large`) or `error.studio.storage` when the object is missing. The upload object is never deleted by a failed
adopt. A session whose record was lost (DO storage reset) still probes (a `service "upload"` row is never fetched). The adopted
session is NOT a new `saved` item: the upload already is the item. Once `ready` it renders, serves `/source` and expires exactly
like a saved one.

Helper endpoint: `POST /probe?id=<16-32 alnum>`, body = the video bytes (at most 200 MB, written to `/tmp/probe/<id>/in`),
answers `200 {duration,width,height}` (`duration` can be null, e.g. a gif without one), `400 error.studio.not_video` (empty body
or no video stream), `413 error.studio.too_large`, `429 error.webp.busy`. The file is deleted before the answer goes out. While
a probe runs the helper counts as busy (one job at a time), and a pending job makes a probe 429.

### What writes `media_items` (migration `0004_library.sql`)

| source | when | kind / bucket | written by |
|--------|------|---------------|------------|
| `webp` | a `POST /webp` job's file reaches R2 (`key_id` = the job's key, `link` = the source URL) | public / media | `WebpService.upload` |
| `studio` | a studio render turns `success` (once, on the transition) | public / media | `StudioService.renderStatus`; `link` is null for an upload's render |
| `saved` | a studio save (not an adopt) becomes `ready` | private / originals | `StudioService.finalize` |
| `host` | publish | public / media | `publishStudio` |
| `upload` | web lane | private / originals | web Worker |

Every insert is guarded by `WHERE NOT EXISTS (same bucket and r2_key)` and swallows its own errors (logged as
`[library] ...`): bookkeeping never fails the download, save, render or publish it belongs to. Cost of that choice: a D1 blip
at the wrong moment leaves a file without a row until the backfill is run again (it is idempotent). Webp-service jobs whose
owner label is `studio:<sid>` are recorded by the studio, not as `webp`. `DELETE /media/<name>` (existing route) now also sets
`deleted_at` on the live `media` row for that name; it still only accepts `<10 alnum>.webp` names, so a published `.mp4` is
deleted through the web lane's `/api/library/items/<id>` instead.

### Backfill (`scripts/backfill-library.mjs`, run by the owner)

    node deploy/cloudflare/scripts/backfill-library.mjs --dry-run   # reads D1 and R2, prints what it would add, writes nothing
    node deploy/cloudflare/scripts/backfill-library.mjs             # adds it

Uses the global `cf` (`cf d1 query <db-id> --sql ... / --batch ...`, `cf r2 objects list --bucket-name cobalt-media`; typed
`NULL`/number parameters go in `--batch` JSON because `--params` only carries strings). Adds `saved` rows for ready sessions
that are not uploads, `studio` rows for successful renders, and a `webp` row for every `cobalt-media` object nothing above
explains (using the object's `customMetadata` for key id, source link and time when present; `keyId` starting with `studio:`
makes it a `studio` row). Rows already present (same bucket + key) are skipped, and so is a second run. `--db`,
`--media-bucket`, `--media-base-url` and `--cf` override the defaults.

### Verified and unverified

Verified (2026-10-02): `npm test` and `npm run typecheck` in `api/` (real SQL on every migration; Worker + DO routes wired
through fakes; the backfill against a fake `cf` binary). A real container (`linux/amd64`, the previous image with the new
`helper/` mounted over it) answered `POST /probe` for an mp4 (320x240, 2 s) and a gif (160x90, 1.5 s) with the right
`{duration,width,height}`, 400 `error.studio.not_video` for a text file, 403 without the key, and left `/tmp/probe` empty.
NOT verified before deploy: handing an R2 object body straight to another bucket's `put()` in the Worker (the documented copy
pattern, but never run here), the service binding call from the web Worker, the adopt poll across a real Durable Object, and the
backfill against the real `cf` output (its parser accepts the API envelope or the bare result; check `--dry-run` first).

## App routes (the native app, `APP-API-CONTRACT.md`)

The backend half of the Apple app. The contract file is the pinned reference for shapes; this is what exists and what is
and is not verified. Everything is additive: no existing route changed its request or response (the pending answers of
`GET /webp/<id>` and `GET /studio/<sid>/render/<job>` and every session body gained fields, none were renamed). No D1
migration, no new binding, no web change. The Worker-side code is `api/src/app-routes.ts` (no Cloudflare imports, like
`studio-edge.ts`); `worker.ts` dispatches it right after the key lookup, before anything that reads a request body.

| route | auth | answered by |
|---|---|---|
| `GET /capabilities` | none (a key, if sent, is reported) | Worker (D1 for the key at most) |
| `PUT /studio/upload?name=` | key | Worker (R2 + D1), then the DO's internal `POST /studio/upload/adopt` for a video |
| `GET /library?limit=&cursor=` | key | Worker (D1) |
| `GET\|HEAD /library/items/<id>/file` | key | Worker (D1 + R2) |
| `POST /library/items/<id>/publish` | key | Worker (D1 + R2) |
| `POST /library/items/<id>/studio` | key | Worker (D1), then the DO's internal adopt (or reopens a ready session) |

- **`/capabilities`** reports `server: "cobalt-cloudflare"`, the upstream `cobalt.version` (the one `version` field of the
  repo's `api/package.json`, bundled at build time; `null` if it were missing), the feature flags, the limits (imported from
  the constants that enforce them: `MAX_RENDER_SECONDS`, `MIN_RENDER_SECONDS`, `RENDER_WIDTHS`, `RENDER_QUALITIES`, `RENDER_FPS`,
  `MAX_UPLOAD_BYTES`, `MAX_SOURCE_BYTES`, `SESSION_TTL_MS`) and the key's state: `missing`, `invalid` (malformed, unknown or
  revoked), `valid` (with `key_name`), or `unknown` (D1 failed). Never a 401, never the container, `cache-control: no-store`.
- **`PUT /studio/upload`**: content type must be one of gif, webp, png, jpeg, mp4, quicktime, heic (415 otherwise),
  `content-length` numeric (411), at most 100 000 000 bytes (413: Cloudflare's request body limit on this plan), non-zero (400).
  All of that is decided from headers; a refused body is cancelled, never read. The body goes straight from the request to R2
  (`uploads/<16 base62>.<ext>`, a known length, nothing buffered), the `media_items` row records the caller's key id, and a
  video or gif continues into a studio session through the same adopt a library "open in studio" uses. A refused adopt (busy
  helper) is still a 201 with `id: null` and `studio_error`: the file is stored, retry with `POST /library/items/<id>/studio`.
  The request log gets one row (`PUT /studio/upload`, the declared size, `url_type: upload`) and never the body.
  `/studio/upload/adopt` is a 404 from outside (the gate), `x-cobalt-key-id` is stripped from clients as everywhere, and the DO
  refuses the call without it.
- **`GET /library`**: posts, newest first. A post is `COALESCE(session_id, link, id)`, refined so an upload and the webps made
  from it (whose adopted session's link is `upload:<item id>`) are one card. Paged by `MAX(created_at)` then the post key,
  descending; `cursor` is base64url of `<ms>.<post key>`; `limit` 1..50 (default 20); `counts` and `usage` cover the whole
  library. A *saved* original reopened in the studio after its session expired is adopted under a new session whose link is
  `upload:<the saved row's session id>` (not its item id), so its new renders group under the same post key as the saved
  original and the post stays one card; an uploaded original is adopted as `upload:<item id>` as before. Known gap (accepted,
  no migration): an image hosted from an upload shows as a second post next to its private upload (its host row has no session
  or link); a saved row with no session id (backfilled) still groups its reopened renders under its item id.
- **`/library/items/<id>/file`** is `studioSource` for a private file without the 7-day session expiry (same `parseRange`
  rules); **publish** is the web's `itemPublish` with the same reader/writer copy loop (no `pipeTo`); **studio** is the
  web's `itemStudio`.
- **Save progress** (`step`, `step_bytes`, `step_total`, `waking`) on every session body, from the DO's in-memory map: the
  helper's `GET /fetch/<id>` pending answer now carries `stage` (`downloading` or `probing`), `bytes`, `total`; `storing` counts
  the chunks of the R2 copy. After a DO eviction the fields are null / false until the next step.
- **Render progress** (`phase`, `frames_done`, `frames_total`): the helper counts the PNG frames on disk during `decode`
  (minus the newest, which may still be written, capped at the expected total), reports the real count at `pack`, and `fetching`
  while a link job resolves and downloads. The DO keeps the last pending body per job in memory.

### Jobs finish with nobody polling (the sweep)

A result used to be collected into R2 only when someone polled, and the container sleeps 45 s after its last activity, so a
client that went away mid-render lost the WebP. Now accepting a render job, a `/webp` job, a link save or an adopt calls
`scheduleSweep`, which does `schedule(5, "sweepJobs")` on the Containers library's own scheduler (not `alarm()`, which the
library owns), de-duplicated by the storage key `sweep:at` (`src/sweep.ts`). `CobaltContainer.sweepJobs()` runs
`StudioService.sweep()`: every `job:<id>` without a result, accepted within 6 minutes, is collected exactly as a client poll
would (D1, the library item, R2), and every `save:<sid>` that is not locked is advanced one step while its current helper
fetch is younger than 8 minutes + 60 s. It re-arms itself in 5 s while anything is pending; each pass makes helper calls, which
renew the container's activity timer, so the container stays awake exactly while something is pending and the 45 s sleep applies
otherwise. The save budget hangs on `startedAt`, not `lastAdvance`, because the sweep refreshes `lastAdvance` itself, and it is
checked before the lock: a save past it is never advanced and never counted pending, even with a hung step holding its lock; a
lock older than `LOCK_STALE_MS` (60 s) is stale, so the sweep drops it and advances the save like a client poll would.

The Containers library awaits `sweepJobs()` inside its own `alarm()` before it checks `sleepAfter`, so a hung helper call must
not be able to hold the sweep: every `WebpService` helper call is raced against our own ceiling (`callHelper`; job calls 20 s,
the result download 60 s, the studio upload 5 min; `AbortSignal.timeout` is not honoured for `containerFetch` in the DO), each
sweep item is cut at 30 s (`SWEEP_ITEM_MS`, counted pending) and the whole pass at 60 s (`SWEEP_PASS_MS` in `sweep.ts`, counted as
one pending thing). An abandoned call is not cancelled; its result is dropped.

A client long-poll of `GET /webp/<id>` (or a studio render poll) and the sweep can collect the same job. Whoever finishes deletes
the helper's job, so the other's next helper poll is a 404: `WebpService.status()` re-reads `result:<id>` at the top of every loop
pass and on a 404, and `finish()` never overwrites a stored result, so a collected success is never turned into
`error.webp.job_lost` (it was: the macOS Shortcut, `wait=20`, saw `job_lost` for a WebP that was in R2). `renderStatus` also
answers the recorded success when its own D1 update finds the row already settled.

`GET|HEAD /library/items/<id>/file` and `POST /library/items/<id>/studio` take the object's size from R2 (`head`), not the row:
a stale or missing `bytes` no longer gives a 200 for a missing object, a wrong `Content-Range`, or an adopt refused for size 0.

### Verified and unverified (app routes)

Verified: `npm test` and `npm run typecheck` in `api/` and `web/` (the real SQL on every migration; the Worker, the DO's services
and the helper's HTTP server wired through fakes; the 101 MB refusal, bad names, grouping, paging with ties, Range, the sweep's
logic and its scheduling). NOT verified before deploy, all of it runtime behaviour that only exists on Cloudflare:
**that `schedule()` callbacks fire on the deployed runtime while no request is in flight** (the tests prove the sweep logic and
that it is scheduled; a live check is a render started, the client gone, and `studio_renders.status = 'success'` a minute later);
that the container really stays awake across sweeps; a 100 MB upload through the Worker into R2; and `FixedLengthStream` in
the library publish copy (the same loop the web Worker's publish uses).


## Live Activities (APNs push for the Apple app, `APP-API-CONTRACT.md` section 8)

The server half of `apple/CONTRACT-LIVE.md`: the Dynamic Island and Lock Screen activity of a pipeline run is kept current by
ActivityKit pushes sent from the Durable Object, including push-to-start for share-sheet runs (an extension cannot call
`Activity.request`). Only Live Activity pushes; no ordinary alert pushes. No D1 migration, no new binding, no web change: tokens
and runs live in the DO's storage next to `job:`, `save:` and `sweep:at`. Code: `api/src/apns.ts` (JWT, request, answer
table, the two transports), `api/src/live.ts` (store, merge/coalesce rule, payloads, the `/live/*` routes inside the DO),
hooks in `studio.ts`, cadence in `sweep.ts`, `POST /apns` in `helper/server.js`.

### Secrets and bindings

Three secrets, from `~/.config/cobalt/secrets.json` through `cf deploy --secrets-file` like `COBALT_API_KEY` (declared in
`api/cloudflare.config.ts` as `bindings.secret()`):

| name | what |
|---|---|
| `APNS_KEY_P8` | the APNs auth key (`AuthKey_<id>.p8`), the whole PEM as ONE JSON string with `\n` escapes (a doubly escaped `\\n` is tolerated) |
| `APNS_KEY_ID` | the 10-character key id |
| `APNS_TEAM_ID` | the 10-character Apple team id |

and two text bindings with defaults: `APNS_BUNDLE_ID` (`com.capybaraharmony.cobalt`; the topic is
`<bundle id>.push-type.liveactivity`) and `APNS_VIA` (`"worker"`, or `"helper"`). They are read by the Worker (the capability flag)
and the DO (signing, sending); **none** goes into the container's `envVars`, so the container never sees a secret and the env
fingerprint (the restart-on-env-change check) does not change. Producing the JSON string:

    node -e 'const fs=require("fs"),p=process.env.HOME+"/.config/cobalt/secrets.json",j=JSON.parse(fs.readFileSync(p));
      j.APNS_KEY_P8=fs.readFileSync(process.argv[1],"utf8");j.APNS_KEY_ID="<key id>";j.APNS_TEAM_ID="<team id>";
      fs.writeFileSync(p,JSON.stringify(j,null,2))' ~/Downloads/AuthKey_XXXXXXXXXX.p8

Without all three (missing or empty) the server degrades cleanly: `features.live_activity_push` is `false` in `GET /capabilities`,
`PUT /live/runs/<run>` answers `pushing: false, reason: "not_configured"` and stores nothing, no hook sends anything, and the app
falls back to local updates. **Unverified: whether `cf` 1.0.0-beta.5 refuses a declared `bindings.secret()` that is missing from
the secrets file.** `cf deploy --help` only says `--dry-run` skips "uploading the Worker", not that it pushes no container image, so
no dry run was made; if the first deploy refuses, add the three names to the file first (the deploy note below does that anyway).

### Routes (all keyed: `Authorization: Api-Key`; a library-service caller, wrong methods, bad run ids and unknown `/live/*` are 404)

The Worker handles them right after the key lookup (before `describeBody` and `logRequest`: never in `request_log`), drops
`Authorization`, sets `x-cobalt-key-id` and forwards to the DO, whose `handle()` answers `/live/*` first (before the env-fingerprint
check and never through `super.fetch`: **a live route never wakes or restarts the container**) and refuses a request without the
key id (403). Bodies are JSON, at most 4096 bytes (else 400). Errors: `error.live.bad_request` (400), `error.live.not_found`
(404), `error.live.server_stage` (409), `error.live.too_many_runs` (429, the caps below).

| route | answer |
|---|---|
| `PUT /live/start-token` `{token, environment}` | 204; one start token per key (`live:start:<key id>`) |
| `DELETE /live/start-token` | 204 |
| `PUT /live/runs/<run>` | 200 `{status, pushing, started, reason?}` (`reason`: `no_start_token`, `not_configured`, `start_unconfirmed`, `start_rate_limited`); upserts the run (`live:run:<run>`, small index entry `live:idx:<key id>:<run>`, index `live:sid:<sid>`); `start: true` with no update token, no earlier start and a run that has not ended sends the one push-to-start; a new update token while the state differs from what APNs accepted sends one catch-up update (priority 10); 429 `error.live.too_many_runs` past the caps |
| `POST /live/runs/<run>/state` `{state}` | 202; only the device stages `uploading`, `reading`, `ready`, `failed` (409 `server_stage` otherwise); 404 for an unknown run or another key's |
| `DELETE /live/runs/<run>` | 204, idempotent; with an update token and not ended: one `end` push with the stored state, dismissal now, no alert; then the record goes |
| `GET /live/selftest` | the check below |

`pushing` is false when APNs is not configured or the last non-token APNs failure for this key (`live:health:<key id>`) is under
10 minutes old. Validation is strict where Swift would otherwise drop the whole update: the `Int` fields of the content state
(`rail`, `bytes`, `total`, `framesDone`, `framesTotal`, `result*`) must be integers.

### What is pushed, and when

The triggers are the existing transitions, reached by a client poll or by the sweep (no new timers: work after a DO response does
not survive). `StudioService` calls `LiveHooks` (`onSave`, `onRender`), each awaited but raced against `LIVE_PUSH_MS = 3000`
(`raceCeiling`; a hook that throws or hangs never fails or stalls the poll beyond that): every save-progress change (one
`setProgress`; not the adopted-upload probe), a failed save, render accepted, pending (`decode` frames, `pack`), success and
failure (the recorded rows are repeated on every poll, so a lost push is retried). Session `ready` pushes nothing: the device
reads the video then. The merge rule (reset counters and `since` on a stage change, `fetching` keeps the registered `since`,
title and duration carry over) is `nextState()`; the parity test builds every server-written entry of
`api/test/fixtures/live-states.json` from its event and sanitises every device-written one. Coalescing per run: an equal state is
never re-sent; a stage change or a terminal state goes at once at priority 10 (expiration +1 h); a counter goes at most once a
second at priority 5 (expiration +60 s); the latest value always goes with the next poll or sweep. `end`: done dismisses after
15 min with the alert `webp ready` / `<service> · <size>`, failed after 5 min with `cobalt couldn't finish`; no sound anywhere.
While a run with an update token waits on a server step, the sweep re-arms every 2 s instead of 5 (`hasActiveRuns()`), and the
same pass runs `cleanup()` (runs older than 8 h or ended over 1 h ago, index entries without runs, start tokens not refreshed
for 60 days). `cleanup()` and `hasActiveRuns()` read the small per-run index entries (`live:idx:`), never the run records.

Limits (review fixes, 2026-10-02; `error.live.too_many_runs`, 429): a key may hold 16 runs that have not ended and 64 in all
(ended ones are kept an hour), a session 16; at most one push-to-start per key per 10 s (`start_rate_limited`); nothing is ever
pushed to a run that has ended; a counter is skipped while the key is unhealthy (an outage must not make every poll wait out a
failing push), and with `APNS_VIA=helper` also outside the server stages `fetching`/`saving`/`rendering` (a relay would renew the
container's `sleepAfter`; stage changes, the end and catch-up still go). A start whose outcome is unknown (the request left, no
answer came back) is **never re-sent**: the run keeps `startAttemptedAt`, later `start: true` answers `start_unconfirmed`. The
conservative choice: at worst that run's activity never appears; re-sending could make two. A failed `end` stays pending on the
run and the sweep retries it (5 s, 15 s, 40 s after each failure: the first try plus 3 retries over about a minute; DO-only work,
the container is not touched with the `worker` transport; with `helper` an `end` wakes it as always), re-arming for the retry
even with no job pending; a client poll inside the backoff does not re-send; after the third retry only a poll retries.

APNs answers: 200 records `sent`; 400 `BadDeviceToken` retries once on the other host and remembers the environment that took it
(else the token is dropped); 410 and 400 `ExpiredToken` drop the token; 403 `ExpiredProviderToken` re-signs once and retries once
(never a re-sign within 20 minutes of the last forced one; the JWT is otherwise reused for 50 minutes, **kept in DO storage
(`live:jwt`) so a DO eviction does not re-sign it**); other 403, other 4xx, 5xx, a network error or the 2.5 s transport ceiling
mark the key unhealthy for 10 minutes (`pushing: false`); 429 `TooManyProviderTokenUpdates` is such a failure too (logged with its
reason; it used to be silent); any other 429 changes nothing.
Logs: one line per attempt, `[live] apns <status> <reason|-> event=<start|update|end> pri=<5|10> run=<first 8> token=<first 8>
apns-id=<id>`. Never the key, the JWT, a full token or a content state (tests spy on `console` to prove it).

### The self-test, and how to read it

After deploying with the secrets, call it with the device's own key:

    curl -s -H "Authorization: Api-Key <the key>" https://api.capybaraharmony.com/live/selftest

It signs a JWT and sends one update to the **sandbox** host for the device token of 64 zeros, through the configured transport,
with the real topic, and answers `{"status":"success","configured":true,"transport":"worker","host":"api.sandbox.push.apple.com",
"jwt":"ok","apns_status":400,"apns_reason":"BadDeviceToken"}`. Read `apns_reason`:

- `BadDeviceToken`: HTTP/2, the JWT and the topic all work. Done.
- `InvalidProviderToken`: wrong key id, team id or key (or a mangled PEM: `jwt` would say `error` if it could not even be read).
- `TopicDisallowed` / `BadTopic`: the key is not allowed for this bundle id.
- `transport: <message>`, or no `apns_status`: the transport failed. Set `APNS_VIA` to `helper` in `api/cloudflare.config.ts` and
  redeploy, then call it again. `{"configured":false}`: a secret is missing.

It never returns the JWT or the key. With `APNS_VIA=helper` it wakes the container (an explicit owner action).

### The transport switch (`APNS_VIA`)

`"worker"` (default): `fetch()` from the Durable Object to `https://api.push.apple.com` / `https://api.sandbox.push.apple.com`;
HTTP/2 is negotiated by the Workers runtime (three independent reports of it working deployed; `apple/CONTRACT-LIVE.md` 3.1).
`"helper"`: the DO still signs and builds every request and posts `{host, path, headers, body}` to the helper's `POST /apns`
(behind `x-internal-key`), which relays the bytes over `node:http2` (one session per host, reconnected on GOAWAY, error or a
stale session with one retry, all inside one 2 s budget: the helper always answers before the DO's 2.5 s per-attempt ceiling) and
answers `{status, reason, apns_id}`; any host but the two Apple ones is a 400, and
only the push headers are forwarded. The DO uses it only while the container is running, except for `start` and `end` pushes and
the self-test, which wake it first (a counter while it sleeps is skipped; the next event sends the latest). The wake
(`ensureRunning()`) happens before and outside the 2.5 s ceiling, under its own 30 s budget: it used to run inside it, so a cold
container made the push time out (key unhealthy for 10 minutes, `started: false`) while the waking container delivered it anyway,
and a retried `start: true` then made a second activity. A wake that fails or runs out is `unhealthy` and sent nothing, so a retry
is safe; a `PUT` with `start: true` can therefore take up to about 30 s on a cold container. The signing key
never enters the container either way; in `helper` mode the container does see each relayed request, i.e. the short-lived provider
JWT (valid up to an hour) and the device token, in memory only and never logged.

### Verified and unverified (Live Activities)

Verified: `npm test` and `npm run typecheck` in `api/` and `web/`: the ES256 signature checked with WebCrypto against a generated
P-256 key, the exact headers and payloads, the answer table, the coalescing with a virtual clock, the hooks at every studio
transition (client poll and sweep), the real `StudioService` wired to the real `LiveService`, and the helper relay against a local
`node:http2` server. NOT verified before deploy (only a live deploy can): **HTTP/2 from the Durable Object to Apple** (the
self-test is the check), APNs throttling of priority-5 updates at one per second, that a push-started activity's update token
reaches the app (`apple/CONTRACT-LIVE.md` section 6, Plan B: broadcast channels), whether `cf` refuses a declared secret that is
missing from the secrets file, and the real Apple provider-token rules (the 20-minute re-sign floor is ours, from Apple's docs).
Known costs: a brand-new run registered with an update token gets one redundant update push (the contract's literal "state
differs from sent" rule; sent starts empty); a terminal state whose `end` push failed is retried by the sweep three times over about a
minute and by a client poll after that (if Apple stays down longer the activity just goes stale); a start whose outcome is unknown
is never re-sent (that run's activity may never appear); the hooks (`LIVE_PUSH_MS = 3000`) abandon a start or end that waits on a
cold container's wake (up to 30 s), which then continues in the DO and records its result if the DO stays alive (the start's
"attempted" marker is written first, so an eviction in between cannot allow a second start). Tested, not run live: the wake, the
2 s relay budget and the sweep retries are all virtual-clock or local-server tests. Not covered: `cf` has not run any of this.

### Deploy (owner; not run by the lane)

Add the three APNs secrets to `~/.config/cobalt/secrets.json`, then the API deploy only (`prepare-git-info.sh`, then
`cf deploy --secrets-file ~/.config/cobalt/secrets.json` from `deploy/cloudflare/api`). No D1 migration, no web deploy. The helper
change ships in the image (the deploy id restarts the container once). Then `GET /live/selftest` with the device's key and read the
answer as above.

## Hark notifications (stand-in for APNs, `APP-API-CONTRACT.md` section 9)

Until there is an APNs key, a job the owner walked away from (typically a share-sheet run) is announced through their Hark
webhook: `POST <HARK_WEBHOOK_URL>` with `{"title","body"}`. Code: `api/src/notify.ts` (the opt-in, the exactly-once record, the
send, the retries, the route inside the DO), hooks in `studio.ts`, retry re-arming in `sweep.ts`.

- **Secret**: `HARK_WEBHOOK_URL` in `~/.config/cobalt/secrets.json`, declared in `api/cloudflare.config.ts` as `bindings.secret()`.
  Missing, empty or not https = the bridge is off, `features.notify_bridge` is `false`, nothing is stored or sent. The URL is
  never in `envVars`, never logged, never returned. `cf deploy --dry-run --secrets-file` accepts it (checked 2026-10-04).
- **Opt-in** (nothing fires without one): `PUT|DELETE /studio/<sid>/notify` (key, the session's owner only) with
  `{"on":["saved","rendered","failed"],"label"?}`, valid 24 h; or `"notify": true` on one `POST /studio/<sid>/render`.
- **Fired from** the save becoming ready, a render finishing and either failing, by the poll or the sweep, whichever sees it first;
  each event once (a record in DO storage). 3 s ceiling per send; 5xx/network/timeout retried twice by the sweep (5 s, 20 s); a
  4xx is final. Logs: `[notify] hark sent|failed <status> sid=<8>` only.
- **Verified**: `npm test` (`test/notify.test.ts`: opt-in auth and validation, TTL, every event once under a poll/sweep race, no
  fire without opt-in, bridge off, payload limits, timeout and retry bounds, no secret in logs) and the dry run. **Not verified**:
  the real Hark endpoint's behaviour, and a `fetch` from the DO to it, until deployed.
- **Deploy**: API only, as for Live Activities; no migration, no web deploy.

## Crop (`APP-API-CONTRACT.md` section 10)

`POST /studio/<sid>/render` and `POST /webp` accept an optional `crop` `{x,y,w,h}` (normalized 0..1, in the displayed orientation).
`helper/crop.js` (shared by the DO and the helper) converts it to even pixels from the probed, rotation-applied size, clamps it
inside the frame and refuses under 64 px (`error.webp.invalid_params`); the helper's ffmpeg filter becomes
`fps=<fps>,crop=<w>:<h>:<x>:<y>,scale='min(<width>,iw)':-2:...`. No crop = exactly the old behaviour. `features.crop: true` in
`GET /capabilities`. Tests: `test/crop.test.ts`. Also run against a real local ffmpeg (Homebrew, 2026-10-04, not the container's): the exact `buildFrameArgs`
filter on a 640x360 clip gave 320x180 frames for a half crop and 480x270 without one, and on the same clip tagged with a 90 degree
rotation (probed as 360x640) a bottom-half crop gave 360x320 frames: the crop is read in the displayed orientation. Not run in the
container image (Alpine's ffmpeg); the helper change ships in the image, so the deploy restarts the container once.
