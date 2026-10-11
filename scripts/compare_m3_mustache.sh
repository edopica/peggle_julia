#!/usr/bin/env bash
# Catalog-driven M3 mustache trace comparison.
#
# For every traced shot fixture in fixtures/mustache/catalog.lua:
#   1. capture a snapshot-enabled Lua trace into tmp/m3/lua-snapshots/ via the
#      harness (fixture mode, dev tree, mustache artifact dir);
#   2. regenerate the snapshot-enabled Julia trace into results/m3/;
#   3. compare both corpora with tools/compare_traces.py --control, including
#      the full per-step simulation state.
#
# The comparator's left expected records are the durable snapshot-free corpus
# at fixtures/mustache/expected (the harness writes its snapshot-enabled
# records to tmp/m3/lua-snapshots/expected, which the trace hash in an
# expected record does not describe); the left traces are the snapshot-enabled
# tmp copies.
#
# Outputs:
#   tmp/m3/lua-snapshots/{expected,traces}/   Lua snapshot-enabled capture
#   results/m3/traces/*.jsonl                 Julia snapshot-enabled traces
#   results/m3/expected/*.json                Julia fixture expected records
#   results/m3/mustache-compare.json          comparison report
#
# Usage (from anywhere; paths resolve relative to this script):
#   scripts/compare_m3_mustache.sh               # capture + control compare
#   scripts/compare_m3_mustache.sh --julia-only  # regenerate Julia traces only
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

julia_only=0
for arg in "$@"; do
  case "$arg" in
    --julia-only) julia_only=1 ;;
    *)
      echo "ERROR: unknown argument: $arg (only --julia-only is supported)" >&2
      exit 2
      ;;
  esac
done

julia_bin="${JULIA:-julia}"
project="$repo_root/julia/PeggleSim"
shot_bench="$repo_root/julia/PeggleSim/bin/shot_bench.jl"
ref_dir="$repo_root/../peggle_evolved"
level="$repo_root/fixtures/mustache/artifact/mustache.v1.json"
config="$repo_root/fixtures/mustache/config.dev.v1.json"
catalog="$repo_root/fixtures/mustache/catalog.lua"
durable_expected="$repo_root/fixtures/mustache/expected"
snapshot_root="$repo_root/tmp/m3/lua-snapshots"
lua_expected="$snapshot_root/expected"
lua_traces="$snapshot_root/traces"
traces_dir="$repo_root/results/m3/traces"
expected_dir="$repo_root/results/m3/expected"
compare_out="$repo_root/results/m3/mustache-compare.json"

if [[ ! -f "$catalog" ]]; then
  echo "ERROR: missing catalog $catalog" >&2
  exit 1
fi
if [[ ! -d "$ref_dir" ]]; then
  echo "ERROR: dev tree not found at $ref_dir" >&2
  exit 1
fi

# id|category|aim_index for every traced shot fixture, in catalog order.
catalog_tsv="$(luajit - "$catalog" <<'LUA'
local path = arg[1]
local chunk, err = loadfile(path)
if not chunk then
  io.stderr:write("cannot load catalog " .. path .. ": " .. tostring(err) .. "\n")
  os.exit(1)
end
local catalog = chunk()
if type(catalog) ~= "table" or type(catalog.fixtures) ~= "table" then
  io.stderr:write("catalog is not a fixture table\n")
  os.exit(1)
end
for _, fx in ipairs(catalog.fixtures) do
  if fx.kind == "shot" and fx.trace then
    print(string.format("%s|%s|%d", fx.id, fx.category, fx.aim_index))
  end
end
LUA
)"

if [[ -z "$catalog_tsv" ]]; then
  echo "ERROR: catalog has no traced shot fixtures" >&2
  exit 1
fi

fixture_count="$(printf '%s\n' "$catalog_tsv" | grep -c .)"
echo "compare_m3_mustache: $fixture_count traced fixture(s) in catalog"

if [[ $julia_only -eq 0 ]]; then
  if ! revision="$(git -C "$ref_dir" rev-parse HEAD 2>/dev/null)"; then
    echo "ERROR: cannot read HEAD from $ref_dir" >&2
    exit 1
  fi
  if ! tree="$(git -C "$ref_dir" rev-parse 'HEAD^{tree}' 2>/dev/null)"; then
    echo "ERROR: cannot read tree hash from $ref_dir" >&2
    exit 1
  fi
  config_sha="$(sha256sum "$ref_dir/src/config.lua" | awk '{print $1}')"

  rm -rf "$snapshot_root"
  mkdir -p "$lua_expected" "$lua_traces"
  echo "compare_m3_mustache: capturing snapshot-enabled Lua traces (dev tree $revision)"
  "$repo_root/scripts/love.sh" love "$repo_root/harness" -- \
    --fixtures \
    --fixtures-snapshots \
    --catalog "$catalog" \
    --fixtures-out "$lua_expected" \
    --fixtures-traces "$lua_traces" \
    --reference-dir "$ref_dir" \
    --artifact-dir "$repo_root/fixtures/mustache/artifact" \
    --reference-revision "$revision" \
    --reference-tree "$tree" \
    --config-sha256 "$config_sha"
fi

mkdir -p "$traces_dir" "$expected_dir"
while IFS='|' read -r id category aim; do
  [[ -n "$id" ]] || continue
  echo "compare_m3_mustache: trace $id (aim_index $aim, category $category)"
  "$julia_bin" --project="$project" "$shot_bench" \
    --fixture "$id" \
    --level "$level" \
    --config "$config" \
    --aim "$aim" \
    --category "$category" \
    --snapshots \
    --trace-out "$traces_dir/$id.jsonl" \
    --expected-out "$expected_dir/$id.json"
done <<< "$catalog_tsv"

if [[ $julia_only -eq 1 ]]; then
  echo "compare_m3_mustache: --julia-only; comparison skipped"
  exit 0
fi

status=0
python3 "$repo_root/tools/compare_traces.py" --control \
  --left-traces "$lua_traces" \
  --left-expected "$durable_expected" \
  --right-traces "$traces_dir" \
  --right-expected "$expected_dir" \
  --out "$compare_out" \
  --left-label lua \
  --right-label julia || status=$?

python3 - "$compare_out" "$status" <<'PY'
import json
import sys

path = sys.argv[1]
status = int(sys.argv[2])
try:
    with open(path, encoding="utf-8") as handle:
        report = json.load(handle)
except OSError as exc:
    print("compare_m3_mustache: cannot read report %s: %s" % (path, exc),
          file=sys.stderr)
    sys.exit(status or 2)

control = report.get("control") or {}
categories = {}
for entry in (report.get("fixtures") or {}).values():
    for category, count in (entry.get("classifications") or {}).items():
        categories[category] = categories.get(category, 0) + count
summary = ", ".join("%s=%d" % (key, categories[key]) for key in sorted(categories))
if not summary:
    summary = "none"
print("compare_m3_mustache: mode=%s fixtures=%s identical=%s "
      "expected_records_identical=%s differences=[%s] failures=%d" % (
          report.get("mode"),
          control.get("fixtures_compared"),
          control.get("identical_fixtures"),
          control.get("expected_records_identical"),
          summary,
          len(control.get("failures") or [])))
for failure in control.get("failures") or []:
    print("compare_m3_mustache: control failure: %s: %s" % (
        failure.get("fixture"), failure.get("reason")), file=sys.stderr)
sys.exit(status)
PY
