# M4 correctness-breadth validation

M4 is the full static-level shot-behavior milestone. It is **open**. This page
records **sessions 1 and 2 of 3**. Session 1 is corpus parity (this page);
session 2 is the performance gate, recorded in
[`wiki/benchmarks/m4-perf.md`](../benchmarks/m4-perf.md) and
[`wiki/devlog/2026-10-21.md`](../devlog/2026-10-21.md). Cross-machine
qualification is still to come (§9). Session 1 validates the
pinned corpus end to end: 14 shot fixtures, 11 boundary scenarios, 6 gameplay
traces, and 7 full-grid candidate workloads all match the frozen Lua reference
exactly, with one real parity bug found and fixed along the way (§6.1).

## 1. Status and scope

| Item | State |
| --- | --- |
| M4 milestone | **In progress / open** |
| Session 1 — correctness breadth | Complete (this page) |
| Session 2 — performance gate | Complete; see [`m4-perf.md`](../benchmarks/m4-perf.md) |
| Session 3 — cross-machine qualification + closeout | Not started |

Session 1 covers:

- manifest-driven replay of every shot fixture in `fixtures/expected/` with
  provenance verification and exact field comparison;
- byte-level trace parity for the six traced fixtures;
- all 7 M4 workloads over the full 1,801-index candidate grid, compared with
  the existing M3 sweep comparator;
- serial/parallel thread identity for the two dense workloads;
- a faithful port of the 11 boundary scenarios in `fixtures/scenarios.lua`.

It does **not** cover zero-allocation warm stepping, the representative
benchmark, median/tail/alloc/scaling performance metrics, cross-machine
bit-identical qualification, or M4 closeout. The only source change in the
session is the divider parity fix in §6.1; no expected record, fixture, trace,
or reference file was edited.

## 2. Corpus

| Corpus | Count | Location |
| --- | ---: | --- |
| Shot fixtures (`kind == "shot"`) | 14 | `fixtures/expected/<id>.json` |
| Scenario probes (`kind == "scenario"`) | 11 | `fixtures/expected/probe_*.json`, definitions in `fixtures/scenarios.lua` |
| Gameplay traces | 6 | `fixtures/traces/<id>.jsonl` |
| Sweep workloads | 7 | `harness/workloads.lua`, five static levels |

The 14 shot fixtures span completion/clearing, bucket catch, style shots,
fever, multiball, power spawn, and slide metadata:
`bucket_catch`, `clearing_cascade`, `completion_miss_fell_out`,
`double_long_shot_style`, `long_shot_style_fever`, `lucky_bounce_style`,
`multiball_slide_3`, `off_the_wall_style`, `power_green_spawn`,
`slide_line_metadata`, `slide_rail_graze`, `slide_slide_style`,
`squiggly_annular_drop`, and `super_long_shot_fever`.

The 7 workloads are `overhead_static_2p`, `circles_small`, `circles_mixed`,
`lines_rect_annular`, `annular_dense`, `annular_dense_multi3`, and
`lines_rect_annular_multi3` (the last two use 3 balls, the rest 1). They cover
five static levels: `long_shot`, `circle_level`, `off_the_wall`, `slide`, and
`squiggly_circle`. The Lua side is the frozen pin `reference/peggle_evolved`
(§6.2); the Julia side loads `interchange/levels/` and
`interchange/config.v1.json`.

## 3. Method

**Manifest-driven replay.** `julia/PeggleSim/bin/replay_fixtures.jl` treats
each expected JSON record as its own manifest. For every shot fixture it loads
`interchange/levels/<source.level>.v1.json` and
`interchange/config.v1.json`, verifies provenance before running, rebuilds the
checkpoint, resets, launches, and runs `run_shot!`. Provenance is hard-gated,
never skipped: `source.level_sha256` must equal the SHA-256 of the artifact
bytes and `source.config_sha256` must equal the loaded config's
`source_sha256` identity; a mismatch is a hard error (the driver aborts with a
nonzero exit), never a skip.

**Exact comparison, no tolerance.** The 14 compared fields per fixture are:

| Object | Fields |
| --- | --- |
| `completion` | `completed`, `reason`, `steps` |
| `result` | `score`, `peg_score`, `bonus`, `style_points`, `styles`, `pegs_hit`, `reds_hit`, `multiplier`, `is_fever`, `balls`, `balls_spawned` |

`result.balls_spawned` is the Julia `shot_summary.spawned` value. Every field
is compared with exact equality, including the styles map; no tolerance is
applied and no expected value was edited to make a comparison pass.

**Trace byte comparison.** For the six fixtures carrying a `trace` block the
driver regenerates the snapshot-free trace with the default `system_libm`
backend (`include_snapshot = false`) and compares it byte-for-byte with
`fixtures/traces/<id>.jsonl`, including the recorded SHA-256 and event count.
It also compares the traced run's summary against the untraced run's summary
on the same 14 fields.

**Sweeps and thread identity.** Each workload runs the Lua harness over the
full grid and Julia `shot_bench` at thread 1, compared by the existing
`scripts/compare_m3_sweeps.py` (not forked for M4). The comparison covers 16
shared fields — `index`, `angle`, `steps`, `completed`, `reason`, `score`,
`peg_score`, `bonus`, `style_points`, `style_total`, `styles`, `pegs_hit`,
`reds_hit`, `multiplier`, `is_fever`, `balls` — and requires complete index
coverage on both sides. `spawned` is the only exempt Lua row field because the
Lua raw format does not emit it. The two dense workloads also run at threads 2
and 4; identity requires `serial_parallel_identical` and byte-identical
candidate rows against the t1 reference.

**Scenario probes.** `julia/PeggleSim/bin/scenario_probe.jl` reproduces each
Lua scenario body at the Julia physics/engine seam. Ten scenarios drive
`PeggleSim.physics_update!`; `probe_near_tie_equal_toi` drives the shot
engine. Every expected `result` and `completion` field is compared exactly,
including nested event arrays. `-0` versus `0` and `Int` versus `Float` JSON
representations are recorded as representation notes but are equal JSON
numbers, not hidden tolerances.

## 4. Commands

```bash
make m4-parity          # fixtures + traces + 7 sweeps + thread identity + scenarios
make m4-replay          # fixture replay and trace parity only, into results/m4/
scripts/m4_parity.sh --help
```

`scripts/m4_parity.sh` resolves paths from its own location. Flags:
`--stride N` (default 1), `--out-dir DIR` (default `results/m4`),
`--raw-dir DIR` (default `results/raw`), `--workloads LIST|all`,
`--threads "1 2 4"`, `--skip-lua`, `--skip-julia`, `--skip-traces`, and
`--skip-scenarios`. The Lua sweeps always use `reference/peggle_evolved`. Exit
status is 0 only when every requested group passes; 1 is a parity failure or
missing report, 2 is bad usage or missing input.

Direct drivers:

```bash
julia --project=julia/PeggleSim julia/PeggleSim/bin/replay_fixtures.jl \
  --expected-dir fixtures/expected --level-dir interchange/levels \
  --config interchange/config.v1.json \
  --out results/m4/fixture-parity.json \
  --trace-report results/m4/trace-parity.json \
  --trace-out-dir results/m4/traces

julia --project=julia/PeggleSim julia/PeggleSim/bin/replay_fixtures.jl \
  --only long_shot_style_fever --skip-traces

julia --project=julia/PeggleSim julia/PeggleSim/bin/scenario_probe.jl \
  --expected-dir fixtures/expected --config interchange/config.v1.json \
  --out results/m4/scenario-parity.json
```

`replay_fixtures.jl` exits 0 only when every shot fixture matches and every
traced fixture is byte-identical; any parity, corpus, or provenance failure
exits nonzero. `scenario_probe.jl` exits 0 only when every ported scenario
matches (1 on a parity/port failure, 2 on malformed input or provenance
mismatch). A scenario that could not be ported faithfully would be
reported as `not_ported` with a reason, never silently skipped.

## 5. Results

All numbers below are read from the reports; this page deliberately does not
duplicate their per-fixture tables.

| Group | Pass | Evidence |
| --- | --- | --- |
| Shot fixtures | 14/14 fixtures; 196/196 fields; 14/14 provenance | [`fixture-parity.json`](../../results/m4/fixture-parity.json) |
| Traces | 6/6 byte-identical; 6/6 traced-vs-untraced summaries | [`trace-parity.json`](../../results/m4/trace-parity.json) |
| Sweeps | 7/7 workloads; 12,607/12,607 candidates; 0 divergent | [`sweep-summary.json`](../../results/m4/sweep-summary.json), `results/m4/sweeps-compare-<id>.json` |
| Thread identity | 11 runs; 2 workloads at t1/t2/t4; rows identical | [`sweep-summary.json`](../../results/m4/sweep-summary.json) |
| Scenarios | 11/11; 210/210 fields; 0 gaps | [`scenario-parity.json`](../../results/m4/scenario-parity.json) |
| Combined (`make m4-parity`) | 4/4 groups; `overall_pass = true` | [`parity-summary.json`](../../results/m4/parity-summary.json) |

Details behind the counts:

- **Fixtures.** `summary.matched = 14`, `failed = 0`,
  `fields_compared_total = 196` (14 per fixture), `all_match = true`. Both
  provenance values match for all 14 records.
- **Traces.** `summary.identical = 6`, `all_byte_identical = true`,
  `summaries_identical = 6`, `summary_equivalence_all = true`,
  `failed = 0`. Event counts are 183 (`clearing_cascade`), 306
  (`long_shot_style_fever`), 900 (`multiball_slide_3`), 768
  (`slide_rail_graze`), 644 (`slide_slide_style`), and 284
  (`squiggly_annular_drop`). The regenerated traces are transient
  (gitignored); the durable evidence is the report with its SHA-256 values.
- **Sweeps.** Every workload is clean at stride 1 with 1,801/1,801 candidates
  and no missing indices, `mismatch_candidates = 0`,
  `first_divergent_candidate = null`, and no `per_field_mismatch_count`
  entries. The only unavailable field is `spawned`.
- **Thread identity.** The 11 runs are t1 for all 7 workloads plus t2/t4 for
  `lines_rect_annular` and `annular_dense`. For both dense workloads all three
  thread counts have the same row SHA-256, `serial_parallel_identical` is true
  for every run, and `rows_identical_across_threads = true`.
- **Scenarios.** `ported = 11`, `matched = 11`, `not_ported = 0`,
  `failed = 0`, `fields_compared_total = 210` (155 result leaves + 55
  completion fields), `first_mismatch = null`. No `scenario-gaps.json` was
  written because no gap remains.

The combined report written by `make m4-parity` is
[`parity-summary.json`](../../results/m4/parity-summary.json). It records
`overall_pass = true` with `counts.passed = 4`, `counts.failed = 0`, and
`counts.skipped = 0`, and repeats the group counts above (14 fixtures/196
fields, 6 traces, 7 sweeps, 11 scenarios/210 fields). The group reports remain
the detailed evidence.

## 6. Findings

### 6.1 Fever-divider contact metadata: a real parity bug found and fixed

This was a genuine Lua-vs-Julia divergence, not a test artifact. The frozen
`src/systems/physics.lua` passes the hit peg through the Lua and/or idiom
`is_extra and nil or circ` (`checkCircles`, around lines 409 and 436). In Lua
that expression always evaluates to `circ`: `nil` is falsy, so the `or` branch
wins for both values of `is_extra`. Extra-circle contacts (fever dividers)
therefore carry the divider table into `emit_contact`, which emits
`peg_shape = "circle"`, `peg_x`/`peg_y` from the divider, `peg_angle = 0`, and
omits `peg_id`, `peg_type`, and `line`.

Minimal reproduction:

```bash
luajit -e 'local circ={x=480,y=1900}; local is_extra=true; print((is_extra and nil or circ).x)'
# 480: the and/or idiom yields circ even when is_extra is true
```

The Julia port had "fixed" the apparent intent with `is_extra ? nothing :
circ`, so `ball_contact_fever_divider` events lost those four metadata keys.
The divergence was trace-only: physics, score, and summaries were unaffected.
It still broke byte parity for `long_shot_style_fever`, leaving 5/6 traces
matching.

The fix is in `julia/PeggleSim/src/physics.jl`: `hit_peg` is widened to
`Union{Nothing,Peg,FeverDivider}`, `check_circles` passes `circ`,
`emit_contact!` has a divider branch that emits the static transform and shape
`"circle"` with no id/type/line, and the impact-velocity path keeps the
divider velocity at 0. The divider branch of `test_physics.jl` was updated to
assert the reference behavior. Before the fix a divider event had no peg keys;
after it has `peg_shape = "circle"`, `peg_x = 480`, `peg_y = 1900`, and
`peg_angle = 0`. The regenerated trace now matches corpus SHA-256
`f2161904d986eb851e685a54623fec98f542ba7490211b2d44c664103c7ba71a`
(56,566 bytes). The M3 mustache control stayed 5/5 because it has no divider
contacts.

### 6.2 Pinned reference, not the dev tree

The task text suggested `--reference-dir ../peggle_evolved` for the Lua side,
but the full-grid run and the repeatable script use the frozen pin
`reference/peggle_evolved`. That is deliberate:

- the dev tree currently has `src/levels/circle_level.lua` deleted, so
  `circles_small` cannot load there;
- the dev `src/config.lua` sets `ball_ball_restitution = 0.7`, while
  `interchange/config.v1.json` and the pinned tree use `0.8`; the Julia side
  loads the interchange config.

All 7 workloads are pinned levels, and the five level sources are byte-identical
between the pinned tree and the dev tree's HEAD; the dev working tree is what
differs (deleted `circle_level.lua`, `ball_ball_restitution = 0.7`).
`scripts/verify_reference.sh` passes 133/133.
The M4 reports must be read as pinned-vs-Julia evidence, not dev-tree
evidence. This differs from the M3 mustache corpus, which is intentionally
captured from the dev tree (`wiki/context/m3-mustache.md`).

### 6.3 M3 is unaffected

`make m3-mustache` remains 5/5 byte-identical with
`expected_records_identical = true`, `differences = []`, and no failures
([`mustache-compare.json`](../../results/m3/mustache-compare.json)). The divider
fix changes only metadata on fever-divider contacts, which that corpus does
not exercise.

## 7. Scenario decision and coverage

The decision is **option (a): a faithful port** of all 11 boundary scenarios,
not a reduced set. All 11 matched exactly (210 compared fields, no gaps). Ten
probes drive `PeggleSim.physics_update!`; `probe_near_tie_equal_toi` drives the
shot engine. The ported mechanisms are:

- circle graze bands at 0.25, 0.50, and 0.75 px past tangent;
- a rotated rectangle corner;
- annular outer and inner surfaces and an annular cap crossing;
- a reducer near-tie at equal TOI;
- depenetration against an inner wall and through a band exit;
- an equal-mass ball-ball impulse.

Porting details that matter:

- **Config isolation.** `SimConfig` is immutable. Physics probes use a
  named-override copy with `gravity = 0.0`, matching the Lua scenarios'
  `Config.gravity = 0` mutation; the loaded config is never mutated.
- **Capture-time dimensions.** The Lua runner inherits 1200×1900 from the
  preceding shot fixture (`squiggly_annular_drop`); the driver passes those
  dimensions explicitly. The annular outer-surface record rules out other
  widths, and the near-tie step count depends on the 1900 height.
- **Observation shape.** The driver projects the Julia journal payload onto
  the Lua contact sink shape (`type`, `ball_id`, `peg_id`, `peg_shape`,
  `contact_kind`, `did_bounce`, `toi`, `impact_*`, `normal_*`, and
  in/out velocities). Peg identity uses `Peg.id`, matching Lua's
  `peg.original_index`.
- **Near-tie mapping.** The Lua helper installs two inline pegs with
  `original_index` 1 and 2, does not promote purple pegs (both stay blue,
  score 40), launches from `(600, 150)` with `vy = 400` under the default
  gravity 1000, and has no `onAllBallsDepleted` callback, so fall-out starts
  the end-of-turn clearing cascade. The expected `steps = 163` is 153 fall-out
  steps plus 10 clearing steps. The Julia port builds the same `EngineState`,
  uses the default `ShotCallbacks()`, and reproduces the trajectory, the final
  `scored_order = [1, 2]`, `pegs_hit = 2`, and `score = 40`.

**Residual risk.** No scenario mechanism remains unverified. The remaining
risk is maintenance: the driver relies on the current internal
`PeggleSim._fresh_shot_engine` entry point and on the capture-time dimensions
being determined by fixture order. If either changes, the driver fails loudly
with a mismatch or exit 1 rather than passing silently.

## 8. Gates

All gates were run on the final tree in this session, after the divider fix.

| Gate | Result |
| --- | --- |
| `make verify` | 133/133 files match `reference/files.sha256`, before and after the fix |
| `make check` | OK (interchange reproducibility, schemas, contract tests) |
| `make julia-test` | 5616/5616 pass (baseline before the fix: 5608/5608) |
| `make m3-mustache` | 5/5 byte-identical; `expected_records_identical = true`; `differences = []`; `failures = 0` |
| `make m4-parity` | 4/4 groups pass; combined report `overall_pass = true` (see [`parity-summary.json`](../../results/m4/parity-summary.json)) |

## 9. Remaining M4 work

M4 remains **open**. The two remaining sessions are:

1. ~~**Performance gate (session 2).**~~ Done. The criterion, the per-site
   allocation accounting, the seven-workload benchmark and the same-host Lua
   comparison are in [`wiki/benchmarks/m4-perf.md`](../benchmarks/m4-perf.md).
   Steady-state stepping is 0 B/step on `circles_small` and `annular_dense`;
   `mustache` (both aims) and `lines_rect_annular` retain a small command-path
   residue (2–13 allocating steps out of 768–1,797) that is itemised with a
   concrete fix plan in §4.3 of that page. Session 3 should close that residue
   and then qualify cross-machine.
2. **Qualification and closeout (session 3).** Cross-machine bit-identical
   qualification of the validated corpus, then M4 closeout. The cross-platform
   capture procedure is in `wiki/context/cross-platform-qualification.md`.

Until those are complete and recorded, M4 must not be marked done.
