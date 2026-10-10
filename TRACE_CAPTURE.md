# Trace capture on another machine (CORE-MATH WP-E)

Capture CORE-MATH gameplay traces and candidate samples on any machine, bring
the capture directory back to the Linux PC, and compare it exactly. This path
needs only LÖVE 11.5 — no Julia, no Python, no compiler.

Every capture must come from the same repository state (same commits / same
working trees) and uses the pinned config overlay recorded in
`provenance.json`. Detailed reference:
`wiki/context/cross-platform-qualification.md` §5b.

## Prerequisites (all platforms)

- `julia_clone` and `peggle_evolved` at the same commits as the Linux PC.
- LÖVE 11.5 (`love` / `love.exe`), desktop session (no xvfb needed).
- Platform artifact present under `julia_clone`:
  - Linux:   `native/artifacts/linux-x86_64/libpeggle_math.so`
  - macOS:   `native/artifacts/darwin-aarch64/libpeggle_math.dylib`
  - Windows: `native/artifacts/windows-x86_64/peggle_math.dll`
- `sha256sum` (Linux/MSYS) or `shasum -a 256` (macOS).

## Linux (comparison host — baseline)

```bash
cd julia_clone
scripts/wpd_capture_host.sh --out tmp/core-math/xhost/linux-x86_64 --label linux-x86_64
```

## macOS ARM64

```bash
cd julia_clone
scripts/wpd_capture_host.sh --out ~/wpd-capture-mac --label mac-arm64
```

Add `--dev-tree ../peggle_evolved` or `--lib <path>` only if the defaults do
not fit. Expected warning: the dev-tree `src/config.lua` differs from the
pinned config; the pinned config is overlaid at runtime and the dev tree is
never modified.

## Windows x86-64

With Git Bash / MSYS, run the same command as macOS. Without bash, use
PowerShell from the `julia_clone` root (create the output directories first):

```powershell
$love = "C:\Program Files\LOVE\love.exe"     # or love.exe on PATH
$repo = "C:\path\to\julia_clone"
$dev  = "C:\path\to\peggle_evolved"
$out  = "C:\wpd-capture-win"
New-Item -ItemType Directory -Force "$out\expected", "$out\traces", "$out\candidates" | Out-Null

$env:PEGGLE_MATH_BACKEND = "core_math"
$env:PEGGLE_MATH_LIB = "$repo\native\artifacts\windows-x86_64\peggle_math.dll"

# Fixtures (expected records + per-step snapshots):
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
  --reference-dir "$dev" --run-id win-pc --host-label win-pc `
  --config-file "$repo/reference/peggle_evolved/src/config.lua"
```

The `--config-file` argument is only needed when the dev-tree config carries
the known `ball_ball_restitution` edit; drop it if the hashes already match.
When running under LuaJIT + bash on any platform, prefer the script above —
it also writes `provenance.json` and `capture.log`.

## Send back

Zip or tar the whole capture directory:

```bash
tar -czf wpd-capture-win.tar.gz -C /path/to/parent wpd-capture-win
```

## Compare on the Linux PC

```bash
cd julia_clone
scripts/wpd_compare_hosts.sh \
  --left-root tmp/core-math/xhost/linux-x86_64 \
  --right-root /path/to/wpd-capture-win \
  --out tmp/core-math/xhost/compare
```

Exit 0 means exact agreement (only per-platform `math_backend` identity
metadata may differ). Exit 3 means the provenance is incompatible (different
reference revision/tree/config or dev-tree commit); exit 1 means a real
difference and the report names the first divergent step. Manual PowerShell
captures have no `provenance.json`; add `--allow-missing-provenance` for them.
