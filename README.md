# julia_clone — Peggle Evolved simulation platform (Julia)

A portable simulation platform for [Peggle Evolved](../peggle_evolved). It
generates levels, runs bot games, and measures level behavior at scales the
Lua game cannot reach. See the implementation plan in
`../peggle_evolved/temp/julia_port/implementation-plan.md`.

M0 (this milestone) defines the workload and freezes the reference. It does
not contain Julia code yet.

## Layout

| Path | Purpose |
| --- | --- |
| `reference/peggle_evolved/` | Byte-for-byte export of the frozen Lua reference revision (`reference/PIN.md`) |
| `reference/files.sha256` | Per-file hash manifest of the pinned tree |
| `harness/` | LÖVE-based baseline sweep harness (candidate grid, phase timings) |
| `scripts/` | Reference verification, headless LÖVE wrapper, baseline runner |
| `docs/` | M0 reference, workload, and inventory documents |
| `results/` | Baseline summaries; raw per-candidate output goes to `results/raw/` (gitignored) |

## Quickstart

Requirements: LÖVE 11.x, LuaJIT, and a display (or `xvfb-run` for unattended
runs). Verification and the test suite need no display.

```bash
make verify                 # check the pinned reference against hashes
make list                   # list baseline workloads
make self-check             # grid identity + candidate determinism
make quick                  # short sweep (every 20th index)
make baseline               # full-grid baseline (long)
make test                   # run the reference test suite
```

Run a focused sweep directly:

```bash
scripts/run_baseline.sh --workload circles_small --stride 50
```

## The M0 workload

A candidate is one legal aim index from a ready-to-aim turn boundary with zero
additional launch delay. The grid has 1801 indices (0..1800), derived from the
reference snapping function in `src/systems/physics.lua`. The harness verifies
that enumerating indices reproduces the snapping function exactly before every
sweep.

Each candidate is evaluated from an identical fresh state (level setup, turn
reset). Timings are split into `init`, `reset`, `sim`, `extract`, and `output`
phases. See `docs/reference.md`, `docs/workload.md`, and `docs/inventory.md`.
Measured baseline numbers and the campaign sizing they imply are in
`docs/baseline-metrics.md`.
