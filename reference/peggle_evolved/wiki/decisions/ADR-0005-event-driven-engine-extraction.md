# ADR 0005: Event-Driven Game Engine Extraction

## Status

Accepted

## Context

The codebase contained significant duplication between `src/states/game.lua` (the main gameplay loop) and `src/bench/mode.lua` (the CLI-driven benchmark and replay runner). Over 500 lines of identical logic covering simulation stepping, fixed-timestep accumulation, aiming/DAS controls, and rendering were duplicated across both files.

However, the implementations slightly diverged in specific areas:
- **Scoring**: `game.lua` tracked player score based on a sequence of turns, whereas `mode.lua` kept a simple flat `totalScore`.
- **Bucket bonuses**: `game.lua` awarded a free ball (solo) or incremental point bonuses (1v1). `mode.lua` awarded a flat bucket bonus.
- **Game over logic**: `game.lua` applied 1v1 specific penalties for no red-pegs, halted the simulation, and rendered a "Return to Menu" UI. `mode.lua` handled benchmark exits (`Perf.saveAndExit()`), or blindly looped levels.

Whenever simulation fixes (such as continuous collision trace exports, stall detection times, or clearing cascade fixes) were applied, they had to be manually synced between the two files. If they weren't synced properly, the benchmark trace logs would generate mismatched results when analyzing standard gameplay shots.

## Decision

We have extracted all shared gameplay logic into a unified **`Engine`** component (`src/engine/core.lua`). 

The engine uses an **Event-Driven Architecture** to handle divergences between contexts. Rather than managing mode-specific rules directly, it operates completely standalone and exposes behavioral hooks through a callback configuration table provided during initialization.

```lua
self.engine = Engine.new({
    onHUDRefresh = function(eng) ... end,
    onLaunch = function(eng) ... end,
    onBucketCatch = function(eng, ball) ... end,
    onFeverCatch = function(eng, ball, value) ... end,
    onTurnEnd = function(eng) ... end,
    onAllBallsDepleted = function(eng) ... end
})
```

`game.lua` and `mode.lua` now both instantiate `Engine`. They delegate `update()`, `draw()`, `mousepressed()`, and `keypressed()` events to the engine, allowing it to manage the unified physics and gameplay logic, while handling their specialized behavior exclusively in the callbacks.

## Consequences

**Positive:**
- Complete parity between gameplay runs and benchmark/replay runs. Replays are guaranteed to behave identically because they use the exact same state machine.
- `src/states/game.lua` has been reduced from ~900 lines to ~350, entirely focused on UI state, player turn orchestration, and 1v1 rules.
- `src/bench/mode.lua` is similarly reduced, focused purely on instrumenting LuaJIT profiling and Perf metric saving.

**Negative:**
- State is now split between `GameState`/`BenchMode` (which hold scores and configurations) and the `Engine` (which holds all active entities). UI callbacks must be mindful to reference `engine.active_balls` instead of `self.active_balls`.
