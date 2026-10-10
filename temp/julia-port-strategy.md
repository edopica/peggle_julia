# Julia port vs Lua-side optimization — strategy notes

Date: 2026-10-03
Related: `temp/update-phase-optimization-report.md`

## TL;DR

1. **Port first is the right call**, but before writing the Julia sim, freeze the
   determinism contract (transcendentals + RNG + comparison method) and the
   validation corpus. Layout is not the risk; math is.
2. **Do not do a Lua SoA refactor.** SoA is a data-layout decision for the Julia
   side, not a shared code shape. Keep the Lua engine AoS as the reference.
3. Share **algorithm, phase order, float-op order, tie-breaking, trace schema**;
   do not share data layout, the event-journal deep-copy/ownership model,
   closure patterns, or LuaJIT-specific tricks.
4. The Lua optimizations found earlier split into portable and LuaJIT-specific;
   only P1/P2 are worth doing on the Lua side, mainly to produce validation
   corpora faster.

## 1. What "portable structure" should mean

Aim for a **determinism contract plus a validation corpus**, not a line-by-line
transposition. Lua-style AoS tables, per-step `{}` scratch, and the
deep-copy event journal transposed literally into Julia produce slow,
type-unstable code. The port should be idiomatic Julia against the same
observable behavior.

Portable (must match):

- 26-phase pipeline order and every ordering rule in `wiki/architecture.md`.
- Physics algorithm: broadphase predicate, narrow phase per shape, TOI
  selection priority + index tie-break, 5-iteration cap, rotation slices,
  graze deferral, depenetration, ball-ball impulses.
- Float operation order on every branch (this is what replays/traces encode).
- Event/command schemas and canonical trace JSONL.
- Replay semantics (schema v2 capture/restore, ball IDs, shot lifecycle).

Not portable (implement per language):

- AoS vs SoA and entity representation.
- The journal's validated `Exportable.copy` ownership model. In Julia, use
  immutable event structs / value snapshots; copying becomes cheap and safe.
- Lua closures as per-iteration helpers (Julia closures that capture reassigned
  locals box them; use plain functions and explicit state).
- Rendering coupling and `love.*`; the sim core boundary is already close to
  love-free (`BenchLib` stub proves it). `love` appears only in:
  `peg_colors` (`love.math.newRandomGenerator`), `level_manager`
  (`love.graphics.getDimensions`), draw code, and `Engine:update`
  (`love.mouse.isDown`).

## 2. Determinism is the real porting risk

Function classification for cross-language equality:

| Category | Functions | Port risk |
|---|---|---|
| Correctly rounded, IEEE | `+ - * /`, `sqrt`, `floor`, `ceil`, comparisons | none |
| Lua-specific semantics | `%` (floor-mod), `^`, integer/float printing `%.17g` | small, replicate exactly |
| Library-defined | `sin`, `cos`, `atan2`, `exp` | **1-ulp divergence possible (glibc vs openlibm/LLVM)** |
| RNG | `love.math.newRandomGenerator` (xorshift family) | must reimplement the exact algorithm or re-baseline colors |

Consequences:

- A 1-ulp difference can flip a TOI tie, a graze boundary, or a `did_bounce`
  threshold after a few hundred steps. Strict byte-equality of long traces is
  not guaranteed by "both use doubles".
- Decide the contract explicitly:
  - **A. Bit-exact**: pin the transcendental implementation (e.g. Julia
    `ccall` into the same libm, or port the exact kernels), replicate Lua `%`,
    port the LÖVE RNG. Best for automated trace diffing; more porting work and
    platform-specific.
  - **B. Tolerant**: exact event ordering/types, positions within a tolerance,
    step counts within a small window. Simpler and robust for level search;
    needs a tolerance-aware differ and periodic manual review of divergences.
- Recommended: run a **cheap spike first** — evaluate the handful of `sin/cos/
  atan2` call patterns on real inputs under both runtimes and count mismatches.
  That single result decides A vs B before the port starts.

## 3. Data layout recommendation

- **Lua side: keep AoS.** The physics/engine use entity tables with mixed
  scalar fields; converting to SoA is a large, bit-risky rewrite whose only
  payoff (fewer table dereferences) is often smaller than the GC savings from
  the allocation fixes. It would not be reused as Julia code anyway.
- **Julia side: choose independently, based on profiling.** For uniform numeric
  arrays (balls, circle pegs) `Vector{Float64}` per field (or StructArrays) is
  natural; for the shape union
  (`circle | rectangle | annular | line-arc`) prefer per-shape vectors and
  function barriers over an abstract `AbstractPeg` field, to keep type
  stability. AoS of immutable structs is also acceptable at these entity
  counts; decide with `@code_warntype`/allocations, not with the Lua layout.
- Net: the two implementations share the algorithm; layout is a local
  optimization in each.

## 4. Candidate mapping (from the update-phase report)

| Candidate | Portable? | Julia equivalent |
|---|---|---|
| P1 Path sampling allocation-free | **Yes, concept** | Arc-length table + safeguarded Newton port directly; Julia immutable points don't allocate, but keep the loop allocation-free and precompute tables at load |
| P2 Physics closure removal | **Yes, structure** | Plain functions + explicit state struct passed through; avoids Julia closure boxing too |
| P3 cached trig / dead sqrt | Yes | Same precomputation |
| P4 lazy annular draw geometry | Yes, architecture | Sim/render split exists in any port |
| P5 scratch pooling + owned events | Concept yes, code no | Preallocated buffers; immutable event structs instead of deep-copy journal |
| P6 `draw_path` pooling | Peripheral | Small `Vector` per ball |
| P7 cached shape bounds | Yes | Store on the entity struct |
| P8 broadphase acceleration | Yes, and likely needed | Same algorithm; higher impact in Julia because the sim will run much faster elsewhere, making broadphase the bottleneck |
| P9 skip static-peg scans | Yes | Precomputed moving-peg index list |
| LuaJIT-only (`table.new`, FFI, `bit`, JIT trace tuning, `ipairs` heuristics) | **No** | Never port; never do for portability's sake |

## 5. Recommended sequence

0. Freeze the corpus: 42-case level × angle matrix, replays, gameplay traces;
   make it runnable with one command and record hashes.
1. Spike the math/RNG divergence and pick contract A or B (section 2).
2. Formalize the pure sim-core boundary (no `love.*`, scalar inputs/outputs);
   `BenchLib` is most of the way there.
3. Port in dependency order, validating each layer against the corpus as you
   go: `path`/`circuits` → `peg`/`bucket`/`fever_buckets` →
   `impact_geometry` → `physics` → engine processors → `Engine` pipeline.
4. Only then do Julia performance work (type stability, allocation-free step,
   preallocated buffers, SoA if profiling asks).
5. Back-port to Lua only what pays for corpus generation: **P1 and P2**.
   They are the two largest update-phase wins, they are the same changes the
   Julia port wants structurally, and faster Lua corpus generation directly
   feeds port validation. Defer P4/P5/P8 in Lua until the port lands.

## 6. Direct answer to "SoA vs language-specific features"

- SoA is a portable *principle* (separate hot arrays, sequential access, no
  per-entity sub-table churn), not a portable *code shape*. Adopt it in Julia
  where profiling justifies it; do not convert Lua to match it.
- LuaJIT-specific optimizations buy update time now but are throwaway for the
  port and can encode assumptions (allocations sinking, trace behavior) that
  mislead the Julia design.
- If the port is the priority, the only Lua work worth doing first is the
  portable algorithm work (P1/P2), because it accelerates the validation
  corpus the port needs. Everything else belongs in the Julia implementation.
