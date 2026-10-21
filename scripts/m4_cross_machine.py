#!/usr/bin/env python3
"""Compare two M4 qualification capture roots from different hosts.

Each capture root is a directory produced by one host and contains:

    host.json                                   host facts, commit, source hash
    results/m4/fixture-parity.json              M4 fixture parity report
    results/m4/trace-parity.json                M4 trace parity report
    results/m4/scenario-parity.json             M4 scenario parity report
    results/m4/julia-<workload>-t<threads>.json Julia sweep summaries
    results/raw/m4-julia-<workload>-t<t>.jsonl  Julia full-grid candidate rows
    results/core-math/qualification/*.json      M2 parity manifests (optional)

The comparison is bit-identical by construction: the corpus reports and the
candidate-row files must hash equal, and the two M2 parity manifests must agree
on their `identity` and `authoritative` blocks (the same blocks
`scripts/compare_parity.sh` checks). Timing fields in the sweep summaries are
reported as excluded, never compared.

The verdict distinguishes a *second host* (distinct hostnames) from a *second
OS* (distinct platform strings). This tool can only certify what the captures
show; it does not claim a second OS when both hosts run the same one.

Exit status: 0 when every comparison passes, 1 on a difference, 2 on usage or
missing input.

Canonical JSON: sorted keys, 2-space indent, trailing newline.
"""

import argparse
import glob
import hashlib
import json
import os
import sys

FORMAT = "peggle.m4_cross_machine"
SCHEMA_VERSION = 1

# Sweep-summary keys that are host/timing dependent and therefore excluded
# from the structural comparison.
SUMMARY_TIMING_KEYS = (
    "wall_seconds",
    "candidates_per_second",
    "steps_per_second",
    "serial",
    "parallel",
    "phases",
)

REQUIRED_REPORTS = (
    "results/m4/fixture-parity.json",
    "results/m4/trace-parity.json",
    "results/m4/scenario-parity.json",
)


def fail(message):
    sys.stderr.write("m4_cross_machine: {}\n".format(message))
    sys.exit(2)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def require(path):
    if not os.path.isfile(path):
        fail("missing input: {}".format(path))
    return path


def relative(path, root):
    return os.path.relpath(path, root).replace(os.sep, "/")


def compare_file(left_path, right_path, left_root, right_root):
    return {
        "path": relative(left_path, left_root),
        "left_sha256": sha256_file(left_path),
        "right_sha256": sha256_file(right_path),
        "identical": sha256_file(left_path) == sha256_file(right_path),
    }


def compare_summaries(left_path, right_path, left_root):
    left = load_json(left_path)
    right = load_json(right_path)
    differing = []
    for key in sorted(set(left) | set(right)):
        if key in SUMMARY_TIMING_KEYS:
            continue
        if left.get(key) != right.get(key):
            differing.append(key)
    return {
        "path": relative(left_path, left_root),
        "fields_equal": not differing,
        "differing_fields": differing,
        "timing_fields_excluded": list(SUMMARY_TIMING_KEYS),
        "candidates": left.get("candidates"),
        "threads": left.get("threads"),
        "serial_parallel_identical": bool(left.get("serial_parallel_identical")),
    }


def first_difference(left, right, path=""):
    if type(left) is not type(right):
        return path or "$"
    if isinstance(left, dict):
        for key in sorted(set(left) | set(right)):
            if key not in left or key not in right:
                return "{}.{}".format(path, key) if path else key
            found = first_difference(left[key], right[key],
                                     "{}.{}".format(path, key) if path else key)
            if found is not None:
                return found
        return None
    if isinstance(left, list):
        if len(left) != len(right):
            return path
        for index, (a, b) in enumerate(zip(left, right)):
            found = first_difference(a, b, "{}[{}]".format(path, index))
            if found is not None:
                return found
        return None
    if left != right:
        return path or "$"
    return None


def compare_manifests(left_root, right_root):
    left_paths = sorted(glob.glob(os.path.join(
        left_root, "results/core-math/qualification/*.json")))
    right_paths = sorted(glob.glob(os.path.join(
        right_root, "results/core-math/qualification/*.json")))
    if not left_paths or not right_paths:
        return [], False
    # Pair each left manifest with the right manifest of the same file name,
    # falling back to a single-manifest cross-pair (the two hosts record their
    # own label, so the file names may differ on purpose).
    pairs = []
    for left_path in left_paths:
        name = os.path.basename(left_path)
        candidates = [p for p in right_paths
                      if os.path.basename(p) == name] or right_paths
        if len(candidates) == 1:
            pairs.append((left_path, candidates[0]))
    entries = []
    all_equal = bool(pairs)
    for left_path, right_path in pairs:
        left = load_json(left_path)
        right = load_json(right_path)
        identity_diff = first_difference(left.get("identity"),
                                         right.get("identity"), "identity")
        authoritative_diff = first_difference(
            left.get("authoritative"), right.get("authoritative"),
            "authoritative")
        entry = {
            "left": relative(left_path, left_root),
            "right": relative(right_path, right_root),
            "left_label": left.get("label"),
            "right_label": right.get("label"),
            "identity_equal": identity_diff is None,
            "authoritative_equal": authoritative_diff is None,
            "first_identity_difference": identity_diff,
            "first_authoritative_difference": authoritative_diff,
            "identity": left.get("identity"),
        }
        entries.append(entry)
        if identity_diff is not None or authoritative_diff is not None:
            all_equal = False
    return entries, all_equal


def main(argv):
    parser = argparse.ArgumentParser(
        description="Compare two M4 qualification capture roots.")
    parser.add_argument("--left-root", required=True,
                        help="reference capture root (e.g. tmp/cross-machine-local)")
    parser.add_argument("--right-root", required=True,
                        help="second-host capture root")
    parser.add_argument("--out", required=True, help="canonical JSON report path")
    args = parser.parse_args(argv)

    left_root = os.path.abspath(args.left_root)
    right_root = os.path.abspath(args.right_root)
    for root in (left_root, right_root):
        if not os.path.isdir(root):
            fail("capture root is not a directory: {}".format(root))

    left_host = load_json(require(os.path.join(left_root, "host.json")))
    right_host = load_json(require(os.path.join(right_root, "host.json")))

    reports = []
    for name in REQUIRED_REPORTS:
        left_path = require(os.path.join(left_root, name))
        right_path = require(os.path.join(right_root, name))
        reports.append(compare_file(left_path, right_path, left_root, right_root))

    left_raw = sorted(glob.glob(os.path.join(
        left_root, "results/raw/m4-julia-*.jsonl")))
    right_raw = sorted(glob.glob(os.path.join(
        right_root, "results/raw/m4-julia-*.jsonl")))
    if not left_raw or not right_raw:
        fail("no results/raw/m4-julia-*.jsonl in a capture root")
    right_raw_by_name = {os.path.basename(p): p for p in right_raw}
    rows = []
    for left_path in left_raw:
        name = os.path.basename(left_path)
        if name not in right_raw_by_name:
            fail("candidate rows missing on the right: {}".format(name))
        entry = compare_file(left_path, right_raw_by_name[name],
                             left_root, right_root)
        entry["workload"] = name[len("m4-julia-"):].rsplit("-t", 1)[0]
        entry["threads"] = int(name.rsplit("-t", 1)[1].split(".")[0])
        rows.append(entry)

    summaries = []
    for left_path in sorted(glob.glob(os.path.join(
            left_root, "results/m4/julia-*.json"))):
        name = os.path.basename(left_path)
        right_path = os.path.join(right_root, "results/m4", name)
        if not os.path.isfile(right_path):
            continue
        summaries.append(compare_summaries(left_path, right_path, left_root))

    manifests, manifests_equal = compare_manifests(left_root, right_root)

    distinct_hosts = (left_host.get("hostname") != right_host.get("hostname")
                      and left_host.get("hostname") and right_host.get("hostname"))
    left_platform = "{} {}".format(left_host.get("uname_m"), left_host.get("glibc"))
    right_platform = "{} {}".format(right_host.get("uname_m"), right_host.get("glibc"))
    distinct_os = left_host.get("uname_m") != right_host.get("uname_m")
    same_commit = left_host.get("repo_commit") == right_host.get("repo_commit")
    same_source = (left_host.get("julia_src_tree_sha256") ==
                   right_host.get("julia_src_tree_sha256"))
    same_julia = left_host.get("julia_version") == right_host.get("julia_version")

    reasons = []
    if not distinct_hosts:
        reasons.append("capture roots are from the same hostname")
    if not same_commit:
        reasons.append("repository commits differ")
    if not same_source:
        reasons.append("julia/PeggleSim/src tree hashes differ")
    if not same_julia:
        reasons.append("Julia versions differ")
    if not all(entry["identical"] for entry in reports):
        reasons.append("corpus reports are not byte-identical")
    if not all(entry["identical"] for entry in rows):
        reasons.append("candidate rows are not byte-identical")
    if not all(entry["fields_equal"] for entry in summaries):
        reasons.append("sweep summary structure differs")
    if not manifests_equal:
        reasons.append("parity manifests do not match")

    complete = not reasons
    document = {
        "schema_version": SCHEMA_VERSION,
        "format": FORMAT,
        "method": (
            "Two capture roots from two hosts. Corpus reports and candidate-row "
            "files must hash equal; sweep summaries compare structural fields "
            "only (timing fields are excluded); M2 parity manifests must agree "
            "on identity and authoritative blocks, the same blocks "
            "scripts/compare_parity.sh checks. Allocation and throughput "
            "measurements are never mixed across hosts."
        ),
        "hosts": {
            "left": left_host,
            "right": right_host,
        },
        "comparisons": {
            "reports": reports,
            "candidate_rows": rows,
            "sweep_summaries": summaries,
            "parity_manifests": manifests,
        },
        "verdict": {
            "complete": complete,
            "distinct_hosts": distinct_hosts,
            "distinct_os": distinct_os,
            "same_commit": same_commit,
            "same_julia_version": same_julia,
            "same_source_tree": same_source,
            "left_platform": left_platform,
            "right_platform": right_platform,
            "all_reports_identical": all(entry["identical"] for entry in reports),
            "all_candidate_rows_identical": all(entry["identical"] for entry in rows),
            "all_sweep_summaries_structurally_equal": all(
                entry["fields_equal"] for entry in summaries),
            "all_parity_manifests_equal": manifests_equal,
            "scope": ("second host, same OS" if distinct_hosts and not distinct_os
                      else "second host, second OS" if distinct_hosts
                      else "single host"),
            "reasons": reasons,
        },
    }

    out_path = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")

    verdict = document["verdict"]
    print("m4_cross_machine: left={} right={}".format(
        left_host.get("hostname"), right_host.get("hostname")))
    print("m4_cross_machine: reports identical={} rows identical={} "
          "summaries equal={} manifests equal={}".format(
              verdict["all_reports_identical"],
              verdict["all_candidate_rows_identical"],
              verdict["all_sweep_summaries_structurally_equal"],
              verdict["all_parity_manifests_equal"]))
    print("m4_cross_machine: scope={} complete={}".format(
        verdict["scope"], verdict["complete"]))
    for reason in verdict["reasons"]:
        print("m4_cross_machine: reason: {}".format(reason))
    print("m4_cross_machine: wrote {}".format(out_path))
    return 0 if complete else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
