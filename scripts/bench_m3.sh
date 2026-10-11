#!/usr/bin/env bash
# M3 mustache Lua-vs-Julia benchmark.
#
# Runs the same candidate grid (the full mustache level from the dev tree)
# through the Lua harness and the Julia shot_bench driver, then compares every
# candidate field and writes a machine-readable report:
#
#   results/m3/lua-bench.summary.json     Lua timed sweep (--no-replay-serialize)
#   results/m3/lua-bench-replay.summary.json  Lua single-repeats with replay I/O
#   results/m3/lua-raw-summary.json       Lua agreement sweep summary
#   results/raw/m3-lua-raw.candidates.jsonl   Lua agreement raw JSONL (gitignored)
#   results/m3/julia-sweep-tT.json(l)     Julia sweeps, one per thread count
#   results/m3/sweeps-compare.json        stride-N field agreement report
#   results/m3/sweeps-compare-full.json   full-grid agreement attempt
#   results/m3/bench-report.json          combined report
#
# Usage (from anywhere; paths resolve relative to this script):
#   scripts/bench_m3.sh [--stride N] [--repeats R] [--threads "1 2 4 8 12"]
#                       [--full-grid auto|none|STRIDE]
#
# --full-grid auto estimates the full Lua grid cost from the stride-N rate and
# runs stride 1 when the projection is at most 20 minutes, otherwise stride 5.
#
# Requires the peggle_evolved dev tree (../peggle_evolved), LuaJIT, LÖVE
# (scripts/love.sh handles headless displays), and Julia.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

stride=20
repeats=2
threads_list="1 2 4 8 12"
full_grid=auto

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stride) stride="${2:?--stride requires a value}"; shift 2 ;;
    --repeats) repeats="${2:?--repeats requires a value}"; shift 2 ;;
    --threads) threads_list="${2:?--threads requires a value}"; shift 2 ;;
    --full-grid) full_grid="${2:?--full-grid requires a value}"; shift 2 ;;
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
case "$full_grid" in
  auto|none) ;;
  *)
    if ! [[ "$full_grid" =~ ^[0-9]+$ ]] || (( full_grid < 1 )); then
      echo "ERROR: --full-grid must be auto, none, or a positive integer" >&2
      exit 2
    fi
    ;;
esac

ref_dir="$repo_root/../peggle_evolved"
level="$repo_root/fixtures/mustache/artifact/mustache.v1.json"
config="$repo_root/fixtures/mustache/config.dev.v1.json"
workloads="$repo_root/fixtures/mustache/workloads.lua"
project="$repo_root/julia/PeggleSim"
shot_bench="$repo_root/julia/PeggleSim/bin/shot_bench.jl"
julia_bin="${JULIA:-julia}"
m3_dir="$repo_root/results/m3"
raw_dir="$repo_root/results/raw"

if [[ ! -f "$ref_dir/src/levels/mustache.lua" ]]; then
  echo "ERROR: dev-tree mustache level not found at $ref_dir/src/levels/mustache.lua" >&2
  exit 1
fi
if [[ ! -f "$level" || ! -f "$config" || ! -f "$workloads" ]]; then
  echo "ERROR: missing M3 fixtures under fixtures/mustache/" >&2
  exit 1
fi

mkdir -p "$m3_dir" "$raw_dir" "$repo_root/tmp/m3"
rm -f "$repo_root/tmp/m3/full-grid-state.json"

host_label="$(hostname -s)"
nproc_val="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)"

# Cap requested thread counts at nproc and deduplicate.
capped_threads=()
for tok in ${threads_list//,/ }; do
  if ! [[ "$tok" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid thread count: $tok" >&2
    exit 2
  fi
  (( tok < 1 )) && tok=1
  if (( tok > nproc_val )); then
    echo "bench_m3: capping thread count $tok to nproc=$nproc_val"
    tok=$nproc_val
  fi
  capped_threads+=("$tok")
done
threads_sorted="$(printf '%s\n' "${capped_threads[@]}" | sort -n -u | tr '\n' ' ')"
if [[ -z "${threads_sorted// /}" ]]; then
  echo "ERROR: --threads needs at least one thread count" >&2
  exit 2
fi
# The stride-N agreement reference is the single-thread Julia run.
if ! grep -qw 1 <<< "$threads_sorted"; then
  threads_sorted="1 $threads_sorted"
fi
read -r -a thread_values <<< "$threads_sorted"

julia_version="$("$julia_bin" --version 2>/dev/null || echo unknown)"
echo "bench_m3: host=$host_label nproc=$nproc_val stride=$stride repeats=$repeats"
echo "bench_m3: threads=$threads_sorted"
echo "bench_m3: $julia_version"

# ---------------------------------------------------------------------------
# 1. Lua baseline (dev tree): timed sweep, then the raw agreement sweep.
# ---------------------------------------------------------------------------
echo "== Lua timed sweep (stride $stride, repeat $repeats, no replay serialize) =="
"$repo_root/scripts/love.sh" love "$repo_root/harness" -- \
  --sweep \
  --workloads "$workloads" \
  --workload mustache_full \
  --stride "$stride" \
  --repeat "$repeats" \
  --no-replay-serialize \
  --summary-out "$m3_dir/lua-bench" \
  --reference-dir "$ref_dir" \
  --run-id m3-lua \
  --host-label "$host_label"

echo "== Lua replay-serialization check (stride $stride, repeat 1) =="
"$repo_root/scripts/love.sh" love "$repo_root/harness" -- \
  --sweep \
  --workloads "$workloads" \
  --workload mustache_full \
  --stride "$stride" \
  --repeat 1 \
  --summary-out "$m3_dir/lua-bench-replay" \
  --reference-dir "$ref_dir" \
  --run-id m3-lua-replay \
  --host-label "$host_label"

echo "== Lua agreement sweep raw (stride $stride, repeat 1) =="
"$repo_root/scripts/love.sh" love "$repo_root/harness" -- \
  --sweep \
  --workloads "$workloads" \
  --workload mustache_full \
  --stride "$stride" \
  --repeat 1 \
  --no-replay-serialize \
  --out "$raw_dir/m3-lua-raw" \
  --summary-out "$m3_dir/lua-raw" \
  --reference-dir "$ref_dir" \
  --run-id m3-lua-raw \
  --host-label "$host_label"

# ---------------------------------------------------------------------------
# 2. Julia sweeps: one run per thread count, serial/parallel identity + alloc.
# ---------------------------------------------------------------------------
for t in "${thread_values[@]}"; do
  echo "== Julia sweep (threads $t, stride $stride) =="
  "$julia_bin" -t "$t" --project="$project" "$shot_bench" \
    --sweep \
    --level "$level" \
    --config "$config" \
    --stride "$stride" \
    --threads "$t" \
    --verify-serial \
    --alloc \
    --out "$m3_dir/julia-sweep-t$t.jsonl" \
    --summary "$m3_dir/julia-sweep-t$t.json"
done

# ---------------------------------------------------------------------------
# 3. Agreement at the timed stride (Julia t1 is the same-core reference).
# ---------------------------------------------------------------------------
echo "== Sweep agreement (stride $stride) =="
lua_ok=0
python3 "$repo_root/scripts/compare_m3_sweeps.py" \
  --lua-raw "$raw_dir/m3-lua-raw.candidates.jsonl" \
  --julia "$m3_dir/julia-sweep-t1.jsonl" \
  --stride "$stride" \
  --julia-label t1 \
  --out "$m3_dir/sweeps-compare.json" || lua_ok=$?

# ---------------------------------------------------------------------------
# 4. Full-grid agreement attempt (auto: stride 1 unless the projection is
#    slower than 20 minutes, then stride 5).
# ---------------------------------------------------------------------------
full_json=""
full_state="skipped"
if [[ "$full_grid" != "none" ]]; then
  lua_cps="$(python3 - "$m3_dir/lua-bench.summary.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    summary = json.load(handle)
rates = [w["candidates_per_second"] for w in summary["workloads"]]
print(sum(rates) / len(rates))
PY
)"
  projected="$(python3 - "$lua_cps" <<'PY'
import sys

rate = float(sys.argv[1])
print("%.1f" % (1801 / rate))
PY
)"
  threshold=1200
  if [[ "$full_grid" == "auto" ]]; then
    chosen_stride="$(python3 - "$projected" "$threshold" <<'PY'
import sys

projected, threshold = float(sys.argv[1]), float(sys.argv[2])
print(1 if projected <= threshold else 5)
PY
)"
    if [[ "$chosen_stride" == "1" ]]; then
      echo "bench_m3: full-grid projection ${projected}s <= ${threshold}s; running stride 1"
    else
      echo "bench_m3: full-grid projection ${projected}s > ${threshold}s; falling back to stride 5"
    fi
  else
    chosen_stride="$full_grid"
    echo "bench_m3: full-grid stride $chosen_stride (explicit)"
  fi

  echo "== Lua full-grid raw (stride $chosen_stride) =="
  "$repo_root/scripts/love.sh" love "$repo_root/harness" -- \
    --sweep \
    --workloads "$workloads" \
    --workload mustache_full \
    --stride "$chosen_stride" \
    --repeat 1 \
    --no-replay-serialize \
    --out "$raw_dir/m3-lua-full-raw" \
    --summary-out "$m3_dir/lua-full-raw" \
    --reference-dir "$ref_dir" \
    --run-id m3-lua-full \
    --host-label "$host_label"

  echo "== Julia full-grid sweep (stride $chosen_stride, threads 1) =="
  "$julia_bin" -t 1 --project="$project" "$shot_bench" \
    --sweep \
    --level "$level" \
    --config "$config" \
    --stride "$chosen_stride" \
    --threads 1 \
    --out "$raw_dir/m3-julia-full-t1.jsonl" \
    --summary "$m3_dir/julia-full-t1.json"

  echo "== Sweep agreement (stride $chosen_stride) =="
  full_ok=0
  python3 "$repo_root/scripts/compare_m3_sweeps.py" \
    --lua-raw "$raw_dir/m3-lua-full-raw.candidates.jsonl" \
    --julia "$raw_dir/m3-julia-full-t1.jsonl" \
    --stride "$chosen_stride" \
    --julia-label t1-full \
    --out "$m3_dir/sweeps-compare-full.json" || full_ok=$?
  if [[ -f "$m3_dir/sweeps-compare-full.json" ]]; then
    FULL_GRID_MODE="$full_grid" FULL_CHOSEN_STRIDE="$chosen_stride" \
    FULL_PROJECTED="$projected" FULL_THRESHOLD="$threshold" FULL_OK="$full_ok" \
      python3 - "$repo_root" <<'PY'
import json
import os
import sys

root = sys.argv[1]
path = os.path.join(root, "results", "m3", "sweeps-compare-full.json")
with open(path, encoding="utf-8") as handle:
    report = json.load(handle)
state = {
    "attempted": True,
    "mode": os.environ["FULL_GRID_MODE"],
    "chosen_stride": int(os.environ["FULL_CHOSEN_STRIDE"]),
    "projected_seconds": float(os.environ["FULL_PROJECTED"]),
    "threshold_seconds": float(os.environ["FULL_THRESHOLD"]),
    "clean": report["clean"],
    "candidates_compared": report["candidates_compared"],
    "coverage": report["coverage"],
    "fields_compared": report["fields_compared"],
    "unavailable_fields": report["unavailable_fields"],
    "per_field_mismatch_count": report["per_field_mismatch_count"],
    "first_divergent_candidate": report["first_divergent_candidate"],
}
with open(os.path.join(root, "tmp", "m3", "full-grid-state.json"), "w",
          encoding="utf-8") as handle:
    json.dump(state, handle)
PY
  fi
  if (( full_ok != 0 )); then
    full_state="failed"
    echo "bench_m3: WARNING: full-grid agreement found mismatches (see $m3_dir/sweeps-compare-full.json)" >&2
  else
    full_state="clean"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Combined machine-readable report.
# ---------------------------------------------------------------------------
STRIDE="$stride" REPEATS="$repeats" HOST_LABEL="$host_label" NPROC="$nproc_val" \
THREAD_LIST="$threads_sorted" FULL_MODE="$full_grid" FULL_STATE="$full_state" \
JULIA_VERSION="$julia_version" LUA_COMPARE_EXIT="$lua_ok" \
  python3 - "$repo_root" <<'PY'
import datetime
import glob
import json
import os
import re
import sys

root = sys.argv[1]
m3 = os.path.join(root, "results", "m3")
raw = os.path.join(root, "results", "raw")


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def rel(path):
    return os.path.relpath(path, root)


def mean(values):
    return sum(values) / len(values) if values else None


def phase_seconds_lua(summary, name):
    values = [w["phases"][name]["mean"] for w in summary["workloads"]
              if name in w["phases"]]
    return mean(values) / 1e6 if values else None


def phase_seconds_julia(block):
    return {name: block["phases"][name]["mean_ns"] / 1e9
            for name in ("reset", "sim", "extract")}


def steps_stats_lua(summary):
    workloads = summary["workloads"]
    return {
        "mean": mean([w["steps"]["mean"] for w in workloads]),
        "p50": mean([w["steps"]["p50"] for w in workloads]),
        "p99": mean([w["steps"]["p99"] for w in workloads]),
        "max": max(w["steps"]["max"] for w in workloads),
    }


lua = load(os.path.join(m3, "lua-bench.summary.json"))
lua_replay = load(os.path.join(m3, "lua-bench-replay.summary.json"))

lua_walls = [w["wall_seconds"] for w in lua["workloads"]]
lua_cps = [w["candidates_per_second"] for w in lua["workloads"]]
lua_sps = [w["sim_steps_per_second"] for w in lua["workloads"]]
replay_cps = [w["candidates_per_second"] for w in lua_replay["workloads"]]

lua_block = {
    "workload": lua["workloads"][0]["workload"],
    "candidates": lua["workloads"][0]["candidates"],
    "threads": 1,
    "serial_parallel_identity": None,
    "serial_parallel_identity_note": "n/a: the Lua harness is single-threaded",
    "repeat_count": lua["options"]["repeat_count"],
    "replay_serialize": lua["options"]["replay_serialize"],
    "wall_seconds_total": sum(lua_walls),
    "wall_seconds_mean_per_repeat": mean(lua_walls),
    "candidates_per_second_mean": mean(lua_cps),
    "candidates_per_second_min": min(lua_cps),
    "candidates_per_second_max": max(lua_cps),
    "steps_per_second_mean": mean(lua_sps),
    "phases_mean_seconds": {
        name: phase_seconds_lua(lua, name)
        for name in ("init", "reset", "sim", "extract", "output")
    },
    "steps_stats": steps_stats_lua(lua),
    "determinism": lua["workloads"][0]["determinism"],
    "reference_revision": lua["reference"].get("revision"),
    "cold_start_seconds": lua["cold_start"]["setup_seconds"],
    "harness_wall_seconds": lua["harness_wall_seconds"],
}
replay_note = {
    "candidates_per_second_with_serialize": mean(replay_cps),
    "candidates_per_second_without_serialize": mean(lua_cps),
    "ratio_with_over_without": (mean(replay_cps) / mean(lua_cps)
                                if mean(lua_cps) else None),
    "note": ("replay serialization is harness I/O overhead, not simulation "
             "physics; the timed sweep uses --no-replay-serialize and this is "
             "one extra repeat=1 measurement, so the ratio cannot separate a "
             "real serialization cost from run-to-run rate variation"),
}

julia_threads = []
for path in sorted(glob.glob(os.path.join(m3, "julia-sweep-t*.json")),
                   key=lambda p: int(re.search(r"t(\d+)\.json$", p).group(1))):
    summary = load(path)
    entry = {
        "threads": summary["threads"],
        "requested_threads": summary["requested_threads"],
        "repeat_count": 1,
        "repeat_note": ("single post-warmup sweep per thread count; "
                        "--verify-serial runs the serial then parallel pass"),
        "verify_serial": summary["verify_serial"],
        "serial_parallel_identical": summary["serial_parallel_identical"],
        "candidates": summary["candidates"],
        "serial": {
            "wall_seconds": summary["serial"]["wall_seconds"],
            "candidates_per_second": summary["serial"]["candidates_per_second"],
            "steps_per_second": summary["serial"]["steps_per_second"],
        } if "serial" in summary else None,
        "parallel": {
            "wall_seconds": summary["parallel"]["wall_seconds"],
            "candidates_per_second": summary["parallel"]["candidates_per_second"],
            "steps_per_second": summary["parallel"]["steps_per_second"],
            "phases_mean_seconds": phase_seconds_julia(summary["parallel"]),
        } if "parallel" in summary else None,
        "steps_stats": summary["steps"],
        "alloc": {key: value for key, value in summary["alloc"].items()
                  if key != "bytes"} if "alloc" in summary else None,
        "alloc_method": summary.get("alloc_method"),
        "summary_path": rel(path),
        "jsonl_path": rel(path + "l"),
    }
    if entry["serial"] and entry["parallel"]:
        entry["parallel_speedup_vs_serial"] = (
            entry["parallel"]["candidates_per_second"]
            / entry["serial"]["candidates_per_second"])
    julia_threads.append(entry)

single = next(entry for entry in julia_threads if entry["threads"] == 1)
single_cps = single["parallel"]["candidates_per_second"]


def agreement_block(path):
    if not os.path.isfile(path):
        return None
    report = load(path)
    return {
        "report": rel(path),
        "clean": report["clean"],
        "requested_stride": report["requested_stride"],
        "detected_stride": report["detected_stride"],
        "julia_label": report["julia_label"],
        "candidates_compared": report["candidates_compared"],
        "coverage": report["coverage"],
        "fields_compared": report["fields_compared"],
        "unavailable_fields": report["unavailable_fields"],
        "per_field_mismatch_count": report["per_field_mismatch_count"],
        "mismatch_candidates": report["mismatch_candidates"],
        "first_divergent_candidate": report["first_divergent_candidate"],
    }


full_state = os.environ["FULL_STATE"]
full_block = {"state": full_state}
full_state_path = os.path.join(root, "tmp", "m3", "full-grid-state.json")
if os.path.isfile(full_state_path):
    full_block.update(load(full_state_path))

report = {
    "format": "peggle.m3_bench_report",
    "schema_version": 1,
    "generated_utc": datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"),
    "host_label": os.environ["HOST_LABEL"],
    "nproc": int(os.environ["NPROC"]),
    "julia_version": os.environ["JULIA_VERSION"],
    "stride": int(os.environ["STRIDE"]),
    "repeats": int(os.environ["REPEATS"]),
    "threads_requested_capped": os.environ["THREAD_LIST"].split(),
    "lua": lua_block,
    "lua_replay_serialization": replay_note,
    "julia": {
        "single_thread": single,
        "threads": julia_threads,
        "alloc_method": single.get("alloc_method"),
        "alloc_note": ("allocation accounting is process-wide; it is measured "
                       "on the serial path only"),
    },
    "speedup": {
        "metric": "candidates_per_second",
        "same_core_inputs": {
            "stride": int(os.environ["STRIDE"]),
            "candidates": single["candidates"],
            "julia_threads": 1,
        },
        "lua_candidates_per_second": mean(lua_cps),
        "julia_candidates_per_second": single_cps,
        "julia_over_lua": single_cps / mean(lua_cps),
        "lua_over_julia": mean(lua_cps) / single_cps,
        "caveat": ("single-core wall-clock comparison at the same stride and "
                   "indices; rates vary between runs (Lua timed with "
                   "repeat=%s, Julia with a single post-warmup pass); treat "
                   "the ratio as indicative, not a benchmark-grade result"
                   % os.environ["REPEATS"]),
    },
    "agreement": {
        "timed_stride": agreement_block(os.path.join(m3, "sweeps-compare.json")),
        "lua_compare_exit": int(os.environ["LUA_COMPARE_EXIT"]),
    },
    "full_grid": full_block,
    "host": {
        "cpu_model": next((line.split(":", 1)[1].strip()
                           for line in open("/proc/cpuinfo", encoding="utf-8")
                           if line.startswith("model name")), None),
        "os": os.uname().sysname + " " + os.uname().release,
        "love_version": lua["host"].get("love_version"),
        "luajit": lua["host"].get("luajit"),
    },
}

out_path = os.path.join(m3, "bench-report.json")
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=2, sort_keys=True)
    handle.write("\n")
print("bench_m3: wrote %s" % rel(out_path))
PY

if (( lua_ok != 0 )); then
  echo "bench_m3: FAILED: stride-$stride agreement mismatches (see $m3_dir/sweeps-compare.json)" >&2
  exit 1
fi

echo "bench_m3: done"
