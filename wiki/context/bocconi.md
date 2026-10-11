# Bocconi Cluster (`bocconi`)

The university SLURM cluster. The SSH alias `bocconi` (`HostName slogin.hpc.unibocconi.it`, user `3320522`) is defined in `~/.ssh/config`. Renaming the alias did not change the real hostname.

## Environment

- Login node: `slnode01` (Xeon Emerald Rapids; julia CPU target `graniterapids`).
- Compute nodes: `gnode01`, `gnode02` (Xeon Gold Ice Lake; julia CPU target `icelake-server`, flag-identical to each other).
- Scheduler: SLURM, `stud` partition, account `3320522`. Default wrapper from `scripts/remote/hosts/bocconi.conf`: `salloc --ntasks=$NTASKS --gres=$GRES --mem=32G --cpus-per-task=$CPUS_PER_TASK --account=3320522 --partition=stud --qos=stud`.
- CPUs are slow; jobs are limited to at most 8 CPUs.
- GPUs: 2× A100 per GPU node.

## Precompilation is CPU-target specific (critical)

Julia precompile caches bake the host CPU feature set. Login (`graniterapids`) and compute (`icelake-server`, mutually compatible) do NOT share caches. `salloc` shells stay on the LOGIN node; only `srun` reaches compute nodes.

- ALWAYS run `scripts/remote/precompile.sh bocconi` before tests and after every `sync_code.sh` or Flux source change. Give the bash tool a lengthy timeout (at least 15 minutes, up to ~20 for the first post-sync pass).
- `precompile.sh bocconi` compiles on a compute node via `srun` (thesis env + Flux test env). NEVER run julia that loads the project envs on the login node (`julia --project=...` with `using Flux`): a login compile is wasted work, and a compute-node run after a source change silently recompiles for ~2-5 min inside the test watchdog otherwise.
- If a run prints `Precompiling packages...`, a sync happened without a follow-up precompile: stop, precompile, rerun.
- `setup_node.sh bocconi` only resolves dependencies (never precompiles); run it on first setup or `Project.toml` changes.
- `JULIA_CPU_TARGET` (env) does not pin the loading process, and even `-C` cannot bridge the login/compute gap; keep all julia work on compute nodes. Details: ADR-0005 and `wiki/devlog/01-pr2694/2026-09-03-precompile-experiment.md`.

## Running commands

Make variables go as make arguments, because `salloc` execs argv directly and an env prefix before the remote command fails with `Unable to find command "FLUX_REPO_PATH=..."`. Resource overrides are environment prefixes on the *script*:

```bash
scripts/remote/run.sh bocconi "make c8-mpi FLUX_REPO_PATH=../ddp_flux"
NTASKS=2 CPUS_PER_TASK=4 scripts/remote/run.sh bocconi "make launch-2"
```

## GPU access pattern

- GPUs are reachable with `salloc --gres=gpu:2` plus `mpiexecjl` inside the allocation. `make` targets switch to `srun --mpi=pmi2` automatically when `SLURM_JOB_ID` is set.
- `run.sh` wraps commands in `bash -l`, which resets environment variables needed for CUDA. `make example-ddp` has run through `run.sh` successfully, but a GPU/NCCL run that fails suspiciously should be retried with a direct `ssh bocconi` + `salloc` + `mpiexecjl` command (see `wiki/devlog/01-pr2694/2026-08-01.md`).

## Usage sequence

```bash
scripts/remote/sync_code.sh bocconi      # after code changes
scripts/remote/setup_node.sh bocconi     # first setup or Project.toml change
scripts/remote/precompile.sh bocconi     # always after a sync; long timeout
scripts/remote/run.sh bocconi make check
```
