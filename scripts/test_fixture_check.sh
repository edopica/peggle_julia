#!/usr/bin/env bash
# Negative regression test for `--fixtures --check`.
#
# The verifier must never write into the reference corpus:
#   1. corrupt a trace in a scratch corpus copy and require check mode to fail;
#   2. require the corrupted trace to be byte-unchanged after the failure;
#   3. run check mode on a clean copy (a trace-backed shot and a scenario) and
#      require success with every scratch file hash unchanged.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

pin="$repo_root/reference/PIN.md"
revision="$(sed -n 's/.*Revision (full) | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
tree="$(sed -n 's/.*Tree hash | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
if [[ -z "$revision" || -z "$tree" ]]; then
  echo "ERROR: cannot read revision/tree from $pin" >&2
  exit 1
fi
config_sha="$(sha256sum "$repo_root/reference/peggle_evolved/src/config.lua" | awk '{print $1}')"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

make_corpus() {
  local dir="$1"
  mkdir -p "$dir/expected" "$dir/traces"
  cp -a "$repo_root/fixtures/expected/." "$dir/expected/"
  cp -a "$repo_root/fixtures/traces/." "$dir/traces/"
}

run_check() {
  local dir="$1"
  shift
  scripts/love.sh love harness -- \
    --fixtures --check \
    --reference-revision "$revision" \
    --reference-tree "$tree" \
    --config-sha256 "$config_sha" \
    --fixtures-out "$dir/expected" \
    --fixtures-traces "$dir/traces" \
    "$@"
}

snapshot_hashes() {
  local dir="$1"
  (cd "$dir" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
}

failures=0

echo "== corrupted corpus: check mode must fail and preserve the trace =="
bad="$scratch/bad"
make_corpus "$bad"
printf 'X' >> "$bad/traces/slide_rail_graze.jsonl"
corrupt_sha="$(sha256sum "$bad/traces/slide_rail_graze.jsonl" | awk '{print $1}')"

if run_check "$bad" --id slide_rail_graze > "$scratch/bad.log" 2>&1; then
  echo "FAIL: check mode reported success on a corrupted reference trace" >&2
  cat "$scratch/bad.log" >&2
  failures=$((failures + 1))
else
  echo "OK: check mode failed as expected"
  tail -1 "$scratch/bad.log" >&2 || true
fi

after_sha="$(sha256sum "$bad/traces/slide_rail_graze.jsonl" | awk '{print $1}')"
if [[ "$after_sha" != "$corrupt_sha" ]]; then
  echo "FAIL: check mode overwrote the corrupted trace ($corrupt_sha -> $after_sha)" >&2
  failures=$((failures + 1))
else
  echo "OK: corrupted trace left untouched"
fi

echo "== clean corpus: check mode must succeed without writing =="
clean="$scratch/clean"
make_corpus "$clean"
before="$(snapshot_hashes "$clean")"

if run_check "$clean" --id slide_rail_graze > "$scratch/clean_shot.log" 2>&1; then
  echo "OK: trace-backed shot fixture verified"
else
  echo "FAIL: clean trace-backed shot fixture did not verify" >&2
  cat "$scratch/clean_shot.log" >&2
  failures=$((failures + 1))
fi

if run_check "$clean" --id probe_annular_outer_surface > "$scratch/clean_scenario.log" 2>&1; then
  echo "OK: scenario fixture verified"
else
  echo "FAIL: clean scenario fixture did not verify" >&2
  cat "$scratch/clean_scenario.log" >&2
  failures=$((failures + 1))
fi

after="$(snapshot_hashes "$clean")"
if [[ "$before" != "$after" ]]; then
  echo "FAIL: check mode modified the clean corpus:" >&2
  diff <(echo "$before") <(echo "$after") >&2 || true
  failures=$((failures + 1))
else
  echo "OK: clean corpus hashes unchanged"
fi

if [[ $failures -ne 0 ]]; then
  echo "test_fixture_check: $failures failure(s)" >&2
  exit 1
fi
echo "test_fixture_check: OK"
