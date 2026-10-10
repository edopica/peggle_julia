#!/usr/bin/env bash
#
# build.sh - reproducible build of the shared pinned native math component.
#
# Consumes the vendored CORE-MATH source pin under native/core-math/, builds
# native/peggle_math.c + native/sqrt_shim.c into
# native/artifacts/<platform>/<artifact>, audits the exported/undefined symbol
# sets, checks that the hardware square-root instruction survived, and writes
# build.json + <artifact>.sha256. See tmp/core-math/interface-spec.md for the
# frozen interface.
#
# Shipping matrix: linux-x86_64 (host, gcc), windows-x86_64 (mingw or zig cc),
# darwin-aarch64 (clang + macOS SDK or zig cc). Cross artifacts are built and
# symbolized here but are NOT runtime-qualified: run --smoke on the target OS.
#
# Usage:
#   native/build.sh [--platform <name>] [--smoke] [--no-repro-check]
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
                      supported: linux-x86_64, windows-x86_64, darwin-aarch64
  --smoke             compile and run native/smoke_test.c after building
                      (host platform only; never used for cross artifacts)
  --no-repro-check    skip the second build used to test byte reproducibility
  -h, --help          show this help

Toolchain selection (CC always wins when set):
  linux-x86_64    gcc
  windows-x86_64  x86_64-w64-mingw32-gcc if present, else zig cc
                  (-target x86_64-windows-gnu)
  darwin-aarch64  clang with a usable macOS SDK, else zig cc
                  (-target aarch64-macos)

Zig is found via $ZIG (path to the zig binary or its directory), then PATH,
then the untracked scratch locations /tmp/opencode/zig/zig and
<repo>/tmp/zig/zig.
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

# ---------------------------------------------------------------------------
# Per-platform configuration.
#
# CORE-MATH requires: no fast-math, no finite-math-only, round-to-nearest,
# subnormals enabled, -frounding-math, -fsignaling-nans, GNU extensions. The
# Linux x86-64 flag set is frozen (its artifact hash is an acceptance
# invariant). The other platforms start from the same set minus -fPIC on
# Windows (meaningless for PE) and minus -msse4.1 on aarch64, where
# -mcpu=generic keeps the baseline at Armv8-A and avoids the Apple M1 default
# (whose "+aggressive-fma" feature would fuse multiply-adds despite
# -ffp-contract=off).
# ---------------------------------------------------------------------------
ARTIFACT_NAME=""
CFLAGS=()
LINK_FLAGS=()
AUDIT_KIND=""
REPRO_MODE="temp"
CPU_BASELINE=""
FMA_POLICY=""
SQRT_SHIM_DESC=""
SQRT_EXPECT=""
MACHO_EXTRA_EXPORTS=()
case "$PLATFORM" in
  linux-x86_64)
    [[ "$(uname -s)" == "Linux" ]] || die "platform $PLATFORM requires a Linux host"
    [[ "$(uname -m)" == "x86_64" ]] || die "platform $PLATFORM requires an x86_64 host"
    ARTIFACT_NAME="libpeggle_math.so"
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
    LINK_FLAGS=(-shared -Wl,--version-script=native/peggle_math.map)
    AUDIT_KIND=elf
    REPRO_MODE=temp
    SQRT_EXPECT="sqrtsd"
    CPU_BASELINE="-msse4.1 (makes __builtin_roundeven use roundsd; no libm roundeven dependency)"
    FMA_POLICY="no hardware FMA target: CORE-MATH __builtin_fma binds to the correctly-rounded libm fma; no accidental FMA contraction (-ffp-contract=off)"
    SQRT_SHIM_DESC="native/sqrt_shim.c defines a hidden hardware sqrtsd \`sqrt\` for CORE-MATH cold paths only; the version script keeps it out of the ABI"
    ;;
  windows-x86_64)
    ARTIFACT_NAME="peggle_math.dll"
    CFLAGS=(
      -O2
      -std=gnu11
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
    LINK_FLAGS=(-shared)
    AUDIT_KIND=coff
    # zig's COFF linker derives the PE header timestamp and PDB GUID from the
    # output path, so only a rebuild to the same path can be byte-compared.
    REPRO_MODE=same-path
    SQRT_EXPECT="sqrtsd"
    CPU_BASELINE="-msse4.1; x86-64 (SSE2) baseline, no FMA target (correctly-rounded fma is linked statically)"
    FMA_POLICY="no hardware FMA target: __builtin_fma is resolved statically (zig compiler-rt / mingw-w64, not a runtime DLL import); no accidental FMA contraction (-ffp-contract=off)"
    SQRT_SHIM_DESC="native/sqrt_shim.c defines a hidden hardware sqrtsd \`sqrt\` for CORE-MATH cold paths only; PE export table keeps it out of the ABI (dllexport controls exports)"
    ;;
  darwin-aarch64)
    ARTIFACT_NAME="libpeggle_math.dylib"
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
      -mcpu=generic
      -fvisibility=hidden
      -Wall
      -Wshadow
    )
    LINK_FLAGS=(-shared -Wl,-install_name,@rpath/libpeggle_math.dylib)
    AUDIT_KIND=macho
    REPRO_MODE=temp
    SQRT_EXPECT="fsqrt"
    MACHO_EXTRA_EXPORTS=(__mh_dylib_header ___dso_handle)
    CPU_BASELINE="-mcpu=generic: Armv8-A baseline (frintn/fsqrt/fmadd available); no -msse4.1; zig's Apple M1 default avoided because it enables aggressive FMA fusion"
    FMA_POLICY="CORE-MATH __builtin_fma lowers to the hardware fmadd instruction (single rounding); -ffp-contract=off prevents accidental contraction"
    SQRT_SHIM_DESC="native/sqrt_shim.c defines a hidden hardware fsqrt \`sqrt\` for CORE-MATH cold paths only; Mach-O visibility keeps it out of the ABI"
    ;;
  *)
    die "platform '$PLATFORM' is not supported; supported: linux-x86_64, windows-x86_64, darwin-aarch64"
    ;;
esac

find_zig() {
  local z="${ZIG:-}"
  if [[ -n "$z" ]]; then
    if [[ -d "$z" && -x "$z/zig" ]]; then
      printf '%s\n' "$z/zig"
      return 0
    fi
    if [[ -x "$z" ]]; then
      printf '%s\n' "$z"
      return 0
    fi
    die "ZIG='$z' is neither an executable nor a directory containing zig"
  fi
  if command -v zig >/dev/null 2>&1; then
    command -v zig
    return 0
  fi
  local candidate
  for candidate in /tmp/opencode/zig/zig "$REPO_ROOT/tmp/zig/zig"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  die "no zig toolchain found: set ZIG=/path/to/zig, add zig to PATH, or install a pinned Zig (see tmp/core-math/ scratch notes)"
}

# ---------------------------------------------------------------------------
# Compiler selection. CC (env) always wins; the target triple is verified
# afterwards so the host compiler can never silently build a cross artifact.
# ---------------------------------------------------------------------------
COMPILER_KIND=""
CC_CMD=()
ZIG_BIN=""
MACOS_SDK="${MACOS_SDK:-}"
if [[ -n "${CC:-}" ]]; then
  COMPILER_KIND="override"
  CC_CMD=("$CC")
else
  case "$PLATFORM" in
    linux-x86_64)
      COMPILER_KIND=gcc
      CC_CMD=(gcc)
      ;;
    windows-x86_64)
      if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
        COMPILER_KIND=mingw
        CC_CMD=(x86_64-w64-mingw32-gcc)
      else
        ZIG_BIN="$(find_zig)"
        COMPILER_KIND=zig
        CC_CMD=("$ZIG_BIN" cc -target x86_64-windows-gnu)
      fi
      ;;
    darwin-aarch64)
      if [[ -z "$MACOS_SDK" ]] && command -v xcrun >/dev/null 2>&1; then
        MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
      fi
      if [[ -n "$MACOS_SDK" && -e "$MACOS_SDK/usr/lib/libSystem.tbd" ]] && command -v clang >/dev/null 2>&1; then
        COMPILER_KIND=clang-sdk
        CC_CMD=(clang -target arm64-apple-macos13.0 -isysroot "$MACOS_SDK")
      else
        ZIG_BIN="$(find_zig)"
        COMPILER_KIND=zig
        CC_CMD=("$ZIG_BIN" cc -target aarch64-macos)
      fi
      ;;
  esac
fi

command -v "${CC_CMD[0]}" >/dev/null 2>&1 || die "compiler '${CC_CMD[0]}' not found in PATH"

case "$PLATFORM" in
  linux-x86_64)
    if [[ "$COMPILER_KIND" == "gcc" ]]; then
      if ! gcc --version 2>/dev/null | head -1 | grep -q 'GCC'; then
        die "the default linux-x86_64 toolchain must be GCC (found: $(gcc --version 2>/dev/null | head -1)); set CC=... to override"
      fi
    fi
    ;;
  windows-x86_64)
    if [[ "$COMPILER_KIND" == "override" && "${CC_CMD[0]}" == *mingw*gcc* ]]; then
      COMPILER_KIND=mingw
    fi
    ;;
esac

if [[ "$COMPILER_KIND" == "mingw" ]]; then
  LINK_FLAGS+=(-static-libgcc)
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required to generate build metadata"

TARGET_TRIPLE="$("${CC_CMD[@]}" -dumpmachine)"
[[ -n "$TARGET_TRIPLE" ]] || die "could not determine the compiler target triple"
case "$PLATFORM" in
  linux-x86_64)
    [[ "$TARGET_TRIPLE" == *linux* ]] || die "compiler target '$TARGET_TRIPLE' is not Linux (requested $PLATFORM)"
    ;;
  windows-x86_64)
    [[ "$TARGET_TRIPLE" == *windows* || "$TARGET_TRIPLE" == *mingw* ]] \
      || die "compiler target '$TARGET_TRIPLE' is not Windows (requested $PLATFORM); use x86_64-w64-mingw32-gcc or zig cc, or set CC=..."
    ;;
  darwin-aarch64)
    [[ "$TARGET_TRIPLE" == *darwin* || "$TARGET_TRIPLE" == *macos* || "$TARGET_TRIPLE" == *apple* ]] \
      || die "compiler target '$TARGET_TRIPLE' is not Darwin (requested $PLATFORM); use clang with a macOS SDK or zig cc, or set CC=..."
    ;;
esac

if [[ "$COMPILER_KIND" == "zig" ]]; then
  ZIG_VERSION="$("$ZIG_BIN" version)"
  CLANG_VERSION="$("${CC_CMD[@]}" --version 2>/dev/null | head -1)"
  COMPILER_LINE="zig cc $ZIG_VERSION ($CLANG_VERSION)"
else
  COMPILER_LINE="$("${CC_CMD[0]}" --version 2>/dev/null | head -1)"
fi

# CORE-MATH requires -fsignaling-nans. GCC honors it; clang (and therefore
# zig cc) accepts but ignores it with a warning. Probe the toolchain instead of
# assuming, so the limitation is recorded rather than silently dropped.
FLAGS_IGNORED=()
PROBE_FILE="$(mktemp)"
PROBE_OUT="$(mktemp)"
rm -f "$PROBE_OUT"
printf 'int peggle_math_flag_probe;\n' > "$PROBE_FILE"
PROBE_ERR=""
if ! PROBE_ERR="$("${CC_CMD[@]}" -fsignaling-nans -x c -c "$PROBE_FILE" -o "$PROBE_OUT" 2>&1)"; then
  rm -f "$PROBE_FILE" "$PROBE_OUT"
  die "compiler does not accept -fsignaling-nans: $PROBE_ERR"
fi
rm -f "$PROBE_FILE" "$PROBE_OUT"
if grep -qi 'not supported' <<<"$PROBE_ERR"; then
  FLAGS_IGNORED+=("-fsignaling-nans")
fi

ARTIFACT_REL="native/artifacts/$PLATFORM/$ARTIFACT_NAME"
ARTIFACT_DIR="$REPO_ROOT/native/artifacts/$PLATFORM"
ARTIFACT="$ARTIFACT_DIR/$ARTIFACT_NAME"
SHA_FILE="$ARTIFACT_DIR/$ARTIFACT_NAME.sha256"
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
  "${CC_CMD[@]}"
  "${CFLAGS[@]}"
  "${LINK_FLAGS[@]}"
  -I native
  "${SOURCES[@]}"
  -lm
  -o "$ARTIFACT_REL"
)

mkdir -p "$ARTIFACT_DIR" "$NATIVE_DIR/build_generated"

# Snapshot the artifact directory, then remove linker by-products after each
# link (zig's COFF linker writes <dll>.pdb and an import library, .exp/.ilk
# are possible from other PE linkers). The artifact directory must contain
# only <artifact>, <artifact>.sha256 and build.json.
declare -A ARTIFACT_DIR_BASELINE=()
if [[ -d "$ARTIFACT_DIR" ]]; then
  for f in "$ARTIFACT_DIR"/*; do
    [[ -e "$f" ]] || continue
    ARTIFACT_DIR_BASELINE["$(basename "$f")"]=1
  done
fi
clean_artifact_dir() {
  local f base
  for f in "$ARTIFACT_DIR"/*; do
    [[ -e "$f" ]] || continue
    [[ "$f" == "$ARTIFACT" ]] && continue
    base="$(basename "$f")"
    case "$base" in
      build.json|"$ARTIFACT_NAME".sha256) continue ;;
      *.pdb|*.lib|*.exp|*.ilk) rm -f "$f"; continue ;;
    esac
    if [[ -z "${ARTIFACT_DIR_BASELINE[$base]:-}" ]]; then
      rm -f "$f"
    fi
  done
}

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
clean_artifact_dir

# ---------------------------------------------------------------------------
# Exported/undefined symbol audit, per object format.
#
# Forbidden in all formats: host transcendental/binary64 math symbols. Linux
# additionally restrict undefined references to the libc/libgcc set below.
# Windows import tables and Mach-O undefined symbols get their own explicit
# per-platform allowlists, recorded verbatim in build.json; any unexpected
# entry is a hard error.
# ---------------------------------------------------------------------------
FORBIDDEN=(sin cos tan asin acos atan atan2 exp log pow sqrt)
ABI_EXPORTS=(
  peggle_math_abi_version
  peggle_math_identity
  peggle_math_sin
  peggle_math_cos
  peggle_math_tan
  peggle_math_asin
  peggle_math_acos
  peggle_math_atan
  peggle_math_atan2
  peggle_math_exp
  peggle_math_log
  peggle_math_pow
  peggle_math_sqrt
)
UNDEF_STRONG=()
UNDEF_WEAK=()
ALLOWED_STRONG=()
ALLOWED_WEAK=()
AUDIT_TOOL=""
COFF_EXPORTS=()
COFF_ALLOWED_EXPORTS=("${ABI_EXPORTS[@]}")
COFF_IMPORTS=()
COFF_ALLOWED_IMPORTS=()
MACHO_EXPORTS=()
MACHO_ALLOWED_EXPORTS=()
MACHO_UNDEF=()
MACHO_ALLOWED_UNDEF=()
FMA_UNDEFINED=0

case "$AUDIT_KIND" in
  elf)
    # Only the libc/libgcc runtime helpers listed below are allowed as
    # undefined symbols. `fma` is CORE-MATH-required and must be the
    # correctly-rounded libm fma (no hardware FMA target here).
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
    AUDIT_TOOL="nm -D --undefined-only + nm -D --defined-only"

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
    ;;
  coff)
    # The exact runtime import set observed for this toolchain. Windows PE
    # imports are named without a leading underscore on x86-64; the forbidden
    # check strips leading underscores before matching.
    COFF_ALLOWED_IMPORTS=(
      __acrt_iob_func
      __stdio_common_vfprintf
      _execute_onexit_table
      _exit
      _initialize_onexit_table
      _initterm
      _initterm_e
      _register_onexit_function
      abort
      calloc
      DeleteCriticalSection
      EnterCriticalSection
      exit
      free
      fwrite
      GetLastError
      InitializeCriticalSection
      LeaveCriticalSection
      puts
      Sleep
      strlen
      strncmp
      TlsGetValue
      VirtualProtect
      VirtualQuery
    )

    if command -v llvm-readobj >/dev/null 2>&1; then
      AUDIT_TOOL="llvm-readobj --coff-exports --coff-imports"
      RAW_COFF="$(llvm-readobj --coff-exports --coff-imports "$ARTIFACT")"
    elif command -v llvm-objdump >/dev/null 2>&1; then
      AUDIT_TOOL="llvm-objdump -p (COFF import/export tables)"
      RAW_COFF="$(llvm-objdump -p "$ARTIFACT")"
    elif command -v x86_64-w64-mingw32-objdump >/dev/null 2>&1; then
      AUDIT_TOOL="x86_64-w64-mingw32-objdump -p (COFF import/export tables)"
      RAW_COFF="$(x86_64-w64-mingw32-objdump -p "$ARTIFACT")"
    elif command -v objdump >/dev/null 2>&1 && objdump -p "$ARTIFACT" >/dev/null 2>&1; then
      AUDIT_TOOL="objdump -p (COFF import/export tables)"
      RAW_COFF="$(objdump -p "$ARTIFACT")"
    else
      die "no PE reader found for the $PLATFORM symbol audit; install LLVM (llvm-readobj/llvm-objdump) or binutils with PE support (objdump), or x86_64-w64-mingw32-objdump"
    fi
    ;;
  macho)
    # Mach-O symbol names carry one leading underscore. dyld_stub_binder is
    # the Mach-O lazy-binding runtime symbol; __mh_dylib_header/___dso_handle
    # are linker-generated image symbols and are not part of the math ABI.
    MACHO_ALLOWED_UNDEF=(
      _exit
      _feclearexcept
      _fegetexceptflag
      _fegetround
      _feholdexcept
      _feraiseexcept
      _fesetexceptflag
      _fetestexcept
      _feupdateenv
      _printf
      _puts
      dyld_stub_binder
    )
    MACHO_ALLOWED_EXPORTS=()
    for s in "${ABI_EXPORTS[@]}"; do MACHO_ALLOWED_EXPORTS+=("_$s"); done
    MACHO_ALLOWED_EXPORTS+=("${MACHO_EXTRA_EXPORTS[@]}")

    NM_TOOL=""
    if command -v llvm-nm >/dev/null 2>&1; then
      NM_TOOL="llvm-nm"
    elif command -v nm >/dev/null 2>&1 && nm --defined-only --extern-only "$ARTIFACT" >/dev/null 2>&1; then
      NM_TOOL="nm"
    else
      die "no Mach-O symbol reader found for the $PLATFORM symbol audit; install LLVM (llvm-nm) or run this audit on macOS"
    fi
    AUDIT_TOOL="$NM_TOOL --defined-only --extern-only + $NM_TOOL --undefined-only"

    # `nm` prints an address and type for defined symbols but a bare name for
    # undefined ones, so $NF is the symbol name in both cases.
    RAW_MACHO_DEF="$("$NM_TOOL" --defined-only --extern-only "$ARTIFACT" | awk 'NF >= 1 {print $NF}')"
    while read -r name; do
      [[ -n "$name" ]] || continue
      MACHO_EXPORTS+=("$name")
    done <<< "$RAW_MACHO_DEF"

    RAW_MACHO_UND="$("$NM_TOOL" --undefined-only "$ARTIFACT" | awk 'NF >= 1 {print $NF}')"
    while read -r name; do
      [[ -n "$name" ]] || continue
      MACHO_UNDEF+=("$name")
    done <<< "$RAW_MACHO_UND"

    if [[ ${#MACHO_EXPORTS[@]} -gt 0 ]]; then
      mapfile -t MACHO_EXPORTS < <(printf '%s\n' "${MACHO_EXPORTS[@]}" | sort -u)
    fi
    if [[ ${#MACHO_UNDEF[@]} -gt 0 ]]; then
      mapfile -t MACHO_UNDEF < <(printf '%s\n' "${MACHO_UNDEF[@]}" | sort -u)
    fi

    declare -A MACHO_ALLOWED_EXPORT_SET=()
    for s in "${MACHO_ALLOWED_EXPORTS[@]}"; do MACHO_ALLOWED_EXPORT_SET["$s"]=1; done
    declare -A MACHO_ALLOWED_UNDEF_SET=()
    for s in "${MACHO_ALLOWED_UNDEF[@]}"; do MACHO_ALLOWED_UNDEF_SET["$s"]=1; done

    MACHO_BAD_EXPORTS=()
    for s in "${MACHO_EXPORTS[@]}"; do
      [[ -n "${MACHO_ALLOWED_EXPORT_SET[$s]:-}" ]] || MACHO_BAD_EXPORTS+=("$s")
    done
    MACHO_BAD_UNDEF=()
    MACHO_FORBIDDEN=()
    for s in "${MACHO_UNDEF[@]}"; do
      [[ -n "${MACHO_ALLOWED_UNDEF_SET[$s]:-}" ]] || MACHO_BAD_UNDEF+=("$s")
      base="${s#_}"
      for f in "${FORBIDDEN[@]}"; do
        [[ "$base" == "$f" ]] && MACHO_FORBIDDEN+=("$s")
      done
    done

    if [[ ${#MACHO_FORBIDDEN[@]} -gt 0 ]]; then
      die "forbidden host math symbols are undefined in $ARTIFACT_REL: ${MACHO_FORBIDDEN[*]}"
    fi
    if [[ ${#MACHO_BAD_UNDEF[@]} -gt 0 ]]; then
      die "unexpected undefined symbols in $ARTIFACT_REL: ${MACHO_BAD_UNDEF[*]} (update the allowed list in native/build.sh only after review)"
    fi
    if [[ ${#MACHO_BAD_EXPORTS[@]} -gt 0 ]]; then
      die "unexpected exported symbols in $ARTIFACT_REL: ${MACHO_BAD_EXPORTS[*]} (update the allowed list in native/build.sh only after review)"
    fi
    # fma on aarch64 is a hardware instruction; record the resolution.
    FMA_UNDEFINED=0
    echo "    symbol audit OK: no forbidden symbols; exports: ${#MACHO_EXPORTS[@]}; undefined: ${MACHO_UNDEF[*]:-none}"
    ;;
esac

# ---------------------------------------------------------------------------
# Symbol audit for COFF, performed with a parser fed by $RAW_COFF. Defined as
# a function only for the windows branch; kept out of the elf/macho paths so
# the Linux byte-identity-critical flow is untouched.
# ---------------------------------------------------------------------------
coff_audit() {
  local raw="$1" line
  local parsed
  parsed="$(printf '%s\n' "$raw" | awk '
    /^Export \{/ { sec="E"; next }
    /^Import \{/ { sec="I"; dll=""; next }
    /^Export Table:/ { sec="E2"; next }
    /^The Import Tables:/ { sec="I2"; next }
    sec=="I" && /Name: / && !/Symbol: / { dll=$2; next }
    sec=="I" && /Symbol: / { print "I\t" dll "\t" $2; next }
    sec=="E" && /Name: / { print "E\t" $2; next }
    sec=="I2" && /DLL Name: / { dll=$3; next }
    sec=="I2" && /^ *[0-9]+ +/ { print "I\t" dll "\t" $2; next }
    sec=="E2" && /^ *[0-9]+ +0x/ { print "E\t" $3; next }
  ')"
  while IFS=$'\t' read -r kind a b; do
    [[ -n "${kind:-}" ]] || continue
    if [[ "$kind" == "E" ]]; then
      COFF_EXPORTS+=("$a")
    else
      COFF_IMPORTS+=("$a"$'\t'"$b")
    fi
  done <<< "$parsed"

  if [[ ${#COFF_EXPORTS[@]} -gt 0 ]]; then
    mapfile -t COFF_EXPORTS < <(printf '%s\n' "${COFF_EXPORTS[@]}" | sort -u)
  fi
  declare -A COFF_ALLOWED_IMPORT_SET=()
  for s in "${COFF_ALLOWED_IMPORTS[@]}"; do COFF_ALLOWED_IMPORT_SET["$s"]=1; done
  declare -A COFF_ALLOWED_EXPORT_SET=()
  for s in "${COFF_ALLOWED_EXPORTS[@]}"; do COFF_ALLOWED_EXPORT_SET["$s"]=1; done

  # Exports: exact ABI set.
  UNEXPECTED_EXPORTS=()
  for s in "${COFF_EXPORTS[@]}"; do
    [[ -n "${COFF_ALLOWED_EXPORT_SET[$s]:-}" ]] || UNEXPECTED_EXPORTS+=("$s")
  done
  for a in "${COFF_ALLOWED_EXPORTS[@]}"; do
    found=0
    for s in "${COFF_EXPORTS[@]}"; do [[ "$s" == "$a" ]] && found=1; done
    [[ "$found" == "1" ]] || UNEXPECTED_EXPORTS+=("missing:$a")
  done

  # Imports: exact runtime allowlist; forbidden names after stripping leading
  # underscores.
  UNEXPECTED_IMPORTS=()
  FORBIDDEN_IMPORTS=()
  for pair in "${COFF_IMPORTS[@]}"; do
    name="${pair#*$'\t'}"
    [[ -n "${COFF_ALLOWED_IMPORT_SET[$name]:-}" ]] || UNEXPECTED_IMPORTS+=("$name")
    base="${name#"${name%%[!_]*}"}"
    for f in "${FORBIDDEN[@]}"; do
      [[ "$base" == "$f" ]] && FORBIDDEN_IMPORTS+=("$name")
    done
  done

  if [[ ${#FORBIDDEN_IMPORTS[@]} -gt 0 ]]; then
    die "forbidden host math symbols are imported by $ARTIFACT_REL: ${FORBIDDEN_IMPORTS[*]}"
  fi
  if [[ ${#UNEXPECTED_IMPORTS[@]} -gt 0 ]]; then
    die "unexpected DLL imports in $ARTIFACT_REL: ${UNEXPECTED_IMPORTS[*]} (update the allowed list in native/build.sh only after review)"
  fi
  if [[ ${#UNEXPECTED_EXPORTS[@]} -gt 0 ]]; then
    die "unexpected export/ABI mismatch in $ARTIFACT_REL: ${UNEXPECTED_EXPORTS[*]} (update the allowed list in native/build.sh only after review)"
  fi
  local names=()
  for pair in ${COFF_IMPORTS[@]+"${COFF_IMPORTS[@]}"}; do names+=("${pair#*$'\t'}"); done
  echo "    symbol audit OK: exports: ${#COFF_EXPORTS[@]}; DLL imports: ${names[*]:-none}"
}
if [[ "$AUDIT_KIND" == "coff" ]]; then
  coff_audit "$RAW_COFF"
fi

# ---------------------------------------------------------------------------
# Hardware square-root instruction check (sqrt_shim.c must stay hardware-only).
# ---------------------------------------------------------------------------
DISASM_TOOL=""
if command -v llvm-objdump >/dev/null 2>&1; then
  DISASM_TOOL="llvm-objdump"
elif command -v objdump >/dev/null 2>&1 && objdump -d "$ARTIFACT" >/dev/null 2>&1; then
  DISASM_TOOL="objdump"
else
  die "no disassembler available to verify the hardware $SQRT_EXPECT instruction; install LLVM (llvm-objdump) or binutils (objdump)"
fi
DISASM_OUT="$("$DISASM_TOOL" -d "$ARTIFACT" 2>/dev/null || true)"
if ! grep -qw "$SQRT_EXPECT" <<<"$DISASM_OUT"; then
  die "expected hardware '$SQRT_EXPECT' instruction not found in $ARTIFACT_REL (sqrt_shim regression?)"
fi
echo "    sqrt instruction OK: $SQRT_EXPECT ($DISASM_TOOL)"
AUDIT_TOOL="$AUDIT_TOOL; $DISASM_TOOL -d ($SQRT_EXPECT present)"

# ---------------------------------------------------------------------------
# Byte reproducibility check.
#   temp       - second compile to a temporary path (path-independent bytes).
#   same-path  - second compile to the same output path (zig's COFF linker
#                derives the PE timestamp/PDB GUID from the output path, so a
#                different path is expected to differ).
# ---------------------------------------------------------------------------
ARTIFACT_SHA="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
REPRO_RESULT="not_checked"
REPRO_SCOPE=""
if [[ "$REPRO_CHECK" == "1" ]]; then
  TMP_REPRO="$(mktemp -d)"
  trap 'rm -rf "$TMP_REPRO"' EXIT
  if [[ "$REPRO_MODE" == "same-path" ]]; then
    REPRO_SCOPE="second build to the same output path (this linker derives PE timestamp/PDB GUID from the output path; different paths are expected to differ)"
    cp "$ARTIFACT" "$TMP_REPRO/first_artifact"
    if (cd "$REPO_ROOT" && "${BUILD_CMD[@]}"); then
      REPRO_SHA="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
      if [[ "$REPRO_SHA" == "$ARTIFACT_SHA" ]]; then
        REPRO_RESULT="true"
      else
        REPRO_RESULT="false"
        echo "warning: a second build produced different bytes ($REPRO_SHA != $ARTIFACT_SHA)" >&2
      fi
    else
      REPRO_RESULT="error"
    fi
    # Restore the audited first-build bytes.
    cp "$TMP_REPRO/first_artifact" "$ARTIFACT"
  else
    REPRO_SCOPE="second build to a temporary path (compiled bytes are path independent)"
    REPRO_CMD=("${BUILD_CMD[@]}")
    REPRO_CMD[${#REPRO_CMD[@]}-1]="$TMP_REPRO/$ARTIFACT_NAME"
    if (cd "$REPO_ROOT" && "${REPRO_CMD[@]}"); then
      REPRO_SHA="$(sha256sum "$TMP_REPRO/$ARTIFACT_NAME" | awk '{print $1}')"
      if [[ "$REPRO_SHA" == "$ARTIFACT_SHA" ]]; then
        REPRO_RESULT="true"
      else
        REPRO_RESULT="false"
        echo "warning: a second build produced different bytes ($REPRO_SHA != $ARTIFACT_SHA)" >&2
      fi
    else
      REPRO_RESULT="error"
    fi
  fi
  rm -rf "$TMP_REPRO"
  trap - EXIT
fi
clean_artifact_dir
ARTIFACT_SHA="$(sha256sum "$ARTIFACT" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Artifact checksum (sha256sum format, bare filename for `sha256sum -c`).
# ---------------------------------------------------------------------------
(cd "$ARTIFACT_DIR" && sha256sum "$ARTIFACT_NAME" > "$ARTIFACT_NAME.sha256")
echo "==> artifact sha256: $ARTIFACT_SHA"

# ---------------------------------------------------------------------------
# Optional smoke test (host platform only).
# ---------------------------------------------------------------------------
SMOKE_RAN=0
SMOKE_RESULT="not_run"
SMOKE_NOTE=""
QUALIFICATION_JSON=""
if [[ "$PLATFORM" != "$HOST_PLATFORM" ]]; then
  SMOKE_RESULT="not_run_cross_artifact"
  SMOKE_NOTE="cross artifact built with $COMPILER_LINE; runtime qualification (native/smoke_test.c) must be run on an actual $PLATFORM machine"
  if [[ "$RUN_SMOKE" == "1" ]]; then
    die "--smoke is only valid for the host platform ($HOST_PLATFORM); cross artifacts must be qualified on the target OS"
  fi
  QUALIFICATION_JSON="$(python3 - "$PLATFORM" "$COMPILER_LINE" <<'PY'
import json
import sys
platform, compiler = sys.argv[1], sys.argv[2]
print(json.dumps({
    "cross_built": True,
    "qualified_on_target": False,
    "note": f"cross-compiled for {platform} with {compiler}; no runtime/smoke test has been executed on the target OS",
}, separators=(",", ":")))
PY
)"
elif [[ "$RUN_SMOKE" == "1" ]]; then
  echo "==> compiling and running native/smoke_test.c"
  (cd "$REPO_ROOT" && "${CC_CMD[@]}" -O2 -std=gnu11 -Wall -Wextra -I native \
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
export PEGGLE_CC="${CC_CMD[*]}"
export PEGGLE_TARGET="$TARGET_TRIPLE"
export PEGGLE_REVISION="$REVISION"
export PEGGLE_TAG="$CORE_MATH_TAG"
export PEGGLE_ARTIFACT_REL="$ARTIFACT_REL"
export PEGGLE_ARTIFACT_NAME="$ARTIFACT_NAME"
export PEGGLE_ARTIFACT_SHA="$ARTIFACT_SHA"
export PEGGLE_ARTIFACT_SIZE="$(stat -c '%s' "$ARTIFACT")"
export PEGGLE_TIMESTAMP="$BUILD_TIMESTAMP"
export PEGGLE_REPRO_RESULT="$REPRO_RESULT"
export PEGGLE_REPRO_SCOPE="$REPRO_SCOPE"
export PEGGLE_FMA_UNDEFINED="$FMA_UNDEFINED"
export PEGGLE_FMA_POLICY="$FMA_POLICY"
export PEGGLE_CPU_BASELINE="$CPU_BASELINE"
export PEGGLE_SQRT_SHIM="$SQRT_SHIM_DESC"
export PEGGLE_SMOKE_RAN="$SMOKE_RAN"
export PEGGLE_SMOKE_RESULT="$SMOKE_RESULT"
export PEGGLE_SMOKE_NOTE="$SMOKE_NOTE"
export PEGGLE_QUALIFICATION_JSON="$QUALIFICATION_JSON"
export PEGGLE_AUDIT_KIND="$AUDIT_KIND"
export PEGGLE_AUDIT_TOOL="$AUDIT_TOOL"
PEGGLE_COMMAND="$(printf '%s\n' "${BUILD_CMD[@]}")"
export PEGGLE_COMMAND
PEGGLE_CFLAGS="$(printf '%s\n' "${CFLAGS[@]}")"
export PEGGLE_CFLAGS
PEGGLE_LINK_FLAGS="$(printf '%s\n' "${LINK_FLAGS[@]}")"
export PEGGLE_LINK_FLAGS
PEGGLE_UNDEF_STRONG="$(printf '%s\n' ${UNDEF_STRONG[@]+"${UNDEF_STRONG[@]}"})"
export PEGGLE_UNDEF_STRONG
PEGGLE_UNDEF_WEAK="$(printf '%s\n' ${UNDEF_WEAK[@]+"${UNDEF_WEAK[@]}"})"
export PEGGLE_UNDEF_WEAK
PEGGLE_ALLOWED_STRONG="$(printf '%s\n' ${ALLOWED_STRONG[@]+"${ALLOWED_STRONG[@]}"})"
export PEGGLE_ALLOWED_STRONG
PEGGLE_ALLOWED_WEAK="$(printf '%s\n' ${ALLOWED_WEAK[@]+"${ALLOWED_WEAK[@]}"})"
export PEGGLE_ALLOWED_WEAK
PEGGLE_FORBIDDEN="$(printf '%s\n' "${FORBIDDEN[@]}")"
export PEGGLE_FORBIDDEN
PEGGLE_FLAGS_IGNORED="$(printf '%s\n' ${FLAGS_IGNORED[@]+"${FLAGS_IGNORED[@]}"})"
export PEGGLE_FLAGS_IGNORED
PEGGLE_COFF_EXPORTS="$(printf '%s\n' ${COFF_EXPORTS[@]+"${COFF_EXPORTS[@]}"})"
export PEGGLE_COFF_EXPORTS
PEGGLE_COFF_ALLOWED_EXPORTS="$(printf '%s\n' "${COFF_ALLOWED_EXPORTS[@]}")"
export PEGGLE_COFF_ALLOWED_EXPORTS
PEGGLE_COFF_IMPORTS="$(printf '%s\n' ${COFF_IMPORTS[@]+"${COFF_IMPORTS[@]}"})"
export PEGGLE_COFF_IMPORTS
PEGGLE_COFF_ALLOWED_IMPORTS="$(printf '%s\n' "${COFF_ALLOWED_IMPORTS[@]}")"
export PEGGLE_COFF_ALLOWED_IMPORTS
PEGGLE_MACHO_EXPORTS="$(printf '%s\n' ${MACHO_EXPORTS[@]+"${MACHO_EXPORTS[@]}"})"
export PEGGLE_MACHO_EXPORTS
PEGGLE_MACHO_ALLOWED_EXPORTS="$(printf '%s\n' "${MACHO_ALLOWED_EXPORTS[@]}")"
export PEGGLE_MACHO_ALLOWED_EXPORTS
PEGGLE_MACHO_UNDEF="$(printf '%s\n' ${MACHO_UNDEF[@]+"${MACHO_UNDEF[@]}"})"
export PEGGLE_MACHO_UNDEF
PEGGLE_MACHO_ALLOWED_UNDEF="$(printf '%s\n' "${MACHO_ALLOWED_UNDEF[@]}")"
export PEGGLE_MACHO_ALLOWED_UNDEF

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

kind = os.environ["PEGGLE_AUDIT_KIND"]
audit = {
    "kind": kind,
    "tool": os.environ["PEGGLE_AUDIT_TOOL"],
    "result": "pass",
    "forbidden_symbols": env_lines("PEGGLE_FORBIDDEN"),
    "forbidden_symbols_present": [],
}
if kind == "elf":
    audit.update({
        "undefined_symbols_strong": env_lines("PEGGLE_UNDEF_STRONG"),
        "undefined_symbols_weak": env_lines("PEGGLE_UNDEF_WEAK"),
        "allowed_symbols": env_lines("PEGGLE_ALLOWED_STRONG"),
        "allowed_weak_symbols": env_lines("PEGGLE_ALLOWED_WEAK"),
        "fma_undefined": os.environ["PEGGLE_FMA_UNDEFINED"] == "1",
    })
elif kind == "coff":
    dlls = {}
    for pair in env_lines("PEGGLE_COFF_IMPORTS"):
        dll, name = pair.split("\t", 1)
        dlls.setdefault(dll, []).append(name)
    audit.update({
        "exports": env_lines("PEGGLE_COFF_EXPORTS"),
        "allowed_exports": env_lines("PEGGLE_COFF_ALLOWED_EXPORTS"),
        "imports_by_dll": {k: sorted(v) for k, v in sorted(dlls.items())},
        "imported_symbols": sorted(n for names in dlls.values() for n in names),
        "allowed_imports": env_lines("PEGGLE_COFF_ALLOWED_IMPORTS"),
        "fma_undefined": False,
        "fma_resolution": "statically linked compiler-rt/mingw-w64 (correctly rounded), not a runtime DLL import",
    })
elif kind == "macho":
    audit.update({
        "exports": env_lines("PEGGLE_MACHO_EXPORTS"),
        "allowed_exports": env_lines("PEGGLE_MACHO_ALLOWED_EXPORTS"),
        "undefined_symbols_strong": env_lines("PEGGLE_MACHO_UNDEF"),
        "undefined_symbols_weak": [],
        "allowed_symbols": env_lines("PEGGLE_MACHO_ALLOWED_UNDEF"),
        "allowed_weak_symbols": [],
        "fma_undefined": False,
        "fma_resolution": "hardware fmadd instruction (single rounding), no libcall",
    })

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
        "filename": os.environ["PEGGLE_ARTIFACT_NAME"],
        "sha256": os.environ["PEGGLE_ARTIFACT_SHA"],
        "size_bytes": int(os.environ["PEGGLE_ARTIFACT_SIZE"]),
    },
    "build": {
        "cwd": ".",
        "command": env_lines("PEGGLE_COMMAND"),
        "flags": env_lines("PEGGLE_CFLAGS"),
        "link_flags": env_lines("PEGGLE_LINK_FLAGS"),
        "flags_ignored_by_toolchain": env_lines("PEGGLE_FLAGS_IGNORED"),
        "sqrt_implementation": "hardware-ieee754",
        "sqrt_source": "peggle_math_sqrt: __builtin_sqrt with -fno-math-errno (no host sqrt call)",
        "sqrt_internal_shim": os.environ["PEGGLE_SQRT_SHIM"],
        "cpu_baseline": os.environ["PEGGLE_CPU_BASELINE"],
        "fma_policy": os.environ["PEGGLE_FMA_POLICY"],
        "artifact_reproducible": os.environ["PEGGLE_REPRO_RESULT"],
        "reproducibility_scope": os.environ["PEGGLE_REPRO_SCOPE"],
    },
    "undefined_symbol_audit": audit,
    "smoke_test": {
        "ran": os.environ["PEGGLE_SMOKE_RAN"] == "1",
        "result": os.environ["PEGGLE_SMOKE_RESULT"],
    },
    "build_timestamp_utc": os.environ["PEGGLE_TIMESTAMP"],
}
note = os.environ.get("PEGGLE_SMOKE_NOTE", "")
if note:
    doc["smoke_test"]["note"] = note
qual = os.environ.get("PEGGLE_QUALIFICATION_JSON", "")
if qual:
    doc["qualification"] = json.loads(qual)
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, sort_keys=False)
    f.write("\n")
PY

echo "==> wrote $(realpath --relative-to="$REPO_ROOT" "$BUILD_JSON")"
echo "==> done: $ARTIFACT"
