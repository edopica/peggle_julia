#!/usr/bin/env bash
# Capture (or verify) the M1 reference fixture catalog.
#
# Usage:
#   scripts/capture_fixtures.sh                 # capture all expected records
#   scripts/capture_fixtures.sh --id ID         # capture one fixture
#   scripts/capture_fixtures.sh --check         # re-capture and require equality
#   scripts/capture_fixtures.sh --list-fixtures # list catalog entries
#
# Extra harness options are passed through, e.g. --fixtures-traces DIR.
# In check mode the harness never writes to the expected-record or trace
# directories; traces are re-captured to temporary files.
#
# Requires a display (or xvfb-run); scripts/love.sh handles both.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ref_dir="$repo_root/reference/peggle_evolved"
pin="$repo_root/reference/PIN.md"

revision="$(sed -n 's/.*Revision (full) | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
tree="$(sed -n 's/.*Tree hash | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
if [[ -z "$revision" || -z "$tree" ]]; then
  echo "ERROR: cannot read revision/tree from $pin" >&2
  exit 1
fi
config_sha="$(sha256sum "$ref_dir/src/config.lua" | awk '{print $1}')"

# Level artifacts must exist before shot fixtures can record level provenance.
if [[ ! -f "$repo_root/interchange/levels/slide.v1.json" ]]; then
  echo "ERROR: interchange level artifacts missing; run scripts/export_interchange.sh first" >&2
  exit 1
fi

mkdir -p "$repo_root/fixtures/expected" "$repo_root/fixtures/traces"

exec "$repo_root/scripts/love.sh" love "$repo_root/harness" -- \
  --fixtures \
  --reference-revision "$revision" \
  --reference-tree "$tree" \
  --config-sha256 "$config_sha" \
  "$@"
