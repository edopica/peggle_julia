-- ribbon_waves benchmark workload (v5 world-scale level).
--
-- Loaded explicitly with `--workloads fixtures/ribbon_waves/workloads.lua`
-- against the dev tree; the pinned M1 reference cannot load the ribbon_waves
-- level, so this catalog is never part of harness/workloads.lua.
return {
  {
    id = "ribbon_waves_full",
    level = "ribbon_waves",
    balls = 1,
    group = "ribbon_waves",
    note = "99 static gameplay pegs (53 circles r10 + 46 ribbon pegs = 138 annular collision pieces, segments=16, in 5 zero-gap seam-segmented Lines.generate ribbons) on 702.27x613.18 world; full-physics benchmark",
  },
}
