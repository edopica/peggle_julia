# Ribbon solo bot campaigns

The MVP runs only `ribbon_waves` (the ribbon fixture). It uses the existing
static level artifact, configuration, math backend, fixed timestep, shot engine,
and copying ready-to-aim checkpoint contract. The vendored reference is unchanged.

## Run and reproduce

From the repository root, with Julia 1.12.6 and the pinned package environment:

```bash
make verify
julia --project=julia/PeggleSim -t 3 julia/PeggleSim/bin/campaign.jl \
  --level fixtures/ribbon_waves/artifact/ribbon_waves.v1.json \
  --config fixtures/ribbon_waves/config.dev.v1.json \
  --games 3 --workers 3 --base-seed 20261024 --sector-size 100 --epsilon 1 \
  --max-steps 3600 --max-turns 100 --repeats 3 \
  --out results/campaign/baseline.json
make verify
```

`--help` lists all options and defaults. The entry point is a benchmark driver:
it runs complete sequential and concurrent warmups, followed by sequential and concurrent
campaigns for each repetition, alternating their order. It checks every game
and decision against the warmup before writing results. A mismatch fails the
command. For a shorter diagnostic, use `--max-turns 1 --repeats 1`; this records
incomplete games and cannot establish completed-game throughput.

The module API is `PeggleSim.run_campaign(level, config, CampaignOptions(...);
parallel=true)`. It runs a single campaign without warmup or file output.
`parallel=false` runs the same games sequentially. Load level/config once and
reuse them across calls. Options validate positive game/worker counts, sector
size, step and turn limits, and nonnegative seed/epsilon. The CLI rejects levels
other than ribbon. Custom paths must supply the same static ribbon level;
configuration changes are recorded through file hashes.

## Policy and randomness

Every decision evaluates the entire existing snapped grid, serially inside the
game's worker. The fixture config has 1,800 intervals and **1,801 legal
candidates**, indices **0–1800 inclusive**. There is no subsampling. Grid identity
is checked through the existing snapping implementation before each campaign.

With sector size 100, sectors cover 0–99, 100–199, …, 1700–1799, and 1800–1800.
Sector IDs in output are one-based; aim indices are zero-based. Each sector
records its best immediate total shot score and every tied winning index.
The median is the central score (or the arithmetic mean of the two central
scores for an even number of sectors). All sectors with best score at least
the median remain eligible, including equal scores. Pick a sector uniformly,
then a winning index uniformly within it. This deliberately gives the final
partial sector the same selection probability as any other eligible sector.

Epsilon is an integer number of aim-index steps, default 1. Sample the integer
offset from `max(-epsilon, -index):min(epsilon, last_index-index)`. This includes
zero and samples legal offsets directly; there is no clamping. Bot integer
draws use rejection sampling over the existing xorshift generator's 64-bit draws.

Each game owns its bot generator, derived from base seed and game identity by
the documented `bot_seed` implementation in `src/campaign.jl`. Derived seeds
fit exactly in the existing generator constructor's Float64 seed representation.
They do not depend on scheduling. The base seed controls bot choices only.
All games start from the same checkpoint and artifact-defined gameplay seed,
including the same initial colors and purple promotion. Bot draws never consume
the gameplay RNG. Output records both seeds and subsequent RNG states.

## Lifecycle and ownership

Before implementation, inspection found a complete shot engine and checkpoint
implementation, but no solo launch bookkeeping, match completion, or next-turn
handoff. The added layer ports these rules from the frozen
`src/states/game.lua` (`_onLaunch`, `_onBucketCatch`, `_endTurn`) and
`src/engine/core.lua` (`resetTurn`):

- Consume one ball on launch; a solo bucket catch returns one ball and awards
  **no bucket bonus points**. Fever points and style scores remain engine-owned.
- Run the full end-of-turn clearing cascade, including peg removal and color
  queue cleanup. Bank the total shot score only for a completed actual shot.
- Finish when all red pegs are cleared, or when no balls remain. Both are
  completed games; red clearance is distinguished from ball exhaustion.
- Otherwise retain board, score, multiplier, gameplay RNG, bucket/fever phase,
  step/shot counters, and monotonic ball identity namespace. Allocate one new
  unlaunched ball, clear turn-local scores/trackers, promote purple, and capture
  the next ready-to-aim checkpoint. There are zero waiting steps before launch.

One persistent Julia worker task owns each game at the default three games /
three workers. Each task uses a live engine and a separate reusable candidate
engine, a score vector, and engine-owned scratch buffers. Candidate reset copies
from the decision checkpoint; neither candidates nor selection mutate live state.
The noisy actual shot executes directly on that original live state. There is
no candidate parallelism or new geometry-sharing architecture. If configured
with fewer workers than games, persistent workers process strided game IDs.
Julia tasks can migrate between OS threads; these are logical workers, not
separate processes or pinned threads.

If **any** candidate reaches the step cap, all indices are still evaluated and
the game terminates with `candidate_step_limit` and the incomplete indices.
It cannot choose using truncated scores. `actual_step_limit` is also explicit.
`turn_limit` stops a game that still has further turns. None count as completed.
For incomplete actual shots, final score is the banked score from completed
turns; the shot record contains the unbanked partial score.

## Output and timing

The aggregate report records exact CLI options, artifact/config/source/manifest
hashes, revision and working-tree status, command, environment, warmup time,
one-time input load cost, all trial metrics, and history paths. Each trial's
history JSON records game IDs, seeds, sector winners/ties/scores, threshold,
eligible sectors, intended sector/index, offset, executed index, actual score
components and style counts, remaining balls/pegs/reds, RNG states, final score,
turn count, completion and reason. Timing fields live separately from gameplay;
identity comparisons include entire game/decision objects, excluding timing.

Measured campaign wall time starts before grid validation and initial checkpoint
construction. It includes worker/engine/buffer setup, simulation, selection,
next-turn checkpoint work, identity verification, and JSON history serialization,
file write and close. It excludes Julia startup, one-time artifact loading,
warmup, explicit pretrial GC, and the final aggregate report write. Load time is
reported separately because input is loaded once for the whole experiment.
Writes are closed but not fsynced. Warmup includes compilation, full sequential and concurrent campaigns,
and the exact formatted IOStream serialization path used by trial output.

Reported completed games/hour and candidates/second divide by this wall time.
Decision latency spans the full candidate sweep, selection, actual execution,
and next-turn preparation; it excludes initial worker setup and file output.
Reports include mean and nearest-rank p50/p95. Phase times sum wall durations
inside workers: candidate reset, candidate simulation (launch/run/score read),
selection/noise, actual shot/summary/handoff, and next-turn checkpoint. In parallel,
these worker-seconds overlap and must not be interpreted as campaign wall time.
Per-candidate clock reads are included in the measured baseline.

Linux RSS is sampled after each trial's history output. Peak RSS is process-wide
and cumulative across warmup and trials; sequential and parallel measurements
share one process. It does not establish isolated per-mode memory requirements.

See [the measured baseline](../benchmarks/bot-campaign.md). Tests are in
`julia/PeggleSim/test/test_campaign.jl`; the full package suite also replays the
ribbon Lua trace fixtures.
