#!/usr/bin/env bash
# Capture (or verify) the M2 cross-language math census fixture:
#   fixtures/math_census/math_census.v1.json
#
# Usage:
#   scripts/capture_math_census.sh                 # capture the fixture
#   scripts/capture_math_census.sh --check         # recompute and compare
#   scripts/capture_math_census.sh --out PATH      # write elsewhere
#
# Provenance discovery mirrors scripts/capture_fixtures.sh. The tool itself is
# plain `luajit` (system libm); no display is required. --check never writes
# the committed fixture.
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

if ! compgen -G "$repo_root/interchange/levels/*.v1.json" > /dev/null; then
  echo "ERROR: interchange level artifacts missing; run scripts/export_interchange.sh first" >&2
  exit 1
fi
if [[ ! -f "$repo_root/interchange/files.sha256" ]]; then
  echo "ERROR: interchange/files.sha256 missing; run scripts/export_interchange.sh first" >&2
  exit 1
fi
if ! compgen -G "$repo_root/fixtures/expected/*.json" > /dev/null; then
  echo "ERROR: fixtures/expected records missing; run scripts/capture_fixtures.sh first" >&2
  exit 1
fi

check=0
for arg in "$@"; do
  [[ "$arg" == "--check" ]] && check=1
done
if [[ $check -eq 0 ]]; then
  mkdir -p "$repo_root/fixtures/math_census"
fi

exec luajit "$repo_root/tools/capture_math_census.lua" \
  --reference-revision "$revision" \
  --reference-tree "$tree" \
  --config-sha256 "$config_sha" \
  "$@"
