#!/usr/bin/env bash
# Negative/regression contract cases for `peggle.checkpoint` v1 against
# scripts/validate_interchange.py. Every case is a mutation of
# schemas/examples/checkpoint.v1.example.json.
#
#   post-turn-retained-flag: Engine:resetTurn() (core.lua:510-554) clears
#   clearQueue and clearTimer but does NOT reset clearingIsEndOfTurn. That
#   flag is set by Engine:startClearing(isEndOfTurn) (core.lua:1019) and read
#   only while clearQueue drains (core.lua:1059), so at a post-turn
#   ready-to-aim boundary it is a retained, inert flag. The validator must
#   accept is_end_of_turn=true while active is false and timer is 0.
#
#   missing-hit-counter: hitCounter assigns peg.hit_order as pegs score
#   (core.lua:816-817), survives resetTurn (core.lua:510-554), and hit pegs
#   are removed by clearing (Engine:removePeg, core.lua:1025-1047), so it is
#   authoritative and cannot be reconstructed from the remaining engine.pegs.
#   It is required.
#
#   reds-over-total: redPegsHitAmount counts scored reds (core.lua:820) and
#   totalRedPegs is the level red count (core.lua:384); both survive
#   resetTurn, so red_pegs_hit_amount must not exceed total_red_pegs.
#
#   multiplier-mismatch, fever-flag-mismatch: current_multiplier is derived by
#   Engine:updateMultiplier (core.lua:306-320) from
#   red_pegs_hit_amount / total_red_pegs, and is_fever is true iff
#   current_multiplier == 100 (core.lua:319). Both derived values must be
#   recomputed and checked at ready_to_aim.
#
#   nonzero-bonus-at-ready-to-aim, nonzero-style-at-ready-to-aim:
#   Engine:resetTurn zeroes bonusScore and styleScore (core.lua:544-545), so
#   both accumulators must be 0 at ready_to_aim.
#
# The script needs no display and no LÖVE; it is wired into `make check`.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

failures=0

# apply_case NAME DESTINATION: write the named mutation of the example
# checkpoint to DESTINATION.
apply_case() {
  local name="$1" destination="$2"
  python3 - "$name" "$repo_root/schemas/examples/checkpoint.v1.example.json" "$destination" <<'PY'
import json
import sys

name, source, destination = sys.argv[1], sys.argv[2], sys.argv[3]
with open(source, "r", encoding="utf-8") as handle:
    artifact = json.load(handle)
engine = artifact["engine"]


def post_turn_retained_flag():
    engine["step_id"] = 183
    engine["shot_id"] = 1
    engine["hit_counter"] = 6
    engine["total_red_pegs"] = 10
    engine["red_pegs_hit_amount"] = 2
    engine["current_multiplier"] = 1
    engine["is_fever"] = False
    engine["clearing"]["is_end_of_turn"] = True


def missing_hit_counter():
    del engine["hit_counter"]


def reds_over_total():
    engine["total_red_pegs"] = 1
    engine["red_pegs_hit_amount"] = 2


def multiplier_mismatch():
    engine["total_red_pegs"] = 10
    engine["red_pegs_hit_amount"] = 9
    engine["current_multiplier"] = 1


def fever_flag_mismatch():
    engine["total_red_pegs"] = 10
    engine["red_pegs_hit_amount"] = 10
    engine["current_multiplier"] = 100
    engine["is_fever"] = False


def nonzero_bonus_at_ready_to_aim():
    engine["bonus_score"] = 10


def nonzero_style_at_ready_to_aim():
    engine["style_score"] = 5


mutations = {
    "post-turn-retained-flag": post_turn_retained_flag,
    "missing-hit-counter": missing_hit_counter,
    "reds-over-total": reds_over_total,
    "multiplier-mismatch": multiplier_mismatch,
    "fever-flag-mismatch": fever_flag_mismatch,
    "nonzero-bonus-at-ready-to-aim": nonzero_bonus_at_ready_to_aim,
    "nonzero-style-at-ready-to-aim": nonzero_style_at_ready_to_aim,
}
mutations[name]()

with open(destination, "w", encoding="utf-8") as handle:
    json.dump(artifact, handle, indent=2)
    handle.write("\n")
PY
}

expect_accept() {
  local name="$1"
  local case_file="$scratch/$name.json"
  apply_case "$name" "$case_file"
  if scripts/validate_interchange.py "$case_file" > "$scratch/$name.log" 2>&1; then
    echo "OK: $name validated"
  else
    echo "FAIL: validator rejected a valid checkpoint ($name)" >&2
    cat "$scratch/$name.log" >&2
    failures=$((failures + 1))
  fi
}

expect_reject() {
  local name="$1"
  local case_file="$scratch/$name.json"
  apply_case "$name" "$case_file"
  if scripts/validate_interchange.py "$case_file" > "$scratch/$name.log" 2>&1; then
    echo "FAIL: $name was accepted; must be rejected" >&2
    failures=$((failures + 1))
  else
    echo "OK: $name rejected"
  fi
}

echo "== post-turn-retained-flag: retained is_end_of_turn must validate =="
expect_accept "post-turn-retained-flag"

echo "== scoring/derived-field cases must be rejected =="
expect_reject "missing-hit-counter"
expect_reject "reds-over-total"
expect_reject "multiplier-mismatch"
expect_reject "fever-flag-mismatch"
expect_reject "nonzero-bonus-at-ready-to-aim"
expect_reject "nonzero-style-at-ready-to-aim"

if [[ $failures -ne 0 ]]; then
  echo "test_checkpoint_contract: $failures failure(s)" >&2
  exit 1
fi
echo "test_checkpoint_contract: OK"
