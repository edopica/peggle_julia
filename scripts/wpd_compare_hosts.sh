#!/usr/bin/env bash
# WP-E cross-machine comparison: run on the Linux comparison host.
#
# Loads two host captures produced by scripts/wpd_capture_host.sh, checks that
# their provenance is compatible, and requires the trace and candidate corpora
# to be identical under tools/compare_traces.py --require-identical and
# tools/compare_candidates.py --require-identical.
#
# Usage:
#   scripts/wpd_compare_hosts.sh --left-root DIR --right-root DIR --out DIR
#                                [--left-label L] [--right-label R]
#                                [--allow-missing-provenance]
#
# Exit codes: 0 all comparisons pass and the identity prerequisites match;
# 1 a comparison found differences; 2 usage or missing/incomplete input;
# 3 INCOMPATIBLE provenance/artifact identity (reference revision/tree/config
#   sha256, backend name, CORE-MATH revision, or dev-tree git identity).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/wpd_compare_hosts.sh --left-root DIR --right-root DIR --out DIR
                                    [--left-label L] [--right-label R]
                                    [--allow-missing-provenance]

Options:
  --left-root DIR                first host capture (expected/ + traces/)
  --right-root DIR               second host capture (expected/ + traces/)
  --out DIR                      comparison output directory
  --left-label L                 label override for the left capture
  --right-label R                label override for the right capture
  --allow-missing-provenance     proceed (with a warning) when a capture has
                                 no provenance.json; identity checks are
                                 skipped for that side
  -h, --help                     show this help

Writes cross-machine-trace.json, cross-machine-candidates.json (unless both
captures omit candidates/), and cross-machine-summary.json under --out.
EOF
}

left_root=""
right_root=""
out_dir=""
left_label=""
right_label=""
allow_missing=0

while [ $# -gt 0 ]; do
  case "$1" in
    --left-root)
      [ $# -ge 2 ] || { echo "ERROR: --left-root requires a value" >&2; exit 2; }
      left_root="$2"; shift 2 ;;
    --right-root)
      [ $# -ge 2 ] || { echo "ERROR: --right-root requires a value" >&2; exit 2; }
      right_root="$2"; shift 2 ;;
    --out)
      [ $# -ge 2 ] || { echo "ERROR: --out requires a value" >&2; exit 2; }
      out_dir="$2"; shift 2 ;;
    --left-label)
      [ $# -ge 2 ] || { echo "ERROR: --left-label requires a value" >&2; exit 2; }
      left_label="$2"; shift 2 ;;
    --right-label)
      [ $# -ge 2 ] || { echo "ERROR: --right-label requires a value" >&2; exit 2; }
      right_label="$2"; shift 2 ;;
    --allow-missing-provenance) allow_missing=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

for required in "$left_root" "$right_root" "$out_dir"; do
  if [ -z "$required" ]; then
    echo "ERROR: --left-root, --right-root, and --out are required" >&2
    usage >&2
    exit 2
  fi
done
if [ ! -d "$left_root" ]; then
  echo "ERROR: left capture root not found: $left_root" >&2
  exit 2
fi
if [ ! -d "$right_root" ]; then
  echo "ERROR: right capture root not found: $right_root" >&2
  exit 2
fi
command -v python3 > /dev/null 2>&1 || {
  echo "ERROR: python3 is required" >&2
  exit 2
}

left_root="$(cd "$left_root" && pwd)"
right_root="$(cd "$right_root" && pwd)"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

for side in left right; do
  if [ "$side" = left ]; then root="$left_root"; else root="$right_root"; fi
  if [ ! -d "$root/expected" ] || [ ! -d "$root/traces" ]; then
    echo "ERROR: $side capture $root must contain expected/ and traces/" >&2
    echo "  Run scripts/wpd_capture_host.sh on that host first." >&2
    exit 2
  fi
done

left_prov="$left_root/provenance.json"
right_prov="$right_root/provenance.json"
missing_provenance=0
for side in left right; do
  if [ "$side" = left ]; then prov="$left_prov"; else prov="$right_prov"; fi
  if [ ! -f "$prov" ]; then
    missing_provenance=1
    echo "WARNING: $side capture has no provenance.json ($prov)" >&2
  fi
done
if [ "$missing_provenance" -eq 1 ] && [ "$allow_missing" -ne 1 ]; then
  echo "ERROR: provenance.json is missing; re-run with --allow-missing-provenance" >&2
  echo "  to compare anyway (identity prerequisites are then not checked)." >&2
  exit 2
fi

left_cand=0
right_cand=0
if [ -f "$left_root/candidates/raw.candidates.jsonl" ] \
    && [ -f "$left_root/candidates/summary.summary.json" ]; then
  left_cand=1
fi
if [ -f "$right_root/candidates/raw.candidates.jsonl" ] \
    && [ -f "$right_root/candidates/summary.summary.json" ]; then
  right_cand=1
fi
if [ "$left_cand" -ne "$right_cand" ]; then
  echo "ERROR: candidate files present on one side only" >&2
  echo "  left candidates:  $([ "$left_cand" -eq 1 ] && printf yes || printf no)" >&2
  echo "  right candidates: $([ "$right_cand" -eq 1 ] && printf yes || printf no)" >&2
  exit 2
fi

prov_field() {
  local file="$1" field="$2" fallback="$3"
  if [ ! -f "$file" ]; then
    printf '%s' "$fallback"
    return 0
  fi
  python3 - "$file" "$field" "$fallback" <<'PY'
import json
import sys

path, field, fallback = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, "r", encoding="utf-8") as handle:
        value = json.load(handle)
except (OSError, ValueError):
    print(fallback)
    sys.exit(0)
for part in field.split("."):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        print(fallback)
        sys.exit(0)
if value is None:
    print(fallback)
elif isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, str):
    print(value)
else:
    print(json.dumps(value, sort_keys=True))
PY
}

if [ -z "$left_label" ]; then
  left_label="$(prov_field "$left_prov" "label" "$(basename "$left_root")")"
fi
if [ -z "$right_label" ]; then
  right_label="$(prov_field "$right_prov" "label" "$(basename "$right_root")")"
fi

incompatible=0
if [ "$missing_provenance" -eq 0 ]; then
  set +e
  python3 - "$left_prov" "$right_prov" "$left_label" "$right_label" <<'PY'
import json
import sys

left_path, right_path, left_label, right_label = sys.argv[1:5]


def load(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as err:
        print("ERROR: cannot read provenance %s: %s" % (path, err),
              file=sys.stderr)
        sys.exit(2)


def dig(doc, dotted):
    value = doc
    for part in dotted.split("."):
        if isinstance(value, dict) and part in value:
            value = value[part]
        else:
            return None
    return value


left = load(left_path)
right = load(right_path)
problems = []

for field in ("reference.revision", "reference.tree",
              "reference.config_sha256", "backend", "core_math_revision"):
    left_value = dig(left, field)
    right_value = dig(right, field)
    if left_value is not None and right_value is not None \
            and left_value != right_value:
        problems.append("%s differs: %s=%r %s=%r"
                        % (field, left_label, left_value,
                           right_label, right_value))

for field in ("dev_tree.git_head", "dev_tree.status_porcelain_sha256"):
    left_value = dig(left, field)
    right_value = dig(right, field)
    if left_value and right_value and left_value != right_value:
        problems.append("%s differs: %s=%r %s=%r"
                        % (field, left_label, left_value,
                           right_label, right_value))

if problems:
    for problem in problems:
        print("INCOMPATIBLE: " + problem, file=sys.stderr)
    sys.exit(3)
PY
  compat_status=$?
  set -e
  if [ "$compat_status" -eq 3 ]; then
    incompatible=1
  elif [ "$compat_status" -ne 0 ]; then
    echo "ERROR: provenance check failed (exit $compat_status)" >&2
    exit 2
  fi
fi

if [ "$incompatible" -eq 1 ]; then
  echo "INCOMPATIBLE: capture provenance does not match; refusing to compare" >&2
  exit 3
fi

trace_status=0
echo "== trace comparison (require-identical) =="
python3 "$repo_root/tools/compare_traces.py" --require-identical \
  --left-traces "$left_root/traces" \
  --left-expected "$left_root/expected" \
  --right-traces "$right_root/traces" \
  --right-expected "$right_root/expected" \
  --left-label "$left_label" \
  --right-label "$right_label" \
  --out "$out_dir/cross-machine-trace.json" \
  || trace_status=$?

cand_status=0
cand_ran=false
if [ "$left_cand" -eq 1 ]; then
  cand_ran=true
  echo "== candidate comparison (require-identical) =="
  python3 "$repo_root/tools/compare_candidates.py" --require-identical \
    --left-raw "$left_root/candidates/raw.candidates.jsonl" \
    --left-summary "$left_root/candidates/summary.summary.json" \
    --right-raw "$right_root/candidates/raw.candidates.jsonl" \
    --right-summary "$right_root/candidates/summary.summary.json" \
    --left-label "$left_label" \
    --right-label "$right_label" \
    --out "$out_dir/cross-machine-candidates.json" \
    || cand_status=$?
else
  echo "== candidate comparison skipped (both captures omit candidates/) =="
fi

header_incompat=0
if [ -f "$out_dir/cross-machine-trace.json" ]; then
  set +e
  python3 - "$out_dir/cross-machine-trace.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    report = json.load(handle)

revisions = {}
for fixture, result in (report.get("fixtures") or {}).items():
    backend = result.get("math_backend") or {}
    for side in ("left", "right"):
        block = backend.get(side)
        if not isinstance(block, dict):
            continue
        identity = block.get("native_identity")
        if not isinstance(identity, str) or not identity:
            continue
        try:
            parsed = json.loads(identity)
        except ValueError:
            continue
        revision = parsed.get("core_math_revision")
        if revision:
            revisions.setdefault(revision, []).append("%s/%s" % (fixture, side))

if len(revisions) > 1:
    detail = "; ".join("%s: %s" % (revision, ", ".join(where))
                       for revision, where in sorted(revisions.items()))
    print("INCOMPATIBLE: trace headers carry different CORE-MATH revisions: "
          + detail, file=sys.stderr)
    sys.exit(3)

if revisions:
    only = next(iter(revisions))
    print("trace header core_math_revision: %s (%d record(s))"
          % (only, len(revisions[only])))
else:
    print("trace header core_math_revision: not declared (no metadata block)")
PY
  header_status=$?
  set -e
  if [ "$header_status" -eq 3 ]; then
    header_incompat=1
  elif [ "$header_status" -ne 0 ]; then
    echo "ERROR: trace-header identity check failed (exit $header_status)" >&2
    exit 2
  fi
fi

python3 - "$left_root" "$right_root" "$out_dir" \
  "$left_label" "$right_label" \
  "$left_prov" "$right_prov" \
  "$trace_status" "$cand_ran" "$cand_status" "$header_incompat" <<'PY'
import json
import os
import sys

(left_root, right_root, out_dir, left_label, right_label,
 left_prov, right_prov, trace_status, cand_ran, cand_status,
 header_incompat) = sys.argv[1:12]


def load_provenance(path):
    if not path or not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def host_entry(root, label, provenance):
    return {
        "root": root,
        "label": label,
        "os": provenance.get("os"),
        "platform": provenance.get("platform"),
        "hostname": (provenance.get("uname") or {}).get("node"),
        "backend": provenance.get("backend"),
        "core_math_revision": provenance.get("core_math_revision"),
        "lib_sha256": (provenance.get("lib") or {}).get("sha256"),
        "capture_time_utc": provenance.get("capture_time_utc"),
    }


hosts = [
    host_entry(left_root, left_label, load_provenance(left_prov)),
    host_entry(right_root, right_label, load_provenance(right_prov)),
]
os_values = sorted({host["os"] for host in hosts if host["os"]})
identity_keys = sorted({host["hostname"] or host["label"] for host in hosts})
distinct_hosts = len(identity_keys)
distinct_os = len(os_values)
physical_hosts = distinct_hosts >= 2 and all(
    host["hostname"] or host["label"] for host in hosts)
distinct_os_ok = distinct_os >= 2

reasons = []
if not physical_hosts:
    reasons.append("captures do not come from two distinct physical hosts")
if not distinct_os_ok:
    reasons.append("captures do not cover two distinct operating systems")

comparisons = {}


def comparison_entry(report_path, exit_code, ran):
    entry = {
        "ran": ran,
        "report": report_path if ran else None,
        "exit_code": exit_code,
        "passed": False,
        "failures": [],
    }
    if ran and report_path and os.path.isfile(report_path):
        try:
            with open(report_path, "r", encoding="utf-8") as handle:
                report = json.load(handle)
        except (OSError, ValueError):
            report = {}
        control = report.get("control") or {}
        entry["passed"] = (exit_code == 0
                           and not report.get("failures"))
        entry["failures"] = report.get("failures") or []
        entry["mode"] = report.get("mode")
        entry["fixtures_compared"] = control.get("fixtures_compared")
        entry["identical_fixtures"] = control.get("identical_fixtures")
        entry["workloads_compared"] = control.get("workloads_compared")
        entry["identical_workloads"] = control.get("identical_workloads")
        entry["state_comparison"] = report.get("state_comparison")
        entry["identical"] = control.get("clean")
    elif not ran:
        entry["passed"] = True
        entry["skipped"] = True
    else:
        entry["passed"] = False
    return entry


comparisons["traces"] = comparison_entry(
    os.path.join(out_dir, "cross-machine-trace.json"),
    int(trace_status), True)
comparisons["candidates"] = comparison_entry(
    os.path.join(out_dir, "cross-machine-candidates.json"),
    int(cand_status), cand_ran == "true")

if not comparisons["traces"]["passed"]:
    reasons.append("trace comparison found differences or failed")
if not comparisons["candidates"]["passed"]:
    reasons.append("candidate comparison found differences or failed")
if header_incompat == "1":
    reasons.append("trace headers carry different CORE-MATH revisions")

incompatible = header_incompat == "1"
complete = (not incompatible and physical_hosts and distinct_os_ok
            and comparisons["traces"]["passed"]
            and comparisons["candidates"]["passed"])

summary = {
    "format": "peggle.cross_machine_summary",
    "schema_version": 1,
    "mode": "cross_machine",
    "hosts": hosts,
    "os_values": os_values,
    "distinct_hosts": distinct_hosts,
    "distinct_os": distinct_os,
    "physical_hosts": physical_hosts,
    "candidates_compared": cand_ran == "true",
    "comparisons": comparisons,
    "incompatible": incompatible,
    "complete": complete,
    "reasons": reasons,
}

with open(os.path.join(out_dir, "cross-machine-summary.json"),
          "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2, sort_keys=True)
    handle.write("\n")

print("cross-machine summary: complete=%s physical_hosts=%s distinct_os=%d"
      % (str(complete).lower(), str(physical_hosts).lower(), distinct_os))
for reason in reasons:
    print("  reason: " + reason)
PY

summary_status=$?
if [ "$summary_status" -ne 0 ]; then
  echo "ERROR: could not write cross-machine-summary.json" >&2
  exit 2
fi

if [ "$header_incompat" -eq 1 ]; then
  exit 3
fi
if [ "$trace_status" -ne 0 ] || [ "$cand_status" -ne 0 ]; then
  exit 1
fi
echo "wpd_compare_hosts: OK"
exit 0
