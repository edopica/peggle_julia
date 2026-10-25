# Handoff — ribbon_waves ribbon-end geometry (v4 is wrong)

**Status:** the current working tree contains a wrong fix (v4 semicircular end
caps). Do not refine it. The correct terminal shape is the **natural flat
radial side of the last annular sector**, with **sharp corners**, emitted as a
normal peg in the line. The real defect is a **curvature sign reversal
(inflection) in the ribbon path near its ends**, not the shape of the end face.

This document records:

1. what the user asked for;
2. why v3 (flat end) still looked inflected;
3. what v4 did and why it is geometrically wrong;
4. the evidence for the real root cause;
5. the recommended repair and validation plan.

---

## 1. What the user wants

The user's exact requirements, after rejecting both v3 and v4:

- The ribbon is a curve divided into **annular sectors**.
- Each sector has **two arc sides** (inner/outer; these are the sliding
  surfaces) and **two flat radial sides** (the seams).
- The ribbon's terminal face is the **flat radial side of the last sector**,
  spanning the band's thickness. Nothing is added beyond it.
- **No corner rounding. Sharp edges only.**
- The terminal side must be the **natural radial side of the last sector**
  (radial to that sector's arc centre).
- The curve near the end must not inflect: the second derivative must not
  change sign. In the reference, the slope keeps increasing as you approach
  the edge.
- The last sector is **just another peg in the line** (line metadata, count,
  slide continuity), exactly like `squiggly_circle`. It is not a separate
  cap peg.

### Correct end (schematic)

```
        outer arc (slide surface)
      .-------------------.
     /                     \
    |   flat radial end     |   <-- last sector's radial side
     \                     /       sharp corners, no extra geometry
      `-------------------'
        inner arc (slide surface)
```

### Wrong end produced by v4

```
        .-''''''''-.
      /              \   <-- visible semicircular nose
     |     body       |
      \              /
        `----------'
```

A half-disc is **not** an annular sector: it has one arc and one diameter
(two collinear radial edges), not two arcs and two distinct flat radial
sides. Its visible end is the arc, so the ribbon ends round instead of flat.

---

## 2. What v3 did, and why it still looked wrong

v3 (the committed baseline) was conceptually right about the end face: each
ribbon was one `Lines.generate` line, and the last generated annular sector
ended in its natural flat radial side. No cap geometry was added.

But the **path itself has an inflection near its ends**. The last few
annular sectors follow that S-shaped path, so the ribbon's outer edge bends
one way and then the other. The user sees the curvature sign change in the
last few pegs and describes it as an "inflection point."

The flat end face was therefore **not the bug**. The bug is the centerline
fed to `Lines.generate`. v3 inherited it from
`ribbons[].path` in `fixtures/ribbon_waves/source/ribbon_waves_geometry.json`.

Qualitative comparison (not a like-for-like overlay: v3 and v4 use different
trims/tessellations, so the faces sit at different points):

![v3 flat end in cyan vs v4 semicircle in red](ribbon_caps/v3_v4_cap54.png)

The cyan v3 outline is a flat radial cut, but it sits slightly short of the
reference end and its sharp corners meet the arcs abruptly. The red v4
outline is a semicircular nose: its leftmost point is close to the reference
end, but the profile is round instead of flat. Neither is the target: a flat
radial face at the reference end, sharp corners, no cap.

Measured for the `wave_1` start (native px, from the committed artifacts and
`reference/peg_mask.png`):

- reference mask: leftmost boundary `x ~ 939` at `y ~ 401`; the flat face
  spans roughly `x ~ 940..946` over `y ~ 398..416`;
- v3 terminal flat face: `(944.6, 432.3)` to `(952.4, 388.0)` — flat, but
  ~5 px inside the reference and angled with the inflected path;
- v4 cap: centre `(965.9, 416.0)`, radius `22.5`, leftmost `x ~ 943.4` —
  close to the reference tip, but the visible profile is a semicircle.

---

## 3. What v4 did, and why it is wrong

v4 changed
[`tools/generate_ribbon_waves_level.py`](../tools/generate_ribbon_waves_level.py):

- trims each path end by `thickness/2 - 4` native px, i.e.
  `thickness/2 - 4*scale` world px (`scale = 10/22`);
- adds **10 separate 180-degree `Peg.new_annular` caps**:
  `r_in = 0`, `r_out = thickness/2`, `segments = 16`;
- shifts each cap `0.02` world px outward to clear `LevelChecker`'s
  static-overlap warning band;
- emits the caps as **line-less** pegs (because `Lines.validate` requires
  `0 < r_in < r_out` for a line-tagged annular peg).

Result: 171 pegs = 53 circles + 108 body annular + 10 caps; body line counts
`20/20/24/24/20`.

### Why this is wrong

1. **Wrong terminal shape.** The cap is a half-disc. Its flat diameter is at
   the body seam; the visible end is the semicircular arc. The user explicitly
   wants a flat radial face, not a round nose.
2. **Violates the sector model.** A ribbon sector has two arcs and two flat
   sides. The cap has one arc and one diameter (two collinear radial edges),
   so it is not a sector.
3. **Not part of the line.** The caps are line-less. The user wants the last
   sector to be a normal line peg, carrying `line` metadata and contributing
   to `slide`. v4 introduces a separate peg class at the ribbon ends.
4. **Adds a seam and a gap.** The 0.02 px outward shift leaves a physical
   discontinuity between body and cap. The cap is also coloured independently
   by `PegColors.init`, so it can render as a separate blob at the end.
5. **Does not fix the inflection.** The path S starts inside the terminal
   cubic, 10–25 px from the tip depending on ribbon/end. The cap only replaces
   the last ~19 world px (the `thickness/2 - 4` native-px body trim plus the
   `thickness/2` cap radius), so the S in the remaining body is still there.
   The cap's own tight arc does not remove it and adds a second feature at the
   tip.
6. **The mask IoU improvement was misleading.** IoU went from `0.944666` to
   `0.946300`, but the metric is dominated by the ribbon-body area and is
   insensitive to a ~10 px end-shape change. It does not validate the cap.
7. **It caused avoidable corpus churn.** The extra pegs changed tessellation
   and peg IDs, so all three traces were recaptured and the `ribbon` aim had
   to be retuned from 120 to 17 to restore `slide`. That churn is not needed
   for the real fix.

### Bottom line

v4 is an overcorrection: it replaced the correct *kind* of terminal face
(flat radial side) with an invalid *shape* (half-disc) because the original
complaint was misread as an end-face problem. The end face was already the
right family; the curve leading to it was wrong.

---

## 4. Root-cause evidence: the path inflects near its ends

The source path is a `cubic-hermite-lsq-spline-v1` fit with 10 cubic
segments per ribbon. Sampling the first and last cubic and computing the
curvature sign (cross product of first and second derivatives) shows sign
flips inside those cubics:

| ribbon | end | sign flip at | k(t=0) | k(t=1) |
| --- | --- | ---: | ---: | ---: |
| `wave_1` | end | `t ~ 0.10` | `-0.00157` | `+0.03346` |
| `wave_1` | start | none | — | — |
| `wave_2` | start | `t ~ 0.70` | `+0.01163` | `-0.00454` |
| `wave_2` | end | `t ~ 0.10` | `-0.00202` | `+0.03615` |
| `wave_3` | start | `t ~ 0.75` | `+0.02126` | `-0.00466` |
| `wave_3` | end | `t ~ 0.25` | `-0.00146` | `+0.00767` |
| `wave_4` | start | `t ~ 0.80` | `+0.01268` | `-0.00225` |
| `wave_4` | end | `t ~ 0.30` | `-0.00235` | `+0.01242` |
| `wave_5` | start/end | none | — | — |

For **end** cubics, `t=0` is the interior side and `t=1` is the tip. For
**start** cubics, `t=0` is the tip and `t=1` is the interior side. The
sign convention also depends on traversal direction; the flip is the point.

The sign convention differs by traversal direction, but the important fact
is the **flip**: each affected terminal cubic first curves with the opposite
sign, then reverses to the sign that continues into the tip. That is an
S-shape / inflection. The user's "second derivative changes sign" matches
this exactly.

The flip is inside the first/last cubic, not at the terminal face. It can sit
10–25 px from the tip (up to ~70% of a 35 px cubic on the start side; the
end-side flips in the table range from ~10% to ~30% of the cubic). A
semicircular cap that replaces only the last ~19 world px cannot remove an S
that starts that far back.

Likely causes to investigate:

- the LSQ cubic Hermite end conditions / tangent estimation at the first and
  last knots;
- the 8 px `trim_px` leaving a short terminal cubic whose Hermite tangent is
  estimated from an asymmetric neighborhood;
- the centreline extraction including part of the rounded reference end,
  pulling the fit sideways near the boundary;
- ordinary cubic overshoot on a high-curvature terminal interval.

The user's reading of the reference is a monotone approach: curvature of one
sign, with the slope increasing toward the edge. The generated path does not
do that. (A numeric curvature extraction from the reference mask would make
this a hard test rather than a visual criterion.)

### How to reproduce the diagnostic

Load `fixtures/ribbon_waves/source/ribbon_waves_geometry.json`, take
`ribbons[].path.segments[0]` and `segments[-1]`, sample t = 0..1, and
compute:

```python
d1 = 3*(1-t)**2*(c1-p0) + 6*(1-t)*t*(c2-c1) + 3*t**2*(p1-c2)
d2 = 6*(1-t)*(c2-2*c1+p0) + 6*t*(p1-2*c2+c1)
cross = d1.x*d2.y - d1.y*d2.x      # curvature sign
```

Print the sign sequence; the flips above should reproduce. Do the same on
the **generated outer edge** after a candidate fix, because
`Lines.generate` arc fitting can introduce an additional small reversal.

---

## 5. Correct fix

### Principle

Fix the **centerline near the ends** so curvature does not change sign; then
let `Lines.generate` emit the last sector normally. Its natural radial side
is the terminal face. Add nothing beyond it, round nothing, and keep it in
the line.

### Preferred approach

Repair the first and last cubic of each ribbon path before constructing the
`Path` fed to `Lines.generate`. Candidate methods, in order of preference:

1. **Shape-preserving fit / clamped end tangents.** Refit the centerline
   with a monotone-curvature or PCHIP-style method, or clamp the end tangent
   to the secant of the last few centreline samples and adjust the adjacent
   control point so the cubic cannot hook. This is the most principled fix if
   the extraction pipeline can be changed.
2. **Terminal arc/quadratic replacement.** Replace the last (and, where
   needed, first) cubic with a circular arc or quadratic that matches the
   interior position, tangent and curvature sign, and ends at the reference
   endpoint. Verify the curvature sign stays constant.
3. **Trim to monotone region + well-behaved extension.** Trim the path to a
   point where curvature is already monotone, then extend to the reference
   end with a segment whose curvature has the same sign (e.g. arc
   extrapolation). Do not simply shorten the ribbon if that leaves it short
   of the mask.
4. **Fix the extraction.** If the path fit itself is the culprit, fix
   `../level_segment/extract_ribbon_waves.py` and regenerate the pinned
   geometry. This changes the source hash and every fixture hash, but it fixes
   the root cause at the source and keeps the generator simple.

Do **not**:

- add separate cap pegs;
- use a 180-degree pie / semicircle;
- round the corners;
- add a line-less terminal peg;
- tune mask IoU as the primary oracle.

### Important constraint: path provenance

The source geometry is pinned and the capture script requires it to match
`../level_segment/ribbon_waves_geometry.json` byte-for-byte. If the repair is
done in the generator (options 1–3), the emitted level path will differ from
the pinned `ribbons[].path`; document that explicitly and add a test for the
repaired path's monotone curvature. If the repair is done in the extraction
(option 4), update the source copy and all hashes/provenance.

### What "done" looks like

- The last few sectors' centreline/outer edge has **no curvature sign
  change** near either ribbon end.
- The terminal face is the **flat radial side** of the last sector, with
  sharp corners.
- The terminal sector carries `line` metadata and is counted in the line;
  `slide` still works.
- No extra pegs beyond the normal line tessellation.
- A zoomed render vs `reference/peg_mask.png` shows a flat end, not a
  semicircle.
- `check_level` passes with 0 ERROR / 0 WARN.
- The corpus is recaptured once, after the geometry is final.

---

## 6. Current tree state (v4, wrong)

The working tree currently contains the v4 experiment. Do not build on it.

Modified tracked files:

- `tools/generate_ribbon_waves_level.py` — cap trim + 10 cap pegs.
- `fixtures/ribbon_waves/artifact/ribbon_waves.v1.json` — 171 pegs.
- `fixtures/ribbon_waves/catalog.lua` — `ribbon` aim 17; notes.
- `fixtures/ribbon_waves/expected/*.json`, `traces/*.jsonl` — recaptured v4.
- `fixtures/ribbon_waves/mask_diff.png`, `mask_diff_raw.png`,
  `mask_metrics.json` — v4 evidence.
- `fixtures/ribbon_waves/README.md`, `source/README.md`,
  `workloads.lua` — v4 text/counts.
- `fixtures/ribbon_waves/config.dev.v1.json` — **independent** config change
  from the dev tree (`launch_speed 600`, `ball_ball_restitution 0.6`); it is
  not part of the cap fix.
- `julia/PeggleSim/test/test_ribbon_waves.jl` — v4 counts/caps.
- `scripts/check_ribbon_waves_mask.py` — v4 report text.
- `wiki/context/ribbon-waves.md`, `wiki/devlog/2026-10-22.md` — v4 docs.

Generated/untracked:

- `../peggle_evolved/src/levels/ribbon_waves.lua` — v4 level with caps.
  Regenerate after reverting the generator.

The source geometry is unchanged:
`fixtures/ribbon_waves/source/ribbon_waves_geometry.json`
(sha256 `bc52e4282b9ee0c42fc20049f40ba18f6b3f52718a9b04616a786941a7e247ea`).
The path inflection is in that file; fixing it in the generator leaves the
file pinned, fixing it in extraction changes the hash.

### Reverting

The v3 implementation is available from git HEAD. Save the v4 diff first if
it is useful as a negative example:

```bash
git diff > /tmp/ribbon_waves_v4_wrong.patch
git checkout -- tools/generate_ribbon_waves_level.py \
  fixtures/ribbon_waves julia/PeggleSim/test/test_ribbon_waves.jl \
  scripts/check_ribbon_waves_mask.py \
  wiki/context/ribbon-waves.md wiki/devlog/2026-10-22.md
```

Caveat: `fixtures/ribbon_waves/config.dev.v1.json` also reverts to the old
dev config. If the dev tree is still at `de49dab` (`launch_speed 600`,
`ball_ball_restitution 0.6`), re-capture with the current config; the traces
will differ from both old v3 and v4 for reasons unrelated to the ribbon
geometry. Decide whether to keep the current config artifact before
reverting it.

---

## 7. Validation plan

1. **Path curvature check (new test).** For each ribbon, sample the first and
   last cubic; assert no curvature sign change and that the curvature
   magnitude approaches the tip without reversing. This is the regression
   test for the actual bug.
2. **Generated outer edge check.** Sample the union boundary (or the
   artifact's outer arc polyline) near both ends; assert the same.
3. **End-shape crop.** Render the artifact in native space and crop each end;
   compare with `reference/peg_mask.png`. The face must be flat with sharp
   corners. Store a small contact sheet as evidence.
4. **Level checks.** `check_level` 0 ERROR / 0 WARN. Expected counts if the
   v3 tessellation is restored: 167 pegs = 53 circles + 114 annular; line
   counts `20/20/26/28/20`. If the path repair changes the counts, document
   why.
5. **Corpus.** Recapture `expected/` and `traces/` once; run the focused
   Julia test and the full suite; run
   `scripts/capture_ribbon_waves.sh --check` for byte identity.
6. **Mask IoU.** Report it, but do not optimize it: it is a body-dominated
   metric and cannot distinguish a 10 px end shape. The dedicated end crop
   and curvature test are the oracles for this fix.

---

## 8. Files and commands

Key files:

- `tools/generate_ribbon_waves_level.py` — level generator (path → `Path` +
  `Lines.generate`).
- `fixtures/ribbon_waves/source/ribbon_waves_geometry.json` — pinned path
  input; contains the inflection.
- `../peggle_evolved/src/systems/lines.lua` — `Lines.generate` /
  `Lines.validate`.
- `../peggle_evolved/src/entities/peg.lua` — `Peg.new_annular`; polygon is
  outer arc forward + inner arc reversed, so the radial sides are flat.
- `fixtures/ribbon_waves/reference/peg_mask.png` — silhouette oracle.
- `scripts/check_ribbon_waves_mask.py` — rasterizer / mask report.

Useful commands:

```bash
python3 tools/generate_ribbon_waves_level.py --check
luajit ../peggle_evolved/tools/check_level.lua \
  ../peggle_evolved/src/levels/ribbon_waves.lua
python3 scripts/check_ribbon_waves_mask.py
scripts/capture_ribbon_waves.sh --check
julia --project=julia/PeggleSim -e \
  'using Test, JSON, PeggleSim; include("julia/PeggleSim/test/test_ribbon_waves.jl")'
make julia-test
```

Note: the old `../level_segment/ribbon_waves_overlay.png` is drawn from the
v2 `pieces` array by `extract_ribbon_waves.py`; it is not a render of the
generated level. Do not use it as the generated-level oracle. The artifact
render / `mask_diff.png` is authoritative.

---

## 9. Open decisions for the next agent

1. **Where to fix the path:** generator-side repair (keeps the pinned source,
   but the emitted path deviates from it) vs extraction-side fix (changes the
   pinned geometry and all hashes). The extraction-side fix is cleaner if
   `../level_segment` may change; otherwise generator-side.
2. **Terminal construction:** clamped-end cubic vs arc/quadratic replacement
   vs trim+extend. Whichever is used, the acceptance test is monotone
   curvature near both ends, not a particular mathematical form.
3. **Start vs end:** `wave_2`/`wave_3`/`wave_4` also show start-side
   flips, so fix both ends of every ribbon, not only the visually worst end.
4. **Counts:** the v3 counts are `20/20/26/28/20` (114). A path repair may
   change tessellation; prefer preserving the v3 counts if possible, but do
   not contort the path to hit them.
5. **Corpus aim:** if the geometry change alters traces, recapture and choose
   aims that still exercise the intended categories; do not retune just to
   preserve a historical style outcome.

---

## 10. One-paragraph summary for the user

The ribbons are chains of annular sectors, so their ends must be the flat
radial side of the last sector — sharp, flat, and part of the line. v3 had
that end shape, but its path curved the wrong way for the last few sectors,
so the ribbon looked inflected. v4 misread that as an end-face problem and
put a semicircular half-disc cap on each end, which is neither an annular
sector nor part of the line, and did not remove the path inflection. The fix
is to repair the first and last cubic of each ribbon path so curvature keeps
one sign all the way to the tip, then let `Lines.generate` end normally in
the last sector's flat radial side. No caps, no rounding, no extra pegs.
