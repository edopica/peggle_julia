# Campaign diagnostics

Phase 2 of `temp/benchmark-improvement-plan.md` adds a separate diagnostic
protocol, `campaign-diagnostics/1`. It does not replace the historical
throughput benchmark or change physics, selection, RNG, scheduling, or output
verification. `run_campaign` keeps phase instrumentation enabled by default;
`phase_instrumentation=false` specializes away candidate and phase clocks.
Disabled phase measurements are `nothing`, not measured zeros. Match setup and
decision latency clocks remain enabled in both variants.

From the repository root:

```bash
python3 scripts/run_campaign_diagnostics.py --allow-dirty
```

Omit `--allow-dirty` for official runs on committed source. Exploratory runs
retain a source snapshot, binary patch, file hash inventory, revision and dirty
state. Pass `--expected-gameplay-sha256 HASH` to require agreement with a
previous qualified run. The default workload is the unchanged eight-match
ribbon 1v1 campaign, all 1,801 aim indices, with historical seeds and limits.

The runner creates a unique immutable attempt under
`results/diagnostics/.staging/`, then finalizes into `runs/<run-id>/` after
validation. Existing IDs and archives cannot be overwritten. Failures and
interruptions retain the staging directory and explicit status. The compact
records are:

- `manifest.json`: protocol, source fingerprint, workload/input hashes, host,
  exact child commands/options and compressed artifact reference.
- `trials.csv`: every measured trial, including end-to-end/component wall times,
  allocation bytes, GC time/counts, compilation time, completion/candidate counts,
  gameplay hash, post-campaign RSS and sampled/lifetime peaks.
- `processes.csv`: loaded/warmed RSS, startup-to-entry, entry-to-load, artifact
  load, warmup and total process wall times for each fresh process. Optional
  load/warmup compilation counters distinguish compilation inside those regions.
- `diagnostics.json`: nested CPU/allocation summaries and runtime/thread counts.
- `checks.json`: gameplay, completion, source/input stability, reference
  verification and archive retrieval checks, with artifact member hashes.
- `README.md`: generated medians and min/max spread, paired timer overhead,
  memory table, CPU categories, allocation sources and measurement limits.

These use a diagnostic schema rather than pretending profile wall times are
headline throughput trials in `results/benchmarks/index.csv`. CSV quoting,
missing values and SHA-256 conventions follow the
[benchmark result standard](benchmark-results.md). Large raw artifacts are
compressed into `results/diagnostics/artifacts/<run-id>.tar.gz`; every member
is read back and checksum-verified before temporary files are removed. External
durable storage remains unconfigured; no old artifacts are removed.

## Timing, memory and profiling protocol

Each active-worker setting (default 1/2/4/8) starts a fresh Julia process with
the same thread budget: eight default threads, zero interactive threads, and
`--gcthreads=1`. Actual default/interactive/GC thread counts are recorded because
the GC can also have a concurrent sweep thread. Only that worker setting is
warmed, once per instrumentation variant, using the full workload and exact
verification/output path. Warmup includes compilation and is reported separately.
Three paired repetitions alternate enabled/disabled order: on/off, off/on,
on/off. Explicit pre-trial GC is outside the measured interval.

The historical end-to-end boundary remains setup/grid/checkpoint validation,
all decisions, gameplay equality verification and JSON write/close. Setup and
simulation versus verification/output are reported separately. Hashing, profile
decoding, startup, artifact loading, warmup and final summary writing are outside
this boundary. Julia `@timed` supplies bytes, GC pauses/full collections and GC
elapsed time over the enclosing diagnostic trial, including its small wrapper;
compilation/recompilation seconds remain visible. GC time is not aggregate
GC-thread CPU time. No detailed profiler runs in these timing trials.
Startup figures describe this diagnostic harness, which imports profiling libraries;
they do not substitute for a cold-start measurement of the production CLI.

RSS is sampled by the external Python parent every 100 ms, with campaign stage
markers, so no sampling task runs on Julia simulation workers. Loaded, warmed
and immediate post-campaign RSS are snapshots. A sampled campaign maximum can
miss short peaks. `process_lifetime_peak_rss_bytes` explicitly includes load,
compilation, both warmups and all trials in that process. Fresh processes isolate
worker settings, but these values still do not establish live heap size or
incremental memory per worker. Non-Linux snapshot/sampling values are unavailable.

Separate fresh one-worker processes each warm the uninstrumented variant, then
profile the complete campaign,
including dense early and sparse later decisions:

- CPU: Julia `Profile`, 10 ms interval, 10 million buffer entries; full-buffer
  and empty profiles fail validation. A portable all-thread text tree and
  primary-thread collapsed stack counts are retained. Exclusive categories use
  the deepest recognized frame: broad-phase filtering, collision/physics,
  engine updates, scoring/events, campaign/reset, GC, and runtime/other.
  Collision/physics also includes integration/resolution. Native code and
  inlining limit precision. GC safepoints alone are not labeled collection work.
- Allocation attribution: Julia `Profile.Allocs` with default event sampling
  probability 0.01; each sampled type, byte size and function/file/line stack is
  preserved. Sources
  are ranked by sampled bytes; these are not exact campaign allocation totals.
  Use timing-trial bytes for totals. Profile timings are not throughput evidence.

`--profile-repeats` defaults to one complete profile per kind; increase it to
repeat attribution. `--repeats` controls paired timing repetitions and defaults
to three. Increase paired repetitions before claiming small gains. Candidates
and repeated seeds are not independent experimental replications. Worker settings
execute sequentially in requested order; frequency, thermal, SMT, affinity and
contention effects are not isolated by this protocol. Host topology, allowed
CPUs and governors are captured, with no claim that they were controlled.

All measured trials, profiler campaigns and full warmups must share one gameplay
hash and candidate count; truncations fail completion validation. Reference
integrity is checked before and after, campaign config synchronization before,
and source/input fingerprints before and after. A short integration smoke test
can explicitly permit incomplete matches:

```bash
python3 scripts/run_campaign_diagnostics.py --allow-dirty --smoke \
  --games 1 --worker-counts 1 --julia-threads 2 --max-turns 1 --max-steps 1 \
  --repeats 2 --out tmp/diagnostic-smoke
python3 -m unittest discover -s scripts/tests -v
```

Smoke output is labeled accordingly and cannot establish performance or match
completion. Use the normal complete workload for diagnostic conclusions.

The first measured run and its findings are in the
[local diagnostic report](../benchmarks/campaign-diagnostics.md). It predates
separate load/warmup compilation counters; those fields are unavailable there.
Compilation counters cover timed regions; initial harness compilation remains
part of entry-to-load duration.
