# Ribbon bot campaign baseline

This is the first full-game baseline for the Julia MVP. The policy, lifecycle,
output schema, and timing boundaries are specified in
[the workflow](../context/bot-campaign.md). Only `ribbon_waves` was used.

## Configuration and method

The command and environment are saved in
[`results/campaign/baseline.json`](../../results/campaign/baseline.json).
Full histories for all six measured campaigns and verification logs live beside
it. The baseline uses Julia 1.12.6 on an AMD Ryzen 5 4600H (6 cores / 12 hardware
threads), Linux x86-64, and three Julia worker threads. No CPU affinity is set.

| Setting | Value |
| --- | --- |
| Games | 3 independent solo games |
| Bot base seed | 20261024 |
| Level | `fixtures/ribbon_waves/artifact/ribbon_waves.v1.json` |
| Config | `fixtures/ribbon_waves/config.dev.v1.json` |
| Grid | 0–1800 inclusive: 1,801 candidates per decision |
| Sector size | 100; 19 sectors, final sector 1800–1800 |
| Epsilon | 1 aim-index step |
| Step limit | 3,600 per candidate / actual shot |
| Turn limit | 100 per game |
| Repetitions | 3 sequential + 3 concurrent |

The fixture configuration is used as stored, including its gravity and wall
damping. This is the reconstructed ribbon corpus, whose provenance is separate
from the frozen M0 reference. Artifact, config, campaign source and Julia
manifest SHA-256 hashes are recorded in the report.

Input parsing happens once; the same initial checkpoint realization is shared
by all three games in each campaign. Full sequential and concurrent warmups
exercise all seeded turns and the exact formatted output path before measurement.
Repetitions alternate execution order:
sequential/parallel, parallel/sequential, sequential/parallel. Explicit GC runs
before each trial, outside its timer. No tests run alongside the benchmark.

Campaign wall time includes checkpoint construction, grid validation, workers,
engines and buffers, every full-grid decision and actual shot, identity
verification, and history JSON write/close. Julia startup, input load, warmup,
pretrial GC and final report writing are separate. The reported one-time load
cost can be added to wall time for a campaign that must parse its own inputs.

Decision latency includes a game's candidate sweep, selection/noise, actual
shot, and next-turn checkpoint preparation. Phase durations are sums of worker
wall times and overlap in parallel. Memory samples are process RSS after output;
peak RSS includes warmup and previous trials. This measures the MVP process,
not isolated incremental worker memory.

## Gameplay results

All three games complete under the existing solo rules. There are no candidate
or actual-shot truncations. Completion includes exhausting the ball supply;
it does not imply clearing every red peg.

| Game | Bot seed | Score | Turns | Termination | Balls left | Reds left |
| --- | --- | ---: | ---: | --- | ---: | ---: |
| 1 | 5216396562836589 | 291,620 | 9 | all_red_cleared | 1 | 0 |
| 2 | 1877692158208550 | 445,070 | 9 | all_red_cleared | 4 | 0 |
| 3 | 2150283236279660 | 265,560 | 10 | balls_exhausted | 0 | 1 |

The shared artifact gameplay seed is 20261021. Each campaign has 28 decisions
and evaluates **50,428 candidates** (28 × 1,801). Game 2 catches three balls,
which are returned to its supply without adding bucket bonus points.

## Measured results

One-time input load: **0.298 s**. Combined sequential/concurrent
warmup and compilation/output preparation: **82.349 s**, excluded
from every trial below. Values in the summary table are medians of three trials.

| Metric | Sequential | Three workers |
| --- | ---: | ---: |
| Campaign wall time (s) | 56.898 | 22.295 |
| Completed games/hour | 189.8 | 484.4 |
| Candidates/second | 886.3 | 2,261.8 |
| Mean decision latency (s) | 2.032 | 2.149 |
| p50 decision latency (s) | 0.959 | 1.023 |
| p95 decision latency (s) | 6.885 | 7.310 |
| Verification + history output (s) | 0.0062 | 0.0063 |

**Median wall-time speedup: 2.55×.** Adding the one-time load cost
to either mode does not materially change this result. Decision latency per
game does not improve with campaign parallelism: three games make progress at
once, while every game still evaluates candidates serially.

| Repeat | Sequential wall (s) | Concurrent wall (s) |
| --- | ---: | ---: |
| 1 | 56.119 | 22.175 |
| 2 | 56.898 | 22.295 |
| 3 | 57.138 | 23.392 |

| Phase: median worker-seconds | Sequential | Concurrent |
| --- | ---: | ---: |
| simulation | 55.9953 | 59.2843 |
| candidate_reset | 0.7017 | 0.6873 |
| selection | 0.0028 | 0.0027 |
| actual_shot | 0.0583 | 0.0601 |
| checkpoint | 0.0028 | 0.0026 |

Post-output RSS ranges from **528.8 to 536.9 MiB** across trials.
The cumulative process peak is **609.8 MiB**, including warmup/JIT.
Per-mode memory deltas cannot be inferred from these shared-process samples.

Gameplay and decision histories are identical across all six measured campaigns
and both warmup campaigns. A second offline audit checked all 168 measured decisions for sector
coverage, median/eligibility, winning ties, legal noise and score accumulation.
The audit and source/input hash checks are saved in
[`history-audit.json`](../../results/campaign/verification/history-audit.json).

## Observed bottlenecks

Candidate simulation accounts for about **98.6–98.8%** of instrumented worker
phase time. Candidate reset is about **1.1–1.3%**; selection/noise, actual shots
and next-turn checkpoint preparation are much smaller. The first full-board
decision takes roughly seven seconds per game; later decisions become cheaper
as pegs disappear. Reported p95 latency reflects these initial expensive turns.

The parallel campaign finishes when its slowest game finishes. In the first
corrected concurrent trial, game worker durations are approximately
22.17 s, 18.03 s, and 19.05 s.
This imbalance and slightly higher aggregate simulation time under concurrent
load explain much of the gap from an ideal 3× speedup. No shared-geometry, SIMD,
candidate subsampling, or nested candidate parallelism was introduced.

## Verification

The full Julia suite passes **10,871 / 10,871** checks, including the existing
ribbon byte-exact Lua trace replays and new policy/lifecycle/isolation tests.
The new scheduling test compares actual full-grid selections and noisy shots
between sequential and concurrent execution. Separate limit tests confirm
truncated sweeps and turn-limited games do not count as completed.

The frozen Lua suite passes **475 / 475** tests. `make check` passes its eight
groups (codec, export reproducibility, manifest, schema, fixture contract,
checkpoint contract, trace comparison, sweep comparison). The pinned reference
has 133 matching files before and after the measurement session. Logs are in
[`results/campaign/verification/`](../../results/campaign/verification/).
