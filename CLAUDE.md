# CLAUDE.md

Personal fork of imputnet/cobalt (`origin` = harmonyvt/cobalt, `upstream` =
imputnet/cobalt). `main` tracks `upstream/main`; update with
`git pull --ff-only upstream main`. Keep upstream files untouched where
possible so pulls stay clean. Fork-only additions live in `deploy/`.

## Delegation policy

The main thread (Fable) orchestrates: direction, dispatch prompts, gating,
review, artifacts and git. Substantive work goes to named Claude lanes with the
model pinned by agent type: `opus-lane` for judgment calls, review and deep
research; `sonnet-lane` / `sonnet-quick` for implementation, scripts, lookups
and runtime verification. Never delegate to any other engine. Lanes own
disjoint files, never commit or push, and their reports are checked against
the files and a real run before anything is called done.

## Layout

- `api/`: Node media-download API (Express, ffmpeg-static, youtubei.js).
  Needs a real container (spawns ffmpeg, native `isolated-vm`, node:cluster).
  Port 9000. Docs: `docs/api-env-variables.md`, `docs/protect-an-instance.md`.
- `web/`: SvelteKit static frontend (adapter-static → `web/build`).
  `WEB_DEFAULT_API` is required at build time.
- `packages/`: shared workspace packages.
- `mobile/`: untracked local Expo work; not part of upstream.

## Private Cloudflare deployment (`deploy/cloudflare/`)

- `cobalt.capybaraharmony.com`: static web build, behind Cloudflare Access
  (email one-time PIN, owner only).
- `api.capybaraharmony.com`: Worker + Cloudflare Container running the API
  image. The Worker rejects `POST /` without a valid per-owner key before waking
  the container. The API runs with `API_KEY_URL`, `API_AUTH_REQUIRED=1`,
  `CORS_WILDCARD=0`, and `CORS_URL` set to the web origin.
- Access cannot sit in front of the API: the web app's cross-origin fetches
  carry no cookies. Per-owner API keys are the API's lock: the owner creates and
  revokes named keys in the web UI; only SHA-256 hashes are stored, in the D1
  database `cobalt-keys` (`deploy/cloudflare/d1/migrations/`, bound as `DB` in
  both Workers). The web Worker (`web/src/index.ts`, `runWorkerFirst` for
  `/api/keys*` only) verifies the Cloudflare Access JWT and serves
  GET/POST/DELETE `/api/keys`. The API Worker (`api/src/gate.ts` decides,
  `api/src/keys.ts` looks up in D1) swaps in the internal `COBALT_API_KEY`
  before forwarding to the container.
- Deploy tool is the Cloudflare `cf` CLI (v1.0.0-beta.5), not Wrangler. Configs are
  `deploy/cloudflare/{api,web}/cloudflare.config.ts` (the cf config; the API
  container is defined there) plus `wrangler.config.ts` (bundler settings; cf
  delegates the build to the local Wrangler devDependency, so never run
  `wrangler login` or `wrangler deploy`). The upstream `web/wrangler.jsonc` is
  unrelated and untouched; deploy configs live only under `deploy/cloudflare/`.
- Animated WebP hosting: `POST /webp`, `GET /webp/:id`, `DELETE /media/:name` on the API Worker (same client keys).
  The container entrypoint is `deploy/cloudflare/api/helper/supervisor.js` (runs `node src/cobalt` plus a helper API on
  port 9100 guarded by `x-internal-key`; one ffmpeg encode at a time). The Durable Object copies finished files into the
  R2 bucket `cobalt-media` (public at `https://media.capybaraharmony.com/`, unguessable names). The Worker strips
  `cf-container-target-port` and `x-cobalt-key-id` from every request (`api/src/headers.ts`). Details, contract and
  limits: `deploy/cloudflare/README.md`. The bucket and its custom domain are created by the owner before deploying.
- Worktree caveat: in a git worktree `.git` is a file, which breaks
  `packages/version-info` (API startup and the web `/version.json` prerender).
  `deploy/cloudflare/api/prepare-git-info.sh` writes a synthetic git dir to
  `api/.gitinfo/` (gitignored); the API Dockerfile copies it to `/app/.git`, and
  `deploy/cloudflare/build-web.sh` builds web in a temp copy using it. Run
  `prepare-git-info.sh` before every API deploy.
- Deploy commands (from the repo root): `deploy/cobalt-deploy api|web|ios|mac [--dry-run]` wraps all of these
  (`deploy/cobalt-deploy --help`). By hand:
  - API: `deploy/cloudflare/api/prepare-git-info.sh`, then
    `cd deploy/cloudflare/api && cf deploy --secrets-file ~/.config/cobalt/secrets.json`
  - Web: `deploy/cloudflare/build-web.sh`, then
    `cd deploy/cloudflare/web && cf deploy --secrets-file ~/.config/cobalt/secrets.json`
    (the web Worker needs COBALT_API_KEY too: it calls the API through the service
    binding `API` with `x-cobalt-service`).
- Studio, library and media (contracts: `deploy/cloudflare/STUDIO-CONTRACT.md`,
  `deploy/cloudflare/LIBRARY-CONTRACT.md`): public files in R2 `cobalt-media`
  (media.capybaraharmony.com), private originals/uploads in R2 `cobalt-originals`, the
  record of everything in D1 `media_items`. The studio (/studio/<sid>) and library
  (/library) pages are self-contained HTML embedded in the web Worker; the only upstream
  edit for them is the sidebar "library" tab (Sidebar.svelte, SidebarTab.svelte).
- Library search (`APP-API-CONTRACT.md` section 21): EmbeddingGemma 2 on a private Hugging Face Space
  (`deploy/huggingface/embed`), vectors in D1 `media_embeddings`, indexed by the API Worker's 15-minute cron
  (`api/src/embed.ts`), `GET /library/search`. Off unless `EMBED_TOKEN` is in the secrets file.
- Old Discord links (`APP-API-CONTRACT.md` section 19.6): an unsigned or expired Discord attachment link is signed again
  through Discord's `attachments/refresh-urls` by the container's helper, then saved. Off unless `DISCORD_BOT_TOKEN` is in
  the secrets file (the key must exist there, even empty, or `cf deploy` refuses).
- Rich link pages (`APP-API-CONTRACT.md` section 22): `share.capybaraharmony.com/<name>` (a second domain on the API
  Worker, `src/share.ts`) serves Open Graph pages for public files so links unfurl in Discord, iMessage, X; the app
  copies them when `GET /capabilities` has `share_base_url`.
- Roast captions (`APP-API-CONTRACT.md` section 25): Claude Haiku 5.5 titles and descriptions for share previews, in
  D1 `media_captions` (`api/src/roast.ts`), written at gallery-link creation and by the 15-minute cron. Off unless
  `ANTHROPIC_API_KEY` is in the secrets file.
- Sets (`APP-API-CONTRACT.md` section 28): named groups of share link collections, `CollectionGroup` in code (a
  `ShareSet` is already a link), D1 `collection_groups`/`collection_group_items` (migration 0017), `/share/groups`.
- Moving gallery links (`APP-API-CONTRACT.md` section 29): gallery links hold up to 10 files; each public video gets
  a 4 s silent animated WebP preview (helper webp job, owner `loop:<item id>`, D1 `media_loops`, migration 0018,
  `api/src/loops.ts`) that Discord's media gallery plays without a tap.
- Stage (`APP-API-CONTRACT.md` section 30; "studio" in the app's copy, since studio already means the save/trim
  session in code): an OBS canvas at `studio.capybaraharmony.com/live/<token>`, a viewer store at `/store` (locked by
  default), Twitch channel-point rewards via EventSub (`api/src/stage*.ts`, `StageRoom` DO, D1 `stage_*`, migration
  0019). Twitch is off unless `TWITCH_CLIENT_ID`, `TWITCH_CLIENT_SECRET`, `TWITCH_EVENTSUB_SECRET` are in the secrets file.
- Op registry (`APP-API-CONTRACT.md` section 33): `defineOp` in `api/src/registry/` gives a route, its zod input check
  and the chat AI's tool in one place. Every route (and the share/stage/studio hosts) is an op; `gate.ts` only answers
  preflights and the final 404. `test/route-snapshot.test.ts` pins every route's answer: a PR moving routes must leave
  the fixture unchanged. Ops live in `registry/ops/<area>.ts`; tier `ask` ops pause for a confirm card (DO storage, 15 min).
  After changing an op run `npm run gen` in `deploy/cloudflare/api`: it rewrites `openapi.json`, the contract's route
  index and `apple/CobaltKit/.../API/Generated/Endpoints.swift` (section 33.13); `npm test` fails while they are stale.
- MCP server (`APP-API-CONTRACT.md` section 35): `POST /mcp` on the API host serves the chat AI's ops as MCP tools
  (`src/mcp.ts`, `src/registry/ops/mcp.ts`), auth `Bearer <client key>`, each key one MCP "thread" (`chat:<thread>`, same
  caps). `upload_begin` mints a 15-minute `PUT /mcp/upload/<token>` link for local files. A new chat op appears there too;
  hide chat-only calls in `MCP_SKIPPED_CALLS`, MCP-only ops use `when: (f) => f.mcp === true`.
- Workbench (`APP-API-CONTRACT.md` section 33.11, ffmpeg editing 33.11.1): the chat AI and MCP Linux box (`cobalt.box.run`/`pull`/`save`), the
  `Workbench` DO (`api/src/workbench*.ts`) on container app `cobalt-api-workbench` (`deploy/cloudflare/workbench/`, standard-1,
  one instance). No secrets, no own internet: every HTTP(S) request passes the Worker's outbound rule (19.2 + our own zone
  refused). Wiped on sleep (2 min) and between threads; `WORKBENCH_DAILY_MINUTES` caps awake time (default 60, 0 = off).
- yt-dlp box (`APP-API-CONTRACT.md` section 49): a second downloader for saves, the `YtDlpBox` DO (`api/src/ytdlp.ts`) on
  container app `cobalt-api-ytdlp` (`deploy/cloudflare/ytdlp/`, basic, one instance), same single-file `/fetch` routes as
  the helper. `SAVE_ENGINE` "fallback" = cobalt first and yt-dlp when cobalt fails on the link; "first" = yt-dlp first.
  `engine` on POST /studio and `library.save` picks one. Items saves stay cobalt's. Bump `YT_DLP_VERSION` + `YT_DLP_SHA256` (GitHub release) when a site breaks.
- Chat (`APP-API-CONTRACT.md` section 27): Haiku 5.5 threads about the library in D1 `chat_threads`/`chat_messages`
  (`api/src/chat.ts`), code mode: the model's JavaScript runs in a Dynamic Worker (`LOADER` binding,
  `api/src/chat-loader.ts`) against the read-only tools in `api/src/chat-tools.ts`.
- Accounts (`APP-API-CONTRACT.md` section 42): Cloudflare Access does the login; each device holds a session, an
  `api_keys` row with `kind = 'session'` (migration 0026) sent exactly like a client key, 90-day sliding expiry in
  `lookupKey`, at most 50. Apps: web Worker `GET /api/auth/app` (one-time code in D1 `auth_handoffs`, PKCE, 302 to
  `cobalt-apple://signed-in`), then the API's `POST /auth/exchange`; the web app mints its own via `POST /api/auth/web`.
  Owner routes `/auth/*` in `registry/ops/auth.ts`; `/api/keys` only sees `kind = 'key'` ("keys for tools"). Minting SQL is
  duplicated in `{api,web}/src/sessions.ts`, pinned by `web/test/sessions.test.ts`.
- Runtime lessons (all hit live): `pipeTo()` between streams is not implemented in the
  Workers runtime (copy with a reader/writer loop); AbortSignal timeouts on containerFetch
  are not honoured inside the DO (race your own timeout); work after a DO response does not
  survive (make it poll-driven); a container rollout restarts instances with their old env
  (CobaltContainer restarts on env/deploy-id fingerprint change). Anthropic answers 403 "Request not allowed"
  from some Cloudflare locations, so chat and captions call it through the `ModelRelay` Durable Object
  pinned to `enam` (`api/src/model-fetch.ts`). Workers + container logs
  are on: query with `cf observability telemetry query --body '{...,"parameters":{"datasets":["cloudflare-workers"]}}'`.
- Use the GLOBAL `cf` for D1 migrations (`npx cf` got 7403 on remote apply).
  - `cf deploy --dry-run` builds everything and uploads nothing.
- Secrets: `COBALT_API_KEY` (a UUID) is an INTERNAL Worker-to-container key,
  never given to clients. It lives in `~/.config/cobalt/secrets.json`
  (`{"COBALT_API_KEY": "<uuid>"}`, chmod 600, never committed) and is uploaded via
  `--secrets-file`. Rotate by writing a new UUID there and redeploying the API;
  client keys are unaffected.
- D1 migration (remote, run by the owner): `cd deploy/cloudflare/web && npx cf d1
  migrations apply 42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir ../d1/migrations`.
- Tests: `npm test && npm run typecheck` in `deploy/cloudflare/api` and
  `deploy/cloudflare/web` (Worker tests run the real SQL on `node:sqlite`).
  Full runbook and accepted trade-offs: `deploy/cloudflare/README.md`.

## Apple app (apple/)

Native SwiftUI app for this fork: one multiplatform target (iPhone, iPad, Mac; not
Catalyst) plus an iOS share extension. iOS 18 / macOS 15, Swift 6, no third-party
dependencies. Contracts: `apple/CONTRACT.md` (app: layout, CobaltKit public API, screens,
copy, motion, lanes, gates) and `deploy/cloudflare/APP-API-CONTRACT.md` (the additive
backend routes it uses; nothing under `api/` changes). Design source: `apple/mockup/`.

- `apple/project.yml`: XcodeGen spec; `Cobalt.xcodeproj` is generated and gitignored.
- `apple/CobaltKit/`: local Swift package (models, API client, capability detection,
  pipeline, stores, keychain, share inbox, preview data). `apple/Cobalt/`: app UI and
  design system. `apple/CobaltShare/`: share extension. `apple/Config/`: signing,
  entitlements, Info.plists. Team id only in the gitignored `apple/Config/Local.xcconfig`.
- Bundle ids `com.capybaraharmony.cobalt` (+ `.share`), app group
  `group.com.capybaraharmony.cobalt`, URL scheme `cobalt-apple`.
- Build and test (from the repo root):
  - `cd apple && xcodegen generate`
  - `xcodebuild -project apple/Cobalt.xcodeproj -scheme Cobalt -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' -derivedDataPath apple/.build/ios CODE_SIGNING_ALLOWED=NO build`
  - the same with `-destination 'platform=macOS' -derivedDataPath apple/.build/mac`
  - `cd apple/CobaltKit && swift test`
- TestFlight: `deploy/cobalt-deploy ios testflight [--dry-run]` (`deploy/apple/testflight.sh`): automatic signing via an
  App Store Connect API key in `~/.config/cobalt/appstoreconnect.json`, internal testing only, shares the Feather build
  number sequence (`~/cobalt-ipas/testflight.tsv`). Setup: `deploy/apple/README.md` (TestFlight).
- Mac TestFlight: `deploy/cobalt-deploy mac testflight [--dry-run]` (`testflight.sh --mac`): sandboxed pkg, same app
  record as iOS (universal purchase; macOS platform added once in App Store Connect). `deploy/cobalt-deploy mac` still
  does the old unsandboxed /Applications install. Sandbox notes: `deploy/apple/README.md` (TestFlight for the Mac).
- Previews and tests run on `PreviewClient` / `AppModel.preview(<scenario>)`, which replay
  the mockup's real data and timings without network.
