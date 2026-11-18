# How capystore gets deployed

Fork-only guide (harmonyvt/cobalt). Everything runs on Harmony's Mac from `~/cobalt`, through one front door:
`deploy/cobalt-deploy <api|web|ios|mac>`. Deeper detail lives in `deploy/RUNBOOK.md`, `deploy/cloudflare/README.md` and
`deploy/apple/README.md`; this page is the short version.

## TLDR

```bash
cd ~/cobalt
git pull --ff-only origin main && git --no-pager log --oneline -1   # origin, NOT a bare `git pull` (that's upstream)

# 1. D1 migration, only if the release adds one
cf d1 migrations apply 42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir deploy/cloudflare/d1/migrations

# 2. Server
deploy/cobalt-deploy api            # API Worker cobalt-api + containers (OrbStack must be running)
deploy/cobalt-deploy web            # web Worker cobalt-web, only if web changed

# 3. Apps (bump MARKETING_VERSION in apple/project.yml first, via a PR)
deploy/cobalt-deploy ios testflight
deploy/cobalt-deploy mac testflight
```

Every one of these is a production change: it needs Harmony's own typed yes naming the operation. Add `--dry-run` to
any of them to build everything and upload nothing.

## The big picture

| Piece | What it is | Where it lives | Deployed with |
|---|---|---|---|
| API | Worker `cobalt-api` + Cloudflare Containers (cobalt, editor, workbench, yt-dlp) | `api.capybaraharmony.com` (+ `share.`, `studio.`) | `deploy/cobalt-deploy api` |
| Web | Static SvelteKit build + Worker `cobalt-web` behind Cloudflare Access | `cobalt.capybaraharmony.com` | `deploy/cobalt-deploy web` |
| Database | D1 `cobalt-keys` (id `42f18bb0-…`), bound as `DB` in both Workers | Cloudflare | `cf d1 migrations apply` |
| Media | R2 `cobalt-media` (public) and `cobalt-originals` (private) | `media.capybaraharmony.com` | nothing to deploy |
| iOS app | TestFlight, internal testing only | App Store Connect | `deploy/cobalt-deploy ios testflight` |
| Mac app | TestFlight, sandboxed pkg, same app record | App Store Connect | `deploy/cobalt-deploy mac testflight` |

**Order for a release that touches both sides:** migration, then API (and web), wait a few minutes for the container
rollout, then the apps. Apps must cope with an older server and the server with older apps.

## Before any deploy

1. **Pull from the fork, not upstream.** `~/cobalt`'s `main` tracks `upstream/main` (imputnet), so a bare `git pull`
   brings in nothing of ours. Always `git pull --ff-only origin main` and check the commit with
   `git --no-pager log --oneline -1`. (A deploy once shipped stale code because of this.)
2. **Merge the release PRs first.** If a build went to TestFlight from a PR branch, merge that PR before releasing from
   `main`, or the next release silently drops its work. (8.19 to 8.22 lost the 8.17/8.18 fixes this way.)
3. **One deploy at a time from `~/cobalt`.** Only one thread deploys from the Mac at once. Other work builds in a separate
   git worktree; never switch `~/cobalt` off `main`. Prefer one combined release from `main`.
4. **Get the typed yes.** Production changes (API/web deploy, D1 migration, TestFlight upload) need Harmony's own typed
   message naming the exact operation. Card taps and a bare "go" don't count. The Claude Code safety check on the Mac
   may still block it; then Harmony runs the command by hand.

## API (Worker `cobalt-api` + containers)

```bash
deploy/cobalt-deploy api [--dry-run]
```

What it does: runs `deploy/cloudflare/api/prepare-git-info.sh` (writes a synthetic `.git` for the version info), warns
if the APNs secrets are empty (Live Activity pushes would be off), then
`cd deploy/cloudflare/api && cf deploy --secrets-file ~/.config/cobalt/secrets.json`.

- **OrbStack must be running**: the container images are built locally with Docker.
- **`npm ci` after a PR adds packages**: run it in `deploy/cloudflare/api` (and `web`) or the build fails.
- **`cf` is the Cloudflare CLI** (v1.0.0-beta.5), not Wrangler. Never run `wrangler login` or `wrangler deploy`. Use the
  global `cf`, not `npx cf`.
- **Gate first** (optional but cheap): `npm test && npm run typecheck` in `deploy/cloudflare/api`. After changing an op,
  `npm run gen` or the tests fail.
- **After the deploy**: the first container start can 500/503 once; it retries itself. Don't redeploy to "fix" it.
  New helper features show up only after the new container has started (a few minutes).
- **Rollback (Worker only)**:
  `cf workers deployments create --script-name cobalt-api --strategy percentage --versions '[{"version_id":"<id>","percentage":100}]'`.
  The container image can't be pinned back that way; redeploy an older commit from a worktree instead.

## Web (Worker `cobalt-web`)

```bash
deploy/cobalt-deploy web [--dry-run]
```

Runs `deploy/cloudflare/build-web.sh` (builds `web/` in a temp copy with the synthetic `.git`, renames the app to
"capystore" in that copy only, writes `web/build`), then `cf deploy` in `deploy/cloudflare/web`. Only needed when
`web/`, `deploy/cloudflare/web/` or shared code changed. The web Worker also needs `COBALT_API_KEY` in the secrets file.

## D1 migrations

```bash
cf d1 migrations list  42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir deploy/cloudflare/d1/migrations
cf d1 migrations apply 42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir deploy/cloudflare/d1/migrations
```

- Files live in `deploy/cloudflare/d1/migrations/` (`0045_extension_pairings.sql` was the newest on 2026-11-18).
- **Apply before the code that reads the new tables.** Migrations are additive and stay applied on rollback.
- **Check numbering before you name one.** Parallel PRs can both claim the next number (and the next contract section).
  Look at `main` and the open PRs first.
- Use the **global** `cf` (`npx cf` once got error 7403 on a remote apply). A one-off 7403 usually works on retry.

## iOS and Mac apps (TestFlight)

```bash
deploy/cobalt-deploy ios testflight [--dry-run] [--commit <ref>]
deploy/cobalt-deploy mac testflight [--dry-run] [--commit <ref>]
```

- **Marketing version**: bump `MARKETING_VERSION` in `apple/project.yml` by hand for every release (small PR to `main`).
  iOS and Mac share it.
- **Build number**: automatic. It's one past the newest of the Feather source, `~/cobalt-ipas/testflight.tsv` and
  `project.yml`, so iOS and Mac take turns on one rising number (e.g. iOS 130, Mac 131). `--build <n>` overrides it.
- **Signing**: automatic via the App Store Connect API key in `~/.config/cobalt/appstoreconnect.json`. Nothing by hand
  in Xcode or the keychain.
- **`--commit <ref>`** ships exactly that commit from a temporary worktree, so unfinished work in `~/cobalt` stays out.
- **dSYMs**: copied to `~/cobalt-dsyms/<version>-<build>/` (Mac: `mac-<version>-<build>/`) before the archive is deleted,
  and also uploaded to Apple. Keep them; they symbolicate crashes. Match with `dwarfdump --uuid`.
- Apple takes about 5 to 15 minutes to process; the internal group gets it automatically.
- Builds are internal testing only (never Beta App Review).
- Older channels, still in the script: `deploy/cobalt-deploy ios --notes "…"` publishes to the Feather sideload source
  (`ios list` shows its builds), and `deploy/cobalt-deploy mac` installs an unsandboxed copy to `/Applications`.
- Gate before a release: `cd apple && xcodegen generate`, then the iOS 27 simulator and macOS `xcodebuild` lines in
  `CLAUDE.md`, and `cd apple/CobaltKit && swift test`. A job-queue test and a few box/webp tests are known flaky.

## Secrets

- All in `~/.config/cobalt/secrets.json` (chmod 600, never committed). Every `cf deploy` uploads them with
  `--secrets-file`. Secrets **not** in the file stay as they are on the live Worker.
- Other files beside it: `appstoreconnect.json` + `AuthKey_<id>.p8` (TestFlight), `feather.json` (Feather source).
- `COBALT_API_KEY` is internal (Worker to container); clients never get it. Rotate by writing a new UUID and redeploying.
- **Never paste a secret into chat.** To change one live secret without a deploy, read it silently, then set it:

  ```zsh
  read -rs "K?value: " && cf workers secrets update ANTHROPIC_API_KEY --worker cobalt-api --type secret_text --text "$K"; unset K
  cf workers secrets list --worker cobalt-api      # check it's there
  ```

  Put it in `secrets.json` too, or it won't be in the file for the next deploy.
- Optional features are off until their key is in the file, e.g. `EMBED_TOKEN`, `OPENROUTER_API_KEY`,
  `TWITCH_*`, `DISCORD_BOT_TOKEN` (that one must exist, even empty, or `cf deploy` refuses).

## Mac gotchas

- **Commit signing goes through 1Password** and fails while the Mac is locked. Push fixes from a cloud session instead.
- **The Claude Code safety check** may block `cobalt-deploy`, migrations and merges even after a typed yes. Then run
  the command yourself in a terminal.
- **Disk runs near full.** A build needs about 3 GB. Old `~/cobalt-*` worktrees can be cleared.
- **Logs**: `cf o11y telemetry query --body '{…,"parameters":{"datasets":["cloudflare-workers"]}}'`.
