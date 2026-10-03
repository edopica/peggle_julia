# Audit 000: Physics and Bouncing Mechanics (Continuous Collision Detection)

## 1. Overview & Verification
This audit reviews the custom physics simulation implemented in `src/systems/physics.lua`, focusing on Continuous Collision Detection (CCD), time-of-impact (TOI) calculations, sub-stepping, and normal vector reflections.

## 2. Technical Mechanics

### A. Discrete vs. Continuous Collision Detection
Standard discrete physics updates (`position = position + velocity * dt`) cause high-speed tunneling through pegs or boundary walls. Peggle Evolved uses a continuous swept-volume approach, solving mathematically *when* within frame `dt` a collision will take place (`0.0 <= t <= 1.0`).

### B. Broad-Phase Bounding Filter
To maintain performance during sub-stepping:
- Each peg defines a conservative `bounding_radius`.
- Sub-step distance calculation: `reach = ball.radius + peg.bounding_radius + movement_length`.
- If `(dx^2 + dy^2) > reach^2`, collision calculation for that peg is bypassed.

### C. Time of Impact (TOI) Quadratic Equation
For a moving circle (ball) and static circle (peg):
- Relative displacement: `move_x = vx * dt`, `move_y = vy * dt`
- Initial separation: `dx = ball.x - peg.x`, `dy = ball.y - peg.y`
- Combined radius: `radius_sum = ball.radius + peg.radius`
- Quadratic coefficients:
  - `a = move_x^2 + move_y^2`
  - `b = 2 * (dx * move_x + dy * move_y)`
  - `c = (dx^2 + dy^2) - radius_sum^2`
  - Discriminant: `d = b^2 - 4*a*c`

If `d >= 0`, the smallest positive root `t = (-b - sqrt(d)) / (2*a)` yields the exact collision moment.

### D. Response Vector Reflection
Upon collision at time `t`:
1. Ball position updates to impact coordinate.
2. Normal vector `N` calculated from peg center to ball center: `N = (ball.pos - peg.pos) / radius_sum`.
3. Velocity reflected across normal: `V_new = V - (1 + restitution) * (V · N) * N`.
4. Friction / tangential damping applied if configured.

#### Settling threshold
Restitution is not applied to arbitrarily slow contacts. If the normal approach
speed (`-dot`) is below `Config.bounce_min_normal_speed` (100 px/s), the contact
is a *settling* contact: it uses `Config.settle_restitution` (0.2, non-zero so
the ball still ejects from wedges) and reports `did_bounce=false`. This keeps
micro-contacts from resetting style-shot slide runs and from sustaining
indefinite low-energy bouncing. The mechanic is stateless and deterministic.

#### Leftover-time integration after `max_iterations`
When the CCD loop exhausts its iteration budget while the ball is still resting
on a surface, the leftover frame time used to apply free-fall gravity *without*
advancing the ball. That broke the work/energy balance and pumped kinetic energy
into the contact every frame: a ball in the slide level's arc bowl was observed
accelerating from ~50 to >3500 px/s with no height to pay for it. The leftover
time now advances the ball first and then applies gravity, matching the loop's
own move-then-gravity order. This bounds contact-heavy trajectories.

## 3. Determinism Checklist
- [x] Fixed timestep sub-stepping (`1/60s`)
- [x] Indexed array iteration (`ipairs`)
- [x] Collision pair sorting before resolution
- [x] Explicit seed management for any RNG calls
