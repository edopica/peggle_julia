# Peggle Evolved — Quickstart

**Peggle Evolved** is a 2D Peggle clone built with [LÖVE2D](https://love2d.org/) (v11.x) and Lua (LuaJIT). The project uses a custom continuous collision detection (CCD) physics engine for deterministic simulation, code-driven levels defined as Lua tables, a fixed-timestep game loop, and a state machine for UI navigation.

## Running the game

```bash
love .
```

LÖVE2D must be installed separately. The project requires LuaJIT (the default Lua runtime distributed with LÖVE2D).

On launch, the game starts at the **main menu**:
- **Solo Mode** — single player, bucket gives free balls, no penalties
- **1v1 Mode** — alternating turns with Player 1/Player 2, bucket gives incremental points (2500 × catch count), -25% score penalty if no red pegs hit in a turn

Select a level from the list (non-benchmark levels only). A scaled preview of the level's pegs is shown on the right. Press `Start` to begin.

## CLI flags (benchmarking & debugging mode)

```
love . -- --bench            Enable benchmarking mode (disables rendering overhead)
love . -- --bench --nojit    Benchmark with LuaJIT disabled
love . -- --bench --balls N  Fire N balls simultaneously
love . -- --bench --level NAME  Load a specific benchmark level
love . -- --profile          Enable jit.profile sampling
love . -- --replay SELECTOR  Load a saved shot replay instead of a standard level.
                             SELECTOR is a path, a saved name/label, or "latest"
love . -- --list-replays    List saved replays in replays/ and exit
love . -- --export-traces FILE  Export JSONL traces of the entire physics frame sequence
love . -- --export-gameplay-traces FILE  Export canonical gameplay event trace (events, commands, snapshots) per fixed step
love . -- --retain-shot-timeline  Keep shot-per-step event journals in memory (for analysis / debugging)
love . -- --headless         Disable rendering/audio (contact presentation off)
love . -- --impact-debug [FILE]  Log every physical collision (frame, iteration, TOI, impact center, separations, velocities) to JSONL (default temp/impact_log.jsonl) and draw persistent markers at exact impact centers
love . -- --present-debug [FILE]  Log every presented frame (render/sim step ids, alpha, dt, vsync, actual sampled ball/peg transforms, world/screen surface separation per pending collision) to JSONL (default temp/present_log.jsonl)
love . -- --contact-present off  Disable the render-only contact presenter (guaranteed one-frame exact-contact presentation per collision); A/B diagnostic
love . -- --time-scale N      Scale simulation time by N while rendering normally (e.g. 0.02 for slow-motion presentation diagnostics, 3 for multi-step-per-draw stress)
love . -- --test-style-shot --level LEVEL --target-style STYLE  Fast-forward thousands of aim angles to find a trick shot, then switch to interactive replay mode
```

In benchmark mode, the game simulates the turn automatically and writes results to `benchmark_results.csv` before exiting. 
When testing shots interactively, the game automatically captures the physics setup of your last launched shot to `src/replays/last_shot.lua`. You can replay this exact shot via `make trace` or `love . -- --replay src/replays/last_shot.lua --export-traces debug_trace.jsonl`. For richer event-level debugging (peg scoring, commands, style shots), use `--export-gameplay-traces debug_gameplay.jsonl --retain-shot-timeline`. Replay runs are one-shot: the game terminates by itself when the replayed shot completes (immediately, when the capture holds no live balls).

To keep a shot permanently, press `F8` in-game while the last shot is still buffered. This opens a naming prompt: leave the field blank to use the capture timestamp (`YYYYMMDD_HHMMSS`), or type a label to append. Saved replays live in `replays/` (gitignored) and are never overwritten. Browse and replay them with:

```bash
make replays              # list saved replays
make replay               # replay the newest one
make replay cool_shot     # replay by unique name/label
love . -- --replay latest # equivalent CLI form
```

Because saves are timestamped, every shot is preserved instead of replacing the previous one. `last_shot.lua` and `make trace` keep working unchanged for the rolling capture.

If you are developing new levels or debugging style shots and need to find an angle that triggers a specific mechanic (e.g. `long_shot` or `lucky_bounce`), you can use the built-in brute forcer:
```bash
make test-styles <style_name>
# Example: make test-styles lucky_bounce
```
This headless search takes only fractions of a second to evaluate the entire 180° arc and drops you into a visual viewer where you can instantly step between successful trajectories.

## Project philosophy

- **Deterministic physics**: Custom CCD, no Box2D. Everything uses a fixed `dt = 1/60`, a seeded RNG (`love.math.newRandomGenerator`), and `ipairs` (never `pairs`) for physics iteration order.
- **Stable ball identities**: Every ball receives a unique permanent integer ID (≤ 2⁵³−1) for the lifetime of the Engine instance. IDs are never reused across turns, shots, or levels. Both `registerBall` and `applyReplayState` perform complete identity preflights before any authoritative state mutation.
- **Code-first levels**: Levels are Lua files in `src/levels/` that return peg arrays and configuration tables. No visual editors.
- **Hot-reloadable config**: `src/config.lua` can be reloaded at runtime with `R` key. Module cache is cleared so dependent systems pick up changes.

## Repository map

| Area | Location | Purpose |
|------|----------|---------|
| Entrypoint & game loop | `main.lua` | LÖVE callbacks, CLI arg parsing, delegates to bench mode or state machine |
| CLI shared options | `src/cli_options.lua` | Session-wide CLI flags (gameplay trace, timeline, headless) shared between main.lua and GameState |
| State machine & game logic | `src/states/` | Menu, Level Select, and Game states (one file each); state router in `src/states/init.lua` |
| Core engine | `src/engine/core.lua` | 26-phase fixed-step simulation loop; peg scoring, clearing, aim, event/command pipeline orchestration |
| Bench / replay mode | `src/bench/mode.lua` | Standalone benchmark and shot-replay game loop |
| Configuration | `src/config.lua` | All tunables: physics, display, peg types, scoring rules, style-shot thresholds, gameplay params |
| Entities | `src/entities/` | Ball, Peg (circle/rectangle/annular), Bucket, FeverBuckets |
| Systems — Physics & collision | `src/systems/` | `physics.lua` (CCD engine), `impact_geometry.lua` (TOI/sep helpers), `contact_events.lua` (render-only presenter), `impact_debug.lua` (collision instrumentation) |
| Systems — Gameplay pipeline | `src/systems/` | `gameplay_events.lua` (per-step event journal), `gameplay_commands.lua` (command buffer), `style_shots.lua` (style recognition), `slide_inversion.lua` (valley pendulum apex detection), `ball_state.lua` (idle/no-score detection), `simulation_snapshot.lua` (state capture), `gameplay_trace_exporter.lua` (canonical JSONL trace) |
| Systems — Other | `src/systems/` | `peg_colors.lua`, `circuits.lua` (+ `circuit_primitives.lua`, `motion_schema.lua`), `powers.lua`, `screen.lua`, `perf.lua`, `level_validator.lua`, `replay.lua`, `replay_library.lua`, `trace_exporter.lua`, `level_manager.lua`, `overlap_detector.lua`, `circuit_analyzer.lua`, `level_checker.lua` |
| Levels | `src/levels/` | Level definitions (including benchmark levels) |
| Tests | `tests/` | Unit + integration tests (343 total across 19 files): gameplay events, commands, style shots, ball state, slide inversion, simulation snapshot, trace exporter, engine integration, step record ownership, ball IDs, level manager, replay compat, motion schema, circuits |
| Wiki docs | `wiki/` | Architecture, game mechanics, audits, ADRs, devlog, failure post-mortems |
| Standalone tools | `tools/` | Level checker, dumper, trace exporter, JSON library, quick test runner |

## Where to go next

- **[Architecture](architecture.md)** — Module dependency graph, data flow through the game loop, entity-system relationships, virtual resolution subsystem.
- **[Gameplay Event Pipeline](gameplay-pipeline.md)** — Mermaid diagrams of the phase 1 event/command pipeline: data flow, the 26-phase `stepSimulation` timeline, and the canonical `StepRecord` trace structure.
- **[Game Mechanics](game-mechanics.md)** — Scoring formula, multiplier tiers, fever/ultra-fever, purple peg queue, clearing cascade, circuit-based peg movement, green peg powers.

## Key existing documentation

The following directories contain structured documentation that predates the unified wiki:

| Document | What it covers |
|----------|---------------|
| `context/current.md` | Architecture overview and directory layout |
| `context/physics_and_pegs.md` | Deep dive into CCD collision detection, peg shapes, broadphase |
| `context/benchmarking_architecture.md` | Perf system metrics and reporting |
| `decisions/ADR-0001-custom-ccd-physics.md` | Why custom physics was chosen |
| `decisions/ADR-0002-decoupled-level-management.md` | Level management design rationale |
| `decisions/ADR-0003-virtual-resolution-subsystem.md` | Virtual resolution (1200×1900) design (partially superseded by ADR-0004) |
| `decisions/ADR-0004-per-level-virtual-resolution.md` | Per-level virtual resolution with LevelManager |
| `audits/` | Technical correctness audits (physics, color assignment) |
| `failures/` | Post-mortems for notable bugs |
| `devlog/` | Development history and decisions |

## Quick reference: debug keys

| Key | Action |
|-----|--------|
| `Escape` | Return to main menu (from game or level select) |
| `R` | Reload config and restart level |
| `F3` | Toggle debug overlay (FPS, memory) |
| `F4` | Toggle JIT profiler dump to `profile_dump.txt` |
| `F5` | Restart the game (hard reload) |
| `F6` | Load benchmark lasagna level |
| `F8` | Save the last launched shot to `replays/` (opens a naming prompt) |
| `Enter` | Launch ball (same as mouse click); confirm selection in menus |
| Up/Down arrows | Navigate level list (in level select) |
| Left/Right arrows | Aim adjustment: tap = 1 discrete step, hold >0.2s = continuous sweep (in game) |
| Mouse wheel | Aim adjustment (2 degree increments) (in game) |
| Mouse right-click | Fast-forward circuits & bucket 5× (only when ball is not active) |
