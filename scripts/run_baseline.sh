#!/usr/bin/env bash
# Run the M0 baseline sweep against the pinned reference.
#
# Usage:
#   scripts/run_baseline.sh [harness options...]
#
# Environment:
#   RUN_ID      label for output files (default: UTC timestamp)
#   HOST_LABEL  host label (default: short hostname)
#   OUT_DIR     result directory (default: <repo>/results)
#
# Examples:
#   scripts/run_baseline.sh --stride 20 --workload circles_small
#   scripts/run_baseline.sh --repeat 3
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ref_dir="$repo_root/reference/peggle_evolved"
pin="$repo_root/reference/PIN.md"

if [[ ! -d "$ref_dir" ]]; then
  echo "ERROR: missing vendored reference at $ref_dir" >&2
  exit 1
fi

revision="$(sed -n 's/.*Revision (full) | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
tree="$(sed -n 's/.*Tree hash | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
if [[ -z "$revision" || -z "$tree" ]]; then
  echo "ERROR: cannot read revision/tree from $pin" >&2
  exit 1
fi

config_sha="$(sha256sum "$ref_dir/src/config.lua" | awk '{print $1}')"
run_id="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
host_label="${HOST_LABEL:-$(hostname -s)}"
out_dir="${OUT_DIR:-$repo_root/results}"
raw_dir="$out_dir/raw"
mkdir -p "$raw_dir"

out_prefix="$raw_dir/${run_id}_${host_label}"
summary_prefix="$out_dir/${run_id}_${host_label}"

echo "run_id=$run_id host=$host_label"
echo "reference=$revision config_sha256=$config_sha"

"$repo_root/scripts/love.sh" love "$repo_root/harness" -- \
  --sweep \
  --out "$out_prefix" \
  --summary-out "$summary_prefix" \
  --reference-revision "$revision" \
  --reference-tree "$tree" \
  --config-sha256 "$config_sha" \
  --run-id "$run_id" \
  --host-label "$host_label" \
  "$@"
