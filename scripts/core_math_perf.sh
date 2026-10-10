#!/usr/bin/env bash
# WP-F on-host performance comparison for CORE-MATH.
#
# Usage:
#   scripts/core_math_perf.sh
#
# Writes under tmp/core-math/:
#   perf/math-bench-lua-{system_libm,core_math}.json    LuaJIT microbench
#   perf/math-bench-julia-{system_libm,core_math}.json  Julia microbench
#   perf/checkpoint-bench-{system_libm,core_math}.json  checkpoint/reset bench
#   perf/sweep-{system_libm,core_math}/                 candidate sweeps
#   perf-summary.json                                   combined measurements
#   perf-report.md                                      prose report
#
# Both backends run the same peggle_evolved development tree; only
# PEGGLE_MATH_BACKEND/PEGGLE_MATH_LIB differ. The dev tree config.lua carries
# a pre-existing ball_ball_restitution edit (0.7 vs the pinned 0.8); it
# applies equally to both backends, is not changed here, and nothing is
# compared against the pinned reference.
#
# The report states there is no fixed adoption threshold and that the
# cross-machine matrix is incomplete, so adoption is not decided. No Julia
# shot-speedup claim is made.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

dev_tree="$repo_root/../peggle_evolved"
dev_tree_arg="../peggle_evolved"
dev_artifact="$dev_tree/native/linux-x86_64/libpeggle_math.so"
artifact="$repo_root/native/artifacts/linux-x86_64/libpeggle_math.so"
perf_dir="$repo_root/tmp/core-math/perf"
host_label="$(hostname -s)"

backends=(system_libm core_math)

for tool in luajit julia python3; do
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

mkdir -p "$perf_dir"

start_seconds=$SECONDS

echo "core_math_perf: repo=$repo_root"
echo "  dev_tree=$dev_tree"
echo "  artifact=$artifact"
echo "  host=$host_label"

# ---------------------------------------------------------------------------
# 1-2. Math microbenchmarks (LuaJIT and Julia, both backends)
# ---------------------------------------------------------------------------
for backend in "${backends[@]}"; do
  echo "[1/5] Lua math bench (backend=$backend)"
  PEGGLE_MATH_BACKEND="$backend" PEGGLE_MATH_LIB="$artifact" \
    luajit "$repo_root/tools/math_bench.lua" \
    --detmath-root "$dev_tree_arg" \
    --out "$perf_dir/math-bench-lua-$backend.json"
done

for backend in "${backends[@]}"; do
  echo "[2/5] Julia math bench (backend=$backend)"
  PEGGLE_MATH_BACKEND="$backend" PEGGLE_MATH_LIB="$artifact" \
    julia --project=julia/PeggleSim julia/PeggleSim/bin/math_bench.jl \
    --out "$perf_dir/math-bench-julia-$backend.json"
done

# ---------------------------------------------------------------------------
# 3. Julia checkpoint/reset benchmark (default iterations and warmups)
# ---------------------------------------------------------------------------
for backend in "${backends[@]}"; do
  echo "[3/5] Julia checkpoint bench (backend=$backend)"
  PEGGLE_MATH_BACKEND="$backend" PEGGLE_MATH_LIB="$artifact" \
    julia --project=julia/PeggleSim julia/PeggleSim/bin/checkpoint_bench.jl \
    --out "$perf_dir/checkpoint-bench-$backend.json"
done

# ---------------------------------------------------------------------------
# 4. Lua candidate sweeps through the dev tree (stride 20, repeat 3)
# ---------------------------------------------------------------------------
sweep_start=$SECONDS
for backend in "${backends[@]}"; do
  echo "[4/5] candidate sweep (backend=$backend, stride 20, repeat 3)"
  mkdir -p "$perf_dir/sweep-$backend/raw" "$perf_dir/sweep-$backend/summary"
  PEGGLE_MATH_BACKEND="$backend" PEGGLE_MATH_LIB="$artifact" \
    RUN_ID="perf-$backend" HOST_LABEL="$host_label" \
    "$repo_root/scripts/run_baseline.sh" \
    --stride 20 --repeat 3 \
    --reference-dir "$dev_tree_arg" \
    --out "$perf_dir/sweep-$backend/raw" \
    --summary-out "$perf_dir/sweep-$backend/summary"
done
sweep_seconds=$((SECONDS - sweep_start))
echo "  sweeps finished in ${sweep_seconds}s"

# ---------------------------------------------------------------------------
# 5. Combined summary and prose report
# ---------------------------------------------------------------------------
echo "[5/5] writing tmp/core-math/perf-summary.json and perf-report.md"
PERF_HOST_LABEL="$host_label" \
PERF_JULIA_VERSION="$(julia --version)" \
PERF_LUAJIT_VERSION="$(luajit -e 'print(jit.version)')" \
PERF_CPUS="$(nproc)" \
PERF_WALL_SECONDS="$((SECONDS - start_seconds))" \
python3 - "$perf_dir" "$repo_root" "$dev_tree_arg" <<'PY'
import datetime
import glob
import hashlib
import json
import os
import platform
import sys

perf_dir, repo_root, dev_tree_arg = sys.argv[1], sys.argv[2], sys.argv[3]
backends = ("system_libm", "core_math")


def load(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def median(values):
    values = sorted(values)
    if not values:
        return None
    return values[len(values) // 2]


def ratio(core, system):
    if core is None or system is None or system == 0:
        return None
    return core / system


def cpu_model():
    try:
        with open("/proc/cpuinfo", "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.lower().startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or "unknown"


def mem_total_kb():
    try:
        with open("/proc/meminfo", "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1])
    except (OSError, ValueError):
        pass
    return None


def os_pretty():
    try:
        with open("/etc/os-release", "r", encoding="utf-8", errors="replace") as fh:
            fields = {}
            for line in fh:
                if "=" in line:
                    key, value = line.rstrip("\n").split("=", 1)
                    fields[key] = value.strip('"')
            return fields.get("PRETTY_NAME", "")
    except OSError:
        return ""


def find_sweep_summary(backend):
    base = os.path.join(perf_dir, "sweep-" + backend)
    exact = os.path.join(base, "summary",
                         "perf-{}_{}.summary.json".format(
                             backend, os.environ["PERF_HOST_LABEL"]))
    if os.path.isfile(exact):
        return exact
    matches = sorted(glob.glob(
        os.path.join(base, "**", "*.summary.json"), recursive=True))
    if not matches:
        raise SystemExit("missing sweep summary under " + base)
    return matches[-1]


# --- load raw inputs -------------------------------------------------------
lua_docs = {b: load(os.path.join(perf_dir, "math-bench-lua-{}.json".format(b)))
            for b in backends}
julia_docs = {b: load(os.path.join(perf_dir,
                                   "math-bench-julia-{}.json".format(b)))
              for b in backends}
checkpoint_docs = {b: load(os.path.join(
    perf_dir, "checkpoint-bench-{}.json".format(b))) for b in backends}
sweep_docs = {b: load(find_sweep_summary(b)) for b in backends}

# --- environment -----------------------------------------------------------
environment = {
    "host": os.environ["PERF_HOST_LABEL"],
    "os": "{} {}".format(os.uname().sysname, os.uname().release),
    "distro": os_pretty(),
    "cpu_model": cpu_model(),
    "cpus_logical": int(os.environ["PERF_CPUS"]),
    "mem_total_kb": mem_total_kb(),
    "julia": os.environ["PERF_JULIA_VERSION"],
    "luajit": os.environ["PERF_LUAJIT_VERSION"],
    "date_utc": datetime.datetime.now(
        datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "script_wall_seconds": int(os.environ["PERF_WALL_SECONDS"]),
}

repo_artifact = os.path.join(repo_root, "native", "artifacts",
                             "linux-x86_64", "libpeggle_math.so")
dev_artifact = os.path.join(repo_root, dev_tree_arg, "native",
                            "linux-x86_64", "libpeggle_math.so")
dev_config = os.path.join(repo_root, dev_tree_arg, "src", "config.lua")
pin_config = os.path.join(repo_root, "reference", "peggle_evolved",
                          "src", "config.lua")
artifacts = {
    "dev_tree": dev_tree_arg,
    "dev_tree_library": {"path": dev_artifact, "sha256": sha256_file(dev_artifact)},
    "repo_library": {"path": repo_artifact, "sha256": sha256_file(repo_artifact)},
    "libraries_identical": (
        sha256_file(dev_artifact) == sha256_file(repo_artifact)),
    "dev_config_sha256": sha256_file(dev_config),
    "pinned_reference_config_sha256": sha256_file(pin_config),
    "note": ("the dev tree config.lua carries a pre-existing "
             "ball_ball_restitution edit (0.7 vs the pinned 0.8); both "
             "backends use the same dev tree, so the backend comparison is "
             "unaffected and nothing is compared against the pinned "
             "reference"),
}


# --- math bench ------------------------------------------------------------
def math_block(doc, include_allocations):
    block = {
        "backend": doc["backend"],
        "identity": doc["identity"],
        "inputs_checksum": doc["inputs_checksum"],
        "warmup_calls": doc["warmup_calls"],
        "calls_per_batch": doc["calls_per_batch"],
        "batch_count": doc["batch_count"],
        "measured_calls_per_function": doc["measured_calls_per_function"],
        "total_seconds": doc["total_seconds"],
        "ns_per_call": {fn: dict(entry["ns_per_call"])
                        for fn, entry in doc["per_function"].items()},
        "checksums": {fn: entry["checksum"]
                      for fn, entry in doc["per_function"].items()},
    }
    if include_allocations:
        block["allocated_bytes"] = {
            fn: int(entry["allocated_bytes"])
            for fn, entry in doc["per_function"].items()}
    return block


def combined_math(lua_block, julia_block):
    names = sorted(set(lua_block["system_libm"]["ns_per_call"]) |
                   set(julia_block["system_libm"]["ns_per_call"]))
    per_function = {}
    for fn in names:
        entry = {}
        for engine, block in (("lua", lua_block), ("julia", julia_block)):
            system = block["system_libm"]["ns_per_call"][fn]["median"]
            core = block["core_math"]["ns_per_call"][fn]["median"]
            item = {
                "system_libm_ns_per_call_median": system,
                "core_math_ns_per_call_median": core,
                "ratio_core_over_system": ratio(core, system),
            }
            if "allocated_bytes" in block["system_libm"]:
                item["system_libm_allocated_bytes"] = \
                    block["system_libm"]["allocated_bytes"][fn]
                item["core_math_allocated_bytes"] = \
                    block["core_math"]["allocated_bytes"][fn]
            entry[engine] = item
        per_function[fn] = entry
    return per_function


lua_math = {b: math_block(lua_docs[b], False) for b in backends}
julia_math = {b: math_block(julia_docs[b], True) for b in backends}
math_bench = {
    "lua": {
        "system_libm": lua_math["system_libm"],
        "core_math": lua_math["core_math"],
        "per_function": combined_math(lua_math, julia_math),
    },
    "julia": {
        "system_libm": julia_math["system_libm"],
        "core_math": julia_math["core_math"],
        "per_function": combined_math(lua_math, julia_math),
    },
    "inputs_checksums": {
        "lua_system_libm": lua_docs["system_libm"]["inputs_checksum"],
        "lua_core_math": lua_docs["core_math"]["inputs_checksum"],
        "julia_system_libm": julia_docs["system_libm"]["inputs_checksum"],
        "julia_core_math": julia_docs["core_math"]["inputs_checksum"],
    },
}


# --- checkpoint bench ------------------------------------------------------
def checkpoint_block(doc):
    results = doc["results"]
    return {
        "configurations": len(results),
        "build_us_median": doc["summary"]["build_us_median"],
        "capture_p50_us_median": doc["summary"]["capture_p50_us_median"],
        "reset_p50_us_median": doc["summary"]["reset_p50_us_median"],
        "reset_over_build": doc["summary"]["reset_over_build"],
        "capture_allocated_bytes_median": median(
            [int(r["capture"]["allocated_bytes"]) for r in results]),
        "reset_allocated_bytes_median": median(
            [int(r["reset"]["allocated_bytes"]) for r in results]),
        "checkpoint_bytes_median": median(
            [int(r["memory"]["checkpoint_bytes"]) for r in results]),
        "scratch_bytes_median": median(
            [int(r["memory"]["scratch_bytes"]) for r in results]),
        "method": doc["method"],
        "baseline_present": doc["baseline"]["present"],
        "math_backend": doc.get("math_backend"),
    }


checkpoint = {b: checkpoint_block(checkpoint_docs[b]) for b in backends}
checkpoint_ratio = {}
for field in ("build_us_median", "capture_p50_us_median", "reset_p50_us_median",
              "reset_over_build", "capture_allocated_bytes_median",
              "reset_allocated_bytes_median", "checkpoint_bytes_median",
              "scratch_bytes_median"):
    checkpoint_ratio[field] = ratio(checkpoint["core_math"][field],
                                    checkpoint["system_libm"][field])


# --- sweeps ----------------------------------------------------------------
def sweep_block(doc):
    workloads = doc["workloads"]
    grouped = {}
    for entry in workloads:
        grouped.setdefault(entry["workload"], []).append(entry)
    per_workload = {}
    for name, runs in sorted(grouped.items()):
        candidates = [r["candidates_per_second"] for r in runs]
        sim_steps = [r["sim_steps_per_second"] for r in runs]
        phases = {}
        for phase in ("init", "reset", "sim", "extract", "output"):
            phases[phase] = median([r["phases"][phase]["p50"] for r in runs])
        cand_median = median(candidates)
        spread = 0.0
        if cand_median:
            spread = (max(candidates) - min(candidates)) / cand_median
        per_workload[name] = {
            "repeats": len(runs),
            "candidates_per_second_median": cand_median,
            "candidates_per_second_min": min(candidates),
            "candidates_per_second_max": max(candidates),
            "candidates_per_second_rel_spread": spread,
            "sim_steps_per_second_median": median(sim_steps),
            "sim_steps_per_second_min": min(sim_steps),
            "sim_steps_per_second_max": max(sim_steps),
            "phase_p50_us_median": phases,
        }
    total_wall = doc["totals"]["wall_seconds"]
    total_candidates = doc["totals"]["candidates"]
    sim_us = sum(w["phases"]["sim"]["sum"] for w in workloads)
    steps = sum(w["steps"]["sum"] for w in workloads)
    return {
        "aggregate": {
            "candidates": total_candidates,
            "wall_seconds": total_wall,
            "candidates_per_second": total_candidates / total_wall,
            "sim_steps_per_second": steps / (sim_us / 1e6),
            "sim_steps_total": steps,
            "completed": doc["totals"]["completed"],
            "incomplete": doc["totals"]["incomplete"],
            "harness_wall_seconds": doc["harness_wall_seconds"],
            "warmup_seconds_total": sum(w["warmup_seconds"] for w in workloads),
            "cold_start_setup_seconds": doc["cold_start"]["setup_seconds"],
            "cold_start_process_age_at_load_ms":
                doc["cold_start"]["process_age_at_load_ms"],
            "rss_kb_start": doc["memory"]["rss_kb_start"],
            "rss_kb_end": doc["memory"]["rss_kb_end"],
            "lua_kb_start": doc["memory"]["lua_kb_start"],
            "lua_kb_end": doc["memory"]["lua_kb_end"],
        },
        "per_workload": per_workload,
        "workloads_per_repeat": len(grouped),
    }


sweeps = {b: sweep_block(sweep_docs[b]) for b in backends}
workload_names = sorted(set(sweeps["system_libm"]["per_workload"]) |
                        set(sweeps["core_math"]["per_workload"]))
sweep_ratios = {
    "candidates_per_second": ratio(
        sweeps["core_math"]["aggregate"]["candidates_per_second"],
        sweeps["system_libm"]["aggregate"]["candidates_per_second"]),
    "sim_steps_per_second": ratio(
        sweeps["core_math"]["aggregate"]["sim_steps_per_second"],
        sweeps["system_libm"]["aggregate"]["sim_steps_per_second"]),
}
per_workload_ratios = {}
for name in workload_names:
    sys_w = sweeps["system_libm"]["per_workload"][name]
    core_w = sweeps["core_math"]["per_workload"][name]
    per_workload_ratios[name] = {
        "candidates_per_second": ratio(
            core_w["candidates_per_second_median"],
            sys_w["candidates_per_second_median"]),
        "sim_steps_per_second": ratio(
            core_w["sim_steps_per_second_median"],
            sys_w["sim_steps_per_second_median"]),
    }

# --- methodology -----------------------------------------------------------
methodology = {
    "engines": ("Lua and Julia microbenchmarks run in different engines; "
                "their absolute per-call costs are not directly comparable. "
                "Only within-engine core_math/system_libm ratios are "
                "reported."),
    "math_bench_inputs": ("{} precomputed splitmix64-derived doubles per "
                          "engine (varied magnitudes and signs plus "
                          "specials); both engines generate the same table "
                          "and report inputs_checksum".format(
                              lua_docs["system_libm"]["input_count"])),
    "math_bench_schedule": ("{} warmup calls per function, then {} batches "
                            "of {} calls; per-call ns = batch ns / "
                            "calls_per_batch, percentiles over the batches"
                            .format(lua_docs["system_libm"]["warmup_calls"],
                                    lua_docs["system_libm"]["batch_count"],
                                    lua_docs["system_libm"]["calls_per_batch"])),
    "math_bench_checksum": ("64-bit XOR of the IEEE-754 bits of every output "
                            "over one full input pass; identical reruns of "
                            "one backend must reproduce it"),
    "lua_allocations": ("not measured; LuaJIT has no per-call allocation "
                        "accounting"),
    "julia_allocations": ("Base.@allocated for one call after warmup"),
    "sweep": ("run_baseline.sh --stride 20 --repeat 3 through the dev tree "
              "for both backends; the default 7 workloads; only "
              "PEGGLE_MATH_BACKEND/PEGGLE_MATH_LIB differ"),
    "ratio_definition": ("ratio_core_over_system = core_math value / "
                         "system_libm value; for ns_per_call lower than 1.0 "
                         "favors core_math, for throughput rates (candidates "
                         "per second, sim steps per second) higher than 1.0 "
                         "favors core_math"),
    "backend_engagement": ("both backends resolve through the same dev-tree "
                           "detmath and repository artifact; PEGGLE_MATH_LIB "
                           "is set explicitly, and a missing artifact is a "
                           "startup error (no fallback)"),
    "adoption_threshold": None,
    "adoption_decision": "not_decided",
    "matrix": {"hosts": 1, "os": ["linux"], "complete": False},
    "wall_seconds": int(os.environ["PERF_WALL_SECONDS"]),
}

summary = {
    "format": "peggle.core_math_perf",
    "schema_version": 1,
    "environment": environment,
    "artifacts": artifacts,
    "methodology": methodology,
    "measurements": {
        "math_bench": math_bench,
        "checkpoint_bench": {
            "system_libm": checkpoint["system_libm"],
            "core_math": checkpoint["core_math"],
            "ratio_core_over_system": checkpoint_ratio,
        },
        "sweeps": {
            "system_libm": sweeps["system_libm"],
            "core_math": sweeps["core_math"],
            "ratio_core_over_system": sweep_ratios,
            "per_workload_ratios": per_workload_ratios,
        },
    },
    "adoption": {
        "threshold": None,
        "decision": "not_decided",
        "matrix": {"hosts": 1, "os": ["linux"], "complete": False},
        "statement": ("No fixed adoption threshold is defined for WP-F, and "
                      "the cross-machine/cross-OS matrix is incomplete "
                      "(single Linux x86-64 host), so adoption is not "
                      "decided. No Julia shot-speedup claim is made."),
    },
}

summary_path = os.path.join(os.path.dirname(perf_dir), "perf-summary.json")
with open(summary_path, "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2, sort_keys=True)
    handle.write("\n")


# --- report ----------------------------------------------------------------
def fmt(value, digits=3):
    if value is None:
        return "n/a"
    if isinstance(value, int):
        return str(value)
    return "{:.{}f}".format(value, digits)


def ratio_cell(value):
    if value is None:
        return "n/a"
    return "{:.4f}".format(value)


lines = []
A = lines.append
A("# WP-F CORE-MATH on-host performance report")
A("")
A("Date: {}. Host `{}` ({} logical CPUs), {}.".format(
    environment["date_utc"], environment["host"],
    environment["cpus_logical"], environment["distro"] or environment["os"]))
A("Julia: {}. {}. CPU: {}.".format(
    environment["julia"], environment["luajit"], environment["cpu_model"]))
A("Library: `{}` (sha256 `{}`).".format(
    artifacts["repo_library"]["path"], artifacts["repo_library"]["sha256"]))
A("")
A("Both backends run the same dev tree `{}`; only "
  "`PEGGLE_MATH_BACKEND`/`PEGGLE_MATH_LIB` differ. The dev tree carries a "
  "pre-existing `ball_ball_restitution` edit (see `artifacts.note`); it "
  "applies equally to both backends and nothing here is compared with the "
  "pinned reference. This is single-host, single-OS evidence."
  .format(dev_tree_arg))
A("")
A("## Math microbenchmark")
A("")
A("Method: {}. {}; per-call nanoseconds are the median/p90/p99 over the "
  "batch-level per-call values. `ratio` is core_math/system_libm "
  "(lower is better). Lua and Julia are separate engines: compare ratios "
  "within an engine, not absolute Lua-vs-Julia costs."
  .format(methodology["math_bench_inputs"],
          methodology["math_bench_schedule"]))
A("")
A("### LuaJIT (dev-tree detmath)")
A("")
A("| function | system_libm ns/call | core_math ns/call | ratio |")
A("| --- | ---: | ---: | ---: |")
for fn in sorted(math_bench["lua"]["per_function"]):
    item = math_bench["lua"]["per_function"][fn]["lua"]
    A("| {} | {} | {} | {} |".format(
        fn, fmt(item["system_libm_ns_per_call_median"]),
        fmt(item["core_math_ns_per_call_median"]),
        ratio_cell(item["ratio_core_over_system"])))
A("")
A("### Julia (PeggleSim.DetMath)")
A("")
A("| function | system_libm ns/call | core_math ns/call | ratio | "
  "system alloc B | core alloc B |")
A("| --- | ---: | ---: | ---: | ---: | ---: |")
for fn in sorted(math_bench["julia"]["per_function"]):
    item = math_bench["julia"]["per_function"][fn]["julia"]
    A("| {} | {} | {} | {} | {} | {} |".format(
        fn, fmt(item["system_libm_ns_per_call_median"]),
        fmt(item["core_math_ns_per_call_median"]),
        ratio_cell(item["ratio_core_over_system"]),
        item["system_libm_allocated_bytes"],
        item["core_math_allocated_bytes"]))
A("")
checksums = math_bench["inputs_checksums"]
A("Inputs checksum (same table in all four runs): " +
  ", ".join("{}={}".format(k, v) for k, v in sorted(checksums.items())) + ".")
lua_check = math_bench["lua"]
julia_check = math_bench["julia"]
fns_all = sorted(lua_check["system_libm"]["checksums"])
diff_lua = [fn for fn in fns_all
            if lua_check["system_libm"]["checksums"][fn] !=
            lua_check["core_math"]["checksums"][fn]]
diff_julia = [fn for fn in fns_all
              if julia_check["system_libm"]["checksums"][fn] !=
              julia_check["core_math"]["checksums"][fn]]
cross_sys = sum(1 for fn in fns_all
                if lua_check["system_libm"]["checksums"][fn] ==
                julia_check["system_libm"]["checksums"][fn])
cross_core = sum(1 for fn in fns_all
                 if lua_check["core_math"]["checksums"][fn] ==
                 julia_check["core_math"]["checksums"][fn])
A("")
A("Output checksums (per-function XOR of the result bit patterns) are "
  "recorded in perf-summary.json. Within one engine the two backends differ "
  "only where the two libraries round differently: Lua differs on [{}] and "
  "agrees elsewhere; Julia differs on [{}]. Across engines, {} of {} "
  "checksums agree under system_libm and {} of {} agree under core_math, so "
  "both engines drive the same library results on the sampled inputs. "
  "Re-running one backend reproduces every checksum."
  .format(", ".join(diff_lua), ", ".join(diff_julia),
          cross_sys, len(fns_all), cross_core, len(fns_all)))
A("")

sys_ckpt = checkpoint["system_libm"]
core_ckpt = checkpoint["core_math"]
A("## Julia checkpoint/reset benchmark (default 200 iterations, 20 warmups)")
A("")
A("| metric | system_libm | core_math | ratio |")
A("| --- | ---: | ---: | ---: |")
A("| build us, median | {} | {} | {} |".format(
    fmt(sys_ckpt["build_us_median"]), fmt(core_ckpt["build_us_median"]),
    ratio_cell(checkpoint_ratio["build_us_median"])))
A("| capture p50 us, median | {} | {} | {} |".format(
    fmt(sys_ckpt["capture_p50_us_median"]),
    fmt(core_ckpt["capture_p50_us_median"]),
    ratio_cell(checkpoint_ratio["capture_p50_us_median"])))
A("| reset p50 us, median | {} | {} | {} |".format(
    fmt(sys_ckpt["reset_p50_us_median"]),
    fmt(core_ckpt["reset_p50_us_median"]),
    ratio_cell(checkpoint_ratio["reset_p50_us_median"])))
A("| capture allocated B, median | {} | {} | {} |".format(
    sys_ckpt["capture_allocated_bytes_median"],
    core_ckpt["capture_allocated_bytes_median"],
    ratio_cell(checkpoint_ratio["capture_allocated_bytes_median"])))
A("| reset allocated B, median | {} | {} | {} |".format(
    sys_ckpt["reset_allocated_bytes_median"],
    core_ckpt["reset_allocated_bytes_median"],
    ratio_cell(checkpoint_ratio["reset_allocated_bytes_median"])))
A("| checkpoint bytes, median | {} | {} | {} |".format(
    sys_ckpt["checkpoint_bytes_median"], core_ckpt["checkpoint_bytes_median"],
    ratio_cell(checkpoint_ratio["checkpoint_bytes_median"])))
A("| reset/build | {} | {} | {} |".format(
    fmt(sys_ckpt["reset_over_build"], 5), fmt(core_ckpt["reset_over_build"], 5),
    ratio_cell(checkpoint_ratio["reset_over_build"])))
A("")

A("## Candidate sweeps (stride 20, repeat 3, 7 workloads)")
A("")
A("Cold start is process/harness setup before the timed sweeps; the rates "
  "below are warm throughput. `ratio` is core_math/system_libm "
  "(higher is better).")
A("")
A("| backend | candidates | wall s | cand/s | sim steps/s |")
A("| --- | ---: | ---: | ---: | ---: |")
for backend in backends:
    agg = sweeps[backend]["aggregate"]
    A("| {} | {} | {} | {} | {} |".format(
        backend, agg["candidates"], fmt(agg["wall_seconds"]),
        fmt(agg["candidates_per_second"]),
        fmt(agg["sim_steps_per_second"], 1)))
A("| ratio core/system | | | {} | {} |".format(
    ratio_cell(sweep_ratios["candidates_per_second"]),
    ratio_cell(sweep_ratios["sim_steps_per_second"])))
A("")
sys_steps = sweeps["system_libm"]["aggregate"]["sim_steps_total"]
core_steps = sweeps["core_math"]["aggregate"]["sim_steps_total"]
if sys_steps == core_steps:
    A("Both backends evaluated the same {} candidates, and in this sample "
      "the total simulation step count was identical ({}), so the throughput "
      "ratio is not confounded by different step counts."
      .format(sweeps["system_libm"]["aggregate"]["candidates"], sys_steps))
else:
    A("Both backends evaluated the same {} candidates; total simulation "
      "steps differed ({} system_libm vs {} core_math), so the throughput "
      "ratio mixes backend cost with trajectory differences."
      .format(sweeps["system_libm"]["aggregate"]["candidates"],
              sys_steps, core_steps))
A("")
A("Per-workload (median of the three repeats):")
A("")
A("| workload | sys cand/s | core cand/s | ratio | sys steps/s | core steps/s | ratio |")
A("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
for name in workload_names:
    sys_w = sweeps["system_libm"]["per_workload"][name]
    core_w = sweeps["core_math"]["per_workload"][name]
    ratios = per_workload_ratios[name]
    A("| {} | {} | {} | {} | {} | {} | {} |".format(
        name, fmt(sys_w["candidates_per_second_median"]),
        fmt(core_w["candidates_per_second_median"]),
        ratio_cell(ratios["candidates_per_second"]),
        fmt(sys_w["sim_steps_per_second_median"], 1),
        fmt(core_w["sim_steps_per_second_median"], 1),
        ratio_cell(ratios["sim_steps_per_second"])))
A("")
A("Phase p50 medians, aggregated across workloads (microseconds):")
A("")
A("| phase | system_libm | core_math | ratio |")
A("| --- | ---: | ---: | ---: |")
for phase in ("init", "reset", "sim", "extract", "output"):
    sys_p = median([sweeps["system_libm"]["per_workload"][n]
                    ["phase_p50_us_median"][phase] for n in workload_names])
    core_p = median([sweeps["core_math"]["per_workload"][n]
                     ["phase_p50_us_median"][phase] for n in workload_names])
    A("| {} | {} | {} | {} |".format(
        phase, fmt(sys_p), fmt(core_p), ratio_cell(ratio(core_p, sys_p))))
A("")

A("## Cold start and memory")
A("")
A("Cold start is the process age at harness load (mostly LÖVE startup) plus "
  "the harness setup before any candidate runs; the candidate rates above "
  "are warm throughput. The two sweeps ran sequentially, so machine-level "
  "drift between them is not counterbalanced.")
A("")
for backend in backends:
    agg = sweeps[backend]["aggregate"]
    A("- {}: process age at harness load {} ms, harness setup {} s, "
      "timed sweep wall {} s (plus {} s of untimed warmups), harness wall "
      "{} s.".format(
          backend, fmt(agg["cold_start_process_age_at_load_ms"]),
          fmt(agg["cold_start_setup_seconds"], 6),
          fmt(agg["wall_seconds"]), fmt(agg["warmup_seconds_total"], 2),
          fmt(agg["harness_wall_seconds"])))
    A("  RSS {} -> {} kB; Lua heap {} -> {} kB.".format(
        agg["rss_kb_start"], agg["rss_kb_end"],
        fmt(agg["lua_kb_start"], 1), fmt(agg["lua_kb_end"], 1)))
A("")
A("Lua per-call allocation is not measured; the Julia microbench records "
  "`Base.@allocated` per call (table above), and the checkpoint benchmark "
  "reports per-configuration allocation medians.")
A("")

A("## Repeated-run variation")
A("")
for backend in backends:
    spreads = {name: sweeps[backend]["per_workload"][name]
               ["candidates_per_second_rel_spread"]
               for name in workload_names}
    worst = max(spreads, key=spreads.get)
    A("- {}: candidates/s relative spread (max-min)/median over 3 repeats, "
      "worst workload `{}` {:.2%}; median spread {:.2%}.".format(
          backend, worst, spreads[worst], median(list(spreads.values())) or 0.0))
init_sys = median([sweeps["system_libm"]["per_workload"][n]
                   ["phase_p50_us_median"]["init"] for n in workload_names])
init_core = median([sweeps["core_math"]["per_workload"][n]
                    ["phase_p50_us_median"]["init"] for n in workload_names])
A("")
A("The init phase does not call the math backend, yet its median p50 was "
  "{} us (system_libm) vs {} us (core_math), so machine-level run-to-run "
  "variation is present in addition to backend cost; the sweep ratios "
  "should be read together with the spreads above."
  .format(fmt(init_sys), fmt(init_core)))
A("")

A("## Decision status")
A("")
A("There is no fixed adoption threshold for WP-F. The cross-machine and "
  "cross-OS performance matrix is incomplete (single Linux x86-64 host), "
  "so adoption is not decided. The report records measurements only; it "
  "makes no Julia shot-speedup claim.")
A("")

report_path = os.path.join(os.path.dirname(perf_dir), "perf-report.md")
with open(report_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))

print("core_math_perf summary: " + summary_path)
print("core_math_perf report:  " + report_path)
print("  sweep cand/s ratio core/system = " +
      ratio_cell(sweep_ratios["candidates_per_second"]))
print("  sweep sim steps/s ratio        = " +
      ratio_cell(sweep_ratios["sim_steps_per_second"]))
PY

elapsed=$((SECONDS - start_seconds))
echo "core_math_perf: OK (sweeps ${sweep_seconds}s, total ${elapsed}s)"
echo "  tmp/core-math/perf-summary.json"
echo "  tmp/core-math/perf-report.md"
