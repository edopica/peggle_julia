#!/usr/bin/env bash
# Verify the vendored reference tree against reference/files.sha256.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ref_dir="$repo_root/reference/peggle_evolved"
manifest="$repo_root/reference/files.sha256"

if [[ ! -d "$ref_dir" ]]; then
  echo "ERROR: missing vendored reference at $ref_dir" >&2
  exit 1
fi
if [[ ! -f "$manifest" ]]; then
  echo "ERROR: missing manifest at $manifest" >&2
  exit 1
fi

actual="$(mktemp)"
expected="$(mktemp)"
trap 'rm -f "$actual" "$expected"' EXIT

(cd "$ref_dir" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$actual"
sort -k2 "$manifest" > "$expected"

if diff -u "$expected" "$actual" > /dev/null; then
  echo "reference OK: $(wc -l < "$expected") files match $manifest"
else
  echo "ERROR: reference tree does not match the manifest:" >&2
  diff -u "$expected" "$actual" >&2 || true
  exit 1
fi
