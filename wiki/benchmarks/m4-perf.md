# M4 performance gate

Measured steady-state cost of the Julia shot engine across the seven M0
workloads, the zero-allocation criterion for warm fixed-capacity stepping, the
allocation accounting behind it, the same-host Lua comparison, and the
session-3 strict-zero and second-host closeout.

- Status: **session 3 of 3 complete; M4 is closed**.
- Correctness anchor: the session-1 corpus (`results/m4/parity-summary.json`,
  `overall_pass = true`; 14/14 fixtures, 6/6 traces, 7/7 sweeps, 11/11
  scenarios) plus the gates in §7.
- Producers: `scripts/bench_m4.sh` (`make m4-bench`),
  `scripts/m4_allocation.jl`, and `scripts/m4_cross_machine.py`.
- Results: `results/m4/bench-report.json`,
  `results/m4/allocation-profile.json`, and the cross-machine comparison
  (`results/m4/cross-machine.json`, sha256
  `685a1687c8d95710f174478309d237382485698109f0394eacd5c13c8ec79703`).
- Hosts: omarchy, AMD Ryzen 5 4600H (6 cores / 12 threads), Linux, Julia
  1.12.6, LÖVE 11.5.0, LuaJIT 2.1, math backend `system_libm`; session-3
  second host deathstar, AMD Ryzen Threadripper 2990WX (32 cores / 64
  threads), Ubuntu 22.04, glibc 2.35.

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
`circles_small`, `lines_rect_annular`, and `annular_dense` (all 1 ball). Aims
are chosen deterministically per workload and recorded in the profile. The
benchmark covers all seven M0 workloads (stride 20, 91 candidates), with the
session-1 full grid used as the full-grid reference.

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

Source: `results/m4/bench-report.json` (`make m4-bench`, session-3 re-run).
Seven M0 workloads, stride 20 (91 candidates of the 1,801-index grid), Lua timed with
`--stride 20 --repeat 2 --no-replay-serialize`, Julia one post-warmup pass per
thread count with `--verify-serial --alloc`. Same host as §4.

### 3.1 Throughput and latency

| workload | Lua p50 ms | Lua p99 ms | Lua cand/s | Julia t1 p50 ms | Julia t1 p99 ms | Julia t1 cand/s | Julia t12 cand/s | ×Lua (t1) | t12 speedup (eff.) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| overhead_static_2p | 0.76 | 4.66 | 948.0 | 0.073 | 0.60 | 925.3 | 886.4 | 0.98× | 0.96× (0.08) |
| circles_small | 0.90 | 6.60 | 715.7 | 0.267 | 0.81 | 850.4 | 1,119.4 | 1.19× | 1.32× (0.11) |
| circles_mixed | 0.41 | 3.79 | 1,437.9 | 0.079 | 0.38 | 994.8 | 1,034.9 | 0.69× | 1.04× (0.09) |
| lines_rect_annular | 3.70 | 39.45 | 121.7 | 0.486 | 8.17 | 366.5 | 610.5 | 3.01× | 1.67× (0.14) |
| annular_dense | 61.26 | 78.00 | 16.2 | 1.756 | 9.17 | 292.3 | 652.0 | 18.02× | 2.23× (0.19) |
| lines_rect_annular_multi3 | 24.82 | 49.88 | 48.8 | 6.182 | 11.87 | 177.5 | 564.5 | 3.64× | 3.18× (0.26) |
| annular_dense_multi3 | 67.28 | 94.57 | 14.6 | 6.884 | 14.99 | 126.3 | 447.8 | 8.64× | 3.54× (0.30) |

Reading the table:

- Julia wins on the five workloads with real simulation cost (1.2–18.0×). The
  two cheap rows moved slightly: `circles_mixed` 0.641 → 0.692× (still below
  Lua) and `overhead_static_2p` 1.049 → 0.976× (now just under 1.0×). Both are
  the report's own indicative, not benchmark-grade, ratios; they are reported,
  not hidden. Those two are cheap levels where per-candidate fixed cost
  dominates and LuaJIT's tight JITted loop is hard to beat.
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
  the parallel dispatch (e.g. `circles_small` 3,412 vs 850 cand/s). Thread
  scaling is therefore measured against t1 parallel, not against serial.
- Thread scaling is bounded by candidate granularity: 91 candidates over up to
  12 threads, and the cheap workloads finish a candidate in microseconds, so
  efficiency at 12 threads is 0.08–0.30 even though wall time still improves.
  The dense and multi-ball workloads scale best (2.2–3.5× on 12 threads, i.e.
  0.19–0.30 per-thread efficiency).

### 3.2 Allocations and peak memory

| workload | Julia alloc p50 B/candidate | alloc mean B/candidate | Lua RSS MB | Julia t1 RSS MB |
| --- | ---: | ---: | ---: | ---: |
| overhead_static_2p | 5,360 | 6,156 | 120.8 | 616.0 |
| circles_small | 10,512 | 11,056 | 123.6 | 612.0 |
| circles_mixed | 8,496 | 8,983 | 121.3 | 602.0 |
| lines_rect_annular | 21,264 | 22,505 | 130.2 | 601.9 |
| annular_dense | 47,920 | 48,449 | 128.7 | 599.3 |
| lines_rect_annular_multi3 | 21,440 | 22,790 | 129.1 | 602.2 |
| annular_dense_multi3 | 48,080 | 48,970 | 131.4 | 597.4 |

These per-candidate bytes cover `reset + launch + run + extract` on the serial
path with an extra untimed warmup pass, so they are dominated by `reset`
(rebuilding the checkpoint's pegs) and are **not** the steady-state gate of
§1.1 — that is §4. Peak RSS is whole-process (runtime + JIT + GC) from
`scripts/bench_process.py` (now ported to `scripts/bench_process.jl`; the
measurement method is unchanged); Julia's larger figure is the runtime and JIT,
not per-worker state, and for threads > 1 it is not a per-worker measure.

Mean per-candidate allocation is informational, not the §1.1 gate; it fell on
all seven workloads (e.g. `lines_rect_annular_multi3` 30,318 → 22,790
B/candidate, -24.8%; `lines_rect_annular` -11.0%).

- Every Julia thread-count row reports `serial_parallel_identical = true` and
  byte-identical candidate rows across T = 1, 2, 4, 8, 12 (`35/35` rows in the
  session-3 run).
- The stride-20 Lua-vs-Julia row agreement is clean for all seven workloads
  (`bench-sweeps-compare-*.json`, 91/91 candidates), and the full-grid
  reference is the session-1 stride-1 report.
- **Baseline delta.** The pre-change tree had no same-protocol throughput run,
  so the honest baseline is the allocation profile: mustache 570 fell from
  3,929 B/step at the start of session 2 to strict zero in session 3 (§4.2,
  §4.1) at the same authoritative outcome. Throughput should be read as
  absolute numbers against Lua above, not as a before/after ratio.

## 4. Allocation accounting

Source: `results/m4/allocation-profile.json` (single thread, trace disabled,
`Base.gc_bytes()` deltas with `GC.gc()` outside every measured region, three
warmup shots per aim, step cap 4000). Reproduce with §8.

### 4.1 Phase totals

| workload | aim | reset B | launch B | steady total B | steps | B/step | max step B | nonzero steps | §1.1 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| circles_small | 900 | 8,784 | 0 | 0 | 202 | 0.000 | 0 | 0 / 202 | **pass** |
| annular_dense | 900 | 46,192 | 0 | 0 | 284 | 0.000 | 0 | 0 / 284 | **pass** |
| lines_rect_annular | 900 | 19,536 | 0 | 0 | 768 | 0.000 | 0 | 0 / 768 | **pass** |
| mustache | 900 | 25,360 | 0 | 0 | 922 | 0.000 | 0 | 0 / 922 | **pass** |
| mustache | 570 | 29,688 | 0 | 0 | 1,797 | 0.000 | 0 | 0 / 1,797 | **pass** |

All five probes meet §1.1 strictly: the sum **and** the maximum single-step
delta are 0, not a median or an average. `Profile.Allocs` at
`sample_rate = 1.0` over the same warmed loops records **zero allocation
sites** on every row (the profile's `sites` arrays are empty, not filtered), so
there is no residual site to classify, itemize, or plan around. Launch is 0 B
everywhere. Reset is unchanged by this session (8,784 / 46,192 / 19,536 /
25,360 / 29,688 B) and remains reported separately per §1.3.

Before/after on the same host and method (before = clean worktree at
`6544414`, measured in session 3 so both columns describe the same tree
history; after = this session):

| probe | before B/step | before max B | before nonzero | after B/step | after max B |
| --- | ---: | ---: | ---: | ---: | ---: |
| circles_small 900 | 0.000 | 0 | 0 / 202 | 0.000 | 0 |
| annular_dense 900 | 6.310 | 448 | 4 / 284 | 0.000 | 0 |
| lines_rect_annular 900 | 16.958 | 4,352 | 12 / 768 | 0.000 | 0 |
| mustache 900 | 16.121 | 5,136 | 7 / 922 | 0.000 | 0 |
| mustache 570 | 27.112 | 4,192 | 42 / 1,797 | 0.000 | 0 |

### 4.2 Session 2: what was removed

Measured before/after in session 2 on that session's working tree (mustache 570
was the longest shot, 1,797 steps, and dominated the totals):

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

The session-2 table is retained as the session-2 measurement; it was captured
on the pre-final working tree and its numbers do not reproduce at `6544414`
(§4.5). The session-3 column of §4.1 is the one that describes the commit.

### 4.3 Session 3: the command-path cluster

The residue that session 2 left was one coherent cluster: command emission and
application, plus the style-shot slide-run map churn that the final session-2
change (removing an unsound reuse pool, §7 finding 2) had moved into the
per-bounce path. The per-site B/step values are `Profile.Allocs` profiler
payload, not gate bytes — the profile's `attributed_to_measured_ratio` is 0.910
(≈91% of `gc_bytes`) — so they are not summed into the §1.1 gate.

The sites measured at `6544414` with the same `Profile.Allocs` method (mustache
570 unless noted):

| site | B/step (570) | classification | fix |
| --- | ---: | --- | --- |
| `style_shots.jl:133` `by_line[key] = run` | 5.698 | steady-state | per-ball slide-run map cache; keys persist |
| `engine.jl:613` `apply_commands!` `EventFields` | 4.897 | steady-state | typed command records make the emit type-stable |
| `events.jl:80` `_copy_payload` (push) | 3.561 | steady-state | no payload copy on the push path |
| `events.jl:272` `push_command!` `Dict` | 2.974 | steady-state | concrete `GameplayCommand` record |
| `slide_inversion.jl:232` command `Dict` | 2.644 | steady-state | typed `remove_slide_pegs` push |
| `style_shots.jl:115` new run map | 1.425 | steady-state | same map cache |
| `events.jl:78` `_copy_payload` dict | 0.890 | steady-state | export-only copy |
| `engine.jl:485` `start_clearing!` comprehension | 0.855 | steady-state | reused `clear_lit` + in-place sort |
| `events.jl:84` `_copy_payload` vector | 0.570 | steady-state | pooled `source_sequences` |
| `style_shots.jl:217/216/213` award pushes (900 only) | 0.616 | steady-state | typed award pushes |
| `state.jl:88` `BallState` (power spawn) | 0.267 | steady-state | recycled spawn objects |
| `ball_state.jl:134/121` clearing commands | 0.223 | steady-state | typed `start_midturn_clearing` |
| `engine.jl:486` `sort!` scratch | 0.223 | steady-state | `InsertionSort` (stable, in place) |
| `slide_inversion.jl:126` `_si_lowest_hit_pegs` | 0.200 | steady-state | pooled `peg_ids` scratch |
| `slide_inversion.jl:0` `_si_lowest_hit_pegs` (inlined) | 0.160 | steady-state | same |
| `engine.jl:608` `apply_commands!` `remove_slide_pegs` | 0.080 | steady-state | typed `remove_slide_pegs` slot |
| `engine.jl:621` `apply_commands!` `remove_slide_pegs` | 0.009 | steady-state | same |
| `engine.jl:554` `_present_payload` dict | 0.347 (900) | steady-state | reused `StyleInfo` callback view |
| `engine.jl:581` `copy(seqs)` for callback | 0.304 (900) | steady-state | same |

The refactor, in the order the ownership boundary moves:

1. **Commands got the `EventFields` treatment.** `GameplayCommands.commands` and
   `.applied` are `Vector{GameplayCommand}`: a concrete record with the
   envelope (`type`, `step`, `shot_id`, `sequence`) and one typed slot per
   payload key the engine emits (`ball_id`, `style`, `points`, `distance`,
   `peg_id`, `line_id`, `reason`, `source_sequences`, `peg_ids`, plus `status`
   for applied records and a cold `extra` slot). It is a read-only
   `AbstractDict{String,Any}` view, so consumers that used the dictionary form
   still work.
2. **The deep copy moved to the export boundary, it was not deleted.**
   `push_command!` still detaches caller-owned dictionary input (typed slots or
   a copied `extra`), and `command_snapshot` / `applied_snapshot` / the trace
   step record still materialize detached `Dict{String,Any}` payloads with the
   identical key set, value types and (sorted) trace bytes. The engine's own
   emitters push typed records through `push_style_award!`,
   `push_start_midturn_clearing!` and `push_remove_slide_pegs!`; the
   `source_sequences`/`peg_ids` vectors come from per-buffer pools that are
   rewound per step and never mutated after the push.
3. **The derived event stopped being boxed.** The old `apply_commands!` read
   `Any` out of a `Dict`, so the `style_awarded`/`slide_peg_removed`
   `EventFields` could not be inferred and was heap-allocated (~270 B) on every
   applied command. With typed reads the constructor stays unboxed and
   `emit_derived!` is `@inline`d, so those events cost nothing.
4. **The style callback got a reusable view.** `on_style_shot` is a dynamically
   typed function field, so passing a fresh `Dict` boxed every scalar and
   passing an immutable struct boxed the struct itself. It now receives
   `eng.style_info`, a mutable `StyleInfo` filled in place, which exposes
   exactly the keys the old detached dictionary carried.
5. **Clearing reuses one list.** `start_clearing!` fills `eng.clear_lit`
   (handed to `e.clear_queue` and drained to empty by `update_clearing!`) and
   sorts it in place with `InsertionSort` — stable, like the default algorithm,
   and allocation-free. Spawned balls are recycled from `eng.spawn_pool`
   instead of constructing a new `BallState` per power spawn.
6. **Slide-run maps survive the shot.** A ball holds either a live map in
   `slide_runs` or a zeroed one in `slide_cache`, never both:
   `_style_clear_ball_slide!` deletes the live map and parks it,
   `_style_run_tab!` removes it from the cache before it goes live, and
   `reset_shot!` reclaims live maps into the cache. `run_pool` is a monotonic
   registry and is deliberately **not** rewound: a pooled run object is handed
   out at most once and then owned by its (ball, line) map, so rewinding could
   alias two lines onto one object (the session-2 failure mode in a new
   disguise). The pool therefore grows only with the number of distinct
   (ball, line) pairs ever played, which is bounded by the level.

### 4.4 Remaining sites

None. Every measured step allocates nothing on all five probes, so there is no
residual site to classify with bytes/step or a plan. The classification
vocabulary of §1.6 is unchanged and still describes any future residue; the
profile schema still reports per-site classification when sites exist.

### 4.5 Reproducibility finding: the session-2 committed profile is stale

The `results/m4/allocation-profile.json` committed in session 2 was captured at
`b8e94f0` with a **dirty** `julia/PeggleSim/src` (`src_jl_sha256
0631c714…`), before the final session-2 changes. It does not reproduce at
`6544414` (clean, `src_jl_sha256 df16438b…`):

| probe | session-2 profile | re-measured at 6544414 | session-2 verdict | re-measured verdict |
| --- | ---: | ---: | --- | --- |
| circles_small 900 | 0.000 | 0.000 | pass | pass |
| annular_dense 900 | 0.000 | 6.310 | pass | fail (4 steps) |
| lines_rect_annular 900 | 11.125 | 16.958 | fail | fail |
| mustache 900 | 14.993 | 16.121 | fail | fail |
| mustache 570 | 21.543 | 27.112 | fail | fail |

Root cause: the unsound per-ball slide-run map pool was removed after the
profile was captured (§7 finding 2), which moved the `style_shots` map
creation/insertion into the per-bounce path — ~7 B/step of profiler payload on
mustache 570 (≈5.6 B/step measured; the removed pool also carried 2.391 B/step)
and enough new allocating steps to fail `annular_dense`. So the session-2 page's
"the gate passes strictly on `circles_small` and `annular_dense`" describes the
pre-final tree, not the committed one; at `6544414` only `circles_small`
passed. This session's measurements are the committed ones, and they are a
strict zero on all five probes, so the gate is met on the final tree
(`4ae588d`), not at `6544414` — but the discrepancy is recorded rather than
quietly replaced.

## 5. Diagnostic overhead

Session-3 measurement on `circles_small` (91 candidates, T=1): one pass traced
with `--trace-dir`, one untraced, same stride/level/balls.

| metric | value |
| --- | --- |
| result rows | byte-identical (same SHA-256 `ea7c1a2f…`, unchanged from session 2) |
| untraced throughput | 2,906.7 candidates/s |
| traced throughput | 348.5 candidates/s |
| traced/untraced throughput | 0.120 (≈8.3× slower per candidate) |
| process wall seconds | +9.3 % (14.83 s vs 13.57 s, including Julia startup and run-to-run variance; the measured pass adds 0.23 s) |
| trace volume | 187.4 bytes per simulated step |

Tracing changes no result field, which is the point: the trace path is
observation-only, and the main table in §3 is untraced. The traced and untraced
rows are identical (same SHA-256) even though the traced pass is slower; the
8.3× per-candidate figure is the cost of the trace writer, not of the engine.

## 6. Caveats

- Throughput and latency are same-host comparisons only. Session 3 adds
  cross-machine corpus parity on a second host, same OS; it is not a
  throughput comparison and makes no second-OS claim.
- On the cheap levels (`circles_mixed`, `overhead_static_2p`) per-candidate
  fixed cost dominates and LuaJIT is hard to beat; the comparison is reported
  in §3. That is a reported loss/tie, not a regression against a measured
  baseline (none exists at this protocol).
- Cross-platform scope: the second host runs the same OS; the macOS ARM64 and
  Windows x86-64 rows in `wiki/context/cross-platform-qualification.md` remain
  uncollected and are not claimed.
- Allocation accounting is process-wide, so it is single-threaded.
- Stride-20 samples are 91 candidates; long shots dominate p99/max.
- Julia and Lua are timed with different repeat counts; the same-core speedup
  is indicative, as in M3.
- `spawned` is not a shared sweep field; the multiball trace fixture covers
  spawn behavior.

## 7. Gates

All gates were run on the final session-3 tree (commit `4ae588d`, source tree
clean; the report's `git_dirty` flag reflects uncommitted result files).

| Gate | Result |
| --- | --- |
| `make verify` | 133/133 reference files match `reference/files.sha256` |
| `make julia-test` | 5,617 / 5,617 |
| `make m3-mustache` | 5/5 traces byte-identical; `expected_records_identical = true` |
| `make m4-parity` | fixtures 14/14, traces 6/6 byte-identical, sweeps 7/7, scenarios 11/11, `overall_pass = true` |
| `make m4-bench` (session-3 re-run) | 7/7 workloads complete, 0 failed runs, 35/35 thread rows `serial_parallel_identical = true`, Lua stride-20 and full-grid agreement clean; serial median -2.5%, no systematic throughput change |
| allocation gate | `results/m4/allocation-profile.json`; strict zero on all five probes (sum and max 0; zero sites) |
| cross-machine | deathstar vs omarchy; 3/3 reports, 9/9 candidate rows, 11/11 summaries, parity manifests equal; `results/m4/cross-machine.json` sha256 `685a1687c8d95710f174478309d237382485698109f0394eacd5c13c8ec79703`; `complete=true`, scope `second host, same OS` |

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
make verify
make julia-test
make m3-mustache
make m4-parity
scripts/m4_allocation.jl --workload all --out results/m4/allocation-profile.json
make m4-bench
python3 scripts/m4_cross_machine.py --left-root tmp/cross-machine-local \
  --right-root tmp/cross-machine-deathstar --out results/m4/cross-machine.json
scripts/compare_parity.sh results/core-math/qualification/linux-x86_64.json \
  results/core-math/qualification/linux-x86_64-deathstar.json
```

Exact commands, hosts, and measured revisions are recorded in the result JSON
(`git_head`, `src_jl_sha256`, `dirty`), the benchmark report, and the
cross-machine comparison.
