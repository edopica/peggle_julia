# Imported screenshot levels fixture corpus

Five static boards reconstructed from screenshots by
`../level_segment/levels/{b1,b2,g1,m1,m2}`. The levels live only in the
peggle_evolved dev tree, so the corpus is captured there, not from the pinned
M1 reference.

| Level | Gameplay pegs | Composition | level_seed |
| --- | ---: | --- | ---: |
| b1 | 94 | 6 circles, 24 rectangles, 64 ribbons (142 pieces) | 20261113 |
| b2 | 89 | 19 circles, 57 rectangles, 13 annular (no ribbons; control) | 20261111 |
| g1 | 96 | 35 circles, 61 ribbons (178 pieces) | 20261111 |
| m1 | 90 | 68 circles, 22 ribbons (68 pieces) | 20261111 |
| m2 | 115 | 63 circles, 52 ribbons (84 pieces) | 20261111 |

Each level has 25 red and 2 green pegs; the rest are blue.

## Files

- `artifact/<level>.v1.json`: exported `peggle.level` artifacts (ribbon pegs
  carry their annular `parts`; see
  [ribbon pegs](../../wiki/context/ribbon-pegs.md)).
- `config.dev.v1.json`: dev-tree config artifact (`RULES_RAMP_BUCKET`).
- `catalog.lua`: 25 shots, aims 0/450/900/1350/1800 per level.
- `workloads.lua`: one full-grid workload per level (sweep parity).
- `expected/*.json`, `traces/*.jsonl`: Lua records and canonical traces.
  `julia/PeggleSim/test/test_imported_levels.jl` replays them byte-for-byte.

```bash
scripts/capture_imported_levels.sh          # export + capture
scripts/capture_imported_levels.sh --check  # verify only
```

## Colors

The generators order each level's pegs so that the seeded `PegColors.init`
shuffle under the artifact `level_seed` reproduces the screenshot colors. The
fixtures keep that seed because the Lua engine uses it. Julia campaigns draw a
per-match color seed instead (`--colors per_game`, the default), so colors
are not fixed by the level.

## Shots (Lua capture, Julia identical)

Captured from the peggle_evolved dev tree at `10ee3a0` (clean tree
`b3630882…`, config `src/config.lua` sha256 `e40d659e…`). The config artifact
selects `RULES_RAMP_BUCKET` (ramp bucket, catch hold, one-ball multiball,
launch speed 400, wall damping 0.8); it is byte-identical to
`campaigns/ribbon/config.v1.json`. See
[bucket ramps](../../wiki/context/bucket-ramps.md).

| Shot | Aim | Steps | Reason | Pegs | Reds | Spawned | Score | Styles |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | --- |
| b1_right_wall | 0 | 317 | fell_out | 8 | 3 | 0 | 2800 | — |
| b1_right | 450 | 369 | fell_out | 10 | 2 | 0 | 2800 | — |
| b1_center | 900 | 491 | fell_out | 12 | 3 | 0 | 4680 | — |
| b1_left | 1350 | 169 | fell_out | 5 | 2 | 0 | 1150 | — |
| b1_left_wall | 1800 | 395 | fell_out | 7 | 0 | 0 | 490 | — |
| b2_right_wall | 0 | 424 | fell_out | 15 | 4 | 1 | 17650 | — |
| b2_right | 450 | 348 | fell_out | 15 | 4 | 1 | 15000 | — |
| b2_center | 900 | 528 | bucket_caught | 11 | 4 | 0 | 15170 | — |
| b2_left | 1350 | 310 | fell_out | 15 | 3 | 1 | 13650 | — |
| b2_left_wall | 1800 | 119 | fell_out | 2 | 0 | 0 | 40 | — |
| g1_right_wall | 0 | 453 | bucket_caught | 18 | 4 | 0 | 24720 | slide:1 |
| g1_right | 450 | 310 | fell_out | 10 | 2 | 0 | 7700 | — |
| g1_center | 900 | 247 | fell_out | 3 | 1 | 0 | 360 | — |
| g1_left | 1350 | 289 | fell_out | 9 | 3 | 0 | 7650 | — |
| g1_left_wall | 1800 | 256 | fell_out | 6 | 1 | 0 | 900 | — |
| m1_right_wall | 0 | 405 | fell_out | 16 | 5 | 0 | 9760 | — |
| m1_right | 450 | 315 | fell_out | 5 | 1 | 0 | 700 | — |
| m1_center | 900 | 199 | fell_out | 2 | 0 | 0 | 40 | — |
| m1_left | 1350 | 116 | fell_out | 2 | 0 | 0 | 40 | — |
| m1_left_wall | 1800 | 278 | fell_out | 10 | 3 | 2 | 3700 | — |
| m2_right_wall | 0 | 741 | fell_out | 28 | 4 | 0 | 17920 | — |
| m2_right | 450 | 309 | fell_out | 14 | 4 | 0 | 7000 | — |
| m2_center | 900 | 521 | fell_out | 14 | 3 | 0 | 5740 | — |
| m2_left | 1350 | 698 | bucket_caught | 16 | 4 | 0 | 18320 | — |
| m2_left_wall | 1800 | 466 | bucket_caught | 13 | 1 | 0 | 15360 | lucky_bounce:1 |

`Spawned` counts green-power balls; under the one-ball multiball rule each
green hit spawns one ball (m1_left_wall hits both greens). A `bucket_caught`
shot ends after the caught ball falls out and the 90-step catch hold elapses.

The classic-rule capture at `bbd8622` (config `0e34b40…`) that this corpus
replaced is in git history (commit `8cb8d51`). The full-grid sweep reports
`results/ribbon_port/sweep-compare-*.json` were measured against that
classic-rule capture and are kept as a historical record.

These are the six "real" levels (with `ribbon_waves`) that the Julia tests,
campaigns and benchmarks use; see `wiki/context/testing.md`.
