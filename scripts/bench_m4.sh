#!/usr/bin/env bash
# M4 representative performance benchmark (performance gate inputs).
#
# Runs the seven workloads from harness/workloads.lua through the pinned Lua
# reference harness and the Julia shot engine, collects throughput, latency,
# allocation and peak-memory metrics, adds one tracing-on-vs-off diagnostic,
# and writes one canonical report:
#
#   results/m4/bench-report.json                       combined report
#   results/m4/bench-lua-<id>.summary.json             Lua timed sweep (repeat R)
#   results/raw/m4-bench-lua-<id>.candidates.jsonl     Lua raw rows (gitignored)
#   results/m4/bench-julia-<id>-t<T>.json(l)           Julia sweeps per thread count
#   results/m4/bench-sweeps-compare-<id>.json          stride-N row agreement (informational)
#   results/m4/bench-diag-<id>-{untraced,traced}.json  diagnostic summaries
#   results/raw/m4-bench-diag-<id>-traces/             per-candidate traces (gitignored)
#   tmp/m4-bench/journal.tsv                           run journal (resume input)
#
# Measurement protocol (unchanged from M3; only the workload set is new):
#   * Lua: frozen pinned tree reference/peggle_evolved, single-threaded,
#     --sweep --stride N --repeat R --no-replay-serialize. The harness reads
#     level and balls from harness/workloads.lua, so there is no --balls flag.
#   * Julia: one post-warmup sweep per thread count with --verify-serial
#     (serial + parallel passes, rows must be bit-identical) and --alloc
#     (process-wide bytes on the serial pass). Thread counts are capped at
#     nproc; the report records requested vs actual.
#   * Peak memory: every sweep process is wrapped by scripts/bench_process.py,
#     which uses GNU `time -v` when available and otherwise the kernel ru_maxrss
#     high-water mark (VmHWM) of the one child.
#   * Diagnostic: circles_small (default) timed once untraced and once with
#     --trace-dir; traced timing is reported separately and never merged into
#     the main table. Result rows must be byte-identical.
#   * Full-grid throughput is reused read-only from session 1: stride 1
#     results/m4/lua-<id>.summary.json and results/m4/julia-<id>-t1.json. The
#     new benchmark is stride 20, so the report says so explicitly.
#
# Usage (from anywhere; paths resolve relative to this script):
#   scripts/bench_m4.sh [--stride N] [--repeats R] [--threads "1 2 4 8 12"]
#                       [--workloads LIST|all]
#                       [--diagnostic-workload ID|none]
#                       [--out-dir DIR] [--raw-dir DIR]
#                       [--resume] [--report-only]
#
# --resume reuses a completed run from the existing journal when its summary
# still matches the requested stride/repeats/threads/balls/level (cheap file +
# JSON check); otherwise that run is repeated. --report-only skips all runs and
# rebuilds results/m4/bench-report.json from the existing journal/artifacts.
#
# Exit status: 0 iff every requested run succeeded and the report was written;
# 1 if any measurement failed; 2 on bad usage or missing inputs.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# ~/.julia is read-only under the sandbox; keep a writable depot overlay unless
# the caller already provided one.
export JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH:-$repo_root/tmp/julia-depot:$HOME/.julia}"
mkdir -p "$repo_root/tmp/julia-depot"

usage() {
  cat <<'EOF'
M4 representative performance benchmark.

Usage: scripts/bench_m4.sh [options]

Options:
  --stride N                  aim-index stride (default: 20)
  --repeats R                 Lua timed repeats per workload (default: 2)
  --threads LIST              Julia thread counts (default: "1 2 4 8 12");
                              values are capped at nproc, 1 is always included
  --workloads LIST|all        comma-separated workload ids (default: all)
  --diagnostic-workload ID|none
                              workload for the tracing on/off diagnostic
                              (default: circles_small)
  --out-dir DIR               summary/report directory (default: results/m4)
  --raw-dir DIR               raw JSONL/trace directory (default: results/raw)
  --resume                    reuse completed runs that still match the options
  --report-only               do not run anything; rebuild the report from the
                              existing journal under tmp/m4-bench/
  -h, --help                  show this help and exit

Workloads: overhead_static_2p, circles_small, circles_mixed,
lines_rect_annular, annular_dense, annular_dense_multi3,
lines_rect_annular_multi3 (from harness/workloads.lua).

The Lua side always uses the frozen pinned tree reference/peggle_evolved.
Full-grid stride-1 throughput is reused from session 1 (results/m4/); it is
never re-measured here. Peak memory per process is captured by
scripts/bench_process.py (GNU time -v when present, else ru_maxrss).
EOF
}

stride=20
repeats=2
threads_arg="1 2 4 8 12"
workloads_arg="all"
diag_workload="circles_small"
out_dir_arg="results/m4"
raw_dir_arg="results/raw"
resume=0
report_only=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stride) stride="${2:?--stride requires a value}"; shift 2 ;;
    --repeats) repeats="${2:?--repeats requires a value}"; shift 2 ;;
    --threads) threads_arg="${2:?--threads requires a value}"; shift 2 ;;
    --workloads) workloads_arg="${2:?--workloads requires a value}"; shift 2 ;;
    --diagnostic-workload) diag_workload="${2:?--diagnostic-workload requires a value}"; shift 2 ;;
    --out-dir) out_dir_arg="${2:?--out-dir requires a value}"; shift 2 ;;
    --raw-dir) raw_dir_arg="${2:?--raw-dir requires a value}"; shift 2 ;;
    --resume) resume=1; shift ;;
    --report-only) report_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! [[ "$stride" =~ ^[0-9]+$ ]] || (( stride < 1 )); then
  echo "ERROR: --stride must be a positive integer" >&2
  exit 2
fi
if ! [[ "$repeats" =~ ^[0-9]+$ ]] || (( repeats < 1 )); then
  echo "ERROR: --repeats must be a positive integer" >&2
  exit 2
fi

abspath() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$repo_root/$1" ;;
  esac
}

out_dir="$(abspath "$out_dir_arg")"
raw_dir="$(abspath "$raw_dir_arg")"

# ---------------------------------------------------------------------------
# M4 workload map. Must match harness/workloads.lua; the catalog is verified
# below when luajit is available so drift is a hard error, not a silent skew.
# ---------------------------------------------------------------------------
workloads_catalog="$repo_root/harness/workloads.lua"
config="$repo_root/interchange/config.v1.json"
levels_dir="$repo_root/interchange/levels"
pinned_ref="$repo_root/reference/peggle_evolved"
project="$repo_root/julia/PeggleSim"
shot_bench="$repo_root/julia/PeggleSim/bin/shot_bench.jl"
comparator="$repo_root/scripts/compare_m3_sweeps.py"
process_wrap="$repo_root/scripts/bench_process.py"
report_py="$repo_root/scripts/bench_m4_report.py"
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
m4_balls=(1 1 1 1 1 3 3)
m4_groups=(overhead circles circles rectangles annular multiball multiball)

list_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Parse and validate workloads, thread counts, and the diagnostic workload.
# ---------------------------------------------------------------------------
workload_ids=()
workload_levels=()
workload_balls=()
workload_groups=()
if [[ "$workloads_arg" == "all" ]]; then
  workload_ids=("${m4_ids[@]}")
  workload_levels=("${m4_levels[@]}")
  workload_balls=("${m4_balls[@]}")
  workload_groups=("${m4_groups[@]}")
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
  ((${#cleaned_ids[@]} > 0)) || {
    echo "ERROR: --workloads selected no workloads" >&2
    exit 2
  }
  for i in "${!m4_ids[@]}"; do
    if list_contains "${m4_ids[$i]}" "${cleaned_ids[@]}"; then
      workload_ids+=("${m4_ids[$i]}")
      workload_levels+=("${m4_levels[$i]}")
      workload_balls+=("${m4_balls[$i]}")
      workload_groups+=("${m4_groups[$i]}")
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
((${#normalized_threads[@]} > 0)) || {
  echo "ERROR: --threads needs at least one thread count" >&2
  exit 2
}
threads_requested="$(printf '%s\n' "${normalized_threads[@]}" | sort -n -u | tr '\n' ' ')"
threads_requested="${threads_requested% }"

nproc_val="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
capped_threads=()
for value in ${threads_requested//,/ }; do
  capped="$value"
  if (( capped > nproc_val )); then
    echo "bench_m4: capping thread count $capped to nproc=$nproc_val"
    capped="$nproc_val"
  fi
  capped_threads+=("$capped")
done
threads_capped="$(printf '%s\n' "${capped_threads[@]}" | sort -n -u | tr '\n' ' ')"
threads_capped="${threads_capped% }"
if ! grep -qw 1 <<< "$threads_capped"; then
  threads_capped="1 $threads_capped"
fi
read -r -a thread_values <<< "$threads_capped"

diag_id=""
diag_level=""
diag_balls=""
if [[ "$diag_workload" != "none" ]]; then
  if ! list_contains "$diag_workload" "${m4_ids[@]}"; then
    echo "ERROR: unknown --diagnostic-workload '$diag_workload' (known: ${m4_ids[*]}, none)" >&2
    exit 2
  fi
  for i in "${!m4_ids[@]}"; do
    if [[ "${m4_ids[$i]}" == "$diag_workload" ]]; then
      diag_id="${m4_ids[$i]}"
      diag_level="${m4_levels[$i]}"
      diag_balls="${m4_balls[$i]}"
      break
    fi
  done
fi

# ---------------------------------------------------------------------------
# Preflight.
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required" >&2
  exit 2
fi
if [[ ! -f "$config" ]]; then
  echo "ERROR: missing config artifact $config" >&2
  exit 2
fi
if [[ ! -f "$shot_bench" ]]; then
  echo "ERROR: missing Julia sweep driver $shot_bench" >&2
  exit 2
fi
if [[ ! -f "$comparator" || ! -f "$process_wrap" || ! -f "$report_py" ]]; then
  echo "ERROR: missing benchmark helper under scripts/" >&2
  exit 2
fi
for i in "${!workload_ids[@]}"; do
  level_path="$levels_dir/${workload_levels[$i]}.v1.json"
  if [[ ! -f "$level_path" ]]; then
    echo "ERROR: missing level artifact for '${workload_ids[$i]}': $level_path" >&2
    exit 2
  fi
done
if (( report_only == 0 )); then
  if [[ ! -f "$workloads_catalog" ]]; then
    echo "ERROR: missing workload catalog $workloads_catalog" >&2
    exit 2
  fi
  if [[ ! -d "$repo_root/harness" ]]; then
    echo "ERROR: missing harness directory $repo_root/harness" >&2
    exit 2
  fi
  if [[ ! -f "$pinned_ref/src/config.lua" ]]; then
    echo "ERROR: frozen Lua reference tree not found at $pinned_ref" >&2
    exit 2
  fi
  if ! command -v love >/dev/null 2>&1; then
    echo "ERROR: LÖVE ('love') is required for the Lua sweeps" >&2
    exit 2
  fi
  if ! command -v "$julia_bin" >/dev/null 2>&1; then
    echo "ERROR: Julia ('$julia_bin') is required" >&2
    exit 2
  fi
  # Verify the embedded workload map against harness/workloads.lua.
  if command -v luajit >/dev/null 2>&1; then
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
  io.write(string.format("%s|%s|%d|%s\n", workload.id, workload.level,
    workload.balls or 1, workload.group or ""))
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
      expected_row="${m4_ids[$i]}|${m4_levels[$i]}|${m4_balls[$i]}|${m4_groups[$i]}"
      if ! grep -Fxq -- "$expected_row" <<< "$catalog_tsv"; then
        echo "ERROR: M4 workload map does not match $workloads_catalog for '${m4_ids[$i]}'" >&2
        echo "       expected row: $expected_row" >&2
        exit 2
      fi
    done
  else
    echo "bench_m4: WARNING: luajit unavailable; workload map not verified against harness/workloads.lua" >&2
  fi
fi

julia_version="$("$julia_bin" --version 2>/dev/null || echo unknown)"
git_head="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
git_dirty=0
if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
  git_dirty=1
fi

state_dir="$repo_root/tmp/m4-bench"
times_dir="$state_dir/times"
mkdir -p "$out_dir" "$raw_dir" "$state_dir" "$times_dir"
journal="$state_dir/journal.tsv"

echo "bench_m4: host=$host_label nproc=$nproc_val stride=$stride repeats=$repeats"
echo "bench_m4: threads requested=[$threads_requested] capped=[$threads_capped]"
echo "bench_m4: workloads=${workload_ids[*]}"
echo "bench_m4: out=$out_dir_arg raw=$raw_dir_arg diagnostic=${diag_id:-none}"
echo "bench_m4: $julia_version"
if [[ "$git_head" != "unknown" ]]; then
  echo "bench_m4: git head=$git_head dirty=$git_dirty"
fi

# ---------------------------------------------------------------------------
# Run journal / resume state.
# ---------------------------------------------------------------------------
work_journal="$journal"
if (( report_only )); then
  :
elif (( resume )) && [[ -f "$journal" ]]; then
  work_journal="$journal.resume.$$"
  : > "$work_journal"
elif (( resume )); then
  echo "bench_m4: --resume requested but no journal at $journal; running all measurements"
  : > "$work_journal"
else
  : > "$work_journal"
fi

declare -A reused=()
declare -A run_status=()

# Does an existing summary still describe the requested run?  Cheap: one JSON
# read per candidate record.  Only used by --resume.
summary_matches() { # kind path stride repeats threads balls expected level workload
  python3 - "$@" <<'PY'
import json
import sys

(kind, path, stride, repeats, threads, balls, expected, level,
 workload) = sys.argv[1:10]
try:
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
except Exception:
    sys.exit(1)
expected = int(expected)
try:
    if kind == "lua":
        options = doc.get("options") or {}
        workloads = doc.get("workloads") or []
        if not workloads:
            sys.exit(1)
        first = workloads[0]
        ok = (options.get("stride") == int(stride)
              and options.get("repeat_count") == int(repeats)
              and first.get("workload") == workload
              and first.get("level") == level
              and int(first.get("balls") or 1) == int(balls)
              and first.get("candidates") == expected)
    else:
        ok = (doc.get("threads") == int(threads)
              and doc.get("level") == level
              and int(doc.get("balls") or 1) == int(balls)
              and doc.get("candidates") == expected)
except (TypeError, ValueError):
    sys.exit(1)
sys.exit(0 if ok else 1)
PY
}

aim_steps="$(python3 - "$config" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
print(int((config.get("values") or {}).get("aim_discretization_steps", 1800)))
PY
)"
expected_candidates=$((aim_steps / stride + 1))

if (( resume )) && [[ -f "$journal" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r -a fields <<< "$line"
    key="${fields[0]:-}"
    kind="${fields[1]:-}"
    case "$kind" in
      lua)
        id="${fields[2]:-}"
        status="${fields[3]:-1}"
        summary="${fields[4]:-}"
        raw="${fields[5]:-}"
        reps="${fields[7]:-}"
        balls=""
        level=""
        for i in "${!workload_ids[@]}"; do
          if [[ "${workload_ids[$i]}" == "$id" ]]; then
            balls="${workload_balls[$i]}"
            level="${workload_levels[$i]}"
            break
          fi
        done
        if [[ "$status" == "0" && "$reps" == "$repeats" && -f "$summary" && -f "$raw" ]] \
            && summary_matches lua "$summary" "$stride" "$repeats" 1 "${balls:-1}" "$expected_candidates" "$level" "$id"; then
          reused["$key"]=1
          run_status["$key"]=0
          printf '%s\n' "$line" >> "$work_journal"
          echo "bench_m4: resume: reusing Lua $id"
        fi
        ;;
      julia)
        id="${fields[2]:-}"
        threads="${fields[3]:-1}"
        status="${fields[4]:-1}"
        summary="${fields[5]:-}"
        raw="${fields[6]:-}"
        balls=""
        level=""
        for i in "${!workload_ids[@]}"; do
          if [[ "${workload_ids[$i]}" == "$id" ]]; then
            balls="${workload_balls[$i]}"
            level="${workload_levels[$i]}"
            break
          fi
        done
        if [[ "$status" == "0" && -f "$summary" && -f "$raw" ]] \
            && summary_matches julia "$summary" "$stride" "$repeats" "$threads" "${balls:-1}" "$expected_candidates" "$level" ""; then
          reused["$key"]=1
          run_status["$key"]=0
          printf '%s\n' "$line" >> "$work_journal"
          echo "bench_m4: resume: reusing Julia $id t$threads"
        fi
        ;;
      diag)
        phase="${fields[3]:-}"
        status="${fields[4]:-1}"
        summary="${fields[5]:-}"
        raw="${fields[6]:-}"
        trace_dir="${fields[8]:--}"
        if [[ "$status" == "0" && -f "$summary" && -f "$raw" ]] \
            && summary_matches julia "$summary" "$stride" "$repeats" 1 "${diag_balls:-1}" "$expected_candidates" "$diag_level" ""; then
          if [[ "$phase" != "traced" || -d "$trace_dir" ]]; then
            reused["$key"]=1
            run_status["$key"]=0
            printf '%s\n' "$line" >> "$work_journal"
            echo "bench_m4: resume: reusing diagnostic $phase"
          fi
        fi
        ;;
      *) ;;
    esac
  done < "$journal"
fi

run_measured() { # time_json label command...
  local time_json="$1"
  local label="$2"
  shift 2
  python3 "$process_wrap" --out "$time_json" --label "$label" -- "$@"
}

journal_add() {
  printf '%s\n' "$*" >> "$work_journal"
}

if (( report_only )); then
  if [[ ! -f "$journal" ]]; then
    echo "ERROR: --report-only needs an existing journal at $journal" >&2
    exit 2
  fi
  echo "bench_m4: --report-only; rebuilding report from $journal"
else

  # -------------------------------------------------------------------------
  # 1. Lua reference sweeps (frozen pinned tree) and Julia sweeps.
  # -------------------------------------------------------------------------
  for i in "${!workload_ids[@]}"; do
    id="${workload_ids[$i]}"
    level="${workload_levels[$i]}"
    balls="${workload_balls[$i]}"
    level_path="$levels_dir/$level.v1.json"
    lua_summary_prefix="$out_dir/bench-lua-$id"
    lua_summary="$lua_summary_prefix.summary.json"
    lua_raw_prefix="$raw_dir/m4-bench-lua-$id"
    lua_raw="$lua_raw_prefix.candidates.jsonl"
    lua_time="$times_dir/lua-$id.json"
    lua_key="lua:$id"

    if [[ -n "${reused[$lua_key]:-}" ]]; then
      echo "== Lua sweep: $id (reused) =="
    else
      echo "== Lua sweep: $id (level $level, balls $balls, stride $stride, repeat $repeats) =="
      lua_status=0
      run_measured "$lua_time" "lua:$id" \
        "$repo_root/scripts/love.sh" love "$repo_root/harness" -- \
        --sweep \
        --workloads "$workloads_catalog" \
        --workload "$id" \
        --stride "$stride" \
        --repeat "$repeats" \
        --no-replay-serialize \
        --out "$lua_raw_prefix" \
        --summary-out "$lua_summary_prefix" \
        --reference-dir "$pinned_ref" \
        --run-id "m4-bench-lua-$id" \
        --host-label "$host_label" \
        || lua_status=$?
      run_status["$lua_key"]=$lua_status
      journal_add "$(printf '%s\tlua\t%s\t%d\t%s\t%s\t%s\t%d' \
        "$lua_key" "$id" "$lua_status" "$lua_summary" "$lua_raw" "$lua_time" "$repeats")"
      if (( lua_status != 0 )); then
        echo "bench_m4: WARNING: Lua sweep '$id' exited $lua_status" >&2
      fi
    fi

    for T in "${thread_values[@]}"; do
      julia_summary="$out_dir/bench-julia-$id-t$T.json"
      julia_raw="$raw_dir/m4-bench-julia-$id-t$T.jsonl"
      julia_time="$times_dir/julia-$id-t$T.json"
      julia_key="julia:$id:t$T"

      if [[ -n "${reused[$julia_key]:-}" ]]; then
        echo "== Julia sweep t$T: $id (reused) =="
        continue
      fi
      echo "== Julia sweep t$T: $id (level $level, balls $balls, stride $stride) =="
      julia_status=0
      run_measured "$julia_time" "julia:$id:t$T" \
        "$julia_bin" -t "$T" --project="$project" "$shot_bench" \
        --sweep \
        --level "$level_path" \
        --config "$config" \
        --stride "$stride" \
        --balls "$balls" \
        --threads "$T" \
        --verify-serial \
        --alloc \
        --out "$julia_raw" \
        --summary "$julia_summary" \
        || julia_status=$?
      run_status["$julia_key"]=$julia_status
      journal_add "$(printf '%s\tjulia\t%s\t%d\t%d\t%s\t%s\t%s' \
        "$julia_key" "$id" "$T" "$julia_status" "$julia_summary" "$julia_raw" "$julia_time")"
      if (( julia_status != 0 )); then
        echo "bench_m4: WARNING: Julia sweep '$id' t$T exited $julia_status" >&2
      fi
    done

    # Informational stride-N agreement (the M4 correctness gate is the
    # session-1 full-grid parity report; the comparator is reused, not forked).
    compare_report="$out_dir/bench-sweeps-compare-$id.json"
    compare_key="compare:$id"
    if [[ "${run_status[$lua_key]:-1}" -eq 0 && "${run_status[julia:$id:t1]:-1}" -eq 0 ]]; then
      echo "== sweep compare (stride $stride): $id =="
      compare_status=0
      python3 "$comparator" \
        --lua-raw "$lua_raw" \
        --julia "$raw_dir/m4-bench-julia-$id-t1.jsonl" \
        --stride "$stride" \
        --julia-label t1 \
        --out "$compare_report" \
        || compare_status=$?
    else
      compare_status=255
      rm -f "$compare_report"
    fi
    journal_add "$(printf '%s\tcompare\t%s\t%d\t%s\t%s\t%s' \
      "$compare_key" "$id" "$compare_status" "$lua_raw" \
      "$raw_dir/m4-bench-julia-$id-t1.jsonl" "$compare_report")"
    if (( compare_status != 0 && compare_status != 1 )); then
      echo "bench_m4: WARNING: sweep compare '$id' did not run" >&2
    elif (( compare_status == 1 )); then
      echo "bench_m4: WARNING: stride-$stride rows differ for '$id' (see $compare_report)" >&2
    fi
  done

  # -------------------------------------------------------------------------
  # 2. Diagnostic: tracing off vs on, one workload, reported separately.
  # -------------------------------------------------------------------------
  if [[ -n "$diag_id" ]]; then
    diag_level_path="$levels_dir/$diag_level.v1.json"
    diag_trace_dir="$raw_dir/m4-bench-diag-$diag_id-traces"
    for phase in untraced traced; do
      diag_key="diag:$phase"
      if [[ -n "${reused[$diag_key]:-}" ]]; then
        echo "== diagnostic $phase: $diag_id (reused) =="
        continue
      fi
      diag_summary="$out_dir/bench-diag-$diag_id-$phase.json"
      diag_raw="$raw_dir/m4-bench-diag-$diag_id-$phase.jsonl"
      diag_time="$times_dir/diag-$diag_id-$phase.json"
      echo "== diagnostic $phase: $diag_id (level $diag_level, balls $diag_balls, stride $stride) =="
      diag_cmd=(
        "$julia_bin" -t 1 --project="$project" "$shot_bench"
        --sweep
        --level "$diag_level_path"
        --config "$config"
        --stride "$stride"
        --balls "$diag_balls"
        --threads 1
        --out "$diag_raw"
        --summary "$diag_summary"
      )
      trace_field="-"
      if [[ "$phase" == "traced" ]]; then
        rm -rf "$diag_trace_dir"
        mkdir -p "$diag_trace_dir"
        diag_cmd+=(--trace-dir "$diag_trace_dir")
        trace_field="$diag_trace_dir"
      fi
      diag_status=0
      run_measured "$diag_time" "diag:$diag_id:$phase" "${diag_cmd[@]}" \
        || diag_status=$?
      run_status["$diag_key"]=$diag_status
      journal_add "$(printf '%s\tdiag\t%s\t%s\t%d\t%s\t%s\t%s\t%s' \
        "$diag_key" "$diag_id" "$phase" "$diag_status" "$diag_summary" \
        "$diag_raw" "$diag_time" "$trace_field")"
      if (( diag_status != 0 )); then
        echo "bench_m4: WARNING: diagnostic $phase exited $diag_status" >&2
      fi
    done
  else
    echo "bench_m4: diagnostic disabled (--diagnostic-workload none)"
  fi

  if [[ "$work_journal" != "$journal" ]]; then
    mv "$work_journal" "$journal"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Aggregation and canonical report.
# ---------------------------------------------------------------------------
report_status=0
python3 "$report_py" \
  --repo-root "$repo_root" \
  --journal "$journal" \
  --out "$out_dir/bench-report.json" \
  --stride "$stride" \
  --repeats "$repeats" \
  --threads "$threads_capped" \
  --requested-threads "$threads_requested" \
  --workloads "${workload_ids[*]}" \
  --host-label "$host_label" \
  --nproc "$nproc_val" \
  --julia-version "$julia_version" \
  --git-head "$git_head" \
  --git-dirty "$git_dirty" \
  --out-dir "$out_dir" \
  --raw-dir "$raw_dir" \
  --diagnostic-workload "$diag_id" \
  || report_status=$?

if (( report_status != 0 )); then
  echo "bench_m4: FAILED: report is incomplete (see failures above)" >&2
  exit 1
fi

echo "bench_m4: done"
echo "bench_m4: report $out_dir/bench-report.json"
