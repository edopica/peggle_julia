#!/usr/bin/env bash
# Capture (or verify) the M3 mustache reference corpus.
#
# The corpus is captured from the peggle_evolved dev tree, not from the pinned
# M1 reference: src/levels/mustache.lua is untracked there and the dev config
# differs from the pin by ball_ball_restitution = 0.7. Outputs:
#
#   fixtures/mustache/artifact/mustache.v1.json   level artifact (real provenance)
#   fixtures/mustache/config.dev.v1.json          dev config artifact
#   fixtures/mustache/expected/*.json             fixture records
#   fixtures/mustache/traces/*.jsonl              snapshot-free gameplay traces
#
# The corpus is deliberately outside the M1 fixture corpus; `make check-all`
# never re-captures it. See wiki/context/m3-mustache.md.
#
# Usage (from anywhere; paths resolve relative to this script):
#   scripts/capture_m3_mustache.sh          # re-export and capture the corpus
#   scripts/capture_m3_mustache.sh --check  # verify only; never writes the corpus
#
# Check mode re-exports the artifacts to a temporary directory, requires them
# to be byte-identical to the committed ones, and runs the harness fixture mode
# with --check (records and traces are re-captured in memory/temp files).
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

ref_dir="$repo_root/../peggle_evolved"
level_source="$ref_dir/src/levels/mustache.lua"
config_source="$ref_dir/src/config.lua"

if [[ ! -d "$ref_dir" ]]; then
  echo "ERROR: dev tree not found at $ref_dir" >&2
  exit 1
fi
if [[ ! -f "$level_source" ]]; then
  echo "ERROR: mustache level source not found at $level_source" >&2
  exit 1
fi
if [[ ! -f "$config_source" ]]; then
  echo "ERROR: dev config not found at $config_source" >&2
  exit 1
fi

if ! revision="$(git -C "$ref_dir" rev-parse HEAD 2>/dev/null)"; then
  echo "ERROR: cannot read HEAD from $ref_dir (not a git checkout?)" >&2
  exit 1
fi
if ! tree="$(git -C "$ref_dir" rev-parse 'HEAD^{tree}' 2>/dev/null)"; then
  echo "ERROR: cannot read tree hash from $ref_dir" >&2
  exit 1
fi
config_sha="$(sha256sum "$config_source" | awk '{print $1}')"

echo "capture_m3_mustache: dev tree $ref_dir"
echo "  revision   = $revision"
echo "  tree       = $tree"
echo "  config_sha = $config_sha"

artifact="$repo_root/fixtures/mustache/artifact/mustache.v1.json"
config_artifact="$repo_root/fixtures/mustache/config.dev.v1.json"

tmpdir=""
if [[ $check -eq 1 ]]; then
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/capture_m3_mustache.XXXXXX")"
  trap 'rm -rf "$tmpdir"' EXIT
  artifact_out="$tmpdir/mustache.v1.json"
  config_out="$tmpdir/config.dev.v1.json"
else
  mkdir -p "$repo_root/fixtures/mustache/artifact"
  artifact_out="$artifact"
  config_out="$config_artifact"
fi

luajit "$repo_root/tools/export_level.lua" \
  --reference "$ref_dir" \
  --level mustache \
  --out "$artifact_out" \
  --check \
  --revision "$revision" \
  --tree "$tree" \
  --config-sha256 "$config_sha"

luajit "$repo_root/tools/export_config.lua" \
  --reference "$ref_dir" \
  --out "$config_out" \
  --check \
  --source-sha256 "$config_sha"

if [[ $check -eq 1 ]]; then
  if ! cmp -s "$artifact_out" "$artifact"; then
    echo "ERROR: re-exported level artifact differs from $artifact" >&2
    exit 1
  fi
  if ! cmp -s "$config_out" "$config_artifact"; then
    echo "ERROR: re-exported config artifact differs from $config_artifact" >&2
    exit 1
  fi
  echo "artifacts: re-exports match the committed bytes"
fi

args=(
  --fixtures
  --catalog "$repo_root/fixtures/mustache/catalog.lua"
  --fixtures-out "$repo_root/fixtures/mustache/expected"
  --fixtures-traces "$repo_root/fixtures/mustache/traces"
  --reference-dir "$ref_dir"
  --artifact-dir "$repo_root/fixtures/mustache/artifact"
  --reference-revision "$revision"
  --reference-tree "$tree"
  --config-sha256 "$config_sha"
)
if [[ $check -eq 1 ]]; then
  args+=(--check)
fi

"$repo_root/scripts/love.sh" love "$repo_root/harness" -- "${args[@]}"
