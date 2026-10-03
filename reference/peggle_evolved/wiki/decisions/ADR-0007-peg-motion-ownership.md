# ADR-0007: Peg Motion Ownership Refactor

## Status
Accepted

## Context

Before this refactor, moving pegs were assigned to circuits through three
overlapping mechanisms:

1. Legacy flat authoring fields on the peg: `circuit_id` (circuit reference)
   and `circuit_t` (initial path position), plus runtime
   `circuit_state`/`circuit_timer`.
2. Circuit-owned peg arrays: a circuit definition could carry `pegs = {...}`,
   which `Engine:setupLevel()` merged into the global peg list at load time,
   assigning `circuit_id` on the fly.
3. Mixed runtime handling: peg transforms were applied inside
   `Circuits.update()` with per-step state spread across the peg and the
   circuit definition.

This split ownership made levels harder to author and audit, made circuit
definitions mutable during simulation, and complicated replay/snapshot
formats. Replays captured flat circuit fields (including a `base_angle` bug
that could capture the current applied rotation instead of the declared
base), and could not restore mid-shot motion state exactly.

## Decision

1. **`level_data.pegs` is the only peg collection.** Circuit definitions
   (`level_circuits`) are immutable at runtime and never own pegs. Any
   circuit definition containing a `pegs` array fails load-time validation.
2. **Moving pegs carry `peg.motion = { circuit = <id>, phase = <number> }`**
   (authoring fields). Runtime state lives on the same table:
   `motion.time` (current path position, starts at `phase`),
   `motion.state` (`"moving"` | `"paused"`), `motion.timer` (move/pause
   cycle timer). `phase` stays immutable.
3. **Circuits split into initialize/update.**
   `Circuits.initialize(pegs, circuit_defs)` applies the declared-phase
   transform once during level setup with zero velocity;
   `Circuits.update(pegs, circuit_defs, dt)` advances each step and
   computes velocities as the secant `(end - start) / dt`, preserving
   timer overshoot across move/pause boundaries.
4. **`motion_schema.lua` validates at load time.** Hard errors for legacy
   authoring fields, unknown circuit references, malformed primitives, and
   timed circuits without `pause_time`. `path_fn`-only circuits remain
   runnable with a one-time warning.
5. **Replays use `schema_version = 2`** with per-peg base transform,
   current transform, velocities, `hit_order`, and full runtime motion
   state; `base_angle` is always the declared base. Legacy captures remain
   loadable through a compatibility adapter in `Engine:applyReplayState`.
6. **Snapshots** keep flat `circuit_id`/`circuit_t`/`circuit_state`/
   `circuit_timer` fields derived from `peg.motion` (trace compatibility)
   and add an authoritative `motion` sub-table.
7. **Levels migrate by merging circuit-owned pegs into `pegs`** in the
   normalized order (preserving peg order, colors, collisions, and
   replays) and replacing flat assignments with `peg.motion`. The legacy
   grid benchmark levels (100–1000 pegs) and `test_rotation` were removed
   rather than migrated.

## Consequences

### Positive
- Single source of truth for peg ownership; circuit definitions are pure
  path data.
- Motion state is complete and self-contained per peg, which makes
  snapshots and replays exact (mid-shot captures restore byte-identical
  continuations).
- Load-time validation catches authoring errors deterministically instead
  of failing mid-simulation.
- Annular peg geometry is now rebuilt from base geometry whenever the
  applied rotation changes (including returning to zero), fixing stale
  rotation drift.

### Negative / Trade-offs
- Two-phase validation: base-position boundary validation runs before
  motion initialization (preserving baseline surviving sets), while the
  initialized-position check is warning-only; out-of-bounds phase
  positions are therefore possible by design.
- Legacy replay compatibility code must be retained in
  `Engine:applyReplayState`.
- `path_fn` circuit support remains as a runtime fallback (deprecated but
  functional).
