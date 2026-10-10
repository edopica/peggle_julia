# Interchange formats (M1)

This document defines the versioned data contract between the Lua reference
and the Julia simulator: levels, configuration, checkpoints, actions, results,
and reference fixtures. The machine-readable definitions live in `schemas/`;
this page records the rationale, the supported static subset, and the rules
that keep artifacts reproducible across machines.

Regenerate every artifact with:

```bash
make export     # interchange/ + SVG previews
make fixtures   # fixtures/expected/ + optional traces (needs LÖVE/display)
make check      # reproducibility + schema validation (no display)
make check-all  # check + fixture re-capture comparison
```

## 1. Artifact inventory

| Artifact | Path | Producer | Consumer |
| --- | --- | --- | --- |
| Level definition | `interchange/levels/<name>.v1.json` | `tools/export_level.lua` | M2 level construction, previews |
| Sim config | `interchange/config.v1.json` | `tools/export_config.lua` | M2 constants and math contract |
| SVG preview | `interchange/previews/<name>.svg` | `scripts/render_level_svg.py` | human review, contact sheets |
| Artifact manifest | `interchange/files.sha256` | `scripts/export_interchange.sh` | `scripts/verify_interchange.sh` |
| Fixture catalog | `fixtures/catalog.lua` | hand-authored | fixture capture |
| Fixture records | `fixtures/expected/<id>.json` | harness fixture mode | M3/M4 parity |
| Fixture traces | `fixtures/traces/<id>.jsonl` | harness fixture mode | M3/M4 event comparison |

Schemas:

| Format | Schema |
| --- | --- |
| `peggle.level` | `schemas/level.v1.schema.json` |
| `peggle.config` | `schemas/config.v1.schema.json` |
| `peggle.checkpoint` | `schemas/checkpoint.v1.schema.json` |
| `peggle.action_log` | `schemas/action-log.v1.schema.json` |
| `peggle.shot_result` | `schemas/shot-result.v1.schema.json` |
| `peggle.fixture` | `schemas/fixture.v1.schema.json` |

`scripts/validate_interchange.py` implements the JSON-Schema subset used by
these files and adds cross-field checks (contiguous peg ids, effective type
counts, line-group consistency).

## 2. Canonical encoding

All interchange JSON uses the canonical encoder in `tools/canonical_json.lua`:

- object keys are emitted in ascending lexicographic order;
- arrays keep their 1..n order; container kinds are explicit: empty
  containers must be marked with `CanonicalJSON.array` or
  `CanonicalJSON.object` (`[]` and `{}`), and an unmarked empty table is a
  hard error. Unmarked non-empty tables keep the inference rule: a
  contiguous integer sequence encodes as an array, anything else as an
  object;
- the decoder marks decoded arrays and objects, so decode -> encode
  preserves `[]` vs `{}` exactly;
- doubles use `%.17g`, integers below 2^53 use decimal notation;
- negative zero is preserved as `-0`; NaN and infinities are rejected;
- no timestamps or environment data appear in authoritative artifacts.

These rules make a byte comparison a valid equality check for numeric state
and ordering. Levels are written in engine order; peg `id` is the engine's
`original_index` (contiguous `1..n`).

### Hash conventions

| Name | Meaning |
| --- | --- |
| `config_sha256` | SHA-256 of `reference/peggle_evolved/src/config.lua` (the M0 pin convention) |
| `level_sha256` | SHA-256 of the level artifact file (`interchange/levels/<name>.v1.json`) |
| `reference_revision` / `reference_tree` | Values from `reference/PIN.md` |

## 3. `peggle.level` v1 (static subset)

The exporter runs the same load-time pipeline as `Engine:setupLevel` up to
(but not including) peg-color assignment:

1. load the level module through `LevelManager.load`;
2. normalize raw pegs through `Peg.new`/`Peg.new_rectangle`/`Peg.new_annular`
   exactly as the engine does;
3. `Lines.validate` (line metadata contract);
4. boundary filtering via `LevelValidator.validate_pegs`;
5. `Lines.validate` again (stale line groups are a hard error);
6. assign `original_index` in level order.

The artifact therefore describes the authoritative board the simulator must
build. Fields:

| Field | Notes |
| --- | --- |
| `name`, `virtual_width`, `virtual_height` | Resolved per-level dimensions |
| `level_seed` | Seeded color assignment input (`345` when absent upstream) |
| `type_counts` | **Effective** counts (`blue = pegs - red - green - purple`), as passed to `PegColors.init` |
| `default_peg_type` | Config fallback for unknown authored types |
| `pegs` | Ordered array; `id` is contiguous and stable |
| `provenance` | Reference revision/tree, config hash, level source path |

Per-peg fields:

- circle: `radius`
- rectangle: `width`, `height`, `angle`
- annular: `r_in`, `r_out`, `theta_start`, `theta_end_abs`, `segments`
- optional `line`: `{ id, index, count, closed, gap }` copied verbatim;
  this is the metadata slide inversion and slide-style recognition read.

Peg `type` is the *resolved render type*: unknown authored values (for
example the numeric third argument in `circle_level.lua`) fall back through
the engine's `typeDef` rule to `default_peg_type`. Runtime colors come from
`PegColors.init(pegs, type_counts, level_seed)` and are not part of the
level artifact.

### Static subset and motion rejection

The v1 level format supports **static levels only**: `level_circuits` absent
or empty and no `peg.motion` assignment. The pinned static set is:

`circle_level`, `double_long_shot`, `long_shot`, `lucky_bounce`,
`off_the_wall`, `slide`, `squiggly_circle`, `super_long_shot`.

Moving levels (`level1`, `benchmark_lasagna`, `advanced_circuits`,
`slide_rotating`) are rejected with exit code 2 and a per-circuit reason.
Legacy `path_fn` circuit functions get their own explicit error; they are
never silently converted (the old `tools/dump_level.lua` converted them to
`kind = "unknown"`, which is why M0 marked it as a partial tool).
Moving-level formats and path caches arrive with the M8 motion phase.

## 4. `peggle.config` v1

A canonical dump of every value in the pinned `src/config.lua`, plus
`source_sha256`. M2 pins its constants from this artifact and records the
content hash in cross-machine manifests. Nested tables (`peg_types`,
`background_color`) are preserved.

## 5. `peggle.checkpoint` v1 (defined, captured in M2)

The decision checkpoint is the state immediately before candidate evaluation
at the ready-to-aim turn boundary: after `Engine:resetTurn()` and before
`Engine:launchBalls()` (`harness/main.lua run_candidate`, `src/engine/core.lua`,
`src/states/game.lua`). Version 1 admits `boundary: "ready_to_aim"` only.
Mid-shot capture is intentionally not advertised: arbitrary continuation adds
authoritative state (swept positions, in-flight event/command journals, the
capture step's circuit phase) and therefore requires a schema version bump
(M8 if the motion phase needs it).

`schemas/examples/checkpoint.v1.example.json` is the captured fixture-grade
`super_long_shot` record, byte-identical to
`fixtures/checkpoints/super_long_shot.v1.json`. The full captured set (the
eight static levels plus `slide.multiball3`) lives in `fixtures/checkpoints/`;
Julia independently builds each record from the level artifact and matches
the canonical bytes exactly (`wiki/audits/m2-rng-geometry.md`). Empty maps are
written as `{}` (canonical container markers, section 2).

| Field | Contract |
| --- | --- |
| `boundary` | `"ready_to_aim"` only in v1 |
| `engine.step_id`, `engine.shot_id` | Fixed-step and shot counters. `step_id` counts simulated steps; `shot_id` is reset by `setupLevel`, incremented by `launchBalls`, and not reset by `resetTurn`, so after a turn they are nonzero (only the first ready-to-aim is 0/0) |
| `engine.level_name` | Level name |
| `engine.next_ball_id` | Next permanent ball-ID candidate (`>= 1`) |
| `engine.used_ball_ids` | Permanently consumed ids in allocation order; never reused |
| `engine.turn_pegs_hit` | Peg ids scored this turn in hit order; `[]` at ready-to-aim |
| `engine.clearing` | `{ active, is_end_of_turn, timer }`; required. At ready-to-aim `active` must be false and `timer` 0; `is_end_of_turn` is retained from the last `startClearing` call and may be true while inactive |
| `engine.pegs` | Engine order; each `{ id, type, hit, x, y, shape }` plus geometry |
| `engine.balls` | Each `{ id, x, y, vx, vy, launched, radius }`; all unlaunched |
| `engine.bucket` | `x`, `phase` (as `Bucket.new`); optional `prev_x`, `top`, `hole`, `edge`, `height` |
| `engine.fever_buckets` | `top`, `height`, `animating`, `buckets`, `dividers` |
| `engine` scoring | All required. Authoritative continuation fields serialized verbatim: `hit_counter` (assigns `peg.hit_order`, core.lua:816-817), `total_red_pegs` (level count, core.lua:384), `red_pegs_hit_amount` (scored reds, core.lua:820). All three survive `resetTurn` (core.lua:510-554), and clearing removes hit pegs (core.lua:1025-1047), so they cannot be reconstructed from `engine.pegs`. Derived: `current_multiplier = updateMultiplier(red_pegs_hit_amount, total_red_pegs)` (thresholds, core.lua:306-320); `is_fever` iff `current_multiplier == 100`. Per-turn `bonus_score`/`style_score` must be `0` at ready-to-aim (`resetTurn`, core.lua:544-545) |
| `rng` | Generator, seed, and non-empty base64 `state_b64` of `RandomGenerator:getState()` (the continuation input) |
| `purple_queue.queue` | Ordered un-hit blue peg ids still queued for promotion |
| `purple_queue.active` | Peg ids currently promoted to purple |
| `trackers.style_shots` | `reset_shot` maps: `last_impact`, `qualifying_streak`, `last_qualifying_seq`, `bucket_bounced`, `bounced_after_bucket`, `side_wall_hit`, `hit_any_peg`, `awarded`, `slide_runs`, `slide_awarded` |
| `trackers.ball_state` | `idle`, `idle_timer`, `reacted` (maps), `all_idle_latch`, `no_score_timer`, `no_score_timeout_fired` |
| `trackers.slide_inversion` | `line_hits`, `hit_seen`, `removed`, `track` (maps) |
| `match` | `mode`, `players` (exactly 2), `current_player_index`, `shared_bucket_hits`, `game_over`, optional `winner` (`0` = draw) |

`scripts/validate_interchange.py` enforces these cross-field invariants:

- `used_ball_ids` unique; `next_ball_id > max(used_ball_ids)` when non-empty;
- ball ids unique, present in `used_ball_ids`, below `next_ball_id`, and
  unlaunched;
- peg ids unique and strictly ascending in engine order; `hit` is boolean;
- `queue` and `active` disjoint; queue ids are un-hit blue pegs, active ids
  are purple pegs;
- clearing inactive (`active` false, `timer` 0; `is_end_of_turn` is retained
  from the last `startClearing` and may be true); `turn_pegs_hit` empty;
  every tracker map empty; `ball_state` latches and timers reset;
- scoring: `red_pegs_hit_amount <= total_red_pegs`; `current_multiplier`
  equals the `Engine:updateMultiplier` derivation from those two fields
  (`total_red_pegs == 0` -> 1; else `pct >= 1.0` -> 100, `>= 0.88` -> 10,
  `>= 0.75` -> 5, `>= 0.60` -> 3, `>= 0.40` -> 2, else 1; core.lua:306-320);
  `is_fever` iff `current_multiplier == 100`; `bonus_score` and `style_score`
  are 0 at ready-to-aim (`resetTurn`, core.lua:544-545);
- `match.players` has exactly two entries; `winner` is absent while
  `game_over` is false.

Mutable sub-objects deliberately allow additional properties: encoders must
serialize **every** authoritative field, and unknown fields are
authoritative, not ignorable. Version 1 defines the minimum contract; a
change that cannot be represented is a schema version bump.

M0 rebuilt state per candidate (`setupLevel` per candidate) and documented
that RNG, purple queues, circuit phases, and bucket phase were not restored.
M2 replaces that rebuild with this checkpoint.

## 6. `peggle.action_log` and `peggle.shot_result` v1

- An action is `{ aim_index: 0..1800, delay: integer >= 0 }`. `delay` is
  reserved for the M8 timing search and is always `0` in M0/M1 artifacts.
- The action log is the ordered list of applied actions for a match or solo
  run, with stable sequence numbers, player, turn, and decision step.
- A shot result is the authoritative candidate summary: steps, completion
  and reason, score components, style counts, board totals, and spawned
  balls. It matches the M0 harness feature set plus `balls_spawned`.
  `schemas/examples/shot-result.v1.example.json` is a captured example.

## 7. `peggle.fixture` v1

See `wiki/context/fixtures.md` for the fixture matrix and capture protocol.
Each record embeds reference revision/tree, config hash, level artifact hash,
seed, action, completion rule, result, and an optional trace hash.

`peggle.fixture` itself leaves the `result` payload open (scenario
observations have their own shapes), but the validator cross-checks every
shot fixture's `result` as a `peggle.shot_result`. That is what catches
type-level drift such as a zero-style `styles` encoded as `[]` instead of
`{}`; the canonical codec's explicit containers keep the encoding correct.

## 8. Round-trip and verification

`tools/export_level.lua --check` performs three comparisons per level:

1. artifact -> canonical text -> decoded artifact -> canonical text is
   byte-identical (numeric serialization, key order, array order);
2. the decoded artifact equals the in-memory artifact under bit-level
   numeric comparison (ids, dimensions, geometry, line metadata);
3. every decoded peg matches the live resolved peg, and ids are contiguous.

`make check` additionally re-exports into a scratch directory and requires a
byte-identical tree, verifies `interchange/files.sha256`, and validates every
artifact, fixture record, and schema example. `make check-all` re-captures
the fixtures under LÖVE and requires byte-identical records.

Level initialization parity beyond these checks — running the reference and
the Julia construction side by side — is the M2 acceptance item; the
`interchange/` artifacts are its input.
