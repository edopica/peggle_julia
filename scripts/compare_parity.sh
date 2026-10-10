#!/usr/bin/env bash
# Compare two parity manifests (WP-F; repaired for WP-D).
#
# Usage: scripts/compare_parity.sh A.json B.json [--all]
#
# Order of checks:
#   1. validation: both documents must be well-formed "peggle.parity"
#      manifests: a supported schema version, the full identity and
#      prerequisites tree, and every authoritative block (math census, RNG
#      sequences, peg colors, levels, geometry, reset entries,
#      reset_deterministic). The first problem exits 5 with
#      "INVALID <A|B>: <path>: <problem>"; malformed manifests are never
#      skipped and never reported as a difference.
#   2. prerequisites: the `identity` sections must be equal (reference,
#      config, fixtures, level manifest, Julia source hash, native math
#      backend identity). Incompatible manifests never reach the
#      authoritative comparison (exit 3 with path and both values).
#   3. status: a manifest that failed its own census/RNG/color/reset checks
#      is rejected even when both manifests fail identically (exit 4).
#   4. authoritative: `authoritative` subtrees must be bit-exact, so signed
#      zero and every float payload are compared as IEEE-754 bit patterns.
#      By default only that subtree is compared; `--all` compares the whole
#      documents (the `environment` section may legally differ). The first
#      difference is reported with path, expected, and actual values
#      (truncated to 200 characters), exit 1.
#
# Exit codes:
#   0  parity OK ("PARITY OK")
#   1  authoritative difference
#   2  usage error or missing file
#   3  incompatible identity
#   4  failed status
#   5  invalid or unsupported manifest
#
# Requires only python3.

set -euo pipefail

usage() {
    echo "usage: $(basename "$0") A.json B.json [--all]" >&2
    exit 2
}

files=()
mode=authoritative
for arg in "$@"; do
    case "$arg" in
        --all) mode=all ;;
        -h|--help) usage ;;
        --) ;;
        *) files+=("$arg") ;;
    esac
done

if [ "${#files[@]}" -ne 2 ]; then
    usage
fi

a="${files[0]}"
b="${files[1]}"
[ -f "$a" ] || { echo "compare_parity: missing file: $a" >&2; exit 2; }
[ -f "$b" ] || { echo "compare_parity: missing file: $b" >&2; exit 2; }

python3 - "$a" "$b" "$mode" <<'PY'
import json
import struct
import sys

a_path, b_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]

SUPPORTED_SCHEMA_VERSIONS = (2,)


def parse_int(text):
    if text == "-0":
        return -0.0
    return int(text)


with open(a_path) as handle:
    a = json.load(handle, parse_int=parse_int)
with open(b_path) as handle:
    b = json.load(handle, parse_int=parse_int)

TRUNC = 200


def show(value):
    text = json.dumps(value, sort_keys=True)
    if len(text) > TRUNC:
        text = text[: TRUNC - 3] + "..."
    return text


def leaf_equal(left, right):
    if isinstance(left, bool) or isinstance(right, bool):
        return left is right or left == right
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        if isinstance(left, float) or isinstance(right, float):
            return struct.pack("<d", float(left)) == struct.pack("<d", float(right))
        return left == right
    return left == right


def first_difference(left, right, path):
    """Return (path, left_value, right_value) or None."""
    if isinstance(left, dict) and isinstance(right, dict):
        for key in sorted(set(left) | set(right)):
            child = path + "." + key if path else key
            if key not in left:
                return (child, "<missing>", show(right[key]))
            if key not in right:
                return (child, show(left[key]), "<missing>")
            difference = first_difference(left[key], right[key], child)
            if difference is not None:
                return difference
        return None
    if isinstance(left, list) and isinstance(right, list):
        if len(left) != len(right):
            index = min(len(left), len(right))
            left_value = show(left[index]) if index < len(left) else "<missing>"
            right_value = show(right[index]) if index < len(right) else "<missing>"
            return ("{}[{}]".format(path, index), left_value, right_value)
        for index, (lvalue, rvalue) in enumerate(zip(left, right), start=1):
            difference = first_difference(
                lvalue, rvalue, "{}[{}]".format(path, index))
            if difference is not None:
                return difference
        return None
    if isinstance(left, bool) != isinstance(right, bool):
        return (path or "$", show(left), show(right))
    if not leaf_equal(left, right):
        return (path or "$", show(left), show(right))
    return None


def validate(label, doc):
    def fail(path, problem):
        print("INVALID {}: {}: {}".format(label, path, problem))
        sys.exit(5)

    if not isinstance(doc, dict):
        fail("$", "top level is not an object")

    identity = doc.get("identity")
    if not isinstance(identity, dict):
        fail("identity", "missing or not an object")
    if identity.get("format") != "peggle.parity":
        fail("identity.format", 'expected "peggle.parity", got {}'
             .format(show(identity.get("format"))))
    version = identity.get("schema_version")
    if isinstance(version, bool) or not isinstance(version, int):
        fail("identity.schema_version",
             "expected an integer, got {}".format(show(version)))
    if version not in SUPPORTED_SCHEMA_VERSIONS:
        fail("identity.schema_version",
             "unsupported value {}; supported: {}".format(
                 show(version),
                 ", ".join(str(allowed) for allowed in SUPPORTED_SCHEMA_VERSIONS)))
    for key in ("format", "schema_version", "reference_revision",
                "reference_tree", "config_sha256", "package_version",
                "checkpoint_schema_version", "julia_source_sha256",
                "prerequisites"):
        if key not in identity:
            fail("identity." + key, "missing")
    prerequisites = identity["prerequisites"]
    if not isinstance(prerequisites, dict):
        fail("identity.prerequisites", "not an object")
    for key in ("config_artifact_sha256", "census_fixture_sha256",
                "rng_sequences_fixture_sha256", "peg_colors_fixture_sha256",
                "levels_sha256", "package_version", "math_backend"):
        if key not in prerequisites:
            fail("identity.prerequisites." + key, "missing")
    math_backend = prerequisites["math_backend"]
    if not isinstance(math_backend, dict):
        fail("identity.prerequisites.math_backend", "not an object")
    if not isinstance(math_backend.get("backend"), str):
        fail("identity.prerequisites.math_backend.backend",
             "missing or not a string")

    authoritative = doc.get("authoritative")
    if not isinstance(authoritative, dict):
        fail("authoritative", "missing or not an object")
    for section in ("math_census", "rng_sequences", "peg_colors",
                    "levels", "geometry"):
        if not isinstance(authoritative.get(section), dict):
            fail("authoritative." + section, "missing or not an object")
    reset = authoritative.get("reset")
    if not isinstance(reset, dict):
        fail("authoritative.reset", "missing or not an object")
    if not reset:
        fail("authoritative.reset", "no reset entries")
    for name in sorted(reset):
        if not isinstance(reset[name], dict):
            fail("authoritative.reset." + name, "entry is not an object")
    if not isinstance(authoritative.get("reset_deterministic"), bool):
        fail("authoritative.reset_deterministic",
             "missing or not a boolean")


# 0. Validation: malformed or unsupported manifests never compare.
validate("A", a)
validate("B", b)

# 1. Prerequisites: identities must match exactly before anything else.
difference = first_difference(a["identity"], b["identity"], "identity")
if difference is not None:
    path, left_value, right_value = difference
    print("INCOMPATIBLE {}: A={} B={}".format(path, left_value, right_value))
    sys.exit(3)

# 2. Failed status is rejected even when both manifests fail identically.
status_failures = []
for label, doc in (("A", a), ("B", b)):
    auth = doc["authoritative"]
    for section in ("math_census", "rng_sequences", "peg_colors"):
        block = auth[section]
        if block.get("verified") is not True:
            status_failures.append(
                "{}: authoritative.{}.verified={}".format(
                    label, section, show(block.get("verified"))))
    if auth["reset_deterministic"] is not True:
        status_failures.append(
            "{}: authoritative.reset_deterministic={}".format(
                label, show(auth["reset_deterministic"])))
    for name in sorted(auth["reset"]):
        record = auth["reset"][name]
        if record.get("restored_matches_original") is not True:
            status_failures.append(
                "{}: authoritative.reset.{}.restored_matches_original={}"
                .format(label, name,
                        show(record.get("restored_matches_original"))))
if status_failures:
    for failure in status_failures:
        print("STATUS FAIL " + failure)
    sys.exit(4)

# 3. Authoritative comparison.
prefix = ""
if mode != "all":
    prefix = "authoritative"
    a = a["authoritative"]
    b = b["authoritative"]

difference = first_difference(a, b, prefix)
if difference is None:
    print("PARITY OK")
    sys.exit(0)
path, left_value, right_value = difference
print("DIFFERENCE {}: A={} B={}".format(path, left_value, right_value))
sys.exit(1)
PY
