# ribbon_waves fixture corpus (v3, one slide per ribbon)

`ribbon_waves` is a playable Peggle Evolved level reconstructed from a
segmented real-level screenshot, plus a three-shot Lua-vs-Julia trace corpus.
The level is a **dev-tree** level (`src/levels/ribbon_waves.lua`, untracked,
generated), like `mustache.lua`; it is not part of the pinned M1 interchange.

**v3 supersedes v1 and v2.** The 2026-10-21 v1 fit each brick independently
and was rejected: the ribbons read as disconnected pieces and the pegs were
too large for the ball. The 2026-10-22 v2 introduced one smooth centerline per
ribbon but still emitted **46 annular bricks** with 1–2 px seam insets; the
user rejected it because the ribbons still looked like a bunch of distinct
pegs. v3 makes each ribbon **one continuous slide** using exactly the engine's
`squiggly_circle`/`mustache` primitive.

## The correction (v3)

Requirement: **"each ribbon must be a single slide, a single curve that
contains all the pegs, as in the squiggly circle level."**

The old 46-brick approach was wrong for this requirement even though the
bricks shared a centerline: each brick was still its own
`Peg.new_annular` sector, and an adaptive per-seam angular inset (cap
0.02 rad, mean 0.006758 rad) opened 1–2 px gaps to hide cap overlaps. That
reads as 46 pegs with seams, not one slide, and it carried no line metadata,
so the `slide` style could not be awarded. The seams were a workaround for
representing one curve as many single-arc pieces — the opposite of the
contract. v3 removes the per-brick representation entirely: no
`Peg.new_annular` calls in the level, no adaptive seam inset, and no authored
brick boundaries.

## Representation

Each of the five ribbons is exactly one `Path.new` followed by one
`Lines.generate` zero-gap annular line:

```lua
local path_wave_i = Path.new({ segments = { ... } })  -- 10 cubics, open
local line_wave_i = Lines.generate({
    id = "wave_i",
    path = path_wave_i,
    peg = {
        kind = "annular",
        thickness = <ribbon thickness>,
        max_length = 40.0,
        segments = 16,
        type = "blue",
    },
    gap = 0,
    curve_tolerance = 1.0,
})
```

`Lines.generate` is the same primitive used by
[squiggly_circle.lua](../../../peggle_evolved/src/levels/squiggly_circle.lua) and
[mustache.lua](../../../peggle_evolved/src/levels/mustache.lua). It proves that every
neighbouring pair of generated annular pieces shares a full cap before the
level can load, and it stamps the line metadata on each generated peg. The
pieces are the engine's collision/draw tessellation of one continuous path;
they are **not** independently authored bricks. No new slide entity was
needed.

| item | value |
| --- | --- |
| pegs | **167** = **53 circles** (r=10 world) + **114 generated annular** |
| lines | **5**: `wave_1` … `wave_5` |
| generated pegs per line | **20 / 20 / 26 / 28 / 20** (sum 114) |
| line metadata | every annular peg: `line.gap = 0`, `line.closed = false`, contiguous `line.index` 1..count, `shape.segments = 16` |
| circle lines | every circle has `line == nil` |
| level source calls | `Peg.new = 53`, `Lines.generate = 5`, `Peg.new_annular = 0` |
| authored `type_counts` | red 25, green 1, purple 0; blue derived 141 |
| artifact `type_counts` | blue 141, green 1, purple 0, red 25 |
| `level_seed` | 20261021 |

The five lines are the only authored lines; circles carry no line. Colors are
engine-assigned by `PegColors.init` from the seeded pool; the in-game color
layout is arbitrary. The screenshot's purple is not authored, and the normal
turn-1 promotion still happens at play. Positions and shapes are the
contract.

## Path model

The geometry now carries `ribbons[].path` as
`cubic-hermite-lsq-spline-v1`: **10 cubic Hermite segments per ribbon** in
native coordinates, an **8 px end trim**, and LSQ spline knot spacing
**35 px** (`wave_2` uses **60 px**). The affine world transform maps the cubic
control points directly.

| line | knots (px) | fit RMS (px) | fit max (px) | min curvature radius (px) | world thickness |
| --- | ---: | ---: | ---: | ---: | ---: |
| `wave_1` | 35 | 0.356 | 1.284 | 30.16 | 20.454545 |
| `wave_2` | 60 | 1.798 | 7.306 | 27.66 | 20.000000 |
| `wave_3` | 35 | 0.315 | 1.146 | 73.78 | 21.162682 |
| `wave_4` | 35 | 0.325 | 1.125 | 72.80 | 21.162682 |
| `wave_5` | 35 | 0.225 | 0.828 | 52.32 | 21.280909 |

`Lines.generate` options for every line: `segments = 16`,
`curve_tolerance = 1.0`, `max_length = 40.0`, `gap = 0`, `closed = false`.

The geometry's old `pieces` arrays (46, counts 8/8/11/11/8) remain **only** as
seam/color diagnostics; the generator no longer emits them as pegs. Adding
`ribbons[].path` left the path-free geometry byte-identical to the old
`b3e3f615…` hash, so the board transform did not change.

## Engine change

[src/systems/lines.lua](../../../peggle_evolved/src/systems/lines.lua) accepts an optional
`spec.peg.segments` for annular lines and forwards it to
`Peg.new_annular`; `nil` preserves the historical `annular_segments()`
heuristic. The option is validated as an integer ≥ 4 and rejected for
non-annular pegs. `Peg.new_annular` itself is **not changed in v3** — the
optional eighth `segments` argument added in v2 remains, and its final clamp
still applies. Only `ribbon_waves.lua` passes `segments = 16`.

The Lua engine suite passes **483 / 483**, and the mustache artifact
re-exports byte-identically (accounting for the artifact's provenance flags).

## Mask check

[check_ribbon_waves_mask.py](../../scripts/check_ribbon_waves_mask.py) rasterises the **exported
artifact** in native space, cleans the reference mask per ribbon (2.5 px
closing disk + hole fill; the 53 circle components are untouched), and
compares silhouettes with 4× supersampling. Exactly five ribbon bands must
result. The raw mask's speckles are not chased.

| metric | value |
| --- | --- |
| cleaned IoU (authoritative) | **0.944666** (precision 0.964395, recall 0.978803) |
| raw IoU (not gated) | 0.932317 |
| per-ribbon cleaned IoU | 0.930223 / 0.885778 / 0.924359 / 0.918036 / 0.922391 |
| circles (raw mask, informational) | 53, mean IoU 0.994754 |
| regression gates | 0.92 overall, 0.86 per ribbon |
| fidelity reference | 0.97 overall / 0.95 per ribbon — **not reached, not claimed** |

**Honest limit:** the authoritative IoU is **0.944666**, not 0.97. That is
better than v2's 0.937084 *despite removing the seams*, because the smooth
path no longer reproduces the seam notches and end-cap artifacts of the
46-brick representation. The residual is constant thickness per ribbon,
squared arc end caps against rounded mask caps, and smooth-path fit residual
(worst on `wave_2`, whose fit max is 7.306 px), **not** seams. Reaching 0.97
would require per-brick free fitting, which is exactly what the user
rejected. Diff images:
[mask_diff.png](../../fixtures/ribbon_waves/mask_diff.png) (cleaned) and
[mask_diff_raw.png](../../fixtures/ribbon_waves/mask_diff_raw.png).

## Corpus

All three shots use `rule = "bench"`, `max_steps = 3600`, `balls = 1`, and
end with `reason = "fell_out"`.

| id | aim | steps | pegs | reds | score | style | trace events |
| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| `ribbon_waves_center` | 900 | 312 | 21 | 5 | 13,860 | none | 312 |
| `ribbon_waves_left_wall` | 1800 | 658 | 20 | 2 | 7,600 | none | 658 |
| `ribbon_waves_ribbon` | 120 | 434 | 41 | 7 | 47,640 | **`slide` ×1** | 434 |

The `ribbon` shot now awards **SLIDE** because the generated pegs carry line
metadata (v2 explicitly could not). `left_wall` is the true left-ward launch
(`vx < 0`) and awards no style; its category is retained as intent.

## Commands

```bash
# from the julia_clone repository root

# regenerate / validate the level from the frozen geometry
python3 tools/generate_ribbon_waves_level.py
python3 tools/generate_ribbon_waves_level.py --check

# capture/check the corpus (re-exports, mask check, 3 traces)
scripts/capture_ribbon_waves.sh
scripts/capture_ribbon_waves.sh --check

# mask checker
python3 scripts/check_ribbon_waves_mask.py
python3 scripts/check_ribbon_waves_mask.py --selftest

# level load check
(cd ../peggle_evolved && luajit tools/check_level.lua src/levels/ribbon_waves.lua)

# Julia
make julia-test
julia --project=julia/PeggleSim -e \
  'using Test, JSON, PeggleSim; include("julia/PeggleSim/test/test_ribbon_waves.jl")'
```

`check_level` reports **167 pegs (53 circles, 0 rectangles, 114 annular),
ERRORS 0, WARNINGS 0, PASS**. The focused Julia test is **2,675 / 2,675**;
the full Julia suite is **8,292 / 8,292**. It asserts the five line groups,
`segments = 16`, the path contract, and byte-exact Lua traces.

## Provenance

- Level: [src/levels/ribbon_waves.lua](../../../peggle_evolved/src/levels/ribbon_waves.lua), sha256
  `089d2c830fb6f9bb66d7eb40afa4f32de22a9f9ffda5e3593f44969be50480c1`,
  21,406 B (generated; do not edit).
- Geometry: [level_segment/ribbon_waves_geometry.json](../../../level_segment/ribbon_waves_geometry.json), sha256
  `bc52e4282b9ee0c42fc20049f40ba18f6b3f52718a9b04616a786941a7e247ea`,
  225,726 B; copy in `../../fixtures/ribbon_waves/source/`. The path-free
  baseline is byte-identical to the old
  `b3e3f615bb045401e25c12ded7386a7ff794521da1ef0ade09d6538c297e6e6e`.
- Artifact: [ribbon_waves.v1.json](../../fixtures/ribbon_waves/artifact/ribbon_waves.v1.json),
  sha256 `442be8366717cebc0a6bda2f058fe253150397d0b6cfc2ac79edac319ac30eb3`,
  38,879 B; 167 pegs; `type_counts blue 141 / green 1 / purple 0 / red 25`.
- Config: [config.dev.v1.json](../../fixtures/ribbon_waves/config.dev.v1.json), sha256
  `170487a48e936e82e911f45e021f7a7002b8e2f0e29bb2569e271fb62041002a`.
- Artifact provenance: revision
  `da752257f613abbd209f1aa1acdd37a5f9be05f5`, tree
  `61278edc5467bf8399c24f4af0fcf36d75cac6a2`, config sha256
  `a17e60b43b1437510a59ba59c8791b27600a4b7fd7d56bc5f9c18d3e94f114d9`.
- Level generator: [generate_ribbon_waves_level.py](../../tools/generate_ribbon_waves_level.py).

## Known limitations

- Constant ribbon thickness and a 10-cubic smooth path; 0.944666 mask IoU
  ceiling, below the 0.97 fidelity reference.
- The 114 annular pegs are one line's tessellation, not independent bricks;
  edits belong in the path/`Lines.generate` options, never per peg.
- Colors are engine-assigned, not the screenshot's.
- The level is generated and untracked in the dev tree.

## Related

- [fixtures/ribbon_waves/README.md](../../fixtures/ribbon_waves/README.md) —
  corpus details, fixture table, mask evidence.
- [Screenshot of the five continuous waves](../../tmp/ribbon_waves/out/ribbon_waves_single.png)
  (702×613, sha256 `575ffc7f3565a66b1c0304915b94d092ace8e1cbddeb7b8635297507e712e1b7`).
- [level_segment/ribbon_waves_report.md](../../../level_segment/ribbon_waves_report.md)
  — extraction-side report; its 46-piece render/IoU figures are v2 and predate
  the v3 level, which is measured by the mask checker above.
- [peggle_evolved/temp/ribbon_waves-report.md](../../../peggle_evolved/temp/ribbon_waves-report.md)
  — Lua-side report.
