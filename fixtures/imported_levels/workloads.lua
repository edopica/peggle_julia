-- Imported screenshot levels: full-grid workloads for Lua/Julia sweep parity.
--
-- Loaded explicitly with `--workloads fixtures/imported_levels/workloads.lua`
-- against the dev tree; the pinned M1 reference cannot load these levels.
return {
  { id = "b1_full", level = "b1", balls = 1, group = "imported_levels",
    note = "B1: 6 circles, 24 rectangles, 64 ribbons; static world-scale screenshot reconstruction" },
  { id = "b2_full", level = "b2", balls = 1, group = "imported_levels",
    note = "B2: 19 circles, 57 rectangles, 13 annular (no ribbons); static world-scale screenshot reconstruction" },
  { id = "g1_full", level = "g1", balls = 1, group = "imported_levels",
    note = "G1: 35 circles, 61 ribbons; static world-scale screenshot reconstruction" },
  { id = "m1_full", level = "m1", balls = 1, group = "imported_levels",
    note = "M1: 68 circles, 22 ribbons; static world-scale screenshot reconstruction" },
  { id = "m2_full", level = "m2", balls = 1, group = "imported_levels",
    note = "M2: 63 circles, 52 ribbons; static world-scale screenshot reconstruction" },
}
