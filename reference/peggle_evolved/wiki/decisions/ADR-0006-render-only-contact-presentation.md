# ADR-0006: Render-Only Exact Contact Presentation

**Date:** 2026-07-24  
**Status:** Accepted  

## Context

Peggle Evolved features a continuous collision detection (CCD) deterministic physics engine operating at a fixed 60Hz. To ensure visual smoothness on higher-refresh-rate displays, entity positions are linearly interpolated (lerped) between previous and current physics steps at draw time based on the rendering `alpha`. 

However, users reported "ghost bounces"—a persistent visual gap between the ball and the peg at the apex of collisions. Investigations revealed two root causes:
1. **Physical Standoff:** The physics system employs a `Config.safe_t_margin` (0.001) that stops the ball slightly before the exact time of impact (TOI) to prevent numerical tunneling and resticking. 
2. **Presentation Sampling Rate:** At typical display refresh rates, the exact fractional interpolation alpha corresponding to the collision TOI (`frame_t`) is almost never naturally sampled by the draw loop. The rendered frames invariably straddle the apex, showing the ball approaching and then receding without ever drawing the exact contact frame.

An initial attempt to fix this ("Option 1") modified the physics system to inject the exact geometric TOI into the ball's interpolation path (`draw_path`). While this eliminated the gap, it desynchronized the visual arc from the physics arc by the margin vector, causing visible "snap-back" jitter at subsequent frame boundaries.

## Decision

We decouple exact collision presentation from the physics simulation by introducing a render-only contact queue (`ContactEvents`).

1. **Read-Only Physics:** The physics sub-step resolves collisions natively with `safe_t_margin` and remains completely unaware of presentation logic. It merely emits read-only collision records to the `ContactEvents` queue.
2. **Render-Time Override:** During the draw loop, `ContactEvents` checks if a collision's impact time (`frame_t`) has passed. For exactly *one rendered frame*, it overrides the ball's interpolated `draw_path` and the peg's interpolated angle/position with the exact geometric TOI coordinates.
3. **Queue Retention:** Because a single draw call might encompass multiple simulation steps (or none, in slow motion), the event queue persists across frames, guaranteeing at-least-once and at-most-once presentation of every physical impact.
4. **Lighting Synchronization:** The gameplay hit state (`peg.hit`) triggers instantly in physics, but the visual glow is delayed and latched (`peg.visual_hit`) until the exact contact frame is presented.

## Consequences

**Positive:**
- **Zero Gap:** The ball is guaranteed to be rendered visibly touching the peg at the exact impact center, satisfying the visual expectation of contact.
- **No Snap-Back:** Because `draw_path` exactly tracks the physics trajectory again, there is no interpolation desynchronization or teleportation jitter.
- **Determinism Maintained:** The core physics loop is untouched. Standoff margins and trajectory calculations remain strictly deterministic.
- **Correct Lighting:** Pegs light up exactly when the visual contact occurs, not before.

**Negative:**
- **Complexity:** Requires a cross-frame stateful queue managed between the `Engine` update and draw phases.
- **One-Frame Discontinuity:** For exactly one frame, the ball's visual position jumps off its mathematically continuous interpolated curve to touch the peg. At 60+ FPS, this is perceived as a satisfying exact strike rather than a stutter, but it is technically a discontinuity.

## Addendum (2026-09-12): Exact presentation is for discrete bounces only

The original rule presented every swept contact. In continuous contact (a ball
rolling around an annular arc) the ball records several contacts per physics
step — more than the one presentation a rendered frame can show — so the
presenter fell behind and drew the ball at stale impact centers (up to 167 px
off). The renderer now discriminates on the physics-computed `did_bounce`
field (`true` when normal approach speed ≥ `Config.bounce_min_normal_speed`):

- **Presentable:** swept contacts with `did_bounce == true` — discrete
  impacts, presented at the exact contact center for one frame.
- **Not presentable:** settle/continuous contacts (`did_bounce == false`) and
  overlap/depenetrate events. They are never overridden; the ball follows its
  normal interpolated path and pegs light immediately.

This is render-only. `did_bounce` is emitted read-only by physics and no
physics computation, ordering, RNG, or state changes.