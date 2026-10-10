#!/usr/bin/env bash
# Capture (or verify) the M2 reference fixtures:
#   fixtures/rng/rng_sequences.v1.json
#   fixtures/rng/peg_colors.v1.json
#   fixtures/checkpoints/<level>.v1.json (+ slide.multiball3.v1.json)
#
# Usage:
#   scripts/capture_m2.sh                 # capture all M2 fixtures
#   scripts/capture_m2.sh --check         # re-capture and require equality
#   scripts/capture_m2.sh --check --id seed-345
#   scripts/capture_m2.sh --check --level slide
#   scripts/capture_m2.sh --level slide   # write; aggregate files are complete
#
# Discovery of the pinned revision/tree/config hash mirrors
# scripts/capture_fixtures.sh. The harness writes only in capture mode; check
# mode compares canonical re-captures in memory and never touches the corpus.
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

if [[ ! -f "$repo_root/interchange/levels/slide.v1.json" ]]; then
  echo "ERROR: interchange level artifacts missing; run scripts/export_interchange.sh first" >&2
  exit 1
fi

rng_out="$repo_root/fixtures/rng"
checkpoints_out="$repo_root/fixtures/checkpoints"
check=0
want_mode=0
pending=""
for arg in "$@"; do
  case "$arg" in
    --check) check=1 ;;
    --m2-capture|--m2-rng|--m2-peg-colors|--m2-checkpoints) want_mode=1 ;;
    --rng-out) pending="rng_out" ;;
    --checkpoints-out) pending="checkpoints_out" ;;
    *)
      if [[ "$pending" == "rng_out" ]]; then rng_out="$arg"; fi
      if [[ "$pending" == "checkpoints_out" ]]; then checkpoints_out="$arg"; fi
      pending=""
      ;;
  esac
done

if [[ $check -eq 0 ]]; then
  mkdir -p "$rng_out" "$checkpoints_out"
fi

levels_csv=""
while IFS= read -r file; do
  name="$(basename "$file" .v1.json)"
  if [[ -z "$levels_csv" ]]; then levels_csv="$name"; else levels_csv="$levels_csv,$name"; fi
done < <(ls "$repo_root"/interchange/levels/*.v1.json | LC_ALL=C sort)

if [[ -z "$levels_csv" ]]; then
  echo "ERROR: no static level artifacts under interchange/levels" >&2
  exit 1
fi

mode_args=()
if [[ $want_mode -eq 0 ]]; then
  mode_args+=(--m2-capture)
fi

exec "$repo_root/scripts/love.sh" love "$repo_root/harness" -- \
  "${mode_args[@]}" \
  --levels "$levels_csv" \
  --rng-out "$rng_out" \
  --checkpoints-out "$checkpoints_out" \
  --reference-revision "$revision" \
  --reference-tree "$tree" \
  --config-sha256 "$config_sha" \
  "$@"
