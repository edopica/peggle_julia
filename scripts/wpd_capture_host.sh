#!/usr/bin/env bash
# WP-E cross-machine capture: CORE-MATH gameplay traces + candidate samples.
#
# Runs on the second host (Linux, macOS, or Windows Git Bash/MSYS) with
# LÖVE 11.5 and the platform native artifact. Writes one self-contained
# capture directory that travels home and is compared there with
# scripts/wpd_compare_hosts.sh (Linux, python3).
#
# Usage:
#   scripts/wpd_capture_host.sh --out DIR [--label LABEL] [--dev-tree PATH]
#                               [--lib PATH] [--backend core_math]
#                               [--stride 20] [--repeat 1] [--skip-candidates]
#
# Layout written under DIR:
#   expected/                        fixture expected records (25)
#   traces/                          gameplay traces (6, with snapshots)
#   candidates/raw.candidates.jsonl  candidate sweep (unless --skip-candidates)
#   candidates/summary.summary.json
#   provenance.json                  host/artifact/reference identity
#   capture.log                      this script's stdout
#
# Notes:
#   * No python dependency: hashes use sha256sum, or shasum -a 256 on macOS.
#   * The harness runs through scripts/love.sh, which execs directly on
#     macOS/MSYS and uses xvfb on headless Linux. On plain Windows cmd/
#     PowerShell run the direct commands printed at the start of capture.log.
#   * The pinned config is overlaid at runtime (--config-file) when the dev
#     tree src/config.lua differs from the pinned reference config; the dev
#     tree is never modified and the override is recorded in provenance.json.
#   * LÖVE and LuaJIT come from the dev tree the harness is given via
#     --reference-dir; the dev tree must carry the core_math backend
#     (src/detmath.lua and the gameplay_trace_exporter math_backend header).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/wpd_capture_host.sh --out DIR [options]

Options:
  --out DIR            capture directory (required; created if missing)
  --label LABEL        host label recorded in provenance and run metadata
                       (default: hostname)
  --dev-tree PATH      peggle_evolved development tree (default:
                       <repo>/../peggle_evolved)
  --lib PATH           native math artifact to load (default:
                       <repo>/native/artifacts/<platform>/<filename>)
  --backend NAME       math backend (default: core_math)
  --stride N           candidate sweep stride (default: 20)
  --repeat N           candidate sweep repeats (default: 1)
  --skip-candidates    capture fixtures only (no candidate sweep)
  -h, --help           show this help

Writes <out>/{expected,traces}, <out>/candidates (unless skipped),
<out>/provenance.json, and <out>/capture.log.
EOF
}

out_dir=""
label=""
dev_tree="$repo_root/../peggle_evolved"
lib=""
backend="core_math"
stride=20
repeat=1
skip_candidates=0

while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      [ $# -ge 2 ] || { echo "ERROR: --out requires a value" >&2; exit 2; }
      out_dir="$2"; shift 2 ;;
    --label)
      [ $# -ge 2 ] || { echo "ERROR: --label requires a value" >&2; exit 2; }
      label="$2"; shift 2 ;;
    --dev-tree)
      [ $# -ge 2 ] || { echo "ERROR: --dev-tree requires a value" >&2; exit 2; }
      dev_tree="$2"; shift 2 ;;
    --lib)
      [ $# -ge 2 ] || { echo "ERROR: --lib requires a value" >&2; exit 2; }
      lib="$2"; shift 2 ;;
    --backend)
      [ $# -ge 2 ] || { echo "ERROR: --backend requires a value" >&2; exit 2; }
      backend="$2"; shift 2 ;;
    --stride)
      [ $# -ge 2 ] || { echo "ERROR: --stride requires a value" >&2; exit 2; }
      stride="$2"; shift 2 ;;
    --repeat)
      [ $# -ge 2 ] || { echo "ERROR: --repeat requires a value" >&2; exit 2; }
      repeat="$2"; shift 2 ;;
    --skip-candidates) skip_candidates=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [ -z "$out_dir" ]; then
  echo "ERROR: --out DIR is required" >&2
  usage >&2
  exit 2
fi
for value in "$stride" "$repeat"; do
  case "$value" in
    ''|*[!0-9]*) echo "ERROR: stride/repeat must be non-negative integers" >&2; exit 2 ;;
  esac
done

sha256_file() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum > /dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "ERROR: sha256sum or shasum -a 256 is required" >&2
    return 1
  fi
}

sha256_stream() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum > /dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    echo "ERROR: sha256sum or shasum -a 256 is required" >&2
    return 1
  fi
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r//g'
}

absolute_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$PWD" "$1" ;;
  esac
}

count_files() {
  local dir="$1" pattern="$2"
  if [ -d "$dir" ]; then
    find "$dir" -type f -name "$pattern" 2>/dev/null | wc -l | tr -d ' '
  else
    printf '0'
  fi
}

to_windows_path() {
  if command -v cygpath > /dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

main() {
  cd "$repo_root"

  local uname_s uname_m os_name arch platform artifact_name
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"
  case "$uname_s" in
    Linux) os_name=linux ;;
    Darwin) os_name=darwin ;;
    MINGW*|MSYS*|CYGWIN*) os_name=windows ;;
    *)
      echo "ERROR: unsupported OS from uname -s: $uname_s (supported: Linux, Darwin, MINGW/MSYS/CYGWIN)" >&2
      return 1 ;;
  esac
  case "$uname_m" in
    x86_64|amd64) arch=x86_64 ;;
    arm64|aarch64|armv8l) arch=aarch64 ;;
    i686|i386|i586|x86) arch=x86 ;;
    *)
      echo "ERROR: unsupported machine from uname -m: $uname_m" >&2
      return 1 ;;
  esac
  platform="$os_name-$arch"
  case "$os_name" in
    windows) artifact_name="peggle_math.dll" ;;
    darwin) artifact_name="libpeggle_math.dylib" ;;
    *) artifact_name="libpeggle_math.so" ;;
  esac

  dev_tree="$(absolute_path "$dev_tree")"
  if [ -z "$lib" ]; then
    lib="$repo_root/native/artifacts/$platform/$artifact_name"
  else
    lib="$(absolute_path "$lib")"
  fi
  local uname_n
  uname_n="$(uname -n 2>/dev/null || hostname 2>/dev/null || printf '')"
  if [ -z "$label" ]; then
    label="$uname_n"
  fi
  if [ -z "$label" ]; then
    label="host"
  fi

  if [ ! -d "$dev_tree" ]; then
    echo "ERROR: dev tree not found: $dev_tree" >&2
    echo "  Pass --dev-tree PATH (the peggle_evolved working tree with the" >&2
    echo "  core_math backend files)." >&2
    return 1
  fi
  dev_tree="$(cd "$dev_tree" && pwd)"
  if [ ! -f "$dev_tree/src/config.lua" ]; then
    echo "ERROR: $dev_tree/src/config.lua is missing; not a peggle_evolved tree" >&2
    return 1
  fi
  if [ ! -f "$lib" ]; then
    echo "ERROR: native math artifact not found: $lib" >&2
    echo "  Build or copy the platform artifact under native/artifacts/$platform/," >&2
    echo "  or pass --lib PATH." >&2
    return 1
  fi
  lib="$(cd "$(dirname "$lib")" && pwd)/$(basename "$lib")"

  local lib_sha declared_sha manifest_sha=false
  lib_sha="$(sha256_file "$lib")"
  declared_sha=""
  if [ -f "$lib.sha256" ]; then
    declared_sha="$(awk '{print $1}' "$lib.sha256" | head -1)"
    manifest_sha=true
    if [ -n "$declared_sha" ] && [ "$declared_sha" != "$lib_sha" ]; then
      echo "ERROR: artifact sha256 does not match $lib.sha256" >&2
      echo "  actual:   $lib_sha" >&2
      echo "  declared: $declared_sha" >&2
      return 1
    fi
  fi

  local pin ref_dir revision tree config_sha
  pin="$repo_root/reference/PIN.md"
  ref_dir="$repo_root/reference/peggle_evolved"
  revision="$(sed -n 's/.*Revision (full) | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
  tree="$(sed -n 's/.*Tree hash | `\([0-9a-f]*\)`.*/\1/p' "$pin")"
  if [ -z "$revision" ] || [ -z "$tree" ]; then
    echo "ERROR: cannot read revision/tree from $pin" >&2
    return 1
  fi
  if [ ! -f "$ref_dir/src/config.lua" ]; then
    echo "ERROR: pinned reference config missing: $ref_dir/src/config.lua" >&2
    return 1
  fi
  config_sha="$(sha256_file "$ref_dir/src/config.lua")"

  local config_override=0 override_file="" dev_config_sha
  dev_config_sha="$(sha256_file "$dev_tree/src/config.lua")"
  local -a config_override_args=()
  if [ "$dev_config_sha" != "$config_sha" ]; then
    config_override=1
    override_file="$ref_dir/src/config.lua"
    local override_sha
    override_sha="$(sha256_file "$override_file")"
    if [ "$override_sha" != "$config_sha" ]; then
      echo "ERROR: config override $override_file sha256 $override_sha" >&2
      echo "  does not match the pinned config sha256 $config_sha" >&2
      return 1
    fi
    echo "WARNING: dev tree config.lua differs from the pinned reference config" >&2
    echo "  dev tree: $dev_config_sha" >&2
    echo "  pin:      $config_sha" >&2
    echo "  The pinned config is overlaid at runtime (--config-file); the dev" >&2
    echo "  tree file is not modified." >&2
    config_override_args=(--config-file "$override_file")
  fi

  mkdir -p "$out_dir/expected" "$out_dir/traces"
  if [ "$skip_candidates" -eq 0 ]; then
    mkdir -p "$out_dir/candidates"
  fi

  echo "wpd_capture_host: platform=$platform backend=$backend label=$label"
  echo "  repo_root=$repo_root"
  echo "  dev_tree=$dev_tree"
  echo "  lib=$lib sha256=$lib_sha"
  echo "  reference=$revision tree=$tree config_sha256=$config_sha"
  echo "  config_override=$config_override"

  local love_version love_available=false
  love_version=""
  if command -v love > /dev/null 2>&1; then
    love_available=true
    love_version="$(love --version 2>&1 | head -1 || true)"
  else
    echo "ERROR: 'love' was not found on PATH; install LÖVE 11.5 or add the" >&2
    echo "  launcher to PATH (macOS: /Applications/love.app/Contents/MacOS/love," >&2
    echo "  Windows: the directory containing love.exe)." >&2
    return 1
  fi

  local -a common_args
  common_args=(
    --reference-revision "$revision"
    --reference-tree "$tree"
    --config-sha256 "$config_sha"
    --reference-dir "$dev_tree"
  )
  local -a fixture_args
  fixture_args=(
    --fixtures
    --fixtures-snapshots
    --fixtures-out "$out_dir/expected"
    --fixtures-traces "$out_dir/traces"
  )
  local -a sweep_args
  sweep_args=(
    --sweep
    --stride "$stride"
    --repeat "$repeat"
    --out "$out_dir/candidates/raw"
    --summary-out "$out_dir/candidates/summary"
    --run-id "$label"
    --host-label "$label"
  )

  print_direct() {
    local description="$1"
    shift
    local harness_win lib_win
    harness_win="$(to_windows_path "$repo_root/harness")"
    lib_win="$(to_windows_path "$lib")"
    echo "# $description (bash / Git Bash / MSYS):"
    printf 'PEGGLE_MATH_BACKEND=%s PEGGLE_MATH_LIB=%q' "$backend" "$lib"
    printf ' love %q --' "$repo_root/harness"
    printf ' %q' "$@"
    printf '\n'
    echo "# $description (Windows PowerShell, love.exe on PATH):"
    printf '  $env:PEGGLE_MATH_BACKEND = "%s"\n' "$backend"
    printf '  $env:PEGGLE_MATH_LIB = "%s"\n' "$(json_escape "$lib_win")"
    printf '  love.exe "%s" --' "$(json_escape "$harness_win")"
    printf ' "%s"' "$@"
    printf '\n'
  }

  echo "#"
  echo "# Direct equivalent commands (reproducible without this script):"
  print_direct "fixture capture" \
    "${fixture_args[@]}" "${common_args[@]}" \
    ${config_override_args[@]+"${config_override_args[@]}"}
  if [ "$skip_candidates" -eq 0 ]; then
    print_direct "candidate sweep" \
      "${sweep_args[@]}" "${common_args[@]}" \
      ${config_override_args[@]+"${config_override_args[@]}"}
  fi
  echo "#"

  local start_seconds=$SECONDS

  echo "[1/2] fixture capture (expected records + snapshots)"
  env "PEGGLE_MATH_BACKEND=$backend" "PEGGLE_MATH_LIB=$lib" \
    "$repo_root/scripts/love.sh" love "$repo_root/harness" -- \
    "${fixture_args[@]}" "${common_args[@]}" \
    ${config_override_args[@]+"${config_override_args[@]}"}

  if [ "$skip_candidates" -eq 0 ]; then
    echo "[2/2] candidate sweep (stride $stride, repeat $repeat, all workloads)"
    env "PEGGLE_MATH_BACKEND=$backend" "PEGGLE_MATH_LIB=$lib" \
      "$repo_root/scripts/love.sh" love "$repo_root/harness" -- \
      "${sweep_args[@]}" "${common_args[@]}" \
      ${config_override_args[@]+"${config_override_args[@]}"}
  else
    echo "[2/2] candidate sweep skipped (--skip-candidates)"
  fi

  local expected_records trace_files candidates_captured=false
  expected_records="$(count_files "$out_dir/expected" '*.json')"
  trace_files="$(count_files "$out_dir/traces" '*.jsonl')"
  if [ "$skip_candidates" -eq 0 ] && [ -f "$out_dir/candidates/raw.candidates.jsonl" ] \
      && [ -f "$out_dir/candidates/summary.summary.json" ]; then
    candidates_captured=true
  fi

  local git_available=false git_head="" status_porcelain_sha=""
  if command -v git > /dev/null 2>&1 \
      && git -C "$dev_tree" rev-parse --git-dir > /dev/null 2>&1; then
    git_available=true
    git_head="$(git -C "$dev_tree" rev-parse HEAD 2>/dev/null || true)"
    status_porcelain_sha="$(
      git -C "$dev_tree" status --porcelain 2>/dev/null | sha256_stream || true
    )"
  fi

  local core_math_revision="" core_math_tag="" embedded_revision="" embedded_tag=""
  if [ -f "$repo_root/native/core-math/PIN.md" ]; then
    core_math_revision="$(sed -n 's/^| Revision | `\([0-9a-f]*\)`.*/\1/p' \
      "$repo_root/native/core-math/PIN.md" | head -1)"
    core_math_tag="$(sed -n 's/^| Tag | `\([^`]*\)`.*/\1/p' \
      "$repo_root/native/core-math/PIN.md" | head -1)"
  fi
  embedded_revision="$(
    LC_ALL=C grep -ao '"core_math_revision":"[0-9a-f]*"' "$lib" 2>/dev/null \
      | head -1 \
      | sed -e 's/.*"core_math_revision":"//' -e 's/"$//' \
      || true
  )"
  embedded_tag="$(
    LC_ALL=C grep -ao '"core_math_tag":"[^"]*"' "$lib" 2>/dev/null \
      | head -1 \
      | sed -e 's/.*"core_math_tag":"//' -e 's/"$//' \
      || true
  )"
  if [ -n "$embedded_revision" ]; then
    core_math_revision="$embedded_revision"
  fi
  if [ -n "$embedded_tag" ]; then
    core_math_tag="$embedded_tag"
  fi

  local capture_time
  capture_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  {
    printf '{\n'
    printf '  "format": "peggle.host_capture",\n'
    printf '  "schema_version": 1,\n'
    printf '  "label": "%s",\n' "$(json_escape "$label")"
    printf '  "capture_time_utc": "%s",\n' "$capture_time"
    printf '  "platform": "%s",\n' "$platform"
    printf '  "os": "%s",\n' "$os_name"
    printf '  "arch": "%s",\n' "$arch"
    printf '  "uname": {"system": "%s", "machine": "%s", "node": "%s"},\n' \
      "$(json_escape "$uname_s")" "$(json_escape "$uname_m")" "$(json_escape "$uname_n")"
    printf '  "backend": "%s",\n' "$(json_escape "$backend")"
    printf '  "lib": {"path": "%s", "filename": "%s", "sha256": "%s", "sha256_manifest": "%s", "verified": %s},\n' \
      "$(json_escape "$lib")" "$(json_escape "$artifact_name")" "$lib_sha" \
      "$(json_escape "$declared_sha")" "$manifest_sha"
    printf '  "core_math_revision": "%s",\n' "$(json_escape "$core_math_revision")"
    printf '  "core_math_tag": "%s",\n' "$(json_escape "$core_math_tag")"
    printf '  "love": {"available": %s, "version": "%s"},\n' \
      "$love_available" "$(json_escape "$love_version")"
    printf '  "reference": {"revision": "%s", "tree": "%s", "config_sha256": "%s"},\n' \
      "$revision" "$tree" "$config_sha"
    printf '  "config": {"override": %s, "dev_config_sha256": "%s", "pinned_config_sha256": "%s", "override_file": "%s"},\n' \
      "$([ "$config_override" -eq 1 ] && printf true || printf false)" \
      "$dev_config_sha" "$config_sha" "$(json_escape "$override_file")"
    printf '  "dev_tree": {"path": "%s", "git_available": %s, "git_head": "%s", "status_porcelain_sha256": "%s"},\n' \
      "$(json_escape "$dev_tree")" "$git_available" \
      "$(json_escape "$git_head")" "$(json_escape "$status_porcelain_sha")"
    printf '  "candidates": {"captured": %s, "stride": %s, "repeat": %s},\n' \
      "$candidates_captured" "$stride" "$repeat"
    printf '  "counts": {"expected_records": %s, "trace_files": %s}\n' \
      "$expected_records" "$trace_files"
    printf '}\n'
  } > "$out_dir/provenance.json"

  local elapsed=$((SECONDS - start_seconds))
  echo "wpd_capture_host: OK (${elapsed}s)"
  echo "  provenance.json        $out_dir/provenance.json"
  echo "  expected records       $expected_records"
  echo "  trace files            $trace_files"
  echo "  candidates captured    $candidates_captured"
  echo ""
  echo "Send this whole directory home:"
  echo "  $out_dir"
  local out_parent out_base
  out_parent="$(dirname "$out_dir")"
  out_base="$(basename "$out_dir")"
  echo "Bundle it with:"
  echo "  tar -czf \"$out_base.tar.gz\" -C \"$out_parent\" \"$out_base\""
  echo "Then compare on the Linux PC with:"
  echo "  scripts/wpd_compare_hosts.sh --left-root <linux-capture> --right-root <this-capture> --out <dir>"
}

mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
main "$@" 2>&1 | tee "$out_dir/capture.log"
status=${PIPESTATUS[0]}
exit "$status"
