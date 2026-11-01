# The yt-dlp box (APP-API-CONTRACT.md section 49): saves one link at a time with yt-dlp for the studio save, next to
# cobalt. Build context is THIS directory alone: `docker build -t cobalt-ytdlp deploy/cloudflare/ytdlp`. linux/amd64
# (Cloudflare Containers).
#
# server.mjs listens on 9300 and answers only the YtDlpBox Durable Object (x-internal-key). Node is also yt-dlp's
# JavaScript runtime for YouTube's signatures (`--js-runtimes node`); ffmpeg merges the video and audio streams and
# ffprobe measures the file.
FROM node:24-trixie-slim

# yt-dlp's own standalone Linux build from its GitHub release (https://github.com/yt-dlp/yt-dlp/releases): one binary
# with Python and the extras inside (yt-dlp-ejs, the YouTube signature solver, included). Pinned by version AND sha256
# (from the release's SHA2-256SUMS): a bump changes both lines. Bump and redeploy the API when a site breaks.
ARG YT_DLP_VERSION=2026.10.26
ARG YT_DLP_SHA256=767ba9dce7052aa196f8b12652f433d76de128ba168966fa84b6394d5e6c6795

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl ffmpeg \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /usr/local/bin/yt-dlp "https://github.com/yt-dlp/yt-dlp/releases/download/${YT_DLP_VERSION}/yt-dlp_linux" \
    && echo "${YT_DLP_SHA256}  /usr/local/bin/yt-dlp" | sha256sum -c - \
    && chmod 755 /usr/local/bin/yt-dlp \
    && yt-dlp --version

# Fail the build, not a save, when a tool is missing.
RUN set -e; ffmpeg -hide_banner -version | head -1; ffprobe -hide_banner -version | head -1; node --version

WORKDIR /app
COPY server.mjs /app/server.mjs
USER node
EXPOSE 9300
CMD ["node", "/app/server.mjs"]
