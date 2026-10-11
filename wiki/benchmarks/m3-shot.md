# M3 mustache shot benchmark

Measured cost of one full-physics shot on the mustache level, for the Lua
reference and the Julia shot engine. The benchmark is also the first
cross-engine performance comparison for the port. It adds the thread scaling
and allocation behavior of the Julia sweeps.

- Results file: `results/m3/bench-report.json` (combined report)
- Producer: `scripts/bench_m3.sh` (`make m3-bench`)
- Driver: `julia/PeggleSim/bin/shot_bench.jl`
- Correctness anchor: full-grid agreement, 1,801/1,801 candidates
  (`results/m3/sweeps-compare-full.json`)
- Host: omarchy, AMD Ryzen 5 4600H, 12 threads, Linux, LÖVE 11.5.0,
  LuaJIT 2.1, Julia 1.12.6

## 1. Method

- Grid: the same 1,801 aim indices (0..1800) on both engines. The timed sweep
  uses stride 20 and evaluates 91 candidates.
- Completion: one ball, clearing off, `max_steps = 3600`. The Julia records
  mark this rule as `bench`.
- Observation: sweep mode. No gameplay traces and no snapshots are written
  during timing.
- Lua: dev tree `../peggle_evolved`, single-threaded, `--no-replay-serialize`
  for the timed sweep. The report averages 2 repeats.
- Julia: one post-warmup pass per thread count. `--verify-serial` runs the
  serial pass and the parallel pass and requires bit-identical rows.
- Replay serialization: one extra Lua run with replay serialization enabled
  measures 18.77 candidates/s against 16.66 without it. Treat this 1.13 ratio
  as indicative only. It cannot separate serialization cost from run-to-run
  rate variation.

## 2. Same-core Lua vs Julia (91 candidates, stride 20)

| Engine | Candidates/s | Steps/s | Samples |
| --- | ---: | ---: | --- |
| Lua harness | 16.66 (14.35–18.97) | 20,757 | repeat 2, mean |
| Julia t1, serial pass | 33.46 | 28,210 | 1 post-warmup pass |
| Julia t1, parallel pass | 32.56 | 27,447 | 1 post-warmup pass |

The same-core speedup is 1.95× by candidates/s (32.56 / 16.66). It is
indicative, not a benchmark-grade ratio. See §6.

## 3. Per-candidate phase times

Means over the 91 candidates. `init` is the Lua per-candidate level setup
(`setupLevel`). The M2 checkpoint replaces that setup with the Julia `reset`.

| Phase | Lua | Julia t1 |
| --- | ---: | ---: |
| `init` | 20.6 ms | not modeled (checkpoint reset) |
| `reset` | 9.5 µs | 41.8 µs |
| `sim` | 40.6 ms | 29.9 ms |
| `extract` | 21.1 µs | 18.9 µs |
| `output` | 1.6 µs | not a Julia phase |

Reset is negligible on both sides. The Julia reset is 0.14% of the Julia `sim`
mean, and the Lua reset is 0.02% of the Lua `sim` mean. The candidate step
distribution is the same on both engines: mean 843, p50 765, p99 3010, max
3010.

## 4. Thread scaling (91 candidates, parallel pass)

| Threads | Candidates/s | Steps/s |
| ---: | ---: | ---: |
| 1 | 32.6 | 27,447 |
| 2 | 50.0 | 42,144 |
| 4 | 65.0 | 54,816 |
| 8 | 93.2 | 78,586 |
| 12 | 93.3 | 78,672 |

The serial and parallel passes are bit-identical at every thread count
(`serial_parallel_identical = true`). The serial pass rate stays in the
31.5–34.2 candidates/s range across all thread counts, so the scaling is not a
serial-cost artifact. Scaling flattens between 8 and 12 threads on this
12-thread host.

The full-grid single-thread reference is 27.7 candidates/s over 1,801
candidates (`results/m3/julia-full-t1.json`). The stride-20 sample runs faster
per candidate (32.6 candidates/s) because the two samples differ.

## 5. Allocations

Method: `Base.gc_bytes()` delta around reset+launch+run+extract per candidate,
on the serial path, post-warmup. One extra untimed serial pass compiles every
candidate code path first. Allocation accounting is process-wide, so parallel
runs cannot attribute bytes to one candidate. The exact method string is the
`alloc_method` field in `results/m3/julia-sweep-t1.json`.

| Metric | Value |
| --- | ---: |
| Candidates | 91 |
| Mean | 11.26 MB |
| p50 | 4.96 MB |
| p99 | 92.87 MB |
| Max | 92.87 MB |
| Min | 0.34 MB |
| Total | 1.025 GB |

M3 does not require zero allocation (correctness first). This table is the M4
baseline.

## 6. Caveats

- The same-core speedup is indicative. Julia is timed with one post-warmup
  pass and Lua with repeat 2. Rates vary between runs. Do not quote 1.95× as a
  benchmark-grade ratio.
- Allocation accounting is process-wide and serial-only.
- The timed sample is 91 candidates (stride 20). Long candidates dominate the
  p99 and the per-candidate totals.
- The replay-serialization measurement is one extra repeat. The 1.13 ratio is
  not proof of a real serialization cost.
- `spawned` is not a shared sweep field. The Lua raw format omits it. The
  multiball trace fixture covers spawn behavior (see
  `wiki/context/m3-mustache.md`).

## 7. Correctness anchor: full-grid agreement

`make m3-bench` also runs the full candidate grid on both engines. The
comparison runs before the combined report is written.

- 1,801/1,801 indices compare clean across 16 shared fields: `index`,
  `angle`, `steps`, `completed`, `reason`, `score`, `peg_score`, `bonus`,
  `style_points`, `style_total`, `styles`, `pegs_hit`, `reds_hit`,
  `multiplier`, `is_fever`, and `balls`.
- `first_divergent_candidate` is `null` and `per_field_mismatch_count` is
  empty (`results/m3/sweeps-compare-full.json`).
- Julia serial and parallel sweeps are bit-identical at every thread count.
- The trace-level state comparison is in `wiki/context/m3-mustache.md`
  (`results/m3/mustache-compare.json`).

## 8. Reproduction

```bash
make m3-bench
scripts/bench_m3.sh --stride 20 --threads "1 2 4 8 12"
scripts/bench_m3.sh --stride 50 --threads "1 2 4"
scripts/bench_m3.sh --full-grid none
```

The script requires the dev tree `../peggle_evolved`, LuaJIT, LÖVE, and Julia
1.12.6. The default `--full-grid auto` runs stride 1 when the projected Lua
grid time is at most 20 minutes, and stride 5 otherwise.

Outputs:

| File | Contents |
| --- | --- |
| `results/m3/bench-report.json` | combined machine-readable report |
| `results/m3/lua-bench.summary.json` | timed Lua sweep (`--no-replay-serialize`) |
| `results/m3/lua-bench-replay.summary.json` | Lua single-repeat run with replay I/O |
| `results/m3/julia-sweep-t<T>.json(l)` | Julia sweep per thread count |
| `results/m3/julia-full-t1.json` | full-grid Julia reference (stride 1) |
| `results/m3/sweeps-compare.json` | stride-20 field agreement |
| `results/m3/sweeps-compare-full.json` | full-grid field agreement |
| `results/raw/m3-*.jsonl` | raw candidate rows (gitignored) |
