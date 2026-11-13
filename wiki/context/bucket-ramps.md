# Ramp bucket, catch hold and one-ball multiball (dev-tree `10ee3a0`)

Ported on 2026-11-11 from peggle_evolved `10ee3a0` ("Reshape bucket with side
ramps, hold shot end after catch, fix multiball"). Like
[ribbon pegs](ribbon-pegs.md), the Lua change is **after the pin**
(`d17f6e7`). The pinned reference, the M1 interchange and the M1–M4 corpora
are unchanged. The new rules apply only when a config artifact exported from
`10ee3a0` (or later) is loaded. Today that means `campaigns/ribbon/` and,
since 2026-11-12, the real-level corpora `fixtures/{ribbon_waves,imported_levels}`.

## Lua semantics (10ee3a0)

- **Multiball** (`src/systems/powers.lua`): `Powers.activate` returns ONE spec,
  `{x = peg.x, y = peg.y - 10, vx = 150, vy = -200}`. It used to return two
  (±150).
- **Bucket shape** (`src/entities/bucket.lua`): convex pieces in bucket-local
  coordinates (x from the center, y down from the rim top). Per side, mirrored:
  - a flat rim `[hole/2, hole/2 + rim_w] x [0, rim_h]`;
  - a ramp triangle that starts at the rim's top-outer corner and drops to the
    level's lower border at `bucket_ramp_slope_deg` (clamped to [1, 89]; NaN
    falls back to 20), so `ramp_width = drop / tan(slope)`;
  - an inner block under the rim.

  A floor rectangle joins the two sides under the opening. Piece order is
  bodies (ramp L, ramp R, inner L, inner R), floor, then rims (L, R). It is the
  iteration and tie-break order. `drop = nonneg(bucket_height) +
  nonneg(bucket_margin)`, `top = vh - drop`, and
  `half_span = hole/2 + rim_w + ramp_w` drives the sinusoid amplitude.
  `make_piece` drops repeated vertices and degenerate pieces, so
  `bucket_rim_height = 0` leaves 5 pieces.
- **Collision** (`Bucket.resolve`): runs once per step after physics (engine
  phase 11), in the bucket's frame. The ball's step goes from
  `prev - bucket.prev_x` to `pos - bucket.x`. If the start position overlaps no
  piece, the ball is swept against offset edges and vertex circles and the
  earliest TOI wins. A hit whose center is outside the opening
  (`|cx| > hole/2`) is placed at contact plus `overlap_push_margin`, reflected
  with `1 + restitution`, separated, and reported as `bounced`. Otherwise, a
  downward ball (`vy > 0`) inside the catch zone (`|px| <= hole/2`,
  `py + r >= 0`, `py - r <= height`) is `caught`. Otherwise, a discrete push-out
  (up to 4 iterations against the deepest piece) gives `bounced` or nil.
- **Catch** (`src/engine/core.lua`): `caught` sets `b.bucket_caught`, emits
  `bucket_caught_ball` and calls `onBucketCatch`. The ball is **not**
  removed. A caught ball skips all further bucket and fever-bucket resolution.
  It is removed at fall-out (`y - r > vh + fall_out_margin`) with
  `last_removal_reason = "bucket_caught"` and no `ball_fell_out` event. That
  sets `catch_hold_until_step = max(existing, step + ceil(bucket_catch_hold /
  fixed_dt))`. Shot-end detection (phase 15) waits while
  `#balls == 0 and step < catch_hold_until_step`, and clears the hold when
  the shot ends. `resetTurn` clears it.
- **Snapshots** (`simulation_snapshot.lua`): the ball carries
  `bucket_caught = true` while caught. The bucket carries `rim_width,
  rim_height, ramp_width, ramp_height, height, floor` instead of `edge`. The
  engine carries `catch_hold_until_step` while it is set.
- **Config**: new keys `bucket_rim_width` (12), `bucket_rim_height` (4),
  `bucket_ramp_slope_deg` (30), `bucket_catch_hold` (1.5) and the render-only
  `bucket_rim_color`. `bucket_edge` was removed. Changed values:
  `bucket_hole` 105, `bucket_height` 10.4, `bucket_margin` 4.8,
  `launch_speed` 400, `wall_damping` 0.8. The Lua wiki text says the default
  slope is 20°, but the config value is 30.

## Rule selection (Julia)

`load_config` resolves the rules once into `SimConfig.rules::RuleSet`, based on
which bucket keys the artifact carries:

| Artifact carries | `rules` | Bucket | Catch | Green power |
| --- | --- | --- | --- | --- |
| `bucket_edge`, none of the 10ee3a0 keys | `RULES_CLASSIC` | three rectangles | instant removal | two balls |
| all four of `bucket_rim_width`, `bucket_rim_height`, `bucket_ramp_slope_deg`, `bucket_catch_hold`, no `bucket_edge` | `RULES_RAMP_BUCKET` | rims + ramps, swept | fall out, then hold | one ball |

Any other combination is rejected (`ArgumentError`). `bucket_rim_color` is
accepted as a presentation key and never stored. The pinned
`interchange/config.v1.json` and `fixtures/mustache/config.dev.v1.json` select
`RULES_CLASSIC`, so they reproduce the old behavior bit-for-bit. Since
2026-11-12 the real-level corpora (`fixtures/{ribbon_waves,imported_levels}`)
are 10ee3a0 captures whose configs select `RULES_RAMP_BUCKET` (see below).
`bucket_catch_hold_steps = ceil(bucket_catch_hold / fixed_dt)` (90) is also
computed at load. Lua computes the same expression at every fall-out.

Per-step code branches on `c.rules === RULES_RAMP_BUCKET` (an enum compare)
or on `bucket.ramps`. There are no dictionary lookups.

## Julia implementation

- `config.jl`: `RuleSet`, `CONFIG_CLASSIC_BUCKET_KEYS`,
  `CONFIG_RAMP_BUCKET_KEYS`, the new fields. Under the classic rules the ramp
  fields are 0.0; under the ramp rules `bucket_edge` is 0.0.
- `state.jl`: `BucketEdge`/`BucketPiece` are isbits and fixed-capacity (≤ 4
  vertices). `BucketState` gains `ramps` and
  `rim_width/rim_height/ramp_width/ramp_height/floor`, plus a preallocated
  `pieces::Vector{BucketPiece}` (capacity 7). `BallState` gains
  `bucket_caught`. The constructor mirrors `Bucket.new`, including `nonneg`,
  the slope clamp and `det_tan(slope * pi / 180)`.
- `bucket.jl`: `bucket_build_pieces!` (Lua `build_pieces`/`make_piece`, using
  `Base.setindex` on tuples, no heap). `ramp_bucket_resolve!` with
  `_bucket_piece_penetration`, `_bucket_sweep`, `_bucket_reflect!`,
  `_bucket_separate!`, `_bucket_overlaps_any` and `bucket_in_catch_zone`. Each
  keeps the Lua operand order and routes `sqrt` through DetMath. Lua `nil`
  results become a leading `Bool` in a returned tuple. `bucket_resolve!` and
  `bucket_half_span` dispatch on `bucket.ramps`, and the classic resolver is
  now `classic_bucket_resolve!`.
- `engine.jl`: `ShotEngine.catch_hold_until_step::Union{Nothing,Int}` is
  runtime state that is not checkpointed. It is reset by
  `reset_shot_engine!`, the equivalent of `resetTurn`. Phases 11, 12 and 15
  follow core.lua. With the classic rules `bucket_caught` and the hold are
  never set, so those branches reduce to the old code. A mismatch between the
  checkpoint's bucket model and `config.rules` throws in `shot_engine` and
  `reset_shot_engine!`.
- `powers.jl`: `powers_activate!(dest, peg, c)` appends into the engine's
  reused `pending_spawn_specs`. The old path allocated a fresh `Vector` per
  green hit. `powers_activate(peg, c)` is kept for the API and tests.
- `checkpoint.jl`: `CheckpointBucket` carries the model and the ramp fields.
  The model is encoded by key presence, as in Lua `copy_bucket`: a classic
  bucket encodes exactly the old keys, so pinned checkpoints are
  byte-identical. Restoring rebuilds the pieces only when the model or a
  dimension changed. Candidate resets never rebuild. `schemas/checkpoint.v1`
  documents the optional ramp-bucket keys (the schema is permissive).
- `snapshot.jl`: emits the per-model bucket keys, `bucket_caught` and
  `catch_hold_until_step`, as Lua does.

## Evidence (2026-11-11)

- **Bucket oracle**: a LuaJIT script loads `10ee3a0` `src/entities/bucket.lua`
  through `tests/love_stub` and covers five configs (default, rim 20, slope
  45, slope 10 with rim height 0, rim height 30). It checks the geometry, 300
  update steps and 20,000 random swept resolves: moving bucket, still balls,
  catches, bounces and push-outs. All values are bit-identical in Julia
  (`%a` comparison, 0 mismatches).
- **Shot traces**: the 25 imported-level shots (b1/b2/g1/m1/m2 × 5 aims) were
  captured from the dev tree at `10ee3a0` into a scratch directory, with **full
  per-step snapshots**. The flow and harness were those of
  `capture_imported_levels.sh` and needed no tooling change. Julia traces are
  25/25 byte-identical, covering 5 catches with holds, 5 bucket bounces and 5
  one-ball spawns. The corpus was not committed; the trace-parity agent owns it.
- The pinned M4 fixture replay matches 14/14 fixtures and 6/6 traces
  byte-identical, with a report identical to the committed
  `results/m4/fixture-parity.json`. All test suites still replay the classic
  dev-tree corpora (ribbon_waves, imported_levels, mustache) byte-for-byte.
- **Allocation**: warmed ramp-rule shots (catches, holds, spawns) step with
  0 bytes, the same as the classic rules on the same boards.

## Real-level corpora (re-captured 2026-11-12)

`fixtures/ribbon_waves` and `fixtures/imported_levels` were captured at
`bbd8622` under the classic rules until 2026-11-12. They were re-captured from
the clean dev tree at `10ee3a0` (tree `b3630882…`, `src/config.lua` sha256
`e40d659e…`) with `scripts/capture_ribbon_waves.sh` and
`scripts/capture_imported_levels.sh`; no tooling change was needed. Both
config artifacts now select `RULES_RAMP_BUCKET` and are byte-identical to
`campaigns/ribbon/config.v1.json`. The level geometry is unchanged; only the
artifact provenance changed. Every shot changed (new rules). Both `--check`
modes pass, and Julia replays all 28 records and traces byte-for-byte
(`test_imported_levels.jl`, `test_ribbon_waves.jl`). The 25+3 Lua records
now include 5 bucket catches with holds and 5 shots with one-ball spawns. These are
the six real levels that tests, campaigns and benchmarks use
([testing](testing.md)). The full-grid sweep reports under
`results/ribbon_port/` were measured against the classic-rule captures and
remain historical.

## Conservative broad phase (2026-11-13)

Both the live Lua game and Julia now skip ramp-bucket resolution when the
entire swept circle is above, left of, or right of the bucket's local bounds.
The check uses both endpoints in the moving bucket's frame, with padding
`ball.radius + 1`. The narrow-phase calculations and their order are unchanged.
`collision_half_span` is derived alongside the convex pieces. Julia checkpoint
restores rebuild it when dimensions change; it is not serialized.

The [validation and timing record](../../results/analysis/bucket-broadphase.json)
records the directed resolver oracle, full-grid Lua/Julia comparisons,
multi-turn traces, allocation gates and deathstar measurements. Julia uses
1.12.6 with `system_libm`; the timing protocol is one thread, CPU 2, a full
1,801-candidate warmup and the best of three prepared sweeps. The before/after
ns/step are b1 12,196 → 11,375, b2 3,936 → 3,034 and m1 8,082 → 7,254.
These include the complete candidate sweep and reset cost.
