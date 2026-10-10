# M2 audit: cross-language math census

Status: complete (2026-10-04). Machines: reference host only (see §6).

- Fixture: `fixtures/math_census/math_census.v1.json`
  (670,570 B, SHA-256 `fa052e17...86b0`)
- Result summary: `results/m2-math-census.json`
- Producer: `tools/capture_math_census.lua` via
  `scripts/capture_math_census.sh` (plain `luajit`, no display)
- Verifier: `julia/PeggleSim/bin/math_census.jl` and `src/parity.jl`
  (`make math-census`, `make math-census-check`, `make julia-parity`)

## 1. Method

The census compares one recorded LuaJIT value against one recomputed Julia
value per case as a 64-bit IEEE-754 bit pattern (`"0x%016x"` string), never as
a decimal. A case passes only on exact string equality; one ULP is a
mismatch.

- **Recorded inputs.** Every finite double in `fixtures/expected/*.json` and
  `interchange/levels/*.v1.json` is collected with the canonical decoder,
  deduplicated bit-exactly (an FFI union separates `-0` from `+0`), and sorted
  by numeric value. The current corpus is 1546 unique values from 33 files.
  Per-function recorded-input caps (unary values, binary pairs) exist only to
  bound future growth and are not reached today.
- **Boundary cases.** The capture adds explicit cases per function: `0`, `-0`,
  `±1`, `±π` multiples and neighbours, `±π/2`, tiny/huge/subnormal values;
  axis/quadrant/sign and equal-magnitude pairs for `atan2`; one ULP inside
  and outside `[-1, 1]` for `asin`; sign combinations, near-multiples, and
  zero/tiny/huge operands for `lua_mod`; explicit base/exponent grids for
  `pow`. Pairs whose Lua result is NaN or infinite are excluded from `mod`
  because canonical JSON rejects non-finite numbers; such results are kept as
  bit patterns for the other functions.
- **Truth.** `capture_math_census.lua` runs under LuaJIT, whose `math.*`
  calls forward to the system C library. That is the same implementation the
  pinned LÖVE/LuaJIT reference uses. Expected values are the captured bit
  patterns.
- **Check.** `bin/math_census.jl` recomputes every case with `DetMath`
  (`:system_libm` on this host) and, as a diagnostic only, with Julia `Base`
  (`:openlibm`). The process exits nonzero on any system-libm mismatch;
  openlibm divergence is reported, not failed. `src/parity.jl` repeats the
  system-libm check inside every parity manifest, so the census gates
  `make julia-parity` as well.

## 2. Case counts

| Function | Cases | | Function | Cases |
| --- | ---: | --- | --- | ---: |
| `atan2` | 3164 | | `pow` | 1613 |
| `mod` | 1857 | | `sin` | 1588 |
| `atan` | 1588 | | `cos` | 1588 |
| `exp` | 1558 | | `log` | 1339 |
| `sqrt` | 1338 | | `asin` | 161 |

Total: **15,794 cases**. Fixture source provenance:
`reference_revision d17f6e7`, `reference_tree 3dc7ddfe...`,
`config_sha256 455757c9...`.

`DetMath` also exposes `det_tan` and `det_acos`; they are not part of this
fixture's input corpus because the recorded static artifacts do not call
them. They are covered by the same backend mechanism and must enter the
census when a milestone first uses them authoritatively.

## 3. System libm result (Tier A)

| Checked | Mismatches | Fixture SHA-256 |
| ---: | ---: | --- |
| 15,794 | **0** | `fa052e17...86b0` |

`system_libm` is bit-identical to the captured LuaJIT truth on every case.
This is the evidence behind the default backend decision
(`wiki/decisions/0001-math-backend.md`).

## 4. Openlibm divergence (Tier B, diagnostic)

Julia `Base` misses 705 of 15,794 cases (4.46%), confirming that the backend
selection is load-bearing rather than cosmetic:

| Function | Cases | Divergences | Rate |
| --- | ---: | ---: | ---: |
| `atan2` | 3164 | 461 | 14.57% |
| `asin` | 161 | 14 | 8.70% |
| `pow` | 1613 | 89 | 5.52% |
| `cos` | 1588 | 53 | 3.34% |
| `sin` | 1588 | 45 | 2.83% |
| `atan` | 1588 | 35 | 2.20% |
| `exp` | 1558 | 7 | 0.45% |
| `log` | 1339 | 1 | 0.07% |
| `mod` | 1857 | 0 | 0.00% |
| `sqrt` | 1338 | 0 | 0.00% |
| **Total** | **15,794** | **705** | **4.46%** |

## 5. Decision: Tier A now, Tier B later

(Historical note: WP-C renamed this tier to `:julia_base`, reported with the
canonical name `julia_base`; `openlibm` remains an accepted input alias. See
the 2026-10-09 amendment in `wiki/decisions/0001-math-backend.md`.)

`:system_libm` is the authoritative backend on the initial (Linux/glibc)
environment matrix because it matches the reference exactly. `:openlibm` is
kept as the non-authoritative fallback for other platforms; its divergence
rates above are the measured cost of that portability. Promoting Tier B
requires either a per-platform math contract or a platform-specific census
with its own truth capture, and a schema/manifest decision about mixed
backends. Until then, parity manifests compare the authoritative section only
and record the backend identity in `environment`.

## 6. Cross-machine caveat

The strict cross-machine contract is **not yet demonstrated with two
physical machines**. The reference host is an AMD Ryzen 5 4600H / glibc 2.44
machine; a second host (`deathstar`) was not reachable from this session
(DNS resolution failed). What has been verified locally:

- `results/parity/local.json` was emitted by `bin/parity_emit.jl`;
- the test suite (`test/test_parity.jl`) generates two independently labelled
  manifests and requires their `authoritative` sections to be byte-identical;
- `scripts/compare_parity.sh` reports the first differing JSON path and was
  exercised on both equal and deliberately flipped manifests.

A future session must run `make julia-parity` with a distinct label on the
second host and compare with `scripts/compare_parity.sh` before any
cross-machine claim is made.
