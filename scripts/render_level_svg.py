#!/usr/bin/env python3
"""Render a standalone SVG preview from a peggle.level.v1 artifact.

No Julia code and no game runtime are involved: the artifact's static peg
geometry is drawn directly, so previews work on headless servers and can be
collected into contact sheets.

Usage:
  scripts/render_level_svg.py LEVEL.json --out PREVIEW.svg [--config CONFIG.json]
  scripts/render_level_svg.py --all [--interchange DIR]
"""

import argparse
import glob
import html
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)

DEFAULT_COLORS = {
    "blue": (0.30, 0.55, 1.00),
    "red": (1.00, 0.30, 0.30),
    "purple": (0.70, 0.30, 1.00),
    "green": (0.30, 1.00, 0.45),
}


def fmt(value):
    return f"{value:.10g}"


def color_of(peg_type, colors):
    rgb = colors.get(peg_type, DEFAULT_COLORS.get(peg_type, (1.0, 1.0, 1.0)))
    return "rgb({},{},{})".format(
        max(0, min(255, round(rgb[0] * 255))),
        max(0, min(255, round(rgb[1] * 255))),
        max(0, min(255, round(rgb[2] * 255))),
    )


def load_colors(config_path):
    if not config_path or not os.path.exists(config_path):
        return {}
    with open(config_path, "r", encoding="utf-8") as handle:
        artifact = json.load(handle)
    peg_types = artifact.get("values", {}).get("peg_types", {})
    return {name: definition.get("color", (1, 1, 1)) for name, definition in peg_types.items()}


def annular_path(peg):
    cx, cy = peg["x"], peg["y"]
    r_in, r_out = peg["r_in"], peg["r_out"]
    start, end = peg["theta_start"], peg["theta_end_abs"]
    sweep = end - start
    two_pi = 2 * math.pi

    def point(radius, theta):
        return (cx + radius * math.cos(theta), cy + radius * math.sin(theta))

    if sweep >= two_pi - 1e-9:
        # Full ring: outer circle plus inner circle with even-odd fill. The
        # relative arc displacements must be diametric chords through the peg
        # center, so each pair of semicircles shares the center (cx, cy).
        return (
            f"M {fmt(cx + r_out)} {fmt(cy)} "
            f"a {fmt(r_out)} {fmt(r_out)} 0 1 1 {fmt(-2 * r_out)} 0 "
            f"a {fmt(r_out)} {fmt(r_out)} 0 1 1 {fmt(2 * r_out)} 0 Z "
            f"M {fmt(cx + r_in)} {fmt(cy)} "
            f"a {fmt(r_in)} {fmt(r_in)} 0 1 1 {fmt(-2 * r_in)} 0 "
            f"a {fmt(r_in)} {fmt(r_in)} 0 1 1 {fmt(2 * r_in)} 0 Z"
        )
    large = 1 if sweep > math.pi else 0
    ox0, oy0 = point(r_out, start)
    ox1, oy1 = point(r_out, end)
    ix1, iy1 = point(r_in, end)
    ix0, iy0 = point(r_in, start)
    return (
        f"M {fmt(ox0)} {fmt(oy0)} "
        f"A {fmt(r_out)} {fmt(r_out)} 0 {large} 1 {fmt(ox1)} {fmt(oy1)} "
        f"L {fmt(ix1)} {fmt(iy1)} "
        f"A {fmt(r_in)} {fmt(r_in)} 0 {large} 0 {fmt(ix0)} {fmt(iy0)} Z"
    )


def render(artifact, colors, show_lines=True):
    width = artifact["virtual_width"]
    height = artifact["virtual_height"]
    pegs = artifact["pegs"]
    lines = []
    lines.append(
        '<?xml version="1.0" encoding="UTF-8"?>'
    )
    lines.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" '
        f'width="{fmt(width)}" height="{fmt(height)}" '
        f'viewBox="0 0 {fmt(width)} {fmt(height)}" '
        f'data-level="{html.escape(artifact["name"])}" '
        f'data-schema-version="{artifact["schema_version"]}">'
    )
    lines.append(
        f"<title>{html.escape(artifact['name'])} level preview</title>"
    )
    lines.append(
        f'<rect x="0" y="0" width="{fmt(width)}" height="{fmt(height)}" '
        f'fill="#1a1a26"/>'
    )

    if show_lines:
        groups = {}
        for peg in pegs:
            line = peg.get("line")
            # Annular peg centers are arc centers, not surface positions, so a
            # centerline polyline is meaningless for annular lines.
            if line is None or peg["shape"] == "annular":
                continue
            groups.setdefault(line["id"], []).append(peg)
        for line_id, members in groups.items():
            members.sort(key=lambda peg: peg["line"]["index"])
            points = " ".join(f"{fmt(p['x'])},{fmt(p['y'])}" for p in members)
            lines.append(
                f'<polyline points="{points}" fill="none" stroke="#3c3c55" '
                f'stroke-width="1.5" data-line="{html.escape(line_id)}"/>'
            )

    for peg in pegs:
        fill = color_of(peg["type"], colors)
        shape = peg["shape"]
        attrs = f'fill="{fill}" stroke="#0d0d14" stroke-width="0.8"'
        if shape == "circle":
            lines.append(
                f'<circle cx="{fmt(peg["x"])}" cy="{fmt(peg["y"])}" '
                f'r="{fmt(peg["radius"])}" {attrs}/>'
            )
        elif shape == "rectangle":
            deg = math.degrees(peg["angle"])
            lines.append(
                f'<rect x="{fmt(-peg["width"] / 2)}" y="{fmt(-peg["height"] / 2)}" '
                f'width="{fmt(peg["width"])}" height="{fmt(peg["height"])}" '
                f'transform="translate({fmt(peg["x"])} {fmt(peg["y"])}) '
                f'rotate({fmt(deg)})" {attrs}/>'
            )
        elif shape == "annular":
            lines.append(
                f'<path d="{annular_path(peg)}" fill-rule="evenodd" {attrs}/>'
            )
        else:
            raise ValueError(f"unknown peg shape {shape!r}")

    launch_x = width / 2
    lines.append(
        f'<path d="M {fmt(launch_x - 7)} 38 L {fmt(launch_x + 7)} 38 '
        f'L {fmt(launch_x)} 52 Z" fill="#e8e8f0" opacity="0.85"/>'
    )
    lines.append(
        f'<text x="10" y="{fmt(height - 12)}" fill="#8a8aa0" '
        f'font-family="monospace" font-size="13">'
        f'{html.escape(artifact["name"])} | {fmt(width)}x{fmt(height)} | '
        f'{len(pegs)} pegs | static | seed {artifact["level_seed"]}'
        f"</text>"
    )
    lines.append("</svg>")
    return "\n".join(lines) + "\n"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("level", nargs="?", help="peggle.level.v1 artifact")
    parser.add_argument("--out", help="output SVG path")
    parser.add_argument("--config", help="peggle.config.v1 artifact for colors")
    parser.add_argument(
        "--all", action="store_true",
        help="render every interchange/levels/*.v1.json to interchange/previews/",
    )
    parser.add_argument(
        "--interchange",
        default=os.path.join(REPO_ROOT, "interchange"),
        help="interchange directory used by --all",
    )
    parser.add_argument("--no-lines", action="store_true", help="hide line centerlines")
    args = parser.parse_args(argv)

    colors = load_colors(args.config or os.path.join(args.interchange, "config.v1.json"))

    jobs = []
    if args.all:
        pattern = os.path.join(args.interchange, "levels", "*.v1.json")
        for path in sorted(glob.glob(pattern)):
            name = os.path.basename(path)[: -len(".v1.json")]
            out = os.path.join(args.interchange, "previews", name + ".svg")
            jobs.append((path, out))
    else:
        if not args.level:
            parser.error("LEVEL or --all is required")
        if not args.out:
            parser.error("--out is required with LEVEL")
        jobs.append((args.level, args.out))

    for level_path, out_path in jobs:
        with open(level_path, "r", encoding="utf-8") as handle:
            artifact = json.load(handle)
        svg = render(artifact, colors, show_lines=not args.no_lines)
        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as handle:
            handle.write(svg)
        print(f"wrote {out_path} ({len(artifact['pegs'])} pegs)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
