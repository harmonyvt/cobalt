# The chat's workbench box (APP-API-CONTRACT.md section 33.7): a plain Linux box with yt-dlp, curl, ffmpeg and python3 that
# the chat AI runs commands in when the normal tools cannot save something. Build context is THIS directory alone:
# `docker build -t cobalt-workbench deploy/cloudflare/workbench`. linux/amd64 (Cloudflare Containers).
#
# Nothing listens and nothing secret is inside: the Workbench Durable Object runs commands with the container exec API, as
# the unprivileged user `box` in /workspace, and every HTTP(S) request leaves through the Worker's outbound rule.
FROM debian:trixie-slim

ARG YT_DLP_VERSION=2026.10.26

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl ffmpeg python3 python3-venv file jq unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*

# yt-dlp from PyPI (Debian's copy lags the sites it reads), without certifi so it trusts the system bundle, which
# box-init extends with the platform's interception CA.
RUN python3 -m venv /opt/ytdlp \
    && /opt/ytdlp/bin/pip install --no-cache-dir --no-deps "yt-dlp==${YT_DLP_VERSION}" \
    && /opt/ytdlp/bin/yt-dlp --version

RUN useradd --create-home --uid 1000 --shell /bin/bash box \
    && mkdir -p /workspace && chown box:box /workspace

COPY box-init /usr/local/bin/box-init
RUN chmod 755 /usr/local/bin/box-init

# Fail the build, not a chat, when a tool is missing.
RUN set -e; curl --version | head -1; ffmpeg -hide_banner -version | head -1; python3 --version

ENV PATH=/opt/ytdlp/bin:/usr/local/bin:/usr/bin:/bin
WORKDIR /workspace
CMD ["sleep", "infinity"]
