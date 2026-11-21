#!/usr/bin/env bash
# Launch gate: build the Release app, launch it, and fail unless it is still alive after a wait AND wrote its marker.
#
# Usage: deploy/apple/launch-gate.sh ios|mac [--project apple/Cobalt.xcodeproj] [--timeout 15] [--skip-layout]
#
#   ios|mac          which app to build and launch (iOS Simulator, or this Mac)
#   --project <p>    the xcodegen'd project (default apple/Cobalt.xcodeproj)
#   --timeout <s>    seconds to wait after launch before judging (default 15)
#   --skip-layout    skip deploy/apple/layout-checks.sh (the iOS gate runs it when it exists and is executable)
#
# PASS needs both: the process is still running after the wait, and Library/Caches/launch-ok exists (LaunchMarker in
# apple/Cobalt/App/LifecycleEnvironment.swift writes it when the first window appears). A crash or hang before the first
# frame fails the gate (8.27 shipped a launch crash that no unit test could see). The simulator is COBALT_GATE_SIM
# (default 'iPhone 17 Pro,OS=27.0'). testflight.sh runs this before archiving. Fork-only; see deploy/apple/README.md.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE="$ROOT/apple"
BUNDLE_ID="com.capybaraharmony.cobalt"
SIM="${COBALT_GATE_SIM:-platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0}"
MARKER="launch-ok"

PLATFORM=""
PROJECT="$APPLE/Cobalt.xcodeproj"
TIMEOUT=15
SKIP_LAYOUT=0

die() { echo "launch-gate.sh: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
step() { printf '\n==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        ios|mac) PLATFORM="$1" ;;
        --project)
            [ $# -ge 2 ] || { echo "launch-gate.sh: --project needs a path" >&2; exit 2; }
            PROJECT="$2"; shift
            ;;
        --timeout)
            [ $# -ge 2 ] || { echo "launch-gate.sh: --timeout needs seconds" >&2; exit 2; }
            TIMEOUT="$2"; shift
            ;;
        --skip-layout) SKIP_LAYOUT=1 ;;
        -h|--help)
            sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "launch-gate.sh: unknown argument: $1 (see --help)" >&2
            exit 2
            ;;
    esac
    shift
done
[ -n "$PLATFORM" ] || { echo "launch-gate.sh: say ios or mac (see --help)" >&2; exit 2; }
case "$TIMEOUT" in ""|*[!0-9]*) die "--timeout must be whole seconds" ;; esac
case "$PROJECT" in /*) ;; *) PROJECT="$ROOT/$PROJECT" ;; esac
[ -d "$PROJECT" ] || die "no project at $PROJECT (run xcodegen generate in apple/ first)"
need xcodebuild; need plutil

FAILED=""
fail() { FAILED="$FAILED
  - $*"; }

newest_crash_report() {
    local name="$1" dir="$HOME/Library/Logs/DiagnosticReports"
    [ -d "$dir" ] || return 0
    find "$dir" -maxdepth 1 \( -name "${name}*.ips" -o -name "${name}*.crash" \) -mmin -2 -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null | head -n 1 || true
}

# ----------------------------------------------------------------------------------------------- iOS

gate_ios() {
    need xcrun; need jq
    local derived="$APPLE/.build/gate-ios" log="$APPLE/.build/gate-ios-build.log"
    mkdir -p "$APPLE/.build"

    step "xcodebuild build (Release, iOS Simulator)"
    if ! xcodebuild -project "$PROJECT" -scheme Cobalt -configuration Release \
        -destination "$SIM" -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build >"$log" 2>&1; then
        tail -n 40 "$log" >&2
        die "the Release simulator build failed; full log: $log"
    fi
    tail -n 2 "$log"

    local app exe proc
    app="$(find "$derived/Build/Products" -maxdepth 2 -name '*.app' -path '*Release-iphonesimulator*' | head -n 1)"
    [ -d "$app" ] || die "build finished but no .app under $derived/Build/Products/Release-iphonesimulator"
    exe="$(plutil -extract CFBundleExecutable raw -o - "$app/Info.plist")"
    proc="$exe"

    # The simulator named in the destination (name + OS).
    local sim_name sim_os udid
    sim_name="$(sed -n 's/.*name=\([^,]*\).*/\1/p' <<<"$SIM")"
    sim_os="$(sed -n 's/.*OS=\([^,]*\).*/\1/p' <<<"$SIM")"
    [ -n "$sim_name" ] || die "COBALT_GATE_SIM has no name=... part: $SIM"
    udid="$(xcrun simctl list -j devices available | jq -r --arg n "$sim_name" --arg os "$sim_os" '
        [.devices | to_entries[]
         | select(($os == "") or (.key | test("iOS-" + ($os | gsub("\\."; "-")) + "$")))
         | .value[] | select(.name == $n)] | (map(select(.state == "Booted")) + .) | .[0].udid // empty')"
    [ -n "$udid" ] || die "no simulator named '$sim_name' (OS ${sim_os:-any}); xcrun simctl list devices"

    step "simulator $sim_name ($udid)"
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
    xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl install "$udid" "$app"

    local data
    data="$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data)"
    rm -f "$data/Library/Caches/$MARKER"

    step "launch, then wait ${TIMEOUT}s"
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
    sleep "$TIMEOUT"

    local entry pid
    entry="$(xcrun simctl spawn "$udid" launchctl list 2>/dev/null | grep "UIKitApplication:$BUNDLE_ID" || true)"
    pid="$(awk '{print $1}' <<<"$entry" | head -n 1)"
    if [ -z "$entry" ] || [ "$pid" = "-" ] || [ -z "$pid" ]; then
        fail "the app is not running ${TIMEOUT}s after launch (crashed or exited)"
    fi
    [ -f "$data/Library/Caches/$MARKER" ] || fail "Library/Caches/$MARKER was not written (no first window appeared)"

    if [ -n "$FAILED" ]; then
        echo "LAUNCH GATE FAILED (ios):$FAILED" >&2
        echo "--- last 40 lines of the app log" >&2
        xcrun simctl spawn "$udid" log show --last 1m --predicate "process == \"$proc\"" 2>&1 | tail -n 40 >&2 || true
        local crash; crash="$(newest_crash_report "$proc")"
        [ -n "$crash" ] && echo "--- newest crash report: $crash" >&2
        xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
        exit 1
    fi
    echo "launch gate passed: alive after ${TIMEOUT}s (pid $pid), $MARKER written"

    if [ "$SKIP_LAYOUT" -eq 0 ] && [ -x "$ROOT/deploy/apple/layout-checks.sh" ]; then
        step "layout checks"
        xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
        "$ROOT/deploy/apple/layout-checks.sh" || { echo "LAUNCH GATE FAILED (ios): layout checks failed" >&2; exit 1; }
    else
        xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------------------------ Mac

gate_mac() {
    local derived="$APPLE/.build/gate-mac" log="$APPLE/.build/gate-mac-build.log"
    mkdir -p "$APPLE/.build"

    step "xcodebuild build (Release, macOS)"
    if ! xcodebuild -project "$PROJECT" -scheme Cobalt -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build >"$log" 2>&1; then
        tail -n 40 "$log" >&2
        die "the Release Mac build failed; full log: $log"
    fi
    tail -n 2 "$log"

    local app exe bin
    app="$(find "$derived/Build/Products/Release" -maxdepth 1 -name '*.app' | head -n 1)"
    [ -d "$app" ] || die "build finished but no .app under $derived/Build/Products/Release"
    exe="$(plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist")"
    bin="$app/Contents/MacOS/$exe"
    [ -x "$bin" ] || die "no executable at $bin"

    # Signed like the local install (mac-install.sh): the login keychain trusts the Developer ID signature of the key's
    # item, so the launch reads it without a prompt. Unsigned, the first launch of a build blocks in Settings.shared()
    # on the keychain access prompt (no cached key answer yet) and no window ever appears.
    local id ent
    id="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -n 1 | awk '{print $2}' || true)"
    if [ -n "$id" ]; then
        step "sign with Developer ID (as mac-install.sh)"
        ent="$(mktemp -t cobalt-gate-entitlements).plist"
        cat >"$ent" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>com.apple.security.personal-information.photos-library</key><true/>
</dict></plist>
XML
        find "$app/Contents" \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' -o -name '*.xpc' \) -prune -print 2>/dev/null |
        while read -r nested; do
            codesign --force --options runtime --timestamp=none --sign "$id" "$nested" >/dev/null
        done
        codesign --force --options runtime --timestamp=none --entitlements "$ent" --sign "$id" "$app"
        rm -f "$ent"
    else
        echo "launch-gate.sh: no Developer ID identity; unsigned, the launch may wait on the keychain prompt" >&2
    fi

    # Unsandboxed the caches folder is ~/Library/Caches itself (no bundle id folder); sandboxed it is in the container.
    local markers=("$HOME/Library/Caches/$MARKER"
                   "$HOME/Library/Caches/$BUNDLE_ID/$MARKER"
                   "$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Caches/$MARKER")
    rm -f "${markers[@]}"
    pkill -f "$bin" 2>/dev/null || true

    step "launch, then wait ${TIMEOUT}s"
    # Without saved window state: the build shares the owner's bundle id, and when their last session ended with the main
    # window closed (running from the menu bar icon) the restored launch opens no window, so the marker never comes.
    open -n -g "$app" --args -ApplePersistenceIgnoreState YES
    sleep "$TIMEOUT"

    local pid found=""
    pid="$(pgrep -f "$bin" | head -n 1 || true)"
    [ -n "$pid" ] || fail "the app is not running ${TIMEOUT}s after launch (crashed or exited)"
    for m in "${markers[@]}"; do [ -f "$m" ] && found="$m"; done
    [ -n "$found" ] || fail "$MARKER was not written to either caches folder (no first window appeared)"

    if [ -n "$FAILED" ]; then
        echo "LAUNCH GATE FAILED (mac):$FAILED" >&2
        echo "--- last 40 lines of the app log" >&2
        log show --last 1m --predicate "process == \"$exe\"" 2>&1 | tail -n 40 >&2 || true
        local crash; crash="$(newest_crash_report "$exe")"
        [ -n "$crash" ] && echo "--- newest crash report: $crash" >&2
    fi

    # Only the gate's own process: quitting by bundle id would also quit an installed cobalt the owner has open.
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
    sleep 2
    pkill -f "$bin" 2>/dev/null || true
    [ -z "$FAILED" ] || exit 1
    echo "launch gate passed: alive after ${TIMEOUT}s (pid $pid), $MARKER written ($found)"
}

case "$PLATFORM" in ios) gate_ios ;; mac) gate_mac ;; esac
