# ADR-0001: Math backend for the authoritative path

## Status

Accepted (2026-10-04).

## Context

- The pinned Lua reference runs under LuaJIT 2.1 + LÖVE 11.5, whose
  transcendentals come from the host C library (`libm.so.6`, glibc 2.44 on the
  reference host).
- Julia normally evaluates `sin`, `cos`, `atan2`, `pow`, ... through its
  bundled `libopenlibm`, which differs from glibc libm by one ULP on a small
  fraction of inputs. Those inputs occur in real level geometry, so matching
  Lua bit-for-bit requires a deliberate backend choice.
- M2 acceptance requires the strict cross-machine contract on the initial
  supported environment matrix, and the parity manifest must record enough
  identity to interpret a future mismatch.
- The exact `random_normal` port also depends on `sqrt`, `log`, `sin`, and
  `cos`, so the RNG fixture inherits the math contract.

## Decision

Keep two explicit backends behind the same `DetMath` interface, selected by
the module constant `MATH_BACKEND`:

- **Tier A (default, authoritative on Linux):** `:system_libm` calls
  `libm.so.6` with `ccall`, the same library LuaJIT uses. On the reference
  host this gives 0 mismatches over 15,794 recorded cases.
- **Tier B (portability fallback, not yet authoritative):** `:openlibm` calls
  Julia `Base`. `math_backend_identity()` records `backend`, `library`,
  `glibc`, and `julia` in the non-authoritative `environment` section of every
  parity manifest.

The authoritative path never uses `@fastmath`, `@simd`, `@turbo`, `muladd`,
or `fma`; a test scans the sources for all five. `lua_mod` is the floored
`a - floor(a/b)*b`, never C `fmod` or Julia `rem`.

Measured openlibm divergence from the captured system-libm truth
(`results/m2-math-census.json`, 15,794 cases, 705 total divergences, 4.46%):

| Function | Cases | Divergences | Rate |
| --- | --- | --- | --- |
| `asin` | 161 | 14 | 8.70% |
| `atan` | 1588 | 35 | 2.20% |
| `atan2` | 3164 | 461 | 14.57% |
| `cos` | 1588 | 53 | 3.34% |
| `exp` | 1558 | 7 | 0.45% |
| `log` | 1339 | 1 | 0.07% |
| `mod` | 1857 | 0 | 0.00% |
| `pow` | 1613 | 89 | 5.52% |
| `sin` | 1588 | 45 | 2.83% |
| `sqrt` | 1338 | 0 | 0.00% |

## Consequences

### Positive

- Bit-identical math, RNG, and initialized geometry against the Lua reference
  on Linux without re-implementing libm.
- The backend is explicit and auditable; the census, the source scan, and the
  manifest identity all make a silent change visible.
- Tier B already runs everywhere and keeps macOS/Windows development viable
  (non-authoritative until a platform-specific contract is decided).

### Negative / Trade-offs

- `:system_libm` makes the authoritative result host-dependent: it requires
  glibc-family libm and would legitimately differ on musl or macOS.
- Tier B differences (up to 14.6% of `atan2` cases) rule out cross-backend
  bit parity, so manifests must be compared only within the supported
  matrix; `results/parity/local.json` therefore labels its environment and
  compares only the `authoritative` section by default.
- The cross-machine follow-up is still open: a second physical host could not
  be reached in this session (DNS for `deathstar` failed). The compare tooling
  and two independently generated local manifests agree, but a genuine
  cross-machine pairing must be captured before the strict contract is
  claimed beyond one host.

## Amendment (2026-10-09): WP-C backend selection and naming

This amendment is part of the shared CORE-MATH integration
(`temp/core-math-pre-m3-plan.md` §6). It does not supersede the authoritative
system-libm decision; it changes how the backend is selected and named.

- Backend selection is now a runtime choice read from `PEGGLE_MATH_BACKEND` in
  `DetMath.__init__`, never a precompilation-time constant. The accepted values
  are `system_libm` (default on Linux), `core_math`, and `julia_base`;
  `openlibm` is accepted as a backward-compatible alias and is always reported
  as the canonical name `julia_base`. Unknown values are a hard load error,
  and a missing or incompatible `core_math` component never falls back.
- `:julia_base` means "Julia runtime Base math". It is **not** a claim about a
  pinned Openlibm implementation, and it is not evidence for cross-machine
  reproducibility: `math_backend_identity()` reports `Base.Math.libm` as the
  library name with no version commitment. Earlier text in this ADR that
  described Tier B as "bundled libopenlibm" should be read in this sense.
- `:core_math` is a new experimental backend. It loads the pinned native
  component (`native/artifacts/<platform>/libpeggle_math.so`, ABI 1, or
  `PEGGLE_MATH_LIB`) and routes all 11 interface functions through the
  `peggle_math_*` symbols. Its identity fields (`abi_version`,
  `artifact_sha256`, `core_math_revision`, `core_math_tag`, `platform`) are
  recorded in the parity `environment` section and in benchmark outputs.
- Adoption of `:core_math` as the authoritative backend is **pending**: WP-D
  correctness evidence and WP-F performance evidence must complete first.
  `:system_libm` remains the historical/authoritative backend on Linux until
  the adoption ADR replaces this decision.

## Amendment (2026-10-10): WP-D/WP-E/WP-F status

This amendment records experiment status; it still does not supersede the
authoritative system-libm decision.

- **WP-D is complete on one host.** `tmp/core-math/wpd-acceptance.md`
  reports 113,735 shared math cases + 57 contract specials with zero
  Lua-vs-Julia bit mismatches under both backends, zero oracle mismatches for
  `core_math` (independent MPFR interval oracle, no undecided cases), and
  126 recorded historical-glibc oracle deviations on the system axis. RNG
  sequences, peg colors and every purple-queue rebuild round, level
  geometry, and all nine ready-to-aim checkpoints agree across engines; the
  system-libm capture is byte-identical to the historical corpus.
- **Parity manifests are schema 2.** They recompute and hash RNG/color state
  instead of only hashing fixture files, record post-mutation and restored
  resets with `restored_matches_original`, pin Julia source and native
  component identity with explicit prerequisites, and the comparison tool
  rejects incompatible prerequisites and failed status before comparing.
- **WP-E/WP-F on-host evidence is clean**: the pinned reference, the dev
  tree system_libm control, and the dev tree core_math captures are
  simulation-identical across all 25 fixtures and 637 sampled candidates;
  per-call CORE-MATH costs in Lua are 1.3-2.8x for the trig/pow/log
  functions and ~0.8-1.0x for `atan2`/`sqrt`/`mod`, with the sampled
  candidate sweep ~21% slower. Performance evidence is directional, not
  precise (run variation 24-36%).
- **Adoption remains pending.** The required two-physical-host, two-OS
  exact comparison is still unavailable, no Windows/macOS artifact exists,
  and the M3 shot evaluator has not run. No performance threshold has been
  agreed. The `system_libm` backend therefore remains authoritative and the
  reference pin unchanged.
