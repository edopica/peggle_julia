# 0003-aim-angle-clamp.md

## Symptom
- The mouse aiming angle would incorrectly snap when aiming at distant objects that required a slightly upwards ballistic lob. This prevented the player from targeting targets at extreme horizontal distances since the upward physics trajectory was discarded.
- Aiming towards the top-left using `math.atan2` produced negative angle values that incorrectly snapped to the bottom-right `0.17` limit due to wrapping issues.

## Root Cause
- `src/engine/core.lua` inside `Engine:mousemoved` used a hard-clamp (`if angle < 0 then angle = (angle > -math.pi / 2) and 0 or math.pi`) to deal with `math.atan2`'s negative half-plane. This immediately forced any upwards firing solution to straight horizontal.

## Solution
- Replaced the hard-clamp with continuous modular angle normalization before applying the standard soft physical limits:
  ```lua
  local mid = math.pi / 2
  while angle < mid - math.pi do angle = angle + 2 * math.pi end
  while angle > mid + math.pi do angle = angle - 2 * math.pi end
  ```
- This perfectly confines the mathematical output to `[-1.57, 4.71]` before being smoothly clamped by `math.max/min(mid - limit, mid + limit)`, preserving all valid physics trajectories, even upward ballistic arcs, while naturally defeating angle wrap-around bugs.