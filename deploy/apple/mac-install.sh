#!/usr/bin/env bash
# Build the macOS app (Release), sign it with this Mac's Developer ID for local use, and install it to /Applications.
#
# Usage: deploy/apple/mac-install.sh
#
# Local install facts (fork-only):
#   - NOT sandboxed: there is no provisioning profile on this Mac, so an app group / keychain group would be refused.
#     The app falls back to its own store under ~/Library/Application Support and the login keychain.
#   - Entitlement: photos library only. Hardened runtime on. Not notarized (spctl says "Unnotarized Developer ID":
#     expected for a local install).
#   - It quits a running cobalt (osascript) before replacing it. Back up ~/Movies/cobalt and
#     ~/Library/Application Support/{Videos,Sync} first when a release changes folder or store handling.
#
# Needs: xcodegen, xcodebuild, codesign, a "Developer ID Application" identity in the keychain.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE="$ROOT/apple"
LOG="${TMPDIR:-/tmp}/cobalt-mac-release.log"
ENT="$(mktemp -t cobalt-mac-entitlements).plist"

die() { echo "mac-install.sh: $*" >&2; exit 1; }
command -v xcodegen >/dev/null || die "missing tool: xcodegen"

cd "$APPLE"
xcodegen generate >/dev/null
xcodebuild -project Cobalt.xcodeproj -scheme Cobalt -configuration Release -destination 'platform=macOS' \
    -derivedDataPath .build/mac-release CODE_SIGNING_ALLOWED=NO build > "$LOG" 2>&1 || true
grep -E '\*\* BUILD (SUCCEEDED|FAILED)' "$LOG" | tail -1
grep -q '\*\* BUILD SUCCEEDED \*\*' "$LOG" || die "build failed, see $LOG"

APP="$(find .build/mac-release/Build/Products/Release -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP" ] || die "no .app in .build/mac-release"
echo "built: $APP"

# DEBUG-only launch switches must not ship in a Release binary.
if strings "$APP/Contents/MacOS/cobalt" | grep -q cobaltSandboxRoot; then
    die "Release binary still contains -cobaltSandboxRoot (DEBUG-only); refusing to install"
fi

cat > "$ENT" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>com.apple.security.personal-information.photos-library</key><true/>
</dict></plist>
XML

ID="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | awk '{print $2}')"
[ -n "$ID" ] || die "no 'Developer ID Application' identity in the keychain"

# nested code first (frameworks, plugins, helpers), then the app
find "$APP/Contents" \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' -o -name '*.xpc' \) -prune -print 2>/dev/null |
while read -r nested; do
    codesign --force --options runtime --timestamp=none --sign "$ID" "$nested" >/dev/null
done
codesign --force --options runtime --timestamp=none --entitlements "$ENT" --sign "$ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "signature ok"

NAME="$(basename "$APP")"
PROC="$(basename "$NAME" .app)"
if pgrep -x "$PROC" >/dev/null; then
    osascript -e "quit app \"$PROC\"" || true
    sleep 1
fi
rm -rf "/Applications/$NAME"
ditto "$APP" "/Applications/$NAME"
PLIST="/Applications/$NAME/Contents/Info.plist"
echo "installed /Applications/$NAME version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST"))"
rm -f "$ENT"
