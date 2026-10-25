I would improve profiling first, then run the improved benchmark on deathstar, and choose the first optimization from those results. SIMD filtering is a plausible candidate, but the current measurements don’t yet establish its potential benefit.

I reviewed commit 5de45c7, the runner, and the saved results. The benchmark report (wiki/benchmarks/1v1-campaign.md) is a credible warm, fixed-workload baseline:

- It evaluates complete matches and all 1,801 candidates per decision.
- Warmup exercises sequential, parallel, and output paths.
- All measured runs reproduce the same gameplay histories.
- Three repetitions give reasonably consistent times: roughly 149 seconds at one worker and 39 seconds at eight.
- Timing boundaries and memory limitations are documented clearly.

Its main limitation is what we can infer from it.

The scaling is better than the reported efficiency alone suggests. Using the saved sequential match durations and the actual strided assignments, I calculated these approximate limits assuming each match’s duration stayed unchanged under concurrency:

| Workers | Speedup allowed by batch imbalance alone | Measured speedup |
|---|---:|---:|
| 2 | 1.99× | 1.95× |
| 4 | 3.58× | 3.22× |
| 8 | 5.51× | 3.80× |

At eight workers, this batch could not reach 8× even with eight perfectly independent cores: the longest match determines completion time. There is additional slowdown under concurrency, but we cannot yet attribute it to SMT, CPU frequency, cache effects, or GC.

Also, the reported matches/hour extrapolates repeated eight-match batches. It does not establish the sustained throughput of a continuously occupied worker pool.

My proposed next step is a small diagnostic extension, preserving the existing baseline:

1. Profile CPU time inside simulation. Run a separate warmed sampling profile, initially with one worker. Distinguish broad-phase rejection, precise collision tests, engine updates, scoring/events, and GC. “Simulation is 99%” identifies the subsystem, not the optimization.
2. Measure allocations and GC per campaign. Record allocated bytes, collection counts, and GC time. Use separate diagnostic runs for allocation attribution. Earlier zero-allocation shot probes do not establish that whole campaigns allocate nothing.
3. Measure memory per concurrency setting in fresh processes. Record loaded/warmed memory and campaign peak RSS. The current cumulative peak, after warming eight workers, cannot establish incremental worker memory.
4. Add a sustained-throughput workload. Keep the original eight matches as a regression benchmark, and add a fixed, larger seed set with several matches per worker. Record worker busy time and completion tails. Include six workers locally, but use the larger batch: eight matches split across six workers are inherently unbalanced.

I would also compare phase timing enabled versus disabled once, to quantify instrumentation overhead. Three repetitions are adequate for this first baseline; small optimization claims will need more paired measurements.

Then use deathstar as the first second-host experiment. Its previously recorded 32-core CPU makes it useful for investigating scaling beyond the laptop’s six physical cores. Run both the unchanged eight-match workload for direct comparison and the larger workload for throughput. Verify current hardware, allocation/affinity, and host contention before interpreting results, and require matching gameplay histories across hosts.

Bocconi becomes useful afterward for a different CPU architecture or if it is the intended deployment platform. Merely repeating the current test there would give another timing without resolving most of today’s uncertainty.

SIMD filtering should come next only if the profile supports it. The existing broad phase is a concrete candidate, but measure its cost and rejection rate first. Compare a scalar layout/work-reduction improvement against SIMD so we can identify where the gain comes from. Preserve survivor order, collision tolerances, and deterministic arithmetic; the documented @simd restriction also needs an explicit contract review.

For perspective, if filtering occupies 20% of runtime, making it four times faster yields only about 1.18× overall. That fraction is the missing measurement.

My choice for the next commit: CPU profiling, campaign allocation/GC metrics, and a larger fixed throughput workload—followed by a deathstar run before changing the physics implementation.
