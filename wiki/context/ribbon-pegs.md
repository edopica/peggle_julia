# Ribbon pegs (dev-tree `shape = "ribbon"`)

Ported on 2026-11-11 from peggle_evolved `bbd8622` ("Separate ribbon peg
segmentation from collision geometry"). The Lua change is **after the pin**
(`d17f6e7`). The pinned reference, M1 interchange and M1–M4 corpora are
unchanged; ribbons occur only in dev-tree corpora (`fixtures/ribbon_waves`,
`fixtures/imported_levels`).

## What a ribbon is

A ribbon is **one gameplay peg**: it is scored, colored, counted in
`type_counts`, carries line metadata, and is removed as one unit. Its collision
geometry is an ordered chain of annular **pieces** (`peg.parts`). Lua authors
it with `Lines.generate{ peg = { kind = "ribbon" }, segmentation = ... }`. The
path is cut at segmentation boundaries (`count`, `target_length` or explicit
`boundaries`). Each section is fitted with exact arcs or biarcs, so the
gameplay seams are independent of the internal arc joins.

Collision rules (`src/entities/ribbon.lua`, `src/systems/physics.lua`):

- Physics never sees the owner. `Ribbon.collision_pieces` replaces each owner
  in `annular_pegs` with its pieces, in place, at the start of every
  `Physics.update`. Tie-break `peg_index` is therefore the index in the
  **expanded** list.
- Pieces suppress their internal caps and corners. With `path_direction`
  `d` and piece index `i` of `n`:
  `no_cap_start = d==1 and i>1 or d==-1 and i<n`,
  `no_cap_end = d==1 and i<n or d==-1 and i>1`. Only the path entry and exit
  caps collide. With mixed directions (biarc inflections) both exposed caps
  can be sector-start caps.
- `register_hit`, `grazed_add` and depenetration report `ribbon_owner`, so
  events carry the owner's `id`, `type`, `line`, `peg_shape = "ribbon"`,
  owner `x/y/angle` and no `peg_theta`.
- Piece velocity is the secant `(part - step_start_transform) / dt`, with the
  step-start transform rebuilt from the owner. For a static owner this is
  `part.x - (owner.x + (part.x - owner.x))`, which is **not always zero**:
  a few pieces per board get an ulp-scale phantom velocity (~1e-12 px/s).
  Measured: 3/138 pieces on ribbon_waves, 6/142 on b1, 7/178 on g1, 1/68 on
  m1 and 20/84 on m2. The port reproduces this verbatim; full-grid parity
  depends on it.

## Interchange

`tools/export_level.lua` normalizes ribbons as `Engine:setupLevel` does
(`p.base_x and (p.radius or p.shape == "ribbon")`). It exports the owner
`x/y`, `path_start/path_end` and every piece
`{x, y, r_in, r_out, theta_start, theta_end_abs, segments, path_direction}`.
The round-trip check covers every piece field. Cap flags and local offsets
are derived by consumers, not stored. Schemas: `ribbonPeg`/`ribbonPart` in
`schemas/level.v1.schema.json`; `"ribbon"` was added to the checkpoint peg
shape enum. The SVG previewer draws one seamless outline per ribbon, and
`scripts/check_ribbon_waves_mask.py` rasterizes the pieces.

## Julia implementation

- `level.jl`: `RibbonPart` (piece center, `local_x/y = part - owner`, sector,
  direction, cap flags) and `RibbonShape` (parts, path span, Lua
  `Ribbon.new` bounding radius). `Peg.shape` is now `PegShapeUnion`.
- `physics.jl`: `ribbon_collision_pieces!` is the per-step expansion. It
  uses pooled piece `Peg`s in `PhysicsContext` (zero steady-state
  allocation). Pieces carry `ribbon_owner`, `no_cap_start/end` and an inline
  `piece_shape`. Rewriting the union `shape` field would box the sector on
  every step, so physics reads it through `annular_shape`. `gameplay_peg` maps
  pieces to owners in `register_hit!`, `grazed_add!` and depenetration.
- Pieces keep their **authored** centers. Lua recomputes them only in
  `Ribbon.set_transform`, which a static level reaches only through
  `applyReplayState`. The harness and the live game never call it, and Julia
  checkpoint restore stays owner-only.
- `prepare_checkpoint` records `has_ribbons`. Ribbon boards never take the
  frozen `static_geometry` path, because piece records are refreshed from the
  expansion every step.
- Checkpoint encode/decode, snapshots (`base_angle`, `angle`, `parts`) and
  `surface_separation` handle ribbons.

## Peg colors

The imported screenshot levels (`b1`, `g1`, `m1`, `m2`, and `b2`, which has
no ribbons) come from `../level_segment/levels/*/generate_*_lua.py`. Those
generators simulate the `PegColors.init` shuffle for the chosen `level_seed`
(`compute_color_plan`/`color_order`) and reorder the peg array, so the seeded
shuffle lands the screenshot colors on their source pegs. Under the artifact
`level_seed`, 93/94 (b1), 88/89 (b2), 95/96 (g1), 89/90 (m1) and 114/115 (m2)
pegs get their authored type; the remaining one is the first purple. The
authored `type` field itself is never read by either engine.

Colors are not meant to be a fixed property of a level. Julia campaigns
therefore seed each match's color shuffle with a per-match seed by default
(see [bot campaign](bot-campaign.md)). Parity fixtures and sweeps keep the
artifact `level_seed`, because that is what the Lua engine uses and what the
traces were captured with. `build_sim_state`/`build_checkpoint` accept
`color_seed` for other callers.

## Evidence (2026-11-11)

- `fixtures/ribbon_waves`: recaptured from the dev tree (99 gameplay pegs:
  53 circles + 46 ribbons / 138 pieces). 3/3 traces byte-identical.
- `fixtures/imported_levels`: 25 shots (5 aims × 5 levels), byte-identical
  traces and records. They include slide awards on ribbons (g1, m2), spawns
  and bucket catches.
- Full-grid Lua-vs-Julia sweeps over all 1,801 aims on ribbon_waves, b1, b2,
  g1, m1 and m2 found **0 mismatching candidates** (10,806 total) on every
  shared field. Reports: `results/ribbon_port/sweep-compare-*.json`.
- `make julia-test` 43,985/43,985; `make julia-scripts-test` 219/219;
  `make check` OK. The M4 strict-zero allocation gate passes on all five probes,
  and ribbon boards also step without src allocations.
