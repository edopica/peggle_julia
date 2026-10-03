# 0005 Moving Peg Visual Gap (Invisible Collision)

## Context
After rendering interpolation was introduced (ball/peg/bucket positions interpolated across the fixed 60 Hz physics step to eliminate stutter on high-refresh displays), the user observed the ball bouncing off moving pegs with a visible gap — an "invisible collision" — and one frame where the ball appeared to hit two pegs far apart simultaneously (`temp/report.md`).

## Failure
Two distinct causes, separated by instrumenting the physics with per-hit world-space gap measurements (ball position at resolution time vs. the peg's *interpolated* transform at the same sub-frame instant):

1. **Frozen-angle sweep vs. interpolated rotation**: rectangle and annular sweeps froze the peg's angle at sub-step start (`angle - va * time_remaining`) while the renderer interpolates the angle linearly across the whole frame. The contact point/normal was therefore computed on geometry the peg had already rotated away from — a mismatch of up to `|va| * dt * bounding_radius` (measured 6 px on `test_rotation`'s 200×40 rects at 5 rad/s, plus a pathological double-resolution: a swept hit with a wrong normal immediately followed by a `min_t == 0` pop-out with a different normal). Annular cap normals additionally used stale *end-of-frame* values even at sub-step start. Interpolation did not create this error — at lockstep 60 Hz physics and render states agree at frame boundaries, hiding it; interpolation exposed it mid-frame.
2. **Iteration-exhaustion interpenetration**: in resting contact on a fast spinner, `min_t == 0` push-outs consume an iteration but no time, so `max_iterations` (5) could be exhausted with most of the frame left. The ball then froze mid-frame while the peg kept rotating to its end-of-frame transform (up to ~8.5 px of surface travel), so the next frame *started* with the ball visibly inside the peg — real interpenetration, identical in physics and rendering, ratcheting deeper frame over frame (measured 1.8 → 4.1 px).

The "two pegs far apart" observation was *not* a bug: multi-iteration CCD legitimately resolved two real contacts in one frame (moving peg at `t = 0.21`, static peg at `t = 0.79`); both pegs stay lit while the moving one travels on, reading as a teleport.

## Resolution
1. **Angle slicing** (`checkRectangles`/`checkAnnulars` in `physics.lua`): pegs with `va ~= 0` split the sub-step window into slices such that the surface arc per slice stays under `Config.rotation_sweep_arc_px` (0.5 px, capped at `rotation_sweep_max_slices` = 32). Each slice runs the existing frozen-angle sweep with positions/angle at slice start (matching the renderer exactly at slice boundaries); annular cap normals and corners are recomputed per slice instead of reusing stale values. Slice count derives only from velocities and config constants, preserving determinism.
2. **End-of-frame de-penetration**: after the iteration loop, a discrete position-only pass pushes the ball out of any peg it still overlaps at final transforms (and lights it). This bounds visible interpenetration to zero regardless of iteration exhaustion or frozen-angle lag.

Verified by instrumented harnesses (`temp/rotation_repro.lua`, `temp/trace_run.lua`, `temp/replay_repro.lua`): worst measured gap went from 6.0 px to below 0.5 px in all scenarios with no regressions on non-rotating levels; realistic-profile performance unchanged (0.020 vs 0.015 ms/frame).

## Takeaways
- Any render-side interpolation of a transform the physics freezes is an implicit contract: the sweep must bound its frozen-transform error to stay within the graze tolerance, or the mid-frame states interpolation reveals will be wrong.
- Sub-step loops where a resolution consumes an iteration but no time (`min_t == 0`) need an explicit end-of-frame consistency guarantee; otherwise moving geometry always wins the race against the iteration cap.
- Measure visual artifacts in world space against the *rendered* (interpolated) transforms before changing physics: two of the three reported symptoms (double hit, teleporting peg) were correct physics that only looked wrong.
