# Cross-platform qualification runbook (macOS ARM64 and Windows x86-64)

Operational runbook for collecting the second-host and second-OS evidence for
the M2 CORE-MATH gate. The gate has two parts:

1. **native runtime qualification** — the pinned `peggle_math` artifact
   actually loads on the target OS and returns the exact expected IEEE-754
   results (`julia/PeggleSim/bin/native_qualify.jl`);
2. **cross-machine parity manifests** — the same M2 authoritative state
   (math census, RNG, peg colors, level geometry, reset determinism) is
   reproduced bit-for-bit on a different host and OS
   (`julia/PeggleSim/bin/parity_emit.jl` + `scripts/compare_parity.sh`).

`system_libm` remains the default and authoritative backend and CORE-MATH
adoption stays **undecided** (ADR-0001). This trip collects the missing
evidence; it does not change the backend. Historical fixtures under
`fixtures/`, `interchange/`, and `reference/` are never modified.

The Linux side is already captured:
`results/core-math/qualification/linux-x86_64.json` (core_math, experimental
census, 15,794 census / 514 RNG / 39 color checks and 9 reset configurations,
all verified). The trip adds `darwin-arm64.json` and `windows-x64.json`.

## 1. What travels

| Item | Notes |
| --- | --- |
| The repository, including `results/core-math/parity/math_census.v1.json` | 670,689 bytes, sha256 `075130e0ce57043e9582bc16272b6f633ae1584b7f900a13ee4223182d62b9f2`; tracked, so it travels with the repo. Provenance: `results/core-math/parity/README.md`. |
| `results/core-math/qualification/linux-x86_64.json` | Committed Linux baseline manifest for the cross-machine comparison. Regenerate it if any repository source changes after its capture (command in §4). |
| `native/artifacts/windows-x86_64/` (`peggle_math.dll`, `.sha256`, `build.json`) | Cross-built (zig cc), not yet runtime-qualified. dll sha256 `bad2c2274783cc4ce123618463b6486811c9f863a44c228d99ad33fee3c29ec6`. **Currently untracked: the user must `git add` and commit it before travel.** |
| `native/artifacts/darwin-aarch64/` (`libpeggle_math.dylib`, `.sha256`, `build.json`) | Cross-built (zig cc). dylib sha256 `3b877368fed9608e575ef48904ab016ce83f4a719f599cb2ac0a04d64fb0f8a5`. **Currently untracked: commit before travel.** |
| `native/build.sh`, `scripts/verify_core_math.sh`, `scripts/compare_parity.sh` | Build, static verification, manifest comparison. |
| `julia/PeggleSim/bin/parity_emit.jl`, `julia/PeggleSim/bin/native_qualify.jl` | Manifest emission and runtime smoke. |
| `scripts/love.sh` | Portable launcher (macOS/Windows desktop sessions skip the Linux xvfb logic). Only needed for the optional Tier 2 traces. |
| Historical fixtures (`fixtures/rng/*.v1.json`, `fixtures/math_census/`, `interchange/`) | Tracked; the manifest depends on them byte-for-byte. |

Both machines must use the census file above unchanged. The manifest records
its effective path and sha256 in `identity.prerequisites`
(`census_fixture_path`, `census_fixture_sha256`), and `compare_parity.sh`
refuses to compare incompatible prerequisites (exit 3).

**Line endings (Windows):** all identity hashes are computed over raw file
bytes, so the Windows checkout must use LF, not CRLF. The tracked
`.gitattributes` (`* text=auto eol=lf`) enforces LF in the working tree, so
a fresh clone needs no manual `core.autocrlf` change and the in-tree
attribute overrides a local `core.autocrlf=true` setting. Verify before
running anything:

```powershell
(Get-FileHash results\core-math\parity\math_census.v1.json -Algorithm SHA256).Hash.ToLower()
# must print 075130e0ce57043e9582bc16272b6f633ae1584b7f900a13ee4223182d62b9f2
```

Record both artifact sha256 values as loaded (a native rebuild changes them;
see the recording table in §6).

## 2. macOS ARM64

Prerequisites:

- Xcode Command Line Tools (`xcode-select --install`) for `clang` and the
  macOS SDK.
- Julia 1.12.6.
- ```bash
  brew install bash coreutils
  export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"
  bash --version | head -1   # must be 4.x/5.x (Homebrew), not /bin/bash 3.2
  python3 --version          # CLT or Homebrew; needed by verify_core_math.sh
  ```
  `native/build.sh` and `verify_core_math.sh` need bash 4+ and GNU coreutils
  (`sha256sum`, `stat`, `realpath`). If `bash --version` reports 3.2, put
  Homebrew bash first (`export PATH="$(brew --prefix)/bin:$PATH"`) or invoke
  `"$(brew --prefix)/bin/bash" native/build.sh ...`.

Build and qualify (from the repository root):

```bash
bash native/build.sh --platform darwin-aarch64 --smoke
scripts/verify_core_math.sh --platform darwin-aarch64
julia --project=julia/PeggleSim -e 'using Pkg; Pkg.instantiate()'
PEGGLE_MATH_BACKEND=core_math julia --project=julia/PeggleSim julia/PeggleSim/bin/native_qualify.jl
mkdir -p results/core-math/qualification
PEGGLE_MATH_BACKEND=core_math julia --project=julia/PeggleSim julia/PeggleSim/bin/parity_emit.jl \
    --census results/core-math/parity/math_census.v1.json \
    --label darwin-arm64 \
    --out results/core-math/qualification/darwin-arm64.json
```

Notes:

- `--platform darwin-aarch64` is deliberate: without it the script also
  inspects the native Linux artifact, which has no cross-artifact record, so
  the all-platform sweep is a Linux-host operation. On the Mac the checksum,
  build-metadata, and statically embedded identity checks run for the dylib;
  the script's full runtime ABI checks are Linux-only, so
  `native_qualify.jl` and the parity manifest are the runtime proof here.
- The native build replaces the cross-built `libpeggle_math.dylib` and its
  `.sha256`. That is expected; record the new sha256. To restore the
  committed cross artifact afterwards: `git checkout -- native/artifacts/darwin-aarch64`.
- `PEGGLE_MATH_BACKEND=core_math` is required for `parity_emit.jl`: the
  experimental census records CORE-MATH bits, and without the variable the
  process defaults to `julia_base` on macOS and the census check fails.
  `native_qualify.jl` defaults to `core_math` on its own.
- If clang or the SDK fails, the fallback is the committed cross-built dylib;
  native `build --smoke` is preferred for full qualification:
  ```bash
  PEGGLE_MATH_LIB="$PWD/native/artifacts/darwin-aarch64/libpeggle_math.dylib" \
    julia --project=julia/PeggleSim julia/PeggleSim/bin/native_qualify.jl
  PEGGLE_MATH_BACKEND=core_math \
  PEGGLE_MATH_LIB="$PWD/native/artifacts/darwin-aarch64/libpeggle_math.dylib" \
    julia --project=julia/PeggleSim julia/PeggleSim/bin/parity_emit.jl \
      --census results/core-math/parity/math_census.v1.json \
      --label darwin-arm64 \
      --out results/core-math/qualification/darwin-arm64.json
  ```
  With the cross-built dylib, skip `native/build.sh`;
  `scripts/verify_core_math.sh --platform darwin-aarch64` will not pass
  because the script requires a host-platform smoke result for the host
  artifact. The manifest still validates the loaded dylib against the
  committed `.sha256`.

## 3. Windows x86-64

Prerequisites:

- Julia 1.12.6, Git. Python 3 is optional: the Windows parity path does not
  need it (`compare_parity.sh` can run later on Linux/macOS).
- LF checkout (see §1).
- No bash is needed. The committed cross-built DLL is used through the
  default artifact lookup `native/artifacts/windows-x86_64/peggle_math.dll`.

Run in PowerShell from the repository root:

```powershell
$env:PEGGLE_MATH_BACKEND="core_math"
julia --project=julia\PeggleSim -e "using Pkg; Pkg.instantiate()"
julia --project=julia\PeggleSim julia\PeggleSim\bin\native_qualify.jl
New-Item -ItemType Directory -Force results\core-math\qualification | Out-Null
julia --project=julia\PeggleSim julia\PeggleSim\bin\parity_emit.jl `
    --census results\core-math\parity\math_census.v1.json `
    --label windows-x64 `
    --out results\core-math\qualification\windows-x64.json
```

`PEGGLE_MATH_BACKEND=core_math` must stay set for `parity_emit.jl` (see the
macOS note). `native_qualify.jl` defaults to `core_math` independently.

Optional/advanced: a native Windows build under MSYS2 or Git Bash with
mingw-w64 or Zig:

```bash
bash native/build.sh --platform windows-x86_64 --smoke
```

This requires GNU userland (bash 4+, coreutils, python3) and supplies an
independent local build. It overwrites the committed artifact, `.sha256`,
and `build.json`; that is expected. Record the new sha256. To restore the
committed cross artifact and metadata afterwards:

```bash
git checkout -- native/artifacts/windows-x86_64
```

**Windows paths (fixed):** `PeggleSim._recorded_fixture_path` normalizes all
recorded fixture paths to `/`, so the Windows manifest records
`identity.prerequisites.census_fixture_path` as
`results/core-math/parity/math_census.v1.json` exactly like Linux and macOS.
No manifest post-processing is needed; `compare_parity.sh` compares the
identity strings directly.

## 4. Collect and compare

The emit commands already write into `results/core-math/qualification/`.
Bring the macOS and Windows manifests back to one machine (or run the
comparison later on Linux):

Then:

```bash
scripts/compare_parity.sh results/core-math/qualification/darwin-arm64.json results/core-math/qualification/windows-x64.json
scripts/compare_parity.sh results/core-math/qualification/darwin-arm64.json results/core-math/qualification/linux-x86_64.json
scripts/compare_parity.sh results/core-math/qualification/windows-x64.json  results/core-math/qualification/linux-x86_64.json
```

All three must print `PARITY OK` and exit 0. Exit codes: 0 parity, 1
authoritative difference, 2 usage/missing file, 3 incompatible identity,
4 failed status, 5 invalid manifest.

Expected historical comparison (not an error):

```bash
scripts/compare_parity.sh results/core-math/qualification/linux-x86_64.json results/parity/local.json
# INCOMPATIBLE ... -> exit 3
```

`results/parity/local.json` is the historical `system_libm` manifest with the
historical census fixture and an older Julia source hash; exiting 3 there is
the documented outcome. Any other nonzero result is a real problem.

The Linux baseline was regenerated on 2026-10-10 after the fixture-path
separator fix in `PeggleSim._recorded_fixture_path`. The recorded source hash
(`identity.julia_source_sha256`) covers every `julia/PeggleSim/src/*.jl`, so
any further change to `julia/PeggleSim/src/**` invalidates stored manifests
on every host. If any repository source changed after the Linux baseline was
captured, regenerate it from the tracked census and re-run the comparisons:

```bash
PEGGLE_MATH_BACKEND=core_math julia --project=julia/PeggleSim julia/PeggleSim/bin/parity_emit.jl \
    --census results/core-math/parity/math_census.v1.json \
    --label linux-x86_64 \
    --out results/core-math/qualification/linux-x86_64.json
```

## 5. Optional Tier 2: full Lua traces

Only when LÖVE 11.5, a desktop session, and the sibling `../peggle_evolved`
dev tree are present. This is supplementary; it is not required for the
primary matrix claim.

```bash
make wpd-trace
```

Outputs are host-local under `tmp/` (gitignored): copy
`tmp/core-math/trace-compare.json` and `tmp/core-math/candidate-compare.json`
back. A `WARNING: dev tree config.lua differs from the pinned reference
config` is expected when the dev tree carries the known pre-existing
`ball_ball_restitution` edit: the pinned config is overlaid at runtime via
`--config-file` and the dev tree file is not modified. The trace script
invokes `scripts/love.sh` itself, which skips the Linux xvfb logic on macOS
and Windows.

## 5b. LÖVE-only trace capture (no Julia)

This path collects the WP-E cross-machine gameplay evidence on a PC that only
has LÖVE 11.5 and Lua. It produces one self-contained capture directory per
host, to be compared later on the Linux PC. It yields the WP-E
"`CORE-MATH runs agree exactly across the required matrix`" evidence; the
Julia parity manifests (`native_qualify.jl`/`parity_emit.jl`, §2–§4) still
need Julia. A per-user Julia install through
[juliaup](https://github.com/JuliaLang/juliaup) is optional if the friend
also wants to emit those.

### What the friend's PC needs

- Both repositories, at the **same commits and the same working-tree state**.
  The dev tree (`peggle_evolved`) must carry the core_math backend support
  (`src/detmath.lua`, the `math_backend` trace header in
  `src/systems/gameplay_trace_exporter.lua`); in this project those may be
  uncommitted, so copy the working tree (zip/rsync), do not rely on a bare
  clone. `provenance.json` records the dev-tree `git rev-parse HEAD` and a
  `git status --porcelain` hash; `wpd_compare_hosts.sh` refuses to compare
  captures whose dev-tree identity differs.
- LÖVE 11.5 with `love`/`love.exe` on `PATH` (or the full path to the app).
- A native runtime session (desktop); no `xvfb` is needed.
- The platform artifact: `native/artifacts/<platform>/<filename>`
  (`linux-x86_64/libpeggle_math.so`, `windows-x86_64/peggle_math.dll`,
  `darwin-aarch64/libpeggle_math.dylib`). The script defaults to that path
  and also verifies `<artifact>.sha256`; use `--lib PATH` otherwise.
- Bash (macOS/Git Bash/MSYS) to run the capture script, and `sha256sum` or
  `shasum -a 256`. No Python is required for the capture.

### Capture (macOS / Git Bash / MSYS)

From the julia_clone repository root:

```bash
scripts/wpd_capture_host.sh --out ~/wpd-capture-friend --label friend-pc
```

Useful options: `--dev-tree PATH`, `--lib PATH`, `--backend core_math`
(default), `--stride 20` / `--repeat 1` (candidate sweep), and
`--skip-candidates` (fixtures only). The script writes
`expected/`, `traces/`, `candidates/`, `provenance.json`, and `capture.log`
under `--out`. A `WARNING: dev tree config.lua differs from the pinned
reference config` is expected when the dev tree carries the known
`ball_ball_restitution` edit: the pinned config is overlaid at runtime via
`--config-file` and the dev tree is never modified. The start of
`capture.log` prints the exact direct `love` commands.

### Fallback: plain Windows PowerShell (no bash)

Run from the julia_clone root in PowerShell. Create the output directories
first; `love.exe` does not create them. Use forward slashes (LÖVE accepts
them). Pass `--config-file` only when the script prints the warning above;
the overlay path is `<repo>\reference\peggle_evolved\src\config.lua`.

```powershell
$love = "C:\Program Files\LOVE\love.exe"     # or love.exe on PATH
$repo = "C:\path\to\julia_clone"
$dev  = "C:\path\to\peggle_evolved"
$out  = "C:\wpd-capture-friend"
New-Item -ItemType Directory -Force "$out\expected", "$out\traces", "$out\candidates" | Out-Null

$env:PEGGLE_MATH_BACKEND = "core_math"
$env:PEGGLE_MATH_LIB = "$repo\native\artifacts\windows-x86_64\peggle_math.dll"

# Fixtures (expected records + snapshots):
& $love "$repo\harness" -- --fixtures --fixtures-snapshots `
  --fixtures-out "$out/expected" --fixtures-traces "$out/traces" `
  --reference-revision d17f6e7089b6e761f4367fc6a6dcd5b4da0309b9 `
  --reference-tree 3dc7ddfe19916e149d2531b20c73463c28a202c8 `
  --config-sha256 455757c900c604563865b5195eda2f31cfeba3d8666b6d782390e38c47e91d4d `
  --reference-dir "$dev" `
  --config-file "$repo/reference/peggle_evolved/src/config.lua"

# Candidate sweep:
& $love "$repo\harness" -- --sweep --stride 20 --repeat 1 `
  --out "$out/candidates/raw" --summary-out "$out/candidates/summary" `
  --reference-revision d17f6e7089b6e761f4367fc6a6dcd5b4da0309b9 `
  --reference-tree 3dc7ddfe19916e149d2531b20c73463c28a202c8 `
  --config-sha256 455757c900c604563865b5195eda2f31cfeba3d8666b6d782390e38c47e91d4d `
  --reference-dir "$dev" --run-id friend-pc --host-label friend-pc `
  --config-file "$repo/reference/peggle_evolved/src/config.lua"
```

Read the revision/tree/config values from `reference/PIN.md` and
`reference/peggle_evolved/src/config.lua`, or copy them from the printed
direct commands. The manual path writes no `provenance.json` and no
`capture.log`; on the Linux side add `--allow-missing-provenance` (identity
checks are then skipped, but the trace-header CORE-MATH revision check still
runs).

### Send home and compare

Zip/send the **whole capture directory** (`expected/`, `traces/`,
`candidates/`, `provenance.json`, `capture.log`). On the Linux PC, capture
the Linux side with the same script, then compare:

```bash
scripts/wpd_capture_host.sh --out tmp/core-math/xhost-linux --label linux-host
scripts/wpd_compare_hosts.sh \
    --left-root  tmp/core-math/xhost-linux \
    --right-root /path/to/friend-capture \
    --out        tmp/core-math/cross-machine
```

Compare like with like: both roots must be captures from
`scripts/wpd_capture_host.sh` (a root is a directory with `expected/` and
`traces/`), or pass `--allow-missing-provenance` for a manual capture. The
pre-existing `tmp/core-math/traces/core_math` directory also has that shape
(but no candidates and no provenance) and can be used with
`--allow-missing-provenance`.
`make wpd-compare-hosts ARGS="..."` wraps the same command. The script
writes `cross-machine-trace.json`, `cross-machine-candidates.json` (when both
sides have candidates), and `cross-machine-summary.json`. Exit 0 means every
comparison passed and the identity prerequisites matched; exit 1 means a
difference; exit 3 prints `INCOMPATIBLE` (reference revision/tree/config
sha256, backend name, CORE-MATH revision, or dev-tree git identity).

`cross-machine-summary.json` sets `complete: true` only when the two roots
come from two distinct physical hosts and at least two distinct `os` values,
and all comparisons pass. Two captures from the same Linux host (the dry
run) therefore pass the comparisons but stay `complete: false` with reasons;
the friend's Windows/macOS capture is what flips it. A successful Windows or
macOS capture compared against the Linux capture is the WP-E second-host,
second-OS evidence.

## 6. Results recording

Fill in one row per host. Keep the `native_qualify.jl` output (PASS counts)
with the manifests.

| Host / OS | Julia | Backend | Artifact sha256 | native_qualify | Manifest | Tier 2 |
| --- | --- | --- | --- | --- | --- | --- |
| Linux x86-64 (reference) | 1.12.6 | core_math | `d012f42e...` (`libpeggle_math.so`) | PASS 16/16 | `results/core-math/qualification/linux-x86_64.json` | optional |
| macOS ARM64 | 1.12.6 | core_math | native build sha or committed `3b877368...` | PASS __/16 | `results/core-math/qualification/darwin-arm64.json` | if LÖVE present |
| Windows x86-64 | 1.12.6 | core_math | committed `bad2c227...` or native build sha | PASS __/16 | `results/core-math/qualification/windows-x64.json` | if LÖVE present |

Bring back: both manifests, the
`native_qualify.jl` terminal output, the artifact sha256 values actually
loaded, and the comparison results. Commit the two new manifests under
`results/core-math/qualification/`.

What the evidence supports: CORE-MATH runtime qualification on the target OS
and bit-exact `authoritative` parity of the M2 state across Linux, macOS
ARM64, and Windows x86-64 for the tracked census. It does not itself decide
CORE-MATH adoption and does not replace the historical `system_libm`
fixtures.

## 7. Do not

- Do not edit `reference/`, the historical `fixtures/`, or `interchange/`.
- Do not modify `../peggle_evolved/src/config.lua` (use the runtime
  `--config-file` overlay; the trace script does this itself).
- Do not replace or regenerate `results/core-math/parity/math_census.v1.json`
  on the trip; both machines must use the exact tracked bytes (sha256 above).
- Do not treat a failed `native_qualify.jl` or a nonzero `compare_parity.sh`
  (other than the documented historical exit 3) as acceptable evidence.
