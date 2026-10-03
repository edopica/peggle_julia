# ADR-0001: Custom Swept Continuous Collision Detection (CCD) Physics

## Status
Accepted

## Context
Standard discrete physics updates (`position = position + velocity * dt`) lead to tunneling issues at high velocities, especially with small projectiles like balls and thin peg geometries. Relying on LÖVE2D's default Box2D physics module introduces external dependencies, cross-platform non-determinism, and unwanted rigid-body dynamics.

## Decision
Implement a custom, fully deterministic physics engine using swept-circle Continuous Collision Detection (CCD) in `src/systems/physics.lua`.

- **Deterministic Sub-stepping:** Physics updates run on a fixed 1/60s timestep.
- **Time of Impact (TOI):** Collisions calculate exact time fractions (`0.0 <= t <= 1.0`) via quadratic equation solutions for circle-circle collisions and linear intersection for boundary walls.
- **Broad-Phase Filtering:** Bounding sphere checks filter out distant pegs prior to exact TOI evaluation.
- **Sorted Pairs:** Collision pairs are strictly sorted prior to resolution to maintain frame determinism.

## Consequences
### Positive
- Cross-platform determinism across framerates and seeds.
- Zero tunneling through pegs or boundary walls.
- Full control over restitution, aiming trajectory prediction, and hit event hooks.

### Negative / Trade-offs
- Manual implementation effort required for non-circle geometries or complex moving bodies.
- Increased CPU overhead for TOI sub-stepping under dense peg conditions (mitigated by broad-phase filtering).
