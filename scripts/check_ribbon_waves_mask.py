#!/usr/bin/env python3
"""Check the exported ribbon_waves artifact against the reference peg mask.

The checker rasterizes the **exported** ``peggle.level`` v1 artifact (exactly
what the Lua game and the Julia harness consume) into the level screenshot's
native pixel space, cleans the reference mask, and compares silhouettes.

Why the artifact and not the extractor output
---------------------------------------------
The artifact is the contract the game and Julia load.  The extraction
intermediate (``ribbon_waves_geometry.json``) is only used here for the
**world transform** the level generator applied: scale, shooter and virtual
size.  Geometry inconsistencies must show up in the artifact check, not be
hidden by rasterizing the extractor's own numbers.

World transform (inverse)
-------------------------
The artifact pegs are in world coordinates.  The plan's mapping is

    x_world = (x_native - sx) * s + virtual_width  / 2
    y_world = (y_native - sy) * s + 50
    r_world = r_native * s

with ``s = 10 / 22 = 0.4545...``, native shooter ``(772.5, 50)``,
``virtual_width = 1545 * s`` and ``virtual_height = 50 + (1289 - 50) * s``.
The checker inverts it:

    x_native = sx + (x_world - virtual_width  / 2) / s
    y_native = sy + (y_world - sy) / s
    r_native = r_world / s

The transform is read from ``fixtures/ribbon_waves/source/ribbon_waves_geometry.json``
(``world`` block and ``native_width``/``native_height``); the artifact's
virtual size is validated against it.  ``--identity-transform`` is available
for non-ribbon boards (the mustache artifact) whose virtual space *is* their
native space.

Mask cleaning (authoritative comparison)
----------------------------------------
The raw mask has small black speckles and seam gaps between bricks.  The level
is modelled as one smooth wave per ribbon, so the checker cleans the mask
before the authoritative comparison:

* split the raw mask into 8-connected components;
* components with area > ``--ribbon-min-area`` (default 2000) are ribbon
  material (the 53 circles are 1517 px each and are left untouched);
* close the ribbon material with a ``--close-radius`` disk (default 2.5 px =
  a 5 px diameter, enough to bridge the brick seams);
* fill holes enclosed by each resulting ribbon band;
* exactly ``--ribbons`` (default 5) bands must result.

The raw mask is also compared and reported with a documented tolerance, but
the pass/fail gates use the **cleaned** mask: overall IoU >= ``--threshold``
(default 0.92) and IoU >= ``--ribbon-threshold`` (default 0.86) for every
ribbon band.  These are **regression floors, not a fidelity claim**: the accepted model is
the v3 single-slide representation — one continuous zero-gap
``Lines.generate`` line per ribbon (the ``squiggly_circle``/``mustache``
primitive), with constant thickness and squared end caps.  The artifact does
**not** open seam insets; adjacent pegs share a full cap and the old adaptive
seam inset is gone.  The remaining gap is constant thickness, squared end
caps and smooth-path/end-trim residuals, so the honest cleaned IoU is about
0.945 overall and 0.886-0.930 per band.  The 0.97/0.95 values remain the
fidelity reference and are reported for information only.

Shapes and angle semantics
--------------------------
* ``circle``: disk of ``radius`` around (x, y).
* ``annular``: the sector between ``r_in`` and ``r_out`` from ``theta_start``
  to ``theta_end_abs``; the outline is the outer arc forward plus the inner
  arc reversed, filled with the even-odd rule (``r_in == 0`` pie slices and
  full rings work).  ``x + r*cos(theta)``, ``y + r*sin(theta)``; screen y
  grows down, so increasing theta sweeps visually clockwise.  ``segments`` is
  collision detail only; the silhouette always uses a dense arc.
* ``rectangle``: ``width`` x ``height`` centred on (x, y), rotated by
  ``angle`` radians with screen-space positive = clockwise.

Rasterization uses ``--supersample`` x ``--supersample`` subpixels per pixel
and sets a pixel when the union of shapes covers at least half of it, so
overlapping pegs count once.

Diff images
-----------
``--diff`` (cleaned, authoritative) and ``--diff-raw`` (raw) are 8-bit RGB
PNGs: white = both, red = artifact-only (false positive), blue = mask-only
(false negative), black = neither.

Exit status: 0 iff the cleaned overall IoU and every cleaned per-ribbon IoU
pass; 1 on a metric failure; 2 for usage/input errors (reported on stderr).

Usage
-----
  scripts/check_ribbon_waves_mask.py                  # defaults below
  scripts/check_ribbon_waves_mask.py --selftest       # rasterizer + cleaner tests
  scripts/check_ribbon_waves_mask.py --json           # machine-readable metrics
"""

import argparse
import array
import json
import math
import os
import struct
import sys
import tempfile
import zlib
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)

DEFAULT_ARTIFACT = os.path.join(
    REPO_ROOT, "fixtures", "ribbon_waves", "artifact", "ribbon_waves.v1.json")
DEFAULT_MASK = os.path.join(
    REPO_ROOT, "fixtures", "ribbon_waves", "reference", "peg_mask.png")
DEFAULT_SOURCE = os.path.join(
    REPO_ROOT, "fixtures", "ribbon_waves", "source", "ribbon_waves_geometry.json")
DEFAULT_DIFF = os.path.join(REPO_ROOT, "fixtures", "ribbon_waves", "mask_diff.png")
DEFAULT_DIFF_RAW = os.path.join(
    REPO_ROOT, "fixtures", "ribbon_waves", "mask_diff_raw.png")
DEFAULT_METRICS = os.path.join(
    REPO_ROOT, "fixtures", "ribbon_waves", "mask_metrics.json")

TWO_PI = 2.0 * math.pi
# Dense-arc angular step for annular outlines.  0.25 degrees keeps the chord
# sagitta far below a 1/4 pixel at every radius used by a 1545x1289 board
# (r=2000 -> sagitta ~0.005 px), while staying cheap.
ARC_STEP = math.radians(0.25)
MAX_ARC_VERTS = 4096
MIN_ARC_VERTS = 8

_MISSING = object()


class CheckError(Exception):
    """Input/configuration error that should be reported without a traceback."""

# ---------------------------------------------------------------------------
# Minimal PNG I/O (stdlib only)
# ---------------------------------------------------------------------------

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
_PNG_CHANNELS = {0: 1, 2: 3, 4: 2, 6: 4}


def _paeth(a, b, c):
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def decode_png(path):
    """Decode an 8-bit non-interlaced PNG.

    Returns a dict with ``width``, ``height``, ``channels`` and a flat
    ``bytearray`` of ``width * height * channels`` bytes.  Supports color
    types 0 (gray), 2 (RGB), 4 (gray+alpha) and 6 (RGBA) with every filter
    type (0-4).  Palette, 16-bit and interlaced images are rejected with a
    clear error.
    """
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as exc:
        raise CheckError(f"cannot read PNG {path!r}: {exc.strerror or exc}")

    if not data.startswith(PNG_SIGNATURE):
        raise CheckError(f"{path}: not a PNG file (bad signature)")

    pos = len(PNG_SIGNATURE)
    ihdr = None
    idat = []
    saw_iend = False
    while pos + 8 <= len(data):
        length = int.from_bytes(data[pos:pos + 4], "big")
        ctype = data[pos + 4:pos + 8]
        chunk_end = pos + 8 + length
        if chunk_end + 4 > len(data):
            raise CheckError(f"{path}: truncated PNG chunk {ctype!r}")
        payload = data[pos + 8:chunk_end]
        crc_stored = int.from_bytes(data[chunk_end:chunk_end + 4], "big")
        crc_actual = zlib.crc32(ctype + payload) & 0xFFFFFFFF
        if crc_stored != crc_actual:
            raise CheckError(f"{path}: CRC mismatch in PNG chunk {ctype!r}")
        pos = chunk_end + 4
        if ctype == b"IHDR":
            ihdr = payload
        elif ctype == b"IDAT":
            idat.append(payload)
        elif ctype == b"IEND":
            saw_iend = True
            break
        elif ctype == b"PLTE":
            raise CheckError(f"{path}: palette PNGs are not supported (write grayscale or RGB)")
    if ihdr is None:
        raise CheckError(f"{path}: PNG has no IHDR chunk")
    if not idat:
        raise CheckError(f"{path}: PNG has no IDAT data")
    if not saw_iend:
        raise CheckError(f"{path}: PNG has no IEND chunk (truncated file)")

    width, height, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(
        ">IIBBBBB", ihdr
    )
    if interlace != 0:
        raise CheckError(f"{path}: interlaced PNGs are not supported (interlace={interlace})")
    if compression != 0 or filter_method != 0:
        raise CheckError(
            f"{path}: unsupported PNG compression/filter method "
            f"({compression}/{filter_method})"
        )
    if bit_depth != 8:
        raise CheckError(f"{path}: only 8-bit PNGs are supported (got bit depth {bit_depth})")
    channels = _PNG_CHANNELS.get(color_type)
    if channels is None:
        raise CheckError(
            f"{path}: unsupported PNG color type {color_type} "
            "(supported: 0 gray, 2 RGB, 4 gray+alpha, 6 RGBA)"
        )
    if width <= 0 or height <= 0:
        raise CheckError(f"{path}: invalid PNG dimensions {width}x{height}")

    try:
        raw = zlib.decompress(b"".join(idat))
    except zlib.error as exc:
        raise CheckError(f"{path}: cannot inflate PNG image data: {exc}")

    stride = width * channels
    expected = height * (stride + 1)
    if len(raw) != expected:
        raise CheckError(
            f"{path}: PNG data size {len(raw)} does not match {width}x{height} "
            f"x {channels} channel(s) (expected {expected}); corrupt or unsupported file"
        )

    out = bytearray(height * stride)
    prev = bytearray(stride)
    bpp = channels
    src = 0
    for y in range(height):
        filter_type = raw[src]
        line = raw[src + 1:src + 1 + stride]
        src += stride + 1
        row = bytearray(line)
        if filter_type == 0:
            pass
        elif filter_type == 1:  # Sub
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif filter_type == 2:  # Up
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                upleft = prev[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + _paeth(left, prev[i], upleft)) & 0xFF
        else:
            raise CheckError(f"{path}: unknown PNG filter type {filter_type} on row {y}")
        out[y * stride:(y + 1) * stride] = row
        prev = row

    return {"width": width, "height": height, "channels": channels, "pixels": out, "path": path}


def _png_chunk(ctype, payload):
    return (
        len(payload).to_bytes(4, "big")
        + ctype
        + payload
        + (zlib.crc32(ctype + payload) & 0xFFFFFFFF).to_bytes(4, "big")
    )


def encode_png(width, height, channels, pixels):
    """Encode an 8-bit grayscale (1) or RGB (3) PNG with filter type 0."""
    if channels not in (1, 3):
        raise CheckError(f"encode_png: only grayscale or RGB output is supported (got {channels})")
    stride = width * channels
    if len(pixels) != height * stride:
        raise CheckError(
            f"encode_png: pixel buffer has {len(pixels)} bytes, expected {height * stride}"
        )
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter: None
        raw += pixels[y * stride:(y + 1) * stride]
    color_type = 0 if channels == 1 else 2
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    return (
        PNG_SIGNATURE
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + _png_chunk(b"IEND", b"")
    )


def write_png(path, width, height, channels, pixels):
    data = encode_png(width, height, channels, pixels)
    parent = os.path.dirname(os.path.abspath(path))
    try:
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(data)
    except OSError as exc:
        raise CheckError(f"cannot write PNG {path!r}: {exc.strerror or exc}")


def png_gray_values(image):
    """Return a flat bytearray of luminance values for a decoded PNG.

    Grayscale is used as-is; RGB is converted with Rec.601 luma; an alpha
    channel is composited over black (transparent pixels become background).
    """
    width = image["width"]
    height = image["height"]
    channels = image["channels"]
    pixels = image["pixels"]
    count = width * height
    gray = bytearray(count)
    if channels == 1:
        gray[:] = pixels
        return gray
    for i in range(count):
        base = i * channels
        if channels == 2:
            value = pixels[base]
            alpha = pixels[base + 1]
        elif channels == 3:
            value = (299 * pixels[base] + 587 * pixels[base + 1] + 114 * pixels[base + 2] + 500) // 1000
            alpha = 255
        else:  # RGBA
            value = (299 * pixels[base] + 587 * pixels[base + 1] + 114 * pixels[base + 2] + 500) // 1000
            alpha = pixels[base + 3]
        if alpha != 255:
            value = (value * alpha + 127) // 255
        gray[i] = value if value <= 255 else 255
    return gray


def mask_binary(image):
    """Threshold a decoded mask PNG at >127 (documented contract)."""
    gray = png_gray_values(image)
    binary = bytearray(len(gray))
    for i, value in enumerate(gray):
        binary[i] = 1 if value > 127 else 0
    return binary



# ---------------------------------------------------------------------------
# Artifact loading / normalization
# ---------------------------------------------------------------------------


def _first(mapping, names, what, default=_MISSING):
    for name in names:
        if name in mapping and mapping[name] is not None:
            return mapping[name]
    if default is _MISSING:
        raise CheckError(f"{what}: missing required field (one of {', '.join(names)})")
    return default


def _as_float(value, what):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CheckError(f"{what}: expected a number, got {value!r}")
    result = float(value)
    if not math.isfinite(result):
        raise CheckError(f"{what}: expected a finite number, got {value!r}")
    return result


def _as_int(value, what):
    number = _as_float(value, what)
    if number != int(number):
        raise CheckError(f"{what}: expected an integer, got {value!r}")
    return int(number)


def _peg_type(raw, default="unknown"):
    value = _first(raw, ("type", "peg_type", "color"), "peg", default=default)
    return str(value)


def _circle_from(raw, index, what):
    x = _as_float(_first(raw, ("x", "cx"), what), f"{what}.x")
    y = _as_float(_first(raw, ("y", "cy"), what), f"{what}.y")
    radius = _as_float(_first(raw, ("radius", "r"), what), f"{what}.radius")
    if radius < 0:
        raise CheckError(f"{what}: radius must be >= 0, got {radius}")
    return {
        "index": index,
        "id": raw.get("id", raw.get("name", index + 1)),
        "shape": "circle",
        "type": _peg_type(raw),
        "x": x,
        "y": y,
        "radius": radius,
    }


def _rectangle_from(raw, index, what):
    x = _as_float(_first(raw, ("x", "cx"), what), f"{what}.x")
    y = _as_float(_first(raw, ("y", "cy"), what), f"{what}.y")
    width = _as_float(_first(raw, ("width", "w"), what), f"{what}.width")
    height = _as_float(_first(raw, ("height", "h"), what), f"{what}.height")
    angle = _as_float(_first(raw, ("angle", "rotation", "theta"), what, default=0.0), f"{what}.angle")
    if width < 0 or height < 0:
        raise CheckError(f"{what}: width/height must be >= 0, got {width}x{height}")
    return {
        "index": index,
        "id": raw.get("id", raw.get("name", index + 1)),
        "shape": "rectangle",
        "type": _peg_type(raw),
        "x": x,
        "y": y,
        "width": width,
        "height": height,
        "angle": angle,
    }


def _annular_from(raw, index, what):
    x = _as_float(_first(raw, ("x", "cx"), what), f"{what}.x")
    y = _as_float(_first(raw, ("y", "cy"), what), f"{what}.y")
    r_in = _as_float(_first(raw, ("r_in", "r0", "inner_radius"), what), f"{what}.r_in")
    r_out = _as_float(_first(raw, ("r_out", "r1", "outer_radius"), what), f"{what}.r_out")
    theta_start = _as_float(_first(raw, ("theta_start", "start_theta", "theta0"), what), f"{what}.theta_start")
    theta_end = _as_float(
        _first(raw, ("theta_end_abs", "theta_end", "end_theta", "theta1"), what),
        f"{what}.theta_end_abs",
    )
    if r_in < 0 or r_out < 0:
        raise CheckError(f"{what}: r_in/r_out must be >= 0, got {r_in}/{r_out}")
    if r_out < r_in:
        raise CheckError(f"{what}: r_out ({r_out}) must be >= r_in ({r_in})")
    if r_out == 0:
        raise CheckError(f"{what}: degenerate annular peg (r_out == 0)")
    sweep = theta_end - theta_start
    if sweep <= 0:
        raise CheckError(
            f"{what}: theta_end_abs ({theta_end}) must be > theta_start ({theta_start}); "
            "the artifact contract requires a positive sweep"
        )
    if sweep > TWO_PI + 1e-9:
        raise CheckError(
            f"{what}: angular sweep {sweep} exceeds 2*pi; a single annular peg "
            "must be a sector or a full ring"
        )
    return {
        "index": index,
        "id": raw.get("id", raw.get("name", index + 1)),
        "shape": "annular",
        "type": _peg_type(raw),
        "x": x,
        "y": y,
        "r_in": r_in,
        "r_out": r_out,
        "theta_start": theta_start,
        "theta_end_abs": theta_end,
        # `segments` is collision detail; kept only for reporting.
        "segments": raw.get("segments"),
    }


def normalize_artifact_peg(raw, index):
    what = f"pegs[{index}]"
    if not isinstance(raw, dict):
        raise CheckError(f"{what}: expected an object, got {type(raw).__name__}")
    shape = _first(raw, ("shape",), what)
    if shape == "circle":
        return _circle_from(raw, index, what)
    if shape == "rectangle":
        return _rectangle_from(raw, index, what)
    if shape == "annular":
        return _annular_from(raw, index, what)
    raise CheckError(f"{what}: unknown peg shape {shape!r}")


def load_artifact(path):
    """Load a ``peggle.level`` v1 artifact; pegs are normalized but untransformed."""
    doc = _json_object(path, "artifact")
    if "format" in doc and doc["format"] != "peggle.level":
        raise CheckError(f"{path}: artifact format must be 'peggle.level', got {doc['format']!r}")
    if "pegs" not in doc or not isinstance(doc["pegs"], list):
        raise CheckError(f"{path}: artifact has no 'pegs' list")
    if not doc["pegs"]:
        raise CheckError(f"{path}: artifact contains no pegs")
    width = _as_float(_first(doc, ("virtual_width",), "artifact"), "artifact.virtual_width")
    height = _as_float(_first(doc, ("virtual_height",), "artifact"), "artifact.virtual_height")
    if width <= 0 or height <= 0:
        raise CheckError(f"{path}: invalid virtual size {width}x{height}")
    pegs = [normalize_artifact_peg(raw, i) for i, raw in enumerate(doc["pegs"])]
    return {
        "pegs": pegs,
        "size": (width, height),
        "name": doc.get("name", os.path.basename(path)),
        "path": path,
    }





# ---------------------------------------------------------------------------
# World transform (from the extraction geometry's `world` block)
# ---------------------------------------------------------------------------


def _json_object(path, what):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            doc = json.load(handle)
    except OSError as exc:
        raise CheckError(f"cannot read {what} {path!r}: {exc.strerror or exc}")
    except json.JSONDecodeError as exc:
        raise CheckError(f"{path}: invalid JSON: {exc}")
    if not isinstance(doc, dict):
        raise CheckError(f"{path}: top-level JSON value must be an object")
    return doc


def load_transform(path, mask_size):
    """Read the world -> native transform from the extraction geometry JSON.

    Only the ``world`` block and the native size are used; the extractor's
    per-peg geometry is deliberately ignored so the comparison is against the
    exported artifact.
    """
    doc = _json_object(path, "source geometry")
    world = doc.get("world")
    if not isinstance(world, dict):
        raise CheckError(
            f"{path}: missing 'world' block (scale/shooter_native/virtual_width/"
            "virtual_height); pass --identity-transform for native-space boards")

    scale = _as_float(_first(world, ("scale",), "world"), "world.scale")
    if scale <= 0:
        raise CheckError(f"world.scale must be > 0, got {scale}")
    shooter = world.get("shooter_native")
    if not isinstance(shooter, (list, tuple)) or len(shooter) != 2:
        raise CheckError(f"world.shooter_native must be [x, y], got {shooter!r}")
    shooter_x = _as_float(shooter[0], "world.shooter_native[0]")
    shooter_y = _as_float(shooter[1], "world.shooter_native[1]")
    virtual_width = _as_float(
        _first(world, ("virtual_width",), "world"), "world.virtual_width")
    virtual_height = _as_float(
        _first(world, ("virtual_height",), "world"), "world.virtual_height")

    native_width = native_height = None
    for wkey, hkey in (("native_width", "native_height"), ("image_width", "image_height")):
        if wkey in doc and hkey in doc:
            native_width = _as_float(doc[wkey], wkey)
            native_height = _as_float(doc[hkey], hkey)
            break
    if native_width is None:
        image_size = doc.get("image_size")
        if isinstance(image_size, (list, tuple)) and len(image_size) == 2:
            native_width = _as_float(image_size[0], "image_size[0]")
            native_height = _as_float(image_size[1], "image_size[1]")
    if native_width is None:
        native_width, native_height = mask_size

    peg_radius = world.get("peg_radius")
    if peg_radius is not None:
        peg_radius = _as_float(peg_radius, "world.peg_radius")
    ball_radius = world.get("ball_radius")
    if ball_radius is not None:
        ball_radius = _as_float(ball_radius, "world.ball_radius")

    ribbon_count = doc.get("ribbons")
    ribbon_count = len(ribbon_count) if isinstance(ribbon_count, list) else None

    return {
        "scale": scale,
        "shooter_x": shooter_x,
        "shooter_y": shooter_y,
        "virtual_width": virtual_width,
        "virtual_height": virtual_height,
        "native_width": native_width,
        "native_height": native_height,
        "peg_radius": peg_radius,
        "ball_radius": ball_radius,
        "ribbon_count": ribbon_count,
        "path": path,
    }


def identity_transform(width, height):
    """Transform for boards authored directly in virtual pixel space."""
    return {
        "scale": 1.0,
        "shooter_x": width / 2.0,
        "shooter_y": 50.0,
        "virtual_width": float(width),
        "virtual_height": float(height),
        "native_width": float(width),
        "native_height": float(height),
        "peg_radius": None,
        "ball_radius": None,
        "ribbon_count": None,
        "path": None,
    }


def validate_transform(transform, artifact_size, mask_size):
    """Check the world block, artifact size and mask size are consistent."""
    expected_vw = transform["native_width"] * transform["scale"]
    expected_vh = (
        transform["shooter_y"]
        + (transform["native_height"] - transform["shooter_y"]) * transform["scale"])
    tolerance = 1e-3
    if abs(transform["virtual_width"] - expected_vw) > tolerance:
        raise CheckError(
            f"world block is inconsistent: virtual_width "
            f"{transform['virtual_width']:.6f} != native_width * scale "
            f"({transform['native_width']:.3f} * {transform['scale']:.6f} = "
            f"{expected_vw:.6f})")
    if abs(transform["virtual_height"] - expected_vh) > tolerance:
        raise CheckError(
            f"world block is inconsistent: virtual_height "
            f"{transform['virtual_height']:.6f} != shooter_y + (native_height - "
            f"shooter_y) * scale ({expected_vh:.6f})")
    if (float(mask_size[0]), float(mask_size[1])) != (
            transform["native_width"], transform["native_height"]):
        raise CheckError(
            f"mask size {mask_size[0]}x{mask_size[1]} != native size "
            f"{transform['native_width']:.0f}x{transform['native_height']:.0f}")
    if abs(artifact_size[0] - transform["virtual_width"]) > tolerance or \
            abs(artifact_size[1] - transform["virtual_height"]) > tolerance:
        raise CheckError(
            f"artifact virtual size {artifact_size[0]:.6f}x{artifact_size[1]:.6f} "
            f"!= world size {transform['virtual_width']:.6f}x"
            f"{transform['virtual_height']:.6f}")
    if transform["peg_radius"] is not None and transform["peg_radius"] <= 0:
        raise CheckError(
            f"world.peg_radius must be > 0, got {transform['peg_radius']}")


def world_to_native_peg(peg, transform):
    """Invert the level generator's world transform for one artifact peg."""
    scale = transform["scale"]
    x = transform["shooter_x"] + (
        peg["x"] - transform["virtual_width"] / 2.0) / scale
    y = transform["shooter_y"] + (
        peg["y"] - transform["shooter_y"]) / scale
    native = dict(peg)
    native["x"] = x
    native["y"] = y
    if peg["shape"] == "circle":
        native["radius"] = peg["radius"] / scale
    elif peg["shape"] == "annular":
        native["r_in"] = peg["r_in"] / scale
        native["r_out"] = peg["r_out"] / scale
    elif peg["shape"] == "rectangle":
        native["width"] = peg["width"] / scale
        native["height"] = peg["height"] / scale
    else:  # pragma: no cover - normalize_artifact_peg rejects unknown shapes
        raise CheckError(f"cannot transform unknown shape {peg['shape']!r}")
    return native


def world_to_native_pegs(pegs, transform):
    return [world_to_native_peg(peg, transform) for peg in pegs]


# ---------------------------------------------------------------------------
# Reference mask cleaning (speckles and brick seams)
# ---------------------------------------------------------------------------


def connected_components(mask, width, height):
    """8-connected components of a binary image, via row-run union-find.

    Returns a list of components, each ``{area, bbox: (x0, y0, x1, y1), runs:
    [(y, x0, x1), ...]}`` sorted by top-left corner.  Runs keep memory and
    time proportional to the number of horizontal runs, not pixels.
    """
    parent = []

    def find(a):
        root = a
        while parent[root] != root:
            root = parent[root]
        while parent[a] != root:
            parent[a], a = root, parent[a]
        return root

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    meta = []          # run id -> (y, x0, x1)
    prev_ids = []
    for y in range(height):
        base = y * width
        row_ids = []
        x = 0
        while x < width:
            while x < width and not mask[base + x]:
                x += 1
            if x >= width:
                break
            x0 = x
            while x < width and mask[base + x]:
                x += 1
            rid = len(meta)
            meta.append((y, x0, x - 1))
            parent.append(rid)
            row_ids.append(rid)
        # Union with the overlapping/touching runs of the previous row.
        i = j = 0
        while i < len(prev_ids) and j < len(row_ids):
            _, px0, px1 = meta[prev_ids[i]]
            _, cx0, cx1 = meta[row_ids[j]]
            if px1 + 1 < cx0:
                i += 1
            elif cx1 + 1 < px0:
                j += 1
            else:
                union(prev_ids[i], row_ids[j])
                if px1 < cx1:
                    i += 1
                else:
                    j += 1
        prev_ids = row_ids

    groups = {}
    for rid in range(len(meta)):
        groups.setdefault(find(rid), []).append(rid)
    components = []
    for ids in groups.values():
        runs = [meta[rid] for rid in ids]
        x0 = min(run[1] for run in runs)
        x1 = max(run[2] for run in runs)
        y0 = min(run[0] for run in runs)
        y1 = max(run[0] for run in runs)
        area = sum(run[2] - run[1] + 1 for run in runs)
        components.append(
            {"area": area, "bbox": (x0, y0, x1, y1), "runs": runs})
    components.sort(key=lambda comp: (comp["bbox"][1], comp["bbox"][0]))
    return components


def _paint_runs(target, runs, width, value=1):
    for y, x0, x1 in runs:
        base = y * width
        for x in range(x0, x1 + 1):
            target[base + x] = value


def disk_offsets(radius):
    """Integer offsets whose centre lies inside a disk of `radius` pixels."""
    if radius <= 0:
        return [(0, 0)]
    reach = int(math.ceil(radius))
    offsets = []
    limit = radius * radius
    for dy in range(-reach, reach + 1):
        for dx in range(-reach, reach + 1):
            if dx * dx + dy * dy <= limit:
                offsets.append((dx, dy))
    return offsets


def dilate(source, width, height, offsets):
    target = bytearray(len(source))
    for y in range(height):
        base = y * width
        for x in range(width):
            if not source[base + x]:
                continue
            for dx, dy in offsets:
                nx, ny = x + dx, y + dy
                if 0 <= nx < width and 0 <= ny < height:
                    target[ny * width + nx] = 1
    return target


def erode(source, width, height, offsets):
    target = bytearray(len(source))
    for y in range(height):
        base = y * width
        for x in range(width):
            if not source[base + x]:
                continue
            keep = True
            for dx, dy in offsets:
                nx, ny = x + dx, y + dy
                if not (0 <= nx < width and 0 <= ny < height) or not source[ny * width + nx]:
                    keep = False
                    break
            if keep:
                target[base + x] = 1
    return target


def _fill_holes(component, source, width, height):
    """Fill background pockets enclosed by one component.

    Returns ``(filled_runs, holes_pixels)``; `source` is the binary image the
    component came from, so enclosure is judged on the closed band.
    """
    x0, y0, x1, y1 = component["bbox"]
    bw = x1 - x0 + 1
    bh = y1 - y0 + 1
    local = bytearray(bw * bh)
    for y, rx0, rx1 in component["runs"]:
        row = (y - y0) * bw - x0
        for x in range(rx0, rx1 + 1):
            local[row + x] = 1

    outside = bytearray(bw * bh)
    queue = deque()

    def seed(x, y):
        index = y * bw + x
        if not local[index] and not outside[index]:
            outside[index] = 1
            queue.append(index)

    for x in range(bw):
        seed(x, 0)
        seed(x, bh - 1)
    for y in range(bh):
        seed(0, y)
        seed(bw - 1, y)
    while queue:
        index = queue.popleft()
        x = index % bw
        y = index // bw
        if x > 0:
            seed(x - 1, y)
        if x + 1 < bw:
            seed(x + 1, y)
        if y > 0:
            seed(x, y - 1)
        if y + 1 < bh:
            seed(x, y + 1)

    filled = list(component["runs"])
    holes = 0
    for y in range(bh):
        x = 0
        while x < bw:
            index = y * bw + x
            if local[index] or outside[index]:
                x += 1
                continue
            run_start = x
            while x < bw and not local[y * bw + x] and not outside[y * bw + x]:
                x += 1
            filled.append((y + y0, run_start + x0, x - 1 + x0))
            holes += x - run_start
    filled.sort(key=lambda run: (run[0], run[1]))
    return filled, holes


def build_cleaned_mask(mask, width, height, close_radius=2.5,
                       ribbon_min_area=2000, expected_ribbons=5):
    """Return the cleaned mask and its ribbon bands.

    Circles (components with area <= `ribbon_min_area`) are copied from the
    raw mask untouched.  Ribbon material is morphologically closed with a
    disk of `close_radius` pixels and each resulting band's holes are filled.
    """
    components = connected_components(mask, width, height)
    ribbon_components = [comp for comp in components if comp["area"] > ribbon_min_area]
    circle_components = [comp for comp in components if comp["area"] <= ribbon_min_area]
    if not ribbon_components:
        raise CheckError(
            f"mask has no component with area > {ribbon_min_area}; "
            "cannot identify ribbon bands")

    ribbon_seed = bytearray(width * height)
    for comp in ribbon_components:
        _paint_runs(ribbon_seed, comp["runs"], width)

    offsets = disk_offsets(close_radius)
    closed = erode(
        dilate(ribbon_seed, width, height, offsets), width, height, offsets)

    bands = connected_components(closed, width, height)
    if expected_ribbons and len(bands) != expected_ribbons:
        raise CheckError(
            f"mask cleaning produced {len(bands)} ribbon band(s), expected "
            f"{expected_ribbons}; the brick seams may be wider than "
            f"--close-radius {close_radius} px")

    cleaned = bytearray(mask)
    band_filled = []
    for band in bands:
        filled_runs, holes = _fill_holes(band, closed, width, height)
        _paint_runs(cleaned, filled_runs, width)
        band_filled.append(dict(band, runs=filled_runs, area=band["area"] + holes))
    added = sum(band["area"] for band in band_filled) - sum(
        comp["area"] for comp in ribbon_components)

    band_label = array.array("b", [0]) * (width * height)
    for index, band in enumerate(band_filled, start=1):
        _paint_runs(band_label, band["runs"], width, index)

    return {
        "cleaned": cleaned,
        "band_label": band_label,
        "bands": band_filled,
        "raw_components": len(components),
        "raw_ribbon_components": len(ribbon_components),
        "circle_components": len(circle_components),
        "circle_area_min": min((comp["area"] for comp in circle_components), default=0),
        "circle_area_max": max((comp["area"] for comp in circle_components), default=0),
        "raw_pixels": sum(mask),
        "cleaned_pixels": sum(cleaned),
        "added_pixels": added,
        "close_radius": close_radius,
        "ribbon_min_area": ribbon_min_area,
        "offsets": len(offsets),
    }

# ---------------------------------------------------------------------------
# Rasterization
# ---------------------------------------------------------------------------


def annular_polygons(peg):
    """Return the even-odd subpaths of an annular peg, in pixel coordinates.

    Vertices follow the engine convention: x + r*cos(theta), y + r*sin(theta)
    with y growing downward.  A partial sector is one closed path (outer arc
    forward, inner arc reversed); a full ring is two closed circles.
    """
    cx = peg["x"]
    cy = peg["y"]
    r_in = peg["r_in"]
    r_out = peg["r_out"]
    start = peg["theta_start"]
    end = peg["theta_end_abs"]
    sweep = end - start

    def point(radius, theta):
        return (cx + radius * math.cos(theta), cy + radius * math.sin(theta))

    if sweep >= TWO_PI - 1e-9:
        count = int(math.ceil(TWO_PI / ARC_STEP))
        count = max(MIN_ARC_VERTS, min(MAX_ARC_VERTS, count))
        outer = [point(r_out, TWO_PI * i / count) for i in range(count)]
        paths = [outer]
        if r_in > 0:
            inner = [point(r_in, -TWO_PI * i / count) for i in range(count)]
            paths.append(inner)
        return paths

    count = int(math.ceil(sweep / ARC_STEP))
    count = max(MIN_ARC_VERTS, min(MAX_ARC_VERTS, count))
    outer = [point(r_out, start + sweep * i / count) for i in range(count + 1)]
    inner = [point(r_in, start + sweep * i / count) for i in range(count, -1, -1)]
    return [outer + inner]


def _shape_vertices(peg):
    """Return polygon subpaths for non-circle shapes (empty for circles)."""
    shape = peg["shape"]
    if shape == "annular":
        return annular_polygons(peg)
    if shape == "rectangle":
        x = peg["x"]
        y = peg["y"]
        hw = peg["width"] / 2.0
        hh = peg["height"] / 2.0
        if hw == 0 or hh == 0:
            return []
        cos_a = math.cos(peg["angle"])
        sin_a = math.sin(peg["angle"])

        def corner(sx, sy):
            return (x + sx * cos_a - sy * sin_a, y + sx * sin_a + sy * cos_a)

        return [[corner(-hw, -hh), corner(hw, -hh), corner(hw, hh), corner(-hw, hh)]]
    raise CheckError(f"unknown shape {shape!r}")


def _shape_bbox(peg, vertices):
    shape = peg["shape"]
    if shape == "circle":
        r = peg["radius"]
        return (peg["x"] - r, peg["y"] - r, peg["x"] + r, peg["y"] + r)
    xs = [p[0] for path in vertices for p in path]
    ys = [p[1] for path in vertices for p in path]
    return (min(xs), min(ys), max(xs), max(ys))


def _clip_bbox(bbox, width, height):
    x0 = max(0, int(math.floor(bbox[0])))
    y0 = max(0, int(math.floor(bbox[1])))
    x1 = min(width, int(math.ceil(bbox[2])))
    y1 = min(height, int(math.ceil(bbox[3])))
    if x1 <= x0 or y1 <= y0:
        return None
    return (x0, y0, x1, y1)


def _mask_typecode(supersample):
    """Unsigned array type for a per-pixel subpixel bitmask (S*S bits)."""
    return "H" if supersample * supersample <= 16 else "Q"


def _new_mask(count, supersample):
    return array.array(_mask_typecode(supersample), [0]) * count


def _or_span(mask, mask_w, mask_h, origin_x, origin_y, row, xl, xr, supersample):
    """OR the subpixel cells of the span [xl, xr) on subpixel row `row`.

    Subpixel cell centers are at (col + 0.5) / supersample; a cell is inside
    when its center lies in [xl, xr).  Bit ``(row % s) * s + (col % s)`` of a
    pixel records that subpixel, so shapes OR into an exact union instead of
    double counting overlaps.
    """
    s = supersample
    col_start = int(math.ceil(xl * s - 0.5))
    col_end = int(math.ceil(xr * s - 0.5))
    clip_start = origin_x * s
    clip_end = (origin_x + mask_w) * s
    if col_start < clip_start:
        col_start = clip_start
    if col_end > clip_end:
        col_end = clip_end
    if col_end <= col_start:
        return
    prow = row // s - origin_y
    if prow < 0 or prow >= mask_h:
        return
    bit_base = (row % s) * s
    base = prow * mask_w
    px_first = col_start // s - origin_x
    px_last = (col_end - 1) // s - origin_x
    if px_first == px_last:
        offset = col_start - (px_first + origin_x) * s
        count = col_end - col_start
        mask[base + px_first] |= ((1 << count) - 1) << (bit_base + offset)
        return
    offset = col_start - (px_first + origin_x) * s
    count = s - offset
    mask[base + px_first] |= ((1 << count) - 1) << (bit_base + offset)
    full = ((1 << s) - 1) << bit_base
    for px in range(px_first + 1, px_last):
        mask[base + px] |= full
    count = col_end - (px_last + origin_x) * s
    mask[base + px_last] |= ((1 << count) - 1) << bit_base


def _fill_circle(mask, mask_w, mask_h, origin_x, origin_y, peg, supersample):
    s = supersample
    cx = peg["x"]
    cy = peg["y"]
    radius = peg["radius"]
    if radius <= 0:
        return
    row_lo = max(origin_y * s, int(math.ceil((cy - radius) * s - 0.5)))
    row_hi = min((origin_y + mask_h) * s, int(math.ceil((cy + radius) * s - 0.5)))
    radius_sq = radius * radius
    for row in range(row_lo, row_hi):
        yc = (row + 0.5) / s
        dy = yc - cy
        if dy * dy > radius_sq:
            continue
        half = math.sqrt(max(0.0, radius_sq - dy * dy))
        _or_span(mask, mask_w, mask_h, origin_x, origin_y, row, cx - half, cx + half, s)


def _fill_polygons(mask, mask_w, mask_h, origin_x, origin_y, paths, supersample):
    s = supersample
    if not paths:
        return
    buckets = {}
    last_row = -1
    for path in paths:
        if len(path) < 2:
            continue
        for i in range(len(path)):
            x0, y0 = path[i]
            x1, y1 = path[(i + 1) % len(path)]
            if y0 == y1:
                continue
            if y0 > y1:
                x0, y0, x1, y1 = x1, y1, x0, y0
            row_lo = max(origin_y * s, int(math.ceil(y0 * s - 0.5)))
            row_hi = min(
                (origin_y + mask_h) * s, int(math.ceil(y1 * s - 0.5))
            )
            if row_hi <= row_lo:
                continue
            slope = (x1 - x0) / (y1 - y0)
            buckets.setdefault(row_lo, []).append((x0, y0, slope, y1))
            if row_hi - 1 > last_row:
                last_row = row_hi - 1
    if not buckets:
        return
    active = []
    row_min = min(buckets)
    for row in range(row_min, last_row + 1):
        added = buckets.get(row)
        if added:
            active.extend(added)
        yc = (row + 0.5) / s
        if active:
            active = [edge for edge in active if edge[3] > yc]
        if len(active) < 2:
            continue
        xs = sorted(edge[0] + (yc - edge[1]) * edge[2] for edge in active)
        for i in range(0, len(xs) - 1, 2):
            _or_span(
                mask, mask_w, mask_h, origin_x, origin_y, row, xs[i], xs[i + 1], s
            )


def rasterize_peg(peg, width, height, supersample):
    """Rasterize one peg into a local subpixel bitmask.

    Returns ``(geometric_bbox, clipped_bbox, local_mask, pixel_count)`` where
    ``local_mask`` is a width*height bitmask for the clipped bbox (or None if
    the shape is outside the board) and ``pixel_count`` is this shape's own
    >=50%-covered pixel count (union-independent, for diagnostics).
    """
    try:
        vertices = _shape_vertices(peg) if peg["shape"] != "circle" else []
    except CheckError as exc:
        raise CheckError(f"peg id={peg.get('id')!r} ({peg['shape']}): {exc}")
    bbox = _shape_bbox(peg, vertices)
    clipped = _clip_bbox(bbox, width, height)
    if clipped is None:
        return bbox, None, None, 0
    bx0, by0, bx1, by1 = clipped
    bw = bx1 - bx0
    bh = by1 - by0
    local = _new_mask(bw * bh, supersample)
    if peg["shape"] == "circle":
        _fill_circle(local, bw, bh, bx0, by0, peg, supersample)
    else:
        _fill_polygons(local, bw, bh, bx0, by0, vertices, supersample)
    threshold = supersample * supersample
    count = 0
    for value in local:
        if value.bit_count() * 2 >= threshold:
            count += 1
    return bbox, clipped, local, count


def rasterize_document(document, width, height, supersample):
    """Rasterize the union of every peg; returns (binary, peg raster infos).

    The union is taken on the subpixel grid (per-pixel bitmasks OR-ed
    together) and thresholded once at 50% coverage, so the result is the
    supersampled silhouette of all shapes rather than a sum of per-shape
    thresholds.
    """
    total = width * height
    union = _new_mask(total, supersample)
    infos = []
    for peg in document["pegs"]:
        bbox, clipped, local, area = rasterize_peg(peg, width, height, supersample)
        if clipped is not None and local is not None:
            bx0, by0, bx1, by1 = clipped
            bw = bx1 - bx0
            bh = by1 - by0
            for row in range(bh):
                src = row * bw
                dst = (by0 + row) * width + bx0
                for x in range(bw):
                    value = local[src + x]
                    if value:
                        union[dst + x] |= value
        infos.append(
            {
                "id": peg.get("id"),
                "shape": peg["shape"],
                "type": peg.get("type", "unknown"),
                "bbox": clipped,
                "pixels": area,
                "peg": peg,
                "local": local,
            }
        )
    threshold = supersample * supersample
    binary = bytearray(total)
    for i, value in enumerate(union):
        if value.bit_count() * 2 >= threshold:
            binary[i] = 1
    return binary, infos



# ---------------------------------------------------------------------------
# Comparison / reporting
# ---------------------------------------------------------------------------


DIFF_BOTH = (255, 255, 255)
DIFF_FALSE_POSITIVE = (255, 0, 0)
DIFF_FALSE_NEGATIVE = (0, 96, 255)
DIFF_NEITHER = (0, 0, 0)


def compare_binary(artifact, mask, width, height):
    """Pixel counts and the RGB diff buffer for two binary images."""
    count = width * height
    if len(artifact) != count or len(mask) != count:
        raise CheckError("internal error: binary image size mismatch")
    diff = bytearray(count * 3)
    intersection = 0
    artifact_pixels = 0
    mask_pixels = 0
    false_positive = 0
    false_negative = 0
    both = bytes(DIFF_BOTH)
    red = bytes(DIFF_FALSE_POSITIVE)
    blue = bytes(DIFF_FALSE_NEGATIVE)
    black = bytes(DIFF_NEITHER)
    for i in range(count):
        a = artifact[i]
        m = mask[i]
        if m:
            mask_pixels += 1
        base = i * 3
        if a:
            artifact_pixels += 1
            if m:
                intersection += 1
                diff[base:base + 3] = both
            else:
                false_positive += 1
                diff[base:base + 3] = red
        elif m:
            false_negative += 1
            diff[base:base + 3] = blue
        else:
            diff[base:base + 3] = black
    union = intersection + false_positive + false_negative
    iou = intersection / union if union else 0.0
    precision = intersection / artifact_pixels if artifact_pixels else 0.0
    recall = intersection / mask_pixels if mask_pixels else 0.0
    return {
        "intersection_pixels": intersection,
        "artifact_pixels": artifact_pixels,
        "mask_pixels": mask_pixels,
        "false_positive_pixels": false_positive,
        "false_negative_pixels": false_negative,
        "union_pixels": union,
        "iou": iou,
        "precision": precision,
        "recall": recall,
        "diff": diff,
    }

def per_peg_stats(infos, artifact, mask, width, top):
    """Attribute global FP/FN pixels to peg bounding boxes."""
    stats = []
    for info in infos:
        bbox = info["bbox"]
        if bbox is None:
            stats.append(
                {
                    "id": info["id"],
                    "shape": info["shape"],
                    "type": info["type"],
                    "bbox": None,
                    "peg_pixels": 0,
                    "missing_pixels": 0,
                    "extra_pixels": 0,
                }
            )
            continue
        bx0, by0, bx1, by1 = bbox
        missing = 0
        extra = 0
        for row in range(by0, by1):
            base = row * width
            for x in range(bx0, bx1):
                i = base + x
                if mask[i] and not artifact[i]:
                    missing += 1
                elif artifact[i] and not mask[i]:
                    extra += 1
        stats.append(
            {
                "id": info["id"],
                "shape": info["shape"],
                "type": info["type"],
                "bbox": [bx0, by0, bx1, by1],
                "peg_pixels": info["pixels"],
                "missing_pixels": missing,
                "extra_pixels": extra,
            }
        )
    stats.sort(key=lambda item: (item["missing_pixels"] + item["extra_pixels"]), reverse=True)
    return stats[:top] if top > 0 else []





# ---------------------------------------------------------------------------
# Per-ribbon comparison
# ---------------------------------------------------------------------------


def _iter_set_pixels(info, width):
    """Yield global indices of an info entry's >=50%-covered pixels."""
    bbox = info["bbox"]
    local = info["local"]
    if not bbox or not local:
        return
    bx0, by0, bx1, by1 = bbox
    bw = bx1 - bx0
    threshold = info["threshold"]
    for row in range(by1 - by0):
        base = (by0 + row) * width + bx0
        lrow = row * bw
        for x in range(bw):
            value = local[lrow + x]
            if value and value.bit_count() * 2 >= threshold:
                yield base + x


def assign_bands(infos, clean, width, supersample):
    """Assign every non-circle artifact peg to a ribbon band.

    A peg belongs to the band it overlaps most (in rasterized pixels).  A peg
    with no overlap at all is attached to the nearest band by bounding-box
    centre so a misplaced piece still lowers that band's IoU instead of being
    silently dropped.
    """
    bands = clean["bands"]
    labels = clean["band_label"]
    threshold = supersample * supersample
    assignments = []
    band_pegs = [[] for _ in bands]
    for info in infos:
        if info["shape"] == "circle":
            continue
        info["threshold"] = threshold
        counts = [0] * len(bands)
        for index in _iter_set_pixels(info, width):
            label = labels[index]
            if label:
                counts[label - 1] += 1
        best = max(range(len(bands)), key=counts.__getitem__)
        if counts[best]:
            method = "overlap"
            overlap = counts[best]
        else:
            method = "nearest"
            overlap = 0
            bbox = info["bbox"]
            if bbox:
                px = (bbox[0] + bbox[2]) / 2.0
                py = (bbox[1] + bbox[3]) / 2.0
            else:
                px, py = info["peg"]["x"], info["peg"]["y"]

            def distance(band):
                bb = band["bbox"]
                bx = (bb[0] + bb[2]) / 2.0
                by = (bb[1] + bb[3]) / 2.0
                return (bx - px) ** 2 + (by - py) ** 2

            best = min(range(len(bands)), key=lambda index: distance(bands[index]))
        band_pegs[best].append(info)
        assignments.append(
            {
                "id": info["id"],
                "shape": info["shape"],
                "type": info["type"],
                "band": best + 1,
                "method": method,
                "overlap_pixels": overlap,
            }
        )
    return assignments, band_pegs


def band_render_labels(band_pegs, width, height):
    """Paint each assigned peg's pixels with its band id (1-based)."""
    render = array.array("b", [0]) * (width * height)
    for band_index, infos in enumerate(band_pegs, start=1):
        for info in infos:
            for index in _iter_set_pixels(info, width):
                render[index] = band_index
    return render


def per_band_metrics(clean, band_pegs, render, width, height, margin=2):
    """IoU/precision/recall per ribbon band, authoritative against the cleaned mask."""
    labels = clean["band_label"]
    results = []
    for index, band in enumerate(clean["bands"], start=1):
        x0, y0, x1, y1 = band["bbox"]
        for info in band_pegs[index - 1]:
            bbox = info["bbox"]
            if bbox:
                x0 = min(x0, bbox[0])
                y0 = min(y0, bbox[1])
                x1 = max(x1, bbox[2])
                y1 = max(y1, bbox[3])
        x0 = max(0, x0 - margin)
        y0 = max(0, y0 - margin)
        x1 = min(width, x1 + margin)
        y1 = min(height, y1 + margin)
        intersection = render_pixels = truth_pixels = 0
        for y in range(y0, y1):
            base = y * width
            for x in range(x0, x1):
                pos = base + x
                truth = labels[pos] == index
                drawn = render[pos] == index
                if truth:
                    truth_pixels += 1
                if drawn:
                    render_pixels += 1
                if truth and drawn:
                    intersection += 1
        union = truth_pixels + render_pixels - intersection
        results.append(
            {
                "band": index,
                "bbox": [x0, y0, x1, y1],
                "pegs": [info["id"] for info in band_pegs[index - 1]],
                "truth_pixels": truth_pixels,
                "render_pixels": render_pixels,
                "intersection_pixels": intersection,
                "union_pixels": union,
                "iou": intersection / union if union else 0.0,
                "precision": intersection / render_pixels if render_pixels else 0.0,
                "recall": intersection / truth_pixels if truth_pixels else 0.0,
            }
        )
    return results


def circle_metrics(infos, raw_mask, width, supersample):
    """Per-circle IoU against the raw mask (circles are untouched by cleaning)."""
    results = []
    for info in infos:
        if info["shape"] != "circle":
            continue
        info["threshold"] = supersample * supersample
        intersection = peg_pixels = mask_pixels = 0
        for index in _iter_set_pixels(info, width):
            peg_pixels += 1
            if raw_mask[index]:
                intersection += 1
        bbox = info["bbox"]
        if bbox:
            bx0, by0, bx1, by1 = bbox
            for y in range(by0, by1):
                base = y * width
                for x in range(bx0, bx1):
                    if raw_mask[base + x]:
                        mask_pixels += 1
        union = peg_pixels + mask_pixels - intersection
        results.append(
            {
                "id": info["id"],
                "iou": intersection / union if union else 0.0,
                "peg_pixels": peg_pixels,
                "mask_pixels": mask_pixels,
                "intersection_pixels": intersection,
            }
        )
    results.sort(key=lambda item: item["iou"])
    return {
        "count": len(results),
        "mean_iou": (sum(item["iou"] for item in results) / len(results)) if results else 0.0,
        "min_iou": results[0]["iou"] if results else 0.0,
        "worst": results[:5],
    }


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


def _display(path):
    if not path:
        return "(none)"
    try:
        relative = os.path.relpath(path, REPO_ROOT)
    except ValueError:
        return path
    return relative if not relative.startswith("..") else path


def _shape_summary(pegs):
    counts = {}
    for peg in pegs:
        counts[peg["shape"]] = counts.get(peg["shape"], 0) + 1
    order = ("circle", "annular", "rectangle")
    parts = [f"{counts[name]} {name}" for name in order if counts.get(name)]
    for name in sorted(set(counts) - set(order)):
        parts.append(f"{counts[name]} {name}")
    return ", ".join(parts) if parts else "no pegs"


def _metric_block(metrics):
    return (
        f"IoU {metrics['iou']:.6f} | precision {metrics['precision']:.6f} | "
        f"recall {metrics['recall']:.6f} | px {metrics['artifact_pixels']} vs "
        f"{metrics['mask_pixels']} (intersection {metrics['intersection_pixels']}, "
        f"FP {metrics['false_positive_pixels']}, FN {metrics['false_negative_pixels']})"
    )


def format_report(artifact, transform, clean, raw, cleaned, ribbons, circles, stats, args):
    lines = []
    lines.append(f"artifact: {_display(args.artifact)}")
    lines.append(
        f"  {artifact['name']}: {len(artifact['pegs'])} pegs "
        f"({_shape_summary(artifact['pegs'])}); virtual size "
        f"{artifact['size'][0]:.4f}x{artifact['size'][1]:.4f}")
    if transform["path"]:
        lines.append(f"world transform: {_display(transform['path'])}")
    else:
        lines.append("world transform: identity (--identity-transform)")
    lines.append(
        f"  scale {transform['scale']:.10f}; shooter_native "
        f"({transform['shooter_x']:.4f}, {transform['shooter_y']:.4f}); "
        f"virtual {transform['virtual_width']:.6f}x{transform['virtual_height']:.6f}; "
        f"native {transform['native_width']:.0f}x{transform['native_height']:.0f}")
    if transform["peg_radius"] is not None:
        lines.append(
            f"  world peg radius {transform['peg_radius']:.4f} "
            f"(native {transform['peg_radius'] / transform['scale']:.4f})")
    lines.append(
        f"  inverse: x_native = {transform['shooter_x']:.4f} + "
        f"(x_world - {transform['virtual_width'] / 2.0:.6f}) / s; "
        f"y_native = {transform['shooter_y']:.4f} + (y_world - "
        f"{transform['shooter_y']:.4f}) / s")
    lines.append(f"mask:     {_display(args.mask)}")
    lines.append(
        f"  raw {clean['raw_pixels']} px; "
        f"{clean['raw_components']} components ({clean['raw_ribbon_components']} "
        f"ribbon pieces, {clean['circle_components']} circles area "
        f"{clean['circle_area_min']}-{clean['circle_area_max']} untouched)")
    lines.append(
        f"  cleaned: close disk r={clean['close_radius']:g} px "
        f"({clean['offsets']} offsets) + fill holes -> {len(clean['bands'])} bands, "
        f"{clean['cleaned_pixels']} px (+{clean['added_pixels']} vs raw)")
    lines.append(
        f"supersample {args.supersample}x; pixel set at >=50% coverage; "
        f"regression floors: cleaned IoU >= {args.threshold:.4f} overall and "
        f">= {args.ribbon_threshold:.4f} per ribbon")
    lines.append(
        "  (floors, not a fidelity claim: the smooth constant-thickness "
        "single-slide model and squared end caps cap the honest cleaned IoU "
        "near 0.945 overall / 0.886-0.930 per band; 0.97/0.95 is the "
        "fidelity reference, reported only)")
    lines.append(f"cleaned (authoritative): {_metric_block(cleaned)}")
    lines.append(f"raw (documented tolerance, not gated): {_metric_block(raw)}")
    lines.append("per-ribbon (cleaned, required >= %.4f):" % args.ribbon_threshold)
    lines.append(
        f"  {'band':>4} {'pegs':>4} {'bbox (x0,y0)-(x1,y1)':<26} "
        f"{'truth':>7} {'render':>7} {'IoU':>8} {'prec':>8} {'recall':>8}")
    for item in ribbons:
        bbox = item["bbox"]
        lines.append(
            f"  {item['band']:>4} {len(item['pegs']):>4} "
            f"({bbox[0]},{bbox[1]})-({bbox[2]},{bbox[3]})".ljust(42)
            + f" {item['truth_pixels']:>7} {item['render_pixels']:>7} "
            f"{item['iou']:>8.6f} {item['precision']:>8.6f} {item['recall']:>8.6f}")
    lines.append(
        f"circles (raw mask, informational): {circles['count']} circles, "
        f"mean IoU {circles['mean_iou']:.6f}, min {circles['min_iou']:.6f}")
    if stats:
        lines.append(f"worst pegs (top {len(stats)} by missing+extra px vs cleaned mask):")
        for item in stats:
            bbox = item["bbox"]
            bbox_text = (
                f"({bbox[0]},{bbox[1]})-({bbox[2]},{bbox[3]})" if bbox else "outside")
            lines.append(
                f"  id {item['id']} {item['shape']} {item['type']} {bbox_text}: "
                f"peg {item['peg_pixels']} px, extra {item['extra_pixels']}, "
                f"missing {item['missing_pixels']}")
    lines.append(
        f"diff: {_display(args.diff)} (cleaned; white=both, red=false positive, "
        "blue=false negative, black=neither)")
    lines.append(f"diff: {_display(args.diff_raw)} (raw mask)")
    lines.append(f"metrics: {_display(args.metrics)}")
    ribbon_failures = [
        item["band"] for item in ribbons if item["iou"] < args.ribbon_threshold]
    overall_ok = cleaned["iou"] >= args.threshold
    if overall_ok and not ribbon_failures:
        lines.append(
            f"PASS: cleaned IoU {cleaned['iou']:.6f} >= {args.threshold:.4f}; "
            f"{len(ribbons)}/{len(ribbons)} ribbons >= {args.ribbon_threshold:.4f}")
    else:
        if not overall_ok:
            lines.append(
                f"FAIL: cleaned IoU {cleaned['iou']:.6f} < {args.threshold:.4f}")
        if ribbon_failures:
            detail = ", ".join(
                f"band {item['band']} {item['iou']:.6f}" for item in ribbons
                if item["band"] in ribbon_failures)
            lines.append(
                f"FAIL: ribbon IoU < {args.ribbon_threshold:.4f}: {detail}")
    return lines


# ---------------------------------------------------------------------------
# Self test
# ---------------------------------------------------------------------------


def _synthetic_document(pegs, width, height):
    return {"pegs": pegs, "layout": "synthetic", "size": (width, height),
            "name": "selftest"}


def _circle_peg(index, x, y, radius):
    return {"index": index, "id": index + 1, "shape": "circle", "type": "blue",
            "x": float(x), "y": float(y), "radius": float(radius)}


def _annular_peg(index, x, y, r_in, r_out, start, end):
    return {"index": index, "id": index + 1, "shape": "annular", "type": "red",
            "x": float(x), "y": float(y), "r_in": float(r_in), "r_out": float(r_out),
            "theta_start": float(start), "theta_end_abs": float(end)}


def _rect_peg(index, x, y, width, height, angle):
    return {"index": index, "id": index + 1, "shape": "rectangle", "type": "green",
            "x": float(x), "y": float(y), "width": float(width),
            "height": float(height), "angle": float(angle)}


def _raster_single(peg, width, height, supersample=4):
    document = _synthetic_document([peg], width, height)
    binary, infos = rasterize_document(document, width, height, supersample)
    return binary, infos[0]


def _area_of(binary):
    return sum(binary)


def run_selftest():
    failures = []
    results = []

    def check(name, ok, detail):
        results.append((name, ok, detail))
        if not ok:
            failures.append(name)

    # PNG round-trips (gray and RGB) and every decoder filter path.
    with tempfile.TemporaryDirectory(prefix="ribbon_mask_selftest_") as tmp:
        gray = bytearray((x * 17) % 256 for x in range(9 * 7))
        gray_path = os.path.join(tmp, "gray.png")
        write_png(gray_path, 9, 7, 1, gray)
        decoded = decode_png(gray_path)
        check(
            "png_roundtrip_gray",
            decoded["width"] == 9 and decoded["height"] == 7
            and decoded["channels"] == 1 and decoded["pixels"] == gray,
            f"{decoded['width']}x{decoded['height']}x{decoded['channels']}",
        )

        rgb = bytearray((i * 37) % 256 for i in range(11 * 5 * 3))
        rgb_path = os.path.join(tmp, "rgb.png")
        write_png(rgb_path, 11, 5, 3, rgb)
        decoded = decode_png(rgb_path)
        check(
            "png_roundtrip_rgb",
            decoded["width"] == 11 and decoded["height"] == 5
            and decoded["channels"] == 3 and decoded["pixels"] == rgb,
            f"{decoded['width']}x{decoded['height']}x{decoded['channels']}",
        )

        def encode_with_filters(width, height, channels, pixels, filters):
            stride = width * channels
            raw = bytearray()
            previous = bytes(stride)
            for y in range(height):
                filter_type = filters[y % len(filters)]
                line = bytes(pixels[y * stride:(y + 1) * stride])
                raw.append(filter_type)
                for i in range(stride):
                    value = line[i]
                    left = line[i - channels] if i >= channels else 0
                    up = previous[i]
                    upleft = previous[i - channels] if i >= channels else 0
                    if filter_type == 0:
                        encoded = value
                    elif filter_type == 1:
                        encoded = (value - left) & 0xFF
                    elif filter_type == 2:
                        encoded = (value - up) & 0xFF
                    elif filter_type == 3:
                        encoded = (value - ((left + up) >> 1)) & 0xFF
                    else:
                        encoded = (value - _paeth(left, up, upleft)) & 0xFF
                    raw.append(encoded)
                previous = line
            color_type = 0 if channels == 1 else 2
            ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
            return (
                PNG_SIGNATURE
                + _png_chunk(b"IHDR", ihdr)
                + _png_chunk(b"IDAT", zlib.compress(bytes(raw), 6))
                + _png_chunk(b"IEND", b"")
            )

        for label, width, height, channels, pixels in (
            ("gray", 13, 9, 1, bytes((i * 29 + 7) % 256 for i in range(13 * 9))),
            ("rgb", 12, 7, 3, bytes((i * 53 + 11) % 256 for i in range(12 * 7 * 3))),
        ):
            for filters in ([0], [1], [2], [3], [4], [0, 1, 2, 3, 4]):
                path = os.path.join(
                    tmp, f"filters_{label}_{''.join(map(str, filters))}.png")
                with open(path, "wb") as handle:
                    handle.write(encode_with_filters(
                        width, height, channels, pixels, filters))
                image = decode_png(path)
                check(
                    f"png_filters_{label}_{''.join(map(str, filters))}",
                    image["pixels"] == bytearray(pixels),
                    f"filters {filters}",
                )

    # Filled circle area and bbox.
    radius = 20.0
    binary, info = _raster_single(_circle_peg(0, 64, 64, radius), 128, 128)
    observed = _area_of(binary)
    expected = math.pi * radius * radius
    check(
        "circle_area",
        abs(observed - expected) / expected <= 0.02,
        f"observed {observed} expected {expected:.1f}",
    )
    check("circle_bbox", info["bbox"] == (44, 44, 84, 84), f"bbox {info['bbox']}")

    # Union semantics: identical overlapping pegs must not double count.
    doubled, _ = rasterize_document(
        _synthetic_document(
            [_circle_peg(0, 64, 64, radius), _circle_peg(1, 64, 64, radius)],
            128, 128), 128, 128, 4)
    check(
        "union_identical_overlap",
        _area_of(doubled) == observed,
        f"single {observed} double {_area_of(doubled)}",
    )

    # Annular areas: full rings and partial sectors.
    expected = math.pi * (30.0 ** 2 - 10.0 ** 2)
    for label, start, end in (
        ("full_annulus_0", 0.0, TWO_PI),
        ("full_annulus_neg", -math.pi, math.pi),
    ):
        binary, _ = _raster_single(_annular_peg(0, 64, 64, 10, 30, start, end), 128, 128)
        observed = _area_of(binary)
        check(
            label,
            abs(observed - expected) / expected <= 0.02,
            f"observed {observed} expected {expected:.1f}",
        )

    for label, start, end in (
        ("sector_quarter", 0.0, math.pi / 2),
        ("sector_half", 0.0, math.pi),
        ("sector_three_quarter", 0.0, 1.5 * math.pi),
        ("sector_negative_quarter", -math.pi / 2, 0.0),
    ):
        sweep = end - start
        binary, _ = _raster_single(_annular_peg(0, 64, 64, 10, 30, start, end), 128, 128)
        observed = _area_of(binary)
        expected = 0.5 * sweep * (30.0 ** 2 - 10.0 ** 2)
        check(
            label,
            abs(observed - expected) / expected <= 0.02,
            f"observed {observed} expected {expected:.1f}",
        )

    # Theta quadrant convention: y grows down, so theta 0..pi/2 is bottom-right.
    for label, start, end, sx, sy in (
        ("theta_0_to_90_bottom_right", 0.0, math.pi / 2, 1, 1),
        ("theta_90_to_180_bottom_left", math.pi / 2, math.pi, -1, 1),
        ("theta_180_to_270_top_left", math.pi, 1.5 * math.pi, -1, -1),
        ("theta_270_to_360_top_right", 1.5 * math.pi, TWO_PI, 1, -1),
    ):
        binary, _ = _raster_single(_annular_peg(0, 64, 64, 0, 30, start, end), 128, 128)
        total = 0
        sum_x = 0
        sum_y = 0
        for y in range(128):
            for x in range(128):
                if binary[y * 128 + x]:
                    total += 1
                    sum_x += x
                    sum_y += y
        centroid_x = sum_x / total if total else 0
        centroid_y = sum_y / total if total else 0
        check(
            label,
            total > 0 and (centroid_x - 64) * sx > 0 and (centroid_y - 64) * sy > 0,
            f"centroid ({centroid_x:.2f},{centroid_y:.2f}) sign ({sx:+d},{sy:+d})",
        )

    # Rectangle keeps its area under rotation.
    for label, angle in (("rectangle_area_axis", 0.0),
                         ("rectangle_area_rotated", math.pi / 6)):
        binary, _ = _raster_single(_rect_peg(0, 64, 64, 40, 20, angle), 128, 128)
        observed = _area_of(binary)
        check(
            label,
            abs(observed - 40.0 * 20.0) / (40.0 * 20.0) <= 0.02,
            f"observed {observed} expected 800.0",
        )

    # World transform round-trip and consistency validation.
    scale = 10.0 / 22.0
    native_w, native_h = 1545.0, 1289.0
    transform = {
        "scale": scale,
        "shooter_x": 772.5,
        "shooter_y": 50.0,
        "virtual_width": native_w * scale,
        "virtual_height": 50.0 + (native_h - 50.0) * scale,
        "native_width": native_w,
        "native_height": native_h,
        "peg_radius": 10.0,
        "ball_radius": 6.0,
        "ribbon_count": 5,
        "path": None,
    }
    world = _circle_peg(0, 0, 0, 10.0)
    world["x"] = 123.25
    world["y"] = 456.5
    native = world_to_native_peg(world, transform)
    # native -> world is the inverse used by the generator
    bx = (native["x"] - transform["shooter_x"]) * scale + transform["virtual_width"] / 2.0
    by = (native["y"] - transform["shooter_y"]) * scale + transform["shooter_y"]
    check(
        "transform_roundtrip",
        abs(bx - world["x"]) < 1e-9 and abs(by - world["y"]) < 1e-9
        and abs(native["radius"] - 22.0) < 1e-9,
        f"world ({world['x']},{world['y']}) -> native ({native['x']:.6f},"
        f"{native['y']:.6f}, r {native['radius']:.6f}) -> world ({bx:.6f},{by:.6f})",
    )
    try:
        validate_transform(transform, (transform["virtual_width"],
                                       transform["virtual_height"]),
                           (1545, 1289))
        consistent = True
    except CheckError:
        consistent = False
    bad = dict(transform, virtual_width=1.0)
    try:
        validate_transform(bad, (bad["virtual_width"], bad["virtual_height"]),
                           (1545, 1289))
        bad_rejected = False
    except CheckError:
        bad_rejected = True
    check("transform_consistency_ok", consistent, "valid block accepted")
    check("transform_consistency_reject", bad_rejected, "bad virtual_width rejected")

    # Mask cleaning: close the brick seam, fill band holes, leave circles alone.
    width, height = 240, 140
    mask = bytearray(width * height)

    def put(x, y, value=1):
        mask[y * width + x] = value

    for y in range(20, 41):
        for x in range(2, 238):
            put(x, y)
    for y in range(20, 41):
        for x in range(100, 104):      # 4 px brick seam
            put(x, y, 0)
    for y in range(28, 31):
        for x in range(60, 63):        # 3x3 hole in the band
            put(x, y, 0)
    for y in range(height):
        for x in range(width):
            dx = x - 50
            dy = y - 110
            if dx * dx + dy * dy <= 15 * 15:
                put(x, y)
    for y in range(108, 110):
        for x in range(63, 65):        # enclosed notch in a circle
            put(x, y, 0)

    cleaned = build_cleaned_mask(
        mask, width, height, close_radius=2.5, ribbon_min_area=2000,
        expected_ribbons=1)
    band_hole = cleaned["cleaned"][29 * width + 61]
    circle_hole = cleaned["cleaned"][108 * width + 63]
    seam = cleaned["cleaned"][30 * width + 101]
    circle_raw_px = sum(
        mask[y * width + x]
        for y in range(90, 131) for x in range(30, 71))
    circle_clean_px = sum(
        cleaned["cleaned"][y * width + x]
        for y in range(90, 131) for x in range(30, 71))
    check(
        "clean_close_seam",
        seam == 1,
        f"seam pixel {seam}",
    )
    check(
        "clean_fill_band_hole",
        band_hole == 1 and cleaned["band_label"][29 * width + 61] == 1,
        f"band hole {band_hole}",
    )
    check(
        "clean_leave_circle_untouched",
        circle_hole == 0 and circle_clean_px == circle_raw_px,
        f"circle hole {circle_hole}; circle px {circle_raw_px}->{circle_clean_px}",
    )
    check(
        "clean_single_band",
        len(cleaned["bands"]) == 1 and cleaned["raw_ribbon_components"] == 2,
        f"bands {len(cleaned['bands'])} raw ribbon pieces "
        f"{cleaned['raw_ribbon_components']}",
    )

    # End-to-end on the committed mustache artifact: rasterize the artifact,
    # write that silhouette as a mask, decode it and require an exact match.
    # This exercises the real artifact loader + PNG pipeline (identity space).
    mustache = os.path.join(
        REPO_ROOT, "fixtures", "mustache", "artifact", "mustache.v1.json")
    if os.path.isfile(mustache):
        artifact = load_artifact(mustache)
        board_w, board_h = int(artifact["size"][0]), int(artifact["size"][1])
        pegs = world_to_native_pegs(
            artifact["pegs"], identity_transform(board_w, board_h))
        binary, infos = rasterize_document(
            _synthetic_document(pegs, board_w, board_h),
            board_w, board_h, 4)
        shapes = {}
        for info in infos:
            shapes[info["shape"]] = shapes.get(info["shape"], 0) + 1
        with tempfile.TemporaryDirectory(prefix="ribbon_mask_selftest_") as tmp:
            mask_path = os.path.join(tmp, "mustache.png")
            write_png(mask_path, board_w, board_h, 1,
                      bytes(255 if value else 0 for value in binary))
            from_mask = mask_binary(decode_png(mask_path))
            metrics = compare_binary(binary, from_mask, board_w, board_h)
        check(
            "mustache_artifact_shapes",
            shapes.get("circle") == 27 and shapes.get("annular") == 72,
            f"shape counts {shapes}",
        )
        check(
            "mustache_artifact_silhouette_roundtrip",
            abs(metrics["iou"] - 1.0) < 1e-12
            and metrics["false_positive_pixels"] == 0
            and metrics["false_negative_pixels"] == 0,
            f"IoU {metrics['iou']:.6f} fp {metrics['false_positive_pixels']} "
            f"fn {metrics['false_negative_pixels']}",
        )

    # Compare pipeline: identical binaries give IoU 1.0, a shifted mask must not.
    with tempfile.TemporaryDirectory(prefix="ribbon_mask_selftest_") as tmp:
        document = _synthetic_document(
            [_annular_peg(0, 32, 32, 5, 20, -0.3, 2.2)], 64, 64)
        binary, _ = rasterize_document(document, 64, 64, 4)
        mask_path = os.path.join(tmp, "mask.png")
        write_png(mask_path, 64, 64, 1, bytes(255 if v else 0 for v in binary))
        from_mask = mask_binary(decode_png(mask_path))
        same = compare_binary(binary, from_mask, 64, 64)
        shifted = bytearray(64 * 64)
        for y in range(64):
            for x in range(64):
                if from_mask[y * 64 + x] and x + 2 < 64:
                    shifted[y * 64 + x + 2] = 1
        moved = compare_binary(binary, shifted, 64, 64)
        check(
            "compare_identical_iou",
            abs(same["iou"] - 1.0) < 1e-12,
            f"IoU {same['iou']:.6f}",
        )
        check(
            "compare_shifted_detects_diff",
            moved["iou"] < 0.99 and moved["false_positive_pixels"] > 0
            and moved["false_negative_pixels"] > 0,
            f"IoU {moved['iou']:.6f} fp {moved['false_positive_pixels']} "
            f"fn {moved['false_negative_pixels']}",
        )

    for name, ok, detail in results:
        print(f"{'PASS' if ok else 'FAIL'} {name}: {detail}")
    print(f"selftest: {len(results) - len(failures)} passed, {len(failures)} failed")
    return 0 if not failures else 1


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser():
    parser = argparse.ArgumentParser(
        description="Check the exported ribbon_waves artifact against the "
                    "cleaned reference peg mask.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--artifact", default=DEFAULT_ARTIFACT,
        help="peggle.level.v1 artifact to rasterize "
             f"(default: {os.path.relpath(DEFAULT_ARTIFACT, REPO_ROOT)})")
    parser.add_argument(
        "--mask", default=DEFAULT_MASK,
        help="reference grayscale mask PNG "
             f"(default: {os.path.relpath(DEFAULT_MASK, REPO_ROOT)})")
    parser.add_argument(
        "--source-geometry", default=DEFAULT_SOURCE, metavar="FILE",
        help="extraction geometry JSON supplying the world transform "
             f"(default: {os.path.relpath(DEFAULT_SOURCE, REPO_ROOT)})")
    parser.add_argument(
        "--identity-transform", action="store_true",
        help="treat the artifact as native-space (no world block); for "
             "non-ribbon boards such as the mustache artifact")
    parser.add_argument(
        "--diff", default=DEFAULT_DIFF,
        help=f"cleaned-mask diff PNG (default: {os.path.relpath(DEFAULT_DIFF, REPO_ROOT)})")
    parser.add_argument(
        "--diff-raw", default=DEFAULT_DIFF_RAW,
        help="raw-mask diff PNG "
             f"(default: {os.path.relpath(DEFAULT_DIFF_RAW, REPO_ROOT)})")
    parser.add_argument(
        "--metrics", default=DEFAULT_METRICS,
        help="metrics JSON (default: "
             f"{os.path.relpath(DEFAULT_METRICS, REPO_ROOT)})")
    parser.add_argument(
        "--threshold", type=float, default=0.92,
        help="required cleaned overall IoU regression floor (default: 0.92)")
    parser.add_argument(
        "--ribbon-threshold", type=float, default=0.86,
        help="required cleaned IoU per ribbon band regression floor (default: 0.86)")
    parser.add_argument(
        "--ribbons", type=int, default=5,
        help="number of ribbon bands expected after cleaning (default: 5)")
    parser.add_argument(
        "--close-radius", type=float, default=2.5,
        help="mask cleaning disk radius in pixels (default: 2.5 = 5 px diameter)")
    parser.add_argument(
        "--ribbon-min-area", type=int, default=2000,
        help="mask components above this area are ribbon material (default: 2000)")
    parser.add_argument(
        "--supersample", type=int, default=4,
        help="supersampling factor per axis (default: 4)")
    parser.add_argument("--top", type=int, default=10,
                        help="worst pegs to report (default: 10)")
    parser.add_argument("--quiet", action="store_true",
                        help="suppress the human-readable report")
    parser.add_argument("--json", action="store_true",
                        help="print the metrics JSON to stdout")
    parser.add_argument("--selftest", action="store_true",
                        help="run synthetic rasterizer/cleaner tests and exit")
    return parser


def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.selftest:
        try:
            return run_selftest()
        except CheckError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 2
        except Exception as exc:  # pragma: no cover
            print(f"ERROR: selftest crashed: {type(exc).__name__}: {exc}",
                  file=sys.stderr)
            return 2

    try:
        if not (0.0 < args.threshold <= 1.0):
            raise CheckError(f"--threshold must be in (0, 1], got {args.threshold}")
        if not (0.0 < args.ribbon_threshold <= 1.0):
            raise CheckError(
                f"--ribbon-threshold must be in (0, 1], got {args.ribbon_threshold}")
        if args.ribbons < 1:
            raise CheckError(f"--ribbons must be >= 1, got {args.ribbons}")
        if args.close_radius < 0:
            raise CheckError(f"--close-radius must be >= 0, got {args.close_radius}")
        if args.ribbon_min_area < 0:
            raise CheckError(
                f"--ribbon-min-area must be >= 0, got {args.ribbon_min_area}")
        if not (1 <= args.supersample <= 8):
            raise CheckError(f"--supersample must be in [1, 8], got {args.supersample}")
        if args.top < 0:
            raise CheckError(f"--top must be >= 0, got {args.top}")

        mask_image = decode_png(args.mask)
        mask_size = (mask_image["width"], mask_image["height"])
        raw_mask = mask_binary(mask_image)
        if not any(raw_mask):
            raise CheckError(f"{args.mask}: mask has no pixels above the >127 threshold")

        artifact = load_artifact(args.artifact)
        if args.identity_transform:
            transform = identity_transform(
                int(artifact["size"][0]), int(artifact["size"][1]))
            if (int(artifact["size"][0]), int(artifact["size"][1])) != mask_size:
                raise CheckError(
                    f"identity transform requires artifact size == mask size; "
                    f"artifact {artifact['size'][0]:.0f}x{artifact['size'][1]:.0f} "
                    f"mask {mask_size[0]}x{mask_size[1]}")
        else:
            transform = load_transform(args.source_geometry, mask_size)
            if transform["ribbon_count"] is not None \
                    and transform["ribbon_count"] != args.ribbons:
                raise CheckError(
                    f"source geometry has {transform['ribbon_count']} ribbons but "
                    f"--ribbons is {args.ribbons}")
        validate_transform(transform, artifact["size"], mask_size)

        native_pegs = world_to_native_pegs(artifact["pegs"], transform)
        width, height = mask_size
        native_binary, infos = rasterize_document(
            {"pegs": native_pegs}, width, height, args.supersample)

        raw_metrics = compare_binary(native_binary, raw_mask, width, height)
        raw_diff = raw_metrics.pop("diff")

        clean = build_cleaned_mask(
            raw_mask, width, height, close_radius=args.close_radius,
            ribbon_min_area=args.ribbon_min_area, expected_ribbons=args.ribbons)
        cleaned_metrics = compare_binary(
            native_binary, clean["cleaned"], width, height)
        cleaned_diff = cleaned_metrics.pop("diff")

        assignments, band_pegs = assign_bands(
            infos, clean, width, args.supersample)
        render = band_render_labels(band_pegs, width, height)
        ribbons = per_band_metrics(clean, band_pegs, render, width, height)
        circles = circle_metrics(infos, raw_mask, width, args.supersample)
        stats = per_peg_stats(
            infos, native_binary, clean["cleaned"], width, args.top)

        write_png(args.diff, width, height, 3, cleaned_diff)
        write_png(args.diff_raw, width, height, 3, raw_diff)

        shape_counts = {}
        for peg in artifact["pegs"]:
            shape_counts[peg["shape"]] = shape_counts.get(peg["shape"], 0) + 1
        ribbon_failures = [
            item["band"] for item in ribbons if item["iou"] < args.ribbon_threshold]
        ok = cleaned_metrics["iou"] >= args.threshold and not ribbon_failures

        payload = {
            "format": "ribbon_waves.mask_check.v2",
            "ok": ok,
            "thresholds": {
                "overall_iou": args.threshold,
                "ribbon_iou": args.ribbon_threshold,
                "kind": "regression_floor",
                "fidelity_reference": {"overall_iou": 0.97, "ribbon_iou": 0.95},
                "authoritative": "cleaned",
            },
            "artifact": {
                "path": _display(args.artifact),
                "name": artifact["name"],
                "virtual_size": list(artifact["size"]),
                "peg_count": len(artifact["pegs"]),
                "shape_counts": shape_counts,
            },
            "transform": {
                "path": _display(args.source_geometry) if not args.identity_transform else None,
                "identity": bool(args.identity_transform),
                "scale": transform["scale"],
                "shooter_native": [transform["shooter_x"], transform["shooter_y"]],
                "virtual_width": transform["virtual_width"],
                "virtual_height": transform["virtual_height"],
                "native_size": [transform["native_width"], transform["native_height"]],
                "peg_radius": transform["peg_radius"],
                "ball_radius": transform["ball_radius"],
            },
            "mask": {
                "path": _display(args.mask),
                "size": [width, height],
                "raw_pixels": clean["raw_pixels"],
                "cleaned_pixels": clean["cleaned_pixels"],
                "added_pixels": clean["added_pixels"],
                "raw_components": clean["raw_components"],
                "raw_ribbon_components": clean["raw_ribbon_components"],
                "circle_components": clean["circle_components"],
                "close_radius": clean["close_radius"],
                "ribbon_min_area": clean["ribbon_min_area"],
                "bands": len(clean["bands"]),
            },
            "raw": dict(raw_metrics, authoritative=False),
            "cleaned": dict(cleaned_metrics, authoritative=True),
            "ribbons": ribbons,
            "circles": circles,
            "band_assignments": assignments,
            "worst_pegs": stats,
            "diff": {
                "cleaned": _display(args.diff),
                "raw": _display(args.diff_raw),
            },
            "metrics_path": _display(args.metrics),
        }

        try:
            os.makedirs(
                os.path.dirname(os.path.abspath(args.metrics)) or ".", exist_ok=True)
            with open(args.metrics, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, indent=2)
                handle.write("\n")
        except OSError as exc:
            raise CheckError(
                f"cannot write metrics {args.metrics!r}: {exc.strerror or exc}")

        report = format_report(
            artifact, transform, clean, raw_metrics, cleaned_metrics,
            ribbons, circles, stats, args)
        if args.json:
            print(json.dumps(payload, indent=2))
            if not args.quiet:
                print("\n".join(report), file=sys.stderr)
        elif not args.quiet:
            print("\n".join(report))

        return 0 if ok else 1
    except CheckError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
