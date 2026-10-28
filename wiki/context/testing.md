# Test selection

Run the simulator suite with `make julia-test` and the benchmark harness
contracts with `make julia-scripts-test`. To exercise actual concurrent campaign
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

Full-grid qualification, cross-host comparisons, and performance measurements
remain explicit commands (`make m4-parity`, `make m4-bench`, and the allocation
probe in the quickstart). The benchmark publisher's real end-to-end smoke is
`make julia-scripts-integration`.

Local before/after measurements and assertion counts are recorded in
[the pruning results](../../results/test-pruning/2026-10-28.json). These include
compilation and overlapping processes, so treat timings as indicative.
