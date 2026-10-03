# Failure Report 0001: Top-Corner Peg Trajectory Boundary Conflict

## Symptom
When aiming at pegs located near the top corners of the playfield (e.g., `x = 62, y = 71`), the player is physically unable to arc the ball so that it lands on the top of the peg. The ball either strikes the side of the peg or the trajectory gets disrupted.

## Root Cause Analysis
The physics engine's Continuous Collision Detection (CCD) is mathematically sound. The issue stems from environmental boundary limits and spawn coordinates:

1. **Ceiling Barrier Height:**
   - Ball spawn point: `(400, 50)`
   - Ceiling boundary: `y = 0`
   - Top peg location: `y = 71.67`

   To hit a peg from above, the ball requires a high parabolic arc. Because the ceiling was set at `y = 0` (only 50 pixels above the ball spawn point), upward shots immediately collided with the ceiling wall, causing an unwanted bounce downwards.

2. **Trajectory Preference:**
   Flat arcs fail to clear the upper curve of high-placed pegs without adequate ceiling clearance.

## Mitigation & Resolution
1. Raised the ceiling layout boundary (`Config.layout.ceiling = -200`) in `src/config.lua` and updated virtual resolution clipping bounds in `src/systems/screen.lua`.
2. Documented launcher height and camera margin requirements for level design.

> **Modernization note (2026-07-25):** The `Config.layout` sub-table was later removed. Ceiling boundary enforcement is now handled by `src/systems/level_validator.lua`, which filters pegs that extend beyond the playfield walls at level load time. The virtual resolution system has also evolved — see ADR-0003 and ADR-0004.

(End of file — total 24 lines)
