# julia_clone — Peggle Evolved simulation platform (Julia)

A portable simulation platform for [Peggle Evolved](../peggle_evolved). It
generates levels, runs bot games, and measures level behavior at scales the
Lua game cannot reach. See the implementation plan in
`temp/implementation-plan.md`.

M0 defined the workload and froze the reference. M1 defines the versioned
interchange formats, exports every static level with SVG previews, and
captures the reference fixture matrix. M2 adds the Julia package
(`julia/PeggleSim`): a pinned environment, the deterministic math backend and
exact LÖVE 11.5 RNG, the level/state/checkpoint types, and cross-machine
parity tooling. M3 ports the full physics system and the engine shot pipeline,
validates byte-identical Lua-vs-Julia gameplay traces on the mustache level,
and adds the first cross-engine benchmark. Start with the
[wiki quickstart](wiki/quickstart.md).

## Layout

| Path | Purpose |
| --- | --- |
| `wiki/` | Project documentation: quickstart, context notes, benchmarks, audits, devlog ([layout](wiki/quickstart.md#wiki-layout)) |
| `reference/peggle_evolved/` | Byte-for-byte export of the frozen Lua reference revision (`reference/PIN.md`) |
| `harness/` | LÖVE harness: M0 candidate sweep, fixture capture, candidate search, M2 captures, M3 capture options |
| `julia/PeggleSim/` | Julia package: math/RNG/state foundation, checkpoint contract, full-physics shot engine, parity tools |
| `tools/` | Lua interchange tools: canonical JSON, level/config exporters, M2 captures |
| `schemas/` | Versioned interchange schemas and examples |
| `interchange/` | Generated level/config artifacts, SVG previews, manifest |
| `fixtures/` | Fixture catalog, expected records, gameplay traces, `rng/`, `checkpoints/`, `math_census/`, `mustache/` |
| `scripts/` | Julia benchmark-execution harness plus reference verification, export, fixture capture, previews, baseline runner, M2 captures, M3/M4 capture/compare/bench |
| `results/` | Baseline summaries, M2 benchmark/census/parity results, M3 benchmark/sweep reports; `results/raw/` is gitignored |

## Quickstart

Requirements: LÖVE 11.x, LuaJIT, Python 3 for analysis/SVG tooling, and a
display (`xvfb-run` for unattended runs). Verification, schema checks, and the
test suite need no display. M2/M3/M4 and the benchmark-execution harness need
Julia 1.12.6; the pinned environment is reproduced with
`julia --project=julia/PeggleSim -e 'using Pkg; Pkg.instantiate()'`.

```bash
make verify       # check the pinned reference against hashes
make export       # regenerate interchange artifacts and SVG previews
make fixtures     # capture reference fixture records (needs LÖVE/display)
make check        # interchange reproducibility + schema validation
make check-all    # check plus fixture re-capture comparison
make list         # list baseline workloads
make self-check   # grid identity + candidate determinism
make quick        # short sweep (every 20th index)
make baseline     # full-grid baseline (long)
make test         # run the reference test suite
make julia-test   # run the Julia package test suite
make julia-scripts-test # run the Julia benchmark-execution harness tests
make julia-parity # recompute the cross-machine parity manifest
make julia-bench  # checkpoint/reset benchmark
make m3-trace     # Julia snapshot traces for the base mustache fixtures
make m3-mustache  # 5-fixture Lua-vs-Julia trace control comparison
make m3-sweep     # stride-200 serial/parallel identity sweep
make m3-bench     # Lua-vs-Julia mustache benchmark + full-grid agreement
```

## The M0 workload

A candidate is one legal aim index from a ready-to-aim turn boundary with zero
additional launch delay. The grid has 1801 indices (0..1800), derived from the
reference snapping function in `src/systems/physics.lua`. The harness verifies
that enumerating indices reproduces the snapping function exactly before every
sweep.

Each candidate is evaluated from an identical fresh state (level setup, turn
reset). Timings are split into `init`, `reset`, `sim`, `extract`, and `output`
phases. See `wiki/context/reference.md`, `wiki/context/workload.md`, and
`wiki/context/inventory.md`. Measured baseline numbers and the campaign sizing
they imply are in `wiki/benchmarks/baseline-metrics.md`.

## The M1 interchange, previews, and fixtures

- `wiki/context/interchange.md` — the versioned level, config, checkpoint,
  action-log, result, and fixture formats, plus the static-level subset and
  motion-rejection rules.
- `wiki/context/fixtures.md` — the reference fixture matrix (grazes, shape
  boundaries, near-ties, overlap correction, clearing, fever, powers, style
  awards), capture protocol, and the assessment of the upstream "42-case
  matrix" that does not exist.
- `interchange/previews/` — standalone SVG previews for every static level,
  rendered without the game or Julia.

## The M2 math and state foundation

- `wiki/context/julia.md` — the pinned `julia/PeggleSim` package: DetMath
  backends (system libm on Linux, Julia Base fallback, experimental
  `core_math`), the exact LÖVE 11.5 RNG port, level/config/state types, and
  the ready-to-aim checkpoint contract.
- `wiki/audits/m2-math-census.md` — 15,794 math cases over recorded and
  boundary inputs; zero bit mismatches against the LuaJIT reference under
  system libm (`results/m2-math-census.json`).
- `wiki/audits/m2-rng-geometry.md` — RNG fixture coverage (initial color
  assignment and purple-queue rebuilds), byte-identical initialized geometry
  for all 9 checkpoints, and reset determinism without aliasing.
- `wiki/benchmarks/m2-checkpoint.md` — checkpoint/reset cost
  (`results/m2-checkpoint-bench.json`): the dense annular checkpoint restores
  in ~14 µs against the M0 ~82 ms per-candidate `setupLevel` rebuild.
- `results/parity/local.json` plus `scripts/compare_parity.sh` — the
  cross-machine parity manifest and first-difference comparison tool.

## The M3 full-physics shot engine

- `wiki/context/julia.md` — the M3 sources of `julia/PeggleSim`: event journal
  and commands, full `Physics.update` with swept CCD, bucket/fever/powers,
  style shots, ball state, slide inversion, the 26-phase `ShotEngine`
  pipeline, snapshots, and canonical traces (4,722 tests pass).
- `wiki/context/m3-mustache.md` — the 5-fixture mustache corpus, the capture
  and snapshot-comparison runbook, and the full-grid agreement.
- `wiki/benchmarks/m3-shot.md` — the Lua-vs-Julia mustache benchmark
  (`results/m3/bench-report.json`): 16.66 vs 32.56 candidates/s same-core
  (indicative 1.95×), 93.3 candidates/s at 12 threads, and the allocation
  table.
- `results/m3/` — combined benchmark report, Lua summaries, Julia sweeps,
  trace comparison, and the full-grid agreement report.
