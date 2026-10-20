#!/usr/bin/env bash
# M4 correctness-breadth parity orchestration.
#
# Runs the M4 parity groups and writes one combined, deterministic report:
#
#   1. Julia fixture replay + trace parity (replay_fixtures.jl), covering every
#      shot fixture in fixtures/expected and every corpus trace.
#   2. Full-grid candidate sweeps for the M4 workloads from harness/workloads.lua,
#      Lua harness vs Julia shot_bench (thread 1), compared with the existing
#      scripts/compare_m3_sweeps.py comparator (never forked here).
#   3. Thread identity for the two dense workloads (lines_rect_annular,
#      annular_dense): t2/t4 runs plus the t1 reference, requiring
#      serial_parallel_identical and byte-identical candidate rows.
#   4. Scenario disposition probe (scenario_probe.jl), which writes
#      results/m4/scenario-parity.json.
#   5. <out-dir>/parity-summary.json: canonical JSON (sorted keys, one trailing
#      newline), no timestamps or host metadata.
#
# Outputs (lua summaries, Julia summaries and the compare reports are ordinary
# run artifacts; raw candidate rows are gitignored):
#
#   <out-dir>/fixture-parity.json          fixture replay report
#   <out-dir>/trace-parity.json            trace parity report (durable evidence)
#   <out-dir>/traces/<id>.jsonl            regenerated traces (transient; gitignored)
#   <out-dir>/lua-<id>.summary.json        Lua sweep summary
#   <raw-dir>/m4-lua-<id>.candidates.jsonl Lua raw candidate rows
#   <out-dir>/julia-<id>-t<N>.json         Julia sweep summaries
#   <raw-dir>/m4-julia-<id>-t<N>.jsonl     Julia raw candidate rows
#   <out-dir>/sweeps-compare-<id>.json     comparator reports
#   <out-dir>/parity-summary.json          combined report
#   results/m4/scenario-parity.json        scenario probe report (fixed path)
#
# Usage (from anywhere; paths resolve relative to this script):
#   scripts/m4_parity.sh [--stride N] [--out-dir DIR] [--raw-dir DIR]
#                        [--workloads LIST|all] [--threads "1 2 4"]
#                        [--skip-lua] [--skip-julia] [--skip-traces]
#                        [--skip-scenarios]
#
# --workloads takes comma-separated ids from harness/workloads.lua; "all"
# selects the seven M4 workloads. --threads is the thread-identity list; thread
# 1 is always run as the sweep reference. --skip-lua/--skip-julia skip that
# whole side, which also skips the comparator for every workload (the sweep
# group is marked skipped, never failed). --skip-traces disables trace
# regeneration; --skip-scenarios skips the scenario disposition probe.
#
# Exit status: 0 iff every requested group passes; 1 on any parity failure or
# missing report; 2 on bad usage or missing inputs.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
  cat <<'EOF'
M4 correctness-breadth parity orchestration.

Usage: scripts/m4_parity.sh [options]

Options:
  --stride N            aim-index stride (default: 1)
  --out-dir DIR         report directory (default: results/m4)
  --raw-dir DIR         raw candidate JSONL directory (default: results/raw)
  --workloads LIST|all  comma-separated workload ids (default: all)
  --threads LIST        thread-identity counts (default: "1 2 4")
  --skip-lua            skip the Lua sweeps (comparator skipped, not failed)
  --skip-julia          skip every Julia step
  --skip-traces         do not regenerate corpus traces
  --skip-scenarios      skip the scenario disposition probe
  -h, --help            show this help and exit

Groups: fixtures, traces, sweeps (with thread identity), scenarios.
The combined report is written to <out-dir>/parity-summary.json.
The Lua sweeps run the frozen pinned tree (reference/peggle_evolved), not the
../peggle_evolved dev tree, so both sides share the pinned config/level basis.
EOF
}

stride=1
out_dir="results/m4"
raw_dir="results/raw"
workloads_arg="all"
threads_arg="1 2 4"
skip_lua=0
skip_julia=0
skip_traces=0
skip_scenarios=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stride) stride="${2:?--stride requires a value}"; shift 2 ;;
    --out-dir) out_dir="${2:?--out-dir requires a value}"; shift 2 ;;
    --raw-dir) raw_dir="${2:?--raw-dir requires a value}"; shift 2 ;;
    --workloads) workloads_arg="${2:?--workloads requires a value}"; shift 2 ;;
    --threads) threads_arg="${2:?--threads requires a value}"; shift 2 ;;
    --skip-lua) skip_lua=1; shift ;;
    --skip-julia) skip_julia=1; shift ;;
    --skip-traces) skip_traces=1; shift ;;
    --skip-scenarios) skip_scenarios=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! [[ "$stride" =~ ^[0-9]+$ ]] || (( stride < 1 )); then
  echo "ERROR: --stride must be a positive integer" >&2
  exit 2
fi
if [[ -z "$out_dir" || -z "$raw_dir" ]]; then
  echo "ERROR: --out-dir and --raw-dir must not be empty" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# M4 workload map. Must match harness/workloads.lua; the catalog is verified
# below when luajit is available so drift is a hard error, not a silent skew.
# ---------------------------------------------------------------------------
workloads_catalog="$repo_root/harness/workloads.lua"
config="$repo_root/interchange/config.v1.json"
levels_dir="$repo_root/interchange/levels"
# The Lua sweeps must run against the frozen pinned tree, not the
# ../peggle_evolved dev tree: those levels and the pinned config are what the
# interchange artifacts (interchange/config.v1.json, loaded by the Julia side)
# describe. The dev tree currently differs (src/levels/circle_level.lua is
# deleted and ball_ball_restitution is 0.7 vs the pinned 0.8), so running the
# multi3 workloads there would compare unlike inputs. The five levels present in
# both trees are byte-identical, and scripts/verify_reference.sh passes 133/133.
ref_dir="$repo_root/reference/peggle_evolved"
project="$repo_root/julia/PeggleSim"
shot_bench="$repo_root/julia/PeggleSim/bin/shot_bench.jl"
replay_fixtures="$repo_root/julia/PeggleSim/bin/replay_fixtures.jl"
scenario_probe="$repo_root/julia/PeggleSim/bin/scenario_probe.jl"
comparator="$repo_root/scripts/compare_m3_sweeps.py"
scenario_report="$repo_root/results/m4/scenario-parity.json"
julia_bin="${JULIA:-julia}"
host_label="$(hostname -s 2>/dev/null || echo unknown)"

m4_ids=(
  overhead_static_2p
  circles_small
  circles_mixed
  lines_rect_annular
  annular_dense
  annular_dense_multi3
  lines_rect_annular_multi3
)
m4_levels=(
  long_shot
  circle_level
  off_the_wall
  slide
  squiggly_circle
  squiggly_circle
  slide
)
m4_balls=(
  1
  1
  1
  1
  1
  3
  3
)

list_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Parse and validate the requested workloads and thread counts.
# ---------------------------------------------------------------------------
workload_ids=()
workload_levels=()
workload_balls=()
workload_rows=()
if [[ "$workloads_arg" == "all" ]]; then
  for i in "${!m4_ids[@]}"; do
    workload_ids+=("${m4_ids[$i]}")
    workload_levels+=("${m4_levels[$i]}")
    workload_balls+=("${m4_balls[$i]}")
    workload_rows+=("${m4_ids[$i]}|${m4_levels[$i]}|${m4_balls[$i]}")
  done
else
  IFS=',' read -r -a requested_ids <<< "$workloads_arg"
  cleaned_ids=()
  for raw_id in "${requested_ids[@]}"; do
    id="${raw_id//[[:space:]]/}"
    if [[ -z "$id" ]]; then
      echo "ERROR: --workloads contains an empty workload id" >&2
      exit 2
    fi
    if ! list_contains "$id" "${m4_ids[@]}"; then
      echo "ERROR: unknown workload id '$id' (known: ${m4_ids[*]})" >&2
      exit 2
    fi
    cleaned_ids+=("$id")
  done
  if (( ${#cleaned_ids[@]} == 0 )); then
    echo "ERROR: --workloads selected no workloads" >&2
    exit 2
  fi
  # Emit in catalog order, deduplicated.
  for i in "${!m4_ids[@]}"; do
    if list_contains "${m4_ids[$i]}" "${cleaned_ids[@]}"; then
      workload_ids+=("${m4_ids[$i]}")
      workload_levels+=("${m4_levels[$i]}")
      workload_balls+=("${m4_balls[$i]}")
      workload_rows+=("${m4_ids[$i]}|${m4_levels[$i]}|${m4_balls[$i]}")
    fi
  done
fi

normalized_threads=()
IFS=', ' read -r -a thread_tokens <<< "$threads_arg"
for token in "${thread_tokens[@]}"; do
  [[ -n "$token" ]] || continue
  if ! [[ "$token" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --threads must be positive integers, got '$token'" >&2
    exit 2
  fi
  value=$((token + 0))
  if (( value < 1 )); then
    echo "ERROR: --threads must be >= 1, got '$token'" >&2
    exit 2
  fi
  normalized_threads+=("$value")
done
if (( ${#normalized_threads[@]} == 0 )); then
  echo "ERROR: --threads needs at least one thread count" >&2
  exit 2
fi
threads_sorted="$(printf '%s\n' "${normalized_threads[@]}" | sort -n -u | tr '\n' ' ')"
read -r -a threads_list <<< "$threads_sorted"
identity_threads=()
for value in "${threads_list[@]}"; do
  if (( value != 1 )); then
    identity_threads+=("$value")
  fi
done
identity_ids=()
for candidate in lines_rect_annular annular_dense; do
  if list_contains "$candidate" "${workload_ids[@]}"; then
    identity_ids+=("$candidate")
  fi
done

# ---------------------------------------------------------------------------
# Preflight: fail before any long run on missing inputs or drivers.
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required" >&2
  exit 2
fi
if [[ ! -f "$config" ]]; then
  echo "ERROR: missing config artifact $config" >&2
  exit 2
fi
if [[ ! -f "$comparator" ]]; then
  echo "ERROR: missing sweep comparator $comparator" >&2
  exit 2
fi
for i in "${!workload_ids[@]}"; do
  level_path="$levels_dir/${workload_levels[$i]}.v1.json"
  if [[ ! -f "$level_path" ]]; then
    echo "ERROR: missing level artifact for workload '${workload_ids[$i]}': $level_path" >&2
    exit 2
  fi
done

if (( skip_lua == 0 )); then
  if [[ ! -f "$workloads_catalog" ]]; then
    echo "ERROR: missing workload catalog $workloads_catalog" >&2
    exit 2
  fi
  if [[ ! -f "$repo_root/scripts/love.sh" ]]; then
    echo "ERROR: missing harness wrapper scripts/love.sh" >&2
    exit 2
  fi
  if [[ ! -d "$repo_root/harness" ]]; then
    echo "ERROR: missing harness directory $repo_root/harness" >&2
    exit 2
  fi
  if [[ ! -d "$ref_dir" ]]; then
    echo "ERROR: Lua reference tree not found at $ref_dir" >&2
    exit 2
  fi
  if ! command -v love >/dev/null 2>&1; then
    echo "ERROR: LÖVE ('love') is required for the Lua sweeps; pass --skip-lua to omit them" >&2
    exit 2
  fi
fi

if (( skip_julia == 0 )); then
  if ! command -v "$julia_bin" >/dev/null 2>&1; then
    echo "ERROR: Julia ('$julia_bin') is required for the Julia steps; pass --skip-julia to omit them" >&2
    exit 2
  fi
  if [[ ! -f "$shot_bench" ]]; then
    echo "ERROR: missing Julia sweep driver $shot_bench" >&2
    exit 2
  fi
  if [[ ! -f "$replay_fixtures" ]]; then
    echo "ERROR: missing Julia replay driver $replay_fixtures" >&2
    exit 2
  fi
  if (( skip_scenarios == 0 )) && [[ ! -f "$scenario_probe" ]]; then
    echo "ERROR: scenario driver not found: $scenario_probe" >&2
    echo "       pass --skip-scenarios to run without the scenario disposition group" >&2
    exit 2
  fi
fi

# Verify the embedded workload map against harness/workloads.lua when possible.
if command -v luajit >/dev/null 2>&1 && [[ -f "$workloads_catalog" ]]; then
  if ! catalog_tsv="$(luajit - "$workloads_catalog" <<'LUA'
local path = arg[1]
local chunk, err = loadfile(path)
if not chunk then
  io.stderr:write("cannot load workload catalog " .. path .. ": " .. tostring(err) .. "\n")
  os.exit(1)
end
local catalog = chunk()
if type(catalog) ~= "table" then
  io.stderr:write("workload catalog is not a table\n")
  os.exit(1)
end
for _, workload in ipairs(catalog) do
  io.write(string.format("%s|%s|%d\n", workload.id, workload.level, workload.balls or 1))
end
LUA
)"; then
    echo "ERROR: cannot parse workload catalog $workloads_catalog" >&2
    exit 2
  fi
  catalog_rows="$(printf '%s\n' "$catalog_tsv" | awk 'NF { count++ } END { print count + 0 }')"
  if (( catalog_rows != ${#m4_ids[@]} )); then
    echo "ERROR: $workloads_catalog lists $catalog_rows workloads; the M4 map has ${#m4_ids[@]}" >&2
    exit 2
  fi
  for i in "${!m4_ids[@]}"; do
    expected_row="${m4_ids[$i]}|${m4_levels[$i]}|${m4_balls[$i]}"
    if ! grep -Fxq -- "$expected_row" <<< "$catalog_tsv"; then
      echo "ERROR: M4 workload map does not match $workloads_catalog for '${m4_ids[$i]}'" >&2
      echo "       expected row: $expected_row" >&2
      exit 2
    fi
  done
else
  echo "m4_parity: WARNING: luajit unavailable; workload map not verified against harness/workloads.lua" >&2
fi

mkdir -p "$out_dir" "$raw_dir"
rm -f "$out_dir/parity-summary.json"

state_dir="$(mktemp -d "${TMPDIR:-/tmp}/m4_parity.XXXXXX")"
journal="$state_dir/journal.tsv"
: > "$journal"
cleanup() {
  rm -rf "$state_dir"
}
trap cleanup EXIT

workload_rows_joined=""
for row in "${workload_rows[@]}"; do
  workload_rows_joined+="${workload_rows_joined:+;}${row}"
done

echo "m4_parity: stride=$stride workloads=${workload_ids[*]} threads=${threads_list[*]}"
echo "m4_parity: out=$out_dir raw=$raw_dir"
echo "m4_parity: skip_lua=$skip_lua skip_julia=$skip_julia skip_traces=$skip_traces skip_scenarios=$skip_scenarios"

# ---------------------------------------------------------------------------
# 1. Fixture replay + trace parity.
# ---------------------------------------------------------------------------
if (( skip_julia )); then
  echo "m4_parity: --skip-julia; fixture replay skipped"
else
  echo "== fixture replay + trace parity =="
  replay_args=(
    --out "$out_dir/fixture-parity.json"
    --trace-report "$out_dir/trace-parity.json"
    --trace-out-dir "$out_dir/traces"
  )
  if (( skip_traces )); then
    replay_args+=(--skip-traces)
  fi
  rm -f "$out_dir/fixture-parity.json" "$out_dir/trace-parity.json"
  fixtures_exit=0
  "$julia_bin" --project="$project" "$replay_fixtures" "${replay_args[@]}" \
    || fixtures_exit=$?
  printf 'fixtures\t%s\t%s\t%s\n' \
    "$fixtures_exit" "$out_dir/fixture-parity.json" "$out_dir/trace-parity.json" \
    >> "$journal"
  if (( fixtures_exit != 0 )); then
    echo "m4_parity: WARNING: fixture replay exited $fixtures_exit" >&2
  fi
fi

# ---------------------------------------------------------------------------
# 2. Lua-vs-Julia candidate sweeps (Julia t1 is the sweep reference).
# ---------------------------------------------------------------------------
for i in "${!workload_ids[@]}"; do
  id="${workload_ids[$i]}"
  level="${workload_levels[$i]}"
  balls="${workload_balls[$i]}"
  level_path="$levels_dir/$level.v1.json"
  lua_summary_prefix="$out_dir/lua-$id"
  lua_summary="$lua_summary_prefix.summary.json"
  lua_raw="$raw_dir/m4-lua-$id"
  julia_summary="$out_dir/julia-$id-t1.json"
  julia_raw="$raw_dir/m4-julia-$id-t1.jsonl"
  compare_report="$out_dir/sweeps-compare-$id.json"

  lua_status="skipped"
  if (( skip_lua == 0 )); then
    echo "== Lua sweep: $id (level $level, balls $balls, stride $stride) =="
    lua_status=0
    "$repo_root/scripts/love.sh" love "$repo_root/harness" -- \
      --sweep \
      --workload "$id" \
      --stride "$stride" \
      --repeat 1 \
      --no-replay-serialize \
      --out "$lua_raw" \
      --summary-out "$lua_summary_prefix" \
      --reference-dir "$ref_dir" \
      --run-id "m4-lua-$id" \
      --host-label "$host_label" \
      || lua_status=$?
    if (( lua_status != 0 )); then
      echo "m4_parity: WARNING: Lua sweep '$id' exited $lua_status" >&2
    fi
  fi

  julia_status="skipped"
  if (( skip_julia == 0 )); then
    echo "== Julia sweep t1: $id (level $level, balls $balls, stride $stride) =="
    julia_status=0
    "$julia_bin" -t 1 --project="$project" "$shot_bench" \
      --sweep \
      --level "$level_path" \
      --config "$config" \
      --stride "$stride" \
      --balls "$balls" \
      --threads 1 \
      --verify-serial \
      --out "$julia_raw" \
      --summary "$julia_summary" \
      || julia_status=$?
    if (( julia_status != 0 )); then
      echo "m4_parity: WARNING: Julia sweep '$id' exited $julia_status" >&2
    fi
  fi

  compare_status="skipped"
  if (( skip_lua == 0 && skip_julia == 0 )); then
    rm -f "$compare_report"
    if (( lua_status != 0 )); then
      compare_status="lua_failed"
    elif (( julia_status != 0 )); then
      compare_status="julia_failed"
    elif [[ ! -f "$lua_raw.candidates.jsonl" || ! -f "$julia_raw" ]]; then
      compare_status="missing_raw"
    else
      compare_status=0
      echo "== sweep compare: $id =="
      python3 "$comparator" \
        --lua-raw "$lua_raw.candidates.jsonl" \
        --julia "$julia_raw" \
        --stride "$stride" \
        --julia-label t1 \
        --out "$compare_report" \
        || compare_status=$?
      if (( compare_status != 0 )); then
        echo "m4_parity: WARNING: sweep compare '$id' exited $compare_status" >&2
      fi
    fi
  fi

  printf 'sweep\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$lua_status" "$julia_status" "$compare_status" \
    "$lua_summary" "$julia_summary" "$lua_raw.candidates.jsonl" "$julia_raw" \
    "$compare_report" \
    >> "$journal"

  if list_contains "$id" "${identity_ids[@]}"; then
    printf 'thread_t1\t%s\t%s\t%s\t%s\n' \
      "$id" "$julia_summary" "$julia_raw" "$julia_status" \
      >> "$journal"
  fi
done

# ---------------------------------------------------------------------------
# 3. Thread identity for the dense workloads (t2/t4 vs the t1 reference).
# ---------------------------------------------------------------------------
if (( skip_julia )); then
  echo "m4_parity: --skip-julia; thread identity skipped"
elif (( ${#identity_threads[@]} == 0 )); then
  echo "m4_parity: no thread counts > 1 requested; thread identity skipped"
elif (( ${#identity_ids[@]} == 0 )); then
  echo "m4_parity: identity workloads not selected; thread identity skipped"
else
  for id in "${identity_ids[@]}"; do
    level=""
    balls=""
    for i in "${!workload_ids[@]}"; do
      if [[ "${workload_ids[$i]}" == "$id" ]]; then
        level="${workload_levels[$i]}"
        balls="${workload_balls[$i]}"
        break
      fi
    done
    level_path="$levels_dir/$level.v1.json"
    for value in "${identity_threads[@]}"; do
      summary="$out_dir/julia-$id-t$value.json"
      rows="$raw_dir/m4-julia-$id-t$value.jsonl"
      echo "== Julia sweep t$value (thread identity): $id =="
      run_status=0
      "$julia_bin" -t "$value" --project="$project" "$shot_bench" \
        --sweep \
        --level "$level_path" \
        --config "$config" \
        --stride "$stride" \
        --balls "$balls" \
        --threads "$value" \
        --verify-serial \
        --out "$rows" \
        --summary "$summary" \
        || run_status=$?
      if (( run_status != 0 )); then
        echo "m4_parity: WARNING: Julia sweep '$id' t$value exited $run_status" >&2
      fi
      printf 'thread\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$value" "$summary" "$rows" "$run_status" \
        >> "$journal"
    done
  done
fi

# ---------------------------------------------------------------------------
# 4. Scenario disposition probe (writes the fixed results/m4 report path).
# ---------------------------------------------------------------------------
if (( skip_julia == 0 && skip_scenarios == 0 )); then
  echo "== scenario disposition probe =="
  scenario_start_epoch="$(date +%s)"
  scenario_status=0
  "$julia_bin" --project="$project" "$scenario_probe" || scenario_status=$?
  scenario_stale=0
  if [[ -f "$scenario_report" ]]; then
    scenario_mtime="$(python3 -c 'import os, sys; print(int(os.path.getmtime(sys.argv[1])))' \
      "$scenario_report" 2>/dev/null || echo 0)"
    if (( scenario_mtime < scenario_start_epoch )); then
      scenario_stale=1
    fi
  fi
  printf 'scenario\t%s\t%s\t%s\n' \
    "$scenario_status" "$scenario_report" "$scenario_stale" \
    >> "$journal"
  if (( scenario_status != 0 )); then
    echo "m4_parity: WARNING: scenario probe exited $scenario_status" >&2
  fi
  if (( scenario_stale != 0 )); then
    echo "m4_parity: WARNING: scenario report was not rewritten by this run" >&2
  fi
elif (( skip_julia )); then
  echo "m4_parity: --skip-julia; scenario probe skipped"
else
  echo "m4_parity: --skip-scenarios; scenario probe skipped"
fi

# ---------------------------------------------------------------------------
# 5. Combined deterministic report.
# ---------------------------------------------------------------------------
M4_REPO_ROOT="$repo_root" \
M4_STATE_DIR="$state_dir" \
M4_OUT_DIR="$out_dir" \
M4_RAW_DIR="$raw_dir" \
M4_STRIDE="$stride" \
M4_THREADS="${threads_list[*]}" \
M4_WORKLOADS="${workload_ids[*]}" \
M4_WORKLOAD_ROWS="$workload_rows_joined" \
M4_SKIP_LUA="$skip_lua" \
M4_SKIP_JULIA="$skip_julia" \
M4_SKIP_TRACES="$skip_traces" \
M4_SKIP_SCENARIOS="$skip_scenarios" \
python3 - <<'PY'
import hashlib
import json
import os
import sys

root = os.path.abspath(os.environ["M4_REPO_ROOT"])
# The scenario probe writes this fixed repo path regardless of --out-dir.
scenario_report = os.path.join(root, "results", "m4", "scenario-parity.json")
state_dir = os.environ["M4_STATE_DIR"]
out_dir = os.environ["M4_OUT_DIR"]
raw_dir = os.environ["M4_RAW_DIR"]
stride = int(os.environ["M4_STRIDE"])
threads = [int(value) for value in os.environ["M4_THREADS"].split()]
workload_ids = os.environ["M4_WORKLOADS"].split()
flags = {
    "skip_lua": os.environ["M4_SKIP_LUA"] == "1",
    "skip_julia": os.environ["M4_SKIP_JULIA"] == "1",
    "skip_traces": os.environ["M4_SKIP_TRACES"] == "1",
    "skip_scenarios": os.environ["M4_SKIP_SCENARIOS"] == "1",
}
skip_reason = " ".join(
    name for name, active in (
        ("--skip-lua", flags["skip_lua"]),
        ("--skip-julia", flags["skip_julia"]),
    ) if active)
workloads = {}
for item in os.environ["M4_WORKLOAD_ROWS"].split(";"):
    if not item:
        continue
    wid, level, balls = item.split("|")
    workloads[wid] = {"level": level, "balls": int(balls)}
extra_threads = [value for value in threads if value != 1]
identity_ids = [wid for wid in ("lines_rect_annular", "annular_dense")
                if wid in workload_ids]


def display(path):
    absolute = os.path.abspath(path)
    if absolute == root:
        return "."
    prefix = root + os.sep
    if absolute.startswith(prefix):
        return os.path.relpath(absolute, root)
    return absolute


def try_load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle), None
    except OSError as exc:
        return None, "cannot read %s: %s" % (display(path), exc)
    except ValueError as exc:
        return None, "invalid JSON in %s: %s" % (display(path), exc)


def sha256_file(path):
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
    except OSError:
        return None
    return digest.hexdigest()


def summary_counts(summary, keys):
    if not isinstance(summary, dict):
        return None
    return {key: summary.get(key) for key in keys}


# ---------------------------------------------------------------------------
# Read the orchestration journal written by the shell steps.
# ---------------------------------------------------------------------------
fixtures_record = None
sweep_records = {}
thread_t1_records = {}
thread_records = {}
scenario_record = None
journal_path = os.path.join(state_dir, "journal.tsv")
with open(journal_path, encoding="utf-8") as handle:
    for line in handle:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        kind = parts[0]
        try:
            if kind == "fixtures":
                fixtures_record = {
                    "exit": int(parts[1]),
                    "report": parts[2],
                    "trace_report": parts[3],
                }
            elif kind == "sweep":
                sweep_records[parts[1]] = {
                    "lua_status": parts[2],
                    "julia_status": parts[3],
                    "compare_status": parts[4],
                    "lua_summary": parts[5],
                    "julia_summary": parts[6],
                    "lua_raw": parts[7],
                    "julia_raw": parts[8],
                    "compare_report": parts[9],
                }
            elif kind == "thread_t1":
                thread_t1_records[parts[1]] = {
                    "summary": parts[2],
                    "rows": parts[3],
                    "status": parts[4],
                }
            elif kind == "thread":
                thread_records.setdefault(parts[1], {})[int(parts[2])] = {
                    "summary": parts[3],
                    "rows": parts[4],
                    "status": parts[5],
                }
            elif kind == "scenario":
                scenario_record = {
                    "exit": int(parts[1]),
                    "report": parts[2],
                    "stale": parts[3] == "1",
                }
        except (IndexError, ValueError):
            print("m4_parity: ERROR: malformed journal line: %r" % line,
                  file=sys.stderr)
            sys.exit(2)

# ---------------------------------------------------------------------------
# Fixtures.
# ---------------------------------------------------------------------------
if flags["skip_julia"]:
    fixtures = {
        "status": "skipped",
        "pass": None,
        "reason": "--skip-julia",
    }
else:
    reasons = []
    report_path = None
    driver_exit = None
    summary = None
    if fixtures_record is None:
        reasons.append("replay driver did not run")
    else:
        report_path = fixtures_record["report"]
        driver_exit = fixtures_record["exit"]
        if driver_exit not in (0, 1):
            reasons.append(
                "replay driver exited %d before writing a usable report"
                % driver_exit)
        elif os.path.isfile(report_path):
            doc, error = try_load(report_path)
            if error:
                reasons.append(error)
            elif isinstance(doc, dict):
                summary = doc.get("summary")
            else:
                reasons.append("fixture report is not an object")
        else:
            reasons.append("missing fixture report")
    all_match = summary.get("all_match") if isinstance(summary, dict) else None
    matched = summary.get("matched") if isinstance(summary, dict) else None
    total = summary.get("fixtures") if isinstance(summary, dict) else None
    failed = summary.get("failed") if isinstance(summary, dict) else None
    if not isinstance(summary, dict):
        if report_path and os.path.isfile(report_path):
            reasons.append("fixture report has no summary object")
    else:
        for key in ("fixtures", "matched", "failed", "all_match"):
            if key not in summary:
                reasons.append("fixture summary is missing '%s'" % key)
    if all_match is not True:
        reasons.append("fixture all_match is not true")
    if failed not in (0, None) and failed != 0:
        reasons.append("fixture summary reports failed=%r" % (failed,))
    if isinstance(total, int) and isinstance(matched, int) and matched != total:
        reasons.append("fixture matched (%d) != fixtures (%d)" % (matched, total))
    fixtures = {
        "status": "pass" if not reasons else "fail",
        "pass": not reasons,
        "driver_exit": driver_exit,
        "report": display(report_path) if report_path else None,
        "all_match": all_match,
        "counts": summary_counts(
            summary,
            ("fixtures", "matched", "failed", "fields_compared_per_fixture",
             "fields_compared_total"),
        ),
        "reasons": reasons,
    }

# ---------------------------------------------------------------------------
# Traces.
# ---------------------------------------------------------------------------
if flags["skip_julia"]:
    traces = {
        "status": "skipped",
        "pass": None,
        "reason": "--skip-julia",
    }
elif flags["skip_traces"]:
    traces = {
        "status": "skipped",
        "pass": None,
        "reason": "--skip-traces",
    }
else:
    reasons = []
    report_path = fixtures_record["trace_report"] if fixtures_record else None
    driver_exit = fixtures_record["exit"] if fixtures_record else None
    summary = None
    if report_path is None:
        reasons.append("trace report path missing")
    elif driver_exit not in (0, 1):
        reasons.append(
            "replay driver exited %d before writing a usable trace report"
            % driver_exit)
    elif not os.path.isfile(report_path):
        reasons.append("missing trace report")
    else:
        doc, error = try_load(report_path)
        if error:
            reasons.append(error)
        elif isinstance(doc, dict):
            summary = doc.get("summary")
        else:
            reasons.append("trace report is not an object")
    if not isinstance(summary, dict):
        if report_path and os.path.isfile(report_path):
            reasons.append("trace report has no summary object")
    else:
        required = (
            "traced_fixtures", "regenerated", "identical", "failed",
            "all_byte_identical", "summaries_identical", "summary_equivalence_all",
        )
        for key in required:
            if key not in summary:
                reasons.append("trace summary is missing '%s'" % key)
        if summary.get("all_byte_identical") is not True:
            reasons.append("trace all_byte_identical is not true")
        if summary.get("summary_equivalence_all") is not True:
            reasons.append("trace summary_equivalence_all is not true")
        if summary.get("failed") not in (0, None):
            reasons.append("trace summary reports failed=%r"
                           % (summary.get("failed"),))
        if summary.get("regenerated") != summary.get("traced_fixtures"):
            reasons.append("trace regenerated count != traced_fixtures")
        if summary.get("identical") != summary.get("regenerated"):
            reasons.append("trace identical count != regenerated")
    traces = {
        "status": "pass" if not reasons else "fail",
        "pass": not reasons,
        "driver_exit": driver_exit,
        "report": display(report_path) if report_path else None,
        "counts": summary_counts(
            summary,
            ("traced_fixtures", "regenerated", "identical", "failed",
             "summaries_identical"),
        ),
        "all_byte_identical": summary.get("all_byte_identical")
        if isinstance(summary, dict) else None,
        "summary_equivalence_all": summary.get("summary_equivalence_all")
        if isinstance(summary, dict) else None,
        "reasons": reasons,
    }

# ---------------------------------------------------------------------------
# Sweeps (per workload) and thread identity.
# ---------------------------------------------------------------------------
sweep_entries = []
sweep_reasons_all = []
for wid in workload_ids:
    info = workloads[wid]
    record = sweep_records.get(wid)
    entry = {
        "workload": wid,
        "level": info["level"],
        "balls": info["balls"],
        "status": "skipped",
        "pass": None,
        "clean": None,
        "mismatch_candidates": None,
        "candidates_compared": None,
        "coverage": None,
        "lua_summary": None,
        "julia_summary": None,
        "lua_raw": None,
        "julia_raw": None,
        "compare_report": None,
        "reasons": [],
    }
    if flags["skip_lua"] or flags["skip_julia"]:
        entry["reason"] = skip_reason
        sweep_entries.append(entry)
        continue
    reasons = []
    if record is None:
        reasons.append("sweep did not run")
    else:
        entry.update({
            "lua_summary": display(record["lua_summary"]),
            "julia_summary": display(record["julia_summary"]),
            "lua_raw": display(record["lua_raw"]),
            "julia_raw": display(record["julia_raw"]),
            "compare_report": display(record["compare_report"]),
        })
        if record["lua_status"] != "0":
            reasons.append("Lua sweep status %s" % record["lua_status"])
        if record["julia_status"] != "0":
            reasons.append("Julia sweep status %s" % record["julia_status"])
        compare_status = record["compare_status"]
        if compare_status not in ("0", "1"):
            reasons.append("comparator did not run (%s)" % compare_status)
        report = None
        if os.path.isfile(record["compare_report"]):
            report, error = try_load(record["compare_report"])
            if error:
                reasons.append(error)
            elif not isinstance(report, dict):
                reasons.append("compare report is not an object")
                report = None
        if isinstance(report, dict):
            entry["clean"] = report.get("clean")
            entry["mismatch_candidates"] = report.get("mismatch_candidates")
            entry["candidates_compared"] = report.get("candidates_compared")
            entry["coverage"] = report.get("coverage")
            if report.get("clean") is not True:
                reasons.append("compare report is not clean")
            if report.get("mismatch_candidates") not in (0, None):
                reasons.append("compare report has %r mismatch candidates"
                               % (report.get("mismatch_candidates"),))
        elif compare_status in ("0", "1"):
            reasons.append("missing compare report")
        if compare_status == "1" and "compare report is not clean" not in reasons:
            reasons.append("comparator found mismatches")
    entry["reasons"] = reasons
    entry["status"] = "pass" if not reasons else "fail"
    entry["pass"] = not reasons
    if reasons:
        sweep_reasons_all.append(wid)
    sweep_entries.append(entry)

sweep_counts = {
    "workloads": len(sweep_entries),
    "passed": sum(1 for entry in sweep_entries if entry["status"] == "pass"),
    "failed": sum(1 for entry in sweep_entries if entry["status"] == "fail"),
    "skipped": sum(1 for entry in sweep_entries if entry["status"] == "skipped"),
}
if flags["skip_lua"] or flags["skip_julia"]:
    sweeps_status = "skipped"
    sweeps_pass = None
elif sweep_counts["failed"] > 0 or sweep_counts["passed"] == 0:
    sweeps_status = "fail"
    sweeps_pass = False
else:
    sweeps_status = "pass"
    sweeps_pass = True

if flags["skip_julia"]:
    identity = {
        "status": "skipped",
        "pass": None,
        "reason": "--skip-julia",
        "threads": [1] + extra_threads,
        "workloads": [],
        "counts": {"workloads": 0, "passed": 0, "failed": 0},
    }
elif not extra_threads:
    identity = {
        "status": "skipped",
        "pass": None,
        "reason": "no thread counts > 1 requested",
        "threads": [1],
        "workloads": [],
        "counts": {"workloads": 0, "passed": 0, "failed": 0},
    }
elif not identity_ids:
    identity = {
        "status": "skipped",
        "pass": None,
        "reason": "identity workloads not selected",
        "threads": [1] + extra_threads,
        "workloads": [],
        "counts": {"workloads": 0, "passed": 0, "failed": 0},
    }
else:
    identity_entries = []
    all_threads = [1] + extra_threads
    for wid in identity_ids:
        reasons = []
        entry = {
            "workload": wid,
            "status": "fail",
            "pass": False,
            "threads": all_threads,
            "serial_parallel_identical": {},
            "rows_byte_identical": None,
            "row_sha256": {},
            "summaries": {},
            "rows": {},
            "reasons": [],
        }
        t1 = thread_t1_records.get(wid)
        if t1 is None:
            reasons.append("t1 reference run missing")
        else:
            entry["summaries"]["1"] = display(t1["summary"])
            entry["rows"]["1"] = display(t1["rows"])
            if t1["status"] != "0":
                reasons.append("t1 sweep status %s" % t1["status"])
            doc, error = try_load(t1["summary"]) if os.path.isfile(t1["summary"]) else (None, "missing t1 summary")
            if error:
                reasons.append(error)
            elif isinstance(doc, dict):
                entry["serial_parallel_identical"]["1"] = doc.get(
                    "serial_parallel_identical")
                if doc.get("verify_serial") is not True:
                    reasons.append("t1 summary verify_serial is not true")
                if doc.get("serial_parallel_identical") is not True:
                    reasons.append("t1 serial_parallel_identical is not true")
            else:
                reasons.append("t1 summary is not an object")
        for value in extra_threads:
            key = str(value)
            run = thread_records.get(wid, {}).get(value)
            if run is None:
                reasons.append("t%s run missing" % key)
                continue
            entry["summaries"][key] = display(run["summary"])
            entry["rows"][key] = display(run["rows"])
            if run["status"] != "0":
                reasons.append("t%s sweep status %s" % (key, run["status"]))
            if not os.path.isfile(run["summary"]):
                reasons.append("missing t%s summary" % key)
                continue
            doc, error = try_load(run["summary"])
            if error:
                reasons.append(error)
                continue
            if not isinstance(doc, dict):
                reasons.append("t%s summary is not an object" % key)
                continue
            identical = doc.get("serial_parallel_identical")
            entry["serial_parallel_identical"][key] = identical
            if doc.get("verify_serial") is not True:
                reasons.append("t%s summary verify_serial is not true" % key)
            if identical is not True:
                reasons.append("t%s serial_parallel_identical is not true" % key)
        sha_by_thread = {}
        for key, rows_path in entry["rows"].items():
            if not os.path.isfile(rows_path):
                sha_by_thread[key] = None
                continue
            sha_by_thread[key] = sha256_file(rows_path)
        entry["row_sha256"] = sha_by_thread
        known = [digest for digest in sha_by_thread.values() if digest]
        entry["rows_byte_identical"] = (
            len(sha_by_thread) == len(all_threads)
            and all(digest is not None for digest in sha_by_thread.values())
            and len(set(known)) == 1
        )
        if not entry["rows_byte_identical"]:
            reasons.append("candidate rows are not byte-identical across t1/t%s"
                           % "/t".join(str(value) for value in extra_threads))
        entry["reasons"] = reasons
        entry["status"] = "pass" if not reasons else "fail"
        entry["pass"] = not reasons
        identity_entries.append(entry)
    identity_counts = {
        "workloads": len(identity_entries),
        "passed": sum(1 for entry in identity_entries if entry["status"] == "pass"),
        "failed": sum(1 for entry in identity_entries if entry["status"] == "fail"),
    }
    identity = {
        "status": "pass" if identity_counts["failed"] == 0 else "fail",
        "pass": identity_counts["failed"] == 0,
        "threads": all_threads,
        "workloads": identity_entries,
        "counts": identity_counts,
    }

sweeps = {
    "status": sweeps_status,
    "pass": sweeps_pass,
    "counts": sweep_counts,
    "workloads": sweep_entries,
    "thread_identity": identity,
}
if sweeps_status == "skipped":
    sweeps["reason"] = skip_reason
elif sweeps_status == "fail":
    sweeps["failing_workloads"] = sweep_reasons_all

# ---------------------------------------------------------------------------
# Scenarios.
# ---------------------------------------------------------------------------
if flags["skip_julia"]:
    scenarios = {
        "status": "skipped",
        "pass": None,
        "reason": "--skip-julia",
    }
elif flags["skip_scenarios"]:
    scenarios = {
        "status": "skipped",
        "pass": None,
        "reason": "--skip-scenarios",
    }
else:
    reasons = []
    summary = None
    pass_basis = None
    driver_exit = None
    report_path = scenario_report
    stale = False
    if scenario_record is None:
        reasons.append("scenario probe did not run")
    else:
        driver_exit = scenario_record["exit"]
        report_path = scenario_record["report"]
        stale = scenario_record["stale"]
        if driver_exit != 0:
            reasons.append("scenario driver exit %d" % driver_exit)
        if not os.path.isfile(report_path):
            reasons.append("missing scenario report")
        elif stale:
            reasons.append("scenario report was not rewritten by this run")
        else:
            doc, error = try_load(report_path)
            if error:
                reasons.append(error)
            elif not isinstance(doc, dict):
                reasons.append("scenario report is not an object")
            else:
                summary = doc.get("summary")
    if isinstance(summary, dict):
        explicit = None
        for key in ("all_ported_match", "all_pass", "all_match", "all_ok"):
            value = summary.get(key)
            if isinstance(value, bool):
                explicit = value
                pass_basis = "summary.%s" % key
                break
        if explicit is None:
            for key in ("failed", "mismatches", "failure_count"):
                value = summary.get(key)
                if isinstance(value, bool):
                    explicit = value
                    pass_basis = "summary.%s" % key
                    break
                if isinstance(value, int) and not isinstance(value, bool):
                    explicit = value == 0
                    pass_basis = "summary.%s" % key
                    break
        if explicit is False:
            reasons.append("scenario summary reports a failure")
        if explicit is None:
            pass_basis = "driver_exit"
    elif not flags["skip_scenarios"]:
        if scenario_record is not None:
            reasons.append("scenario report has no summary object")
    scenarios = {
        "status": "pass" if not reasons else "fail",
        "pass": not reasons,
        "driver_exit": driver_exit,
        "report": display(report_path),
        "report_fresh": (not stale) if scenario_record is not None else None,
        "pass_basis": pass_basis,
        "summary": summary if isinstance(summary, dict) else None,
        "reasons": reasons,
    }

# ---------------------------------------------------------------------------
# Overall.
# ---------------------------------------------------------------------------
groups = {
    "fixtures": fixtures,
    "traces": traces,
    "sweeps": sweeps,
    "scenarios": scenarios,
}
order = ("fixtures", "traces", "sweeps", "scenarios")
requested = [name for name in order if groups[name]["status"] != "skipped"]
failed = [name for name in requested if groups[name]["pass"] is not True]
overall_pass = not failed
counts = {
    "groups": len(order),
    "requested": len(requested),
    "passed": len(requested) - len(failed),
    "failed": len(failed),
    "skipped": len(order) - len(requested),
}
report = {
    "format": "peggle.m4_parity_summary",
    "schema_version": 1,
    "options": {
        "stride": stride,
        "workloads": workload_ids,
        "threads": threads,
        "skip_lua": flags["skip_lua"],
        "skip_julia": flags["skip_julia"],
        "skip_traces": flags["skip_traces"],
        "skip_scenarios": flags["skip_scenarios"],
        "out_dir": display(out_dir),
        "raw_dir": display(raw_dir),
    },
    "fixtures": fixtures,
    "traces": traces,
    "sweeps": sweeps,
    "scenarios": scenarios,
    "counts": counts,
    "overall_pass": overall_pass,
}

output_path = os.path.join(out_dir, "parity-summary.json")
os.makedirs(out_dir, exist_ok=True)
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=2, sort_keys=True)
    handle.write("\n")

print("m4_parity: fixtures=%s traces=%s sweeps=%s scenarios=%s overall_pass=%s" % (
    fixtures["status"], traces["status"], sweeps["status"],
    scenarios["status"], overall_pass))
if failed:
    print("m4_parity: failing groups: %s" % ", ".join(failed), file=sys.stderr)
print("m4_parity: wrote %s" % display(output_path))
sys.exit(0 if overall_pass else 1)
PY
