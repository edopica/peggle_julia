# Ribbon 1v1 campaign: 1/2/4/8-worker baseline

1v1 is the primary campaign workload. This benchmark compares the same eight
seeded shared-board matches at **1, 2, 4 and 8 active match workers**, with three
measurements per count. Solo remains available and its original
[baseline](bot-campaign.md) is preserved at pushed commit `e7070d9`.

## Inputs and method

The [workflow](../context/bot-campaign.md) defines the rules, policy, output and
timing boundaries. The exact command, options, config/source/manifest hashes,
environment and all trial metrics are stored in
[`results/campaign/1v1/baseline.json`](../../results/campaign/1v1/baseline.json).
Every trial writes full histories alongside the report.

The only level is the existing 133-peg `ribbon_waves` artifact. The same artifact
seed (20261021), initial colors and first purple promotion are used in every
match. Bot base seed is 20261024; each player has its own recorded derived seed.
Both players evaluate all **1,801 legal indices** at every decision, with
100-index sectors (including final 1800–1800), median filtering, random eligible
sector/tie choice and epsilon 1 discrete execution noise. Candidate evaluation
is serial within each match worker.

The default input is now `campaigns/ribbon/config.v1.json`, exported from the
current Lua working-tree config with a saved source snapshot and hash. Its
gravity 700, launch speed 600 and wall damping 1.0 already matched the historical
ribbon fixture on the first sync; there is no numerical physics change relative
to that solo baseline. The frozen M0 config and trace goldens are unchanged.
This comparison measures worker scaling on the new 1v1 workload; it cannot
attribute any difference from the solo baseline to new physics parameters.

Host: AMD Ryzen 5 4600H, 6 physical cores / 12 logical CPUs, Linux x86-64,
Julia 1.12.6, **eight available Julia simulation threads**. The variable is
active simulation workers, not separately restarted Julia pool sizes. At eight
workers, there is one persistent task per match; fewer workers process strided
match IDs. There is no CPU affinity setting or candidate-level parallelism.
Eight workers can use SMT siblings on this six-core host.

The runner loads inputs once, warms one complete sequential campaign and one
complete eight-worker campaign, and warms the formatted file-output path.
Measured count order is 1/2/4/8, 8/4/2/1, 1/2/4/8 across the three repetitions.
Pretrial GC is outside each timer. No test workload runs alongside measurement.

Wall time includes grid/checkpoint creation, worker and engine setup, every
decision and actual shot, next-turn handoffs, full-history identity verification
and history serialization/write/close. Startup, one-time load, warmup, pretrial
GC and final report write are separate. Files are closed but not fsynced.
Decision latency includes the full sweep, selection/noise, execution and next-turn
checkpoint. Phase worker-seconds overlap at higher concurrency.

RSS is sampled after output; process peak RSS is cumulative over warmup and all
trials in the same process. These numbers do not isolate additional memory per
worker. Full OS/CPU/affinity/governor details are saved in
[`environment.json`](../../results/campaign/1v1/environment.json).

## Match results

The same eight matches are used at every worker count. Seven finish by red
clearance; match 7 exhausts both players' ten-ball supplies. All are completed
matches. No simulation or turn cap is reached. Each campaign evaluates
**142,279 candidates across 79 turns** (79 × 1,801).

| Match | Player 1 score | Player 2 score | Winner | Turns | Termination |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 | 128,460 | 146,250 | 2 | 7 | all_red_cleared |
| 2 | 248,840 | 149,963 | 1 | 10 | all_red_cleared |
| 3 | 140,770 | 325,590 | 2 | 8 | all_red_cleared |
| 4 | 233,364 | 117,240 | 1 | 9 | all_red_cleared |
| 5 | 210,860 | 308,470 | 2 | 6 | all_red_cleared |
| 6 | 839,728 | 71,650 | 1 | 11 | all_red_cleared |
| 7 | 31,533 | 7,608 | 1 | 20 | balls_exhausted |
| 8 | 104,580 | 289,420 | 2 | 8 | all_red_cleared |

The players use independent bot streams with the same policy. These results
are a reproducible workload, not a statistically qualified balance or win-rate
study. Gross shot scores and net score settlements are both retained in the
histories, including 17 no-red turns and all shared catch increments.

## Measured worker scaling

One-time input load: **0.310 s**. Combined warmup/JIT and
formatted-output preparation: **187.731 s**, excluded from
the following campaign times. Each summary value is the median of three runs.

| Workers | Campaign wall (s) | Completed matches/hour | Candidates/second | Speedup | Efficiency |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 148.948 | 193.4 | 955.2 | 1.00× | 100.0% |
| 2 | 76.578 | 376.1 | 1,858.0 | 1.95× | 97.3% |
| 4 | 46.329 | 621.6 | 3,071.1 | 3.22× | 80.4% |
| 8 | 39.234 | 734.1 | 3,626.4 | 3.80× | 47.5% |

| Workers | Repeat 1 (s) | Repeat 2 (s) | Repeat 3 (s) |
| ---: | ---: | ---: | ---: |
| 1 | 148.443 | 149.374 | 148.948 |
| 2 | 76.578 | 77.783 | 75.941 |
| 4 | 47.217 | 46.053 | 46.329 |
| 8 | 39.234 | 39.642 | 38.828 |

| Workers | Mean decision (s) | p50 decision (s) | p95 decision (s) | Verification/output (s) |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1.885 | 0.983 | 6.727 | 0.0194 |
| 2 | 1.935 | 1.024 | 7.043 | 0.0190 |
| 4 | 2.128 | 1.044 | 7.668 | 0.0479 |
| 8 | 2.831 | 1.216 | 11.087 | 0.0485 |

| Workers | Simulation (s) | Candidate reset (s) | Selection (ms) | Actual shot (ms) | Checkpoint (ms) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 146.734 | 1.674 | 8.027 | 152.138 | 7.882 |
| 2 | 150.688 | 1.660 | 7.867 | 157.293 | 8.085 |
| 4 | 165.696 | 1.838 | 9.314 | 173.121 | 7.479 |
| 8 | 220.876 | 2.119 | 8.345 | 209.641 | 7.955 |

RSS after output ranges from **566.8 to 599.5 MiB**.
Cumulative process peak RSS is **634.4 MiB**, including warmup and all
worker counts. Phase values are summed worker wall durations; they overlap
at higher concurrency and include any GC pauses that occur inside the phase.

All **12 measured campaigns** complete all eight matches
(**96 completions**, repeated seeded workload), without
simulation or turn truncation. Gameplay and decision histories are identical
across all trials and both warmups. The independent offline audit checks
**948 recorded decisions** and accounts for
**1,707,348 candidate evaluations**, checking
sector coverage/median/ties/noise, both players'
score settlements, red-hit detection, shared catches, ball consumption, next
player, winners and all source/input hashes. Its executable command is:

```bash
python3 scripts/audit_campaign.py results/campaign/1v1/baseline.json \
  --out results/campaign/1v1/verification/history-audit.json
```

## Observed bottlenecks

Candidate simulation accounts for **98.8–98.9%** of
instrumented phase time; candidate reset is **0.9–1.1%**.
Selection/noise, actual shots and checkpoint preparation remain much smaller.
These phase timers do not separate physics work from GC pauses.

Eight workers deliver **3.80×** single-worker throughput and
**18.1%** more throughput than four workers.
The smaller gain from four to eight comes with higher individual decision
latencies and lower efficiency per active worker.

The slowest sequential match (match 7) takes **26.92 s**, while
the fastest takes **12.66 s**. With one task per match, the batch
must wait for the slowest task. Its 20 turns create a visible tail relative to
the other matches' 6–11 turns. The six-core / twelve-logical-CPU host also means
eight workers can share physical cores. The data show sublinear scaling and
higher per-game simulation durations; they do not isolate CPU frequency, cache,
SMT or GC effects. No engine/geometry refactor, SIMD or candidate parallelism
was added for this baseline.

## Verification

The full Julia suite passes **10,996** checks, including existing ribbon Lua
trace parity and 125 added 1v1 checks. Nine match-rule cases execute the saved
Lua GameState methods directly and compare Julia bookkeeping against their
captured results: score cancellation, quarter-score floor penalties, shared
catch bonuses, player alternation/skipping, ball exhaustion, red clearance,
score-based winner selection, ties and optional solo free-ball behavior.

The pinned Lua suite passes **475** tests; interchange reproducibility/schema/
contract checks and the current config-copy check pass. The frozen reference's
133 files verify before and after measurement. Logs are preserved in
[`verification/`](../../results/campaign/1v1/verification/).
