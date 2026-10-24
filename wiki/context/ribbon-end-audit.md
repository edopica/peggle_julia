# Ribbon-end design audit — 2026-10-24

**Resolved later on 2026-10-24:** v5 replaces the outer arms with fitted exact
arcs. All ten ends now pass, and the user confirmed the Lua level looks right.
See [the current implementation](ribbon-waves.md). The findings below describe
the rejected v4 geometry; running the audit now measures the corrected v5.

The current v4 repair is still wrong: **all ten ends flatten toward the tip**.
This supersedes the success claims about terminal shape in `ribbon-waves.md`.
The reference image is `../../../level_segment/level.png`; its ribbon arms
turn upward more steeply toward their exposed ends. The requested quantity
is steepness (absolute slope), not increasing curvature magnitude.

## Reproduction and evidence

Run `python3 scripts/audit_ribbon_slopes.py --check` from the repository root.
It exits 1 for the current geometry, writes sampled measurements to
`tmp/ribbon-slope-audit/metrics.json`, and a standalone plot to
`tmp/ribbon-slope-audit/slopes.svg`. The legacy generator's
`--check-geometry` still passes the same geometry.

| Ribbon | Left steepness: body → tip | Right steepness: body → tip |
| --- | --- | --- |
| wave_1 | 0.731 → 0.345 | 0.731 → 0.330 |
| wave_2 | 0.624 → 0.620 | 0.723 → 0.304 |
| wave_3 | 0.886 → 0.799 | 0.894 → 0.783 |
| wave_4 | 0.988 → 0.847 | 0.976 → 0.848 |
| wave_5 | 0.746 → 0.372 | 0.710 → 0.375 |

These are derivatives of the generated path, measured between the interior
knot and the tip of each terminal cubic, not measurements of screenshot
pixels or a newly captured game render. The audit samples 201 points per
terminal; it is a diagnostic, not a formal proof for arbitrary cubics.

## Why repeated repairs failed

1. `../level_segment/extract_ribbon_waves.py` extracts vertical silhouette
   midpoints. Near an angled end face a vertical slice intersects the end
   face as well as the sides, so its midpoint is not the centerline. Smoothing
   those samples preserves the bias. The extraction's curvature gate uses
   absolute curvature to constrain radius, without requiring the right bend.
2. `tools/generate_ribbon_waves_level.py::_repair_terminal_cubics` preserves
   both biased endpoints and the interior tangent. Those constraints determine
   a unique circular arc. Its signed curvature is `2 cross(tangent,chord) /
   |chord|²`; the current data gives the wrong sign at every end. Changing
   tessellation tolerance cannot fix that input geometry.
3. The repair checks constant, single-signed curvature inside only the last
   cubic. Either sign passes. It does not check whether the end steepens or
   whether curvature reverses across the neighboring knot. Thus it can move
   the reversal to a join and still declare success.
4. The generator hardcodes the fitted model and exactly ten cubics per ribbon.
   This is a restriction of this reconstruction script, not of the engine.

Screen y increases downward. Traversing these ribbons left to right, the
desired terminal curvature is negative on **both** ends. On the left, slope
is positive and gets larger going outward; on the right, slope is negative
and its magnitude gets larger going outward. A generic “slope increases”
assertion without this coordinate convention would be ambiguous.

## Representation assessment and changes needed

The engine already has sufficient primitives. `src/systems/path.lua` accepts
arc and cubic segments; `src/systems/lines.lua::emit_biarc_annular` supports
mixed arc/cubic paths and emits explicit arcs directly. An ordinary annular
sector provides the requested flat radial face. There is no need for a new
cap entity or collision shape.

The missing capability is an authoring contract:

- Separate observed silhouette samples from editable design geometry. Keep
  the original extraction for provenance, but allow endpoint positions and
  tangents to be refitted; do not freeze biased endpoints as ground truth.
- Author terminal regions with a required bend direction and increasing
  outward steepness, spanning the transition from the body through the tip.
  Fit to the side boundaries and actual end face, excluding contaminated
  vertical-midpoint samples. Permit more than one old cubic to change.
- Allow explicit arcs alongside cubics in the generator. Use the engine's
  exact arc representation when circular ends are intended. Ordinary cubic
  Béziers only approximate circles; the current comments calling the
  conversion exact are incorrect. Matching normalized tangent directions
  establishes G1 continuity, not necessarily parametric C1 continuity.
- Validate the required sign and outward steepness over the whole terminal
  region, including joins, then validate the emitted annular geometry.
  `Lines.generate` checks positional error, radius and contact continuity;
  those checks do not impose a designer's curvature-sign requirement.
- Review a reference overlay and terminal crops alongside slope plots.
  Whole-level silhouette IoU and playable trace parity cannot certify the
  requested end shape.

The audit adds the missing diagnostic without regenerating the level or
replacing existing fixtures. A corrected reconstruction and its gameplay
recapture remain separate implementation work; this audit does not claim
that the visible level has been fixed.
