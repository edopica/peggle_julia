# 0004 Circuit Rotation Physics Explosion

## Context
When a ball hit a circular or annular peg moving downward in a circuit (specifically an `ellipse` path which returns a rotation delta), the ball violently shot upwards at speeds exceeding 1000 units/s. Additionally, when attempting to fix this physics issue, stationary annular pegs began violently flickering and vibrating visually.

## Failure
1. **The Bounce Bug**: `src/systems/circuits.lua` calculated the angular velocity of moving pegs via a numerical derivative: `peg.va = (new_angle - old_angle) / dt`. However, `src/entities/peg.lua`'s `set_transform` function was conditionally discarding `new_angle` for non-rectangular shapes. Because of this, `old_angle` evaluated to `0`, while `new_angle` accumulated linearly over time. The result was a massive, infinitely-growing angular velocity (e.g., >400 rad/sec) passed to the collision engine. The collision resolver applied tangential forces via `pvy = pvy + pva * rx`, introducing hundreds of units of false upward velocity to the peg and causing the massive repulsive force upon contact.
2. **The Visual Flicker Bug**: `src/engine/core.lua` overloaded the `peg.prev_angle` property to store the `theta_start` arc offset for `annular` pegs instead of the previous rotation delta. When `peg.angle` was fixed to accurately track the delta `da`, the draw interpolation inside `Peg.draw` evaluated an interpolation between `-90` degrees (the start arc) and `0` degrees (the rotation delta) based on the rendering delta `alpha`. This caused stationary annular pegs to jitter wildly between these two extreme angles every frame.

## Resolution
1. Moved `peg.angle = new_angle or peg.angle` out of the shape-specific conditionals in `Peg.set_transform` so that all peg types (even circles without visual rotation) maintain an accurate rotational state. This stabilizes the numerical derivative back to a constant `speed`, rectifying the bounce force.
2. Re-standardized `peg.prev_angle` in `src/engine/core.lua` to store `peg.angle` unconditionally across all shape types.
3. Updated the annular visual interpolation math in `Peg.draw` to offset the polygon via `prev_da + (curr_da - prev_da) * alpha - curr_da`, completely decoupling the rotation delta from the absolute arc `theta_start`. 

## Takeaways
- If a property like `angle` is consumed by a universal system (like rigid body physics or a numerical derivation system), the property *must* be consistently populated by the entity transform, even if the visual rendering component doesn't need or care about the property.
- Overloading properties (like using `prev_angle` to store `theta_start` just because the variable is "available" for that shape) tightly couples unrelated concepts and creates fragile failure scenarios when universal systems are modified.
