# julia_clone — Quickstart

**julia_clone** is the simulation platform for
[Peggle Evolved](../../peggle_evolved): a portable Julia program that generates
levels, runs bot games, and measures level behavior at a scale the Lua game
cannot reach. The governing plan is
`../peggle_evolved/temp/julia_port/implementation-plan.md`; the goal notes are
in the same directory.

Start here, then follow the links below. The Lua game's own documentation is
in `../peggle_evolved/wiki/`.

## Current status

| Milestone | State |
| --- | --- |
| M0 — define the workload and select the reference | **Done** |
| M1 — interchange, fixtures, level previews | **Done** |
| M2 — math and state foundations (first Julia code) | **Done** |
| M3 — full-physics shot engine, mustache traces, first benchmark | **Done** |
| M4 — full static-level shot behavior + main performance gate | **Done** — correctness breadth and strict zero-allocation gate passed; second-host corpus qualification recorded; M4 closed |

The repository contains the frozen Lua reference, the baseline sweep harness,
the versioned interchange artifacts and fixtures, the M2/M3 Julia package
(`julia/PeggleSim`) with its pinned math/RNG/state foundation and full
physics/engine port, the mustache trace corpus, and the documentation. The
measured M3 results are in `wiki/benchmarks/m3-shot.md`. M4 correctness
breadth is validated on the pinned corpus
(`wiki/context/m4-validation.md`), and the M4 performance gate — the
zero-allocation criterion plus the seven-workload benchmark against Lua — is in
`wiki/benchmarks/m4-perf.md`. M4 is **closed** as of session 3: the gate is
strict zero on all five allocation probes, the benchmark was re-run, and the
validated corpus is byte-identical on a second Linux host. The cross-platform
runbook's macOS ARM64 and Windows x86-64 rows remain uncollected and are not
claimed.

## Requirements

- LuaJIT and LÖVE 11.x for the baseline harness (LÖVE needs a display, or
  `xvfb-run` on headless servers; `scripts/love.sh` handles both).
- Python 3 for the remaining analysis/report tools (SVG previews, schema
  validation, comparisons), and the peak-RSS fallback when GNU time is
  unavailable. Benchmark orchestration is Julia.
- Julia 1.12.6 for the `julia/PeggleSim` package (M2/M3/M4) and for the
  benchmark-execution harness; the pinned environment is reproduced with
  `julia --project=julia/PeggleSim -e 'using Pkg; Pkg.instantiate()'`.
  The Lua checks do not need Julia.
- `make verify`, `make check`, and `make test` need neither a display nor
  LÖVE (fixture capture does).

## Common commands

```bash
make verify       # verify the pinned reference against reference/files.sha256
make export       # regenerate interchange artifacts and SVG previews
make fixtures     # capture reference fixture records (needs LÖVE/display)
make fixture-list # list the reference fixture catalog
make check        # interchange reproducibility + schema validation
make check-all    # check plus fixture re-capture and corpus-integrity tests
make list         # list baseline workloads
make self-check   # grid identity + candidate-evaluation determinism
make quick        # short sweep (every 20th aim index)
make baseline     # full-grid baseline (long; writes results/ and results/raw/)
make test         # run the pinned reference test suite in a scratch copy
```

M2 Julia targets:

```bash
make julia-test          # run the Julia package test suite (pinned env)
make julia-scripts-test  # run the Julia benchmark-execution harness tests
make julia-parity        # recompute results/parity/local.json
make julia-bench         # checkpoint/reset benchmark (writing results/)
make capture-m2          # capture RNG/peg-color/checkpoint fixtures (needs LÖVE)
make capture-m2-check    # re-capture the M2 fixtures and require equality
make math-census         # capture the math census fixture and Julia summary
make math-census-check   # re-capture the math census fixture and compare
make wpd-math            # CORE-MATH vs system libm vs MPFR oracle (WP-D)
make wpd-state           # Lua core_math state capture + Julia comparison (WP-D)
make wpd-parity          # experimental CORE-MATH parity manifest (WP-D)
make wpd-trace           # gameplay traces/candidate samples, single host (WP-E)
make wpd-perf            # math/checkpoint/sweep performance comparison (WP-F)
```

M3 Julia targets:

```bash
make m3-trace            # Julia snapshot traces for the base mustache fixtures
make m3-mustache         # 5-fixture Lua-vs-Julia trace control comparison
make m3-sweep            # stride-200 serial/parallel identity sweep
make m3-bench            # Lua-vs-Julia mustache benchmark + full-grid agreement
```

M4 Julia targets:

```bash
make m4-parity           # full M4 correctness-breadth run (replay, sweeps, threads, scenarios)
make m4-replay           # fixture replay + trace parity into results/m4/
make m4-bench            # M4 seven-workload benchmark (Lua + Julia, latency/throughput/alloc/RSS)
scripts/m4_allocation.jl --workload all --out results/m4/allocation-profile.json  # strict-zero allocation gate
```

The `wpd-*` targets are the experimental CORE-MATH comparison; their outputs
and acceptance records live under `tmp/core-math/` (see
`tmp/core-math/wpc-acceptance.md`, `wpd-acceptance.md`,
`wpef-acceptance.md`). They do not change the historical fixtures or the
default `system_libm` backend.

Benchmark execution harness (Julia):

```bash
julia --project=julia/PeggleSim scripts/run_campaign_benchmark.jl --help
julia --project=julia/PeggleSim scripts/run_campaign_benchmark.jl --allow-dirty \
  --worker-counts 1 --games 1 --repeats 1 --warmup none \
  --benchmarks-dir tmp/benchmark-smoke
julia --project=julia/PeggleSim scripts/sync_campaign_config.jl --check
julia --project=julia/PeggleSim scripts/bench_process.jl --out tmp/m.json --label smoke -- julia -e 'println("ok")'
make julia-scripts-test
```

See [benchmark result storage](context/benchmark-results.md) for the run
contract, validation rules, and archival limitations.

Focused commands:

```bash
scripts/run_baseline.sh --workload circles_small --stride 50
scripts/render_summary.py results/RUN.summary.json
scripts/verify_reference.sh
scripts/export_interchange.sh
scripts/capture_fixtures.sh --id slide_rail_graze
scripts/validate_interchange.py
scripts/compare_m3_mustache.sh --julia-only
scripts/bench_m3.sh --stride 20 --threads "1 2 4"
```

## Ribbon bot campaign

The primary workload evaluates all 1,801 aim indices at every turn and runs
eight independent **1v1 matches** on the same ribbon realization. Solo remains
an explicit alternative. The current Lua config is copied into `campaigns/ribbon/`.

```bash
julia --project=julia/PeggleSim -t 8 julia/PeggleSim/bin/campaign.jl --worker-counts 1,2,4,8 --repeats 3
```

This warms the simulation/output paths, measures the same eight matches at
1/2/4/8 workers, verifies identical histories, and saves `results/campaign/1v1/`.
See [workflow and contracts](context/bot-campaign.md) and
[1v1 scaling baseline](benchmarks/1v1-campaign.md).
See [benchmark result storage and validation](context/benchmark-results.md) for
versioned run records, comparison rules, and archival limitations.
See [campaign diagnostics](context/campaign-diagnostics.md) for warmed CPU and
allocation profiles, GC totals, isolated memory measurements and paired phase-timer comparisons.

## Repository layout

| Path | Purpose |
| --- | --- |
| `wiki/` | Permanent project documentation (this directory; see below) |
| `reference/peggle_evolved/` | Byte-for-byte export of the frozen Lua revision; **read-only** |
| `reference/PIN.md` | Reference revision, tree hash, config hash, manifest rules |
| `reference/files.sha256` | Per-file hash manifest of the pinned tree |
| `harness/` | LÖVE sweep harness: candidate grid, phase timings, fixture capture, search, additive M3 capture options |
| `julia/PeggleSim/` | Julia package: pinned math/RNG/state foundation, checkpoint contract, full-physics shot engine, parity tools |
| `tools/` | Lua interchange tools: canonical JSON, level/config exporters, M2 captures |
| `schemas/` | Versioned interchange schemas and examples |
| `interchange/` | Generated level/config artifacts, SVG previews, manifest |
| `fixtures/` | Fixture catalog, expected records, gameplay traces, `rng/`, `checkpoints/`, `math_census/`, `mustache/` |
| `scripts/` | Julia benchmark-execution harness (`run_campaign_benchmark.jl`, `bench_process.jl`, `sync_campaign_config.jl`, `benchmark/`), plus verification, export, fixture capture, previews, baseline runner, M2 captures, parity compare, M3/M4 capture/compare/bench |
| `results/` | Baseline summary JSON (committed); `results/parity/`, M2 benchmark/census summaries, M3 benchmark/sweep reports; `results/raw/` per-candidate JSONL (gitignored) |
| `tmp/` | Local scratch (gitignored) |

## Wiki layout

All permanent documentation lives under `wiki/`. Ephemeral plans, scratch
notes, and investigation reports go to `tmp/` locally or to
`../peggle_evolved/temp/` when they belong to the Lua project. The layout
mirrors `../peggle_evolved/wiki/` so material can move between the projects.

| Path | Purpose | Status |
| --- | --- | --- |
| `wiki/quickstart.md` | Entry point and this layout description | current |
| `wiki/context/` | Durable technical notes that later work depends on | current |
| `wiki/context/reference.md` | Frozen revision, config, candidate grid, decision boundary, action/result schemas | current |
| `wiki/context/workload.md` | Representative workloads, seeds, phase definitions, measurement protocol, campaign sizing | current |
| `wiki/context/optimization-strategy.md` | Italian discussion summary: memory layout, shared geometry, CPU caches, threading, SIMD, and throughput per euro | exploratory |
| `wiki/context/prepared-checkpoint.md` | Prepared candidate resets, compact geometry caches, parity gates and comparison protocol | current |
| `wiki/benchmarks/prepared-checkpoint.md` | Deathstar three-variant reset/geometry experiment, measured allocation and throughput | current |
| `wiki/context/inventory.md` | Inventory of the existing Lua corpus, tools, and plumbing | current |
| `wiki/context/interchange.md` | Versioned level/config/checkpoint/action/result formats, static subset, verification | current |
| `wiki/context/fixtures.md` | Reference fixture matrix, capture protocol, the 42-case assessment | current |
| `wiki/context/julia.md` | M2/M3 Julia package: pinned env, DetMath backends, RNG, state, checkpoint contract, shot engine, traces | current |
| `wiki/context/m3-mustache.md` | M3 mustache corpus: 5 trace fixtures, capture and comparison runbook, full-grid agreement | current |
| `wiki/context/m4-validation.md` | M4 correctness-breadth validation: corpus, method, results, divider fix, scenario decision | current |
| `wiki/context/julia-benchmark-harness.md` | Julia benchmark-execution harness: scope, files, commands, parity evidence, remaining Python | current |
| `wiki/context/ribbon-waves.md` | Screenshot-reconstructed `ribbon_waves` level: extraction, Lua level, 3-shot trace corpus, mask checker, Julia tests | current |
| `wiki/benchmarks/` | Measured performance and parity results | current |
| `wiki/benchmarks/baseline-metrics.md` | M0 Lua candidate-sweep baseline and continuing-metric protocol | current |
| `wiki/benchmarks/m2-checkpoint.md` | M2 checkpoint/reset benchmark and M0 init comparison | current |
| `wiki/benchmarks/m3-shot.md` | M3 Lua-vs-Julia mustache shot benchmark: same-core, thread scaling, allocations | current |
| `wiki/devlog/` | Dated engineering log, one file per date (`YYYY-MM-DD.md`) | current |
| `wiki/decisions/` | ADRs for port decisions (math contract, storage, scheduler, ...) | current |
| `wiki/decisions/0001-math-backend.md` | Math backend decision: system libm default, Julia Base fallback, experimental `core_math` | current |
| `wiki/audits/` | Correctness audits (math census, determinism, RNG) | current |
| `wiki/audits/m2-math-census.md` | M2 math census: 15,794 cases, 0 system-libm mismatches | current |
| `wiki/audits/m2-rng-geometry.md` | M2 RNG, initialized geometry, reset determinism audit | current |
| `wiki/failures/` | Post-mortems for notable bugs and campaign failures | reserved |
| `wiki/templates/` | Document templates (devlog, ADR) | current |

Conventions:

- Use the templates in `wiki/templates/` for new devlogs and ADRs.
- A devlog entry is appended to the current date's file; do not rewrite past
  entries except to fix factual errors.
- Keep `wiki/context/` notes current when a milestone changes the reference,
  the workload, or the measurement protocol.
- Record numeric results as files under `results/` and link them from the
  relevant wiki page; do not paste large tables into the devlog.

## Reference rules

- The pinned revision in `reference/PIN.md` is the authoritative Lua behavior.
  `reference/peggle_evolved/` is vendored and read-only; the harness may
  monkeypatch at runtime but never edits it.
- Run `make verify` before and after any measurement session. The manifest
  covers 133 files; a fresh clone must verify clean.
- Advancing the pin requires re-capturing baselines, fixtures, and golden
  outputs. Uncommitted working-tree edits in the Lua repository are never
  part of the pin.
- The candidate grid is derived from `Physics.getSnappedAimAngle` and
  verified at harness startup; never substitute a separate angle loop.

## Documentation map

| Question | Read |
| --- | --- |
| What is frozen, and what is a legal action? | `wiki/context/reference.md` |
| What exactly is measured? | `wiki/context/workload.md` |
| What already exists in Lua? | `wiki/context/inventory.md` |
| What do the interchange artifacts contain? | `wiki/context/interchange.md` |
| Which reference fixtures exist and why? | `wiki/context/fixtures.md` |
| How is the Julia side built? | `wiki/context/julia.md` |
| How is a benchmark run executed and validated now? | `wiki/context/julia-benchmark-harness.md`, `wiki/context/benchmark-results.md` |
| Which M3 fixtures exist, and how are they compared? | `wiki/context/m3-mustache.md` |
| What M4 validated, and how it was closed? | `wiki/context/m4-validation.md` |
| How do I collect the macOS/Windows qualification evidence? | `wiki/context/cross-platform-qualification.md` |
| How fast is Lua today? | `wiki/benchmarks/baseline-metrics.md` |
| How fast is the M2 checkpoint/reset? | `wiki/benchmarks/m2-checkpoint.md` |
| How fast is the M3 shot engine, and is it bit-identical to Lua? | `wiki/benchmarks/m3-shot.md` |
| Is the Julia math/RNG bit-identical? | `wiki/audits/m2-math-census.md`, `wiki/audits/m2-rng-geometry.md` |
| What happened on a given day? | `wiki/devlog/` |
| Why was a port decision made? | `wiki/decisions/` |
| What is the overall plan? | `../peggle_evolved/temp/julia_port/implementation-plan.md` |
| How does the Lua game work? | `../peggle_evolved/wiki/quickstart.md` |
