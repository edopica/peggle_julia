# Inventory: existing corpus and reusable tooling

This is the M0 inventory of what the pinned reference already provides and
what the Julia port can reuse or must replace.

All paths are relative to `reference/peggle_evolved/` unless noted.

## 1. Test corpus

`luajit tests/run.lua` runs every `tests/test_*.lua` file without LÖVE using
`tests/love_stub.lua`. The stub replaces `love.math.newRandomGenerator` with a
simple LCG and neutralizes graphics/timer/input calls, so its RNG sequences are
**not** the LÖVE sequences and must not be used to capture expected values.

| File | Focus |
| --- | --- |
| `test_engine_integration.lua` | scoring reduction, multiball, ordering, shot lifecycle |
| `test_style_shots.lua` | all style recognition (long/super/double, lucky bounce, off-the-wall, slide) |
| `test_ball_ball_collisions.lua` | swept equal-mass ball impulses |
| `test_ball_ids.lua` | stable identity namespace, allocation, replay compat |
| `test_replay_compat.lua` | schema v2 capture/restore and legacy captures |
| `test_simulation_snapshot.lua` | authoritative snapshot contents and ordering |
| `test_gameplay_events.lua`, `test_gameplay_commands.lua` | event journal and command buffer semantics |
| `test_gameplay_trace_exporter.lua` | canonical JSONL trace schema |
| `test_step_record_ownership.lua` | step record deep-copy ownership |
| `test_ball_state.lua` | stall/idle/no-score timers |
| `test_slide_inversion.lua`, `test_slide_level.lua` | valley pendulum inversion |
| `test_lines.lua` | zero-gap line generation and metadata |
| `test_path.lua` | path construction, arc length, cubic accuracy |
| `test_circuits.lua`, `test_advanced_circuits.lua`, `test_circuit_analyzer.lua`, `test_motion_schema.lua` | motion validation and runtime |
| `test_annular_depenetration.lua`, `test_bounce_settling.lua` | collision edge cases |
| `test_level_manager.lua`, `test_level_validator.lua` | level loading and boundary filtering |
| `test_replay_library.lua` | saved-replay library |
| `test_contact_presentation.lua` | render-only contact presenter |

Runner result on the pinned tree: see `wiki/benchmarks/baseline-metrics.md`
(`make test`).

## 2. Replay corpus (local, not committed upstream)

`replays/` in the working repository is gitignored and holds 9 captured shots
as of M0 (bucket catches, circuit behavior, missed bucket, multiball fever,
bounce, two tunneling cases). `src/replays/last_shot.lua` is the rolling
capture used by `make trace`. These are useful seeds for the M1 fixture set
but are not present in the vendored pin.

## 3. Existing level exporter and dumpers

| Tool | Purpose | Reusable for the port? |
| --- | --- | --- |
| `tools/dump_level.lua` | converts a level table to JSON, drops runtime caches, flattens compiled paths | superseded in M1 by `../julia_clone/tools/export_level.lua` (versioned, static-only, hard-fails on motion) |
| `tools/check_level.lua` | level validation via `src/systems/level_checker.lua` | yes, as a geometry check reference |
| `tools/export_trace.lua` | replays a shot headlessly and exports physics/gameplay traces | yes, the trace schema is the cross-engine comparison basis |
| `tools/test_style_shot.lua` | brute-forces a style shot over a 0.1° angle loop with snapping disabled | no: not the bot action space; strategy only |
| `tools/json.lua` | tiny JSON serializer | reused by the M0 harness for summaries |
| `tools/run_headless.sh` | display-env wrapper for unattended LÖVE runs | concept reused in `scripts/love.sh` |

## 4. Benchmark tooling

| Artifact | Purpose | M0 status |
| --- | --- | --- |
| `src/systems/perf.lua` | per-frame update/draw timers, peg-check and collision counters | reused conceptually; M0 harness adds phase-level timers |
| `src/bench/mode.lua` | `--bench` loop: N balls dropped, `benchmark_results.csv` output | reused semantics for shot end and multiball spawn; not candidate sweeps |
| `benchmark_results.csv` (repo root) | accumulated `--bench` runs (levels, balls, jit, fps, update ms, peg checks, collisions) | historical data; not phase-separated |
| `wiki/benchmarks/b1000_jit.txt`, `b1000_nojit.txt`, `new_draw_results.csv` | older 1000-ball benchmark logs | historical |
| `wiki/context/benchmarking_architecture.md` | describes `Perf` metrics | reference |

The existing benchmarks measure frames of a full game loop, not candidate
throughput from a decision state. The M0 harness is the first tool that
measures the actual bot workload.

## 5. Trace and checkpoint plumbing

| Module | Role | Port relevance |
| --- | --- | --- |
| `src/systems/simulation_snapshot.lua` | complete authoritative state capture as plain data (schema v2) | basis for `DecisionCheckpoint`, but no restore exists |
| `src/systems/replay.lua` | serializes/restores an in-progress shot | partial restore; does not capture RNG state |
| `src/systems/gameplay_trace_exporter.lua` | canonical per-step event/command/snapshot JSONL | the cross-engine comparison schema |
| `src/systems/gameplay_events.lua`, `gameplay_commands.lua` | per-step event journal and command buffer | event semantics contract |
| `src/systems/path.lua`, `circuits.lua`, `circuit_primitives.lua`, `path.lua` | path compilation, runtime sampling, circuit motion | required in the moving-level phase (M8); current `dump_level` does not preserve compiled caches |

The plan's checkpoint contract (RNG state, purple queues, circuit phases,
bucket phase, identities, match state) is **not** implemented upstream. M2
implements it; M0 rebuilds state per candidate instead.

## 6. Game/match layer

`src/states/game.lua` (551 lines) holds the match rules: inventories, turn
changes, 1v1 shared bucket counter, no-red penalty, fever transitions. These
rules are not part of the shot evaluator; the M5 match layer rebuilds them
from this source. Wiki descriptions differ from current match code in at least
one place (1v1 bucket bonus), so the pinned source wins.

## 7. The "42-case matrix"

The strategy document proposes a 42-case level × angle validation matrix, but
no such artifact exists anywhere in the pinned tree. M1 assessed it as a
planning placeholder and defined the replacement mechanism-oriented matrix in
`wiki/context/fixtures.md` (14 natural shot cases, 11 boundary scenarios, 25
captured records). The matrix is not treated as existing upstream coverage.

## 8. Source map for later milestones

| Concern | Pinned source |
| --- | --- |
| Phase order and shot lifecycle | `src/engine/core.lua` |
| Aim grid and collision behavior | `src/systems/physics.lua`, `src/config.lua` |
| Match rules | `src/states/game.lua` |
| Circuit and path behavior | `src/systems/circuits.lua`, `src/systems/circuit_primitives.lua`, `src/systems/path.lua` |
| Color state | `src/systems/peg_colors.lua` |
| Trace snapshot scope | `src/systems/simulation_snapshot.lua` |
| Replay compatibility | `src/systems/replay.lua`, `src/systems/replay_library.lua` |
| Existing level exporter | `tools/dump_level.lua` |
| Existing shot search | `tools/test_style_shot.lua` |
| Architecture and mechanics | `wiki/architecture.md`, `wiki/gameplay-pipeline.md`, `wiki/game-mechanics.md` |
