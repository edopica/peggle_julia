#!/usr/bin/env bash
# Experimental CORE-MATH-era parity census capture (WP-D open item).
#
# Produces tmp/core-math/parity/math_census.v1.json in the historical census
# schema (fixtures/math_census/math_census.v1.json) and with the SAME input
# corpus, but with expected values computed through the dev tree
# ../peggle_evolved/src/detmath under PEGGLE_MATH_BACKEND=core_math (default),
# with PEGGLE_MATH_LIB pointing at this repository's built artifact. The
# historical fixture is never read as expectations and never modified.
#
# Usage:
#   scripts/capture_wpd_parity_census.sh [--out PATH] [--detmath-root PATH]
#
# Environment overrides:
#   PEGGLE_MATH_BACKEND  backend used for the capture (default core_math)
#   PEGGLE_MATH_LIB      native artifact loaded by the dev tree (default
#                        native/artifacts/linux-x86_64/libpeggle_math.so)
#   WPD_DETMATH_ROOT     dev tree root (default ../peggle_evolved)
#
# The script fails when the dev tree or the artifact is missing, when the
# selected backend does not match the request, or when the recomputed
# inputs/counts differ from the historical census.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

out="$repo_root/tmp/core-math/parity/math_census.v1.json"
detmath_root="${WPD_DETMATH_ROOT:-$repo_root/../peggle_evolved}"
backend="${PEGGLE_MATH_BACKEND:-core_math}"
native_lib="${PEGGLE_MATH_LIB:-$repo_root/native/artifacts/linux-x86_64/libpeggle_math.so}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      [[ $# -ge 2 ]] || { echo "missing value for --out" >&2; exit 2; }
      out="$2"
      shift 2
      ;;
    --detmath-root)
      [[ $# -ge 2 ]] || { echo "missing value for --detmath-root" >&2; exit 2; }
      detmath_root="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,22p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "capture_wpd_parity_census: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

ref_dir="$repo_root/reference/peggle_evolved"
pin="$repo_root/reference/PIN.md"
historical="$repo_root/fixtures/math_census/math_census.v1.json"

if [[ ! -f "$detmath_root/src/detmath.lua" ]]; then
  echo "ERROR: missing dev tree src/detmath.lua under $detmath_root" >&2
  exit 1
fi
if [[ ! -f "$native_lib" ]]; then
  echo "ERROR: missing native math artifact: $native_lib" >&2
  echo "       run scripts/capture_wpd_parity_census.sh --help for overrides" >&2
  exit 1
fi
if [[ ! -f "$historical" ]]; then
  echo "ERROR: missing historical census fixture: $historical" >&2
  exit 1
fi

revision="$(sed -n 's/.*Revision (full) | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
tree="$(sed -n 's/.*Tree hash | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
if [[ -z "$revision" || -z "$tree" ]]; then
  echo "ERROR: cannot read revision/tree from $pin" >&2
  exit 1
fi
config_sha="$(sha256sum "$ref_dir/src/config.lua" | awk '{print $1}')"

echo "capture_wpd_parity_census: backend=$backend detmath-root=$detmath_root"
echo "capture_wpd_parity_census: native-lib=$native_lib"
PEGGLE_MATH_BACKEND="$backend" PEGGLE_MATH_LIB="$native_lib" \
  luajit "$repo_root/tools/capture_math_census.lua" \
  --reference-revision "$revision" \
  --reference-tree "$tree" \
  --config-sha256 "$config_sha" \
  --detmath-root "$detmath_root" \
  --out "$out"

python3 - "$historical" "$out" "$backend" <<'PY'
import json
import sys

hist_path, exp_path, backend = sys.argv[1], sys.argv[2], sys.argv[3]


def fail(message):
    print("capture_wpd_parity_census: FAIL: " + message, file=sys.stderr)
    sys.exit(1)


with open(hist_path) as handle:
    hist = json.load(handle)
with open(exp_path) as handle:
    exp = json.load(handle)

if hist.get("format") != exp.get("format"):
    fail("format differs: {} != {}".format(hist.get("format"), exp.get("format")))
if hist.get("schema_version") != exp.get("schema_version"):
    fail("schema_version differs")
if hist.get("format") != "peggle.math_census":
    fail("unexpected historical format")

# The experimental fixture must reuse the historical input corpus exactly.
for section in ("inputs", "counts"):
    if hist.get(section) != exp.get(section):
        fail("{} differ from the historical census; refusing a partial corpus"
             .format(section))
for key in ("reference_revision", "reference_tree", "config_sha256",
            "fixtures_sha256"):
    if hist["source"].get(key) != exp["source"].get(key):
        fail("source.{} differs from the historical census".format(key))

math_backend = exp.get("source", {}).get("math_backend")
if not isinstance(math_backend, dict):
    fail("missing source.math_backend provenance block")
if math_backend.get("backend") != backend:
    fail("source.math_backend.backend is {}, expected {}"
         .format(math_backend.get("backend"), backend))

total = 0
differences = 0
by_function = {}
first = None
for name in sorted(hist["expected"]):
    want = hist["expected"][name]
    got = exp["expected"].get(name)
    if got is None or len(got) != len(want):
        fail("expected['{}'] is missing or has a different length".format(name))
    total += len(want)
    for index, (historical_bits, core_bits) in enumerate(zip(want, got)):
        if historical_bits == core_bits:
            continue
        differences += 1
        by_function[name] = by_function.get(name, 0) + 1
        if first is None:
            first = (name, index, historical_bits, core_bits)

print("capture_wpd_parity_census: input corpus identical to the historical "
      "census ({} cases)".format(total))
print("capture_wpd_parity_census: backend={} expected differences: {} of {}"
      .format(backend, differences, total))
if by_function:
    print("capture_wpd_parity_census: by function: " + ", ".join(
        "{} {}".format(name, by_function[name]) for name in sorted(by_function)))
if first is not None:
    print("capture_wpd_parity_census: first difference: {}[{}] "
          "historical={} {}={}".format(first[0], first[1], first[2],
                                       backend, first[3]))
PY

echo "capture_wpd_parity_census: wrote $out"
