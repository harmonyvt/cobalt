#!/bin/sh
# Builds the web app into <repo>/web/build for the private deployment.
#
# Why not just `pnpm --filter @imput/cobalt-web build`: the web build prerenders
# /version.json through packages/version-info, which reads .git/HEAD etc. In a
# git worktree .git is a file, so the build fails with ENOTDIR. This script
# builds in a temporary copy of the tree that has a synthetic .git directory
# (from api/prepare-git-info.sh) and copies web/build back. It works from any
# checkout, normal or worktree, and leaves the checkout's own .git untouched.
#
# Override PNPM to use another pnpm 9 (default: npx pnpm@9.6.0).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
PNPM=${PNPM:-"npx --yes pnpm@9.6.0"}
WEB_DEFAULT_API=${WEB_DEFAULT_API:-https://api.capybaraharmony.com/}
WEB_HOST=${WEB_HOST:-cobalt.capybaraharmony.com}
export WEB_DEFAULT_API WEB_HOST

"$here/api/prepare-git-info.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/cobalt-web-build.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

rsync -a \
    --exclude '/.git' --exclude 'node_modules' --exclude '/deploy' \
    --exclude '/mobile' --exclude '/apple' --exclude '/web/build' --exclude '/web/.svelte-kit' \
    "$repo/" "$tmp/"
cp -R "$here/api/.gitinfo" "$tmp/.git"

# Fork rename: the web app shows "capystore". Patched in the temp copy only, so the
# upstream web/ files stay untouched and upstream pulls stay clean.
APP_NAME=${APP_NAME:-capystore}
for f in "$tmp"/web/i18n/*/general.json; do
    sed -i.bak -E 's/^( *"cobalt": )"[^"]*"/\1"'"$APP_NAME"'"/' "$f" && rm -f "$f.bak"
done
sed -i.bak -E 's/"(name|short_name)": "cobalt"/"\1": "'"$APP_NAME"'"/' "$tmp/web/static/manifest.json"
sed -i.bak -E 's/(name="(application-name|apple-mobile-web-app-title)" content=)"cobalt"/\1"'"$APP_NAME"'"/' "$tmp/web/src/app.html"
rm -f "$tmp/web/static/manifest.json.bak" "$tmp/web/src/app.html.bak"

cd "$tmp"
$PNPM install --frozen-lockfile
$PNPM --filter @imput/cobalt-web build

rm -rf "$repo/web/build"
cp -R "$tmp/web/build" "$repo/web/build"
echo "web build written to $repo/web/build"
