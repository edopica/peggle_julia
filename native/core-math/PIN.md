# CORE-MATH vendored pin (Work Package B)

## Identity

| Field | Value |
| --- | --- |
| Upstream URL | https://gitlab.inria.fr/core-math/core-math.git |
| Revision | `040ee482a8caefe2afe71a3a59d43923d2f0c7e6` (full 40-hex commit) |
| Tag | none (upstream has no tags) |
| Commit date | 2026-10-09 11:05:19 +0200 |
| Commit subject | `two fixes for BF16 with clang` |
| Retrieval date | 2026-10-09 |
| License | MIT (see `LICENSE`) |
| Vendored files | 16 upstream files: 15 `.c`/`.h` sources plus `LICENSE` |
| Manifest | `files.sha256`, 17 entries (16 upstream files + this `PIN.md`) |

## Revision selection rationale

Upstream publishes no release tags: `git tag -l` in a fresh clone and
`git ls-remote --tags` against the upstream URL both return an empty list as of
the retrieval date. The task preference for a release tag therefore cannot be
satisfied. The full HEAD commit `040ee482a8caefe2afe71a3a59d43923d2f0c7e6` was
selected because it is the newest revision and contains every required
binary64 routine with its `cr_*` entry point:

- `src/binary64/sin/sin.c` -> `cr_sin`
- `src/binary64/cos/cos.c` -> `cr_cos`
- `src/binary64/tan/tan.c` -> `cr_tan`
- `src/binary64/asin/asin.c` -> `cr_asin`
- `src/binary64/acos/acos.c` -> `cr_acos`
- `src/binary64/atan/atan.c` -> `cr_atan`
- `src/binary64/atan2/atan2.c` -> `cr_atan2`
- `src/binary64/exp/exp.c` -> `cr_exp`
- `src/binary64/log/log.c` -> `cr_log`
- `src/binary64/pow/pow.c` -> `cr_pow`

No local edits were made to the vendored bytes. Verified against the clone by
direct sha256 comparison during vendoring.

## Vendor subset (transitive closure)

All 10 routine `.c` files, plus exactly the local headers they include
(confirmed with `gcc -MM`):

- `src/binary64/atan2/tint.h` (included by `atan2.c`)
- `src/binary64/log/dint.h` (included by `log.c`)
- `src/binary64/pow/pow.h`, `src/binary64/pow/dint.h`, `src/binary64/pow/qint.h`
  (included by `pow.c`; `pow.h` includes the two dint/qint headers)

`log/dint.h` and `pow/dint.h` are different files in this revision and both are
vendored under their original paths. Test harness files (`*_mpfr.c`,
`check_special.c`, `worst.c`, `buildSC.c`, Makefiles, `.wc`/`.sollya`/`.sage`
data) are not needed to build the routines and are not vendored.

## Upstream build requirements (revision-specific, from README.md and check.sh)

- GCC: upstream CI uses
  `-O3 -march=native -Wshadow -fno-finite-math-only -frounding-math -fsignaling-nans`.
  `-frounding-math` is required for GCC because `#pragma STDC FENV_ACCESS ON`
  is not supported (gcc.gnu.org/PR34678); `-fsignaling-nans` is in the GCC
  default flag set.
- No fast-math, no `-ffinite-math-only`, no flush-to-zero; the routines assume
  IEEE-754 semantics, round-to-nearest ties-to-even, subnormals enabled, and
  `FLT_EVAL_METHOD == 0` (true on x86-64 SSE2; `-fexcess-precision=standard`
  would be needed on 32-bit x87 targets).
- FMA: several routines use `__builtin_fma`; when the target has no FMA
  instruction this lowers to a call to the correctly-rounded `fma` from libm,
  which upstream explicitly allows (README "Support of errno" section).
- errno support is opt-in (`-DCORE_MATH_SUPPORT_ERRNO`) and is not enabled;
  the component exposes no errno contract.
- The code uses GNU extensions (`asm`), so strict `-std=c11` does not compile
  it; the build uses `-std=gnu11`.

## Known upstream limitations affecting this pin

- Correct rounding applies to the binary64 routines used here; CORE-MATH is a
  collection of independent routines, not a complete libm replacement.
- `atan2.c` and `pow.c` contain diagnostic `printf`/`exit` cold paths used if
  an internal worst-case check fails; these remain in the artifact and appear
  in the allowed undefined-symbol list.
- `-march=native` is deliberately not used (platform artifact must not depend
  on the build host microarchitecture). See `../../peggle_math.c` and
  `../../build.sh` for the flags actually used.
