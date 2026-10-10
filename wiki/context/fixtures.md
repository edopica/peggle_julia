# Reference fixtures (M1)

The fixture set is the frozen behavioral corpus the Julia port is compared
against. Every expected value is captured by running the pinned Lua reference
under LÖVE; nothing is hand-computed. Expected records live in
`fixtures/expected/`, optional gameplay traces in `fixtures/traces/`, and the
catalog in `fixtures/catalog.lua`. M2 adds the initialization corpus:
`fixtures/rng/` (generator and peg-color sequences), `fixtures/checkpoints/`
(ready-to-aim states per static level), and `fixtures/math_census/`.

```bash
make fixture-list              # list catalog entries
make fixtures                  # capture/refresh expected records
scripts/capture_fixtures.sh --id ID
scripts/capture_fixtures.sh --check   # byte-identical re-capture
make check-all                 # check plus fixture re-capture and corpus-integrity tests
```

## 1. The "42-case matrix" assessment

`temp/julia-port-strategy.md` §5 step 0 proposes freezing "the corpus: 42-case
level × angle matrix". M0's inventory (`wiki/context/inventory.md` §7) searched
the pinned tree and found no such artifact; M1 confirms it does not exist in
the reference or its wiki. The number was a planning placeholder, not a
specification, so M1 defines the actual matrix below. It is deliberately
organized by **mechanism** rather than by a fixed case count, so coverage is
auditable: every acceptance category from implementation-plan §5, M1 maps to
at least one fixture.

Coverage summary: 14 natural aim-grid shots, 11 boundary scenarios, 25
records, using all eight static levels of the twelve pinned levels. Moving
levels are out of M1 scope by definition.

## 2. Matrix by required category

| Category | Fixtures | Mechanism exercised |
| --- | --- | --- |
| shape boundaries | `probe_graze_gap_0_25/0_50/0_75`, `probe_rectangle_corner_rotated`, `probe_annular_outer_surface`, `probe_annular_inner_surface`, `probe_annular_cap_crossing`, `squiggly_annular_drop` | exact graze threshold, swept rotated rectangle corner, annular inner/outer/cap surfaces, dense zero-gap annular contact |
| near-ties | `probe_near_tie_equal_toi` | two pegs at equal TOI; reducer keeps candidate-index order |
| grazes | `slide_rail_graze` | straight drop grazes every zero-gap rail peg (38 circles via non-bouncing grazes), awards slide |
| overlap correction | `probe_depenetration_inner_wall`, `probe_depenetration_band_exit` | inner-wall overlap stays in the hole; band overlap exits through the nearer surface |
| clearing | `clearing_cascade` | `completion = "clearing"` steps through end-of-turn clearing to the next ready-to-aim boundary |
| fever | `super_long_shot_fever` | hitting the level's only red triggers fever |
| powers | `power_green_spawn` | green peg hit spawns two power balls |
| style awards | `slide_slide_style`, `long_shot_style_fever`, `double_long_shot_style`, `lucky_bounce_style`, `off_the_wall_style` | slide, long shot, double long shot, lucky bounce, off the wall |
| line metadata | `slide_line_metadata` | `line.id/index/count/closed/gap` through slide scoring and inversion |
| bucket | `bucket_catch` | clean bucket catch, no style |
| multiball | `multiball_slide_3`, `probe_ball_ball_impulse` | three simultaneous balls; equal-mass head-on ball-ball impulse |
| completion | `completion_miss_fell_out` | simplest completion path (no contact, falls out) |

## 3. Natural shot fixtures

All shots are legal aim-grid indices from the ready-to-aim boundary with zero
additional delay (`delay = 0`). `bench` completion ends when no launched ball
remains; `clearing` continues to the next ready-to-aim boundary.

| Fixture | Level | Index | Balls | Completion | Captured outcome |
| --- | --- | --- | --- | --- | --- |
| `slide_rail_graze` | slide | 900 | 1 | bench | 45 pegs, slide style, 768 steps |
| `slide_slide_style` | slide | 406 | 1 | bench | 23 pegs, slide style, 644 steps |
| `slide_line_metadata` | slide | 503 | 1 | bench | 22 pegs, slide style, 721 steps |
| `completion_miss_fell_out` | long_shot | 900 | 1 | bench | 0 pegs, `fell_out`, 80 steps |
| `clearing_cascade` | circle_level | 53 | 1 | clearing | 6 pegs, 2 spawned, 183 steps |
| `bucket_catch` | circle_level | 61 | 1 | bench | `bucket_caught`, 117 steps |
| `super_long_shot_fever` | super_long_shot | 1736 | 1 | bench | fever, super long shot, 230 steps |
| `long_shot_style_fever` | long_shot | 1736 | 1 | bench | long shot + fever + 2 spawned, 306 steps |
| `power_green_spawn` | circle_level | 53 | 1 | bench | 2 spawned, no style, 154 steps |
| `double_long_shot_style` | double_long_shot | 633 | 1 | bench | double + long + super long shot, 345 steps |
| `lucky_bounce_style` | lucky_bounce | 1046 | 1 | bench | lucky bounce + bucket catch, 232 steps |
| `off_the_wall_style` | off_the_wall | 7 | 1 | bench | off the wall, 76 steps |
| `multiball_slide_3` | slide | 900 | 3 | bench | 47 pegs, slide style, 900 steps |
| `squiggly_annular_drop` | squiggly_circle | 900 | 1 | bench | 4 annular pegs, 284 steps |

Indices were located with the harness search mode, which evaluates the whole
grid and filters by style, fever, spawn, bucket, and score:

```bash
scripts/love.sh love harness -- --search --level slide --match style:slide --limit 5
scripts/love.sh love harness -- --search --level circle_level --match spawned
```

## 4. Scenario fixtures

`fixtures/scenarios.lua` runs targeted physics/engine setups under LÖVE and
returns compact observations. The runner snapshots scalar `Config` values and
`LevelManager` dimensions around each scenario, so mutations cannot leak.
Scenarios pin the seams that natural shots cannot reliably target.

| Fixture | Probes |
| --- | --- |
| `probe_graze_gap_0_25/0_50/0_75` | circle graze band: 0.25 px (graze event), exactly 0.5 px (`graze_tolerance`, no event), 0.75 px (no event) |
| `probe_rectangle_corner_rotated` | swept rotated-rectangle corner: local -y path 3 px outside the bottom-left corner, single bouncing sweep (TOI 0.9997) whose impact point is the corner |
| `probe_annular_outer_surface` / `_inner_surface` | radial sweep against both annular faces |
| `probe_annular_cap_crossing` | swept flat cap: perpendicular approach 0.2 rad outside the start cap at radius 45, single bouncing sweep (TOI 0.71) at cap radius 44.1 |
| `probe_near_tie_equal_toi` | engine reducer tie-break with two equal-TOI pegs |
| `probe_depenetration_inner_wall` | large-radius border inner-wall overlap (8718.93 -> 8718.8 radius, stays inside) |
| `probe_depenetration_band_exit` | band overlap exits inward (93.9) and outward (126.1) |
| `probe_ball_ball_impulse` | equal-mass head-on impulse, symmetric result |

The depenetration probes are the exact regression geometries from
`tests/test_annular_depenetration.lua`; the near-tie probe mirrors the
candidate-index tie rule; the remaining probes measure thresholds the aim
grid cannot address precisely.

## 5. Expected record and trace contract

Every `fixtures/expected/<id>.json` record contains (schema
`peggle.fixture` v1):

- `source`: reference revision, tree, config hash, and for shots the level
  name and level artifact hash;
- `seed`: level seed and effective type counts;
- `action`: aim index/angle/delay/balls, or the scenario name;
- `completion`: rule (`bench`/`clearing`/`scenario`), completed flag, reason,
  steps, and the step cap;
- `result`: score components, style map, board totals, spawned balls; or the
  scenario observation table;
- `trace`: for trace-enabled shots, the relative path, SHA-256, and step
  count of the canonical gameplay trace.

Traces are written by `GameplayTraceExporter` with `include_snapshot = false`:
one JSONL line per fixed step with raw events, derived events, requested
commands, and applied commands (sorted keys, `%.17g` numbers). Snapshots are
excluded to bound repository size; the trace hash still pins the exact event
stream. The historical `fixtures/traces` corpus stays snapshot-free: default
captures and `capture_fixtures.sh --check` never request snapshots. WP-E
experimental fresh captures can opt in with the harness `--fixtures-snapshots`
option, which sets `include_snapshot = true`; `scripts/core_math_trace.sh`
uses it for its reference, `system_libm`, and `core_math` captures.
`tools/compare_traces.py` then compares the full authoritative per-step
simulation state when both corpora carry snapshots (`state_comparison = full`)
and reports event/result agreement otherwise (`not_captured`, or
`scope_mismatch` when only one side has them).

## 6. Capture protocol and determinism

1. `make export` must be current; shot fixtures record the level artifact
   hash.
2. Capture runs under LÖVE 11.x with the pinned reference on `package.path`;
   the RNG is the real `love.math.newRandomGenerator`.
3. Expected records contain no timestamps or host data, so the same pinned
   revision must reproduce them byte-for-byte.
4. `scripts/capture_fixtures.sh --check` re-captures every fixture and fails
   on any difference. Verification never writes to the reference corpus:
   shot traces are captured to temporary files, the existing reference trace
   in `--fixtures-traces` (default `fixtures/traces`) must match the expected
   record's `trace.sha256` and contain `trace.events + 1` lines (the exporter
   writes a header), and the regenerated trace is byte-compared with the
   reference. Expected records are compared as raw canonical text and are not
   rewritten.
5. `make check-all` runs the re-capture comparison plus artifact
   reproducibility, schema validation, and `scripts/test_fixture_check.sh`,
   a negative test that corrupts a scratch trace and requires check mode to
   fail without modifying either corpus dir.
6. Any physics/config change advances the reference pin and re-captures the
   fixtures; captured values are never hand-edited.

## 7. How later milestones consume the corpus

- M2 (done) initializes geometry and RNG from `interchange/` and matches the
  captured M2 fixtures: `fixtures/rng/rng_sequences.v1.json`,
  `fixtures/rng/peg_colors.v1.json`, and the ready-to-aim records in
  `fixtures/checkpoints/`. Julia-built checkpoints are byte-identical to the
  captured records, and the parity manifest pins the fixture and geometry
  hashes (`wiki/context/julia.md`, `wiki/audits/m2-rng-geometry.md`).
- M3 compares its first shot sweeps against the natural shot records on the
  same grid, completion rule, and observation mode.
- M4 expands to full static gameplay and uses the scenario probes and
  clearing/fever/style/bucket/multiball shots for event-semantics parity.
- Cross-engine comparison distinguishes event semantics from numeric
  payloads; the scenario observations carry exact impact coordinates and
  velocities for tolerance decisions.

Scenario fixtures exercise the low-level engine/physics seam rather than a
launched candidate; they are reference observations, not bot actions. The
action schema (`aim_index`, `delay`) covers all shot fixtures and needs no
change when the M8 timing search arrives.
