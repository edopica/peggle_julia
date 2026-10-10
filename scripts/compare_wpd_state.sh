#!/usr/bin/env bash
# Compare the WP-D2 state captures against independent Julia recomputation:
#   tmp/core-math/state-compare-system_libm.json
#   tmp/core-math/state-compare-core_math.json
#   tmp/core-math/state-summary.json
#
# Usage:
#   scripts/compare_wpd_state.sh
#
# Runs julia/PeggleSim/bin/wpd_state_compare.jl for both backends and then
# julia/PeggleSim/bin/wpd_state_summary.jl. Exits nonzero when the
# system_libm control differs from the historical corpus or when either
# comparator fails; core_math level/checkpoint differences are reported by the
# comparator with first-difference paths.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

state_root="$repo_root/tmp/core-math"
mkdir -p "$state_root"

overall=0

for backend in system_libm core_math; do
  state_dir="$state_root/state-$backend"
  compare_out="$state_root/state-compare-$backend.json"
  if julia --project=julia/PeggleSim julia/PeggleSim/bin/wpd_state_compare.jl \
      --repo . \
      --state-dir "tmp/core-math/state-$backend" \
      --backend "$backend" \
      --out "tmp/core-math/state-compare-$backend.json"; then
    echo "compare_wpd_state: comparator PASS: $backend"
  else
    echo "compare_wpd_state: comparator FAIL: $backend" >&2
    overall=1
  fi
  if [[ ! -f "$compare_out" ]]; then
    echo "ERROR: comparator did not write $compare_out" >&2
  fi
done

if julia --project=julia/PeggleSim julia/PeggleSim/bin/wpd_state_summary.jl \
    --repo . \
    --state-root "$state_root" \
    --out "$state_root/state-summary.json"; then
  echo "compare_wpd_state: summary PASS"
else
  echo "compare_wpd_state: summary FAIL" >&2
  overall=1
fi

if [[ $overall -ne 0 ]]; then
  echo "compare_wpd_state: FAILED" >&2
  exit 1
fi
echo "compare_wpd_state: OK"
