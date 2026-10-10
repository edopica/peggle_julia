# M0 report — workload defined, reference frozen, Lua baseline measured

Repo: `../julia_clone/` (sibling of `peggle_evolved/`), commits `c8dbddb` and
`7894c37` on `main`.
Plan: `temp/julia_port/implementation-plan.md` §5, M0.
Docs: `../julia_clone/wiki/quickstart.md` (documents the wiki layout); M0
devlog: `../julia_clone/wiki/devlog/2026-10-03.md`.

## What was built

| M0 task | Deliverable |
| --- | --- |
| Reference revision + config | `reference/PIN.md`, `reference/peggle_evolved/` (`d17f6e7`), `reference/files.sha256`, `scripts/verify_reference.sh` |
| Candidate grid + decision boundary | `wiki/context/reference.md`: 1801 indices (0..1800) derived from `Physics.getSnappedAimAngle`; ready-to-aim boundary after `resetTurn`; zero launch delay; `delay` field reserved |
| Representative levels/seeds/decisions | `harness/workloads.lua`, `wiki/context/workload.md`: 7 static workloads (circles, mixed, rectangles/annular/lines, dense annular, two multiball) with level seeds |
| Corpus + tool inventory | `wiki/context/inventory.md`: 475-test suite, 9 local replays, level dumpers, trace exporters, `Perf`, existing bench mode; the "42-case matrix" does not exist upstream |
| Lua throughput measurement | `harness/` (LÖVE swap harness), `scripts/run_baseline.sh`, `results/20261003T093826Z_omarchy.summary.json` |
| Continuing metrics | `wiki/benchmarks/baseline-metrics.md`: phase-split sweep time, warm throughput, cold start, memory, campaign sizing, comparison protocol |

## Measured baseline (this laptop, LuaJIT + LÖVE 11.5)

- Grid validation: 1801 indices, 0 snapping mismatches; determinism spot
  checks 0 mismatches in every workload.
- Run: 37,821 candidates, 37,821 completed, 0 incomplete, 1570 s → **24.1 candidates/s**.
- Per candidate, p50: `annular_dense` init **81 ms** vs sim 5.5 ms;
  `lines_rect_annular` init 1.0 ms vs sim 2.8 ms; multiball trade
  `lines_rect_annular_multi3` sim 30.3 ms.
- Removing per-candidate init via the M2 checkpoint would lift
  `annular_dense` from 11.5 to ~180 candidates/s (~15x).
- Memory: Lua heap 0.7 → 6.3 MiB over the campaign; RSS +20 MiB. No
  fixed-capacity stepping exists yet.
- Cold start: 120 ms process age at harness load.

Caveats: the host was thermally throttled (94.5 °C) and shared with the
desktop session; repeat 3 slowed ~35%. Engine determinism was unaffected.
Dedicated benchmark hardware remains deferred, per the plan.

## Decisions recorded

- Reference is the committed `d17f6e7`; uncommitted WIP edits to
  `src/systems/path.lua` and `src/systems/physics.lua` are excluded. Committing
  them requires advancing the pin and re-capturing baselines.
- `toi_epsilon = 1e-9` and current tie-breaking stay; no physics change.
- Default shot end is the bench boundary (balls removed). `--clearing on`
  measures the full end-of-turn clearing to the next ready-to-aim boundary.
- Moving/path-driven levels (`level1`, `benchmark_lasagna`,
  `advanced_circuits`, `slide_rotating`) are deferred to M8.

## Follow-ups

- M1: extend `tools/dump_level.lua` into the versioned interchange; define
  the fixture matrix in place of the non-existent 42-case matrix; SVG previews.
- M2: implement the explicit checkpoint (RNG, purple queue, bucket phase) so
  candidate evaluation stops paying the dense-level init cost.
- M3: compare the first Julia sweep against `results/20261003T093826Z_omarchy.summary.json`.
