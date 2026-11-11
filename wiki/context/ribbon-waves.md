# ribbon_waves — seam-segmented ribbons (v6)

**Current state (2026-11-11).** The Lua level is now maintained in
`../peggle_evolved/src/levels/ribbon_waves.lua` and must **not** be
regenerated with `tools/generate_ribbon_waves_level.py`. That generator writes
the older unsegmented v5 representation (80 annular gameplay pegs). Each of
the five paths is now one `kind = "ribbon"` line, cut at the screenshot seam x
coordinates (8/8/11/11/8 ribbon pegs). It keeps the v5 curves and fitted
terminal arcs, with thicknesses of 19.4545 (wave_1), 19.0 (wave_2) and the generated
values elsewhere. The board has **99 gameplay pegs: 53 circles + 46 ribbons
(138 annular collision pieces)**. Ribbon semantics and the Julia port are
described in [ribbon pegs](ribbon-pegs.md).

Current shots (recaptured from the dev tree, gravity 700, wall damping 1.0,
one ball, bench rule, max_steps 3600; Julia byte-identical):

| Shot | Aim | Steps | Reason | Pegs hit | Reds | Spawned | Score |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| `center` | 900 | 309 | fell_out | 17 | 5 | 2 | 10,540 |
| `left_wall` | 1800 | 551 | bucket_caught | 20 | 6 | 0 | 24,800 |
| `ribbon` | 80 | 142 | bucket_caught | 5 | 1 | 0 | 10,700 |

Cleaned silhouette IoU is 0.963880; per band it is 0.945089 / 0.902032 /
0.960266 / 0.956509 / 0.955793, and raw IoU is 0.951382. The 0.92 / 0.86
floors pass. The thinner wave_1/wave_2 ribbons explain the small drop from
v5. A full-grid Lua/Julia sweep agrees on all 1,801 aims
(`results/ribbon_port/sweep-compare-ribbon_waves.json`).

The sections below record the v5 terminal-arc work. The geometry they
describe still underlies the paths, but their peg counts and shot table are
historical.

## Geometry and authoring

The pinned extraction remains unchanged. Its silhouette midpoints are biased
near angled end faces. The v4 repair froze those biased endpoints and checked
only constant curvature, accepting the wrong bend at all ten ends. See the
[ribbon-end audit](ribbon-end-audit.md) for the failure analysis.

The generator now replaces the outer **two** source cubics at each end with
an **exact circular arc**. The six middle cubics remain unchanged. The new
arcs fit both side boundaries and the flat end face against the cleaned
reference mask; their endpoints can move. Each joins the body with the same
position and tangent direction (G1 continuity). No engine changes were needed.

- Authoring parameters: [ribbon_waves_ends.json](../../tools/ribbon_waves_ends.json).
- Reproducible fitter: [fit_ribbon_waves_ends.py](../../tools/fit_ribbon_waves_ends.py)
  (numpy, scipy, Pillow; available in `../level_segment/.venv`).
- Generator: [generate_ribbon_waves_level.py](../../tools/generate_ribbon_waves_level.py)
  (standard library plus LuaJIT validation).
- Generated game level: [ribbon_waves.lua](../../../peggle_evolved/src/levels/ribbon_waves.lua).

The design file pins its source geometry hash. Regeneration checks exact arc
angle bounds: each entire terminal arm stays in the upward-bending quadrant,
so steepness increases toward its tip. It also checks the neighboring body's
curvature sign and every tangent join. `--check` compares the installed
executable source with regenerated geometry, in addition to structural checks.
The Julia tests independently verify outward steepening on the **exported
terminal sectors**, not just the authored path.

## Board and measured fidelity

133 pegs = 53 circles (world radius 10) + 80 annular sectors. Each ribbon has
16 generated sectors, `gap=0`, `segments=16`, and continuous line metadata.
World dimensions remain 702.272727 × 613.181818; ball radius is 6. Authored
counts are red 25, green 1, purple 0, blue derived as 107; seed is 20261021.

Cleaned silhouette IoU improved from **0.939040 to 0.966956**. Per-ribbon IoU
is **0.966024 / 0.910620 / 0.960684 / 0.956839 / 0.955757**. Raw IoU is
0.954427. The existing 0.92 overall / 0.86 per-ribbon regression floors pass.
The 0.97 / 0.95 fidelity reference is still not reached everywhere: the
unchanged wave_2 body fit is the largest remaining mismatch. This is not a
pixel-perfect reconstruction, and colors remain engine-assigned.

[Exported overlay](../../tmp/ribbon-refit/exported-overlay.png) ·
[End comparisons](../../tmp/ribbon-refit/end-comparison.png) ·
[Slope plot](../../tmp/ribbon-slope-audit/slopes.svg).
These previews are local diagnostic artifacts. Durable measured evidence is
in `fixtures/ribbon_waves/mask_metrics.json` and the corresponding diff PNGs.

## Gameplay corpus (v5, historical)

All three shots were recaptured from the actual Lua engine with one initial
ball, bench rule, max_steps 3600. The center shot is bucket-caught; the other
two fall out. The left-wall shot awards one slide style. Julia reproduces
all three records and traces byte-for-byte. Line metadata and slide eligibility are present. The current fixture records
contain the exact awarded styles and scores.

| Shot | Aim | Steps | Pegs hit | Spawned | Score |
| --- | ---: | ---: | ---: | ---: | ---: |
| `center` | 900 | 156 | 12 | 0 | 20,560 |
| `left_wall` | 1800 | 590 | 25 | 0 | 24,750 |
| `ribbon` | 80 | 265 | 6 | 0 | 900 |

## Regeneration and validation

```bash
# Optional refitting; review the candidate before replacing the authoring JSON.
../level_segment/.venv/bin/python tools/fit_ribbon_waves_ends.py

# v5 only: do not run against the current hand-maintained Lua level.
# python3 tools/generate_ribbon_waves_level.py
python3 tools/generate_ribbon_waves_level.py --check-geometry
python3 scripts/audit_ribbon_slopes.py --check
scripts/capture_ribbon_waves.sh
scripts/capture_ribbon_waves.sh --check
julia --project=julia/PeggleSim -e 'using Test, JSON, PeggleSim; include("julia/PeggleSim/test/test_ribbon_waves.jl")'
```

The level checker reports zero errors/warnings; the focused Julia suite
passes **2,192 / 2,192**, including emitted geometry and all three replay traces.
The pinned reference is untouched. See the [fixture README](../../fixtures/ribbon_waves/README.md)
for corpus paths and provenance.

The final capture uses the user’s current gravity `700` and wall damping `1.0`;
these settings were preserved, not edited by the level correction.
