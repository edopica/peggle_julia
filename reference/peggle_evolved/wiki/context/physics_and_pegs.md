# Physics and Peg Systems Architecture

This document describes the current architecture for physics, collision detection, and peg definitions in Peggle Evolved. The game employs a custom 2D deterministic physics engine, prioritizing reproducibility over the general-purpose, but less predictable, Box2D library.

## Physics System and Bouncing Strategy

The core physics loop is handled in `src/systems/physics.lua`.

### 1. Continuous Collision Detection (CCD)
The engine relies on a swept-collision or Continuous Collision Detection (CCD) model to prevent "tunneling"—a common issue where fast-moving objects skip over thin obstacles between frames. During each update step, the system traces the exact path of each active ball given its velocity (`vx`, `vy`) and the current time delta (`dt`).

### 2. Time of Impact (TOI) and Iterative Sub-stepping
The bouncing strategy operates via an iterative sub-stepping loop:
- The system keeps track of `time_remaining`, which starts as the full `dt` for the frame.
- It iterates a maximum of `max_iterations` (currently 5) per frame.
- In each pass, it sweeps the ball's movement vector against all scene boundaries and obstacles, looking for the minimum Time of Impact (`min_t`, normalized from 0.0 to 1.0).
- If a collision occurs (`min_t < 1.0`), the physics state of the ball is moved to slightly before the exact point of impact (`move_x * safe_t`, `move_y * safe_t`) using a `safe_t_margin` to prevent tunneling stickiness.
- **Presentation Layer**: Because `safe_t` introduces a tiny physical standoff, and because the actual collision `frame_t` is rarely sampled perfectly by the fixed vsync render cadence, a separate render-only `ContactEvents` system captures the exact geometric impact center. On the next draw, it overrides the ball's interpolated render position to guarantee an exact-contact frame with no visible gap (see `failures/0006-bounce-contact-presentation-gap.md`).
- The remaining time for the frame is then adjusted to `time_remaining * (1 - min_t)`. 

### 3. Collision Resolution and Bounce Math
When an impact occurs:
- The exact surface normal (`hit_nx`, `hit_ny`) at the point of intersection is calculated based on the shape geometry.
- For moving obstacles (like circuit pegs), the ball's velocity is computed relative to the peg's *translational* velocity (`vx`, `vy`) only. Angular velocity (`va`) is deliberately excluded from the impulse: transferring spin into the bounce produced unpredictable, physics-breaking launches (see failures/0004), and rotating contact geometry is instead handled exactly by angle slicing (see section 6).
- The ball's relative velocity is dotted against the normal.
- If the dot product is negative (moving towards the surface), the velocity is reflected across the normal:
  ```lua
  local impulse_x = -(1 + bounce_factor) * dot * hit_nx
  local impulse_y = -(1 + bounce_factor) * dot * hit_ny
  ```
- `bounce_factor` comes from `Config.restitution` (general bounce) or `Config.wall_damping` (side wall impacts).
- **Bounce settling threshold**: a contact whose normal approach speed (`-dot`) is below `Config.bounce_min_normal_speed` (100 px/s) is a resting/creeping contact, not a bounce. It uses the reduced `Config.settle_restitution` (0.2) and reports `did_bounce=false`, so micro-contacts do not reset style-shot slide runs. The non-zero settle restitution keeps the ball from wedging permanently in tight corners.
- An explicit discrete push-out is also applied if initial overlapping is detected (`min_t == 0`) to prevent getting permanently stuck.
- Gravity is applied piecewise: it accelerates the ball proportionally to the time spent *before* the collision, and any leftover time accelerates the newly bounced vector.

### 4. Graze Tolerance
A specific design allowance called `Config.graze_tolerance` allows the ball to register a visual "hit" on a peg without triggering a physical bounce if the mathematical intersection is extremely shallow. This logic is applied uniformly across all peg types (circles, arcs, flat sides of rectangles, and flat caps of annular pegs), ensuring grazing shots always feel forgiving and rewarding regardless of the peg's geometry.

### 5. Rotating Pegs: Angle Slicing and De-penetration
The renderer interpolates peg rotation across the frame (`prev_angle → angle`), but a swept check can only freeze a peg's angle at one instant. Freezing it for the whole frame produced visible mismatches of up to `|va| * dt * bounding_radius` pixels (e.g. ~8.5 px for a 200×40 rect at 5 rad/s): the ball bounced off — or clipped into — a position the peg was no longer drawn at (see failures/0005).

Two complementary mechanisms keep physics and rendering consistent:

1. **Angle slicing** (`checkRectangles`, `checkAnnulars`): for pegs with `va ~= 0`, the sub-step window is split into slices such that the surface arc travelled per slice (`|va| * slice_time * bounding_radius`) stays below `Config.rotation_sweep_arc_px` (0.5 px, capped by `Config.rotation_sweep_max_slices` = 32). Each slice runs the ordinary frozen-angle sweep with ball/peg positions and angle evaluated at slice start (matching the renderer's linear interpolation exactly at slice boundaries); hit times are converted slice-local → iteration-wide. Annular cap normals and corners are recomputed at the slice angle rather than translated from stale end-of-frame values.
2. **End-of-frame de-penetration**: `min_t == 0` push-outs consume an iteration but no time, so resting contact on a fast spinner can exhaust `max_iterations`; the ball then freezes mid-frame while pegs advance to their final transform, starting the next frame interpenetrated. After the iteration loop, a discrete position-only pass pushes the ball out of any peg it still overlaps (circle/rect/annular at their final transforms) and lights the peg. Velocity is untouched; the pass is deterministic (array order) and normally fires only on sub-pixel frozen-angle lag.

### 6. Multi-ball Support and Ball-Ball Collisions
The physics engine and game state natively support multiple concurrent balls. The game state tracks an `active_balls` collection, and `Physics.update` sequentially processes the time substeps for all balls in the array.

Launched balls collide with each other. Inside each ball's CCD iteration, every other launched ball is swept as a moving circle (`checkBalls`) with a combined radius of `2 * ball_radius`. Other balls use the same moving-obstacle model as pegs:

- A ball **not yet processed** this frame is treated as starting at its stored position and moving with its current velocity over the iteration window. An impulse delivered to it changes the velocity its own sub-step will use.
- A ball **already processed** is treated like a peg: its stored position is the frame-end and the window start is back-derived as `position - vend * window`, where `vend` is the velocity it actually finished its sub-step with (post-bounce), so a bounced ball does not phantom its pre-bounce direction into later sweeps.

Resolution is an equal-mass impulse: `j = -(1 + e) * dot / 2` along the contact normal, applied `+j` to the sweeping ball and `-j` to the other, with `e = Config.ball_ball_restitution`. Momentum is conserved exactly. The existing settling threshold (`bounce_min_normal_speed` / `settle_restitution`) also applies, so creeping contacts do not register as bounces. Coincident centers (green-power multiball spawns) seed the normal from the relative motion so the pair separates without a zero-length normal. After the peg de-penetration passes, an end-of-frame `depenetrate_balls` pass pushes the current ball out of any residual ball overlap (position only).

Every ball-ball contact is reported as a raw `ball_contact_ball` event with both stable ball ids (`ball_id`, `other_ball_id`), the contact kind, the bounce flag, and incoming/outgoing velocities for both balls. The reducer ignores this event type (balls do not score); StyleShots treats a real bounce as a slide-run reset for both balls. `Config.ball_ball_collisions = false` restores the legacy pass-through behavior for A/B diagnostics.

## Peg Architecture

Pegs are defined in `src/entities/peg.lua` as plain Lua tables (following the data-driven entity pattern).

### Shape-Based Partitioning
To optimize the continuous collision detection passes, the game state separates pegs into three distinct tables (`circle_pegs`, `rect_pegs`, and `annular_pegs`) when a level is initialized. The `Physics.update` function accepts these separate lists directly. This eliminates the need to iterate over all pegs multiple times and perform dynamic shape checks (`if peg.shape == ...`) within the tight sub-stepping collision loop.

### Shape Profiles
Pegs support multiple geometric profiles:
- **Circles:** Default profile. Defined by a `radius`. Collision is a standard swept circle-circle test.
- **Rectangles (OBB):** Defined by `width`, `height`, and an `angle`. Precalculates sines and cosines for fast rotation math. Collision involves transforming the ball into the rectangle's local space to perform swept AABB and corner-circle tests.
- **Annulars (Curved Arcs):** Defined by an inner radius (`r_in`), outer radius (`r_out`), and a sweep angle (`theta_start` to `theta_end`). Complex collision handling tests against outer/inner bounds, flat end-caps, and the 4 boundary corners.

### Metadata and Broadphase
To optimize collision passes:
- Pegs cache a `bounding_radius`, which is used in a rapid distance-squared broadphase check. If a ball's swept path doesn't come near the bounding radius, the complex narrow-phase math is entirely skipped.
- Pre-computed arrays, like `peg.corners` or `peg.polygon` (for drawing), are generated at initialization to save frame processing time.

### State and Types
- Each peg tracks a `hit` boolean, turning `true` when the physics system registers a collision.
- The base characteristics (color, score value) are decoupled from the entity itself and rely on `Config.peg_types`. The specific type ("blue", "red", "purple") dictates how it evaluates its score and blends its lighting color upon being hit.
