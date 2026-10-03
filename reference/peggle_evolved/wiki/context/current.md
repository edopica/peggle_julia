# Current System Context & Architecture

This document serves as a high-level snapshot of the software architecture, repository layout, and runtime execution flow of **Peggle Evolved**. For detailed module descriptions, dependency graphs, and 26-phase simulation ordering, see the canonical [architecture.md](../architecture.md).

---

## 1. Directory Layout

```
peggle_evolved/
├── main.lua                    # Thin orchestrator: CLI args, delegates to bench mode or state machine
├── Makefile                    # Shortcuts: run, trace, bench
├── temp/                       # Ephemeral planning docs (gitignored)
├── tools/                      # Standalone CLI tools (level checker, dumper, trace exporter)
├── wiki/                       # Structured project documentation
│   ├── quickstart.md
│   ├── architecture.md
│   ├── game-mechanics.md
│   ├── audits/                 # Detailed technical reviews and verification
│   ├── context/                # System architecture & current state (this file)
│   ├── decisions/              # Architecture Decision Records (ADRs)
│   ├── devlog/                 # Dated developer progress logs
│   ├── failures/               # Bug post-mortems and failure reports
│   └── templates/              # Documentation templates
└── src/
    ├── config.lua              # Central hot-reloadable game parameters
    ├── cli_options.lua         # Shared CLI flags for GameState / BenchMode
    ├── engine/
    │   └── core.lua            # 26-phase simulation coordinator (Engine class)
    ├── bench/
    │   └── mode.lua            # Standalone benchmark / replay game loop
    ├── entities/               # Game objects (ball, bucket, fever_buckets, peg)
    ├── levels/                 # Level layout definitions (including benchmarks)
    ├── states/                 # State machine (Menu, LevelSelect, Game — one file each)
    │   └── init.lua            # State router (States table + switch())
    └── systems/                # 24 runtime subsystems (see below)
```

---

## 2. Core Architecture & Subsystems

### A. Entry Point: `main.lua`

- **Role:** Thin orchestrator that parses CLI arguments and dispatches to either the benchmark/replay game loop (`src/bench/mode.lua`) or the normal state-machine gameplay (`src/states/`).
- **CLI Options:** `src/cli_options.lua` holds session-wide flags (`gameplay_trace_file`, `retain_shot_timeline`, `headless`) shared between `main.lua` and `GameState`.
- **Hot-Reloading:** Config reloading on `R` key is handled in `GameState:keypressed()` (normal mode) and `src/bench/mode.lua` (bench mode).

### B. Configuration: `src/config.lua`

- **Role:** Houses all design constants: gravity, window size, restitution, ball launch velocity, peg dimensions, score bonuses, timing thresholds, aim parameters, and style-shot distances.
- **Key defaults:** Virtual resolution `1200×1900`, `fullscreen = true`, `aim_discretization_steps = 2000`, `fixed_dt = 1/60`.
- **Modularity:** Returns a central table. Reloading replaces its contents in-place so dependent modules reference the same table and pick up changes instantly.

### C. Entities Layer (`src/entities/`)

- **`ball.lua`:** Active projectile with position, velocity, radius, and `launched` (boolean flag). `launched = false` means waiting at the top for aim.
- **`peg.lua`:** Three shape constructors — circle (`Peg.new`), rectangle (`Peg.new_rectangle`), annular/arc (`Peg.new_annular`). Tracks `hit` state, `multiplier_at_hit`, motion attachment (`peg.motion`), and pre-computed collision geometry.
- **`bucket.lua`:** Sliding catcher at screen bottom with sinusoidal motion. Three sub-rectangles for bounce detection; catch when ball enters the middle hole.
- **`fever_buckets.lua`:** Five-slot catcher replacing normal bucket during fever (×100 multiplier). Values: `{10000, 50000, 100000, 50000, 10000}`.

### D. Engine (`src/engine/`)

- **`core.lua`:** The `Engine` class — central simulation coordinator with a 26-phase fixed-timestep loop. Manages pegs, balls, accumulator, multiplier, event pipeline (GameplayEvents + GameplayCommands), identity namespace (ball IDs), and rendering interpolation. Factory method `Engine.new(callbacks)` accepts hooks: `onBucketCatch`, `onTurnEnd`, `onStyleShot`, `onStepFinalized`, etc.

### E. Subsystems Layer (`src/systems/`) — 28 modules

| Category | Modules |
|----------|---------|
| **Physics & Collision** | `physics` (CCD engine), `impact_geometry` (TOI/sep helpers), `contact_events` (render-only presenter), `impact_debug` (collision instrumentation) |
| **Gameplay Event Pipeline** | `gameplay_events` (per-step journal), `exportable` (payload deep-copy), `gameplay_commands` (ordered buffer), `style_shots` (recognition), `slide_inversion` (valley apex detection), `ball_state` (idle/timeout), `simulation_snapshot` (state capture), `gameplay_trace_exporter` (canonical JSONL) |
| **Peg Systems** | `peg_colors` (deterministic color + purple queue), `circuits` (movement), `circuit_primitives` (declarative paths), `motion_schema` (load-time motion validation), `powers` (green peg abilities) |
| **Rendering / I/O** | `screen` (virtual resolution + letterboxing), `perf` (benchmark instrumentation) |
| **Level Management** | `level_manager` (loading + per-level resolution), `level_validator` (wall-boundary discard), `path` (path primitives), `lines` (zero-gap line generation) |
| **Dev / QA Tools** | `overlap_detector` (SAT overlap checks), `circuit_analyzer` (dynamic overlap), `level_checker` (orchestrator), `replay` (shot capture), `trace_exporter` (legacy entity JSONL) |

See [architecture.md](../architecture.md) for full dependency graph, data flow, and detailed per-module descriptions.

---

## 3. Guiding Principles & Constraints

1. **Determinism First:** All simulation logic uses fixed time-steps (`dt = 1/60`), explicit `ipairs` table iterations, and seeded `love.math.newRandomGenerator` instances. Time-of-impact ties are broken by explicit priority ordering (wall > circle_peg > rect_peg > annular_peg > extra_circle) and then by peg index.
2. **No Box2D Dependency:** Physics collision detection and resolution are fully custom (swept CCD with sub-stepping, rotation slicing, and end-of-frame de-penetration).
3. **Structured Documentation:** Technical records follow the `audits/`, `context/`, `decisions/`, `devlog/`, and `failures/` taxonomy.
4. **Event-Driven Architecture:** The engine's 26-phase `stepSimulation` strictly separates raw observations (physics facts) from derived inferences (scoring, style shots, ball state). A command buffer collects requested mutations which are applied atomically in a single phase, ensuring deterministic ordering and traceability.

---

## 4. Virtual Resolution

The game world operates at a **per-level virtual resolution** defaulting to **1200×1900** (defined in `src/config.lua`). Individual levels can override with `virtual_width`/`virtual_height` fields. The `LevelManager` resolves the active resolution at level load; the `Screen` module applies a uniform scale with letterbox/pillarbox to fit the actual window. See [ADR-0003](../decisions/ADR-0003-virtual-resolution-subsystem.md) and [ADR-0004](../decisions/ADR-0004-per-level-virtual-resolution.md) for historical context and evolution.
