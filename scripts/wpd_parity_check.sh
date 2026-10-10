#!/usr/bin/env bash
# Local contract check for the WP-D experimental CORE-MATH-era parity path.
#
# Requires the experimental census produced by
# scripts/capture_wpd_parity_census.sh
# (`tmp/core-math/parity/math_census.v1.json`).
#
# Checks:
#   1. two independent Julia processes emit manifests from the same
#      experimental census; scripts/compare_parity.sh must print
#      "PARITY OK" (exit 0);
#   2. one experimental manifest compared with the historical
#      results/parity/local.json (system_libm) must be rejected as
#      incompatible (exit 3). A missing historical manifest is recorded as a
#      documented skip, not a failure.
#
# This proves same-host reproducibility of the experimental inputs; it is not
# cross-machine evidence by itself.
#
# Usage:
#   scripts/wpd_parity_check.sh
#
# Environment overrides:
#   PEGGLE_MATH_LIB  native artifact for the Julia core_math backend
#   JULIA            Julia command (default "julia")
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

julia_cmd="${JULIA:-julia}"
census="$repo_root/tmp/core-math/parity/math_census.v1.json"
out_dir="$repo_root/tmp/core-math/parity"
historical="$repo_root/results/parity/local.json"
native_lib="$repo_root/native/artifacts/linux-x86_64/libpeggle_math.so"

if [[ ! -f "$census" ]]; then
  echo "wpd_parity_check: ERROR: missing experimental census: $census" >&2
  echo "  run scripts/capture_wpd_parity_census.sh (or make wpd-parity) first" >&2
  exit 1
fi
mkdir -p "$out_dir"

export PEGGLE_MATH_BACKEND=core_math
if [[ -z "${PEGGLE_MATH_LIB:-}" && -f "$native_lib" ]]; then
  export PEGGLE_MATH_LIB="$native_lib"
fi

emit() {
  local label="$1"
  local out="$2"
  "$julia_cmd" --project=julia/PeggleSim julia/PeggleSim/bin/parity_emit.jl \
    --repo "$repo_root" \
    --census "$census" \
    --label "$label" \
    --out "$out"
}

echo "wpd_parity_check: emitting two independent core_math manifests"
emit core_math-a "$out_dir/core_math-a.json"
emit core_math-b "$out_dir/core_math-b.json"

echo "wpd_parity_check: compare_parity.sh core_math-a.json core_math-b.json"
set +e
scripts/compare_parity.sh "$out_dir/core_math-a.json" "$out_dir/core_math-b.json" \
  | tee "$out_dir/compare-core_math-a-b.log"
code_ab="${PIPESTATUS[0]}"
set -e
if [[ $code_ab -ne 0 ]]; then
  echo "wpd_parity_check: FAIL: two same-input core_math manifests are not parity (exit $code_ab)" >&2
  exit 1
fi

if [[ ! -f "$historical" ]]; then
  echo "wpd_parity_check: SKIP: historical manifest absent: $historical"
  echo "wpd_parity_check: OK (core_math self-parity; historical comparison skipped)"
  exit 0
fi

echo "wpd_parity_check: compare_parity.sh core_math-a.json results/parity/local.json"
set +e
scripts/compare_parity.sh "$out_dir/core_math-a.json" "$historical" \
  | tee "$out_dir/compare-core_math-vs-historical.log"
code_hist="${PIPESTATUS[0]}"
set -e
if [[ $code_hist -ne 3 ]]; then
  echo "wpd_parity_check: FAIL: core_math vs historical expected exit 3 (incompatible), got $code_hist" >&2
  exit 1
fi

echo "wpd_parity_check: OK (core_math self-parity exit 0; vs historical exit 3 as expected)"
