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
- `config.dev.v1.json`: dev-tree config artifact.
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

| Shot | Aim | Steps | Reason | Pegs | Reds | Spawned | Score | Styles |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | --- |
| b1_right_wall | 0 | 512 | fell_out | 19 | 1 | 2 | 5320 | — |
| b1_right | 450 | 276 | fell_out | 11 | 3 | 0 | 4180 | — |
| b1_center | 900 | 325 | bucket_caught | 10 | 4 | 0 | 14600 | — |
| b1_left | 1350 | 565 | fell_out | 13 | 4 | 0 | 12740 | — |
| b1_left_wall | 1800 | 346 | fell_out | 22 | 7 | 2 | 18700 | — |
| b2_right_wall | 0 | 451 | fell_out | 20 | 5 | 2 | 23000 | — |
| b2_right | 450 | 61 | fell_out | 2 | 0 | 0 | 40 | — |
| b2_center | 900 | 444 | fell_out | 18 | 5 | 2 | 11340 | — |
| b2_left | 1350 | 246 | fell_out | 7 | 1 | 0 | 1120 | — |
| b2_left_wall | 1800 | 182 | fell_out | 2 | 2 | 0 | 5400 | off_the_wall:1 |
| g1_right_wall | 0 | 169 | fell_out | 7 | 1 | 0 | 4550 | — |
| g1_right | 450 | 264 | fell_out | 10 | 4 | 0 | 4600 | — |
| g1_center | 900 | 468 | fell_out | 15 | 2 | 0 | 9950 | slide:1 |
| g1_left | 1350 | 132 | fell_out | 5 | 2 | 0 | 1150 | — |
| g1_left_wall | 1800 | 600 | fell_out | 20 | 6 | 0 | 19800 | slide:1 |
| m1_right_wall | 0 | 335 | fell_out | 8 | 2 | 0 | 2080 | — |
| m1_right | 450 | 390 | fell_out | 10 | 2 | 2 | 2800 | — |
| m1_center | 900 | 195 | fell_out | 3 | 0 | 0 | 90 | — |
| m1_left | 1350 | 358 | fell_out | 17 | 5 | 0 | 10540 | — |
| m1_left_wall | 1800 | 714 | fell_out | 22 | 7 | 2 | 18700 | — |
| m2_right_wall | 0 | 553 | fell_out | 28 | 3 | 2 | 15400 | — |
| m2_right | 450 | 407 | fell_out | 13 | 4 | 0 | 11370 | slide:1 |
| m2_center | 900 | 475 | fell_out | 15 | 4 | 0 | 7650 | — |
| m2_left | 1350 | 555 | fell_out | 21 | 9 | 0 | 36710 | slide:1 |
| m2_left_wall | 1800 | 381 | bucket_caught | 16 | 3 | 0 | 21880 | slide:1 |

Full-grid sweeps (1,801 aims per level) agree with Lua on every candidate:
`results/ribbon_port/sweep-compare-*.json`.

## Status after peggle_evolved 10ee3a0

This corpus was captured at `bbd8622` under the classic rules (classic bucket,
two-ball multiball, launch speed 600, wall damping 1.0). Its config artifact
still selects `RULES_CLASSIC`, and Julia replays it byte-identically. It is
**stale relative to the dev tree** from `10ee3a0` onward: the `--check`
capture fails, because the config, the artifact provenance and every shot
changed. See [bucket ramps](../../wiki/context/bucket-ramps.md).
