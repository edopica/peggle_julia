# 0006 Bounce Contact Presentation Gap (Ghost Bounces)

## Context
The ball visibly bounced off pegs without ever being drawn touching them — a
persistent small gap at the apex of every bounce. Initial suspicion fell on
the CCD `safe_t_margin` (0.001), which parks the ball `|v|·margin·dt` (~0.016
px) before the exact TOI to avoid re-sticking. A first fix ("Option 1",
commit 8c59577) injected the exact TOI coordinates into `ball.draw_path`;
it made the ball touch at `frame_t` but shifted the whole outgoing visual arc
off the physics arc by the margin vector, so the ball teleported backwards at
every frame boundary after a bounce (snap-back jitter), and the pre-existing
free-flight quirk (`safe_t` also applied at `min_t == 1.0`) compounded it by
drawing the ball 0.1% ahead of physics on every free-flight frame.

## Failure
Presentation-sampling instrumentation (`--present-debug`, per-draw alpha /
step ids / actual sampled transforms / signed separations) proved the
`safe_t_margin` standoff was negligible and not the real defect:

- The *continuous* minimum of the draw interpolation over α∈[0,1] reaches
  ~0.01 px at every collision's `frame_t` — but **no actually presented frame
  lands there**. At 60 Hz vsync the presented alpha sat at ≈0.21–0.25 every
  frame, so 6 of 7 swept impacts in `last_shot` had their `draw_path`
  replaced before the collision alpha was ever sampled; presented samples
  jumped from +0.6…+4.3 px before the peg to +0.9…+7.9 px after it
  (mean closest presented approach 1.8 px).
- A true 0.02x simulation-time run (50 presented frames per step) collapsed
  the presented minimum to ≈ the continuous minimum (0.015–0.11 px,
  α-quantization) — confirming a **presentation-sampling artifact**, not a
  physics or interpolation error.

## Resolution
Render-only contact presenter (`src/systems/contact_events.lua`):

1. Physics reports every physical collision (read-only) into a bounded,
   coalesced event queue that survives across sim steps: sim/path step,
   `frame_t`, exact impact center, peg TOI transform (start-transform +
   relative-motion model), normal, velocities.
2. On each `Engine:draw`, the earliest due event per ball (path step passed,
   or alpha crossed `frame_t`) is presented for **exactly one rendered
   frame**: the ball is drawn at the exact impact center and the peg at its
   retained TOI transform, then the event is consumed after the frame
   finishes drawing.
3. `peg.visual_hit` (render state) latches at presentation; `Peg.draw` lights
   via `visual_hit or (hit and no pending contact)`, so lighting begins on
   the same rendered frame as visible contact while `peg.hit` stays the
   gameplay state. Graze-only hits never generate forced contact frames.
4. Option 1 was reverted: `draw_path` mirrors physics (safe) coordinates
   again, so ordinary interpolation tracks the true trajectory with no
   snap-back; the free-flight quirk itself was left untouched (fixing it
   would change trajectories and invalidate replays).

Verified (`temp/presentation_report.md`): replay traces byte-identical with
presentation on/off; every swept impact presented exactly once with contact
separation ≤ 2.5e-14 px (acceptance was ≤ 0.05); no collision lost at 3 fixed
steps per draw; `--contact-present off` restores the old rendering for A/B.

## Addendum (2026-09-12): discrete bounces only

Presenting every swept contact broke down in continuous contact: a ball
rolling around an annular arc records several contacts per physics step, more
than one rendered frame can show, so the presenter trailed the queue and drew
the ball at stale impact centers (up to 167 px off; see
`temp/report-slide-roll-presentation.md`). The presenter now requires
`did_bounce == true` (normal approach speed ≥ `Config.bounce_min_normal_speed`)
in addition to `kind == "sweep"`. Settle/continuous contacts are not
presentable: the ball is drawn on its interpolated path and the peg lights
immediately, with no exact-contact override. Discrete free-flight bounces keep
the one-frame exact-contact presentation and the contact-gated lighting. The
change is render-only; the physics trace is byte-identical.

## Takeaways
- "Minimum over continuous α" metrics say nothing about what a sampled
  display actually presents; instrument the presented frames themselves
  (step ids, real alpha, real dt/vsync) before fixing the wrong layer.
- Decoupling rendered positions from physics *state* is safe only if the
  visual trajectory stays locked to the physics trajectory everywhere except
  the single instant you deliberately override — shift an arc and you pay it
  back as a teleport at the next path reset.
- Fixes that must not perturb determinism belong entirely on the render side
  of the physics/render boundary: retain exact TOI data at physics time,
  present it at draw time.
- Exact-contact presentation is meaningful only for discrete impacts. A
  continuous-contact event is not a moment to freeze on; presenting it is the
  same class of error as the ghost bounce, one queue deep.
