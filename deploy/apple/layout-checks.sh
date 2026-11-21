#!/usr/bin/env bash
# Layout checks: the CobaltUITests target on the iOS Simulator (and an iPad when asked). What the owner chose in the
# library (the picks, the post in the inspector, the bar's menus) must survive a rotation, a trip to the background and
# the iPad's spread pane opening and closing (apple/CobaltUITests/LayoutStateUITests.swift).
#
# Usage: deploy/apple/layout-checks.sh [--project apple/Cobalt.xcodeproj] [--help]
#
#   COBALT_GATE_SIM    the iPhone destination (default 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0')
#   COBALT_GATE_IPAD   an iPad destination, e.g. 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0';
#                      unset skips the iPad run (the pane check only runs there)
#
# Debug configuration on purpose: the tests launch the app with `-previewScenario happy -previewTab library`, and those
# launch arguments exist only in Debug builds (apple/Cobalt/App/CobaltApp.swift, LaunchConfig). Exits non-zero when any
# run fails. launch-gate.sh (the TestFlight gate) runs this after the launch check when it is executable.
# Fork-only; see deploy/apple/README.md.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="$ROOT/apple/Cobalt.xcodeproj"
SIM="${COBALT_GATE_SIM:-platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0}"
IPAD="${COBALT_GATE_IPAD:-}"
DERIVED="$ROOT/apple/.build/gate-ui"

usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "layout-checks.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --project)
            [ $# -ge 2 ] || { echo "layout-checks.sh: --project needs a path" >&2; exit 2; }
            PROJECT="$2"; shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "layout-checks.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

command -v xcodebuild >/dev/null 2>&1 || die "missing tool: xcodebuild (run this on the Mac)"
if [ ! -d "$PROJECT" ]; then
    command -v xcodegen >/dev/null 2>&1 || die "no $PROJECT and no xcodegen to make it"
    (cd "$ROOT/apple" && xcodegen generate)
fi

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cobalt-layout.XXXXXX")"
trap 'rm -rf "$LOG_DIR"' EXIT

# One destination. The project defines no schemes, so `Cobalt` is the scheme Xcode makes for the app, which lists the
# UI test bundle that tests it; if this Xcode left the bundle out of it, the bundle's own scheme runs the same tests.
run() {
    local name="$1" destination="$2" log="$LOG_DIR/$1.log"
    printf '\n==> layout checks: %s (%s)\n' "$name" "$destination"
    local scheme
    for scheme in Cobalt CobaltUITests; do
        if xcodebuild test \
            -project "$PROJECT" \
            -scheme "$scheme" \
            -configuration Debug \
            -only-testing:CobaltUITests \
            -destination "$destination" \
            -derivedDataPath "$DERIVED" \
            CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$log"; then
            echo "layout checks passed: $name"
            return 0
        fi
        # only a scheme without the bundle is worth a second try; a failing test is a failure
        if [ "$scheme" = Cobalt ] && grep -Eq "isn't a member of the specified test plan or scheme|does not contain a test target|is not configured for the test action" "$log"; then
            echo "layout-checks.sh: the Cobalt scheme has no CobaltUITests; trying its own scheme" >&2
            continue
        fi
        break
    done
    echo "LAYOUT CHECKS FAILED: $name (log above)" >&2
    return 1
}

failed=0
run iphone "$SIM" || failed=1
if [ -n "$IPAD" ]; then
    run ipad "$IPAD" || failed=1
else
    echo "layout-checks.sh: COBALT_GATE_IPAD is not set; the iPad pane check did not run"
fi
exit "$failed"
