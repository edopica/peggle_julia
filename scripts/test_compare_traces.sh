#!/usr/bin/env bash
# Contract cases for tools/compare_traces.py (WP-E trace comparison).
#
# Builds synthetic trace/expected corpora (no LÖVE, no captures) and requires:
#   * identical snapshot-bearing corpora -> control exit 0, state_comparison
#     "full", complete snapshot_coverage, state_scope_note None;
#   * a mutated authoritative snapshot field -> non-control exit 0 with a
#     semantic state_bit_difference, difference_counts path
#     snapshot.balls[].x, first_difference embedding both step records, and
#     control exit 1;
#   * snapshot-free corpora -> state_comparison "not_captured" and an event
#     vx bit change still classified value_bit_difference;
#   * a bare -0 JSON integer token is preserved as -0.0 and one ULP from 0;
#   * ulp_distance is monotonic across signed zero and subnormals;
#   * a scope mismatch (snapshots on one side only) records
#     "scope_mismatch" without failing --strict-reference, but fails
#     --control;
#   * VOLATILE_ANIMATION_FIELDS is empty: fever-bucket divider y and
#     animating are authoritative (state_bit_difference / state_structure),
#     volatile_differences stay empty, --strict-reference and --control fail,
#     and --volatile-out writes [];
#   * --volatile-report rejects any path outside the empty explicit allowlist
#     (list or discovery-report form) with exit 2 naming the path, while the
#     mechanism still accepts an empty list;
#   * snapshot coverage: a missing per-step snapshot makes state_comparison
#     "partial" (a failure under --control/--strict-reference) with per-side
#     missing step ids in snapshot_coverage; a snapshot missing on both sides
#     at a step is a state_structure difference at normalized path
#     "snapshot"; a snapshot present on one side only reports present/missing;
#   * header include_snapshot must match the observed snapshots: declared true
#     with no snapshots, or snapshots with declared false, are state_structure
#     differences at path "snapshot" (and fail control/strict-reference);
#   * malformed --volatile-report shapes (non-string list entries, a non-list
#     volatile_paths_discovered, or a bare JSON scalar) are exit 2 with a
#     "compare_traces:" message and no Python traceback;
#   * a scope mismatch whose declared side has a per-step hole reports a
#     state_structure hole difference (expected include_snapshot=true, actual
#     "missing on right") that fails --strict-reference and --control, while
#     a legitimately snapshot-free side still passes --strict-reference
#     unchanged.
#   * --require-identical (cross-machine mode, mode name "require_identical"):
#     identical state with different math_backend library/native_identity
#     strings passes and records the metadata (math_backend_identity_equal
#     false); a one-ULP state difference, a different backend name, partial
#     coverage, a scope mismatch, a missing trace on one side, and a missing
#     expected record all fail; --require-identical is mutually exclusive
#     with --control (argparse exit 2).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

python3 - "$scratch" <<'PY'
import json
import math
import os
import sys

base = sys.argv[1]
one_ulp_up = math.nextafter(2.0, math.inf)
event_ulp_up = math.nextafter(100.0, math.inf)


def snapshot(x=10.0, divider_y=2.0, animating=False):
    return {
        "schema_version": 2,
        "step_id": 1,
        "shot_id": 1,
        "level_name": "synthetic",
        "is_fever": False,
        "current_multiplier": 1,
        "hit_counter": 0,
        "total_red_pegs": 3,
        "red_pegs_hit_amount": 0,
        "bonus_score": 0,
        "style_score": 0,
        "turn_peg_count": 0,
        "clearing_active": False,
        "clearing_is_end_of_turn": False,
        "clear_timer": 0,
        "balls": [{
            "id": 1, "x": x, "y": 20.0, "prev_x": 10.0, "prev_y": 10.0,
            "vx": 1.0, "vy": 2.0, "radius": 8.0, "launched": True,
        }],
        "pegs": [{"original_index": 0, "type": "blue", "hit": False,
                  "x": 5.0, "y": 6.0}],
        "bucket": {"x": 100.0, "prev_x": 99.0, "top": 40.0, "hole": 5.0,
                   "edge": 3.0, "height": 10.0, "phase": 0.0},
        "fever_buckets": {
            "top": 0.0,
            "height": 0.0,
            "animating": animating,
            "buckets": [{"x": 1.0, "width": 2.0, "value": 1}],
            "dividers": [{"x": 1.0, "y": divider_y, "radius": 3.0}],
        },
        "turn_pegs_hit": [0],
    }


def event(step_id, vx=100.0):
    return {"ball_id": 1, "phase": "raw", "schema_version": 1, "sequence": 1,
            "shot_id": step_id, "step": step_id, "type": "ball_launched",
            "vx": vx, "vy": 89.0, "x": 600.0, "y": 50.0}


def corpus(name, header_include, steps, backend=None):
    traces = os.path.join(base, name, "traces")
    expected = os.path.join(base, name, "expected")
    os.makedirs(traces, exist_ok=True)
    os.makedirs(expected, exist_ok=True)
    header = {"kind": "gameplay_trace", "schema_version": 1,
              "include_snapshot": header_include,
              "math_backend": backend if backend is not None
              else {"name": "system_libm"}}
    lines = [json.dumps(header, sort_keys=True)]
    for step_id, snapshot_value, vx in steps:
        step = {"kind": "step", "schema_version": 1, "step": step_id,
                "shot_id": step_id,
                "raw_events": [event(step_id, vx)], "derived_events": [],
                "requested_commands": [], "applied_commands": []}
        if snapshot_value is not None:
            step["snapshot"] = snapshot_value
        lines.append(json.dumps(step, sort_keys=True))
    with open(os.path.join(traces, "fixture.jsonl"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    with open(os.path.join(expected, "fixture.json"), "w", encoding="utf-8") as handle:
        json.dump({}, handle)


def expected_only(name):
    os.makedirs(os.path.join(base, name, "traces"), exist_ok=True)
    expected = os.path.join(base, name, "expected")
    os.makedirs(expected, exist_ok=True)
    with open(os.path.join(expected, "fixture.json"), "w", encoding="utf-8") as handle:
        json.dump({}, handle)


def raw_corpus(name, step_line):
    traces = os.path.join(base, name, "traces")
    expected = os.path.join(base, name, "expected")
    os.makedirs(traces, exist_ok=True)
    os.makedirs(expected, exist_ok=True)
    header = ('{"include_snapshot":false,"kind":"gameplay_trace",'
              '"math_backend":{"name":"system_libm"},"schema_version":1}')
    with open(os.path.join(traces, "fixture.jsonl"), "w", encoding="utf-8") as handle:
        handle.write(header + "\n")
        handle.write(step_line + "\n")
    with open(os.path.join(expected, "fixture.json"), "w", encoding="utf-8") as handle:
        json.dump({}, handle)


corpus("snap_left", True, [(1, snapshot(), 100.0)])
corpus("snap_right", True, [(1, snapshot(), 100.0)])
corpus("snap_mut", True, [(1, snapshot(x=999.0), 100.0)])

corpus("event_left", False, [(1, None, 100.0)])
corpus("event_right", False, [(1, None, event_ulp_up)])

corpus("scope_left", False, [(1, None, 100.0)])
corpus("scope_right", True, [(1, snapshot(), 100.0)])

corpus("scope_hole_left", False, [(1, None, 100.0), (2, None, 100.0)])
corpus("scope_hole_right", True, [(1, snapshot(), 100.0), (2, None, 100.0)])

corpus("div_left", True, [(1, snapshot(), 100.0)])
corpus("div_right", True, [(1, snapshot(divider_y=one_ulp_up), 100.0)])

corpus("vol_left", True, [(1, snapshot(), 100.0)])
corpus("vol_right", True,
       [(1, snapshot(divider_y=one_ulp_up, animating=True), 100.0)])

corpus("coverage_left", True, [(1, snapshot(), 100.0), (2, None, 100.0)])
corpus("coverage_right", True, [(1, snapshot(), 100.0), (2, None, 100.0)])

corpus("hole_left", True, [(1, snapshot(), 100.0), (2, snapshot(), 100.0)])
corpus("hole_right", True, [(1, snapshot(), 100.0), (2, None, 100.0)])

corpus("declared_left", True, [(1, None, 100.0)])
corpus("declared_right", True, [(1, None, 100.0)])

corpus("undeclared_left", False, [(1, snapshot(), 100.0)])
corpus("undeclared_right", False, [(1, snapshot(), 100.0)])

core_backend_left = {
    "name": "core_math", "abi_version": 1,
    "library": "/host/left/native/linux-x86_64/libpeggle_math.so",
    "native_identity": '{"platform":"linux-x86_64"}',
}
core_backend_right = {
    "name": "core_math", "abi_version": 1,
    "library": "/host/right/native/darwin-aarch64/libpeggle_math.dylib",
    "native_identity": '{"platform":"darwin-aarch64"}',
}
corpus("req_left", True, [(1, snapshot(), 100.0)], backend=core_backend_left)
corpus("req_right", True, [(1, snapshot(), 100.0)], backend=core_backend_right)
corpus("req_name_right", True, [(1, snapshot(), 100.0)],
       backend={"name": "system_libm"})
expected_only("req_missing_trace_right")

raw_event = ('{"ball_id":1,"phase":"raw","schema_version":1,"sequence":1,'
             '"shot_id":1,"step":1,"type":"ball_launched","vx":{vx},'
             '"vy":89.0,"x":600.0,"y":50.0}')
raw_step = ('{"applied_commands":[],"derived_events":[],"kind":"step",'
            '"raw_events":[%s],"requested_commands":[],"schema_version":1,'
            '"shot_id":1,"step":1}')
raw_corpus("negzero_left", raw_step % (raw_event.replace("{vx}", "-0"),))
raw_corpus("negzero_right", raw_step % (raw_event.replace("{vx}", "0"),))

with open(os.path.join(base, "unapproved.json"), "w", encoding="utf-8") as handle:
    json.dump(["snapshot.balls[].x"], handle)
with open(os.path.join(base, "unapproved_report.json"), "w", encoding="utf-8") as handle:
    json.dump({"volatile_paths_discovered": ["snapshot.balls[].x"]}, handle)
with open(os.path.join(base, "unapproved_divider.json"), "w", encoding="utf-8") as handle:
    json.dump(["snapshot.fever_buckets.dividers[].y"], handle)
with open(os.path.join(base, "empty_allowlist.json"), "w", encoding="utf-8") as handle:
    json.dump([], handle)
with open(os.path.join(base, "malformed_entry_report.json"), "w", encoding="utf-8") as handle:
    json.dump({"volatile_paths_discovered": [None]}, handle)
with open(os.path.join(base, "malformed_field_report.json"), "w", encoding="utf-8") as handle:
    json.dump({"volatile_paths_discovered": "x"}, handle)
with open(os.path.join(base, "malformed_scalar_report.json"), "w", encoding="utf-8") as handle:
    json.dump("just-a-string", handle)
PY

fail() {
  echo "test_compare_traces: FAIL: $*" >&2
  exit 1
}

run_capture() {
  local expected_code="$1"
  shift
  set +e
  output="$(python3 tools/compare_traces.py "$@" 2>&1)"
  code=$?
  set -e
  [[ $code -eq $expected_code ]] ||
    fail "expected exit $expected_code, got $code: $output"
}

base() {
  corpus_args=(--left-traces "$scratch/$1/traces"
               --left-expected "$scratch/$1/expected"
               --right-traces "$scratch/$2/traces"
               --right-expected "$scratch/$2/expected")
}

# 1. Identical snapshot corpora: control clean, full state comparison.
base snap_left snap_right
run_capture 0 "${corpus_args[@]}" --control --out "$scratch/report1.json"

# 2. Snapshot mutation: non-control reports a semantic difference, control fails.
base snap_left snap_mut
run_capture 0 "${corpus_args[@]}" --out "$scratch/report2.json"
run_capture 1 "${corpus_args[@]}" --control --out "$scratch/report2c.json"

# 3. Snapshot-free corpora: event comparison only, event bits still compared.
base event_left event_right
run_capture 0 "${corpus_args[@]}" --out "$scratch/report3.json"

# 4. Bare -0 JSON integer token versus 0.
base negzero_left negzero_right
run_capture 0 "${corpus_args[@]}" --out "$scratch/report4.json"

# 6. Scope mismatch: fails a control, never --strict-reference by itself.
base scope_left scope_right
run_capture 0 "${corpus_args[@]}" --strict-reference --out "$scratch/report6.json"
run_capture 0 "${corpus_args[@]}" --out "$scratch/report6b.json"
run_capture 1 "${corpus_args[@]}" --control --out "$scratch/report6c.json"

# 7. Strict reference: unapproved event and snapshot differences fail.
base event_left event_right
run_capture 1 "${corpus_args[@]}" --strict-reference --out "$scratch/report7a.json"
grep -q "outside the explicit volatile allowlist" <<< "$output" ||
  fail "strict-reference failure did not name the allowlist: $output"
base snap_left snap_mut
run_capture 1 "${corpus_args[@]}" --strict-reference --out "$scratch/report7b.json"

# 8. Divider y is authoritative: plain run reports it, strict/control fail.
base div_left div_right
run_capture 0 "${corpus_args[@]}" --out "$scratch/report8.json"
run_capture 1 "${corpus_args[@]}" --strict-reference --out "$scratch/report8s.json"
grep -q "snapshot.fever_buckets.dividers\[0\].y" <<< "$output" ||
  fail "strict-reference divider failure did not name the path: $output"
run_capture 1 "${corpus_args[@]}" --control --out "$scratch/report8c.json"

# 9. Animating and divider are both authoritative; the allowlist stays empty.
base vol_left vol_right
run_capture 1 "${corpus_args[@]}" --strict-reference \
  --volatile-out "$scratch/volatile.json" --out "$scratch/report9.json"

# 10. --volatile-report rejects any path (empty allowlist); [] still accepted.
base snap_left snap_right
run_capture 2 "${corpus_args[@]}" --volatile-report "$scratch/unapproved.json" \
  --out "$scratch/report10a.json"
grep -q "snapshot.balls\[\].x" <<< "$output" ||
  fail "unapproved volatile list path was not named: $output"
run_capture 2 "${corpus_args[@]}" --volatile-report "$scratch/unapproved_report.json" \
  --out "$scratch/report10b.json"
grep -q "snapshot.balls\[\].x" <<< "$output" ||
  fail "unapproved volatile report path was not named: $output"
run_capture 2 "${corpus_args[@]}" --volatile-report "$scratch/unapproved_divider.json" \
  --out "$scratch/report10c.json"
grep -q "snapshot.fever_buckets.dividers\[\].y" <<< "$output" ||
  fail "unapproved divider path was not named: $output"
run_capture 0 "${corpus_args[@]}" --volatile-report "$scratch/empty_allowlist.json" \
  --out "$scratch/report10d.json"

# 11. Missing snapshot on both sides at step 2: partial coverage failure.
base coverage_left coverage_right
run_capture 0 "${corpus_args[@]}" --out "$scratch/report11.json"
run_capture 1 "${corpus_args[@]}" --control --out "$scratch/report11c.json"
grep -q "snapshot coverage incomplete" <<< "$output" ||
  fail "control coverage failure did not explain the gap: $output"
run_capture 1 "${corpus_args[@]}" --strict-reference --out "$scratch/report11s.json"

# 12. Snapshot on one side only at step 2: partial coverage, present/missing.
base hole_left hole_right
run_capture 0 "${corpus_args[@]}" --out "$scratch/report12.json"
run_capture 1 "${corpus_args[@]}" --control --out "$scratch/report12c.json"

# 13. Header declares include_snapshot=true but carries no snapshots: partial.
base declared_left declared_right
run_capture 0 "${corpus_args[@]}" --out "$scratch/report13.json"
run_capture 1 "${corpus_args[@]}" --control --out "$scratch/report13c.json"
run_capture 1 "${corpus_args[@]}" --strict-reference --out "$scratch/report13s.json"

# 14. Snapshots present but header declares include_snapshot=false: full data.
base undeclared_left undeclared_right
run_capture 0 "${corpus_args[@]}" --out "$scratch/report14.json"
run_capture 1 "${corpus_args[@]}" --control --out "$scratch/report14c.json"
run_capture 1 "${corpus_args[@]}" --strict-reference --out "$scratch/report14s.json"

# 15. Malformed --volatile-report input is exit 2 with a compare_traces: message.
base snap_left snap_right
run_capture 2 "${corpus_args[@]}" --volatile-report "$scratch/malformed_entry_report.json" \
  --out "$scratch/report15a.json"
grep -q "compare_traces:" <<< "$output" ||
  fail "malformed entry report did not use the compare_traces: message: $output"
grep -q "Traceback" <<< "$output" &&
  fail "malformed entry report raised a traceback: $output"
run_capture 2 "${corpus_args[@]}" --volatile-report "$scratch/malformed_field_report.json" \
  --out "$scratch/report15b.json"
grep -q "compare_traces:" <<< "$output" ||
  fail "malformed field report did not use the compare_traces: message: $output"
grep -q "Traceback" <<< "$output" &&
  fail "malformed field report raised a traceback: $output"
run_capture 2 "${corpus_args[@]}" --volatile-report "$scratch/malformed_scalar_report.json" \
  --out "$scratch/report15c.json"
grep -q "compare_traces:" <<< "$output" ||
  fail "malformed scalar report did not use the compare_traces: message: $output"
grep -q "Traceback" <<< "$output" &&
  fail "malformed scalar report raised a traceback: $output"

# 16. Scope mismatch with a declared per-step hole on the right: strict fails.
base scope_hole_left scope_hole_right
run_capture 1 "${corpus_args[@]}" --strict-reference --out "$scratch/report16.json"
run_capture 0 "${corpus_args[@]}" --out "$scratch/report16b.json"
run_capture 1 "${corpus_args[@]}" --control --out "$scratch/report16c.json"

# 17. require-identical: differing backend library/identity metadata passes.
base req_left req_right
run_capture 0 "${corpus_args[@]}" --require-identical --out "$scratch/report17.json"

# 18. require-identical: one-ULP state difference fails.
base snap_left snap_mut
run_capture 1 "${corpus_args[@]}" --require-identical --out "$scratch/report18.json"

# 19. require-identical: different backend names fail.
base req_left req_name_right
run_capture 1 "${corpus_args[@]}" --require-identical --out "$scratch/report19.json"
grep -q "backend names differ" <<< "$output" ||
  fail "backend-name failure did not explain the mismatch: $output"

# 20. require-identical: partial coverage and scope mismatch fail.
base coverage_left coverage_right
run_capture 1 "${corpus_args[@]}" --require-identical --out "$scratch/report20a.json"
grep -q "snapshot coverage incomplete" <<< "$output" ||
  fail "require-identical coverage failure did not explain the gap: $output"
base scope_left scope_right
run_capture 1 "${corpus_args[@]}" --require-identical --out "$scratch/report20b.json"

# 21. require-identical: a trace missing on one side fails.
base snap_left req_missing_trace_right
run_capture 1 "${corpus_args[@]}" --require-identical --out "$scratch/report21.json"
grep -q "trace exists on one side only" <<< "$output" ||
  fail "require-identical missing-trace failure did not explain: $output"

# 22. require-identical is mutually exclusive with --control (argparse exit 2).
base snap_left snap_right
run_capture 2 "${corpus_args[@]}" --require-identical --control --out "$scratch/report22.json"
grep -q "not allowed with" <<< "$output" ||
  fail "mutual exclusion was not an argparse error: $output"

# 5. ULP unit assertions, imported from the repo path.
python3 - "$repo_root" <<'PY'
import importlib.util
import math
import os
import sys

path = os.path.join(sys.argv[1], "tools", "compare_traces.py")
spec = importlib.util.spec_from_file_location("compare_traces_under_test", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

assert module.ulp_distance(0.0, -0.0) == 1
assert module.ulp_distance(-0.0, 5e-324) == 2
assert module.ulp_distance(0.0, 5e-324) == 1
assert module.ulp_distance(-5e-324, 5e-324) == 3
assert module.ulp_distance(float("nan"), 0.0) is None
assert module.ulp_distance(0.0, float("nan")) is None
assert module.ulp_distance(float("-inf"), float("inf")) > 0
assert module.ulp_distance(1.0, math.nextafter(1.0, math.inf)) == 1
PY

python3 - "$scratch" <<'PY'
import json
import math
import os
import sys

base = sys.argv[1]


def load(name):
    with open(os.path.join(base, name), "r", encoding="utf-8") as handle:
        return json.load(handle)


def check(condition, message):
    if not condition:
        raise SystemExit("test_compare_traces check failed: " + message)


full_coverage = {"steps_total": 1, "steps_with_snapshot": 1, "missing_steps": []}

r1 = load("report1.json")
fixture1 = r1["fixtures"]["fixture"]
check(r1["mode"] == "control", "report1 mode")
check(fixture1["state_comparison"] == "full", "report1 full state")
check(fixture1["identical"] is True, "report1 identical")
check(fixture1["snapshot_steps_compared"] == 1, "report1 snapshot steps")
check(fixture1["snapshot_coverage"]["left"] == full_coverage,
      "report1 left coverage")
check(fixture1["snapshot_coverage"]["right"] == full_coverage,
      "report1 right coverage")
check(r1["state_comparison"] == {"full": 1, "partial": 0, "not_captured": 0,
                                 "scope_mismatch": 0},
      "report1 state summary")
check(r1["state_scope_note"] is None, "report1 state note")
check(r1["control"]["clean"] is True, "report1 control clean")
check(r1["control"]["strict_reference"] is False, "report1 strict flag")
check(r1["volatile_policy"]["known_fields"] == [], "report1 known fields empty")

r2 = load("report2.json")
fixture2 = r2["fixtures"]["fixture"]
check(fixture2["identical"] is False, "report2 semantic difference")
check(fixture2["classifications"] == {"state_bit_difference": 1},
      "report2 classification")
check(fixture2["difference_counts"].get("snapshot.balls[].x") == 1,
      "report2 difference path")
check(fixture2["state_difference_counts"].get("snapshot.balls[].x") == 1,
      "report2 state difference path")
check(fixture2["state_comparison"] == "full", "report2 full state")
first2 = fixture2["first_difference"]
check(first2["step"] == 1, "report2 first step")
check(first2["path"] == "step.1.snapshot.balls[0].x", "report2 first path")
check(first2["expected"] == 10.0 and first2["actual"] == 999.0,
      "report2 first values")
check(first2["ulp"] is not None and first2["ulp"] > 0, "report2 first ulp")
check(first2["left_step_json"]["snapshot"]["balls"][0]["x"] == 10.0,
      "report2 left step embeds snapshot")
check(first2["right_step_json"]["snapshot"]["balls"][0]["x"] == 999.0,
      "report2 right step embeds snapshot")
check(sum(r2["ulp_histogram"].values()) == 1, "report2 ulp histogram")

r3 = load("report3.json")
fixture3 = r3["fixtures"]["fixture"]
check(fixture3["state_comparison"] == "not_captured", "report3 state scope")
check(fixture3["classifications"] == {"value_bit_difference": 1},
      "report3 classification")
check(fixture3["difference_counts"].get("raw_events[].vx") == 1,
      "report3 difference path")
check(fixture3["state_scope"] == {"left_include_snapshot": False,
                                  "right_include_snapshot": False},
      "report3 state scope metadata")
check(r3["state_comparison"] == {"full": 0, "partial": 0, "not_captured": 1,
                                 "scope_mismatch": 0},
      "report3 state summary")
check(isinstance(r3["state_scope_note"], str) and r3["state_scope_note"],
      "report3 scope note")
zero_coverage = {"steps_total": 1, "steps_with_snapshot": 0, "missing_steps": [1]}
check(fixture3["snapshot_coverage"]["left"] == zero_coverage,
      "report3 left coverage zeros")
check(fixture3["snapshot_coverage"]["right"] == zero_coverage,
      "report3 right coverage zeros")

r4 = load("report4.json")
first4 = r4["fixtures"]["fixture"]["first_difference"]
check(first4["path"] == "step.1.raw_events[0].vx", "report4 path")
check(first4["expected"] == 0.0 and
      math.copysign(1.0, first4["expected"]) == -1.0, "report4 signed -0")
check(first4["actual"] == 0.0 and
      math.copysign(1.0, first4["actual"]) == 1.0, "report4 signed +0")
check(first4["ulp"] == 1, "report4 signed-zero ulp")

r6 = load("report6.json")
check(r6["mode"] == "reference_discovery", "report6 mode")
check(r6["failures"] == [], "report6 strict must not fail scope mismatch")
fixture6 = r6["fixtures"]["fixture"]
check(fixture6["state_comparison"] == "scope_mismatch", "report6 scope")
check(fixture6["identical"] is True, "report6 identical")
check(fixture6["state_scope"] == {"left_include_snapshot": False,
                                  "right_include_snapshot": True},
      "report6 scope metadata")
check(fixture6["snapshot_steps_compared"] == 0, "report6 steps compared")

r6b = load("report6b.json")
check(r6b["fixtures"]["fixture"]["state_comparison"] == "scope_mismatch",
      "report6b scope")
check(r6b["state_comparison"] == {"full": 0, "partial": 0, "not_captured": 0,
                                  "scope_mismatch": 1},
      "report6b state summary")

r8 = load("report8.json")
fixture8 = r8["fixtures"]["fixture"]
check(fixture8["classifications"] == {"state_bit_difference": 1},
      "report8 divider classification")
check(fixture8["difference_counts"].get("snapshot.fever_buckets.dividers[].y") == 1,
      "report8 divider path")
check(fixture8["volatile_differences"] == [],
      "report8 divider is never volatile")

r9 = load("report9.json")
fixture9 = r9["fixtures"]["fixture"]
check(fixture9["classifications"] == {"state_bit_difference": 1,
                                      "state_structure": 1},
      "report9 authoritative classifications")
check(fixture9["difference_counts"].get("snapshot.fever_buckets.dividers[].y") == 1,
      "report9 divider path")
check(fixture9["difference_counts"].get("snapshot.fever_buckets.animating") == 1,
      "report9 animating path")
check(fixture9["volatile_differences"] == [], "report9 volatile differences")
check(r9["volatile_paths_discovered"] == [],
      "report9 discovered paths stay empty")
check(r9["volatile_policy"]["source"] == "explicit-allowlist",
      "report9 policy source")
check(r9["volatile_policy"]["known_fields"] == [], "report9 known fields")
check(r9["volatile_policy"]["allowed_paths"] == [], "report9 allowed paths")
check(r9["volatile_policy"]["unapproved_differences"] ==
      ["snapshot.fever_buckets.animating",
       "snapshot.fever_buckets.dividers[].y"],
      "report9 unapproved differences")
with open(os.path.join(base, "volatile.json"), "r", encoding="utf-8") as handle:
    volatile_out = json.load(handle)
check(volatile_out == [], "volatile-out stays empty")

r10d = load("report10d.json")
check(r10d["mode"] == "core_vs_system", "report10d mode")
check(r10d["fixtures"]["fixture"]["identical"] is True,
      "report10d empty allowlist accepted")
check(r10d["volatile_policy"]["allowed_paths"] == [],
      "report10d allowed paths stay empty")

r11 = load("report11.json")
fixture11 = r11["fixtures"]["fixture"]
check(fixture11["state_comparison"] == "partial", "report11 partial state")
check(fixture11["snapshot_steps_compared"] == 1, "report11 steps compared")
partial_coverage = {"steps_total": 2, "steps_with_snapshot": 1,
                    "missing_steps": [2]}
check(fixture11["snapshot_coverage"]["left"] == partial_coverage,
      "report11 left coverage")
check(fixture11["snapshot_coverage"]["right"] == partial_coverage,
      "report11 right coverage")
check(fixture11["difference_counts"].get("snapshot") == 1,
      "report11 snapshot difference count")
check(fixture11["classifications"] == {"state_structure": 1},
      "report11 classification")
check(fixture11["identical"] is False, "report11 not identical")
first11 = fixture11["first_difference"]
check(first11["step"] == 2, "report11 first step")
check(first11["path"] == "step.2.snapshot", "report11 first path")
check(first11["expected"] == "present" and
      first11["actual"] == "missing on both sides",
      "report11 first values")
check(r11["state_comparison"] == {"full": 0, "partial": 1, "not_captured": 0,
                                  "scope_mismatch": 0},
      "report11 state summary")
check(isinstance(r11["state_scope_note"], str) and r11["state_scope_note"],
      "report11 scope note")

r12 = load("report12.json")
fixture12 = r12["fixtures"]["fixture"]
check(fixture12["state_comparison"] == "partial", "report12 partial state")
check(fixture12["snapshot_steps_compared"] == 1, "report12 steps compared")
check(fixture12["snapshot_coverage"]["left"] ==
      {"steps_total": 2, "steps_with_snapshot": 2, "missing_steps": []},
      "report12 left coverage")
check(fixture12["snapshot_coverage"]["right"] ==
      {"steps_total": 2, "steps_with_snapshot": 1, "missing_steps": [2]},
      "report12 right coverage")
first12 = fixture12["first_difference"]
check(first12["step"] == 2 and first12["path"] == "step.2.snapshot",
      "report12 difference location")
check(first12["expected"] == "present" and first12["actual"] == "missing",
      "report12 difference values")
check(fixture12["classifications"] == {"state_structure": 1},
      "report12 classification")

r13 = load("report13.json")
fixture13 = r13["fixtures"]["fixture"]
check(fixture13["state_comparison"] == "partial", "report13 partial state")
check(fixture13["difference_counts"].get("snapshot") == 2,
      "report13 snapshot difference count")
check(fixture13["classifications"] == {"state_structure": 2},
      "report13 classification")
check(fixture13["identical"] is False, "report13 not identical")
first13 = fixture13["first_difference"]
check(first13["expected"] == "include_snapshot=true" and
      first13["actual"] == "no snapshot records on left",
      "report13 header consistency values")

r14 = load("report14.json")
fixture14 = r14["fixtures"]["fixture"]
check(fixture14["state_comparison"] == "full", "report14 full data scope")
check(fixture14["difference_counts"].get("snapshot") == 2,
      "report14 snapshot difference count")
check(fixture14["classifications"] == {"state_structure": 2},
      "report14 classification")
check(fixture14["identical"] is False, "report14 not identical")
first14 = fixture14["first_difference"]
check(first14["expected"] == "include_snapshot=false" and
      first14["actual"] == "snapshot records present on left",
      "report14 header consistency values")

r16 = load("report16.json")
check(r16["mode"] == "reference_discovery", "report16 mode")
check(r16["failures"] != [], "report16 strict must fail the declared hole")
fixture16 = r16["fixtures"]["fixture"]
check(fixture16["state_comparison"] == "scope_mismatch", "report16 scope")
check(fixture16["snapshot_coverage"]["right"] ==
      {"steps_total": 2, "steps_with_snapshot": 1, "missing_steps": [2]},
      "report16 right coverage")
check(fixture16["snapshot_coverage"]["left"] ==
      {"steps_total": 2, "steps_with_snapshot": 0, "missing_steps": [1, 2]},
      "report16 left coverage")
check(fixture16["difference_counts"].get("snapshot") == 1,
      "report16 snapshot difference count")
check(fixture16["state_difference_counts"].get("snapshot") == 1,
      "report16 state difference count")
first16 = fixture16["first_difference"]
check(first16["step"] == 2 and first16["path"] == "step.2.snapshot",
      "report16 first location")
check(first16["expected"] == "include_snapshot=true" and
      first16["actual"] == "missing on right",
      "report16 first values")

r16b = load("report16b.json")
check(r16b["mode"] == "core_vs_system", "report16b mode")
check(r16b["failures"] == [], "report16b plain run has no failures")
fixture16b = r16b["fixtures"]["fixture"]
check(fixture16b["state_comparison"] == "scope_mismatch", "report16b scope")
check(fixture16b["snapshot_coverage"]["right"] ==
      {"steps_total": 2, "steps_with_snapshot": 1, "missing_steps": [2]},
      "report16b right coverage")
check(fixture16b["snapshot_coverage"]["left"] ==
      {"steps_total": 2, "steps_with_snapshot": 0, "missing_steps": [1, 2]},
      "report16b left coverage")
check(fixture16b["difference_counts"].get("snapshot") == 1,
      "report16b snapshot difference count")
check(fixture16b["state_difference_counts"].get("snapshot") == 1,
      "report16b state difference count")
first16b = fixture16b["first_difference"]
check(first16b["step"] == 2 and first16b["path"] == "step.2.snapshot",
      "report16b first location")
check(first16b["expected"] == "include_snapshot=true" and
      first16b["actual"] == "missing on right",
      "report16b first values")

r17 = load("report17.json")
check(r17["mode"] == "require_identical", "report17 mode")
check(r17["control"]["require_identical"] is True, "report17 control flag")
check(r17["failures"] == [], "report17 must not fail metadata")
fixture17 = r17["fixtures"]["fixture"]
check(fixture17["identical"] is True, "report17 identical")
check(fixture17["state_comparison"] == "full", "report17 full state")
check(fixture17["math_backend_identity_equal"] is False,
      "report17 identity metadata differs")
check(fixture17["math_backend"]["left"]["name"] == "core_math" and
      fixture17["math_backend"]["right"]["name"] == "core_math",
      "report17 backend names equal")
check(fixture17["math_backend"]["left"]["library"] !=
      fixture17["math_backend"]["right"]["library"],
      "report17 library metadata recorded")
check(fixture17["math_backend"]["left"]["native_identity"] !=
      fixture17["math_backend"]["right"]["native_identity"],
      "report17 native identity metadata recorded")
check(fixture17["classifications"] == {} and
      fixture17["expected_nonvolatile_differences"] == 0,
      "report17 no semantic differences")

r18 = load("report18.json")
check(r18["mode"] == "require_identical", "report18 mode")
fixture18 = r18["fixtures"]["fixture"]
check(fixture18["identical"] is False, "report18 semantic difference")
check(fixture18["classifications"] == {"state_bit_difference": 1},
      "report18 classification")
check(r18["failures"] != [], "report18 failure recorded")

r19 = load("report19.json")
check(r19["mode"] == "require_identical", "report19 mode")
check(r19["failures"] != [], "report19 backend-name failure recorded")

r20a = load("report20a.json")
check(r20a["fixtures"]["fixture"]["state_comparison"] == "partial",
      "report20a partial coverage")
check(r20a["failures"] != [], "report20a partial-coverage failure recorded")

r20b = load("report20b.json")
check(r20b["fixtures"]["fixture"]["state_comparison"] == "scope_mismatch",
      "report20b scope mismatch")
check(r20b["failures"] != [], "report20b scope-mismatch failure recorded")

r21 = load("report21.json")
check(r21["failures"] != [], "report21 missing-trace failure recorded")

print("test_compare_traces checks: OK")
PY

echo "test_compare_traces: OK (42 comparison cases, 4 ULP assertions)"
