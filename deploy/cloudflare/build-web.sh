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
    --exclude '/mobile' --exclude '/web/build' --exclude '/web/.svelte-kit' \
    "$repo/" "$tmp/"
cp -R "$here/api/.gitinfo" "$tmp/.git"

cd "$tmp"
$PNPM install --frozen-lockfile
$PNPM --filter @imput/cobalt-web build

rm -rf "$repo/web/build"
cp -R "$tmp/web/build" "$repo/web/build"
echo "web build written to $repo/web/build"
