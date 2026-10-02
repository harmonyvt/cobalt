#!/bin/sh
# Writes a minimal synthetic git directory to ./.gitinfo/ next to this script.
#
# packages/version-info reads .git/HEAD, .git/config and .git/logs/HEAD at API
# startup. In a git worktree (or any checkout where .git is a file) the real
# .git cannot be copied into the image, so the Dockerfile copies this directory
# to /app/.git instead. Run it before every image build / deploy, from any
# checkout.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="$here/.gitinfo"

commit=$(git -C "$here" rev-parse HEAD)
branch=$(git -C "$here" rev-parse --abbrev-ref HEAD)
# detached HEAD reports "HEAD"; keep it a valid ref-less value in that case
remote=$(git -C "$here" remote get-url origin 2>/dev/null || true)
[ -n "$remote" ] || remote="https://github.com/harmonyvt/cobalt.git"
now=$(date +%s)
zero=0000000000000000000000000000000000000000

rm -rf "$out"
mkdir -p "$out/logs"

if [ "$branch" = "HEAD" ]; then
    printf '%s\n' "$commit" > "$out/HEAD"
else
    printf 'ref: refs/heads/%s\n' "$branch" > "$out/HEAD"
fi

printf '[remote "origin"]\n\turl = %s\n' "$remote" > "$out/config"

# format parsed by version-info: last line, space-split, field 2 = commit
printf '%s %s cobalt-deploy <deploy@localhost> %s +0000\tdeploy\n' \
    "$zero" "$commit" "$now" > "$out/logs/HEAD"

echo "wrote $out (branch=$branch commit=$commit remote=$remote)"
