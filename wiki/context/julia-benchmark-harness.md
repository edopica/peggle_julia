# Julia benchmark-execution harness

**Status:** current (2026-10-26). The benchmark-execution path is Julia, with
a small Python 3 resource-measurement helper when GNU time is unavailable.
Python also remains for analysis, reporting, validation CLIs, and diagnostics.

## Why

The repository's benchmark runner, per-process measurement wrapper, and config
pre-check were Python. This port replaces that execution path with Julia so a
benchmark can be run, validated, archived, and indexed without a Python
interpreter. Per-process RSS measurement needs either GNU time or Python 3.
The scope was deliberately limited to the execution harness; porting every
analysis script was not attempted.

## Layout

| Path | Role |
| --- | --- |
| `scripts/run_campaign_benchmark.jl` | Benchmark orchestrator: reserves a run, captures host/source provenance, runs pre-checks, executes `julia/PeggleSim/bin/campaign.jl`, transforms raw output to the versioned schemas, archives evidence, writes the manifest/README, validates, publishes, reindexes, and validates again. |
| `scripts/bench_process.jl` | Runs one benchmark child and records wall time and peak RSS (GNU `time -v` when available, otherwise a Python 3 helper collecting `getrusage(RUSAGE_CHILDREN)`); forwards stdio and the child exit code, mapping signal termination to `128 + signal`. |
| `scripts/bench_process_resource.py` | Small fallback launcher: spawns the workload after Python has exec'd, so resource accounting excludes Julia's inherited footprint. Requires only Python 3 standard-library modules. |
| `scripts/sync_campaign_config.jl` | Exports the current Lua config through `tools/export_config.lua`, writes the campaign inputs and provenance, and supports byte-exact `--check`. |
| `scripts/benchmark/BenchmarkHarness.jl` | Module that includes the shared implementation. |
| `scripts/benchmark/schema.jl` | Schema constants, canonical gameplay history, SHA-256, CSV, archive, manifest/checks I/O, README generation, harness fingerprint. |
| `scripts/benchmark/harness.jl` | Git provenance, run reservation, exclusive archive publication, source snapshots, host metadata, RSS extraction, harness manifest. |
| `scripts/benchmark/validator.jl` | `BenchmarkValidator` / `validate!`: the retained-evidence and cross-table validator used by the runner. |
| `scripts/benchmark/index.jl` | `generate_index`: deterministic `index.csv` generation and README refresh. |
| `scripts/tests/test_*.jl` | Julia tests for the harness, validator, index, runner CLI, and process wrapper. |
| `scripts/tests/integration_runner.jl` | Opt-in end-to-end smoke: one real match, full publish/index/validate path (~30 s). |

The former `scripts/run_campaign_benchmark.py`, `scripts/bench_process.py`,
`scripts/sync_campaign_config.py`, and
`scripts/tests/test_benchmark_runner.py` were removed.

## Commands

```bash
# Harness contracts (including child-process measurement and input validation)
make julia-scripts-test

# One real end-to-end run in ignored scratch storage
make julia-scripts-integration

# Run a benchmark (same flags as the former Python runner)
julia --project=julia/PeggleSim scripts/run_campaign_benchmark.jl --help
julia --project=julia/PeggleSim scripts/run_campaign_benchmark.jl \
  --allow-dirty --worker-counts 1 --games 1 --repeats 1 --warmup none \
  --benchmarks-dir tmp/benchmark-smoke

# Measurement wrapper
julia --project=julia/PeggleSim scripts/bench_process.jl \
  --out tmp/m.json --label smoke -- julia -e 'println("ok")'
```

`scripts/bench_m4.sh` calls `scripts/bench_process.jl`; its inline JSON helpers
and the report generator remain Python analysis glue.

The fallback must collect child usage inside the small helper. Reading
`RUSAGE_CHILDREN` in Julia includes the launcher's inherited pre-exec memory
and can report hundreds of MiB even for `/bin/true`. The fallback records
`method: python_resource_ru_maxrss`; it still includes the small helper footprint
inherited by the workload. Earlier `julia_resource_ru_maxrss` records may be
inflated and should be remeasured before comparing memory results. If Python 3
is unavailable, the fallback fails with nonzero status and null RSS.

## Behaviour and evidence

Verified against the committed benchmark runs and the Python implementation:

- `generate_run_readme` reproduces both committed `README.md` files
  byte-for-byte from their manifests and CSV tables.
- `read_csv_rows` → `write_csv_rows` round-trips both committed `trials.csv`
  and `matches.csv` byte-for-byte.
- Canonical gameplay history regenerates the exact committed bytes and hash.
- The committed harness fingerprints are reproduced from their
  `source.harness_files` manifests.
- The Julia validator accepts both committed runs; mutation tests match the
  Python validator's verdicts and error counts across the Python regression
  cases.
- A full Julia-run smoke (`julia-smoke-03`) was accepted by the Python
  validator (`scripts/validate_benchmark.py`) with the same index, and the
  opt-in Julia integration test passes 15/15 checks.

## Known byte-level differences

The JSON and archive surfaces are semantically equivalent, but not always
byte-identical to the former Python output:

- Pretty JSON object key order follows Julia `Dict` iteration rather than
  Python insertion order, and non-ASCII text is emitted unescaped. Values parse
  identically and the validator is JSON-semantic.
- `tar.gz` members have the requested names/order/content, but archive bytes
  (mtimes, ownership, gzip framing) differ; archive SHA is computed from the
  produced file.
- CLI parsing accepts full flag names and `--flag=value`, but not argparse
  prefix abbreviations (`--work`).
- `CsvTable` cannot represent Python's `None` restkey; short rows are still
  reported as malformed, while extra data-row values beyond the header are
  ignored.

## Remaining Python (out of scope)

`scripts/benchmark_schema.py`, `scripts/validate_benchmark.py`,
`scripts/generate_benchmark_index.py`, `scripts/compare_benchmarks.py`,
`scripts/bench_m4_report.py`, `scripts/run_campaign_diagnostics.py`,
`scripts/import_legacy_benchmark.py`, the SVG/level tools, and the notebook
generator remain Python. The benchmark-storage helpers used by the importer and
diagnostics were moved into `scripts/benchmark_schema.py` so those analysis
paths keep working after the execution-script removal.
