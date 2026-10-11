# M3 mustache reference corpus

The M3 mustache corpus is the first Lua-vs-Julia gameplay-trace reference for
the full physics port. It contains five complete shots on the mustache level,
captured from the peggle_evolved **dev tree**. It lives under
`fixtures/mustache/` and is deliberately separate from the pinned M1 fixture
corpus. The durable corpus is captured and verified only by
`scripts/capture_m3_mustache.sh`. The snapshot comparison copies come from
`scripts/compare_m3_mustache.sh` (§5).

## 1. What the corpus contains

| File | Contents |
| --- | --- |
| `fixtures/mustache/catalog.lua` | 5 shot fixtures, all with `trace = true` |
| `fixtures/mustache/workloads.lua` | benchmark workload catalog (`mustache_full`) |
| `fixtures/mustache/artifact/mustache.v1.json` | level artifact (99 pegs: 27 circle, 72 annular) |
| `fixtures/mustache/config.dev.v1.json` | dev-tree config artifact |
| `fixtures/mustache/expected/<id>.json` | fixture records with real provenance |
| `fixtures/mustache/traces/<id>.jsonl` | snapshot-free canonical gameplay traces |

| Fixture | Aim | Category | Outcome | Steps | Spawned | Trace bytes | Trace SHA-256 (prefix) |
| --- | ---: | --- | --- | ---: | ---: | ---: | --- |
| `m3_mustache_center` | 900 | completion | `fell_out` | 922 | 0 | 369,646 | `ecdf5d80…` |
| `m3_mustache_left_wall` | 0 | power | `fell_out` | 1,507 | 2 | 2,621,421 | `1c4ef8a8…` |
| `m3_mustache_right_wall` | 1800 | style | `fell_out` | 886 | 0 | 363,408 | `c476084b…` |
| `m3_mustache_bucket` | 1680 | bucket | `bucket_caught` | 178 | 0 | 31,125 | `96ed1cc6…` |
| `m3_mustache_multiball` | 570 | multiball | `fell_out` | 1,797 | 6 | 10,193,965 | `8d74f0c0…` |

The bucket fixture catches the ball with 3 pegs hit and no power spawn. The
multiball fixture spawns 6 balls and no bucket catch. The `Steps` count equals
the number of trace event lines, because each trace writes one header plus one
line per fixed step.

The traces are written by `GameplayTraceExporter` with
`include_snapshot = false` (one JSONL header plus one line per fixed step).
Snapshots are excluded to bound repository size. The fixture records store the
trace path as `fixtures/traces/<id>.jsonl` (the harness's logical path
convention). The bytes live in `fixtures/mustache/traces/` and are located by
`--fixtures-traces`.

## 2. Why the dev tree

The corpus must come from `../peggle_evolved`, not from the vendored pinned
`reference/peggle_evolved/`:

- `src/levels/mustache.lua` is **untracked** in the dev tree (it exists only
  as a working-tree file), so it is not part of the pinned reference at all.
  The harness loads it through `--reference-dir ../peggle_evolved`.
- The dev config differs from the pinned artifact in exactly one key:
  `ball_ball_restitution = 0.7` (pinned: `0.8`).
- M3 ports from the dev tree sources. The pin is only a cross-check
  (`tmp/m3/INTERFACES.md`).

## 3. Not part of the pinned M1 corpus

`fixtures/mustache/` is auxiliary and intentionally outside the frozen M1/M2
corpus:

- `make check-all` re-captures `fixtures/catalog.lua` (with
  `scripts/capture_fixtures.sh`) and never touches `fixtures/mustache/`.
- `make check` (interchange reproducibility, schemas, contract tests) is
  unaffected.
- Two additive harness options enable the corpus. `--artifact-dir DIR`
  overrides the level-artifact directory for shot fixtures, and the default
  stays `repo_root/interchange/levels`. `--workloads FILE` overrides the
  workload catalog, and the default stays `harness/workloads.lua`. The pinned
  catalog cannot load the untracked mustache level, so the M3 benchmark passes
  `fixtures/mustache/workloads.lua` explicitly. M1 and M0 behavior is
  unchanged.

## 4. Capture and verify

```bash
scripts/capture_m3_mustache.sh          # re-export artifacts, capture records + traces
scripts/capture_m3_mustache.sh --check  # verify only; never writes the corpus
```

The script resolves paths from its own location, requires the dev tree and
`src/levels/mustache.lua`, and derives provenance at run time: `REV`/`TREE`
from `git -C ../peggle_evolved rev-parse`, config SHA-256 from
`../peggle_evolved/src/config.lua`. It then re-exports the level and config
artifacts (`tools/export_level.lua`, `tools/export_config.lua` with `--check`)
and runs the harness in fixture mode via `scripts/love.sh` with the mustache
catalog, output dirs, `--reference-dir`, `--artifact-dir`, and the resolved
provenance. The capture writes the snapshot-free records and traces of §1. In
`--check` mode, artifacts are re-exported to a temporary directory and
byte-compared with the committed files, and the harness receives `--check`, so
the corpus is never modified.

The capture is deterministic as long as the dev tree files are unchanged:
re-running it updates only `source.level_sha256` and the record hash when the
level artifact is re-exported with new provenance. The traces are byte-stable
because the physics and config are unchanged.

## 5. Lua-vs-Julia trace comparison

```bash
make m3-mustache                             # 5-fixture capture + control comparison
scripts/compare_m3_mustache.sh               # same, directly
scripts/compare_m3_mustache.sh --julia-only  # regenerate Julia traces; skip capture
make m3-trace                                # Julia snapshot traces, base fixtures only
```

The catalog-driven script is `scripts/compare_m3_mustache.sh`. It performs
these steps:

1. Read every traced shot fixture from `fixtures/mustache/catalog.lua`
   (5 entries).
2. Capture snapshot-enabled Lua traces into `tmp/m3/lua-snapshots/` (harness
   fixture mode, dev tree, `--artifact-dir`, resolved provenance).
3. Regenerate snapshot-enabled Julia traces and expected records into
   `results/m3/traces/` and `results/m3/expected/`.
4. Compare both corpora with `tools/compare_traces.py --control`. The left
   side pairs the Lua snapshot traces with the durable snapshot-free expected
   records. The right side is Julia.
5. Write `results/m3/mustache-compare.json`.

The durable corpus stays snapshot-free to bound repository size. The
snapshot-enabled copies are comparison artifacts under `tmp/m3/lua-snapshots/`
and `results/m3/`. The comparator requires a snapshot at every recorded step
on both sides. Incomplete coverage fails a control comparison.

Expected outputs in `results/m3/mustache-compare.json`:

| Report field | Value |
| --- | --- |
| `control.fixtures_compared` / `identical_fixtures` | 5 / 5 |
| `control.expected_records_identical` | `true` |
| `state_comparison.full` | 5 |
| `control.volatile_differences` | 0 |
| `failures`, `semantic_differences` | `[]` |

The full-state comparison covers every fixed step of every fixture: 922
(center), 1,507 (left_wall), 886 (right_wall), 178 (bucket), and 1,797
(multiball).

## 6. Full-grid agreement and benchmark

- Full candidate grid: 1,801/1,801 indices agree across 16 shared fields,
  and `first_divergent_candidate` is `null`
  (`results/m3/sweeps-compare-full.json`).
- Julia serial and parallel sweeps are bit-identical at every thread count.
- `spawned` is Julia-only in the sweep rows. The Lua raw format omits it. The
  multiball fixture covers spawn behavior in the trace comparison.
- `make m3-sweep` runs a stride-200 serial/parallel identity sweep
  (`results/m3/sweep-summary.json`).
- The benchmark numbers are in `wiki/benchmarks/m3-shot.md` and
  `results/m3/bench-report.json`.

## 7. Exact provenance

| Value | Current |
| --- | --- |
| `reference_revision` | `da752257f613abbd209f1aa1acdd37a5f9be05f5` |
| `reference_tree` | `61278edc5467bf8399c24f4af0fcf36d75cac6a2` |
| `config_sha256` | `a17e60b43b1437510a59ba59c8791b27600a4b7fd7d56bc5f9c18d3e94f114d9` |
| `level_sha256` (artifact file) | `ea33fadd70666980cf426fb4a2854f66c28d333fb9f1a57b15a282cfddd0f747` |
| Level seed / type counts | `20261011`, blue 80, green 3, purple 0, red 16 |

`source.level_sha256` hashes the artifact bytes, so any provenance change in
the artifact changes every fixture record even when the geometry is identical.
