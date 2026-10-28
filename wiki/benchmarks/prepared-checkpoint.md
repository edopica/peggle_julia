# Prepared checkpoints and compact geometry — Deathstar, 28 October 2026

The combined implementation reduced median campaign time by **3.43%** and
allocated bytes by **90.84%** against the current-source baseline. It beat the
baseline in each of three paired repetitions. The independent contribution of
compact geometry remains unresolved: comparisons with prepared reset alone
changed direction between repetitions.

The [numeric report](../../results/analysis/prepared-checkpoint-2026-10-28.json)
contains every timing/allocation sample, paired ratios and limitations. The
[evidence archive](../../results/benchmarks/artifacts/deathstar-20261028-prepared-checkpoint-evidence.tar.gz)
retains both experiments, source snapshots, fingerprints, runner scripts,
canonical histories and local qualification. Its SHA-256 is recorded in the
numeric report; all 2,925 regular/hardlinked members were read back successfully.

## Protocol and results

Baseline revision: `808724efbf71d3009339bbb0dae461f85fdf06ca`. Exploratory
candidate source was fingerprinted and is byte-identical to the final local
Julia source. All variants use Julia 1.12.6, `system_libm`/glibc 2.35, eight
default threads, zero interactive threads, one requested GC thread, and eight
workers on Deathstar (`znver1`). No affinity, NUMA or system settings changed.

Each campaign runs ten complete ribbon 1v1 matches, seed 20261024, all 1,801
aim indices per decision, 3,600 maximum steps, and 100 maximum turns. Every
trial evaluated 198,110 candidates. Each variant received a complete ten-match
warmup. Three measured repetitions alternate variant order in a Latin square:
baseline/prepared/compact, compact/baseline/prepared, prepared/compact/baseline.

| Variant | Median seconds | Min–max seconds | Median allocated MiB |
| --- | ---: | ---: | ---: |
| Baseline | 33.438 | 33.360–35.994 | 2,720.26 |
| Prepared reset, object scans | 33.518 | 32.160–34.332 | 206.57 |
| Prepared reset + static compact geometry | 32.292 | 32.112–34.852 | 249.27 |

The combined/baseline speedups by repetition are **1.0389×, 1.0355×, 1.0328×**.
The median throughput increase is 3.55%. Prepared reset alone reduced allocation
by 92.41%, but its median elapsed time was 0.24% higher than baseline in this
session. The combined variant allocated about 42.70 MiB more than prepared-only.

All timings include setup, preparation, simulation, gameplay equality checking
and JSON write/close. Phase instrumentation is enabled for every variant.
`@timed` records allocation, GC and compilation. Hashing, reset probes and
explicit pre-trial GC are outside the campaign interval. A residual 19.7 ms
compilation cost appears in the first baseline trial; all other measured trials
record zero compilation. No profiler ran during timing.

Variants are separate modules in one process. This permits interleaving warmed
implementations, but shares the GC and retained runtime/code memory. Allocated
bytes are not live memory or RSS. The reset probe's retained worker graph was
77,166 bytes for baseline and 107,468 for compact; the geometry cache adds
retained storage even while total allocation falls sharply.

All variants slowed in the final repetition. The balanced order and positive
paired combined/baseline ratios support a modest improvement on this batch,
but three repetitions on one host do not isolate host drift or establish a
cross-workload/server-wide uncertainty interval. Ten matches on eight workers
are the historical regression batch, not a sustained saturation or SMT study.

## Geometry refresh experiment and retained behavior

The first experiment refreshed compact geometry every physics frame. Its median
combined time was 34.232 seconds, versus 33.134 for baseline and 32.550 for
prepared-only. That implementation was not retained for the closed campaign
path. Both experiments and their original histories/source are in the archive.

The final campaign explicitly promises static geometry: its artifacts have no
circuits and its match callbacks never modify peg geometry or velocity. It
therefore copies prepared geometry on reset and maintains list alignment on
removal, without repeating the frame refresh. General prepared-engine callers
retain refresh by default. See the [implementation contract](../context/prepared-checkpoint.md).

The campaign default retains the combined path, which improved total time in
all three paired comparisons and reduced allocation. `compact=false` remains
available to isolate pooled reset. These measurements do not establish that
compact geometry independently improves throughput, nor that a native-language
version of the same layout would improve it further.

## Correctness and reproduction

The final full local suite passed **80,453/80,453** checks. Deathstar passed
**66,315/66,315** focused final checks; the first experiment also ran the full
suite, passing 58,439 checks. Tests cover ownership, repeated removal/reset,
initial-ball and spawn-pool separation, complete restore semantics, signed zero,
moving broad-phase inputs, ordered events, multiball and clearing.

All 14 fixture replays matched and all six traces were byte-identical. Eleven
full-grid sweeps across the seven M4 workloads produced **19,811 rows** identical
to the retained qualified baseline, including serial/parallel comparisons at
one, two and four threads on the dense workloads. All five warmed stepping
allocation gates remained strict zero. Frozen reference verification passed
before and after qualification/measurement. Source fingerprints were unchanged.

All nine final campaign histories were byte-identical to each other and the
historical Deathstar history, SHA-256
`82b282ee176746817047e93d90755bedae81de07ed3b5ed876c9c336c8a96bb3`.
Archive retrieval independently verified every source fingerprint and compared
the measured compact Julia code against the local working tree.

Extract the evidence archive, enter `remote/compact/`, and use an unused output
directory to repeat the final comparison:

```bash
julia --project=julia/PeggleSim -t 8,0 --gcthreads=1 \
  scripts/bench_prepared_checkpoint.jl ../baseline ../prepared ../../reproduction 8 3
```

The remote jobs remain under
`~/projects/peggle-benchmarks/compact-checkpoint-20261028-01/` and `...-02/`.
