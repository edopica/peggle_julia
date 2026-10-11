# Deathstar Node Interaction Guide

## Overview

The remote node `deathstar` is a non-SLURM Ubuntu machine configured for remote execution. It is accessible via the SSH alias `deathstar` in `~/.ssh/config`. It has a fast Ryzen Threadripper CPU and 3 GPUs.

**IMPORTANT WARNING**: This node is someone else's personal computer.
- **Do NOT overuse it**: Limit your testing and execution to what is strictly necessary.
- **NO destructive commands**: Commands that delete, modify system configurations, or heavily disrupt the file system outside of the project workspace are strictly prohibited.
- **Caution with burdensome workflows**: Workflows that require heavy CPU/GPU load or excessive memory should be treated with caution to avoid freezing the system or interrupting the owner's work. Always clean up processes if they hang.

## GPU Safety (critical)

- ALWAYS run `ssh deathstar "nvidia-smi"` first and confirm all 3 GPUs respond before any GPU use.
- If any GPU is unavailable or unresponsive, DO NOT attempt GPU tests: NCCL crashes completely when even a single GPU is missing.
- Primary use is CPU MPI testing (the main CPU workforce). GPU work is only a fallback, and only with all GPUs healthy.

## Precompilation

Deathstar is a single machine with no scheduler wrapper, so `scripts/remote/precompile.sh deathstar` compiles exactly where the tests will run. The Bocconi login-vs-compute rule does not apply here.

## Workflow Scripts

The same scripts used for the `bocconi` cluster work here, but they run directly on the machine without a job-scheduler wrapper.

### 1. Syncing Code
```bash
./scripts/remote/sync_code.sh deathstar
```
This syncs both the Flux fork and the thesis workspace to `~/projects/` on `deathstar`.

### 2. Setting Up the Environment
```bash
./scripts/remote/setup_node.sh deathstar
```

### 3. Precompiling
```bash
./scripts/remote/precompile.sh deathstar
```

### 4. Running Commands
```bash
./scripts/remote/run.sh deathstar make check
```
*(Note: unlike `bocconi`, `run.sh deathstar` executes commands directly on the host without `salloc`/`srun`.)*

## Current Status
- SSH configuration is present in `~/.ssh/config`.
- The environment has been synced and the node has been used for CPU MPI runs (for example the C8 gate); check `ssh deathstar "nvidia-smi"` before asking it for GPU work.
