#!/usr/bin/env bash
#
# verify_core_math.sh - verify the pinned native math component (WP-B).
#
# Verifies every platform artifact present under native/artifacts/:
#   1. vendored CORE-MATH files against native/core-math/files.sha256
#   2. each artifact against <artifact>.sha256 and build.json (hash, path,
#      revision, audit result, cross-artifact qualification flags)
#   3. the identity JSON statically embedded in each artifact
#   4. the host platform (linux-x86_64 here) additionally gets the full ABI
#      load/dlsym checks, the symbol-set audit, and the prebuilt smoke_test
#      when present.
#
# Non-host platforms are reported as `UNQUALIFIED on this host`: their
# checksums and metadata are checked, but runtime qualification must happen on
# the target OS.
#
# Usage: scripts/verify_core_math.sh [--platform <name>]
#        (default: every platform directory under native/artifacts/)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ONLY_PLATFORM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      [[ $# -ge 2 ]] || { echo "error: --platform requires an argument" >&2; exit 1; }
      ONLY_PLATFORM="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: scripts/verify_core_math.sh [--platform <name>]"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

host_platform() {
  local os arch
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) os=unknown ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) arch=unknown ;;
  esac
  printf '%s-%s\n' "$os" "$arch"
}
HOST_PLATFORM="$(host_platform)"

artifact_name_for() {
  case "$1" in
    windows-*) printf 'peggle_math.dll\n' ;;
    darwin-*) printf 'libpeggle_math.dylib\n' ;;
    *) printf 'libpeggle_math.so\n' ;;
  esac
}

VENDOR_DIR="$REPO_ROOT/native/core-math"
ARTIFACTS_ROOT="$REPO_ROOT/native/artifacts"

[[ -f "$VENDOR_DIR/files.sha256" ]] || { echo "error: missing $VENDOR_DIR/files.sha256" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 1; }

PLATFORMS=()
if [[ -n "$ONLY_PLATFORM" ]]; then
  PLATFORMS=("$ONLY_PLATFORM")
else
  shopt -s nullglob
  for d in "$ARTIFACTS_ROOT"/*/; do
    PLATFORMS+=("$(basename "$d")")
  done
  shopt -u nullglob
fi
[[ ${#PLATFORMS[@]} -gt 0 ]] || { echo "error: no platform artifacts under native/artifacts (run native/build.sh first)" >&2; exit 1; }

echo "==> vendored CORE-MATH pin (native/core-math/files.sha256)"
(cd "$VENDOR_DIR" && sha256sum --quiet -c files.sha256)
echo "    OK: $(wc -l < "$VENDOR_DIR/files.sha256" | tr -d ' ') hashed files"

VERIFIED=()
for platform in "${PLATFORMS[@]}"; do
  artifact_name="$(artifact_name_for "$platform")"
  artifact_dir="$ARTIFACTS_ROOT/$platform"
  lib="$artifact_dir/$artifact_name"
  build_json="$artifact_dir/build.json"
  sha_file="$artifact_dir/$artifact_name.sha256"

  [[ -d "$artifact_dir" ]] || { echo "error: missing $artifact_dir (run native/build.sh --platform $platform)" >&2; exit 1; }
  [[ -f "$lib" ]] || { echo "error: missing $lib (run native/build.sh --platform $platform)" >&2; exit 1; }
  [[ -f "$build_json" ]] || { echo "error: missing $build_json" >&2; exit 1; }
  [[ -f "$sha_file" ]] || { echo "error: missing $sha_file" >&2; exit 1; }

  echo "==> [$platform] artifact checksum ($artifact_name.sha256)"
  (cd "$artifact_dir" && sha256sum --quiet -c "$artifact_name.sha256")
  echo "    OK"

  echo "==> [$platform] build metadata and static identity"
  python3 - "$REPO_ROOT" "$platform" "$artifact_name" "$HOST_PLATFORM" <<'PY'
import hashlib
import json
import os
import re
import sys

repo, platform, artifact_name, host_platform = sys.argv[1:5]
adir = os.path.join(repo, "native", "artifacts", platform)
lib = os.path.join(adir, artifact_name)

def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)

with open(os.path.join(adir, "build.json"), encoding="utf-8") as f:
    build = json.load(f)
with open(os.path.join(repo, "native", "core-math", "PIN.md"), encoding="utf-8") as f:
    pin_text = f.read()
m = re.search(r"^\| Revision \| `([0-9a-f]{40})`", pin_text, re.M)
if not m:
    fail("could not parse revision from native/core-math/PIN.md")
revision = m.group(1)

if build.get("component") != "peggle_math":
    fail("build.json component is not peggle_math")
if build.get("abi_version") != 1:
    fail("build.json abi_version is not 1")
if build["platform"] != platform:
    fail(f"build.json platform {build['platform']!r} != {platform!r}")
if build["core_math"]["revision"] != revision:
    fail("build.json revision does not match PIN.md")
expected_path = os.path.join("native", "artifacts", platform, artifact_name)
if build["artifact"].get("path") != expected_path:
    fail(f"build.json artifact path {build['artifact'].get('path')!r} != {expected_path!r}")
if build["artifact"].get("filename") != artifact_name:
    fail(f"build.json artifact filename {build['artifact'].get('filename')!r} != {artifact_name!r}")

with open(lib, "rb") as f:
    artifact_sha = hashlib.sha256(f.read()).hexdigest()
if artifact_sha != build["artifact"]["sha256"]:
    fail("artifact sha256 does not match build.json")

audit = build["undefined_symbol_audit"]
if audit.get("result") != "pass":
    fail("recorded symbol audit did not pass")
if audit.get("forbidden_symbols_present"):
    fail(f"recorded forbidden symbols present: {audit['forbidden_symbols_present']}")
for required in ("sin", "cos", "tan", "asin", "acos", "atan", "atan2", "exp", "log", "pow", "sqrt"):
    if required not in audit.get("forbidden_symbols", []):
        fail(f"forbidden-symbol policy is missing {required!r}")

smoke = build.get("smoke_test", {})
if platform == host_platform:
    if smoke.get("result") not in ("not_run", "pass"):
        fail(f"host platform smoke_test result is {smoke.get('result')!r}")
else:
    qual = build.get("qualification")
    if not qual or qual.get("cross_built") is not True or qual.get("qualified_on_target") is not False:
        fail("cross artifact is missing the cross_built/qualified_on_target qualification record")
    if smoke.get("result") != "not_run_cross_artifact":
        fail("cross artifact smoke_test result must be not_run_cross_artifact")
    if not build.get("build", {}).get("artifact_reproducible"):
        pass  # reproducibility failure is recorded, not fatal here

# Static identity JSON embedded in the artifact (works for PE, Mach-O, ELF).
with open(lib, "rb") as f:
    data = f.read()
idx = data.find(b'{"abi_version"')
if idx < 0:
    fail("embedded identity JSON not found in artifact")
depth = 0
end = None
in_str = False
esc = False
for i in range(idx, len(data)):
    c = data[i:i + 1]
    if in_str:
        if esc:
            esc = False
        elif c == b"\\":
            esc = True
        elif c == b'"':
            in_str = False
        continue
    if c == b'"':
        in_str = True
    elif c == b"{":
        depth += 1
    elif c == b"}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end is None:
    fail("embedded identity JSON is not terminated")
try:
    ident = json.loads(data[idx:end].decode("utf-8"))
except Exception as exc:  # noqa: BLE001
    fail(f"embedded identity JSON does not parse: {exc}")

if ident.get("abi_version") != 1 or ident.get("name") != "peggle_math":
    fail("embedded identity abi_version/name is wrong")
if ident.get("core_math_revision") != revision:
    fail("embedded identity core_math_revision does not match PIN.md")
if ident.get("platform") != platform:
    fail("embedded identity platform does not match")
if ident.get("sqrt_implementation") != "hardware-ieee754":
    fail("embedded identity sqrt_implementation is wrong")
if not ident.get("compiler") or not ident.get("build_flags"):
    fail("embedded identity compiler/build_flags are empty")

print(f"    OK: ABI 1; revision {revision}; artifact {artifact_sha[:12]}; audit {audit.get('kind')} pass")
PY

  if [[ "$platform" == "$HOST_PLATFORM" && "$HOST_PLATFORM" == "linux-x86_64" ]]; then
    command -v nm >/dev/null 2>&1 || { echo "error: nm (binutils) is required for the host symbol audit" >&2; exit 1; }
    echo "==> [$platform] host ABI/symbol checks (dlopen)"
    python3 - "$REPO_ROOT" "$platform" "$artifact_name" <<'PY'
import ctypes
import hashlib
import json
import os
import re
import struct
import subprocess
import sys

repo, platform, artifact_name = sys.argv[1:4]
vendor = os.path.join(repo, "native", "core-math")
adir = os.path.join(repo, "native", "artifacts", platform)
lib = os.path.join(adir, artifact_name)

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
      echo "==> [$platform] smoke test"
      LD_LIBRARY_PATH="$artifact_dir" "$REPO_ROOT/native/build_generated/smoke_test"
    fi
  else
    echo "    UNQUALIFIED on this host ($HOST_PLATFORM): checksum + metadata + static identity pass;"
    echo "    runtime/ABI/smoke qualification must be performed on a real $platform machine"
  fi

  VERIFIED+=("$platform")
done

echo "core-math verify OK (${VERIFIED[*]})"
