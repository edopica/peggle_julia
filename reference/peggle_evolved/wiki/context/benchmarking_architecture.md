# Benchmarking and Profiling Architecture

This document describes the implementation details of the benchmarking system in Peggle Evolved, primarily handled by the `src/systems/perf.lua` module. The system provides real-time performance metrics to help detect bottlenecks in the physics and rendering loops.

## The `Perf` Module
The benchmarking tool is designed as a lightweight, singleton-like module. It tracks execution times and counts operations, periodically dumping the statistics to the console.

### 1. Initialization and Toggle State
The module is strictly opt-in to avoid any overhead during normal gameplay. It is initialized via `Perf.init(enabled)`, which sets the internal flag `Perf.is_enabled`.
If the module is not enabled, all other functions in the module return immediately (acting as minimal-overhead no-ops).
It also detects whether **LuaJIT** is available and outputs its version and current status upon initialization.

### 2. Time Tracking Hooks
The module uses `love.timer.getTime()` to calculate execution durations. It exposes pairs of hook functions to wrap specific code blocks:
- `Perf.beginUpdate()` / `Perf.endUpdate()`: Wraps the core game logic and physics simulation.
- `Perf.beginDraw()` / `Perf.endDraw()`: Wraps the rendering pipeline.

These times are accumulated over the course of multiple frames.

### 3. Metric Counters
In addition to frame timings, the system tracks specific intensive operations by exposing increment/setter functions:
- `Perf.incPegChecks(n)`: Tracks the number of broadphase (distance) checks performed against pegs. Called heavily from within `physics.lua`.
- `Perf.incCollisions(n)`: Tracks the number of exact physical impacts resolved.
- `Perf.setActiveBalls(n)`: Tracks the number of balls currently being simulated.

### 4. Reporting
The `Perf.report(dt)` function is called every frame. It acts as the aggregator:
- It accumulates the delta time (`dt`) and increments the `frames` counter.
- Once the internal timer reaches **1.0 second**, it calculates the averages over the past second:
  - Average `dt` (ms)
  - Average `update` time (ms)
  - Average `draw` time (ms)
- It fetches the current `fps` via `love.timer.getFPS()`.
- It fetches the current state of the LuaJIT compiler.
- It dumps a formatted string to standard output (console) with all these metrics.
- Finally, it zeroes out the accumulators and counters to start fresh for the next second.

### Example Output
```text
--- BENCHMARK MODE ENABLED ---
LuaJIT: true | version=LuaJIT 2.1.0-beta3 | arch=x64 | status=true
BENCH | fps=60 | avg_dt=16.667ms | update=1.205ms | draw=0.850ms | peg_checks=452 | collisions=3 | active_balls=1 | jit=true
```
