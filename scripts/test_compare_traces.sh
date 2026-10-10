#!/usr/bin/env bash
# Contract cases for tools/compare_traces.py (WP-E trace comparison).
#
# Builds synthetic trace/expected corpora (no LÖVE, no captures) and requires:
#   * identical snapshot-bearing corpora -> control exit 0, state_comparison
#     "full", identical fixture;
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
#   * --strict-reference fails on any difference outside the explicit
#     volatile allowlist, allows the fever-bucket animation fields,
#     --volatile-out only writes approved paths, and an unapproved
#     --volatile-report path exits 2.
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


def event(vx=100.0):
    return {"ball_id": 1, "phase": "raw", "schema_version": 1, "sequence": 1,
            "shot_id": 1, "step": 1, "type": "ball_launched", "vx": vx,
            "vy": 89.0, "x": 600.0, "y": 50.0}


def corpus(name, snapshot_value=None, header_include=False, event_vx=100.0):
    traces = os.path.join(base, name, "traces")
    expected = os.path.join(base, name, "expected")
    os.makedirs(traces, exist_ok=True)
    os.makedirs(expected, exist_ok=True)
    header = {"kind": "gameplay_trace", "schema_version": 1,
              "include_snapshot": header_include,
              "math_backend": {"name": "system_libm"}}
    step = {"kind": "step", "schema_version": 1, "step": 1, "shot_id": 1,
            "raw_events": [event(event_vx)], "derived_events": [],
            "requested_commands": [], "applied_commands": []}
    if snapshot_value is not None:
        step["snapshot"] = snapshot_value
    with open(os.path.join(traces, "fixture.jsonl"), "w", encoding="utf-8") as handle:
        handle.write(json.dumps(header, sort_keys=True) + "\n")
        handle.write(json.dumps(step, sort_keys=True) + "\n")
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


corpus("snap_left", snapshot_value=snapshot(), header_include=True)
corpus("snap_right", snapshot_value=snapshot(), header_include=True)
corpus("snap_mut", snapshot_value=snapshot(x=999.0), header_include=True)

corpus("event_left", event_vx=100.0)
corpus("event_right", event_vx=event_ulp_up)

corpus("scope_left")
corpus("scope_right", snapshot_value=snapshot(), header_include=True)

corpus("div_left", snapshot_value=snapshot(), header_include=True)
corpus("div_right", snapshot_value=snapshot(divider_y=one_ulp_up),
       header_include=True)

corpus("vol_left", snapshot_value=snapshot(), header_include=True)
corpus("vol_right", snapshot_value=snapshot(divider_y=one_ulp_up,
                                            animating=True),
       header_include=True)

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

# 1. Identical snapshot corpora: control must be clean and compare full state.
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

# Divider animation is allowlisted and never fails a strict reference run.
base div_left div_right
run_capture 0 "${corpus_args[@]}" --strict-reference --out "$scratch/report9.json"

base vol_left vol_right
run_capture 0 "${corpus_args[@]}" --strict-reference \
  --volatile-out "$scratch/volatile.json" --out "$scratch/report10.json"

# 8. Unapproved paths in a --volatile-report input are malformed input (exit 2).
base snap_left snap_right
run_capture 2 "${corpus_args[@]}" --volatile-report "$scratch/unapproved.json" \
  --out "$scratch/report11.json"
grep -q "snapshot.balls\[\].x" <<< "$output" ||
  fail "unapproved volatile list path was not named: $output"
run_capture 2 "${corpus_args[@]}" --volatile-report "$scratch/unapproved_report.json" \
  --out "$scratch/report12.json"
grep -q "snapshot.balls\[\].x" <<< "$output" ||
  fail "unapproved volatile report path was not named: $output"

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


r1 = load("report1.json")
fixture1 = r1["fixtures"]["fixture"]
check(r1["mode"] == "control", "report1 mode")
check(fixture1["state_comparison"] == "full", "report1 full state")
check(fixture1["identical"] is True, "report1 identical")
check(fixture1["snapshot_steps_compared"] == 1, "report1 snapshot steps")
check(r1["state_comparison"] == {"full": 1, "not_captured": 0, "scope_mismatch": 0},
      "report1 state summary")
check(r1["state_scope_note"] is None, "report1 state note")
check(r1["control"]["clean"] is True, "report1 control clean")
check(r1["control"]["strict_reference"] is False, "report1 strict flag")

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
check(r3["state_comparison"] == {"full": 0, "not_captured": 1,
                                 "scope_mismatch": 0},
      "report3 state summary")
check(isinstance(r3["state_scope_note"], str) and r3["state_scope_note"],
      "report3 scope note")

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
check(r6b["state_comparison"] == {"full": 0, "not_captured": 0,
                                  "scope_mismatch": 1},
      "report6b state summary")

r9 = load("report9.json")
check(r9["failures"] == [], "report9 allowlisted diff must pass")
fixture9 = r9["fixtures"]["fixture"]
check(fixture9["classifications"] == {"volatile_animation": 1},
      "report9 volatile classification")
check(fixture9["difference_counts"].get("snapshot.fever_buckets.dividers[].y") == 1,
      "report9 divider path")
check(fixture9["identical"] is True, "report9 allowlisted difference ignored")
check(r9["volatile_policy"]["unapproved_differences"] == [],
      "report9 unapproved differences")

r10 = load("report10.json")
allowlist = ["snapshot.fever_buckets.animating",
             "snapshot.fever_buckets.dividers[].y"]
fixture10 = r10["fixtures"]["fixture"]
check(fixture10["classifications"] == {"volatile_animation": 2},
      "report10 volatile classifications")
check(r10["volatile_paths_discovered"] == allowlist,
      "report10 discovered paths restricted to allowlist")
check(r10["volatile_policy"]["source"] == "explicit-allowlist",
      "report10 policy source")
check(r10["volatile_policy"]["known_fields"] == allowlist,
      "report10 known fields")
check(r10["volatile_policy"]["allowed_paths"] == allowlist,
      "report10 allowed paths")
check(r10["volatile_policy"]["unapproved_differences"] == [],
      "report10 unapproved differences")
with open(os.path.join(base, "volatile.json"), "r", encoding="utf-8") as handle:
    volatile_out = json.load(handle)
check(volatile_out == allowlist, "volatile-out contains only approved paths")

print("test_compare_traces checks: OK")
PY

echo "test_compare_traces: OK (14 comparison cases, 4 ULP assertions)"
