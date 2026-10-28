# PeggleSim

Julia implementation of the Peggle Evolved simulation. This package implements
the M2 milestone: deterministic math, the exact LÖVE 11.5 RNG, the
level/config/state types, the ready-to-aim checkpoint capture/reset contract,
and the cross-machine parity manifest. The full test suite is
`julia --project=julia/PeggleSim -e 'using Pkg; Pkg.test()'` (3,725 pass,
0 fail). The durable notes are in `wiki/context/julia.md`.

## Pinned environment

`Project.toml` and `Manifest.toml` are committed together and form the pinned
environment. Runtime dependencies are the `JSON` 0.21 package plus the Julia
stdlibs `Base64`, `Printf`, and `SHA`; `Test` is the only test dependency.
Reproduce the manifest with:

```bash
julia --project=julia/PeggleSim -e 'using Pkg; Pkg.instantiate()'
```

## Math backend

`DetMath` exposes one function per authoritative math call site
(`det_sin`, `det_cos`, `det_atan`, `det_atan2`, `det_asin`, `det_acos`,
`det_tan`, `det_exp`, `det_log`, `det_pow`, `det_sqrt`, `lua_mod`) behind
three backends selected once, in `__init__`, from `PEGGLE_MATH_BACKEND`:

- `system_libm` (default on Linux) calls `libm.so.6` with `ccall`, which is
  the same library LuaJIT uses, giving bit-identical results on this platform;
- `core_math` (experimental) loads the pinned native component from
  `native/artifacts/<platform>/` (`libpeggle_math.so`, `peggle_math.dll`, or
  `libpeggle_math.dylib` by platform; or `PEGGLE_MATH_LIB`) and calls the
  `peggle_math_*` symbols; a missing artifact or ABI mismatch is a hard error
  with no fallback;
- `julia_base` (default elsewhere) calls Julia runtime `Base` math. This is
  not a pinned implementation claim; `openlibm` is accepted as an alias.

`math_backend_identity()` reports the active backend, library, platform,
native ABI/artifact identity when applicable, glibc version, and Julia version
for cross-machine manifests. The deterministic path must not use `@fastmath`,
`@simd`, `@turbo`, `muladd`, or `fma`. Numerical parity is checked against
the captured Lua math census and gameplay traces.

## Canonical JSON

`canonical_json` matches `tools/canonical_json.lua` byte-for-byte: sorted
object keys, arrays in order, `%.17g` doubles, integral values below 2^53 as
plain decimals, `-0` preserved, NaN and infinity rejected, and no timestamps
or host data. Empty containers are explicit: a `Vector` encodes as `[]`, a
`Dict` as `{}`, and `CanonicalArray`/`CanonicalObject` force a kind when the
Julia container does not express it. `sha256_hex` and `float_bits_hex` support
artifact hashing and numeric comparison.

## Tests

```bash
julia --project=julia/PeggleSim -e 'using Pkg; Pkg.test()'
```

`test/runtests.jl` auto-discovers every `test_*.jl` file in `test/`. Tests that
need fixtures produced by a parallel workstream skip with a printed note while
those files are absent.
