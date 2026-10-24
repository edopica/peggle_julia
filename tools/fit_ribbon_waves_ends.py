#!/usr/bin/env python3
"""Refit exact terminal arcs to reference band boundaries, not column midpoints.

Requires numpy, scipy and Pillow (available in ../level_segment/.venv).
Run from the repository root:
  ../level_segment/.venv/bin/python tools/fit_ribbon_waves_ends.py

Writes a candidate design and diagnostic overlay under tmp/ribbon-refit.
Review the overlay, then copy ends.json to tools/ribbon_waves_ends.json and
regenerate the level. Normal level generation needs only the standard library.
The six middle source cubics and their tangents remain fixed. Each outer arc
has two free parameters: radius and length. Its bend direction is prescribed;
its endpoint is free. Fit both offset sides and the flat end face against a
cleaned reference-mask signed distance field, using a robust least-squares loss.
"""
from pathlib import Path
import argparse
import json

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import (binary_closing, binary_fill_holes,
                           distance_transform_edt, map_coordinates)
from scipy.optimize import least_squares
import generate_ribbon_waves_level as g


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out-dir', type=Path, default=g.JULIA_ROOT / 'tmp/ribbon-refit')
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    geometry = g.JULIA_ROOT / 'fixtures/ribbon_waves/source/ribbon_waves_geometry.json'
    reference = g.JULIA_ROOT / 'fixtures/ribbon_waves/reference/peg_mask.png'
    raw = json.loads(geometry.read_text())
    mask = np.asarray(Image.open(reference).convert('L')) > 127
    y, x = np.mgrid[-3:4, -3:4]
    mask = binary_fill_holes(binary_closing(mask, structure=x*x+y*y <= 2.5**2))
    sdf = distance_transform_edt(~mask) - distance_transform_edt(mask)
    preview = Image.open(g.WORKSPACE / 'level_segment/level.png').convert('RGB')
    draw = ImageDraw.Draw(preview)
    design = {'description': 'Boundary-fitted exact terminal arcs; native-pixel radius and length. Anchored to six preserved body cubics; tips are free.',
              'geometry_sha256': g.sha256_file(geometry),
              'mask_sha256': g.sha256_file(reference), 'ribbons': {}}
    for ribbon in raw['ribbons']:
        ends = design['ribbons'][ribbon['id']] = {}
        segments = ribbon['path']['segments']
        half_thickness = ribbon['thickness'] * ribbon['alignment']['thickness_scale'] / 2
        for side in ('start', 'end'):
            index, t, sign = (1, 1, 1) if side == 'start' else (-2, 0, -1)
            anchor = np.array(g._cubic_point(segments[index], t))
            tangent = np.array(g._normalize(g._cubic_derivative(segments[index], t)))
            if side == 'start':
                tangent = -tangent
            normal = np.array([-tangent[1], tangent[0]])
            old_tip = np.array(segments[0]['p0'] if side == 'start' else segments[-1]['p1'])
            initial_length = np.linalg.norm(old_tip - anchor) * 1.12

            def points(parameters, fractions, offset=0):
                radius, length = parameters
                curvature = sign / radius
                angles = curvature * length * np.asarray(fractions)
                center = anchor + normal / curvature
                radial = -normal / curvature
                rotated = np.array([
                    np.cos(angles)*radial[0] - np.sin(angles)*radial[1],
                    np.sin(angles)*radial[0] + np.cos(angles)*radial[1]]).T
                return center + rotated * (1 + offset / radius)

            def residual(parameters):
                sides = np.concatenate([
                    points(parameters, np.linspace(.04, 1, 90), offset)
                    for offset in (-half_thickness, half_thickness)])
                a, b = [points(parameters, [1], offset)[0]
                        for offset in (-half_thickness, half_thickness)]
                face = a + (b-a) * np.linspace(.1, .9, 20)[:, None]
                samples = np.concatenate([sides, face])
                return map_coordinates(sdf, [samples[:, 1], samples[:, 0]], order=1)

            fit = least_squares(
                residual, [initial_length*1.2, initial_length],
                bounds=([half_thickness*2.1, initial_length*.8],
                        [initial_length*4, initial_length*1.3]),
                loss='soft_l1', f_scale=2, max_nfev=500, diff_step=1e-4)
            if not fit.success:
                raise RuntimeError(f'{ribbon["id"]} {side}: {fit.message}')
            radius, length = fit.x
            ends[side] = {'radius_native': float(radius), 'length_native': float(length)}
            print(ribbon['id'], side, ends[side],
                  'boundary RMS px:', float(np.sqrt(np.mean(residual(fit.x)**2))))
            for offset in (-half_thickness, half_thickness):
                draw.line([tuple(p) for p in points(fit.x, np.linspace(0, 1, 150), offset)],
                          fill=(0, 255, 255), width=2)
            draw.line([tuple(points(fit.x, [1], offset)[0])
                       for offset in (-half_thickness, half_thickness)], fill=(0, 255, 255), width=2)
    preview.save(args.out_dir / 'fitted-ends-overlay.png')
    (args.out_dir / 'ends.json').write_text(json.dumps(design, indent=2) + '\n')


if __name__ == '__main__':
    main()
