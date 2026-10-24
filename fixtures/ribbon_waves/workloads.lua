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
    note = "133 static pegs (53 circles r10 + 80 annular segments=16 in 5 zero-gap Lines.generate lines, exact terminal arcs steepen outward) on 702.27x613.18 world; full-physics benchmark",
  },
}
