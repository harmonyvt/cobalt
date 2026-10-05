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
install over the old one. The last 5 builds stay in the file; older ipas are deleted from R2. (From Feather's source:
the list shows the newest version string and download; whether it also flags an already-installed copy as outdated was
not confirmed, so check the version shown against the one on the device.) Bump the version for every release (below).

## Cutting a release

1. Bump `MARKETING_VERSION` and/or `CURRENT_PROJECT_VERSION` in `apple/project.yml` (`CURRENT_PROJECT_VERSION` must
   change on every release; it is the build number and part of the ipa name).
2. `deploy/apple/release.sh --dry-run` first: builds, packs, copies dSYMs and `~/Downloads/cobalt.ipa`, prints the
   `source.json` it would publish, uploads nothing.
3. `deploy/apple/release.sh` publishes: ipa and icon first, `source.json` last, then deletes ipas that fell out of the
   5-version window, then fetches the published source back to check it shows the new build.

Flags: `--dry-run`, `--show-url` (print the real URL), `--taildrop <device>` (also `tailscale file cp` the ipa to a
device; ignored by `--dry-run`), `--notes "text"` (release note shown in Feather; default `cobalt <version> (<build>)`),
`--skip-build` (reuse the Release app already in `apple/.build/ipa`).

Needs `xcodegen`, Xcode, `jq`, and the global `cf` logged in (`cf r2 objects put/list/delete`). Outputs land in
`apple/.build/feather/` (gitignored): the ipa, `source.json`, `icon.png`, `build.log`.

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

- `release.sh`: the whole pipeline.
- Source format: AltStore source v2 as Feather's `AltSourceKit` decoder reads it (required there: non-empty `apps`,
  each app's `iconURL`, each version's `version`). We also send the AltStore-required fields (`bundleIdentifier`,
  `developerName`, `localizedDescription`, `buildVersion`, `date`, `size`, `appPermissions`).

## Not verified here

Signing and installing through Feather on a device was not exercised from this lane. The app's entitlements (push, app
group, keychain group) are ones Feather has to re-map to the owner's team; if an install fails or the share extension or
Live Activity does not appear, look there first.
