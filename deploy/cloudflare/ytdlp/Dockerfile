# The yt-dlp box (APP-API-CONTRACT.md section 49): saves one link at a time with yt-dlp for the studio save, next to
# cobalt. Build context is THIS directory alone: `docker build -t cobalt-ytdlp deploy/cloudflare/ytdlp`. linux/amd64
# (Cloudflare Containers).
#
# server.mjs listens on 9300 and answers only the YtDlpBox Durable Object (x-internal-key). Node is also yt-dlp's
# JavaScript runtime for YouTube's signatures (`--js-runtimes node`); ffmpeg merges the video and audio streams and
# ffprobe measures the file.
FROM node:24-trixie-slim

ARG YT_DLP_VERSION=2026.10.26

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates ffmpeg python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

# yt-dlp from PyPI (Debian's copy lags the sites it reads). `[default]` brings yt-dlp-ejs (the YouTube signature
# solver), certifi, brotli and websockets. Bump YT_DLP_VERSION and redeploy when a site breaks.
RUN python3 -m venv /opt/ytdlp \
    && /opt/ytdlp/bin/pip install --no-cache-dir "yt-dlp[default]==${YT_DLP_VERSION}" \
    && /opt/ytdlp/bin/yt-dlp --version

# Fail the build, not a save, when a tool is missing.
RUN set -e; ffmpeg -hide_banner -version | head -1; ffprobe -hide_banner -version | head -1; node --version

ENV PATH=/opt/ytdlp/bin:/usr/local/bin:/usr/bin:/bin
WORKDIR /app
COPY server.mjs /app/server.mjs
USER node
EXPOSE 9300
CMD ["node", "/app/server.mjs"]
