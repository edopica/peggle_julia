# Plan — clone the segmented real Peggle level as a playable level + Julia harness fixture

Status: **executed 2026-10-21** — see §11 for the outcome and the three
corrections made during execution. The text below is kept as the original plan.

## 1. Goal

Turn the segmentation in `../level_segment/` (`level.png`, `peg_mask.png`) into:

1. A playable level in `../peggle_evolved` at
   `src/levels/ribbon_waves.lua`.
2. A Julia harness fixture in `../julia_clone/fixtures/ribbon_waves/`
   (level artifact, dev config, shot catalog/traces, tests).
3. A trivial, repeatable check of the produced level against
   `../level_segment/peg_mask.png` (black/white silhouette, uniform peg colors).

Work must be delegated to subagents (orchestrator keeps context). Keep the
three repos clean: no edits to the pinned `julia_clone/reference/` or to
`julia_clone/interchange/` (those are the frozen M1 corpus).

## 2. Decisions already made (can be revisited)

| Decision | Value | Why |
| --- | --- | --- |
| Level name | `ribbon_waves` | Descriptive; not claiming the real Peggle level name |
| Virtual size | `1545 x 1289` | Exactly the `level.png` pixel size; coordinates 1:1 |
| Coordinate mapping | image pixel `(x,y)` == virtual `(x,y)` | Shooter (`vw/2,50`) and bucket (`vh-30`) already line up with the screenshot; mask comparison is pixel-exact |
| Peg radius | `22` | The mask's 53 circle components are all area 1517 → r=22; use r=22 to match the reference |
| Color mapping | visible blue→`blue`, visible orange→`red`, green→`green`, purple→`purple` | Engine type names; `Config.peg_types.red` is the orange/red peg |
| Orange bricks | each orange ribbon brick is a `red` peg | Orange pegs are the level's completion target |
| Shapes | circles = `circle`; ribbon bricks = `annular` sectors | Matches the mustache/ribbon authoring model and the Julia v1 schema |
| Purple | author the visible plus as `purple` (purple=1) for visual fidelity | Mechanics will also promote 1 blue/turn, so the game may show 2 purples; alternative is purple=0 and let it be the promoted peg. Flagged as an open question. |
| Green | author the one visible green peg (green=1) | |
| Scale | none (native pixels) | Mask fidelity is the priority; note ball radius 6 vs peg radius 22 makes the ball relatively small. If play feel matters, reconsider scaling to ~880x734 or adding a per-level ball radius later. |

## 3. Facts learned during exploration

### Repos / paths

- Workspace: `/home/kurapica/Projects/pevo/julia_clone` (Julia port, current).
- Game: `/home/kurapica/Projects/pevo/peggle_evolved` (LÖVE2D/Lua).
- Segmentation workspace: `/home/kurapica/Projects/pevo/level_segment`
  (OpenCV/skimage venv at `level_segment/.venv`).
- `julia_clone/reference/peggle_evolved` is the **pinned, read-only** source.
  `julia_clone/interchange/` is generated from that pin; **do not add levels
  there** (M1 corpus/test `test_level.jl` hard-codes the static level list and
  manifest count).
- The precedent for a dev-tree level + artifact + traces is
  `julia_clone/fixtures/mustache/` and `scripts/capture_m3_mustache.sh`.

### Level format / engine behavior

- Lua level module returns
  `{ pegs, type_counts, level_seed, name, virtual_width, virtual_height }`.
- Peg constructors (`src/entities/peg.lua`):
  `Peg.new(x,y,type,radius)`,
  `Peg.new_rectangle(...)`,
  `Peg.new_annular(x,y,type,r_in,r_out,theta_start,theta_end)`.
- Ribbons/bricks can be emitted as individual `new_annular` pegs (no
  `Lines.generate` needed). `line` metadata is optional in the Julia schema;
  it is only needed for slide **style-shot** detection. If line metadata is
  added, indexes must be consistent per line and pass `Lines.validate`.
- **Critical:** the engine ignores authored `type` on load. `Engine:setupLevel`
  calls `PegColors.init(pegs, type_counts, level_seed)`, which builds a pool
  (`blue*N`, `green*N`, `purple*N`, `red*N`), Fisher–Yates shuffles it with
  LÖVE's seeded RNG, then assigns `peg[i].type = pool[i]` in array order.
  To reproduce the screenshot colors, **order the pegs so pool[i] equals the
  desired type of the peg at position i** (collect desired-type pegs in order
  and fill positions according to the pool sequence). The color layout is then
  exact. The pool sequence can be printed by a tiny LÖVE script that calls
  `PegColors.init` on dummy pegs; a Python reimplementation of LÖVE's RNG is
  not required.
- Export: `julia_clone/tools/export_level.lua --reference <dev-tree> --level
  ribbon_waves --out ... --check ...` applies the same load pipeline and emits
  `peggle.level` v1. It records provenance (git revision/tree, config sha).
  Use the dev tree `../peggle_evolved`, like mustache.
- Julia `load_level` accepts circle/rectangle/annular, requires contiguous ids,
  and rejects motion/circuits. Annular fields: `x,y,r_in,r_out,theta_start,
  theta_end_abs,segments,type`, with `theta_end_abs > theta_start`.
- `julia_clone/scripts/render_level_svg.py` already renders artifact geometry
  to SVG; can be reused for a visual preview, but a raster mask checker is
  needed for pixel comparison.

### Segmentation facts

- `level.png` / `peg_mask.png`: 1545x1289.
- `peg_mask.png`: 73 components; 53 circles (each area 1517, bbox 45x45 →
  r=22) + 20 ribbon fragments that belong to **5 ribbons**.
- The mask circle centers are accurate, including the special pegs:
  green disk center ≈ `(604.4, 315.9)` (mask component `(604,315)`), purple
  disk center ≈ `(799,1033)` (mask component `(799,1033)`).
  The `segmentation_results.png` hard-coded `(587,324)` green zoom label is
  cosmetic and wrong; do **not** use it.
- Circle color classification (sample the original image): ≈ blue 37,
  red/orange 14, green 1, purple 1 = 53. Verify exact counts in extraction;
  some samples hit icon/shadow pixels.
- Ribbon mask: close the 20 fragments with a ~9 px ellipse + fill holes to get
  5 clean bands. Bboxes:
  1. top-right `x 939..1430, y 376..477`
  2. mid-right `x 182..674, y 578..679` (actually mid-left in screen terms)
  3. right `x 809..1480, y 638..763`
  4. bottom-left `x 89..771, y 827..962`
  5. bottom-right `x 871..1364, y 961..1062`
- The bands are x-monotonic. Skeletonization (`skimage.morphology.skeletonize`)
  gives a usable centerline; ordering by x and median-y per x, then
  `scipy.interpolate.UnivariateSpline`, works and has been spot-tested on all
  5 bands. There are a few spurs/multi-y columns at the steeper ends; median by
  x and a smoothing spline handles them.
- Sampling the original image along the centerline yields a clean 1-D material
  sequence: blue core (`B`), orange core (`O`), gold seam (`G`), highlight
  (`W`/`?`). Gold runs mark brick boundaries; run lengths are ~4–16 px near
  steep ends, ~1–8 px on shallow parts. Brick cores are ~43–45 px long.
  Example top-right ribbon runs (x from 942): `O` small, `B` 4+35+7, `G` 8,
  `O` 45, `G`~6+7, `O` 45, `G` 16, `O` 44, `G` 5, `B` 6+45+9, `G` 6,
  `O` 37, `G` 5+3, `O` 8+11, `G` 7. Clean up 1–2 px noise before choosing seam
  centers and brick types.
- Earlier watershed labels (`segment_pegs.py`) split each brick into core +
  gold-rim labels; do not rely on them for per-brick regions. The centerline
  seam detection is more robust. The mask itself is the target.

## 4. Extraction algorithm (subagent A)

Write a self-contained pipeline in `level_segment/` (uses its `.venv`):

1. Read `level.png`, `peg_mask.png`.
2. **Circles:** take the 53 mask components with area ≈1517, centroid as
   center, r=22. Classify type from the original image inside the disk
   (exclude white icon highlights and dark rim; use median hue over saturated
   pixels). Output list with `x,y,r,type,mask_component`.
3. **Ribbons:** build the 5-band mask (close 9px + fill holes, keep area>5000).
4. **Centerline:** skeletonize each band; order by x; median y per x; smooth
   spline `y(x)`; compute arc length and local thickness (distance transform
   of the band at the centerline, or perpendicular mask extent).
5. **Seams/colors:** sample the image along the centerline (small normal
   average). Classify `B/O/G/W/?`; smooth the 1-D label sequence (remove runs
   <3 px; merge `?` into neighbours sensibly). Gold runs = seams; interior
   gold-run centers = brick boundaries; end gold runs = caps. Each interval
   between seams is one brick; its type = majority B or O.
6. **Per-brick annular fit:** for each interval, collect the band pixels
   between consecutive seam centers (in x / arc-length). Fit
   `(cx, cy, r_in, r_out, theta_start, theta_end)`:
   - initialize center/radius by circle fit to the centerline points in the
     interval, `r_in/r_out` from the distance transform / radial extents;
   - refine with `scipy.optimize.minimize` (Powell/Nelder–Mead) maximizing
     IoU between the rasterized sector and the interval's mask region;
     derive or optimize the two angles (sector < π);
   - normalize to `theta_end_abs > theta_start` (add 2π if needed).
   The fit is degenerate for near-straight bricks (huge radius); that's fine,
   but clamp to sane bounds and prefer a stable local fit. Adjacent sectors
   should meet at seam centers (shared x boundaries), even if their fitted
   centers differ.
7. **Output:**
   - `level_segment/ribbon_waves_geometry.json` (canonical, ordered per
     ribbon; includes source hashes, image size, circle/brick lists, colors,
     per-ribbon ids and seam positions).
   - `level_segment/ribbon_waves_render.png` (rasterized uniform-color
     geometry on black/white).
   - `level_segment/ribbon_waves_diff.png` (mask vs render diff).
   - optional `level_segment/ribbon_waves_mask_fixed.png` if a manifest
     correction is actually needed (currently none expected).
8. **Acceptance:**
   - circle centers within 1 px of the mask components; 53 circles.
   - all 5 ribbons fully covered; each brick has a valid sector.
   - rasterized silhouette vs `peg_mask.png`: overall IoU ≥ 0.97 (target
     0.98+); report precision/recall and worst per-ribbon IoU.
   - a color preview (not just silhouette) that visually matches the
     screenshot's blue/orange pattern. Include a 1:1 overlay at the original
     resolution and a zoomed crop if useful.
   - Re-runnable from scratch with one command; no network.

## 5. Lua level (subagent B, depends on A)

1. Implement `level_segment/generate_ribbon_waves_lua.py` (or a mode of the
   extractor) that reads the geometry JSON and writes
   `../peggle_evolved/src/levels/ribbon_waves.lua`.
2. Compute the engine's color pool sequence for a chosen `level_seed`
   (e.g. `20261021`) and the desired counts using a tiny LÖVE/LuaJIT script
   that calls `PegColors.init` with dummy pegs (or run the game once). Then
   order the pegs so `pool[i]` matches each peg's desired type. Keep a
   human-ordered description in the geometry JSON; only the emitted Lua array
   is permuted.
3. Emit a clear header: generated from `level.png` / `peg_mask.png`, the
   generator path, source hash, coordinate system, and that the peg order is
   color-assignment order.
4. Optionally add line metadata per ribbon:
   - only if `Lines.validate` + exporter line checks accept non-contiguous
     groups after permutation; otherwise omit metadata and accept that the
     `slide` style is not awarded.
   - If omitted, still use zero-gap annular sectors; collision/slide physics
     do not need metadata.
5. Verify in the dev tree:
   - `luajit tools/check_level.lua` / `tools/dump_level.lua` loads with no
     discards/warnings; peg count and type counts correct.
   - Run the game headless via `tools/run_headless.sh` (display exists:
     `DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-1`) and capture a screenshot of
     the loaded level; compare visually to `level.png`.
   - Export:
     `julia_clone/tools/export_level.lua --reference ../peggle_evolved
     --level ribbon_waves --out .../ribbon_waves.v1.json --check
     --revision ... --tree ... --config-sha256 ...`
     with provenance from `git -C ../peggle_evolved rev-parse HEAD` and
     `src/config.lua` hash.
   - Export a dev config artifact (`tools/export_config.lua`) for the fixture.
6. Acceptance: level loads, 53 circles + all bricks present, no boundary
   discards, exported artifact types exactly match the screenshot colors,
   rendered artifact silhouette passes the mask checker.

## 6. Julia harness fixture (subagent C, depends on B)

Create `julia_clone/fixtures/ribbon_waves/`:

```
artifact/ribbon_waves.v1.json      # exported from ../peggle_evolved
config.dev.v1.json                 # exported dev config
source/ribbon_waves_geometry.json  # copy of A's geometry (provenance)
reference/peg_mask.png             # copy of the reference mask (20 KB)
catalog.lua                        # 2-3 shot fixtures (center, left wall, a ribbon hit)
workloads.lua                      # optional benchmark workload
expected/<fixture>.json            # captured Lua records
traces/<fixture>.jsonl             # captured Lua traces (snapshot-free)
README.md                          # corpus description, capture/compare commands
```

- Model `scripts/capture_ribbon_waves.sh` on
  `scripts/capture_m3_mustache.sh`: resolve `../peggle_evolved`, re-export
  artifact/config with `--check`, run the LÖVE harness with `--catalog`,
  `--fixtures-dir`, `--fixtures-traces`, `--reference-dir`,
  `--artifact-dir`, provenance args; add `--check` mode.
- **Mask checker:** `julia_clone/scripts/check_ribbon_waves_mask.py` loads the
  artifact JSON, rasterizes circles and annular sectors (filled polygon:
  outer arc + reversed inner arc; rectangles if any) at 1545x1289, compares to
  `fixtures/ribbon_waves/reference/peg_mask.png`, prints IoU/precision/recall
  and writes a diff PNG. Must pass at the same threshold as A. This validates
  the **exported artifact**, i.e. exactly what the game and Julia consume.
- **Julia tests:** add `julia/PeggleSim/test/test_ribbon_waves.jl` (and include
  it in `runtests.jl`):
  - artifact loads; 53 circles; expected annular count; contiguous ids;
    type_counts sum == peg count; all pegs in bounds; shapes valid.
  - golden trace replay for at least one captured shot; compare with the
    same M3 trace-parity utilities (bit-exact where the M3 control is
    bit-exact). If capture proves flaky, at minimum a deterministic shot via
    `bin/shot_bench.jl` with a checked-in expected JSON.
- Do not touch `interchange/` or `test_level.jl`'s static list.
- Acceptance: `make julia-test` passes including the new test; mask checker
  passes on the artifact; `scripts/capture_ribbon_waves.sh --check` passes.

## 7. Docs / integration (subagent D or orchestrator)

- `level_segment/README.md`: what was extracted, how to rerun, tool
  requirements, output files, known mask quirks (none currently).
- `julia_clone/wiki/context/ribbon-waves.md`: fixture description, commands,
  provenance, what is validated, link to mask checker.
- `peggle_evolved/temp/ribbon_waves-report.md` (repo convention: ephemeral
  reports in `temp/`): how the level was generated, level stats, screenshot.
- Optionally a `julia_clone/wiki/devlog/<date>.md` entry.
- Final cross-check: `git status` in all three repos; only intended files.
  Do not commit unless asked.

## 8. Delegation pipeline

1. **A — extraction** (can start immediately; owns `level_segment/` and
   `julia_clone/tmp/ribbon_waves/`). Deliver geometry JSON + render/diff +
   IoU report.
2. **C-prep — mask checker/fixture scaffolding** (can start immediately; owns
   `julia_clone/scripts/check_ribbon_waves_mask.py`, fixture dirs, README).
   Test the rasterizer on the mustache artifact first.
3. **B — Lua level** (starts when A delivers; owns
   `../peggle_evolved/src/levels/ribbon_waves.lua`, generator in
   `level_segment/`, dev-tree verification). Produces artifact via exporter.
4. **C-finish — capture + Julia tests** (starts when B delivers artifact).
5. **D — independent verification** (after B/C): re-run mask checker from
   clean state, load level in game, replay traces, review docs. Report
   failures with exact paths/commands.

Coordinate via `send_message`; each agent reports the files it wrote and the
commands it ran. The orchestrator inspects intermediate outputs before moving
to the next stage and keeps the schema/format consistent.

## 9. Risks / open questions

- **Brick seam detection near ribbon ends** (steep, short gold runs): fall back
  to equal arc-length splitting between reliable seams, then refine fits
  against the mask. Validate visually.
- **Color assignment order**: the ordering trick is exact only if the pool
  sequence is reproduced with the same LÖVE RNG and counts. Verify by
  re-exporting and checking every peg type against the desired list.
- **Purple semantics**: authored purple vs promoted purple (see §2). Decide
  before final capture; authored purple is the current default.
- **Game feel at native scale**: ball r=6 vs peg r=22. Mask fidelity is
  prioritized; if the user cares about play balance, discuss scaling later.
- **Line metadata + slide style**: optional; do not let it block the level.
- **Filesystem policy**: current session allows writes outside the workspace;
  a future session may not. If writes to `../peggle_evolved` or
  `../level_segment` are denied, the work can be staged in
  `julia_clone/tmp/ribbon_waves/` and copied in one batch.
- **Do not modify** `julia_clone/reference/`, `julia_clone/interchange/`,
  `julia_clone/interchange/files.sha256`, or the pinned test lists.

## 10. Quick command reference

```bash
# segmentation env
../level_segment/.venv/bin/python ...

# game load / screenshot
cd ../peggle_evolved && tools/run_headless.sh love . -- --level ribbon_waves ...
luajit tools/check_level.lua src/levels/ribbon_waves.lua   # verify exact usage

# export artifact (from julia_clone)
luajit tools/export_level.lua --reference ../peggle_evolved --level ribbon_waves \
  --out fixtures/ribbon_waves/artifact/ribbon_waves.v1.json --check \
  --revision "$(git -C ../peggle_evolved rev-parse HEAD)" \
  --tree "$(git -C ../peggle_evolved rev-parse HEAD^{tree})" \
  --config-sha256 "$(sha256sum ../peggle_evolved/src/config.lua | cut -d' ' -f1)"

# mask check
python3 scripts/check_ribbon_waves_mask.py

# Julia harness
make julia-test
scripts/capture_ribbon_waves.sh --check
```

## 11. Execution outcome (2026-10-21)

All stages (A extraction → B Lua level → C fixture/tests) completed and
independently re-verified. Acceptance:

| Gate | Result |
| --- | --- |
| Artifact silhouette vs `peg_mask.png` | **IoU 0.971917** (P 0.986112, R 0.985405), exit 0 at 0.97 |
| Extraction geometry (pre-inset) | IoU 0.972259; one-command rerun byte-identical |
| Lua `check_level` | **PASS**, 99 pegs, 0 boundary discards, 0 errors, 0 warnings |
| Julia full suite | **6,404/6,404** (`test_ribbon_waves.jl`: 787) |
| Trace parity | 3 shots, completion/result fields exact, trace bytes byte-identical |
| `capture_ribbon_waves.sh --check` | exit 0, artifacts byte-identical, 3 records verified |
| Pinned reference / interchange | untouched (`make verify`: 133 files OK) |

### Plan corrections (the plan's §2/§3/§4 were wrong on three points)

1. **Purple cannot be authored.** `Engine:setupLevel` computes
   `type_counts.blue = #pegs - red - green` and `PegColors.init` asserts the
   shuffled pool size equals the peg count, so `purple = 1` crashes with
   "pool size (N+1) does not match peg count (N)". The level authors the
   purple peg as blue and places it at the head of the turn-1 purple queue
   (blue-slot rank 48, artifact id 68); `resetTurn` promotes it, so the game
   shows exactly one purple at (799.5, 1033.5) from the first turn. The
   artifact's `type_counts.purple` is 0 by necessity.
2. **World = mask pixel index + 0.5.** The mask is in pixel-index space; the
   checker samples cell centres. Without the half-pixel shift the 53 circles
   alone cost FP 1,961 + FN 1,378; with it, FP 424 / FN 0. All geometry is
   emitted in the corrected world convention.
3. **Bricks are fitted to the mask core**, not seam-centre-to-seam-centre.
   The mask leaves ~3,507 px of gold/slit gaps black; filling them caps IoU
   at 0.984, while fitting the cores reaches 0.972 with zero overlap
   (max penetration 0.004 px). A 0.0004 rad end inset keeps the tessellated
   polygons > 0.01 px apart so `LevelChecker` reports no near-contact
   warnings. No line metadata is emitted (the colour permutation scrambles
   line indices; `slide` is not awarded).

Also confirmed: the extracted counts differ from the plan's estimate —
53 circles are blue 39 / red 12 / green 1 / purple 1 (not 37/14), and the
ribbons have **46** bricks (33 blue + 13 red), not 20; 99 pegs total.

### Outputs

- `level_segment/`: `extract_ribbon_waves.py`, geometry/metrics JSON,
  render/diff/preview/zoom, `EXTRACTION.md`, `README.md`,
  `generate_ribbon_waves_lua.py`.
- `../peggle_evolved/src/levels/ribbon_waves.lua` (99 pegs, seed 20261021,
  `check_level` clean); screenshot `../peggle_evolved/temp/ribbon_waves_level.png`;
  report `../peggle_evolved/temp/ribbon_waves-report.md`.
- `julia_clone/fixtures/ribbon_waves/`: artifact, dev config, geometry copy,
  reference mask, catalog (3 shots), expected records, traces, README,
  mask diff/metrics.
- `julia_clone/scripts/check_ribbon_waves_mask.py`,
  `julia_clone/scripts/capture_ribbon_waves.sh`,
  `julia_clone/julia/PeggleSim/test/test_ribbon_waves.jl`,
  `julia_clone/wiki/context/ribbon-waves.md`.

The pinned `reference/` and the frozen `interchange/` were not modified; all
new material is an untracked working-tree file.
