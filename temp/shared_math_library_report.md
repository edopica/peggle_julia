# Shared Math Library for Lua↔Julia Parity — Evaluation Report

**Status:** Draft for discussion
**Date:** 2026-10-03
**Scope:** The "shared C math library" road for making the future Julia headless clone produce
event traces that match the Lua/LÖVE2D game. Measurements taken on the development machine
(see §3).

**Related documents:**
- `temp/unified_geometry_kernel.md` — geometry contract, validation pyramid, numeric policy.
- `temp/fat_epsilon_logical_determinism_evaluation.md` — `toi_epsilon` policy, tie-breaking, discriminant stress testing.
- `temp/archive/julia-implementation-guide.md` — earlier full-port guide (predates these findings).

---

## 1. Executive summary

The Lua↔Julia numeric gap is **not** a general floating-point problem. It is a **five-function
problem** (`sin`, `cos`, `atan`/`atan2`, `asin`, plus `math.atan`), concentrated in roughly
**30 authoritative call sites**.

Measured facts:

| | LuaJIT (game) | Julia (clone) |
|---|---|---|
| Math library | system libm (glibc) | bundled openlibm (`Base.Math.libm == "libopenlibm"`) |
| `sin` vs system libm | **0 / 200,000** (it *is* system libm) | **~3.1 %** of inputs differ by 1 ULP |
| `atan2` / `atan(y,x)` | **0 / 200,000** (it *is* system atan2) | **~17.8 %** of inputs differ (Julia does not use libm `atan2`) |
| `sqrt` | correct rounding | 0 differences (correctly rounded in both) |
| FMA contraction of `a*b+c` | none | **none by default** (strict IEEE; `muladd` is context-dependent) |

A shared math library therefore does **not** require changing Julia's scientific stack. It only
requires that the clone's five transcendental functions resolve to the same implementation the
game already uses. Two tiers are available:

- **Tier A (zero game change, Linux-dev parity):** Julia calls the *system* libm for those five
  functions via `ccall`. Bit-identical to LuaJIT on the same machine. No shipped-game changes.
- **Tier B (cross-platform parity, optional):** bundle **openlibm** (the library Julia already
  uses) and have the Lua game call it for the same five functions. This makes both engines
  portable and mutually identical across operating systems, at the cost of a native build
  step and a one-time re-capture of golden traces.

**Recommendation:** adopt **Tier A now**, keep **Tier B** as a documented, low-cost upgrade path,
and keep the physics path strict-IEEE (no `@fastmath`, no `@turbo`, no `muladd`). This removes the
only known math divergence source without giving up any Julia scientific capability and without
porting physics to C/C++.

---

## 2. Problem statement

Requirement already agreed: Lua and Julia traces need not be bit-identical, but **events must match
~99.99 % of the time**. The geometry-kernel proposal already plans a fat `toi_epsilon`
(`1e-6`) plus a strict total-order comparator to absorb tiny TOI differences.

That mechanism handles *near-ties*. It does **not** handle:

1. Two engines evaluating the same formula to slightly different results, and
2. Those differences crossing a hard discrete branch (hit vs graze, physical hit vs candidate
   lost, face vs corner, inside-arc vs outside-arc).

A shared math library attacks (1) directly, reducing (2) to logic bugs rather than numerics.

---

## 3. Measurement environment

| Component | Value |
|---|---|
| OS | Linux |
| glibc | 2.44 |
| CPU | AMD Ryzen 5 4600H (znver2), FMA available |
| Julia | 1.12.6 |
| LuaJIT | 2.1.1788460057 |
| LÖVE | system package; links `libluajit-5.1.so.2` and `libm.so.6` |

Reproduction commands are in the appendix. Julia's `Base.Math.libm` is `libopenlibm`; calling
the system library requires the versioned soname (`libm.so.6`) because `/usr/lib/libm.so` is a
linker script on this distribution.

---

## 4. What actually diverges

### 4.1 LuaJIT uses the system libm directly

`math.sin`, `math.cos`, `math.atan2`, `math.atan`, `math.asin` call the host C library.
Measured against `ffi.C.sin` / `ffi.C.atan2` on the same process: **0 differences in 200,000
samples** for both moderate and large arguments. LuaJIT's JIT emits a call to libm; it does not
substitute an internal approximation.

`math.sqrt`, `math.floor`, `math.ceil`, `math.min`, `math.max`, `math.abs` are exact or
correctly rounded.

### 4.2 Julia uses openlibm and is strict-IEEE by default

- `Base.Math.libm == "libopenlibm"` — Julia bundles openlibm (fdlibm/FreeBSD `msun` derivative)
  for cross-platform consistency, not because it is better at scientific workloads.
- Julia's default math mode is `ieee`. Plain `a*b+c` is not contracted into FMA, and FP
  operations are not reassociated.

### 4.3 Divergence rates (openlibm vs glibc)

| Function | Differences | Notes |
|---|---:|---|
| `sin` (moderate args, ±50) | 6,230 / 200,000 (**3.1 %**) | 1 ULP |
| `sin` (large args, ±5e5) | 6,170 / 200,000 (**3.1 %**) | relevant: circuit time grows without bound |
| `atan(y, x)` vs `atan2` | 35,570 / 200,000 (**17.8 %**) | Julia implements two-arg `atan` itself |
| `sqrt` | 0 / 100,000 | correctly rounded in both |

The `atan` figure is the important one: the annular arc-membership test uses `math.atan2` and
feeds a **discrete** branch (`is_inside_arc`, `physics.lua:606` and `:1052`).

### 4.4 FMA and operation order

- Plain `a*b+c` differs from guaranteed-fused `fma(a,b,c)` in **23.5 %** of random cases, and
  `code_native` for `x*y+1.0` shows `mulsd` and no FMA. **Julia does not contract plain
  arithmetic.**
- `muladd` is context-dependent: as a standalone function it compiled to FMA; inside the census
  loop it did not. `plain != fma` but `plain == muladd` in 1,000,000 / 1,000,000 samples.
  **Do not use `muladd`/`fma` in the deterministic path.**
- LuaJIT does not contract either.

Consequence: if the clone mirrors Lua's expression order and avoids fast-math constructs, all
`+ - * / sqrt` results are already bit-identical.

### 4.5 The divergence surface is small and known

Repo-wide trig occurrences: 89. Authoritative simulation sites: **~30**.

| Module | Trig occurrences | Authoritative? |
|---|---:|---|
| `src/systems/physics.lua` | 18 | **yes** — all feed discrete branches |
| `src/systems/circuit_primitives.lua` | 9 | **yes** — peg transforms/velocities |
| `src/engine/core.lua` (launch) | 2 | **yes** — launch vector |
| `src/entities/bucket.lua` | 1 | **yes** — bucket position |
| `src/entities/peg.lua`, `lines.lua`, `path.lua`, `overlap_detector.lua`, `impact_geometry.lua` | 59 | no — load-time, render, debug |

Physics trig feeds discrete outcomes at: rectangle local-space transforms
(`physics.lua:345-346`), annular `is_inside_arc` (`:606`, `:1052`), cap direction/radial bands
(`:683-744`), annular corner positions (`:756-757`). Indices/velocities from
`circuit_primitives.lua` propagate into every collision decision a moving peg participates in.

---

## 5. Options

### Option A — Tier A: Julia calls system libm per call

Add a small module (e.g. `DetMath.jl`) used **only** by the clone's physics/circuits/bucket:

```julia
module DetMath
const LIBM = "libm.so.6"   # platform-resolved; see §7
sin(x::Float64)   = ccall((:sin,   LIBM), Float64, (Float64,), x)
cos(x::Float64)   = ccall((:cos,   LIBM), Float64, (Float64,), x)
atan2(y::Float64, x::Float64) = ccall((:atan2, LIBM), Float64, (Float64, Float64), y, x)
asin(x::Float64)  = ccall((:asin,  LIBM), Float64, (Float64,), x)
end
```

- **Pros:** zero changes to the shipped game; bit-identical to LuaJIT on the same host; trivial
  to implement and test; no native build for the game; Julia's scientific stack untouched.
- **Cons:** parity holds only where the game's libm and the clone's libm are the same
  (Linux/glibc, same version). Not cross-platform.
- **Cost:** ~half a day plus the divergence census.

### Option B — Tier B: bundle one libm in both engines (recommended target state)

Bundle **openlibm** (Julia's default; designed for portability/reproducibility):

- Julia uses openlibm natively (no change at all), compiled/kept strict-IEEE.
- Lua game calls openlibm for the five functions. Two sub-variants:
  - **B1 — Lua override at startup:** expose a tiny C shim (`det_sin`, `det_cos`, …) linked into
    LÖVE, then override `math.sin`/`math.cos`/`math.atan2`/`math.atan`/`math.asin` at startup via
    LuaJIT FFI. Measured overhead: **19.4 ns/call** for the overridden `math.sin` vs 17.3 ns/call
    for a direct FFI call — negligible against collision math.
  - **B2 — link-time redirect:** statically link openlibm and wrap/redirect the libm symbols so
    LuaJIT's `sin` resolves to openlibm. Less code, but fragile and platform-specific; not
    recommended as the first implementation.

- **Pros:** cross-platform bit parity for the five functions; Julia already uses openlibm, so no
  Julia-side change; one deterministic math identity shared by both engines.
- **Cons:** native build additions; one-time change to the game's numeric output (golden traces
  and `benchmark_results.csv` must be re-captured); FFI overhead (small, §6).
- **Cost:** moderate; can be deferred until cross-platform parity is actually required.

### Option C — Global `USE_SYSTEM_LIBM=1` (rejected)

Rebuilding Julia against glibc globally.

- Does **not** give cross-platform parity (glibc varies by version and differs from Apple/MSVC).
- Trades Julia's portable consistency for per-host matching with no scientific upside.
- Violates the "physics must be frozen, not tuned per host" principle.
- Rejected. If system libm is wanted, scope it (Option A), do not rebuild Julia.

### Option D — Do nothing; rely on `toi_epsilon`

Rejected as the primary mechanism. The epsilon absorbs *near-ties*; it cannot reconcile a
discrete branch flipped by an `atan2` 1-ULP difference (annular arc membership) or a
near-zero discriminant. It remains valuable as a safety net, not as a substitute for math parity.

### Comparison

| | A (system libm) | B (bundled openlibm) | C (rebuild Julia) | D (epsilon only) |
|---|---|---|---|---|
| Linux-dev parity | yes | yes | yes | heuristic |
| Cross-platform parity | no | **yes** | no | no |
| Game changes | none | native shim + override | none | none |
| Julia changes | scoped shim | none | global rebuild | none |
| Native build cost | none | moderate | none | none |
| Scientific Julia unaffected | yes | yes | **no** | yes |
| Golden re-capture | no | yes (one time) | no | no |

---

## 6. Performance

### Call overhead (5,000,000 calls, this machine)

| Call | ns/call |
|---|---:|
| LuaJIT `math.sin` (native libm) | ~19 |
| LuaJIT `math.sin = ffi.C.sin` override | 19.4 |
| LuaJIT direct `ffi.C.sin` | 17.3 |
| Julia `Base.sin` (openlibm) | 16.7 |
| Julia `ccall((:sin,"libm.so.6"), …)` | 29.0 |

The per-call cost of the shared-math approach is **~12 ns** on the Julia side and **~2 ns** on the
Lua side. Against a CCD step that already spends hundreds of nanoseconds to microseconds per
collision, this is noise. It is not a reason to choose or reject any option.

### Where simulation throughput actually comes from

Massive level simulation throughput comes from **threading across independent shots**
(`Threads.@threads` over an angle/delay grid), not from SIMD inside a single shot. This is
fortunate for parity:

- Threading across shots does not change any single shot's arithmetic.
- SIMD/`@turbo` within a shot would reassociate and contract reductions and **must not** be used
  in the deterministic path. Restrict `@turbo`/LoopVectorization to the outer metrics layer or to
  a separately validated fast path.

---

## 7. Cross-platform matrix

| Platform | Lua game libm | Julia default | Tier A parity | Tier B parity |
|---|---|---|---|---|
| Linux/glibc | glibc | openlibm | yes | yes |
| macOS | Apple libSystem | openlibm | no | yes |
| Windows | UCRT/MSVC | openlibm | no | yes |

Tier A is sufficient **only if** reference traces are always produced on the same
OS/libm as the simulations (e.g. Linux CI/dev). If the shipped game must reproduce on other
platforms, plan for Tier B.

Platform symbols: `libm.so.6` on Linux; `libm`/`libSystem` on macOS; on Windows the CRT exports
`sin` etc. from the universal CRT. Tier B removes these differences by making both engines call
openlibm, which builds on all three.

---

## 8. What this solves and what it does not

**Solves:** the only known *numerical* divergence source between the two engines after strict
IEEE arithmetic is enforced. With it, the two implementations should be bit-identical for the
same inputs and the same expression order.

**Does not solve (must be handled separately):**

1. **Tie-breaking by volatile index.** `register_hit` currently breaks ties by per-shape array
   index `_i` (`physics.lua:167-192`), which shifts when pegs are removed. Migrate to stable
   `original_index` (+ `feature_id`) in both engines. Already recommended by the fat-epsilon
   evaluation.
2. **Floored modulo.** Lua `%` on negative angles is floored; C `fmod` is truncated. Use a
   floored helper in Julia/C (`mod` matches Lua) — relevant at `physics.lua:607`, `:1053`,
   `bucket.lua:40`, `impact_geometry.lua:62`.
3. **RNG parity.** `love.math.newRandomGenerator` is a 64-bit xorshift* with Wang-hash seeding,
   used for peg color assignment (`src/systems/peg_colors.lua:50`). It is reproducible, but the
   clone must port the algorithm and LÖVE's `random(1, n)` mapping exactly.
4. **Operation-order discipline.** The clone must mirror Lua's expression order and avoid
   `@fastmath`, `@turbo`, `@simd` reductions, and `muladd`/`fma` in the physics path.
5. **Resolved level geometry.** Dump fully-resolved peg transforms and circuit definitions so the
   clone never re-runs load-time authoring trig (`lines.lua`, `path.lua`).
6. **Serialization.** Compare parsed numbers, not formatted strings; tag fields exact vs
   tolerance. Lua's `%.17g` round-trips doubles; `simulation_snapshot.lua` and the trace exporter
   already follow this convention.

---

## 9. Interaction with `toi_epsilon` and tie-breaking

The shared math library changes the role of the epsilon:

- **Before:** the epsilon absorbs both genuine near-ties *and* cross-language libm drift.
- **After:** drift is eliminated; the epsilon only groups genuine simultaneous contacts
  (same formula path, same inputs). The recommended `1e-6` from the fat-epsilon evaluation
  remains appropriate as a safety margin, and the `(priority, original_index, feature_id)` total
  order still decides ties.

This is the desirable end state: the comparator is exercised only by real geometric ties, so a
tie observed on one engine is reproducible on the other.

---

## 10. Recommended approach

1. **Adopt Tier A now** as part of the Julia clone's `Config`/math layer:
   `DetMath.jl` with the five functions routed to system libm. No game changes.
2. **Keep Tier B as the documented upgrade** if cross-platform trace parity becomes a
   requirement. Prefer B1 (startup override via a small C shim) over symbol redirection.
3. **Freeze the numeric contract** in the geometry-kernel phase: strict IEEE; no fast-math;
   no `muladd`/`fma`; floored modulo; mirrored expression order.
4. **Do not port the physics to C/C++ for parity reasons.** The shared-math shim is smaller,
   faster to build, and preserves the Lua hot-reload dev loop. A native physics core, if ever
   wanted, should be justified by performance/shipping/single-source-of-truth, not by parity.
5. **Make the first Julia deliverable a divergence census** (§11) rather than a full simulator.

---

## 11. Validation plan: divergence census

Before writing the full clone, build a minimal harness that compares *values*, not outcomes:

1. Instrument the Lua physics to log, per collision candidate, the exact float64 inputs and
   intermediates: local transforms, `is_inside_arc` angle, cap normals, discriminants, `t1`.
2. Re-run the same shots in a Julia skeleton that computes the same quantities in the same order.
3. Compare bit patterns (`reinterpret(UInt64, x)`), not tolerances, and classify each difference:
   - `sin`/`cos` (expected: 0 with Tier A),
   - `atan2` (expected: 0 with Tier A; ~18 % without),
   - arithmetic (expected: 0),
   - logic/order (real porting bugs).
4. Run the census over a corpus that includes rotating pegs, annular pegs, grazes, depenetration,
   dense clusters, and the adversarial cases listed in the fat-epsilon evaluation.
5. Record the residual discrete-branch disagreements and confirm they are covered by
   `toi_epsilon` + the total-order comparator.

Exit criterion: **zero math-layer differences** with Tier A. Any remaining event divergence is
then provably a logic bug in one of the two implementations, which is exactly the property the
project wants.

---

## 12. Open questions

1. Is cross-platform trace parity required (shipped Windows/macOS game vs Linux simulations), or
   is Linux-dev parity sufficient? → Tier A vs Tier B.
2. Does the project accept a one-time re-capture of golden traces if bundling openlibm (Tier B)
   changes the game's numeric output? (Mechanics are nearly complete, so timing is favorable.)
3. What is the simulation throughput target, and will `@turbo`/SIMD ever be desired inside a
   single shot? If so, it must be isolated from the deterministic path and validated separately.
4. Is a native production engine a real long-term goal? If yes, a native **geometry kernel** may
   be the right scope — not a full C++ physics step.

---

## Appendix A — Reproduction commands

Julia vs system libm divergence:

```julia
julia -e '
using Random
bits(x)=reinterpret(UInt64,x)
function run()
  Random.seed!(12345)
  d=0; n=200000
  for i in 1:n
    x=(rand()-0.5)*100.0
    bits(sin(x)) != bits(ccall((:sin,"libm.so.6"),Float64,(Float64,),x)) && (d+=1)
  end
  println("sin openlibm vs glibc: $d / $n")
  d=0
  for i in 1:n
    y=(rand()-0.5)*100.0; x=(rand()-0.5)*100.0
    bits(atan(y,x)) != bits(ccall((:atan2,"libm.so.6"),Float64,(Float64,Float64),y,x)) && (d+=1)
  end
  println("atan vs atan2: $d / $n")
end
run()
'
```

LuaJIT confirmation that `math.*` is system libm:

```lua
luajit -e '
local ffi=require("ffi")
ffi.cdef[[double sin(double); double atan2(double,double);]]
local d=0; for i=1,200000 do
  local x=(i%1000)*0.1
  if math.sin(x) ~= ffi.C.sin(x) then d=d+1 end
end
print("math.sin vs ffi.C.sin diffs:", d)
'
```

FMA census:

```julia
julia -e '
using Random
bits(x)=reinterpret(UInt64,x)
function census()
  Random.seed!(2); dpf=0; dpm=0; dmf=0; n=1_000_000
  for i in 1:n
    a=randn(); b=randn(); c=randn()
    p=a*b+c; f=fma(a,b,c); m=muladd(a,b,c)
    bits(p)!=bits(f) && (dpf+=1)
    bits(p)!=bits(m) && (dpm+=1)
    bits(m)!=bits(f) && (dmf+=1)
  end
  println("plain!=fma: $dpf / $n"); println("plain!=muladd: $dpm / $n"); println("muladd!=fma: $dmf / $n")
end
census()
'
```

Call-overhead benchmarks:

```lua
luajit -e '
local ffi=require("ffi"); ffi.cdef[[double sin(double);]]
local N=5000000; local s=0
local t0=os.clock(); for i=1,N do s=s+math.sin(i*0.001) end
local t1=os.clock(); for i=1,N do s=s+ffi.C.sin(i*0.001) end
local t2=os.clock()
print(string.format("math.sin %.2f ns/call, ffi %.2f ns/call", (t1-t0)/N*1e9, (t2-t1)/N*1e9))
'
```

```julia
julia -e '
function bench()
  N=5_000_000; s=0.0
  t0=time_ns(); for i in 1:N; s+=sin(i*0.001); end
  t1=time_ns(); for i in 1:N; s+=ccall((:sin,"libm.so.6"),Float64,(Float64,),i*0.001); end
  t2=time_ns()
  println("Base.sin ", round((t1-t0)/N;digits=2), " ns/call; ccall ", round((t2-t1)/N;digits=2), " ns/call")
end
bench()
'
```
