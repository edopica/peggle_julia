#!/usr/bin/env python3
"""Audit the design intent missing from the legacy terminal-curvature check.

Screen coordinates have y increasing downward. For these five upturned
ribbons, traversed left to right, both terminal regions need NEGATIVE signed
curvature. Absolute slope must increase when travelling from body to tip.
Sampling is diagnostic, not a formal curvature proof. No fixtures are changed.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import generate_ribbon_waves_level as generator


def audit(geometry):
    rows = []
    for ribbon in geometry["ribbons"]:
        for side, index in (("left", 0), ("right", -1)):
            segment = ribbon["segments"][index]
            steepness, curvature = [], []
            for i in range(201):
                t = 1 - i / 200 if side == "left" else i / 200
                dx, dy = generator.path_derivative(segment, t)
                if dx <= 0:
                    raise ValueError("Expected a regular left-to-right ribbon")
                steepness.append(abs(dy / dx))
                curvature.append(generator.path_curvature(segment, t))
            neighbor = ribbon["segments"][1 if side == "left" else -2]
            neighbor_k = generator.path_curvature(neighbor, 0 if side == "left" else 1)
            rows.append({
                "ribbon": ribbon["id"], "side": side,
                "body_steepness": steepness[0], "tip_steepness": steepness[-1],
                "curvature_min": min(curvature), "curvature_max": max(curvature),
                "neighbor_curvature_at_join": neighbor_k,
                "wrong_bend": max(curvature) >= 0,
                "flattens": any(b < a - 1e-9 for a, b in zip(steepness, steepness[1:])),
                "steepness_body_to_tip": steepness,
            })
    return rows


def write_plot(path, rows):
    # Standalone vector plot; values are measured, not a proposed reconstruction.
    svg = ['<svg xmlns="http://www.w3.org/2000/svg" width="840" height="850" viewBox="0 0 840 850">',
           '<rect width="840" height="850" fill="white"/>',
           '<g font-family="sans-serif" fill="#222">',
           '<text x="30" y="28" font-size="20">Ribbon steepness from body to tip</text>',
           '<text x="30" y="52" font-size="14">Measured |dy/dx|: every curve must rise toward its tip.</text>']
    scale = max(1, max(max(row['steepness_body_to_tip']) for row in rows))
    for n, row in enumerate(rows):
        x, y = 65 + (n % 2) * 410, 102 + (n // 2) * 148
        values = row["steepness_body_to_tip"]
        points = ' '.join(f'{x + 300*i/200:.2f},{y + 90 - 80*v/scale:.2f}' for i, v in enumerate(values))
        svg.extend([
            f'<text x="{x}" y="{y-12}" font-size="14">{row["ribbon"]} — {row["side"]}</text>',
            f'<path d="M{x},{y} V{y+90} H{x+300}" fill="none" stroke="#aaa"/>',
            f'<text x="{x-30}" y="{y+14}" font-size="11">{scale:.1f}</text>',
            f'<text x="{x-22}" y="{y+93}" font-size="11">0</text>',
            f'<polyline points="{points}" fill="none" stroke="#c33" stroke-width="3"/>',
            f'<text x="{x}" y="{y+110}" font-size="12">body {values[0]:.3f}</text>',
            f'<text x="{x+235}" y="{y+110}" font-size="12">tip {values[-1]:.3f}</text>',
        ])
    svg.append('</g></svg>')
    path.write_text('\n'.join(svg) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--geometry', type=Path, default=ROOT / 'fixtures/ribbon_waves/source/ribbon_waves_geometry.json')
    parser.add_argument('--out-dir', type=Path, default=ROOT / 'tmp/ribbon-slope-audit')
    parser.add_argument('--check', action='store_true', help='exit 1 if any end flattens or bends the wrong way')
    args = parser.parse_args()
    rows = audit(generator.load_geometry(args.geometry))
    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / 'metrics.json').write_text(json.dumps(rows, indent=2, allow_nan=False) + '\n')
    write_plot(args.out_dir / 'slopes.svg', rows)
    for row in rows:
        print(f'{row["ribbon"]} {row["side"]:5}: |slope| '
              f'{row["body_steepness"]:.4f} -> {row["tip_steepness"]:.4f}; '
              f'wrong_bend={row["wrong_bend"]}, flattens={row["flattens"]}')
    failed = sum(row['wrong_bend'] or row['flattens'] for row in rows)
    print(f'{failed}/{len(rows)} ends violate the design intent; outputs: {args.out_dir}')
    return int(args.check and failed > 0)


if __name__ == '__main__':
    raise SystemExit(main())
