# Game Mechanics

## Game modes

| Mode | Turn order | Bucket behavior | Red-hit penalty | Win condition |
|------|-----------|-----------------|-----------------|---------------|
| **Solo** | Single player | Free ball (+1 to inventory) | None | All reds cleared or 0 balls |
| **1v1** | Alternating P1/P2 | Incremental points (`bucket_hits × 2500`) | -25% score | All reds cleared or both out of balls |

Players start with `Config.starting_balls` (default 10) in both modes. In 1v1, a turn overlay announces "PLAYER N'S TURN" for 1.5 seconds when control switches.

### Mode-dependent turn tracking

The `GameState` maintains a `Players` array:
```lua
Players = {
    { score = 0, balls = 10, bucket_hits = 0 },
    { score = 0, balls = 10, bucket_hits = 0 },
}
```

In solo mode, only `Players[1]` is used. In 1v1, `self.current_player_index` toggles between 1 and 2 each turn.

## Scoring formula

The total score displayed is computed by taking the player's stored score and adding the engine's current turn score (`engine:getTurnScore()`):

```
displayScore = player.score + (weightedSum × pegCount) + engine.bonusScore + engine.styleScore
```

Where, for the current turn:
- **`weightedSum`** = sum of each hit peg's `Peg.value(type)` × the multiplier at the moment it was hit
- **`pegCount`** = number of pegs hit this turn (`#turnPegsHit`)
- **`engine.bonusScore`** = accumulated bucket bonus points this turn
- **`engine.styleScore`** = accumulated style shot points this turn (Long Shot, Super Long Shot, Double, Lucky Bounce, Off the Wall)
- **`player.score`** = score carried from previous turns

At turn end (`_endTurn()`), `player.score += engine:getTurnScore()`, and the engine handles resetting `bonusScore` back to 0. This means bucket points are added directly to the player's permanent score each turn.

Hitting more pegs in a single turn yields a quadratic benefit: each additional peg increases both the sum and the count multiplier.

Peg point values (defined in `src/config.lua` → `peg_types`):

| Type | Points |
|------|--------|
| Blue | 10 |
| Green | 10 |
| Red | 100 |
| Purple | 500 |

The multiplier at the moment of each hit is captured as `peg.multiplier_at_hit` and frozen — subsequent hits in the same turn use the multiplier that was active when the specific peg was struck.

## Multiplier system

The multiplier is computed by `updateMultiplier()` based on the **percentage of red pegs hit** across all turns so far:

| Red pegs hit | Multiplier |
|-------------|------------|
| < 40% | ×1 |
| 40%–59% | ×2 |
| 60%–74% | ×3 |
| 75%–87% | ×5 |
| 88%–99% | ×10 |
| 100% | ×100 (fever) |

**Source**: `Engine:updateMultiplier()` in `src/engine/core.lua`. Red peg hit count is tracked incrementally via `redPegsHitAmount`, updated each time a red peg is struck in `Engine:reducePegContacts()`.

## Style shots

Style shots are awarded based on ball trajectory patterns during a shot. They are recognized by `StyleShots:process_step()` in `src/systems/style_shots.lua` and applied as `award_style_points` commands in phase 20 of the simulation step. Style points are tracked in `engine.styleScore` and included in `shot_completed.total_score`.

| Style | Trigger | Points |
|-------|---------|--------|
| **Long Shot** | Ball travels ≥ `long_shot_distance` (400 px) between two valid (swept or grazed) peg contacts | 1,000 |
| **Super Long Shot** | Ball travels ≥ `super_long_shot_distance` (700 px) between two valid (swept or grazed) peg contacts | 5,000 |
| **Double** | Two consecutive qualified long-shot segments (any combo of Long/Super Long) | 2,000 |
| **Lucky Bounce** | Ball bounces off the bucket, subsequently bounces on any peg or wall, and is later caught by the bucket | 2,500 |
| **Off the Wall** | Ball contacts a side wall (left/right) as its *first* impact of the shot, then scores a non-blue peg | 5,000 |

### Chain rules

- Only valid impacts (**sweep** or **graze**) on peg contacts participate for distance-based styles.
- A **blue-peg** or **already-hit-peg** contact **breaks the qualifying chain** — it resets `last_impact` so subsequent segments start fresh.
- **Long Shot** and **Super Long Shot** are mutually exclusive — a single segment only awards the highest qualifying tier.
- **Double** requires two consecutive segments that both qualify for Long or Super Long.
- **Off the Wall**: a side-wall hit is only registered if the ball hasn't hit any pegs yet. It is "consumed" when a subsequent contact scores a non-blue peg (awarding the points) or fails on a blue/already-hit peg.
- Every award command carries `source_sequences` — the event sequences that caused it — for traceability. The corresponding `style_awarded` derived event echoes them, and the deferred `callbacks.onStyleShot(engine, award)` presentation hook fires only after the award has been authoritatively applied (never from inside a processor).
- Per-ball state (`last_impact`, `qualifying_streak`, `bucket_bounced`, `bounced_after_bucket`, `side_wall_hit`, `hit_any_peg`) persists across steps within a single shot and resets at `reset_shot()` (called at each new launch).

### Config thresholds

All thresholds are defined in `src/config.lua`:

```lua
long_shot_distance = 400,
super_long_shot_distance = 700,
off_the_wall_min_distance = 150,
long_shot_points = 1000,
super_long_shot_points = 5000,
double_style_points = 2000,
lucky_bounce_points = 2500,
off_the_wall_points = 5000,
```

**Sources**: `src/systems/style_shots.lua`, `src/config.lua`.

## Ball state (idle / no-score / stall detection)

The `BallState` system (`src/systems/ball_state.lua`) manages per-ball lifecycle timers that drive mid-turn clearing. It processes each step's complete event journal during the derived phase (step 19) and can push `start_midturn_clearing` commands.

### Idle detection

- A ball is **idle** when its velocity magnitude < `Config.ball_still_speed` (18 px/s) for ≥ `Config.clear_still_time` (0.6s). Idle state emits a `ball_became_idle` derived event.
- **Wake hysteresis**: once a ball has been detected idle, it must exceed `Config.ball_still_speed × Config.ball_wake_speed_multiplier` (18 × 1.5 = 27 px/s) to be considered reactivated. A `ball_reactivated` event fires exactly once per idle-to-moving transition.
- **All-idle latch**: when all launched balls are simultaneously idle, a single `all_balls_became_idle` event fires and a `start_midturn_clearing` command is pushed. The latch is reset when a new ball spawns or when mid-turn clearing completes.

### No-score timeout

- The no-score timer increments by `dt` each step and resets to 0 whenever a `peg_scored` event occurs. Style points do NOT reset the timer.
- When the timer reaches `Config.clear_no_score_time` (10.5s), a `no_score_timeout_reached` event fires and a `start_midturn_clearing` command is pushed. The timeout is latched — it won't fire again until another `peg_scored` resets the timer.

### Resetting

- `BallState:reset_timers()` is called after a mid-turn clearing cascade completes (`clearingIsEndOfTurn == false`). This resets idle timers, wake latches, and the no-score timer so the ball can continue playing.
- `reset_shot()` is called at each new launch to clear all per-ball state.

**Source**: `src/systems/ball_state.lua`, `Engine:stepSimulation()` phases 13, 14, 19, 20.

When all pegs on the board are hit (not just reds), the multiplier stays at ×100 and **ultra fever** is triggered — all fever bucket slots become worth 100,000 points.

## Fever mode

When the multiplier reaches ×100:
1. The normal sliding bucket is **replaced** by `FeverBuckets` — five catch slots with values `{10000, 50000, 100000, 50000, 10000}` separated by circular dividers.
2. **Circuits are not a fever effect**: circuit-driven peg movement via `Circuits.update()` runs on every simulation step throughout the level, including during fever — pegs on the board animate along their predefined paths at all times. Fever replaces the sliding bucket and its scoring behavior; it does not activate peg movement.
3. When a ball falls into a fever bucket slot, the slot value is added to `bonusScore`. The ball is not removed — it continues falling. The turn naturally completes once all active balls have fallen off screen, triggering the level end or benchmark loop reset.
4. If every peg on the board is hit (ultra fever), all five slots become 100,000 points.

**Source**: `Engine:stepSimulation()` in `src/engine/core.lua`, `FeverBuckets` entity.

## Purple peg queue

Purple pegs are special: only `Config.purple_pegs_per_turn` (default 1) blue pegs are promoted to purple at the start of each turn. This is managed by `PegColors` in `src/systems/peg_colors.lua`.

**Turn lifecycle**:
1. **Turn start** (`assign_next_purple_pegs`): All currently active purple pegs are reverted to blue. Then up to `purple_pegs_per_turn` pegs are popped from the front of the shuffled purple queue and promoted to purple.
2. **During turn**: If a purple peg is hit, it's removed from the active list via `on_purple_peg_hit()`. No new purple is promoted mid-turn.
3. **Queue exhaustion**: If the queue runs empty but un-hit blue pegs remain, the queue is rebuilt from surviving blue pegs and re-shuffled.

**Determinism**: The queue is initialized with a Fisher-Yates shuffle using the level's seeded RNG. Only blue pegs enter the queue. Hit pegs are drained from the queue (not promoted).

**Source**: `src/systems/peg_colors.lua`, audit at `audits/001-peg-color-assignment.md`.

## Turn lifecycle

A single turn proceeds as follows:

1. **Aim phase**: The ball sits at the top of the screen (`y=50`). The player aims with mouse or keyboard. A trajectory preview (10 dots) is drawn.
2. **Launch**: On click/Enter, `ball.launched = true`, velocity is set from `current_aim_angle` × `Config.launch_speed`, and the current player's `balls` is decremented by 1. A `ball_launched` raw event is staged and flushed at the next fixed step. `shot_id` is incremented.
3. **Simulation**: The ball falls under gravity, bouncing off pegs, walls, and the bucket. Each peg collision emits a raw `ball_contacted_peg` event. In phase 10, `reducePegContacts()` performs authoritative first-hit reduction and **buffers** `peg_scored` derived events (emitted in phase 17 with `source_sequence` pointing to the raw contact).
4. **Style + ball-state processing**: In phases 18-19, `StyleShots` and `BallState` process the step's complete event journal and push commands (`award_style_points`, `start_midturn_clearing`). Commands are applied in phase 20.
5. **Stall detection**: The `BallState` system tracks idle and no-score timeouts. Two conditions trigger a mid-turn clearing cascade:
   - Ball speed drops below `Config.ball_still_speed` (18 px/s) for `Config.clear_still_time` (0.6s)
   - No peg has been scored for `Config.clear_no_score_time` (10.5s)
6. **Clearing cascade**: Hit pegs vanish one by one in `hit_order` at `Config.peg_vanish_interval` (0.08s) intervals. The ball freezes during the cascade.
   - **Mid-turn clear** (`clearingIsEndOfTurn = false`): After cascade, `BallState:reset_timers()` is called and the ball resumes movement.
   - **End-of-turn clear** (`clearingIsEndOfTurn = true`): Triggered when all balls have fallen off screen. After cascade, the shot ends.
7. **Shot completed**: A `shot_completed` derived event is emitted in phase 21 with final score components (`peg_score`, `bonus_score`, `style_score`, `total_score`). This occurs AFTER command application so totals are authoritative. The shot timeline is finalized and `onTurnEnd` fires (phase 25).
8. **Turn end** (`_endTurn()`):
   - Turn score (weightedSum × pegCount) plus accumulated `bonusScore` is added to the current player's `score`.
   - `bonusScore` and `styleScore` are reset to 0.
   - If `mode == "1v1"` and no red pegs were hit → `player.score *= 0.75` (-25% penalty).
   - **Solo**: If `player.balls <= 0` → game over.
   - **1v1**: Finds the next player with remaining balls. If both out of balls → game over, winner determined by score. Otherwise switches to next player and shows turn overlay.
   - If game not over, `_resetTurn()` creates a new ball for the next shot.

**Ball removal** occurs when:
- A ball is caught by the normal bucket → mode-dependent behavior applied, ball removed
- A ball falls below `Config.virtual_height + Config.fall_out_margin` (80px below screen) → ball removed, `ball_fell_out` raw event emitted
- When all balls are removed, end-of-turn clearing begins

**Multi-ball**: Green peg powers and benchmark mode (`--balls N`) can create multiple simultaneous balls. Each ball is tracked independently with a **stable integer ID** assigned by `registerBall()` — IDs are unique and permanent for the lifetime of the Engine instance (never reused across turns, shots, or level setups). Spawned balls begin physics on the step after their creation step. The turn ends only when all balls have been removed. See [architecture.md: Stable ball identities](architecture.md#stable-ball-identities-srcenginecorelua) for the full identity contract including allocator exhaustion, mutation detection, and failure atomicity.

**Shot lifecycle events**: Every shot produces a `ball_launched` event and (if completed) a `shot_completed` event. When `--retain-shot-timeline` is enabled, the full step-by-step event journal is stored in `engine.shot_timelines[shot_id]` for post-hoc analysis. When `--export-gameplay-traces FILE` is active, every step's raw/derived events, commands, and optional snapshot are written to a canonical JSONL trace.

**Source**: `Engine:stepSimulation()` (26 phases), `Engine:reducePegContacts()`, `Engine:startClearing()`, `Engine:updateClearing()`, `Engine:emitShotCompleted()`, `Engine:finalizeShotTimeline()`, `Engine:resetTurn()` in `src/engine/core.lua`, `BallState` in `src/systems/ball_state.lua`, `StyleShots` in `src/systems/style_shots.lua`, and `GameState:_endTurn()` in `src/states/game.lua`.

## Aim discretization

To enable deterministic simulations and solver-friendly angle spaces, the aiming system supports discretizing the continuous 180° arc into a finite set of equally spaced angles. This is controlled by `Config.aim_discretization_steps` (default: `2000` — roughly 0.09° per step). Set to `nil` to disable and use full continuous precision.

### How it works

The raw `current_aim_angle` is always stored as a high-precision float (updated continuously by mouse, keyboard, and wheel inputs). The discretization is applied only at two endpoints via `Physics.getSnappedAimAngle(angle)`:

1. **Trajectory preview** (`draw()`): The dotted aim line uses the snapped angle so the player sees exactly which discrete step they are on.
2. **Ball launch** (`_launchBalls()` / `mousepressed()`): The ball's initial `vx`/`vy` are computed from the snapped angle, guaranteeing the launch belongs to the finite set.

This separation ensures all input methods (mouse, wheel, keyboard) feel responsive while strictly constraining actual shots to the configured step count.

### DAS keyboard input (Delayed Auto-Shift)

To make keyboard aiming feel both precise (single-step taps) and fast (continuous sweep when held), the arrow keys use a **Delayed Auto-Shift** mechanic:

| Action | Behavior |
|--------|----------|
| **Tap** (`keypressed`) | Snaps `current_aim_angle` to the nearest discrete step, then advances ±1 full step. This guarantees single-step precision regardless of frame rate. |
| **Hold < 0.2s** | No movement — the hold timer hasn't crossed the threshold yet. |
| **Hold > 0.2s** | Continuous sweep at `Config.aim_fine_adjust_speed` (30°/s). |

Hold timers (`key_hold_time_left` / `key_hold_time_right`) are tracked in `update()` and reset to 0 when the key is released (`love.keyboard.isDown` returns false). This prevents the continuous sweep from starting on the first tap — the player must intentionally hold the key to engage sweep mode.

When discretization is disabled (`aim_discretization_steps = nil`), a tap still advances by a fixed 0.5° step to avoid the previous "instant multi-step" feel on quick keypresses.

**Source**: `Engine:keypressed()`, `Engine:update()` in `src/engine/core.lua`; `Physics.getSnappedAimAngle()` in `src/systems/physics.lua`.

## Clearing cascade

When triggered by `startClearing(isEndOfTurn)`:
1. All hit pegs are collected, sorted by `hit_order` (the monotonically increasing `hitCounter` value assigned when the peg was struck).
2. At each `peg_vanish_interval`, the front peg is removed: erased from the master `pegs` array and the shape-specific array (`circle_pegs`/`rect_pegs`/`annular_pegs`), and `PegColors.on_peg_removed()` is notified.
3. When the queue empties, if end-of-turn, scores are finalized and `resetTurn()` is called.

**Source**: `Engine:startClearing()`, `Engine:updateClearing()` in `src/engine/core.lua`.

## Slide-inversion valley removal

A ball can settle into a concave valley formed by a zero-gap generated line
(for example the inner face of the `slide` level's annular arc) and oscillate
like a pendulum, scoring peg after peg on every pass. The `SlideInversion`
system (`src/systems/slide_inversion.lua`) detects each apex — the moment the
ball stops rolling along the slide and goes back — and removes the lowest
already-hit peg(s) of that line from the board, opening the valley floor so the
ball falls out.

**Detection** (per launched ball, per zero-gap line):

- The ball is "on a slide" while it keeps contacting a zero-gap line
  (`line.gap == 0`) within `slide_invert_contact_timeout` (0.3s). Contacting a
  different line restarts tracking; losing contact for the timeout ends it.
- Each peg contact carries the surface normal (peg → ball). The signed
  tangential speed `tang = n.x·v.y − n.y·v.x` flips sign exactly when the ball
  reverses at an apex. No absolute speed threshold is involved, so a low-energy
  swing that never exceeds walking pace is still caught.
- `|tang| < slide_invert_tangent_epsilon` (2 px/s) is ignored (the ball is
  momentarily stopped and the sign is undetermined), so the previous direction
  is held across the apex. A genuine `did_bounce` resyncs the direction instead
  of triggering.

**Removal**: among the already-hit pegs of the sliding line, those with the
greatest recorded impact-point `y` (lowest on screen) are selected; ties within
`slide_invert_lowest_tie` (1 px) are all removed. The processor pushes a
`remove_slide_pegs` command; the Engine removes the pegs from the board and
emits a `slide_peg_removed` derived event. **Scoring is untouched** — a removed
peg stays in `turnPegsHit`, so its points are still awarded; only the board
obstacle disappears. Already-removed pegs are skipped, and removal is paused
while a clearing cascade is active.

**Config** (`src/config.lua`):

```lua
slide_invert_contact_timeout = 0.3,
slide_invert_tangent_epsilon = 2.0,
slide_invert_lowest_tie = 1.0,
```

**Source**: `src/systems/slide_inversion.lua`, `Engine:removePeg()`,
`Engine:applyCommands()` in `src/engine/core.lua`.

## Circuit-based peg movement

Pegs are assigned to circuits (movement paths) via `peg.motion = { circuit = "c1", phase = ... }` in the level's `pegs` array. Circuit definitions live in `level_circuits` within each level file and never own pegs. The `Circuits` system (`src/systems/circuits.lua`) applies the declared-phase transform at level setup (`initialize`) and evaluates movement each fixed step (`update`), using `CircuitPrimitives.eval()` for `kind`-based primitives or falling back to legacy `path_fn(t)`.

**Circuit definition (primitives — recommended)**:
```lua
level_circuits = {
    c1 = {
        kind = "ellipse",     -- primitive from circuit_primitives.lua
        amp_x = 100, amp_y = 50,
        speed = 1.5,          -- t-advance rate
        duration_time = 3.0,  -- optional: move for N seconds
        pause_time = 1.0,     -- optional: pause for N seconds
    },
}
```

**Moving peg assignment (in `pegs`)**:
```lua
{ x = 500, y = 400, type = "blue", radius = 15,
  motion = { circuit = "c1", phase = 0.25 } }
```

**Circuit definition (legacy `path_fn`)**:
```lua
level_circuits = {
    c1 = {
        path_fn = function(t) return dx, dy, da end,
        speed = 1.5,
        duration_time = 3.0,
        pause_time = 1.0,
    },
}
```

- Available primitives: `ellipse` (amp_x, amp_y), `cos_ellipse`, `oscillate_x`/`oscillate_y` (amp, frequency), `rotate` (speed_angular), `line` (amp, angle).
- `t` starts at `motion.phase` (per-peg phase offset), tracked at runtime in `motion.time` (`phase` itself stays immutable).
- Returns `(dx, dy, da)` — position offset from `(base_x, base_y)` and angle delta from `base_angle`.
- When active, peg translational and angular velocities are derived from transform deltas. This ensures proper rigid-body physics interactions, where spinning surfaces accurately apply tangential kicks to the ball based on the contact point's distance from the center of rotation.
  - *Crucial implementation detail:* The engine computes angular velocity as `peg.va = (new_angle - old_angle) / dt`. To prevent infinite derivative explosions that break physics collisions, `peg.angle` and `peg.prev_angle` are continuously synchronized for *all* peg shapes (including `circle` and `annular`), regardless of whether that shape visually draws a 2D rotation.
- Circuit movement is not gated by fever: `Circuits.update()` runs on every fixed simulation step, and every peg carrying a `motion` assignment moves — fever neither activates nor restricts it.
- Invalid motion authoring (legacy `circuit_id`/`circuit_t` fields, unknown circuit references, malformed primitives) raises a load-time error via `MotionSchema` (`src/systems/motion_schema.lua`).

**Source**: `src/systems/circuits.lua`, `src/systems/circuit_primitives.lua`, `src/systems/motion_schema.lua`, levels like `benchmark_lasagna.lua`.

## Green peg powers

When a green peg is hit, `Powers.activate()` returns an array of **spawn specs** — tables with `x`, `y`, `vx`, `vy` — rather than mutating the engine's `active_balls` directly. Currently this spawns two multiball balls with diverging horizontal velocities (±150 px/s).

The **Engine** handles the staging:
1. **Phase 10** (`reducePegContacts`): Green peg hit is detected during scoring reduction. Spawn specs are collected into `pending_spawn_specs`.
2. **Phase 14**: Specs are consumed — balls are created (`Ball.new()`), assigned stable IDs via `registerBall()`, and appended to `active_balls`. A `ball_spawned` raw event is staged for each.
3. The spawned balls begin physics on the **next** fixed step — they do not participate in the same step's scoring, resolution, or removal. This guarantees independent ordering.

The intention is to eventually support multiple power types (multiball, super-guide, free ball, fireball).

## Bucket mechanics

### Normal bucket
- Slides left-right in a sinusoidal pattern: `x = center - amplitude × cos(phase)`. Phase advances each frame at a rate derived from `Config.bucket_accel_multiplier` (default 0.15) scaled by the level width.
- Three solid sub-rectangles (two walls + base) collide with the ball using circle-vs-AABB reflection.
- The ball is caught when it enters the hole (`ball.y + radius >= bucket.top` and within `holeHalf` of bucket center).

**Catch behavior varies by game mode:**

| Mode | Effect |
|------|--------|
| **Solo** | Free ball: `player.balls += 1`. No score awarded. |
| **1v1** | Incremental points: `player.bucket_hits += 1`, then awards `player.bucket_hits × Config.bucket_incremental_base` (default 2500). First catch = 2,500, second = 5,000, third = 7,500, etc. |
| **Benchmark** | Flat `Config.bucket_bonus` (10,000 points). No free ball. |

### 1v1 red-hit penalty

In 1v1 mode, if a player ends their turn without hitting any red pegs (and they did hit at least one peg), their score is reduced by 25%: `player.score = math.floor(player.score * 0.75)`. A floating "-25% NO RED HIT" penalty text appears for 2 seconds. This penalty does **not** apply to solo mode.

**Source**: `GameState:_endTurn()` in `src/states/game.lua`.

### Fever bucket
- Five fixed slots spanning the screen width, separated by circular dividers.
- Ball doesn't bounce — it falls into a slot, the value is added to bonus.
- Fever bucket catch does NOT remove the ball (it continues falling). The turn ends cleanly when all active balls deplete.

**Source**: `src/entities/bucket.lua`, `src/entities/fever_buckets.lua`, `Engine:stepSimulation()` in `src/engine/core.lua`.

## Config hot-reloading

Pressing `R` calls `reloadConfig()` which:
1. Clears `package.loaded["src.config"]`
2. Re-requires the module
3. Merges new values into the existing `Config` table in-place (so other modules' references update)
4. Applies window mode changes
5. Rebuilds the level and resets the turn

This allows real-time tuning of physics constants, peg values, timing thresholds, and visual parameters without restarting.

**Source**: `reloadConfig()` (benchmark mode in `src/bench/mode.lua`), `GameState:keypressed("r")` in `src/states/game.lua`.
