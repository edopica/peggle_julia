#!/usr/bin/env bash
# Run LÖVE commands for Peggle Evolved with a graphical session environment.
# LÖVE opens a window even in bench/replay/headless mode, so unattended runs
# (Hermes cron, SSH, etc.) need display env vars injected.
#
# Usage: tools/run_headless.sh love . -- --bench --level NAME
#
# The env file defaults to ~/.hermes/scripts/love-env.sh (override with
# HERMES_LOVE_ENV). If no display is available and xvfb-run exists, fall back
# to a virtual framebuffer.
set -euo pipefail

ENV_FILE="${HERMES_LOVE_ENV:-$HOME/.hermes/scripts/love-env.sh}"

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
  if command -v xvfb-run >/dev/null 2>&1; then
    exec xvfb-run -a "$@"
  fi
  echo "ERROR: no display (WAYLAND_DISPLAY/DISPLAY unset) and xvfb-run not installed" >&2
  echo "Create $ENV_FILE with your session env, for example:" >&2
  echo "  printf 'export WAYLAND_DISPLAY=wayland-1\\n' > \"$ENV_FILE\"" >&2
  exit 1
fi

exec "$@"
