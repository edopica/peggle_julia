# Ribbon bot campaigns: 1v1 first

The primary workload is a batch of **eight independent 1v1 matches** on
`ribbon_waves`, with the same initial level realization and bot policy. Each
match has two players sharing one evolving board. Solo remains an explicit
alternative. The historical three-game solo baseline is preserved at commit
`e7070d9` and in [its report](../benchmarks/bot-campaign.md).

## Run

From the repository root with Julia 1.12.6 and the pinned package environment:

```bash
julia --project=julia/PeggleSim scripts/sync_campaign_config.jl --check
make verify
julia --project=julia/PeggleSim -t 8 julia/PeggleSim/bin/campaign.jl \
  --mode 1v1 --games 8 --workers 8 --worker-counts 1,2,4,8 --repeats 3 \
  --out results/campaign/1v1/baseline.json
make verify
python3 scripts/audit_campaign.py results/campaign/1v1/baseline.json \
  --out results/campaign/1v1/verification/history-audit.json
```

These are the defaults. `--games` counts independent matches, not players.
Eight matches allow all eight workers to be active at the highest concurrency.
The same eight seeded matches are rerun at each worker count; no results are
mixed between different workloads. One worker is the sequential reference.
`--workers` sets the maximum concurrency, and `--worker-counts` selects the
measured counts. Start Julia with at least that many simulation threads.

The benchmark loads level and config once, runs complete sequential and maximum
concurrency warmups, exercises formatted history output, then performs three
measurements per worker count. It reverses count order on alternate repetitions
to reduce order bias. Every warmup/trial compares complete gameplay and decision
histories to the sequential reference, excluding timings. A mismatch fails.

Solo with the old input and three-game workload:

```bash
julia --project=julia/PeggleSim -t 3 julia/PeggleSim/bin/campaign.jl \
  --mode solo --games 3 --workers 3 --worker-counts 1,3 \
  --config fixtures/ribbon_waves/config.dev.v1.json \
  --out results/campaign/solo-current.json
```

`--help` lists all options. Level, config, match count, seed, sector size,
epsilon, per-shot step limit, per-match turn limit, repetition count and output
are configurable. The CLI supports only ribbon. `--max-turns 1 --max-steps 1`
is a cheap limit/identity diagnostic and does not measure completed matches.

For a single campaign without warmup or file output, use
`PeggleSim.run_campaign(level, config, PeggleSim.CampaignOptions(...); parallel=true)`.
API defaults are 1v1, eight matches and eight workers. Load inputs once and
reuse them. `parallel=false` runs the same matches sequentially.

## Current configuration and provenance

The default config is `campaigns/ribbon/config.v1.json`, exported through the
existing Lua exporter from `../peggle_evolved/src/config.lua`. To copy updated
parameters, run `julia --project=julia/PeggleSim scripts/sync_campaign_config.jl`;
`--check` detects stale inputs. Saved Lua source and provenance hashes make
working-tree edits explicit instead of attributing them to the committed Lua
revision.

The current values are gravity **700**, launch speed **600**, wall damping
**1.0**. All exported values already matched the previous ribbon fixture on
this first sync. The frozen M0 config is different (1000 / 800 / 0.8) and remains
unchanged. The ribbon artifact, historical trace fixture config and previous
benchmark results are also unchanged. New decision checkpoints identify the
actual config source hash supplied to the campaign.

## Policy, grid and RNG

Every decision evaluates all **1,801 legal indices, 0–1800 inclusive**, serially
inside its match worker. The existing snapping implementation verifies grid
identity before every campaign; there is no subsampling or separate angle loop.

With sector size 100, the sectors are 0–99, 100–199, …, 1700–1799, 1800–1800.
Output sector IDs are one-based, aim indices zero-based. Each sector records its
highest immediate total shot score and all tied winning indices. Filter sector
best scores by `score >= median` (average the two central values for an even
number of sectors), choose a surviving sector uniformly, then one of its tied
winners uniformly. The final partial sector has the same sector probability.

In 1v1 the immediate score includes the increasing catch bonus. The policy still
ranks **gross shot score**, before the no-red match penalty; it does not search
for the largest net banked score or model the opponent's next move. Both players
use exactly this policy.

Epsilon is a nonnegative integer in aim-index steps, default 1. Sample the offset
uniformly from `max(-epsilon,-index):min(epsilon,1800-index)`; zero is allowed.
Sample only legal offsets, without clamping. Bot integer draws use unbiased
rejection sampling over the existing generator's 64-bit draws.

Each 1v1 player owns a separate bot generator. Its seed is
`bot_seed(base_seed, 2*(match_id-1)+player_id)`; solo retains
`bot_seed(base_seed, game_id)`. The hash and 53-bit mask in `src/campaign.jl`
make seeds exactly representable by the existing generator constructor. All
sixteen default bot seeds are distinct, recorded, and independent of scheduling.
All matches start from the same artifact gameplay seed, colors and first purple
promotion. Bot draws never consume the separate gameplay RNG.

## 1v1 lifecycle

The match layer follows the saved Lua `GameState:_onLaunch`, `_onBucketCatch`,
`_endTurn` and `_determineWinner`, together with the existing resetTurn contract:

- Both players start with the configured ball supply. Consume one ball on launch.
- A catch adds `shared_catch_count * bucket_incremental_base` to that shot. The
  counter persists across both players and all turns; 1v1 catches return no balls.
- Run the full physics, scoring, fever, style awards and end-of-turn clearing.
  Removed red pegs still count as hit through the retained turn peg references.
- If a completed shot hit a red, bank its total score. Otherwise discard the
  entire shot score and deduct `floor(previous_banked_score * 0.25)`. A canceled
  catch bonus still advances the shared catch counter, matching Lua.
- End when all reds are cleared or both players have exhausted their balls.
  The winner is the higher banked score, even if the other player cleared the
  last red. Winner 0 is a tie; incomplete matches have no winner.
- Otherwise alternate players, skipping any player with no balls. Continue on
  the same board, preserving RNG, bucket/fever phase, multipliers, counters and
  monotonic ball IDs. Reset turn scores/trackers, allocate one unlaunched ball,
  promote purple and capture the next checkpoint.

The ready-to-aim zero-delay contract is retained. Presentation turn overlays
and UI waiting time are excluded. Solo uses free-ball catches without catch
bonus or no-red penalties, and finishes on red clearance or one player's ball
exhaustion.

One persistent task per worker owns the matches assigned to it. At eight workers
there is one task per match; at lower counts workers process strided match IDs.
Each match has private live/candidate engines, buffers and RNGs. Candidate reset
copies the decision checkpoint; evaluations cannot mutate live state or the
shared match catch counter. Execute the noisy actual shot on the original live
state. Candidate parallelism, SIMD and geometry-sharing refactors are absent.
Julia worker tasks may migrate between OS threads; they are not CPU-pinned.

Any incomplete candidate invalidates the decision. All legal indices are still
evaluated, then the match reports `candidate_step_limit` and the affected indices.
`actual_step_limit` and `turn_limit` are explicit too. Truncated matches never
count as completed. Final scores include only settled complete shots.

## Records and timings

Each decision records active player, all sector winners/scores, threshold,
eligible sectors, intended index, offset, executed index, gross shot score,
style counts, hit-red status, credited score, penalty, score delta, both players'
banked scores/balls, next player, shared catches, remaining pegs/reds and RNG
states. Each match records player seeds, gameplay seed, final scores, per-player
turn counts, winner, completion and termination reason.

The report stores exact options, count list, source/config/manifest hashes,
revision and working-tree status, environment, warmup and input-load durations,
trial metrics and all history paths. Measured wall time starts before grid
validation/initial checkpoint creation and includes workers, engines, buffers,
simulation, selection, actual execution, next-turn checkpoints, identity
verification, formatted history output and file close. It excludes Julia startup,
one-time input parsing, warmup, pretrial GC and final aggregate report writing.
Writes are closed but not fsynced. Input load is separately reported and can be
added for a campaign that must load its own inputs.

Completed matches/hour and candidates/second use this wall time. Decision latency
includes the full sweep, selection/noise, actual shot and next-turn preparation;
it excludes initial worker setup and file output. Mean and nearest-rank p50/p95
are reported. Phase worker-seconds separate candidate reset, simulation,
selection, actual shot and next-turn checkpoint work. They overlap in parallel
and must not be treated as campaign wall time. Timing reads remain in the MVP.

RSS is sampled after output. Peak RSS is cumulative across warmup and trials in
one Julia process with eight available simulation threads; the count varied is
active match workers (1/2/4/8). These measurements do not isolate incremental
worker memory or restart Julia with a different pool size at each count.

See [1v1 worker-scaling results](../benchmarks/1v1-campaign.md). Match-layer tests
compare directly against captured outputs of the saved Lua methods; existing
ribbon trace tests continue to cover physics parity.
