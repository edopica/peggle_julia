#!/usr/bin/env bash
# Capture (or verify) the imported-levels fixture corpus (b1, b2, g1, m1, m2).
#
# The levels are screenshot reconstructions that live only in the
# peggle_evolved dev tree (generated there by ../level_segment/levels/*), so
# the corpus is captured from the dev tree, not from the pinned M1 reference.
# Four of the five boards use the dev-tree `ribbon` gameplay peg
# (src/entities/ribbon.lua); b2 is an annular/rectangle control. Outputs:
#
#   fixtures/imported_levels/artifact/<level>.v1.json   level artifacts
#   fixtures/imported_levels/config.dev.v1.json         dev config artifact
#   fixtures/imported_levels/expected/*.json            fixture records
#   fixtures/imported_levels/traces/*.jsonl             snapshot-free traces
#
# The corpus is outside the M1 fixture corpus; `make check-all` never
# re-captures it.
#
# Usage (from anywhere; paths resolve relative to this script):
#   scripts/capture_imported_levels.sh          # export and capture
#   scripts/capture_imported_levels.sh --check  # verify only; never writes
#
# Check mode re-exports the artifacts into a temporary directory, requires
# them to be byte-identical to the committed ones, and runs the harness
# fixture mode with --check.
#
# Requires LuaJIT and LÖVE (scripts/love.sh handles headless displays).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

check=0
for arg in "$@"; do
  case "$arg" in
    --check) check=1 ;;
    *)
      echo "ERROR: unknown argument: $arg (only --check is supported)" >&2
      exit 2
      ;;
  esac
done

levels=(b1 b2 g1 m1 m2)
ref_dir="$repo_root/../peggle_evolved"
config_source="$ref_dir/src/config.lua"
fixture_dir="$repo_root/fixtures/imported_levels"

if [[ ! -d "$ref_dir" ]]; then
  echo "ERROR: dev tree not found at $ref_dir" >&2
  exit 1
fi
for level in "${levels[@]}"; do
  if [[ ! -f "$ref_dir/src/levels/$level.lua" ]]; then
    echo "ERROR: level source not found at $ref_dir/src/levels/$level.lua" >&2
    exit 1
  fi
done

revision="$(git -C "$ref_dir" rev-parse HEAD)"
tree="$(git -C "$ref_dir" rev-parse 'HEAD^{tree}')"
config_sha="$(sha256sum "$config_source" | awk '{print $1}')"

echo "capture_imported_levels: dev tree $ref_dir"
echo "  revision   = $revision"
echo "  tree       = $tree"
echo "  config_sha = $config_sha"

artifact_dir="$fixture_dir/artifact"
config_artifact="$fixture_dir/config.dev.v1.json"

if [[ $check -eq 1 ]]; then
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/capture_imported_levels.XXXXXX")"
  trap 'rm -rf "$tmpdir"' EXIT
  artifact_out_dir="$tmpdir/artifact"
  config_out="$tmpdir/config.dev.v1.json"
  mkdir -p "$artifact_out_dir"
else
  mkdir -p "$artifact_dir" "$fixture_dir/expected" "$fixture_dir/traces"
  artifact_out_dir="$artifact_dir"
  config_out="$config_artifact"
fi

for level in "${levels[@]}"; do
  luajit "$repo_root/tools/export_level.lua" \
    --reference "$ref_dir" \
    --level "$level" \
    --out "$artifact_out_dir/$level.v1.json" \
    --check \
    --revision "$revision" \
    --tree "$tree" \
    --config-sha256 "$config_sha"
done

luajit "$repo_root/tools/export_config.lua" \
  --reference "$ref_dir" \
  --out "$config_out" \
  --check \
  --source-sha256 "$config_sha"

python3 "$repo_root/scripts/validate_interchange.py" \
  "$artifact_out_dir"/*.v1.json "$config_out"

if [[ $check -eq 1 ]]; then
  for level in "${levels[@]}"; do
    if ! cmp -s "$artifact_out_dir/$level.v1.json" "$artifact_dir/$level.v1.json"; then
      echo "ERROR: re-exported $level artifact differs from $artifact_dir/$level.v1.json" >&2
      exit 1
    fi
  done
  if ! cmp -s "$config_out" "$config_artifact"; then
    echo "ERROR: re-exported config artifact differs from $config_artifact" >&2
    exit 1
  fi
  echo "artifacts: re-exports match the committed bytes"
fi

args=(
  --fixtures
  --catalog "$fixture_dir/catalog.lua"
  --fixtures-out "$fixture_dir/expected"
  --fixtures-traces "$fixture_dir/traces"
  --reference-dir "$ref_dir"
  --artifact-dir "$artifact_dir"
  --reference-revision "$revision"
  --reference-tree "$tree"
  --config-sha256 "$config_sha"
)
if [[ $check -eq 1 ]]; then
  args+=(--check)
fi

"$repo_root/scripts/love.sh" love "$repo_root/harness" -- "${args[@]}"
