#!/usr/bin/env bash
# Build the cobalt iOS app unsigned, pack an .ipa, and publish it as a Feather / AltStore source.
#
# Usage: deploy/apple/release.sh [--dry-run] [--show-url] [--taildrop <device>] [--notes "text"] [--skip-build]
#
#   --dry-run          build, pack, copy dSYMs and the ipa, print the source.json that would be published;
#                      upload and delete nothing, send nothing (Taildrop included)
#   --show-url         print the real source URL (it contains the secret token); default prints <token>
#   --taildrop <dev>   also `tailscale file cp` the ipa to that device (ignored by --dry-run)
#   --notes "text"     "what's new" text for this version (default: "cobalt <version> (<build>)")
#   --skip-build       reuse the Release app already in apple/.build/ipa (packs, publishes; does not rebuild)
#
# Needs: xcodegen, xcodebuild, jq, curl, zip, global `cf` (authenticated), and ~/.config/cobalt/feather.json
# ({"token": "<32 hex>", "bucket": "cobalt-media", "baseUrl": "https://media.capybaraharmony.com"}, chmod 600).
# Fork-only; see deploy/apple/README.md. Never prints the token unless --show-url.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE="$ROOT/apple"
CONFIG_FILE="${COBALT_FEATHER_CONFIG:-$HOME/.config/cobalt/feather.json}"
DSYM_ROOT="${COBALT_DSYM_DIR:-$HOME/cobalt-dsyms}"
KEEP_VERSIONS=5

DRY_RUN=0
SHOW_URL=0
SKIP_BUILD=0
TAILDROP=""
NOTES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --show-url) SHOW_URL=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        --taildrop)
            [ $# -ge 2 ] || { echo "release.sh: --taildrop needs a device name" >&2; exit 2; }
            TAILDROP="$2"
            shift
            ;;
        --notes)
            [ $# -ge 2 ] || { echo "release.sh: --notes needs text" >&2; exit 2; }
            NOTES="$2"
            shift
            ;;
        -h|--help)
            sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "release.sh: unknown argument: $1 (see --help)" >&2
            exit 2
            ;;
    esac
    shift
done

die() { echo "release.sh: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
for tool in xcodegen xcodebuild jq curl zip unzip ditto dwarfdump plutil cf; do need "$tool"; done

# --- config (token is read once and only ever printed under --show-url) ----------------------------

[ -f "$CONFIG_FILE" ] || die "missing $CONFIG_FILE (see deploy/apple/README.md)"
TOKEN="$(jq -r '.token // empty' "$CONFIG_FILE")"
BUCKET="$(jq -r '.bucket // "cobalt-media"' "$CONFIG_FILE")"
BASE_URL="$(jq -r '.baseUrl // "https://media.capybaraharmony.com"' "$CONFIG_FILE")"
BASE_URL="${BASE_URL%/}"
case "$TOKEN" in
    *[!0-9a-f]*|"") die "$CONFIG_FILE: token must be 32 lowercase hex characters" ;;
esac
[ "${#TOKEN}" -eq 32 ] || die "$CONFIG_FILE: token must be 32 lowercase hex characters"

PREFIX="apps/$TOKEN"
PUBLIC_BASE="$BASE_URL/$PREFIX"
SOURCE_URL="$PUBLIC_BASE/source.json"

# Everything printed goes through redact unless --show-url, so the token cannot leak into logs.
redact() {
    if [ "$SHOW_URL" -eq 1 ]; then cat; else sed "s/$TOKEN/<token>/g"; fi
}
say() { printf '%s\n' "$*" | redact; }
step() { printf '\n==> %s\n' "$*"; }

# --- version, build, deployment target from apple/project.yml --------------------------------------

yml_setting() { # key
    sed -n "s/^[[:space:]]*$1:[[:space:]]*\"\{0,1\}\([0-9][0-9.]*\)\"\{0,1\}[[:space:]]*\$/\1/p" "$APPLE/project.yml" | head -n 1
}
VERSION="$(yml_setting MARKETING_VERSION)"
BUILD="$(yml_setting CURRENT_PROJECT_VERSION)"
MIN_OS="$(yml_setting iOS)"
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION from apple/project.yml"
[ -n "$BUILD" ] || die "could not read CURRENT_PROJECT_VERSION from apple/project.yml"
[ -n "$MIN_OS" ] || die "could not read the iOS deploymentTarget from apple/project.yml"
[ -n "$NOTES" ] || NOTES="cobalt $VERSION ($BUILD)"

IPA_NAME="cobalt-$VERSION-$BUILD.ipa"
OUT_DIR="$APPLE/.build/feather"
DERIVED="$APPLE/.build/ipa"
STAGE="$APPLE/.build/ipa-pack"
IPA="$OUT_DIR/$IPA_NAME"
ICON_SRC="$APPLE/Cobalt/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

step "cobalt $VERSION ($BUILD), iOS $MIN_OS+$([ "$DRY_RUN" -eq 1 ] && echo ", DRY RUN: nothing will be uploaded")"
[ -f "$ICON_SRC" ] || die "app icon not found: $ICON_SRC"

# --- build -----------------------------------------------------------------------------------------

mkdir -p "$OUT_DIR"
APP="$DERIVED/Build/Products/Release-iphoneos/cobalt.app"

if [ "$SKIP_BUILD" -eq 1 ]; then
    step "skipping build (--skip-build)"
    [ -d "$APP" ] || die "no built app at $APP; run without --skip-build"
else
    step "xcodegen generate"
    (cd "$APPLE" && xcodegen generate)

    step "xcodebuild Release (generic iOS, unsigned)"
    BUILD_LOG="$OUT_DIR/build.log"
    if ! xcodebuild \
        -project "$APPLE/Cobalt.xcodeproj" \
        -scheme Cobalt \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$DERIVED" \
        CODE_SIGNING_ALLOWED=NO \
        build >"$BUILD_LOG" 2>&1; then
        tail -n 40 "$BUILD_LOG" >&2
        die "xcodebuild failed; full log: $BUILD_LOG"
    fi
    tail -n 3 "$BUILD_LOG"
    [ -d "$APP" ] || die "build finished but $APP is missing"
fi

APP_PLIST="$APP/Info.plist"
BUILT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PLIST")"
BUILT_BUILD="$(plutil -extract CFBundleVersion raw -o - "$APP_PLIST")"
[ "$BUILT_VERSION" = "$VERSION" ] && [ "$BUILT_BUILD" = "$BUILD" ] \
    || die "built app is $BUILT_VERSION ($BUILT_BUILD) but project.yml says $VERSION ($BUILD); rebuild without --skip-build"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_PLIST")"

# --- pack the ipa ----------------------------------------------------------------------------------

step "pack $IPA_NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/cobalt.app"
rm -f "$IPA"
(cd "$STAGE" && zip -qry "$IPA" Payload)
[ -d "$STAGE/Payload/cobalt.app/PlugIns" ] || die "no PlugIns in the packed app (share/widget extensions missing)"
EXT_COUNT="$(unzip -Z1 "$IPA" | grep -c '^Payload/cobalt\.app/PlugIns/[^/]*\.appex/$' || true)"
IPA_BYTES="$(stat -f%z "$IPA")"
say "ipa: $IPA ($IPA_BYTES bytes, $EXT_COUNT app extensions)"

# --- dSYMs and binary UUID (for symbolicating crash stacks later) ----------------------------------

step "dSYMs"
DSYM_DIR="$DSYM_ROOT/$VERSION-$BUILD"
PRODUCTS="$DERIVED/Build/Products/Release-iphoneos"
rm -rf "$DSYM_DIR"
mkdir -p "$DSYM_DIR"
DSYM_COUNT=0
for d in "$PRODUCTS"/*.dSYM; do
    [ -d "$d" ] || continue
    ditto "$d" "$DSYM_DIR/$(basename "$d")"
    DSYM_COUNT=$((DSYM_COUNT + 1))
done
[ "$DSYM_COUNT" -gt 0 ] || echo "release.sh: warning: no dSYMs found in $PRODUCTS" >&2
say "copied $DSYM_COUNT dSYM bundles to $DSYM_DIR"
say "app binary UUID:"
dwarfdump --uuid "$APP/cobalt" | sed 's/^/  /'

# --- the copy the owner can AirDrop / open in Files -----------------------------------------------

step "copy to ~/Downloads/cobalt.ipa"
mkdir -p "$HOME/Downloads"
cp -f "$IPA" "$HOME/Downloads/cobalt.ipa"

# --- source.json -----------------------------------------------------------------------------------

step "source.json"
cp -f "$ICON_SRC" "$OUT_DIR/icon.png"

# Previous published versions, so history survives. A 404 means first publish. Anything else is not
# silently treated as empty (that would truncate the history on the next upload).
PREV="$OUT_DIR/previous-source.json"
rm -f "$PREV"
HTTP_CODE="$(curl -sS --max-time 20 -o "$PREV" -w '%{http_code}' \
    -H 'Cache-Control: no-cache' "$SOURCE_URL?cb=$(date +%s)" 2>/dev/null || echo 000)"
PREV_VERSIONS='[]'
case "$HTTP_CODE" in
    200)
        if jq -e '.apps[0].versions | type == "array"' "$PREV" >/dev/null 2>&1; then
            PREV_VERSIONS="$(jq -c '.apps[0].versions' "$PREV")"
            say "previous source has $(jq 'length' <<<"$PREV_VERSIONS") versions"
        else
            die "published source.json is not in the expected shape; refusing to overwrite it"
        fi
        ;;
    404) say "no source published yet (first release)" ;;
    *)
        if [ "$DRY_RUN" -eq 1 ]; then
            say "warning: could not read the published source (HTTP $HTTP_CODE); previewing as a first release"
        else
            die "could not read the published source (HTTP $HTTP_CODE); not publishing blind"
        fi
        ;;
esac

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
IPA_URL="$PUBLIC_BASE/$IPA_NAME"
ICON_URL="$PUBLIC_BASE/icon.png"

# AltStore v2 appPermissions, from what the app really declares: entitlement names from the iOS
# entitlements file, privacy strings from the built Info.plist.
ENTITLEMENTS="$(plutil -convert json -o - "$APPLE/Config/Cobalt-iOS.entitlements" | jq -c 'keys')"
PRIVACY="$(plutil -convert json -o - "$APP_PLIST" | jq -c 'with_entries(select(.key | test("^NS.*UsageDescription$")))')"

NEW_VERSION="$(jq -n -c \
    --arg version "$VERSION" --arg build "$BUILD" --arg date "$NOW" --arg notes "$NOTES" \
    --arg url "$IPA_URL" --argjson size "$IPA_BYTES" --arg minos "$MIN_OS" \
    '{version: $version, buildVersion: $build, date: $date, localizedDescription: $notes,
      downloadURL: $url, size: $size, minOSVersion: $minos}')"

# Newest first (Feather reads versions[0]); this build replaces an earlier upload of the same build.
VERSIONS="$(jq -c -n --argjson new "$NEW_VERSION" --argjson prev "$PREV_VERSIONS" \
    --arg v "$VERSION" --arg b "$BUILD" --argjson keep "$KEEP_VERSIONS" \
    '([$new] + [$prev[] | select((.version != $v) or (.buildVersion != $b))])[:$keep]')"

SOURCE_JSON="$OUT_DIR/source.json"
# Top-level version/versionDate/size/downloadURL on the app mirror Feather's own app-repo.json and cover
# readers that predate `versions`; they always equal versions[0].
jq -n \
    --arg src_icon "$ICON_URL" --arg bundle "$BUNDLE_ID" \
    --argjson versions "$VERSIONS" \
    --argjson entitlements "$ENTITLEMENTS" --argjson privacy "$PRIVACY" \
    '{
      name: "cobalt (private)",
      identifier: "com.capybaraharmony.cobalt.source",
      subtitle: "cobalt for iPhone, iPad and Mac, private builds",
      description: "Private builds of the cobalt app. Add this source in Feather to install and update cobalt.",
      iconURL: $src_icon,
      website: "https://cobalt.capybaraharmony.com",
      tintColor: "2f8af9",
      apps: [{
        name: "cobalt",
        bundleIdentifier: $bundle,
        developerName: "capybaraharmony",
        subtitle: "save videos and clips from links",
        localizedDescription: "cobalt saves videos, audio and clips from links you share. Private build: it talks to your own cobalt server and needs your API key.",
        iconURL: $src_icon,
        tintColor: "2f8af9",
        category: "utilities",
        versions: $versions,
        appPermissions: {entitlements: $entitlements, privacy: $privacy},
        version: $versions[0].version,
        versionDate: $versions[0].date,
        versionDescription: $versions[0].localizedDescription,
        size: $versions[0].size,
        downloadURL: $versions[0].downloadURL
      }],
      news: []
    }' >"$SOURCE_JSON"

# Sanity: the fields Feather's AltSourceKit decoder needs (apps non-empty, app iconURL, version.version).
jq -e '(.apps | length > 0) and (.apps[0].iconURL | type == "string")
       and (.apps[0].versions | length > 0) and all(.apps[0].versions[]; has("version") and has("downloadURL"))
       and (.apps[0].versions[0].version == .apps[0].version)' "$SOURCE_JSON" >/dev/null \
    || die "generated source.json failed its own sanity check"

# Versions that fall out of the window; their ipas are deleted (together with any orphan ipa under the prefix).
KEEP_KEYS="$(jq -r --arg base "$PUBLIC_BASE/" '.apps[0].versions[].downloadURL | ltrimstr($base)' "$SOURCE_JSON")"

if [ "$DRY_RUN" -eq 1 ]; then
    say "source.json that would be published to $SOURCE_URL:"
    redact <"$SOURCE_JSON"
fi

# --- cf R2 helpers ---------------------------------------------------------------------------------

cf_put() { # key file content-type
    local out
    if ! out="$(cf r2 objects put "$PREFIX/$1" --bucket-name "$BUCKET" --file "$2" --content-type "$3" 2>&1)"; then
        printf '%s\n' "$out" | redact >&2
        die "upload failed: $1"
    fi
}
cf_delete() { # key
    local out
    if ! out="$(cf r2 objects delete "$1" --bucket-name "$BUCKET" 2>&1)"; then
        printf '%s\n' "$out" | redact >&2
        die "delete failed: $1"
    fi
}
cf_list() { # prints keys under the prefix, one per line
    local out
    if ! out="$(cf r2 objects list --bucket-name "$BUCKET" --prefix "$PREFIX/" --per-page 1000 2>&1)"; then
        printf '%s\n' "$out" | redact >&2
        die "listing $BUCKET failed"
    fi
    jq -r '[.. | objects | select(has("key")) | .key] | .[]' <<<"$out"
}

step "R2 ($BUCKET, prefix apps/<token>/)"
STALE=""
if [ "$DRY_RUN" -eq 1 ] && [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "404" ]; then
    say "skipping the R2 listing in the dry run (the published source could not be read either)"
else
    EXISTING="$(cf_list || true)"
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        case "$key" in
            "$PREFIX"/cobalt-*.ipa)
                name="${key#"$PREFIX"/}"
                if ! grep -Fxq -- "$name" <<<"$KEEP_KEYS"; then STALE="$STALE$key"$'\n'; fi
                ;;
        esac
    done <<<"$EXISTING"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    say "would upload: $PREFIX/$IPA_NAME (application/octet-stream, $IPA_BYTES bytes)"
    say "would upload: $PREFIX/icon.png (image/png)"
    say "would upload: $PREFIX/source.json (application/json, last)"
    if [ -n "$STALE" ]; then
        while IFS= read -r key; do [ -n "$key" ] && say "would delete: $key"; done <<<"$STALE"
    else
        say "would delete: nothing"
    fi
    if [ -n "$TAILDROP" ]; then say "would Taildrop $IPA_NAME to $TAILDROP (skipped in a dry run)"; fi
    step "dry run done; nothing was uploaded"
else
    # Order matters: the ipa and icon first, source.json last, so a source never points at a missing file.
    cf_put "$IPA_NAME" "$IPA" application/octet-stream
    say "uploaded $IPA_NAME"
    cf_put "icon.png" "$OUT_DIR/icon.png" image/png
    say "uploaded icon.png"
    cf_put "source.json" "$SOURCE_JSON" application/json
    say "uploaded source.json"
    if [ -n "$STALE" ]; then
        while IFS= read -r key; do
            [ -n "$key" ] || continue
            cf_delete "$key"
            say "deleted old build: ${key#"$PREFIX"/}"
        done <<<"$STALE"
    fi

    # Verify what a client will fetch: the exact URL, no cache-buster. R2 sends no Cache-Control we can set
    # through `cf`, and Cloudflare does not edge-cache .json by default; check rather than assume.
    step "verify"
    OK=0
    for attempt in 1 2 3; do
        HDRS="$OUT_DIR/verify-headers.txt"
        GOT="$(curl -sS --max-time 20 -D "$HDRS" "$SOURCE_URL" 2>/dev/null | jq -r '.apps[0].versions[0].buildVersion // empty' 2>/dev/null || true)"
        if [ "$GOT" = "$BUILD" ]; then OK=1; break; fi
        sleep 3
    done
    if [ "$OK" -eq 1 ]; then
        CACHE_STATUS="$(tr -d '\r' <"$HDRS" | sed -n 's/^[Cc]f-cache-status:[[:space:]]*//p' | head -n 1)"
        say "source.json serves build $BUILD (cf-cache-status: ${CACHE_STATUS:-none})"
        case "$CACHE_STATUS" in
            HIT|REVALIDATED|UPDATING|STALE)
                say "warning: the source is being edge-cached; add a Cache Rule (bypass cache) for media.capybaraharmony.com/apps/*/source.json" ;;
        esac
    else
        say "warning: the published source.json does not show build $BUILD yet (got: ${GOT:-nothing}); check the URL and cache rules"
    fi
    IPA_REMOTE_BYTES="$(curl -sSI --max-time 20 "$IPA_URL" 2>/dev/null | tr -d '\r' | sed -n 's/^[Cc]ontent-length:[[:space:]]*//p' | head -n 1)"
    if [ "$IPA_REMOTE_BYTES" = "$IPA_BYTES" ]; then
        say "ipa downloads at $IPA_REMOTE_BYTES bytes"
    else
        say "warning: ipa content-length is ${IPA_REMOTE_BYTES:-unknown}, expected $IPA_BYTES"
    fi
fi

if [ -n "$TAILDROP" ] && [ "$DRY_RUN" -eq 0 ]; then
    step "Taildrop to $TAILDROP"
    need tailscale
    tailscale file cp "$HOME/Downloads/cobalt.ipa" "$TAILDROP:"
fi

step "source URL"
if [ "$SHOW_URL" -eq 1 ]; then
    echo "$SOURCE_URL"
else
    echo "$BASE_URL/apps/<token>/source.json   (token is in $CONFIG_FILE; pass --show-url to print the full URL)"
fi
