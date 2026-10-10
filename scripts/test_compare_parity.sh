#!/usr/bin/env bash
# Contract cases for scripts/compare_parity.sh (WP-D parity repairs).
#
# Builds synthetic parity manifests and requires:
#   * identical manifests -> "PARITY OK", exit 0;
#   * incompatible prerequisites -> exit 3 with the identity path and values;
#   * failed census/RNG/color/reset status -> exit 4 even when both manifests
#     fail identically;
#   * an authoritative difference -> exit 1 with path, expected, and actual;
#   * malformed or unsupported manifests -> exit 5, never a skip or a diff;
#   * signed-zero geometry leaves -> exit 1 (bit-exact comparison).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

python3 - "$scratch" <<'PY'
import copy
import json
import sys

out = sys.argv[1]
h64 = "1" * 64


def manifest(label):
    return {
        "identity": {
            "format": "peggle.parity",
            "schema_version": 2,
            "reference_revision": "a" * 40,
            "reference_tree": "b" * 40,
            "config_sha256": h64,
            "package_version": "0.1.0",
            "checkpoint_schema_version": 1,
            "julia_source_sha256": h64,
            "prerequisites": {
                "config_artifact_sha256": h64,
                "census_fixture_sha256": h64,
                "rng_sequences_fixture_sha256": h64,
                "peg_colors_fixture_sha256": h64,
                "levels_sha256": h64,
                "package_version": "0.1.0",
                "math_backend": {"backend": "system_libm"},
            },
        },
        "authoritative": {
            "math_census": {"fixture_sha256": h64, "verified": True,
                            "total_cases": 10, "mismatches": 0},
            "rng_sequences": {"fixture_sha256": h64, "verified": True,
                              "checked": 5, "mismatches": 0,
                              "computed_sha256": h64},
            "peg_colors": {"fixture_sha256": h64, "verified": True,
                           "checked": 5, "mismatches": 0,
                           "computed_sha256": h64},
            "levels": {"circle_level": h64},
            "geometry": {"circle_level": h64},
            "reset": {
                "circle_level": {
                    "checkpoint_sha256": h64,
                    "mutated_sha256": "2" * 64,
                    "restored_sha256": [h64, h64],
                    "restored_matches_original": True,
                }
            },
            "reset_deterministic": True,
        },
        "environment": {"label": label},
    }


good = manifest("a")
json.dump(good, open(out + "/good.json", "w"))

incompatible = copy.deepcopy(good)
incompatible["identity"]["reference_tree"] = "c" * 40
json.dump(incompatible, open(out + "/incompatible.json", "w"))

status = copy.deepcopy(good)
status["authoritative"]["math_census"]["verified"] = False
status["authoritative"]["reset"]["circle_level"]["restored_matches_original"] = False
status["authoritative"]["reset_deterministic"] = False
json.dump(status, open(out + "/status.json", "w"))

difference = copy.deepcopy(good)
difference["authoritative"]["geometry"]["circle_level"] = "d" * 64
json.dump(difference, open(out + "/difference.json", "w"))

empty = {}
json.dump(empty, open(out + "/empty.json", "w"))

unsupported = copy.deepcopy(good)
unsupported["identity"]["schema_version"] = 99
json.dump(unsupported, open(out + "/unsupported.json", "w"))

missing_block = copy.deepcopy(good)
del missing_block["authoritative"]["math_census"]
json.dump(missing_block, open(out + "/missing_block.json", "w"))

missing_reset = copy.deepcopy(good)
del missing_reset["authoritative"]["reset_deterministic"]
json.dump(missing_reset, open(out + "/missing_reset.json", "w"))

missing_identity_key = copy.deepcopy(good)
del missing_identity_key["identity"]["julia_source_sha256"]
json.dump(missing_identity_key, open(out + "/missing_identity_key.json", "w"))

signed_zero_neg = copy.deepcopy(good)
signed_zero_neg["authoritative"]["geometry"]["probe"] = -0.0
json.dump(signed_zero_neg, open(out + "/signed_zero_neg.json", "w"))

signed_zero_pos = copy.deepcopy(good)
signed_zero_pos["authoritative"]["geometry"]["probe"] = 0.0
json.dump(signed_zero_pos, open(out + "/signed_zero_pos.json", "w"))
PY

fail() {
  echo "test_compare_parity: FAIL: $*" >&2
  exit 1
}

h64="$(printf '1%.0s' {1..64})"
d64="$(printf 'd%.0s' {1..64})"

run_case() {
  local expected_code="$1"; shift
  local expected_text="$1"; shift
  local output
  set +e
  output="$(scripts/compare_parity.sh "$@" 2>&1)"
  local code=$?
  set -e
  [[ $code -eq $expected_code ]] ||
    fail "expected exit $expected_code, got $code: $output"
  grep -q "$expected_text" <<< "$output" ||
    fail "expected '$expected_text' in output: $output"
}

run_case 0 "PARITY OK" "$scratch/good.json" "$scratch/good.json"
run_case 3 "INCOMPATIBLE identity.reference_tree" \
  "$scratch/good.json" "$scratch/incompatible.json"
run_case 4 "STATUS FAIL" "$scratch/status.json" "$scratch/status.json"
run_case 4 "STATUS FAIL" "$scratch/status.json" "$scratch/good.json"
run_case 1 "DIFFERENCE authoritative.geometry.circle_level" \
  "$scratch/good.json" "$scratch/difference.json"
run_case 5 "INVALID" "$scratch/empty.json" "$scratch/empty.json"
run_case 5 "INVALID" "$scratch/good.json" "$scratch/empty.json"
run_case 5 "schema_version" "$scratch/good.json" "$scratch/unsupported.json"
run_case 5 "authoritative.math_census" \
  "$scratch/good.json" "$scratch/missing_block.json"
run_case 5 "authoritative.reset_deterministic" \
  "$scratch/good.json" "$scratch/missing_reset.json"
run_case 5 "identity.julia_source_sha256" \
  "$scratch/good.json" "$scratch/missing_identity_key.json"
run_case 1 "DIFFERENCE authoritative.geometry.probe" \
  "$scratch/signed_zero_neg.json" "$scratch/signed_zero_pos.json"

# The difference report must include both values.
output="$(scripts/compare_parity.sh "$scratch/good.json" "$scratch/difference.json" || true)"
grep -q "A=\"$h64\"" <<< "$output" || fail "difference is missing the A value: $output"
grep -q "B=\"$d64\"" <<< "$output" ||
  fail "difference is missing the B value: $output"

echo "test_compare_parity: OK (12 contract cases)"
