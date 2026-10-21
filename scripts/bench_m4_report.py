#!/usr/bin/env python3
"""Aggregate M4 benchmark artifacts into ``results/m4/bench-report.json``.

The M4 performance gate measures the seven representative workloads from
``harness/workloads.lua``: the Lua reference harness (pinned tree), the Julia
shot engine at 1..N threads, allocations, peak process memory, and one
tracing-on-vs-off diagnostic run.  ``scripts/bench_m4.sh`` writes the raw
artifacts and a run journal; this script is the stdlib-only aggregator that
reads them and emits one canonical JSON report (sorted keys, indent 2, one
trailing newline).

It computes the cross-repeat percentiles itself (nearest-rank, the same rule
as the Julia ``_candidate_stats`` helper) and derives per-candidate latency
from the engine summaries:

* Lua: ``workloads[].phases.total`` in microseconds, one entry per repeat.
* Julia: ``serial``/``parallel`` ``phases.{reset,sim,extract}`` in nanoseconds
  summed per candidate.  The shot summary does not carry a per-phase max, so
  Julia latency ``max_ms`` is ``null`` (reported honestly, not estimated).

Peak memory comes from the per-run measurement JSON written by
``scripts/bench_process.py`` (GNU ``time -v`` when present, otherwise the
kernel's ru_maxrss high-water mark).  Diagnostic trace bytes/step come from
the sum of the per-candidate trace file sizes divided by the traced rows'
total steps.

Usage:
  scripts/bench_m4_report.py --repo-root DIR --journal PATH --out PATH \
      --stride 20 --repeats 2 --threads "1 2 4 8 12" \
      --workloads "id1 id2 ..." --host-label NAME --nproc 12 \
      --julia-version "julia ..." [--git-head SHA] [--git-dirty 0|1] \
      [--out-dir results/m4] [--raw-dir results/raw] \
      [--diagnostic-workload ID]

Exit status: 0 iff every requested run succeeded and the report was written;
1 if a measurement is missing/failed; 2 on bad usage or an unreadable journal.
"""

import argparse
import datetime
import hashlib
import json
import math
import os
import re
import sys

REPORT_FORMAT = "peggle.m4_bench_report"
SCHEMA_VERSION = 1

WORKLOAD_ORDER = (
    "overhead_static_2p",
    "circles_small",
    "circles_mixed",
    "lines_rect_annular",
    "annular_dense",
    "annular_dense_multi3",
    "lines_rect_annular_multi3",
)

# Fallback catalog (id -> level/balls/group) used only to label a workload when
# its Lua summary is unreadable.  scripts/bench_m4.sh verifies the embedded map
# against harness/workloads.lua before running, so this cannot drift silently.
WORKLOAD_CATALOG = {
    "overhead_static_2p": {"level": "long_shot", "balls": 1, "group": "overhead"},
    "circles_small": {"level": "circle_level", "balls": 1, "group": "circles"},
    "circles_mixed": {"level": "off_the_wall", "balls": 1, "group": "circles"},
    "lines_rect_annular": {"level": "slide", "balls": 1, "group": "rectangles"},
    "annular_dense": {"level": "squiggly_circle", "balls": 1, "group": "annular"},
    "annular_dense_multi3": {"level": "squiggly_circle", "balls": 3, "group": "multiball"},
    "lines_rect_annular_multi3": {"level": "slide", "balls": 3, "group": "multiball"},
}


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle), None
    except OSError as exc:
        return None, "cannot read %s: %s" % (display_path(path), exc)
    except ValueError as exc:
        return None, "invalid JSON in %s: %s" % (display_path(path), exc)


_REPO_ROOT_FOR_DISPLAY = None


def display_path(path):
    if path is None:
        return None
    absolute = os.path.abspath(path)
    root = _REPO_ROOT_FOR_DISPLAY
    if root is None:
        return absolute
    if absolute == root:
        return "."
    prefix = root + os.sep
    if absolute.startswith(prefix):
        return os.path.relpath(absolute, root)
    return absolute


def sha256_file(path):
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
    except OSError:
        return None
    return digest.hexdigest()


def percentile(sorted_values, quantile):
    if not sorted_values:
        return None
    rank = int(math.ceil(quantile * len(sorted_values)))
    rank = max(1, min(rank, len(sorted_values)))
    return sorted_values[rank - 1]


def stats(values, ndigits=6):
    """mean/p50/p99/min/max with nearest-rank percentiles."""
    items = [float(value) for value in values if value is not None]
    if not items:
        return {
            "count": 0,
            "mean": None,
            "p50": None,
            "p99": None,
            "min": None,
            "max": None,
        }
    ordered = sorted(items)
    return {
        "count": len(items),
        "mean": round(sum(items) / len(items), ndigits),
        "p50": round(percentile(ordered, 0.50), ndigits),
        "p99": round(percentile(ordered, 0.99), ndigits),
        "min": round(ordered[0], ndigits),
        "max": round(ordered[-1], ndigits),
    }


def split_list(text):
    return [item for item in re.split(r"[,\s]+", (text or "").strip()) if item]


def round_or_none(value, ndigits):
    return None if value is None else round(float(value), ndigits)


def safe_ratio(numerator, denominator):
    if numerator is None or denominator in (None, 0):
        return None
    return round(float(numerator) / float(denominator), 6)


# ---------------------------------------------------------------------------
# Journal
# ---------------------------------------------------------------------------

def read_journal(path):
    """Parse the tab-separated journal written by scripts/bench_m4.sh.

    Record layouts (key first, then kind):
      lua:<id>       lua     <id> <status> <summary> <raw> <time_json> <repeats>
      compare:<id>   compare <id> <status> <lua_raw> <julia_raw> <report>
      julia:<id>:t<T> julia  <id> <T> <status> <summary> <raw> <time_json>
      diag:<phase>   diag    <id> <phase> <status> <summary> <raw> <time_json> <trace_dir>
    """
    records = {
        "lua": {},
        "julia": {},
        "compare": {},
        "diag": {},
    }
    errors = []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.readlines()
    except OSError as exc:
        raise RuntimeError("cannot read journal %s: %s" % (path, exc))

    for line_number, line in enumerate(lines, start=1):
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        try:
            key, kind = parts[0], parts[1]
            if kind == "lua":
                records["lua"][parts[2]] = {
                    "key": key,
                    "id": parts[2],
                    "status": int(parts[3]),
                    "summary": parts[4],
                    "raw": parts[5],
                    "time_json": parts[6],
                    "repeats": int(parts[7]),
                }
            elif kind == "compare":
                records["compare"][parts[2]] = {
                    "key": key,
                    "status": int(parts[3]),
                    "lua_raw": parts[4],
                    "julia_raw": parts[5],
                    "report": parts[6],
                }
            elif kind == "julia":
                thread_count = int(parts[3])
                records["julia"].setdefault(parts[2], {})[thread_count] = {
                    "key": key,
                    "id": parts[2],
                    "threads": thread_count,
                    "status": int(parts[4]),
                    "summary": parts[5],
                    "raw": parts[6],
                    "time_json": parts[7],
                }
            elif kind == "diag":
                records["diag"][parts[3]] = {
                    "key": key,
                    "id": parts[2],
                    "phase": parts[3],
                    "status": int(parts[4]),
                    "summary": parts[5],
                    "raw": parts[6],
                    "time_json": parts[7],
                    "trace_dir": parts[8] if len(parts) > 8 and parts[8] != "-" else None,
                }
            else:
                errors.append("line %d: unknown journal kind %r" % (line_number, kind))
        except (IndexError, ValueError):
            errors.append("line %d: malformed journal line: %r" % (line_number, line))
    if errors:
        raise RuntimeError("; ".join(errors))
    return records


# ---------------------------------------------------------------------------
# Per-run readers
# ---------------------------------------------------------------------------

def read_process_measurement(path):
    record = {
        "peak_rss_kb": None,
        "peak_rss_mb": None,
        "peak_memory_method": None,
        "process_wall_seconds": None,
        "process_exit_code": None,
        "measurement_path": display_path(path),
    }
    if not path or not os.path.isfile(path):
        return record
    doc, error = load_json(path)
    if error or not isinstance(doc, dict):
        record["measurement_error"] = error or "measurement is not an object"
        return record
    record.update({
        "peak_rss_kb": doc.get("peak_rss_kb"),
        "peak_rss_mb": doc.get("peak_rss_mb"),
        "peak_memory_method": doc.get("method"),
        "peak_memory_method_note": doc.get("method_note"),
        "process_wall_seconds": doc.get("wall_seconds"),
        "process_exit_code": doc.get("exit_code"),
    })
    return record


def julia_latency(block):
    """Per-candidate latency in ms derived from the three timed phases."""
    phases = (block or {}).get("phases") or {}
    names = ("reset", "sim", "extract")

    def total(key):
        values = [phases[name][key] for name in names
                  if name in phases and key in phases[name]]
        if not values:
            return None
        return sum(float(value) for value in values)

    mean_ns = total("mean_ns")
    p50_ns = total("p50_ns")
    p99_ns = total("p99_ns")
    return {
        "mean_ms": round_or_none(mean_ns / 1e6 if mean_ns is not None else None, 6),
        "p50_ms": round_or_none(p50_ns / 1e6 if p50_ns is not None else None, 6),
        "p99_ms": round_or_none(p99_ns / 1e6 if p99_ns is not None else None, 6),
        "max_ms": None,
        "max_available": False,
        "basis": ("sum of phases.reset+sim+extract "
                  "(mean_ns/p50_ns/p99_ns); no per-phase max in the summary"),
    }


def julia_phase_ms(block):
    phases = (block or {}).get("phases") or {}
    return {
        name: round_or_none(phases[name]["mean_ns"] / 1e6, 6)
        for name in ("reset", "sim", "extract")
        if name in phases and "mean_ns" in phases[name]
    }


def julia_run_block(block):
    if not isinstance(block, dict):
        return None
    result = {
        "wall_seconds": block.get("wall_seconds"),
        "candidates_per_second": block.get("candidates_per_second"),
        "steps_per_second": block.get("steps_per_second"),
        "steps_stats": block.get("steps"),
        "per_candidate_latency_ms": julia_latency(block),
        "phases_mean_ms": julia_phase_ms(block),
    }
    result["phase_stats_ns"] = block.get("phases")
    return result


def lua_workload_latency(workloads):
    totals = [workload["phases"]["total"] for workload in workloads
              if isinstance(workload.get("phases"), dict)
              and "total" in workload["phases"]]
    return {
        "mean_ms": round_or_none(
            sum(float(item["mean"]) for item in totals) / len(totals) / 1000.0, 6)
        if totals else None,
        "p50_ms": round_or_none(
            sum(float(item["p50"]) for item in totals) / len(totals) / 1000.0, 6)
        if totals else None,
        "p99_ms": round_or_none(
            sum(float(item["p99"]) for item in totals) / len(totals) / 1000.0, 6)
        if totals else None,
        "max_ms": round_or_none(
            max(float(item["max"]) for item in totals) / 1000.0, 6)
        if totals else None,
        "max_available": bool(totals),
        "basis": ("phases.total (init+reset+sim+extract+output) microseconds; "
                  "per-repeat summary quantiles averaged across repeats"),
    }


def lua_phase_ms(workloads):
    result = {}
    for name in ("init", "reset", "sim", "extract", "output", "total"):
        values = [workload["phases"][name]["mean"] for workload in workloads
                  if isinstance(workload.get("phases"), dict)
                  and name in workload["phases"]]
        result[name] = (round_or_none(sum(values) / len(values) / 1000.0, 6)
                        if values else None)
    return result


def lua_steps_stats(workloads):
    steps = [workload["steps"] for workload in workloads
             if isinstance(workload.get("steps"), dict)]
    if not steps:
        return None
    return {
        "mean": round(sum(float(item["mean"]) for item in steps) / len(steps), 6),
        "p50": round(sum(float(item["p50"]) for item in steps) / len(steps), 6),
        "p99": round(sum(float(item["p99"]) for item in steps) / len(steps), 6),
        "max": max(int(item["max"]) for item in steps),
    }


def build_lua_block(record, expected_candidates):
    block = {
        "status": "missing",
        "summary": display_path(record["summary"]) if record else None,
        "raw": display_path(record["raw"]) if record else None,
    }
    if record is None:
        block["reasons"] = ["journal has no Lua run for this workload"]
        return block
    if record["status"] != 0:
        block["status"] = "failed"
        block["reasons"] = ["Lua harness exited %d" % record["status"]]
        return block
    summary, error = load_json(record["summary"])
    if error or not isinstance(summary, dict):
        block["status"] = "failed"
        block["reasons"] = [error or "Lua summary is not an object"]
        return block
    workloads = summary.get("workloads") or []
    if not workloads:
        block["status"] = "failed"
        block["reasons"] = ["Lua summary has no workloads[]"]
        return block

    cps = [workload.get("candidates_per_second") for workload in workloads]
    sps = [workload.get("sim_steps_per_second") for workload in workloads]
    walls = [workload.get("wall_seconds") for workload in workloads]
    first = workloads[0]
    options = summary.get("options") or {}
    process = read_process_measurement(record["time_json"])

    block.update({
        "status": "ok",
        "repeats": len(workloads),
        "candidates": first.get("candidates"),
        "candidates_expected": expected_candidates,
        "candidates_match": first.get("candidates") == expected_candidates,
        "balls": first.get("balls"),
        "repeat_count_requested": options.get("repeat_count"),
        "stride_requested": options.get("stride"),
        "replay_serialize": options.get("replay_serialize"),
        "warmup": options.get("warmup"),
        "max_steps": options.get("max_steps"),
        "wall_seconds_total": round(sum(walls), 6),
        "wall_seconds_per_repeat": stats(walls),
        "candidates_per_second": stats(cps),
        "steps_per_second": stats(sps),
        "per_candidate_latency_ms": lua_workload_latency(workloads),
        "phases_mean_ms": lua_phase_ms(workloads),
        "steps_stats": lua_steps_stats(workloads),
        "determinism": first.get("determinism"),
        "completed": first.get("completed"),
        "incomplete": first.get("incomplete"),
        "host": summary.get("host"),
        "reference": summary.get("reference"),
        "cold_start_seconds": (summary.get("cold_start") or {}).get("setup_seconds"),
        "harness_wall_seconds": summary.get("harness_wall_seconds"),
        "run_date_utc": summary.get("date_utc"),
    })
    block.update(process)
    return block


def build_julia_thread_block(record, expected_candidates, thread_count):
    entry = {
        "status": "missing",
        "requested_threads": record["threads"] if record else thread_count,
        "summary": display_path(record["summary"]) if record else None,
        "raw": display_path(record["raw"]) if record else None,
        "reasons": [],
    }
    if record is None:
        entry["reasons"].append("journal has no Julia run for this thread count")
        return entry
    if record["status"] != 0:
        entry["status"] = "failed"
        entry["reasons"].append("Julia sweep exited %d" % record["status"])
        return entry
    summary, error = load_json(record["summary"])
    if error or not isinstance(summary, dict):
        entry["status"] = "failed"
        entry["reasons"].append(error or "Julia summary is not an object")
        return entry

    actual_threads = summary.get("threads")
    requested_threads = summary.get("requested_threads", record["threads"])
    entry.update({
        "status": "ok",
        "threads": actual_threads,
        "requested_threads": requested_threads,
        "threads_capped": (actual_threads is not None
                           and requested_threads is not None
                           and actual_threads != requested_threads),
        "candidates": summary.get("candidates"),
        "candidates_expected": expected_candidates,
        "candidates_match": summary.get("candidates") == expected_candidates,
        "balls": summary.get("balls"),
        "level": summary.get("level"),
        "max_steps": summary.get("max_steps"),
        "clearing": summary.get("clearing"),
        "verify_serial": summary.get("verify_serial"),
        "serial_parallel_identical": summary.get("serial_parallel_identical"),
        "serial": julia_run_block(summary.get("serial")),
        "parallel": julia_run_block(summary.get("parallel")),
        "primary": julia_run_block(summary),
        "alloc_method": summary.get("alloc_method"),
        "alloc": None,
        "rows_sha256": sha256_file(record["raw"]),
    })
    alloc = summary.get("alloc")
    if isinstance(alloc, dict):
        entry["alloc"] = {
            "count": alloc.get("count"),
            "total_bytes": alloc.get("total_bytes"),
            "mean_bytes": alloc.get("mean_bytes"),
            "p50_bytes": alloc.get("p50_bytes"),
            "p99_bytes": alloc.get("p99_bytes"),
            "min_bytes": alloc.get("min_bytes"),
            "max_bytes": alloc.get("max_bytes"),
        }
    entry.update(read_process_measurement(record["time_json"]))
    if not entry["candidates_match"]:
        entry["reasons"].append(
            "candidate count %r != expected %r for stride"
            % (summary.get("candidates"), expected_candidates))
    return entry


def build_agreement(compare_record, out_dir, wid):
    block = {
        "status": "missing",
        "report": display_path(compare_record["report"]) if compare_record else None,
        "note": ("stride-N Lua-vs-Julia row agreement (informational); the M4 "
                 "full-grid correctness gate is the session-1 "
                 "sweeps-compare report referenced in full_grid_parity_report"),
    }
    if compare_record is None:
        block["reasons"] = ["journal has no compare report for this workload"]
    else:
        block["comparator_exit"] = compare_record["status"]
        doc, error = load_json(compare_record["report"])
        if error or not isinstance(doc, dict):
            block["status"] = "failed"
            block["reasons"] = [error or "comparator report is not an object"]
        else:
            block.update({
                "status": "ok" if doc.get("clean") else "mismatch",
                "clean": doc.get("clean"),
                "requested_stride": doc.get("requested_stride"),
                "candidates_compared": doc.get("candidates_compared"),
                "mismatch_candidates": doc.get("mismatch_candidates"),
                "per_field_mismatch_count": doc.get("per_field_mismatch_count"),
                "first_divergent_candidate": doc.get("first_divergent_candidate"),
                "fields_compared": doc.get("fields_compared"),
                "unavailable_fields": sorted(
                    (doc.get("unavailable_fields") or {}).keys()),
                "lua_repeats": doc.get("lua_repeats"),
                "coverage": doc.get("coverage"),
            })

    parity_path = os.path.join(out_dir, "sweeps-compare-%s.json" % wid)
    parity, parity_error = load_json(parity_path) if os.path.isfile(parity_path) else (None, None)
    block["full_grid_parity_report"] = display_path(parity_path) \
        if os.path.isfile(parity_path) else None
    if isinstance(parity, dict):
        block["full_grid_parity_clean"] = parity.get("clean")
        block["full_grid_parity_candidates"] = parity.get("candidates_compared")
        block["full_grid_parity_stride"] = parity.get("requested_stride")
    else:
        block["full_grid_parity_clean"] = None
        if parity_error:
            block["full_grid_parity_error"] = parity_error
    return block


# ---------------------------------------------------------------------------
# Full-grid reference (session 1, stride 1)
# ---------------------------------------------------------------------------

def build_full_grid_entry(wid, out_dir):
    lua_path = os.path.join(out_dir, "lua-%s.summary.json" % wid)
    julia_path = os.path.join(out_dir, "julia-%s-t1.json" % wid)
    entry = {
        "stride": 1,
        "source": "session 1 (M4 parity) full grid, reused read-only",
        "lua_summary": display_path(lua_path) if os.path.isfile(lua_path) else None,
        "julia_summary": display_path(julia_path) if os.path.isfile(julia_path) else None,
        "lua": None,
        "julia_t1": None,
        "reasons": [],
    }
    if os.path.isfile(lua_path):
        doc, error = load_json(lua_path)
        if error or not isinstance(doc, dict) or not doc.get("workloads"):
            entry["reasons"].append(error or "Lua full-grid summary has no workloads[]")
        else:
            workload = doc["workloads"][0]
            options = doc.get("options") or {}
            entry["lua"] = {
                "stride": options.get("stride"),
                "repeat_count": options.get("repeat_count"),
                "candidates": workload.get("candidates"),
                "candidates_per_second": workload.get("candidates_per_second"),
                "steps_per_second": workload.get("sim_steps_per_second"),
                "wall_seconds": workload.get("wall_seconds"),
            }
    else:
        entry["reasons"].append("missing Lua full-grid summary")

    if os.path.isfile(julia_path):
        doc, error = load_json(julia_path)
        if error or not isinstance(doc, dict):
            entry["reasons"].append(error or "Julia full-grid summary is not an object")
        else:
            serial = doc.get("serial") or {}
            parallel = doc.get("parallel") or {}
            entry["julia_t1"] = {
                "candidates": doc.get("candidates"),
                "threads": doc.get("threads"),
                "requested_threads": doc.get("requested_threads"),
                "verify_serial": doc.get("verify_serial"),
                "alloc_requested": doc.get("alloc_requested"),
                "serial_candidates_per_second": serial.get("candidates_per_second"),
                "parallel_candidates_per_second": parallel.get("candidates_per_second"),
                "primary_candidates_per_second": doc.get("candidates_per_second"),
                "steps_per_second": doc.get("steps_per_second"),
                "wall_seconds": doc.get("wall_seconds"),
            }
    else:
        entry["reasons"].append("missing Julia full-grid t1 summary")

    if entry["lua"] and entry["julia_t1"]:
        lua_cps = entry["lua"].get("candidates_per_second")
        parallel_cps = entry["julia_t1"].get("parallel_candidates_per_second")
        serial_cps = entry["julia_t1"].get("serial_candidates_per_second")
        entry["julia_over_lua_parallel"] = safe_ratio(parallel_cps, lua_cps)
        entry["julia_over_lua_serial"] = safe_ratio(serial_cps, lua_cps)
    return entry


# ---------------------------------------------------------------------------
# Diagnostic (tracing on vs off)
# ---------------------------------------------------------------------------

def raw_total_steps(path):
    total = 0
    count = 0
    if not path or not os.path.isfile(path):
        return None, None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    return None, None
                total += int(row.get("steps") or 0)
                count += 1
    except OSError:
        return None, None
    return total, count


def build_diag_side(record, expected_candidates):
    side = {
        "status": "missing",
        "summary": display_path(record["summary"]) if record else None,
        "raw": display_path(record["raw"]) if record else None,
        "trace_dir": display_path(record["trace_dir"]) if record and record["trace_dir"] else None,
        "reasons": [],
    }
    if record is None:
        side["reasons"].append("no diagnostic run in journal")
        return side
    if record["status"] != 0:
        side["status"] = "failed"
        side["reasons"].append("diagnostic sweep exited %d" % record["status"])
        return side
    summary, error = load_json(record["summary"])
    if error or not isinstance(summary, dict):
        side["status"] = "failed"
        side["reasons"].append(error or "diagnostic summary is not an object")
        return side
    parallel = summary.get("parallel")
    primary_pass = "parallel" if isinstance(parallel, dict) else "serial"
    primary = parallel if isinstance(parallel, dict) else \
        (summary.get("serial") if isinstance(summary.get("serial"), dict) else summary)
    total_steps, row_count = raw_total_steps(record["raw"])
    side.update({
        "status": "ok",
        "threads": summary.get("threads"),
        "requested_threads": summary.get("requested_threads"),
        "verify_serial": summary.get("verify_serial"),
        "candidates": summary.get("candidates"),
        "candidates_expected": expected_candidates,
        "candidates_match": summary.get("candidates") == expected_candidates,
        "timed_pass": primary_pass,
        "wall_seconds": primary.get("wall_seconds") if isinstance(primary, dict) else None,
        "candidates_per_second": primary.get("candidates_per_second")
        if isinstance(primary, dict) else None,
        "steps_per_second": primary.get("steps_per_second")
        if isinstance(primary, dict) else None,
        "total_steps": total_steps,
        "row_count": row_count,
        "rows_sha256": sha256_file(record["raw"]),
    })
    side.update(read_process_measurement(record["time_json"]))
    if side["trace_dir"]:
        trace_files = []
        base = record["trace_dir"]
        if os.path.isdir(base):
            for name in sorted(os.listdir(base)):
                path = os.path.join(base, name)
                if os.path.isfile(path) and name.endswith(".jsonl"):
                    trace_files.append(path)
        total_bytes = sum(os.path.getsize(path) for path in trace_files)
        side["trace_files"] = len(trace_files)
        side["trace_bytes"] = total_bytes
        side["trace_bytes_per_step"] = (
            round(total_bytes / total_steps, 6) if total_steps else None)
        side["trace_bytes_per_candidate"] = (
            round(total_bytes / len(trace_files), 3) if trace_files else None)
        side["trace_bytes_per_step_note"] = (
            "sum of per-candidate trace file sizes / total simulated steps; "
            "each file includes a one-line header, so the marginal per-step "
            "cost is slightly below this value")
    if not side["candidates_match"]:
        side["reasons"].append(
            "candidate count %r != expected %r"
            % (summary.get("candidates"), expected_candidates))
    return side


def build_diagnostic(records, wid, expected_candidates):
    block = {
        "workload": wid,
        "enabled": wid is not None,
        "method": ("one untraced and one traced single serial Julia pass "
                   "(threads=1, no --verify-serial, no --alloc), same stride/"
                   "level/balls; timing-on is diagnostic only and is never "
                   "merged into the main workload table"),
        "stride": None,
        "threads": 1,
        "in_main_table": False,
    }
    if wid is None:
        block["reason"] = "diagnostic disabled"
        return block
    untraced = build_diag_side(records["diag"].get("untraced"), expected_candidates)
    traced = build_diag_side(records["diag"].get("traced"), expected_candidates)
    block["untraced"] = untraced
    block["traced"] = traced
    block["rows_equal"] = (
        untraced.get("rows_sha256") is not None
        and untraced.get("rows_sha256") == traced.get("rows_sha256"))
    block["rows_sha256"] = {
        "untraced": untraced.get("rows_sha256"),
        "traced": traced.get("rows_sha256"),
    }
    block["outcome_equality_check"] = (
        "sha256 of the canonical JSONL result rows; equality means tracing did "
        "not change any candidate field")
    untraced_cps = untraced.get("candidates_per_second")
    traced_cps = traced.get("candidates_per_second")
    block["overhead"] = {
        "untraced_candidates_per_second": untraced_cps,
        "traced_candidates_per_second": traced_cps,
        "candidates_per_second_ratio_traced_over_untraced":
            safe_ratio(traced_cps, untraced_cps),
        "slowdown_fraction": (
            round((untraced_cps - traced_cps) / untraced_cps, 6)
            if untraced_cps and traced_cps is not None else None),
        "traced_wall_seconds_delta": (
            round(traced["wall_seconds"] - untraced["wall_seconds"], 6)
            if traced.get("wall_seconds") is not None
            and untraced.get("wall_seconds") is not None else None),
        "process_wall_seconds_ratio": safe_ratio(
            traced.get("process_wall_seconds"),
            untraced.get("process_wall_seconds")),
    }
    block["trace_bytes_per_step"] = traced.get("trace_bytes_per_step")
    if wid == "circles_small" or wid is None:
        block["preferred_workload_note"] = (
            "circles_small is the preferred diagnostic workload: fast enough "
            "to keep the trace I/O measurable without dominating the run")
    return block


# ---------------------------------------------------------------------------
# Report assembly
# ---------------------------------------------------------------------------

def build_workload(wid, level, balls, group, records, out_dir, stride,
                   expected_candidates, thread_values):
    lua = build_lua_block(records["lua"].get(wid), expected_candidates)
    julia_threads = []
    for thread_count in thread_values:
        julia_threads.append(build_julia_thread_block(
            records["julia"].get(wid, {}).get(thread_count),
            expected_candidates, thread_count))
    julia_by_thread = {
        entry["requested_threads"]: entry for entry in julia_threads
        if entry["requested_threads"] is not None
    }

    def parallel_cps(entry):
        parallel = entry.get("parallel")
        return parallel.get("candidates_per_second") if parallel else None

    t1 = julia_by_thread.get(1)
    t1_ok = t1 is not None and t1["status"] == "ok"
    t1_parallel_cps = parallel_cps(t1) if t1_ok else None
    t1_serial_cps = ((t1.get("serial") or {}).get("candidates_per_second")
                     if t1_ok else None)

    scaling = []
    for entry in julia_threads:
        cps = parallel_cps(entry)
        threads = entry.get("threads") or entry.get("requested_threads")
        scaling.append({
            "requested_threads": entry.get("requested_threads"),
            "threads": threads,
            "threads_capped": entry.get("threads_capped"),
            "status": entry["status"],
            "candidates_per_second_parallel": cps,
            "candidates_per_second_serial":
                (entry.get("serial") or {}).get("candidates_per_second"),
            "speedup_vs_t1": safe_ratio(cps, t1_parallel_cps),
            "efficiency_vs_t1": (
                round(safe_ratio(cps, t1_parallel_cps) / threads, 6)
                if safe_ratio(cps, t1_parallel_cps) is not None and threads
                else None),
        })

    lua_cps = (lua.get("candidates_per_second") or {}).get("mean") \
        if lua["status"] == "ok" else None
    speedup = {
        "metric": "candidates_per_second",
        "lua_candidates_per_second": lua_cps,
        "julia_t1_parallel_candidates_per_second": t1_parallel_cps,
        "julia_t1_serial_candidates_per_second": t1_serial_cps,
        "julia_over_lua": safe_ratio(t1_parallel_cps, lua_cps),
        "lua_over_julia": safe_ratio(lua_cps, t1_parallel_cps),
        "julia_over_lua_serial": safe_ratio(t1_serial_cps, lua_cps),
        "same_core_basis": "Lua single-thread vs Julia t1 parallel pass",
        "caveat": ("same-host, same stride and indices, but Lua is timed with "
                   "repeat(s) while Julia is one post-warmup pass; rates vary "
                   "run to run, so treat the ratio as indicative, not "
                   "benchmark-grade"),
    }

    alloc = (t1 or {}).get("alloc") if t1_ok else None
    allocations = {
        "threads": 1,
        "summary": (t1 or {}).get("summary"),
        "method": (t1 or {}).get("alloc_method"),
        "caveat": ("allocation accounting is process-wide and measured on the "
                   "serial path only (--alloc adds an untimed serial warmup "
                   "pass)"),
    }
    if alloc:
        allocations.update(alloc)
    else:
        allocations["reasons"] = ["no alloc block in the t1 summary"]

    return {
        "workload": wid,
        "level": level,
        "balls": balls,
        "group": group,
        "stride": stride,
        "candidates_expected": expected_candidates,
        "completion_rule": "bench",
        "lua": lua,
        "julia": {
            "threads": julia_threads,
            "t1_candidates_per_second_parallel": t1_parallel_cps,
            "t1_serial_parallel_identical": (
                (t1 or {}).get("serial_parallel_identical") if t1_ok else None),
            "thread_scaling_efficiency_vs_t1": scaling,
        },
        "speedup_same_core": speedup,
        "allocations": allocations,
        "peak_memory": {
            "method": ("per-process RSS from scripts/bench_process.py: GNU "
                       "time -v when available, otherwise the kernel "
                       "ru_maxrss high-water mark; each run records "
                       "peak_memory_method"),
            "lua_rss_kb": lua.get("peak_rss_kb"),
            "julia_rss_kb": {
                str(entry.get("threads") or entry.get("requested_threads")):
                    entry.get("peak_rss_kb")
                for entry in julia_threads
            },
            "per_worker_live_estimate": None,
            "per_worker_note": ("not measured by this harness; peak RSS is "
                               "whole-process (runtime + JIT included) and is "
                               "not per-worker for threads > 1"),
        },
        "agreement": build_agreement(records["compare"].get(wid), out_dir, wid),
        "full_grid_reference": build_full_grid_entry(wid, out_dir),
    }


def main(argv=None):
    global _REPO_ROOT_FOR_DISPLAY

    parser = argparse.ArgumentParser(
        description="Aggregate M4 benchmark artifacts into bench-report.json.")
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--journal", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--stride", type=int, required=True)
    parser.add_argument("--repeats", type=int, required=True)
    parser.add_argument("--threads", required=True,
                        help="capped thread counts, space/comma separated")
    parser.add_argument("--requested-threads", default=None,
                        help="thread counts as requested before capping")
    parser.add_argument("--workloads", required=True,
                        help="workload ids, space/comma separated")
    parser.add_argument("--host-label", required=True)
    parser.add_argument("--nproc", type=int, required=True)
    parser.add_argument("--julia-version", required=True)
    parser.add_argument("--git-head", default=None)
    parser.add_argument("--git-dirty", default=None)
    parser.add_argument("--out-dir", default="results/m4")
    parser.add_argument("--raw-dir", default="results/raw")
    parser.add_argument("--diagnostic-workload", default=None)
    args = parser.parse_args(argv)

    repo_root = os.path.abspath(args.repo_root)
    _REPO_ROOT_FOR_DISPLAY = repo_root
    out_dir = args.out_dir if os.path.isabs(args.out_dir) else \
        os.path.join(repo_root, args.out_dir)
    raw_dir = args.raw_dir if os.path.isabs(args.raw_dir) else \
        os.path.join(repo_root, args.raw_dir)
    stride = args.stride
    repeats = args.repeats
    thread_values = [int(value) for value in split_list(args.threads)]
    if not thread_values:
        print("bench_m4_report: ERROR: --threads selected nothing", file=sys.stderr)
        return 2
    if stride < 1:
        print("bench_m4_report: ERROR: --stride must be >= 1", file=sys.stderr)
        return 2
    workload_ids = split_list(args.workloads)
    if not workload_ids:
        print("bench_m4_report: ERROR: --workloads selected nothing", file=sys.stderr)
        return 2
    requested_threads = ([int(value) for value in split_list(args.requested_threads)]
                         if args.requested_threads else list(thread_values))

    config, config_error = load_json(
        os.path.join(repo_root, "interchange", "config.v1.json"))
    aim_steps = 1800
    if isinstance(config, dict):
        values = config.get("values") or {}
        if isinstance(values.get("aim_discretization_steps"), int):
            aim_steps = values["aim_discretization_steps"]
    expected_candidates = aim_steps // stride + 1

    try:
        records = read_journal(args.journal)
    except RuntimeError as exc:
        print("bench_m4_report: ERROR: %s" % exc, file=sys.stderr)
        return 2

    # Workload map comes from the journal itself where possible, so the report
    # stays consistent with the run that produced the artifacts.
    workload_order = [wid for wid in WORKLOAD_ORDER if wid in workload_ids]
    workload_order += [wid for wid in workload_ids if wid not in workload_order]

    lua_host = {}
    for wid in workload_order:
        record = records["lua"].get(wid)
        if record and record["status"] == 0:
            doc, _ = load_json(record["summary"])
            if isinstance(doc, dict) and isinstance(doc.get("host"), dict):
                lua_host = doc["host"]
                break

    cpu_model = lua_host.get("cpu_model")
    if not cpu_model:
        try:
            with open("/proc/cpuinfo", "r", encoding="utf-8") as handle:
                for line in handle:
                    if line.startswith("model name"):
                        cpu_model = line.split(":", 1)[1].strip()
                        break
        except OSError:
            cpu_model = None
    kernel = lua_host.get("kernel")
    if not kernel:
        kernel = os.uname().release
    os_name = lua_host.get("os")
    if not os_name and os.path.isfile("/etc/os-release"):
        try:
            with open("/etc/os-release", "r", encoding="utf-8") as handle:
                for line in handle:
                    if line.startswith("PRETTY_NAME="):
                        os_name = line.split("=", 1)[1].strip().strip('"')
                        break
        except OSError:
            os_name = None
    mem_total_kb = lua_host.get("mem_total_kb")
    if not mem_total_kb and os.path.isfile("/proc/meminfo"):
        try:
            with open("/proc/meminfo", "r", encoding="utf-8") as handle:
                for line in handle:
                    if line.startswith("MemTotal:"):
                        mem_total_kb = int(line.split()[1])
                        break
        except (OSError, ValueError, IndexError):
            mem_total_kb = None
    host = {
        "host_label": args.host_label,
        "cpu_model": cpu_model,
        "cpu_processors": lua_host.get("cpu_processors"),
        "nproc": args.nproc,
        "kernel": kernel,
        "os": os_name,
        "mem_total_kb": mem_total_kb,
        "love_version": lua_host.get("love_version"),
        "luajit": lua_host.get("luajit"),
        "julia_version": args.julia_version,
        "git_head": args.git_head,
        "git_dirty": (None if args.git_dirty is None
                      else args.git_dirty in ("1", "true", "True")),
        "uname": " ".join(os.uname()),
    }

    workloads = {}
    failures = []
    for wid in workload_order:
        record = records["lua"].get(wid)
        level = None
        balls = None
        group = None
        if record:
            doc, _ = load_json(record["summary"])
            if isinstance(doc, dict) and doc.get("workloads"):
                first = doc["workloads"][0]
                level = first.get("level")
                balls = first.get("balls")
                group = first.get("group")
        # Fall back to the embedded catalog if a summary is unreadable:
        # level/balls/group are still needed to label the block.
        fallback = WORKLOAD_CATALOG.get(wid, {})
        if level is None:
            level = fallback.get("level", "unknown")
        if balls is None:
            balls = fallback.get("balls")
        if group is None:
            group = fallback.get("group")
        block = build_workload(wid, level, balls, group, records, out_dir,
                               stride, expected_candidates, thread_values)
        workloads[wid] = block
        if block["lua"]["status"] != "ok":
            failures.append("%s: Lua measurement %s"
                            % (wid, block["lua"]["status"]))
        for entry in block["julia"]["threads"]:
            if entry["status"] != "ok":
                failures.append("%s: Julia t%s measurement %s"
                                % (wid, entry.get("requested_threads"),
                                   entry["status"]))
        t1_entry = next((entry for entry in block["julia"]["threads"]
                         if entry.get("requested_threads") == 1), None)
        if t1_entry is not None and t1_entry["status"] == "ok" \
                and not block["julia"]["t1_serial_parallel_identical"]:
            failures.append("%s: serial/parallel rows differ" % wid)

    full_grid = {
        "source": "session 1 (M4 parity) full grid, stride 1",
        "stride": 1,
        "benchmark_stride": stride,
        "candidates_per_workload": aim_steps + 1,
        "note": ("Full-grid throughput is stride 1 from session 1; the timed "
                 "benchmark in this report is stride %d (%d candidates per "
                 "workload). Per-candidate rates and tails are not directly "
                 "comparable between stride 1 and stride %d." % (
                     stride, expected_candidates, stride)),
        "workloads": {
            wid: build_full_grid_entry(wid, out_dir) for wid in workload_order
        },
    }

    diagnostic_id = args.diagnostic_workload
    if diagnostic_id in (None, "", "none"):
        diagnostic_id = None
    diagnostic = build_diagnostic(records, diagnostic_id,
                                  expected_candidates)
    diagnostic["stride"] = stride
    if diagnostic_id and diagnostic.get("untraced", {}).get("status") != "ok":
        failures.append("diagnostic: untraced run %s"
                        % diagnostic["untraced"].get("status"))
    if diagnostic_id and diagnostic.get("traced", {}).get("status") != "ok":
        failures.append("diagnostic: traced run %s"
                        % diagnostic["traced"].get("status"))
    if diagnostic_id and not diagnostic.get("rows_equal"):
        failures.append("diagnostic: traced rows differ from untraced rows")

    caveats = [
        ("Same-core speedup compares Lua repeat-timed throughput against one "
         "post-warmup Julia pass; it is indicative, not benchmark-grade."),
        ("Julia t1 headline is the t1 parallel pass (one worker); the serial "
         "pass is reported alongside it. Thread scaling compares parallel "
         "passes at t1 versus tN."),
        ("Thread counts above nproc are capped before launch; "
         "options.threads_requested vs options.threads_capped records the "
         "difference, and each Julia entry records the summary's requested vs "
         "actual thread count."),
        ("Allocation is process-wide and measured on the serial path only; "
         "--alloc adds an extra untimed serial pass so per-candidate bytes "
         "exclude JIT/library warmup."),
        ("Peak memory is whole-process RSS (runtime and JIT included) from "
         "scripts/bench_process.py; for threads > 1 it is not a per-worker "
         "figure."),
        ("Julia per-candidate latency is derived by summing the reset/sim/"
         "extract phase stats; the summary carries mean/p50/p99 per phase but "
         "no per-phase max, so max_ms is null."),
        ("Lua per-candidate latency uses phases.total (us) and averages the "
         "per-repeat summary quantiles across repeats, not a pooled quantile."),
        ("Full-grid reference numbers are stride 1 from session 1; this "
         "benchmark is stride %d. Do not compare per-candidate rates across "
         "strides." % stride),
        ("Tracing-on timing is diagnostic only; it is reported in the "
         "diagnostic block and never merged into the main workload table."),
        ("The Lua harness is single-threaded; thread counts apply to Julia "
         "only. All runs are same-host."),
        ("The M4 correctness gate is the session-1 full-grid parity sweep; "
         "the stride-%d comparator block is informational." % stride),
    ]

    report = {
        "format": REPORT_FORMAT,
        "schema_version": SCHEMA_VERSION,
        "generated_utc": datetime.datetime.now(
            datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "host_label": args.host_label,
        "host": host,
        "options": {
            "stride": stride,
            "repeats": repeats,
            "workloads": workload_order,
            "threads_requested": sorted(set(requested_threads)),
            "threads_capped": sorted(set(thread_values)),
            "nproc": args.nproc,
            "diagnostic_workload": diagnostic_id,
            "out_dir": display_path(out_dir),
            "raw_dir": display_path(raw_dir),
            "julia_project": "julia/PeggleSim",
            "pinned_reference_dir": "reference/peggle_evolved",
            "aim_discretization_steps": aim_steps,
            "candidates_per_stride": expected_candidates,
        },
        "method": {
            "lua": ("scripts/love.sh love harness -- --sweep --workloads "
                    "harness/workloads.lua --workload <id> --stride %d "
                    "--repeat %d --no-replay-serialize --out <raw> "
                    "--summary-out <summary> --reference-dir "
                    "reference/peggle_evolved (frozen pinned tree; balls come "
                    "from the workload catalog)" % (stride, repeats)),
            "julia": ("julia -t <T> --project=julia/PeggleSim "
                      "julia/PeggleSim/bin/shot_bench.jl --sweep --level "
                      "interchange/levels/<level>.v1.json --config "
                      "interchange/config.v1.json --stride %d --balls <N> "
                      "--threads <T> --verify-serial --alloc" % stride),
            "same_core_speedup": ("Lua mean candidates/s vs Julia t1 parallel "
                                  "pass candidates/s at the same stride and "
                                  "indices"),
            "per_candidate_latency": ("Lua: phases.total summary stats; "
                                      "Julia: reset+sim+extract phase stats"),
            "allocation": ("Base.gc_bytes() delta around reset+launch+run+"
                           "extract per candidate on the serial path of the "
                           "t1 run"),
            "peak_memory": ("scripts/bench_process.py per sweep process: GNU "
                            "time -v Maximum resident set size when available, "
                            "otherwise resource.getrusage(RUSAGE_CHILDREN)"
                            ".ru_maxrss (kernel VmHWM of the one child)"),
            "diagnostic_overhead": ("one untraced and one traced single serial "
                                    "Julia t1 pass; trace bytes/step = sum of "
                                    "per-candidate trace file sizes / total "
                                    "steps; outcome equality by SHA-256 of the "
                                    "result JSONL rows"),
            "full_grid_reference": ("read-only reuse of session-1 stride-1 "
                                    "Lua and Julia t1 full-grid summaries"),
            "steps_per_second": ("Lua sim_steps_per_second (steps / sim phase "
                                 "seconds); Julia steps_per_second (steps / "
                                 "wall seconds)"),
        },
        "caveats": caveats,
        "workloads": workloads,
        "full_grid_reference": full_grid,
        "diagnostic": diagnostic,
        "status": {
            "complete": not failures,
            "failures": failures,
            "workloads_requested": len(workload_order),
            "threads_requested": sorted(set(thread_values)),
            "runs_failed": len(failures),
        },
        "artifacts": {
            "journal": display_path(args.journal),
            "raw_dir": display_path(raw_dir),
            "note": ("intermediate Lua/Julia summaries live under %s; raw "
                     "candidate JSONL and diagnostic traces live under %s "
                     "(gitignored)" % (display_path(out_dir), display_path(raw_dir))),
        },
    }

    out_path = args.out if os.path.isabs(args.out) else \
        os.path.join(repo_root, args.out)
    out_parent = os.path.dirname(out_path)
    if out_parent:
        os.makedirs(out_parent, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")

    print("bench_m4_report: workloads=%d complete=%s failures=%d"
          % (len(workload_order), not failures, len(failures)))
    if failures:
        for failure in failures:
            print("bench_m4_report: FAIL %s" % failure, file=sys.stderr)
    print("bench_m4_report: wrote %s" % display_path(out_path))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
