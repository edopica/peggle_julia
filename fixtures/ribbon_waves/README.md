# ribbon_waves fixture corpus (v6)

53 circles and five continuous zero-gap ribbons, reconstructed from the source
screenshot. Since 2026-11-11 each path is one dev-tree `ribbon` line, cut at
the screenshot seams. The board has **99 gameplay pegs: 53 circles + 46 ribbon
pegs (138 annular collision pieces)**, with `segments=16` and `gap=0`. The
Lua level is maintained in peggle_evolved; do not regenerate it with
`tools/generate_ribbon_waves_level.py`, which emits the v5 layout. See
[ribbon pegs](../../wiki/context/ribbon-pegs.md) and
[the geometry notes](../../wiki/context/ribbon-waves.md).

This is a dev-tree corpus, separate from the immutable pinned M1 reference.
`make check-all` does not recapture it. Use `scripts/capture_ribbon_waves.sh`
and its `--check` mode.

## Files

- `source/ribbon_waves_geometry.json`: byte-for-byte upstream extraction.
- `artifact/ribbon_waves.v1.json`: actual exported, validated game geometry.
- `config.dev.v1.json`: captured dev-tree config.
- `catalog.lua`: shot specifications; `workloads.lua`: benchmark workload.
- `expected/*.json`: Lua engine records, including artifact and trace hashes.
- `traces/*.jsonl`: canonical Lua gameplay traces, matched byte-for-byte in Julia.
- `mask_metrics.json`, `mask_diff.png`, `mask_diff_raw.png`: silhouette evidence.

## Shots

| Shot | Aim | Steps | Reason | Pegs hit | Reds | Spawned | Score |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| `center` | 900 | 309 | fell_out | 17 | 5 | 2 | 10,540 |
| `left_wall` | 1800 | 551 | bucket_caught | 20 | 6 | 0 | 24,800 |
| `ribbon` | 80 | 142 | bucket_caught | 5 | 1 | 0 | 10,700 |

Julia reproduces all three records and traces byte-for-byte.

## Fidelity and provenance

Cleaned IoU is **0.963880**; per-ribbon IoU is 0.945089 / 0.902032 / 0.960266 /
0.956509 / 0.955793. Raw IoU is 0.951382. wave_2 remains the largest
residual.

Source geometry SHA-256:
`bc52e4282b9ee0c42fc20049f40ba18f6b3f52718a9b04616a786941a7e247ea`
(upstream now at `../level_segment/levels/ribbon_waves/`). Exported
artifact provenance records the dev-tree revision/tree/config hashes; the
working tree also carried uncommitted level edits (ribbon thickness 19.45/19.0),
so the provenance revision is not a clean-tree claim. Artifact and trace
hashes are stored in each expected record.
