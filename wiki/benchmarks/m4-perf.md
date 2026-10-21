# M4 performance gate

Measured steady-state cost of the Julia shot engine across the seven M0
workloads, the zero-allocation criterion for warm fixed-capacity stepping, the
allocation accounting behind it, and the same-host Lua comparison.

- Status: **session 2 of 3 complete; M4 itself remains open** (cross-machine
  qualification and closeout are session 3).
- Correctness anchor: the session-1 corpus (`results/m4/parity-summary.json`,
  `overall_pass = true`; 14/14 fixtures, 6/6 traces, 7/7 sweeps, 11/11
  scenarios) plus the gates in §7.
- Producer: `scripts/bench_m4.sh` (`make m4-bench`) and
  `scripts/m4_allocation.jl`.
- Results: `results/m4/bench-report.json`,
  `results/m4/allocation-profile.json`.
- Host: omarchy, AMD Ryzen 5 4600H (6 cores / 12 threads), Linux, Julia
  1.12.6, LÖVE 11.5.0, LuaJIT 2.1, math backend `system_libm`.

## 1. Zero-allocation criterion

The governing plan says: *"Warm fixed-capacity stepping targets zero heap
allocation, with any capacity growth measured separately."* This section turns
that sentence into a testable gate.

### 1.1 Steady-state stepping (the gate)

**Definition.** Starting from a warmed engine whose journals, command buffers,
scratch containers, pools, and dictionaries have reached their high-water
capacity for that level and shot length, one fixed simulation step performs
**0 bytes of heap allocation**.

One step is exactly the work performed by `PeggleSim.update!(eng,
config.fixed_dt)` when the accumulator advances one fixed step:

1. `save_previous_state!` (previous-position stamping),
2. `step_simulation!` (phases 1–5 and the `_step_body!` path, phases 6–15),
3. `finalize_step!` (phases 16–26, including the fever bucket update),
4. the `update!` bookkeeping (`steps_run`).

This is the loop that `run_shot!` drives. The step boundary is the `update!`
call, not `step_simulation!`, because the fever bucket animation and the
previous-state stamping are part of every fixed step.

**Pass condition.** For a warmed shot, the sum of `Base.gc_bytes()` deltas
around every measured step is 0, and the maximum single-step delta is 0. A
nonzero mean is a failure even if the median is 0.

**Warmup.** Before measurement the engine is reset and the shot is run to
completion (or to the documented step cap) at least three times, so every
container has grown. The measured pass then starts from a fresh reset and
records step deltas from the first step. Capacity reached during warmup does
not count against the gate; allocation after warmup does. Report the
first-shot growth separately (§1.2).

**Observation mode.** Summary mode, tracing disabled (`eng.trace = nothing`),
no snapshots, no result extraction, no JSONL writing, no process startup. The
engine callbacks used by the benchmark must be the same ones the summary
path uses.

**Threading.** Allocation accounting is process-wide, so the gate is measured
single-threaded (`-t 1`) only. Parallel runs measure throughput and are not
part of the gate.

### 1.2 Capacity growth (measured separately, not a failure)

Allocations needed to reach steady state are reported separately and do not
count against §1.1:

- bytes from the first reset on a cold engine to the first steady step for a
  given level and shot length;
- high-water capacities of the journals, command buffers, scratch containers,
  and dictionaries;
- growth after warmup (must be 0; a nonzero value means the capacity estimate
  was wrong and is a finding, not an allowed cost).

Capacity growth is a one-time cost per worker and level/shot-length pair. A
fresh `ShotEngine` per worker pays it once.

### 1.3 Reset (measured separately)

`reset_shot_engine!` is measured as bytes and microseconds per reset. The
target is near-zero, but reset is not the stepping gate: it happens once per
candidate, not once per step. The current cost (~27.8 KB/reset at the start of
session 2) is small next to simulation time, but cheap reductions are still
made and reported.

### 1.4 Launch and other per-shot work

`launch!` (including staged launch events flushed on the next step) is
measured per shot. It is per-shot overhead, not steady-state stepping.
First-step allocation caused by staged launch events is reported as launch,
not silently mixed into the step mean.

### 1.5 Observation overhead (separate)

Tracing and diagnostic snapshots are measured with a separate trace-enabled
run. They are **not** part of the gate. Summary and diagnostic outcomes must
stay identical (the trace corpus is the canary: byte-identical traces and
identical summary fields). Trace encoding, result extraction, JSONL writing,
process startup, and Lua comparison output are excluded from all
allocation figures.

### 1.6 Classification of every allocation site

Every measured byte is classified as one of:

| Class | Meaning | Counts against the gate? |
| --- | --- | --- |
| steady-state | occurs in a warmed per-step loop | **yes** |
| capacity growth | grows a container to its high-water mark | no (reported) |
| reset | `reset_shot_engine!` / `restore!` | no (reported) |
| export-only | trace, snapshot, summary, extraction, JSONL | no (reported) |

The per-site accounting in §4 and `results/m4/allocation-profile.json` uses
these four labels.

### 1.7 What "zero" does not allow

- No change to physics, scoring, RNG, tie-breaking, epsilons, checkpoint
  bytes, or summary outcomes.
- No reordering of authoritative operations to save allocation unless the
  trace bytes prove identical.
- No `@fastmath`, `@simd`, `muladd`, or `fma` (the test suite scans for
  them).
- No conditional skipping of authoritative state updates. Skipping payload
  construction that is observation-only is allowed **only** when the summary
  path and the trace path both remain byte-identical; the trace corpus gates
  that.

## 2. Method

### 2.1 Phase accounting

Allocation accounting uses `Base.gc_bytes()` deltas around a single measured
region, with `GC.gc()` outside the region, matching the established M3
harness (`scripts/allocation_bench.jl`). Phases are measured separately:

- reset: `reset_shot_engine!(eng, ckpt)`;
- launch: `launch!(eng, aim)` after a reset outside the measured region;
- run: `run_shot!` after reset+launch outside the measured region;
- step: `update!` deltas over a stepwise pass, replicating the `run_shot!`
  loop;
- site attribution: `Profile.Allocs` at `sample_rate = 1.0`, warmed, trace
  disabled, aggregated by stack frame.

All phase measurements use one process, one thread, and a warmed engine. Every
measured result is checked against the first warmup summary; a mismatch aborts
the run. Times are `time_ns` medians over samples and are indicative on a
shared host. Allocation bytes are deterministic and are the gate.

### 2.2 Workloads and aims

The allocation profile covers mustache (historical aims 900 and 570), plus
`circles_small`, `lines_rect_annular`, `annular_dense` (1 ball), and one
3-ball workload. Aims are chosen deterministically per workload and recorded
in the profile. The benchmark covers all seven M0 workloads (stride 20, 91
candidates), with the session-1 full grid used as the full-grid reference.

### 2.3 Benchmark protocol

- Grid: 1,801 aim indices (0..1800); timed sweeps use stride 20.
- Julia: one post-warmup pass per thread count, `--verify-serial --alloc`;
  T = 1, 2, 4, 8, 12 capped at `nproc`; serial and parallel rows must be
  bit-identical.
- Lua: frozen pinned tree (`reference/peggle_evolved`), same harness,
  `--stride 20 --repeat 2 --no-replay-serialize`.
- The M3 3-repeat M0 baseline used replay serialization and a different repeat
  count; it is context only, not the comparison.
- Peak memory: `/usr/bin/time -v` maximum resident set size per sweep
  process, plus a per-worker live estimate where cheap. The method is stated
  per field.
- Full-grid throughput comes from the session-1 stride-1 runs and is labelled
  as such.

## 3. Per-workload benchmark

Source: `results/m4/bench-report.json` (`make m4-bench`). Seven M0 workloads,
stride 20 (91 candidates of the 1,801-index grid), Lua timed with
`--stride 20 --repeat 2 --no-replay-serialize`, Julia one post-warmup pass per
thread count with `--verify-serial --alloc`. Same host as §4.

### 3.1 Throughput and latency

| workload | Lua p50 ms | Lua p99 ms | Lua cand/s | Julia t1 p50 ms | Julia t1 p99 ms | Julia t1 cand/s | Julia t12 cand/s | ×Lua (t1) | t12 speedup (eff.) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| overhead_static_2p | 0.76 | 4.34 | 976.9 | 0.076 | 0.50 | 1,025.2 | 999.7 | 1.0× | 0.98× (0.08) |
| circles_small | 1.02 | 6.52 | 687.6 | 0.230 | 0.70 | 901.8 | 950.9 | 1.3× | 1.05× (0.09) |
| circles_mixed | 0.38 | 3.95 | 1,582.8 | 0.079 | 0.42 | 1,014.8 | 976.7 | 0.6× | 0.96× (0.08) |
| lines_rect_annular | 3.57 | 33.50 | 129.8 | 0.474 | 7.80 | 378.3 | 594.6 | 2.9× | 1.57× (0.13) |
| annular_dense | 55.09 | 71.17 | 17.8 | 1.661 | 8.90 | 302.3 | 542.4 | 17.0× | 1.79× (0.15) |
| lines_rect_annular_multi3 | 23.39 | 48.66 | 51.2 | 5.979 | 11.57 | 181.6 | 514.2 | 3.5× | 2.83× (0.24) |
| annular_dense_multi3 | 75.46 | 98.33 | 13.1 | 6.633 | 14.53 | 130.2 | 462.4 | 10.0× | 3.55× (0.30) |

Reading the table:

- Julia wins on the five workloads with real simulation cost (1.3–17×), loses
  on `circles_mixed` (0.6×) and ties on `overhead_static_2p` (1.0×). Those two
  are cheap levels where per-candidate fixed cost dominates and LuaJIT's tight
  JITted loop is hard to beat; the loss is reported, not hidden.
- The `×Lua` column is throughput at Julia T=1 (one worker) against Lua
  single-threaded. It is indicative: Lua is repeat-timed and Julia is one
  pass (see §6).
- Latency columns are not strictly comparable. Lua's figure is its
  `phases.total` (init+reset+sim+extract+output) quantiles averaged over
  repeats; Julia's is `reset+sim+extract` summed from the summary's phase
  quantiles (the summary has no per-phase `max`, so both columns use p99).
  Throughput is the fair comparison.
- Julia throughput is the t1 **parallel** pass, per the harness convention; the
  t1 serial verification pass is faster on small workloads because it avoids
  the parallel dispatch (e.g. `circles_small` 4,071 vs 902 cand/s). Thread
  scaling is therefore measured against t1 parallel, not against serial.
- Thread scaling is bounded by candidate granularity: 91 candidates over up to
  12 threads, and the cheap workloads finish a candidate in microseconds, so
  efficiency at 12 threads is 0.08–0.30 even though wall time still improves.
  The dense and multi-ball workloads scale best (1.8–3.6× on 12 threads, i.e.
  0.15–0.30 per-thread efficiency).

### 3.2 Allocations and peak memory

| workload | Julia alloc p50 B/candidate | alloc mean B/candidate | Lua RSS MB | Julia t1 RSS MB |
| --- | ---: | ---: | ---: | ---: |
| overhead_static_2p | 5,360 | 6,238 | 153.2 | 587.6 |
| circles_small | 10,512 | 11,339 | 156.2 | 571.6 |
| circles_mixed | 8,496 | 9,064 | 154.0 | 570.2 |
| lines_rect_annular | 22,144 | 25,279 | 163.3 | 590.4 |
| annular_dense | 48,368 | 49,176 | 161.4 | 591.5 |
| lines_rect_annular_multi3 | 30,544 | 30,318 | 160.9 | 573.8 |
| annular_dense_multi3 | 49,872 | 50,989 | 163.0 | 574.3 |

These per-candidate bytes cover `reset + launch + run + extract` on the serial
path with an extra untimed warmup pass, so they are dominated by `reset`
(rebuilding the checkpoint's pegs) and are **not** the steady-state gate of
§1.1 — that is §4. Peak RSS is whole-process (runtime + JIT + GC) from
`scripts/bench_process.py`; Julia's larger figure is the runtime and JIT, not
per-worker state, and for threads > 1 it is not a per-worker measure.

- Every Julia thread-count row reports `serial_parallel_identical = true` and
  byte-identical candidate rows across T = 1, 2, 4, 8, 12.
- The stride-20 Lua-vs-Julia row agreement is clean for all seven workloads
  (`bench-sweeps-compare-*.json`, 91/91 candidates), and the full-grid
  reference is the session-1 stride-1 report.
- **Baseline delta.** The pre-change tree had no same-protocol throughput run,
  so the honest baseline is the allocation profile: mustache 570 fell from
  3,945 B/step to 21.5 B/step (≈183× less allocation in the step loop) at the
  same authoritative outcome. Throughput should be read as absolute numbers
  against Lua above, not as a before/after ratio.

## 4. Allocation accounting

Source: `results/m4/allocation-profile.json` (single thread, trace disabled,
`Base.gc_bytes()` deltas with `GC.gc()` outside every measured region, three
warmup shots per aim, step cap 4000). Reproduce with §8.

### 4.1 Phase totals

| workload | aim | reset B | launch B | steady total B | steps | B/step | max step B | nonzero steps | §1.1 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| circles_small | 900 | 8,784 | 0 | 0 | 202 | 0.000 | 0 | 0 / 202 | **pass** |
| annular_dense | 900 | 46,192 | 0 | 0 | 284 | 0.000 | 0 | 0 / 284 | **pass** |
| lines_rect_annular | 900 | 19,536 | 0 | 8,544 | 768 | 11.125 | 4,352 | 2 / 768 | fail |
| mustache | 900 | 25,360 | 0 | 13,824 | 922 | 14.993 | 5,136 | 5 / 922 | fail |
| mustache | 570 | 29,688 | 0 | 38,712 | 1,797 | 21.543 | 4,328 | 13 / 1,797 | fail |

`p50` and `p99` are 0 B for every row: the non-zero steps are the handful that
first emit a given command or event kind, not a per-step tax. Launch is 0 B
everywhere, and the steady-state median step allocates nothing.

**Verdict.** The gate passes strictly on `circles_small` and `annular_dense`.
It does **not** pass on `mustache` (both aims) or `lines_rect_annular`: those
perform 2–13 allocating steps out of 768–1,797. Those steps are the
"remaining in-scope sites with bytes/step and a plan" case in §1.6, not a
silent pass; §4.3 lists them.

### 4.2 What was removed

Measured before/after on the same host and method (mustache 570 is the
longest shot, 1,797 steps, and dominated the totals):

| workload | aim | before B/step | after B/step | removed |
| --- | ---: | ---: | ---: | ---: |
| mustache | 900 | 304 | 15.0 | 289 |
| mustache | 570 | 3,929 | 21.5 | 3,908 |
| circles_small | 900 | 119 | 0.0 | 119 |
| lines_rect_annular | 900 | 455 | 11.1 | 444 |
| annular_dense | 900 | 133 | 0.0 | 133 |

Four causes, all behavioural no-ops:

1. **Union-typed journal payload.** `GameEvent.fields` was
   `Union{Dict{String,Any},ContactPayload}`, so every contact boxed its payload
   (288 B/event) and every scalar read boxed again. Replaced by the concrete
   `EventFields` superset (`julia/PeggleSim/src/event_fields.jl`), with line
   metadata flattened into `line_meta_*` and re-materialized only at the export
   boundary.
2. **`in(::String, ::Tuple)`.** `_contact_can_score` tested
   `kind in SCORING_CONTACT_KINDS`; `in` over a tuple of `String`s builds
   argument tuples through `tail`, allocating ~40 B per test — by itself 93 B
   per step on mustache 570 (≈ 269 KB per shot). Replaced by an explicit
   disjunction over the same four literals.
3. **`Dict{...,Any}` tracker state.** Style-shot and slide-inversion trackers
   stored `Float64`/`Int`/`Bool` in `Any` slots, boxing on every store. Every
   tracker map and per-(ball, line) payload is now concrete (`StyleLastImpact`,
   `StyleSlideRun`, `SlideTrack`, `SlideHitRecord`, `Dict{Int,Float64}`, …).
4. **Per-shot tracker recreation.** `restore!` did
   `sim.trackers = deepcopy(ckpt.trackers)`, discarding the reuse pools and dict
   capacities every shot, so warmup could never pay off. It now restores into
   the live containers (`_restore_trackers!`), which also cut reset from 27.8 →
   25.4 KB (mustache 900) and 32.2 → 29.7 KB (mustache 570).

Reuse pools (`run_pool`, `award_pool`, `by_line_pool`, `track_pool`,
`hits_pool`) are reset by index at `reset_shot!`, so a warmed repeat of the same
aim hands the same objects back out instead of allocating new ones.

### 4.3 Remaining sites (in-scope, with plan)

`Profile.Allocs` at `sample_rate = 1.0` over the warmed step loop; site bytes
are profiler payload (91.7–92.6 % of `gc_bytes`, GC headers/padding are
unattributed) and must not be summed to the gate total.

| site | B/step (570) | B/step (900) | B/step (slide) | classification | plan |
| --- | ---: | ---: | ---: | --- | --- |
| `engine.jl:613` `apply_commands!` | 4.897 | 2.863 | 2.292 | in-scope | pool/reuse the derived `EventFields` per command kind |
| `events.jl:80` `_copy_payload` | 3.561 | 2.777 | 1.667 | in-scope | typed command payload removes the dict copy |
| `events.jl:270` `push_command!` | 2.974 | 2.317 | 1.385 | in-scope | typed `GameplayCommand` struct (same pattern as `EventFields`) |
| `slide_inversion.jl:232` | 2.644 | 0.573 | 0.688 | in-scope | typed command + reused `peg_ids` scratch |
| `style_shots.jl:106` | 2.391 | 0.312 | — | capacity growth | pre-size `run_pool` from the first shot |
| `engine.jl:569` `apply_commands!` | — | 0.972 | 1.167 | in-scope | same derived-payload pooling |
| `engine.jl:485` `start_clearing!` | 0.855 | 0.156 | — | in-scope | fill a reused `clear_queue` instead of a comprehension |
| `events.jl:84` `_copy_payload` | 0.570 | 0.347 | 0.396 | in-scope | no copy for producer-owned vectors |

All of these are command emission/application or clearing; none is physics,
scoring, RNG, or trace. The prescribed fix for the cluster (~10 B/step at
mustache 570) is one refactor: give `GameplayCommands` a concrete payload type
exactly as the journal got `EventFields`. That is session-3 work, tracked here
so the gate is not reported as met.

**Commands are deliberately excluded** from the gate: `GameplayCommands`
payloads are exported to Lua and deep-copied at push time (a documented
ownership boundary, covered by tests). The gate as written covers the journal
and the step loop; that boundary is why the residual is where it is.

## 5. Diagnostic overhead

Measured on `circles_small` (91 candidates, T=1): one pass traced with
`--trace-dir`, one untraced, same stride/level/balls.

| metric | value |
| --- | --- |
| result rows | byte-identical (same SHA-256 for traced and untraced) |
| untraced throughput | 2,212.7 candidates/s |
| traced throughput | 452.3 candidates/s |
| traced/untraced throughput | 0.204 (≈4.9× slower per candidate) |
| process wall seconds | +1.2 % (the sweep's wall time is dominated by candidate count, not by this pass) |
| trace volume | 187.4 bytes per simulated step |

Tracing changes no result field, which is the point: the trace path is
observation-only, and the main table in §3 is untraced. The 4.9× per-candidate
figure is the cost of the trace writer, not of the engine.

## 6. Caveats

- Same-host comparison only; no cross-machine claim is made in session 2.
- `circles_mixed` and `overhead_static_2p` are Julia-slower or Julia-even:
  per-candidate fixed cost dominates on cheap levels. Not a regression against
  a measured baseline (none exists at this protocol), but not a win either.
- Allocation accounting is process-wide, so it is single-threaded.
- Stride-20 samples are 91 candidates; long shots dominate p99/max.
- Julia and Lua are timed with different repeat counts; the same-core speedup
  is indicative, as in M3.
- `spawned` is not a shared sweep field; the multiball trace fixture covers
  spawn behavior.

## 7. Gates

All gates were run on the final tree for this session (HEAD plus the
session-2 working-tree changes).

| Gate | Result |
| --- | --- |
| `make verify` | 133/133 reference files match `reference/files.sha256` |
| `make julia-test` | 5,616 / 5,616 |
| `make m3-mustache` | 5/5 traces byte-identical; `expected_records_identical = true` |
| `make m4-parity` | fixtures 14/14, traces 6/6, sweeps 7/7, scenarios 11/11, `overall_pass = true` |
| `make m4-bench` | 7/7 workloads complete, 0 failed runs, serial/parallel identical at every thread count |
| allocation profile | `results/m4/allocation-profile.json`, reproducible byte-for-byte |

Two gate findings from session 2 worth keeping visible:

1. A tracker-state leak in `_restore_trackers!` was invisible to
   `make julia-test` and to the byte-identical trace corpus, but failed 5 of
   1,801 candidates in `lines_rect_annular_multi3`. The full-grid sweep is what
   caught it; the fix resets each sub-tracker before restoring.
2. A reuse pool for per-ball slide-run maps was unsound (a cleared map could be
   handed to a second ball while the first still referenced it). It was removed
   rather than patched; the pool now covers only objects that are created once
   and never re-pushed (`run_pool`, `award_pool`, `track_pool`, `hits_pool`).

## 8. Reproduction

```bash
scripts/m4_allocation.jl --workload all --out results/m4/allocation-profile.json
make m4-bench
```

Exact commands, host, and measured revisions are recorded in the result JSON
and in §3/§4 when filled.
