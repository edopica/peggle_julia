#!/usr/bin/env bash
# Run a command (normally `love ...`) with a graphical session available.
# Mirrors reference/peggle_evolved/tools/run_headless.sh so the baseline can
# run unattended on servers.
set -euo pipefail

# Native desktop sessions (macOS, Windows Git Bash/MSYS/Cygwin) already have a
# display; skip the Linux display/xvfb logic and run directly.
case "$(uname -s)" in
  Darwin|MINGW*|MSYS*|CYGWIN*)
    exec "$@"
    ;;
esac

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
