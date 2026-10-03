# M0 workload definition

This document defines the repeatable benchmark workload: which levels, which
decision state, which candidates, which seeds, and which metrics.

## 1. What a workload is

A workload is one static level plus one decision state plus the full legal aim
grid (`wiki/context/reference.md` §3). The unit of work is one **candidate**: launch
the idle ball(s) at one grid angle, simulate fixed steps to shot completion,
and extract features. All candidates in a workload start from an identical
fresh decision state.

Static means fixed peg geometry with normal bucket behavior. Green powers and
ball-ball collisions can still create multiball mid-shot; the synthetic
multiball workloads additionally launch N balls at once.

## 2. Representative workloads

From `harness/workloads.lua`. Peg counts are for the pinned revision.

| Workload id | Level | Pegs | Coverage | Extras |
| --- | --- | --- | --- | --- |
| `overhead_static_2p` | `long_shot` | 2 circles | fixed-overhead floor | 2-peg minimal scene |
| `circles_small` | `circle_level` | 25 circles | static circles | 600×500 canvas |
| `circles_mixed` | `off_the_wall` | 16 circles | circles, red/green mix | 880×550 canvas |
| `lines_rect_annular` | `slide` | 39 circles, 15 rectangles, 19 annular | rectangles, annular, zero-gap lines | slide style path |
| `annular_dense` | `squiggly_circle` | 192 annular | dense static layout, annular | one closed cubic |
| `annular_dense_multi3` | `squiggly_circle` | 192 annular | multiball + dense annular | 3 simultaneous balls |
| `lines_rect_annular_multi3` | `slide` | 73 mixed | multiball + rectangles | 3 simultaneous balls |

Rejected for M0 (moving or path-driven; enter in M8):

| Level | Pegs | Circuits | Why deferred |
| --- | --- | --- | --- |
| `level1` | 50 (circles/rect/annular) | 1 ellipse | motion changes initial geometry over time |
| `benchmark_lasagna` | 224 mixed | 3 (oscillate x/y, rotate) | dense moving benchmark |
| `advanced_circuits` | 116 circles | 1 closed path | path-driven return leg |
| `slide_rotating` | 73 mixed | 2 | rotating annular + lines |

The existing `benchmark_lasagna` numbers in `wiki/benchmarks/` and the root
`benchmark_results.csv` remain the moving-workload reference until M8.

## 3. Seeds and randomness

- Every candidate rebuilds the level through `LevelManager.load` and
  `PegColors.init(pegs, type_counts, level_seed)`.
- Level seeds come from the level files (`circle_level`: 123, `squiggly_circle`:
  20260918, `slide`: 1, `off_the_wall`/`long_shot`: default 345).
- The RNG is `love.math.newRandomGenerator(seed)` (LÖVE xorshift), consumed in
  a fixed order: type-pool shuffle, peg assignment, purple-queue shuffle, first
  purple promotion.
- Bots are deterministic in M0: exhaustive one-ply grid evaluation with no
  noise. There is no bot RNG, no wall-clock dependence, and no scheduling
  dependence in candidate evaluation.
- Multiball spawn positions are deterministic:
  `x_i = (i / (N+1)) * virtual_width`, `y = 50`.

## 4. Timing phase boundaries

The harness splits each candidate into five measured phases:

| Phase | Starts | Ends | Includes |
| --- | --- | --- | --- |
| `init` | before `Engine.new` | after `setupLevel` | engine construction, level module load, peg construction, boundary filter, motion init, color assignment, bucket construction |
| `reset` | before ball creation | after `resetTurn` | ball construction/registration, purple promotion, gameplay tracker reset |
| `sim` | before `launchBalls` | when the shot ends or the cap hits | launch, fixed-step physics, scoring, style/clearing processors |
| `extract` | after the last step | after feature table built | score reads, style aggregation, memory read |
| `output` | before row serialization | after the row write | JSONL row formatting and buffered file write |

Default shot end is the bench boundary: the shot ends when no launched ball
remains. Passing `--clearing on` continues stepping through the end-of-turn
clearing cascade to the next ready-to-aim boundary, which is the M4 boundary.
The default keeps the M0 baseline comparable with the existing Lua tools.

The default per-candidate cap is 3600 fixed steps (60 s simulated). A capped
candidate is counted as **incomplete** with reason `step_limit`; it is never
silently scored as a low result.

## 5. Measurement protocol

1. Verify the grid: all 1801 indices round-trip through
   `Physics.getSnappedAimAngle`.
2. Verify the reference manifest (`scripts/verify_reference.sh`).
3. Determinism spot check: evaluate a few indices twice and require
   bit-identical feature tuples.
4. Warm up the JIT with untimed candidates.
5. Timed sweep of the full grid, `--repeat R` times.
6. Report per-phase median/p90/p99/max, candidates/second, simulated
   steps/second, completed/incomplete counts, reason and style histograms,
   Lua heap, and process RSS.
7. Record cold start separately: process age at harness load and the setup
   time before the first workload, plus external wall time from the runner.

Metrics are reported per workload and repeat so that warm throughput never
hides cold behavior, and so that tail latency is visible.

## 6. Workload estimate for campaigns

The campaign cost is the sum over every decision state, not only selected
shots:

```text
candidates_per_turn   = 1801 (M0, zero extra delay)
candidates_per_game   = candidates_per_turn * turns_per_game
candidates_per_level  = candidates_per_game * matches_per_level
campaign_candidates   = candidates_per_level * levels * (1 + oversampling)
```

Example: a 20-turn 1v1 match evaluates two turns per round, so roughly
`1801 * 2 * turns_per_player` candidates for one match; several thousand
levels at a few matches each is on the order of 10^7–10^9 candidates. The M0
baseline exists to size that number against measured throughput.

Timing search (M8) multiplies the grid by the delay resolution. M0 reserves
the `delay` field in the action schema but always uses zero.

## 7. Comparison protocol for speedup

The continuing metric "same-core speedup" compares:

- the pinned Lua baseline from this harness, and
- the Julia simulator on one worker, same level, same candidate set, same
  observation mode (summary), same completion rule, same step cap.

Reports must show the phase split (init, reset, sim, extract, output), the
candidate grid size, completion counts, and memory. Diagnostic output is never
omitted from one side to flatter it; M0's committed baseline uses summary mode
for both sides.

## 8. M0 baseline results

The committed baseline run is generated with:

```bash
scripts/run_baseline.sh --repeat 3
```

Results live in `results/` (summary JSON) and `results/raw/` (per-candidate
JSONL, gitignored). The measured numbers and analysis are in
`wiki/benchmarks/baseline-metrics.md`.
