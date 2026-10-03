# ADR-0004: Per-Level Virtual Resolution

## Status
Accepted — supersedes the fixed-resolution portion of ADR-0003

## Context
ADR-0003 established a single fixed virtual resolution (originally 900×1200, later 1200×1900) for all levels. While this prevented physics drift, it forced every level into the same coordinate space — levels with small peg layouts appeared tiny, and levels designed for different aspect ratios wasted screen area.

## Decision
Allow each level to define its own `virtual_width` and `virtual_height` in its data table. If a level omits these fields, the global defaults from `Config` apply (1200×1900).

A new `LevelManager` module (`src/systems/level_manager.lua`) owns the resolved virtual dimensions:

- At level load, `LevelManager.load(name)` reads per-level resolution from the level data, falling back to `Config.virtual_width` / `Config.virtual_height`.
- All gameplay systems (physics walls, bucket positioning, ball spawn, fall-out detection, level validation, Screen transform) read from `LevelManager.virtual_width` / `LevelManager.virtual_height` instead of `Config`.
- The window uses desktop-native resolution in fullscreen mode (auto-detected), with a 1920×1080 windowed fallback.
- Any mismatch between the level's aspect ratio and the window produces centered black bars (letterboxing/pillarboxing).

## Consequences
### Positive
- Levels can tightly frame their peg layouts for better visual presentation.
- Different aspect ratios per level are fully supported with automatic letterboxing.
- Benchmark levels continue to use Config defaults with zero changes needed.
- Hot-reload (`R` key) continues to work — `LevelManager.load()` re-resolves dimensions.

### Negative / Trade-offs
- All systems that previously read `Config.virtual_width` / `Config.virtual_height` must now read from `LevelManager`. New systems must follow the same pattern.
- Circular dependency between `LevelManager` and `Screen` is resolved via lazy `require` in `Screen`.
