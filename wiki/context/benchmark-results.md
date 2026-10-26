# Benchmark result storage

Campaign measurements use `results/benchmarks/runs/<run-id>/`, containing a
manifest, trial and match CSV tables, validation checks, and a generated README.
The manifest identifies the measured source separately from the result schema,
measurement protocol, workload inputs, runtime, and host.

Run IDs identify immutable attempts. A retry must use a new ID; existing staged
runs, finalized runs, and archives must not be overwritten. Failed and
interrupted attempts retain their diagnostics. The index is derived from
manifests and is replaced only after successful generation.

## Validation and comparison

From the repository root:

```bash
make julia-scripts-test
python3 -m unittest discover -s scripts/tests -p 'test_benchmark_*.py' -v
python3 scripts/validate_benchmark.py results/benchmarks/runs/RUN_ID --index results/benchmarks/index.csv
python3 scripts/compare_benchmarks.py BASELINE_RUN_ID CANDIDATE_RUN_ID
python3 scripts/generate_benchmark_index.py --no-readme
```

The benchmark execution harness is Julia (`scripts/run_campaign_benchmark.jl`,
`scripts/bench_process.jl`, `scripts/sync_campaign_config.jl`); the remaining
`python3` commands above are analysis/validation tooling, not part of the
execution path. The Julia harness has its own validator and index generator.

The runner requires a committed clean checkout by default. An exploratory run
can use `--allow-dirty`; it retains a source snapshot with binary Git changes,
relevant untracked files, a file hash inventory, and restoration instructions.
For example, a short integration check in ignored scratch storage is:

```bash
julia --project=julia/PeggleSim scripts/run_campaign_benchmark.jl --allow-dirty \
  --worker-counts 1 --games 1 --repeats 1 --warmup none \
  --workload-id ribbon_1v1_1match_1801aim \
  --benchmarks-dir tmp/benchmark-smoke
```

This checks output integration. Its cold timing is not a warmed performance
baseline. Fingerprint version 2 includes simulator source and benchmark helpers;
legacy fingerprints retain the historical file list.

Completed records require supported schema versions, successful required checks
with verifiable evidence, unique trial/match identities, and table references
consistent with the canonical gameplay artifact. Failed and interrupted records
may be incomplete and must retain their explicit status.

Comparison checks workload inputs and measurement semantics, including warmup,
before reporting performance ratios. Host, source, and runtime differences remain
visible. A matching workload label alone does not establish compatibility.
Speedup and efficiency require a measured one-worker baseline. Reports show
`N/A` when it is absent and use the actual recorded repetition counts.

CSV files use Python's `csv` minimal quoting, a header row, UTF-8, and newline
record separators. Units are explicit in column names. Empty optional metrics
mean unavailable; zero means measured zero. Match `gameplay_sha256` values refer
to the canonical campaign history shared by that trial, rather than a separate
per-match history file. Gameplay canonicalization uses the project's sorted-key,
17-significant-digit JSON encoding; it must not be interpreted as general RFC
8785 conformance.

## Historical evidence and retention

The imported baseline preserves the historical dirty state and original
measurements. Source omissions in old archives cannot be repaired retrospectively
by attaching today's source. The small verification run used no warmup and is
not a qualified throughput comparison against the full warmed baseline.

Existing compressed archives remain in `results/benchmarks/artifacts/`. They are
currently ordinary Git blobs. **External durable archival is not yet configured.**
A future destination, retrieval procedure, URI, checksum, and size must be recorded and
verified before removing any existing evidence. Local scratch paths do not
satisfy that requirement. The fixes to validation and provenance do not establish
external retention retroactively. External archival is deferred until the NAS or
another durable destination is configured.

The legacy import and published measurements must not be rerun merely to repair
their storage format. Derived README tables may be regenerated to correct
presentation errors without changing measurements or historical provenance.
