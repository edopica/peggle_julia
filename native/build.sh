#!/usr/bin/env bash
#
# build.sh - reproducible build of the shared pinned native math component.
#
# Consumes the vendored CORE-MATH source pin under native/core-math/, builds
# native/peggle_math.c + native/sqrt_shim.c into
# native/artifacts/<platform>/libpeggle_math.so, audits undefined symbols, and
# writes build.json + libpeggle_math.so.sha256. See
# tmp/core-math/interface-spec.md for the frozen interface.
#
# Usage:
#   native/build.sh [--platform linux-x86_64] [--smoke] [--no-repro-check]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NATIVE_DIR="$REPO_ROOT/native"
VENDOR_DIR="$NATIVE_DIR/core-math"
PLATFORM="linux-x86_64"
RUN_SMOKE=0
REPRO_CHECK=1

usage() {
  cat <<'EOF'
Usage: native/build.sh [options]

Options:
  --platform <name>   target platform (default: linux-x86_64)
                      supported: linux-x86_64 only
  --smoke             compile and run native/smoke_test.c after building
  --no-repro-check    skip the second build used to test byte reproducibility
  -h, --help          show this help
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      [[ $# -ge 2 ]] || die "--platform requires an argument"
      PLATFORM="$2"
      shift 2
      ;;
    --smoke)
      RUN_SMOKE=1
      shift
      ;;
    --no-repro-check)
      REPRO_CHECK=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (try --help)"
      ;;
  esac
done

case "$PLATFORM" in
  linux-x86_64)
    [[ "$(uname -s)" == "Linux" ]] || die "platform $PLATFORM requires a Linux host"
    [[ "$(uname -m)" == "x86_64" ]] || die "platform $PLATFORM requires an x86_64 host"
    ;;
  *)
    die "platform '$PLATFORM' has no build rules yet; supported: linux-x86_64 (windows-x86_64 and darwin-aarch64 are documented open items)"
    ;;
esac

CC="${CC:-gcc}"
command -v "$CC" >/dev/null 2>&1 || die "compiler '$CC' not found in PATH"
if ! "$CC" --version 2>/dev/null | head -1 | grep -q 'GCC'; then
  die "only GCC is supported by the current build rules (found: $("$CC" --version 2>/dev/null | head -1))"
fi
command -v python3 >/dev/null 2>&1 || die "python3 is required to generate build metadata"

COMPILER_LINE="$("$CC" --version | head -1)"
TARGET_TRIPLE="$("$CC" -dumpmachine)"
ARTIFACT_REL="native/artifacts/$PLATFORM/libpeggle_math.so"
ARTIFACT_DIR="$REPO_ROOT/native/artifacts/$PLATFORM"
ARTIFACT="$ARTIFACT_DIR/libpeggle_math.so"
SHA_FILE="$ARTIFACT_DIR/libpeggle_math.so.sha256"
BUILD_JSON="$ARTIFACT_DIR/build.json"
IDENTITY_H="$NATIVE_DIR/build_generated/identity.h"
SMOKE_BIN="$NATIVE_DIR/build_generated/smoke_test"

echo "==> verifying vendored CORE-MATH pin against native/core-math/files.sha256"
[[ -f "$VENDOR_DIR/files.sha256" ]] || die "missing $VENDOR_DIR/files.sha256"
(cd "$VENDOR_DIR" && sha256sum --quiet -c files.sha256) \
  || die "vendored CORE-MATH files do not match files.sha256 (pin modified?)"
PIN_FILES=$(wc -l < "$VENDOR_DIR/files.sha256" | tr -d ' ')
echo "    pin OK ($PIN_FILES files)"

REVISION="$(sed -n 's/^| Revision | `\([0-9a-f]\{40\}\)`.*/\1/p' "$VENDOR_DIR/PIN.md" | head -1)"
[[ -n "$REVISION" ]] || die "could not parse CORE-MATH revision from native/core-math/PIN.md"
CORE_MATH_TAG=""
if grep -q '^| Tag | `' "$VENDOR_DIR/PIN.md"; then
  CORE_MATH_TAG="$(sed -n 's/^| Tag | `\([^`]*\)`.*/\1/p' "$VENDOR_DIR/PIN.md" | head -1)"
fi

# Upstream CORE-MATH (README.md and check.sh) requires: no fast-math, no
# finite-math-only, IEEE-754 semantics with round-to-nearest, subnormals
# enabled, -frounding-math for GCC, -fsignaling-nans, and GNU extensions
# (the routines use `asm`). -msse4.1 makes __builtin_roundeven expand to
# `roundsd` instead of a libm `roundeven` call (glibc >= 2.35 only); the CPU
# baseline is documented in build.json. -march=native is deliberately not
# used: the artifact is a platform artifact, not a build-host artifact.
CFLAGS=(
  -O2
  -std=gnu11
  -fPIC
  -fno-math-errno
  -fno-fast-math
  -ffp-contract=off
  -frounding-math
  -fsignaling-nans
  -fno-finite-math-only
  -msse4.1
  -fvisibility=hidden
  -Wall
  -Wshadow
)

SOURCES=(
  native/core-math/src/binary64/sin/sin.c
  native/core-math/src/binary64/cos/cos.c
  native/core-math/src/binary64/tan/tan.c
  native/core-math/src/binary64/asin/asin.c
  native/core-math/src/binary64/acos/acos.c
  native/core-math/src/binary64/atan/atan.c
  native/core-math/src/binary64/atan2/atan2.c
  native/core-math/src/binary64/exp/exp.c
  native/core-math/src/binary64/log/log.c
  native/core-math/src/binary64/pow/pow.c
  native/peggle_math.c
  native/sqrt_shim.c
)

BUILD_CMD=(
  "$CC"
  "${CFLAGS[@]}"
  -shared
  -Wl,--version-script=native/peggle_math.map
  -I native
  "${SOURCES[@]}"
  -lm
  -o "$ARTIFACT_REL"
)

mkdir -p "$ARTIFACT_DIR" "$NATIVE_DIR/build_generated"

echo "==> generating $IDENTITY_H"
export PEGGLE_REVISION="$REVISION"
export PEGGLE_TAG="$CORE_MATH_TAG"
export PEGGLE_PLATFORM="$PLATFORM"
export PEGGLE_COMPILER="$COMPILER_LINE"
export PEGGLE_FLAGS_STRING="${CFLAGS[*]}"
python3 - "$IDENTITY_H" <<'PY'
import json
import os
import sys

ident = {
    "abi_version": 1,
    "name": "peggle_math",
    "core_math_revision": os.environ["PEGGLE_REVISION"],
    "core_math_tag": os.environ["PEGGLE_TAG"],
    "platform": os.environ["PEGGLE_PLATFORM"],
    "compiler": os.environ["PEGGLE_COMPILER"],
    "build_flags": os.environ["PEGGLE_FLAGS_STRING"],
    "sqrt_implementation": "hardware-ieee754",
}
text = json.dumps(ident, separators=(",", ":"))
literal = json.dumps(text)  # JSON string escaping == C string escaping here
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write("#ifndef PEGGLE_MATH_IDENTITY_H\n")
    f.write("#define PEGGLE_MATH_IDENTITY_H\n")
    f.write("#define PEGGLE_MATH_IDENTITY_JSON " + literal + "\n")
    f.write("#endif /* PEGGLE_MATH_IDENTITY_H */\n")
PY

echo "==> compiling $ARTIFACT_REL"
(cd "$REPO_ROOT" && "${BUILD_CMD[@]}")

# ---------------------------------------------------------------------------
# Undefined-symbol audit.
# Forbidden: host transcendental/binary64 math symbols. Allowed: only the
# libc/libgcc runtime helpers listed below. `fma` is CORE-MATH-required and
# must be the correctly-rounded libm fma (no hardware FMA target here).
# ---------------------------------------------------------------------------
FORBIDDEN=(sin cos tan asin acos atan atan2 exp log pow sqrt)
ALLOWED_STRONG=(
  exit
  feclearexcept
  fegetexceptflag
  fegetround
  feholdexcept
  feraiseexcept
  fesetexceptflag
  fetestexcept
  feupdateenv
  fma
  fmax
  fmin
  printf
  puts
  round
  __stack_chk_fail
)
ALLOWED_WEAK=(
  __cxa_finalize
  __gmon_start__
  _ITM_deregisterTMCloneTable
  _ITM_registerTMCloneTable
)

RAW_UNDEF="$(nm -D --undefined-only "$ARTIFACT" | awk 'NF >= 2 {print $1" "$2}')"
UNDEF_STRONG=()
UNDEF_WEAK=()
while read -r typ name; do
  [[ -n "${typ:-}" && -n "${name:-}" ]] || continue
  base="${name%@*}"
  if [[ "$typ" == "w" || "$typ" == "v" ]]; then
    UNDEF_WEAK+=("$base")
  else
    UNDEF_STRONG+=("$base")
  fi
done <<< "$RAW_UNDEF"
if [[ ${#UNDEF_STRONG[@]} -gt 0 ]]; then
  mapfile -t UNDEF_STRONG < <(printf '%s\n' "${UNDEF_STRONG[@]}" | sort -u)
fi
if [[ ${#UNDEF_WEAK[@]} -gt 0 ]]; then
  mapfile -t UNDEF_WEAK < <(printf '%s\n' "${UNDEF_WEAK[@]}" | sort -u)
fi

FORBIDDEN_PRESENT=()
for f in "${FORBIDDEN[@]}"; do
  for s in ${UNDEF_STRONG[@]+"${UNDEF_STRONG[@]}"} ${UNDEF_WEAK[@]+"${UNDEF_WEAK[@]}"}; do
    [[ "$s" == "$f" ]] && FORBIDDEN_PRESENT+=("$f")
  done
done
UNEXPECTED=()
declare -A ALLOWED_STRONG_SET=()
for s in "${ALLOWED_STRONG[@]}"; do ALLOWED_STRONG_SET["$s"]=1; done
declare -A ALLOWED_WEAK_SET=()
for s in "${ALLOWED_WEAK[@]}"; do ALLOWED_WEAK_SET["$s"]=1; done
for s in ${UNDEF_STRONG[@]+"${UNDEF_STRONG[@]}"}; do
  [[ -n "${ALLOWED_STRONG_SET[$s]:-}" ]] || UNEXPECTED+=("$s")
done
for s in ${UNDEF_WEAK[@]+"${UNDEF_WEAK[@]}"}; do
  [[ -n "${ALLOWED_WEAK_SET[$s]:-}" ]] || UNEXPECTED+=("$s")
done

FMA_UNDEFINED=0
for s in ${UNDEF_STRONG[@]+"${UNDEF_STRONG[@]}"}; do
  [[ "$s" == "fma" ]] && FMA_UNDEFINED=1
done

if [[ ${#FORBIDDEN_PRESENT[@]} -gt 0 ]]; then
  die "forbidden host math symbols are undefined in $ARTIFACT_REL: ${FORBIDDEN_PRESENT[*]}"
fi
if [[ ${#UNEXPECTED[@]} -gt 0 ]]; then
  die "unexpected undefined symbols in $ARTIFACT_REL: ${UNEXPECTED[*]} (update the allowed list in native/build.sh only after review)"
fi
echo "    symbol audit OK: no forbidden symbols; strong undefined: ${UNDEF_STRONG[*]:-none}"

# ---------------------------------------------------------------------------
# Byte reproducibility check (second compile to a temporary path).
# ---------------------------------------------------------------------------
ARTIFACT_SHA="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
REPRO_RESULT="not_checked"
if [[ "$REPRO_CHECK" == "1" ]]; then
  TMP_REPRO="$(mktemp -d)"
  trap 'rm -rf "$TMP_REPRO"' EXIT
  REPRO_CMD=("${BUILD_CMD[@]}")
  REPRO_CMD[${#REPRO_CMD[@]}-1]="$TMP_REPRO/libpeggle_math.so"
  if (cd "$REPO_ROOT" && "${REPRO_CMD[@]}"); then
    REPRO_SHA="$(sha256sum "$TMP_REPRO/libpeggle_math.so" | awk '{print $1}')"
    if [[ "$REPRO_SHA" == "$ARTIFACT_SHA" ]]; then
      REPRO_RESULT="true"
    else
      REPRO_RESULT="false"
      echo "warning: a second build produced different bytes ($REPRO_SHA != $ARTIFACT_SHA)" >&2
    fi
  else
    REPRO_RESULT="error"
  fi
  rm -rf "$TMP_REPRO"
  trap - EXIT
fi

# ---------------------------------------------------------------------------
# Artifact checksum (sha256sum format, bare filename for `sha256sum -c`).
# ---------------------------------------------------------------------------
(cd "$ARTIFACT_DIR" && sha256sum libpeggle_math.so > libpeggle_math.so.sha256)
echo "==> artifact sha256: $ARTIFACT_SHA"

# ---------------------------------------------------------------------------
# Optional smoke test.
# ---------------------------------------------------------------------------
SMOKE_RAN=0
SMOKE_RESULT="not_run"
if [[ "$RUN_SMOKE" == "1" ]]; then
  echo "==> compiling and running native/smoke_test.c"
  (cd "$REPO_ROOT" && "$CC" -O2 -std=gnu11 -Wall -Wextra -I native \
    native/smoke_test.c -o "$SMOKE_BIN" -L "$ARTIFACT_DIR" -lpeggle_math \
    -Wl,-rpath,"$ARTIFACT_DIR")
  SMOKE_RAN=1
  if LD_LIBRARY_PATH="$ARTIFACT_DIR" "$SMOKE_BIN"; then
    SMOKE_RESULT="pass"
  else
    SMOKE_RESULT="fail"
    die "smoke test failed"
  fi
fi

# ---------------------------------------------------------------------------
# build.json
# ---------------------------------------------------------------------------
BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export PEGGLE_PLATFORM="$PLATFORM"
export PEGGLE_COMPILER="$COMPILER_LINE"
export PEGGLE_CC="$CC"
export PEGGLE_TARGET="$TARGET_TRIPLE"
export PEGGLE_REVISION="$REVISION"
export PEGGLE_TAG="$CORE_MATH_TAG"
export PEGGLE_ARTIFACT_REL="$ARTIFACT_REL"
export PEGGLE_ARTIFACT_SHA="$ARTIFACT_SHA"
export PEGGLE_ARTIFACT_SIZE="$(stat -c '%s' "$ARTIFACT")"
export PEGGLE_TIMESTAMP="$BUILD_TIMESTAMP"
export PEGGLE_REPRO_RESULT="$REPRO_RESULT"
export PEGGLE_FMA_UNDEFINED="$FMA_UNDEFINED"
export PEGGLE_SMOKE_RAN="$SMOKE_RAN"
export PEGGLE_SMOKE_RESULT="$SMOKE_RESULT"
PEGGLE_COMMAND="$(printf '%s\n' "${BUILD_CMD[@]}")"
export PEGGLE_COMMAND
PEGGLE_CFLAGS="$(printf '%s\n' "${CFLAGS[@]}")"
export PEGGLE_CFLAGS
PEGGLE_UNDEF_STRONG="$(printf '%s\n' ${UNDEF_STRONG[@]+"${UNDEF_STRONG[@]}"})"
export PEGGLE_UNDEF_STRONG
PEGGLE_UNDEF_WEAK="$(printf '%s\n' ${UNDEF_WEAK[@]+"${UNDEF_WEAK[@]}"})"
export PEGGLE_UNDEF_WEAK
PEGGLE_ALLOWED_STRONG="$(printf '%s\n' "${ALLOWED_STRONG[@]}")"
export PEGGLE_ALLOWED_STRONG
PEGGLE_ALLOWED_WEAK="$(printf '%s\n' "${ALLOWED_WEAK[@]}")"
export PEGGLE_ALLOWED_WEAK
PEGGLE_FORBIDDEN="$(printf '%s\n' "${FORBIDDEN[@]}")"
export PEGGLE_FORBIDDEN

python3 - "$BUILD_JSON" "$VENDOR_DIR/files.sha256" <<'PY'
import json
import os
import sys

def env_lines(name):
    return [line for line in os.environ.get(name, "").split("\n") if line != ""]

sources = {}
with open(sys.argv[2], encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        digest, path = line.split("  ", 1)
        sources["native/core-math/" + path[2:] if path.startswith("./") else path] = digest

doc = {
    "component": "peggle_math",
    "abi_version": 1,
    "platform": os.environ["PEGGLE_PLATFORM"],
    "compiler": os.environ["PEGGLE_COMPILER"],
    "compiler_cc": os.environ["PEGGLE_CC"],
    "target_triple": os.environ["PEGGLE_TARGET"],
    "core_math": {
        "url": "https://gitlab.inria.fr/core-math/core-math.git",
        "revision": os.environ["PEGGLE_REVISION"],
        "tag": os.environ["PEGGLE_TAG"],
        "pin_manifest": "native/core-math/files.sha256",
        "vendored_file_count": len(sources),
    },
    "source_files_sha256": dict(sorted(sources.items())),
    "artifact": {
        "path": os.environ["PEGGLE_ARTIFACT_REL"],
        "sha256": os.environ["PEGGLE_ARTIFACT_SHA"],
        "size_bytes": int(os.environ["PEGGLE_ARTIFACT_SIZE"]),
    },
    "build": {
        "cwd": ".",
        "command": env_lines("PEGGLE_COMMAND"),
        "flags": env_lines("PEGGLE_CFLAGS"),
        "sqrt_implementation": "hardware-ieee754",
        "sqrt_source": "peggle_math_sqrt: __builtin_sqrt with -fno-math-errno (no host sqrt call)",
        "sqrt_internal_shim": "native/sqrt_shim.c defines a hidden hardware sqrtsd `sqrt` for CORE-MATH cold paths only; the version script keeps it out of the ABI",
        "cpu_baseline": "-msse4.1 (makes __builtin_roundeven use roundsd; no libm roundeven dependency)",
        "fma_policy": "no hardware FMA target: CORE-MATH __builtin_fma binds to the correctly-rounded libm fma; no accidental FMA contraction (-ffp-contract=off)",
        "artifact_reproducible": os.environ["PEGGLE_REPRO_RESULT"],
    },
    "undefined_symbol_audit": {
        "tool": "nm -D --undefined-only",
        "result": "pass",
        "undefined_symbols_strong": env_lines("PEGGLE_UNDEF_STRONG"),
        "undefined_symbols_weak": env_lines("PEGGLE_UNDEF_WEAK"),
        "allowed_symbols": env_lines("PEGGLE_ALLOWED_STRONG"),
        "allowed_weak_symbols": env_lines("PEGGLE_ALLOWED_WEAK"),
        "forbidden_symbols": env_lines("PEGGLE_FORBIDDEN"),
        "forbidden_symbols_present": [],
        "fma_undefined": os.environ["PEGGLE_FMA_UNDEFINED"] == "1",
    },
    "smoke_test": {
        "ran": os.environ["PEGGLE_SMOKE_RAN"] == "1",
        "result": os.environ["PEGGLE_SMOKE_RESULT"],
    },
    "build_timestamp_utc": os.environ["PEGGLE_TIMESTAMP"],
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, sort_keys=False)
    f.write("\n")
PY

echo "==> wrote $(realpath --relative-to="$REPO_ROOT" "$BUILD_JSON")"
echo "==> done: $ARTIFACT"
