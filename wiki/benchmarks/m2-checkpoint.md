# M2 checkpoint benchmark

Measured cost of building a ready-to-aim state once, capturing it as a
checkpoint, and resetting a worker from it, for all 9 M2 configurations
(8 static levels, plus `slide` with 3 balls). The point of the checkpoint is
to replace the M0 per-candidate `setupLevel` rebuild with a small restore.

- Results file: `results/m2-checkpoint-bench.json`
- Producer: `julia/PeggleSim/bin/checkpoint_bench.jl` (`make julia-bench`)
- Baseline source: `results/20261003T093826Z_omarchy.summary.json`
  (`wiki/benchmarks/baseline-metrics.md`)
- Host: AMD Ryzen 5 4600H, 12 threads, Linux, Julia 1.12.6, glibc 2.44

## 1. Method

Per configuration the script performs an untimed warmup of the
build/capture/reset paths, then one timed `build_sim_state` call, 200 timed
`capture_checkpoint` calls after 20 warmups, and 200 timed
`reset_worker!(worker, checkpoint)` calls after 20 warmups, using `time_ns`.
Allocations are measured with one `Base.@allocated` call per operation.
Checkpoint and scratch sizes are `Base.summarysize`. The output is
date-free and host-free; percentiles are nearest-rank over the recorded
nanoseconds. One build sample means the `build_us` column is indicative, not
a distribution.

## 2. Per-configuration results

Times in microseconds; p50/p90 from 200 iterations. `ckpt B` is the
checkpoint size in bytes; `scratch B` is the worker scratch (constant
132,384 B); `worker B` is the total worker size.

| Configuration | Balls | Pegs | build | cap p50 | cap p90 | reset p50 | reset p90 | ckpt B | scratch B | worker B | reset/build |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `circle_level` | 1 | 25 | 17.67 | 6.71 | 9.36 | 6.64 | 8.66 | 6,213 | 132,384 | 140,540 | 0.376 |
| `double_long_shot` | 1 | 12 | 32.41 | 5.31 | 6.22 | 5.80 | 6.22 | 4,417 | 132,384 | 138,096 | 0.179 |
| `long_shot` | 1 | 2 | 11.80 | 4.75 | 5.24 | 5.66 | 5.80 | 3,130 | 132,384 | 136,457 | 0.479 |
| `lucky_bounce` | 1 | 15 | 14.18 | 5.24 | 5.66 | 6.15 | 6.57 | 4,869 | 132,384 | 138,572 | 0.434 |
| `off_the_wall` | 1 | 16 | 13.13 | 5.66 | 5.87 | 5.80 | 6.22 | 4,989 | 132,384 | 138,700 | 0.442 |
| `slide` | 1 | 73 | 17.60 | 9.92 | 11.80 | 8.52 | 9.08 | 17,017 | 132,384 | 152,816 | 0.484 |
| `squiggly_circle` | 1 | 192 | 116.42 | 17.74 | 22.42 | 13.90 | 26.82 | 41,024 | 132,384 | 184,303 | 0.119 |
| `super_long_shot` | 1 | 2 | 12.29 | 4.82 | 5.80 | 7.26 | 8.03 | 3,136 | 132,384 | 136,463 | 0.591 |
| `slide.multiball3` | 3 | 73 | 19.97 | 7.05 | 7.61 | 8.59 | 9.15 | 17,177 | 132,384 | 153,008 | 0.430 |

Summary over the 9 configurations: build median 17.60 µs, capture p50 median
5.66 µs, reset p50 median 6.64 µs, median reset/build 0.38.

## 3. Comparison against the M0 Lua per-candidate init

M0 rebuilt the level per candidate (`setupLevel`); the M2 design pays build
and capture **once per checkpoint** and then only reset per candidate. The
benchmark maps 6 configurations to their M0 workloads. M0 `init p50` below is
the median of the three baseline repeats, exactly as stored in
`results/m2-checkpoint-bench.json`; the Julia reset is the M2 p50 above.

| M2 configuration | M0 workload | M0 init p50 (µs) | Julia reset p50 (µs) | Speedup |
| --- | --- | ---: | ---: | ---: |
| `circle_level` | `circles_small` | 109 | 6.64 | 16.4× |
| `long_shot` | `overhead_static_2p` | 53 | 5.66 | 9.4× |
| `off_the_wall` | `circles_mixed` | 66 | 5.80 | 11.4× |
| `slide` | `lines_rect_annular` | 964 | 8.52 | 113× |
| `slide.multiball3` | `lines_rect_annular_multi3` | 1,051 | 8.59 | 122× |
| `squiggly_circle` | `annular_dense` | 81,948 | 13.90 | **5,896×** |

The dense annular case is the headline: M0 spent ~82 ms rebuilding 192
annular pegs per candidate; M2 restores the checkpoint in ~14 µs. Even
charging the one-off build (116 µs) and capture (17.7 µs) to every candidate
would still be ~32 µs, roughly 2,500× below the M0 init. The no-blue levels
(`double_long_shot`, `super_long_shot`) have no M0 mapping because the M0
workload set does not include them.

Caveats:

- Single build sample per configuration; treat `build_us` as indicative.
- M0 and M2 numbers come from the same throttled laptop, not a dedicated
  benchmark host. The M0 repeats show thermal drift (annular_dense init p50
  rose from 81 ms to 122.6 ms on repeat 3); the M0 column uses the median of
  repeats to damp that.
- Reset p90 on `squiggly_circle` (26.8 µs) is noticeably above p50 (13.9 µs);
  tail latency matters and is reported, not averaged away.
- Capture and reset still allocate per call (see §4); the M4 target is
  zero-allocation warm stepping.
- Reset alone is not the full candidate cost: M3 adds physics, simulation,
  and result extraction, which this benchmark does not measure.

## 4. Allocations

Per-call allocation over the captured bytes (`Base.@allocated`, one call per
configuration):

| Configuration | capture B | reset B |
| --- | ---: | ---: |
| `circle_level` | 7,848 | 9,264 |
| `double_long_shot` | 6,080 | 7,392 |
| `long_shot` | 4,736 | 5,952 |
| `lucky_bounce` | 6,576 | 7,824 |
| `off_the_wall` | 6,616 | 7,968 |
| `slide` | 14,488 | 16,176 |
| `squiggly_circle` | 30,584 | 33,312 |
| `super_long_shot` | 4,736 | 5,952 |
| `slide.multiball3` | 14,648 | 16,336 |

Allocation scales with peg count (copying pegs, queue, and balls), as
expected for the copy-on-capture/copy-on-restore ownership rule. This is the
M2 baseline the M4 zero-allocation work is measured against.
