# cobalt for Apple: private Feather source

`release.sh` builds the iOS app unsigned, packs an `.ipa`, and publishes it as an AltStore-format source that
[Feather](https://github.com/khcrysalis/Feather) (an on-device iOS sideloading app) can subscribe to. Feather signs the
app with the owner's own Apple developer account when installing it. Fork-only; nothing under `apple/` or `api/` changes.

## Add the source in Feather (once)

1. Get the URL: `deploy/apple/release.sh --show-url` prints it at the end (or build it by hand:
   `https://media.capybaraharmony.com/apps/<token>/source.json`, token from `~/.config/cobalt/feather.json`).
2. In Feather open **Sources**, tap **+**, paste the URL, tap **Add**. cobalt appears in the source's app list.
3. Open cobalt in the list and tap **Get**; Feather downloads the ipa, signs it, and installs it.

## How updates appear

Each release rewrites `source.json` so `versions[0]` is the newest build (the file also repeats it as the legacy
top-level `version` / `downloadURL`, as Feather's own repo file does). Feather reads `versions[0]` as the current
build, so once it refreshes the source the app's row shows the new version, date and release note; tap **Get** again to
install over the old one. Each version is labeled `<version> (<build>)`, e.g. `2.1 (26)`: Feather uses that label in
**Version History** (open the app) and **Previous Versions** (long-press the row), and flags an installed copy for update
only when the label changes, so a bare `2.1` would make every 2.1 build look identical and hide updates. The source's
`version` therefore differs from the app's `CFBundleShortVersionString` (`2.1`); Feather does not check them against each
other (AltStore would). Every build stays in the file and in R2 as its own `cobalt-<version>-<build>.ipa`; nothing
is deleted unless you pass `--keep <n>` (or set `"keep": n` in `feather.json`), which prunes to the newest n. Publishing
a version + build that is already in the source is refused unless you pass `--replace`. (From Feather's source:
the list shows the newest version string and download; whether it also flags an already-installed copy as outdated was
not confirmed, so check the version shown against the one on the device.) The build number sets itself on every release (below).

## Cutting a release

`deploy/cobalt-deploy ios ...` is the front door: it runs `release.sh` with the same options, `--commit <ref>` ships
exactly that commit from a temporary worktree, `deploy/cobalt-deploy ios list` shows every published build (and which
are in `~/cobalt-ipas/`), and `deploy/cobalt-deploy ios url` prints the source URL.

1. Bump `MARKETING_VERSION` in `apple/project.yml` when the user-facing version should change. The build number is
   automatic: `release.sh` uses one past the newest published build, or `CURRENT_PROJECT_VERSION` from
   `apple/project.yml` if that is higher, and passes it to `xcodebuild`, so the ipa, the app's `CFBundleVersion` and the
   source all agree. `--replace` keeps `project.yml`'s number to re-publish that build.
2. `deploy/apple/release.sh --dry-run` first: builds, packs, copies dSYMs and the ipa (below), prints the
   `source.json` it would publish, uploads nothing.
3. `deploy/apple/release.sh` publishes: ipa and icon first, `source.json` last, then deletes ipas that fell out of the
   `--keep` window (only with `--keep`), then fetches the published source back to check it shows the new build.

Local copies, all named `cobalt-<version>-<build>.ipa` so a new build never overwrites an old one: `~/cobalt-ipas/` (the
archive, never pruned; `COBALT_IPA_ARCHIVE` overrides it), `~/Downloads/`, and the Taildropped file.

Flags: `--dry-run`, `--show-url` (print the real URL), `--taildrop <device>` (also `tailscale file cp` the ipa to a
device; ignored by `--dry-run`), `--notes "text"` (release note shown in Feather; default `cobalt <version> (<build>)`),
`--skip-build` (reuse the Release app already in `apple/.build/ipa`), `--keep <n>` (prune to the newest n builds; default
keeps all), `--replace` (re-publish a version + build that is already published).

Needs `xcodegen`, Xcode, `jq`, and the global `cf` logged in (`cf r2 objects put/list/delete`). Outputs land in
`apple/.build/feather/` (gitignored): the ipa, `source.json`, `icon.png`, `build.log`.

## TestFlight

`testflight.sh` (front door: `deploy/cobalt-deploy ios testflight [--dry-run] [--commit <ref>]`) archives the app signed
by the owner's team and uploads it to App Store Connect, where it lands in TestFlight after Apple processes it (about 5 to
15 minutes). It runs beside the Feather source, not instead of it. Signing is automatic: `xcodebuild` uses the App Store
Connect API key (`-allowProvisioningUpdates`) to register the bundle ids, the app group and push, and to make the
distribution certificate and profiles, so nothing is set up in Xcode or the keychain by hand. Uploads are marked
internal testing only, so they never go to Beta App Review.

Build numbers: one past the newest of the Feather source, `~/cobalt-ipas/testflight.tsv` (one line per upload) and
`apple/project.yml`; `release.sh` reads the same log, so both channels share one rising number. `--build <n>` overrides it.
The archive is deleted after the upload (disk), its dSYMs are copied to `~/cobalt-dsyms/<version>-<build>/` first, and
the upload sends symbols to Apple too.

### One-time setup (owner)

1. **App Store Connect API key**: App Store Connect > Users and Access > Integrations > App Store Connect API > Team
   Keys > +, access **Admin** (cloud signing needs it). Download `AuthKey_<key id>.p8` (Apple offers it only once) and
   note the key id and the issuer id shown above the list.
2. Save it where the script looks (no secret goes in chat or git):

       mkdir -p ~/.config/cobalt && mv ~/Downloads/AuthKey_<key id>.p8 ~/.config/cobalt/ && chmod 600 ~/.config/cobalt/AuthKey_*.p8
       printf '{"keyId":"%s","issuerId":"%s","keyPath":"~/.config/cobalt/AuthKey_%s.p8","teamId":"%s"}\n' \
         <key id> <issuer id> <key id> <team id> > ~/.config/cobalt/appstoreconnect.json && chmod 600 ~/.config/cobalt/appstoreconnect.json

   The team id is in the developer account's Membership details (10 characters). Put it in `apple/Config/Local.xcconfig`
   too (`DEVELOPMENT_TEAM = <team id>`) for device builds from Xcode.
3. `deploy/cobalt-deploy ios testflight --dry-run`: archives, registers the ids and exports a signed ipa without
   uploading. This proves signing before the app record exists.
4. **The app record**: App Store Connect > Apps > + > New App, platform iOS, bundle id `com.capybaraharmony.cobalt`,
   any SKU, a name. The App Store name must be unique across the store, so if "capystore" is taken use any variant; it
   only shows in TestFlight and App Store Connect, the home screen keeps `CFBundleDisplayName` (capystore).
5. TestFlight tab > Internal Testing > + group, add yourself, turn on automatic distribution. Install the TestFlight app
   on the phone.
6. Then each release: `deploy/cobalt-deploy ios testflight` (production: needs the owner's go).

A TestFlight install replaces a Feather install of the same bundle id. If iOS refuses because the Feather copy was signed
by a different team, delete the Feather copy first: that loses the videos kept on the phone and the saved API key (type
it again after). The keychain and app group are keyed by team id, so moving teams never carries them over.

### Live Activities on TestFlight

The Dynamic Island and Lock Screen activity (`apple/CONTRACT-LIVE.md`) is already in the app. A TestFlight build has no
`embedded.mobileprovision`, so the app reads it as the production APNs environment (`LiveEnvironment`). Without APNs the
activity still runs, but only updates while capystore is open; with APNs the server keeps it current with the app closed
and starts one for share-sheet runs. To turn that on, create an APNs key (developer.apple.com > Certificates, Identifiers
& Profiles > Keys > +, Apple Push Notifications service, environment Sandbox & Production), add it to the secrets file as
in `deploy/cloudflare/README.md` ("Live Activities"), deploy the API, then check `GET /live/selftest`.

## dSYMs

Every run copies the Release dSYMs to `~/cobalt-dsyms/<version>-<build>/` and prints the app binary UUID. Keep them: they
are what symbolicates MetricKit crash stacks from that build later. Match a crash report to its dSYM by UUID
(`dwarfdump --uuid <dSYM>`).

## The URL is the secret

R2 has no per-file access control here. Everything lives under `apps/<32 hex token>/` in the public `cobalt-media`
bucket (served at `media.capybaraharmony.com`), so the only protection is that the token is unguessable. Anyone who has
the link can download the ipa and the source. The ipa contains no keys: cobalt's API key is typed in the app by the
owner and kept in the Keychain, never built in. Treat the link like a password anyway; the script never prints it
unless `--show-url`, and `~/.config/cobalt/feather.json` (chmod 600, never committed) holds it. To rotate: replace
`token` with a new `openssl rand -hex 16`, run a release, re-add the source in Feather, and delete the old
`apps/<old token>/` objects (R2 dashboard or `cf r2 objects delete`).

## Files

- `release.sh`: the whole Feather pipeline.
- `testflight.sh`: the TestFlight pipeline (archive, sign, upload).
- Source format: AltStore source v2 as Feather's `AltSourceKit` decoder reads it (required there: non-empty `apps`,
  each app's `iconURL`, each version's `version`). We also send the AltStore-required fields (`bundleIdentifier`,
  `developerName`, `localizedDescription`, `buildVersion`, `date`, `size`, `appPermissions`).

## Not verified here

Signing and installing through Feather on a device was not exercised from this lane. The app's entitlements (push, app
group, keychain group) are ones Feather has to re-map to the owner's team; if an install fails or the share extension or
Live Activity does not appear, look there first.
