# The editor's render container (APP-API-CONTRACT.md 31.8): Node plus ffmpeg, and the helper. Build context is THIS directory
# alone (no monorepo copy, no prepare-git-info.sh): `docker build -t cobalt-edit-render deploy/cloudflare/editor`.
# The image must be linux/amd64 (Cloudflare Containers).
FROM node:24-alpine

# ffmpeg from Alpine: libx264 (the encoder), libzscale/zimg (the HDR tone-map), and the gif / png / mjpeg decoders.
RUN apk add --no-cache ffmpeg

# Fail the build, not a render, when the ffmpeg in the image lacks something the compiler's graph needs.
RUN set -e; \
    ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; \
    ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE ' aac '; \
    ffmpeg -hide_banner -filters  2>/dev/null | grep -q zscale; \
    ffmpeg -hide_banner -filters  2>/dev/null | grep -q tonemap; \
    ffmpeg -hide_banner -decoders 2>/dev/null | grep -qE ' gif '; \
    ffmpeg -hide_banner -decoders 2>/dev/null | grep -qE ' png '; \
    ffmpeg -hide_banner -decoders 2>/dev/null | grep -qE ' mjpeg '; \
    ffmpeg -hide_banner -filters  2>/dev/null | grep -qE ' (colorchannelmixer|overlay|amix|adelay|atempo|loop|tpad|concat|anullsrc|pan) ' ; \
    ffmpeg -version | head -1

WORKDIR /app
COPY helper /app/helper

ENV NODE_ENV=production \
    EDIT_WORK_DIR=/tmp/edit \
    EDIT_PORT=9200
EXPOSE 9200

# EDIT_INTERNAL_KEY and EDIT_DEPLOY_VERSION come from the Durable Object (EditRenderer.envVars). Without a key every request is 403.
CMD ["node", "/app/helper/server.js"]
