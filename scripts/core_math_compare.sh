#!/usr/bin/env bash
# WP-D1: CORE-MATH math comparison end to end.
#
# Usage:
#   scripts/core_math_compare.sh
#
# Writes under tmp/core-math/:
#   wpd-inputs.json                 Julia corpus + MPFR oracle
#   wpd-lua-system_libm.json        Lua results, historical backend
#   wpd-lua-core_math.json          Lua results, CORE-MATH backend
#   wpd-compare-system_libm.json    Julia vs Lua vs oracle, historical backend
#   wpd-compare-core_math.json      Julia vs Lua vs oracle, CORE-MATH backend
#   math-summary.json               cross-backend summary
#
# Requires luajit, julia, the peggle_evolved development tree, and the built
# native artifact. Exits nonzero on generator, census, comparator, or summary
# failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

dev_tree="$repo_root/../peggle_evolved"
artifact="$repo_root/native/artifacts/linux-x86_64/libpeggle_math.so"
dev_artifact="$dev_tree/native/linux-x86_64/libpeggle_math.so"
out_dir="$repo_root/tmp/core-math"

for tool in luajit julia; do
  command -v "$tool" > /dev/null 2>&1 || {
    echo "ERROR: $tool is required" >&2
    exit 1
  }
done

if [[ ! -d "$dev_tree" ]]; then
  echo "ERROR: peggle_evolved development tree not found at $dev_tree" >&2
  exit 1
fi
if [[ ! -f "$dev_artifact" ]]; then
  echo "ERROR: $dev_artifact is missing; run 'make math-native' in peggle_evolved" >&2
  exit 1
fi
if [[ ! -r "$artifact" ]]; then
  echo "ERROR: $artifact is missing or unreadable; run 'make core-math-build'" >&2
  exit 1
fi

mkdir -p "$out_dir"

echo "core_math_compare: repo=$repo_root"
echo "  dev_tree=$dev_tree"
echo "  artifact=$artifact ($(sha256sum "$artifact" | awk '{print $1}'))"

echo "[1/4] generating inputs and oracle"
julia --project=julia/PeggleSim julia/PeggleSim/bin/wpd_census_inputs.jl \
  --fixture fixtures/math_census/math_census.v1.json \
  --out "$out_dir/wpd-inputs.json"

for backend in system_libm core_math; do
  echo "[2/4] Lua census: $backend"
  PEGGLE_MATH_BACKEND="$backend" PEGGLE_MATH_LIB="$artifact" \
    luajit tools/wpd_census.lua \
    --detmath-root "$dev_tree" \
    --inputs "$out_dir/wpd-inputs.json" \
    --out "$out_dir/wpd-lua-$backend.json"

  echo "[3/4] Julia comparison: $backend"
  PEGGLE_MATH_BACKEND="$backend" PEGGLE_MATH_LIB="$artifact" \
    julia --project=julia/PeggleSim julia/PeggleSim/bin/wpd_compare.jl \
    --inputs "$out_dir/wpd-inputs.json" \
    --lua "$out_dir/wpd-lua-$backend.json" \
    --out "$out_dir/wpd-compare-$backend.json" \
    --expect-backend "$backend"
done

echo "[4/4] cross-backend summary"
julia --project=julia/PeggleSim julia/PeggleSim/bin/wpd_summary.jl \
  --dir "$out_dir" \
  --out "$out_dir/math-summary.json"

echo "core_math_compare: OK"
