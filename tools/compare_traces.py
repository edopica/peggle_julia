#!/usr/bin/env python3
"""Compare two canonical gameplay-trace corpora (JSONL + expected records).

Implements WP-E's trace comparison contract (tmp/core-math/wpef-plan.md):

  * JSONL is parsed strictly: one header object, then step objects with
    strictly increasing unique ``step`` ids and the four ordered lists
    ``raw_events``, ``derived_events``, ``requested_commands``,
    ``applied_commands``.
  * JSON numbers preserve signed zero: a bare ``-0`` integer token parses as
    ``-0.0`` (``parse_int``), and ``-0.0`` keeps its sign, so exact
    IEEE-754 bit comparison distinguishes ``-0`` from ``0``.
  * Header equality is enforced except for the non-authoritative
    ``math_backend`` identity block and the ``include_snapshot`` scope
    metadata, which are recorded separately.
  * Events are aligned between the two corpora with a key-based sequence
    alignment (``difflib.SequenceMatcher``); every integer/string/bool field
    inside a matched pair is compared exactly, every float payload field by
    exact IEEE-754 bit pattern plus ULP distance. ``ulp_distance`` uses a
    monotonic order-preserving bit mapping: adjacent representable doubles
    differ by exactly one ULP, ``-0.0`` and ``0.0`` are one ULP apart, and
    NaN compares as unknown (``None``).
  * When both corpora carry per-step ``snapshot`` records (WP-E
    ``--fixtures-snapshots``) the full authoritative simulation state is
    compared recursively with ``compare_state_value``: numeric leaves by
    exact IEEE-754 bits, structure by key presence/list length/type. State
    differences are classified ``state_bit_difference`` or
    ``state_structure``. When only one corpus carries snapshots the scope
    mismatch is recorded (``state_comparison == "scope_mismatch"``) and the
    result is event/result agreement only, not complete simulation-state
    agreement; a control fails on the mismatch, ``--strict-reference`` does
    not. The first divergent state is retained in
    ``first_difference.left_step_json``/``right_step_json``, which embed the
    full step records (snapshots included) for inspection.
  * Every difference is classified into exactly one of
    ``value_bit_difference`` (event float bits), ``step_placement`` (the
    same logical event appears at a different step), ``event_structure``
    (types/ids/commands differ), ``completion`` (max_steps/steps/reason/
    rule), ``score`` (expected-record result/score/semantic fields),
    ``state_bit_difference``/``state_structure`` (snapshot state).
    ``volatile_animation`` is allowed only for the explicit
    ``VOLATILE_ANIMATION_FIELDS`` allowlist of known non-authoritative
    animation fields (the WP-C fever-bucket variable-dt finding); additions
    require review, and every other reference-vs-reference difference is a
    failure requiring investigation. ``trace_hash_metadata`` records
    ``trace.sha256`` differences that follow from the recorded
    ``math_backend`` header alone.

Usage:
  tools/compare_traces.py --left-traces DIR --left-expected DIR
                          --right-traces DIR --right-expected DIR
                          --out REPORT.json [options]

Options:
  --control               differences are failures (control comparison)
  --strict-reference      reference-discovery comparison: any difference
                          outside the explicit volatile allowlist is a
                          failure (report mode ``reference_discovery``)
  --volatile-report FILE  read approved volatile field paths from a prior
                          discovery report (``volatile_paths_discovered``);
                          a path outside the explicit allowlist raises
                          InputError (exit 2)
  --volatile-out FILE     write the approved volatile field paths observed
                          by this comparison (the discovery run feeds this
                          back through --volatile-report)
  --control-json FILE     embed the ``control`` block from a prior --control
                          report (used when writing the core-vs-system report)
  --environment-json STR  environment matrix recorded verbatim
  --left-label/--right-label  labels recorded in the report

Exit codes: 0 report written and control clean, 1 unexpected differences in
--control mode or a reference difference outside the explicit volatile
allowlist in --strict-reference mode, 2 malformed or missing input.
"""

import argparse
import json
import math
import os
import struct
import sys
from collections import Counter
from difflib import SequenceMatcher

FORMAT = "peggle.trace_comparison"
SCHEMA_VERSION = 1
EVENT_LISTS = ("raw_events", "derived_events", "requested_commands", "applied_commands")

PLACEMENT_FIELDS = {
    "sequence", "source_sequence", "source_sequences", "hit_order", "iteration",
    "shot_id", "step",
}
COMPLETION_FIELDS = {"completion_reason", "initial_step", "final_step"}
SCORE_FIELDS = {"total_score", "peg_score", "style_score", "bonus_score", "points", "value"}
FLOAT_FIELDS = {
    "frame_t", "impact_x", "impact_y", "incoming_vx", "incoming_vy",
    "normal_x", "normal_y", "outgoing_vx", "outgoing_vy",
    "other_outgoing_vx", "other_outgoing_vy", "toi", "peg_angle", "peg_theta",
    "peg_x", "peg_y", "x", "y", "vx", "vy", "bucket_x", "distance", "angle",
}
MATCH_FIELDS = (
    "ball_id", "peg_id", "other_ball_id", "wall", "style", "reason",
    "line_id", "peg_type", "contact_kind", "source",
)

ULP_BUCKETS = ((1, "1"), (3, "2-3"), (15, "4-15"), (255, "16-255"),
               (65535, "256-65535"))
ULP_LARGE = ">=65536"
ULP_NAN = "nan"

# Explicit allowlist of known non-authoritative animation fields. WP-C found
# that fever-bucket animation state is updated with the variable frame delta
# (tmp/core-math/wpc-acceptance.md item 3), so these two fields may vary
# run-to-run under load. Additions require review: any other
# reference-vs-reference difference is authoritative and must be
# investigated, never discovered into this list automatically.
VOLATILE_ANIMATION_FIELDS = (
    "snapshot.fever_buckets.animating",
    "snapshot.fever_buckets.dividers[].y",
)

VOLATILE_NOTE = (
    "Only paths in the explicit VOLATILE_ANIMATION_FIELDS allowlist may be "
    "classified volatile_animation (snapshot.fever_buckets.animating and "
    "snapshot.fever_buckets.dividers[].y): WP-C found that fever-bucket "
    "animation state is updated with the variable frame delta "
    "(wpc-acceptance.md item 3), so those fields vary between two otherwise "
    "identical runs. Every other reference-vs-reference difference is a "
    "failure requiring investigation, and allowlist additions require "
    "review. In this fixed-dt harness the discovered set is normally empty."
)

STATE_SCOPE_NOTE = (
    "Some fixtures were compared without per-step snapshots on one or both "
    "sides (state_comparison is not \"full\"): those results are event/result "
    "agreement only, not complete simulation-state agreement."
)


class InputError(Exception):
    pass


def parse_int(text):
    if text == "-0":
        return -0.0
    return int(text)


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def is_integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def float_bits(value):
    if isinstance(value, int):
        value = float(value)
    return struct.unpack("<Q", struct.pack("<d", float(value)))[0]


def ordered_bits(value):
    """Monotonic key: adjacent representable doubles differ by 1, including
    -0.0/+0.0 (distance 1)."""
    bits = float_bits(value)
    if bits & 0x8000000000000000:
        return 0xFFFFFFFFFFFFFFFF - bits
    return bits | 0x8000000000000000


def ulp_distance(left, right):
    if isinstance(left, float) and math.isnan(left):
        return None
    if isinstance(right, float) and math.isnan(right):
        return None
    return abs(ordered_bits(left) - ordered_bits(right))


def ulp_bucket(distance):
    if distance is None:
        return ULP_NAN
    if distance <= 1:
        return "1"
    for limit, name in ULP_BUCKETS:
        if distance <= limit:
            return name
    return ULP_LARGE


def load_json_file(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle, parse_int=parse_int)
    except (OSError, ValueError) as err:
        raise InputError("cannot read JSON %s: %s" % (path, err))


def load_trace(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as err:
        raise InputError("cannot read trace %s: %s" % (path, err))
    if not lines:
        raise InputError("empty trace %s" % path)
    records = []
    for index, line in enumerate(lines):
        if line == "":
            raise InputError("%s: blank line %d" % (path, index + 1))
        try:
            records.append(json.loads(line, parse_int=parse_int))
        except ValueError as err:
            raise InputError("%s: invalid JSON on line %d: %s" % (path, index + 1, err))
    header = records[0]
    if not isinstance(header, dict) or header.get("kind") != "gameplay_trace":
        raise InputError("%s: first line is not a gameplay_trace header" % path)
    steps = []
    previous = None
    for index, record in enumerate(records[1:], start=2):
        if not isinstance(record, dict) or record.get("kind") != "step":
            raise InputError("%s: line %d is not a step record" % (path, index))
        sid = record.get("step")
        if not is_integer(sid):
            raise InputError("%s: line %d has no integer step id" % (path, index))
        if previous is not None and sid <= previous:
            raise InputError("%s: step ids are not strictly increasing at line %d"
                             % (path, index))
        previous = sid
        for list_name in EVENT_LISTS:
            value = record.get(list_name)
            if value is None:
                record[list_name] = []
            elif not isinstance(value, list):
                raise InputError("%s: line %d %s is not a list"
                                 % (path, index, list_name))
        steps.append(record)
    return header, steps


def event_key(list_name, event):
    parts = [list_name, str(event.get("type"))]
    for field in MATCH_FIELDS:
        if field in event:
            parts.append("%s=%r" % (field, event[field]))
    line = event.get("line")
    if isinstance(line, dict) and "id" in line:
        parts.append("line.id=%r" % (line["id"],))
    if "peg_ids" in event and isinstance(event["peg_ids"], list):
        parts.append("peg_ids=%r" % (event["peg_ids"],))
    return "|".join(parts)


class Difference(object):
    __slots__ = ("category", "path", "full_path", "step", "expected", "actual", "ulp")

    def __init__(self, category, path, full_path, step, expected, actual, ulp=None):
        self.category = category
        self.path = path
        self.full_path = full_path
        self.step = step
        self.expected = expected
        self.actual = actual
        self.ulp = ulp

    def as_first_difference(self):
        return {
            "step": self.step,
            "path": self.full_path,
            "expected": self.expected,
            "actual": self.actual,
            "category": self.category,
            "ulp": self.ulp,
        }


def leaf_category(name, left, right):
    if name in PLACEMENT_FIELDS:
        return "step_placement"
    if name in COMPLETION_FIELDS:
        return "completion"
    if name in SCORE_FIELDS:
        return "score"
    if name in FLOAT_FIELDS and is_number(left) and is_number(right):
        return "value_bit_difference"
    return "event_structure"


def compare_value(left, right, name, path_parts, norm_parts, step, out):
    if isinstance(left, dict) and isinstance(right, dict):
        for key in sorted(set(left) | set(right)):
            child_path = path_parts + [key]
            child_norm = norm_parts + [key]
            if key not in left or key not in right:
                out.append(Difference(
                    "event_structure", ".".join(child_norm),
                    ".".join(child_path), step, left.get(key), right.get(key)))
            else:
                compare_value(left[key], right[key], key, child_path,
                              child_norm, step, out)
        return
    if isinstance(left, list) and isinstance(right, list):
        if len(left) != len(right):
            out.append(Difference(
                "event_structure", ".".join(norm_parts + ["length"]),
                ".".join(path_parts) + ".length", step, len(left), len(right)))
        for index in range(min(len(left), len(right))):
            compare_value(left[index], right[index], name,
                          path_parts + ["[%d]" % index], norm_parts + ["[]"],
                          step, out)
        return
    if is_number(left) and is_number(right):
        if is_integer(left) and is_integer(right):
            if left == right:
                return
            category = leaf_category(name, left, right)
            distance = None
            if name in FLOAT_FIELDS:
                category = "value_bit_difference"
                distance = ulp_distance(left, right)
            out.append(Difference(category, ".".join(norm_parts),
                                  ".".join(path_parts), step, left, right, distance))
            return
        if float_bits(left) == float_bits(right):
            return
        out.append(Difference("value_bit_difference", ".".join(norm_parts),
                              ".".join(path_parts), step, left, right,
                              ulp_distance(left, right)))
        return
    if left != right:
        out.append(Difference(leaf_category(name, left, right), ".".join(norm_parts),
                              ".".join(path_parts), step, left, right))


def compare_state_value(left, right, path_parts, norm_parts, step, out):
    """Recursively compare authoritative snapshot values.

    Numeric leaves are compared by exact IEEE-754 bits and classified
    ``state_bit_difference`` (never by event field-name classification);
    dict key presence, list length, and non-numeric leaf mismatches are
    ``state_structure``. Normalized paths start with ``snapshot.`` (list
    elements use ``[]``); full paths are ``step.<sid>.snapshot....`` with
    concrete ``[i]`` indices.
    """
    if isinstance(left, dict) and isinstance(right, dict):
        for key in sorted(set(left) | set(right)):
            child_path = path_parts + [key]
            child_norm = norm_parts + [key]
            if key not in left or key not in right:
                out.append(Difference(
                    "state_structure", ".".join(child_norm),
                    ".".join(child_path), step, left.get(key), right.get(key)))
            else:
                compare_state_value(left[key], right[key], child_path,
                                    child_norm, step, out)
        return
    if isinstance(left, list) and isinstance(right, list):
        if len(left) != len(right):
            out.append(Difference(
                "state_structure", ".".join(norm_parts + ["length"]),
                ".".join(path_parts) + ".length", step, len(left), len(right)))
        for index in range(min(len(left), len(right))):
            compare_state_value(
                left[index], right[index],
                path_parts[:-1] + [path_parts[-1] + "[%d]" % index],
                norm_parts[:-1] + [norm_parts[-1] + "[]"], step, out)
        return
    if is_number(left) and is_number(right):
        if float_bits(left) == float_bits(right):
            return
        out.append(Difference("state_bit_difference", ".".join(norm_parts),
                              ".".join(path_parts), step, left, right,
                              ulp_distance(left, right)))
        return
    if left != right:
        out.append(Difference("state_structure", ".".join(norm_parts),
                              ".".join(path_parts), step, left, right))


def compare_snapshots(left_steps, right_steps, control, out):
    """Compare per-step snapshots; return (scope, steps_compared)."""
    left_has = any(isinstance(record.get("snapshot"), dict)
                   for record in left_steps)
    right_has = any(isinstance(record.get("snapshot"), dict)
                    for record in right_steps)
    steps_compared = 0
    if left_has and right_has:
        left_by_id = {record["step"]: record for record in left_steps}
        right_by_id = {record["step"]: record for record in right_steps}
        for sid in sorted(set(left_by_id) & set(right_by_id)):
            left_snapshot = left_by_id[sid].get("snapshot")
            right_snapshot = right_by_id[sid].get("snapshot")
            left_dict = isinstance(left_snapshot, dict)
            right_dict = isinstance(right_snapshot, dict)
            if left_dict and right_dict:
                steps_compared += 1
                compare_state_value(left_snapshot, right_snapshot,
                                    ["step.%d" % sid, "snapshot"],
                                    ["snapshot"], sid, out)
            elif left_dict or right_dict:
                out.append(Difference(
                    "state_structure", "snapshot", "step.%d.snapshot" % sid,
                    sid, "present" if left_dict else "missing",
                    "present" if right_dict else "missing"))
        return "full", steps_compared
    if not left_has and not right_has:
        return "not_captured", steps_compared
    if control:
        out.append(Difference(
            "state_structure", "snapshot", "snapshot", None,
            "present" if left_has else "missing",
            "present" if right_has else "missing"))
    return "scope_mismatch", steps_compared


def collect_events(steps):
    events = []
    for record in steps:
        sid = record["step"]
        for list_name in EVENT_LISTS:
            for index, event in enumerate(record[list_name]):
                if not isinstance(event, dict):
                    raise InputError("step %d %s[%d] is not an object"
                                     % (sid, list_name, index))
                events.append({
                    "step": sid,
                    "list": list_name,
                    "index": index,
                    "event": event,
                    "key": event_key(list_name, event),
                })
    return events


def compare_event_steps(left_steps, right_steps, out):
    left_ids = [record["step"] for record in left_steps]
    right_ids = [record["step"] for record in right_steps]
    left_by_id = {record["step"]: record for record in left_steps}
    right_by_id = {record["step"]: record for record in right_steps}
    left_max = max(left_ids) if left_ids else None
    right_max = max(right_ids) if right_ids else None
    for sid in sorted(set(left_ids) | set(right_ids)):
        in_left = sid in left_by_id
        in_right = sid in right_by_id
        if in_left and in_right:
            record_left = left_by_id[sid]
            record_right = right_by_id[sid]
            for field in ("kind", "schema_version", "shot_id"):
                if record_left.get(field) != record_right.get(field):
                    category = "step_placement" if field == "shot_id" else "event_structure"
                    out.append(Difference(
                        category, "step.%s" % field,
                        "step.%d.%s" % (sid, field), sid,
                        record_left.get(field), record_right.get(field)))
        elif in_left:
            category = "completion" if right_max is None or sid > right_max else "step_placement"
            out.append(Difference(category, "step[]", "step.%d" % sid, sid,
                                  "present", "missing"))
        else:
            category = "completion" if left_max is None or sid > left_max else "step_placement"
            out.append(Difference(category, "step[]", "step.%d" % sid, sid,
                                  "missing", "present"))


def compare_event_streams(left_steps, right_steps, out):
    left_events = collect_events(left_steps)
    right_events = collect_events(right_steps)
    left_keys = [event["key"] for event in left_events]
    right_keys = [event["key"] for event in right_events]
    matcher = SequenceMatcher(None, left_keys, right_keys, autojunk=False)
    left_matched = [False] * len(left_events)
    right_matched = [False] * len(right_events)
    pairs = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            for offset in range(i2 - i1):
                left_index = i1 + offset
                right_index = j1 + offset
                left_matched[left_index] = True
                right_matched[right_index] = True
                pairs.append((left_index, right_index))
    for left_index, right_index in pairs:
        left_event = left_events[left_index]
        right_event = right_events[right_index]
        path = ["step.%d" % left_event["step"],
                "%s[%d]" % (left_event["list"], left_event["index"])]
        norm = ["%s[]" % left_event["list"]]
        compare_value(left_event["event"], right_event["event"], left_event["list"],
                      path, norm, left_event["step"], out)

    left_extra = [i for i, matched in enumerate(left_matched) if not matched]
    right_extra = [j for j, matched in enumerate(right_matched) if not matched]
    left_counter = Counter(left_keys[i] for i in left_extra)
    right_counter = Counter(right_keys[j] for j in right_extra)
    common = left_counter & right_counter
    used_left = Counter()
    used_right = Counter()
    for index in left_extra:
        key = left_keys[index]
        if used_left[key] >= common.get(key, 0):
            continue
        candidates = [j for j in right_extra
                      if right_keys[j] == key]
        right_index = None
        for candidate in candidates:
            if used_right[candidate] < common.get(key, 0):
                right_index = candidate
                break
        if right_index is None:
            continue
        used_left[key] += 1
        used_right[right_index] += 1
        left_event = left_events[index]
        right_event = right_events[right_index]
        out.append(Difference(
            "step_placement", left_event["list"] + "[]",
            "step.%d.%s[%d] -> step.%d.%s[%d]" % (
                left_event["step"], left_event["list"], left_event["index"],
                right_event["step"], right_event["list"], right_event["index"]),
            left_event["step"], left_event["event"], right_event["event"]))
    for index in left_extra:
        key = left_keys[index]
        if used_left[key] > 0:
            used_left[key] -= 1
            continue
        event = left_events[index]
        out.append(Difference(
            "event_structure", event["list"] + "[]",
            "step.%d.%s[%d]" % (event["step"], event["list"], event["index"]),
            event["step"], event["event"], "missing"))
    for index in right_extra:
        if used_right[index] > 0:
            used_right[index] -= 1
            continue
        event = right_events[index]
        out.append(Difference(
            "event_structure", event["list"] + "[]",
            "step.%d.%s[%d]" % (event["step"], event["list"], event["index"]),
            event["step"], "missing", event["event"]))


def compare_headers(left_header, right_header, out):
    scope_metadata = {"math_backend", "include_snapshot"}
    for key in sorted((set(left_header) | set(right_header)) - scope_metadata):
        if key not in left_header or key not in right_header:
            out.append(Difference("event_structure", "header.%s" % key,
                                  "header.%s" % key, 0,
                                  left_header.get(key), right_header.get(key)))
        elif left_header[key] != right_header[key]:
            out.append(Difference("event_structure", "header.%s" % key,
                                  "header.%s" % key, 0,
                                  left_header[key], right_header[key]))


def classify_expected_leaf(path):
    if not path:
        return "event_structure"
    if path[0] == "completion":
        return "completion"
    if path[0] in ("result", "action", "seed"):
        return "score"
    if path[0] == "trace" and len(path) > 1 and path[1] == "events":
        return "completion"
    return "event_structure"


def compare_expected_value(left, right, path, out):
    if isinstance(left, dict) and isinstance(right, dict):
        for key in sorted(set(left) | set(right)):
            compare_expected_value(left.get(key), right.get(key), path + [key], out)
        return
    if isinstance(left, list) and isinstance(right, list):
        if len(left) != len(right):
            out.append(Difference("event_structure", "expected." + ".".join(path),
                                  "expected." + ".".join(path), 0, len(left), len(right)))
        for index in range(min(len(left), len(right))):
            compare_expected_value(left[index], right[index],
                                   path + ["[%d]" % index], out)
        return
    if is_number(left) and is_number(right):
        if float_bits(left) == float_bits(right):
            return
        distance = None
        if (isinstance(left, float) or isinstance(right, float)
                or (path and path[-1] in FLOAT_FIELDS)):
            distance = ulp_distance(left, right)
        out.append(Difference(classify_expected_leaf(path), "expected." + ".".join(path),
                              "expected." + ".".join(path), 0, left, right, distance))
        return
    if left != right:
        out.append(Difference(classify_expected_leaf(path), "expected." + ".".join(path),
                              "expected." + ".".join(path), 0, left, right))


def compare_expected_pair(left, right, trace_volatile_only, control, out):
    for key in ("format", "schema_version", "id", "category", "kind"):
        if left.get(key) != right.get(key):
            out.append(Difference("event_structure", "expected.%s" % key,
                                  "expected.%s" % key, 0,
                                  left.get(key), right.get(key)))
    for section in ("source", "seed", "action", "completion", "result"):
        if section in left or section in right:
            compare_expected_value(left.get(section), right.get(section),
                                   [section], out)
    left_trace = left.get("trace") or {}
    right_trace = right.get("trace") or {}
    if left_trace.get("path") != right_trace.get("path"):
        out.append(Difference("event_structure", "expected.trace.path",
                              "expected.trace.path", 0,
                              left_trace.get("path"), right_trace.get("path")))
    if left_trace.get("events") != right_trace.get("events"):
        out.append(Difference("completion", "expected.trace.events",
                              "expected.trace.events", 0,
                              left_trace.get("events"), right_trace.get("events")))
    if left_trace.get("sha256") != right_trace.get("sha256"):
        if trace_volatile_only:
            category = "volatile_animation"
        elif control:
            category = "event_structure"
        else:
            category = "trace_hash_metadata"
        out.append(Difference(category, "expected.trace.sha256",
                              "expected.trace.sha256", 0,
                              left_trace.get("sha256"), right_trace.get("sha256")))


def allowed_volatile_fields(paths):
    """Approved subset: never invents paths outside the explicit allowlist."""
    return sorted(set(paths) & set(VOLATILE_ANIMATION_FIELDS))


def is_metadata_path(norm_path):
    if norm_path.endswith("[]") or norm_path == "step":
        return True
    if norm_path.startswith("header."):
        return True
    return norm_path == "expected.trace.sha256"


def path_allowed(norm_path, allowed):
    for prefix in allowed:
        if norm_path == prefix or norm_path.startswith(prefix + "."):
            return True
    return False


def load_volatile_paths(path):
    if not path:
        return []
    report = load_json_file(path)
    if isinstance(report, list):
        paths = [str(item) for item in report]
    else:
        paths = list(report.get("volatile_paths_discovered") or [])
        if not paths:
            for fixture in (report.get("fixtures") or {}).values():
                paths.extend((fixture.get("difference_counts") or {}).keys())
    unapproved = sorted(set(paths) - set(VOLATILE_ANIMATION_FIELDS))
    if unapproved:
        raise InputError(
            "volatile report %s contains path(s) outside the explicit "
            "allowlist: %s" % (path, ", ".join(unapproved)))
    return allowed_volatile_fields(paths)


def analyze_fixture(fixture, left_traces, right_traces, left_expected,
                    right_expected, allowed_volatile, control,
                    strict_reference, failures):
    left_path = os.path.join(left_traces, fixture + ".jsonl")
    right_path = os.path.join(right_traces, fixture + ".jsonl")
    left_exists = os.path.exists(left_path)
    right_exists = os.path.exists(right_path)
    if left_exists != right_exists:
        failures.append({"fixture": fixture, "reason": "trace exists on one side only"})
        return None
    differences = []
    left_header = {}
    right_header = {}
    left_step_by_id = {}
    right_step_by_id = {}
    state_comparison = "not_captured"
    snapshot_steps_compared = 0
    if left_exists:
        left_header, left_steps = load_trace(left_path)
        right_header, right_steps = load_trace(right_path)
        if control:
            for side, header in (("left", left_header), ("right", right_header)):
                backend = header.get("math_backend")
                if backend is not None and backend.get("name") != "system_libm":
                    failures.append({
                        "fixture": fixture,
                        "reason": "control %s trace was captured with backend %r"
                                  % (side, backend.get("name")),
                    })
        left_step_by_id = {record["step"]: record for record in left_steps}
        right_step_by_id = {record["step"]: record for record in right_steps}
        compare_headers(left_header, right_header, differences)
        compare_event_steps(left_steps, right_steps, differences)
        compare_event_streams(left_steps, right_steps, differences)
        state_comparison, snapshot_steps_compared = compare_snapshots(
            left_steps, right_steps, control, differences)
        for diff in differences:
            if path_allowed(diff.path, allowed_volatile):
                diff.category = "volatile_animation"

    state_scope = {
        "left_include_snapshot": left_header.get("include_snapshot"),
        "right_include_snapshot": right_header.get("include_snapshot"),
    }

    has_left_expected = fixture in left_expected
    has_right_expected = fixture in right_expected
    if has_left_expected != has_right_expected:
        failures.append({"fixture": fixture, "reason": "expected record on one side only"})
        return None
    expected_differences = []
    if has_left_expected:
        trace_volatile_only = bool(differences) and all(
            diff.category == "volatile_animation" for diff in differences)
        compare_expected_pair(left_expected[fixture], right_expected[fixture],
                              trace_volatile_only, control, expected_differences)
    result = format_fixture(fixture, differences, expected_differences,
                            left_header, right_header, left_exists,
                            left_step_by_id, right_step_by_id,
                            state_comparison, snapshot_steps_compared,
                            state_scope)
    if control:
        for diff in expected_differences:
            if diff.category not in ("volatile_animation", "trace_hash_metadata"):
                failures.append({
                    "fixture": fixture,
                    "reason": "expected record difference %s (%s)"
                              % (diff.full_path, diff.category),
                })
    if strict_reference:
        reference_diffs = [
            diff for diff in differences
            if diff.category not in ("volatile_animation", "trace_hash_metadata")]
        if not reference_diffs:
            reference_diffs = [
                diff for diff in expected_differences
                if diff.category not in ("volatile_animation", "trace_hash_metadata")]
        if reference_diffs:
            first_reference = pick_first(reference_diffs)
            failures.append({
                "fixture": fixture,
                "reason": "reference difference outside the explicit volatile "
                          "allowlist: %s (%s)"
                          % (first_reference.full_path, first_reference.category),
            })
    return result


def pick_first(differences):
    if not differences:
        return None
    def order(pair):
        index, diff = pair
        return (diff.step if diff.step is not None else -1, index)
    return min(enumerate(differences), key=order)[1]


def format_fixture(fixture, differences, expected_differences,
                   left_header, right_header, traces_compared,
                   left_step_by_id, right_step_by_id, state_comparison,
                   snapshot_steps_compared, state_scope):
    classification_counts = Counter()
    difference_counts = Counter()
    state_difference_counts = Counter()
    ulp_histogram = Counter()
    volatile_paths = []
    for diff in differences:
        classification_counts[diff.category] += 1
        difference_counts[diff.path] += 1
        if diff.category in ("state_structure", "state_bit_difference"):
            state_difference_counts[diff.path] += 1
        if diff.category in ("value_bit_difference", "state_bit_difference"):
            ulp_histogram[ulp_bucket(diff.ulp)] += 1
        if diff.category == "volatile_animation":
            volatile_paths.append(diff.path)
    first = pick_first(differences)
    first_difference = None
    if first is not None:
        first_difference = first.as_first_difference()
        first_difference["left_step_json"] = left_step_by_id.get(first.step)
        first_difference["right_step_json"] = right_step_by_id.get(first.step)
    first_expected = None
    expected_nonvolatile = 0
    for diff in expected_differences:
        classification_counts[diff.category] += 1
        difference_counts[diff.path] += 1
        if diff.ulp is not None and diff.category in ("score", "completion"):
            ulp_histogram[ulp_bucket(diff.ulp)] += 1
        if diff.category == "volatile_animation":
            volatile_paths.append(diff.full_path)
        if diff.category not in ("volatile_animation", "trace_hash_metadata"):
            expected_nonvolatile += 1
        if first_expected is None:
            first_expected = diff
    semantic = any(diff.category not in ("volatile_animation", "trace_hash_metadata")
                   for diff in differences)
    semantic = semantic or expected_nonvolatile > 0
    return {
        "identical": not semantic,
        "traces_compared": traces_compared,
        "state_comparison": state_comparison,
        "state_scope": state_scope,
        "snapshot_steps_compared": snapshot_steps_compared,
        "state_difference_counts": dict(sorted(state_difference_counts.items())),
        "expected_nonvolatile_differences": expected_nonvolatile,
        "first_difference_step": first.step if first is not None else None,
        "classifications": dict(sorted(classification_counts.items())),
        "difference_counts": dict(sorted(difference_counts.items())),
        "ulp_histogram": dict(sorted(ulp_histogram.items())),
        "first_difference": first_difference,
        "first_expected_difference": (
            first_expected.as_first_difference() if first_expected is not None else None),
        "volatile_differences": sorted(set(volatile_paths)),
        "math_backend": {
            "left": left_header.get("math_backend"),
            "right": right_header.get("math_backend"),
        },
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Compare two canonical gameplay-trace corpora.")
    parser.add_argument("--left-traces", required=True)
    parser.add_argument("--left-expected", required=True)
    parser.add_argument("--right-traces", required=True)
    parser.add_argument("--right-expected", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--control", action="store_true",
                        help="mark this comparison as the system control")
    parser.add_argument("--strict-reference", action="store_true",
                        help="reference-discovery comparison: any difference "
                             "outside the explicit volatile allowlist fails")
    parser.add_argument("--volatile-report", default=None,
                        help="report that discovered the allowed volatile paths")
    parser.add_argument("--volatile-out", default=None,
                        help="write the discovered volatile path list here")
    parser.add_argument("--control-json", default=None,
                        help="embed the control block from this prior report")
    parser.add_argument("--environment-json", default=None)
    parser.add_argument("--left-label", default="left")
    parser.add_argument("--right-label", default="right")
    args = parser.parse_args(argv)

    try:
        reported_volatile = load_volatile_paths(args.volatile_report)
        allowed_volatile = allowed_volatile_fields(
            list(reported_volatile) + list(VOLATILE_ANIMATION_FIELDS))
        left_expected = {}
        for name in sorted(os.listdir(args.left_expected)):
            if name.endswith(".json"):
                left_expected[name[:-5]] = load_json_file(
                    os.path.join(args.left_expected, name))
        right_expected = {}
        for name in sorted(os.listdir(args.right_expected)):
            if name.endswith(".json"):
                right_expected[name[:-5]] = load_json_file(
                    os.path.join(args.right_expected, name))
        trace_ids = set()
        for directory in (args.left_traces, args.right_traces):
            for name in sorted(os.listdir(directory)):
                if name.endswith(".jsonl"):
                    trace_ids.add(name[:-6])
    except (OSError, InputError) as err:
        print("compare_traces: %s" % err, file=sys.stderr)
        return 2

    failures = []
    fixture_results = {}
    semantic_differences = []
    observed_paths = set()
    total_ulps = Counter()
    topics = sorted(trace_ids | set(left_expected) | set(right_expected))
    for fixture in topics:
        try:
            result = analyze_fixture(
                fixture, args.left_traces, args.right_traces,
                left_expected, right_expected, allowed_volatile,
                args.control, args.strict_reference, failures)
        except InputError as err:
            failures.append({"fixture": fixture, "reason": str(err)})
            continue
        if result is None:
            continue
        fixture_results[fixture] = result
        if not result["identical"]:
            semantic_differences.append({
                "fixture": fixture,
                "classifications": result["classifications"],
                "first_difference_step": result["first_difference_step"],
                "first_difference": result["first_difference"],
                "first_expected_difference": result["first_expected_difference"],
                "volatile_differences": result["volatile_differences"],
            })
            if args.control:
                failures.append({
                    "fixture": fixture,
                    "reason": "control differences are not confined to "
                              "documented volatile fields",
                })
        for bucket, count in result["ulp_histogram"].items():
            total_ulps[bucket] += count
        observed_paths.update(result["difference_counts"].keys())

    state_scope_counts = Counter(
        result["state_comparison"] for result in fixture_results.values())
    state_comparison_summary = {
        "full": state_scope_counts.get("full", 0),
        "not_captured": state_scope_counts.get("not_captured", 0),
        "scope_mismatch": state_scope_counts.get("scope_mismatch", 0),
    }
    approved_volatile = allowed_volatile_fields(observed_paths)
    approved_set = set(approved_volatile)
    unapproved_differences = sorted(
        path for path in observed_paths
        if path not in approved_set and not is_metadata_path(path))

    control_block = {
        "clean": not failures and not any(
            not fixture["identical"] for fixture in fixture_results.values()),
        "checked": bool(args.control),
        "strict_reference": bool(args.strict_reference),
        "left_label": args.left_label,
        "right_label": args.right_label,
        "fixtures_compared": len(fixture_results),
        "identical_fixtures": sum(
            1 for fixture in fixture_results.values() if fixture["identical"]),
        "volatile_differences": sum(
            len(fixture["volatile_differences"]) for fixture in fixture_results.values()),
        "volatile_paths": approved_volatile,
        "expected_records_identical": not any(
            fixture["expected_nonvolatile_differences"] > 0
            for fixture in fixture_results.values()),
        "failures": failures,
    }
    if args.control_json:
        prior = load_json_file(args.control_json)
        if isinstance(prior, dict) and isinstance(prior.get("control"), dict):
            control_block = prior["control"]
            control_block["embedded_from"] = os.path.abspath(args.control_json)

    if args.strict_reference:
        mode = "reference_discovery"
    elif args.control:
        mode = "control"
    else:
        mode = "core_vs_system"
    report = {
        "format": FORMAT,
        "schema_version": SCHEMA_VERSION,
        "mode": mode,
        "left": {"label": args.left_label, "traces": os.path.abspath(args.left_traces),
                 "expected": os.path.abspath(args.left_expected)},
        "right": {"label": args.right_label, "traces": os.path.abspath(args.right_traces),
                  "expected": os.path.abspath(args.right_expected)},
        "environment": (json.loads(args.environment_json, parse_int=parse_int)
                        if args.environment_json else None),
        "control": control_block,
        "state_comparison": state_comparison_summary,
        "state_scope_note": (
            STATE_SCOPE_NOTE
            if state_comparison_summary["full"] != len(fixture_results)
            else None),
        "volatile_paths_discovered": approved_volatile,
        "volatile_policy": {
            "source": "explicit-allowlist",
            "known_fields": list(VOLATILE_ANIMATION_FIELDS),
            "allowed_paths": approved_volatile,
            "unapproved_differences": unapproved_differences,
            "note": VOLATILE_NOTE,
        },
        "ulp_histogram": dict(sorted(total_ulps.items())),
        "fixtures": fixture_results,
        "semantic_differences": semantic_differences,
        "failures": failures,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")
    if args.volatile_out:
        with open(args.volatile_out, "w", encoding="utf-8") as handle:
            json.dump(approved_volatile, handle, indent=2)
            handle.write("\n")
    if failures:
        label = "control failure" if args.control else "failure"
        for failure in failures:
            print("compare_traces: %s: %s: %s" % (
                label, failure.get("fixture"), failure.get("reason")),
                file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
