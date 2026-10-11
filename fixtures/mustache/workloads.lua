-- M3 mustache benchmark workload.
--
-- Loaded explicitly with `--workloads fixtures/mustache/workloads.lua` against
-- the dev tree; the pinned M1 reference cannot load the mustache level, so this
-- catalog is never part of harness/workloads.lua.
return {
  {
    id = "mustache_full",
    level = "mustache",
    balls = 1,
    group = "mustache",
    note = "99 static pegs (27 circle, 72 annular) from the dev tree; M3 full-physics benchmark",
  },
}
