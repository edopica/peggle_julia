#!/usr/bin/env bash
# Contract cases for scripts/compare_m3_sweeps.py (M3 sweep parity gate).
#
# Requires:
#   * identical corpora -> exit 0, clean report, `spawned` recorded as
#     unavailable (the Lua harness raw never carries it);
#   * a Julia row missing a required result field -> exit 2, never a skip;
#   * a Lua row missing a required result field -> exit 2;
#   * a differing value -> exit 1 with the first divergent candidate.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

python3 - "$scratch" <<'PY'
import json
import sys

out = sys.argv[1]


def lua_row(index, **overrides):
    row = {
        "w": "mustache_full", "r": 1, "i": index, "angle": 90.0 + index,
        "steps": 100 + index, "completed": True, "reason": "fell_out",
        "score": 1000 + index, "peg_score": 900 + index, "bonus": 0,
        "style_points": 100, "style_total": 1, "styles": "slide:1",
        "pegs_hit": 5 + index, "reds_hit": 0, "multiplier": 2,
        "is_fever": False, "balls": 1,
    }
    row.update(overrides)
    return row


def julia_row(index, **overrides):
    row = {
        "index": index, "angle": 90.0 + index, "steps": 100 + index,
        "completed": True, "reason": "fell_out", "score": 1000 + index,
        "peg_score": 900 + index, "bonus": 0, "style_points": 100,
        "style_total": 1, "styles": {"slide": 1}, "pegs_hit": 5 + index,
        "reds_hit": 0, "multiplier": 2, "is_fever": False, "balls": 1,
        "spawned": 0,
    }
    row.update(overrides)
    return row


def write(name, rows):
    with open("%s/%s" % (out, name), "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")


indices = [0, 20, 40]
write("clean.lua.jsonl", [lua_row(i) for i in indices])
write("clean.julia.jsonl", [julia_row(i) for i in indices])

missing_julia = julia_row(20)
del missing_julia["score"]
write("missing_julia.lua.jsonl", [lua_row(i) for i in indices])
write("missing_julia.julia.jsonl",
      [julia_row(0), missing_julia, julia_row(40)])

missing_lua = lua_row(20)
del missing_lua["completed"]
write("missing_lua.lua.jsonl", [lua_row(0), missing_lua, lua_row(40)])
write("missing_lua.julia.jsonl", [julia_row(i) for i in indices])

write("mismatch.lua.jsonl", [lua_row(i) for i in indices])
write("mismatch.julia.jsonl",
      [julia_row(0), julia_row(20, score=1021), julia_row(40)])
PY

comparator="scripts/compare_m3_sweeps.py"
LAST_OUTPUT=""

fail() {
  echo "test_compare_m3_sweeps: FAIL: $*" >&2
  exit 1
}

run_case() {
  local expected_code="$1"; shift
  local lua="$1"; shift
  local julia="$1"; shift
  local out="$1"; shift
  set +e
  LAST_OUTPUT="$(python3 "$comparator" --lua-raw "$lua" --julia "$julia" --out "$out" 2>&1)"
  local code=$?
  set -e
  [[ $code -eq $expected_code ]] ||
    fail "expected exit $expected_code, got $code: $LAST_OUTPUT"
}

# Identical corpora compare clean; `spawned` is the only unavailable field.
run_case 0 "$scratch/clean.lua.jsonl" "$scratch/clean.julia.jsonl" \
  "$scratch/clean.report.json"
grep -q "unavailable fields (not in both raw formats): spawned" \
  <<< "$LAST_OUTPUT" ||
  fail "clean report is missing the spawned coverage note: $LAST_OUTPUT"
if ! python3 - "$scratch/clean.report.json" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1]))
assert report["clean"] is True, report["clean"]
assert report["mismatch_candidates"] == 0, report["mismatch_candidates"]
assert report["candidates_compared"] == 3, report["candidates_compared"]
assert list(report["unavailable_fields"]) == ["spawned"], report["unavailable_fields"]
assert "score" in report["fields_compared"], report["fields_compared"]
assert "spawned" not in report["fields_compared"], report["fields_compared"]
PY
then
  fail "clean corpus report is not clean"
fi

# A Julia row missing a required result field is malformed input, not a skip.
run_case 2 "$scratch/missing_julia.lua.jsonl" "$scratch/missing_julia.julia.jsonl" \
  "$scratch/missing.report.json"
grep -q "missing required field 'score'" <<< "$LAST_OUTPUT" ||
  fail "missing Julia field is not named: $LAST_OUTPUT"
[[ ! -e "$scratch/missing.report.json" ]] ||
  fail "malformed input must not write a report"

# A Lua row missing a required result field is malformed input too.
run_case 2 "$scratch/missing_lua.lua.jsonl" "$scratch/missing_lua.julia.jsonl" \
  "$scratch/missing2.report.json"
grep -q "missing required field 'completed'" <<< "$LAST_OUTPUT" ||
  fail "missing Lua field is not named: $LAST_OUTPUT"

# A differing value still fails the gate with the divergent candidate.
run_case 1 "$scratch/mismatch.lua.jsonl" "$scratch/mismatch.julia.jsonl" \
  "$scratch/mismatch.report.json"
grep -q "first divergent candidate index=20" <<< "$LAST_OUTPUT" ||
  fail "mismatch summary is missing the divergent index: $LAST_OUTPUT"
if ! python3 - "$scratch/mismatch.report.json" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1]))
assert report["clean"] is False
assert report["per_field_mismatch_count"] == {"score": 1}, \
    report["per_field_mismatch_count"]
first = report["first_divergent_candidate"]
assert first["index"] == 20, first
assert first["fields"]["score"] == {"left": 1020, "right": 1021}, first["fields"]
PY
then
  fail "mismatch report is wrong"
fi

echo "test_compare_m3_sweeps: OK (4 contract cases)"
