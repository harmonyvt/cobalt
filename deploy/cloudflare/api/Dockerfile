# Mirrors the root /Dockerfile of this repo (imputnet/cobalt) exactly, except
# for four deliberate deviations:
#   1. the final CMD first writes the API key file from $COBALT_KEYS_JSON
#      (injected by the Worker) and then execs the webp helper's supervisor
#      (/app/webp-helper/supervisor.js), which runs `node src/cobalt` as a child
#      and also serves the animated-WebP helper API on port 9100;
#   2. deploy/cloudflare/api/helper is copied to /app/webp-helper (plain Node,
#      no dependencies; it uses the app's own ffmpeg-static) and 9100 is
#      exposed;
#   3. /app/.git comes from deploy/cloudflare/api/.gitinfo (a synthetic git dir
#      written by prepare-git-info.sh) instead of the build stage's .git, so
#      builds work from git worktrees, where .git is a file. Run
#      prepare-git-info.sh before every build;
#   4. the final stage installs libwebp-tools (img2webp), which the webp helper
#      uses to encode animated WebPs with forced keyframes (ffmpeg's libwebp_anim
#      leaves stale blocks from earlier scenes).
# After every upstream pull (`git pull --ff-only upstream main`), diff this file
# against the root Dockerfile and re-sync it. Build context is the repo root.
# The image must be linux/amd64 (Cloudflare Containers).

FROM node:24-alpine AS base
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"

FROM base AS build
WORKDIR /app
COPY . /app

RUN corepack enable
RUN apk add --no-cache python3 alpine-sdk

RUN --mount=type=cache,id=pnpm,target=/pnpm/store \
    pnpm install --prod --frozen-lockfile

RUN pnpm deploy --filter=@imput/cobalt-api --prod /prod/api

FROM base AS api
WORKDIR /app

COPY --from=build --chown=node:node /prod/api /app
# DIFFERENCE FROM ROOT DOCKERFILE: synthetic git dir, see header.
COPY --chown=node:node deploy/cloudflare/api/.gitinfo /app/.git

# DIFFERENCE FROM ROOT DOCKERFILE: the webp helper, see header.
COPY --chown=node:node deploy/cloudflare/api/helper /app/webp-helper

# DIFFERENCE FROM ROOT DOCKERFILE: img2webp for the webp helper, see header.
RUN apk add --no-cache libwebp-tools

USER node

EXPOSE 9000 9100
# DIFFERENCE FROM ROOT DOCKERFILE: write keys (/tmp is world-writable) then exec
# the supervisor (cobalt as a child + the webp helper).
CMD [ "sh", "-c", "printf '%s' \"$COBALT_KEYS_JSON\" > /tmp/keys.json && exec node /app/webp-helper/supervisor.js" ]
