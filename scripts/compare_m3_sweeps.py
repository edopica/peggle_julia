#!/usr/bin/env python3
"""Compare a Lua harness candidate sweep against a Julia shot_bench sweep.

Both sides evaluate the same candidate aim grid from the same ready-to-aim
checkpoint. The Lua harness writes ``<prefix>.candidates.jsonl`` (one row per
candidate, keys ``w r i angle steps ...``); the Julia driver writes canonical
JSON rows (keys ``index angle steps ...``). This comparator joins the two
corpora on the aim index and checks every shared semantic field:

  index/aim, angle, steps, completed, reason, score, peg_score, bonus,
  style_points, style_total, styles (Lua ``name:count,...`` string vs Julia
  object), pegs_hit, reds_hit, multiplier, is_fever, balls, spawned

The report records the first divergent candidate with the left/right values,
per-field mismatch counts, and the candidate coverage. A field the Lua raw
does not carry is recorded under ``unavailable_fields`` and is not compared:
the Lua harness ``serialize_row`` omits ``spawned`` (the harness feature
exists, the raw JSONL row does not), so ``spawned`` is a coverage gap, not a
divergence. Exit status is 0 iff the two corpora agree on every compared
candidate and field (and cover the same indices); 1 on any mismatch; 2 on
unreadable or malformed input.

Usage:
  scripts/compare_m3_sweeps.py --lua-raw RAW.candidates.jsonl \
      --julia results/m3/julia-sweep-t1.jsonl --out results/m3/sweeps-compare.json \
      [--stride N] [--julia-label t1] [--max-mismatch-records N]
"""

import argparse
import json
import os
import sys
from collections import Counter

FORMAT = "peggle.m3_sweep_compare"
SCHEMA_VERSION = 1

# (field, lua key, julia key) in report order. `index` is the join key and is
# still compared as a field for coverage reporting.
SHARED_FIELDS = (
    ("index", "i", "index"),
    ("angle", "angle", "angle"),
    ("steps", "steps", "steps"),
    ("completed", "completed", "completed"),
    ("reason", "reason", "reason"),
    ("score", "score", "score"),
    ("peg_score", "peg_score", "peg_score"),
    ("bonus", "bonus", "bonus"),
    ("style_points", "style_points", "style_points"),
    ("style_total", "style_total", "style_total"),
    ("styles", "styles", "styles"),
    ("pegs_hit", "pegs_hit", "pegs_hit"),
    ("reds_hit", "reds_hit", "reds_hit"),
    ("multiplier", "multiplier", "multiplier"),
    ("is_fever", "is_fever", "is_fever"),
    ("balls", "balls", "balls"),
    ("spawned", "spawned", "spawned"),
)


class InputError(Exception):
    pass


def load_jsonl(path):
    rows = []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, start=1):
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError as err:
                    raise InputError(
                        "%s:%d: invalid JSON: %s" % (path, line_number, err))
                if not isinstance(row, dict):
                    raise InputError(
                        "%s:%d: row is not an object" % (path, line_number))
                rows.append(row)
    except OSError as err:
        raise InputError("cannot read %s: %s" % (path, err))
    if not rows:
        raise InputError("%s: no rows" % path)
    return rows


def parse_lua_styles(text):
    styles = {}
    for item in str(text).split(","):
        item = item.strip()
        if not item:
            continue
        name, _, count = item.partition(":")
        styles[name] = int(count) if count != "" else 1
    return styles


def normalize_style_value(value, side):
    if value is None:
        return {}
    if isinstance(value, dict):
        return {str(key): int(count) for key, count in value.items()}
    if isinstance(value, str):
        return parse_lua_styles(value)
    raise InputError("unsupported styles value on %s side: %r" % (side, value))


def values_equal(field, left, right):
    if field == "styles":
        return normalize_style_value(left, "lua") == normalize_style_value(right, "julia")
    if isinstance(left, bool) or isinstance(right, bool):
        return isinstance(left, bool) and isinstance(right, bool) and left == right
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return left == right
    return left == right


def lua_index(row, path, line_number):
    value = row.get("i")
    if not isinstance(value, int) or isinstance(value, bool):
        raise InputError("%s:%d: missing integer \"i\" index" % (path, line_number))
    return value


def julia_index(row, path, line_number):
    value = row.get("index")
    if not isinstance(value, int) or isinstance(value, bool):
        raise InputError("%s:%d: missing integer \"index\"" % (path, line_number))
    return value


def detect_stride(indices):
    unique = sorted(set(indices))
    if len(unique) < 2:
        return None
    return min(b - a for a, b in zip(unique, unique[1:]))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Compare a Lua harness raw sweep with a Julia shot_bench sweep.")
    parser.add_argument("--lua-raw", required=True,
                        help="Lua harness <prefix>.candidates.jsonl")
    parser.add_argument("--julia", required=True,
                        help="Julia shot_bench sweep JSONL")
    parser.add_argument("--out", required=True, help="report output path")
    parser.add_argument("--stride", type=int, default=None,
                        help="requested stride (recorded; default: detect)")
    parser.add_argument("--julia-label", default="julia",
                        help="label for the Julia side (e.g. t1)")
    parser.add_argument("--max-mismatch-records", type=int, default=200,
                        help="cap on retained per-candidate mismatch records")
    args = parser.parse_args(argv)

    try:
        lua_rows = load_jsonl(args.lua_raw)
        julia_rows = load_jsonl(args.julia)
    except InputError as err:
        print("compare_m3_sweeps: %s" % err, file=sys.stderr)
        return 2

    lua_by_index = {}
    lua_repeats = set()
    try:
        for line_number, row in enumerate(lua_rows, start=1):
            index = lua_index(row, args.lua_raw, line_number)
            repeat = row.get("r", 1)
            if not isinstance(repeat, int) or isinstance(repeat, bool):
                repeat = 1
            lua_repeats.add(repeat)
            lua_by_index.setdefault(index, []).append((repeat, row))
        julia_by_index = {}
        for line_number, row in enumerate(julia_rows, start=1):
            index = julia_index(row, args.julia, line_number)
            if index in julia_by_index:
                raise InputError(
                    "%s:%d: duplicate Julia index %d" % (args.julia, line_number, index))
            julia_by_index[index] = row
    except InputError as err:
        print("compare_m3_sweeps: %s" % err, file=sys.stderr)
        return 2

    lua_indices = set(lua_by_index)
    julia_indices = set(julia_by_index)
    missing_in_julia = sorted(lua_indices - julia_indices)
    missing_in_lua = sorted(julia_indices - lua_indices)
    shared = sorted(lua_indices & julia_indices)

    # A field is comparable only when the key exists somewhere on both sides.
    # The Lua harness serialize_row does not emit `spawned` (its `features`
    # table has it, the JSONL row does not), so record it as unavailable
    # rather than as a per-candidate mismatch.
    lua_keys = set().union(*(row.keys() for row in lua_rows))
    julia_keys = set().union(*(row.keys() for row in julia_rows))
    unavailable_fields = {}
    compared_fields = []
    for field, lua_key, julia_key in SHARED_FIELDS:
        if lua_key in lua_keys and julia_key in julia_keys:
            compared_fields.append(field)
        else:
            unavailable_fields[field] = {
                "lua_key": lua_key,
                "julia_key": julia_key,
                "lua_present": lua_key in lua_keys,
                "julia_present": julia_key in julia_keys,
            }

    per_field_mismatch = Counter()
    mismatch_records = []
    mismatch_candidates = 0
    first_divergent = None

    try:
        for index in shared:
            rows = sorted(lua_by_index[index], key=lambda pair: pair[0])
            for repeat, lua_row in rows:
                julia_row = julia_by_index[index]
                field_differences = {}
                for field, lua_key, julia_key in SHARED_FIELDS:
                    if field in unavailable_fields:
                        continue
                    left = lua_row.get(lua_key)
                    right = julia_row.get(julia_key)
                    if not values_equal(field, left, right):
                        field_differences[field] = {"left": left, "right": right}
                        per_field_mismatch[field] += 1
                if field_differences:
                    mismatch_candidates += 1
                    record = {
                        "index": index,
                        "repeat": repeat,
                        "angle": lua_row.get("angle"),
                        "fields": field_differences,
                    }
                    if len(mismatch_records) < args.max_mismatch_records:
                        mismatch_records.append(record)
                    if first_divergent is None:
                        first_divergent = record
    except InputError as err:
        print("compare_m3_sweeps: %s" % err, file=sys.stderr)
        return 2

    if missing_in_julia or missing_in_lua:
        for index in missing_in_julia:
            per_field_mismatch["index"] += 1
            mismatch_candidates += 1
            record = {
                "index": index,
                "repeat": None,
                "angle": lua_by_index[index][0][1].get("angle"),
                "fields": {"index": {"left": "present", "right": "missing"}},
            }
            if len(mismatch_records) < args.max_mismatch_records:
                mismatch_records.append(record)
            if first_divergent is None:
                first_divergent = record
        for index in missing_in_lua:
            per_field_mismatch["index"] += 1
            mismatch_candidates += 1
            record = {
                "index": index,
                "repeat": None,
                "angle": julia_by_index[index].get("angle"),
                "fields": {"index": {"left": "missing", "right": "present"}},
            }
            if len(mismatch_records) < args.max_mismatch_records:
                mismatch_records.append(record)
            if first_divergent is None:
                first_divergent = record

    lua_workloads = sorted({row.get("w") for row in lua_rows
                            if isinstance(row.get("w"), str)})
    requested_stride = args.stride
    detected_stride = detect_stride(lua_indices | julia_indices)
    clean = not per_field_mismatch and not missing_in_julia and not missing_in_lua

    report = {
        "format": FORMAT,
        "schema_version": SCHEMA_VERSION,
        "clean": clean,
        "requested_stride": requested_stride,
        "detected_stride": detected_stride,
        "lua_raw": os.path.abspath(args.lua_raw),
        "julia_jsonl": os.path.abspath(args.julia),
        "julia_label": args.julia_label,
        "fields_compared": compared_fields,
        "unavailable_fields": unavailable_fields,
        "lua_workloads": lua_workloads,
        "lua_repeats": sorted(lua_repeats),
        "coverage": {
            "lua_candidates": len(lua_rows),
            "julia_candidates": len(julia_rows),
            "shared_indices": len(shared),
            "lua_indices": len(lua_indices),
            "julia_indices": len(julia_indices),
            "first_index": shared[0] if shared else None,
            "last_index": shared[-1] if shared else None,
            "missing_in_julia": missing_in_julia,
            "missing_in_lua": missing_in_lua,
        },
        "candidates_compared": len(shared),
        "mismatch_candidates": mismatch_candidates,
        "per_field_mismatch_count": dict(sorted(per_field_mismatch.items())),
        "first_divergent_candidate": first_divergent,
        "mismatch_records": mismatch_records,
        "mismatch_records_truncated": mismatch_candidates > len(mismatch_records),
    }

    out_dir = os.path.dirname(os.path.abspath(args.out))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")

    fields = ", ".join("%s=%d" % (key, per_field_mismatch[key])
                       for key in sorted(per_field_mismatch)) or "none"
    print("compare_m3_sweeps: lua=%s julia=%s stride=%s candidates=%d "
          "mismatch_candidates=%d fields=[%s]" % (
              args.lua_raw, args.julia_label,
              requested_stride if requested_stride is not None else detected_stride,
              len(shared), mismatch_candidates, fields))
    if unavailable_fields:
        print("compare_m3_sweeps: unavailable fields (not in both raw formats): %s"
              % ", ".join(sorted(unavailable_fields)))
    if first_divergent is not None:
        print("compare_m3_sweeps: first divergent candidate index=%s repeat=%s" % (
            first_divergent["index"], first_divergent["repeat"]))
        for field, values in sorted(first_divergent["fields"].items()):
            print("  %-14s left=%r right=%r" % (field, values["left"], values["right"]))
    return 0 if clean else 1


if __name__ == "__main__":
    sys.exit(main())
