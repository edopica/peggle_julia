#!/usr/bin/env bash
#
# verify_core_math.sh - verify the pinned native math component (WP-B).
#
# Checks, in order:
#   1. vendored CORE-MATH files against native/core-math/files.sha256
#   2. the built artifact against libpeggle_math.so.sha256 and build.json
#   3. the exported/undefined symbol sets against the frozen ABI and the
#      audit record in build.json (no host transcendentals)
#   4. ABI version and identity JSON through dlopen (python3 ctypes)
#
# A prebuilt native/build_generated/smoke_test is run too when present.
#
# Usage: scripts/verify_core_math.sh [--platform linux-x86_64]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM="linux-x86_64"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      [[ $# -ge 2 ]] || { echo "error: --platform requires an argument" >&2; exit 1; }
      PLATFORM="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: scripts/verify_core_math.sh [--platform linux-x86_64]"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

VENDOR_DIR="$REPO_ROOT/native/core-math"
ARTIFACT_DIR="$REPO_ROOT/native/artifacts/$PLATFORM"
LIB="$ARTIFACT_DIR/libpeggle_math.so"
BUILD_JSON="$ARTIFACT_DIR/build.json"
SHA_FILE="$ARTIFACT_DIR/libpeggle_math.so.sha256"

[[ -f "$VENDOR_DIR/files.sha256" ]] || { echo "error: missing $VENDOR_DIR/files.sha256" >&2; exit 1; }
[[ -f "$LIB" ]] || { echo "error: missing $LIB (run 'make core-math-build' first)" >&2; exit 1; }
[[ -f "$BUILD_JSON" ]] || { echo "error: missing $BUILD_JSON" >&2; exit 1; }
[[ -f "$SHA_FILE" ]] || { echo "error: missing $SHA_FILE" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 1; }
command -v nm >/dev/null 2>&1 || { echo "error: nm (binutils) is required" >&2; exit 1; }

echo "==> vendored CORE-MATH pin (native/core-math/files.sha256)"
(cd "$VENDOR_DIR" && sha256sum --quiet -c files.sha256)
echo "    OK: $(wc -l < "$VENDOR_DIR/files.sha256" | tr -d ' ') hashed files"

echo "==> artifact checksum (native/artifacts/$PLATFORM/libpeggle_math.so.sha256)"
(cd "$ARTIFACT_DIR" && sha256sum --quiet -c libpeggle_math.so.sha256)
echo "    OK"

echo "==> ABI, identity, and symbol audit"
python3 - "$REPO_ROOT" "$PLATFORM" <<'PY'
import ctypes
import hashlib
import json
import os
import re
import struct
import subprocess
import sys

repo, platform = sys.argv[1], sys.argv[2]
vendor = os.path.join(repo, "native", "core-math")
adir = os.path.join(repo, "native", "artifacts", platform)
lib = os.path.join(adir, "libpeggle_math.so")

def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)

with open(os.path.join(adir, "build.json"), encoding="utf-8") as f:
    build = json.load(f)
with open(os.path.join(vendor, "PIN.md"), encoding="utf-8") as f:
    pin_text = f.read()
m = re.search(r"^\| Revision \| `([0-9a-f]{40})`", pin_text, re.M)
if not m:
    fail("could not parse revision from native/core-math/PIN.md")
revision = m.group(1)

if build["platform"] != platform:
    fail(f"build.json platform {build['platform']!r} != {platform!r}")
if build["core_math"]["revision"] != revision:
    fail("build.json revision does not match PIN.md")

with open(lib, "rb") as f:
    artifact_sha = hashlib.sha256(f.read()).hexdigest()
if artifact_sha != build["artifact"]["sha256"]:
    fail("artifact sha256 does not match build.json")

expected_defined = sorted([
    "peggle_math_abi_version",
    "peggle_math_identity",
    "peggle_math_sin",
    "peggle_math_cos",
    "peggle_math_tan",
    "peggle_math_asin",
    "peggle_math_acos",
    "peggle_math_atan",
    "peggle_math_atan2",
    "peggle_math_exp",
    "peggle_math_log",
    "peggle_math_pow",
    "peggle_math_sqrt",
])
out = subprocess.check_output(["nm", "-D", "--defined-only", lib], text=True)
defined = sorted(line.split()[-1] for line in out.splitlines() if line.strip())
if defined != expected_defined:
    fail(f"exported symbols differ from ABI v1\nexpected: {expected_defined}\nactual:   {defined}")

audit = build["undefined_symbol_audit"]
allowed_strong = set(audit["allowed_symbols"])
allowed_weak = set(audit["allowed_weak_symbols"])
forbidden = set(audit["forbidden_symbols"])
out = subprocess.check_output(["nm", "-D", "--undefined-only", lib], text=True)
strong, weak = set(), set()
for line in out.splitlines():
    parts = line.split()
    if len(parts) < 2:
        continue
    typ, name = parts[0], parts[1].split("@")[0]
    (weak if typ in ("w", "v") else strong).add(name)
bad_forbidden = strong & forbidden
if bad_forbidden:
    fail(f"forbidden host math symbols are undefined: {sorted(bad_forbidden)}")
unexpected_strong = strong - allowed_strong
unexpected_weak = weak - allowed_weak
if unexpected_strong or unexpected_weak:
    fail(f"unexpected undefined symbols: strong={sorted(unexpected_strong)} weak={sorted(unexpected_weak)}")

clib = ctypes.CDLL(lib)
clib.peggle_math_abi_version.restype = ctypes.c_int
clib.peggle_math_abi_version.argtypes = []
if clib.peggle_math_abi_version() != 1:
    fail(f"peggle_math_abi_version() == {clib.peggle_math_abi_version()}, expected 1")
clib.peggle_math_identity.restype = ctypes.c_char_p
ident = json.loads(clib.peggle_math_identity().decode("utf-8"))
if ident["abi_version"] != 1 or ident["name"] != "peggle_math":
    fail("identity JSON abi_version/name is wrong")
if ident["core_math_revision"] != revision:
    fail("identity JSON core_math_revision does not match PIN.md")
if ident["platform"] != platform:
    fail("identity JSON platform does not match")
if ident["sqrt_implementation"] != "hardware-ieee754":
    fail("identity JSON sqrt_implementation is wrong")

def bits(x):
    return struct.unpack("<Q", struct.pack("<d", x))[0]

for name in ("sin", "cos", "tan", "asin", "acos", "atan", "atan2", "exp", "log", "pow", "sqrt"):
    fn = getattr(clib, "peggle_math_" + name)
    fn.restype = ctypes.c_double
    fn.argtypes = [ctypes.c_double] * (2 if name in ("atan2", "pow") else 1)
cases = [
    ("sin", (0.0,), 0x0000000000000000),
    ("sin", (-0.0,), 0x8000000000000000),
    ("cos", (0.0,), 0x3FF0000000000000),
    ("sin", (1.0,), 0x3FEAED548F090CEE),
    ("tan", (0.0,), 0x0000000000000000),
    ("asin", (0.0,), 0x0000000000000000),
    ("acos", (1.0,), 0x0000000000000000),
    ("atan2", (1.0, 1.0), 0x3FE921FB54442D18),
    ("exp", (0.0,), 0x3FF0000000000000),
    ("log", (1.0,), 0x0000000000000000),
    ("pow", (2.0, 10.0), 0x4090000000000000),
    ("sqrt", (4.0,), 0x4000000000000000),
]
for name, args, want in cases:
    got = bits(getattr(clib, "peggle_math_" + name)(*args))
    if got != want:
        fail(f"peggle_math_{name}{args} = 0x{got:016x}, expected 0x{want:016x}")
if not (bits(clib.peggle_math_sqrt(-1.0)) & 0x7FF0000000000000):
    fail("peggle_math_sqrt(-1.0) is not NaN")

print(f"    OK: ABI 1; revision {revision}; artifact {artifact_sha[:12]}")
print(f"    OK: exported symbols ({len(defined)}): {' '.join(defined)}")
print(f"    OK: undefined strong: {' '.join(sorted(strong))}")
print(f"    OK: undefined weak: {' '.join(sorted(weak))}")
PY

if [[ -x "$REPO_ROOT/native/build_generated/smoke_test" ]]; then
  echo "==> smoke test"
  LD_LIBRARY_PATH="$ARTIFACT_DIR" "$REPO_ROOT/native/build_generated/smoke_test"
fi

echo "core-math verify OK ($PLATFORM)"
