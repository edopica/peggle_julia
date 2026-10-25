# Benchmark results, profiling, and optimization plan

Date: 2026-10-25. Status: proposed implementation plan.

## Objective and recommended sequence

Make benchmark results reproducible, compact, and easy to compare; identify
the actual simulation bottlenecks; then choose an optimization supported by
measurements. The sequence is:

1. Standardize result storage and provenance; migrate the existing baseline.
2. Improve local CPU, allocation, GC, and memory diagnostics.
3. Add a larger fixed workload to distinguish batch latency from throughput.
4. Repeat the qualified benchmark on deathstar; use Bocconi when justified.
5. Select and validate the first optimization, potentially SIMD filtering.

Results management comes first so every subsequent experiment uses the same
recording and comparison conventions. This document describes future work;
it does not claim that those changes or experiments have already been done.

## Starting evidence and limits

The baseline in commit `5de45c742ace599e2024d0751c851d189b9ddfe9`
measures eight seeded ribbon 1v1 matches at 1/2/4/8 active workers in one
eight-thread Julia process. It evaluates 142,279 candidates over 79 turns,
with three repetitions per setting. Median batch time falls from 148.948 s
to 39.234 s. Full histories agree across measured trials and warmups.

The warmup, completion checks, fixed inputs, and explicit timing boundaries
make this a credible warm, fixed-workload baseline. Its limitations are:

- About 99% of instrumented phase time is called simulation, without enough
  detail to identify the profitable kernel or separate GC effects.
- RSS is sampled after output; peak RSS includes warmup and every worker
  count. Neither establishes incremental memory per worker.
- Eight unequal matches leave workers idle as matches finish. With unchanged
  sequential match durations and the existing strided assignments, estimated
  imbalance-only speedup limits are 1.99×, 3.58×, and 5.51× for 2/4/8 workers,
  versus measured 1.95×, 3.22×, and 3.80×. These are scheduling estimates,
  not predictions of real hardware performance.
- The six-core laptop introduces SMT and frequency effects. Existing data
  cannot isolate them from cache effects, scheduling, or GC.
- Matches/hour describes repeated small batches, not a continuously occupied
  pool. One level realization and eight seeds do not establish general game
  performance or a statistically qualified balance study.
- Repeated full histories added roughly 400,000 lines in the latest commit.

References: [baseline report](../wiki/benchmarks/1v1-campaign.md),
[campaign contract](../wiki/context/bot-campaign.md), and
[optimization discussion](../wiki/context/optimization-strategy.md).

## Phase 1 — Establish a result and provenance standard

### Deliverables

Implement a versioned result format, validator, legacy importer, and summary
generator. Use CSV for tabular measurements and JSON for nested provenance:

```text
results/benchmarks/
  index.csv
  runs/<run-id>/
    manifest.json
    trials.csv
    matches.csv
    checks.json
    README.md
```

- `index.csv`: one row per run, including benchmark, UTC timestamp, host ID,
  source revision, workload ID, protocol version, status, and manifest path.
  Generate it from manifests so it cannot become a second source of truth.
- `manifest.json`: identities, command and options, environment, measurement
  definitions, artifact references, and run status.
- `trials.csv`: one row per trial and worker count, with wall seconds,
  simulation/output seconds, completions, candidates, throughput, latency
  summaries, allocated bytes, GC counts/time, and memory measurements.
- `matches.csv`: one row per trial/match, with seed identity, worker assignment,
  timing, turns, completion reason, and canonical history hash. Keep detailed
  decision records in artifacts rather than duplicating them in these tables.
- `checks.json`: validation outcomes, commands, evidence hashes, and artifact
  references. Distinguish passed, failed, and not collected.
- `README.md`: short interpretation, limitations, and compared run IDs.
  Generate numerical tables from CSV, avoiding manually maintained copies.

Use explicit units in column names, stable identifiers, documented CSV quoting,
and empty values for unavailable metrics. Zero means a measured zero. Include
run/trial IDs in tables so concatenation remains unambiguous. Reject duplicate
IDs, malformed rows, missing required evidence, and incompatible schema versions.

### Provenance requirements

Record these separately; none substitutes for the others:

| Identity | Purpose |
| --- | --- |
| Source Git revision and dirty status | Identify simulator and harness checkout |
| Harness entry point and source fingerprint | Identify the actual measurement implementation |
| Measurement-protocol version | Identify timing boundaries, warmup, scheduling, and measurement semantics |
| Result-schema version | Identify how stored records are interpreted |
| Workload ID and input hashes | Identify level, config, policy, seeds, grid, and completion limits |
| Runtime/environment | Identify Julia, dependency manifest, math backend, CPU target, OS, and hardware |

Define the harness fingerprint as a deterministic manifest of relevant paths
and file-content hashes, including helpers and the simulator source identity;
hashing only the CLI would miss changes in `src/campaign.jl`. Preserve exact
commands, thread-pool sizes, active workers, trial order, warmup policy, CPU
affinity, topology, governor, scheduler allocation, and known contention.

Official new runs should measure a committed source tree. Commit results
afterward, pointing back to that source commit, avoiding a circular dependency
between the measured revision and the results commit. Exploratory dirty runs
must retain a patch or source snapshot, including relevant untracked files,
with a checksum; a dirty flag alone is insufficient.

### Artifact retention and migration

Keep compact manifests, CSV, checks, and interpretations in Git. Archive full
histories, profiles, and logs in compressed bundles outside ordinary Git blobs.
Choose a durable artifact location before removing any existing evidence;
record URI, SHA-256, size, format, and retrieval instructions in the manifest.
Local scratch paths are not durable archival references.

Store one canonical gameplay history per distinct workload/result and let
trials reference its hash. Separate gameplay identity from timing and other
nondeterministic fields. Preserve trial-specific diagnostics and every differing
history on failure. Define canonicalization and its version explicitly.

Import the existing baseline without rerunning it. Preserve original files or
verified archived equivalents, commands, hashes, and known provenance gaps.
Record the importer revision separately from the historical measured revision;
do not assign newly measured or invented fields to legacy runs. Inspect the
original recorded dirty state instead of assuming the results commit was the
exact source tree used during measurement. No Git history rewrite is needed.

Use unique run IDs, for example UTC timestamp plus host and a collision-resistant
suffix. Finalized runs are immutable. Interrupted or failed attempts remain
explicitly marked, and retries get new IDs. Never overwrite a shared
`baseline.json`. Write into a staging directory and finalize after validation.

### Exit criteria

- The imported baseline reproduces all published trial metrics and history hashes.
- A fresh run emits valid records and can be located by revision and workload.
- Artifacts can be retrieved and checksum-verified.
- Comparison tooling identifies both run IDs and checks compatibility. It
  labels intentional differences such as host or source revision instead of
  silently pooling incompatible workloads or measurement protocols.

## Phase 2 — Improve local diagnostics without changing simulation behavior

### Work

1. Add a separate warmed CPU sampling run, initially at one worker. Attribute
   cost to broad-phase filtering, precise collision tests, engine updates,
   scoring/events, and GC where the profiler permits. Include early dense-board
   and later sparse-board decisions, preferably through the complete campaign.
2. Record campaign allocation bytes, GC collection counts, and GC time. Use
   separate diagnostic runs for allocation attribution; previous strict-zero
   shot probes do not prove that a complete campaign allocates nothing.
3. Run memory measurements in fresh processes for each active-worker setting.
   Warm only the tested setting and record loaded, warmed, and post-campaign
   RSS. Sample campaign RSS if needed and label process-lifetime high-water
   marks separately: restarting isolates settings but does not remove warmup
   from a process peak. Record Julia and GC thread counts consistently.
4. Measure phase instrumentation enabled versus disabled to quantify overhead.
   Keep profiling and detailed counters out of headline throughput trials.
5. Retain the original end-to-end boundary, including verification/output, and
   report its components separately. Keep startup, load, and compilation costs
   separate and available for short-campaign cost analysis.

Use repeated runs and balanced execution order. Preserve every raw trial;
report spread alongside medians. Start with the existing three repetitions
for continuity, increasing paired repetitions when evaluating small gains.
Do not treat individual candidates or repeated identical seeds as independent
replications of an optimization experiment.

### Exit criteria

A report identifies the leading simulation costs, allocation sources and GC
contribution, memory behavior by worker count, and instrumentation overhead.
Gameplay hashes remain identical. Any changed measurement boundary receives a
new protocol version rather than silently replacing historical semantics.

## Phase 3 — Separate batch latency from sustained throughput

### Work

Retain the original eight-match workload as the fixed regression and batch
latency benchmark. Add a second, explicitly versioned workload with a fixed,
larger seed set and several matches per maximum tested worker. Freeze the same
set across hosts; do not increase the work on only the faster machine when
claiming direct speedup. Select its size with a pilot before freezing it.

Measure worker busy intervals, task assignment, per-match durations, total
makespan, and completion tail. Distinguish aggregate worker wall durations
from actual CPU time and campaign wall time. Report estimated load imbalance
from sequential match costs alongside observed concurrency slowdown.

Include 1/2/4/6/8 workers locally and, where useful, a separate SMT experiment.
Six workers on the original eight-match batch is not a clean six-core scaling
test because its assignments are uneven. Record topology and affinity; active
worker count alone does not establish physical-core placement.

First measure the existing scheduler. If a shared match queue or persistent
engine reuse is justified, evaluate it as an explicit implementation variant
with identical workload and histories. Avoid combining scheduler changes with
the initial measurement-format migration or a physics optimization.

### Exit criteria

The report separately describes small-batch latency and larger-batch throughput,
shows how much worker capacity is lost to the tail, and explains whether the
larger batch is long enough to approximate sustained operation. All matches
complete; truncations remain failures, not useful throughput.

## Phase 4 — Qualify and compare remote hosts

### Deathstar first

Deathstar was previously recorded as a Threadripper 2990WX with 32 physical
cores and 64 logical CPUs. Verify current topology, available resources, Julia,
dependencies, CPU target, math backend, and contention before measuring.

Run the unchanged eight-match benchmark for continuity and the larger frozen
workload for scaling. Begin with counts comparable to the laptop, then extend
within available resources. Separate physical-core and SMT placement and record
NUMA placement when applicable. Preserve the same source/workload/protocol
identities across hosts, with environment differences explicit.

Verify reference/input integrity before and after measurements and compare
canonical gameplay histories across hosts. Previous cross-host qualification
is useful evidence but does not substitute for checking the new campaign.
If histories differ, investigate correctness before publishing a performance
comparison for supposedly identical work.

### Bocconi when it answers an additional question

Use Bocconi after deathstar if another CPU architecture, deployment decision,
or unresolved scaling question warrants it. Inspect the current allocation
rules and node hardware; old notes are not proof of present availability.
Run Julia warmup and measurement on allocated compute nodes, not the login
node, and record the exact CPU allocation and binding. Existing remote notes
contain Flux/thesis-specific examples; verify applicable tooling instead of
copying unrelated commands into this project's runbook.

### Exit criteria

At least one second host produces retrievable, validated results with matching
gameplay. The comparison distinguishes single-worker performance, batch tails,
multiworker throughput, and memory. Attribute causes only where measurements
support them. Throughput per euro is optional and requires actual applicable
costs, not CPU-family assumptions.

## Phase 5 — Choose and validate the first optimization

Use the profile to rank candidates: less repeated work, scalar filtering/layout
changes, a spatial index, scheduler improvements, or SIMD filtering. Do not
assume that the simulation phase percentage is the SIMD-eligible percentage.

For a possible SIMD broad-phase filter:

1. Measure time share, call volume, and rejection rate in separate diagnostics.
2. Estimate the end-to-end ceiling. For a fraction `f` accelerated by `s`,
   ideal speedup is `1 / ((1 - f) + f / s)`, before additional overhead.
   If filtering is 20% and improves fourfold, total speedup is only about 1.18×.
3. Establish a scalar version of any new data layout before adding SIMD, so
   layout benefits and vectorization benefits can be measured separately.
4. Review the documented prohibition on `@simd` and related numerical
   transformations explicitly before changing that contract. Preserve peg
   order, tolerances, graze cases, rounding behavior, and collision ties;
   reject no true collision. Do not introduce reassociation or FMA silently.
5. Compare filter decisions and candidate outcomes against the scalar oracle,
   run relevant parity suites, and require identical complete campaign histories.
   Inspect generated code to confirm intended vectorization and arithmetic.
6. Run paired baseline/candidate trials on the local host and deathstar, using
   the same workload and protocol. Report kernel and whole-campaign effects,
   allocations, memory, and any architecture-specific regressions.

Choose acceptance thresholds after observing baseline variability and before
evaluating the candidate. Retain an optimization only if its end-to-end benefit
is repeatable, correctness holds, and added complexity is justified. A negative
experiment is still a finalized result with a run ID and interpretation.

## Implementation checkpoints

Suggested reviewable changes, in order:

1. Result schema, provenance specification, validator, and legacy importer.
2. Runner output integration, artifact retention, and generated summaries/index.
3. CPU/allocation/GC/memory diagnostics and instrumentation-overhead comparison.
4. Larger fixed workload and worker-utilization measurements.
5. Remote runbook and deathstar evidence; Bocconi if justified.
6. One selected optimization with paired measurements and parity evidence.

Do not rerun the old baseline merely to migrate its storage format. Do not
remove raw evidence before verifying its replacement archive. Keep numerical
claims linked to immutable runs and keep permanent methodological documentation
in the wiki once the implementation stabilizes.
