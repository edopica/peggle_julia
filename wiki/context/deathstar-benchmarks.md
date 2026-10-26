# Deathstar simulation benchmarks

Deathstar is the intended continuing benchmark host for this Julia port.
It is an Ubuntu workstation reached through `ssh deathstar`, without SLURM.
Leave unrelated projects and system configuration alone, check for competing
workloads before measurement, and run tests before timed trials. No GPU is used.
The Flux workflow scripts mentioned in the older [node guide](deathstar.md)
belong to another project and are not used here.

## Hardware and runtime

Observed 2026-10-26: AMD Ryzen Threadripper 2990WX, 32 physical cores /
64 logical CPUs, four NUMA nodes, approximately 128 GiB RAM, Ubuntu 22.04.
The governor is `schedutil`, boost is enabled, and automatic NUMA balancing
is enabled. The campaign records host metadata; these settings are not changed.

The system `/usr/bin/julia` is **1.6.2**. The benchmark uses pinned **1.12.6**:
`~/.julia/juliaup/julia-1.12.6+0.x64.linux.gnu/bin/julia`.
`~/projects/peggle-benchmarks/tools/bin/` contains a link to that runtime and
LuaJIT extracted from Ubuntu's
`luajit_2.1.0~beta3+dfsg-6ubuntu0.1_amd64.deb`.
No system packages were changed. Python 3 and GNU time are already installed.

## 2026-10-26 campaign

Job directory: `~/projects/peggle-benchmarks/campaign-20261026/`.
The isolated `source/` checkout is clean commit
`14e36b45a6198da067061b6d5885a31ce5d41025`;
`source.bundle` retains the Git source. The adjacent `peggle_evolved/` directory
contains the saved campaign config and game source at their original relative
paths for the config precheck. Their bytes were checked against the local Lua
working tree before deployment. This is not a full Lua project checkout.

`run.sh` is the single detached job. It instantiates the pinned environment,
verifies the frozen reference, checks the campaign config, and runs the Julia
simulator suite before measurement. It then executes:

```bash
julia --project=julia/PeggleSim scripts/run_campaign_benchmark.jl \
  --run-id deathstar-20261026-1v1-10repeats \
  --worker-counts 1,2,4,8 --threads 8 --games 8 --repeats 10 \
  --warmup full --mode 1v1
```

This retains the prior eight-match, 1,801-aim workload, seeds, full warmup,
phase instrumentation, timing boundaries, and alternating ascending/descending
worker order: 40 measured trials, 320 match completions if all succeed.
The Julia simulation pool stays at eight threads. There is no CPU affinity or
NUMA binding, preserving the earlier protocol; topology effects remain a
possible follow-up experiment. BLAS/OpenMP pools are limited to one thread,
and `PEGGLE_MATH_BACKEND=system_libm` is explicit.

After the runner archives, validates, and indexes its output, the job verifies
the frozen reference again and runs the independent Python artifact validator.
Memory remains the prior cumulative-process RSS metric; efficiency means
worker scaling, not energy consumption. More repetitions reduce measurement
noise but do not eliminate systematic bias.

## Checking the job

```bash
ssh deathstar 'cd ~/projects/peggle-benchmarks/campaign-20261026; cat status; tail -30 job.log'
ssh deathstar 'cd ~/projects/peggle-benchmarks/campaign-20261026; cat exit-code finished-at'
```

`status` progresses through `preflight`, `benchmarking`, and `postflight`, then
`completed` or `failed`. `exit-code` and `finished-at` are written on exit.
`job.pid`, `started-at`, `revision`, selected environment variables, host
snapshots, and `simulator-tests.log` are retained outside the measured checkout.
The job uses `nohup setsid bash ./run.sh`, with redirected stdin and output;
it does not depend on an open SSH session.

Successful results are under
`source/results/benchmarks/runs/deathstar-20261026-1v1-10repeats/`, with raw
evidence archived under `source/results/benchmarks/artifacts/` and canonical
histories under `source/results/benchmarks/histories/`. During execution,
progress also appears under `source/results/benchmarks/.staging/`.
Retain failed attempts; retries require a new run ID and job directory.

Tomorrow, retrieve the run, archive, history, index, and job logs together.
Check validation and completion counts before comparing medians, spread,
throughput, speedup, and efficiency with the previous host. Remote storage
alone is not an external durable archive; see [result storage](benchmark-results.md).
