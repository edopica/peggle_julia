# ADR-0003: Fixed Virtual Resolution & Screen Subsystem

## Status
Accepted

## Context
Relying directly on native OS window dimensions (`love.graphics.getWidth()` / `getHeight()`) causes physics drift, inconsistent peg placement, and distorted UI elements across different monitor resolutions and aspect ratios.

## Decision
Establish a fixed virtual resolution (900x1200) managed by `src/systems/screen.lua`.

- All game physics, entity positions, and layout boundaries operate in fixed virtual space.
- The `screen.lua` subsystem handles global scale and translation transforms, rendering letterboxed black borders when OS window aspect ratios mismatch.
- Mouse input coordinates are converted to virtual world coordinates via `Screen.to_world(x, y)`.

## Consequences
### Positive
- Guarantees consistent physics simulation and visual presentation regardless of user display setup.
- Enables seamless window resizing without breaking game coordinates or aiming mechanics.

### Negative / Trade-offs
- Letterboxing introduces pillarbox/letterbox black bars on non-3:4 aspect ratio displays.
