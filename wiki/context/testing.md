# Test selection

Run the simulator suite with `make julia-test` and the benchmark harness
contracts with `make julia-scripts-test`.

## Six real levels

Tests, campaigns and benchmarks use only the six real levels: `b1`, `b2`,
`g1`, `m1`, `m2` (`fixtures/imported_levels`) and `ribbon_waves`
(`fixtures/ribbon_waves`). `PeggleSim.RealLevels` names them
(`RealLevels.NAMES`, `artifact_path(name)`, `config_path()`, `resolve(spec)`),
and the campaign and benchmark CLIs accept those names for `--level`. All six
use the campaign config `campaigns/ribbon/config.v1.json`, which selects the
peggle_evolved `10ee3a0` rules (`RULES_RAMP_BUCKET`). Both corpora were
captured from the dev tree at `10ee3a0`, and their config artifacts are
byte-identical to the campaign config. Re-check them with
`scripts/capture_imported_levels.sh --check` and
`scripts/capture_ribbon_waves.sh --check`.

Do not add tests on the pinned interchange levels (`interchange/levels/*`),
the mustache corpus or the pinned M1–M4 trace/expected/checkpoint corpora.
Pure unit tests that build their own geometry in code may use any config,
including the pinned classic-rules `interchange/config.v1.json`, which still
covers `RULES_CLASSIC`. The zero-allocation gate is `make alloc-gate`
(`scripts/allocation_gate.jl`, strict zero on every steady-state row of the
real-level catalog). The 2026-11-12 records are
`results/allocation-gate/2026-11-12-real-levels{,-prepared}.json`: 12/12 rows
step with 0 bytes; prepared resets allocate 1,168 bytes per candidate. To exercise actual concurrent campaign
workers, run:

```bash
julia --project=julia/PeggleSim -t 3 julia/PeggleSim/test/runtests.jl
```

For focused changes, include the relevant file directly, for example:

```bash
julia --project=julia/PeggleSim julia/PeggleSim/test/test_physics.jl
```

Keep tests that distinguish a specific wrong behavior: captured Lua results,
collision boundaries, scoring rules, match transitions, reset isolation,
event ownership, scheduling identity, and rejected invalid evidence. Prefer an
observable result over a field layout or a source-text requirement. A new
case should cover a distinct failure, rather than another combination already
covered by the same oracle. Use representative scenes for expensive full shots
and campaign runs.

## Pruning on 2026-10-28

Historical record. Some retained coverage named here (`test_colors.jl`,
`test_parity.jl`, the mustache/slide/squiggly prepared-reset shots) was removed
on 2026-11-12; see the last section.

The cleanup removes tests rather than hiding them behind a slower test target.
Production code, the frozen Lua reference, fixtures, and golden traces are
unchanged.

| Removed or reduced | Retained coverage |
| --- | --- |
| Duplicate color replay in `test_rng.jl` | `test_colors.jl` checks the captured colors, queue, promotion rounds, and RNG state more completely. |
| Standalone census test and its diagnostic Base-math calculations | `test_parity.jl` calls the production census verifier against all 15,794 captured Lua results; the standalone audit command remains available. |
| Frozen level/ribbon data inventories and repeated hash-format checks | All nine checkpoint captures and the three byte-exact ribbon Lua traces remain. Config parsing and invalid-input rejection remain. Source geometry fit metrics and authoring constants are no longer pinned by the Julia unit suite. |
| Constructor defaults, payload representation assertions, source-text bans, broad checkpoint memory ceiling | Physics, event mutation isolation, reset behavior, traces, and explicit allocation/benchmark tools check the consequences. The numerical policy still prohibits reassociation. |
| Repeated canonical formatting examples and tests of Printf/JSON round-trips | Captured canonical strings, escaping, numeric boundaries, invalid values, and byte-exact checkpoint encoding remain. |
| CLI help inventory and ordinary parser errors | Runner validation still rejects invalid inputs before creating a run. Measurement, exit-code/signal handling, evidence validation, and archive/index safety remain. |
| Solo full-grid scheduling repeats and worker-count matrix | Solo lifecycle and step-limit rejection remain. One 1v1 serial/instrumented/uninstrumented comparison uses more matches than workers, two turns, and at most two workers. The worker count greater than queue length case remains. |
| Prepared-reset shot matrix (27 to 12 comparisons) | All three reset/geometry modes still compare ordered events and final state against ordinary resets, using mustache center/power shots, slide multiball, and squiggly annular geometry. |

At the time, full-grid qualification, cross-host comparisons and performance
measurements remained explicit commands (`make m4-parity`, `make m4-bench` and
the allocation probe). Those M4 commands were removed on 2026-11-12 (below).
The benchmark publisher's real end-to-end smoke is
`make julia-scripts-integration`.

Local before/after measurements and assertion counts are recorded in
[the pruning results](../../results/test-pruning/2026-10-28.json). These include
compilation and overlapping processes, so treat timings as indicative.

## Restriction to the real levels on 2026-11-12

The real-level corpora were re-captured at `10ee3a0` first, so the surviving
tests check the current rules. Every test that loaded a non-real level or a
pinned corpus was then rewritten onto a real level or deleted.

| File | Change | Coverage lost |
| --- | --- | --- |
| `test_checkpoint.jl` | Byte comparison with the nine Lua-captured pinned checkpoints replaced by an encode/decode round trip on all six levels (plus m1 with three balls); reset, aliasing and `first_difference` moved to b2/g1/ribbon_waves. | Byte equality with Lua `setupLevel` checkpoints. Initial state is still checked indirectly by the 28 Lua trace replays. |
| `test_prepared_checkpoint.jl` | Pinned checkpoints, mustache, slide and squiggly_circle replaced by the six levels; shot parity on b2 (static geometry, catch, spawn), g1 (ribbon slide, catch), m1 with three balls (two spawns) and ribbon_waves (catch). | None specific; the classic-rule two-ball spawn is no longer exercised in full shots. |
| `test_engine.jl` | Mustache shots replaced by b1 900 and m1 1800, asserting the Lua `10ee3a0` record values; clearing and parallel-worker checks on b1. | The classic-rule full shot with a two-ball spawn. |
| `test_snapshot.jl` | Mustache replaced by b2 (circle, annular, rectangle) and g1 (ribbon keys); bucket keys are the ramp-bucket set. | Classic `edge` bucket key in snapshots. |
| `test_shot_scratch.jl` | Mustache replaced by b2. | None. |
| `test_level.jl` | Non-static rejection uses the b2 artifact; the config-artifact check covers both rule sets. | None. |
| `test_style_shots.jl`, `test_ball_state.jl`, `test_slide_inversion.jl` | Mustache config replaced by the campaign config (same style constants). | None. |
| `test_colors.jl` | Deleted: it replayed the Lua peg-color fixture of the eight pinned levels. | Lua oracle for color init, queue order, purple promotion rounds, queue rebuilds and RNG state. The imported-levels test still checks the `level_seed` layout and per-game color draws. |
| `test_parity.jl` | Deleted: the parity manifest is built from the pinned levels, checkpoints and math census. | Math census (15,794 Lua cases) in the unit suite, which is still available as `make math-census-check` and `make julia-parity`; parity-manifest API tests. |

`test_imported_levels.jl` and `test_ribbon_waves.jl` replay the re-captured
corpora (25 + 3 records and traces) and now also check that the corpus config
is the campaign config. `test_campaign.jl` and `test_match_campaign.jl` load
ribbon_waves through the registry. Synthetic unit tests (`test_physics.jl`,
`test_bucket.jl` classic section, `test_powers.jl`, `test_fever.jl`,
`test_contact_payloads.jl`, `test_impact_geometry.jl`,
`test_static_query.jl`) still use the pinned classic config; `test_rng.jl`
still replays the level-independent LÖVE RNG sequences.

Removed with the tests: the `make m3-*` and `make m4-*` targets,
`scripts/{bench_m3.sh,compare_m3_mustache.sh,capture_m3_mustache.sh,compare_m3_sweeps.py,test_compare_m3_sweeps.sh,m4_parity.sh,bench_m4.sh,bench_m4_report.py,m4_cross_machine.py,allocation_validate.py}`
and `bin/{replay_fixtures.jl,scenario_probe.jl}`. `scripts/m4_allocation.jl`
became `scripts/allocation_gate.jl` with a real-level catalog and a `--gate`
exit status. The pinned fixtures stay, because the Lua tooling (`make
fixtures`, `make check-all`, `make capture-m2`, `make math-census`) and the
ribbon_waves mask checker still use them.

