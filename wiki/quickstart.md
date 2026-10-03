# julia_clone — Quickstart

**julia_clone** is the simulation platform for
[Peggle Evolved](../peggle_evolved): a portable Julia program that generates
levels, runs bot games, and measures level behavior at a scale the Lua game
cannot reach. The governing plan is
`../peggle_evolved/temp/julia_port/implementation-plan.md`; the goal notes are
in the same directory.

Start here, then follow the links below. The Lua game's own documentation is
in `../peggle_evolved/wiki/`.

## Current status

| Milestone | State |
| --- | --- |
| M0 — define the workload and select the reference | **Done** |
| M1 — interchange, fixtures, level previews | Not started |
| M2 — math and state foundations (first Julia code) | Not started |
| M3 — minimal shot evaluator and early measurement | Not started |

The repository currently contains the frozen Lua reference, the baseline
sweep harness, and documentation. **There is no Julia code yet.** M2 creates
the Julia package.

## Requirements

- LuaJIT and LÖVE 11.x for the baseline harness (LÖVE needs a display, or
  `xvfb-run` on headless servers; `scripts/love.sh` handles both).
- No Julia toolchain is required until M2.
- `make verify` and `make test` need neither a display nor LÖVE.

## Common commands

```bash
make verify       # verify the pinned reference against reference/files.sha256
make list         # list baseline workloads
make self-check   # grid identity + candidate-evaluation determinism
make quick        # short sweep (every 20th aim index)
make baseline     # full-grid baseline (long; writes results/ and results/raw/)
make test         # run the pinned reference test suite in a scratch copy
```

Focused commands:

```bash
scripts/run_baseline.sh --workload circles_small --stride 50
scripts/render_summary.py results/RUN.summary.json
scripts/verify_reference.sh
```

## Repository layout

| Path | Purpose |
| --- | --- |
| `wiki/` | Permanent project documentation (this directory; see below) |
| `reference/peggle_evolved/` | Byte-for-byte export of the frozen Lua revision; **read-only** |
| `reference/PIN.md` | Reference revision, tree hash, config hash, manifest rules |
| `reference/files.sha256` | Per-file hash manifest of the pinned tree |
| `harness/` | LÖVE baseline sweep harness: candidate grid, phase timings |
| `scripts/` | Reference verification, headless LÖVE wrapper, baseline runner, summary renderer |
| `results/` | Baseline summary JSON (committed); `results/raw/` per-candidate JSONL (gitignored) |
| `tmp/` | Local scratch (gitignored) |

## Wiki layout

All permanent documentation lives under `wiki/`. Ephemeral plans, scratch
notes, and investigation reports go to `tmp/` locally or to
`../peggle_evolved/temp/` when they belong to the Lua project. The layout
mirrors `../peggle_evolved/wiki/` so material can move between the projects.

| Path | Purpose | Status |
| --- | --- | --- |
| `wiki/quickstart.md` | Entry point and this layout description | current |
| `wiki/context/` | Durable technical notes that later work depends on | current |
| `wiki/context/reference.md` | Frozen revision, config, candidate grid, decision boundary, action/result schemas | current |
| `wiki/context/workload.md` | Representative workloads, seeds, phase definitions, measurement protocol, campaign sizing | current |
| `wiki/context/inventory.md` | Inventory of the existing Lua corpus, tools, and plumbing | current |
| `wiki/benchmarks/` | Measured performance and parity results | current |
| `wiki/benchmarks/baseline-metrics.md` | M0 Lua candidate-sweep baseline and continuing-metric protocol | current |
| `wiki/devlog/` | Dated engineering log, one file per date (`YYYY-MM-DD.md`) | current |
| `wiki/decisions/` | ADRs for port decisions (math contract, storage, scheduler, ...) | reserved |
| `wiki/audits/` | Correctness audits (math census, determinism, RNG) | reserved |
| `wiki/failures/` | Post-mortems for notable bugs and campaign failures | reserved |
| `wiki/templates/` | Document templates (devlog, ADR) | current |

Conventions:

- Use the templates in `wiki/templates/` for new devlogs and ADRs.
- A devlog entry is appended to the current date's file; do not rewrite past
  entries except to fix factual errors.
- Keep `wiki/context/` notes current when a milestone changes the reference,
  the workload, or the measurement protocol.
- Record numeric results as files under `results/` and link them from the
  relevant wiki page; do not paste large tables into the devlog.

## Reference rules

- The pinned revision in `reference/PIN.md` is the authoritative Lua behavior.
  `reference/peggle_evolved/` is vendored and read-only; the harness may
  monkeypatch at runtime but never edits it.
- Run `make verify` before and after any measurement session. The manifest
  covers 133 files; a fresh clone must verify clean.
- Advancing the pin requires re-capturing baselines, fixtures, and golden
  outputs. Uncommitted working-tree edits in the Lua repository are never
  part of the pin.
- The candidate grid is derived from `Physics.getSnappedAimAngle` and
  verified at harness startup; never substitute a separate angle loop.

## Documentation map

| Question | Read |
| --- | --- |
| What is frozen, and what is a legal action? | `wiki/context/reference.md` |
| What exactly is measured? | `wiki/context/workload.md` |
| What already exists in Lua? | `wiki/context/inventory.md` |
| How fast is Lua today? | `wiki/benchmarks/baseline-metrics.md` |
| What happened on a given day? | `wiki/devlog/` |
| Why was a port decision made? | `wiki/decisions/` |
| What is the overall plan? | `../peggle_evolved/temp/julia_port/implementation-plan.md` |
| How does the Lua game work? | `../peggle_evolved/wiki/quickstart.md` |
