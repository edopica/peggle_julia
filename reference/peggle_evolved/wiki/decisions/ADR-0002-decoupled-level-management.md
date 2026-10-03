# ADR-0002: Code-First Decoupled Level Management

## Status
Accepted

## Context
Hardcoding level geometry and peg configurations inside the main game loop (`main.lua`) hinders rapid iteration, level testing, and version control. 

## Decision
Adopt a code-first, table-driven level format stored in `src/levels/`.

- Each level is an independent Lua script returning a standard table structure (`name`, `pegs`, `circuits`, `type_counts`, `seed`).
- Level instantiation is decoupled from core game state, allowing `main.lua` to load, unload, and hot-reload levels dynamically.

## Consequences
### Positive
- Level layouts are stored in plain text version-controllable Lua tables.
- Enables live hot-reloading of level layouts without restarting the engine.
- Supports programmatic level generation and procedural seeding.

### Negative / Trade-offs
- Requires code editing or dedicated level editor tools rather than drag-and-drop WYSIWYG editors.
