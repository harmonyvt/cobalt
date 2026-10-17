# cobalt deploy runbook: server and Apple apps

Written 2026-10-14 for an agent picking this up cold. Every command below was run for real during the 1.12 to 1.16
releases (2026-10-06 to 2026-10-13) except where a line says "not verified". Facts that can drift (versions, test counts)
carry the date they were read.

## 0. Ground rules

- Repo: private fork of cobalt. Work in the worktree `/Users/harmony/cobalt/.claude/worktrees/apple-app`, branch
  `apple-app`, remote `origin` branch `apple-app`. Fork-only code lives in `deploy/` and `apple/`.
- Commits are unsigned on purpose (1Password signing was failing and the owner said not to worry):
  `git -c commit.gpgsign=false commit ...`. Push to `origin apple-app`. Children and lanes never commit; the main thread does.
- Production deploys need the owner's go in chat. The Claude Code auto-mode permission check blocks `cf deploy` until the
  owner says so in the conversation; do not route around that.
- Production names: API `https://api.capybaraharmony.com` (Worker + Durable Object + Container, locked by API keys),
  web `https://cobalt.capybaraharmony.com` (behind Cloudflare Access), media `https://media.capybaraharmony.com`
  (R2 `cobalt-media`, public), private originals in R2 `cobalt-originals`, D1 database id
  `42f18bb0-837a-47f7-b1e2-606eb705ab6c`.
- Secrets live in `~/.config/cobalt/` (chmod 600, never committed, never printed, never pasted in chat):
  `secrets.json` (keys: `COBALT_API_KEY`, `HARK_WEBHOOK_URL`, `APNS_KEY_ID`, `APNS_KEY_P8`, `APNS_TEAM_ID`,
  `MEDIA_PURGE_TOKEN`), `feather.json` (`token`, `bucket`, `baseUrl`), `sim-key.json` (an API key for scripts; field `key`),
  `shortcut-key.json`. Read a value into a shell variable with `jq`; never `echo` it.
- Docker: only touch containers you created with an explicit unique name. Never `docker system prune`.
- Never `pkill -f` or kill by name: the owner may have `cobalt` open on this Mac. Kill only PIDs you started.
- Check `uptime` before long runs. When load is high, real-ffmpeg tests and Docker builds time out and look like failures.
- Tools used: `cf` (Cloudflare CLI, not Wrangler), `xcodegen`, `xcodebuild`, `jq`, `curl`, `zip`, `tailscale`, Docker
  (running, for the container image), Node via Volta.

## 1. Server (Cloudflare)

Layout: `deploy/cloudflare/api` (Worker + Container helper in `helper/`), `deploy/cloudflare/web`,
`deploy/cloudflare/d1/migrations`. Full detail: `deploy/cloudflare/README.md`. Wire contract:
`deploy/cloudflare/APP-API-CONTRACT.md` (sections 13 to 19).

### 1.1 Gate (nothing is uploaded)

```bash
cd deploy/cloudflare/api && npm run typecheck && npm test      # 2698 passed, 1 skipped on 2026-10-10
cd ../web && npm run typecheck && npm test                      # 376 passed
cd ../api && npm run dry-run                                    # builds the container image, uploads nothing; slow
```

Known flake: the real-ffmpeg files (`make-webp.test.ts`, `gallery-image.test.ts`) time out at 5 s when the machine is
loaded. Rerun that file alone before treating it as a failure.

### 1.2 Migrations first, only when new files exist

Additive only. Apply before the code that reads the new columns.

```bash
cd deploy/cloudflare/api
cf d1 migrations list  42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir ../d1/migrations
cf d1 migrations apply 42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir ../d1/migrations
```

Latest is `0009_gallery.sql` (applied 2026-10-07). One transient `7403` happened once; a retry worked.

### 1.3 API Worker + container

```bash
deploy/cloudflare/api/prepare-git-info.sh                                   # from the repo root
cd deploy/cloudflare/api && cf deploy --secrets-file ~/.config/cobalt/secrets.json
```

- Run `cf deploy` from `deploy/cloudflare/api`, never the repo root.
- The README requires `prepare-git-info.sh` before every API deploy and the secrets flag. During the 2026-10 deploys the
  flag and script were skipped and the deploy still worked because the secret and `.gitinfo` already existed. Do not rely
  on that; follow the README.
- If only Worker code changed (nothing under `helper/`, no Dockerfile change), add `--containers-rollout none`.
- The container image is rebuilt and rolled out; allow several minutes. New helper behaviour only exists after the new
  container has started.
- `apple/` is excluded from the image (`.dockerignore`); do not undo that (the disk filled once).

### 1.4 Web (only if `deploy/cloudflare/web` or code it shares changed)

```bash
deploy/cloudflare/build-web.sh                                              # from the repo root
cd deploy/cloudflare/web && cf deploy --secrets-file ~/.config/cobalt/secrets.json
```

### 1.5 Verify (read-only, no saves)

```bash
KEY=$(jq -r .key ~/.config/cobalt/sim-key.json)
curl -s -H "Authorization: Api-Key $KEY" https://api.capybaraharmony.com/capabilities | jq '(.features // .cobalt.features // .)'
for p in /studio/line /studio/recent "/library?v=3"; do
  curl -s -o /dev/null -w "$p %{http_code}\n" -H "Authorization: Api-Key $KEY" "https://api.capybaraharmony.com$p"
done
curl -s -o /dev/null -w "web %{http_code}\n" https://cobalt.capybaraharmony.com/      # 302 to Access is correct
```

Expect 200s. On 2026-10-10 the features were `line`, `gallery`, `gallery_make` and `direct_links` all true.
`gallery`, `gallery_make` and `direct_links` are advertised only after the new helper has answered a request once, so
right after a container rollout they read false and a first save can still hit the old container. Wait a few minutes and
retry. One real save of a direct image link is the end-to-end proof and puts a file in the owner's library.

### 1.6 Logs

```bash
# device telemetry (app builds send these)
cf d1 query 42f18bb0-837a-47f7-b1e2-606eb705ab6c --sql \
  "SELECT level,cat,msg,data FROM telemetry_events WHERE build='18' ORDER BY ts DESC LIMIT 50"
cf d1 query 42f18bb0-837a-47f7-b1e2-606eb705ab6c --sql "SELECT * FROM telemetry_crashes ORDER BY ts DESC LIMIT 10"
```

Worker and container logs: `cf observability telemetry query --body '{...,"parameters":{"datasets":["cloudflare-workers"]}}'` (see CLAUDE.md, "Private Cloudflare deployment").

### 1.7 Rollback

No automated rollback. Check the previous good commit out in a separate worktree and repeat 1.3 and 1.4 from there.
Migrations are additive and stay applied. Not verified.

## 2. Apple apps

Project: `apple/` (XcodeGen; `Cobalt.xcodeproj` is generated and gitignored). Packages: `apple/CobaltKit`.
Contracts: `apple/CONTRACT-*.md`. Fork-only release tooling: `deploy/apple/`.

### 2.1 Version

Edit `apple/project.yml`: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (1.16 and 18 on 2026-10-10). The build number
must go up on every release or Feather will not offer the update. Commit and push the bump.

### 2.2 Gate

```bash
cd apple && xcodegen generate
xcodebuild -project Cobalt.xcodeproj -scheme Cobalt -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Cobalt.xcodeproj -scheme Cobalt -destination 'platform=macOS' \
  -derivedDataPath .build/mac CODE_SIGNING_ALLOWED=NO build
cd CobaltKit && swift test                                      # 1624 tests on 2026-10-10
```

- Simulators are iOS 27 only: build on iPhone 17 Pro, `OS=27.0` (as in `CLAUDE.md`).
- Known load-sensitive tests: `TelemetryUploaderTests`, `InstantShareTests` (sub-second asserts), `Offline*`,
  `PhotoCropTests`, `GalleryPipelineTests`. Rerun the suite alone before calling it a regression.
- Delete your `.build/<lane>-*` folders afterwards.

### 2.3 Release from a clean checkout

`release.sh` builds the working tree. To ship exactly a commit and not unfinished work:

```bash
deploy/cobalt-deploy ios --commit <sha> --taildrop harmony --notes "…"   # temp worktree, removed afterwards
```

### 2.4 iPhone (Feather source + Taildrop)

```bash
deploy/cobalt-deploy ios --dry-run                                  # build + pack, uploads nothing
deploy/cobalt-deploy ios --taildrop harmony --notes "what's new"    # from the repo root (runs deploy/apple/release.sh)
deploy/cobalt-deploy ios list                                       # every published build, newest first
```

It builds Release unsigned, packs the ipa, copies dSYMs to `~/cobalt-dsyms/<ver>-<build>/`, uploads the ipa to R2 under
`apps/<token>/`, publishes the Feather/AltStore `source.json`, purges its cached copy, keeps every build (`--keep <n>` prunes), archives
the ipa in `~/cobalt-ipas/` and Taildrops `cobalt-<version>-<build>.ipa` to the device named `harmony`. Re-publishing
an already published build is refused without `--replace`. Success line to look for: `source.json serves build <N>`.
Needs `~/.config/cobalt/feather.json` and an authenticated `cf`. Details: `deploy/apple/README.md`.
The owner then updates from the Feather source or opens the Taildropped ipa.

### 2.5 Mac (direct install, Developer ID)

```bash
deploy/apple/mac-install.sh
```

Builds Release, refuses a binary containing the DEBUG-only `-cobaltSandboxRoot`, signs with the local Developer ID
(hardened runtime, Photos entitlement only, unsandboxed), quits a running cobalt, replaces `/Applications/cobalt.app`
and prints the installed version. This script is the same logic used for 1.14 to 1.16 from a scratch folder; it was
moved into the repo on 2026-10-14 and only syntax-checked there. Back up `~/Movies/cobalt` and
`~/Library/Application Support/{Videos,Sync}` first when a release changes folder or store handling (backups of the
Mac wave sit in `~/cobalt-backups/`).

### 2.5.1 Never run debug builds against the real home

DEBUG builds accept `-cobaltSandboxRoot <dir>` so tests and evidence runs can use a copy. Do not point a development build
of changed folder/store code at the real `~/Movies/cobalt` or `~/Library/Application Support`.

### 2.6 After a release

- Device telemetry for the new build: query 1.6 with `build='<N>'`. Ask the owner to use Settings, send logs.
- Mac crashes: `~/Library/Logs/DiagnosticReports/cobalt-*.ips` (1.14 crashed in SwiftUI `VideoPlayer` on macOS 27.0.1).
- The owner's iPhone build is sideloaded: Feather re-signs it with a third-party certificate, so there is no app
  group and no push entitlement. The share extension cannot hand files to the app; it saves through the server and the
  app finds the result via `GET /studio/recent`. Design for that.

## 3. Deploy order for a change that touches both

1. Migration (if any), 2. API (and web if needed), 3. wait for the container, verify 1.5, 4. app release.
Apps must tolerate a server without the new feature flag (older servers keep today's behaviour); servers must tolerate
older apps (new request fields are optional).

## 4. Where to read more

`CLAUDE.md` (repo), `deploy/cloudflare/README.md`, `deploy/cloudflare/APP-API-CONTRACT.md`, `deploy/apple/README.md`,
`apple/CONTRACT-OFFLINE.md`, `apple/CONTRACT-GALLERY.md`, `apple/CONTRACT-PARALLEL.md`, `apple/CONTRACT-MEDIA.md`,
`apple/PROPOSAL-INSIGHT.md` (AI describe/tag idea; research only, nothing built).
