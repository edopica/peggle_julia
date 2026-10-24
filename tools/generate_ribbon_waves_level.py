#!/usr/bin/env python3
"""Generate the playable ``ribbon_waves`` level from the canonical geometry.

The five ribbons are authored as **five continuous open paths**, each emitted
through one ``Lines.generate`` zero-gap annular line.  This is exactly the
``Path.new`` + ``Lines.generate`` primitive used by
``src/levels/squiggly_circle.lua`` and ``src/levels/mustache.lua``.  There are
no per-brick annular pegs and no seam insets: ``Lines.generate`` proves that
every neighbouring pair of generated annular pieces shares a full cap before
the level can load.

Terminal shape
--------------
The outer two fitted cubics at each end are replaced by a circular arc fitted
against the reference band's side boundaries and flat end face. Endpoints are
free to move: vertical silhouette midpoints are biased near an angled face.
The authored radii/lengths live in ribbon_waves_ends.json. Both ends have
negative screen-space curvature, increasing outward steepness, and G1 joins
to the unchanged six body cubics. The engine receives exact arc segments.

Geometry contract
-----------------
``level_segment/ribbon_waves_geometry.json`` (``ribbon_waves.geometry.v1``)
provides:

* 53 circle pegs in native coordinates (x, y, r);
* 5 ribbons (wave_1 .. wave_5), each with a native thickness,
  ``alignment.thickness_scale``, and a 10-segment cubic Hermite
  LSQ-spline ``path`` whose points are native coordinates.

The world transform is the accepted FIX_PLAN v2 mapping (peg radius 10, ball
radius 6):

    s = 10 / 22
    x_world = (x_native - 772.5) * s + virtual_width  / 2
    y_world = (y_native - 50.0) * s + 50.0
    virtual_width  = 1545 * s
    virtual_height = 50 + (1289 - 50) * s

The transform is affine, so cubic control points map directly.

Colour contract
---------------
``PegColors.init`` reassigns every peg from the seeded pool at ``setupLevel``;
positions and shapes are the real contract.  To keep the exported artifact's
authored counts stable, the first 25 circles are authored ``red``, the next
one ``green``, the remaining 27 ``blue``, and every generated annular peg is
``blue``.  ``type_counts`` authors only red/green/purple because the
engine/exporter derives ``blue = #pegs - red - green``.

Usage
-----
    python3 julia_clone/tools/generate_ribbon_waves_level.py
        [--geometry PATH] [--out PATH] [--seed 20261021]
        [--check] [--check-geometry] [--no-verify]

``--check-geometry`` only loads the pinned geometry, runs the terminal-shape
validation and gates it (no level I/O).  ``--check`` loads the existing output with
LuaJIT and verifies the emitted source, the five line groups, the annular
segment count, and the authored
counts without rewriting the file.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve()
JULIA_ROOT = SCRIPT_PATH.parents[1]          # .../julia_clone
WORKSPACE = SCRIPT_PATH.parents[2]           # .../pevo
PEGGLE_ROOT = WORKSPACE / "peggle_evolved"
DEFAULT_GEOMETRY = WORKSPACE / "level_segment" / "ribbon_waves_geometry.json"
DEFAULT_OUT = PEGGLE_ROOT / "src" / "levels" / "ribbon_waves.lua"

EXPECTED_FORMAT = "ribbon_waves.geometry.v1"
EXPECTED_GEOMETRY_SHA256 = (
    "bc52e4282b9ee0c42fc20049f40ba18f6b3f52718a9b04616a786941a7e247ea"
)
EXPECTED_CIRCLES = 53
EXPECTED_RIBBONS = 5
EXPECTED_SEGMENTS = 10
EXPECTED_LINE_IDS = ("wave_1", "wave_2", "wave_3", "wave_4", "wave_5")
EXPECTED_ANNULAR_SEGMENTS = 16
EXPECTED_RED = 25
EXPECTED_GREEN = 1
EXPECTED_PURPLE = 0

# FIX_PLAN v2 world transform.  The geometry's world block is validated
# against these constants so a silently retuned geometry cannot slip through.
SCALE = 10.0 / 22.0
SHOOTER_X = 772.5
SHOOTER_Y = 50.0
NATIVE_WIDTH = 1545.0
NATIVE_HEIGHT = 1289.0
VIRTUAL_WIDTH = NATIVE_WIDTH * SCALE
VIRTUAL_HEIGHT = 50.0 + (NATIVE_HEIGHT - SHOOTER_Y) * SCALE
PEG_RADIUS = 10.0
BALL_RADIUS = 6.0

JOIN_EPSILON = 1e-9
DEFAULT_SEED = 20261021

TERMINAL_DESIGN = SCRIPT_PATH.with_name("ribbon_waves_ends.json")
TERMINAL_JOIN_TOLERANCE = 1e-9


def die(message: str) -> None:
    sys.stderr.write("generate_ribbon_waves_level: " + message + "\n")
    raise SystemExit(1)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_number(value) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def require_number(obj: dict, key: str, where: str) -> float:
    value = obj.get(key)
    if not is_number(value):
        die(f"{where}.{key} must be a finite number (got {value!r})")
    return float(value)


def require_positive(obj: dict, key: str, where: str) -> float:
    value = require_number(obj, key, where)
    if value <= 0.0:
        die(f"{where}.{key} must be positive (got {value!r})")
    return value


def require_nonnegative(obj: dict, key: str, where: str) -> float:
    value = require_number(obj, key, where)
    if value < 0.0:
        die(f"{where}.{key} must be non-negative (got {value!r})")
    return value


def require_point(obj: dict, key: str, where: str) -> tuple[float, float]:
    value = obj.get(key)
    if not (
        isinstance(value, (list, tuple))
        and len(value) == 2
        and all(is_number(coordinate) for coordinate in value)
    ):
        die(f"{where}.{key} must be [x, y] finite coordinates (got {value!r})")
    return float(value[0]), float(value[1])


def require_dict(obj: dict, key: str, where: str) -> dict:
    value = obj.get(key)
    if not isinstance(value, dict):
        die(f"{where}.{key} must be an object (got {type(value).__name__})")
    return value


def require_list(obj: dict, key: str, where: str) -> list:
    value = obj.get(key)
    if not isinstance(value, list):
        die(f"{where}.{key} must be an array (got {type(value).__name__})")
    return value


def to_world(x_native: float, y_native: float) -> tuple[float, float]:
    """Map a native coordinate to world space (affine; control points too)."""
    return (
        (x_native - SHOOTER_X) * SCALE + VIRTUAL_WIDTH * 0.5,
        (y_native - SHOOTER_Y) * SCALE + 50.0,
    )


def _normalize(vector: tuple[float, float]) -> tuple[float, float]:
    length = math.hypot(vector[0], vector[1])
    if length <= 1e-12:
        die("terminal path has a zero-length tangent")
    return (vector[0] / length, vector[1] / length)


def _cubic_point(segment: dict, t: float):
    p0, c1, c2, p1 = (segment[key] for key in ("p0", "c1", "c2", "p1"))
    mt = 1.0 - t
    return (
        mt ** 3 * p0[0] + 3.0 * mt * mt * t * c1[0]
        + 3.0 * mt * t * t * c2[0] + t ** 3 * p1[0],
        mt ** 3 * p0[1] + 3.0 * mt * mt * t * c1[1]
        + 3.0 * mt * t * t * c2[1] + t ** 3 * p1[1],
    )


def _cubic_derivative(segment: dict, t: float):
    p0, c1, c2, p1 = (segment[key] for key in ("p0", "c1", "c2", "p1"))
    mt = 1.0 - t
    return (
        3.0 * (mt * mt * (c1[0] - p0[0]) + 2.0 * mt * t * (c2[0] - c1[0])
               + t * t * (p1[0] - c2[0])),
        3.0 * (mt * mt * (c1[1] - p0[1]) + 2.0 * mt * t * (c2[1] - c1[1])
               + t * t * (p1[1] - c2[1])),
    )


# ---------------------------------------------------------------------------
# Terminal shape and shared path evaluation
# ---------------------------------------------------------------------------
def _cubic_second_derivative(segment: dict, t: float):
    p0, c1, c2, p1 = (segment[key] for key in ("p0", "c1", "c2", "p1"))
    mt = 1.0 - t
    return (
        6.0 * (mt * (c2[0] - 2.0 * c1[0] + p0[0])
               + t * (p1[0] - 2.0 * c2[0] + c1[0])),
        6.0 * (mt * (c2[1] - 2.0 * c1[1] + p0[1])
               + t * (p1[1] - 2.0 * c2[1] + c1[1])),
    )


def _cubic_curvature(segment: dict, t: float) -> float:
    """Signed curvature of a cubic at parameter t (positive = left turn)."""
    d1 = _cubic_derivative(segment, t)
    d2 = _cubic_second_derivative(segment, t)
    speed_squared = d1[0] * d1[0] + d1[1] * d1[1]
    if speed_squared <= 1e-24:
        die("terminal cubic has a zero-length derivative")
    return (d1[0] * d2[1] - d1[1] * d2[0]) / speed_squared ** 1.5


def path_point(segment: dict, t: float):
    if segment.get("kind") != "arc":
        return _cubic_point(segment, t)
    theta = segment["theta_start"] + t * segment["sweep"]
    return (segment["center"][0] + segment["radius"] * math.cos(theta),
            segment["center"][1] + segment["radius"] * math.sin(theta))


def path_derivative(segment: dict, t: float):
    if segment.get("kind") != "arc":
        return _cubic_derivative(segment, t)
    theta = segment["theta_start"] + t * segment["sweep"]
    speed = segment["radius"] * segment["sweep"]
    return (-speed * math.sin(theta), speed * math.cos(theta))


def path_curvature(segment: dict, t: float):
    if segment.get("kind") != "arc":
        return _cubic_curvature(segment, t)
    return math.copysign(1.0 / segment["radius"], segment["sweep"])


def _repair_terminal_cubics(segments: list, design: dict, where: str):
    """Replace two cubics at either end with a boundary-fitted exact arc."""
    repaired = [dict(segment) for segment in segments[2:-2]]
    stats = {}
    for label in ("start", "end"):
        native = design[label]
        radius = require_positive(native, "radius_native", where) * SCALE
        length = require_positive(native, "length_native", where) * SCALE
        # Anchor to the preserved body, never to a biased tip midpoint.
        body = repaired[0] if label == "start" else repaired[-1]
        t = 0.0 if label == "start" else 1.0
        anchor = path_point(body, t)
        tangent = _normalize(path_derivative(body, t))
        center = (anchor[0] + radius * tangent[1],
                  anchor[1] - radius * tangent[0])
        theta = math.atan2(anchor[1] - center[1], anchor[0] - center[0])
        sweep = -length / radius
        arc = {"kind": "arc", "center": center, "radius": radius,
               "theta_start": theta - sweep if label == "start" else theta,
               "sweep": sweep}
        tip_t = 0.0 if label == "start" else 1.0
        tip = path_point(arc, tip_t)
        tip_tangent = path_derivative(arc, tip_t)
        old_tip = segments[0]["p0"] if label == "start" else segments[-1]["p1"]
        stats[label] = {
            "curvature": -1.0 / radius, "radius": radius,
            "tip_tangent": math.degrees(math.atan2(tip_tangent[1], tip_tangent[0])),
            "tip": tip, "deviation": math.dist(tip, old_tip),
        }
        if path_curvature(body, t) >= 0:
            die(f"{where} {label}: body reverses curvature at the terminal join")
        if label == "start":
            repaired.insert(0, arc)
        else:
            repaired.append(arc)

    for a, b in zip(repaired, repaired[1:]):
        if math.dist(path_point(a, 1), path_point(b, 0)) > 1e-9:
            die(f"{where}: discontinuous terminal join")
        ta = _normalize(path_derivative(a, 1))
        tb = _normalize(path_derivative(b, 0))
        if math.dist(ta, tb) > TERMINAL_JOIN_TOLERANCE:
            die(f"{where}: terminal join is not tangent-continuous")
    for label, arc in (("start", repaired[0]), ("end", repaired[-1])):
        # Exact angle bounds prove the whole arc stays in its outward-steepening
        # quadrant, including between diagnostic samples (screen y is down).
        lower, upper = (math.pi / 2, math.pi) if label == "start" else (0, math.pi / 2)
        if not lower < arc["theta_start"] + arc["sweep"] < arc["theta_start"] < upper:
            die(f"{where} {label}: terminal arc leaves its upward-bending quadrant")
        previous = -1.0
        for i in range(201):
            t = 1 - i / 200 if label == "start" else i / 200
            dx, dy = path_derivative(arc, t)
            steepness = abs(dy / dx)
            if dx <= 0 or path_curvature(arc, t) >= 0 or steepness < previous - 1e-9:
                die(f"{where} {label}: terminal must steepen outward without reversing")
            previous = steepness
    return repaired, stats

def lua_ident(raw: str) -> str:
    """Turn a geometry id into a safe, unique Lua identifier fragment."""
    ident = re.sub(r"[^0-9A-Za-z_]", "_", raw)
    if not ident or ident[0].isdigit():
        ident = "_" + ident
    return ident


def authored_circle_type(index: int) -> str:
    """Positional circle colours: 25 red, 1 green, 27 blue."""
    if index < EXPECTED_RED:
        return "red"
    if index == EXPECTED_RED:
        return "green"
    return "blue"


# ---------------------------------------------------------------------------
# Geometry loading and validation
# ---------------------------------------------------------------------------
def load_geometry(path: Path) -> dict:
    try:
        raw_bytes = path.read_bytes()
    except FileNotFoundError:
        die(f"geometry not found: {path}")
    except OSError as exc:
        die(f"cannot read geometry {path}: {exc}")

    sha256 = hashlib.sha256(raw_bytes).hexdigest()
    try:
        terminal_design = json.loads(TERMINAL_DESIGN.read_text())
    except (OSError, ValueError) as exc:
        die(f"cannot read terminal design {TERMINAL_DESIGN}: {exc}")
    if terminal_design.get("geometry_sha256") != sha256:
        die("terminal design was fitted against different source geometry; refit it first")
    try:
        data = json.loads(raw_bytes.decode("utf-8"))
    except UnicodeDecodeError as exc:
        die(f"geometry {path} is not UTF-8: {exc}")
    except json.JSONDecodeError as exc:
        die(f"geometry {path} is not valid JSON: {exc}")

    if not isinstance(data, dict):
        die(f"geometry {path} must be a JSON object")
    if data.get("format") != EXPECTED_FORMAT:
        die(
            f"geometry format is {data.get('format')!r}; expected "
            f"{EXPECTED_FORMAT!r}"
        )

    world = require_dict(data, "world", "geometry")
    scale = require_number(world, "scale", "world")
    shooter_x, shooter_y = require_point(world, "shooter_native", "world")
    virtual_width = require_number(world, "virtual_width", "world")
    virtual_height = require_number(world, "virtual_height", "world")
    peg_radius = require_number(world, "peg_radius", "world")
    ball_radius_raw = world.get("ball_radius")
    if ball_radius_raw is None:
        sys.stderr.write(
            "generate_ribbon_waves_level: WARNING: world.ball_radius is "
            f"missing; using {BALL_RADIUS!r}\n"
        )
        ball_radius = BALL_RADIUS
    else:
        if not is_number(ball_radius_raw):
            die(f"world.ball_radius must be a finite number (got {ball_radius_raw!r})")
        ball_radius = float(ball_radius_raw)

    world_checks = (
        ("world.scale", scale, SCALE, 1e-12),
        ("world.shooter_native.x", shooter_x, SHOOTER_X, 1e-9),
        ("world.shooter_native.y", shooter_y, SHOOTER_Y, 1e-9),
        ("world.virtual_width", virtual_width, VIRTUAL_WIDTH, 1e-9),
        ("world.virtual_height", virtual_height, VIRTUAL_HEIGHT, 1e-9),
        ("world.peg_radius", peg_radius, PEG_RADIUS, 1e-9),
        ("world.ball_radius", ball_radius, BALL_RADIUS, 1e-9),
    )
    for label, actual, expected, tolerance in world_checks:
        if abs(actual - expected) > tolerance:
            die(
                f"{label} = {actual!r} does not match the accepted world "
                f"transform value {expected!r}"
            )

    circles_raw = require_list(data, "circles", "geometry")
    if len(circles_raw) != EXPECTED_CIRCLES:
        die(
            f"geometry must contain exactly {EXPECTED_CIRCLES} circle pegs; "
            f"got {len(circles_raw)}"
        )

    circles = []
    for index, circle in enumerate(circles_raw):
        where = f"circles[{index}]"
        if not isinstance(circle, dict):
            die(f"{where} must be an object")
        x_native = require_number(circle, "x", where)
        y_native = require_number(circle, "y", where)
        r_native = require_positive(circle, "r", where)
        expected_r = PEG_RADIUS / SCALE
        if abs(r_native - expected_r) > 1e-6:
            die(
                f"{where}.r = {r_native!r} does not map to world peg radius "
                f"{PEG_RADIUS!r} (native should be {expected_r!r})"
            )
        x_world, y_world = to_world(x_native, y_native)
        # Mirror Validator.is_out_of_bounds for circles: walls and ceiling.
        if (
            x_world - PEG_RADIUS < 0.0
            or x_world + PEG_RADIUS > VIRTUAL_WIDTH
            or y_world - PEG_RADIUS < 0.0
        ):
            die(f"{where} maps outside the playfield at ({x_world}, {y_world})")
        circles.append(
            {
                "index": index,
                "x_native": x_native,
                "y_native": y_native,
                "r_native": r_native,
                "x": x_world,
                "y": y_world,
            }
        )

    ribbons_raw = require_list(data, "ribbons", "geometry")
    if len(ribbons_raw) != EXPECTED_RIBBONS:
        die(
            f"geometry must contain exactly {EXPECTED_RIBBONS} ribbons; "
            f"got {len(ribbons_raw)}"
        )

    ribbons = []
    seen_ids = set()
    seen_idents = {}
    declared_thickness = world.get("ribbon_thickness_world")
    thickness_mismatches = []
    for ribbon_index, ribbon in enumerate(ribbons_raw):
        where = f"ribbons[{ribbon_index}]"
        if not isinstance(ribbon, dict):
            die(f"{where} must be an object")
        ribbon_id = ribbon.get("id")
        if not isinstance(ribbon_id, str) or not ribbon_id:
            die(f"{where}.id must be a non-empty string (got {ribbon_id!r})")
        if ribbon_id in seen_ids:
            die(f"duplicate ribbon id {ribbon_id!r}")
        seen_ids.add(ribbon_id)
        ident = lua_ident(ribbon_id)
        if ident in seen_idents:
            die(
                f"ribbon ids {seen_idents[ident]!r} and {ribbon_id!r} both "
                f"sanitise to Lua identifier {ident!r}"
            )
        seen_idents[ident] = ribbon_id

        thickness = require_positive(ribbon, "thickness", where)
        alignment = require_dict(ribbon, "alignment", where)
        thickness_scale = require_positive(
            alignment, "thickness_scale", f"{where}.alignment"
        )
        thickness_world = thickness * thickness_scale * SCALE
        if not math.isfinite(thickness_world) or thickness_world <= 0.0:
            die(f"{where} produces a non-positive world thickness")
        if isinstance(declared_thickness, dict):
            declared = declared_thickness.get(ribbon_id)
            if is_number(declared) and abs(float(declared) - thickness_world) > 1e-9:
                thickness_mismatches.append(
                    f"{ribbon_id} (declared {float(declared)!r}, "
                    f"formula {thickness_world!r})"
                )

        ribbon_path = require_dict(ribbon, "path", where)
        model = ribbon_path.get("model")
        if model != "cubic-hermite-lsq-spline-v1":
            die(f"{where}.path.model is {model!r}; expected "
                "'cubic-hermite-lsq-spline-v1'")
        segment_count = require_number(
            ribbon_path, "segment_count", f"{where}.path"
        )
        if int(segment_count) != EXPECTED_SEGMENTS or segment_count != EXPECTED_SEGMENTS:
            die(
                f"{where}.path.segment_count = {segment_count!r}; expected "
                f"{EXPECTED_SEGMENTS}"
            )
        trim_px = require_nonnegative(ribbon_path, "trim_px", f"{where}.path")
        knot_spacing_px = require_positive(
            ribbon_path, "knot_spacing_px", f"{where}.path"
        )
        fit_rms_px = require_nonnegative(
            ribbon_path, "fit_rms_px", f"{where}.path"
        )
        fit_max_px = require_nonnegative(
            ribbon_path, "fit_max_px", f"{where}.path"
        )
        min_curvature_radius_px = require_positive(
            ribbon_path, "min_curvature_radius_px", f"{where}.path"
        )
        segments_raw = require_list(ribbon_path, "segments", f"{where}.path")
        if len(segments_raw) != EXPECTED_SEGMENTS:
            die(
                f"{where}.path.segments has {len(segments_raw)} segments; "
                f"expected {EXPECTED_SEGMENTS}"
            )

        world_segments = []
        previous_p1 = None
        for segment_index, segment in enumerate(segments_raw):
            seg_where = f"{where}.path.segments[{segment_index}]"
            if not isinstance(segment, dict):
                die(f"{seg_where} must be an object")
            p0 = require_point(segment, "p0", seg_where)
            c1 = require_point(segment, "c1", seg_where)
            c2 = require_point(segment, "c2", seg_where)
            p1 = require_point(segment, "p1", seg_where)
            if previous_p1 is not None:
                join_error = math.hypot(
                    p0[0] - previous_p1[0], p0[1] - previous_p1[1]
                )
                if join_error > JOIN_EPSILON:
                    die(
                        f"{where}.path segments {segment_index - 1} and "
                        f"{segment_index} are discontinuous by "
                        f"{join_error:g} native px (p1 != next p0)"
                    )
            previous_p1 = p1
            world_segments.append(
                {
                    "p0": to_world(*p0),
                    "c1": to_world(*c1),
                    "c2": to_world(*c2),
                    "p1": to_world(*p1),
                }
            )

        # Refit the entire outer arm, including its freely positioned tip.
        world_segments, terminal = _repair_terminal_cubics(
            world_segments, terminal_design["ribbons"][ribbon_id],
            f"{where}.path"
        )

        ribbons.append(
            {
                "id": ribbon_id,
                "ident": ident,
                "thickness": thickness,
                "thickness_scale": thickness_scale,
                "thickness_world": thickness_world,
                "trim_px": trim_px,
                "knot_spacing_px": knot_spacing_px,
                "fit_rms_px": fit_rms_px,
                "fit_max_px": fit_max_px,
                "min_curvature_radius_px": min_curvature_radius_px,
                "segments": world_segments,
                "terminal": terminal,
            }
        )

    if seen_ids != set(EXPECTED_LINE_IDS):
        missing = sorted(set(EXPECTED_LINE_IDS) - seen_ids)
        extra = sorted(seen_ids - set(EXPECTED_LINE_IDS))
        die(
            f"ribbon ids must be exactly {list(EXPECTED_LINE_IDS)}; "
            f"missing={missing}, extra={extra}"
        )

    # Stable wave_1 .. wave_5 emission order regardless of JSON order.
    order = {ribbon_id: index for index, ribbon_id in enumerate(EXPECTED_LINE_IDS)}
    ribbons.sort(key=lambda item: order[item["id"]])

    if thickness_mismatches:
        sys.stderr.write(
            "generate_ribbon_waves_level: WARNING: world.ribbon_thickness_world "
            "does not include alignment.thickness_scale for "
            + ", ".join(thickness_mismatches)
            + "; using thickness * alignment.thickness_scale * s as specified\n"
        )

    if sha256 != EXPECTED_GEOMETRY_SHA256:
        sys.stderr.write(
            "generate_ribbon_waves_level: WARNING: geometry sha256 "
            f"{sha256} differs from the canonical {EXPECTED_GEOMETRY_SHA256}\n"
        )

    return {
        "path": path,
        "sha256": sha256,
        "circles": circles,
        "ribbons": ribbons,
    }


# ---------------------------------------------------------------------------
# Lua emission
# ---------------------------------------------------------------------------
def fmt(value: float) -> str:
    """Shortest round-trip Lua numeric literal for a finite float."""
    number = float(value)
    if not math.isfinite(number):
        die(f"refusing to emit non-finite number {value!r}")
    if number == 0.0:
        return "0.0"  # avoid signed zero and keep float intent
    return repr(number)


def fmt_stat(value: float) -> str:
    """Human-readable header statistic (not used in executable code)."""
    text = f"{float(value):.6f}".rstrip("0").rstrip(".")
    return text if text else "0"


def lua_point(point: tuple[float, float]) -> str:
    return f"{{ x = {fmt(point[0])}, y = {fmt(point[1])} }}"


def render_level(geom: dict, out_path: Path, seed: int, counts: dict | None) -> str:
    lines = []

    def add(text: str = "") -> None:
        lines.append(text)

    add("-- Generated by julia_clone/tools/generate_ribbon_waves_level.py -- do not edit.")
    add("--")
    add("-- Regenerate with:")
    add(f"--   python3 {shlex.quote(str(SCRIPT_PATH))} \\")
    add(f"--       --geometry {shlex.quote(str(geom['path']))} \\")
    add(f"--       --out {shlex.quote(str(out_path))} \\")
    add(f"--       --seed {seed}")
    add("--")
    add(f"-- Geometry: {geom['path']}")
    add(f"--   sha256 {geom['sha256']}")
    add("--")
    add("-- World transform (native -> world):")
    add(f"--   s = {fmt(SCALE)} (10/22)")
    add(f"--   shooter_native = ({fmt(SHOOTER_X)}, {fmt(SHOOTER_Y)})")
    add(f"--   virtual_width  = 1545 * s = {fmt(VIRTUAL_WIDTH)}")
    add(f"--   virtual_height = 50 + (1289 - 50) * s = {fmt(VIRTUAL_HEIGHT)}")
    add("--   x_world = (x_native - shooter_x) * s + virtual_width / 2")
    add("--   y_world = (y_native - shooter_y) * s + 50")
    add(
        f"--   circle pegs: radius {fmt(PEG_RADIUS)} world (native 22.0); "
        f"ball radius {fmt(BALL_RADIUS)} world."
    )
    add("--   The transform is affine, so cubic control points map directly.")
    add("--")
    add("-- One Lines.generate zero-gap line per ribbon (ids wave_1..wave_5), exactly the squiggly_circle/mustache primitive; 5 continuous slides, not 46 bricks.")
    add("-- Each ribbon has six unchanged body cubics and two exact terminal arcs.")
    add("-- Terminal arcs fit the reference side boundaries and flat end faces;")
    add("-- endpoints may move. Both ends steepen outward with negative screen-space")
    add("-- curvature and tangent-continuous joins. No cap pegs are added.")
    add(f"-- Terminal design sha256: {sha256_file(TERMINAL_DESIGN)}")
    for ribbon in geom["ribbons"]:
        add(
            f"--   {ribbon['id']}: trim_px={fmt_stat(ribbon['trim_px'])}, "
            f"knot_spacing_px={fmt_stat(ribbon['knot_spacing_px'])}, "
            f"fit_rms={fmt_stat(ribbon['fit_rms_px'])} px, "
            f"fit_max={fmt_stat(ribbon['fit_max_px'])} px,"
        )
        add(
            f"--           min_curvature_radius={fmt_stat(ribbon['min_curvature_radius_px'])} px, "
            f"thickness={ribbon['thickness_world']:.6f} world"
        )
        start = ribbon["terminal"]["start"]
        end = ribbon["terminal"]["end"]
        add(
            f"--           terminal sectors: start k={start['curvature']:.6f} "
            f"world (R={fmt_stat(start['radius'])}), end k={end['curvature']:.6f} "
            f"world (R={fmt_stat(end['radius'])}); "
            f"tip displacement {fmt_stat(max(start['deviation'], end['deviation']))} world px"
        )
    add("-- Per-line authoring: segments = 16, curve_tolerance = 1.0, max_length = 40.0, gap = 0, closed = false.")
    add("--")
    if counts is not None:
        add(
            f"-- {EXPECTED_CIRCLES} circle pegs + {counts['annular']} generated annular "
            f"pegs = {counts['total']} total pegs."
        )
        add("-- Authored type_counts: red = 25, green = 1, purple = 0.")
        add(
            f"-- blue is derived by the engine/exporter as #pegs - red - green = "
            f"{counts['total'] - EXPECTED_RED - EXPECTED_GREEN}; no blue field is emitted."
        )
    else:
        add(
            f"-- {EXPECTED_CIRCLES} circle pegs + generated annular line pegs = total pegs."
        )
        add("-- N and total are established by loading the emitted level (see --check).")
        add("-- Authored type_counts: red = 25, green = 1, purple = 0.")
        add(
            "-- blue is derived by the engine/exporter as #pegs - red - green; "
            "no blue field is emitted."
        )
    add("--")
    add("-- The five ribbons are the only authored lines. Circle pegs carry no line")
    add("-- metadata. Colors are engine-assigned by PegColors.init from the seeded")
    add("-- pool; the authored types above only satisfy the artifact's count contract.")
    add("-- Positions and shapes are the contract.")
    add("--")
    add('local Peg = require("src.entities.peg")')
    add('local Path = require("src.systems.path")')
    add('local Lines = require("src.systems.lines")')
    add("")
    add("local pegs = {")
    for circle in geom["circles"]:
        peg_type = authored_circle_type(circle["index"])
        add(
            f'\tPeg.new({fmt(circle["x"])}, {fmt(circle["y"])}, "{peg_type}", '
            f'10.0), -- circles[{circle["index"]}] ({peg_type})'
        )
    add("}")
    add("")

    for ribbon in geom["ribbons"]:
        ident = ribbon["ident"]
        add(f"local path_{ident} = Path.new({{")
        add("\tsegments = {")
        for segment in ribbon["segments"]:
            if segment.get("kind") == "arc":
                add('\t\t{ kind = "arc", '
                    f"center = {lua_point(segment['center'])}, "
                    f"radius = {fmt(segment['radius'])}, "
                    f"theta_start = {fmt(segment['theta_start'])}, "
                    f"sweep = {fmt(segment['sweep'])} }},")
            else:
                add('\t\t{ kind = "cubic", '
                    f"p0 = {lua_point(segment['p0'])}, "
                    f"c1 = {lua_point(segment['c1'])}, "
                    f"c2 = {lua_point(segment['c2'])}, "
                    f"p1 = {lua_point(segment['p1'])} }},")
        add("\t},")
        add("})")
        add(f"local line_{ident} = Lines.generate({{")
        add(f'\tid = "{ribbon["id"]}",')
        add(f"\tpath = path_{ident},")
        add("\tpeg = {")
        add('\t\tkind = "annular",')
        add(f"\t\tthickness = {fmt(ribbon['thickness_world'])},")
        add("\t\tmax_length = 40.0,")
        add("\t\tsegments = 16,")
        add('\t\ttype = "blue",')
        add("\t},")
        add("\tgap = 0,")
        add("\tcurve_tolerance = 1.0,")
        add("})")
        add(f"for _, peg in ipairs(line_{ident}) do")
        add("\tpegs[#pegs + 1] = peg")
        add("end")
        add("")

    add("return {")
    add("\tpegs = pegs,")
    add(
        f"\ttype_counts = {{ red = {EXPECTED_RED}, green = {EXPECTED_GREEN}, "
        f"purple = {EXPECTED_PURPLE} }},"
    )
    add(f"\tlevel_seed = {seed},")
    add('\tname = "ribbon_waves",')
    add(f"\tvirtual_width = {fmt(VIRTUAL_WIDTH)},")
    add(f"\tvirtual_height = {fmt(VIRTUAL_HEIGHT)},")
    add("}")
    add("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Source-level verification
# ---------------------------------------------------------------------------
PEG_NEW_RE = re.compile(r"\bPeg\.new\(")
LINES_GENERATE_RE = re.compile(r"\bLines\.generate\(")
PEG_NEW_ANNULAR_RE = re.compile(r"\bPeg\.new_annular\(")


def strip_lua_comments(text: str) -> str:
    """Drop line comments; the generated level has no long comments/strings."""
    return "\n".join(line.split("--", 1)[0] for line in text.splitlines())


def source_counts(text: str) -> dict:
    code = strip_lua_comments(text)
    return {
        "Peg.new": len(PEG_NEW_RE.findall(code)),
        "Lines.generate": len(LINES_GENERATE_RE.findall(code)),
        "Peg.new_annular": len(PEG_NEW_ANNULAR_RE.findall(code)),
    }


def check_source(text: str) -> tuple[dict, list[str]]:
    counts = source_counts(text)
    errors = []
    if counts["Peg.new"] != EXPECTED_CIRCLES:
        errors.append(
            f"emitted source has {counts['Peg.new']} Peg.new(...) calls; "
            f"expected {EXPECTED_CIRCLES}"
        )
    if counts["Lines.generate"] != EXPECTED_RIBBONS:
        errors.append(
            f"emitted source has {counts['Lines.generate']} Lines.generate(...) "
            f"calls; expected {EXPECTED_RIBBONS}"
        )
    if counts["Peg.new_annular"] != 0:
        errors.append(
            f"emitted source has {counts['Peg.new_annular']} direct "
            "Peg.new_annular(...) calls; expected 0 (Lines.generate owns them)"
        )
    return counts, errors


# ---------------------------------------------------------------------------
# Lua probe: load the level and dump a tab-separated structural summary
# ---------------------------------------------------------------------------
LUA_PROBE = r'''
local root = assert(arg[1], "game root")
local level_path = assert(arg[2], "level path")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local function fail(message)
	io.stderr:write("probe: " .. message .. "\n")
	os.exit(2)
end

local chunk, load_error = loadfile(level_path)
if not chunk then fail("loadfile: " .. tostring(load_error)) end
local ok, level = pcall(chunk)
if not ok then fail("load: " .. tostring(level)) end
if type(level) ~= "table" then fail("level did not return a table") end

local function v(value)
	if value == nil then return "-" end
	return tostring(value)
end

io.write("LEVEL\t", v(level.name), "\t", v(level.virtual_width), "\t",
	v(level.virtual_height), "\t", v(level.level_seed), "\n")
local type_counts = level.type_counts or {}
io.write("TC\tred\t", v(type_counts.red), "\n")
io.write("TC\tgreen\t", v(type_counts.green), "\n")
io.write("TC\tpurple\t", v(type_counts.purple), "\n")
io.write("TC\tblue\t", v(type_counts.blue), "\n")

local pegs = level.pegs or {}
for index, peg in ipairs(pegs) do
	local line = peg.line
	io.write("PEG\t", index, "\t", v(peg.shape or "circle"), "\t", v(peg.type),
		"\t", v(peg.radius), "\t", v(line and line.id), "\t",
		v(line and line.index), "\t", v(line and line.count), "\t",
		v(line and line.closed), "\t", v(line and line.gap), "\t",
		v(peg.segments), "\n")
end
io.write("END\t", #pegs, "\n")
'''


def run_probe(level_path: Path) -> tuple[str | None, str | None]:
    """Load *level_path* with LuaJIT; return (stdout, error_message)."""
    with tempfile.TemporaryDirectory(prefix="ribbon_waves_probe_") as tmpdir:
        probe_path = Path(tmpdir) / "probe.lua"
        probe_path.write_text(LUA_PROBE)
        try:
            proc = subprocess.run(
                ["luajit", str(probe_path), str(PEGGLE_ROOT), str(level_path)],
                cwd=str(PEGGLE_ROOT),
                text=True,
                capture_output=True,
                timeout=120,
            )
        except FileNotFoundError:
            return None, "luajit not found"
        except subprocess.TimeoutExpired:
            return None, "luajit probe timed out after 120 s"
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        return None, (
            f"luajit probe failed for {level_path} (exit {proc.returncode})"
            + (f":\n{detail}" if detail else "")
        )
    return proc.stdout, None


def _as_int(value: str, field: str):
    if value in (None, "-"):
        return None
    try:
        return int(float(value))
    except ValueError:
        die(f"probe: malformed integer for {field}: {value!r}")


def _as_float(value: str, field: str):
    if value in (None, "-"):
        return None
    try:
        return float(value)
    except ValueError:
        die(f"probe: malformed number for {field}: {value!r}")


def _as_bool(value: str, field: str):
    if value in (None, "-"):
        return None
    if value == "true":
        return True
    if value == "false":
        return False
    die(f"probe: malformed boolean for {field}: {value!r}")


def parse_probe(stdout: str) -> tuple[dict, dict, list[dict]]:
    meta = {}
    type_counts = {}
    pegs = []
    saw_end = False
    for raw_line in stdout.splitlines():
        if not raw_line:
            continue
        parts = raw_line.split("\t")
        kind = parts[0]
        if kind == "LEVEL":
            if len(parts) != 5:
                die(f"probe: malformed LEVEL line: {raw_line!r}")
            meta = {
                "name": parts[1],
                "virtual_width": _as_float(parts[2], "LEVEL.virtual_width"),
                "virtual_height": _as_float(parts[3], "LEVEL.virtual_height"),
                "level_seed": _as_int(parts[4], "LEVEL.level_seed"),
            }
        elif kind == "TC":
            if len(parts) != 3:
                die(f"probe: malformed TC line: {raw_line!r}")
            type_counts[parts[1]] = _as_int(parts[2], f"TC.{parts[1]}")
        elif kind == "PEG":
            if len(parts) != 11:
                die(f"probe: malformed PEG line: {raw_line!r}")
            pegs.append(
                {
                    "index": _as_int(parts[1], "PEG.index"),
                    "shape": parts[2],
                    "type": parts[3],
                    "radius": _as_float(parts[4], "PEG.radius"),
                    "line_id": None if parts[5] == "-" else parts[5],
                    "line_index": _as_int(parts[6], "PEG.line_index"),
                    "line_count": _as_int(parts[7], "PEG.line_count"),
                    "line_closed": _as_bool(parts[8], "PEG.line_closed"),
                    "line_gap": _as_float(parts[9], "PEG.line_gap"),
                    "segments": _as_int(parts[10], "PEG.segments"),
                }
            )
        elif kind == "END":
            if len(parts) != 2:
                die(f"probe: malformed END line: {raw_line!r}")
            meta["total"] = _as_int(parts[1], "END.total")
            saw_end = True
        # Ignore stray output (warnings, etc.); the structural fields above are
        # what the check consumes.
    if not saw_end:
        die("probe: output has no END record (level load incomplete)")
    return meta, type_counts, pegs


# ---------------------------------------------------------------------------
# Structural check shared by --check and the generation gate
# ---------------------------------------------------------------------------
def analyze(meta: dict, type_counts: dict, pegs: list[dict], source_text: str) -> dict:
    errors: list[str] = []

    src, src_errors = check_source(source_text)
    errors.extend(src_errors)

    if meta.get("name") != "ribbon_waves":
        errors.append(
            f"level name is {meta.get('name')!r}; expected 'ribbon_waves'"
        )
    for field, expected in (
        ("virtual_width", VIRTUAL_WIDTH),
        ("virtual_height", VIRTUAL_HEIGHT),
    ):
        value = meta.get(field)
        if value is None or abs(value - expected) > 1e-9:
            errors.append(
                f"level {field} is {value!r}; expected {expected!r}"
            )

    total = meta.get("total")
    if total is None:
        total = len(pegs)
    if total != len(pegs):
        errors.append(f"probe total {total} != loaded peg count {len(pegs)}")

    circles = [peg for peg in pegs if peg["shape"] == "circle"]
    annular = [peg for peg in pegs if peg["shape"] == "annular"]
    unknown_shapes = [peg for peg in pegs if peg["shape"] not in ("circle", "annular")]
    if len(circles) != EXPECTED_CIRCLES:
        errors.append(
            f"level has {len(circles)} circle pegs; expected {EXPECTED_CIRCLES}"
        )
    if unknown_shapes:
        errors.append(
            f"level has {len(unknown_shapes)} unsupported peg shapes: "
            + ", ".join(sorted({str(peg['shape']) for peg in unknown_shapes}))
        )
    if len(circles) + len(annular) != len(pegs):
        errors.append("level peg count does not equal circles + annular pegs")

    # Positional circle colour contract (authored colours; the engine shuffles
    # them later, but the artifact's authored counts must be stable).
    for position, peg in enumerate(circles):
        expected_type = authored_circle_type(position)
        if peg["type"] != expected_type:
            errors.append(
                f"circle peg {peg['index']} is authored {peg['type']!r}; "
                f"expected {expected_type!r} at circle position {position}"
            )
        if peg["line_id"] is not None:
            errors.append(
                f"circle peg {peg['index']} carries line metadata "
                f"{peg['line_id']!r}; expected line == nil"
            )
        if peg["radius"] is None or abs(peg["radius"] - PEG_RADIUS) > 1e-9:
            errors.append(
                f"circle peg {peg['index']} radius is {peg['radius']!r}; "
                f"expected {PEG_RADIUS!r}"
            )

    groups: dict[str, list[dict]] = {}
    for peg in annular:
        if peg["line_id"] is None:
            errors.append(
                f"annular peg {peg['index']} has no line metadata"
            )
            continue
        if peg["type"] != "blue":
            errors.append(
                f"annular peg {peg['index']} is authored {peg['type']!r}; "
                "expected 'blue'"
            )
        if peg["segments"] != EXPECTED_ANNULAR_SEGMENTS:
            errors.append(
                f"annular peg {peg['index']} segments is {peg['segments']!r}; "
                f"expected {EXPECTED_ANNULAR_SEGMENTS}"
            )
        if peg["line_gap"] != 0:
            errors.append(
                f"annular peg {peg['index']} line.gap is {peg['line_gap']!r}; "
                "expected 0"
            )
        if peg["line_closed"] is not False:
            errors.append(
                f"annular peg {peg['index']} line.closed is "
                f"{peg['line_closed']!r}; expected false"
            )
        if peg["line_id"] not in EXPECTED_LINE_IDS:
            errors.append(
                f"annular peg {peg['index']} has unexpected line id "
                f"{peg['line_id']!r}"
            )
        groups.setdefault(peg["line_id"], []).append(peg)

    for line_id in EXPECTED_LINE_IDS:
        if line_id not in groups:
            errors.append(f"missing line group {line_id!r}")
            continue
        members = groups[line_id]
        declared_count = members[0]["line_count"]
        if declared_count is None:
            errors.append(f"line {line_id!r} has no declared count")
            continue
        if declared_count != len(members):
            errors.append(
                f"line {line_id!r} declares {declared_count} pegs but the level "
                f"holds {len(members)}"
            )
        for expected_index, peg in enumerate(members, start=1):
            if peg["line_index"] != expected_index:
                errors.append(
                    f"line {line_id!r} index {peg['line_index']!r} at position "
                    f"{expected_index}; expected {expected_index}"
                )
            if peg["line_count"] != declared_count:
                errors.append(
                    f"line {line_id!r} has inconsistent count "
                    f"{peg['line_count']!r} != {declared_count!r}"
                )

    extra_ids = sorted(set(groups) - set(EXPECTED_LINE_IDS))
    if extra_ids:
        errors.append(f"unexpected line ids: {extra_ids}")

    sum_counts = sum(len(members) for members in groups.values())
    if total != EXPECTED_CIRCLES + sum_counts:
        errors.append(
            f"total pegs {total} != {EXPECTED_CIRCLES} circles + "
            f"{sum_counts} generated annular pegs"
        )

    red = type_counts.get("red")
    green = type_counts.get("green")
    purple = type_counts.get("purple")
    authored_blue = type_counts.get("blue")
    if red != EXPECTED_RED:
        errors.append(f"type_counts.red is {red!r}; expected {EXPECTED_RED}")
    if green != EXPECTED_GREEN:
        errors.append(f"type_counts.green is {green!r}; expected {EXPECTED_GREEN}")
    if purple != EXPECTED_PURPLE:
        errors.append(f"type_counts.purple is {purple!r}; expected {EXPECTED_PURPLE}")
    if authored_blue is not None:
        errors.append(
            "type_counts must not author blue; the engine/exporter derives "
            f"blue = #pegs - red - green (got blue = {authored_blue!r})"
        )
    derived_blue = None
    if red is not None and green is not None:
        derived_blue = total - red - green
        if derived_blue != total - 26:
            errors.append(
                f"derived blue {derived_blue} != total - 26 "
                f"({total - 26})"
            )

    return {
        "errors": errors,
        "source_counts": src,
        "name": meta.get("name"),
        "level_seed": meta.get("level_seed"),
        "virtual_width": meta.get("virtual_width"),
        "virtual_height": meta.get("virtual_height"),
        "total": total,
        "circles": len(circles),
        "annular": len(annular),
        "groups": {line_id: len(groups.get(line_id, [])) for line_id in EXPECTED_LINE_IDS},
        "sum_counts": sum_counts,
        "type_counts": {
            "red": red,
            "green": green,
            "purple": purple,
            "blue": authored_blue,
        },
        "derived_blue": derived_blue,
    }


def print_check_summary(result: dict, path: Path) -> None:
    src = result["source_counts"]
    print(f"== ribbon_waves check: {path} ==")
    print(
        f"source calls: Peg.new={src['Peg.new']}, "
        f"Lines.generate={src['Lines.generate']}, "
        f"Peg.new_annular={src['Peg.new_annular']}"
    )
    group_text = ", ".join(
        f"{line_id}={result['groups'].get(line_id, 0)}"
        for line_id in EXPECTED_LINE_IDS
    )
    print(f"line groups: {group_text} (sum {result['sum_counts']})")
    print(f"circles: {result['circles']} (all line == nil)")
    print(
        f"annular: {result['annular']} (segments={EXPECTED_ANNULAR_SEGMENTS}, "
        "gap=0, closed=false, indices contiguous)"
    )
    print(
        f"total: {result['total']} = {EXPECTED_CIRCLES} + {result['sum_counts']}"
    )
    print(
        f"type_counts: red={result['type_counts']['red']} "
        f"green={result['type_counts']['green']} "
        f"purple={result['type_counts']['purple']} authored; "
        f"blue={result['derived_blue']} derived (= total - 26)"
    )
    print(
        f"name: {result['name']}; level_seed: {result['level_seed']}; "
        f"virtual: {result['virtual_width']} x {result['virtual_height']}"
    )
    if result["errors"]:
        print(f"RESULT: FAIL ({len(result['errors'])} error(s))")
    else:
        print("RESULT: PASS")


# ---------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------
def run_check_level(tmp_path: Path) -> str:
    tool = PEGGLE_ROOT / "tools" / "check_level.lua"
    if not tool.is_file():
        die(f"check_level tool not found: {tool}")
    try:
        proc = subprocess.run(
            ["luajit", str(tool), str(tmp_path)],
            cwd=str(PEGGLE_ROOT),
            text=True,
            capture_output=True,
            timeout=120,
        )
    except FileNotFoundError:
        die("luajit not found (required for the check_level gate)")
    except subprocess.TimeoutExpired:
        die("check_level timed out after 120 s")
    output = proc.stdout + proc.stderr
    if (
        proc.returncode != 0
        or not re.search(r"ERRORS:\s*0\b", output)
        or not re.search(r"WARNINGS:\s*0\b", output)
    ):
        die(
            "check_level did not pass (required 0 ERROR / 0 WARN):\n" + output
        )
    return output


def print_terminal_summary(geom: dict) -> None:
    print("terminal sectors (boundary-fitted exact arcs, outward steepening):")
    for ribbon in geom["ribbons"]:
        for label in ("start", "end"):
            terminal = ribbon["terminal"][label]
            print(
                f"  {ribbon['id']:7s} {label:5s} "
                f"k={terminal['curvature']:+.9g} world "
                f"(R={fmt_stat(terminal['radius'])}), "
                f"tip_tangent={terminal['tip_tangent']:+.6g} deg, "
                f"tip_displacement={terminal['deviation']:.6g} world px"
            )


def check_existing(out_path: Path, geometry_path: Path) -> int:
    if not out_path.is_file():
        die(f"--check: level not found: {out_path}")
    # Re-run the design gate and require the installed executable geometry
    # to match this generator, not merely its peg counts.
    geom = load_geometry(geometry_path)
    print_terminal_summary(geom)
    text = out_path.read_text()
    stdout, probe_error = run_probe(out_path)
    if probe_error:
        die(f"--check: {probe_error}")
    meta, type_counts, pegs = parse_probe(stdout)
    expected = render_level(geom, out_path, meta["level_seed"], counts=None)
    def executable_lines(source):
        return [line.strip() for line in strip_lua_comments(source).splitlines() if line.strip()]
    if executable_lines(text) != executable_lines(expected):
        die("--check: installed level differs from the current authored geometry")
    result = analyze(meta, type_counts, pegs, text)
    print_check_summary(result, out_path)
    if result["errors"]:
        for message in result["errors"]:
            sys.stderr.write("  - " + message + "\n")
        die(f"--check failed for {out_path}")
    return 0


def print_generation_summary(
    geom: dict, out_path: Path, seed: int, counts: dict | None
) -> None:
    print(f"generate_ribbon_waves_level: wrote {out_path}")
    print(f"  geometry: {geom['path']}")
    print(f"  geometry sha256: {geom['sha256']}")
    print(f"  circles: {len(geom['circles'])}")
    if counts is not None:
        group_text = ", ".join(
            f"{line_id}={counts['groups'].get(line_id, 0)}"
            for line_id in EXPECTED_LINE_IDS
        )
        print(f"  lines: {group_text}")
        print(
            f"  total pegs: {counts['total']} = {len(geom['circles'])} circles "
            f"+ {counts['annular']} annular"
        )
    else:
        print("  lines: unavailable (level not loaded; --no-verify)")
        print("  total pegs: unavailable (level not loaded; --no-verify)")
    print(
        f"  world: {fmt(VIRTUAL_WIDTH)} x {fmt(VIRTUAL_HEIGHT)} "
        f"(peg radius {fmt(PEG_RADIUS)}, ball radius {fmt(BALL_RADIUS)})"
    )
    print(f"  level_seed: {seed}")
    print_terminal_summary(geom)
    thickness_text = ", ".join(
        f"{ribbon['id']}={ribbon['thickness_world']:.12g}"
        for ribbon in geom["ribbons"]
    )
    print(f"  thickness (world): {thickness_text}")
    if counts is not None:
        derived_blue = counts["total"] - EXPECTED_RED - EXPECTED_GREEN
        print(
            "  authored type_counts: red 25, green 1, purple 0; "
            f"blue derived ({derived_blue})"
        )
    else:
        print(
            "  authored type_counts: red 25, green 1, purple 0; "
            "blue derived"
        )


def generate(geometry_path: Path, out_path: Path, seed: int, no_verify: bool) -> int:
    geom = load_geometry(geometry_path)
    out_path = out_path.resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    text = render_level(geom, out_path, seed, counts=None)
    _src, src_errors = check_source(text)
    if src_errors:
        die("internal error: generated source failed its call-count check:\n  "
            + "\n  ".join(src_errors))

    tmp_path = out_path.with_name(out_path.name + ".tmp")
    try:
        if tmp_path.exists():
            tmp_path.unlink()
        tmp_path.write_text(text)

        counts = None
        stdout, probe_error = run_probe(tmp_path)
        if probe_error:
            if no_verify:
                sys.stderr.write(
                    "generate_ribbon_waves_level: WARNING: " + probe_error
                    + "; emitting without generated counts (--no-verify)\n"
                )
            else:
                die(probe_error)
        else:
            meta, type_counts, pegs = parse_probe(stdout)
            analysis = analyze(meta, type_counts, pegs, text)
            if analysis["errors"]:
                for message in analysis["errors"]:
                    sys.stderr.write("  - " + message + "\n")
                die("generated level failed its structural check")
            counts = {
                "total": analysis["total"],
                "annular": analysis["annular"],
                "groups": analysis["groups"],
            }
            # Re-render with the exact generated counts in the header.  Only
            # comments change; the executable body is byte-identical.
            text = render_level(geom, out_path, seed, counts=counts)
            _src, src_errors = check_source(text)
            if src_errors:
                die("internal error: generated source failed its call-count check:\n  "
                    + "\n  ".join(src_errors))
            tmp_path.write_text(text)

        if not no_verify:
            run_check_level(tmp_path)
            print("  check_level: 0 ERROR / 0 WARN")

        os.replace(tmp_path, out_path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink()

    print_generation_summary(geom, out_path, seed, counts)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Emit the ribbon_waves level as five continuous zero-gap "
            "Lines.generate slides."
        )
    )
    parser.add_argument(
        "--geometry",
        type=Path,
        default=DEFAULT_GEOMETRY,
        help=f"canonical geometry JSON (default: {DEFAULT_GEOMETRY})",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=DEFAULT_OUT,
        help=f"output Lua level (default: {DEFAULT_OUT})",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=DEFAULT_SEED,
        help=f"level_seed (default: {DEFAULT_SEED})",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the existing output without rewriting it",
    )
    parser.add_argument(
        "--check-geometry",
        action="store_true",
        help=(
            "only load the pinned geometry, run the terminal-sector repair and "
            "gate it (negative curvature, outward steepening, G1 joins); no level I/O"
        ),
    )
    parser.add_argument(
        "--no-verify",
        action="store_true",
        help="skip the check_level gate before installing the output",
    )
    args = parser.parse_args(argv)

    geometry_path = args.geometry.resolve()
    out_path = args.out.resolve()

    if args.check_geometry:
        geom = load_geometry(geometry_path)
        print_terminal_summary(geom)
        print("RESULT: PASS (all terminal arcs steepen outward with the required bend)")
        return 0

    if args.check:
        return check_existing(out_path, geometry_path)

    return generate(geometry_path, out_path, args.seed, args.no_verify)


if __name__ == "__main__":
    raise SystemExit(main())
