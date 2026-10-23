#!/usr/bin/env bash
# Archive the capystore iOS app signed for App Store Connect and upload it to TestFlight.
#
# Usage: deploy/apple/testflight.sh [--dry-run] [--build <n>] [--keep-archive]
#
#   --dry-run        archive and export a signed App Store ipa into apple/.build/testflight/; upload nothing
#   --build <n>      use this build number (default: one past the newest build of the Feather source, the TestFlight
#                    log and apple/project.yml, so both channels share one rising build number)
#   --keep-archive   keep the .xcarchive (default: deleted after the export to save disk; the dSYMs are copied first)
#
# Signing is automatic: xcodebuild signs in to the developer account with the App Store Connect API key below
# (-allowProvisioningUpdates), registers the bundle ids, the app group and push for the app and its extensions, and
# makes the distribution certificate and profiles itself. Nothing is installed in the keychain by hand.
#
# Needs: xcodegen, Xcode, jq, curl, plutil, and either the Apple ID of the team signed in to Xcode (Settings > Accounts)
# with "teamId" in the config or DEVELOPMENT_TEAM in apple/Config/Local.xcconfig, or a TEAM API key in
# ~/.config/cobalt/appstoreconnect.json (chmod 600, never committed):
#   {"keyId": "<key id>", "issuerId": "<uuid>", "keyPath": "~/.config/cobalt/AuthKey_<keyId>.p8", "teamId": "<10 chars>"}
# The key needs the Admin role (cloud-managed distribution signing). "teamId" may be left out when
# apple/Config/Local.xcconfig sets DEVELOPMENT_TEAM. Fork-only; see deploy/apple/README.md ("TestFlight").
# Never prints the key or its path's contents.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE="$ROOT/apple"
ASC_CONFIG="${COBALT_ASC_CONFIG:-$HOME/.config/cobalt/appstoreconnect.json}"
FEATHER_CONFIG="${COBALT_FEATHER_CONFIG:-$HOME/.config/cobalt/feather.json}"
DSYM_ROOT="${COBALT_DSYM_DIR:-$HOME/cobalt-dsyms}"
IPA_ARCHIVE="${COBALT_IPA_ARCHIVE:-$HOME/cobalt-ipas}"
TF_LOG="$IPA_ARCHIVE/testflight.tsv"

DRY_RUN=0
KEEP_ARCHIVE=0
BUILD_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --keep-archive) KEEP_ARCHIVE=1 ;;
        --build)
            [ $# -ge 2 ] || { echo "testflight.sh: --build needs a number" >&2; exit 2; }
            BUILD_ARG="$2"
            shift
            ;;
        -h|--help)
            sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "testflight.sh: unknown argument: $1 (see --help)" >&2
            exit 2
            ;;
    esac
    shift
done

die() { echo "testflight.sh: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
step() { printf '\n==> %s\n' "$*"; }
for tool in xcodegen xcodebuild jq curl plutil ditto; do need "$tool"; done

# --- App Store Connect key and team ---------------------------------------------------------------

# Two ways to sign in, picked by the config: a TEAM API key (keyId + issuerId + the .p8; works with nobody signed in to
# Xcode), or, when the config has no issuerId (no file, or an individual key, which xcodebuild cannot use), the Apple ID
# signed in under Xcode > Settings > Accounts, which signs and uploads the same way.
KEY_ID=""; ISSUER_ID=""; KEY_PATH=""; TEAM_ID=""
if [ -f "$ASC_CONFIG" ]; then
    KEY_ID="$(jq -r '.keyId // empty' "$ASC_CONFIG")"
    ISSUER_ID="$(jq -r '.issuerId // empty' "$ASC_CONFIG")"
    KEY_PATH="$(jq -r '.keyPath // empty' "$ASC_CONFIG")"
    TEAM_ID="$(jq -r '.teamId // empty' "$ASC_CONFIG")"
fi
case "$ISSUER_ID" in *[!0-9A-Fa-f-]*) ISSUER_ID="" ;; esac       # a placeholder left in is no issuer id
if [ -z "$TEAM_ID" ] && [ -f "$APPLE/Config/Local.xcconfig" ]; then
    TEAM_ID="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]\{10\}\).*$/\1/p' \
        "$APPLE/Config/Local.xcconfig" | head -n 1)"
fi
case "$TEAM_ID" in [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
    *) die "no team id: set \"teamId\" in $ASC_CONFIG or DEVELOPMENT_TEAM in apple/Config/Local.xcconfig" ;; esac
if [ -n "$ISSUER_ID" ]; then
    KEY_PATH="${KEY_PATH/#\~/$HOME}"
    [ -n "$KEY_PATH" ] || KEY_PATH="$HOME/.config/cobalt/AuthKey_$KEY_ID.p8"
    case "$KEY_ID" in ""|*[!A-Za-z0-9]*) die "$ASC_CONFIG: keyId must be the key id (letters and digits, from the file name)" ;; esac
    [ -f "$KEY_PATH" ] || die "the API key file is missing: $KEY_PATH"
    AUTH=(-allowProvisioningUpdates
          -authenticationKeyPath "$KEY_PATH"
          -authenticationKeyID "$KEY_ID"
          -authenticationKeyIssuerID "$ISSUER_ID")
    echo "signing in with the App Store Connect team key $KEY_ID"
else
    AUTH=(-allowProvisioningUpdates)
    echo "signing in with the Apple ID in Xcode > Settings > Accounts (no team key with an issuer id in ${ASC_CONFIG/#"$HOME"/\~})"
fi

# --- version and build number ---------------------------------------------------------------------

yml_setting() { # key
    sed -n "s/^[[:space:]]*$1:[[:space:]]*\"\{0,1\}\([0-9][0-9.]*\)\"\{0,1\}[[:space:]]*\$/\1/p" "$APPLE/project.yml" | head -n 1
}
VERSION="$(yml_setting MARKETING_VERSION)"
YML_BUILD="$(yml_setting CURRENT_PROJECT_VERSION)"
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION from apple/project.yml"

if [ -n "$BUILD_ARG" ]; then
    case "$BUILD_ARG" in ""|*[!0-9]*) die "--build must be a whole number" ;; esac
    BUILD="$BUILD_ARG"
else
    step "build number"
    FEATHER_MAX=0
    if [ -f "$FEATHER_CONFIG" ]; then
        token="$(jq -r '.token // empty' "$FEATHER_CONFIG")"
        base="$(jq -r '.baseUrl // "https://media.capybaraharmony.com"' "$FEATHER_CONFIG")"
        if body="$(curl -fsS --max-time 20 -H 'Cache-Control: no-cache' \
                "${base%/}/apps/$token/source.json?cb=$(date +%s)" 2>/dev/null)"; then
            FEATHER_MAX="$(jq -r '[.apps[0].versions[].buildVersion | tonumber? // empty] | max // 0' <<<"$body" \
                2>/dev/null)" || FEATHER_MAX=0
        else
            echo "testflight.sh: warning: could not read the Feather source; counting TestFlight builds only" >&2
        fi
    fi
    FEATHER_MAX="${FEATHER_MAX:-0}"
    TF_MAX=0
    [ -f "$TF_LOG" ] && TF_MAX="$(awk -F'\t' '$2 ~ /^[0-9]+$/ && $2 > m { m = $2 } END { print m + 0 }' "$TF_LOG")"
    BUILD=$((FEATHER_MAX > TF_MAX ? FEATHER_MAX + 1 : TF_MAX + 1))
    [ "${YML_BUILD:-0}" -gt "$BUILD" ] && BUILD="$YML_BUILD"
    echo "build $BUILD (newest Feather $FEATHER_MAX, newest TestFlight $TF_MAX, project.yml ${YML_BUILD:-?})"
fi

OUT="$APPLE/.build/testflight"
ARCHIVE="$OUT/cobalt-$VERSION-$BUILD.xcarchive"
EXPORT_DIR="$OUT/export-$VERSION-$BUILD"
LOG="$OUT/xcodebuild.log"
mkdir -p "$OUT"
rm -rf "$ARCHIVE" "$EXPORT_DIR"

step "capystore $VERSION ($BUILD) for TestFlight$([ "$DRY_RUN" -eq 1 ] && echo ", DRY RUN: nothing will be uploaded")"

# --- archive --------------------------------------------------------------------------------------

step "xcodegen generate"
(cd "$APPLE" && xcodegen generate)

step "xcodebuild archive (Release, signed by team $TEAM_ID)"
if ! xcodebuild \
    -project "$APPLE/Cobalt.xcodeproj" \
    -scheme Cobalt \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    "${AUTH[@]}" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    CURRENT_PROJECT_VERSION="$BUILD" \
    archive >"$LOG" 2>&1; then
    tail -n 40 "$LOG" >&2
    die "archive failed; full log: $LOG"
fi
tail -n 2 "$LOG"
[ -d "$ARCHIVE/Products/Applications/cobalt.app" ] || die "archive finished but cobalt.app is missing from it"

# --- dSYMs (they symbolicate MetricKit stacks later; TestFlight gets its own copy via uploadSymbols) ---

DSYM_DIR="$DSYM_ROOT/$VERSION-$BUILD"
mkdir -p "$DSYM_DIR"
count=0
for d in "$ARCHIVE"/dSYMs/*.dSYM; do
    [ -d "$d" ] || continue
    ditto "$d" "$DSYM_DIR/$(basename "$d")"
    count=$((count + 1))
done
echo "copied $count dSYM bundles to $DSYM_DIR"

# --- export (and upload) --------------------------------------------------------------------------

DEST=upload
[ "$DRY_RUN" -eq 1 ] && DEST=export
OPTIONS="$OUT/ExportOptions.plist"
cat >"$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$DEST</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>testFlightInternalTestingOnly</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$OPTIONS" >/dev/null || die "ExportOptions.plist is not valid"

step "xcodebuild -exportArchive (destination: $DEST)"
if ! xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$OPTIONS" \
    "${AUTH[@]}" >>"$LOG" 2>&1; then
    tail -n 40 "$LOG" >&2
    die "export$([ "$DEST" = upload ] && echo "/upload") failed; full log: $LOG"
fi
tail -n 3 "$LOG"

if [ "$DRY_RUN" -eq 1 ]; then
    ipa="$(ls "$EXPORT_DIR"/*.ipa 2>/dev/null | head -n 1 || true)"
    [ -n "$ipa" ] || die "export finished but no ipa in $EXPORT_DIR"
    echo "signed App Store ipa (not uploaded): $ipa"
else
    mkdir -p "$IPA_ARCHIVE"
    printf '%s\t%s\t%s\t%s\n' "$VERSION" "$BUILD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo -)" >>"$TF_LOG"
    echo "uploaded capystore $VERSION ($BUILD); App Store Connect takes about 5 to 15 minutes to process it,"
    echo "then it appears in TestFlight for the internal testing group. Logged in ${TF_LOG/#"$HOME"/\~}."
fi

if [ "$KEEP_ARCHIVE" -eq 0 ]; then
    rm -rf "$ARCHIVE"
    [ "$DRY_RUN" -eq 1 ] || rm -rf "$EXPORT_DIR"
fi
