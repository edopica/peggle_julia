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
# Trace snapshots:
#   Fresh WP-E captures include the full authoritative per-step snapshot
#   (--fixtures-snapshots); the reference-vs-system_libm control therefore
#   compares full simulation state, not only events and results. The
#   historical fixtures/traces comparison is event/result agreement only
#   because those files predate snapshot capture; the snapshot scope
#   mismatch is recorded, not a failure. scripts/capture_fixtures.sh still
#   captures the pinned corpus snapshot-free and byte-identical.
#
# Volatile fields:
#   WP-C found that src/engine/core.lua updates fever-bucket animation with
#   the variable frame delta, so fever-bucket animation state can vary
#   run-to-run under load (wpc-acceptance.md item 3). In this harness every
#   authoritative update uses Config.fixed_dt, so the fresh pinned-reference
#   capture is expected byte-identical to the historical fixtures/traces.
#   The script compares fixtures/traces (a second identical-reference
#   sample; no re-capture) against the fresh reference capture with
#   compare_traces.py --strict-reference: any historical-vs-fresh difference
#   outside the explicit volatile allowlist is a hard failure. Allowed
#   paths, recorded in trace-volatile-paths.json and in
#   trace-compare.json:control.volatile_paths, are the only paths a control
#   difference may touch; they are classified volatile_animation. On this
#   host the discovered set was empty. No other volatile field is allowed.
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

environment_json='{"hosts":1,"os":["linux"],"complete":false,"note":"On-host WP-E evidence only (single Linux x86-64 host). Cross-machine and cross-OS exact agreement remain open WP-E items; no cross-machine claim is made."}'

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

# The control requires the dev tree to use the pinned authoritative config.
# A pre-existing working-tree edit (e.g. ball_ball_restitution) changes
# gameplay independently of the math backend; resolving it is a manual
# decision, never something this script may do.
dev_config_sha="$(sha256sum "$dev_tree/src/config.lua" | awk '{print $1}')"
if [[ "$dev_config_sha" != "$config_sha" ]]; then
  echo "ERROR: dev tree config.lua differs from the pinned reference config" >&2
  echo "  dev tree: $dev_config_sha" >&2
  echo "  pin:      $config_sha" >&2
  echo "The WP-E control requires identical authoritative configuration." >&2
  echo "Reconcile the pre-existing dev-tree edit (it is not a math-backend" >&2
  echo "difference), then re-run." >&2
  exit 1
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
    "${ref_args[@]}"
}

echo "[2/8] capture fixtures with the pinned reference"
capture_backend reference "" "$traces_root/reference"

echo "[3/8] capture fixtures with the dev tree (system_libm control)"
capture_backend system_libm "$dev_tree_arg" "$traces_root/system_libm"

echo "[4/8] capture fixtures with the dev tree (core_math)"
capture_backend core_math "$dev_tree_arg" "$traces_root/core_math"

# ---------------------------------------------------------------------------
# 4. Control: reference vs system_libm
# ---------------------------------------------------------------------------
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
    "${ref_args[@]}"
}

echo "[7/8] candidate sweeps (stride 20, repeat 1, all workloads)"
sweep_start=$SECONDS
run_sweep reference reference ""
run_sweep system_libm system_libm "$dev_tree_arg"
run_sweep core_math core_math "$dev_tree_arg"
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
