#!/usr/bin/env bash
# Reproducibility and schema check for the M1 interchange artifacts.
#
#   1. run the canonical JSON codec unit tests;
#   2. export into a scratch directory and require byte-identical output;
#   3. verify the committed manifest;
#   4. validate every artifact and fixture record against schemas/;
#   5. run the negative/regression checkpoint contract cases;
#   6. run the parity comparison contract cases;
#   7. run the trace comparison contract cases.
#
# With --with-fixtures, also re-captures the reference fixtures under LÖVE
# and requires byte-identical expected records, then runs the negative
# corpus-integrity test (a corrupted scratch trace must fail verification
# without being rewritten). Needs a display; use xvfb-run on servers.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

with_fixtures=0
for arg in "$@"; do
  case "$arg" in
    --with-fixtures) with_fixtures=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

echo "== 1/7 canonical JSON codec tests =="
luajit tools/canonical_json_test.lua

echo "== 2/7 export reproducibility =="
INTERCHANGE_DIR="$scratch/interchange" scripts/export_interchange.sh > "$scratch/export.log" 2>&1
if diff -r "$scratch/interchange" "$repo_root/interchange" > "$scratch/diff.log" 2>&1; then
  echo "OK: scratch export matches interchange/"
else
  echo "ERROR: export is not reproducible:" >&2
  cat "$scratch/diff.log" >&2
  exit 1
fi

echo "== 3/7 manifest =="
scripts/verify_interchange.sh

echo "== 4/7 schema validation =="
scripts/validate_interchange.py

echo "== 5/7 checkpoint contract cases =="
scripts/test_checkpoint_contract.sh

echo "== 6/7 parity comparison contract cases =="
scripts/test_compare_parity.sh

echo "== 7/7 trace comparison contract cases =="
scripts/test_compare_traces.sh

if [[ $with_fixtures -eq 1 ]]; then
  echo "== fixtures: re-capture and compare =="
  scripts/capture_fixtures.sh --check > "$scratch/fixtures.log" 2>&1
  tail -1 "$scratch/fixtures.log"

  echo "== fixtures: check mode must not write the corpus =="
  scripts/test_fixture_check.sh > "$scratch/fixture_check.log" 2>&1
  tail -1 "$scratch/fixture_check.log"
fi

echo "interchange check OK"
