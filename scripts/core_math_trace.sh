#!/usr/bin/env bash
# WP-E on-host: Lua gameplay-trace and candidate comparison for CORE-MATH.
#
# Usage:
#   scripts/core_math_trace.sh
#
# Writes under tmp/core-math/:
#   traces/reference/{expected,traces}/     pinned reference capture
#   traces/system_libm/{expected,traces}/   dev-tree system_libm capture
#   traces/core_math/{expected,traces}/     dev-tree CORE-MATH capture
#   trace-control.json                      reference vs system_libm control
#   trace-compare.json                      system_libm vs core_math comparison
#   trace-volatile-sample.json              fixtures/traces vs fresh reference
#   trace-volatile-paths.json               empirically allowed volatile paths
#   control-expected.diff                   byte diff of the control expected dirs
#   candidates/{reference,system_libm,core_math}/{raw.candidates.jsonl,
#       summary.summary.json}
#   candidate-control.json                  reference vs system_libm control
#   candidate-compare.json                  system_libm vs core_math comparison
#
# Control policy (wpef-plan.md):
#   reference and system_libm expected records must be byte-identical and
#   traces semantically identical. Any control difference outside the
#   documented volatile fields is a hard failure (exit 1). Core-vs-system
#   differences are the measured outcome: recorded and classified, never a
#   script failure. The script fails only on an unclean control or a failed
#   capture/comparison.
#
# Config override:
#   A pre-existing src/config.lua edit in the dev tree is not a refusal
#   condition. The script verifies reference/peggle_evolved/src/config.lua
#   against the pinned hash and overlays that pinned config at runtime
#   (--config-file) for every dev-tree capture and sweep. The dev tree file
#   is never modified, and the override is recorded in the comparison
#   environment (config_override, dev_config_sha256, pinned_config_sha256).
#
# Trace snapshots:
#   Fresh WP-E captures include the full authoritative per-step snapshot
#   (--fixtures-snapshots); the reference-vs-system_libm control therefore
#   compares full simulation state, not only events and results. Full state
#   (state_comparison == "full": a snapshot at every recorded step on both
#   sides with identical step-id sets) is required for every trace-enabled
#   fixture, i.e. the 6 catalog entries that declare trace = true; a guard
#   after the control fails if any of them is not full or its trace is
#   missing. The other fixtures are result-only expected-record
#   comparisons. The expected set is derived from the committed corpus, so
#   a missing trace fails the guard instead of lowering the count.
#   Incomplete coverage (missing steps, one-sided holes, or an
#   include_snapshot header the records do not support) is a failure, not
#   partial agreement. The historical fixtures/traces comparison stays
#   snapshot-free because those files predate snapshot capture; it is
#   recorded as scope_mismatch event/result agreement, not a failure.
#   scripts/capture_fixtures.sh still captures the pinned corpus
#   snapshot-free and byte-identical.
#
# Volatile fields:
#   There are NO exempt volatile fields. Fever-bucket state is
#   authoritative, not animation-only: src/engine/core.lua passes
#   feverBuckets.dividers into Physics.update as collision geometry, and
#   src/entities/fever_buckets.lua uses animating to gate the per-step
#   bucket/divider update. In this harness every authoritative update uses
#   Config.fixed_dt, so the fixed-step captures require exact equality. Any
#   difference in snapshot.fever_buckets.animating or
#   snapshot.fever_buckets.dividers[].y is classified state_bit_difference /
#   state_structure and is a failure, never volatile_animation. The script
#   compares fixtures/traces (a second identical-reference sample; no
#   re-capture) against the fresh reference capture with compare_traces.py
#   --strict-reference: any historical-vs-fresh difference other than the
#   recorded snapshot scope mismatch is a hard failure. --volatile-out
#   writes [] (trace-volatile-paths.json), and only an empty volatile
#   report is accepted; --volatile-report rejects every path, exit 2.
#
# Environment matrix (step 8): hosts=1, os=["linux"], complete=false. This is
# single-host, single-OS evidence. Cross-machine and cross-OS exact agreement
# remain open WP-E items; no cross-machine claim is made here.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

dev_tree="$repo_root/../peggle_evolved"
dev_tree_arg="../peggle_evolved"
dev_artifact="$dev_tree/native/linux-x86_64/libpeggle_math.so"
artifact="$repo_root/native/artifacts/linux-x86_64/libpeggle_math.so"
out_dir="$repo_root/tmp/core-math"
traces_root="$out_dir/traces"
candidates_root="$out_dir/candidates"
pin="$repo_root/reference/PIN.md"
ref_dir="$repo_root/reference/peggle_evolved"

environment_note="On-host WP-E evidence only (single Linux x86-64 host). Cross-machine and cross-OS exact agreement remain open WP-E items; no cross-machine claim is made."

for tool in python3 diff sha256sum; do
  command -v "$tool" > /dev/null 2>&1 || {
    echo "ERROR: $tool is required" >&2
    exit 1
  }
done

if [[ ! -d "$dev_tree" ]]; then
  echo "ERROR: peggle_evolved development tree not found at $dev_tree" >&2
  exit 1
fi
if [[ ! -f "$dev_artifact" ]]; then
  echo "ERROR: $dev_artifact is missing; run 'make math-native' in peggle_evolved" >&2
  exit 1
fi
if [[ ! -r "$artifact" ]]; then
  echo "ERROR: $artifact is missing or unreadable; run 'make core-math-build'" >&2
  exit 1
fi

revision="$(sed -n 's/.*Revision (full) | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
tree="$(sed -n 's/.*Tree hash | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
if [[ -z "$revision" || -z "$tree" ]]; then
  echo "ERROR: cannot read revision/tree from $pin" >&2
  exit 1
fi
config_sha="$(sha256sum "$ref_dir/src/config.lua" | awk '{print $1}')"

# The control requires the dev tree to behave exactly like the pinned
# authoritative config. A pre-existing working-tree edit (e.g.
# ball_ball_restitution) changes gameplay independently of the math backend;
# it is overlaid at runtime with the pinned config instead of being
# reconciled in the dev tree. The dev tree file is never modified.
config_override_args=()
dev_config_sha="$(sha256sum "$dev_tree/src/config.lua" | awk '{print $1}')"
if [[ "$dev_config_sha" != "$config_sha" ]]; then
  echo "WARNING: dev tree config.lua differs from the pinned reference config" >&2
  echo "  dev tree: $dev_config_sha" >&2
  echo "  pin:      $config_sha" >&2
  echo "The dev tree has a pre-existing config edit. The pinned config is" >&2
  echo "overlaid at runtime (--config-file) for all dev-tree captures and" >&2
  echo "sweeps; the dev tree file is not modified. The override is recorded" >&2
  echo "in the comparison environment (config_override=true)." >&2
  override_file="$ref_dir/src/config.lua"
  if [[ ! -f "$override_file" ]]; then
    echo "ERROR: config override file missing: $override_file" >&2
    exit 1
  fi
  override_sha="$(sha256sum "$override_file" | awk '{print $1}')"
  if [[ "$override_sha" != "$config_sha" ]]; then
    echo "ERROR: config override $override_file sha256 $override_sha" >&2
    echo "  does not match the pinned config sha256 $config_sha" >&2
    exit 1
  fi
  config_override_args=(--config-file "$override_file")
  environment_json="$(printf '{"hosts":1,"os":["linux"],"complete":false,"note":"%s","config_override":true,"dev_config_sha256":"%s","pinned_config_sha256":"%s"}' \
    "$environment_note" "$dev_config_sha" "$config_sha")"
else
  environment_json="$(printf '{"hosts":1,"os":["linux"],"complete":false,"note":"%s","config_override":false,"pinned_config_sha256":"%s"}' \
    "$environment_note" "$config_sha")"
fi

mkdir -p "$out_dir"
for backend in reference system_libm core_math; do
  mkdir -p "$traces_root/$backend/expected" "$traces_root/$backend/traces"
  mkdir -p "$candidates_root/$backend"
done

echo "core_math_trace: repo=$repo_root"
echo "  dev_tree=$dev_tree"
echo "  artifact=$artifact ($(sha256sum "$artifact" | awk '{print $1}'))"
echo "  reference=$revision config_sha256=$config_sha"

start_seconds=$SECONDS

# ---------------------------------------------------------------------------
# 1. Reference pin
# ---------------------------------------------------------------------------
echo "[1/8] verify_reference.sh (before)"
"$repo_root/scripts/verify_reference.sh"

# ---------------------------------------------------------------------------
# 2-3. Fixture captures
# ---------------------------------------------------------------------------
capture_backend() {
  local backend="$1"
  local reference_arg="$2"
  local target="$3"
  shift 3
  local -a env_args ref_args
  if [[ "$backend" == "reference" ]]; then
    env_args=(env -u PEGGLE_MATH_BACKEND -u PEGGLE_MATH_LIB)
  else
    env_args=(env "PEGGLE_MATH_BACKEND=$backend" "PEGGLE_MATH_LIB=$artifact")
  fi
  if [[ -n "$reference_arg" ]]; then
    ref_args=(--reference-dir "$reference_arg")
  else
    ref_args=()
  fi
  "${env_args[@]}" "$repo_root/scripts/love.sh" love "$repo_root/harness" -- \
    --fixtures \
    --fixtures-snapshots \
    --fixtures-out "$target/expected" \
    --fixtures-traces "$target/traces" \
    --reference-revision "$revision" \
    --reference-tree "$tree" \
    --config-sha256 "$config_sha" \
    "${ref_args[@]}" \
    "$@"
}

echo "[2/8] capture fixtures with the pinned reference"
capture_backend reference "" "$traces_root/reference"

echo "[3/8] capture fixtures with the dev tree (system_libm control)"
capture_backend system_libm "$dev_tree_arg" "$traces_root/system_libm" \
  "${config_override_args[@]+"${config_override_args[@]}"}"

echo "[4/8] capture fixtures with the dev tree (core_math)"
capture_backend core_math "$dev_tree_arg" "$traces_root/core_math" \
  "${config_override_args[@]+"${config_override_args[@]}"}"

# ---------------------------------------------------------------------------
# 4. Control: reference vs system_libm
# ---------------------------------------------------------------------------
# Guard below: every trace-enabled fixture must be a full-state comparison.
echo "[5/8] control comparison (reference vs system_libm)"
volatile_sample="$out_dir/trace-volatile-sample.json"
volatile_paths="$out_dir/trace-volatile-paths.json"
control_expected_diff="$out_dir/control-expected.diff"

expected_byte_identical=false
if diff -r "$traces_root/reference/expected" "$traces_root/system_libm/expected" \
    > "$control_expected_diff" 2>&1; then
  expected_byte_identical=true
fi

# A second identical-reference sample (historical fixtures/traces, captured
# from the pinned reference, snapshot-free) identifies fields that vary
# between identical systems. --strict-reference makes any difference outside
# the explicit volatile allowlist a hard failure. No reference re-capture is
# performed.
python3 "$repo_root/tools/compare_traces.py" \
  --strict-reference \
  --left-traces "$repo_root/fixtures/traces" \
  --left-expected "$repo_root/fixtures/expected" \
  --right-traces "$traces_root/reference/traces" \
  --right-expected "$traces_root/reference/expected" \
  --left-label fixtures-reference \
  --right-label fresh-reference \
  --volatile-out "$volatile_paths" \
  --out "$volatile_sample"

set +e
python3 "$repo_root/tools/compare_traces.py" \
  --control \
  --left-traces "$traces_root/reference/traces" \
  --left-expected "$traces_root/reference/expected" \
  --right-traces "$traces_root/system_libm/traces" \
  --right-expected "$traces_root/system_libm/expected" \
  --left-label reference \
  --right-label system_libm \
  --volatile-report "$volatile_paths" \
  --out "$out_dir/trace-control.json"
control_status=$?
set -e

python3 - "$out_dir/trace-control.json" "$expected_byte_identical" <<'PY'
import json
import sys

path, flag = sys.argv[1], sys.argv[2] == "true"
with open(path, "r", encoding="utf-8") as handle:
    doc = json.load(handle)
doc["control"]["expected_byte_identical"] = flag
with open(path, "w", encoding="utf-8") as handle:
    json.dump(doc, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

if [[ "$control_status" -ne 0 ]]; then
  echo "ERROR: control (reference vs system_libm) failed; see $out_dir/trace-control.json" >&2
  exit 1
fi

# The control must be full-state for every trace-enabled fixture (the
# catalog entries that declare trace = true); the remaining fixtures are
# result-only expected-record comparisons. The expected set is derived from
# the committed corpus (expected records carrying a "trace" object,
# cross-checked against the committed .jsonl traces), so a missing
# committed trace fails the guard instead of lowering the expected count.
python3 - "$out_dir/trace-control.json" "$repo_root/fixtures/expected" \
  "$repo_root/fixtures/traces" <<'PY'
import glob
import json
import os
import sys

report_path, expected_dir, traces_dir = sys.argv[1:4]

trace_enabled = set()
for path in sorted(glob.glob(os.path.join(expected_dir, "*.json"))):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, ValueError) as exc:
        print("ERROR: cannot read %s: %s" % (path, exc), file=sys.stderr)
        sys.exit(1)
    if isinstance(record, dict) and isinstance(record.get("trace"), dict):
        trace_enabled.add(os.path.basename(path)[:-len(".json")])
if not trace_enabled:
    print("ERROR: no trace-enabled fixtures found in %s" % expected_dir,
          file=sys.stderr)
    sys.exit(1)

committed_traces = {
    os.path.basename(path)[:-len(".jsonl")]
    for path in glob.glob(os.path.join(traces_dir, "*.jsonl"))}
if trace_enabled != committed_traces:
    missing = sorted(trace_enabled - committed_traces)
    extra = sorted(committed_traces - trace_enabled)
    if missing:
        print("ERROR: committed traces missing for trace-enabled "
              "fixture(s): " + ", ".join(missing), file=sys.stderr)
    if extra:
        print("ERROR: committed trace(s) exist for non-trace fixture(s): "
              + ", ".join(extra), file=sys.stderr)
    sys.exit(1)

with open(report_path, "r", encoding="utf-8") as handle:
    doc = json.load(handle)
fixtures = doc["fixtures"]

problems = []
for fixture_id in sorted(trace_enabled):
    entry = fixtures.get(fixture_id)
    if entry is None:
        problems.append(
            "%s: no comparison result (trace missing?)" % fixture_id)
        continue
    if entry.get("traces_compared") is not True:
        problems.append("%s: trace not compared" % fixture_id)
    if entry.get("state_comparison") != "full":
        problems.append("%s: state_comparison=%r (expected \"full\")"
                        % (fixture_id, entry.get("state_comparison")))
    steps = entry.get("snapshot_steps_compared", 0)
    if not isinstance(steps, int) or steps <= 0:
        problems.append("%s: snapshot_steps_compared=%r (expected > 0)"
                        % (fixture_id, steps))

stray = sorted(
    fixture_id for fixture_id, entry in fixtures.items()
    if entry.get("traces_compared") is True
    and fixture_id not in trace_enabled)
if stray:
    problems.append(
        "trace produced for non-trace fixture(s): " + ", ".join(stray))

if problems:
    print("ERROR: control is not a full-state comparison:", file=sys.stderr)
    for problem in problems:
        print("  " + problem, file=sys.stderr)
    sys.exit(1)

result_only = sum(
    1 for fixture_id in fixtures if fixture_id not in trace_enabled)
print("control full-state: %d/%d trace-enabled fixtures; %d result-only"
      % (len(trace_enabled), len(trace_enabled), result_only))
PY

if [[ "$expected_byte_identical" != true ]]; then
  echo "WARNING: control expected records are not byte-identical; differences"
  echo "  are allowed only as volatile trace hashes (see trace-control.json)" >&2
fi

# ---------------------------------------------------------------------------
# 5. Core vs system comparison (differences are the measured outcome)
# ---------------------------------------------------------------------------
echo "[6/8] core comparison (system_libm vs core_math)"
python3 "$repo_root/tools/compare_traces.py" \
  --left-traces "$traces_root/system_libm/traces" \
  --left-expected "$traces_root/system_libm/expected" \
  --right-traces "$traces_root/core_math/traces" \
  --right-expected "$traces_root/core_math/expected" \
  --left-label system_libm \
  --right-label core_math \
  --volatile-report "$volatile_paths" \
  --control-json "$out_dir/trace-control.json" \
  --environment-json "$environment_json" \
  --out "$out_dir/trace-compare.json"

# The core_math capture must report the CORE-MATH backend in its trace header;
# a silent fallback to system_libm would otherwise look like a perfect match.
python3 - "$out_dir/trace-compare.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    doc = json.load(handle)
engaged = any(
    ((fixture.get("math_backend") or {}).get("right") or {}).get("name") == "core_math"
    for fixture in doc["fixtures"].values())
if not engaged:
    print("ERROR: no core_math backend identity found in the core trace headers; "
          "the CORE-MATH capture did not engage", file=sys.stderr)
    sys.exit(1)
PY

# ---------------------------------------------------------------------------
# 6. Candidate sample
# ---------------------------------------------------------------------------
run_sweep() {
  local backend="$1"
  local name="$2"
  local reference_arg="$3"
  shift 3
  local -a env_args ref_args
  if [[ "$backend" == "reference" ]]; then
    env_args=(env -u PEGGLE_MATH_BACKEND -u PEGGLE_MATH_LIB)
  else
    env_args=(env "PEGGLE_MATH_BACKEND=$backend" "PEGGLE_MATH_LIB=$artifact")
  fi
  if [[ -n "$reference_arg" ]]; then
    ref_args=(--reference-dir "$reference_arg")
  else
    ref_args=()
  fi
  echo "  sweep: $name (backend=$backend)"
  "${env_args[@]}" RUN_ID="wpef-$name" HOST_LABEL="on-host" \
    "$repo_root/scripts/run_baseline.sh" \
    --stride 20 --repeat 1 \
    --out "$candidates_root/$name/raw" \
    --summary-out "$candidates_root/$name/summary" \
    "${ref_args[@]}" \
    "$@"
}

echo "[7/8] candidate sweeps (stride 20, repeat 1, all workloads)"
sweep_start=$SECONDS
run_sweep reference reference ""
run_sweep system_libm system_libm "$dev_tree_arg" \
  "${config_override_args[@]+"${config_override_args[@]}"}"
run_sweep core_math core_math "$dev_tree_arg" \
  "${config_override_args[@]+"${config_override_args[@]}"}"
sweep_seconds=$((SECONDS - sweep_start))

python3 "$repo_root/tools/compare_candidates.py" \
  --control \
  --left-raw "$candidates_root/reference/raw.candidates.jsonl" \
  --left-summary "$candidates_root/reference/summary.summary.json" \
  --right-raw "$candidates_root/system_libm/raw.candidates.jsonl" \
  --right-summary "$candidates_root/system_libm/summary.summary.json" \
  --left-label reference \
  --right-label system_libm \
  --out "$out_dir/candidate-control.json"

python3 "$repo_root/tools/compare_candidates.py" \
  --left-raw "$candidates_root/system_libm/raw.candidates.jsonl" \
  --left-summary "$candidates_root/system_libm/summary.summary.json" \
  --right-raw "$candidates_root/core_math/raw.candidates.jsonl" \
  --right-summary "$candidates_root/core_math/summary.summary.json" \
  --left-label system_libm \
  --right-label core_math \
  --control-json "$out_dir/candidate-control.json" \
  --environment-json "$environment_json" \
  --out "$out_dir/candidate-compare.json"

# ---------------------------------------------------------------------------
# 7. Reference pin after the captures
# ---------------------------------------------------------------------------
echo "[8/8] verify_reference.sh (after)"
"$repo_root/scripts/verify_reference.sh"

elapsed=$((SECONDS - start_seconds))
echo "core_math_trace: OK (sweeps ${sweep_seconds}s, total ${elapsed}s)"
echo "  trace-compare.json    $out_dir/trace-compare.json"
echo "  candidate-compare.json $out_dir/candidate-compare.json"
