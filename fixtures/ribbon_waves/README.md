# ribbon_waves fixture corpus (v5)

53 circles and five continuous zero-gap slides, reconstructed from the source
screenshot. Each slide has six body cubics plus two exact terminal arcs fitted
to the reference boundaries. All ten ends steepen outward. The user confirmed
the Lua level looks correct on 2026-10-24.

The board contains **133 pegs: 53 circles + 80 annular**, 16 annular sectors
per ribbon, `segments=16`, `gap=0`. The world transform and source extraction
are unchanged. Authoring now also requires `tools/ribbon_waves_ends.json`.

This is a dev-tree corpus, separate from the immutable pinned M1 reference.
`make check-all` does not recapture it. Use `scripts/capture_ribbon_waves.sh`
and its `--check` mode. Read [the current geometry documentation](../../wiki/context/ribbon-waves.md)
for the generator, fitting workflow, regression checks and visual evidence.

## Files

- `source/ribbon_waves_geometry.json`: byte-for-byte upstream extraction.
- `artifact/ribbon_waves.v1.json`: actual exported, validated game geometry.
- `config.dev.v1.json`: captured dev-tree config.
- `catalog.lua`: shot specifications; `workloads.lua`: benchmark workload.
- `expected/*.json`: Lua engine records, including artifact and trace hashes.
- `traces/*.jsonl`: canonical Lua gameplay traces, matched byte-for-byte in Julia.
- `mask_metrics.json`, `mask_diff.png`, `mask_diff_raw.png`: silhouette evidence.

## Shots

| Shot | Aim | Steps | Pegs hit | Spawned | Score |
| --- | ---: | ---: | ---: | ---: | ---: |
| `center` | 900 | 156 | 12 | 0 | 20,560 |
| `left_wall` | 1800 | 590 | 25 | 0 | 24,750 |
| `ribbon` | 80 | 265 | 6 | 0 | 900 |

The center shot is bucket-caught; the other two fall out. The left-wall shot
awards one slide style. The focused Julia suite passes 2,192 assertions, including outward-steepening
checks on the emitted terminal sectors and exact replay parity.

## Fidelity and provenance

Cleaned IoU is **0.966956** (previous incorrect ends: 0.939040); per-ribbon
IoU is 0.966024 / 0.910620 / 0.960684 / 0.956839 / 0.955757. Raw IoU is
0.954427. The unchanged wave_2 body fit remains the largest residual; the
0.97 overall / 0.95 per-ribbon fidelity reference is not fully reached.

Source geometry SHA-256:
`bc52e4282b9ee0c42fc20049f40ba18f6b3f52718a9b04616a786941a7e247ea`.
The authoring JSON additionally records the source mask hash. Generated Lua
comments record the authoring JSON hash. Exported artifact provenance records
the dev-tree revision/tree/config hashes; the generated level is an overlay,
not a claim that the dev tree is clean. Actual artifact and trace hashes are
stored in each expected record rather than duplicated here.

The final capture uses the user’s current gravity `700` and wall damping `1.0`;
these settings were preserved, not edited by the level correction.
