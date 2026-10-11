# Remote Execution Nodes

This document is the index for syncing code to remote machines and running tests there. Each server has its own page with environment details, constraints, and safety rules: read the server page before running anything on it.

| Server | Scheduler | Role | Page |
|---|---|---|---|
| `bocconi` | SLURM | University cluster: CPU/MPI tests and GPU validation | [bocconi.md](bocconi.md) |
| `deathstar` | none | Non-SLURM workstation (courtesy machine), main CPU workforce | [deathstar.md](deathstar.md) |
| `leonardo` | SLURM | CINECA GPU cluster; operational since 2026-10-04 (Julia workflow and 4-rank NCCL verified) | [leonardo.md](leonardo.md) |

SSH aliases are defined in `~/.ssh/config`. The tools live in `scripts/remote/` and all commands below run from the thesis repo root.

## Workflow Scripts

### 1. `scripts/remote/sync_code.sh <remote_host>`
**Purpose**: Sync local modifications of both the Flux fork (`ddp_flux`) and the thesis workspace (`ddp-flux-thesis`) to the remote node under `~/projects/`.
**Mechanism**: `rsync --delete`; excludes `.git` and `.julia`, and protects the remote-resolved `ddp_flux/test/Manifest.toml`. Excluded paths are protected from deletion.
**Important**: a sync changes the Flux sources, which stale-invalidates the remote precompile cache. Always precompile before the next test run.

### 2. `scripts/remote/setup_node.sh <remote_host>`
**Purpose**: Initialize the remote environment after the first sync, or whenever `Project.toml` changes.
**Mechanism**: `ssh` + `make env` on the remote. Resolves dependencies only; it never precompiles.

### 3. `scripts/remote/precompile.sh <remote_host>`
**Purpose**: Precompile both project envs (thesis env + `ddp_flux/test` env) on the machine that will actually run the tests.
**Mechanism**: runs `make precompile-all` through `run.sh`, so on Slurm clusters the compile happens on a compute node via the host configuration wrapper.
**When**: after every `sync_code.sh`, or after any change to the Flux fork source or dependency manifests. On `bocconi` this step is mandatory and must not be skipped; see [bocconi.md](bocconi.md).

### 4. `scripts/remote/run.sh <remote_host> <command...>`
**Purpose**: Execute a command (for example `make check`) inside the remote thesis directory.
**Mechanism**: reads `scripts/remote/hosts/<remote_host>.conf` and prefixes the command with that host's `WRAPPER` (for example `salloc ...` on Slurm clusters). Unknown host names are rejected, so a typo cannot run unwrapped on a cluster login node.
**Examples**:
```bash
scripts/remote/run.sh bocconi make check
NTASKS=2 CPUS_PER_TASK=4 scripts/remote/run.sh bocconi "make launch-2"
```

Resource overrides (`NTASKS`, `CPUS_PER_TASK`, `GRES`) are environment prefixes on the *script*; `make` variables go inside the quoted command. See [bocconi.md](bocconi.md) for why.

## Precompile caches (all servers)

Julia precompile caches bake the host CPU feature set, so a cache built for one CPU family is useless on another. `sync_code.sh` invalidates the remote cache, and `precompile.sh` must run on the machine that will run the tests (a compute node on Slurm clusters). If any run prints `Precompiling packages...`, a sync happened without a follow-up precompile: stop, precompile, rerun.
