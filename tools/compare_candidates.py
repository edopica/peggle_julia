#!/usr/bin/env python3
"""Compare two harness candidate sweeps (raw JSONL + summary JSON).

WP-E candidate contract (tmp/core-math/wpef-plan.md step 6): the pinned
reference and the dev-tree system_libm sweep must be identical in score,
completion reason, steps, and pegs_hit; core_math differences are recorded
and classified. Host metadata and timing fields are never compared
(time_*, mem_kb, host, cold_start, phases, rss_*).

Per candidate row the compared fields are:

  score/peg_score/bonus/style_points/style_total/styles -> category "score"
  completed/reason                                      -> category "completion"
  steps                                                 -> category "steps"
  pegs_hit/reds_hit                                     -> category "pegs_hit"
  multiplier/is_fever/balls/angle                       -> category "other"

Summary aggregates (per workload, one entry per repeat) are checked for
the same categories; ``reasons`` and ``style_hits`` maps are compared
exactly. All compared values are exact (no tolerances): a bare ``-0``
integer token parses as ``-0.0`` (``parse_int``) so signed zero is
preserved and compared bit-exactly.

Usage:
  tools/compare_candidates.py --left-raw FILE --left-summary FILE
                              --right-raw FILE --right-summary FILE
                              --out REPORT.json [--control]
                              [--require-identical]
                              [--control-json FILE]
                              [--left-label L --right-label R]
                              [--environment-json STR]

--control and --require-identical are mutually exclusive. --control checks a
same-host control (differences are failures); --require-identical checks a
cross-machine comparison (every compared difference is a failure; host and
timing fields are never compared) and records mode ``require_identical``.

Exit codes: 0 clean report written, 1 unexpected differences in --control
mode, any compared difference in --require-identical mode, 2 malformed or
missing input.
"""

import argparse
import json
import os
import struct
import sys
from collections import Counter

FORMAT = "peggle.candidate_comparison"
SCHEMA_VERSION = 1

CANDIDATE_FIELDS = (
    ("score", "score"),
    ("peg_score", "score"),
    ("bonus", "score"),
    ("style_points", "score"),
    ("style_total", "score"),
    ("styles", "score"),
    ("completed", "completion"),
    ("reason", "completion"),
    ("steps", "steps"),
    ("pegs_hit", "pegs_hit"),
    ("reds_hit", "pegs_hit"),
    ("multiplier", "other"),
    ("is_fever", "other"),
    ("balls", "other"),
    ("angle", "other"),
)

SUMMARY_FIELDS = (
    ("completed", "completion"),
    ("incomplete", "completion"),
    ("candidates", "other"),
)

SUMMARY_AGGREGATES = (
    ("score", "sum", "score"),
    ("steps", "sum", "steps"),
    ("pegs_hit", "sum", "pegs_hit"),
    ("reds_hit", "sum", "pegs_hit"),
)


class InputError(Exception):
    pass


def parse_int(text):
    if text == "-0":
        return -0.0
    return int(text)


def load_json_file(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle, parse_int=parse_int)
    except (OSError, ValueError) as err:
        raise InputError("cannot read JSON %s: %s" % (path, err))


def load_raw(path):
    rows = {}
    try:
        handle = open(path, "r", encoding="utf-8")
    except OSError as err:
        raise InputError("cannot read raw candidates %s: %s" % (path, err))
    with handle:
        for lineno, line in enumerate(handle, start=1):
            if line.strip() == "":
                continue
            try:
                row = json.loads(line, parse_int=parse_int)
            except ValueError as err:
                raise InputError("%s: invalid JSON on line %d: %s"
                                 % (path, lineno, err))
            key = (row.get("w"), row.get("i"))
            if key in rows:
                raise InputError("%s: duplicate candidate %r on line %d"
                                 % (path, key, lineno))
            rows[key] = row
    return rows


def bits(value):
    return struct.unpack("<Q", struct.pack("<d", float(value)))[0]


def values_equal(left, right):
    if isinstance(left, float) or isinstance(right, float):
        if isinstance(left, bool) or isinstance(right, bool):
            return left == right
        return bits(left) == bits(right)
    return left == right


def structured_value(value):
    if isinstance(value, dict):
        return {key: structured_value(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        return [structured_value(item) for item in value]
    return value


def compare_workload(workload, left_rows, right_rows, left_summary,
                     right_summary):
    differences = []
    classifications = Counter()
    difference_counts = Counter()
    left_keys = sorted(key for key in left_rows if key[0] == workload)
    right_keys = sorted(key for key in right_rows if key[0] == workload)
    left_key_set = set(left_keys)
    right_key_set = set(right_keys)
    for key in sorted(left_key_set - right_key_set):
        differences.append({
            "workload": workload,
            "index": key[1],
            "field": "candidate",
            "expected": "present",
            "actual": "missing",
            "category": "other",
        })
        classifications["other"] += 1
        difference_counts["candidate"] += 1
    for key in sorted(right_key_set - left_key_set):
        differences.append({
            "workload": workload,
            "index": key[1],
            "field": "candidate",
            "expected": "missing",
            "actual": "present",
            "category": "other",
        })
        classifications["other"] += 1
        difference_counts["candidate"] += 1
    for key in sorted(left_key_set & right_key_set):
        left_row = left_rows[key]
        right_row = right_rows[key]
        for field, category in CANDIDATE_FIELDS:
            left_value = left_row.get(field)
            right_value = right_row.get(field)
            equal = values_equal(left_value, right_value)
            if not equal:
                differences.append({
                    "workload": workload,
                    "index": key[1],
                    "field": field,
                    "expected": left_value,
                    "actual": right_value,
                    "category": category,
                })
                classifications[category] += 1
                difference_counts[field] += 1
    summary_differences = []
    left_entry = left_summary.get(workload)
    right_entry = right_summary.get(workload)
    if left_entry is None or right_entry is None:
        summary_differences.append({
            "field": "workload",
            "expected": "present" if left_entry is not None else "missing",
            "actual": "present" if right_entry is not None else "missing",
            "category": "other",
        })
        classifications["other"] += 1
        difference_counts["summary.workload"] += 1
    else:
        for field, category in SUMMARY_FIELDS:
            if left_entry.get(field) != right_entry.get(field):
                summary_differences.append({
                    "field": field,
                    "expected": left_entry.get(field),
                    "actual": right_entry.get(field),
                    "category": category,
                })
                classifications[category] += 1
                difference_counts["summary." + field] += 1
        for field in ("reasons", "style_hits"):
            left_map = structured_value(left_entry.get(field) or {})
            right_map = structured_value(right_entry.get(field) or {})
            if left_map != right_map:
                category = "completion" if field == "reasons" else "score"
                summary_differences.append({
                    "field": field,
                    "expected": left_map,
                    "actual": right_map,
                    "category": category,
                })
                classifications[category] += 1
                difference_counts["summary." + field] += 1
        for field, aggregate, category in SUMMARY_AGGREGATES:
            left_block = left_entry.get(field) or {}
            right_block = right_entry.get(field) or {}
            left_value = left_block.get(aggregate)
            right_value = right_block.get(aggregate)
            if left_value != right_value:
                summary_differences.append({
                    "field": "%s.%s" % (field, aggregate),
                    "expected": left_value,
                    "actual": right_value,
                    "category": category,
                })
                classifications[category] += 1
                difference_counts["summary.%s.%s" % (field, aggregate)] += 1
    identical = not differences and not summary_differences
    first = differences[0] if differences else None
    return {
        "identical": identical,
        "candidates_compared": len(left_key_set & right_key_set),
        "classifications": dict(sorted(classifications.items())),
        "difference_counts": dict(sorted(difference_counts.items())),
        "first_difference": first,
        "summary_differences": summary_differences,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Compare two baseline candidate sweeps.")
    parser.add_argument("--left-raw", required=True)
    parser.add_argument("--left-summary", required=True)
    parser.add_argument("--right-raw", required=True)
    parser.add_argument("--right-summary", required=True)
    parser.add_argument("--out", required=True)
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument("--control", action="store_true")
    mode_group.add_argument("--require-identical", action="store_true",
                            help="cross-machine comparison: every compared "
                                 "difference is a failure")
    parser.add_argument("--control-json", default=None)
    parser.add_argument("--left-label", default="left")
    parser.add_argument("--right-label", default="right")
    parser.add_argument("--environment-json", default=None)
    args = parser.parse_args(argv)

    try:
        left_rows = load_raw(args.left_raw)
        right_rows = load_raw(args.right_raw)
        left_doc = load_json_file(args.left_summary)
        right_doc = load_json_file(args.right_summary)
    except InputError as err:
        print("compare_candidates: %s" % err, file=sys.stderr)
        return 2

    def index_workloads(doc):
        entries = doc.get("workloads")
        if not isinstance(entries, list):
            raise InputError("summary has no workloads list")
        index = {}
        for entry in entries:
            workload = entry.get("workload")
            if workload in index:
                raise InputError("duplicate workload %r in summary" % workload)
            index[workload] = entry
        return index

    try:
        left_summary = index_workloads(left_doc)
        right_summary = index_workloads(right_doc)
    except InputError as err:
        print("compare_candidates: %s" % err, file=sys.stderr)
        return 2

    failures = []
    workloads = {}
    semantic_differences = []
    workload_ids = sorted(
        set(key[0] for key in left_rows) | set(key[0] for key in right_rows)
        | set(left_summary) | set(right_summary))
    for workload in workload_ids:
        result = compare_workload(workload, left_rows, right_rows,
                                  left_summary, right_summary)
        workloads[workload] = result
        if not result["identical"]:
            semantic_differences.append({
                "workload": workload,
                "classifications": result["classifications"],
                "candidates_compared": result["candidates_compared"],
                "first_difference": result["first_difference"],
                "summary_differences": result["summary_differences"],
            })
            if args.control or args.require_identical:
                if args.control:
                    reason = ("control candidate differences in %s"
                              % sorted(result["classifications"]))
                else:
                    reason = ("candidate differences in %s"
                              % sorted(result["classifications"]))
                failures.append({"workload": workload, "reason": reason})

    control_block = {
        "clean": not failures and not any(
            not result["identical"] for result in workloads.values()),
        "checked": bool(args.control),
        "require_identical": bool(args.require_identical),
        "left_label": args.left_label,
        "right_label": args.right_label,
        "workloads_compared": len(workloads),
        "identical_workloads": sum(
            1 for result in workloads.values() if result["identical"]),
        "failures": failures,
    }
    if args.control_json:
        prior = load_json_file(args.control_json)
        if isinstance(prior, dict) and isinstance(prior.get("control"), dict):
            control_block = prior["control"]
            control_block["embedded_from"] = os.path.abspath(args.control_json)

    if args.require_identical:
        mode = "require_identical"
    elif args.control:
        mode = "control"
    else:
        mode = "core_vs_system"
    report = {
        "format": FORMAT,
        "schema_version": SCHEMA_VERSION,
        "mode": mode,
        "left": {"label": args.left_label, "raw": os.path.abspath(args.left_raw),
                 "summary": os.path.abspath(args.left_summary)},
        "right": {"label": args.right_label, "raw": os.path.abspath(args.right_raw),
                  "summary": os.path.abspath(args.right_summary)},
        "environment": json.loads(args.environment_json) if args.environment_json else None,
        "control": control_block,
        "workloads": workloads,
        "semantic_differences": semantic_differences,
        "failures": failures,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")
    if (args.control or args.require_identical) and failures:
        label = "control failure" if args.control else "failure"
        for failure in failures:
            print("compare_candidates: %s: %s: %s" % (
                label, failure.get("workload"), failure.get("reason")),
                file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
