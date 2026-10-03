# Architecture

## Module dependency graph

```
main.lua
├── src/cli_options.lua      (shared CLI flags for GameState/BenchMode)
├── src/states/              (state machine: Menu, LevelSelect, Game)
│   ├── src/states/init.lua          (state router + switch())
│   ├── src/states/menu.lua          (MenuState)
│   ├── src/states/level_select.lua  (LevelSelectState)
│   └── src/states/game.lua          (GameState)
├── src/config.lua           (global configuration, hot-reloadable)
├── src/systems/level_manager.lua (per-level resolution + level loading)
├── src/systems/physics.lua  (custom CCD engine; emits raw contact events)
├── src/systems/peg_colors.lua (deterministic color assignment)
├── src/systems/circuits.lua (peg movement along paths)
│   ├── src/systems/circuit_primitives.lua (declarative path primitives)
│   └── src/systems/motion_schema.lua (load-time motion validation)
├── src/systems/powers.lua   (green peg powers; returns spawn specs)
├── src/systems/screen.lua   (virtual resolution + letterboxing)
├── src/systems/perf.lua     (benchmarking instrumentation)
├── src/systems/level_validator.lua (wall-boundary peg discard)
├── src/systems/replay.lua   (shot setup capture and restoration)
├── src/systems/trace_exporter.lua (JSONL frame-by-frame entity tracing)
├── src/systems/impact_debug.lua (--impact-debug collision instrumentation)
├── src/systems/impact_geometry.lua (pure TOI/separation geometry helpers)
├── src/systems/contact_events.lua (render-only contact presentation queue)
├── src/systems/gameplay_events.lua (per-step append-only event journal)
├── src/systems/exportable.lua (validated deep-copy for journal-owned payloads)
├── src/systems/gameplay_commands.lua (ordered authoritative command buffer)
├── src/systems/style_shots.lua (deterministic style-shot recognition)
├── src/systems/ball_state.lua (per-ball idle/no-score detection)
├── src/systems/slide_inversion.lua (zero-gap valley pendulum apex detection)
├── src/systems/simulation_snapshot.lua (deterministic state capture)
├── src/systems/gameplay_trace_exporter.lua (canonical JSONL gameplay trace)
├── src/entities/ball.lua    (ball state + drawing)
├── src/entities/peg.lua     (peg shapes, transform, drawing)
├── src/entities/bucket.lua  (sliding catcher + ball resolution)
└── src/entities/fever_buckets.lua (fever-mode 5-slot catcher)
```

Every module is a singleton table returned via `require`. There is no dependency injection framework — modules receive references to shared state tables (pegs, balls) passed as function arguments from the game state.

### State machine (`src/states/`)

The game uses a simple state machine with three states, each in its own file, managed via `States.switch(name, ...)`. `main.lua` is a thin orchestrator that delegates all LÖVE callbacks (`update`, `draw`, `mousepressed`, etc.) to the current state.

| State | File | Key | Purpose |
|-------|------|-----|---------|
| Menu | `src/states/menu.lua` | `menu` | Title screen with Solo/1v1 mode selection |
| Level Select | `src/states/level_select.lua` | `level_select` | Level list (scanned from `src/levels/`, benchmarks hidden) with scaled peg preview |
| Game | `src/states/game.lua` | `game` | Full gameplay loop with mode-dependent mechanics |

The state router (`src/states/init.lua`) provides the `States` table with `switch(name, ...)` for transitioning between states. State modules self-register into the `States` table at load time. `main.lua` loads all state modules during initialization so they are available before the first `switch()` call.

Each state is a Lua table with optional `enter(...)`, `leave()`, `update(dt)`, `draw()`, `mousepressed(x, y)`, `mousemoved(x, y, dx, dy)`, `wheelmoved(x, y)`, and `keypressed(key)` methods. The `enter(...)` method receives arguments from `States.switch()`.

The `Engine` (in `src/engine/core.lua`) carries all core game logic (physics, scoring, clearing cascade, aim) as methods on its class. Player data (`players` array) replaces the old global scoring variables to support 1v1 mode and lives in `GameState`. Benchmark and replay CLI modes bypass the state machine entirely, but both `game.lua` and `mode.lua` utilize the exact same `Engine` instance, resolving divergences via injected event callbacks.

## Game loop (`Engine` in `src/engine/core.lua`)

The game loop follows a **fixed-timestep accumulator pattern** inside `Engine:update(dt)`:

```
update(dt)
  → Perf.beginUpdate()
  → accumulator += dt
  → ContactEvents.set_step(sim_step_id)   (presentation bookkeeping)
  → ContactEvents.begin_frame(engine, alpha)
  → while accumulator >= fixed_dt (1/60):
      Engine:savePreviousState() (caches positions/angles for rendering interpolation)
      Engine:stepSimulation(fixed_dt)   (26 explicit phases — see below)
  → ContactEvents.end_frame()
  → aim input processing           (keyboard + mouse)
  → stall detection overrides      (velocity idle, ball frozen)
  → launching conditions           (all balls launched check)
  → Perf.endUpdate()
```

### stepSimulation phases (26 phases + 18b)

The simulation step follows a strict deterministic ordering, documented inline in `src/engine/core.lua`:

| # | Phase | Description |
|---|-------|-------------|
| 1 | `begin_step` | Open GameplayEvents/Commands for `sim_step_id` + `shot_id`; flush staged events (e.g. `ball_launched`) |
| 2 | Register balls | Assign stable IDs to any un-IDed active balls |
| 3 | Time step + ultra-fever | Compute `time_step` (right-click circuit speedup); check ultra-fever condition |
| 4 | Bucket motion | Slide bucket (skipped in fever mode) |
| 5 | Clearing early path | If `clearQueue` is active, call `updateClearing()` then `goto finalize` |
| 6 | Circuits update | Move pegs along their `level_circuits` paths |
| 7 | Physics | CCD collision step → **raw** `ball_contacted_peg` / `ball_contact_ball` events (observational; physics does not mutate `peg.hit`) |
| 8 | Stamp `draw_path` | Record `path_step` for rendering interpolation |
| 9 | All-launched guard | Skip bucket resolution if any ball not yet launched |
| 10 | **Reduce peg contacts** | Authoritative first-hit scoring: iterate raw contacts, assign `hit_order`/`multiplier_at_hit`, update red/fever/purple state, stage green power spawns, **buffer** `peg_scored` derived events |
| 11 | Bucket/fever resolution | Detect catches/bounces → raw `ball_bucket_resolved` events → mode callbacks (`onBucketCatch`, `onFeverCatch`) |
| 12 | Fall-out detection | Balls below screen → raw `ball_fell_out` events |
| 13 | Remove balls | Stable-order removal; notify BallState |
| 14 | Spawn power balls | Append green-power spawns to `active_balls`; register and stage `ball_spawned` |
| 15 | Shot-end detection | If no active balls remain → `startClearing()` or `shot_end_pending = true` |
| 16 | **Seal raw events** | Freeze the raw phase; only derived events after this |
| 17 | **Emit peg_scored** | Append buffered `peg_scored` derived events in source order (with `source_sequence` pointing to the raw contact) |
| 18 | **StyleShots** | Process the step → push `award_style_points` commands |
| 18b | **SlideInversion** | Detect a ball reversing along a zero-gap slide line (pendulum apex) → push `remove_slide_pegs`; skipped while a clearing cascade is active |
| 19 | **BallState** | Derive `ball_became_idle`/`ball_reactivated`/`all_balls_became_idle`/`no_score_timeout_reached` events; push `start_midturn_clearing` commands |
| 20 | **Apply commands** | Execute commands in deterministic insertion order (style awards, midturn clear); emit `style_awarded` derived events |
| 21 | **Shot lifecycle** | If `shot_end_pending`, emit `shot_completed` derived event with final score components (AFTER commands so totals are authoritative) |
| 22 | **Simulation snapshot** | Capture deterministic deep-copy of Engine state (if trace or timeline is enabled) |
| 23 | **Finalize step record** | Assemble step record from detached event snapshot (`GameplayEvents:snapshot()`); optionally retain in `current_shot_timeline` + export to `GameplayTraceExporter`; legacy `TraceExporter.record_frame` |
| 24 | Presentation notify | Fire `onStepFinalized` callback (read-only) |
| 25 | **Shot-end handoff** | If `shot_end_reason` is set: finalize shot timeline, fire `onTurnEnd` (which may start the next shot) |
| 26 | Cleanup | `finish_step` on events and commands |

### Key ordering rules

- **Phase 10 (reduce)** runs _before_ phase 18 (StyleShots), phase 18b (SlideInversion), and phase 19 (BallState) so those processors see the complete derived `peg_scored` events.
- **Phase 16 (seal)** strictly separates raw (observation) from derived (inference).
- **Phase 20 (apply commands)** runs after all processors have pushed commands, so engine state is mutated only once per step.
- **Phase 21 (shot_completed)** is after command application so its `total_score` includes style awards applied this step.
- Phase 12-14 (fall-out + removal + spawn) ensure green-spawned balls do NOT participate in the same step's scoring or resolution — they begin physics on the next step.
- `goto finalize` (Lua 5.2+) ensures every code path — including clearing early-return and unlaunched-balls skip — reaches phases 16-26 for a consistent step record.
- The physics block (phase 7) and reduction block (phase 10) use a `do ... end` scope (lines 570-709) so locals do not cross the `goto finalize` boundary.

### Stable ball identities (`src/engine/core.lua`)

Every launched ball receives a **stable integer ID** that is unique and permanent
for the lifetime of one `Engine` instance. The identity namespace is
instance-scoped and survives `setupLevel()`, `resetTurn()`, shot completion,
clearing, and ball removal. Only `Engine.new()` starts a fresh namespace.

**Identity state** (per instance, initialized in `Engine.new()`):

| Field | Type | Purpose |
|-------|------|---------|
| `next_ball_id` | integer | Next candidate for automatic allocation; monotonically increases |
| `used_ball_ids` | `[id] = true` | Permanent consumed-ID set — IDs are never removed or reused |
| `live_ball_ids` | `[id] = ball` | Forward mapping: currently registered live balls |
| `live_id_by_ball` | `[ball] = id` | Reverse mapping: enables idempotent re-registration and mutation detection |

**Domain**: IDs are positive finite integers at or below `MAX_BALL_ID` (2⁵³−1 =
`9007199254740991`), the largest integer exactly representable in a Lua double.
Automatic allocation never returns `MAX_BALL_ID + 1` — the sentinel represents
an exhausted frontier.

**`Engine:registerBall(b)`** assigns and validates an ID for a Ball object:

- **Automatic** (`b.id == nil`): Scans forward from `next_ball_id` skipping
  consumed IDs, assigns the first available candidate ≤ `MAX_BALL_ID`. If the
  allocator is exhausted (`candidate > MAX_BALL_ID`), errors with a clear
  message **before any state mutation** — `next_ball_id`, `used_ball_ids`,
  live maps, and the ball's `id` field are all unchanged.
- **Explicit** (`b.id` is a valid number): Validated via `Engine.validateBallId`
  (type, finiteness, positivity, integrality, ≤ `MAX_BALL_ID`). Explicit IDs
  may arrive out of numeric order; `next_ball_id` is advanced to `max(next,
  id + 1)` only on success.
- **Idempotent**: Re-registering the same Ball table with its current registered
  ID returns immediately without consuming another ID or changing state.
- **Mutation detection**: Changing a live ball's `b.id` to another number or
  `nil` and then calling `registerBall` raises an error before any mutation.
- **Consumed-ID rejection**: An ID already in `used_ball_ids` or currently live
  in `live_ball_ids` is rejected.

All four validation checks (idempotency, mutation, consumed reuse, duplicate
live) run before the commit block (the line `-- All validations passed: commit`).
A failed registration leaves **no** allocator state, used-ID set, live mapping,
or Ball field changed.

**`Engine:unregisterBall(b)`** removes only live mappings (`live_ball_ids` and
`live_id_by_ball`). The ID stays permanently consumed in `used_ball_ids`.
Uses the stored mapping (`live_id_by_ball[b]`) rather than trusting `b.id`, so
changing a ball's ID to `nil` after registration is detected before mappings are
removed.

**Preflight planner (`_planBallRegistrations`)** validates an entire batch of
candidate balls using shadow state (`shadow_next`, `shadow_used`,
`shadow_ball_to_id`) without touching any authoritative Engine field or Ball
object. Used by both `resetTurn` and `applyReplayState` to guarantee
failure-atomicity: if any ball in the batch has an invalid, duplicate, or
consumed ID, the entire batch is rejected before any mutation.

**`setupLevel` cleanup**: Explicitly replaces `live_ball_ids` and
`live_id_by_ball` with fresh empty tables — this clears stale mappings from
balls that were registered but not in `active_balls`. The permanent identity
namespace (`used_ball_ids`, `next_ball_id`) is preserved so the next automatic
allocation starts above all previously consumed IDs.

**Replay identity preflighting**: `applyReplayState` constructs candidate Ball
objects locally from the replay data and runs `_planBallRegistrations` before
installing any world state (pegs, bucket, fever, scores, ball registration).
Captured IDs are preserved; old replays without IDs receive deterministic
auto-allocation in array order. The replay's activated `shot_id` is nonzero and
no fake `ball_launched` event is staged.

### Rendering Interpolation

To ensure perfectly smooth visual movement while maintaining a deterministic 60Hz physics timestep, the game implements rendering interpolation.

* In the `update` loop, before `_stepSimulation` runs, `_savePreviousState` caches the current `x`, `y`, and `angle` (or `theta_start`) of all moving entities (Balls, the Bucket, and all Pegs).
* In the `draw` loop, an `alpha` value is calculated as `accumulator / Config.fixed_dt`.
* Entities calculate their interpolated screen coordinates based on `prev_state + (current_state - prev_state) * alpha`.
* Complex shapes (like Rectangles and Annular pegs) use Love2D's matrix transformations (`translate`, `rotate`) to visually offset their static geometry, eliminating the need to recalculate polygon vertices every frame.

### Player management

The `GameState` maintains a `Players` array with per-player state:

| Field | Purpose |
|-------|---------|
| `players[i].score` | Accumulated peg + bucket score |
| `players[i].balls` | Remaining shots (decremented on launch, replenished by bucket in solo) |
| `players[i].bucket_hits` | Consecutive bucket catches (drives incremental bonus in 1v1) |

Additional turn-level state (mirrors the old globals) is stored inside the `Engine` instance: `engine.pegs`, `engine.active_balls`, `engine.bonusScore`, `engine.totalRedPegs`, `engine.turnPegsHit`, `engine.clearQueue`, `engine.accumulator`, `engine.current_aim_angle`, etc. The `self.current_player_index` (1 or 2) tracks whose turn is active inside the `GameState`.

After a turn ends (`onTurnEnd` callback triggers `_endTurn()`):
- Turn score is added to the active player's `score`
- `bonusScore` is transferred and reset
- In **solo**: if `player.balls <= 0`, game ends
- In **1v1**: the next player with remaining balls is found; if none, game ends and winner is determined by score comparison

## Entity layer (`src/entities/`)

All entities are plain Lua tables — no classes, no metatables. Constructor functions return tables with fields set directly.

### Ball (`ball.lua`)
- **Fields**: `x`, `y`, `vx`, `vy`, `radius`, `launched` (boolean)
- **`launched`**: `false` means the ball is waiting at the top for the player to aim. When `false`, physics and clearing logic skip this ball.
- **`Ball.sampleDrawPosition(ball, alpha)`**: pure interpolated draw position (draw_path pieces, else prev→current lerp). `Ball.draw` calls it, so instrumentation and rendering use exactly the same calculation. `Ball.draw` then applies the ContactEvents contact-frame override, if any.

### Peg (`peg.lua`)
Three shapes, selected by constructor function:
- **`Peg.new(x, y, type, radius)`** — Circle peg. Sets `.shape = nil` (treated as circle).
- **`Peg.new_rectangle(x, y, type, w, h, angle)`** — Axis-aligned or oriented rectangle. Sets `.shape = "rectangle"`. Pre-computed `.cos_a`/`.sin_a` for local-space collision on update.
- **`Peg.new_annular(x, y, type, r_in, r_out, theta_start, theta_end)`** — Arc/annular section. Sets `.shape = "annular"`. Pre-computes `.corners` (4 points), `.normal_start`/`.normal_end` (cap normals), and `.polygon` (tessellated vertices for draw).

Critical fields on every peg:
- `hit` (bool), `type` (color string), `base_x`/`base_y` (circuit origin)
- `vx`/`vy`/`va` (velocity for moving pegs — used in collision response)
- `motion` (optional, for circuit movement — see [Circuits](#circuits-circuitslua--circuit-primitives-circuit_primitiveslua)): authoring fields `circuit` (id) and `phase` (initial path position), plus runtime fields `time`, `state` ("moving"/"paused"), `timer`

**`Peg.set_transform(peg, x, y, angle)`** is called by Circuits to move/rotate pegs. It updates collision geometry (corners, normals, polygon) incrementally; annular pegs rebuild their geometry from `base_theta_start + angle` whenever the applied rotation changes (including returning to zero), and translate in place otherwise.

**`Peg.sampleDrawTransform(peg, alpha)`**: pure interpolated draw transform (position lerp; angle lerp for rectangles; drawn theta for annulars), shared by `Peg.draw` and instrumentation.

**`Peg.draw(peg)`** handles lit blending via `ContactEvents.should_light(peg)`: a peg lights when `peg.visual_hit` is set (latched at the presented contact frame) or when `peg.hit` is true with no pending contact event (grazes and non-presentable hits light immediately). `peg.hit` stays the gameplay state; `peg.visual_hit` is render-only, so lighting begins on the same rendered frame as visible contact. On a contact frame the peg is drawn at its retained time-of-impact transform.

### Bucket (`bucket.lua`)
- Sliding catcher at the screen bottom. A U-shaped rect: two side walls with a hole in the middle.
- `Bucket.resolve(bucket, ball)` returns `"caught"`, `"bounced"`, or `nil`.
- Uses `collideRect()` (circle-vs-AABB with normal reflection) for the three solid sub-rectangles.

### FeverBuckets (`fever_buckets.lua`)
- Replaces the normal bucket during fever mode (`multiplier == 100`).
- Five slots with values `{10000, 50000, 100000, 50000, 10000}`, separated by 6 circular dividers.
- `FeverBuckets.resolve()` checks which slot the ball falls into; returns `"caught", value`.

## System layer (`src/systems/`)

### Physics (`physics.lua`) — see also `context/physics_and_pegs.md`

`Physics.update(balls, circle_pegs, rect_pegs, annular_pegs, dt, extra_circles, event_sink)` performs swept continuous collision detection for each launched ball, including swept circle-circle collisions between launched balls (equal-mass impulses). Every physical collision is reported to the `event_sink` (a `GameplayEvents` instance) via `event_sink:emit_raw("ball_contacted_peg", ...)` or `event_sink:emit_raw("ball_contact_ball", ...)` — physics is **purely observational** and never mutates `peg.hit`. The `event_sink` replaces the old `on_hit_callback` parameter. Collisions are also reported to `ContactEvents.record_collision` (read-only; drives the render-only contact presenter) and optionally to `ImpactDebug` (`--impact-debug`).

**Algorithm** (per ball, per sub-step):
1. **Broad phase**: sphere-sphere bounding check (`ball.radius + peg.bounding_radius + move_len`) — caches `peg.bounding_radius` lazily.
2. **Narrow phase** (in order): check walls (left/right/ceiling), circle pegs (swept circle-circle), rectangle pegs (swept circle-OBB with corner circles), annular pegs (outer arc, inner arc, caps, corners), extra circles (fever dividers).
3. **TOI selection**: candidate collisions are registered via an inner `register_hit()` function. The earliest TOI wins; ties are broken by a **priority order** (wall > circle_peg = ball > rect_peg > annular_peg > extra_circle), then by **peg/ball index** for same-priority ties. This explicit tie-breaking is the foundation of physics determinism — it replaces implicit iteration-order dependence. Within a `Config.toi_epsilon` (1e-9 seconds) window, candidates are treated as simultaneous.
4. **Resolution**: advance ball to TOI, reflect velocity along contact normal with restitution/wall-damping, push out if overlapping. A `Config.safe_t_margin` (0.001) is subtracted from TOI to avoid re-sticking on adjacent surfaces.
5. **Sub-stepping**: max 5 iterations per frame to handle multiple collisions within one fixed step.
6. **Rotation slicing**: rectangle and annular sweeps for pegs with `va ~= 0` split the sub-step window into slices bounded by `Config.rotation_sweep_arc_px` (0.5 px) of surface arc, so the frozen sweep angle never diverges from the interpolated render angle by more than a pixel (see `context/physics_and_pegs.md` §5 and `failures/0005`).
7. **End-of-frame de-penetration**: after the iteration loop, a discrete position-only pass pushes the ball out of any peg it still overlaps at the final transforms, covering iteration exhaustion on resting contacts and frozen-angle lag.
8. **Graze tolerance**: When a near-miss peg falls within `Config.graze_tolerance` (0.5 px), the engine registers a visual hit via `on_hit_callback` without deflecting the ball. For curved surfaces (circles, arcs), the quadratic discriminant is expanded, and the time of impact (`t1`) is verified to bound the graze strictly within the active motion frame. Graze application is deferred to the end of the step iteration and only committed if the graze time `t_graze` is `<= min_t + Config.toi_epsilon`. This prevents "ghost hits" where a sweep registers an infinite-trajectory graze but the ball is deflected earlier in the frame by another physical collision.

`Physics.getLaunchVelocity(x0, y0, xt, yt, v)` solves the ballistic trajectory for mouse-aiming, picking the flatter of two possible solutions.

`Physics.getSnappedAimAngle(angle)` applies `Config.aim_discretization_steps` to snap a continuous aim angle to the nearest discrete step. If discretization is disabled (`nil`), the raw angle is returned unchanged. This function is used at draw time (trajectory preview) and launch time (ball velocity) to constrain shots to a finite angle set, enabling deterministic simulations and solver-friendly search spaces. See [Game Mechanics: Aim discretization](game-mechanics.md#aim-discretization) for details on the DAS keyboard mechanic.

### PegColors (`peg_colors.lua`) — see also `audits/001-peg-color-assignment.md`

Deterministic peg type assignment using a seeded RNG:
1. At level load, `PegColors.init(pegs, type_counts, seed)` builds a shuffled color pool (Fisher-Yates), assigns types to pegs in `ipairs` order, and initializes the purple queue from all blue pegs.
2. At each turn start, `PegColors.assign_next_purple_pegs()` reverts previous active purples to blue and promotes `Config.purple_pegs_per_turn` blue pegs from the front of the shuffled queue. If the queue empties, it rebuilds from remaining un-hit blue pegs.
3. On purple peg hit, `PegColors.on_purple_peg_hit(peg)` removes it from the active list.
4. On peg removal (clearing cascade), `PegColors.on_peg_removed(peg)` purges it from both the active list and the queue.

**Determinism**: the RNG is a `love.math.newRandomGenerator` seeded once. Types are iterated in alphabetical order (`{"blue","green","purple","red"}`). `ipairs` is used exclusively.

### Circuits (`circuits.lua`) + Circuit Primitives (`circuit_primitives.lua`) + MotionSchema (`motion_schema.lua`)

Drives peg movement along parametric paths. The peg array (`level_data.pegs`) is the **only** peg collection: circuit definitions never own pegs. Each moving peg carries its assignment and runtime state in `peg.motion`:

```lua
peg.motion = { circuit = "c1", phase = 1.5 }  -- authoring (level file)
-- runtime (added by Circuits.initialize, advanced by Circuits.update):
--   motion.time  -- current path position (starts at phase)
--   motion.state -- "moving" | "paused"
--   motion.timer -- move/pause cycle timer (seconds)
```

`Circuits.initialize(pegs, circuit_defs)` runs once during level setup: it applies the declared-phase transform with zero velocity. `Circuits.update(pegs, circuit_defs, dt)` runs each fixed step: it advances the motion state through the whole interval, consuming `dt` in a loop so path time advances only during moving portions — timer overshoot across a move/pause boundary counts toward the next state but never double-counts as path time, and steps larger than a full move/pause cycle cross every boundary — then applies the end transform and computes per-step velocities as the secant `(end - start) / dt` — a fully paused step yields exactly zero velocity. `Circuits.eval_transform(circuit, time)` exposes the path offset `(dx, dy, da)` at a time.

`MotionSchema.validate(pegs, level_circuits)` runs at level load (from `Engine:setupLevel`, `LevelChecker`, and tests) and hard-errors on: circuit defs containing a `pegs` array, definitions mixing `kind` with `path_fn`, non-function `path_fn`, unknown primitive kinds, missing/invalid primitive parameters (incl. non-finite `frequency`/`angle`/`speed_angular` and non-boolean `rotate`), all four legacy flat authoring fields (`circuit_id`/`circuit_t`/`circuit_state`/`circuit_timer`), motion referencing an unknown circuit, and timed circuits without an explicit `pause_time`. `path_fn`-only circuit definitions remain runnable with a one-time load warning.

**Circuit primitives** (`src/systems/circuit_primitives.lua`) provide declarative path types — the recommended way to define circuits. Available primitives: `ellipse` (amp_x, amp_y, rotate), `cos_ellipse`, `oscillate_x`/`oscillate_y` (amp, frequency), `rotate` (speed_angular), `line` (amp, angle).

A circuit definition using primitives:
```lua
level_circuits = {
    c1 = {
        kind = "ellipse",
        amp_x = 100, amp_y = 50, rotate = true,
        speed = 1.5,
        duration_time = 3.0,  -- optional: move for N seconds
        pause_time = 1.0,     -- optional: pause for N seconds
    },
}
```

Legacy `path_fn(t)` functions are still supported (a definition must not mix `kind` with `path_fn`) and trigger a one-time deprecation warning at level load. `CircuitPrimitives.eval(def, t)` evaluates the primitive; `Circuits.eval_transform()` falls back to `path_fn` when the circuit has no `kind`.

A circuit definition has:
- `kind` (string) — the primitive name, evaluated by `CircuitPrimitives.eval()`
- `speed` — multiplier on `t` advancement
- `duration_time` / `pause_time` — optional move/pause cycle (peg alternates between "moving" and "paused" states)

When moving, peg translational velocity (`vx`/`vy`) and angular velocity (`va`) are computed from position and angle deltas. This ensures correct rigid-body collision response, as the contact point's instantaneous surface velocity (which includes $\vec{\omega} \times \vec{r}$) transfers momentum to the ball. When paused, velocities are zeroed.

### Powers (`powers.lua`)

`Powers.activate(peg, engine)` is called when a green peg is hit. It returns an array of **spawn specs** (tables with `x`, `y`, `vx`, `vy`) rather than mutating the engine's `active_balls` directly. The Engine's `reducePegContacts()` collects these specs during the reduction phase, and phase 14 (**Spawn power balls**) creates, registers, and stages `ball_spawned` events. This ensures spawned balls begin physics on the next step and do not participate in the same step's scoring or resolution.

### Screen (`screen.lua`)

Virtual resolution subsystem (see ADR-0003 and ADR-0004). Reads the active resolution from `LevelManager`, applies letterbox/pillarbox scaling to fit the actual window, and handles aspect ratio mismatches with centered black bars. `Screen.to_world(x, y)` converts mouse coordinates back to virtual space. `Screen.apply()`/`Screen.clear()` wrap the draw calls with a scissored transform.

### LevelValidator (`level_validator.lua`)

Filters pegs that extend beyond the left/right/ceiling walls at level load time. Discarded pegs are logged with a warning. This prevents pegs placed outside bounds from causing physics artifacts. Validation runs on **base positions** before motion initialization (preserving the surviving-peg set, order, and color assignment); `Validator.check_initialized_positions()` then re-checks the initialized (phase) positions with **warning-only** semantics, since discarding there would change peg counts and colors.

### Perf (`perf.lua`) — see also `context/benchmarking_architecture.md`

Benchmarking instrumentation. When enabled (via `--bench` CLI flag), it tracks:
- Update and draw time per frame
- Peg checks (broadphase evaluations) and collisions

### ContactEvents (`contact_events.lua`) + ImpactGeometry (`impact_geometry.lua`)

Render-only collision-event queue guaranteeing that every swept physical
collision is **presented** as exact ball–peg contact for exactly one rendered
frame. Physics never samples rendered positions at the collision's `frame_t`
reliably (see temp/presentation_report.md), so the ball would otherwise never
visually touch the peg. The module:

- Records every physical collision from `Physics.update` (sweep / overlap /
  de-penetration; pegs, walls, extra circles) with sim/path step, `frame_t`,
  exact impact center, peg TOI transform, normal, and velocities. Events
  persist across sim steps, independently of `draw_path` lifetime.
- On each `Engine:draw` (`begin_frame`), activates the earliest due event per
  ball — due when its path step has passed or the draw alpha crosses
  `frame_t` — sets `peg.visual_hit`, and (`--present-debug`) logs per-draw
  samples. `end_frame` consumes presented events after drawing.
- Overrides, for that one frame only: the ball's drawn position (exact impact
  center) and the involved peg's drawn transform (retained TOI transform).
- Never touches ball.x/y, velocities, time_remaining, iteration order, RNG,
  scoring, or replay serialization; replay traces are byte-identical with
  presentation on or off (`--contact-present off`).
- Only swept impacts are presentable; graze-only hits never generate forced
  contact frames. Queue bounded (64, FIFO) and coalesced (one presentation
  per ball per frame, chronological).

`ImpactGeometry` holds the shared pure helpers (peg TOI transform under the
start-transform + relative-motion model, signed surface separation for all
shapes, wall separation) used by both `ContactEvents` and `ImpactDebug`.

### GameplayEvents (`gameplay_events.lua`)

A deterministic, append-only, per-step event journal owned by each Engine instance. Events are recorded in two ordered phases:

- **Raw phase** (steps 1-15): Objective physics facts — `ball_contacted_peg`, `ball_launched`, `ball_fell_out`, `ball_spawned`, `ball_bucket_resolved`. These are appended by physics, bucket/fever resolution, and ball-management code in insertion order.
- **Derived phase** (steps 16+): Inferences from processors — `peg_scored` (with `source_sequence` pointing to the raw contact), `ball_became_idle`, `ball_reactivated`, `all_balls_became_idle`, `no_score_timeout_reached`, `style_awarded`, `shot_completed`.

Envelope fields (`schema_version`, `step`, `shot_id`, `sequence`, `phase`, `type`) are auto-assigned. `seal_raw()` freezes the raw phase at step 16. Events carry only primitive types — no live entity references. Payloads are **validated and deep-copied at record time** (functions/userdata/threads, NaN, ±inf, cyclic tables, and non-scalar keys are rejected), so the journal owns its data: later producer-side mutation cannot rewrite history. Staged events (e.g., `ball_launched` staged from a mouse click between steps) are flushed deterministically at the next `begin_step`.

`raw()` and `derived()` return borrowed internal views (the journal-owned arrays) for in-step authoritative processors; they must not be mutated by consumers. `snapshot()` returns a detached deep copy for external / retained boundaries (timeline, trace exporter, `onStepFinalized` callback).

### Exportable (`exportable.lua`)

A validated recursive deep-copy utility used by the events and commands pipeline to enforce payload ownership isolation. `Exportable.copy(value, what)` returns an independent deep copy, raising an error for: functions, userdata, threads, NaN, ±inf, cyclic tables, or unsupported key types. Only strings, finite numbers, booleans, `nil`, and recursively exportable tables are allowed. This guarantees that `snapshot()` yields data fully owned by the trace/timeline consumer, with zero reachable live entity references.

### GameplayCommands (`gameplay_commands.lua`)

An ordered buffer of requested authoritative mutations that processors push to and the Engine applies in phase 20. Commands are applied in deterministic insertion order (by `sequence`). Key command types:

- `award_style_points` — pushed by StyleShots, applied to add `style_score` and emit `style_awarded`
- `start_midturn_clearing` — pushed by BallState, applied to initialise the clearing cascade
- `remove_slide_pegs` — pushed by SlideInversion, applied to remove the lowest already-hit peg(s) of a zero-gap slide line from the board and emit `slide_peg_removed` (idempotent; `ignored_duplicate` when none remain)

Commands and events are sister systems: events record _what happened_, commands request _what should change_. The Engine applies commands once per step after all processors have finished.

**Requested vs applied**: the requested list is never rewritten. Every command the Engine processes in phase 20 is additionally journaled in an applied log (`commands:applied_snapshot()`) with a scalar `status` — `"applied"` (state changed) or `"ignored_duplicate"` (e.g. a second `start_midturn_clearing` while clearing is already active). Both requested and applied commands appear in gameplay traces, so "was this request honored?" is answerable post-hoc. Applying an `award_style_points` command also fires the deferred `callbacks.onStyleShot(engine, award)` presentation hook after the authoritative state change.

### StyleShots (`style_shots.lua`)

Deterministic style-shot recognition from completed gameplay event streams. Processes each step's raw and derived events to identify:

| Style | Trigger | Points |
|-------|---------|--------|
| Long Shot | Ball travels ≥ `long_shot_distance` (400 px) between two valid peg contacts ("sweep" or "graze") | 1,000 |
| Super Long Shot | Ball travels ≥ `super_long_shot_distance` (700 px) | 5,000 |
| Double | Two consecutive qualified long-shot segments | 2,000 |
| Lucky Bounce | Ball bounces off the bucket, subsequently bounces on any peg or wall, and is later caught by the bucket | 2,500 |
| Off the Wall | Ball contacts a side wall (left/right) as its *first* impact of the turn, then scores a non-blue peg | 5,000 |

Chain rules: only valid ("sweep" or "graze") peg contacts qualify; blue-peg or already-hit-peg contacts break the chain. Long and Super Long are mutually exclusive. Per-ball state (`last_impact`, `qualifying_streak`, `bucket_bounced`, `bounced_after_bucket`, `side_wall_hit`, `hit_any_peg`) persists across steps within a shot. All thresholds are configurable in `src/config.lua`.

### BallState (`ball_state.lua`)

Manages per-ball lifecycle, idle detection, and no-score timeout detection. Owns the gameplay-idle, stall, and no-score timers that drive mid-turn clearing:

- **Idle detection**: Ball speed < `ball_still_speed` (18 px/s) for ≥ `clear_still_time` (0.6s) → `ball_became_idle` event. Wake hysteresis prevents flicker.
- **No-score timeout**: No `peg_scored` events for ≥ `clear_no_score_time` (10.5s) → `all_balls_became_idle` event → `start_midturn_clearing` command.
- **All-idle latch**: Fires `all_balls_became_idle` once when all launched balls are simultaneously idle.
- `reset_timers()` resets state after a mid-turn clear completes (so the ball can play on).

Processes during the derived phase (step 19), after `peg_scored` events are present.

### SlideInversion (`slide_inversion.lua`)

Detects a ball trapped oscillating like a pendulum in a concave valley formed
by a zero-gap generated line (e.g. the `slide` level's annular arc) and opens
the valley floor so the ball falls out instead of farming peg scores.

- Tracks each launched ball's zero-gap contact line, holding the ball's
  direction of travel across an apex: the signed tangential speed
  `tang = n.x·v.y − n.y·v.x` (using the contact surface normal) flips sign
  exactly when the ball stops rolling and goes back. No absolute speed
  threshold is used.
- `|tang|` below `slide_invert_tangent_epsilon` (2 px/s) is ignored; a genuine
  `did_bounce` resyncs rather than triggering; a different line or a
  `slide_invert_contact_timeout` (0.3s) gap restarts tracking.
- On a reversal it selects the already-hit pegs of the line with the greatest
  recorded impact-point `y` (lowest on screen; ties within
  `slide_invert_lowest_tie`), pushes a `remove_slide_pegs` command, and marks
  them so a later apex does not re-select them.
- The Engine's apply step removes the pegs from the board and emits
  `slide_peg_removed`. Scoring is untouched — a removed peg stays in
  `turnPegsHit`. Runs in phase 18b, before BallState, and is skipped while a
  clearing cascade is active.

### SimulationSnapshot (`simulation_snapshot.lua`)

Captures a complete, deterministic, in-memory plain-data snapshot of an Engine's authoritative state (`schema_version = 2`). The snapshot contains only scalar values (no live entity references, functions, or userdata). Used by GameplayTraceExporter and shot timeline retention. Includes balls (ordered by `active_balls`), pegs (ordered by `original_index`), bucket, fever buckets, scoring counters, clearing state, and multiplier/fever status. Each peg carries its authoritative `motion` sub-table plus flat `circuit_id`/`circuit_t`/`circuit_state`/`circuit_timer` fields derived from it for trace compatibility.

### Replay, ReplayLibrary & TraceExporter (`replay.lua`, `replay_library.lua`, `trace_exporter.lua`)

Debugging systems for ensuring deterministic parity and resolving physics anomalies.
`Replay` captures the exact engine state at the moment a ball is launched and saves it to `src/replays/last_shot.lua`. Captures use `schema_version = 2`: every peg stores its base transform, current transform (`x`/`y`/`angle`), per-step velocities (`vx`/`vy`/`va`), `hit_order`, and — for moving pegs — the full runtime motion state (`motion = { circuit, phase, time, state, timer }`); the envelope records `hitCounter`, `redPegsHitAmount`, `currentMultiplier`, and the bucket's `phase` and `x`. All numeric fields — including ball IDs — are serialized at full `%.17g` precision so values near 2⁵³−1 round-trip exactly, and `base_angle` is always the declared base rotation, never the current applied rotation. Loading goes through `Engine:applyReplayState()`: `Replay.validate()` runs first (accepting only the legacy format with no version or the exact integer `schema_version = 2`, with structural type-checks on every field the restore path reads) so no invalid file can fail mid-restore after engine state has mutated. Captured ball IDs are preserved (old captures without IDs get deterministic allocation in capture order), the in-progress shot runs under a nonzero `shot_id` anchored at the next step, and per-shot processors (StyleShots, BallState, SlideInversion) are reset — no synthetic `ball_launched` event is emitted. Identity preflighting validates all replay ball IDs before any world mutation; see [Stable ball identities](#stable-ball-identities-srcenginecorelua) for the full contract. Restored scoring counters feed `updateMultiplier()`, so `currentMultiplier` and `isFever` are re-derived consistently (fever bucket activation included), and the bucket is restored with `prev_x = x` to avoid a first-frame jump.

`ReplayLibrary` (`src/systems/replay_library.lua`) manages the persistent named-replay library under `replays/` (gitignored, project-relative). `Engine:launchBalls()` serializes the launch state once, writes the rolling `src/replays/last_shot.lua` for `make trace`, and buffers the serialized Lua source in `self.last_shot_replay_lua` (serialization must happen at launch because the live peg/ball tables mutate during the shot). `Engine:saveLastShotReplay(name)` copies that buffer to `replays/<YYYYMMDD_HHMMSS[_name]>.lua`, adding a numeric suffix if a same-second name already exists so a save can never overwrite another replay. In-game, `F8` opens a naming prompt (blank label = timestamp only). CLI selectors are resolved by `ReplayLibrary.resolve()`: `latest`/`last` pick the newest entry, an explicit path is used as-is (backward compatible), and a stem or unique label suffix resolves to the matching capture. `--list-replays` prints the library (newest first, marked with `*`).

Legacy captures (no `schema_version`, flat `circuit_id`/`circuit_t`/`circuit_state`/`circuit_timer` fields) remain loadable through a compatibility adapter: the level's circuit assignment plus `eval(circuit_t)` re-derives the transform, the flat state is converted to `peg.motion`, and velocities are zeroed (recomputed on the next step with no first-step jump). The declared base rotation is taken from the level, never from the captured value — pre-schema-2 captures baked applied rotation into `base_angle` for rotating annular pegs, which would otherwise double the rotation on restore. Replay runs are one-shot: bench mode terminates automatically when the replayed shot completes (or immediately when the capture holds no live balls). Replays referencing levels that no longer exist (e.g. the removed grid benchmark levels) fail with a clean "level not available" error before any state is touched.
`TraceExporter` streams a line-delimited JSON (`.jsonl`) log of all moving entities' positions throughout a replay to disk, ensuring a negligible memory footprint during recording.

### GameplayTraceExporter (`gameplay_trace_exporter.lua`)

A separate, canonical **gameplay trace** exporter that writes one JSONL line per fixed simulation step. Each step record includes raw/derived events, requested/applied commands, and an optional full authoritative state snapshot. The encoder is fully deterministic — byte-identical traces across runs with the same replay/config/seed. Activated via `--export-gameplay-traces FILE` or by wiring `engine.trace_exporter = GameplayTraceExporter`. This coexists with the legacy `TraceExporter` (which records entity positions); both can run simultaneously.

### Level checking tools (dev/QA)

These modules provide static analysis and brute-force simulation for level authors — they do **not** run during standard gameplay.

- **`overlap_detector.lua`** — SAT-based overlap detection primitives for all shape pairs.
- **`circuit_analyzer.lua`** — Characterizes circuit motion envelopes to detect dynamic overlaps between circuit-driven pegs and static pegs.
- **`level_checker.lua`** — Orchestrates the full static/dynamic overlap check.
- **`test_style_shot.lua`** — An interactive test tool that dynamically swaps the active LÖVE loop to brute-force all 1,800 viable aim angles headlessly. It isolates physics setups that yield a target style shot (e.g. `lucky_bounce`) and then transfers the Engine state back to a visual presenter for instant multi-shot playback.

**CLI usage:**
```bash
lua tools/check_level.lua src/levels/level1.lua
make test-styles <style_name>
```

## Level files (`src/levels/`)

Each level returns a table with:
- `pegs` — array of peg tables (or calls to `Peg.new()`); the **only** peg collection. Moving pegs carry `peg.motion = { circuit = ..., phase = ... }`.
- `type_counts` — `{ red = N, green = M }` (blue count is auto-computed)
- `level_seed` — integer seed for the RNG
- `level_circuits` — optional table of circuit definitions keyed by ID. Circuit definitions are immutable during simulation and never contain a `pegs` array (enforced by MotionSchema at load).

Levels are hot-reloadable: `package.loaded["src.levels." .. name]` is cleared before re-requiring.

The "lasagna" benchmark level stacks multiple circuit-driven layers. The legacy grid benchmark levels (100–1000 pegs) and `test_rotation` were removed with the motion refactor.

## Virtual resolution

The game world operates at a **per-level virtual resolution** that defaults to **1200×1900** (defined in `src/config.lua`: `virtual_width`, `virtual_height`). Individual levels can override this by providing `virtual_width` and `virtual_height` in their data table — for example, `level1.lua` uses 850×550 and `circle_level.lua` uses 600×500.

The `LevelManager` module (`src/systems/level_manager.lua`) resolves the active resolution at level load time and stores it in `LevelManager.virtual_width` / `LevelManager.virtual_height`. All gameplay systems (physics walls, bucket positioning, ball spawn, fall-out detection, level validation) read from `LevelManager` rather than `Config`.

The `Screen` module computes a uniform scale factor and letterbox/pillarbox offset, applied via `love.graphics` transform stack. Mouse input is inverse-transformed through `Screen.to_world()`. Any mismatch between the level's aspect ratio and the window produces centered black bars. This ensures deterministic simulation independent of display resolution.

## Change-oriented guidance

- **Adding a peg shape**: Create a new constructor in `peg.lua`, add narrow-phase collision in `physics.lua`, add draw branch in `Peg.draw()`, and add shape-specific peg array splitting in `Engine:rebuildPegLists()` (src/engine/core.lua).
- **Adding a power**: Extend `Powers.activate()` in `powers.lua`. Return an array of spawn specs (tables with `x`, `y`, `vx`, `vy`) — do NOT mutate `active_balls` directly. The Engine handles ball creation, registration, and `ball_spawned` event staging in phase 14.
- **Adding a gameplay event type**: Define the event name. If it's an observation from physics/bucket/ball management, emit it as raw (before `seal_raw`). If it's an inference from a processor, emit it as derived (after `seal_raw`). Wire any new processors in `finalizeStep()` at the appropriate phase (16-20) before commands are applied.
- **Adding a style shot**: Add the recognition logic in `style_shots.lua:process_step()`. Add the point value and any distance thresholds to `src/config.lua`. Push an `award_style_points` command with a unique `style` identifier.
- **Adding a gameplay command type**: Define the type, add the application logic in `Engine:applyCommands()`, and push the command from the appropriate processor (step 18-19) before the apply phase (step 20).
- **Exporting gameplay traces**: Pass `--export-gameplay-traces FILE` on the command line. The trace includes raw/derived events, commands, and optional snapshots for every fixed step. Combine with `--retain-shot-timeline` to also keep shot histories in memory for analysis.
- **Adding a level mechanic**: Circuit-based movement is the primary extensibility point. Prefer declarative primitives (`kind = "ellipse"`, etc.) from `circuit_primitives.lua` over raw `path_fn`. Define the circuit with a `kind` and its parameters in `level_circuits`, then attach moving pegs to it with `peg.motion = { circuit = "c1", phase = ... }` in the level's `pegs` array — circuit definitions never own pegs.
- **Setting a per-level virtual resolution**: Add `virtual_width` and `virtual_height` fields to the level's return table. Omit them to use the global defaults from `Config`. All systems read from `LevelManager`, so no other changes are needed.
- **Changing physics constants**: Edit `src/config.lua` and press `R` in-game to hot-reload. The config is designed for quick iteration.
- **Debugging physics artifacts**: Launch with `love . -- --replay src/replays/last_shot.lua --export-traces debug_trace.jsonl` for entity traces, or `--export-gameplay-traces debug_gameplay.jsonl --retain-shot-timeline` for full event-level traces including scoring and commands.
- **Benchmarking changes**: Run with `--bench --nojit` for worst-case profiling, `--bench` alone for JIT-optimized results. Use `--balls N` to test multi-ball stress. Add `--export-gameplay-traces temp/bench.jsonl` to capture gameplay event data for analysis.
- **Watch out for**: Always use `ipairs`, not `pairs`, on physics and peg arrays. Iteration order must be deterministic. Don't call `math.random` — use `Config`-seeded RNG through PegColors. Raw events must be emitted before `seal_raw()` (phase 16); derived events must be emitted after. Use `goto finalize` pattern for all early returns from `stepSimulation`.
