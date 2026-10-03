-- M0 workload catalog: representative static-level decision states.
--
-- Every workload evaluates the full legal aim grid (indices 0..1800, derived
-- from Config.aim_discretization_steps) from a ready-to-aim turn boundary with
-- zero additional launch delay, unless the CLI overrides the grid.
--
-- ids are stable identifiers used in result files and documentation.
return {
  {
    id = "overhead_static_2p",
    level = "long_shot",
    balls = 1,
    group = "overhead",
    note = "2 static circle pegs; per-candidate fixed overhead floor",
  },
  {
    id = "circles_small",
    level = "circle_level",
    balls = 1,
    group = "circles",
    note = "25 static circle pegs on a 600x500 virtual canvas",
  },
  {
    id = "circles_mixed",
    level = "off_the_wall",
    balls = 1,
    group = "circles",
    note = "16 static circle pegs, 880x550 canvas, red/green mix",
  },
  {
    id = "lines_rect_annular",
    level = "slide",
    balls = 1,
    group = "rectangles",
    note = "static zero-gap lines: 39 circles, 15 rectangles, 19 annular pegs",
  },
  {
    id = "annular_dense",
    level = "squiggly_circle",
    balls = 1,
    group = "annular",
    note = "192 static annular pegs along one closed cubic; dense static layout",
  },
  {
    id = "annular_dense_multi3",
    level = "squiggly_circle",
    balls = 3,
    group = "multiball",
    note = "3 simultaneous launched balls on the dense annular layout",
  },
  {
    id = "lines_rect_annular_multi3",
    level = "slide",
    balls = 3,
    group = "multiball",
    note = "3 simultaneous launched balls on the static line layout",
  },
}
