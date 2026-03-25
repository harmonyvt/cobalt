#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-start}"

case "$MODE" in
  start|ios|android)
    ;;
  *)
    echo "usage: ./scripts/dev-stack.sh [start|ios|android]" >&2
    exit 1
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_PORT="${COBALT_DEV_API_PORT:-9000}"
API_URL="${COBALT_DEV_API_URL:-http://localhost:${API_PORT}}"
WEB_PORT="${COBALT_DEV_WEB_PORT:-5173}"

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  for pid in "${API_PID:-}" "${WEB_PID:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done

  wait "${API_PID:-}" 2>/dev/null || true
  wait "${WEB_PID:-}" 2>/dev/null || true
  exit "$status"
}

trap cleanup EXIT INT TERM

cd "$ROOT_DIR"

printf 'Starting cobalt dev stack\n'
printf 'API: %s\n' "$API_URL"
printf 'Web: http://localhost:%s\n' "$WEB_PORT"
printf 'Mobile default API: %s\n\n' "$API_URL"

API_PORT="$API_PORT" API_URL="$API_URL" pnpm --filter @imput/cobalt-api run start &
API_PID=$!

WEB_DEFAULT_API="$API_URL" pnpm --filter @imput/cobalt-web exec vite dev --host 0.0.0.0 --port "$WEB_PORT" &
WEB_PID=$!

EXPO_PUBLIC_DEFAULT_API_URL="$API_URL" pnpm --filter @imput/cobalt-mobile run "$MODE"
