#!/usr/bin/env bash
# Capture the WP-D2 state corpus for one or both math backends:
#   tmp/core-math/state-system_libm/{rng,checkpoints,levels}/
#   tmp/core-math/state-core_math/{rng,checkpoints,levels}/
#
# Each backend gets one LÖVE harness run (`--m2-capture`: RNG sequences,
# peg-color init, ready-to-aim checkpoints) against the dev tree
# ../peggle_evolved, plus one `tools/export_level.lua` run per static level.
# The backend is selected with PEGGLE_MATH_BACKEND/PEGGLE_MATH_LIB; both the
# harness and the level exporter read those variables.
#
# Usage:
#   scripts/capture_wpd_state.sh
#
# The provenance (revision/tree/config hash) is discovered exactly like
# scripts/capture_m2.sh. Outputs under tmp/ are overwritten on every run.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ref_dir="$repo_root/reference/peggle_evolved"
pin="$repo_root/reference/PIN.md"
native_lib="$repo_root/native/artifacts/linux-x86_64/libpeggle_math.so"

revision="$(sed -n 's/.*Revision (full) | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
tree="$(sed -n 's/.*Tree hash | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
if [[ -z "$revision" || -z "$tree" ]]; then
  echo "ERROR: cannot read revision/tree from $pin" >&2
  exit 1
fi
config_sha="$(sha256sum "$ref_dir/src/config.lua" | awk '{print $1}')"

if [[ ! -f "$native_lib" ]]; then
  echo "ERROR: missing native math artifact: $native_lib" >&2
  exit 1
fi
if [[ ! -d "$repo_root/../peggle_evolved/src" ]]; then
  echo "ERROR: missing dev tree: $repo_root/../peggle_evolved" >&2
  exit 1
fi

levels=()
while IFS= read -r file; do
  levels+=("$(basename "$file" .v1.json)")
done < <(ls "$repo_root"/interchange/levels/*.v1.json | LC_ALL=C sort)
if [[ ${#levels[@]} -eq 0 ]]; then
  echo "ERROR: no static level artifacts under interchange/levels" >&2
  exit 1
fi
levels_csv="$(IFS=,; echo "${levels[*]}")"

# Engagement preflight: the dev-tree construction path must actually load
# detmath under the selected backend. A missing artifact and an unknown
# backend must both fail hard (no fallback), through the same modules the
# harness and the level exporter use.
preflight_dir="$repo_root/tmp/core-math/preflight"
mkdir -p "$preflight_dir"
if PEGGLE_MATH_BACKEND=core_math PEGGLE_MATH_LIB="$preflight_dir/missing.so" \
    luajit tools/export_level.lua --reference ../peggle_evolved \
    --level "${levels[0]}" > "$preflight_dir/missing.log" 2>&1; then
  echo "ERROR: preflight: missing core_math artifact did not fail" >&2
  exit 1
fi
grep -q "cannot load core_math" "$preflight_dir/missing.log" || {
  echo "ERROR: preflight: missing-artifact failure was not the expected one" >&2
  cat "$preflight_dir/missing.log" >&2
  exit 1
}
if PEGGLE_MATH_BACKEND=bogus \
    luajit tools/export_level.lua --reference ../peggle_evolved \
    --level "${levels[0]}" > "$preflight_dir/unknown.log" 2>&1; then
  echo "ERROR: preflight: unknown backend did not fail" >&2
  exit 1
fi
grep -q "unknown PEGGLE_MATH_BACKEND" "$preflight_dir/unknown.log" || {
  echo "ERROR: preflight: unknown-backend failure was not the expected one" >&2
  cat "$preflight_dir/unknown.log" >&2
  exit 1
}
echo "capture_wpd_state: preflight OK (missing artifact and unknown backend fail hard)"

for backend in system_libm core_math; do
  state_dir="$repo_root/tmp/core-math/state-$backend"
  mkdir -p "$state_dir/rng" "$state_dir/checkpoints" "$state_dir/levels"

  export PEGGLE_MATH_BACKEND="$backend"
  export PEGGLE_MATH_LIB="$native_lib"

  echo "capture_wpd_state: backend=$backend harness --m2-capture"
  "$repo_root/scripts/love.sh" love "$repo_root/harness" -- \
    --reference-dir ../peggle_evolved \
    --m2-capture \
    --levels "$levels_csv" \
    --rng-out "$state_dir/rng" \
    --checkpoints-out "$state_dir/checkpoints" \
    --reference-revision "$revision" \
    --reference-tree "$tree" \
    --config-sha256 "$config_sha"

  for name in "${levels[@]}"; do
    echo "capture_wpd_state: backend=$backend export $name"
    luajit tools/export_level.lua \
      --reference ../peggle_evolved \
      --level "$name" \
      --out "$state_dir/levels/$name.v1.json" \
      --revision "$revision" \
      --tree "$tree" \
      --config-sha256 "$config_sha"
  done

  luajit tools/wpd_backend_probe.lua \
    --detmath-root "$repo_root/../peggle_evolved" \
    --out "$state_dir/backend-identity.json"

  echo "capture_wpd_state: backend=$backend -> $state_dir"
done

echo "capture_wpd_state: done"
