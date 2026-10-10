#!/usr/bin/env bash
# Verify generated interchange artifacts against interchange/files.sha256.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
interchange="${INTERCHANGE_DIR:-$repo_root/interchange}"
manifest="$interchange/files.sha256"

if [[ ! -f "$manifest" ]]; then
  echo "ERROR: missing manifest at $manifest (run scripts/export_interchange.sh)" >&2
  exit 1
fi

actual="$(mktemp)"
expected="$(mktemp)"
trap 'rm -f "$actual" "$expected"' EXIT

(
  cd "$interchange"
  find . -type f ! -name 'files.sha256' -print0 | sort -z | xargs -0 sha256sum
) > "$actual"
sort -k2 "$manifest" > "$expected"

if diff -u "$expected" "$actual" > /dev/null; then
  echo "interchange OK: $(wc -l < "$expected") files match $manifest"
else
  echo "ERROR: interchange artifacts do not match the manifest:" >&2
  diff -u "$expected" "$actual" >&2 || true
  exit 1
fi
