# source/ — pinned v3 extraction geometry

`ribbon_waves_geometry.json` is a byte-for-byte copy of the final v3
extraction:

* `/home/kurapica/Projects/pevo/level_segment/ribbon_waves_geometry.json`
* SHA-256 `bc52e4282b9ee0c42fc20049f40ba18f6b3f52718a9b04616a786941a7e247ea`
* 225,726 bytes
* produced by `level_segment/extract_ribbon_waves.py` (one smooth centerline
  per ribbon, constant thickness, 3-point arcs per brick) **and** extended by
  the v3 path fit (one cubic Hermite least-squares spline per ribbon)
* copied by `scripts/capture_ribbon_waves.sh` (capture mode) and required to
  match upstream byte-for-byte in `--check` mode

It is **not** loaded by the Lua game or the Julia harness. It exists so the
corpus can be audited and regenerated, and it is the single source of the
world transform used by:

* the level generator `julia_clone/tools/generate_ribbon_waves_level.py`
  (→ `../peggle_evolved/src/levels/ribbon_waves.lua`), which now consumes
  `ribbons[].path` and emits exactly one `Lines.generate` line per ribbon,
* the mask checker `scripts/check_ribbon_waves_mask.py` (inverts the `world`
  block to compare the exported artifact in native pixel space).

## The v3 path block (`ribbons[].path`)

Each of the five ribbons carries a `path` object in addition to the legacy
`centerline`/`pieces`/`seams`/`alignment` diagnostics:

```json
"path": {
  "model": "cubic-hermite-lsq-spline-v1",
  "trim_px": 8.0,
  "knot_spacing_px": 35.0,
  "segment_count": 10,
  "fit_rms_px": 0.35574218136656327,
  "fit_max_px": 1.2838109408600644,
  "min_curvature_radius_px": 30.16317503523677,
  "segments": [ /* 10 cubic Hermite segments, native coordinates */ ]
}
```

The path is a 10-segment cubic Hermite least-squares spline fitted to the
extracted centreline. `trim_px = 8` native pixels are trimmed from each open
end; the knot spacing is 35 native px for every ribbon except `wave_2`
(60 native px). The level generator maps the cubic control points through the
same affine world transform as the pegs and feeds the resulting `Path` to
`Lines.generate`, so each ribbon is a single continuous zero-gap slide — the
same primitive used by `squiggly_circle` and `mustache`. It is no longer a
sequence of independent annular bricks.

Per-ribbon path statistics (fit RMS / max residual / minimum curvature radius,
native px):

| ribbon | knot spacing | fit RMS | fit max | min curvature radius |
| --- | ---: | ---: | ---: | ---: |
| `wave_1` | 35 | 0.355742 | 1.283811 | 30.163175 |
| `wave_2` | 60 | 1.797935 | 7.305845 | 27.662588 |
| `wave_3` | 35 | 0.314809 | 1.146097 | 73.780060 |
| `wave_4` | 35 | 0.325212 | 1.125157 | 72.797285 |
| `wave_5` | 35 | 0.225308 | 0.827568 | 52.324141 |

## Source images

| image | SHA-256 |
| --- | --- |
| `level_segment/level.png` (1545x1289 RGB) | `ab7bcbbe2ba8565923abfb864b1d4931e77ec091bc96d0c23645d3c96e9d29e9` |
| `level_segment/peg_mask.png` (binary) | `81edcd390bb37160325cce6979863a19aeb8f05527bb397b696279906f92c6f3` |

Do not edit this copy. A changed geometry means regenerating the Lua level,
re-exporting the artifact, re-capturing the traces, and refreshing every hash
in the fixture README.

## World block (the transform contract)

```json
"world": {
  "scale": 0.45454545454545453,
  "shooter_native": [772.5, 50.0],
  "virtual_width": 702.2727272727273,
  "virtual_height": 613.1818181818181,
  "ball_radius": 6.0,
  "peg_radius": 10.0
}
```

Forward (generator):

```
x_world = (x_native - 772.5) * scale + virtual_width  / 2
y_world = (y_native -  50.0) * scale + 50
r_world = r_native * scale
```

Inverse (mask checker):

```
x_native = 772.5 + (x_world - virtual_width  / 2) / scale
y_native =  50.0 + (y_world - 50) / scale
r_native = r_world / scale
```

Angles are unchanged. The transform is affine, so cubic path control points
map directly. The checker validates that
`virtual_width ≈ native_width * scale` and
`virtual_height ≈ 50 + (native_height - 50) * scale`, and that the artifact's
declared virtual size matches this block.

## Geometry layout

- `format`: `ribbon_waves.geometry.v1` (the upstream `provenance.version`
  still reads `geometry.v2`; the corpus's "v3" label refers to the
  path-bearing single-slide representation, not a new geometry `format`)
- `native_width` / `native_height` (and `image_size`): `1545 x 1289`
- `circles`: 53 entries, native coordinates and `r = 22`
- `ribbons`: 5 entries (`wave_1` … `wave_5`), each with one `centerline`,
  `thickness`, seam metadata, a `path` object (10 cubic Hermite segments),
  and a legacy `pieces` array (`8 / 8 / 11 / 11 / 8` = 46 annular pieces
  total)
- `type_counts`: `blue 73, green 1, purple 0, red 25` (colour intent only;
  the engine reassigns types from this pool)
- `provenance`: generator/extraction notes

**`pieces` are legacy diagnostics, not the level's collision pieces.** They
are the per-brick arc fits used by the v2 seam/colour analysis and by the
source geometry layout; the exported v3 level is generated from
`ribbons[].path` and contains 114 annular pegs grouped into 5 continuous
`Lines.generate` lines (`20 / 20 / 26 / 28 / 20`).

Coordinates are in screenshot pixels (x right, y down); the mask checkout
uses pixel centres `(i+0.5, j+0.5)`. Annular pieces follow
`vertex = (x + r*cos(theta), y + r*sin(theta))` with absolute radians and
`theta_end_abs > theta_start` (screen y down, so increasing theta sweeps
visually clockwise).

The mask checker deliberately rasterizes the **exported artifact**, not this
file: this file only supplies the world transform. Any geometry drift must
show up in the artifact check.
