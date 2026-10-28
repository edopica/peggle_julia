# Prepared decision checkpoints and compact geometry

This is the Julia implementation of optimization strategy §17.1 experiment 4.
The interchange `Checkpoint` remains the serialization and provenance contract.
`prepare_checkpoint(checkpoint)` makes an owned decision snapshot, decodes its
RNG once, and prepares ordered shape-list indices and inline numerical geometry.
Campaign candidate evaluation prepares once before the aim loop, so preparation
is included in total decision/campaign time.

`PreparedCheckpoint` can be read by multiple engines. Each engine owns its
`CheckpointRestoreScratch`: peg and initial-ball pools survive removal from
the live collections. Reset overwrites every field, repopulates identity maps,
restores trackers and reconstructs shape lists from prepared ordered indices.
Positions in these lists retain their collision tie-breaking meaning; they are
not replaced by stable peg IDs. Balls spawned during a shot retain the existing
separate spawn pool. RNG preparation uses the existing checkpoint decoder,
including its `Inf` normal-cache sentinel, and never consumes a draw.

The internal numerical records are `CompactPegGeometry{CircleShape}`,
`CompactPegGeometry{RectangleShape}` and `CompactPegGeometry{AnnularShape}`.
All three are `isbits` records, stored inline in typed vectors without scoring
fields, line strings or GC references. Each carries coordinates, translational
velocity, bounding radius and immutable shape data. A worker owns a reusable
copy of each shape's geometry cache, aligned with its live peg-reference list.
Removal deletes the same ordinal from both lists. Reset restores both lists.
The prepared source vectors are read-only by convention and never modified by
an engine.

By default, before a physics frame the caches refresh from live pegs. This
retains direct callers' changes to transforms, signed-zero and nonzero velocities, shapes and
bounding-radius caches. Each CCD window scans the numerical records first,
loading the live peg only for survivors. Narrow-phase tests, ordered contact
reduction, depenetration, moving/rotating geometry, fever dividers and ball-ball
physics retain their existing semantics and operation order. No SIMD directives,
fast math, native code or spatial index are introduced.

The campaign explicitly opts into `static_geometry=true`: it owns the candidate
engine, loads static artifacts with no circuits, and uses match callbacks that
do not modify peg geometry or velocities. Its geometry is copied on reset and
kept aligned on removal, with no redundant per-frame refresh. This is a caller
promise: callers that change transforms, shapes, velocities or bounding-radius
caches between resets must leave the option disabled. General prepared-engine
construction and reset keep it disabled by default. The `--prepared` corpus
drivers also opt in, since they own the same closed static-level shot pipeline.

The first implementation deliberately retains mutable `Peg` objects for scoring
and the existing public engine interfaces. It does not establish a fully shared
level-wide geometry store with only indexed mutable state. It supplies the
contiguous scan and reset experiment without requiring that broader rewrite.
Future work can compare shared indices against these contiguous private caches.

The existing `reset_shot_engine!(engine, checkpoint)` uses the interchange path.
Passing a `PreparedCheckpoint` enables pooled reset and compact geometry;
`compact=false` isolates pooled reset with the original object scans.
Prepared engine construction is also supported by `shot_engine(prepared; ...)`.

Qualification commands, from the repository root:

```bash
julia --project=julia/PeggleSim -t 4 julia/PeggleSim/test/runtests.jl
julia --project=julia/PeggleSim julia/PeggleSim/bin/replay_fixtures.jl --prepared \
  --out tmp/prepared/replay.json --trace-report tmp/prepared/traces.json \
  --trace-out-dir tmp/prepared/traces
julia --project=julia/PeggleSim -t 4 julia/PeggleSim/bin/shot_bench.jl \
  --sweep --prepared --level interchange/levels/slide.v1.json \
  --config interchange/config.v1.json --stride 1 --threads 4 --verify-serial \
  --out tmp/prepared/slide.jsonl --summary tmp/prepared/slide.json
julia --project=julia/PeggleSim -t 1 scripts/m4_allocation.jl --prepared \
  --workload all --out tmp/prepared/allocation.json --print
```

`scripts/bench_prepared_checkpoint.jl` compares three source trees: baseline,
prepared reset alone, and combined reset/geometry. The prepared-only tree is
identical to the combined tree except that the candidate-loop reset call also
passes `compact=false`. The driver loads the trees into isolated Julia modules, fully
warms each with ten ribbon 1v1 matches, and alternates three measured repetitions
in Latin-square order. Each campaign includes all 1,801 aims at every decision,
seed 20261024, phase instrumentation, gameplay comparison and JSON write/close.
`@timed` records allocated bytes, GC and compilation separately; hashing and
isolated reset/stepping probes are outside campaign timing. Source tree hashes,
reference verification and host/process snapshots accompany the experiment.

Module variants share a process and GC. Allocated bytes are comparable; process
RSS cannot establish a separate memory footprint for each variant. Ten matches
on eight workers retain the historical regression batch, not sustained-load or
SMT/NUMA qualification. Trial repetitions quantify timing dispersion for the
fixed workload; matches and aim samples are not independent benchmark replicas.

The [Deathstar comparison](../benchmarks/prepared-checkpoint.md) records the
28 October measurement and adoption decision: median time −3.43%, total
allocated bytes −90.84%, unchanged gameplay, and no separate throughput claim
for compact geometry versus prepared reset alone.
