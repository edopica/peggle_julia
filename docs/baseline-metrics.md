# M0 baseline metrics

Measured throughput of the pinned Lua reference evaluating the full legal aim
grid from a ready-to-aim decision boundary. This is the Lua side of the
continuing "same-core speedup over current Lua" metric.

## Run identity

| Field | Value |
| --- | --- |
| Run id | `20261003T093826Z` |
| Date (UTC) | 2026-10-03T09:38:27Z |
| Reference | `d17f6e7089b6e761f4367fc6a6dcd5b4da0309b9` |
| Config SHA-256 | `455757c900c604563865b5195eda2f31cfeba3d8666b6d782390e38c47e91d4d` |
| Host | AMD Ryzen 5 4600H (6C/12T), 15.3 GiB RAM, Omarchy (Linux 7.2.5) |
| Runtime | LuaJIT 2.1.1788460057 under LÖVE 11.5, JIT enabled |
| Grid | 1801 indices, snapping mismatches = 0 |
| Options | `max_steps=3600`, `clearing=off`, `replay_serialize=on`, `warmup=8`, `repeat=3` |
| Output | `results/20261003T093826Z_omarchy.summary.json` (+ raw JSONL in `results/raw/`, gitignored) |
| Total | 37,821 candidates, 37,821 completed, 0 incomplete, 1570 s, **24.1 candidates/s** |

Regenerate with `scripts/run_baseline.sh --repeat 3`; render with
`scripts/render_summary.py results/RUN.summary.json`.

## Per-workload results (repeat 1)

Phase times are per-candidate microseconds (p50/p90 nearest-rank). `steps/s`
is simulated fixed steps per wall second during the `sim` phase.

| Workload | Balls | init p50 | reset p50 | sim p50 | sim p90 | sim max | extract p50 | output p50 | steps max | cand/s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `overhead_static_2p` | 1 | 53 | 2 | 559 | 1754 | 5855 | 1 | 9 | 541 | 1008 |
| `circles_small` | 1 | 142 | 3 | 981 | 3757 | 8761 | 4 | 14 | 478 | 574 |
| `circles_mixed` | 1 | 65 | 2 | 334 | 1480 | 5925 | 1 | 9 | 251 | 1265 |
| `lines_rect_annular` | 1 | 951 | 4 | 2831 | 22537 | 42188 | 6 | 17 | 1037 | 120 |
| `annular_dense` | 1 | 81199 | 7 | 5524 | 12307 | 29708 | 5 | 21 | 646 | 11.2 |
| `annular_dense_multi3` | 3 | 122675 | 7 | 22374 | 31602 | 53268 | 4 | 21 | 646 | 6.8 |
| `lines_rect_annular_multi3` | 3 | 1043 | 8 | 30309 | 44862 | 76520 | 9 | 20 | 989 | 36.3 |

Repeats 2 and 3 are in the summary JSON. All workloads have the same
completion counts (100%) in every repeat.

## Cold start and memory

| Metric | Value |
| --- | --- |
| Process age at harness load | 120 ms (LÖVE boot + module load + grid validation) |
| Harness setup before first workload | 1.1 ms |
| RSS at start / end | 121.6 MiB → 142.0 MiB |
| Lua heap at start / end | 732 KiB → 6402 KiB |
| Harness wall time | 1574 s for 37,821 candidates |

## Findings

1. **The candidate grid is exact.** Enumerating indices 0..1800 and passing
   each angle back through `Physics.getSnappedAimAngle` is the identity for
   all 1801 indices. The action space is 1801 candidates, not the 1800 of the
   raw interval count.

2. **All candidates complete.** With a 3600-step cap, every one of 37,821
   candidates finished; the longest observed shot was 1037 fixed steps
   (~17 s simulated). The step cap is still enforced and incomplete results
   are reported explicitly.

3. **Dense-level `init` dominates the current baseline.** On
   `annular_dense`, `setupLevel` (including reloading the level module and
   regenerating 192 annular pegs) costs 81 ms at p50 versus 5.5 ms of
   simulation. This is the strongest argument for the M2 checkpoint contract.
   Removing per-candidate init would raise `annular_dense` from 11.5 to about
   180 candidates/s (~15x) and `annular_dense_multi3` from 6.9 to about 45
   (~6.5x) on this host.

4. **Simulation cost is long-tailed.** On `lines_rect_annular`,
   `sim` p50 is 2.8 ms but p90 is 22.5 ms and max is 42 ms — balls sliding
   along zero-gap lines take many steps. Tail latency, not just median
   throughput, must be a continuing metric.

5. **Per-candidate allocations are unbounded.** The Lua heap grew from
   0.7 MiB to 6.3 MiB over the campaign and RSS grew by about 20 MiB. The
   plan's M4 target of zero heap allocation in warm fixed-capacity stepping
   addresses exactly this. `collectgarbage("collect")` is only called between
   workloads; within a workload the engine allocates per candidate.

6. **Sustained load throttles this host.** `annular_dense` repeat 3 ran at
   7.5 cand/s versus 11.2 in repeat 1, with init p50 rising from 81 ms to
   123 ms. CPU package temperature reached 94.5 °C while the desktop session
   also ran. The engine itself is deterministic (spot checks passed in every
   workload); the variance is thermal/contention, not algorithmic. Hardware
   selection and dedicated benchmark machines remain deferred as agreed.

7. **Replay serialization is included.** By default the baseline measures
   `launchBalls` as the game runs it, including `Replay.serialize` for the
   rolling `last_shot.lua` capture. `--no-replay-serialize` measures the
   workload without it. Candidate evaluation in the Julia port does not need
   this side effect, but the baseline does not silently remove it.

## Campaign sizing against the measured baseline

At 24.1 candidates/s aggregate on this host, and an estimated
`1801 * turns` candidates per game:

| Scenario | Candidates | Wall time at 24.1 cand/s |
| --- | --- | --- |
| 1 game, 20 turns | 36k | 25 min |
| 1000 levels, 1 match, 20 turns | 36M | ~17 days |
| Several thousand levels, a few matches | 10^8–10^9 | 48–480 days |

This is the measurement that justifies the Julia port and defines the target:
the same candidate set at one to two orders of magnitude more throughput on
one core, with the same authoritative results.

## Continuing metrics

Every later milestone reports, on the same workloads:

- phase-split sweep time (init, reset, sim, extract, output);
- warm throughput and cold start separately;
- same-core speedup versus this Lua baseline;
- memory per worker and peak memory;
- worker scaling, reported separately from the single-core speedup;
- median and tail latency (p50/p90/p99/max);
- incomplete/step-limited counts.

Comparisons must use the same grid, completion rule, step cap, and observation
mode on both sides.
